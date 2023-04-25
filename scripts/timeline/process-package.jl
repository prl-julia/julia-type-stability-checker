#
# Goal: proces one Julia package (test for stability, store results in CSV)
#
# Usage: Run from any place with `julia <path/to/julia-sts>/scripts/timeline/process-package.jl`
# Effect: resulting files are stored in the CWD
#

sts_path = dirname(dirname(@__DIR__))
pkg = length(ARGS) > 0 ? ARGS[1] : error("Requires argument: name of the package to process")
pkg_dir = length(ARGS) > 1 ? ARGS[2] : error("Requires argument: package directory")
out_dir = length(ARGS) > 2 ? ARGS[3] : error("Requires argument: output directory")
isempty(strip(pkg)) && (println("ERROR: empty package name"); exit(1))

using Pkg

module_name(pkg::String) =
    if pkg == "DifferentialEquations"
        "DiffEqBase"
    else
        pkg
    end

ev(s) = eval(Meta.parse.(s))

cd(out_dir)
Pkg.activate(".")

@info "Start with package $pkg"

haskey(Pkg.project().dependencies, "StabilityCheck") || Pkg.develop(path=sts_path)
using StabilityCheck

Pkg.develop(path=pkg_dir)
ev("using $pkg")

checkModule(ev(module_name("$pkg")), out_dir, pkg=pkg)
@info "Module $pkg processed."
