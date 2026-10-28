#!/bin/bash
set -uo pipefail

# Key Manager step 2, from the Developer's package: unpack+verify, sign, inject the
# eFUSE values, build both burn images, verify. No hardware touched. See README.md.

# Lives in files/ (internal: key_manager.sh runs it); every path below is relative
# to scripts/secure_boot/, one level up, exactly as before the move.
SCRIPT_DIR=$(dirname "$(dirname "$(readlink -f "$0")")")
cd "$SCRIPT_DIR" || exit 1

FILES_DIR=files
PROJ=${PLNX_PROJ:-$(readlink -f "${SCRIPT_DIR}/../../../..")}
LOG_ROOT=${FILES_DIR}/logs
# Derived once here; the step bodies use them. Steps are subshells, so a local
# re-derivation would be harmless anyway.
BASE_DIR="${SCRIPT_DIR}/${FILES_DIR}" # files/, absolute
SB_DIR="$SCRIPT_DIR"                  # scripts/secure_boot/, absolute

# All derivable - a signing run is one command. Archive from the project root,
# package beside it, keys where _gen_keys.sh puts them.
TGZ=
PKG="${PROJ}/sign"
KEYS="${BASE_DIR}/secure_boot_keys"
BIF=bifs/bootgen_secured.bif
OUT=
# The handover archive for the flashing operator, in the project root beside the
# package it came from. Derived from that package's name so board and date carry.
FLASH_TGZ=
NO_UNPACK=0
UNPACK_ONLY=0
PRODUCT_ONLY=0
FIRST_BURN=0
PURE=0
VERBOSE=0

# shellcheck source=files/_steplib.sh
. "${FILES_DIR}/_steplib.sh"

# ============================== Steps =======================================
# Subshells: exit/cd stay local. Bodies at column 0 - indenting breaks heredocs.

# --------------------------------------------------------- 1. unpack + verify
sb_step_unpack() {
    ARCHIVE=${1:-}
    DEST=${2:-}

    fail=0

    if [ -z "$ARCHIVE" ]; then sb_die "no archive given"; fi
    [ -n "$DEST" ] || sb_die "no destination given"
    [ -f "$ARCHIVE" ] || sb_die "not found: $ARCHIVE"
    # Resolved now, while the caller's working directory is still the one they typed
    # the path against: everything below reads it after cd'ing elsewhere.
    ARCHIVE=$(readlink -f "$ARCHIVE")

    case "$ARCHIVE" in
        *.tgz | *.tar.gz) KIND=tar ;;
        *.zip) KIND=zip ;;
        *) sb_die "unknown archive type: $ARCHIVE (expected .tgz, .tar.gz or .zip)" ;;
    esac
    [ "$KIND" = tar ] || command -v unzip > /dev/null 2>&1 || sb_die "unzip not found in PATH"

    echo "archive : $ARCHIVE"
    echo "sha256  : $(sha256sum "$ARCHIVE" | cut -d' ' -f1)"
    echo "dest    : $DEST"
    echo

    # ------------------------------------------------------------------- keys link
    # Saved before the wipe, restored after - re-linking by hand is what gets forgotten.
    KEEP_LINK=
    if [ -L "${DEST}/keys" ]; then
        KEEP_LINK=$(readlink "${DEST}/keys")
        echo "keys    : keeping the existing symlink -> $KEEP_LINK"
    elif [ -d "${DEST}/keys" ]; then
        # A real directory means key material is sitting inside the destination about
        # to be wiped. Refuse rather than delete it: that tree may be the only copy.
        sb_die "${DEST}/keys is a real directory, not a symlink - refusing to wipe it. Move the key tree outside the package and link to it."
    fi

    if [ -e "$DEST" ]; then
        echo "dest    : removing the existing tree"
        rm -rf "$DEST" || sb_die "cannot remove $DEST"
    fi
    mkdir -p "$DEST" || sb_die "cannot create $DEST"

    # ---------------------------------------------------------------------- unpack
    echo
    echo "== unpack =="
    if [ "$KIND" = tar ]; then
        tar xzf "$ARCHIVE" -C "$DEST" || sb_die "tar failed"
    else
        unzip -q -d "$DEST" "$ARCHIVE" || sb_die "unzip failed"
    fi
    printf '  %d file(s)\n' "$(find "$DEST" -type f | wc -l)"

    # Restored or created here rather than left to the operator - forgetting it does not
    # fail loudly, bootgen just resolves keys/ to nothing.
    if [ -n "${SB_KEY_ROOT:-}" ]; then
        ln -sfn "$(readlink -f "$SB_KEY_ROOT")" "${DEST}/keys"
        echo "  keys -> $(readlink "${DEST}/keys")"
    elif [ -n "$KEEP_LINK" ]; then
        ln -sfn "$KEEP_LINK" "${DEST}/keys"
        echo "  keys -> $KEEP_LINK (restored)"
    fi

    MF="${DEST}/manifest.txt"
    [ -f "$MF" ] || sb_die "no manifest.txt in the package - cannot verify anything. This is not a package this flow can sign from."

    # ------------------------------------------------------------------- key guard
    # The Developer side refuses to ship these; same list, checked from this end.
    echo
    echo "== key-material guard =="
    mapfile -t LEAKS < <(find "$DEST" \( \
        -name '*.nky' -o -name '*.pem' -o -name '*.key' -o \
        -name 'secret_key*' -o -name 'ppk0_hash*' -o \
        -name 'efuse_keys*' -o -name 'authenticatedJtagImage*' \) -print | sort)
    if [ "${#LEAKS[@]}" -gt 0 ]; then
        sb_bad "the package carries key material:"
        printf '         %s\n' "${LEAKS[@]}"
    else
        sb_pass "no key files in the package"
    fi

    # -------------------------------------------------------------------- manifest
    # Every line: the only thing between an edited partition and a signature over it.
    echo
    echo "== manifest =="
    MF_LINES=$(sed -n '/^--- files ---/,$p' "$MF" | grep -cE '^[0-9a-f]{64}  ')
    if [ "$MF_LINES" -eq 0 ]; then
        sb_bad "manifest.txt has no file list - nothing could be checked"
    else
        CHECK=$(cd "$DEST" && sed -n '/^--- files ---/,$p' manifest.txt \
            | grep -E '^[0-9a-f]{64}  ' | sha256sum -c 2>&1)
        if
            BADS=$(printf '%s\n' "$CHECK" | grep -vE ': OK$')
            [ -n "$BADS" ]
        then
            sb_bad "$MF_LINES file(s) listed, and these did not match:"
            printf '%s\n' "$BADS" | sed 's/^/         /'
        else
            sb_pass "all $MF_LINES listed file(s) match their sha256"
        fi

        # A file present but unlisted is not covered by the check above. It is not a
        # signing input unless a BIF names it, but it also has no business being here.
        mapfile -t UNLISTED < <(
            cd "$DEST" || exit 0
            find . -type f -not -name manifest.txt -printf '%P\n' \
                | grep -vE '^(README\.md|program\.sh|build_info\.txt|halt_cores\.tcl)$' \
                | grep -vE '^program_flash/' | sort > /tmp/.pkg_have.$$
            sed -n '/^--- files ---/,$p' manifest.txt | grep -E '^[0-9a-f]{64}  ' \
                | sed 's/^[0-9a-f]\{64\}  //' | sort > /tmp/.pkg_want.$$
            comm -23 /tmp/.pkg_have.$$ /tmp/.pkg_want.$$
            rm -f /tmp/.pkg_have.$$ /tmp/.pkg_want.$$
        )
        if [ "${#UNLISTED[@]}" -gt 0 ]; then
            sb_warn "in the package but not in the manifest:"
            printf '         %s\n' "${UNLISTED[@]}"
        fi
    fi

    # ---------------------------------------------------------------------- report
    # For a person to compare - the package has nothing to check these against.
    echo
    echo "== what this package says it is =="
    mf_field() { sed -n "s/^$1 *: *//p" "$MF" | head -1; }
    printf '  board_xsa      : %s\n' "$(mf_field board_xsa)"
    printf '  id_code        : %s\n' "$(mf_field id_code)"
    printf '  petalinux      : %s\n' "$(mf_field petalinux)"
    printf '  meta-mango     : %s\n' "$(mf_field meta-mango)"
    printf '  mango-bsp      : %s\n' "$(mf_field mango-bsp)"
    printf '  fw-tool.py     : %s\n' "$(mf_field 'fw-tool\.py')"
    printf '  .efuse_keys    : %s\n' "$(mf_field '\.efuse_keys')"
    echo
    echo "  Compare board_xsa against what you were told to expect. Signing the"
    echo "  wrong board's materials produces an image that builds clean, passes"
    echo "  every check here, and does not boot."

    # The provisioning ELF must arrive unprogrammed. A programmed one is the Key
    # Manager's own output and has no business coming from a Developer.
    case "$(mf_field '\.efuse_keys')" in
        unprogrammed*) ;;
        '') sb_warn "manifest records no .efuse_keys state" ;;
        *) sb_bad "the provisioning ELF arrived with keys already injected - do not sign this package" ;;
    esac

    echo
    if [ "$fail" -eq 0 ]; then
        echo "RESULT: PASS - the package is intact and carries no keys."
        printf '  package : %s\n' "$DEST"
        if [ -L "${DEST}/keys" ]; then
            printf '  keys    : %s\n' "$(readlink "${DEST}/keys")"
        else
            printf '  next    : link a key tree in:  ln -s <keydir> %s/keys\n' "$DEST"
        fi
    else
        echo "RESULT: FAIL - do NOT sign from this package."
    fi
    exit "$fail"
}

