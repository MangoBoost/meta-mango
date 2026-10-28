#!/bin/bash
#
# package-images.sh - Build flashable images (BOOT.BIN + image.ub)
#
# BOOT.BIN: merges extracted PDI BIF + outer partitions (U-Boot, TF-A,
# DTB, SMC) into a unified BIF, runs bootgen once with SHA3 partition
# checksums, then appends a 72-byte SHA-256 PLDM footer.
#
# image.ub: produced earlier by petalinux-build; this script appends the
# same 72-byte SHA-256 PLDM footer so the SMC in-band flash path can
# validate it.
#
# Must be invoked with the petalinux project directory as cwd
# (project-spec/ must exist there). build-all.sh handles this via
# pushd $PROJ_DIR.
#
# Usage:
#   ./package-images.sh [--smc <elf_path>] [--clk <250|238|227>]
#
# Options:
#   --smc <path>    SMC firmware ELF path (default: /etc/mango/firmware/mblp.elf)
#   --clk <freq>    Set clock frequency via fw-tool.py (250, 238, or 227).
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(pwd -P)"
if [[ ! -d "${PROJECT_DIR}/project-spec" ]]; then
    echo "ERROR: not in a petalinux project (no project-spec/ in ${PROJECT_DIR})"
    exit 1
fi
HW_DESC_DIR="${PROJECT_DIR}/project-spec/hw-description"
EXTRACTED_DIR="${HW_DESC_DIR}/extracted"
IMAGES_DIR="${PROJECT_DIR}/images/linux"
FWTOOL="/etc/mango/firmware/fw-tool.py"
SMC_DEFAULT="/etc/mango/firmware/mblp.elf"
SMC_ELF=""
CLK_FREQ=""

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --smc)
            SMC_ELF="$2"
            shift 2
            ;;
        --clk)
            CLK_FREQ="$2"
            shift 2
            ;;
        -h | --help)
            echo "Usage: $0 [--smc <elf_path>] [--clk <250|238|227>]"
            echo ""
            echo "Options:"
            echo "  --smc <path>    SMC firmware ELF path (default: ${SMC_DEFAULT})"
            echo "  --clk <freq>    Set clock frequency via fw-tool.py (250, 238, or 227)."
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            exit 1
            ;;
    esac
done

# Default SMC ELF
if [[ -z "${SMC_ELF}" ]]; then
    SMC_ELF="${SMC_DEFAULT}"
fi

if [[ ! -f "${SMC_ELF}" ]]; then
    echo "ERROR: SMC firmware not found: ${SMC_ELF}"
    exit 1
fi

# Validate clock frequency if specified
if [[ -n "${CLK_FREQ}" ]]; then
    if [[ "${CLK_FREQ}" != "250" && "${CLK_FREQ}" != "238" && "${CLK_FREQ}" != "227" ]]; then
        echo "ERROR: Invalid clock frequency: ${CLK_FREQ} (must be 250, 238, or 227)"
        exit 1
    fi
fi

echo "=== Package flashable images (BOOT.BIN + image.ub) ==="
echo "Project: ${PROJECT_DIR}"
echo "SMC ELF: ${SMC_ELF}"

# Step 1: Find latest extracted directory
LATEST_DIR=$(find "${EXTRACTED_DIR}" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2> /dev/null | sort -n | tail -1 | cut -d' ' -f2-)
if [[ -z "${LATEST_DIR}" ]]; then
    echo "ERROR: No extracted directories found in ${EXTRACTED_DIR}"
    exit 1
fi
echo "Latest extracted dir: $(basename "${LATEST_DIR}")"

