# Type Stability in Julia — Statically

This project explores how far we can get with simple enumeration of all possible
instantions of method signature to determine its [type stability][st-def].

[st-def]: https://docs.julialang.org/en/v1/manual/faq/#man-type-stability

## Getting Started

Process a module (check stability of all of its methods):

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

