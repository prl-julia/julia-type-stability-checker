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

struct OpaqueDiscovery
    x::Union{Function, Tuple{Module, Symbol, Type}}
end




abstract type Discovery end
abstract type FunctionDiscovery end
abstract type TypeDiscovery end

struct DiscoveredMacro <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredLambda <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredConstructor <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredCallable <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredBuiltin <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredIntrinsic <: FunctionDiscovery
    f::Function
    m::Method
end
struct DiscoveredGeneric <: FunctionDiscovery
    f::Function
    m::Method
end

struct DiscoveredAlias <: TypeDiscovery
    m::Module
    s::Symbol
    t::Type
end
struct DiscoveredClosure <: TypeDiscovery
    m::Module
    s::Symbol
    t::Type
end
struct DiscoveredFunctionType <: TypeDiscovery
    m::Module
    s::Symbol
    t::Type
end
struct DiscoveredType <: TypeDiscovery
    m::Module
    s::Symbol
    t::Type
end


discover(report::Function, modules::Vector{Module}) = begin
    visited = Set{Module}()
    discovered = Set{OpaqueDiscovery}()

    makefuncdiscovery(f::Function, m::Method) = begin
        f isa Core.Builtin && return DiscoveredBuiltin(f, m)
        f isa Core.IntrinsicFunction && return DiscoveredIntrinsic(f, m)
        mt = typeof(f).name.mt
        name = mt.name
        hasname = isdefined(mt.module, name) && typeof(getfield(mt.module, name)) <: Function
        sname = string(name)
        if hasname
            if startswith(sname, '@')
                return DiscoveredMacro(f, m)
            else
                return DiscoveredGeneric(f, m)
            end
        elseif '#' in sname
            return DiscoveredLambda(f, m)
        elseif mt === Base._TYPE_NAME.mt
            return DiscoveredConstructor(f, m)
        else
            return DiscoveredCallable(f, m)
        end
    end
    maketypediscovery(m::Module, s::Symbol, t::Type) = begin
        base = Base.unwrap_unionall(t)
        if t <: Function
            if occursin("var\"#", string(base))
                return DiscoveredClosure(m, s, t)
            else
                return DiscoveredFunctionType(m, s, t)
            end
        elseif base isa Union || t !== base.name.wrapper || string(s) != string(nameof(t))
            return DiscoveredAlias(m, s, t)
        else
            return DiscoveredType(m, s, t)
        end
    end

    discoveraux(mod::Module, root::Module) = begin
        mod ∈ visited && return
        push!(visited, mod)
    
        for sym in names(mod; all=true, imported=true)
            try
                val = getproperty(mod, sym)
    
                if val isa Module && is_module_nested(val, root)
                    discoveraux(val, root)
                    continue
                end
    
                if val isa Function && sym ∉ [:include, :eval]
                    d = OpaqueDiscovery(val)
                    d ∈ discovered && continue
                    push!(discovered, d)
                    for m in methods(val)
                        any(mod -> is_module_nested(m.module, mod), modules) && report(makefuncdiscovery(val, m))
                    end
                end

                if val isa Type && !(val isa Core.TypeofBottom)
                    d = OpaqueDiscovery((mod, sym, val))
                    d ∈ discovered && continue
                    push!(discovered, d)
                    report(maketypediscovery(mod, sym, val))
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

    for m in modules
        discoveraux(m, m)
    end

end

module TestMod

    # import SentinelArrays
    # const SVec{T} = SentinelArrays.SentinelVector{T, T, Missing, Vector{T}}

    # gener(captured) = [captured + i for i in 1:2]

    # f(abc) = x -> abc + x

    # const lambda = (x::Int32) -> x + 1

    # const MyVector{T} = Array{T,1}
    # const MyVector2 = Vector
    # const MyVector3 = Vector{T} where T
    # const MyVectorInt = Vector{Int}
    # struct CrazyArray{A, B, C, D, E} end
    # const MyCrazyArray{T, U} = CrazyArray{T, U, Int, Bool, 3}

    # const my8by16 = NTuple{16, VecElement{UInt8}}
    # const my8by3 = NTuple{3, VecElement{UInt8}}

    # struct X{T}
    #     x::T
    # end
    # function (x::X)(a) # X.body.name.mt has callable objects (one mt for all of them??)
    #     return x.x + a
    # end

    struct K
        k::Int
    end
    K(a, b, c) = K(a + b + c)

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
        # const MyVector2 = Vector

        # struct Substruct
        #     x::Int
        # end

        # subfunction(x::Int, y::Bool)::String = "$x, $y"
        # import ..testfunc
        # testfunc(::Bool) = 1

    # end

end

