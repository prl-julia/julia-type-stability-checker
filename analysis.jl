#
# Exhaustive enumeration of types for static type stability checking
#

# Debug print:
# ENV["JULIA_DEBUG"] = Main    # turn on
# ENV["JULIA_DEBUG"] = Nothing # turn off

abstract type StCheck end
struct Stb <: StCheck end
struct Uns <: StCheck
    fails :: Vector{Vector{Any}}
end

is_stable_function(f::Function) = begin
    tests = map(m -> (m, is_stable_method(m)), methods(f).ms)
    fails = filter(metAndCheck -> isa(metAndCheck[2], Uns), tests)
    if isempty(fails)
        return true
    else
        println("Some methods failed stability test")
        print_fails(fails)
        return false
    end
end

print_fails(fs :: Vector{Tuple{Method,Uns}}) = begin
    for (m,uns) in fs
        print("The following method:\n\t")
        println(m)
        println("is not stable for the following types of inputs")
        for ts in uns.fails
            println("\t"* string(ts))
        end
    end
end


is_stable_method(m::Method) = begin
    @debug "is_stable_method: $m"
    f = m.sig.parameters[1].instance
    ss = all_subtypes(Vector{Any}([m.sig.parameters[2:end]...]))

    fails = Vector{Any}([])
    res = true
    for s in ss
        if ! is_stable_call(f, s)
            push!(fails, s)
            res = false
        end
    end

    return if res
        Stb()
    else
        Uns(fails)
    end
end

is_stable_call(@nospecialize(f :: Function), @nospecialize(ts :: Vector)) = begin
    ct = code_typed(f, (ts...,), optimize=false)
    if length(ct) == 0
        throw(DomainError("$f, $s")) # type inference failed
    end
    (code, res_type) = ct[1] # we ought to have just one method body, I think
    res = is_concrete_type(res_type)
    #print_stable_check(f,ts,res_type,res)
    res
end

print_stable_check(f,ts,res_type,res) = begin
    print(lpad("is stable call " * string(f), 20) * " | " * rpad(string(ts), 35) * " | " * rpad(res_type, 30) * " |")
    println(res)
end

# Used to instantiate functions for concrete argument types.
# Input: "tuple" of types from the function signature (in the form of Vector, not Tuple).
# Output: vector of "tuples" that subtype input
all_subtypes(ts::Vector; concrete_only=true, skip_unionalls=false) = begin
    @debug "all_subtypes: $ts"
    sigtypes = Set{Vector{Any}}([ts]) # worklist
    result = []
    while !isempty(sigtypes)
        tv = pop!(sigtypes)
        @debug "all_subtypes loop: $tv"
        isconc = all(is_concrete_type, tv)
        if isconc
            push!(result, tv)
        else
            !concrete_only && push!(result, tv)
            dss = direct_subtypes(tv, skip_unionalls)
            union!(sigtypes, dss)
        end
    end
    result
end

# Auxilliary function: immediate subtypes of a tuple of types `ts`
direct_subtypes(ts1::Vector, skip_unionalls::Bool) = begin
    if isempty(ts1)
        return []
    end
    ts = copy(ts1)
    t = pop!(ts)
    ss_last = subtypes(t)
    if isempty(ss_last)
        if typeof(t) == UnionAll
            ss_last = subtype_unionall(t)
        end
    end
    if isempty(ts)
        return (Vector{Any}([s])
                    for s=ss_last
                    if !(skip_unionalls && typeof(s) == UnionAll))
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
# all possibilities for it except unionalls (and their instances) -- to avoid looping, --
# otherwise take Any and Int (TODO is it a good choice? it's very arbitrary).
# Note: ignore lower bounds for simplicity.
subtype_unionall(u :: UnionAll) = begin
    @debug "subtype_unionall of $u"
    ub = u.var.ub
    sample_types = if ub == Any
        [Int64, Any]
    else
        ss = all_subtypes([ub]; concrete_only=false, skip_unionalls=true)
        @debug "var instantiations: $ss"
        map(tup -> tup[1], ss)
        # (tup[1] for tup=all_subtypes([ub]; concrete_only=false, skip_unionalls=true))
    end
    if isempty(sample_types)
        []
    else
        [u{t} for t in sample_types]
    end
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
# --- a) using `one` -- should be stable but alas, the Rational{Bool} instance screws it
add1i(x :: Integer) = x + one(x)
# |
# --- b) using `1` -- surpricingly stable (coercion)
add1iss(x :: Integer) = x + 1
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
# |
# -- d) Number-input: lots of subtypes. Would be stable if skip Rational{Bool} and
#       abstract arguments to parametric types (e.g. Complex{Integer}).
#       Currently unstable.
add1n(x :: Number) = x + one(x)

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
# TODO: fails on `plus` (likely, due to >1 args)
