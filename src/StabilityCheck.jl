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
    SkippedUnionAlls, UnboundedUnionAlls, SkipMandatory,
    Stb, Uns,
    UConstr, UConstrExist, AnyParam, VarargParam, TcFail, OutOfFuel, GenericMethod,
    SearchCfg, build_typesdb_scfg, default_scfg,

    # Utils
    split_method # mostly for testing

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
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg) :: StCheckResults =
    is_stable_module_aux(mod, mod, Set{Module}(), scfg)

# bool-returning version of the above
is_stable_moduleb(mod::Module, scfg :: SearchCfg = default_scfg) :: Bool =
    convert(Bool, is_stable_module(mod, scfg))

# Auxiliary recursive implementation of `is_stable_module`. It gets two extra arguments:
# - root is the toplevel module that we process; we only recurse into modules that are enclosed in root
# - seen is a cache of modules we already processed; this prevents processing modules multiple times
is_stable_module_aux(mod::Module, root::Module, seen::Set{Module}, scfg::SearchCfg) :: StCheckResults = begin
    @debug "is_stable_module($mod)"
    push!(seen, mod)
    res = []
    ns = names(mod; all=!scfg.exported_names_only, imported=true)
    @debug "number of members in $mod: $(length(ns))"
    for sym in ns
        @debug "is_stable_module($mod): check symbol $sym"
        try
            evsym = getproperty(mod, sym)

            # recurse into submodules
            if evsym isa Module && !(evsym in seen) && is_module_nested(evsym, root)
                @debug "is_stable_module($mod): found module $sym"
                append!(res, is_stable_module_aux(evsym, root, seen, scfg))
                continue
            end

            # not interested in non-functional symbols
            isa(evsym, Function) || continue

            # not interested in special functions
            special_syms = [ :include, :eval ]
            (sym in special_syms) && continue

            append!(res,
                    map(m -> MethStCheck(m, is_stable_method(m, scfg)),
                        our_methods_of_function(evsym, mod)))
        catch e
            if e isa UndefVarError
                @warn "Module $mod contains symbol $sym but we can't evaluate it"
                showerror(stdout, e)
                # not our problem, so proceed as usual
            elseif e isa CantSplitMethod
                @warn "Can't process method with no canonical instance:\n"
                # cf. comment in `split_method`
            else
                throw(e)
            end
        end
    end
    return res
end

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
    global stepCount = 0

    # preemptively load types DB if available: we may need to sample
    # unbounded exists any minute
    if scfg.typesDBcfg.use_types_db
        scfg.typesDBcfg.types_db === Nothing &&
            (scfg.typesDBcfg.types_db = typesDB())
        @debug "is_stable_method: types DB up"
    end

    # Step 2: Extract the input type
    # Slpit method into signature and the corresponding function object
    @debug "is_stable_method: split method"
    sm = split_method(m)
    sm isa GenericMethod && return sm
    (func, sig_types) = sm

    # Step 2a: run type inference with the input type even if abstract
    #          and party if we're concrete
    @debug "is_stable_method: check against signature (2a)"
    try
        if is_stable_call(func, sig_types)
            return Stb(1)
        end
    catch e
        return TcFail(sig_types, e)
    end

    # Shortcut:
    # Well-known underconstrained types that we give up on right away
    # are Any and Varargs and an unbounded existential
    @debug "is_stable_method: any, vararg checks"
    Any ∈ sig_types && ! scfg.typesDBcfg.use_types_db &&
        return AnyParam()
    any(t -> has_vararg(t), sig_types) &&
        return VarargParam()
    # TODO:

    # Loop over concrete subtypes of the signature
    unst = Vector{Any}([])
    skipexists = Set{SkippedUnionAlls}([])
    result = Nothing
    @debug "[ is_stable_method ] about to loop"
    for ts in Channel(ch -> all_subtypes(sig_types, scfg, ch))
        @debug "[ is_stable_method ] loop" stepCount "$ts"

        # case over special cases
        if ts == "done"
            break
        end
        if ts isa OutOfFuel
            result = OutOfFuel()
            break
        end
        if ts isa SkippedUnionAlls
            push!(skipexists, ts)
            if scfg.failfast
                break
            else
                continue
            end
        end

        # the actual stability check
        try
            if ! is_stable_call(func, ts)
                push!(unst, ts)
                if scfg.failfast
                    break
                end
            end
        catch e
            return TcFail(ts, e)
        end
    end

    result isa OutOfFuel &&
        return result
    return if isempty(unst)
        if isempty(skipexists) # TODO: kill skipexist, we don't use it
            Stb(stepCount)
        else
            UConstrExist(stepCount, skipexists)
        end
    else
        Uns(stepCount, unst)
    end
