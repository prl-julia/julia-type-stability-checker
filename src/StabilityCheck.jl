module StabilityCheck

#
# Exhaustive enumeration of types for static type stability checking
#

export @stable, @stable!, @stable!_nop,
    is_stable_method, is_stable_function, is_stable_module, is_stable_moduleb,
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
# is_stable_module : Module, SearchCfg -> IO StCheckResults
#
# Check all(*) function definitions in the module for stability.
# Relies on `is_stable_function`.
# (*) "all" can mean all or exported; cf. `SearchCfg`'s  `exported_names_only`.
#
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_module: $mod"
    res = []
    ns = names(mod; all=!scfg.exported_names_only)
    @debug "number of methods in $mod: $(length(ns))"
    for sym in ns
        @debug "is_stable_module($mod): check symbol $sym"
        try
            evsym = getproperty(mod, sym)
            # recurse into submodules
            if evsym isa Module && evsym != mod
                append!(res, is_stable_module(evsym, scfg))
                continue
            end
            isa(evsym, Function) || continue # not interested in non-functional symbols
            (sym == :include || sym == :eval) && continue # not interested in special functions
            res = vcat(res, is_stable_function(evsym, scfg))
        catch e
            if e isa UndefVarError
                @warn "Module $mod exports symbol $sym but it's undefined"
                # showerror(stdout, e)
                # not our problem, so proceed as usual
            else
                throw(e)
            end
        end
    end
    return res
end

# bool-returning version of the above
is_stable_moduleb(mod::Module, scfg :: SearchCfg = default_scfg) :: Bool =
    convert(Bool, is_stable_module(mod, scfg))

#
# is_stable_function : Function, SearchCfg -> IO StCheckResults
#
# Convenience tool to iterate over all known methods of a function.
# Usually, direct use of `is_stable_method` is preferrable, but, for instance,
# `is_stable_module` has to rely on this one.
#
is_stable_function(f::Function, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_function: $f"
    res = []
    for m in methods(f).ms
        try
            push!(res, MethStCheck(m, is_stable_method(m, scfg)))
        catch err
            if err isa CantSplitMethod
                @warn "Can't process method with no canonical instance:\n$m"
                # cf. comment in `split_method`
            else
                throw(err)
            end
        end
    end
    res
end

#
# is_stable_method : Method, SearchCfg -> StCheck
#
# Main interface utility: check if method is stable by enumerating
# all possible instantiations of its signature.
#
# If signature has Any at any place and (! scfg.use_types_db), i.e. we don't want
# to sample types, yeild AnyParam immediately.
# If signature has Vararg at any place, yeild VarargParam immediately.
#
is_stable_method(m::Method, scfg :: SearchCfg = default_scfg) :: StCheck = begin
    @debug "is_stable_method: $m"

    if scfg.use_types_db
        scfg.types_db === Nothing &&
            (scfg.types_db = typesDB())
    end

    # Slpit method into signature and the corresponding function object
    sm = split_method(m)
    sm isa GenericMethod && return sm
    (func, sig_types) = sm

    # Corner cases where we give up
    Any ∈ sig_types && ! scfg.use_types_db && return AnyParam(sig_types)
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
