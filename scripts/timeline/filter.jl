#
# Filter the "interesting" cases. This is a heuristic that tries to find the cases where the
# stability of a given method changes. It computes the delta of 
# the Methods and Unstable columns between rows, and only keeps the rows where
# MethodsDelta is zero and UnstableDelta is non-zero (ie. the two versions have the same
# number of methods but the number of unstable methods changed).
# 
# Caveat: Since this is just a heuristic the results need to be inspected manually. Also some
# interesting cases can be missed.
#
# Cases:
#   * unstable delta != 0: stability changes, but can be  because of adding new or removing old
#       unstable methods
#   * unstable delta == 0: stability doesn't seem to change but possibly changes just cancel out
#   * methods delta == 0 && unstable delta != 0: hopefully the stability of an existing method changed
#   * ...
#
# Usage: Run with `julia <path/to/julia-sts>/scripts/timeline/filter.jl <agg_file> <out_file>`
# Effect: Filters the given agg_file csv
#

agg_file = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: aggregate csv")
out_file = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: output file")

using CSV, DataFrames

function delta(column::Vector{Int64})
    vcat(0, diff(column))
end

df = CSV.read(agg_file, DataFrame)
df.DeltaMethods = delta(df.Methods)
df.DeltaUnstable = delta(df.Unstable)

df = df[(df.DeltaMethods .== 0) .& (df.DeltaUnstable .!= 0), :]

if !isdir(dirname(out_file))
    mkpath(dirname(out_file))
end
@info "Writing to `$out_file'"
CSV.write(out_file, df)