# ---------------------------------------------------------------- 2. AUTH_JTAG
sb_step_authjtag() {
    cd "$BASE_DIR" || exit 1
    # --keys puts the tree outside this directory, so the committed BIF's keys/RSA/...
    # does not resolve. Re-rendered per run with an absolute path.
    KEY_ROOT=${SB_KEY_ROOT:-keys}
    PSK_FILE=${KEY_ROOT}/RSA/psk1_rsa.pem
    BIF_SRC=bifs/bootgen_auth_jtag.bif
    # Signed over, and checked by the PLM against the REVOKE_ID rows before the
    # signature: a revoked ID is refused however good its PPK. key_manager.sh sets it.
    REVOKE_ID=${SB_AUTHJTAG_REVOKE_ID:-0}
    # bootgen ignores -o here and writes this fixed name into its CWD, so it is moved
    # up afterwards. The one artifact left in scripts/secure_boot/ - handed to a person.
    BOOTGEN_OUT=authenticatedJtagImage-rsa.bin
    OUT="${SB_DIR}/${BOOTGEN_OUT}"
    # fixed by the format: a 2048-byte AUTH_JTAG message, not a boot image
    EXPECT_SIZE=2048

    if [ ! -f "$BIF_SRC" ]; then
        echo "ERROR: bif not found: $BIF_SRC" >&2
        exit 1
    fi

    if [ ! -f "$PSK_FILE" ]; then
        echo "ERROR: $PSK_FILE not found." >&2
        echo "Run ./key_manager.sh --gen-keys first to generate the RSA key pair." >&2
        exit 1
    fi

    if ! [[ "$REVOKE_ID" =~ ^[0-9]+$ ]] || [ "$REVOKE_ID" -gt 255 ]; then
        echo "ERROR: SB_AUTHJTAG_REVOKE_ID must be 0..255, got '$REVOKE_ID'" >&2
        exit 1
    fi
    REVOKE_HEX=$(printf '0x%02x' "$REVOKE_ID")

    # Always a rendered copy, never the committed BIF: it carries the absolute key
    # path (--keys puts the tree outside files/) and this run's revoke ID.
    WORK=$(mktemp -d) || {
        echo "ERROR: cannot create a temp directory" >&2
        exit 1
    }
    trap 'rm -rf "$WORK"' EXIT
    BIF="${WORK}/bootgen_auth_jtag.bif"
    sed -E -e "s#^([[:space:]]*pskfile[[:space:]]*=[[:space:]]*).*#\1$(readlink -f "$PSK_FILE")#" \
        -e "s#^([[:space:]]*revoke_id[[:space:]]*=[[:space:]]*).*#\1${REVOKE_HEX}#" \
        "$BIF_SRC" > "$BIF" || {
        echo "ERROR: cannot render $BIF" >&2
        exit 1
    }
    if [ "$(grep -cE '^[[:space:]]*revoke_id[[:space:]]*=' "$BIF")" -ne 1 ]; then
        echo "ERROR: $BIF_SRC must carry exactly one revoke_id line to render" >&2
        exit 1
    fi

    rm -f "$BOOTGEN_OUT" "$OUT"

    # -authenticatedjtag is mandatory: the auth_jtag: section alone is parsed but
    # produces no message, and bootgen still exits 0.
    bootgen -arch versal -image "$BIF" -authenticatedjtag rsa

    if [ ! -f "$BOOTGEN_OUT" ]; then
        echo "ERROR: bootgen reported success but wrote no ${BOOTGEN_OUT}." >&2
        echo "       Check that ${BIF} still has its auth_jtag: section." >&2
        exit 1
    fi

    # A short or empty file means bootgen parsed the BIF but signed nothing, which
    # it does not report as an error - the device would just refuse the message.
    size=$(stat -c %s "$BOOTGEN_OUT")
    if [ "$size" -ne "$EXPECT_SIZE" ]; then
        echo "ERROR: ${BOOTGEN_OUT} is ${size} bytes, expected ${EXPECT_SIZE}." >&2
        echo "       Do not use it - the message is not a valid AUTH_JTAG image." >&2
        exit 1
    fi

    # The ID bootgen signed over sits at 0x04 (little-endian u32) of the message:
    # confirmed by building the same BIF with 0x00, 0x05 and 0x1f and diffing.
    got=$(od -An -tu4 -j4 -N4 "$BOOTGEN_OUT" | tr -d ' ')
    if [ "$got" != "$REVOKE_ID" ]; then
        echo "ERROR: ${BOOTGEN_OUT} carries revoke_id ${got}, the BIF asked for ${REVOKE_ID}." >&2
        echo "       Do not use it - the device would check it against the wrong REVOKE_ID bit." >&2
        exit 1
    fi

    mv "$BOOTGEN_OUT" "$OUT"

    echo "AUTH_JTAG message: $OUT (${size} bytes)"
    echo "  signed with    : $PSK_FILE"
    echo "  revoke_id      : ${REVOKE_HEX} (${REVOKE_ID}; must not be revoked on the card this unlocks)"
    echo "NOTE: this grants JTAG access to any device holding the matching PPK hash."
    echo "      It is signed with the PRIMARY key - keep it with the key owner and"
    echo "      do NOT ship it."
}

