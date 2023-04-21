#
# Plot the evolution of unstable method counts over time
#
# This creates a pdf with a plot of absolute number of unstable methods for each commit in
# history as well as two plots that show the percentage of stable and unstable methods vs. all methods
# for each commit.
# 
# Usage: Run with `julia <path/to/julia-sts>/scripts/timeline/plot.jl <agg_file> <out_file>`
# Effect: Creates a visualization of the evolution of method stability in out_file.
#

agg_file = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: aggregate csv")
out_file = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: output file")

include("utils.jl")

using CSV
using DataFrames
using Plots

pkg = first(splitext(basename(agg_file)))
df = CSV.read(agg_file, DataFrame)
n = size(df)[1]

if n < 2
    @info_extra "Skipped plotting for `$pkg': not enough data"
    exit(0)
end

mmax(v) = maximum(x -> isnan(x) ? -Inf : x, v)
mmin(v) = minimum(x -> isnan(x) ? +Inf : x, v)
xticks(from, to) = round.(Int64, range(from, stop=to, length=min(15, to)))
yticks(from, to, precision) = round.(range(from, stop=to, length=from == to ? 1 : 4), digits=precision)

gr()

unstable = df.Unstable
p1 = plot(
    unstable,
    xticks=xticks(1, n),
    yticks=yticks(mmin(unstable), mmax(unstable), 0),
    xlabel="",
    ylabel="Unstable Total",
    shape=:circle,
    markersize=1,
    grid=true,
    legend=:none,
);

stable_rate = ifelse.(df.Methods .== 0, NaN, df.Stable ./ df.Methods .* 100)
p2 = plot(stable_rate,
    xticks=xticks(1, n),
    yticks=yticks(mmin(stable_rate), mmax(stable_rate), 2),
    label="Stable [%]",
    xlabel="",
    ylabel="",
    shape=:circle,
    markersize=1,
    grid=true,
    legendfontpointsize=5,
);

unstable_rate = ifelse.(df.Methods .== 0, NaN, df.Unstable ./ df.Methods .* 100)
p3 = plot(unstable_rate,
    xticks=xticks(1, n),
    yticks=yticks(mmin(unstable_rate), mmax(unstable_rate), 2),
    label="Unstable [%]",
    xlabel="Commit #",
    ylabel="",
    shape=:circle,
    markersize=1,
    grid=true,
    legendfontpointsize=5,
);

layout = @layout [a{0.5h}; b; c]
plot(p1, p2, p3,
    layout=layout,
    plot_title="Method Stability for `$pkg'",
);

@info_extra "Writing to `$out_file'"
ensure_dir(dirname(out_file))
savefig(out_file)
