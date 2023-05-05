#
# Process a batch of Julia packages.
#
# Usage: Run with `julia --threads=<N> <path/to/julia-sts>/scripts/timeline/history.jl <out_dir> <pkgs>`
#        It's recommended to run this using the timeline/batch.jl script but can also be run manually
# Effect: runs the type stability checks on the given packages and stores the output in out_dir, each package in a separate subdirectory
#
# Details:
#  1. this script expects the packages to all be from the same repo
#  2. clones the package repo into a fresh tmp directory
#  3. lists all the commits on the main branch (ignores commits of merged feature branches)
#     also shuffles the commits, so that each thread processes a random sample of them (this ensures that the work is distributed more uniformly, eg. when the first 100 commits don't even have Project.toml, the thread that gets them would be done immediately and then just wait)
#  4. all commits are processed by a parallel for loop
#      in each iteration, the thread makes its own fresh copy of the cloned repo
#      it checks out the desired commit and gathers some info about it
#      then it looks for Project.toml and parses it
#      if successful, it runs the process-package.jl script on this revision of the project
#      there is also a shared error log for the package saved in the out_dir/timeline_error_log.txt (the line number of the error is reported for reference)
#  5. prints some stats and ends
#

out_dir = length(ARGS) > 0 ? joinpath(pwd(), ARGS[1]) : error("Requires argument: output directory")
pkgs = length(ARGS) > 1 ? ARGS[2:end] : error("Requires arguments: at least one package name")

include("utils.jl")

PROCESS_PACKAGE = joinpath(STS_PATH, "scripts/timeline/process-package.jl")

using Base.Threads
using Random
using TOML

#
# Check the packages information
#
# First, make sure that all the packages come from the same repository.
# Second, filter duplicates (eg. when a package is renamed). This uses a heuristic:
# We want a single package name for every Project.toml (or, for each subdir).
# Thus for the first time we see a subdir, we remember the given package,
# however the next time, we also overwrite the remembered package if the new name
# appears in the repo url.
# This is intended to get the up-to-date name, for example, there are packages "Jusdl" and "Casual"
# both pointing to the root of repo "https://github.com/zekeriyasari/Causal.jl.git"
# We want to only process one of them, namely "Causal"
#
repo = nothing
subdirs = Dict()
for pkg in pkgs
    info = pkg_info(pkg)

    if isnothing(repo)
        global repo = info.repo
    elseif repo != info.repo
        @info_extra "Expected all packages to be from `$repo' but `$pkg' comes from `$(info.repo)'"
        exit(1)
    end

    subdir = isnothing(info.subdir) ? "" : info.subdir
    if !haskey(subdirs, subdir) || occursin(pkg, repo)
        subdirs[subdir] = pkg
    end
end

dump(joinpath(out_dir, repo_to_filename(repo) * "_pkgs.txt"), "Repository: $repo\n$(join([s == "" ? "  Package $p" : "  Package $p in $s" for (s, p) in subdirs], "\n"))\n")

cloned = mktempdir()
exec(`git clone $repo $cloned`)
# Here we can change which commits are processed... E.g. now we only look at
# the linear main branch, not merged feature branches (the merge commits
# are still processed though)
commits = collect(enumerate(reverse(split(strip(exec(`git -C $cloned rev-list --abbrev-commit --first-parent HEAD`))))))
commits = shuffle(commits)  # ensure the init commits before Project.toml are distributed ~equally
n = length(commits)
@info_extra "Checking $n commits"

# bookkeeping
tasks = zeros(Int, nthreads()) # how many tasks each thread processed
skipped = 0
last_progress_report = 0
PROGRESS_FREQ_SEC = 30
TIMEOUT_SEC = 60 * 30  # task timeout, send SIGTERM after TIMEOUT_SEC, then SIGKILL after 60 more sec
START = time()

git_lock = ReentrantLock()  # using `git -C` still seems not to be thread-safe
progress_lock = ReentrantLock()
skipped_lock = ReentrantLock()
error_log_lock = ReentrantLock()

@sync @threads for (i, commit) in commits
    me = threadid()

    _, t = @timed begin
        # create my own fresh copy of the repo
        repo_dir = tempname()
        exec(`cp -r $cloned $repo_dir`)

        msg = ""
        when = ""
        lock(git_lock) do
            exec(`git -C $repo_dir checkout --quiet $commit`)
            msg = exec(`git -C $repo_dir log --pretty=format:'%s' --max-count=1 HEAD`)
            when = exec(`git -C $repo_dir log --pretty=format:'%ad' --max-count=1 --date=iso HEAD`)
        end

        for (subdir, pkg) in subdirs

            # report progress (at most) every PROGRESS_FREQ_SEC
            lock(progress_lock) do
                now = time()
                if now - last_progress_report > PROGRESS_FREQ_SEC
                    global last_progress_report = now
                    done = sum(tasks) + skipped
                    total = n * length(subdirs)
                    frac = done / total
                    elapsed = now - START
                    est = elapsed / frac - elapsed
                    @info_extra "Progress: $(round(frac * 100, digits=2))% ($(done - skipped) tasks done, $skipped skipped, elapsed $(pretty_duration(elapsed)), est. remaining $(pretty_duration(est)))"
                end
            end

            project_dir = joinpath(repo_dir, subdir)
            commit_out_dir = joinpath(out_dir, pkg, "$(lpad(i, 6, '0'))-$commit")

            # try parsing the Project.toml, if not found or invalid, skip this commit for this package
            project = try
                TOML.parsefile(joinpath(project_dir, "Project.toml"))
            catch
                @info_extra "Thread #$me, commit #$i ($commit), pkg $pkg: skipping (can't parse Project.toml)"
                lock(skipped_lock) do
                    global skipped += 1
                end
                continue
            end

            tasks[me] += 1
            pkg_name = get(project, "name", "??")
            version = get(project, "version", "0.0.0")
            @info_extra "Thread #$me, commit #$i ($commit), pkg $pkg: processing $pkg_name@$version"
            then = time()

            # write some metadata for the aggregation script
            csv_info = join([csv_quote(s) for s in ["$pkg_name@$version", commit, msg, when]], ",")
            dump(joinpath(commit_out_dir, "timeline_info.csv"), csv_info)

            # run the stability checks
            try
                # Timeout if the checking takes too long..
                # Also send SIGKILL if the process hangs (noticed that sometimes there's a deadlock?)
                exec(`timeout -k 60 $TIMEOUT_SEC julia $PROCESS_PACKAGE $pkg_name $project_dir $commit_out_dir`)
            catch e
                lock(error_log_lock) do
                    p = joinpath(out_dir, "timeline_error_log.txt")
                    # we report the line where this report is in the error log for easier navigation
                    line = 1 + (
                        try
                            countlines(p)
                        catch
                            0
                        end
                    )
                    @info_extra "Thread #$me, commit #$i ($commit), pkg $pkg: failed, please check log $p:$line"
                    open(p, "a") do f
                        write(f, "======== Thread #$me, commit #$i ($commit), pkg $pkg ========\n")
                        showerror(f, e)
                        flush(f)
                    end
                end
            end
            now = time()
            @info_extra "Thread #$me, commit #$i ($commit), pkg $pkg: done with $pkg_name@$version after $(pretty_duration(now - then))"
        end

        rm(repo_dir, recursive=true)
    end

    @info_extra "Thread #$me, commit #$i ($commit): done in $(pretty_duration(t))"
end
rm(cloned, recursive=true)

# show the work distribution among threads - should be close to uniform
@info_extra "Work distribution: $tasks"
