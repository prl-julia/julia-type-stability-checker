#
# Process a batch of Julia packages.
#
# Usage: Run with `julia --threads=<N> <path/to/julia-sts>/scripts/timeline/batch.jl scratch_dir out_dir`
#        It's recommended to redirect output to a log file (e.g. `&> LOG` in bash) since there is a lot of ouput
# Effect: results are stored in `out_dir`, temporary intermediate files are in `scratch_dir`
#

scratch_dir = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: scratch directory")
out_dir = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: output directory")

if !isdir(scratch_dir)
    mkpath(scratch_dir)
end
if !isdir(out_dir)
    mkpath(out_dir)
end

sts_path = dirname(dirname(@__DIR__))

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
        try
            scratch = joinpath(scratch_dir, pkg)
            out = joinpath(out_dir, "$pkg.csv")
            out_filtered = joinpath(out_dir, "$pkg-filtered.csv")
            info("=== Checking `$pkg' ===")
            run(`julia --threads=$n $(joinpath(sts_path, "scripts/timeline/history.jl")) $url $scratch`)
            info("=== Aggregating results for `$pkg' ===")
            run(`julia $(joinpath(sts_path, "scripts/timeline/aggregate.jl")) $scratch $out`)
            run(`julia $(joinpath(sts_path, "scripts/timeline/filter.jl")) $out $out_filtered`)
        catch e
            info("Processing package $pkg failed: $e")
        end
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