end



# --------------------------------------------------------------------------------------------------------------------------------




struct OpaqueFunction
    f::Function
end
struct OpaqueMethod
    f::Function
    m::Method
end
struct OpaqueType
    s::Symbol
    t::Type
    m::Module
end

discover(mod::Module, root::Module, seen::Set{Module}, functions::Set{OpaqueFunction}, types::Set{OpaqueType}) = begin
    mod ∈ seen && return
    push!(seen, mod)

    for sym in names(mod; all=true, imported=true)
        try
            evsym = getproperty(mod, sym)

            if evsym isa Module && is_module_nested(evsym, root)
                discover(evsym, root, seen, functions, types)
                continue
            end

            if evsym isa Function && sym ∉ [:include, :eval] #  && !(val isa Core.Builtin) && !(val isa Core.IntrinsicFunction)
                push!(functions, OpaqueFunction(evsym))
                continue
            end

            if (evsym isa DataType && !(evsym <: Function)) || evsym isa UnionAll
                push!(types, OpaqueType(sym, evsym, mod))
                continue
            end

        catch e
            if e isa UndefVarError
                GlobalRef(mod, sym) ∉ [GlobalRef(Base, :active_repl), GlobalRef(Base, :active_repl_backend),
                                       GlobalRef(Base.Filesystem, :JL_O_TEMPORARY), GlobalRef(Base.Filesystem, :JL_O_SHORT_LIVED),
                                       GlobalRef(Base.Filesystem, :JL_O_SEQUENTIAL), GlobalRef(Base.Filesystem, :JL_O_RANDOM)] &&
                    @warn "Module $mod exports symbol $sym but it's undefined."
            else
                throw(e)
            end
        end
    end
end

declarationsAndSignatures(report::Function, modules::Vector{Module}) = begin
    functions = Set{OpaqueFunction}()
    types = Set{OpaqueType}()
    visited = Set{Module}()

    for m in modules
        discover(m, m, visited, functions, types)
    end

    for f in functions
        for m in methods(f.f)
            any(mod -> is_module_nested(m.module, mod), modules) && report(OpaqueMethod(f.f, m))
        end
    end

    for t in types
        report(t)
    end
end

module TestMod

    import SentinelArrays
    const SVec{T} = SentinelArrays.SentinelVector{T, T, Missing, Vector{T}}

    # gener(captured) = [captured + i for i in 1:2]

    # f(abc) = x -> abc + x

    # const lambda = (x::Int32) -> x + 1
        
    # const MyVector{T} = Array{T,1}
    # const MyVectorInt = Vector{Int}
    # struct CrazyArray{A, B, C, D, E} end
    # const MyCrazyArray{T, U} = CrazyArray{T, U, Int, Bool, 3}

    # const my8by16 = NTuple{16, VecElement{UInt8}}
    # const my8by3 = NTuple{3, VecElement{UInt8}}

    # struct X{T}
    #     x::T
    # end

    # function (x::X)(a)
    #     return x.x + a
    # end

    # abstract type TestAbstract end

    # struct TestStruct <: TestAbstract end

    # kwargs(x::Int; kw1::String = "hi", kw2::Bool) = 1

    # vargs(x::String, y::Int...) = 1

    # defaultargs(x::Int, def1::String = "hey", def2::Bool = false) = 1

    # testfunc(x, y::String) = 1

    # import Base.Int8

    # primitive type TestPrimitive 40 end

    # abstract type Abs{T} end
    # struct Conc{T, U <: Array{<:T}} <: Abs{T} end

    # foo(::Vector{T}, ::T) where T <: Number = 1

    # module Submod

    #     struct Substruct
    #         x::Int
    #     end

    #     subfunction(x::Int, y::Bool)::String = "$x, $y"
    #     import ..testfunc
    #     testfunc(::Bool) = 1

    # end

end