# Step 2: Find BIF file in latest directory
BIF_FILE=$(ls "${LATEST_DIR}"/pdi_files/*.bif 2> /dev/null | head -1)
if [[ -z "${BIF_FILE}" ]]; then
    # An XSA exported without a BIF (the SP designs) gives nothing to
    # rebuild BOOT.BIN from, so the one petalinux-package boot made is
    # kept as is and only the footers are added. The clock lives in the
    # SMC ELF inside that BOOT.BIN, so --clk cannot be applied here.
    echo -e "\033[1;33mWARNING: No BIF file found in ${LATEST_DIR}/pdi_files/; keeping BOOT.BIN from petalinux-package boot\033[0m"
    echo -e "\033[1;33mWARNING: no SHA3 partition checksums (bitstream included) in this BOOT.BIN, and this XSA cannot build the secure boot package (wrap-package.sh --secured)\033[0m"
    if [[ -n "${CLK_FREQ}" ]]; then
        echo "ERROR: --clk ${CLK_FREQ} needs a BIF to rebuild BOOT.BIN"
        exit 1
    fi
    if [[ ! -f "${IMAGES_DIR}/BOOT.BIN" ]]; then
        echo "ERROR: ${IMAGES_DIR}/BOOT.BIN not found (run petalinux-package boot first)"
        exit 1
    fi
    if [[ ! -f "${IMAGES_DIR}/image.ub" ]]; then
        echo "ERROR: ${IMAGES_DIR}/image.ub not found (run petalinux-build first)"
        exit 1
    fi
    echo "Appending SHA-256 footer to BOOT.BIN..."
    python3 "${SCRIPT_DIR}/gen_sha_footer.py" "${IMAGES_DIR}/BOOT.BIN" "${IMAGES_DIR}/BOOT.BIN"
    echo "Appending SHA-256 footer to image.ub..."
    python3 "${SCRIPT_DIR}/gen_sha_footer.py" "${IMAGES_DIR}/image.ub" "${IMAGES_DIR}/image.ub"
    echo ""
    echo "=== Done (footer only: no partition checksums, no secure boot) ==="
    echo "BOOT.BIN:  ${IMAGES_DIR}/BOOT.BIN"
    echo "image.ub:  ${IMAGES_DIR}/image.ub"
    exit 0
fi
echo "Source BIF: ${BIF_FILE}"

PDI_FILES_DIR="${LATEST_DIR}/pdi_files"
UNIFIED_BIF="${IMAGES_DIR}/bootgen_checksum.bif"

# Copy SMC ELF to images/linux/
cp "${SMC_ELF}" "${IMAGES_DIR}/smc.elf"
echo "Copied SMC ELF to ${IMAGES_DIR}/smc.elf"

# Run fw-tool.py if --clk is specified
if [[ -n "${CLK_FREQ}" ]]; then
    if [[ ! -f "${FWTOOL}" ]]; then
        echo "ERROR: fw-tool.py not found: ${FWTOOL}"
        exit 1
    fi
    echo "Setting clock frequency to ${CLK_FREQ} MHz..."
    python3 "${FWTOOL}" "${IMAGES_DIR}/smc.elf" set clk "${CLK_FREQ}"
    echo "--- SMC Firmware Info ---"
    python3 "${FWTOOL}" "${IMAGES_DIR}/smc.elf" get info || true
    python3 "${FWTOOL}" "${IMAGES_DIR}/smc.elf" get clk || true
    echo "-------------------------"
else
    echo -e "\033[1;33mWARNING: --clk not set, skipping fw-tool.py. Clock frequency unchanged.\033[0m"
fi

# BOOT.BIN DT partition uses the U-Boot-specific dtb (built by uboot-device-tree
# when CONFIG_SUBSYSTEM_UBOOT_EXT_DTB=y), not the Linux system.dtb (loaded raw @0x1000).
UBOOT_DTB="${IMAGES_DIR}/u-boot.dtb"
if [[ ! -f "${UBOOT_DTB}" ]]; then
    echo "ERROR: ${UBOOT_DTB} not found (need CONFIG_SUBSYSTEM_UBOOT_EXT_DTB=y)." >&2
    exit 1
fi
echo "BOOT.BIN U-Boot DT: ${UBOOT_DTB}"

# Step 3: Build unified BIF
# Take extracted BIF (PDI internals), add checksum=sha3 to all partitions,
# resolve file paths, then append outer partitions (DTB, TF-A, U-Boot, SMC).
echo "Creating unified BIF: ${UNIFIED_BIF}"
awk -v pdi_dir="${PDI_FILES_DIR}" -v images_dir="${IMAGES_DIR}" -v uboot_dtb="${UBOOT_DTB}" '
    /^[[:space:]]*partition/ { in_partition = 1 }
    in_partition && /^[[:space:]]*id[[:space:]]*=/ {
        print
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        print indent "checksum = sha3"
        in_partition = 0
        next
    }
    /^[[:space:]]*file[[:space:]]*=/ {
        match($0, /^[[:space:]]*/)
        indent = substr($0, RSTART, RLENGTH)
        split($0, a, "=")
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", a[2])
        fname = a[2]
        if (system("test -f " pdi_dir "/" fname) == 0)
            resolved = pdi_dir "/" fname
        else if (system("test -f " pdi_dir "/gen_files/" fname) == 0)
            resolved = pdi_dir "/gen_files/" fname
        else if (system("test -f " pdi_dir "/static_files/" fname) == 0)
            resolved = pdi_dir "/static_files/" fname
        else
            resolved = fname
        print indent "file = " resolved
        next
    }
    # Before the final closing brace, append the apu_subsystem image
    /^}[[:space:]]*$/ && !done {
        print " image"
        print " {"
        print "  id = 0x1c000000, name=apu_subsystem"
        print "  partition"
        print "  {"
        print "   id = 0x20"
        print "   checksum = sha3"
        print "   type = raw, load = 0x1000"
        print "   file = " uboot_dtb
        print "  }"
        print "  partition"
        print "  {"
        print "   id = 0x21"
        print "   checksum = sha3"
        print "   core = a72-0, exception_level = el-3, trustzone"
        print "   file = " images_dir "/bl31.elf"
        print "  }"
        print "  partition"
        print "  {"
        print "   id = 0x22"
        print "   checksum = sha3"
        print "   core = a72-0, exception_level = el-2"
        print "   file = " images_dir "/u-boot.elf"
        print "  }"
        print "  partition"
        print "  {"
        print "   id = 0x23"
        print "   checksum = sha3"
        print "   core = r5-0"
        print "   file = " images_dir "/smc.elf"
        print "  }"
        print " }"
        done = 1
    }
    { print }
