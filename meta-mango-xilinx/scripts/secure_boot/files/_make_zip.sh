#!/bin/bash
set -uo pipefail

# Developer half: unpack the XSA, stage what both images need, render the BIFs,
# prove the set by building without keys, zip. Never sees a key. See README.md.

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
cd "$SCRIPT_DIR" || exit 1

# SCRIPT_DIR is files/. The project root gained a level when this moved here.
PROJ=${PLNX_PROJ:-$(readlink -f "${SCRIPT_DIR}/../../../../..")}
IMG_DIR="${PROJ}/images/linux"
LOG_ROOT=logs
# Derived once here; the step bodies use them. Steps are subshells, so a local
# re-derivation would be harmless anyway.
BASE_DIR="$SCRIPT_DIR"            # files/, absolute
SB_DIR="$(dirname "$SCRIPT_DIR")" # scripts/secure_boot/, absolute
# _pkg_xsa_bif.py stays a file - it is Python, and two steps below call it.
XSA_BIF="${BASE_DIR}/_pkg_xsa_bif.py"

# mango-bsp artifacts, from the directory the package installs them in. Not built
# by this project, so they stay options - but the project root is not a source.
BSP_DIR=/etc/mango/firmware
SMC="${BSP_DIR}/mblp.elf"
PROV="${BSP_DIR}/mblp-prov.elf"
# scripts/program.sh's FPT_FILE default - outside the project, hence an option
FPT="${BSP_DIR}/fpt.bin"
# The deployed boot.scr, not the one this project builds: mango-bsp owns what the
# board runs at 0x20000, so the package ships that copy.
BOOTSCR="${BSP_DIR}/boot.scr"
# The injector for mblp-prov.elf's key slot, from the same mango-bsp directory. It
# ships in the package: the Key Manager has neither mango-bsp nor a toolchain.
FWTOOL="${BSP_DIR}/fw-tool.py"
# Oldest mango-bsp release accepted, as the date in its version (1.0.0-261007).
# Bump it when the package names an artifact an older release does not produce.
# 261007: mblp-prov.elf adds revoke IDs to an already-burned REVOKE_ID row,
# which key_manager.sh re-provisioning relies on.
BSP_MIN=261007
OUT="${PROJ}/non-secured_image.zip"
STAGE="${SCRIPT_DIR}/_pkg"
# --no-zip: stop after the manifest and leave the staged tree. Used by
# scripts/wrap-package.sh --secured, which archives it itself.
NO_ZIP=0
VERBOSE=0

# shellcheck source=_steplib.sh
. "${SCRIPT_DIR}/_steplib.sh"

# ============================== Steps =======================================
# Subshells: exit/cd stay local. Bodies at column 0 - indenting breaks heredocs.

# ---------------------------------------------------------- 1. unpack the XSA
sb_step_get_xsa() {
    XSA_SRC="${PROJ}/project-spec/hw-description/system.xsa"
    XSA_DIR="${BASE_DIR}/xsa_files"

    if [ ! -f "${XSA_SRC}" ]; then
        echo "Error: ${XSA_SRC} not found." >&2
        echo "Run petalinux-config --get-hw-description with the board XSA first." >&2
        echo "(PLNX_PROJ resolved to: ${PROJ})" >&2
        exit 1
    fi

    # start from a clean tree so a stale extraction cannot be picked up
    if [ -d "${XSA_DIR}" ]; then
        echo "removing existing ${XSA_DIR}"
        rm -rf "${XSA_DIR}"
    fi
    mkdir -p "${XSA_DIR}"

    echo "copying system.xsa: ${XSA_SRC} -> ${XSA_DIR}/"
    cp "${XSA_SRC}" "${XSA_DIR}/"

    # .xsa is a zip archive
    echo "extracting system.xsa"
    unzip -o "${XSA_DIR}/system.xsa" -d "${XSA_DIR}"

    echo "done: ${XSA_DIR}"
}

