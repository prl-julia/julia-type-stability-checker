#
# Process a batch of Julia packages.
#
# Usage: Run with `julia --threads=<N> <path/to/julia-sts>/scripts/timeline/batch.jl pkg_file scratch_dir out_dir`
#        The pkg_file should contain one package name per line.
#        It's recommended to redirect output to a log file (e.g. `&> LOG` in bash)
# Effect: results are stored in `out_dir`, temporary intermediate files are in `scratch_dir`
#

pkg_file = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: file with package names")
scratch_dir = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: scratch directory")
out_dir = length(ARGS) > 2 ? ARGS[3] : error("Requires argument: output directory")

include("utils.jl")

HISTORY = joinpath(STS_PATH, "scripts/timeline/history.jl")
AGGREGATE = joinpath(STS_PATH, "scripts/timeline/aggregate.jl")
FILTER = joinpath(STS_PATH, "scripts/timeline/filter.jl")
PLOT = joinpath(STS_PATH, "scripts/timeline/plot.jl")

N = Threads.nthreads()
@info_extra "== Using $N threads =="

#
# Go through the packages and group them by the repo where they live
# For repos that contain multiple packages (eg. a library in a subdirectory) the history
# script processes all these packages at the same time.
#
# Some observed properties:
#   - mostly the packages are "simple" - there is one package (Project.toml) in the root of a repo
#   - some have just one package but in a subdir, eg. duckdb - just julia bindings for a project in c++
#   - some have multiple packages, eg. makie - originally simple then converted to monorepo
#       - typically one top level package and a bunch of libraries in subdirs
#   - some are renamed - eg. casual - then it seems there are two packages but they map to the same Project.toml
#
# TODO: `pkg_info`` will give changing data over time... should we take a snapshot at a given time?
# TODO: Also there are possible problems with the subdirs changing over time. Eg. the current package
#       lives in `lib/packageX` but when we check out a previous commit, it lived elsewhere / didn't
#       exist yet
#
repos = Dict()
for pkg in read_lines(pkg_file)
    info = pkg_info(pkg)
    if !haskey(repos, info.repo)
        repos[info.repo] = []
    end
    push!(repos[info.repo], (pkg, info.subdir))
end

for (repo, pkgs) in repos
    @info_extra "=== Checking `$repo' ==="
    _, t = @timed begin
        try
            run(`julia --threads=$N $HISTORY $scratch_dir $([p for (p, _) in pkgs])`)

            for (pkg, _) in pkgs
                @info_extra "=== Aggregating results for `$pkg' ==="

                scratch = joinpath(scratch_dir, pkg)
                out = joinpath(out_dir, "$pkg.csv")
                run(`julia $AGGREGATE $scratch $out`)
                if isfile(out)
                    out_filtered = joinpath(out_dir, "$pkg-filtered.csv")
                    run(`julia $FILTER $out $out_filtered`)
                    out_plot = joinpath(out_dir, "$pkg.pdf")
                    run(`julia $PLOT $out $out_plot`)
                end
            end
        catch e
            @info_extra "Processing repository $repo failed: $e"
        end
    end
    @info_extra "=== Done with $repo in $(pretty_duration(t))"
end