# ----------------------------------------------------------- 3. product image
sb_step_bootgen() {
    WORK_DIR=${SB_WORK_DIR:-$BASE_DIR}
    cd "$WORK_DIR" || exit 1
    # project root derived from scripts/secure_boot, one level above files/;
    # override with PLNX_PROJ if meta-mango lives outside the project
    SB_DIR=$(dirname "$BASE_DIR")
    PROJ=${PLNX_PROJ:-$(readlink -f "${SB_DIR}/../../../..")}
    # Where an image lands by default. In package mode that is the package root: the
    # project's images/linux does not exist on a machine that never built anything.
    if [ -n "${SB_WORK_DIR:-}" ]; then
        OUT_DIR=$WORK_DIR
    else
        OUT_DIR="${PROJ}/images/linux"
    fi

    # Args: [bif] [output]. Encrypted BIFs only - it drives the .nky Key 0 / IV
    # patching below, so a BIF without encryption must NOT be passed.
    BIF=${1:-bifs/bootgen_secured.bif}
    OUT=${2:-${OUT_DIR}/BOOT_SECURED.BIN}

    if [ ! -f "$BIF" ]; then
        echo "ERROR: BIF not found: $BIF" >&2
        echo "BIFs live in bifs/ - pass the path, e.g. bifs/bootgen_secured.bif" >&2
        exit 1
    fi

    if [ ! -d "$OUT_DIR" ]; then
        echo "ERROR: $OUT_DIR not found." >&2
        [ -n "${SB_WORK_DIR:-}" ] || echo "Run petalinux-build first. (PLNX_PROJ resolved to: $PROJ)" >&2
        exit 1
    fi

    # a default output name per BIF, so a test image never overwrites the
    # production one when only the BIF is passed (uppercased to match BOOT_SECURED.BIN)
    if [ $# -eq 1 ]; then
        OUT="${OUT_DIR}/BOOT_$(basename "$BIF" .bif | tr '[:lower:]' '[:upper:]').BIN"
    fi

    # The part, for bootgen -p. Passed in from the package manifest's id_code line so
    # a different board is not signed as this one.
    DEV=${SB_BOOTGEN_DEV:-xcvp1202}

    KEY_ROOT=keys
    # bootgen writes the per-partition .nky files here (aeskeyfile paths in the BIF)
    KEY_DIR=${KEY_ROOT}/AES
    SECRET_KEY_FILE=${KEY_ROOT}/secret_key.txt

    if [ ! -f "$SECRET_KEY_FILE" ]; then
        echo "ERROR: $SECRET_KEY_FILE not found." >&2
        echo "Run ./key_manager.sh --gen-keys first to generate a new secret key." >&2
        exit 1
    fi

    SECRET_KEY=$(grep -oE '[0-9a-fA-F]{64}' "$SECRET_KEY_FILE")

    if [ -z "$SECRET_KEY" ]; then
        echo "ERROR: no 64-hex key found in $SECRET_KEY_FILE." >&2
        echo "The file is corrupted. Delete it and run ./key_manager.sh --gen-keys for a new one." >&2
        exit 1
    fi

    # bootgen does not create the key directory itself
    mkdir -p "$KEY_DIR"

    # A leftover .nky with a different Key0 fails as "Key0 must be same across the BIF".
    # ./*.nky is not redundant: bootgen writes ./pmc_data.nky in its CWD.
    rm -f "$KEY_DIR"/*.nky ./*.nky

    # 1st run: generate .nky key files (image here is encrypted with random keys)
    bootgen -arch versal -image "./$BIF" -log debug -w -o "$OUT" -p "$DEV"

    # replace every Key 0 with the secret key, in keys/AES/ and in the stray
    # ./pmc_data.nky described above
    sed -i -E "s/^(Key 0[[:space:]]+)[0-9a-fA-F]+;/\1${SECRET_KEY};/" "$KEY_DIR"/*.nky ./*.nky

    # Pin IV 0 of the metaheader and PLM keys; the rest stay random. From
    # files/_efuse_iv.sh via BASE_DIR - in package mode the CWD is the package root.
    # shellcheck source=../_efuse_iv.sh
    . "${BASE_DIR}/_efuse_iv.sh"
    METAHEADER_IV0=$SB_METAHEADER_IV0
    PLM_IV0=$SB_PLM_IV0
    sed -i -E "s/^(IV 0[[:space:]]+)[0-9a-fA-F]+;/\1${METAHEADER_IV0};/" "$KEY_DIR"/mango_metaheader.nky
    sed -i -E "s/^(IV 0[[:space:]]+)[0-9a-fA-F]+;/\1${PLM_IV0};/" "$KEY_DIR"/mango_plm.nky

    # 2nd run: rebuild the image so it is actually encrypted with the replaced Key 0 / IV 0
    bootgen -arch versal -image "./$BIF" -log debug -w -o "$OUT" -p "$DEV"
}

# ------------------------------------------------------------- 4. inject keys
sb_step_inject() {
    cd "$BASE_DIR" || exit 1
    # No default on purpose: two flows own a provisioning ELF, and guessing between
    # them is how the wrong one gets injected and signed. The caller names it.
    ELF=${1:-}
    KEYFILE=${2:-keys/efuse_keys.txt}

    # SB_EFUSE_WRITE overrides; unset, the arm list comes from the key file's own ARMED
    # line. Two places with an opinion about an OTP write is two that can disagree.
    WANT=${SB_EFUSE_WRITE:-}

    fail=0

    if [ -z "$ELF" ]; then sb_die "no provisioning ELF given"; fi

    [ -f "$ELF" ] || sb_die "not found: $ELF"
    [ -f "$KEYFILE" ] || sb_die "not found: $KEYFILE (run ./key_manager.sh --gen-keys first)"
    command -v python3 > /dev/null 2>&1 || sb_die "python3 not found in PATH"

    if [ -z "$WANT" ]; then
        WANT=$(sed -n -E 's/^ARMED[[:space:]]*=[[:space:]]*//p' "$KEYFILE" | head -1)
        ARM_FROM="${KEYFILE} (ARMED)"
        [ -n "$WANT" ] || sb_die "$KEYFILE has no ARMED line and \$SB_EFUSE_WRITE is unset - nothing says which fuses to arm"
    else
        ARM_FROM="\$SB_EFUSE_WRITE"
    fi

    # ------------------------------------------------------------------- the tool
    # From the package, never /etc/mango/firmware - tool and ELF are one contract.
    PKG_ROOT=$(readlink -f "$(dirname "$ELF")/../..")
    for cand in "${SB_FW_TOOL:-}" "${PKG_ROOT}/common/fw-tool.py"; do
        [ -n "$cand" ] || continue
        [ -f "$cand" ] || continue
        FW_TOOL=$cand
        break
    done
    if [ -z "${FW_TOOL:-}" ]; then
        echo "ERROR: no fw-tool.py at ${PKG_ROOT}/common/fw-tool.py" >&2
        echo "       The injector ships inside the package, next to the materials." >&2
        echo "       A package without it cannot be provisioned from: ask for one" >&2
        echo "       rebuilt by a packaging run that stages it. Do not substitute a" >&2
        echo "       copy from elsewhere - the tool and mblp-prov.elf are one pair," >&2
        echo "       and a mismatched pair writes values at the wrong offset." >&2
        echo "       \$SB_FW_TOOL overrides this, for a path you have checked yourself." >&2
        exit 2
    fi

    # The pair, checked not assumed: a tool that is not the one manifest.txt records
    # writes by a layout this ELF's reader was not built against. eFUSE is OTP.
    MF="${PKG_ROOT}/manifest.txt"
    if [ -f "$MF" ]; then
        MF_SHA=$(sed -n 's/^fw-tool\.py *: *sha256=\([0-9a-f]\{64\}\).*/\1/p' "$MF" | head -1)
        GOT_SHA=$(sha256sum "$FW_TOOL" | cut -d' ' -f1)
        if [ -z "$MF_SHA" ]; then
            sb_warn "manifest.txt records no fw-tool.py sha256 - the pair cannot be checked"
        elif [ "$MF_SHA" != "$GOT_SHA" ]; then
            echo "ERROR: the injector is not the one this package was built with." >&2
            printf '       manifest : %s\n' "$MF_SHA" >&2
            printf '       in use   : %s\n' "$GOT_SHA" >&2
            echo "       Refusing: a tool and an ELF from different releases can" >&2
            echo "       disagree about where a field sits, and the burn is OTP." >&2
            exit 2
        fi
    fi

    # The arm list reaches the tool comma-separated; SB_EFUSE_WRITE is spaces.
    ARM_CSV=$(printf '%s' "$WANT" | tr -s '[:space:]' ',' | sed 's/^,//; s/,$//')

    echo "elf     : $ELF"
    echo "keyfile : $KEYFILE"
    echo "tool    : $FW_TOOL"
    printf 'arm     : %s   (from %s)\n' "$WANT" "$ARM_FROM"
    echo

    # ------------------------------------------------------------------ prior state
    # Before the write, so a re-injection says so rather than being discovered after.
    BEFORE=$(python3 "$FW_TOOL" "$ELF" get efuse_keys 2>&1)
    if printf '%s\n' "$BEFORE" | grep -q 'no keys injected'; then
        echo "before  : not injected (the linked 0xff placeholder)"
    else
        echo "before  : already injected - this run replaces it"
        printf '%s\n' "$BEFORE" | sed 's/^/          /'
    fi
    echo

    # ----------------------------------------------------------------- inject
    echo "== inject =="
    if ! python3 "$FW_TOOL" "$ELF" set efuse_keys "$KEYFILE" --arm "$ARM_CSV"; then
        echo
        # The tool named its own reason above, and it is more specific than anything an
        # exit status could say. This only reports where the ELF stands.
        echo "ERROR: injection failed - see the tool's reason above." >&2
        echo "       A bad arm list or key file is refused before anything is written," >&2
        echo "       so the ELF is unchanged; confirm with:" >&2
        echo "         python3 ${FW_TOOL} ${ELF} get efuse_keys" >&2
        exit 1
    fi
    echo

    # ----------------------------------------------------------------------- verify
    # Read back through the tool: the only thing that parses those bytes as firmware will.
    echo "== verify =="
    AFTER=$(python3 "$FW_TOOL" "$ELF" get efuse_keys 2>&1) || {
        printf '%s\n' "$AFTER" >&2
        sb_die "cannot read .efuse_keys back out of $ELF"
    }
    printf '%s\n' "$AFTER" | sed 's/^/  /'
    echo

    field() { printf '%s\n' "$AFTER" | sed -n "s/^ *$1 *: *//p" | head -1; }

    # Sorted, so the comparison is of sets and not of the order somebody typed.
    norm() { printf '%s' "$1" | tr ',' ' ' | tr -s '[:space:]' '\n' | sed '/^$/d' | sort | tr '\n' ' '; }

    WANT_SET=$(norm "$WANT")
    ARMED_SET=$(norm "$(field armed)")
    LOADED_SET=$(norm "$(field loaded)")

    if [ "$(field version)" = 1 ]; then
        sb_pass "version 1"
    else
        sb_bad "version is '$(field version)', not 1 - this tool and that ELF disagree on the layout"
    fi

    case "$(field crc32)" in
        0x*) sb_pass "crc32 $(field crc32)" ;;
        *) sb_bad "no crc32 in the readback - the blob was not written" ;;
    esac

    if [ "$ARMED_SET" = "$WANT_SET" ]; then
        sb_pass "armed: $ARMED_SET"
    else
        sb_bad "armed list is not what was asked for"
        printf '         asked : %s\n' "$WANT_SET"
        printf '         blob  : %s\n' "$ARMED_SET"
    fi

    # The tool writes a value only for a field it armed, so these two agreeing is
    # what says no unasked-for value rode along into the slot.
    if [ "$LOADED_SET" = "$ARMED_SET" ]; then
        sb_pass "every armed field carries a value, and nothing else does"
    else
        sb_bad "the values in the blob are not the armed set"
        printf '         armed  : %s\n' "$ARMED_SET"
        printf '         loaded : %s\n' "$LOADED_SET"
    fi

    echo

    # Not a defect either way - the app must hold a value to burn it - but which one it
    # is decides how the file may be handled.
    case " $WANT_SET " in
        *" AES_KEY "*)
            sb_warn "AES_KEY is armed, so this ELF now carries the red key."
            sb_warn "  Treat $(basename "$ELF") and every image built from it as key material."
            sb_warn "  It is raw bytes in a binary slot, so 'strings' will not show it:"
            sb_warn "    python3 $(basename "$FW_TOOL") $(basename "$ELF") get efuse_keys"
            ;;
        *)
            sb_pass "AES_KEY is not armed, so the red key is not in this ELF"
            ;;
    esac

    echo
    if [ "$fail" -eq 0 ]; then
        echo "RESULT: PASS - the slot holds the armed fields and nothing else."
    else
        echo "RESULT: FAIL - do NOT build a burn image from this ELF."
    fi
    exit "$fail"
}

