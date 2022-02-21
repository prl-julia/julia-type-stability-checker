# Type Stability in Julia — Statically

This project explores how far we can get with simple enumeration of all possible
instantions of method signature to determine its [type stability][st-def].

[st-def]: https://docs.julialang.org/en/v1/manual/faq/#man-type-stability

## Getting Started

Process a module (check stability of all of its methods):

``` julia
checkModule(MyModule)
```

Assumes: `MyModule` is loaded. Effect: creates a `MyModule.csv` in the current
directory with results of analysis.
