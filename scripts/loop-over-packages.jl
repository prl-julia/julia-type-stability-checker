
#
# Constants
#

sts_path = dirname(dirname(@__FILE__))
out_dir  = joinpath(sts_path, "scratch", "bulk")

pkgs = split("""
Flux
Gadfly
Gen
Genie
IJulia
JuMP
Knet
Plots
Pluto
""")

using Pkg

#
# Script
#

# Go to a fresh env
wd = out_dir #mktempdir()
cd(wd)
Pkg.activate(".")


# Add StabilityCheck
Pkg.add(path=sts_path)
using StabilityCheck

#
# Assumption: a package named X contains a ("main") module named X,
#             which we are going to process
# The assumption is known to break for some noteable packages, e.g. `DifferentialEquations`
#

# Add all packages of interest and make Julia `using` them
ev(s)=eval(Meta.parse.(s))
Pkg.add(pkgs)
for p in pkgs
    ev("using $p")
end

# Run analysis on the packages
for p in pkgs
    checkModule(ev("$p"), out_dir)
end
