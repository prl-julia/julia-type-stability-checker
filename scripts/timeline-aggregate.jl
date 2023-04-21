#
# Aggregate data collected by the timeline.jl script for a given package
#
# Usage: Run with `julia <path/to/julia-sts>/scripts/timeline-aggregate.jl <in_dir> <out_file>`
# Effect: Writes the summary csv in the out_file
#

in_dir = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: input directory")
out_file = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: output file")

function exec(cmd::Cmd)
    out = IOBuffer()
    err = IOBuffer()
    run(pipeline(cmd, stdout=out, stderr=err))
    strip(String(take!(out)) * String(take!(err)))
end

all_agg_files = sort(split(exec(`find $in_dir -maxdepth 2 -name "*-agg.txt"`), "\n"))

if length(all_agg_files) == 0 || (length(all_agg_files) == 1 && first(all_agg_files) == "")
    @info "No aggregate files found..."
    exit(0)
end

result = ["Commit,Message,Date,Version,Module,Methods,Stable,Partial,Unstable,Any,Vararg,Generic,TcFail,NoFuel"]
last_changed_row = ""
for agg in all_agg_files
    dir = dirname(agg)
    commit = strip(read(joinpath(dir, "timeline_commit.txt"), String))
    msg = strip(read(joinpath(dir, "timeline_msg.txt"), String))
    when = strip(read(joinpath(dir, "timeline_when.txt"), String))
    version = strip(read(joinpath(dir, "timeline_version.txt"), String))
    # pkg = strip(read(joinpath(dir, "timeline_pkg.txt"), String))

    # csv excapes
    msg = replace(msg, '"' => "\"\"")

    data = strip(read(agg, String))
    # only report lines that are different from the last line
    if data != last_changed_row
        global last_changed_row = data
        push!(result, "$commit,\"$msg\",$when,$version,$data")
    end
end

@info "Writing to `$out_file'"
open(out_file, "w") do f
    write(f, join(result, "\n"))
    write(f, "\n")
end