# ------------------------------------------------------- 2. collect materials
sb_step_collect() {
    IMG_DIR="${PROJ}/images/linux"
    HW_DIR="${PROJ}/project-spec/hw-description"
    # the tree _get_xsa.sh unpacked from hw-description/system.xsa; the single
    # source for every PL artifact in the package, whole PDI and parts alike
    XSA_DIR="${BASE_DIR}/xsa_files"
    # the BIF inside the XSA resolves its paths against pdi_files/, not against its
    # own directory - verified on both boards
    XSA_PDI="${XSA_DIR}/pdi_files"

    STAGE=${SB_PKG_STAGE:-${BASE_DIR}/_pkg}
    # mango-bsp installs these.
    BSP_DIR=/etc/mango/firmware
    SMC=${SB_PKG_SMC:-${BSP_DIR}/mblp.elf}
    PROV=${SB_PKG_PROV:-${BSP_DIR}/mblp-prov.elf}
    FPT=${SB_PKG_FPT:-${BSP_DIR}/fpt.bin}
    # Tool and ELF are one pair: the tool writes the bit order, hex conversion and CRC
    # window the ELF's reader checks. A mismatched pair burns at the wrong offset.
    FWTOOL=${SB_PKG_FWTOOL:-${BSP_DIR}/fw-tool.py}
    BOOTSCR=${SB_PKG_BOOTSCR:-${BSP_DIR}/boot.scr}

    # Refuse to stage inside the key tree: by the time _pkg_zip's guard ran, build
    # artifacts would already be sitting among the keys.
    case "$(readlink -f "$STAGE")/" in
        "$(readlink -f "$BASE_DIR")"/keys/*)
            sb_die "staging directory is inside the key tree: $STAGE"
            ;;
    esac

    [ -d "$IMG_DIR" ] || sb_die "$IMG_DIR not found. Run petalinux-build first. (PLNX_PROJ=$PROJ)"
    [ -d "$XSA_PDI" ] || sb_die "$XSA_PDI not found - run step 1 first."

    # Clean tree so no stale artifact is picked up. The Key Manager cannot rebuild
    # anything, so whatever ships is what gets signed.
    if [ -d "$STAGE" ]; then
        echo "removing existing $STAGE"
        rm -rf "$STAGE"
    fi
    mkdir -p "$STAGE"/{bifs,nonsecured} \
        "$STAGE"/common/{pdi_files,files} \
        "$STAGE"/mblp/files \
        "$STAGE"/mblp_prov/files \
        "$STAGE"/images/linux

    # A directory says who reads it: common/ both images, mblp/ the product image,
    # mblp_prov/ the provisioning one. Shared PL partitions live in common/.

    # ------------------------------------------------------------------- common
    # The PL/PMC set comes from the XSA's own BIF, not from here - it varies per board.
    [ -x "$XSA_BIF" ] || sb_die "missing $XSA_BIF"
    while IFS=$'\t' read -r src dest; do
        [ -n "$src" ] || continue
        [ -f "${XSA_PDI}/${src}" ] || sb_die "the XSA's BIF names ${src}, which is not in ${XSA_PDI}"
        cp "${XSA_PDI}/${src}" "${STAGE}/${dest}"
    done < <("$XSA_BIF" "$XSA_DIR" --emit copy-list)

    [ -f "${IMG_DIR}/psmfw.elf" ] || sb_die "missing ${IMG_DIR}/psmfw.elf - run petalinux-build first."
    cp "${IMG_DIR}/psmfw.elf" "${STAGE}/common/files/"

    # --------------------------------------------------------------------- mblp
    # Product image only. mango-bsp's r5-0 ELF lands as mblp.elf, the BIFs' name for it.
    # u-boot.dtb is the U-Boot DT, not the Linux system.dtb. PetaLinux builds it
    # only with CONFIG_SUBSYSTEM_UBOOT_EXT_DTB=y (set by init-plnx-config.sh).
    for f in plm.elf bl31.elf u-boot.elf u-boot.dtb; do
        [ -f "${IMG_DIR}/${f}" ] || sb_die "missing ${IMG_DIR}/${f} - run petalinux-build first."
        cp "${IMG_DIR}/${f}" "${STAGE}/mblp/files/"
    done

    [ -f "$SMC" ] || sb_die "product ELF not found: $SMC (override with --smc)"
    cp "$SMC" "${STAGE}/mblp/files/mblp.elf"

    # ----------------------------------------------------------------- mblp_prov
    # Only what it does not share with the product image - the rest is in common/.
    [ -f "${IMG_DIR}/plm-prov.elf" ] || {
        echo "ERROR: missing ${IMG_DIR}/plm-prov.elf" >&2
        echo "       Build it:  petalinux-build -c plm-firmware-efuse" >&2
        echo "       (do NOT substitute plm.elf - the product PLM cannot serve eFUSE writes.)" >&2
        exit 1
    }
    cp "${IMG_DIR}/plm-prov.elf" "${STAGE}/mblp_prov/files/"

    # No base PDI: both images build from the decomposed cdo/rnpi/rcdo in
    # common/pdi_files/, so they cannot disagree about the PL design. Saves ~20MB too.

    [ -f "$PROV" ] || sb_die "provisioning ELF not found: $PROV (override with --prov)"
    cp "$PROV" "${STAGE}/mblp_prov/files/mblp-prov.elf"

    # --------------------------------------------------------------- common tool
    # A program, not a material. In common/ root so no BIF glob takes it for a partition.
    [ -f "$FWTOOL" ] || sb_die "injection tool not found: $FWTOOL (override with --fw-tool)"
    install -m 0755 "$FWTOOL" "${STAGE}/common/fw-tool.py"

    # -------------------------------------------------------------- images/linux
    # The flash side, untouched: never signed, never rebuilt, same for every key set.
    [ -f "${IMG_DIR}/image.ub" ] || sb_die "missing ${IMG_DIR}/image.ub - run petalinux-build first."
    cp "${IMG_DIR}/image.ub" "${STAGE}/images/linux/"

    # boot.scr comes from mango-bsp, not from this project's build: what the board
    # runs at 0x20000 is the deployed copy, so that is the one that ships.
    [ -f "$BOOTSCR" ] || sb_die "boot.scr not found: $BOOTSCR (override with --boot-scr)"
    cp "$BOOTSCR" "${STAGE}/images/linux/boot.scr"

    # The table the offsets in flash_map.txt were taken from, so a reader can check
    # them rather than trust them.
    [ -f "$FPT" ] || sb_die "fpt.bin not found: $FPT (override with --fpt)"
    cp "$FPT" "${STAGE}/images/linux/fpt.bin"

    # No whole PDI is staged. It was only ever here for 'program_flash -pdi' device
    # bring-up over JTAG, which this package no longer carries a tool for.

    # Recorded next to the files: which slot each image belongs in is the one thing
    # here that is easy to get wrong and expensive to get wrong.
    cat > "${STAGE}/images/linux/flash_map.txt" << 'EOF'
Flash layout (smc/assets/fpt.json), and who writes what.

  fpt entry  type  base_addr   partition_size  role
  0          PDI   0x00060000  0x02FA0000      primary boot
  1          PDI   0x03000000  0x02FA0000      golden boot
  2          FIT   0x06000000  0x09800000      kernel + rootfs

Four regions make a bootable device. Written in this order:

  order  file                offset      max size    from
  1      fpt.bin             0x0         0x20000     images/linux/   (mango-bsp)
  2      boot.scr            0x20000     0x20000     images/linux/   (mango-bsp)
  3      BOOT.BIN            0x60000     0x2FA0000   see below
  4      image.ub            0x06000000  0x9800000   images/linux/   (this project)

This package carries no flashing tool - it carries the files. Notes on order 3:

  - It goes to fpt entry 0, the PRIMARY slot. This package ships no BOOT.BIN,
    because which one you mean is the whole question:
      nonsecured/BOOT_PROVISION.BIN  the eFUSE provisioning image. It boots and
        then waits for a register command rather than burning anything on load.
        Unsigned, so it only boots a board whose PPK0_HASH is not burned yet -
        which is exactly the board it is for.
      the Key Manager's signed image, once the board is provisioned.

  - The GOLDEN slot (fpt entry 1, 0x03000000) is a separate write from the
    primary one. The Key Manager's signed BOOT_SECURED.BIN goes there:
      mango-ctl mgmt flash <dev> BOOT_SECURED.BIN golden

  - Once the eFUSEs are burned the ROM rejects any unsigned image (0x345), so
    BOOT_PROVISION.BIN stops booting at that point. Further eFUSE work needs the
    signed provisioning image the Key Manager builds from
    bifs/bootgen_provision_secured.bif.
EOF

    # Sources of the two mango-bsp ELFs, for the manifest. They are the only inputs
    # that do not come from this project, so where they came from is worth keeping.
    {
        printf 'mblp_src=%s\n' "$(readlink -f "$SMC")"
        printf 'prov_src=%s\n' "$(readlink -f "$PROV")"
        printf 'fpt_src=%s\n' "$(readlink -f "$FPT")"
        printf 'fwtool_src=%s\n' "$(readlink -f "$FWTOOL")"
        printf 'bootscr_src=%s\n' "$(readlink -f "$BOOTSCR")"
        printf 'xsa_src=%s\n' "$(readlink -f "${HW_DIR}/system.xsa")"
    } > "${STAGE}/.pkg_sources"

    echo "staged: $STAGE"
    staged_list() { find "$1" -maxdepth 1 -type f -printf '%f\n' | sort | tr '\n' ' '; }
    printf '  common/pdi_files : %s\n' "$(staged_list "${STAGE}/common/pdi_files")"
    printf '  common/files     : %s\n' "$(staged_list "${STAGE}/common/files")"
    printf '  images/linux     : %s\n' "$(staged_list "${STAGE}/images/linux")"
    printf '  mblp/files       : %s\n' "$(staged_list "${STAGE}/mblp/files")"
    printf '  mblp_prov/files   : %s\n' "$(staged_list "${STAGE}/mblp_prov/files")"
    printf '  common (tool)    : %s\n' "$(staged_list "${STAGE}/common")"
}

# ------------------------------------------------------------ 3. render BIFs
sb_step_render_bifs() {
    # No PROJ: this step reads the staged tree, the unpacked XSA and the templates, so
    # it can be re-run on an existing stage while iterating on a BIF.
    STAGE=${SB_PKG_STAGE:-${BASE_DIR}/_pkg}
    BIF_SRC="${BASE_DIR}/bifs"
    XSA_DIR="${BASE_DIR}/xsa_files"

    [ -d "${STAGE}/common/pdi_files" ] || sb_die "$STAGE is not staged - run _pkg_collect.sh first."
    [ -x "$XSA_BIF" ] || sb_die "missing $XSA_BIF"

    # id_code / extended_id_code / id / device, out of the XSA. The id differs per
    # design (0x5 bnic, 0x2 nrt), so it cannot be a constant in the template.
    eval "$("$XSA_BIF" "$XSA_DIR" --emit meta)"
    [ -n "$SB_ID_CODE" ] || sb_die "no id_code in the XSA's BIF"
    [ -n "$SB_DEVICE" ] || sb_die "no fpgaDevice in ${XSA_DIR}/xsa.json"

    APP="${STAGE}/mblp_prov/files/mblp-prov.elf"
    [ -f "$APP" ] || sb_die "$APP not found - run _pkg_collect.sh first."

    # Core from the ELF class, not the file name: an A72 build tagged r5-0 would be
    # accepted by bootgen and load 64-bit code onto the R5.
    ELF_CLASS=$(readelf -h "$APP" | sed -n 's/^ *Class: *//p')
    case "$ELF_CLASS" in
        ELF32) APP_ATTR="core=r5-0" ;;
        ELF64) APP_ATTR="core=a72-0, exception_level=el-3" ;;
        *) sb_die "cannot tell the target core of $APP (readelf class: '${ELF_CLASS:-unknown}')" ;;
    esac

    mkdir -p "${STAGE}/bifs"

    # @PL_IMAGES@ filled from a file, not a sed expression: the block is hundreds of
    # lines with slashes and ampersands, and 'r' interprets neither.
    render() {
        local tmpl=$1 out=$2 pl=$3
        [ -f "$tmpl" ] || sb_die "missing $tmpl"
        sed -e "s|@ID_CODE@|${SB_ID_CODE}|g" \
            -e "s|@EXT_ID_CODE@|${SB_EXT_ID_CODE}|g" \
            -e "s|@BIF_ID@|${SB_BIF_ID}|g" \
            -e "s|@APP_ATTR@|${APP_ATTR}|g" \
            -e "/^@PL_IMAGES@$/{r ${pl}
d
}" "$tmpl" > "$out"
    }

    PL_GOLDEN=$(mktemp)
    PL_PROV=$(mktemp)
    PL_PROV_S=$(mktemp)
    trap 'rm -f "$PL_GOLDEN" "$PL_PROV" "$PL_PROV_S"' EXIT

    "$XSA_BIF" "$XSA_DIR" --emit pl-images --profile golden --secure full > "$PL_GOLDEN"
    "$XSA_BIF" "$XSA_DIR" --emit pl-images --profile provision --secure none > "$PL_PROV"
    "$XSA_BIF" "$XSA_DIR" --emit pl-images --profile provision --secure full > "$PL_PROV_S"

    render "${BIF_SRC}/bootgen_secured.bif.in" "${STAGE}/bifs/bootgen_secured.bif" "$PL_GOLDEN"
    render "${BIF_SRC}/bootgen_provision.bif.in" "${STAGE}/bifs/bootgen_provision.bif" "$PL_PROV"
    render "${BIF_SRC}/bootgen_provision_secured.bif.in" "${STAGE}/bifs/bootgen_provision_secured.bif" "$PL_PROV_S"

    # Derived from the rendered product BIF, never generated separately: the point is
    # that it exercises the SAME partition set. Only the key/auth/enc lines come out.
    grep -vE '^[[:space:]]*(authentication|encryption|keysrc|aeskeyfile|pskfile|sskfile)[[:space:]]*=' \
        "${STAGE}/bifs/bootgen_secured.bif" > "${STAGE}/bifs/_selftest.bif"

    # An unfilled @SLOT@ means a template grew one this step does not know about;
    # bootgen would fail on the literal path. Comments stripped first - they name slots.
    for f in "${STAGE}"/bifs/*.bif; do
        if sed 's|//.*||' "$f" | grep -q '@[A-Z0-9_]\+@'; then
            sed 's|//.*||' "$f" | grep -n '@[A-Z0-9_]\+@' >&2
            sb_die "$f still contains an unfilled @SLOT@ marker"
        fi
    done

    # Every file the generated BIFs name must be staged. Both came from the same
    # source, so a miss means they disagree - the bug this arrangement exists to stop.
    missing=0
    while read -r f; do
        case "$f" in keys/*) continue ;; esac
        [ -f "${STAGE}/${f}" ] || {
            echo "  MISSING ${f}" >&2
            missing=1
        }
    done < <(grep -hoE 'file = [^ ]+' "${STAGE}"/bifs/*.bif | sed 's/file = //' | sort -u)
    [ "$missing" -eq 0 ] || sb_die "the generated BIFs reference files that were not staged"

    echo "generated into ${STAGE}/bifs/  (from ${SB_BIF_SRC})"
    printf '  id_code      : %s  ext=%s  id=%s\n' "$SB_ID_CODE" "$SB_EXT_ID_CODE" "$SB_BIF_ID"
    printf '  device       : %s\n' "$SB_DEVICE"
    printf '  app core     : %s (%s)\n' "$APP_ATTR" "$ELF_CLASS"
    printf '  image blocks : %s\n' "$("$XSA_BIF" "$XSA_DIR" --emit part-names | tr '\n' ' ')"
}

# ------------------------------------------------- 4. non-secured self-test
sb_step_selftest() {
    STAGE=${SB_PKG_STAGE:-${BASE_DIR}/_pkg}

    [ -d "${STAGE}/bifs" ] || sb_die "$STAGE has no bifs/ - did the render-BIFs step run?"

    # bootgen resolves BIF paths against its CWD. For these BIFs that is the package
    # root, which is exactly the position the Key Manager will be in.
    cd "$STAGE" || exit 1

    # Block names read out of the generated BIFs, not written down: a literal list
    # would assert "what we typed is present", which is true of a wrong board too.
    parts_of() { grep -oE '^[[:space:]]*name = [A-Za-z0-9_]+' "$1" | awk '{print $3}' | tr '\n' ' '; }
    GOLDEN_PARTS=$(parts_of bifs/_selftest.bif)
    PROV_PARTS=$(parts_of bifs/bootgen_provision.bif)
    if [ -z "$GOLDEN_PARTS" ] || [ -z "$PROV_PARTS" ]; then
        sb_die "no image block names found in the generated BIFs"
    fi

    # The device comes from the XSA too. bootgen needs it for the golden image
    # (the encrypted one will not build without -p) and it is board data, not ours.
    eval "$("$XSA_BIF" "${BASE_DIR}/xsa_files" --emit meta)"
    [ -n "$SB_DEVICE" ] || sb_die "no fpgaDevice in the XSA"

    # bootgen drops an unplaceable partition WITHOUT failing - exits 0, shorter image.
    # Dump captured, not piped to grep -q, which would SIGPIPE bootgen.
    check_parts() {
        local image=$1 want=$2 layout missing=0 p
        layout=$(bootgen -arch versal -read "$image" 2> /dev/null)
        for p in $want; do
            # anchored on the image header line ("+---Image: <name> [id:...]") so a
            # name cannot be matched by a substring of some other partition's
            if printf '%s\n' "$layout" | grep -qE "Image: ${p} \["; then
                printf '    ok      %s\n' "$p"
            else
                printf '    MISSING %s\n' "$p"
                missing=1
            fi
        done
        [ "$missing" -eq 0 ] || {
            echo "ERROR: $image is missing the partitions marked above." >&2
            echo "       bootgen exits 0 when it drops one, so the image looks fine." >&2
            echo "       Do NOT ship this package." >&2
            exit 1
        }
        printf '%s\n' "$layout" | grep -E '^\+---|^ *\|__' || true
    }

    echo "== golden, unsigned =="
    bootgen -arch versal -image bifs/_selftest.bif -w \
        -o nonsecured/BOOT_NONSECURED.BIN -p "$SB_DEVICE"
    check_parts nonsecured/BOOT_NONSECURED.BIN "$GOLDEN_PARTS"

    echo
    echo "== eFUSE provisioning, unsigned =="
    bootgen -arch versal -image bifs/bootgen_provision.bif -w \
        -o nonsecured/BOOT_PROVISION.BIN -p "$SB_DEVICE"
    check_parts nonsecured/BOOT_PROVISION.BIN "$PROV_PARTS"

    # bootgen drops an empty optional_data.txt beside every image. Harmless, but it
    # would be zipped and listed in the manifest as a material.
    rm -f nonsecured/optional_data.txt

    # The self-test image is not shipped: its value was in being built and read back.
    # It cannot be signed, and only boots an unprovisioned board - BOOT_PROVISION's job.
    rm -f nonsecured/BOOT_NONSECURED.BIN

    echo
    echo "self-test PASS - every partition the signed images need is present."
    echo "  nonsecured/BOOT_PROVISION.BIN   (kept: goes in the primary slot)"
    echo "  BOOT_NONSECURED.BIN              (built, checked, then discarded)"
    echo
    echo "NOTE: BOOT_PROVISION.BIN is unsigned. It boots only a board whose"
    echo "      PPK0_HASH is not burned yet; afterwards the ROM rejects it (0x345)."
}

# --------------------------------------------------------- 5. manifest + zip
sb_step_zip() {
    STAGE=${SB_PKG_STAGE:-${BASE_DIR}/_pkg}
    ZIP=${SB_PKG_ZIP:-${PROJ}/non-secured_image.zip}
    # --no-zip: run the guards, write the manifest, leave the staged tree for
    # wrap-package.sh --secured to tar. Guards are the point, so only the zip is skipped.
    NO_ZIP=${SB_PKG_NO_ZIP:-0}

    [ -d "${STAGE}/bifs" ] || sb_die "$STAGE is not staged - run the earlier steps first."
    [ -f "${STAGE}/.pkg_sources" ] || sb_die "${STAGE}/.pkg_sources missing - re-run step 2."
    # Declared before the source so a truncated .pkg_sources is caught below, not as an
    # unbound variable halfway through the manifest - or a manifest with a blank field.
    mblp_src=
    prov_src=
    xsa_src=
    fpt_src=
    fwtool_src=
    bootscr_src=
    # shellcheck source=/dev/null
    . "${STAGE}/.pkg_sources"
    for v in mblp_src prov_src xsa_src fpt_src fwtool_src bootscr_src; do
        [ -n "${!v}" ] || sb_die "${STAGE}/.pkg_sources has no ${v} - re-run step 2."
    done

    # ------------------------------------------------------------------- guards
    # Key material must never reach the zip. Same set .gitignore keeps out of the repo.
    echo "== key-material guard =="
    mapfile -t LEAKS < <(find "$STAGE" \( \
        -name '*.nky' -o -name '*.pem' -o -name '*.key' -o \
        -name 'secret_key*' -o -name 'ppk0_hash*' -o \
        -name 'efuse_keys*' -o -name 'authenticatedJtagImage*' \) -print | sort)
    if [ "${#LEAKS[@]}" -gt 0 ]; then
        echo "ERROR: key material in the staging tree - refusing to build the zip:" >&2
        printf '  %s\n' "${LEAKS[@]}" >&2
        exit 1
    fi
    echo "  ok  no key files staged"

    # A symlinked keys/ would be followed by 'zip -r' and its contents archived.
    # The Key Manager creates that link after unpacking; it must never exist here.
    if [ -e "${STAGE}/keys" ]; then
        sb_die "${STAGE}/keys exists - the package must ship without a key tree."
    fi
    echo "  ok  no keys/ in the package root"

    # Warn, not fail - mblp-prov.elf is reported separately below. Low-variety runs
    # dropped: binary padding reads as 'AAAA...'. Threshold 8 distinct of 64.
    echo
    echo "== 64-hex scan =="
    while IFS= read -r f; do
        rel=${f#"$STAGE"/}
        [ "$rel" = mblp_prov/files/mblp-prov.elf ] && continue
        # a re-run on an already-staged tree would otherwise flag its own manifest,
        # which records the .efuse_keys sha256
        [ "$rel" = manifest.txt ] && continue
        # awk exits 1 if any match has real variety. Status set in END from a flag: exit
        # inside a rule runs END anyway, and an 'exit 0' there would overwrite it.
        grep -aoE '[0-9A-Fa-f]{64}' "$f" 2> /dev/null | sort -u | awk '
        { delete seen; n = 0
          for (i = 1; i <= 64; i++) { c = substr($0, i, 1)
              if (!(c in seen)) { seen[c] = 1; n++ } }
          if (n >= 8) varied = 1 }
        END { exit(varied ? 1 : 0) }' && continue
        printf '  WARN  64-hex string found in %s\n' "$rel"
    done < <(grep -ralE '[0-9A-Fa-f]{64}' "$STAGE" 2> /dev/null | sort)

    mapfile -t APP_HEX < <(strings -a "${STAGE}/mblp_prov/files/mblp-prov.elf" \
        | grep -xE '[0-9A-Fa-f]{64}' | sort -u)
    printf '  mblp-prov.elf: %d 64-hex string(s)\n' "${#APP_HEX[@]}"

    # ------------------------------------------- .efuse_keys section state
    # This, not the hex scan, decides it: the injector writes raw bytes, not strings.
    ek_section() {
        readelf -SW "$1" | sed 's/^ *\[ *[0-9]\+\] *//' \
            | awk '$1 == ".efuse_keys" {
                 for (i = 6; i <= NF; i++) if ($i ~ /^[A-Za-z]+$/) { f = $i; break }
                 print $4, $5, f; exit }'
    }

    # The product and the provisioning ELF differ by this section and little else, so
    # each is checked for the one it must have - a swapped --smc/--prov is silent.
    APP_ELF="${STAGE}/mblp_prov/files/mblp-prov.elf"
    EK_STATE=absent
    EK_SHA=-
    EK_SIZE=0
    EK_FLAGS=-
    read -r ek_off ek_size EK_FLAGS < <(ek_section "$APP_ELF")
    if [ -n "${ek_off:-}" ]; then
        EK_SIZE=$((16#$ek_size))
        EK_FLAGS=${EK_FLAGS:-none}
    fi

    # No allocated slot means the Key Manager has nowhere to inject - which is what a
    # product ELF looks like here: a linker leftover, 0 bytes and not ALLOC.
    case "$EK_FLAGS" in *A*) ek_alloc=1 ;; *) ek_alloc=0 ;; esac
    if [ "$EK_SIZE" -eq 0 ] || [ "$ek_alloc" -eq 0 ]; then
        [ -n "${ek_off:-}" ] && EK_STATE="empty section header"
        printf '  .efuse_keys : %s, %d bytes, flags=%s\n' "$EK_STATE" "$EK_SIZE" "$EK_FLAGS"
        echo "ERROR: ${APP_ELF##*/} has no allocated .efuse_keys slot." >&2
        echo "       The provisioning ELF carries a 328-byte ALLOC section; the product" >&2
        echo "       one carries an empty header. Check --prov is not the product ELF." >&2
        exit 1
    fi

    ek_bin=$(mktemp)
    dd if="$APP_ELF" bs=1 skip=$((16#$ek_off)) count="$EK_SIZE" status=none of="$ek_bin"
    EK_SHA=$(sha256sum "$ek_bin" | cut -d' ' -f1)
    # all-0xff means no key has been injected yet
    if [ "$(tr -d '\377' < "$ek_bin" | wc -c)" -eq 0 ]; then
        EK_STATE="unprogrammed (all 0xff)"
    else
        EK_STATE="PROGRAMMED - carries data"
    fi
    rm -f "$ek_bin"
    printf '  .efuse_keys : %s, %d bytes, flags=%s\n' "$EK_STATE" "$EK_SIZE" "$EK_FLAGS"

    # A programmed section at Developer handover means keys are in the package. That
    # is the Key Manager's output, never the Developer's, so it stops the zip.
    case "$EK_STATE" in
        PROGRAMMED*)
            echo "ERROR: ${APP_ELF##*/} has a programmed .efuse_keys section." >&2
            echo "       The Developer package must ship the app with keys NOT injected -" >&2
            echo "       an injected one holds the red key and is key material itself." >&2
            echo "       Take the unprogrammed provisioning ELF from mango-bsp and re-run." >&2
            exit 1
            ;;
    esac

    # The mirror check: an allocated slot in the product ELF means the provisioning
    # ELF was staged as the product one, and the product image would ship a key slot.
    MBLP_ELF="${STAGE}/mblp/files/mblp.elf"
    read -r _ g_size g_flags < <(ek_section "$MBLP_ELF")
    if [ -n "${g_size:-}" ] && [ $((16#$g_size)) -gt 0 ] && [ "${g_flags:-}" != "${g_flags#*A}" ]; then
        printf '  mblp        : .efuse_keys %d bytes, flags=%s\n' "$((16#$g_size))" "$g_flags"
        echo "ERROR: ${MBLP_ELF##*/} has an allocated .efuse_keys slot." >&2
        echo "       That is the provisioning ELF - check --smc and --prov are not swapped." >&2
        exit 1
    fi
    printf '  mblp        : no allocated .efuse_keys slot (correct)\n'

    # ----------------------------------------------------------------- manifest
    echo
    echo "== manifest =="
    MANIFEST="${STAGE}/manifest.txt"
    PLNX_VER=$(sed -n 's/^PETALINUX_VER=//p' "${PROJ}/.petalinux/metadata" 2> /dev/null || true)
    MM_VER=$(git -C "$SB_DIR" describe --always --dirty 2> /dev/null || echo unknown)
    # Gated by preflight above; recorded because the two mango-bsp ELFs are
    # the only inputs the Key Manager cannot rebuild.
    BSP_VER=${SB_PKG_BSP_VER:-}
    if [ -z "$BSP_VER" ]; then
        BSP_VER=$(dpkg-query -W -f='${Version}' mango-bsp 2> /dev/null || true)
    fi

    # From the same parser the BIFs were rendered from, not a constant: these differ
    # per design, and a manifest that names the wrong one is worse than none.
    SB_ID_CODE=
    SB_DEVICE=
    eval "$("$XSA_BIF" "${BASE_DIR}/xsa_files" --emit meta 2> /dev/null)" || true

    fp() { sha256sum "$1" | cut -d' ' -f1; }
    mt() { date -r "$1" -u '+%Y-%m-%d %H:%M:%S UTC'; }

    {
        echo "# non-secured secure-boot package, built by _make_zip.sh."
        echo "# Unpack with 'unzip -d <dir>': the archive has no top-level directory,"
        echo "# because bootgen resolves the BIF paths against the package root."
        echo "# Contains NO key material. Create keys/ in the package root after"
        echo "# unpacking - _sign_secure_boot.sh does it."
        echo
        printf 'board_xsa      : %s  sha256=%s\n' "$(basename "$xsa_src")" "$(fp "$xsa_src")"
        printf 'id_code        : %s   device=%s\n' "${SB_ID_CODE:-unknown}" "${SB_DEVICE:-unknown}"
        printf 'petalinux      : %s\n' "${PLNX_VER:-unknown}"
        printf 'meta-mango     : %s\n' "$MM_VER"
        printf 'mango-bsp      : %s\n' "${BSP_VER:-unknown}"
        printf 'mblp.elf       : sha256=%s  mtime=%s\n' "$(fp "$mblp_src")" "$(mt "$mblp_src")"
        printf 'mblp.elf src   : %s\n' "$mblp_src"
        printf 'mblp-prov.elf  : sha256=%s  mtime=%s\n' "$(fp "$prov_src")" "$(mt "$prov_src")"
        printf 'mblp-prov.elf src: %s\n' "$prov_src"
        printf 'fpt.bin src    : %s\n' "$fpt_src"
        printf 'boot.scr src   : %s\n' "$bootscr_src"
        # The injector, pinned like the ELF it writes into: the two are one contract, and
        # a mismatched pair burns at the wrong offset. This line shows the pair.
        printf 'fw-tool.py     : sha256=%s  mtime=%s\n' "$(fp "$fwtool_src")" "$(mt "$fwtool_src")"
        printf 'fw-tool.py src : %s\n' "$fwtool_src"
        printf 'generated      : %s\n' "$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
        echo
        # What the injection will overwrite, and proof of what it held at handover. The
        # sha256 is the useful field - it pins the contents whatever the encoding.
        echo "--- mblp-prov.elf key slot at handover ---"
        printf '.efuse_keys    : %s\n' "$EK_STATE"
        printf '.efuse_keys sz : %d bytes, flags=%s\n' "$EK_SIZE" "$EK_FLAGS"
        printf '.efuse_keys sha256: %s\n' "$EK_SHA"
        if [ "${#APP_HEX[@]}" -eq 0 ]; then
            echo '64-hex strings : (none)'
        else
            printf '64-hex strings :\n'
            printf '  %s\n' "${APP_HEX[@]}"
        fi
        echo
        echo "--- files ---"
        # sorted so two packages built from the same materials diff cleanly
        (cd "$STAGE" && find bifs common mblp mblp_prov images nonsecured -type f | sort \
            | while IFS= read -r f; do printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"; done)
    } > "$MANIFEST"

    printf '  %s (%s files)\n' "$MANIFEST" "$(grep -c '^[0-9a-f]\{64\}  ' "$MANIFEST")"

    # ---------------------------------------------------------------------- zip
    if [ "$NO_ZIP" -ne 0 ]; then
        echo
        echo "== zip =="
        printf '  skipped (--no-zip); staged tree left at %s\n' "$STAGE"
        exit 0
    fi

    echo
    echo "== zip =="
    # Replace rather than update: 'zip' merges into an existing archive by default,
    # so a file dropped from the package would survive in the old zip forever.
    rm -f "$ZIP"
    mkdir -p "$(dirname "$ZIP")"
    # Named entries, not '.', so .pkg_sources stays out and the archive gets no
    # top-level directory - _pkg_unpack.sh chooses the destination with 'unzip -d'.
    (cd "$STAGE" && zip -q -r -X "$ZIP" manifest.txt bifs common mblp mblp_prov images nonsecured)

    printf '  %s (%s)\n' "$ZIP" "$(du -h "$ZIP" | cut -f1)"
}

usage() {
    cat << EOF
Usage: files/_make_zip.sh [options]   (from scripts/secure_boot/)

Runs, in order:
  1. unpack board XSA        the partition files and the XSA's own BIF
  2. collect materials       only what a BIF names, into common/ mblp/ mblp_prov/
  3. render BIFs             board file names resolved, package-relative paths
  4. non-secured self-test   build both images without keys; prove nothing is lost
  5. manifest + zip          sha256 every file, guard against key material, pack

Options:
  --smc  <path>   ELF for the r5-0 partition of the golden image
                  (default: $SMC)
  --prov <path>   eFUSE provisioning app ELF - the one with the .efuse_keys slot
                  (default: $PROV)
  --fpt  <path>   flash partition table for program.sh -f
                  (default: $FPT)
  --boot-scr <p>  u-boot script for program.sh -f (default: $BOOTSCR)
  --fw-tool <path> injector for the provisioning ELF's .efuse_keys slot,
                  staged into the package as common/fw-tool.py
                  (default: $FWTOOL)
  --bsp-min <d>   oldest mango-bsp release date (YYMMDD) accepted by preflight
                  (default: $BSP_MIN). 0 skips the check - only for a host
                  where mango-bsp was not installed from apt.
  --out  <path>   output zip (default: $OUT)
  --stage <dir>   staging directory, wiped on every run
                  (default: files/_pkg)
  --no-zip        run every check and write the manifest, but leave the staged
                  tree instead of zipping it. For a caller that packages the
                  tree itself - scripts/wrap-package.sh --secured does this.
  -v, --verbose   stream each step's output instead of only PASS/FAIL
  -h, --help      this text

The two ELFs come from mango-bsp's $BSP_DIR, not from this project, and
are staged as mblp.elf / mblp-prov.elf whatever they are called there - the
rendered BIFs are written against the package layout. Which mango-bsp they came
from is checked against --bsp-min and recorded in manifest.txt, because they are
the inputs the Key Manager cannot rebuild. The provisioning ELF is the one whose
.efuse_keys section is allocated; both are checked, so a swap cannot pass.

No key is read and none is written. The zip is checked for key material before
it is created, and the package deliberately ships without a keys/ directory:
the Key Manager creates it after unpacking. Every step's full output is kept
under $LOG_ROOT/ regardless of --verbose.
EOF
}

# VERBOSE below is consumed by _steplib.sh, which shellcheck cannot see
# from here because the source happens above this loop.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
    case "$1" in
        --smc)
            SMC=${2:?--smc needs a path}
            shift 2
            ;;
        --prov)
            PROV=${2:?--prov needs a path}
            shift 2
            ;;
        --fpt)
            FPT=${2:?--fpt needs a path}
            shift 2
            ;;
        --boot-scr)
            BOOTSCR=${2:?--boot-scr needs a path}
            shift 2
            ;;
        --fw-tool)
            FWTOOL=${2:?--fw-tool needs a path}
            shift 2
            ;;
        --bsp-min)
            BSP_MIN=${2:?--bsp-min needs a YYMMDD date or 0}
            shift 2
            ;;
        --out)
            OUT=${2:?--out needs a path}
            shift 2
            ;;
        --stage)
            STAGE=${2:?--stage needs a path}
            shift 2
            ;;
        --no-zip)
            NO_ZIP=1
            shift
            ;;
        -v | --verbose)
            VERBOSE=1
            shift
            ;;
        -h | --help)
            usage
            exit 0
            ;;
        *)
            echo "unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$BSP_MIN" in
    0 | [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *)
        echo "--bsp-min takes a release date as YYMMDD, or 0: got '$BSP_MIN'" >&2
        exit 2
        ;;
