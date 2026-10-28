#!/bin/bash -e
######################################################################
# @brief   Script to wrap package
# Copyright (c) 2025 MangoBoost, Inc.
######################################################################

IMG_DIR="./images/linux" # Path of resources of image
PDI_DIR="./project-spec/hw-description"
BUILD_DIR="deliverable"
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

SECURED=0
# Empty: --secured uses _make_zip.sh's own committed minimum mango-bsp release.
BSP_MIN=""
# --secured only: firmware files to stage in place of the installed mango-bsp ones
# (a locally built SMC under test), and the version string the manifest records
# for them. Forwarded to _make_zip.sh as --prov / --smc / --fw-tool and SB_BSP_VER.
PROV_OVERRIDE=""
SMC_OVERRIDE=""
FWTOOL_OVERRIDE=""
BSP_VER_OVERRIDE=""
# Delegated to for --secured. It owns the whole secure-boot flow; this script
# only adds the README, build_info.txt and the usual deliverable/ wrapping.
SECURE_MK="$SCRIPT_DIR/secure_boot/files/_make_zip.sh"

usage() {
    echo "Usage: $0 [--proj-path] --secured"
    echo "--proj-path|-p  : Path of LP image project (ex:<your-path>/plnx_mango_versal_lp"
    echo "--secured       : Build the secure boot package."
    echo "                  Materials for the Key Manager to sign, with no key"
    echo "                  material and no BOOT.BIN. Needs bootgen in PATH and"
    echo "                  takes minutes, not seconds - it unpacks the XSA and"
    echo "                  builds both images unsigned to prove they are complete."
    echo "--prov <elf>    : With --secured, provisioning SMC ELF to stage instead of"
    echo "                  /etc/mango/firmware/mblp-prov.elf (a local build under test)."
    echo "--smc <elf>     : With --secured, production SMC ELF instead of mblp.elf."
    echo "--fw-tool <py>  : With --secured, fw-tool.py paired with that ELF."
    echo "--bsp-ver <s>   : With --secured, the mango-bsp version string the manifest"
    echo "                  records for those files, e.g. local-g<sha>-261007."
    echo "                  The last '-' field must be the YYMMDD date."
    echo "--bsp-min <d>   : With --secured, oldest mango-bsp release date (YYMMDD)"
    echo "                  preflight accepts; 0 skips the check."
    echo "--help|-h       : Show this help message."
}

extract_project() {
    local proj_path=$1
    local tgt_dir=$2
    local tgt_name=$3

    if [ -f "$proj_path/.petalinux/metadata" ]; then
        local hw_path=$(grep "^HARDWARE_PATH=" "$proj_path/.petalinux/metadata" | cut -d'=' -f2)
        if [ -n "$hw_path" ]; then
            printf "%-12s : %s\n" "Hardware" "$(basename "$hw_path")" > "$BUILD_DIR/$tgt_name.txt"

            if [ -f VERSION ]; then
                printf "%-12s : %s\n" "meta-mango" "$(cat VERSION)" >> "$BUILD_DIR/$tgt_name.txt"
            fi

            if dpkg -s mango-bsp > /dev/null 2>&1; then
                local bsp_ver=$(dpkg -s mango-bsp | grep "^Version:" | awk '{print $2}')
                printf "%-12s : %s\n" "mango-bsp" "$bsp_ver" >> "$BUILD_DIR/$tgt_name.txt"
            fi
        fi
    fi
}

