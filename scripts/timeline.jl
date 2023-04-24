#
# Process a batch of Julia packages.
#
# Usage: Run with `julia --threads=<N> <path/to/julia-sts>/scripts/timeline.jl <github_repo> <out_dir>`
#        It's recommended to run this using the timeline-batch.jl script but can also be run manually
# Effect: runs the type stability checks on the given package and stores the output in out_dir
#
# Details:
#  1. clones the package repo into a fresh tmp directory
#  2. lists all the commits on the main branch (ignores commits of merged feature branches)
#     also shuffles the commits, so that each thread processes a random sample of them (this ensures that the work is distributed more uniformly, eg. when the first 100 commits don't even have Project.toml, the thread that gets them would be done immediately and then just wait)
#  3. all commits are processed by a parallel for loop
#      in each iteration, the thread makes its own fresh copy of the cloned repo
#      it checks out the desired commit and gathers some info about it
#      then it looks for Project.toml and parses it
#      if successful, it runs the process-package.jl script on this revision of the project
#      there is also a shared error log for the package saved in the out_dir/timeline_error_log.txt (the line number of the error is reported for reference)
#  4. prints some stats and end
#

using Base.Threads
using Random
using TOML

repo = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: repository of the package")
out_dir = length(ARGS) > 1 ? joinpath(pwd(), ARGS[2]) : error("Requires argument: output directory")

sts_path = dirname(@__DIR__)

# Run cmd (runs in a new process) and capture stdout and stderr.
# On errors, reformats the exception and rethrows. Otherwise returns the concatenation of stdout and stderr
function exec(cmd::Cmd)
    out = IOBuffer()
    err = IOBuffer()
    try
        run(pipeline(cmd, stdout=out, stderr=err))
    catch e
        rethrow(ErrorException("Error executing $cmd: $e\nstdout:\n$(String(take!(out)))\nstderr:\n$(String(take!(err)))\n"))
    end
    strip(String(take!(out)) * String(take!(err)))
end

# Utility to flush output when logging
function info(s::String)
    @info s
    flush(stdout)
    flush(stderr)
end

cloned = mktempdir()
exec(`git clone $repo $cloned`)
# Here we can change which commits are processed... E.g. now we only look at
# the linear main branch, not merged feature branches (the merge commits
# are still processed though)
commits = collect(enumerate(reverse(split(strip(exec(`git -C $cloned rev-list --abbrev-commit --first-parent HEAD`))))))
commits = shuffle(commits)  # ensure the init commits before Project.toml are distributed ~equally
n = length(commits)
skipped = 0
info("Checking $n commits")

# bookkeeping, track how many commits each thread processed
tasks = zeros(Int, nthreads())

# if the tool takes over an hour, kill it
timeout = 60 * 60 * 1  # 1 hour in seconds

git_lock = ReentrantLock()  # using `git -C` still seems not to be thread-safe
skipped_lock = ReentrantLock()
error_log_lock = ReentrantLock()

@sync @threads for (i, commit) in commits
    me = threadid()

    if me == 1
        info("Progress: $(round(sum(tasks) / (n - skipped) * 100, digits=2))% ($(sum(tasks)) tasks done, $skipped skipped)")
    end

    dir = tempname()

    _, t = @timed begin
        msg = ""
        when = ""

        # create my own fresh copy of the repo
        exec(`cp -r $cloned $dir`)
        lock(git_lock) do
            exec(`git -C $dir checkout --quiet $commit`)
            msg = exec(`git -C $dir log --pretty=format:'%s' --max-count=1 HEAD`)
            when = exec(`git -C $dir log --pretty=format:'%ad' --max-count=1 --date=iso HEAD`)
        end

        # if the revision doesn't have Project.toml or it's invalid, skip
        ok = true
        project = try
            TOML.parsefile(joinpath(dir, "Project.toml"))
        catch
            info("Thread #$me commit #$i ($commit): skipping (can't parse Project.toml)")
            lock(skipped_lock) do
                global skipped += 1
            end
            ok = false
        end

        if ok
            tasks[me] += 1
            pkg_name = get(project, "name", "")
            version = get(project, "version", "0.0.0")
            info("Thread #$me commit #$i ($commit): processing $pkg_name@$version")

            # write some metadata for the aggregation script
            o = mkpath(joinpath(out_dir, "$(lpad(i, 5, '0'))-$commit"))
            open(joinpath(o, "timeline_commit.txt"), "w") do f
                write(f, commit)
            end
            open(joinpath(o, "timeline_msg.txt"), "w") do f
                write(f, msg)
            end
            open(joinpath(o, "timeline_when.txt"), "w") do f
                write(f, when)
            end
            open(joinpath(o, "timeline_version.txt"), "w") do f
                write(f, version)
            end
            open(joinpath(o, "timeline_pkg.txt"), "w") do f
                write(f, pkg_name)
            end

            # run the stability checks
            try
                exec(`timeout $timeout julia $sts_path/scripts/timeline-process-package.jl $pkg_name $dir $o`)
            catch e
                lock(error_log_lock) do
                    p = joinpath(out_dir, "timeline_error_log.txt")
                    # we report the line where this report is in the error log for easier navigation
                    line = if isfile(p)
                        try
                            "$(parse(Int, strip(read(pipeline(`cat $p`, stdout=`wc -l`, stderr=devnull), String))) + 1)"
                        catch _
                            "?"
                        end
                    else
                        "1"
                    end
                    info("Thread #$me commit #$i ($commit): failed, please check log $p:$line")
                    open(p, "a") do f
                        write(f, "======== Thread #$me commit #$i ($commit) ========\n")
                        showerror(f, e)
                    end
                end
            end
        end
    end
    rm(dir, recursive=true)

    # pretty time logging
    t, unit = t, "s"
    if t > 60
        t /= 60
        unit = "m"
    end
    if t > 60
        t /= 60
        unit = "h"
    end
    info("Thread #$me commit #$i ($commit): done in $(round(t, digits=2))$unit")
end

# show a plot of the work distribution among threads
info("Work distribution: $tasks")
using Plots
using UnicodePlots
unicodeplots()
b = bar(tasks,
        xlabel="Thread",
        ylabel="Tasks",
        title="# Tasks per thread",
        xlims=(1, length(tasks)),
        ylims=(minimum(tasks) - 1, maximum(tasks) + 1),
        xticks=(1:length(tasks)),
        yticks=((minimum(tasks)-1):(maximum(tasks)+1)),
        show_legend=false)
show(b)
println()
