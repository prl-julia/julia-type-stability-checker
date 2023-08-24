
#
#      Aux utilities
#

import Base: convert, methods


# is_expected_union: Union -> Bool
#
# In Julia 1.8 the definition of expected union will change drastically allowing
# small unions of concrete types, see discussion in
# https://github.com/ulysses4ever/julia-sts/wiki/concrete_type_def-2022-08-15
# I'm not sure we want to follow. At the same time, they fix an actual bug in the
# old def (where `Union{Missing, Vector}` was considered "expected"). So, for the
# time being copy the fix.
#
function is_expected_union(u::Union)
    has_non_missing = false
    for x in Base.uniontypes(u)
        if (x != Missing) && (x != Nothing)
            if has_non_missing
                return false
            elseif !Base.isdispatchelem(x) || x == Core.Box
                return false
            else
                has_non_missing = true
            end
        end
    end
    return true
end

# The heart of stability checking using Julia's built-in facilities:
# 1) compile the given function for the given argument types down to a typed IR
# 2) check the return type for concreteness
is_stable_call(@nospecialize(f :: Function), @nospecialize(ts :: Vector)) = begin
    ct = code_typed(f, (ts...,), optimize=false)
    if length(ct) == 0
        throw(DomainError("$f, $ts")) # type inference failed
    end
    (_ #=code=#, res_type) = ct[1] # we ought to have just one method body, I think
    res = is_concrete_type(res_type)
    #print_stable_check(f,ts,res_type,res)
    res
end

# is_concrete_type: Type -> Bool
#
# Note: Follows definition used in @code_warntype (cf. `warntype_type_printer` in:
# julia/stdlib/InteractiveUtils/src/codeview.jl)
is_concrete_type(@nospecialize(ty)) = begin
    if ty isa Type && (!Base.isdispatchelem(ty) || ty == Core.Box)
        if ty isa Union && is_expected_union(ty)
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

# In case we need to convert to Bool...
convert(::Type{Bool}, x::Stb) = true
convert(::Type{Bool}, x::Uns) = false

convert(::Type{Bool}, x::Vector{MethStCheck}) = all(mc -> isa(mc.check, Stb), x)

# Split method definition expression into name and argument types
split_def(def::Expr) = begin
    defparse = splitdef(def)
    fname    = defparse[:name]
    argtypes = map(a-> eval(splitarg(a)[2]), defparse[:args]) # [2] is arg type
    (fname, argtypes)
end

#
# split_method :: Method -> Union{ (Function, [JlType]), GenericMethod }
#
# Split method object into the corresponding function object and type signature
# of the method, if possible. May fail if unionalls involved in a funny way
# but there doesn't seem to be such cases as of 2023.
#
split_method(m::Method) = begin
    m.sig isa UnionAll && return GenericMethod()
    msig = Base.unwrap_unionall(m.sig) # unwrap is critical for generic methods
    try
        func = msig.parameters[1].instance
        sig_types = Vector{Any}([msig.parameters[2:end]...])
        (func, sig_types)
    catch err
        if ! hasproperty(msig.parameters[1], :instance)
            throw(CantSplitMethod(m)) # this happens for overloaded `()`
            # e.g. in https://github.com/JuliaLang/julia/blob/v1.7.2/base/operators.jl#L1085
            # (c::ComposedFunction)(x...; kw...) = ...
        else
            throw(err) # unknown failure
        end
    end
end

# Given a function and a module, finds all methods defined in the module
# for the function. Convenience method to be used in conjuction with
# `names(m,; imported=true)`.
our_methods_of_function(f :: Function, mod :: Module) :: Vector{Method} = begin
    ms = methods(f).ms
    filter(meth -> meth.module === mod, ms)
end

# For a given module `m`, determine if it is nested in module `outer`,
# i.e., if `outer`` is reachable by following the chain of parent modules
# from `m`
is_module_nested(m::Module, outer::Module) :: Bool = begin
    sentinel = Base.moduleroot(m)
    while true
        m === outer && return true
        m === sentinel && return false
        m = parentmodule(m)
    end
end

# Helper struct that erases the type of a function. Can be stored in Sets and Dicts
# to avoid excessive compilation as it is a concrete type
struct OpaqueFunction
    f::Function
end
methods(of::OpaqueFunction) = methods(of.f)

discover_functions(mod::Module, root::Module, scfg::SearchCfg, seen::Set{Module}, out::Set{OpaqueFunction}) = begin
    mod ∈ seen && return
    push!(seen, mod)

    @debug "discover_functions($mod)"

    for sym in names(mod; all=!scfg.exported_names_only, imported=true)
        try
            val = getproperty(mod, sym)
            val isa Module && is_module_nested(val, root) &&
                discover_functions(val, root, scfg, seen, out)
            val isa Function && !(val isa Core.Builtin) && !(val isa Core.IntrinsicFunction) && sym ∉ [:include, :eval] &&
                push!(out, OpaqueFunction(val))
        catch e
            if e isa UndefVarError
                # Not our problem, so proceed as usual
                # Avoid some warnings from Julia.
                # See https://github.com/JuliaLang/julia/blob/v1.8.5/test/ambiguous.jl#L104-L119
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
