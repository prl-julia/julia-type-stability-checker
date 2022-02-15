module StabilityCheck

#
# Exhaustive enumeration of types for static type stability checking
#

export @stable, @stable!, @stable!_nop,
    is_stable_method, is_stable_function, is_stable_module, is_stable_moduleb,
    check_all_stable,
    convert,
    Stb, Uns,
    SearchCfg

# Debug print:
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on
# ENV["JULIA_DEBUG"] = Nothing         # turn off

using InteractiveUtils
using MacroTools

#
# Data structures to represent answers to stability check requests
#   and search configuration
#

abstract type StCheck end
struct Stb <: StCheck end # hooary, we're stable
struct Uns <: StCheck     # no luck, record types that break stability
    fails :: Vector{Vector{Any}}
end

struct MethStCheck
    method :: Method
    check  :: StCheck
end

Base.@kwdef struct SearchCfg
    concrete_only  :: Bool = true
#   ^ -- enumerate concrete types ONLY;
#        Usually start in this mode, but can switch if we see a UnionAll and decide
#        to try abstract instantiations (whether we decide to do that or not, see
#        `abstract_args` below)

    skip_unionalls :: Bool = false
#   ^ -- don't try to instantiate UnionAll's / existential types, just forget about them
#        -- be default we do instantiate, but can loop if don't turn off on recursive call;

    abstract_args  :: Bool = false
#   ^ -- instantiate type variables with only concrete arguments or abstract arguments too;
#        if the latter, may quickly become unstable, so a reasonable default is be `false`

    exported_names_only :: Bool = true
#   ^ -- when doing stability check on the whole module at once: whether to check only
#        only exported functions
end

default_scfg = SearchCfg()

# How many counterexamples to print by default
MAX_PRINT_UNSTABLE = 5


#
#       Main interface utilities
#


