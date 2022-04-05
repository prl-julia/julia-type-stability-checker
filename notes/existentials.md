# Handling Existentials

Tricky case for simple enumeration. Here's what can go wrong:

- unbounded variable (impossible to enumerate)
- too big to enumerate (the bound is not tight enough)

To have the procedure run in reasonable time we add the following search parameters:

- scfg.skip_unionalls if the user allows to skip all of them
- TODO: the number of instantiations of one variable should probably be bounded
  too; note: there are already similar fuel-like search parameters, e.g.
  - `scfg.fuel` for total number of concrete types to check, and
  - `scfg.max_lattice_steps` for number of steps to take to reach a concrete type.

We land on three special cases that need to be reflected in the report:

- unbounded variable 
- `skip`ed existential (due to the flag)
- `fuel` parameter maxed out

## Implementation Notes

- Distinguishing any of the three cases only makes sense for methods that were deemed stable
(I think?). So, we add a field to the `Stb` type.

- This additional data needs to be reported somehow. Probably, there should be
  an extra `.csv`-file with only stable methods. The file will show the
  existential types. As long as types can have commas in them, we may be better
  off with `.tsv` instead.

- First prototype of idea what is discussed here will not distinguish the three
  cases and will only report `skipped exists: <list>`.

# Past Attempts

At one point we had this to represent possible answers to the question of how to
deal with a type w.r.t. existentials:

```julia
# UnionAll's require care. Below is a hierarchy of cases that we support today.
abstract type UnionAllCheck end
struct NotUnionAll end
struct UnboundedUnionAll end
struct BoundedUnionAll
    instantiatiations :: Vector{JlType} # TODO: change to Channel
end

function check_unionall(t, scfg :: SearchCfg) :: UnionAllCheck
    print(t, scfg)
end
check_unionall(::Any, ::SearchCfg) = NotUnionAll()
check_unionall(u::UnionAll, scfg :: SearchCfg) =
    if u.var.ub == Any
        UnboundedUnionAll()
    else
        BoundedUnionAll(subtype_unionall(u, scfg))
    end

```

Turned out to be not flexible enough, because we check for "bad cases" earlier
than we actually want the instantiations in the good case (the last case in the
hierarchy).
