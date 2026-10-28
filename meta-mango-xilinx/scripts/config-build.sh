#!/bin/bash

if [ $# -ne 2 ]; then
    echo "Usage: $0 [Project DIR] [XSA FILE]"
    exit
fi

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJ_DIR=$(realpath "${1:-$PWD}")
XSA_FILE=$2
if [ ! -d "$PROJ_DIR" ]; then
    echo "Cannot find the petalinux project: $PROJ_DIR"
    exit
fi

XSA_NAME=$(basename "$XSA_FILE")
if [ ! "$XSA_FILE" -ef "$PROJ_DIR/$XSA_NAME" ]; then
    cp "$XSA_FILE" "$PROJ_DIR/"
fi
pushd $PROJ_DIR

petalinux-config --get-hw-description "$XSA_NAME" --silentconfig

popd