# ------------------------------------------------------------- 5. burn images
sb_step_provgen() {
    WORK_DIR=${SB_WORK_DIR:-$BASE_DIR}
    cd "$WORK_DIR" || exit 1
    DEV=${SB_BOOTGEN_DEV:-xcvp1202}

    fail=0

    SECRET_KEY=$(grep -oE '[0-9a-fA-F]{64}' "${SB_KEY_ROOT}/secret_key.txt" 2> /dev/null)
    [ -n "$SECRET_KEY" ] || sb_die "no 64-hex key in ${SB_KEY_ROOT}/secret_key.txt"

    PROV_ELF=mblp_prov/files/mblp-prov.elf
    [ -f "$PROV_ELF" ] || sb_die "not found: ${WORK_DIR}/${PROV_ELF}"

    # An image built from the 0xff placeholder boots and refuses to burn, which reads
    # as "the burn did not take". The injection step runs before this one for that.
    if grep -qa MEFK "$PROV_ELF"; then
        sb_pass "$PROV_ELF carries an injected key blob"
    else
        sb_bad "$PROV_ELF has no key blob - run _efuse_inject.sh first"
        echo "         An image built from the placeholder cannot burn anything." >&2
        exit 1
    fi
    echo

    for pair in "bifs/bootgen_provision.bif:BOOT_PROVISION.BIN:unsigned - before PPK0 is burned" \
        "bifs/bootgen_provision_secured.bif:BOOT_PROVISION_SECURED.BIN:signed - for eFUSE work after the burn"; do
        bif=${pair%%:*}
        rest=${pair#*:}
        out=${rest%%:*}
        what=${rest#*:}

        if [ ! -f "$bif" ]; then
            sb_bad "$bif not found in the package"
            continue
        fi

        printf '== %s ==\n' "$out"
        printf '  bif   : %s   (%s)\n' "$bif" "$what"
        rm -f "$out"
        # Never delete the .nky files here. The product step pinned METAHEADER_IV and
        # PLM_IV into two of them, and those are the values the eFUSEs hold.
        if ! bootgen -arch versal -image "./$bif" -w -o "$out" -p "$DEV" > /dev/null 2>&1; then
            sb_bad "bootgen failed for $bif"
            bootgen -arch versal -image "./$bif" -w -o "$out" -p "$DEV" 2>&1 | tail -20
            continue
        fi

        # Encrypted image: every .nky it names needs the red key. The app
        # partition's .nky is new - bootgen invented a random Key 0 - so substitute
        # and rebuild. IV 0 lines are untouched, so the two pinned IVs survive.
        if grep -q 'aeskeyfile' "$bif"; then
            sed -i -E "s/^(Key 0[[:space:]]+)[0-9a-fA-F]+;/\1${SECRET_KEY};/" \
                keys/AES/*.nky ./*.nky 2> /dev/null
            if ! bootgen -arch versal -image "./$bif" -w -o "$out" -p "$DEV" > /dev/null 2>&1; then
                sb_bad "bootgen second pass failed for $bif"
                continue
            fi
        fi
        if [ -s "$out" ]; then
            sb_pass "$(du -h "$out" | cut -f1)  ${WORK_DIR}/${out}"
        else
            sb_bad "$out was not written"
        fi
        echo
    done

    if [ "$fail" -ne 0 ]; then
        echo "RESULT: FAIL - the burn images were not both built."
        exit 1
    fi

    echo "RESULT: PASS - both provisioning images built."
    echo "  These carry the red key if AES_KEY was armed. Treat them as key material:"
    echo "  a controlled path, once per board family, discarded after the burn."
}

# ------------------------------------------------------------------ 6. verify
sb_step_verify() {
    WORK_DIR=${SB_WORK_DIR:-$BASE_DIR}
    cd "$WORK_DIR" || exit 1
    # same derivation as the build step, so the default input is
    # exactly what that step produced
    SB_DIR=$(dirname "$BASE_DIR")
    PROJ=${PLNX_PROJ:-$(readlink -f "${SB_DIR}/../../../..")}
    BIN=${1:-${PROJ}/images/linux/BOOT_SECURED.BIN}
    KEY_ROOT=${SB_KEY_ROOT:-keys}
    KEY_DIR=${KEY_ROOT}/AES
    SECRET_KEY_FILE=${KEY_ROOT}/secret_key.txt
    # What the burn will write, as _gen_keys.sh wrote it. Comparing against the record
    # the burn is actually done from - not against a recipe patch, as this once did.
    KEYFILE=${KEY_ROOT}/efuse_keys.txt

    # Versal boot header / IHT offsets, each confirmed against 'bootgen -read' output
    # on a built image. Do not adjust without re-reading one.
    BH_KEYSRC_OFF=0x18
    BH_PLM_IV_OFF=0x64
    BH_METAHDR_OFF_OFF=0xc4
    IHT_IV_OFF=0x34
    KEYSRC_EFUSE_RED=A5C3C5A3

    fail=0

    [ -f "$BIN" ] || sb_die "not found: $BIN (did the build step run? see 'build product image' above)"
    [ -f "$SECRET_KEY_FILE" ] || sb_die "not found: $SECRET_KEY_FILE (run ./key_manager.sh --gen-keys first)"
    [ -f "$KEYFILE" ] || sb_die "not found: $KEYFILE (run ./key_manager.sh --gen-keys first)"

    # read `len` bytes at `off` as an uppercase hex string, byte order as stored
    raw_hex() { xxd -p -s "$2" -l "$3" "$1" | tr -d '\n' | tr 'a-f' 'A-F'; }

    # read a little-endian u32 as a decimal number
    le32() {
        local h
        h=$(xxd -p -s "$2" -l 4 "$1" | tr -d '\n')
        printf '%d' "0x${h:6:2}${h:4:2}${h:2:2}${h:0:2}"
    }

    # IV 0 of a .nky file
    nky_iv0() { grep -E '^IV 0[[:space:]]' "$1" | grep -oE '[0-9A-Fa-f]{24}' | tr 'a-f' 'A-F'; }

    # Value of a "NAME = VALUE" line, uppercased. A field this flow does not set is
    # "-", which returns empty - the same as absent, which is what it means.
    kf_val() {
        sed -n -E "s/^$1[[:space:]]*=[[:space:]]*([0-9A-Fa-f]+).*/\1/p" "$KEYFILE" \
            | head -1 | tr 'a-f' 'A-F'
    }

    # the ARMED list: which fields this burn actually writes
    kf_armed() { sed -n -E 's/^ARMED[[:space:]]*=[[:space:]]*//p' "$KEYFILE" | head -1; }
    is_armed() { case " $(kf_armed) " in *" $1 "*) return 0 ;; *) return 1 ;; esac }

    echo "image : $BIN"
    echo

    # ---------------------------------------------------------------- keysrc
    echo "[1] Key source (image must be built for the eFUSE red key)"
    keysrc=$(raw_hex "$BIN" "$BH_KEYSRC_OFF" 4)
    # stored little-endian: A5C3C5A3 -> A3C5C3A5
    keysrc_be="${keysrc:6:2}${keysrc:4:2}${keysrc:2:2}${keysrc:0:2}"
    if [ "$keysrc_be" = "$KEYSRC_EFUSE_RED" ]; then
        sb_pass "encryption_keystore = 0x${keysrc_be} (efuse_red_key)"
    else
        sb_bad "encryption_keystore = 0x${keysrc_be}, expected 0x${KEYSRC_EFUSE_RED} (efuse_red_key)"
        sb_warn "the bif keysrc is wrong - the image will not decrypt with the eFUSE key"
    fi
    echo

    # ---------------------------------------------------------------- IVs
    metahdr_off=$(le32 "$BIN" "$BH_METAHDR_OFF_OFF")
    img_plm_iv=$(raw_hex "$BIN" "$BH_PLM_IV_OFF" 12)
    img_mh_iv=$(raw_hex "$BIN" "$((metahdr_off + IHT_IV_OFF))" 12)

    nky_plm_iv=$(nky_iv0 "$KEY_DIR/mango_plm.nky" 2> /dev/null)
    nky_mh_iv=$(nky_iv0 "$KEY_DIR/mango_metaheader.nky" 2> /dev/null)
    pat_plm_iv=$(kf_val PLM_IV)
    pat_mh_iv=$(kf_val METAHEADER_IV)

    printf '[2] IV consistency  (metahdr_offset = 0x%x)\n' "$metahdr_off"
    check_iv() {
        local name=$1 img=$2 nky=$3 pat=$4 nkyfile=$5
        if [ -z "$img" ]; then
            sb_bad "$name: could not read IV from image"
            return
        fi
        if [ -z "$nky" ]; then
            sb_bad "$name: no IV 0 in $nkyfile"
            return
        fi
        if [ -z "$pat" ]; then
            sb_bad "$name: no value in $KEYFILE"
            return
        fi
        if [ "$img" = "$nky" ] && [ "$img" = "$pat" ]; then
            sb_pass "$name = $img   (image == $nkyfile == efuse_keys.txt)"
        else
            sb_bad "$name mismatch"
            printf '         image        : %s\n' "$img"
            printf '         %-13s: %s\n' "$(basename "$nkyfile")" "$nky"
            printf '         efuse_keys   : %s\n' "$pat"
        fi
    }
    check_iv "MetaHeader IV" "$img_mh_iv" "$nky_mh_iv" "$pat_mh_iv" "$KEY_DIR/mango_metaheader.nky"
    check_iv "PLM IV       " "$img_plm_iv" "$nky_plm_iv" "$pat_plm_iv" "$KEY_DIR/mango_plm.nky"

    # IV reuse breaks AES-GCM: the same IV under the same key leaks the keystream
    if [ -n "$img_mh_iv" ] && [ "$img_mh_iv" = "$img_plm_iv" ]; then
        sb_bad "MetaHeader IV and PLM IV are identical - IV reuse under the same key"
    fi
    for iv in "$img_mh_iv" "$img_plm_iv"; do
        [ "$iv" = "000000000000000000000000" ] && sb_bad "an IV is all zeros"
    done
    echo

    # ------------------------------------------------- burned-IV flag coverage
    echo "[3] armed fuses vs. what the image actually pins"
    printf '  armed : %s\n' "$(kf_armed)"
    # Verified but unarmed = the fuse stays blank, so the ROM never checks the image
    # against it. Worth saying, not failing: a burned board is left out on purpose.
    for pair in "METAHEADER_IV:MetaHeader IV" "PLM_IV:PLM IV"; do
        n=${pair%%:*}
        label=${pair#*:}
        if is_armed "$n"; then
            sb_pass "$n is armed ($label is burned and verified above)"
        else
            sb_warn "$n is not armed - $label will not be burned, so the ROM will not"
            sb_warn "  check the image against it. Correct only if it is already burned."
        fi
    done
    # These two are left random per partition by the build step, so a
    # fixed eFUSE range would be compared against a value that changes every build.
    for pair in "DATA_PARTITION_IV:pmccdo_sec_hdr_iv" "BLACK_IV:black/obfuscated IV"; do
        n=${pair%%:*}
        label=${pair#*:}
        if is_armed "$n"; then
            sb_bad "$n is armed but $label is left random by the build step"
            printf '         burning it would fix in silicon a value the image varies\n'
        fi
    done
    echo

    # ------------------------------------------ AES key (source level only)
    echo "[4] AES red key  (source level only - never present in the image)"
    KEY=$(grep -oE '[0-9a-fA-F]{64}' "$SECRET_KEY_FILE" | tr 'a-f' 'A-F')
    if [ -z "$KEY" ]; then
        sb_bad "no 64-hex key in $SECRET_KEY_FILE"
    else
        n_nky=0
        n_bad=0
        for f in "$KEY_DIR"/*.nky ./*.nky; do
            [ -e "$f" ] || continue
            n_nky=$((n_nky + 1))
            k=$(grep -E '^Key 0[[:space:]]' "$f" | grep -oE '[0-9A-Fa-f]{64}' | tr 'a-f' 'A-F')
            if [ "$k" != "$KEY" ]; then
                sb_bad "Key 0 mismatch in $f"
                n_bad=$((n_bad + 1))
            fi
        done
        [ "$n_nky" -eq 0 ] && sb_bad "no .nky files found - did the build step's first bootgen pass run?"
        [ "$n_nky" -gt 0 ] && [ "$n_bad" -eq 0 ] && sb_pass "Key 0 == $SECRET_KEY_FILE in all $n_nky .nky files"
        if [ "$(kf_val AES_KEY)" = "$KEY" ]; then
            sb_pass "efuse_keys.txt AES_KEY == $SECRET_KEY_FILE"
        else
            sb_bad "efuse_keys.txt AES_KEY != $SECRET_KEY_FILE"
        fi
    fi
    echo

    # --------------------------------------- encrypted boot vs. the key the part holds
    # Every signed image here is encrypted throughout with keysrc = efuse_red_key, so
    # the AES row has to hold this exact key for any of them to boot. That is checked
    # against the arm list below, because the two failures it can produce - a plaintext
    # block, or a key that is not there - both end with a board that boots nothing.
    #
    # bifs/bootgen_provision.bif is exempt: it is the unsigned, plaintext image that
    # performs the burn, so it runs before PPK0_HASH is sealed and never boots after.
    echo "[5] encrypted boot vs. the AES key the part holds"
    # DEC_ONLY first, because it is the one arm-list entry that cannot be recovered
    # from. _gen_keys.sh refuses it; an efuse_keys.txt that carries it was hand-edited.
    if is_armed DEC_ONLY; then
        sb_bad "DEC_ONLY is armed - this flow refuses it"
        printf '         S-HWRoT decrypts ONLY with a PUF KEK (efuse_black_key), and every\n'
        printf '         BIF here is keysrc = efuse_red_key. The ROM would refuse every\n'
        printf '         image this flow builds (0x308), then exhaust the address range\n'
        printf '         (0x30F). LP R.2 was lost this way on 2026-08-05.\n'
        printf '         Do not burn this key file. Regenerate it with ./key_manager.sh --gen-keys.\n'
    else
        sb_pass "DEC_ONLY is not armed (S-HWRoT needs a PUF KEK; this flow is red key)"
    fi
    # The images are encrypted whether or not the ROM demands it, so this walk runs every
    # time: a plaintext block is a build defect here, not a DEC_ONLY-only concern.
    #
    # Brace-walked, not grep-counted: counts that happen to add up say nothing about
    # which block the line was in.
    plaintext_blocks() {
        awk '
            {
                line = $0
                sub(/\/\/.*/, "", line)
                if (line ~ /^[[:space:]]*(partition|metaheader)[[:space:]]*$/) {
                    pending = $1
                    start = NR
                }
                no = gsub(/\{/, "", line)
                nc = gsub(/\}/, "", line)
                if (pending != "" && no > 0) {
                    name = pending
                    pending = ""
                    enc = 0
                    blockdepth = depth + 1
                }
                if (line ~ /encryption[[:space:]]*=[[:space:]]*aes/) enc = 1
                depth += no - nc
                if (name != "" && depth < blockdepth) {
                    if (enc == 0) printf "%s at line %d\n", name, start
                    name = ""
                }
            }
        ' "$1"
    }
    for b in bifs/bootgen_secured.bif bifs/bootgen_provision_secured.bif; do
        if [ ! -f "$b" ]; then
            sb_bad "$b not found - cannot confirm it is encrypted throughout"
            continue
        fi
        plain=$(plaintext_blocks "$b")
        n_blocks=$(grep -cE '^[[:space:]]*(partition|metaheader)[[:space:]]*$' "$b")
        if [ -z "$plain" ]; then
            sb_pass "$b: all $n_blocks blocks encrypted"
        else
            sb_bad "$b has a block with no 'encryption = aes':"
            printf '%s\n' "$plain" | sed 's/^/           /'
            printf '         This flow encrypts these images throughout - defence in depth on\n'
            printf '         top of the RSA check. Fix the BIF before anything is burned.\n'
        fi
    done
    # The image demands a key the ROM reads from the AES row. The default arms AES_KEY, so
    # the same burn writes it; dropping it is only correct on a part that already holds
    # this key, and nothing here can see the part. Say which case the run is in.
    if is_armed AES_KEY; then
        sb_pass "AES_KEY is armed - the burn writes the key these images need"
    else
        sb_warn "AES_KEY is not armed, so this burn does not write the red key. These"
        sb_warn "  images are encrypted with keysrc = efuse_red_key, so the part must"
        sb_warn "  ALREADY hold this exact key ($SECRET_KEY_FILE) or it boots none of"
        sb_warn "  them once PPK0_HASH is burned and the ROM enforces RSA. Confirm the"
        sb_warn "  key with a read-back CRC check, or add AES_KEY to _gen_keys.sh's"
        sb_warn "  --efuse-write list and regenerate efuse_keys.txt."
    fi
    echo

    if [ "$fail" -eq 0 ]; then
        echo "RESULT: PASS - image IVs match the eFUSE values that will be burned."
        echo "        (a PASS does not prove the eFUSEs were burned correctly;"
        echo "         read them back with the provisioning app after burning)"
    else
        echo "RESULT: FAIL - do NOT burn eFUSEs or flash this image. eFUSE is OTP."
    fi
    exit "$fail"
}