report(io, o::OpaqueMethod) = begin
    f, m = o.f, o.m

    mt = typeof(f).name.mt
    name = mt.name
    hasname = isdefined(mt.module, name) &&
              typeof(getfield(mt.module, name)) <: Function
    sname = string(name)
    kind = if hasname
        (startswith(sname, '@') ?
            "macro \"$sname\""
        : mt.module === Core && m.sig === Tuple ?
            "builtin function \"$sname\""
        : # else
            "generic function \"$sname\"")
    elseif '#' in sname
        "anonymous function \"$sname\""
    elseif mt === Base._TYPE_NAME.mt
        "type constructor"
    else
        "callable object"
    end
    println(io, "$m (method for $kind)")
end


#=

- function aliases??
- NTuple for n<=3 is unrolled
- aliases - some use const and some don't

const AdjOrTrans{T,S} = Union{Adjoint{T,S},Transpose{T,S}} where {T,S}
const AdjointAbsVec{T} = Adjoint{T,<:AbstractVector}

abstract type _ConfiguredMenu{C} <: AbstractMenu end
const ConfiguredMenu = _ConfiguredMenu{<:AbstractConfig}

const NestedTuple = Tuple{<:Broadcasted,Vararg{Any}}

const ZlibDecompressorStream{S} = TranscodingStream{ZlibDecompressor,S} where S<:IO

const SizedVector{S,T} = SizedArray{Tuple{S},T,1,1}

const SVec{T} = SentinelVector{T, T, Missing, Vector{T}}

const HermOrSym{T,        S} = Union{Hermitian{T,S}, Symmetric{T,S}}
const RealHermSym{T<:Real,S} = Union{Hermitian{T,S}, Symmetric{T,S}}
const RealHermSymComplexHerm{T<:Real,S} = Union{Hermitian{T,S}, Symmetric{T,S}, Hermitian{Complex{T},S}}
const RealHermSymComplexSym{T<:Real,S} = Union{Hermitian{T,S}, Symmetric{T,S}, Symmetric{Complex{T},S}}

const RealHermSymComplexHerm{T<:Real,S} = Union{Hermitian{T,S}, Symmetric{T,S}, Hermitian{Complex{T},S}}
ERROR: Union{Hermitian{T, S}, Hermitian{Complex{T}, S}, Symmetric{T, S}} where {T<:Real, S}

const AbstractStatMap{var"#s6599"<:RAICode.QueryOptimizer.Statistics.AbstractStat} = Dict{UInt64, var"#s6599"<:RAICode.QueryOptimizer.Statistics.AbstractStat} (from module RAICode.QueryOptimizer.Statistics)
const Abstract

=#

report(io, o::OpaqueType) = begin
    @assert (o.t isa DataType) || (o.t isa UnionAll)

    typevars(t) = begin
        res = TypeVar[]
        while t isa UnionAll
            push!(res, t.var)
            t = t.body
        end
        res
    end

    sym, typ, mod = o.s, o.t, o.m
    base = Base.unwrap_unionall(typ)

    if base isa Union || typ !== base.name.wrapper || string(sym) != string(nameof(typ))
        vars = typevars(typ)
        name = "$(mod).$(sym)"
        println(io, "const $(name)$(isempty(vars) ? "" : "{$(join(vars, ", "))}") = $(base) (from module $(mod))")
    else
        try
            kind = if isabstracttype(typ)
                "abstract type"
            elseif isstructtype(typ)
                ismutabletype(typ) ? "mutable struct" : "struct"
            elseif isprimitivetype(typ)
                "primitive type"
            else
                "???"
            end
            name = "$(base)"
            super = supertype(typ) === Any ? "" : " <: $(Base.unwrap_unionall(supertype(typ)))"
            size = isprimitivetype(typ) ? " $(8 * sizeof(typ))" : ""
            closure = (typ <: Function && '#' in name) ? "(closure) " : ""

            println(io, "$(closure)$(kind) $(name)$(super)$(size) end (from module $(mod))")
        catch e
            println(io, "ERROR: $o")
        end
    end
end

dumpDeclarationsAndSignatures(console::Bool, testing::Bool) = begin
    mods = testing ? [TestMod] : Base.loaded_modules_array()
    funio = console ? Base.stdout : open("functions.jlg", "w")
    typio = console ? Base.stdout : open("types.jlg", "w")
    try
        declarationsAndSignatures(mods) do x
            x isa OpaqueMethod && report(funio, x)
            x isa OpaqueType && report(typio, x)
        end
    finally
        console || close(funio)
        console || close(typio)
    end
end

end # module
