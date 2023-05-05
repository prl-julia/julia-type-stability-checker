#
# Aggregate data collected by the timeline.jl script for a given package
#
# Usage: Run with `julia <path/to/julia-sts>/scripts/timeline/aggregate.jl <in_dir> <out_file>`
# Effect: Writes the summary csv in the out_file
#

in_dir = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: input directory")
out_file = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: output file")

include("utils.jl")

all_agg_files = sort(split(exec(`find $in_dir -maxdepth 2 -name "*-agg.txt"`), "\n"))

if length(all_agg_files) == 0 || (length(all_agg_files) == 1 && first(all_agg_files) == "")
    @info_extra "No aggregate files found..."
    exit(0)
end

result = ["Module,Methods,Stable,Partial,Unstable,Any,Vararg,Generic,TcFail,NoFuel,Version,Commit,Message,Date"]
last_changed_row = ""
for agg in all_agg_files
    dir = dirname(agg)
    info = read_strip(joinpath(dir, "timeline_info.csv"))
    data = read_strip(agg)

    # only report lines that are different from the last line
    if data != last_changed_row
        global last_changed_row = data
        push!(result, "$data,$info")
    end
end

dump(out_file, join(result, "\n") * "\n")
