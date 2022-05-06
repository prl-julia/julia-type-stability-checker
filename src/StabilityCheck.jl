module StabilityCheck

#
# Exhaustive enumeration of types for static type stability checking
#

export @stable, @stable!, @stable!_nop,
    is_stable_method, is_stable_function, is_stable_module, is_stable_moduleb,
    check_all_stable,
    convert,

    # Stats
    AgStats,
    aggregateStats,
    # CSV-aware tools
    checkModule, prepCsv,

    # Types
    MethStCheck,
    SkippedUnionAlls, UnboundedUnionAlls, SkipMandatory, TooManyInst,
    Stb, Uns, AnyParam, VarargParam, TcFail, OutOfFuel, GenericMethod,
    SearchCfg

# Debug print:
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on
# ENV["JULIA_DEBUG"] = Nothing         # turn off

include("equality.jl")

using InteractiveUtils
using MacroTools
using CSV
using Setfield

include("types.jl")
include("report.jl")
include("aux.jl")
include("enumeration.jl")


#
#       Main interface utilities
#


# @stable!: method definition AST -> IO same definition
# Side effects: Prints warning if finds unstable signature instantiation.
#               Relies on is_stable_method.
macro stable!(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(esc(def))
        m = which($(esc(fname)), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
        (f,_) = split_method(m)
        f
    end
end

# Interface for delayed stability checks; useful for define-after-use cases (cf. Issue #3)
# @stable delays the check until `check_all_stable` is called. The list of checks to perform
# is stored in a global list that needs cleenup once in a while with `clean_checklist`.
checklist=[]
macro stable(def)
    push!(checklist, def)
    def
end
check_all_stable() = begin
    @debug "start check_all_stable"
    for def in checklist
        (fname, argtypes) = split_def(def)
        @debug "Process method $fname with signature: $argtypes"
        m = which(eval(fname), eval(argtypes))
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end
clean_checklist() = begin
    global checklist = [];
end

# Variant of @stable! that doesn't splice the provided function definition
# into the global namespace. Mostly for testing purposes. Relies on Julia's
# hygiene support.
macro stable!_nop(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(def)
        m = which($(fname), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end

# is_stable_module : Module, SearchCfg -> IO StCheckResults
# Check all(*) function definitions in the module for stability.
# Relies on `is_stable_function`.
# (*) "all" can mean all or exported; cf. `SearchCfg`'s  `exported_names_only`.
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_module: $mod"
    res = []
    ns = names(mod; all=!scfg.exported_names_only)
    @debug "number of methods in $mod: $(length(ns))"
    for sym in ns
        @debug "is_stable_module: check symbol $sym"
        try
            evsym = getproperty(mod, sym)
            isa(evsym, Function) || continue # not interested in non-functional symbols
            (sym == :include || sym == :eval) && continue # not interested in special functions
            res = vcat(res, is_stable_function(evsym, scfg))
        catch e
            if e isa UndefVarError
                @warn "Module $mod exports symbol $sym but it's undefined"
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

# is_stable_function : Function, SearchCfg -> IO StCheckResults
# Convenience tool to iterate over all known methods of a function.
# Usually, direct use of `is_stable_method` is preferrable, but, for instance,
# `is_stable_module` has to rely on this one.
is_stable_function(f::Function, scfg :: SearchCfg = default_scfg) :: StCheckResults = begin
    @debug "is_stable_function: $f"
    map(m -> MethStCheck(m, is_stable_method(m, scfg)), methods(f).ms)
end

# is_stable_method : Method, SearchCfg -> StCheck
# Main interface utility: check if method is stable by enumerating
# all possible instantiations of its signature.
# If signature has Any at any place, yeild AnyParam immediately.
# If signature has Vararg at any place, yeild VarargParam immediately.
is_stable_method(m::Method, scfg :: SearchCfg = default_scfg) :: StCheck = begin
    @debug "is_stable_method: $m"
    sm = split_method(m)
    sm isa GenericMethod && return sm
    (func, sig_types) = sm

    # corner cases where we give up
    Any ∈ sig_types && return AnyParam(sig_types)
    any(t -> is_vararg(t), sig_types) && return VarargParam(sig_types)

    # loop over all instantiations of the signature
    fails = Vector{Any}([])
    steps = 0
    skipexists = Set{SkippedUnionAlls}([])
    for ts in Channel(ch -> all_subtypes(sig_types, scfg, ch))
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
        try
            if ! is_stable_call(func, ts)
                push!(fails, ts)
            end
        catch
            return TcFail(ts)
        end
        steps += 1
        if steps > scfg.fuel
            return OutOfFuel()
        end
    end

    return if isempty(fails)
        Stb(steps, skipexists)
    else
        Uns(fails)
    end
end


end # module
