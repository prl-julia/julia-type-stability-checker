#
# Data structures to represent answers to stability check requests
#   and search configuration
#

JlType = Any
JlSignature = Vector{T} where T

#
# Hierarchy of reasons for skipping UnionAlls
#
abstract type SkippedUnionAlls end
struct UnboundedUnionAlls <: SkippedUnionAlls
    # Unbounded UnionAll basically gives an occurence of Any,
    # which can't be handled by enumeration.
    ts :: Vector{Any}
end
struct SkipMandatory      <: SkippedUnionAlls
    # see SearchCfg.skip_unionalls: we turn off instantiation
    # of unionalls if we're currently processing one.
    ts :: Tuple
end

#######################################################################
#
#       Core Hierarchy: possible answers to a stability check query
#

abstract type StCheck end

#
# Two basic answers: yes or no
#
struct Stb <: StCheck         # hooary, we're stable
    steps :: Int64
end
struct Uns <: StCheck         # no luck; holds types that violate type stability
    steps :: Int64
    fails :: Vector{JlSignature}
end

#
# The third option is "not sure" -- underconstrained input type
#
abstract type UConstr <: StCheck   # Input type is underconstrained
end
struct OutOfFuel  <: UConstr       # Fuel exhausted or should be, no additional info
                                   # the rest of options bear some
end
struct UConstrExist <: UConstr     # Some existential unhapiness
    steps :: Int64
    skipexist :: Set{SkippedUnionAlls}
end
struct AnyParam    <: UConstr      # Give up on Any-params in methods; can't tell if it's stable
end
struct VarargParam <: UConstr      # Give up on VA-params  in methods; can't tell if it's stable
end
struct GenericMethod <: StCheck    # TODO: we could handle them analogous to existentials in types
                                   #       so it doesn't have to be a special case, but for now it's
end

#
# Failure of Juila's Type Checker -- technically, 4th answer, happens rarely
#
struct TcFail <: StCheck      # Julia typechecker sometimes fails for unclear reason
    sig :: JlSignature
    err :: Any
end

#####################################################

Base.:(==)(x::StCheck, y::StCheck) = structEqual(x,y)

# Result of a check along with the method under the check (for reporting purposes)
struct MethStCheck
    method :: Method
    check  :: StCheck
end

# Result of many checks (convinience alias)
StCheckResults = Vector{MethStCheck}

# Types Database Config
Base.@kwdef struct TypesDBCfg
    use_types_db :: Bool = false
#   ^ -- for cases where we can't enumerate exhaustively (unbounded UnionAlls),
#        whether to sample from types database;

    types_db :: Union{ Nothing, Vector{Any} } = nothing
#   ^ -- the actual db we sample from if use_types_db is true

    sample_count :: Int = 0
#   ^ -- How many types to sample from the DB.
#        Invariant: less then or equal to length(types_db)
end

# Subtype enumeration procedure parameters
Base.@kwdef struct SearchCfg
    concrete_only  :: Bool = true
#   ^--- enumerate concrete types ONLY;
#        Usually start in `true` mode, but can switch if we see a UnionAll and decide
#        to try abstract instantiations (whether we decide to do that or not, see
#        `abstract_args` below)

    skip_unionalls :: Bool = false
#   ^--- don't try to instantiate UnionAll's / existential types, just forget about them
#        -- be default we do instantiate, but can loop if don't turn off on recursive call;

    abstract_args  :: Bool = true
#   ^--- instantiate type variables with only concrete arguments (`false`) or
#        abstract arguments too (`true`);

    exported_names_only :: Bool = false
#   ^--- when doing stability check on the whole module at once: whether to check only
#        only exported functions

    failfast :: Bool = true
#   ^--- exit when find the first counterexample

    fuel :: Int = 100 #typemax(Int)
#   ^--- search fuel, i.e. how many types we want to enumerate before give up

    typesDBcfg :: TypesDBCfg = TypesDBCfg()
#   ^--- Parameters of the types DB.
end

#
# Several sample search configs
#
default_scfg = SearchCfg()

fast_scfg = SearchCfg(fuel=30)

build_typesdb_scfg(inFile = intypesCsvFileDefault; sample_count :: Int = 100000) = begin
    scfg = @set default_scfg.typesDBcfg.use_types_db = true
    scfg = @set scfg.typesDBcfg.types_db            = typesDB(inFile)[1:min(end,sample_count)]
    scfg = @set scfg.typesDBcfg.sample_count        = sample_count
    scfg = @set scfg.fuel                           = length(scfg.typesDBcfg.types_db)
    scfg
end

# How many counterexamples to print by default
MAX_PRINT_UNSTABLE = 5

# Types of failures

struct CantSplitMethod
    m :: Method
end

Base.@kwdef struct TypesDBErrorMetrics
    types_count :: Int = 0 # count types processed

    # Special case counters
    function_types    :: Int = 0 # count function types
    main_module_types :: Int = 0 # count types defined in the "Main" module
    error_count       :: Int = 0 # count failure to eval types
end

struct TypesDBErrorReport
    error_messages :: Vector
    metrics        :: TypesDBErrorMetrics
end
