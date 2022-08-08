#
# Goal: proces one Julia package (test for stability, store results in CSV)
#
# Usage: Run from any place with `julia <path/to/julia-sts>/scripts/loop-over-packages.jl`
# Effect: results are stored in the CWD
#

#
# Constants
#

sts_path = dirname(dirname(@__FILE__))
out_dir  = "." # joinpath(sts_path, "scratch", "bulk")
pkg = length(ARGS) > 0 ? ARGS[1] : error("Requires one argument: name of the package to process")
isempty(strip(pkg)) && (println("ERROR: empty package name"); exit(1))

using Pkg

# module_name: (pkg: String) -> (mod: String)
# Map package name onto a module name for a "most representative" module
# in the package. Usually it's the `id` function (main module's name is the
# same as package name).
# Currently known and relevant exception is DifferentialEquations.
# TODO: support several modules per package
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

# Run analysis on the packages
checkModule(ev(module_name("$pkg")), out_dir, pkg=pkg)
@info "Module $pkg processed."
