#!/usr/bin/env bash

# IJulia, JuMP -- LOOP need to limit fuel?..
#
pkgs='Gen
IJulia
JuMP
Knet
Plots
Pluto'
# Flux
# Gadfly
# Genie
# Gen
# IJulia
# JuMP
# Knet
# Plots
# Pluto

#echo "$pkgs"

MYDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while IFS= read -r pkg; do
    julia "$MYDIR/process-package.jl" "$pkg"
done <<< "$pkgs"
