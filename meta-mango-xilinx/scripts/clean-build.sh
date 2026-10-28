#!/bin/bash

if [ $# -ne 1 ]; then
    echo "Usage: $0 [Project DIR]"
    exit
fi

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
PROJ_DIR=$(realpath "$1")

if [ ! -d "$PROJ_DIR" ]; then
    echo "Project not found, creating versal project: $PROJ_DIR"
    mkdir -p "$(dirname "$PROJ_DIR")"
    pushd "$(dirname "$PROJ_DIR")"
    petalinux-create -n "$(basename "$PROJ_DIR")" project --template versal
    popd
else
    # Existing project: clean the previous build. distclean re-parses the
    # project's system.xsa and fails if it was never validly configured
    # (residue from a prior failed run); tolerate it since config-build
    # reconfigures from a fresh XSA next.
    pushd "$PROJ_DIR"
    petalinux-build -x distclean \
        || echo "distclean skipped: project not validly configured yet"
    popd
fi

pushd "$PROJ_DIR"
rm -rf sstate-cache tmp downloads deliverable
popd