usage() {
    cat << EOF
Usage: files/_sign_secure_boot.sh [options]

Internal: key_manager.sh runs this. Run it by hand only to debug one signing run.

Runs, in order:
  1. unpack package          unpack the .tgz, verify every sha256 in manifest.txt
  2. AUTH_JTAG message       authenticatedJtagImage-rsa.bin, from the PSK
  3. build product image     bootgen two-pass -> BOOT_SECURED.BIN
  4. inject eFUSE values     efuse_keys.txt -> mblp-prov.elf's .efuse_keys
  5. build burn images       BOOT_PROVISION{,_SECURED}.BIN
  6. verify image vs eFUSE   image IVs vs the .nky files vs efuse_keys.txt, every
                             block encrypted, and DEC_ONLY not armed
  7. pack for flashing       BOOT_SECURED.BIN + BOOT_PROVISION_SECURED.BIN
                             (+ BOOT_PROVISION.BIN with --first-burn, or
                              BOOT_PROVISION.BIN instead of it with --pure)

Options:
  --tgz <path>     the Developer's package. Default: the one
                   *-secured-img.tgz in $PROJ
  --package <dir>  where to unpack it (default: $PKG). Wiped on every run
  --keys <dir>     key tree from ./key_manager.sh --gen-keys (default: $KEYS)
  --bif <path>     product BIF, relative to the package root
                   (default: $BIF)
  --out <path>     product image (default: <package>/BOOT_SECURED.BIN)
  --flash-tgz <p>  handover archive for the flashing operator
                   (default: <proj>/<date>_<machine>-secured-boot.tgz)
  --first-burn     also pack BOOT_PROVISION.BIN into the flash tgz, for the
                   first burn when the flashing operator burns the eFUSEs too.
                   With AES_KEY armed the tgz then carries the red key
  --pure           pack the UNSIGNED BOOT_PROVISION.BIN in place of
                   BOOT_PROVISION_SECURED.BIN, so the tgz is the product image
                   plus the unsigned burn image only - for a board whose PPK0 is
                   not burned yet, where the signed burn image is the one it
                   cannot boot. Exclusive with --first-burn. With AES_KEY armed
                   the tgz carries the red key
  --no-unpack      keep the existing <package> tree instead of re-unpacking.
                   For re-signing or debugging only - it gives up the guarantee
                   that what is signed is what arrived
  --unpack-only    run step 1 only (unpack, verify, link keys/) and stop.
                   Builds nothing. Used by rekey.sh before it edits a BIF
  --product-only   stop after "build product image": no inject, no burn
                   images, no verify, no pack. Combines with --no-unpack.
                   Used by rekey.sh for an image whose BIF the verify step
                   does not know how to check
  -v, --verbose    stream each step's output instead of only PASS/FAIL
  -h, --help       this text

A key set (./key_manager.sh --gen-keys) has to exist first. Nothing here writes to the board. Every
step's full output is kept under $LOG_ROOT/ regardless of --verbose.

Environment:
  SB_AUTHJTAG_REVOKE_ID=<N>  revoke ID the AUTH_JTAG message is signed over
                   (default 0). The PLM refuses a message whose ID the card has
                   revoked, so after any revoke burn this must be the ID the
                   card's images use. key_manager.sh sets it.
EOF
}

