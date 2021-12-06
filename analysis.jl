#
# Exhaustive enumeration of types for static type stability checking
#

is_stable_function(f::Function) =
    all(is_stable_method, methods(f).ms)

is_stable_method(m::Method) = begin
    println("is_stable_method: $m")
    f = m.sig.parameters[1].instance
    ss = all_subtypes(Vector{Any}([m.sig.parameters[2:end]...]))
    for s in ss
        if ! is_stable_call(f, s)
            return false
        end
    end
    return true
end

is_stable_call(@nospecialize(f :: Function), @nospecialize(ts :: Vector)) = begin
    print("is_stable_call: $f | $ts\t| ")
    ct = code_typed(f, (ts...,), optimize=false)
    if length(ct) == 0
        throw(DomainError("$f, $s")) # type inference failed
    end
    (code, res_type) = ct[1] # we ought to have just one method body, I think
    res = isconcretetype(res_type)
    print("$res_type\t|")
    println(res)
    res
end

all_subtypes(ts::Vector) = begin
    println("all_subtypes: $ts")
    sigtypes = Set{Vector{Any}}([ts])
    concrete = []
    while !isempty(sigtypes)
        tv = pop!(sigtypes)
        println("all_subtypes loop: $tv")
        if all(isconcretetype, tv)
            push!(concrete, tv)
        else
            union!(sigtypes, direct_subtypes(tv))
        end
    end
    concrete
end

direct_subtypes(ts::Vector) = begin
    if isempty(ts)
        return []
    end
    ss_last = subtypes(pop!(ts))
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

#
# Examples of type-(un)stable functions
#

# stable
mysum(a::AbstractArray) = begin
    r = zero(eltype(a))
    for x in a
        r += x
    end
    r
end

# stable
add1(x :: Number) = x + one(x)

# surpricingly stable (coercion)
add1ss(x :: Number) = x + 1

# still stable! (constant folding)
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
is_stable_function(add1uns)
