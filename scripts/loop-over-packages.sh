#!/usr/bin/env bash

# IJulia, JuMP -- LOOP need to limit fuel?..
#
pkgs='Gen
Flux
Gadfly
Genie
IJulia
JuMP
Knet
Plots
Pluto'

#echo "$pkgs"

MYDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

while IFS= read -r pkg; do
    julia "$MYDIR/process-package.jl" "$pkg"
done <<< "$pkgs"
