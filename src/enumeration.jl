
#
#      Enumaration of subtypes
#


# We are evil and we use a global var to measure fuel consumption.
# It'd be a pain to thread but one day...
# Currently it counts the number of calls to direct_subtypes1:
# it was very tricky to figure what to count...
# NOTE: it will reset on every call to is_stable_method
stepCount = 0

#
# all_subtypes: JlSignature, SearchCfg, Channel -> ()
#
# Enumerate "all" subtypes of the given tuple-type (first argument) by iterating
# applications of the auxiliary `direct_subtypes` function.
# Usually emplyed to produce concrete subtypes but when instantiating existentials
# may need to produce abstract types as well -- the search configuration (second parameter)
# controls which mode we are in.
#
# Input:
#   - "tuple" of types from a function signature (in the form of Vector, not Tuple);
#   - search configuration
#   - results channel to be consumed in asynchronous manner
#
# Output: ()
#
# Effects:
#   - subtypes of the input type (1st arg) are sent to the channel (3rd arg)
#
all_subtypes(ts::Vector, scfg :: SearchCfg, result :: Channel) = begin
    @debug "[ all_subtypes ] $ts"
    sigtypes = Set{Any}([ts]) # worklist
    steps = 0
    while !isempty(sigtypes)

        tv = pop!(sigtypes)
        @debug "[ all_subtypes ] loop: $tv"

        # Pass on markers for skipped unionalls
        if tv isa SkippedUnionAlls
            push!(result, tv)
            continue
        end

        # If all types in tv are concrete, push it to the caller
        isconc = all(is_concrete_type, tv)
        if isconc
            @debug "[ all_subtypes ] concrete"

            # Manage fuel w.r.t. reaching concrete types
            global stepCount
            stepCount += 1
            @debug "[ all_subtypes ]" stepCount scfg.fuel
            if stepCount > scfg.fuel
                put!(result, OutOfFuel())
                scfg.failfast &&
                    break
            else
                put!(result, tv)
            end
        # otherwise, get some subtypes, add to worklist, loop
        else
            @debug "[ all_subtypes ] abstract"

            !scfg.concrete_only && put!(result, tv)
            dss = direct_subtypes(tv, scfg)
            if dss === nothing
                put!(result, OutOfFuel())
                scfg.failfast &&
                    break
            end
            union!(sigtypes, dss)
        end

    end
    put!(result, "done")
end

is_unbounded_exist(t) = t.var.ub == Any
has_unboundeded_exist(tv :: JlSignature) = begin
    unionalls = filter(t -> t isa UnionAll, tv)
    unb = filter(is_unbounded_exist, unionalls)
    !isempty(unb)
end

# Shortcut: well-known underconstrained types that we want to avoid
#           for which we will return NoFuel eventually.
#           Varargs, Tuple, Function, etc.
blocklist = [Function]
has_vararg(t) = occursin("Vararg", "$t") || # crude but works
    t == Tuple # ~ Tuple{Vararg{Any}}
to_avoid(t) =
    has_vararg(t) ||
    any(b -> t <: b, blocklist)

#
# direct_subtypes: JlSignature, SearchCfg -> [Union{JlSignature, SkippedUnionAlls}]
#
# Auxilliary function: immediate subtypes of a tuple of types `ts1`
#
direct_subtypes(ts1::Vector, scfg :: SearchCfg) = begin
    @debug "direct_subtypes: $ts1"
    isempty(ts1) && return [[]]

    ts = copy(ts1)
    t = pop!(ts)

    to_avoid(t) &&
        (return nothing)

    ss_t = direct_subtypes1(t, scfg)
    ss_t === nothing && return nothing # we really need to bring in Monads.jl...
    @debug "direct_subtypes of head: $(ss_t)"
    res = []
    ss_ts = direct_subtypes(ts, scfg)
    ss_ts === nothing && return nothing
    for s_first in ss_t
        if s_first isa SkippedUnionAlls
            push!(res, s_first)
        else
            for s_rest in ss_ts
                if s_rest isa SkippedUnionAlls
                    push!(res, s_rest)
                else
                    push!(res, push!(Vector(s_rest), s_first))
                end

                # It is here where we decided to manage fuel w.r.t. traversing lattice.
                # Used to be in direct_subtypes1, but we can exponentially blow
                # in this quadratic loop even with linear amount of calls to
                # direct_subtype1...
                # There's another point, which has to do with reaching concrete types,
                # inside all_subtypes.
                global stepCount
                stepCount += 1
                @debug "direct_subtypes1" stepCount scfg.fuel
                stepCount > scfg.fuel && return nothing

            end
        end
    end
    res
end

# Single (Non-tuple) type input version of direct_subtypes
direct_subtypes1(t::Any, scfg :: SearchCfg) = begin
    @debug "direct_subtypes1: $t"

    ss = subtypes(t)

    res =
        # NOTE: the order of if-branches is important
        if t == Any         # if Any got here, we're asked to sample
            scfg.typesDBcfg.types_db
        elseif !isempty(ss) # we try to crawl nominal hierarchy all the way first
            ss
        elseif t isa UnionAll
            subtype_unionall(t, scfg)
        elseif t isa Union
            subtype_union(t)
        elseif is_concrete_type(t)
            [t]
        elseif t <: Tuple
            map(t -> Tuple{t...},
                direct_subtypes(Vector{Any}([t.parameters...]), scfg)
            )
        else
            []
            # @assert false "direct_subtypes1: can't subtype $t (should not happen)"
        end
    # @info "" res
    return res
end

#
# instantiations: UnionAll, SearchCfg -> Channel{JlType}
#
# All possible instantiations of the top variable of a UnionAll,
# except unionalls (and their instances) -- to avoid looping.
# NOTE: don't forget to unwrap the contents of the results (tup -> tup[1]);
#       the reason this is needed: we expect insantiations to be a JlType,
#       but `all_subtypes` works with JlSignatures
#
instantiations(u :: UnionAll, scfg :: SearchCfg) = begin
    @debug "[ instantiations ] of $u"
    scfg1 = @set scfg.concrete_only = scfg.abstract_args
    scfg1 = @set scfg1.skip_unionalls = true # don't recurse
            # ^ TODO: approximation needs documenting
    Channel(ch ->
                all_subtypes(
                    [u.var.ub],
                    scfg1,
                    ch))
end

#
# subtype_unionall: UnionAll, SearchCfg -> Union{[JlType], Nothing}
#
# For a UnionAll, enumerate all instatiations following `instantiations`.
# Return nothing if run out of fuel.
#
# Note: ignore lower bounds for simplicity.
#
# TODO: make result Channel-based
#
subtype_unionall(u :: UnionAll, scfg :: SearchCfg) = begin
    @debug "[ subtype_unionall ] of $u"

    u.var.ub == Any && !scfg.typesDBcfg.use_types_db &&
        return nothing

    res = []
    for t in instantiations(u, scfg)
        @debug "[ subtype_unionall ] loop over inst.: t = $t"
        if t isa OutOfFuel
            return nothing
        elseif t == "done"
            return res
        else
            try # u{t} can fail due to unsound bounds (cf. #8)
                push!(res, u{t[1]})
            catch
                # skip failed instatiations
            end
        end
    end
end

#
# subtype_union: Union -> [JlType]
#
# This flattens the nested union to an array of its types since the `subtypes` builtin
# function only returns declared subtypes. However, for a Union, we want to process
# each of the contained types as its subtypes.
#
subtype_union(t::Union) = begin
    @debug "subtype_union of $t"
    res = []
    while t isa Union
        push!(res, t.a)
        t = t.b
    end
    push!(res, t)
    res
end
