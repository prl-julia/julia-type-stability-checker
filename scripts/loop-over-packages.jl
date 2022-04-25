#
# Goal: proces a bulk of Julia package (test for stability, store in CSV)
#
# Usage: Run from any place with `julia loop-over-packages.jl`
# Effect: results are stored in `<repo>/scratch/bulk` (subject to change)
#

#
# Constants
#

sts_path = dirname(dirname(@__FILE__))
out_dir  = joinpath(sts_path, "scratch", "bulk")

pkgs = split("""
Flux
""")

# Gadfly
# Gen
# Genie
# IJulia
# JuMP
# Knet
# Plots
# Pluto

using Pkg

#
# Script
#

# Go to a fresh env
wd = out_dir #mktempdir()
cd(wd)
Pkg.activate(".")


# Add StabilityCheck
haskey(Pkg.project().dependencies, "StabilityCheck") || Pkg.develop(path=sts_path)
using StabilityCheck
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on debug

#
# Assumption: a package named X contains a ("main") module named X,
#             which we are going to process
# The assumption is known to break for some noteable packages, e.g. `DifferentialEquations`
#

# Add all packages of interest and make Julia `using` them
ev(s)=eval(Meta.parse.(s))
for p in pkgs
    haskey(Pkg.project().dependencies, p) || Pkg.add(p)
    ev("using $p")
end

@info "Finished `using` modules of interest, start processing..."

# Run analysis on the packages
for p in pkgs
    checkModule(ev("$p"), out_dir)
    @info "Module $p processed."
end
