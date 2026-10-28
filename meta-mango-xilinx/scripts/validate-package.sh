#!/bin/bash -e
######################################################################
# @brief   Validate contents of a wrapped LP package
# Copyright (c) 2026 MangoBoost, Inc.
######################################################################

# The *-secured-img.tgz contract: no BOOT.BIN (that is the Key Manager's
# output) and no kernel/rootfs (nothing in the signing flow reads them) -
# just the signing materials and a manifest listing them all with sha256.
SECURED_ARTIFACTS=(
    "images/linux/boot.scr"
    "images/linux/image.ub"
    "manifest.txt"
    "bifs/bootgen_secured.bif"
    "bifs/bootgen_provision.bif"
    "bifs/bootgen_provision_secured.bif"
    "bifs/_selftest.bif"
    "common/files/psmfw.elf"
    "mblp/files/plm.elf"
    "mblp_prov/files/plm-prov.elf"
    "mblp_prov/files/mblp-prov.elf"
    "common/fw-tool.py"
    "nonsecured/BOOT_PROVISION.BIN"
)

BUILD_DIR="deliverable"

shopt -s nullglob
pkgs=("$BUILD_DIR"/*-img.tgz)
if [ ${#pkgs[@]} -eq 0 ]; then
    echo "ERROR: no *-img.tgz found under $BUILD_DIR/"
    exit 1
fi

overall=0
for tgz in "${pkgs[@]}"; do
    tmpdir=$(mktemp -d)
    if ! tar xzf "$tgz" -C "$tmpdir"; then
        echo "  FAIL: cannot extract $(basename "$tgz")"
        overall=1
        rm -rf "$tmpdir"
        continue
    fi

    failed=0

    required=("${SECURED_ARTIFACTS[@]}")

    for f in "${required[@]}"; do
        if [ ! -s "$tmpdir/$f" ]; then
            echo "  FAIL: missing or empty — $f"
            failed=1
        fi
    done

    # A secured package with a BOOT.BIN in it is a packaging bug, not a bonus:
    # either a stale artifact was staged, or someone put a signed image back
    # into the tree the Developer hands over.
    case "$(basename "$tgz")" in
        *-secured-img.tgz)
            if [ -e "$tmpdir/images/linux/BOOT.BIN" ]; then
                echo "  FAIL: secured package must not carry images/linux/BOOT.BIN"
                failed=1
            fi
            ;;
    esac

    if ! ls "$tmpdir/project-spec/hw-description/"*.pdi > /dev/null 2>&1; then
        echo "  FAIL: no .pdi found in project-spec/hw-description/"
        failed=1
    fi

    if [ $failed -eq 0 ]; then
        echo "  OK: $(basename "$tgz")"
    else
        echo "  FAIL: $(basename "$tgz")"
        overall=1
    fi

    rm -rf "$tmpdir"
done

exit $overall