baseShowMethodCustom(io::IO, m::Method, kind::String) = begin
    tv, decls, file, line = Base.arg_decl_parts(m)
    sig = Base.unwrap_unionall(m.sig)
    if sig === Tuple
        # Builtin
        print(io, m.name, "(...)  [", kind, " @ ", m.module, "]")
        return
    end
    print(io, decls[1][2], "(")
    join(
        io,
        String[isempty(d[2]) ? d[1] : string(d[1], "::", d[2]) for d in decls[2:end]],
        ", ",
        ", ",
    )
    kwargs = Base.kwarg_decl(m)
    if !isempty(kwargs)
        print(io, "; ")
        join(io, map(Base.sym_to_string, kwargs), ", ", ", ")
    end
    print(io, ")")
    Base.show_method_params(io, tv)

    print(io, "  [", kind, " @ ", m.module)
    if line > 0
        file, line = Base.updated_methodloc(m)
        print(io, " ", file, ":", line)
    end
    print(io, "]")
end

baseShowTypeCustom(io::IO, @nospecialize(x::Type)) = begin
    if !Base.print_without_params(x)
        properx = Base.makeproper(io, x)
        if Base.make_typealias(properx) !== nothing || (Base.unwrap_unionall(x) isa Union && x <: Base.make_typealiases(properx)[2])
            # show(IOContext(io, :compact => true), x)
            if !(get(io, :compact, false)::Bool)
                Base.printstyled(IOContext(io, :compact => false), x)
            end
            return
        end
    end
    show(io, x)
end

Base.show(io::IO, d::DiscoveredMacro) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "macro")
end

Base.show(io::IO, d::DiscoveredLambda) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "lambda")
end

Base.show(io::IO, d::DiscoveredConstructor) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "constructor")
end

Base.show(io::IO, d::DiscoveredCallable) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "callable")
end

Base.show(io::IO, d::DiscoveredBuiltin) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "builtin")
end

Base.show(io::IO, d::DiscoveredIntrinsic) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "intrinsic")
end

Base.show(io::IO, d::DiscoveredGeneric) = begin
    print(io, "function ")
    baseShowMethodCustom(io, d.m, "generic")
end

Base.show(io::IO, d::DiscoveredAlias) = begin
    print(io, "const $(d.m).$(d.s) = ")
    baseShowTypeCustom(io, d.t)
end

Base.show(io::IO, d::DiscoveredClosure) = begin
    show(io, DiscoveredType(d.m, d.s, d.t))
end

Base.show(io::IO, d::DiscoveredFunctionType) = begin
    show(io, d.t)
end

Base.show(io::IO, d::DiscoveredType) = begin
    print(io,
        if isabstracttype(d.t)
            "abstract type"
        elseif isstructtype(d.t)
            ismutabletype(d.t) ? "mutable struct" : "struct"
        elseif isprimitivetype(d.t)
            "primitive type"
        else
            "???"
        end)
    print(io, " ", Base.unwrap_unionall(d.t))
    if supertype(d.t) !== Any
        print(io, " <: ")
        b = Base.unwrap_unionall(supertype(d.t))
        Base.show_type_name(io, b.name)
        isempty(b.parameters) || print(io, "{")
        print(io, join(map(p -> p isa TypeVar ? p.name : p, b.parameters), ", "))
        isempty(b.parameters) || print(io, "}")
    end
    if isprimitivetype(d.t)
        print(io, " ", 8 * sizeof(d.t))
    end
    print(io, " end")
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

# builtins(mod) = filter(n -> getproperty(mod, n) isa Core.Builtin, names(mod; all=true, imported=true))
# intrinsics(mod) = filter(n -> getproperty(mod, n) isa Core.IntrinsicFunction, names(mod; all=true, imported=true))

discoverDeclarationsAndSignatures(mods::AbstractVector{Module}=Base.loaded_modules_array();
        funcfile=nothing,
        typefile=nothing,
        skip_macros=true,
        skip_lambdas=true,
        skip_constructors=false,
        skip_callable=false,
        skip_builtins=true,
        skip_intrinsics=true,
        skip_generics=false,
        skip_aliases=true,
        skip_closures=true,
        skip_functiontypes=true,
        skip_types=false) = begin

    funio = isnothing(funcfile) ? Base.stdout : open(funcfile, "w")
    typio = isnothing(typefile) ? Base.stdout : open(typefile, "w")

    shouldShow(::DiscoveredMacro) = !skip_macros
    shouldShow(::DiscoveredLambda) = !skip_lambdas
    shouldShow(::DiscoveredConstructor) = !skip_constructors
    shouldShow(::DiscoveredCallable) = !skip_callable
    shouldShow(::DiscoveredBuiltin) = !skip_builtins
    shouldShow(::DiscoveredIntrinsic) = !skip_intrinsics
    shouldShow(::DiscoveredGeneric) = !skip_generics
    shouldShow(::DiscoveredAlias) = !skip_aliases
    shouldShow(::DiscoveredClosure) = !skip_closures
    shouldShow(::DiscoveredFunctionType) = !skip_functiontypes
    shouldShow(::DiscoveredType) = !skip_types

    try
        discover(mods) do x
            shouldShow(x) || return
            io = x isa FunctionDiscovery ? funio : typio
            println(io, x)
        end
    finally
        funio === Base.stdout || close(funio)
        typio === Base.stdout || close(typio)
    end
end

end # module
