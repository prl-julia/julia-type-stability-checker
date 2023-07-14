#!/usr/bin/env bash

MYDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

PKGS=${1:-"$MYDIR/pkgs.txt"}

echo "[INFO] Processing package list in $PKGS"
echo "       (pass an alternative localtion as the script argument next time if desired)"

while IFS= read -r pkg; do
    echo "Processing package $pkg"
    mkdir -p "$pkg"
    pushd "$pkg"
    julia "$MYDIR/process-package.jl" "$pkg"
    popd
done < $PKGS
