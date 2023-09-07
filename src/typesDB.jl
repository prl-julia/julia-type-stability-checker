
#
#    Load types database from a CSV File
#

#
# WARNING: This file does Pkg.add. Run it in a private depot to not pollute the default one.
# E.g.:
#   ❯ JULIA_PROJECT=~/s/sts/repo JULIA_DEPOT_PATH=./depot julia -L ~/s/sts/repo/src/typesDB.jl -e 'print(typesDB())'
# Note:
#   Using this approach, you usually need to instantiate the environment first
#   ❯ JULIA_PROJECT=~/s/sts/repo JULIA_DEPOT_PATH=./depot julia -e 'using Pkg; Pkg.instantiate()'
#
# Entry Point:
#   typesDB
#
# Input:
#   - intypesCsvFile with info about Julia types as dumped by
#       https://github.com/prl-julia/julia-type-stability/blob/main/Stability/scripts/julia/merge-intypes.jl
#
# Effects:
#   Load all the types from the file into the current Julia session.
#
# Relevance to StabilityCheck:
#   The idea is that when we can't enumerate everything, we sample from these types.
#

intypesCsvFileDefault = "/home/artem/research/julia-type-stability/sts/repo/test/merged-small.csv"


# @info "Starting typesDB.jl. Using packages..."

using CSV, Pkg, DataFrames

# @info "... done."

#
# Aux utils
#
evalp(s::AbstractString) = Core.eval(Main, Meta.parse(s))
is_builtin_module(mod::AbstractString) = mod in ["Core", "Base"]

tag = "[ STS-TYPESDB ]"
macro mydebug(msg)
    :( @debug (tag * " " * string($(esc(msg)))))
end


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
        @mydebug "Activate a separate environment to add a package"
        Pkg.activate("envs/$pkg";io=devnull)
        @mydebug "Try to Pkg.add package '$(pkg)' (may take some time)... "
        Pkg.add(pkg;io=devnull)
        @mydebug "... done"
    catch err
        @warn "$tag Couldn't add package for type $(pkg.tyname) (module: $(pkg.modl))"
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

#
# Returns a vector of Julia type objects created based on info
# from the given CSV file
#
# Side effects:
#
#   - Pkg.add packages that may store the types requested
#   - your environment switches to something else of form ./envs/<package-name>
#   - if any errors are noticed, create types-db-load-errors.csv
#
typesDB(inFile = intypesCsvFileDefault) = begin
    types=[]
    @mydebug "Reading in typesDB data..."
    intypesCsv = CSV.read(inFile, DataFrame)
    @mydebug "... done."

    failed=[]
    i=0  # count types processed
    # Special case counters
    fi=0 # count function types
    mi=0 # count types defined in the "Main" module
    ei=0 # count failure to eval types

    for tyRow in eachrow(intypesCsv)
        i+=1
        @mydebug "[$i] Processing: $(tyRow.tyname) from $(tyRow.modl)..."

        # Special case: function types. Skip for now:
        startswith(tyRow.tyname, "typeof") && (fi += 1; (@mydebug "Special case: function type. Skip."); continue)

        # Special case: sometimes our own methods (Stability) get in the way. Skip.
        tyRow.modl == "Stability" && continue;

        pkg=guess_package(tyRow)
        @mydebug "Guessed package: $pkg"

        # Special case: 'Main' module.
        # Some tests define types, and usually they end up in the 'Main' module.
        # We don't try to resurrect those because it's not easy to eval a test
        # module in the current environment (tests run in a sandbox).
        if pkg == "Main"
            @mydebug "A type defined within test suite found (module 'Main'). Skip."
            mi+=1
            continue
        end

        if addpackage(pkg)
            tyname = tyRow.tyname
            try
                if ! is_builtin_module(pkg)
                    @mydebug "Using the module $pkg"
                    evalp("using $pkg")
                    @mydebug "Evaluating the module..."
                    m = evalp(pkg)
                    @mydebug "... and the type"
                    ty = Core.eval(m, tyname)
                else
                    @mydebug "Builtin module. Evaluating the type in global scope"
                    ty = evalp(tyname)
                end
                isconcretetype(ty) && push!(types, ty) # TODO: figure how abstract types can end up
                # in the database; it shouldn't be the case!
            catch err
                # Record error
                ei += 1
                push!(failed, (tyname=tyname, modl=tyRow.modl, error=err))

                # Report error
                @warn "$tag Failed when using the module ($pkg) or type ($(tyRow.tyname))"
                showerror(stderr, err) #, stacktrace(catch_backtrace()))
                println(stderr)
            end
        else
            push!(failed, (tyname=tyRow.tyname,
                           modl=tyRow.modl,
                           error=ArgumentError("Can't add package")))
            ei += 1
        end
    end
    if ei > 0
        report = TypesDBErrorReport(failed, TypesDBErrorMetrics(i,fi,mi,ei))
        CSV.write("types-db-load-errors.csv", failed)
        @info "Report on loading types DB"
        dump(report)
    end
    types
end
