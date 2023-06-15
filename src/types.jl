#
# Data structures to represent answers to stability check requests
#   and search configuration
#

JlType = Any
JlSignature = Vector{JlType}

#
# Hierarchy of reasons for skipping UnionAlls
#
abstract type SkippedUnionAlls end
struct UnboundedUnionAlls <: SkippedUnionAlls
    # Unbounded UnionAll basically gives an occurence of Any,
    # which can't be handled by enumeration.
    ts :: Tuple
end
struct SkipMandatory      <: SkippedUnionAlls
    # see SearchCfg.skip_unionalls: we turn off instantiation
    # of unionalls if we're currently processing one.
    ts :: Tuple
end
struct TooManyInst      <: SkippedUnionAlls
    # see SearchCfg.max_instantiations and subtype_unionall
    ts :: Tuple
end

#
#       Core Hierarchy: possible answers to a stability check querry
#
abstract type StCheck end
struct Stb <: StCheck         # hooary, we're stable
    steps :: Int64
end
struct Par <: StCheck         # Partial -- we're stable modulo some UnionAlls
    steps :: Int64
    skipexist :: Set{SkippedUnionAlls}
end
struct Uns <: StCheck         # no luck; holds types that break stability
    steps :: Int64
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
    err :: Any
end
struct OutOfFuel  <: StCheck  # fuel exhausted
end
struct GenericMethod <: StCheck # TODO: we could handle them analogous to existentials in types
                                #       so it doesn't have to be a special case, but for now it's
end

Base.:(==)(x::StCheck, y::StCheck) = structEqual(x,y)
Base.:(==)(x::TooManyInst, y::TooManyInst) = structEqual(x,y)

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
#        Usually start in `true` mode, but can switch if we see a UnionAll and decide
#        to try abstract instantiations (whether we decide to do that or not, see
#        `abstract_args` below)

    skip_unionalls :: Bool = false
#   ^ -- don't try to instantiate UnionAll's / existential types, just forget about them
#        -- be default we do instantiate, but can loop if don't turn off on recursive call;

    abstract_args  :: Bool = true
#   ^ -- instantiate type variables with only concrete arguments (`false`) or
#        abstract arguments too (`true`);

    exported_names_only :: Bool = false
#   ^ -- when doing stability check on the whole module at once: whether to check only
#        only exported functions

    fuel :: Int = 1000 #typemax(Int)
#   ^ -- search fuel, i.e. how many types we want to enumerate before give up

    max_lattice_steps :: Int = 1000 #typemax(Int)
#   ^ -- how many steps to perform max to get from the signature to a concrete type;
#        for some signatures we struggle to get to a leaf type

    max_instantiations :: Int = 1000 #typemax(Int)
#   ^ -- how many instantiations of a type variable to examine (sometimes it's too much)

    use_types_db :: Bool = false
#   ^ -- for cases where we can't enumerate exhaustively (unbounded UnionAlls),
#        whether to sample from types database;

    types_db :: Union{ Nothing, Vector{Any} } = nothing
#   ^ -- the actual db we sample from if use_types_db is true
end

#
# Several sample search configs
#
default_scfg = SearchCfg()
fast_scfg = SearchCfg(fuel=100, max_lattice_steps=100, max_instantiations=100)
build_typesdb_scfg(inFile = intypesCsvFileDefault) = begin
    scfg1 = @set default_scfg.use_types_db = true
    scfg2 = @set scfg1.types_db = typesDB(inFile)
    scfg3 = @set scfg2.fuel = length(scfg2.types_db)
    scfg3
end

# How many counterexamples to print by default
MAX_PRINT_UNSTABLE = 5

# Types of failures

struct CantSplitMethod
    m :: Method
end
