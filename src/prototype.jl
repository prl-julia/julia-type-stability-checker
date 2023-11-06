module Prototype

using InteractiveUtils


const Mutable = Array{T, 0} where T

abstract type SubtypeNode end

# const Option = Union{Nothing, T} where T
# none() = fill(nothing)
# some(v::T) where T = fill(v)


const MAXDEPTH = 2
# const INITCAP = 2^15

# const NNODES = sizehint!(Dict{Type, Int}(), INITCAP)
# const NLEAVES = sizehint!(Dict{Type, Int}(), INITCAP)

const TYPECACHE = Dict{Type, SubtypeNode}()
const TYPEVARCACHE = Dict{TypeVar, SubtypeNode}()
const VARARGCACHE = Dict{Core.TypeofVararg, SubtypeNode}()


nmembers(t::Union) = begin
    n = 1
    
    while t isa Union
        n += 1
        t = t.b
    end

    n
end
member(t::Union, i::Int) = begin
    while t isa Union
        i == 1 && return t.a
        i -= 1
        t = t.b
    end
    i == 1 && return t
    @assert false "Union index out of bounds"
end

isconcrete(t) = isconcretetype(t) ||
    (isabstracttype(t) &&
        (isempty(subtypes(t)) ||
         (t !== Any && t in subtypes(t))))
isabstract(t) = isabstracttype(t) && !isconcrete(t)
istuple(t) = t <: Tuple
isnamedtuple(t) = t <: NamedTuple  # TODO: Maybe `t === NamedTuple`?


struct ConcreteNode <: SubtypeNode
    t::DataType
    ConcreteNode(t) = begin
        @debug "New ConcreteNode($t)"
        @assert !Base.has_free_typevars(t)
        new(t)
    end
end


struct AbstractNode <: SubtypeNode
    t::DataType
    subtypes::Vector{Union{Nothing, SubtypeNode}}
end

AbstractNode(t) = begin
    @debug "New AbstractNode($t)"
    @assert !Base.has_free_typevars(t)
    AbstractNode(t, repeat([nothing], length(subtypes(t))))
end


struct TupleNode <: SubtypeNode
    t::DataType
    parameters::Vector{Union{Nothing, SubtypeNode}}
end

TupleNode(t) = begin
    @debug "New TupleNode($t)"
    @assert !Base.has_free_typevars(t)
    TupleNode(t, [SubtypeNode(p) for p in t.parameters])
end


struct UnionNode <: SubtypeNode
    t::Union
    members::Vector{Union{Nothing, SubtypeNode}}
end

UnionNode(t) = begin
    @debug "New UnionNode($t)"
    @assert !Base.has_free_typevars(t)
    UnionNode(t, repeat([nothing], nmembers(t)))
end


struct UnionAllNode <: SubtypeNode
    t::UnionAll
    var::Mutable{Union{Nothing, SubtypeNode}}
end

UnionAllNode(t) = begin
    @debug "New UnionAllNode($t)"
    @assert !Base.has_free_typevars(t)
    UnionAllNode(t, fill(nothing))
end


struct TypeVarNode <: SubtypeNode
    t::TypeVar
    ub::Mutable{Union{Nothing, SubtypeNode}}
end

TypeVarNode(t) = begin
    @debug "New TypeVarNode($t)"
    TypeVarNode(t, fill(nothing))
end

Base.hash(n::TypeVarNode, h::UInt) = hash((n.var.ub, n.var.lb), h)

Base.:(==)(n1::TypeVarNode, n2::TypeVarNode) = hash(n1) == hash(n2)


struct VarargNode <: SubtypeNode
    t::Core.TypeofVararg
    VarargNode(t) = begin
        @debug "New VarargNode($t)"
        new(t)
    end
end


struct NamedTupleNode <: SubtypeNode
    t::UnionAll
    NamedTupleNode(t) = begin
        @debug "New NamedTupleNode($t)"
        new(t)
    end
end


SubtypeNode(t::DataType) = begin
    get!(TYPECACHE, t) do
        if isconcrete(t)
            ConcreteNode(t)
        elseif isabstract(t)
            AbstractNode(t)
        elseif istuple(t)
            TupleNode(t)
        else
            @assert false "Unreachable"
        end
    end
end

SubtypeNode(t::Union) = begin
    get!(TYPECACHE, t) do
        UnionNode(t)
    end
end

SubtypeNode(t::UnionAll) = begin
    get!(TYPECACHE, t) do
        if isnamedtuple(t)
            NamedTupleNode(t)
        else
            UnionAllNode(t)
        end
    end
end

SubtypeNode(t::TypeVar) = begin
    get!(TYPEVARCACHE, t) do
        TypeVarNode(t)
    end
end

SubtypeNode(t::Core.TypeofVararg) = begin
    get!(VARARGCACHE, t) do
        VarargNode(t)
    end
end

nnodes(n::SubtypeNode) = nnodes(n.t)
nleaves(n::SubtypeNode) = nleaves(n.t)

nnodes(t::DataType) = begin
    if isconcrete(t)
        1
    elseif isabstract(t)
        1 + sum([nnodes(s) for s in subtypes(t)])
    elseif istuple(t)
        1 + prod([nnodes(p) for p in t.parameters])
    else
        @assert false "Unreachable"
    end
end
nnodes(t::Union) = begin
    1 + sum([nnodes(member(t, i)) for i in 1:nmembers(t)])
end
nnodes(t::UnionAll) = begin
    1 + nnodes(t.var) # TODO: AAAAAGGGGHHH!!     * nnodes()
end
nnodes(t::TypeVar) = begin
    1
end
nnodes(t::Core.TypeofVararg) = begin
    1
