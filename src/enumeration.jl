
#
#      Enumaration of subtypes
#


#
# all_subtypes: JlSignature, SearchCfg, Channel -> ()
#
# Enumerate "all" subtypes of the given tuple-type (first argument).
# It's usually employed to instantiate method signature with concrete argument types.
# But during recursive calls to instantiate type variables may also be required
# to produce abstract types too. This is controlled by the search configuration
# (second parameter).
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
            put!(result, tv)
        # otherwise, get some subtypes, add to worklist, loop
        else
            @debug "[ all_subtypes ] abstract"

            # Special cases for unionalls.
            # Skip and push a marker describing the case to the caller.
            #
            #   - skip unionalls due to search config
            unionalls = filter(t -> typeof(t) == UnionAll, tv)
            if scfg.skip_unionalls && !isempty(unionalls)
                put!(result, SkipMandatory(Tuple(unionalls)))
                continue
            end
            #   - unbounded unionall -- bail out
            unb = filter(u -> u.var.ub == Any, unionalls)
            if !isempty(unb)
                put!(result, UnboundedUnionAlls(Tuple(unb)))
                continue
            end

            # Normal case
            !scfg.concrete_only && put!(result, tv)
            dss = generate_subtypes(tv, scfg)
            union!(sigtypes, dss)
        end

        # check "fuel" (subtype lattice allowed depth)
        steps += 1
        if steps == scfg.max_lattice_steps
            put!(result, OutOfFuel())
            return
        end
    end
    put!(result, "done")
end

blocklist = [Function]
is_vararg(t) = isa(t, Core.TypeofVararg)

#
# generate_subtypes: JlSignature, SearchCfg -> [Union{JlSignature, SkippedUnionAlls}]
#
# Auxilliary function: immediate subtypes of a tuple of types `ts1`
#
# Precondition: no unbound existentials in ts1
#
generate_subtypes(ts1::Vector, scfg :: SearchCfg) = begin
    @debug "generate_subtypes: $ts1"
    isempty(ts1) && return [[]]

    ts = copy(ts1)
    t = pop!(ts)

    # subtypes of t -- first component in ts
    ss_first = if is_vararg(t) || any(b -> t <: b, blocklist)
        []
        else subtypes(t)
    end

    @debug "generate_subtypes of head: $(ss_first)"
    # no subtypes may mean it's a UnionAll requiring special handling
    if isempty(ss_first)
        if typeof(t) == UnionAll
            ss_first = subtype_unionall(t, scfg)
        end
    end

    res = []
    ss_rest = generate_subtypes(ts, scfg)
    for s_first in ss_first
        if s_first isa SkippedUnionAlls
            push!(res, s_first)
        else
            for s_rest in ss_rest
                if s_rest isa SkippedUnionAlls
                    push!(res, s_rest)
                else
                    push!(res, push!(Vector(s_rest), s_first))
                end
            end
        end
    end
    res
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
# subtype_unionall: UnionAll, SearchCfg -> [Union{JlType, SkippedUnionAll}]
#
# For a non-Any upper-bounded UnionAll, enumerate all instatiations following `instantiations`.
#
# Note: ignore lower bounds for simplicity.
#
# Note (history): for unbounded (Any-bounded) unionalls we used to instantiate the variable
# with Any and Int. This felt too arbitrary.
#
# TODO: make result Channel-based
#
subtype_unionall(u :: UnionAll, scfg :: SearchCfg) = begin
    @debug "subtype_unionall of $u"

    @assert u.var.ub != Any

    res = []
    instcnt = 0
    for t in instantiations(u, scfg)
        if t isa SkippedUnionAlls
            push!(res, t)
        else
            try # u{t} can fail due to unsond bounds (cf. #8)
                push!(res, u{t[1]})
            catch
                # skip failed instatiations
            end
            instcnt += 1
            if instcnt >= scfg.max_instantiations
                push!(res, TooManyInst((u,)))
            end
        end
    end
    res
end