# VERBOSE below is consumed by files/_steplib.sh, which shellcheck cannot see
# from here because the source happens above this loop.
# shellcheck disable=SC2034
while [ $# -gt 0 ]; do
    case "$1" in
        --tgz)
            TGZ=${2:?--tgz needs a path}
            shift 2
            ;;
        --package)
            PKG=${2:?--package needs a path}
            shift 2
            ;;
        --keys)
            KEYS=${2:?--keys needs a path}
            shift 2
            ;;
        --bif)
            BIF=${2:?--bif needs a path}
            shift 2
            ;;
        --out)
            OUT=${2:?--out needs a path}
            shift 2
            ;;
        --flash-tgz)
            FLASH_TGZ=${2:?--flash-tgz needs a path}
            shift 2
            ;;
        --no-unpack)
            NO_UNPACK=1
            shift
            ;;
        --unpack-only)
            UNPACK_ONLY=1
            shift
            ;;
        --product-only)
            PRODUCT_ONLY=1
            shift
            ;;
        --first-burn)
            FIRST_BURN=1
            shift
            ;;
        --pure)
            PURE=1
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

# They mean opposite things about the same file: --first-burn adds the unsigned
# burn image next to the signed one, --pure ships it instead of the signed one.
if [ "$UNPACK_ONLY" -eq 1 ] && { [ "$PRODUCT_ONLY" -eq 1 ] || [ "$NO_UNPACK" -eq 1 ]; }; then
    echo "--unpack-only runs the unpack step alone; it takes neither --product-only" >&2
    echo "nor --no-unpack." >&2
    exit 2
