
#########################################
#
#      Data analysis utilities
#
#########################################


# ----------------------------------------
#
#    Conversion to CSV: Detailed Report
#
# ----------------------------------------


# Record of csv-ready checking results
struct MethStCheckCsv
    check :: String
    steps :: Union{Int, Missing}
    extra :: String
    name  :: String
    sig   :: String
    mod   :: String
    file  :: String
    line  :: Int
end

StCheckResultsCsv = Vector{MethStCheckCsv}

stCheckToCsv(::StCheck) :: String = error("unknown check")
stCheckToCsv(::Stb)         = "stable"
stCheckToCsv(::Uns)         = "unstable"
stCheckToCsv(::UConstrExist) = "uconstr"
stCheckToCsv(::AnyParam)    = "Any"
stCheckToCsv(::VarargParam) = "vararg"
stCheckToCsv(::TcFail)      = "tc-fail"
stCheckToCsv(::OutOfFuel)   = "nofuel"
stCheckToCsv(::GenericMethod) = "generic"

steps(s::Union{Stb,Uns}) = s.steps
steps(::StCheck) = missing

stCheckToExtraCsv(::StCheck) :: String = error("unknown check")
stCheckToExtraCsv(::Stb)        = ""
stCheckToExtraCsv(p::UConstrExist)        = "$(p.skipexist)"
stCheckToExtraCsv(::Uns)         = ""
stCheckToExtraCsv(::AnyParam)    = ""
stCheckToExtraCsv(::VarargParam) = ""
stCheckToExtraCsv(f::TcFail)     = "$(f.sig)"
stCheckToExtraCsv(::OutOfFuel)   = ""
stCheckToExtraCsv(::GenericMethod) = ""

prepCsvCheck(mc::MethStCheck) :: MethStCheckCsv =
    MethStCheckCsv(
        stCheckToCsv(mc.check),
        steps(mc.check),
        stCheckToExtraCsv(mc.check),
        "$(mc.method.name)",
        "$(mc.method.sig)",
        "$(mc.method.module)",
        "$(mc.method.file)",
        mc.method.line,
    )

#  Main pure interface to detailed report: csv'ize stability checking results
prepCsv(mcs::StCheckResults) :: StCheckResultsCsv = map(prepCsvCheck, mcs)


# ----------------------------------------
#
#    Conversion to CSV: Aggregated Report
#
# ----------------------------------------


#
# Note: Aggregated v Detailed
#
# What makes life easier with two types of reports is that they're largerly
# independent. One may think that aggregated is computed based on the detailed
# but that's actually NOT the case. Both are computed based on the raw structured
# data we get from the analysis.
#


# Record of aggregated results. One Julia module turns into one instance of it.
# Note: If you change it, you probably need to update scripts/aggregate.sh
struct AgStats
    methCnt :: Int64
    stbCnt :: Int64
    parCnt :: Int64
    unsCnt  :: Int64
    anyCnt  :: Int64
    vaCnt   :: Int64
    gen     :: Int64
    tcfCnt  :: Int64
    nofCnt  :: Int64
end

showAgStats(pkg::String, ags::AgStats) :: String =
    "$pkg,$(ags.methCnt),$(ags.stbCnt),$(ags.parCnt),$(ags.unsCnt),$(ags.anyCnt)," *
        "$(ags.vaCnt),$(ags.gen),$(ags.tcfCnt),$(ags.nofCnt)\n"

aggregateStats(mcs::StCheckResults) :: AgStats = AgStats(
    # TODO: this is a lot of passes over mcs; should rewrite into one loop
    length(mcs),
    count(mc -> isa(mc.check, Stb), mcs),
    count(mc -> isa(mc.check, UConstrExist), mcs),
    count(mc -> isa(mc.check, Uns), mcs),
    count(mc -> isa(mc.check, AnyParam), mcs),
    count(mc -> isa(mc.check, VarargParam), mcs),
    count(mc -> isa(mc.check, GenericMethod), mcs),
    count(mc -> isa(mc.check, TcFail), mcs),
    count(mc -> isa(mc.check, OutOfFuel), mcs),
)

# ----------------------------------------
#
#    Reporting Driver
#
# ----------------------------------------

# checkModule :: Module, Path -> IO ()
# Check stability in the given module, store results under the given path
# Effects:
#   1. Module.csv with detailed, user-friendly results
#   2. Module-agg.txt with aggregate results
checkModule(m::Module, out::String="."; pkg::String="$m")= begin
    checkRes = is_stable_module(m)

    # raw, to allow load it back up for debugging purposes
    # CSV.write(joinpath(out, "$m-raw.csv"), checkRes)

    # detailed
    repname = joinpath(out,"$pkg.csv")
    @info "Generating and writing out detailed report to $repname"
    CSV.write(repname, prepCsv(checkRes))

    # aggregate
    aggrepname = joinpath(out, "$pkg-agg.txt")
    @info "Generating and writing out aggregated report to $aggrepname"
    write(aggrepname, showAgStats(pkg, aggregateStats(checkRes)))
    return ()
end


# ----------------------------------------
#
#   Printing utilities
#
# ----------------------------------------


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
