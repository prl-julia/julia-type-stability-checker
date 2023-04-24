#
# Process a batch of Julia packages.
#
# Usage: Run with `julia --threads=<N> <path/to/julia-sts>/scripts/timeline-batch.jl`
#        It's recommended to redirect output to a log file (e.g. `&> LOG` in bash) since there is a lot of ouput
# Effect: results are stored in the CWD in `timelines` subdirectory, temporary intermediate files are in `scratch` subdirectory
#

sts_path = dirname(@__DIR__)

function info(s::String)
    @info s
    flush(stdout)
    flush(stderr)
end

packages = [
    ("Multisets", "https://github.com/scheinerman/Multisets.jl.git"),
    ("Gen", "https://github.com/probcomp/Gen.jl.git"),
    ("Flux", "https://github.com/FluxML/Flux.jl.git"),
    ("Gadfly", "https://github.com/GiovineItalia/Gadfly.jl.git"),
    ("Genie", "https://github.com/GenieFramework/Genie.jl.git"),
    ("IJulia", "https://github.com/JuliaLang/IJulia.jl.git"),
    ("JuMP", "https://github.com/jump-dev/JuMP.jl.git"),
    ("Knet", "https://github.com/denizyuret/Knet.jl.git"),
    ("Plots", "https://github.com/JuliaPlots/Plots.jl.git"),
    ("Pluto", "https://github.com/fonsp/Pluto.jl.git"),
]

n = Threads.nthreads()
info("== Using $n threads ==")

for (pkg, url) in packages
    _, t = @timed begin
        scratch = joinpath(".", "scratch/$pkg")
        out = joinpath(".", "timelines/$pkg.csv")
        out_filtered = joinpath(".", "timelines/$pkg-filtered.csv")
        info("=== Checking `$pkg' ===")
        run(`julia --threads=$n $(joinpath(sts_path, "scripts/timeline.jl")) $url $scratch`)
        info("=== Aggregating results for `$pkg' ===")
        run(`julia $(joinpath(sts_path, "scripts/timeline-aggregate.jl")) $scratch $out`)
        run(`julia $(joinpath(sts_path, "scripts/timeline-filter.jl")) $out $out_filtered`)
    end
    # Report nice time
    t, unit = t, "s"
    if t > 60
        t /= 60
        unit = "m"
    end
    if t > 60
        t /= 60
        unit = "h"
    end
    info("=== Done with $pkg in $(round(t, digits=3))$unit")
end