wrap_secured_package() {
    local proj_path=$(cd "$1" && pwd)
    local tgt_dir="$BUILD_DIR"/$2
    local tgt_pkg="$tgt_dir-img.tgz"
    # The old .tgz is kept until tar replaces it: the secure flow can fail before
    # it stages anything, and the previous package is still the only valid one.
    rm -rf "$tgt_dir"
    mkdir -p "$tgt_dir"

    if [ ! -x "$SECURE_MK" ]; then
        echo "ERROR: $SECURE_MK not found - run this from the meta-mango root."
        exit 1
    fi

    # _make_zip.sh stages, renders the BIFs, proves the materials by building both
    # images without keys, and writes manifest.txt. --no-zip stops it before the
    # archive so this script can wrap the tree; it reads no key and ships none.
    local mk_args=(--stage "$(cd "$tgt_dir" && pwd)" --no-zip)
    [ -n "$BSP_MIN" ] && mk_args+=(--bsp-min "$BSP_MIN")
    [ -n "$PROV_OVERRIDE" ] && mk_args+=(--prov "$(readlink -f "$PROV_OVERRIDE")")
    [ -n "$SMC_OVERRIDE" ] && mk_args+=(--smc "$(readlink -f "$SMC_OVERRIDE")")
    [ -n "$FWTOOL_OVERRIDE" ] && mk_args+=(--fw-tool "$(readlink -f "$FWTOOL_OVERRIDE")")
    [ -n "$BSP_VER_OVERRIDE" ] && export SB_BSP_VER_OVERRIDE="$BSP_VER_OVERRIDE"

    # rmdir only removes it if nothing was staged; a partial tree is left to look
    # at. An empty deliverable/<name>/ would read as a finished package.
    if ! PLNX_PROJ="$proj_path" "$SECURE_MK" "${mk_args[@]}"; then
        rmdir "$tgt_dir" 2> /dev/null || true
        exit 1
    fi

    # No flashing tools: this package is signing materials plus the four files
    # that go to flash. Whoever deploys it writes them with their own tool.
    cp "$SCRIPT_DIR/README_secured_pkg.md" "$tgt_dir/README.md"

    extract_project "$proj_path" "$tgt_dir" "$2"

    if [ -f "$BUILD_DIR/$2.txt" ]; then
        cat "$BUILD_DIR/$2.txt"
    fi

    # .pkg_sources is _make_zip.sh's own scratch note, already folded into
    # manifest.txt. It stays on disk so the manifest step can be re-run against
    # an existing stage, but it is not part of the package.
    tar czf "$tgt_pkg" --exclude=.pkg_sources -C "$tgt_dir" .
}

check_proj_path() {
    if ! (cd "$1") > /dev/null 2>&1; then
        echo "ERROR: $1 does not exist"
        exit 1
    fi
}

get_target_name() {
    local proj_path=$(cd "$1" && pwd)
    local config_file="$proj_path/project-spec/configs/config"

    if [ ! -f "$config_file" ]; then
        echo "ERROR: Configuration file not found at $config_file"
        exit 1
    fi

    local tgt_name=$(grep "^CONFIG_YOCTO_MACHINE_NAME=" "$config_file" | cut -d'=' -f2 | tr -d '"')

    if [ -z "$tgt_name" ]; then
        echo "ERROR: Could not find CONFIG_YOCTO_MACHINE_NAME in $config_file"
        exit 1
    fi
    echo "$tgt_name"
}

#-------------------#
#  Main Logic       #
#-------------------#

while [ "$#" -gt 0 ]; do
    case "$1" in
        help | -h | --help)
            usage
            exit 0
            ;;
        --proj-path | -p)
            shift
            proj_path=$1
            check_proj_path $proj_path
            ;;
        --secured)
            SECURED=1
            ;;
        --bsp-min)
            shift
            BSP_MIN=$1
            ;;
        --prov)
            shift
            PROV_OVERRIDE=$1
            ;;
        --smc)
            shift
            SMC_OVERRIDE=$1
            ;;
        --fw-tool)
            shift
            FWTOOL_OVERRIDE=$1
            ;;
        --bsp-ver)
            shift
            BSP_VER_OVERRIDE=$1
            ;;
        *)
            usage
            exit 1
            ;;
    esac
    shift
done

if [ -z "$proj_path" ]; then
    usage
    # meta-mango normally sits inside the project it belongs to, so the path is
    # almost always '..' - say so rather than leave it to the usage block.
    if [ -d "../project-spec" ]; then
        hint=""
        [ "$SECURED" -eq 1 ] && hint=" --secured"
        echo
        echo "This looks like a layer inside a PetaLinux project. You probably want:"
        echo "  $0 -p ..$hint"
    fi
    exit 1
fi

tgt=$(get_target_name $proj_path)
base_tgt=$tgt
tgt="$(date +%y%m%d)_$tgt"
# A distinct name so the two packages can never be mistaken for one another:
# one carries a finished BOOT.BIN, the other deliberately has none.
[ "$SECURED" -eq 1 ] && tgt="$tgt-secured"

echo
echo "----------------------------------------------------------------------"
echo "                       Package Generation Summary"
echo "----------------------------------------------------------------------"
printf "%-12s : %s\n" "Detected Target" "$base_tgt"
[ "$SECURED" -eq 1 ] && printf "%-12s : %s\n" "Mode" "secure boot (no key material, no BOOT.BIN)"

# Generate Package
if [ "$SECURED" -eq 1 ]; then
    wrap_secured_package $proj_path $tgt
else
    echo "ERROR: only the secure boot package is supported; pass --secured"
    exit 1
fi

echo
echo "[Deliverables]"
printf "  %-12s : %s\n" "Directory" "./$BUILD_DIR/"
printf "  %-12s : %s\n" "Package" "$tgt-img.tgz"
printf "  %-12s : %s\n" "Metadata" "$tgt.txt"
echo "----------------------------------------------------------------------"
