#
# Exhaustive enumeration of types for static type stability checking
#

is_stable_function(f::Function) =
    all(is_stable_method, methods(f).ms)

is_stable_method(m::Method) = begin
    @debug "is_stable_method: $m"
    f = m.sig.parameters[1].instance
    ss = all_concrete_subtypes(Vector{Any}([m.sig.parameters[2:end]...]))

    for s in ss
        if ! is_stable_call(f, s)
            return false
        end
    end
    return true
end

is_stable_call(@nospecialize(f :: Function), @nospecialize(ts :: Vector)) = begin
    ct = code_typed(f, (ts...,), optimize=false)
    if length(ct) == 0
        throw(DomainError("$f, $s")) # type inference failed
    end
    (code, res_type) = ct[1] # we ought to have just one method body, I think
    res = is_concrete_type(res_type)
    print(lpad("is stable call " * string(f), 20) * " | " * rpad(string(ts), 35) * " | " * rpad(res_type, 30) * " |")
    println(res)
    res
end

# Used to instantiate functions for concrete argument types.
# Input: "tuple" of types from the function signature (in the form of Vector, not Tuple).
# Output: vector of "tuples" that subtype input
all_concrete_subtypes(ts::Vector) = begin
    @debug "all_concrete_subtypes: $ts"
    sigtypes = Set{Vector{Any}}([ts])
    concrete = []
    while !isempty(sigtypes)
        tv = pop!(sigtypes)
        @debug "all_concrete_subtypes loop: $tv"
        if all(is_concrete_type, tv)
            push!(concrete, tv)
        else
            dss = direct_subtypes(tv)
            union!(sigtypes, dss)
        end
    end
    concrete
end

# Auxilliary function: immediate subtypes of a tuple of types `ts`
direct_subtypes(ts::Vector) = begin
    if isempty(ts)
        return []
    end
    t = pop!(ts)
    ss_last = subtypes(t)
    if isempty(ss_last)
        if typeof(t) == UnionAll
            ss_last = subtype_unionall(t)
        end
    end
    if isempty(ts)
        return map(s -> Vector{Any}([s]), ss_last)
    end

    res = []
    ss_rest = direct_subtypes(ts)
    for t_last in ss_last
        for t_rest in ss_rest
            push!(res, push!(Vector(t_rest), t_last))
        end
    end
    res
end

# If type variable has non-Any upper bound, enumerate
# all concrete (TODO: should be all?) possibilities,
# otherwise take Any and Int.
# Note: ignore lower bounds for simplicity.
subtype_unionall(u :: UnionAll) = begin
    @debug "subtype_unionall of $u"
    ub = u.var.ub
    sample_types = if ub == Any
        [Int64, Any]
    else
        map(tup -> tup[1], all_concrete_subtypes([ub]))
    end
    [u{t} for t in sample_types]
end

# Follows definition used in @code_warntype (cf. `warntype_type_printer` in:
# julia/stdlib/InteractiveUtils/src/codeview.jl)
is_concrete_type(@nospecialize(ty)) = begin
    if ty isa Type && (!Base.isdispatchelem(ty) || ty == Core.Box)
        if ty isa Union && Base.is_expected_union(ty)
            true # this is a "mild" problem, so we round up to "stable"
        else
            false
        end
    else
        true
    end
    # Note 1: Core.Box is a type of a heap-allocated value
    # Note 2: isdispatchelem is roughly eqviv. to
    #         isleaftype (from Julia pre-1.0)
    # Note 3: expected union is a trivial union (e.g.
    #         Union{Int,Missing}; those are deemed "probably
    #         harmless"
end

#
# Examples of type-(un)stable functions
#

abstract type MyAbsVec{T} end

struct MyVec{T <: Signed} <: MyAbsVec{T}
    data :: Vector{T}
end

# Ex. (mysum1) stable, hard: abstract parametric type
mysum1(a::AbstractArray) = begin
    r = zero(eltype(a))
    for x in a
        r += x
    end
    r
end

# Ex. (mysum2) stable, hard: cf. (mysum1) but use our types
# for simpler use case
mysum2(a::MyAbsVec) = begin
    r = zero(eltype(a))
    for x in a
        r += x
    end
    r
end

# Ex. (add1)
# |
# --- a) using `one` -- stable
add1(x :: Number) = x + one(x)
# |
# --- b) using `1` -- surpricingly stable (coercion)
add1ss(x :: Number) = x + 1
# |
# --- c) with type inspection -- still stable! (constant folding)
add1uns(x :: Number) =
    if typeof(x) <: Integer
        x + 1
    elseif typeof(x) <: Real
        x + 1.0
    else
        x + one(x)
    end

trivial_unstable(x::Int) = x > 0 ? 0 : "0"

plus(x :: Number, y :: Number) = x + y

sum_top(v, t) = begin
    res = 0 # zero(eltype(v))
    for x in v
        res += x < t ? x : t
    end
    res
end

# test call:
#is_stable_function(add1uns)
