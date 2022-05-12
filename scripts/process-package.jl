#
# Goal: proces one Julia package (test for stability, store in CSV)
#
# Usage: Run from any place with `julia loop-over-packages.jl`
# Effect: results are stored in `<repo>/scratch/bulk` (subject to change)
#

#
# Constants
#

sts_path = dirname(dirname(@__FILE__))
out_dir  = joinpath(sts_path, "scratch", "bulk")
pkg = ARGS[1]
#println("pkg param: \"$pkg\"")
isempty(strip(pkg)) && (println("ERROR: empty package name"); exit(1))

using Pkg

# Map package name onto a module name for a "most representative" module
# in the package. Usually it's the `id` function. Currently known and relevant
# exception is DifferentialEquations
module_name(pkg::String) =
    if pkg == "DifferentialEquations"
        "DiffEqBase"
    else
        pkg
    end

#
# Script
#

# Go to a "fresh" env
wd = out_dir #mktempdir()
cd(wd)
Pkg.activate(".")

@info "Start with package $pkg."

# Add StabilityCheck
haskey(Pkg.project().dependencies, "StabilityCheck") || Pkg.develop(path=sts_path)
using StabilityCheck
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on debug

# Add the package of interest and make Julia `using` it
ev(s)=eval(Meta.parse.(s))
haskey(Pkg.project().dependencies, pkg) || Pkg.add(pkg)
ev("using $pkg")

@info "Finished `using` modules of interest, start processing..."

#
# Assumption: a package named X contains a ("main") module named X,
#             which we are going to process
# The assumption is known to break for some noteable packages, e.g. `DifferentialEquations`
#

# Run analysis on the packages
checkModule(ev(module_name("$pkg")), out_dir, pkg=pkg)
@info "Module $pkg processed."