fi
if [ "$PURE" -eq 1 ] && [ "$FIRST_BURN" -eq 1 ]; then
    echo "--pure and --first-burn are exclusive: --pure already packs BOOT_PROVISION.BIN," >&2
    echo "and drops BOOT_PROVISION_SECURED.BIN. Pick one." >&2
    exit 2
fi

sb_colors

# ------------------------------------------------------------------ preflight
sb_pf_init
sb_pf_tools bootgen openssl python3 xxd readelf sha256sum sed grep

# ---- the archive
# Found, not typed. Two present is an error - the board must not be guessed.
if [ "$NO_UNPACK" -eq 1 ]; then
    sb_pf_ok "--no-unpack: using the existing tree at $PKG"
    sb_pf_hint "what gets signed is whatever is in there now, not a fresh unpack"
elif [ -n "$TGZ" ]; then
    if [ -f "$TGZ" ]; then
        sb_pf_ok "package: $TGZ"
    else sb_pf_bad "not found: $TGZ"; fi
else
    mapfile -t FOUND < <(find "$PROJ" -maxdepth 1 -name '*-secured-img.tgz' | sort)
    case "${#FOUND[@]}" in
        1)
            TGZ=${FOUND[0]}
            sb_pf_ok "package: $TGZ"
            ;;
        0)
            sb_pf_bad "no *-secured-img.tgz in $PROJ"
            sb_pf_hint "put the Developer's package there, or pass --tgz <path>"
            ;;
        *)
            sb_pf_bad "${#FOUND[@]} packages in $PROJ - name the one to sign with --tgz"
            for f in "${FOUND[@]}"; do sb_pf_hint "$(basename "$f")"; done
            ;;
    esac
fi

# ---- the key set
# Checked, never created. A missing one fails halfway with a half-written image.
SB_KEYS_OK=1
for f in "${KEYS}/secret_key.txt" \
    "${KEYS}/RSA/psk1_rsa.pem" \
    "${KEYS}/RSA/ssk1_rsa.pem" \
    "${KEYS}/efuse_keys.txt"; do
    if [ -f "$f" ]; then
        sb_pf_ok "$(basename "$f")"
    else
        sb_pf_bad "not found: $f"
        SB_KEYS_OK=0
    fi
done
if [ "$SB_KEYS_OK" -eq 0 ]; then
    sb_pf_cmd "Please run:" "./key_manager.sh --gen-keys ${KEYS}"
    sb_pf_hint "this script signs with an existing key set and creates none"
else
    # Every run, because nothing downstream catches an image built correctly from
    # the wrong key set: it builds clean, does not boot, and the OTP is spent.
    SB_PSK_FPR=$(openssl rsa -in "${KEYS}/RSA/psk1_rsa.pem" -pubout -outform DER 2> /dev/null \
        | openssl sha256 -r 2> /dev/null | cut -d' ' -f1)
    sb_pf_ok "psk_fpr: ${SB_PSK_FPR:-<unreadable>}"
    sb_pf_hint "must match the board-family register for the board being signed for"
    SB_ARMED=$(sed -n -E 's/^ARMED[[:space:]]*=[[:space:]]*//p' "${KEYS}/efuse_keys.txt" | head -1)
    sb_pf_ok "armed: ${SB_ARMED}"
    # Named here because preflight is the last thing read before a run that ends in an
    # OTP write, and these three are the ones with no way back.
    case " $SB_ARMED " in
        *" DEC_ONLY "*)
            sb_pf_bad "DEC_ONLY is armed - this flow refuses it. S-HWRoT decrypts only"
            sb_pf_hint "  with a PUF KEK and every BIF here is efuse_red_key, so the part"
            sb_pf_hint "  would boot nothing (0x308, then 0x30F). LP R.2, 2026-08-05."
            sb_pf_hint "  Regenerate efuse_keys.txt with ./key_manager.sh --gen-keys - step 6 fails on it."
            ;;
    esac
    case " $SB_ARMED " in
        *" AES_KEY "*) ;;
        *)
            sb_pf_hint "AES_KEY is not armed: the burn writes no red key, so the part must"
            sb_pf_hint "  already hold it or the signed images will not boot."
            ;;
    esac
    case " $SB_ARMED " in
        *" AES_WR_LK "* | *" PPK0_WR_LK "* | *" PPK1_WR_LK "* | *" PPK2_WR_LK "* | \
            *" USER_KEY0_WR_LK "* | *" USER_KEY1_WR_LK "*)
            sb_pf_hint "a write lock is armed: the fields it seals can never be written"
            sb_pf_hint "  again on that part, so a burn that lands wrong is scrap"
            ;;
    esac
fi

sb_pf_done

KEYS=$(readlink -f "$KEYS")
PKG_ABS=$(readlink -f "$PKG" 2> /dev/null || echo "$PKG")
: "${OUT:=${PKG_ABS}/BOOT_SECURED.BIN}"
# <date>_<machine>-secured-img.tgz in -> <date>_<machine>-secured-boot.tgz out, so
# the two halves of the handover read as a pair.
if [ -z "$FLASH_TGZ" ]; then
    if [ -n "$TGZ" ]; then
        FLASH_TGZ="${PROJ}/$(basename "$TGZ" | sed 's/-secured-img\.tgz$/-secured-boot.tgz/')"
    else
        FLASH_TGZ="${PROJ}/secured-boot.tgz"
    fi
fi