end


sample(n::ConcreteNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))found concrete type $(n.t)"
    n.t
end

sample(n::AbstractNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling abstract type $(n.t)"
    i = rand(1:length(n.subtypes))
    if isnothing(n.subtypes[i])
        n.subtypes[i] = SubtypeNode(subtypes(n.t)[i])
    end

    sample(n.subtypes[i], only_concrete, max_depth, prefix + 2)
end

sample(n::TupleNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling $(n.t)"
    Tuple{[sample(x, only_concrete, max_depth, prefix + 2) for x in n.parameters]...}
end

sample(n::UnionNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling $(n.t)"
    i = rand(1:length(n.members))
    if isnothing(n.members[i])
        n.members[i] = SubtypeNode(member(n.t, i))
    end

    sample(n.members[i], only_concrete, max_depth, prefix + 2)
end

sample(n::UnionAllNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling unionall type $(n.t)"
    if isnothing(n.var[])
        n.var[] = SubtypeNode(n.t.var)
    end

    t = sample(n.var[], false, max_depth, prefix + 2)
    @debug "$max_depth) $(repeat(" ", prefix))typevar = $t"

    # See https://github.com/JuliaLang/julia/issues/52042
    inst = try
        n.t{t}
    catch e
        if e isa TypeError
            @warn "$max_depth) $(repeat(" ", prefix))type error: $e, returning bottom"
            return Union{}
        else
            throw(e)
        end
    end

    @debug "$max_depth) $(repeat(" ", prefix))instantiation = $inst"
    if max_depth < 1
        @debug "$max_depth) $(repeat(" ", prefix))out-of-depth, returning instantiation $inst"
        return inst
    end
    sample(SubtypeNode(inst), only_concrete, max_depth - 1, prefix + 2)
end

sample(n::TypeVarNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling typevar $(n.t)"
    if isnothing(n.ub[])
        n.ub[] = SubtypeNode(n.t.ub)
    end

    if max_depth < 1
        @debug "$max_depth) $(repeat(" ", prefix))out-of-depth, returning upper bound $(n.t.ub)"
        return n.t.ub
    end
    sample(n.ub[], only_concrete, n.ub[] isa UnionAllNode ? max_depth : max_depth - 1, prefix + 2)
end

sample(n::VarargNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling vararg $(n.t)"
    # TODO: n.t.T, n.t.N should be available for sampling
    n.t
end

sample(n::NamedTupleNode, only_concrete::Bool, max_depth::Int, prefix::Int) = begin
    @debug "$max_depth) $(repeat(" ", prefix))sampling namedtuple $(n.t)"
    # TODO: What should we do?
    NamedTuple()
end

sample(n::SubtypeNode) = sample(n, true, MAXDEPTH, 0)

####### TESTS #####################################################################


# abstract type A end
# struct A1 <: A end
# struct A2 <: A end

# abstract type B end
# abstract type B1 <: B end
# struct B11 <: B1 end
# struct B12 <: B1 end
# abstract type B2{T <: A} <: B end
# struct B21{T} <: B2{T} end
# struct B22{T} <: B2{T} end
# struct B3 <: B end
# struct B4 <: B end

# f1(::A, ::B) = nothing
# f2(::Any) = nothing
# const X = Tuple{T, Array{S}} where S <: AbstractArray{T} where T<:Integer
# f3(::X) = nothing


abstract type MyAny end

abstract type MyInt <: MyAny end
struct MyInt9 <: MyInt end
struct MyInt17 <: MyInt end
struct MyInt33 <: MyInt end

abstract type MyArray{T<:MyAny} <: MyAny end
struct MyHerm{T<:MyAny, S<:MyArray{<:T}} <: MyArray{T} end
struct MyHB{T<:MyInt} <: MyArray{T} end
struct MyHC <: MyArray{MyInt} end

abstract type MyRec <: MyAny end
struct MyRecRec{T<:MyRec} <: MyRec end
struct MyRecBottom <: MyRec end

# f(::MyInt) = 1
# f(::MyArray{<:MyInt9}) = 1
# f(::MyHerm) = 1
# f(::MyAny) = 1
# f(::Signed, ::Vararg{String}) = 1
# f(::Number, ::Number) = 1
# f(::Any) = 1
# f(::Type{Bool}) = 1
# f(::Vector{Number}) = 1
# f(::Vector{T} where T<:Number) = 1
# f(::Vector{T}) where T<:Number = 1
# f(::Vector{T}) where Integer <: T <: Real = 1

f() = 1

sample_subtypes(m::Method, samples::Int = 512) = begin
    Channel() do ch
        n = SubtypeNode(m.sig)
        # @info "Signature: $(m.sig)"

        seen = Set{Type}()
        for _ in 1:samples
            s = sample(n)
            # @info "  $s"
            @assert s <: m.sig "Generated $(s) that is *not* a subtype of $(m.sig)!"
            s in seen && continue
            push!(seen, s)
            put!(ch, s)
        end
        # @info "Found $(length(seen)) unique instantiations"

        # @info "Caches:" length(TYPECACHE) length(TYPEVARCACHE) length(VARARGCACHE)
        put!(ch, "done")
    end
end

# prototype(m::Method) = begin
#     for s in sample_subtypes(m)
#         @info "$s"
#     end
# end


#= IDEAS #####################################################################

- each node gives a vector of index ranges for each of its children

eachsubtype(f::Function, n::ConcreteNode) = begin
    f(n.t)
end

precompute the numbers of children / leaves for all types up to max depth to get uniform sampling w/o replacement

special-case subtypes(Function)

=#

end # module Prototype
