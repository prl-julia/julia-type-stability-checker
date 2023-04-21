#
# Goal: proces one Julia package (test for stability, store results in CSV)
#
# Usage: Run from any place with `julia <path/to/julia-sts>/scripts/process-package.jl`
# Effect: resulting files are stored in the CWD
#

################################################################################
#
# Constants and Utilities
#

sts_path = dirname(dirname(@__FILE__))
pkg = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: name of the package to process")
pkg_dir = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: package directory")
out_dir = length(ARGS) > 2 ? ARGS[3] : error("Requires argument: output directory")
ver = nothing
isempty(strip(pkg)) && (println("ERROR: empty package name"); exit(1))

pkgver(pkg, ver) = pkg * (ver === nothing ? "" : "@" * ver)

store_cur_version(pkg::String) = begin
    deps = collect(values(Pkg.dependencies()))
    i    = findfirst(i -> i.name == pkg, deps)
    ver  = deps[i].version
    fname= "$pkg-version.txt"
    write(fname, "$ver")
    @info "Write down $pkg version to $fname"
end


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

ev(s)=eval(Meta.parse.(s))

################################################################################
#
#    Script
#

# Go to a "fresh" env
cd(out_dir)
Pkg.activate(".")

@info "Start with package $(pkgver(pkg, ver))."

###
#     Add StabilityCheck
###

haskey(Pkg.project().dependencies, "StabilityCheck") || Pkg.develop(path=sts_path)
using StabilityCheck
# ENV["JULIA_DEBUG"] = StabilityCheck  # turn on debug

###
#    Add the package of interest and make Julia `using` it
###

Pkg.develop(path=pkg_dir)
store_cur_version(pkg)
ev("using $pkg")

@info "Finished `using` modules of interest, start processing..."

###
#     Run analysis on the packages
###

checkModule(ev(module_name("$pkg")), out_dir, pkg=pkg)
@info "Module $pkg processed."