# ------------------------------------------------------- 7. pack for flashing
sb_step_pack() {
    OUT_TGZ=${1:?no output tgz given}
    WORK_DIR=${SB_WORK_DIR:-$BASE_DIR}
    cd "$WORK_DIR" || exit 1

    fail=0

    # The images the flashing operator boots, and a note saying which slot each
    # one goes in. Handing over images alone is how a board ends up bricked.
    PRODUCT=$(basename "${SB_PRODUCT_IMAGE:-BOOT_SECURED.BIN}")
    if [ "${SB_PURE:-0}" = 1 ]; then
        # --pure: the unsigned burn image REPLACES the signed one. For a board whose
        # PPK0 is not burned yet, the signed burn image is the one it cannot boot.
        IMAGES=("$PRODUCT" BOOT_PROVISION.BIN)
    else
        IMAGES=("$PRODUCT" BOOT_PROVISION_SECURED.BIN)
        # --first-burn: the unsigned burn image rides along, for the handover where the
        # flashing operator burns the fuses too. Off by default - two-package delivery.
        [ "${SB_FIRST_BURN:-0}" = 1 ] && IMAGES+=(BOOT_PROVISION.BIN)
    fi
    for f in "${IMAGES[@]}"; do
        [ -f "$f" ] || sb_die "not found: ${WORK_DIR}/${f}"
    done

    # Recorded so the operator can tell one board family's images from another's
    # without opening them. board_xsa comes from the package that was signed.
    mf_field() { sed -n "s/^$1 *: *//p" manifest.txt 2> /dev/null | head -1; }
    NOTE=$(mktemp) || sb_die "cannot create a temp file"
    trap 'rm -f "$NOTE"' EXIT
    {
        printf '# Secure boot images for flashing. GENERATED - do not edit.\n'
        printf '%-14s = %s\n' board_xsa "$(mf_field board_xsa)"
        printf '%-14s = %s\n' id_code "$(mf_field id_code)"
        printf '%-14s = %s\n' psk_fpr "${SB_PSK_FPR:-unknown}"
        printf '%-14s = %s\n' packed_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
        printf '\n'
        for f in "${IMAGES[@]}"; do
            printf '%s  %s\n' "$(sha256sum "$f" | cut -d' ' -f1)" "$f"
        done
        printf '\n'
        printf '# Order. eFUSE is one-time programmable and a wrong burn ends the board.\n'
        printf '#\n'
        printf '#   1. mango-ctl mgmt flash <dev> %s golden\n' "$PRODUCT"
        printf '#      mango-ctl dev reset <dev>            confirm it boots\n'
        if [ "${SB_PURE:-0}" = 1 ] || [ "${SB_FIRST_BURN:-0}" = 1 ]; then
            printf '#   2. burn the eFUSEs with BOOT_PROVISION.BIN (in this tgz), the\n'
            printf '#      UNSIGNED provisioning image - it carries the red key.\n'
        else
            printf '#   2. burn the eFUSEs with the UNSIGNED provisioning image, which is\n'
            printf '#      delivered separately - it carries the red key.\n'
        fi
        printf '#   3. mango-ctl mgmt flash <dev> %s     primary, after the burn\n' "$PRODUCT"
        printf '#\n'
        if [ "${SB_PURE:-0}" = 1 ]; then
            printf '# --pure: this tgz carries ONLY the unsigned burn image. It is for a board\n'
            printf '# whose PPK0 is not burned yet. Once the burn is done an unsigned image is\n'
            printf '# refused (0x345), and eFUSE work from then on needs the SIGNED burn image\n'
            printf '# (BOOT_PROVISION_SECURED.BIN) - not in here, and it cannot be rebuilt later\n'
            printf '# without this same package and key set. Keep it.\n'
        else
            printf '# BOOT_PROVISION_SECURED.BIN is for eFUSE work AFTER the burn, when an\n'
            printf '# unsigned image is refused (0x345). Never both slots unsigned at burn time.\n'
        fi
    } > "$NOTE"

    rm -f "$OUT_TGZ"
    mkdir -p "$(dirname "$OUT_TGZ")" || sb_die "cannot create $(dirname "$OUT_TGZ")"
    # --transform so the note lands under its real name rather than the temp one
    tar czf "$OUT_TGZ" \
        --transform="s|^$(basename "$NOTE")$|flash_notes.txt|" \
        -C "$WORK_DIR" "${IMAGES[@]}" \
        -C "$(dirname "$NOTE")" "$(basename "$NOTE")" || sb_die "tar failed"

    sb_pass "$(du -h "$OUT_TGZ" | cut -f1)  $OUT_TGZ"
    tar tzf "$OUT_TGZ" | sed 's/^/         /'
    echo

    if grep -qE '^ARMED.*AES_KEY' "${SB_KEY_ROOT}/efuse_keys.txt" 2> /dev/null; then
        sb_warn "AES_KEY is armed, so every provisioning image carries the red key."
        sb_warn "  This tgz is key material. Controlled path, and destroy it after use."
    else
        sb_pass "AES_KEY is not armed - no red key in any image"
    fi

    exit "$fail"
}

# ---------------------------------------------------------------------- steps
# Order is the dependency; verify last so its result is the headline.
# shellcheck disable=SC2034
STEPS=(
    "AUTH_JTAG message|sb_step_authjtag|"
    "build product image|sb_step_bootgen|${BIF} ${OUT}"
    "inject eFUSE values|sb_step_inject|${PKG_ABS}/mblp_prov/files/mblp-prov.elf ${KEYS}/efuse_keys.txt"
    "build burn images|sb_step_provgen|"
    "verify image vs eFUSE|sb_step_verify|${OUT}"
    "pack for flashing|sb_step_pack|${FLASH_TGZ}"
)
# --product-only keeps the first two; --unpack-only keeps none of these.
if [ "$PRODUCT_ONLY" -eq 1 ]; then
    STEPS=("${STEPS[@]:0:2}")
elif [ "$UNPACK_ONLY" -eq 1 ]; then
    STEPS=()
fi
if [ "$NO_UNPACK" -eq 0 ]; then
    STEPS=("unpack package|sb_step_unpack|${TGZ} ${PKG_ABS}" "${STEPS[@]}")
fi

# Through the environment, not step arguments, which _steplib.sh word-splits:
# SB_KEY_ROOT = key tree, SB_WORK_DIR = package root (bootgen's CWD).
export SB_KEY_ROOT="$KEYS"
# read by the packing step for its notes file
export SB_PSK_FPR SB_PRODUCT_IMAGE="$OUT"
export SB_WORK_DIR="$PKG_ABS"
export SB_FIRST_BURN="$FIRST_BURN" SB_PURE="$PURE"

RUN_ID=$(date '+%Y%m%d-%H%M%S')
LOG_DIR="${LOG_ROOT}/${RUN_ID}"
mkdir -p "$LOG_DIR"

printf '%s== secure boot flow ==%s\n' "$C_BLD" "$C_OFF"
printf 'package          : %s\n' "${TGZ:-(--no-unpack)}"
printf 'unpacked to      : %s\n' "$PKG_ABS"
printf 'keys             : %s\n' "$KEYS"
printf 'bif              : %s\n' "$BIF"
printf 'product_image    : %s\n' "$OUT"
printf 'logs             : %s/%s/\n\n' "$SCRIPT_DIR" "$LOG_DIR"

# bootgen -p is not set here: it varies per board, lives in the package manifest,
# and that file does not exist until step 1 has run. Each bootgen step reads it.

sb_run_steps
sb_summary || exit 1

if [ "$UNPACK_ONLY" -eq 1 ] || [ "$PRODUCT_ONLY" -eq 1 ]; then
    printf '%sRESULT: PASS%s (partial run: %s)\n' "$C_GRN" "$C_OFF" \
        "$([ "$UNPACK_ONLY" -eq 1 ] && echo --unpack-only || echo --product-only)"
    printf '  package          : %s\n' "$PKG_ABS"
    [ "$PRODUCT_ONLY" -eq 1 ] && printf '  product_image    : %s\n' "$OUT"
    echo "  Nothing here is verified against the eFUSE values. Do not flash from a"
    echo "  partial run unless the caller verifies the image itself (rekey.sh does)."
    exit 0
fi

printf '%sRESULT: PASS%s\n' "$C_GRN" "$C_OFF"
printf '  product_image    : %s\n' "$OUT"
printf '  burn_unsigned    : %s/BOOT_PROVISION.BIN\n' "$PKG_ABS"
printf '  burn_signed      : %s/BOOT_PROVISION_SECURED.BIN\n' "$PKG_ABS"
printf '  jtag_auth        : %s/authenticatedJtagImage-rsa.bin\n' "$SCRIPT_DIR"
printf '  verified against : %s/efuse_keys.txt\n' "$KEYS"
printf '  for the flasher  : %s\n' "$FLASH_TGZ"
echo
if [ "$PURE" -eq 1 ]; then
    echo "--pure: the tgz above carries BOOT_PROVISION.BIN, not the signed one. It"
    echo "burns the fuses and carries the red key when AES_KEY is armed - controlled"
    echo "path, and destroy the tgz after the burn. Keep BOOT_PROVISION_SECURED.BIN"
    echo "from the path above: after the burn it is the only one that still boots,"
    echo "and it cannot be rebuilt from a later package. See README.md."
elif [ "$FIRST_BURN" -eq 1 ]; then
    echo "--first-burn: BOOT_PROVISION.BIN is inside the tgz above. It burns the"
    echo "fuses and carries the red key when AES_KEY is armed - controlled path,"
    echo "and destroy the tgz after the burn. See README.md."
else
    echo "Delivery is two packages, never one - see README.md. The tgz above is the"
    echo "flashing half; BOOT_PROVISION.BIN burns the fuses and goes separately."
fi