esac

sb_colors

# ------------------------------------------------------------------ preflight
sb_pf_init
sb_pf_tools bootgen unzip zip sha256sum readelf strings sed grep

if [ -d "$IMG_DIR" ]; then
    sb_pf_ok "project: $PROJ"
else
    sb_pf_bad "$IMG_DIR not found - run petalinux-build first (PLNX_PROJ=$PROJ)"
fi
if [ -f "${PROJ}/project-spec/hw-description/system.xsa" ]; then
    sb_pf_ok "system.xsa present"
else
    sb_pf_bad "${PROJ}/project-spec/hw-description/system.xsa not found"
fi

# First, because the release decides what the two ELFs are called: "wrong
# release" beats "mblp-prov.elf not found" from one that names it differently.
sb_pf_bsp_min "$BSP_MIN"

# Before the XSA unpack spends a minute, because these are the ones a Developer
# forgets: two come from another repo, the third needs an unfamiliar recipe.
for f in "$SMC" "$PROV" "${IMG_DIR}/plm-prov.elf" "$FPT" "$FWTOOL" "$BOOTSCR"; do
    if [ -f "$f" ]; then
        sb_pf_ok "$(basename "$f"): $f"
    else
        sb_pf_bad "$(basename "$f") not found: $f"
        [ "$f" = "${IMG_DIR}/plm-prov.elf" ] \
            && sb_pf_cmd "Please run:" "petalinux-build -c plm-firmware-efuse"
        [ "$f" = "$FPT" ] \
            && sb_pf_hint "program.sh -f writes it at offset 0x0; override with --fpt"
        [ "$f" = "$FWTOOL" ] \
            && sb_pf_hint "mango-bsp installs it beside mblp-prov.elf; override with --fw-tool"
    fi
