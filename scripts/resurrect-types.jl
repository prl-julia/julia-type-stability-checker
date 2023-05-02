#
# WARNING: This file does Pkg.add. Run it in a private depot to not pollute the default one.
# E.g.:
#   ❯ JULIA_PROJECT=~/s/sts/repo/scripts JULIA_DEPOT_PATH=. julia ~/s/sts/repo/scripts/resurrect-types.jl
#
# Input:
#   - intypesCsvFile with info about Julia types as dumped by
#       github.com/prl-julia/julia-type-stability/blob/main/Stability/scripts/julia/merge-intypes.jl
#
# Effects:
#   Load all the types from the file into the current Julia session.
#
# So far, it's a testing poligon for something that can become a part of StabilityCheck.
# The idea is that when we can't enumerate everything, we sample from these types.
#

intypesCsvFile = "merged-intypes.csv"

@info "Starting resurrect.jl. Using packages..."

using CSV, Pkg, DataFrames #, Query

@info "... done."

#
# Aux utils
#
evalp(s::String) = eval(Meta.parse(s))

# Parsing namepaths (things of a form Mod.Submod.Type)
parts(ty) = split(ty,".")
unqualified_type(ty) = string(last(parts(ty)))
root_module(ty) = string(first(parts(ty)))

"""
guess_package: (tyrow : {modl, tyname, occurs}) -> String

Try to guess name of a package we need to add, in order to be able to
use the given type.

Algorithm:
- if tyRow.tyanme has a dot, then it's a fully-qualified type name, and we try the "root"
  module of the namepath (M.N.T -> M)
- otherwise try tyRow.modl -- the module we've been processing when saw the type.
"""
guess_package(tyRow) = begin
    '.' in tyRow.tyname && return root_module(tyRow.tyname)
    tyRow.modl
end

"""
addpackage: String -> IO ()

The function tries to update the current environment in a way that it's possible to
`Core.eval(tyrow.modl, tyrow.tyname)`.
"""
addpackage(pkg::String) = begin

    pkg in ["Core", "Base"] && return true # stdlib-modules don't need anything

    try
        @info "Activate a separate environment to add a package"
        Pkg.activate("envs/$pkg";io=devnull)
        @info "Try to Pkg.add package $(pkg) (may take some time)... "
        Pkg.add(pkg;io=devnull)
        @info "... done"
    catch err
        @warn "Couldn't add package for type $(pkg.tyname) (module: $(pkg.modl))"
        errio=stderr
        showerror(errio, err)
        println(errio)
        exit(1)
        # return false
    end

    return true
end

#######################################################################################
#
# Entry point
#
main() = begin
    @info "Reading in data..."
    intypesCsv = CSV.read(intypesCsvFile, DataFrame)
    @info "... done."

    failed=[]
    i=0
    fi=0
    gi=0
    ei=0
    for tyRow in eachrow(intypesCsv)
        i+=1
        @info "[$i] Processing: $(tyRow.tyname) from $(tyRow.modl)..."

        # Special cases (skip for now):
        # - function types
        startswith(tyRow.tyname, "typeof") && (fi += 1; (@info "Special case: function type. Pass."); continue)
        # - generic types
        # '{' in tyRow.tyname && (gi += 1; (@info "Special case: generic type. Pass."); continue)

        pkg=guess_package(tyRow)
        @info "Guessed package: $pkg"
        if addpackage(pkg)
            try
                @info "using the module $pkg"
                evalp("using $pkg")
                m = evalp(tyRow.modl)
                ty = Core.eval(m, unqualified_type(tyRow.tyname))
            catch err
                ei += 1
                @warn "Unexpected failure when using the module or type" #. Continue."
                exit(1)
            end
        else
            push!(failed, (tyRow.tyname, tyRow.modl))
            ei += 1
        end
    end
    @show (i,fi,gi,ei,failed)
end

main()
