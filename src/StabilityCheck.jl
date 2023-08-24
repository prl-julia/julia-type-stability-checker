module StabilityCheck

#
# Exhaustive enumeration of types for static type stability checking
#

export @stable, @stable!, @stable!_nop,
    is_stable_method, is_stable_module, is_stable_moduleb,
    check_all_stable,
    convert,
    typesDB,

    # Stats
    AgStats,
    aggregateStats,
    # CSV-aware tools
    checkModule, prepCsv,

    # Types
    MethStCheck,
    SkippedUnionAlls, UnboundedUnionAlls, SkipMandatory, TooManyInst,
    Stb, Par, Uns, AnyParam, VarargParam, TcFail, OutOfFuel, GenericMethod,
    SearchCfg, build_typesdb_scfg, default_scfg

# Debug print:
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on
# ENV["JULIA_DEBUG"] = Nothing         # turn off

include("equality.jl")

using InteractiveUtils
using MacroTools
using CSV
using Setfield

include("typesDB.jl")
include("types.jl")
include("report.jl")
include("utils.jl")
include("enumeration.jl")
include("annotations.jl")


#
#       Main interface utilities
#

#
# is_stable_module : Module, SearchCfg; Vector{Module} -> IO StCheckResults
#
# Check all method definitions in the module for stability.
# "All" can mean all we can find or exported only; this is controlled by `SearchCfg`'s  `exported_names_only`.
#
# By default, we don't handle methods extending functions defined elsewhere if these functions
# were not also imported. See explanation of `extra_modules` below.
#
# The `extra_modules` parameter can be used to include functions that are introduced
# in these modules. The reason for it is that a module can add methods to external
# functions without also importing them into its scope. For example, when a
# module `m` contains `Base.push!(x::MyVec, e) = ...` without importing `push!`,
# then `names(m)` does not include `push!`. However, `names(Base)` does, and we
# can then filter only the methods that originate in `m`.
#
# To make sure we find all methods from `m`, `extra_modules` has to contain all
# the transitive dependencies of `m`, as well as `Base` and `Core` (which are
# always imported by default). One simple over-approximation is to use
# `Base.loaded_modules_array()`.
#
# Notes: constructors and function-like(*) objects are currently ignored
#
# (*) https://docs.julialang.org/en/v1/manual/methods/#Function-like-objects
#
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg; extra_modules :: Vector{Module} = Module[]) :: StCheckResults = begin
    @debug "is_stable_module($mod)" extra_modules

    functions_found = Dict{Module,Set{OpaqueFunction}}()
    modules_visited = Set{Module}([Main])
    for m in Iterators.flatten(([mod], extra_modules))
        discover_functions(m, m, scfg, modules_visited, get!(functions_found, m, Set{OpaqueFunction}()))
            end

    result = StCheckResults()
    for f in Set(Iterators.flatten(values(functions_found)))
        for m in methods(f)
            try
                is_module_nested(m.module, mod) &&
                    push!(result, MethStCheck(m, is_stable_method(m, scfg)))
        catch e
                if e isa CantSplitMethod
                    @warn "Can't process method with no canonical instance: $(e.m)."
                # cf. comment in `split_method`
            else
                throw(e)
            end
        end
    end
    end
    return result
end

# bool-returning version of the above
is_stable_moduleb(mod::Module, scfg :: SearchCfg = default_scfg; extra_modules :: Vector{Module} = Module[]) :: Bool =
    convert(Bool, is_stable_module(mod, scfg; extra_modules))

#
# is_stable_method : Method, SearchCfg -> StCheck
#
# Main interface utility: check if method is stable by enumerating
# all possible instantiations of its signature.
#
# If signature has Any at any place and (! scfg.types_db.use_types_db), i.e. we don't want
# to sample types, yeild AnyParam immediately.
# If signature has Vararg at any place, yeild VarargParam immediately.
#
is_stable_method(m::Method, scfg :: SearchCfg = default_scfg) :: StCheck = begin
    @debug "is_stable_method: $m"

    if scfg.typesDBcfg.use_types_db
        scfg.typesDBcfg.types_db === Nothing &&
            (scfg.typesDBcfg.types_db = typesDB())
    end

    # Split method into signature and the corresponding function object
    sm = split_method(m)
    sm isa GenericMethod && return sm
    (func, sig_types) = sm

    # Corner cases where we give up
    Any ∈ sig_types && ! scfg.typesDBcfg.use_types_db && return AnyParam(sig_types)
    any(t -> is_vararg(t), sig_types) && return VarargParam(sig_types)

    # Loop over all instantiations of the signature
    unst = Vector{Any}([])
    steps = 0
    skipexists = Set{SkippedUnionAlls}([])
    for ts in Channel(ch -> all_subtypes(sig_types, scfg, ch))
        @debug "[ is_stable_method ] loop" steps "$ts"

        # case over special cases
        if ts == "done"
            break
        end
        if ts isa OutOfFuel
            return ts
        end
        if ts isa SkippedUnionAlls
            push!(skipexists, ts)
            continue
        end

        # the actual stability check
        try
            if ! is_stable_call(func, ts)
                push!(unst, ts)
            end
        catch e
            return TcFail(ts, e)
        end

        # increment the counter, check fuel
        steps += 1
        if steps > scfg.fuel
            return OutOfFuel()
        end
    end

    return if isempty(unst)
        if isempty(skipexists)
            Stb(steps)
        else
            Par(steps, skipexists)
        end
    else
        Uns(steps, unst)
    end
end


end # module