done

# The staging tree is wiped on every run and then zipped whole. Pointed inside
# the key tree, that would both destroy keys and ship them.
case "$(readlink -f "$STAGE")/" in
    "$(readlink -f "$SCRIPT_DIR")"/keys/*)
        sb_pf_bad "--stage is inside files/keys/ - refusing"
        ;;
    *) sb_pf_ok "stage: $STAGE" ;;
esac

sb_pf_done

# ---------------------------------------------------------------------- steps
# Self-test before the zip: a FAIL there must leave no zip behind.
# shellcheck disable=SC2034
STEPS=(
    "unpack board XSA|sb_step_get_xsa|"
    "collect materials|sb_step_collect|"
    "render BIFs|sb_step_render_bifs|"
    "non-secured self-test|sb_step_selftest|"
    "manifest + zip|sb_step_zip|"
)

# Paths reach the steps through the environment rather than as step arguments,
# which _steplib.sh word-splits.
export SB_PKG_STAGE="$STAGE"
export SB_PKG_SMC="$SMC"
export SB_PKG_PROV="$PROV"
export SB_PKG_FPT="$FPT"
export SB_PKG_FWTOOL="$FWTOOL"
export SB_PKG_BOOTSCR="$BOOTSCR"
export SB_PKG_ZIP="$OUT"
export SB_PKG_NO_ZIP="$NO_ZIP"
# Set by preflight; the manifest records which mango-bsp the two ELFs came from.
export SB_PKG_BSP_VER="${SB_BSP_VER:-}"

RUN_ID=$(date '+%Y%m%d-%H%M%S')
LOG_DIR="${LOG_ROOT}/${RUN_ID}-pkg"
mkdir -p "$LOG_DIR"

printf '%s== non-secured package ==%s\n' "$C_BLD" "$C_OFF"
printf 'project      : %s\n' "$PROJ"
printf 'golden elf   : %s\n' "$SMC"
printf 'prov elf     : %s\n' "$PROV"
printf 'fw tool      : %s\n' "$FWTOOL"
if [ "$NO_ZIP" -eq 1 ]; then
    printf 'package      : (--no-zip) %s\n' "$STAGE"
else
    printf 'package      : %s\n' "$OUT"
fi
printf 'logs         : %s/%s/\n\n' "$SCRIPT_DIR" "$LOG_DIR"

sb_run_steps
sb_summary || exit 1

printf '%sRESULT: PASS%s\n' "$C_GRN" "$C_OFF"
if [ "$NO_ZIP" -eq 1 ]; then
    printf '  staged   : %s\n' "$STAGE"
else
    printf '  package  : %s\n' "$OUT"
fi
printf '  manifest : %s/manifest.txt\n' "$STAGE"
echo
if [ "$NO_ZIP" -eq 1 ]; then
    echo "  The staged tree is the package; the caller archives it."
else
    echo "  Hand the zip to the Key Manager. It holds no key material; they create"
    echo "  keys/ in the package root after unpacking."
fi
echo "  The self-test images inside are unsigned - they are proof the materials"
echo "  are complete, not something to flash on a provisioned board."
