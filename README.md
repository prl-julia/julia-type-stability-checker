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
