#
#                    Data analysis and presentation utilities
#

#
#                      Convert to CSV: Raw Data
#

# One line of CSV with a single stability check of a method; holds:
# - method check result
# - method signature
# - method's module name
# - source file
# - line in the source file where the method is defined
struct MethCheckCsv
    check :: String
    sig   :: String
    mod   :: String
    file  :: String
    line  :: Int
end

StCheckResultsCsv = Vector{MethCheckCsv}

stCheckType(::StCheck) :: String = error("unknown check")
stCheckType(::Stb)         = "stable"
stCheckType(::Uns)         = "unstable"
stCheckType(::AnyParam)    = "Any"
stCheckType(::VarargParam) = "vararg"
stCheckType(::TcFail)      = "tc-fail"
stCheckType(::OutOfFuel)   = "nofuel"
stCheckType(::GenericMethod) = "generic"

# Create MethCheckCsv from MethStCheck
prepCsvCheck(mc::MethStCheck) :: MethCheckCsv =
    MethCheckCsv(
        stCheckType(mc.check),
        "$(mc.method.sig)",
        "$(mc.method.module)",
        "$(mc.method.file)",
        mc.method.line,
    )

prepCsv(mcs::StCheckResults) :: StCheckResultsCsv = map(prepCsvCheck, mcs)

#
#                        Convert to CSV: Details About Stable Methods
#

struct StableMethodCsv
    sig    :: String
    steps  :: Int
    skipExistCount :: Int
    skipExist      :: String
    mod    :: String
    file   :: String
    line   :: Int
end

StableMethodResultsCsv = Vector{StableMethodCsv}

prepCsvStableMethod(mc::MethStCheck) :: StableMethodCsv = begin
    @assert(mc.check isa StCheck)
    s = mc.check
    StableMethodCsv(
        "$(mc.method.sig)",
        s.steps,
        length(s.skipexist),
        "$(s.skipexist)",
        "$(mc.method.module)",
        "$(mc.method.file)",
        mc.method.line,
    )
end

prepCsvStable(mcs::StCheckResults) :: StableMethodResultsCsv  =
    map(prepCsvStableMethod, filter(mc -> mc.check isa Stb, mcs))

#
#                          Aggregate Stats
#

struct AgStats
    methCnt :: Int64
    stblCnt :: Int64
    unsCnt  :: Int64
    anyCnt  :: Int64
    vaCnt   :: Int64
    gen     :: Int64
    tcfCnt  :: Int64
    nofCnt  :: Int64
end

showAgStats(pkg::String, ags::AgStats) :: String =
    "$pkg,$(ags.methCnt),$(ags.stblCnt),$(ags.unsCnt),$(ags.anyCnt)," *
        "$(ags.vaCnt),$(ags.gen),$(ags.tcfCnt),$(ags.nofCnt)\n"

aggregateStats(mcs::StCheckResults) :: AgStats = AgStats(
    length(mcs),
    count(mc -> isa(mc.check, Stb), mcs),
    count(mc -> isa(mc.check, Uns), mcs),
    count(mc -> isa(mc.check, AnyParam), mcs),
    count(mc -> isa(mc.check, VarargParam), mcs),
    count(mc -> isa(mc.check, GenericMethod), mcs),
    count(mc -> isa(mc.check, TcFail), mcs),
    count(mc -> isa(mc.check, OutOfFuel), mcs),
)

#
#                          Interface
#

# checkModule :: Module, Path -> IO ()
# Check stability in the given module, store results under the given path
# Effects:
#   1. Module.csv with complete, raw results
#   2. Module-stable.csv with more detailed info about stable methods
#   3. Module-agg.txt with aggregate results
checkModule(m::Module, out::String="."; pkg::String="$m")= begin
    checkRes = is_stable_module(m)

    # raw, to allow load it back up for debugging purposes
    # CSV.write(joinpath(out, "$m-raw.csv"), checkRes)

    # complete
    CSV.write(joinpath(out,"$pkg.csv"), prepCsv(checkRes))

    # stable detailed
    CSV.write(joinpath(out,"$pkg-stable.csv"), prepCsvStable(checkRes))

    # aggregate
    write(joinpath(out, "$pkg-agg.txt"), showAgStats(pkg, aggregateStats(checkRes)))
    return ()
end

# End of persistent (CSV) error reports

###########################################################################################
#
#                      Printing utilities
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

print_uns(::Method, ::StCheck) = ()
print_uns(m::Method, mst::Union{AnyParam, TcFail, VarargParam, OutOfFuel}) = begin
    @warn "Method $(m.name) failed stabilty check with: $mst"
end
print_uns(m::Method, mst::Uns) = begin
    @warn "Method $(m.name) unstable on the following inputs"
    print_fails(mst)
end

print_check_results(checks :: Vector{MethStCheck}) = begin
    fails = filter(methAndCheck -> isa(methAndCheck.check, Uns), checks)
    if !isempty(fails)
        println("Some methods failed stability test")
        print_unsmethods(fails)
    end
end

print_unsmethods(fs :: StCheckResults) = begin
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
