# Type Stability in Julia — Statically

This project explores how far we can get with simple enumeration of all possible
instantions of method signature to determine its _[type stability][st-def]_.

[st-def]: https://docs.julialang.org/en/v1/manual/faq/#man-type-stability

## Batch-Package Checking

Main script: `$JULIA_STS/scripts/loop-over-packages.sh`. The list of packages is
hardcoded as of now (TODO: should be a parameter).

No assumptions other than Julia and internet connectivity (to download
packages) available.

Preferably in a fresh directory, run this:

``` shellsession
❯ $JULIA_STS/scripts/loop-over-packages.sh
...
❯ $JULIA_STS/scripts/aggregate.sh
...
```

This should create one `csv` and one `txt` file per package on the list, and the
aggregate script collects data from the `txt`'s to an `aggregate.csv` file.

## Whole-Package Checking

Main script: `$JULIA_STS/scripts/process-package.jl`. It also works as one
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
These are located in `$JULIA_STS/scripts/timeline`:

- `batch.jl`: The main script which reads the list of packages from a file and calls the other scripts for each.
- `history.jl`: Takes care of git management (clones the package, checks out individual commits). Also the only part that's using multiple threads to speed up the processing.
- `process-package.jl`: Runs the stability checks for a given package for a given revision (a slightly modified version of `scripts/process-package.jl`).
- `aggregate.jl`: Creates a CSV summary of all the processed revisions of a package.
- `filter.jl`: Tries to filter the interesting stability cases with a heuristic.
- `plot.jl`: Creates a pdf plot that shows for each commit the number of unstable methods, as well as the rate of stable and unstable methods to all methods.

These scripts assume packages `CSV`, `DataFrames`, `Plots` (for filtering and plotting).

For example, to check the `Multisets` package using 8 threads, create a text file with the package name (in general, this file should contain one package name per line):

```
echo "Multisets" > /tmp/packages
```

Then run the `batch.jl` script:

```bash
julia --threads=8 $JULIA_STS/scripts/timeline/batch.jl \
    /tmp/packages \
    /tmp/scratch \
    /tmp/timeline \
    &> /tmp/timeline_log
```

To watch the progress, you can `tail -f --retry /tmp/timeline_log`.

This will write the intermediate files to `/tmp/scratch` (a subdirectory for the `Multisets` 
package that contains a subdirectory for each processed commit and an error log 
`timeline_error_log.txt`).

The output files (`Multisets.csv`, `Multisets-filtered.csv`, `Multisets.pdf`) are written to 
`/tmp/timeline`.

The log should contain something like the following:

```bash
$ cat /tmp/timeline_log
[ Info: [2023-05-05T15:37:31.995] == Using 8 threads ==
[ Info: [2023-05-05T15:37:32.651] === Checking `https://github.com/scheinerman/Multisets.jl.git' ===
[ Info: [2023-05-05T15:37:33.762] Writing to `/tmp/scratch/https___github_com_scheinerman_Multisets_jl_git_pkgs.txt'
[ Info: [2023-05-05T15:37:34.518] Checking 65 commits
[ Info: [2023-05-05T15:37:35.261] Progress: 0.0% (0 tasks done, 0 skipped, elapsed 0.72 s, est. remaining Inf d)
[ Info: [2023-05-05T15:37:35.270] Thread #5, commit #6 (c878909), pkg Multisets: skipping (can't parse Project.toml)
...
[ Info: [2023-05-05T15:37:35.311] Thread #5, commit #6 (c878909): done in 0.27 s
[ Info: [2023-05-05T15:37:35.312] Thread #6, commit #51 (a1c89dc), pkg Multisets: processing Multisets@0.3.3
...
[ Info: [2023-05-05T15:37:35.400] Writing to `/tmp/scratch/Multisets/000051-a1c89dc/timeline_info.csv'
...
[ Info: [2023-05-05T15:37:52.898] Thread #6, commit #51 (a1c89dc), pkg Multisets: done with Multisets@0.3.3 after 17.59 s
[ Info: [2023-05-05T15:37:52.900] Thread #6, commit #51 (a1c89dc): done in 17.86 s
...
[ Info: [2023-05-05T15:38:14.835] Progress: 83.08% (18 tasks done, 36 skipped, elapsed 40.31 s, est. remaining 8.21 s)
...
[ Info: [2023-05-05T15:38:36.918] Work distribution: [1, 1, 3, 4, 5, 4, 2, 2]
[ Info: [2023-05-05T15:38:36.983] === Aggregating results for `Multisets' ===
[ Info: [2023-05-05T15:38:37.442] Writing to `/tmp/timeline/Multisets.csv'
[ Info: [2023-05-05T15:38:53.255] Writing to `/tmp/timeline/Multisets-filtered.csv'
[ Info: [2023-05-05T15:39:21.646] Writing to `/tmp/timeline/Multisets.pdf'
[ Info: [2023-05-05T15:39:27.181] === Done with https://github.com/scheinerman/Multisets.jl.git in 1.91 m
```

And the results can be found in:

```bash
$ ls /tmp/scratch/
https___github_com_scheinerman_Multisets_jl_git_pkgs.txt  Multisets
$ ls /tmp/scratch/Multisets/
000044-19f1220  000048-5291b2e  000052-c556e27  000056-dc50172  000060-b9e0cb9  000064-692a160
000045-09eb09c  000049-fab665c  000053-90ae494  000057-92b8a76  000061-0dd0d96  000065-fe08c9c
000046-89277a2  000050-d7bc545  000054-a26cbf1  000058-ea34a45  000062-30c9321
000047-257bbb9  000051-a1c89dc  000055-3db912f  000059-1970e9a  000063-e66d7df
$ ls /tmp/timeline
Multisets.csv  Multisets-filtered.csv  Multisets.pdf
```