' "${BIF_FILE}" > "${UNIFIED_BIF}"

echo "Unified BIF written to: ${UNIFIED_BIF}"

# Step 4: Run bootgen to create BOOT.BIN
echo "Running bootgen..."
if ! command -v bootgen &> /dev/null; then
    echo "ERROR: bootgen not found in PATH (source the PetaLinux or Vitis settings.sh)"
    exit 1
fi
bootgen -arch versal -image "${UNIFIED_BIF}" -o "${IMAGES_DIR}/BOOT.BIN" -w

# Step 5: Append SHA-256 footer to BOOT.BIN
echo "Appending SHA-256 footer to BOOT.BIN..."
python3 "${SCRIPT_DIR}/gen_sha_footer.py" "${IMAGES_DIR}/BOOT.BIN" "${IMAGES_DIR}/BOOT.BIN"

# Step 6: Append SHA-256 footer to image.ub
echo "Appending SHA-256 footer to image.ub..."
if [[ ! -f "${IMAGES_DIR}/image.ub" ]]; then
    echo "ERROR: ${IMAGES_DIR}/image.ub not found (run petalinux-build first)"
    exit 1
fi
python3 "${SCRIPT_DIR}/gen_sha_footer.py" "${IMAGES_DIR}/image.ub" "${IMAGES_DIR}/image.ub"

echo ""
echo "=== Done ==="
echo "BOOT.BIN:  ${IMAGES_DIR}/BOOT.BIN"
echo "image.ub:  ${IMAGES_DIR}/image.ub"
echo "BIF:       ${UNIFIED_BIF}"
