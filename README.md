# Type Stability in Julia — Statically

[![Build Status](https://github.com/ulysses4ever/julia-sts/actions/workflows/ci.yml/badge.svg)](https://github.com/ulysses4ever/julia-sts/actions/workflows/ci.yml?query=branch%3Amain)
[![codecov](https://codecov.io/gh/ulysses4ever/julia-sts/branch/main/graph/badge.svg?label=codecov)](https://codecov.io/gh/ulysses4ever/julia-sts)

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

## Types Database

Normally, we don't check methods with `Any` in the parameters types
because there is no sensible way to enumerate subtypes of `Any` without
any additional knowledge. One way we can get around it is to collect
a set of types and test only enumerate that set every time we see
an `Any`-parameter. That's what the “types database” idea about.

The implementation with further comments in the source code lives in
[src/typesDB.jl](src/typesDB.jl) (you may be interested in the format of the
database). A simple example of how to use it is shown in the test suite:

```
juila> f(x)=1
juila> typesdb_cfg = build_typesdb_scfg("merged-small.csv")
juila> is_stable_method((@which f(1)), typesdb_cfg)
Stb(2)
```

The testing database in `"merged-small.csv"` is really small.
For a realistic example of a database with 10K types collected from
tracing test suites of popular Julia packages, refer to the `types-database`
directory in the [`julia-sts-data`][julia-sts-data] repository.

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

These scripts assume packages `DataStructures` (for `OrderedDict`), `CSV`, `DataFrames`, `Plots` (for filtering and plotting). Please make sure they are installed:

```julia
using Pkg; Pkg.add(["DataStructures", "CSV", "DataFrames", "Plots"])
```

### Results

The pipeline produces several outputs (in addition to the regular output of the stability checker):

- `<PKG_NAME>/<IDX>-<COMMIT_HASH>/timeline_info.csv`: stores some metadata that is used during aggregation
- `<PKG_NAME>.csv`: contains information about individual commits (from `<PKG>-agg.txt`), filtering duplicate lines (i.e., only commits that cause changes)
- `<PKG_NAME>-filtered.csv`: further filters the results to only commits that don't change the number of methods but introduce/remove unstable ones
- `<PKG_NAME>.pdf`: shows three plots (if we have enough data) - the absolute number of unstable methods, the rate of stable methods to all methods, and the rate of unstable methods to all methods (the `x` axis for all of these is the number of a commit as it appears in `<PKG_NAME>.csv` - i.e., two consecutive points are not necessarily consecutive commits as there can be commits in between that don't change stability)
- `https___github_com_<PKG_REPO>_git_pkgs.txt`: records the repository url, as well as a list of all packages in that repository and their respective subdirectories
- `timeline_error_log.txt`: records stdout and strerr for failed runs, common for all packages (the normal log contains line numbers within this file for easier navigation)
- `finished.txt`: lists completed packages, these are skipped when the pipeline is restarted

### Example

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

If there are errors, the log will mention the file and line number to look at to see the details, such as:

```
[ Info: ...: failed, please check log /tmp/scratch/timeline_error_log.txt:2795580
```

Stdout and stderr of the failed commit can then be seen for instance with (mind the `+` before the line number):

```bash
tail -n +2795580 /tmp/scratch/timeline_error_log.txt | less
```

## Sharing Results

The results of the scripts are stored in the [`julia-sts-data`][julia-sts-data]
repository instead of this one.

[julia-sts-data]: https://github.com/ulysses4ever/julia-sts-data