# @stable!: method definition AST -> IO same definition
# Side effects: Prints warning if finds unstable signature instantiation.
#               Relies on is_stable_method.
macro stable!(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(esc(def))
        m = which($(esc(fname)), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
        (f,_) = split_method(m)
        f
    end
end

# Interface for delayed stability checks; useful for define-after-use cases (cf. Issue #3)
# @stable delays the check until `check_all_stable` is called. The list of checks to perform
# is stored in a global list that needs cleenup once in a while with `clean_checklist`.
checklist=[]
macro stable(def)
    push!(checklist, def)
    def
end
check_all_stable() = begin
    @debug "start check_all_stable"
    for def in checklist
        (fname, argtypes) = split_def(def)
        @debug "Process method $fname with signature: $argtypes"
        m = which(eval(fname), eval(argtypes))
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end
clean_checklist() = begin
    global checklist = [];
end

# Variant of @stable! that doesn't splice the provided function definition
# into the global namespace. Mostly for testing purposes. Relies on Julia's
# hygiene support.
macro stable!_nop(def)
    (fname, argtypes) = split_def(def)
    quote
	    $(def)
        m = which($(fname), $argtypes)
        mst = is_stable_method(m)

        print_uns(m, mst)
    end
end

# is_stable_module : Module, SearchCfg -> IO Vector{MethStCheck}
# Check all(*) function definitions in the module for stability.
# Relies on `is_stable_function`.
# (*) By "all" we mean all exported, by default, but this can be switched
# to literally all using `SearchCfg`'s  `exported_names_only`.
is_stable_module(mod::Module, scfg :: SearchCfg = default_scfg) :: Vector{MethStCheck} = begin
    @debug "is_stable_module: $mod"
    res = []
    for sym in names(mod; all=!scfg.exported_names_only)
        @debug "is_stable_module: check symbol $sym"
        evsym = Core.eval(mod, sym)
        isa(evsym, Function) || continue # not interested in non-functional symbols
        (sym == :include || sym == :eval) && continue # not interested in special functions
        res = vcat(res, is_stable_function(evsym, scfg))
    end
    return res
end

# bool-returning version of the above
is_stable_moduleb(mod::Module, scfg :: SearchCfg = default_scfg) :: Bool =
    convert(Bool, is_stable_module(mod, scfg))

# is_stable_function : Function, SearchCfg -> IO Vector{MethStCheck}
# Convenience tool to iterate over all known methods of a function.
# Usually, direct use of `is_stable_method` is preferrable, but, for instance,
# `is_stable_module` has to rely on this one.
is_stable_function(f::Function, scfg :: SearchCfg = default_scfg) :: Vector{MethStCheck} = begin
    @debug "is_stable_function: $f"
    checks = map(m -> MethStCheck(m, is_stable_method(m, scfg)), methods(f).ms)

    # TODO: make the function pure and move code below somewhere in the UI level
    fails = filter(methAndCheck -> isa(methAndCheck.check, Uns), checks)
    if !isempty(fails)
        println("Some methods failed stability test")
        print_unsmethods(fails)
    end

    return checks
end

# is_stable_method : Method, SearchCfg -> StCheck
# Main interface utility: check if method is stable by enumerating
# all possible instantiations of its signature.
is_stable_method(m::Method, scfg :: SearchCfg = default_scfg) :: StCheck = begin
    @debug "is_stable_method: $m"
    (func, sig_types) = split_method(m)
    sig_subtypes = all_subtypes(sig_types, scfg)

    fails = Vector{Any}([])
    for ts in sig_subtypes
        if ! is_stable_call(func, ts)
            push!(fails, ts)
        end
    end

    return if isempty(fails)
        Stb()
    else
        Uns(fails)
    end
end


#
#      Printing utilities
#

print_fails(uns :: Uns) = begin
    local i = 0
    for ts in uns.fails
        println("\t" * string(ts))
        i += 1
        if i == MAX_PRINT_UNSTABLE
            println("and $(length(uns.fails) - i) more... (adjust MAX_PRINT_UNSTABLE to see more)")
            return
        end
    end
end

print_uns(::Method, ::Stb) = ()
print_uns(m::Method, mst::Uns) = begin
    @warn "Method $(m.name) unstable on the following inputs"
    print_fails(mst)
end

print_unsmethods(fs :: Vector{MethStCheck}) = begin
    for mck in fs
        print("The following method:\n\t")
        println(mck.method)
        println("is not stable for the following types of inputs")
        print_fails(mck.check)
    end
end

print_stable_check(f,ts,res_type,res) = begin
    print(lpad("is stable call " * string(f), 20) * " | " *
        rpad(string(ts), 35) * " | " * rpad(res_type, 30) * " |")
    println(res)
end


#
#      Aux utilities
#

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

# Used to instantiate functions for concrete argument types.
# Input:
#   - "tuple" of types from the function signature (in the form of Vector, not Tuple);
#   - search configuration
# Output: vector of "tuples" that subtype input
all_subtypes(ts::Vector, scfg :: SearchCfg) = begin
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
            !scfg.concrete_only && push!(result, tv)
            dss = direct_subtypes(tv, scfg)
            union!(sigtypes, dss)
        end
    end
    result
end

# Auxilliary function: immediate subtypes of a tuple of types `ts`
direct_subtypes(ts1::Vector, scfg :: SearchCfg) = begin
    if isempty(ts1)
        return []
    end
    ts = copy(ts1)
    t = pop!(ts)
    ss_last = subtypes(t)
    if isempty(ss_last)
        if typeof(t) == UnionAll
            ss_last = subtype_unionall(t, scfg)
        end
    end
    if isempty(ts)
        return (Vector{Any}([s])
                    for s=ss_last
                    if !(scfg.skip_unionalls && typeof(s) == UnionAll))
    end

    res = []
    ss_rest = direct_subtypes(ts, scfg)
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
subtype_unionall(u :: UnionAll, scfg :: SearchCfg) = begin
    @debug "subtype_unionall of $u"
    ub = u.var.ub
    sample_types = if ub == Any
        [Int64, Any]
    else
        ss = all_subtypes([ub],
                          SearchCfg(concrete_only  = scfg.abstract_args,
                                    skip_unionalls = true,
                                    abstract_args  = scfg.abstract_args))
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

# In case we need to convert to Bool...
import Base.convert
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

# Split method object into the corresponding function object and type signature
# of the method
split_method(m::Method) = begin
    msig = Base.unwrap_unionall(m.sig) # unwrap is critical for generic methods
    func = msig.parameters[1].instance
    sig_types = Vector{Any}([msig.parameters[2:end]...])
    (func, sig_types)
end


end # module
