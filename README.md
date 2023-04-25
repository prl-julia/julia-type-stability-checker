# Type Stability in Julia — Statically

This project explores how far we can get with simple enumeration of all possible
instantions of method signature to determine its _[type stability][st-def]_.

[st-def]: https://docs.julialang.org/en/v1/manual/faq/#man-type-stability

## Batch-Package Checking

Main script: `$JULIA-STS/scripts/loop-over-packages.sh`. The list of packages is
hardcoded as of now (TODO: should be a parameter).

No assumptions other than Julia and internet connectivity (to download
packages) available.

Preferably in a fresh directory, run this:

``` shellsession
❯ $JULIA-STS/scripts/loop-over-packages.sh
...
❯ $JULIA-STS/scripts/aggregate.sh
...
```

This should create one `csv` and one `txt` file per package on the list, and the
aggregate script collects data from the `txt`'s to an `aggregate.csv` file.

## Whole-Package Checking

Main script: `$JULIA-STS/scripts/process-package.jl`. It also works as one
iteration of the loop in the batch-package approach above.

No assumptions other than Julia and internet connectivity (to download
packages) available.

Preferably in a fresh directory, run this:

``` shellsession
❯ julia "$JULIA_STS/scripts/process-package.jl" Multisets
...
❯ ls *.csv *.txt
Multisets-agg.txt  Multisets.csv
❯ $JULIA_STS/scripts/aggregate.sh
...
❯ ls *.csv
aggregate.csv  Multisets.csv
```

## Whole-Module Checking

Process a module (check stability of all of its methods) in a Julia session:

``` julia
checkModule(MyModule)
```

- Assumes: `MyModule` is loaded.
- Effects: in the current directory creates:
  - `MyModule.csv` with raw results of analysis;
  - `MyModule-agg.txt` with aggregate stats (possibly, for further analysis).

A (possibly empty) set of `agg`-files can be turned into a single CSV via calling
`scripts/aggregate.sh`. For just one file, it only adds the heading. The result
is written in `aggregate.csv`.

## Per-method Checking

See examples in the `tests` directory.

## Package History Checking

There is a suite of scripts to examine the git history of packages 
and report how the stability of methods changed over time. 
These are located in `$JULIA-STS/scripts/timeline`:

- `batch.jl`: The main script, this is where all the packages to check are listed.
- `history.jl`: Takes care of git management (clones the package, checks out individual commits). Also the only part that's using multiple threads to speed up the processing.
- `process-package.jl`: Runs the stability checks for a given package for a given revision (a slightly modified version of `scripts/process-package.jl`).
- `aggregate.jl`: Creates a CSV summary of all the processed revisions of a package.
- `filter.jl`: Tries to filter the interesting stability cases with a heuristic.

These scripts assume the following packages: `CSV` and `DataFrames` (for filtering), `TOML` (for history to parse `Project.toml`s), `Plots` and `UnicodePlots` (for history to report balancing stats, can be deleted)

For example, to check the `Multisets` package using 8 threads, first modify the `batch.jl` 
script to list the package name and github repo:

```
packages = [
    ("Multisets", "https://github.com/scheinerman/Multisets.jl.git"),
]
```

Then `cd $JULIA-STS` and run

```
julia --threads=8 scripts/timeline/batch.jl \
    /tmp/scratch \
    /tmp/timeline \
    &> /tmp/timeline_log
```

To watch the progress, you can `tail -f --retry /tmp/timeline_log`.

This will write the intermediate files to `/tmp/scratch` (a subdirectory for the `Multisets` 
package that contains a subdirectory for each processed commit and an error log 
`timeline_error_log.txt`).

The output files (`Multisets.csv` and `Multisets-filtered.csv`) are written to 
`/tmp/timeline`.

The log should contain something like the following:

```bash
$ cat /tmp/timeline_log
[ Info: == Using 8 threads ==
[ Info: === Checking `Multisets' ===
[ Info: Checking 65 commits
[ Info: Progress: 0.0% (0 tasks done, 0 skipped)
[ Info: Thread #8 commit #32 (1d14ba5): skipping (can't parse Project.toml)
[ Info: Thread #8 commit #32 (1d14ba5): done in 0.18s
[ Info: Thread #6 commit #53 (90ae494): processing Multisets@0.3.5
...
[ Info: Thread #6 commit #53 (90ae494): done in 11.66s
...
[ Info: Progress: 44.44% (16 tasks done, 29 skipped)
...
[ Info: Thread #3 commit #54 (a26cbf1): done in 10.95s
[ Info: Work distribution: [2, 3, 6, 2, 2, 4, 0, 3]
         ⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀# Tasks per thread⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀   
         ┌────────────────────────────────────────┐   
       7 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│ y1
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⣀⣀⚬⣀⣀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│ y1
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡤⠤⚬⠤⢤⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
         │⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
   Tasks │⠀⠀⠀⡤⠤⚬⠤⢤⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢠⠤⚬│   
         │⠀⠀⠀⡇⠀⠀⠀⢸⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢸⠀⠀│   
         │⚬⠒⡆⡇⠀⠀⠀⢸⠀⡇⠀⠀⠀⢸⢰⠒⠒⚬⠒⡆⢰⠒⚬⠒⠒⡆⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢸⠀⠀│   
         │⠀⠀⡇⡇⠀⠀⠀⢸⠀⡇⠀⠀⠀⢸⢸⠀⠀⠀⠀⡇⢸⠀⠀⠀⠀⡇⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢸⠀⠀│   
         │⠀⠀⡇⡇⠀⠀⠀⢸⠀⡇⠀⠀⠀⢸⢸⠀⠀⠀⠀⡇⢸⠀⠀⠀⠀⡇⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢸⠀⠀│   
         │⠀⠀⡇⡇⠀⠀⠀⢸⠀⡇⠀⠀⠀⢸⢸⠀⠀⠀⠀⡇⢸⠀⠀⠀⠀⡇⡇⠀⠀⠀⢸⠀⠀⠀⠀⠀⠀⢸⠀⠀│   
         │⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⠉⚬⠉⠉⠉⠉⠉│   
      -1 │⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀│   
         └────────────────────────────────────────┘   
         ⠀1⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀Thread⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀⠀8⠀   
[ Info: === Aggregating results for `Multisets' ===
[ Info: Writing to `/tmp/timeline/Multisets.csv'
[ Info: Writing to `/tmp/timeline/Multisets-filtered.csv'
[ Info: === Done with Multisets in 1.754m
```
