#
# Data structures to represent answers to stability check requests
#   and search configuration
#

JlType = Any
JlSignature = Vector{JlType}

# Hieararchy of possible answers to a stability check querry
abstract type StCheck end
struct Stb <: StCheck         # hooary, we're stable
    steps :: Int64
    skipexist :: Vector{JlType}
end
struct Uns <: StCheck         # no luck, record types that break stability
    fails :: Vector{Vector{Any}}
end
struct AnyParam    <: StCheck # give up on Any-params in methods; can't tell if it's stable
    sig :: Vector{Any}
end
struct VarargParam <: StCheck # give up on VA-params  in methods; can't tell if it's stable
    sig :: Vector{Any}
end
struct TcFail <: StCheck      # Julia typechecker sometimes fails for unclear reason
    sig :: Vector{Any}
end
struct OutOfFuel  <: StCheck  # fuel exhausted
end
struct UnboundExist <: StCheck  # we hit unbounded existentials, which we can't enumerate
    t :: JlType                 # (same as Any, but maybe interesting to analyze separately)
                                # TODO: this is not accounted for yet, as we don't distinguish
                                #       between various cases under SkippedUnionAlls
end

Base.:(==)(x::StCheck, y::StCheck) = structEqual(x,y)

# Result of a check along with the method under the check (for reporting purposes)
struct MethStCheck
    method :: Method
    check  :: StCheck
end

# Result of many checks (convinience alias)
StCheckResults = Vector{MethStCheck}

# Subtype enumeration procedure parameters
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

    exported_names_only :: Bool = false
#   ^ -- when doing stability check on the whole module at once: whether to check only
#        only exported functions

    fuel :: Int = typemax(Int)
#   ^ -- search fuel, i.e. how many types we want to enumerate before give up

    max_lattice_steps :: Int = typemax(Int)
#   ^ -- how many steps to perform max to get from the signature to a concrete type;
#        for some signatures we struggle to get to a leat type
end

default_scfg = SearchCfg()
fast_scfg = SearchCfg(fuel=100, max_lattice_steps=100)

# How many counterexamples to print by default
MAX_PRINT_UNSTABLE = 5

struct SkippedUnionAlls
    ts :: Vector{JlType}
end
