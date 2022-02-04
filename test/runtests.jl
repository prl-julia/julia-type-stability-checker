using Test
using InteractiveUtils
using StabilityCheck

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

plus2i(x :: Integer, y :: Integer) = x + y
plus2n(x :: Number, y :: Number) = x + y

sum_top(v, t) = begin
    res = 0 # zero(eltype(v))
    for x in v
        res += x < t ? x : t
    end
    res
end

rational_plusi(a::Rational{T}, b::Rational{T}) where T <: Integer = a + b

# test call:
#is_stable_function(add1i)

#
# Tests
#

@testset "Simple stable" begin
    @test is_stable_method(@which add1i(1))    == Stb()
    @test is_stable_method(@which add1iss(1))  == Stb()
    @test is_stable_method(@which plus2i(1,1)) == Stb()

    @test is_stable_method(@which rational_plusi(1//1,1//1)) == Stb()
end

@testset "Simple unstable" begin
    @test isa(is_stable_method(@which add1uns(1)),    Uns)
    @test isa(is_stable_method(@which add1n(1)),      Uns)
    @test isa(is_stable_method(@which plus2n(1,1)),   Uns)

    # this fails when abstract instantiations are ON (compare to the similar test in the "stable" examples)
    @test isa(is_stable_method((@which rational_plusi(1//1,1//1)), SearchCfg(abstract_args=true)), Stb)
end
