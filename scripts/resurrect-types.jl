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
evalp(s::AbstractString) = eval(Meta.parse(s))
is_builtin_module(mod::AbstractString) = mod in ["Core", "Base"]

# Parsing namepaths (things of a form Mod.Submod.Type)
parts(ty) = split(ty,".")
unqualified_type(ty) = string(last(parts(ty)))
root_module(ty) = string(first(parts(ty)))

#
# Main utilities
#

"""
guess_package: (tyrow : {modl, tyname, occurs}) -> String

Try to guess name of a package we need to add, in order to be able to
use the given type.

Algorithm:
- if tyRow.tyname has a dot, then it's a fully-qualified type name, and we try the "root"
  module of the namepath (M.N.T -> M),
- otherwise try tyRow.modl -- the module we've been processing when saw the type.
"""
guess_package(tyRow) = begin
    head = chopsuffix(tyRow.tyname, r"\{.*") # head of a parametric type
    '.' in head && return root_module(head)
    root_module(tyRow.modl)
end

"""
addpackage: String -> IO ()

The function tries to add a package with the given name in a separate environment.
"""
addpackage(pkg::AbstractString) = begin

    is_builtin_module(pkg) && return true # stdlib-modules don't need anything

    try
        @info "Activate a separate environment to add a package"
        Pkg.activate("envs/$pkg";io=devnull)
        @info "Try to Pkg.add package '$(pkg)' (may take some time)... "
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
    i=0  # count types processed
    # Special case counters
    fi=0 # count function types
    mi=0 # count types defined in the "Main" module
    ei=0 # count failure to eval types

    for tyRow in eachrow(intypesCsv)
        i+=1
        @info "[$i] Processing: $(tyRow.tyname) from $(tyRow.modl)..."

        # Special case: function types. Skip for now:
        startswith(tyRow.tyname, "typeof") && (fi += 1; (@info "Special case: function type. Skip."); continue)

        # Special case: sometimes our own methods (Stability) get in the way. Skip.
        tyRow.modl == "Stability" && continue;

        pkg=guess_package(tyRow)
        @info "Guessed package: $pkg"

        # Special case: 'Main' module.
        # Some tests define types, and usually they end up in the 'Main' module.
        # We don't try to resurrect those because it's not easy to eval a test
        # module in the current environment (tests run in a sandbox).
        if pkg == "Main"
            @info "A type defined within test suite found (module 'Main'). Skip."
            mi+=1
            continue
        end

        if addpackage(pkg)
            try
                if ! is_builtin_module(pkg)
                    @info "Using the module $pkg"
                    evalp("using $pkg")
                    @info "Evaluating the module..."
                    m = evalp(pkg)
                    @info "... and the type"
                    ty = Core.eval(m, unqualified_type(tyRow.tyname))
                else
                    @info "Builtin module. Evaluating the type in global scope"
                    ty = eval(unqualified_type(tyRow.tyname))
                end
            catch err
                ei += 1
                @error "Unexpected failure when using the module or type"
                showerror(stderr, err, stacktrace(catch_backtrace()))
                println(stderr)
                exit(1)
            end
        else
            push!(failed, (tyRow.tyname, tyRow.modl))
            ei += 1
        end
    end
    @show (i,fi,mi,ei,failed)
end

main()
