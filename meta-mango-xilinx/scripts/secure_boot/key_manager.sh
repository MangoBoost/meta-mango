#!/bin/bash
set -uo pipefail

# Key Manager: the two images a card is flashed with, for a first burn or a re-burn.
# Nothing touches a board.
#
#   ./key_manager.sh --gen-keys <pkg.tgz> --from <project-dir>   a new state in that project
#                                               [--revoke <N>]    ... with IDs 0..N revoked in its keys
#                                               [--keys-from <tar|dir>]  first state: an existing key set instead of a new one
#   ./key_manager.sh --revoke <N> <state>                         revoke IDs 0..N in an existing state
#   ./key_manager.sh --init <state>                               blank card, first provisioning
#   ./key_manager.sh <before-state> <after-state>                 provisioned card, move to a new state
#
# A project is any directory under files/workspaces/ (the name is free: boostx, boostx-acme, ...).
# A state is <project>/<package name>/ - one Developer package, the key set the card holds
# (or will hold) with it, and the flash tar that gets it there. The first state of a
# project gets a new key set; every later one copies the keys of the project's latest
# state, and a name that is taken gets -1, -2, ... appended.
# Bare key trees still work in place of a state dir, with --tgz naming the package.
#
# --init burns the key set's red key, PPK0 hash, the pinned IVs and PPK0_WR_LK (and any
# REVOKE_ID rows its efuse_keys.txt has a value for). No ARMED line is read.
# A re-burn burns what changed from before to after:
#   new revoke bits      -> into blank REVOKE_ID rows; images carry the highest revoked ID + 1
# The AES key, PPK0 and the IVs are burned by the before set and may not change.
#
# Output: flash-init-<time>.tar (--init) or flash-update-<time>.tar, in the (after) state
# dir's out/ (or the current directory for a bare key tree), holding
#   production_BOOT.BIN  golden  - the image the card boots afterwards
#   provision_BOOT.BIN   primary - burns the fuses, copies golden to primary, resets
# See README.md "Provision".

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
FILES="${SCRIPT_DIR}/files"
HELP="${FILES}/_key_manager_lib.py"
SIGN="${FILES}/_sign_secure_boot.sh"
JTAG="${SCRIPT_DIR}/authenticatedJtagImage-rsa.bin"

die() {
    printf 'key_manager: %s\n' "$*" >&2
    exit 1
}
say() { printf '%s\n' "$*"; }

# ------------------------------------------------------------- workspaces
# files/workspaces/<project>/<state>/. <project> is any directory name; <state> is the
# package name without -secured-img.tgz, with -1, -2, ... appended when that name is
# already a state of the project. A re-provision names two states, before and after:
# the after's keys/ was copied from the project's latest state by --gen-keys and then
# edited by hand. Directory creation order is the card's history.
#   <state>/<package>-secured-img.tgz   the package
#   <state>/keys/                       the key set. The only copy: back it up off this checkout
#   <state>/out/                        flash-*.tar and the notes of every run that targeted this state
#   <state>/.work/                      work trees, key copies shredded on exit
#   <state>/workspace.txt               PROJECT, STATE, PACKAGE, CREATED, FROM, PSK_FPR   history.log  one line per action
# A bare key tree (secret_key.txt at its top) is still accepted wherever a state dir is,
# with --tgz naming the package.
WS_ROOT="${FILES}/workspaces"
WS_FORMAT='mango-key-manager-workspace/2'

is_workspace() { [ -f "${1}/workspace.txt" ] || [ -f "${1}/keys/secret_key.txt" ]; }
# <date>_<machine>-secured-img.tgz -> <date>_<machine>
tgz_state() {
    local b
    b=$(basename "$1")
    [[ "$b" =~ ^([0-9]{6}_.+)-secured-img\.tgz$ ]] || return 1
    printf '%s' "${BASH_REMATCH[1]}"
}
# The manifest checks every run does, done once more when a package is imported.
tgz_check() {
    local mf
    mf=$(tar xzOf "$1" ./manifest.txt 2> /dev/null) || die "$1: no manifest.txt - not a package this flow can sign from"
    grep -qE '^id_code[[:space:]]*:.*device=xcvp1202\b' <<< "$mf" \
        || die "$1: manifest id_code is not device=xcvp1202"
}
ws_field() { sed -n -E "s/^${2}[[:space:]]*=[[:space:]]*//p" "${1}/workspace.txt" 2> /dev/null | head -1; }
ws_log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$2" >> "${1}/history.log"; }
psk_fpr() { openssl rsa -in "$1" -pubout -outform DER 2> /dev/null | openssl sha256 -r 2> /dev/null | cut -d' ' -f1; }
# The one package in a state dir.
ws_tgz() {
    local f n=0 hit=''
    for f in "${1}"/*-secured-img.tgz; do [ -f "$f" ] || continue; n=$((n + 1)); hit=$f; done
    [ "$n" -eq 1 ] || return 1
    printf '%s' "$hit"
}
# The project's latest state: newest workspace.txt CREATED (mtime of keys/secret_key.txt
# for a state without one); ties go to the name that sorts last (-2 after -1).
ws_latest() { # <project-dir>
    local d best='' bt=0 t
    for d in "${1}"/*/; do
        d=${d%/}
        is_workspace "$d" || continue
        t=$(date -d "$(ws_field "$d" CREATED)" +%s 2> /dev/null) || t=$(stat -c %Y "${d}/keys/secret_key.txt" 2> /dev/null) || t=0
        if [ "$t" -gt "$bt" ] || { [ "$t" -eq "$bt" ] && [[ "$d" > "$best" ]]; }; then bt=$t; best=$d; fi
    done
    [ -n "$best" ] || return 1
    printf '%s' "$best"
}

# --gen-keys <pkg.tgz> --from <project-dir> [gen options]
#   <project-dir> is files/workspaces/<name>, or just <name>. Made if missing.
#   The new state is <project-dir>/<package name>/ (-1, -2, ... when taken). Its keys/ is
#   copied from the project's latest state; a project with no state yet gets a new key
#   set from the generator (the only case the generator runs, and the only case generator
#   options such as --efuse-write apply).
#   An existing keys/ is never handed to the generator and never copied over: on a
#   provisioned board's tree efuse_keys.txt IS the board state.
# --gen-keys <keys-dir> [gen options]   a bare key tree, as before.
if [ "${1:-}" = --gen-keys ]; then
    shift
    FROM='' TGZ_IN='' REVOKE_UPTO='' KEYS_FROM='' POS=() GEN_OPTS=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --from) FROM=${2:?--from needs a project directory}; shift 2 ;;
            --revoke) REVOKE_UPTO=${2:?--revoke needs an ID}; shift 2 ;;
            --keys-from) KEYS_FROM=${2:?--keys-from needs a key tree (.tar or directory)}; shift 2 ;;
            --state) die "--state is gone: a state is named after its package, -1/-2/... when that name is taken" ;;
            --efuse-write | --keys) GEN_OPTS+=("$1" "${2:?$1 needs a value}"); shift 2 ;;
            -*) GEN_OPTS+=("$1"); shift ;;
            *) POS+=("$1"); shift ;;
        esac
    done
    for a in "${POS[@]}"; do
        if [ -f "$a" ] && tgz_state "$a" > /dev/null; then
            [ -z "$TGZ_IN" ] || die "two packages given: $TGZ_IN and $a"
            TGZ_IN=$a
        elif [ -f "$a" ]; then
            die "$(basename "$a") is not named <date>_<machine>-secured-img.tgz"
        else
            [ -z "$FROM" ] || die "unexpected argument: $a"
            FROM=$a
        fi
    done
    if [ -z "$TGZ_IN" ]; then
        # bare key tree. _gen_keys.sh cd's into scripts/secure_boot/ first: resolve against the caller's cwd
        [ -n "$FROM" ] || die "--gen-keys needs <pkg.tgz> --from <project-dir>, or a key directory"
        if [ -d "$FROM" ] && is_workspace "$FROM"; then
            die "$FROM is a state directory. The next state of its project: --gen-keys <pkg.tgz> --from $(dirname "$FROM")"
        fi
        exec "${FILES}/_gen_keys.sh" --keys "$(readlink -m "$FROM")" "${GEN_OPTS[@]}"
    fi
    [ -n "$FROM" ] || die "--gen-keys $(basename "$TGZ_IN") needs --from <project-dir>  (files/workspaces/<name>, any name)"
    PKG_STATE=$(tgz_state "$TGZ_IN")
    TGZ_IN=$(readlink -f "$TGZ_IN")
    tgz_check "$TGZ_IN"
    # the project directory: a path, or a bare name under files/workspaces/
    case "$FROM" in
        */* | . | ..) PROJ_DIR=$(readlink -m "$FROM") ;;
        *) PROJ_DIR="${WS_ROOT}/${FROM}" ;;
    esac
    PROJECT=$(basename "$PROJ_DIR")
    [[ "$PROJECT" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "project name '$PROJECT': letters, digits, . _ - only"
    if [ -d "$PROJ_DIR" ] && is_workspace "$PROJ_DIR"; then
        die "$FROM is a state directory, not a project. The next state of its project: --gen-keys $(basename "$TGZ_IN") --from $(dirname "$PROJ_DIR")"
    fi
    (umask 077 && mkdir -p "$PROJ_DIR") || die "cannot create $PROJ_DIR"
    # the project's latest state, if it has one: its keys are what the card holds
    PREV=$(ws_latest "$PROJ_DIR") || PREV=''
    if [ -n "$PREV" ]; then
        for f in secret_key.txt RSA/psk1_rsa.pem RSA/ssk1_rsa.pem efuse_keys.txt; do
            [ -f "${PREV}/keys/${f}" ] || die "${PREV}/keys is incomplete (missing ${f}) - restore the whole tree from its backup"
        done
        [ "${#GEN_OPTS[@]}" -eq 0 ] || die "${PROJECT} already has a key set (${PREV}); generator options (${GEN_OPTS[*]}) do not apply"
        [ -z "$KEYS_FROM" ] || die "${PROJECT} already has a key set (${PREV}); --keys-from is for a project's first state only"
    fi
    # --keys-from: a project's first state from a key set that already exists (a board
    # provisioned before state directories), as a .tar of the tree or the tree itself.
    # Taken as it is: its efuse_keys.txt is the board's state and is never regenerated.
    KF_TMP=''
    if [ -n "$KEYS_FROM" ]; then
        [ -e "$KEYS_FROM" ] || die "--keys-from: not found: $KEYS_FROM"
        [ "${#GEN_OPTS[@]}" -eq 0 ] || die "--keys-from takes an existing key set; generator options (${GEN_OPTS[*]}) do not apply"
        if [ -f "$KEYS_FROM" ]; then
            KF_TMP=$(mktemp -d) || die "mktemp"
            tar -C "$KF_TMP" -xf "$KEYS_FROM" || die "cannot unpack $KEYS_FROM"
            # the tree may be the archive root or one directory below it
            if [ -f "${KF_TMP}/secret_key.txt" ]; then KEYS_SRC=$KF_TMP
            else
                KEYS_SRC=$(find "$KF_TMP" -mindepth 1 -maxdepth 1 -type d | head -1)
                [ -n "$KEYS_SRC" ] && [ -f "${KEYS_SRC}/secret_key.txt" ] || { rm -rf "$KF_TMP"; die "$KEYS_FROM does not hold a key tree (no secret_key.txt at its root or one level down)"; }
            fi
        else
            KEYS_SRC=$(readlink -f "$KEYS_FROM")
        fi
        for f in secret_key.txt RSA/psk1_rsa.pem RSA/ssk1_rsa.pem efuse_keys.txt; do
            [ -f "${KEYS_SRC}/${f}" ] || { [ -z "$KF_TMP" ] || rm -rf "$KF_TMP"; die "--keys-from: $KEYS_FROM is incomplete (missing ${f})"; }
        done
        grep -q '^FORMAT[[:space:]]*=[[:space:]]*mango-efuse-keys/1' "${KEYS_SRC}/efuse_keys.txt" \
            || { [ -z "$KF_TMP" ] || rm -rf "$KF_TMP"; die "--keys-from: ${KEYS_SRC}/efuse_keys.txt is not a mango-efuse-keys/1 file"; }
    fi
    # the state name: the package name, then -1, -2, ... when taken
    STATE=$PKG_STATE
    n=0
    while [ -e "${PROJ_DIR}/${STATE}" ]; do n=$((n + 1)); STATE="${PKG_STATE}-${n}"; done
    WS="${PROJ_DIR}/${STATE}"
    (umask 077 && mkdir -p "${WS}/keys" "${WS}/out") || die "cannot create $WS"
    say "project  : $PROJ_DIR"
    say "state    : $WS"
    cp "$TGZ_IN" "${WS}/.$(basename "$TGZ_IN").tmp" && mv "${WS}/.$(basename "$TGZ_IN").tmp" "${WS}/$(basename "$TGZ_IN")" \
        || die "cannot copy $TGZ_IN into $WS"
    SUM=$(sha256sum "${WS}/$(basename "$TGZ_IN")" | cut -d' ' -f1)
    say "package  : $(basename "$TGZ_IN")   sha256 ${SUM:0:16}"
    {
        printf '%-9s = %s\n' FORMAT "$WS_FORMAT"
        printf '%-9s = %s\n' PROJECT "$PROJECT"
        printf '%-9s = %s\n' STATE "$STATE"
        printf '%-9s = %s\n' PACKAGE "$PKG_STATE"
        printf '%-9s = %s\n' CREATED "$(date '+%Y-%m-%d %H:%M:%S')"
        [ -z "$PREV" ] || printf '%-9s = %s\n' FROM "$PREV"
    } > "${WS}/workspace.txt"
    ws_log "$WS" "created     ${WS}${PREV:+  from ${PREV}}"
    ws_log "$WS" "package     $(basename "$TGZ_IN")  sha256=${SUM}"
    rc=0
    if [ -n "$KEYS_FROM" ]; then
        cp -a "${KEYS_SRC}/." "${WS}/keys/" || die "cannot copy $KEYS_SRC"
        [ -z "$KF_TMP" ] || { find "$KF_TMP" -type f -exec shred -u {} \; 2> /dev/null; rm -rf "$KF_TMP"; }
        chmod 600 "${WS}/keys/secret_key.txt" "${WS}/keys/efuse_keys.txt" "${WS}/keys/RSA/"*.pem
        say "keys     : imported from ${KEYS_FROM}  (taken as the card's state; efuse_keys.txt untouched)"
        ws_log "$WS" "keys        imported from ${KEYS_FROM}  sha256=$(sha256sum "$KEYS_FROM" 2> /dev/null | cut -d' ' -f1)"
        printf '%-9s = %s\n' KEYS_FROM "$KEYS_FROM" >> "${WS}/workspace.txt"
    elif [ -n "$PREV" ]; then
        cp -a "${PREV}/keys/." "${WS}/keys/" || die "cannot copy ${PREV}/keys"
        chmod 600 "${WS}/keys/secret_key.txt" "${WS}/keys/efuse_keys.txt" "${WS}/keys/RSA/"*.pem
        say "keys     : copied from ${PREV}/keys  (the set the card holds; add revoke bits for the change, never a new secret_key.txt)"
        ws_log "$WS" "keys        copied from ${PREV}/keys"
        ws_log "$PREV" "next        ${WS}"
    else
        say "keys     : first state of ${PROJECT} - a new key set"
        GEN_OUT=$(mktemp) || die "mktemp"
        "${FILES}/_gen_keys.sh" --keys "${WS}/keys" "${GEN_OPTS[@]}" | tee "$GEN_OUT"
        rc=${PIPESTATUS[0]}
        rm -f "$GEN_OUT"
        ws_log "$WS" "gen-keys    rc=${rc}"
    fi
    if [ "$rc" -eq 0 ] && [ -n "$REVOKE_UPTO" ]; then
        # revoking N revokes every ID below it too - the default, because a register of
        # skipped IDs is exactly what nobody keeps for a board in the field
        [[ "$REVOKE_UPTO" =~ ^[0-9]+$ ]] || die "--revoke needs a number, got '$REVOKE_UPTO'"
        python3 "$HELP" revoke --file "${WS}/keys/efuse_keys.txt" --upto "$REVOKE_UPTO" || exit 1
        ws_log "$WS" "revoke      IDs 0..${REVOKE_UPTO} set in keys/efuse_keys.txt"
    fi
    if [ "$rc" -eq 0 ]; then
        FPR=$(psk_fpr "${WS}/keys/RSA/psk1_rsa.pem")
        [ -n "$FPR" ] || die "cannot read ${WS}/keys/RSA/psk1_rsa.pem"
        printf '%-9s = %s\n' PSK_FPR "$FPR" >> "${WS}/workspace.txt"
        if [ -n "$PREV" ]; then
            PFPR=$(ws_field "$PREV" PSK_FPR)
            [ -z "$PFPR" ] || [ "$PFPR" = "$FPR" ] || say "WARNING: psk_fpr differs from ${PREV}/workspace.txt - these are not the same key set"
        fi
        say ""
        say "state    : $WS"
        say "  keys     : ${WS}/keys   psk_fpr ${FPR:0:16}...   (the only copy - back it up off this checkout)"
        if [ -n "$PREV" ]; then
            if [ -n "$REVOKE_UPTO" ]; then
                say "  next     : ./key_manager.sh ${PREV} ${WS}"
            else
                say "  next     : ./key_manager.sh --revoke <N> ${WS}   (revoke IDs 0..N), then"
                say "             ./key_manager.sh ${PREV} ${WS}"
            fi
        else
            say "  next     : ./key_manager.sh --init ${WS}"
        fi
    fi
    exit "$rc"
fi

# --revoke <N> <state>: revoke IDs 0..N in an existing state's keys/efuse_keys.txt.
# Refused once the state has produced a flash tar: its request is what a card got.
if [ "${1:-}" = --revoke ]; then
    N=${2:-}
    ST=${3:-}
    { [ -n "$N" ] && [ -n "$ST" ] && [ $# -eq 3 ]; } || die "--revoke <N> <state>"
    [[ "$N" =~ ^[0-9]+$ ]] || die "--revoke needs a number, got '$N'"
    { [ -d "$ST" ] && [ -f "${ST}/keys/efuse_keys.txt" ]; } || die "$ST is not a state directory with keys/efuse_keys.txt"
    ST=$(readlink -f "$ST")
    for t in "${ST}"/out/flash-*.tar; do
        [ -f "$t" ] && die "$ST already produced $(basename "$t"); make a new state for a new burn: --gen-keys <pkg.tgz> --from $(dirname "$ST") --revoke $N"
    done
    python3 "$HELP" revoke --file "${ST}/keys/efuse_keys.txt" --upto "$N" || exit 1
    [ -f "${ST}/workspace.txt" ] && ws_log "$ST" "revoke      IDs 0..${N} set in keys/efuse_keys.txt"
    exit 0
fi

usage() {
    cat << EOF
Usage: ./key_manager.sh --gen-keys <pkg.tgz> --from <project-dir> [--revoke <N>] [-v] [--efuse-write "<fields>"]
       ./key_manager.sh --gen-keys <pkg.tgz> --from <project-dir> --keys-from <keys.tar|dir>
       ./key_manager.sh --revoke <N> <state>
       ./key_manager.sh --init <state>
       ./key_manager.sh <before-state> <after-state>

  A project is any directory under files/workspaces/ (boostx, boostx-acme, test, ...).
  A state is <project>/<package name>/: one Developer package
  (<date>_<machine>-secured-img.tgz) with the key set the card holds with it.

  --gen-keys <pkg.tgz> --from <project-dir>
                        a new state in that project (made if missing). The state is named
                        after the package; -1, -2, ... when that name is taken.
                          first state of the project  -> a NEW key set (generator options apply)
                          later states                -> keys/ COPIED from the project's latest
                                                         state. Then add revoke bits to the copy
                                                         (--revoke, or edit REVOKE_ID_* rows)
                        <project-dir> may be a bare name: --from boostx = files/workspaces/boostx
                        --revoke <N> revokes IDs 0..N in the new state's keys (see below)
                        --keys-from <keys.tar|dir>  first state only: take an existing key
                        set (a board provisioned before state dirs) instead of generating
  --revoke <N> <state>  revoke IDs 0..N in that state's keys/efuse_keys.txt. Revoking an
                        ID revokes every lower one too (the default: a board refusing ID N
                        must not accept an older image either). Bits already set stay.
                        New images are then signed with revoke_id N+1. Refused once the
                        state has produced a flash tar. N is 0..238: production IDs are
                        0..239, and 240..255 are reserved and never burned by this tool.
  --init <state>        first provisioning of a blank card: burns the key set's red key,
                        PPK0 hash, IVs, PPK0_WR_LK. Output in <state>/out/.
  <before> <after>      re-provision: burns the revoke bits added from before/keys to
                        after/keys, signs with after's package. Output in <after>/out/.
                        Same AES key, RSA pair and IVs in both, or it is refused.

  Output: flash-init-<time>.tar or flash-update-<time>.tar holding production_BOOT.BIN
          (golden) and provision_BOOT.BIN (primary); notes in out/<time>/FLASH_NOTES.md.

Bare key trees (no state dir) still work, with --tgz naming the package:
       ./key_manager.sh --gen-keys <keys-dir>
       ./key_manager.sh --init <keys-dir> --tgz <pkg.tgz>
       ./key_manager.sh <before-keys-dir> <after-keys-dir> --tgz <pkg.tgz>
  The tar then lands in the current directory.

Options (not needed normally):
  --dry-run        print what would be burned and stop
  --tgz <pkg.tgz>  name the package instead of taking the state dir's
  --user-slot 1    re-provision: burn USER_KEY1 instead of USER_KEY0
  --proj --work --out --keep-work -v   see README.md
EOF
}

INIT=0 WS='' WS_BEFORE='' BEFORE='' AFTER='' USER_SLOT=0 TGZ='' PROJ='' WORK='' OUT='' DRY=0 KEEP=0 VFLAG=()
while [ $# -gt 0 ]; do
    case "$1" in
        --init) INIT=1; AFTER=${2:?--init needs a state or keys directory}; shift 2 ;;
        --user-slot) USER_SLOT=${2:?}; shift 2 ;;
        --tgz) TGZ=${2:?}; shift 2 ;;
        --proj) PROJ=${2:?}; shift 2 ;;
        --work) WORK=${2:?}; shift 2 ;;
        --out) OUT=${2:?}; shift 2 ;;
        --dry-run) DRY=1; shift ;;
        --keep-work) KEEP=1; shift ;;
        -v | --verbose) VFLAG=(-v); shift ;;
        -h | --help) usage; exit 0 ;;
        -*) usage >&2; die "unknown option: $1" ;;
        *)
            if [ "$INIT" -eq 0 ] && [ -z "$BEFORE" ]; then BEFORE=$1
            elif [ "$INIT" -eq 0 ] && [ -z "$AFTER" ]; then AFTER=$1
            else die "unexpected argument: $1"; fi
            shift
            ;;
    esac
done
if [ -z "$AFTER" ] || { [ "$INIT" -eq 0 ] && [ -z "$BEFORE" ]; }; then
    usage >&2
    exit 2
fi
if [ "$INIT" -eq 1 ] && [ -n "$BEFORE" ]; then die "--init takes one state or keys directory"; fi
# State dirs in place of key trees: keys/ is the tree, the dir's package is the package,
# out/ takes the results. WS is the dir the results go to (the after state). A state
# dir and a bare tree are not mixed in one run: the pairing would hide which one the
# card actually holds.
if [ -d "$AFTER" ] && is_workspace "$AFTER"; then
    WS=$(readlink -f "$AFTER")
    AFTER="${WS}/keys"
    if [ "$INIT" -eq 0 ]; then
        { [ -d "$BEFORE" ] && is_workspace "$BEFORE"; } || die "$AFTER is a state directory but $BEFORE is not"
        WS_BEFORE=$(readlink -f "$BEFORE")
        BEFORE="${WS_BEFORE}/keys"
        [ "$WS_BEFORE" != "$WS" ] || die "before and after are the same state directory"
        PB=$(ws_field "$WS_BEFORE" PROJECT); PA=$(ws_field "$WS" PROJECT)
        [ -z "$PB" ] || [ -z "$PA" ] || [ "$PB" = "$PA" ] || die "before is project '$PB', after is project '$PA'"
    fi
elif [ "$INIT" -eq 0 ] && [ -d "$BEFORE" ] && is_workspace "$BEFORE"; then
    die "$BEFORE is a state directory but $AFTER is not. Make the after state with: ./key_manager.sh --gen-keys <pkg.tgz> --from $(dirname "$BEFORE")"
fi

# ------------------------------------------------------------ 0. preconditions
# _steplib.sh word-splits step arguments, so a path with a space or glob character
# would silently become two arguments inside _sign_secure_boot.sh.
safe_path() {
    case "$1" in
        *[[:space:]]* | *'*'* | *'?'* | *'['*) die "path has a space or glob character: $1" ;;
    esac
}
CALLER_DIR=$(pwd -P)
TS=$(date '+%Y%m%d-%H%M%S')
PROJ=$(readlink -f "${PROJ:-${PLNX_PROJ:-${SCRIPT_DIR}/../../../..}}")
[ "$INIT" -eq 1 ] || BEFORE=$(readlink -f "$BEFORE")
AFTER=$(readlink -f "$AFTER")
case "$USER_SLOT" in 0 | 1) ;; *) die "--user-slot is 0 or 1" ;; esac
MODE_TAG=$([ "$INIT" -eq 1 ] && echo init || echo update)
if [ -n "$WS" ]; then
    # everything a run leaves behind stays inside the (after) state directory
    WORK=$(readlink -m "${WORK:-${WS}/.work/${TS}}")
    OUT=$(readlink -m "${OUT:-${WS}/out/${TS}}")
    TAR="${WS}/out/flash-${MODE_TAG}-${TS}.tar"
    mkdir -p "${WS}/out" || die "cannot create ${WS}/out"
else
    WORK=$(readlink -m "${WORK:-${PROJ}/.provision-work/${TS}}")
    OUT=$(readlink -m "${OUT:-${WORK}.result}")
    TAR="${CALLER_DIR}/flash-${MODE_TAG}-${TS}.tar"
fi
TAR_DIR=$(dirname "$TAR")
for p in "$PROJ" "$BEFORE" "$AFTER" "$WORK" "$OUT" "$TAR"; do safe_path "$p"; done
TREES=("$AFTER")
[ "$INIT" -eq 1 ] || TREES=("$BEFORE" "$AFTER")

for d in "${TREES[@]}"; do
    for f in RSA/psk1_rsa.pem RSA/ssk1_rsa.pem secret_key.txt efuse_keys.txt; do
        [ -f "${d}/${f}" ] || die "missing ${d}/${f}"
    done
    grep -q '^FORMAT[[:space:]]*=[[:space:]]*mango-efuse-keys/1' "${d}/efuse_keys.txt" \
        || die "${d}/efuse_keys.txt is not a mango-efuse-keys/1 file"
done
for t in bootgen openssl python3 sha256sum flock; do
    command -v "$t" > /dev/null 2>&1 || die "$t not found in PATH"
done

# The package: for a state dir, the one it holds. For bare trees, the project root of
# root of this script's clone and of the clones the two key trees live in (the
# directory that holds meta-mango/).
proj_of() {
    local d=$1
    while [ "$d" != / ]; do
        [ -d "${d}/meta-mango" ] && { printf '%s\n' "$d"; return; }
        d=$(dirname "$d")
    done
}
if [ -z "$TGZ" ] && [ -n "$WS" ]; then
    # the (after) state dir's own package - the one the state is named after
    TGZ=$(ws_tgz "$WS") || die "$WS must hold exactly one *-secured-img.tgz (or name one with --tgz)"
elif [ -z "$TGZ" ]; then
    mapfile -t ROOTS < <({ printf '%s\n' "$PROJ"; for d in "${TREES[@]}"; do proj_of "$d"; done; } | sort -u)
    mapfile -t FOUND < <(for r in "${ROOTS[@]}"; do
        [ -d "$r" ] || continue
        find "$r" -maxdepth 1 -name '*-secured-img.tgz' -exec readlink -f {} \;
    done | sort -u)
    if [ "${#FOUND[@]}" -ne 1 ]; then
        printf 'key_manager: need exactly one *-secured-img.tgz, found %d. Looked in:\n' "${#FOUND[@]}" >&2
        printf '  %s\n' "${ROOTS[@]}" >&2
        [ "${#FOUND[@]}" -gt 0 ] && printf 'found:\n' >&2 && printf '  %s\n' "${FOUND[@]}" >&2
        die "keep one package in one of those directories, or name it with --tgz"
    fi
    TGZ=${FOUND[0]}
fi
TGZ=$(readlink -f "$TGZ")
safe_path "$TGZ"
[ -f "$TGZ" ] || die "package not found: $TGZ"
MANIFEST=$(tar xzOf "$TGZ" ./manifest.txt 2> /dev/null) || die "$TGZ: no manifest.txt"
grep -qE '^id_code[[:space:]]*:.*device=xcvp1202\b' <<< "$MANIFEST" \
    || die "$TGZ: manifest id_code is not device=xcvp1202 (_sign_secure_boot.sh signs for xcvp1202)"
# The mango-bsp release the package's mblp-prov.elf came from (YYMMDD in 1.0.0-YYMMDD).
# From 261007 it adds revoke IDs to a REVOKE_ID row that already has bits.
# Same release _make_zip.sh's BSP_MIN names; keep the two together.
BSP_REVOKE_GROW_MIN=261007
PKG_BSP=$(sed -n -E 's/^mango-bsp[[:space:]]*:[[:space:]]*([^[:space:]]+).*/\1/p' <<< "$MANIFEST" | head -1)
PKG_BSP_DATE=${PKG_BSP##*-}

# bootgen's PPK hash, not the PEM's sha256: the same key re-encoded must not look new.
ppk_hash() {
    local psk=$1 t h
    t=$(mktemp -d) || die "mktemp"
    printf 'digestgen_psk0_bif:\n{\n  pskfile = %s\n}\n' "$psk" > "${t}/p.bif"
    if ! bootgen -arch versal -image "${t}/p.bif" -efuseppkbits "${t}/h.txt" > "${t}/log" 2>&1; then
        cat "${t}/log" >&2
        rm -rf "$t"
        die "bootgen could not hash $psk"
    fi
    h=$(grep -oE '[0-9a-fA-F]{64}' "${t}/h.txt" | head -1 | tr 'a-f' 'A-F')
    rm -rf "$t"
    [ -n "$h" ] || die "no PPK hash for $psk"
    printf '%s' "$h"
}
PPK_AFTER=$(ppk_hash "${AFTER}/RSA/psk1_rsa.pem") || exit 1
PPK_BEFORE=
[ "$INIT" -eq 1 ] || { PPK_BEFORE=$(ppk_hash "${BEFORE}/RSA/psk1_rsa.pem") || exit 1; }
# shellcheck source=files/_efuse_iv.sh
. "${FILES}/_efuse_iv.sh"

AES_CHANGE=0 AES_SLOT='' USER_N=0 ARM='' REVOKE='' PROV_RID=0 PROD_RID=0 KEYSRC_AFTER=''
BEFORE_KEY_ID='' AFTER_KEY_ID='' REVOKE_GROW='' REVOKE_HOLES=''
read_plan() {
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^[A-Z_]+=[\'A-Za-z0-9_\ =]*$ ]] || die "unexpected plan line: $line"
        eval "$line"
    done <<< "$1"
}
if [ "$INIT" -eq 1 ]; then
    INIT_REQ=$(mktemp) || die "mktemp"
    PLAN=$(python3 "$HELP" mkinit --template "${AFTER}/efuse_keys.txt" --out "$INIT_REQ" \
        --key "${AFTER}/secret_key.txt" --ppk "$PPK_AFTER" --iv-meta "$SB_METAHEADER_IV0" --iv-plm "$SB_PLM_IV0")
    rc=$?
    shred -u "$INIT_REQ" 2> /dev/null || rm -f "$INIT_REQ"
    [ "$rc" -eq 0 ] || exit 1
    read_plan "$PLAN"
    KEYSRC_AFTER=0xA5C3C5A3
    say "== provision plan: first burn (blank card) =="
    say "  package        : $TGZ"
    say "  keys           : $AFTER   key $AFTER_KEY_ID   PPK ${PPK_AFTER:0:12}"
    say "  burns          : $ARM"
    say "  image revoke_id: production ${PROD_RID}"
else
    PLAN=$(python3 "$HELP" plan \
        --before-key "${BEFORE}/secret_key.txt" --after-key "${AFTER}/secret_key.txt" \
        --ppk-before "$PPK_BEFORE" --ppk-after "$PPK_AFTER" \
        --iv-meta "$SB_METAHEADER_IV0" --iv-plm "$SB_PLM_IV0" \
        --before-efuse "${BEFORE}/efuse_keys.txt" --after-efuse "${AFTER}/efuse_keys.txt" \
        --user-slot "$USER_SLOT") || exit 1
    read_plan "$PLAN"
    say "== provision plan: re-provision =="
    say "  package        : $TGZ  (mango-bsp ${PKG_BSP:-unknown})"
    say "  before / after : key $BEFORE_KEY_ID / $AFTER_KEY_ID   PPK ${PPK_BEFORE:0:12}"
    if [ "$AES_CHANGE" -eq 1 ] && [ -n "$AES_SLOT" ]; then
        say "  AES            : new key -> $AES_SLOT  (image keysrc efuse_user_key${USER_N} = ${KEYSRC_AFTER:-UNCONFIRMED})"
    elif [ "$AES_CHANGE" -eq 1 ]; then
        say "  AES            : already in USER_KEY${USER_N}, not burned again  (image keysrc efuse_user_key${USER_N} = ${KEYSRC_AFTER:-UNCONFIRMED})"
    else
        say "  AES            : unchanged (image keysrc efuse_red_key)"
    fi
    say "  revoke         : ${REVOKE:-no new bits}"
    if [ -n "${REVOKE_HOLES:-}" ]; then
        say "  WARNING        : IDs ${REVOKE_HOLES} below the highest revoked ID are NOT revoked. Images signed"
        say "                   with them still boot. The default is cumulative: ./key_manager.sh --revoke <N> <after-state>"
    fi
    if [ -n "$REVOKE_GROW" ]; then
        # an older mblp-prov.elf refuses the whole burn on the board: catch it here
        if ! [[ "$PKG_BSP_DATE" =~ ^[0-9]{6}$ ]] || [ "$PKG_BSP_DATE" -lt "$BSP_REVOKE_GROW_MIN" ]; then
            die "${REVOKE_GROW} already has bits on the card; adding to it needs a package built with mango-bsp ${BSP_REVOKE_GROW_MIN} or newer, this one is ${PKG_BSP:-unknown}"
        fi
        say "  revoke rows    : ${REVOKE_GROW} add to bits already burned (package mango-bsp ${PKG_BSP} >= ${BSP_REVOKE_GROW_MIN})"
    fi
    say "  image revoke_id: provision ${PROV_RID}, production ${PROD_RID}"
    say "  burns          : $ARM"
fi
if [ "$DRY" -eq 1 ]; then
    say "dry run: nothing written."
    exit 0
fi
[ -n "$KEYSRC_AFTER" ] || die "the efuse_user_key${USER_N} key-source word is not confirmed (KEYSRC_EFUSE_USER_KEY1 in files/_key_manager_lib.py) - refusing to build an image this script cannot check"
[ -e "$OUT" ] && die "$OUT already exists"
[ -e "$TAR" ] && die "$TAR already exists"
[ -w "$TAR_DIR" ] || die "cannot write the tar into $TAR_DIR"
[ -e "$WORK" ] && die "$WORK already exists - work trees are never reused"

exec 9> "${FILES}/.key_manager.lock" || die "cannot open the lock file"
flock -n 9 || die "another key_manager.sh is running in this clone"

umask 077
mkdir -p "$WORK" || die "cannot create $WORK"
OUT_TMP="${WORK}/out.tmp"
mkdir -p "$OUT_TMP"
PUBLISHED=0

# ----------------------------------------------------------------- cleanup
shred_path() {
    local p
    [ -e "$1" ] || [ -L "$1" ] || return 0
    if [ -L "$1" ]; then rm -f "$1"; return; fi
    if [ -d "$1" ]; then
        while IFS= read -r -d '' p; do
            shred -u "$p" 2> /dev/null || rm -f "$p" || CLEAN_FAIL+=("$p")
        done < <(find "$1" -type f -print0)
        find "$1" -depth -type d -empty -delete 2> /dev/null
    else
        shred -u "$1" 2> /dev/null || rm -f "$1" || CLEAN_FAIL+=("$1")
    fi
}
CLEAN_FAIL=()
clean_work() {
    local p
    for p in "${WORK}/keys-run1" "${WORK}/keys-run2" "${WORK}/run1/keys" "${WORK}/run2/keys" \
        "${WORK}/run1/mblp_prov/files/mblp-prov.elf" "${WORK}/run1/BOOT_PROVISION.BIN" \
        "${WORK}/run1/flash.tgz" "${WORK}/run2/flash.tgz" "${WORK}/authjtag.orig" \
        "${WORK}/run1/pmc_data.nky" "${WORK}/run2/pmc_data.nky"; do
        shred_path "$p"
    done
}
on_exit() {
    local rc=$?
    if [ -f "${WORK}/authjtag.orig" ]; then cp -p "${WORK}/authjtag.orig" "$JTAG"; fi
    if [ "$PUBLISHED" -eq 0 ]; then
        [ "$KEEP" -eq 1 ] || clean_work
        shred_path "$OUT_TMP"
        if [ "$rc" -ne 0 ]; then
            printf 'key_manager: FAILED - nothing published. Work tree: %s\n' "$WORK" >&2
            [ -z "$WS" ] || ws_log "$WS" "${MODE_TAG}      FAILED rc=${rc}  work=${WORK}"
        fi
    fi
    exit "$rc"
}
trap on_exit EXIT
trap 'exit 130' INT TERM

[ -f "$JTAG" ] && cp -p "$JTAG" "${WORK}/authjtag.orig"

copy_tree() { # <src> <dst>: the four files only, never backups or .nky
    mkdir -p "${2}/RSA"
    cp "${1}/RSA/psk1_rsa.pem" "${1}/RSA/ssk1_rsa.pem" "${2}/RSA/"
    cp "${1}/secret_key.txt" "${2}/"
    chmod 600 "${2}/RSA/"*.pem "${2}/secret_key.txt"
}

# Runs _sign_secure_boot.sh, keeps its stdout, and returns the logs directory it named.
LAST_LOGS=
sign_run() { # <name> <args...>
    local name=$1 start
    shift
    start=$(date +%s)
    say "-- _sign_secure_boot.sh $name"
    "$SIGN" "${VFLAG[@]}" "$@" > "${WORK}/${name}.out" 2>&1
    local rc=$?
    grep -E '^\[[0-9]+/[0-9]+\]|RESULT' "${WORK}/${name}.out" | sed 's/^/   /'
    LAST_LOGS=$(sed -n -E 's#^logs[[:space:]]+: (.*)/$#\1#p' "${WORK}/${name}.out" | head -1)
    if [ "$rc" -ne 0 ] || ! grep -q 'RESULT: PASS' "${WORK}/${name}.out"; then
        die "$name failed (see ${WORK}/${name}.out)"
    fi
    [ -d "$LAST_LOGS" ] || die "$name: no logs directory in its output"
    local n
    n=$(find "$LAST_LOGS" -maxdepth 1 -name '[0-9]*-*.log' -newermt "@$((start - 1))" | wc -l)
    [ "$n" -ge 1 ] || die "$name: logs in $LAST_LOGS are not from this run"
    sleep 1 # RUN_ID is per second: the next run must not share this directory
}

if [ "$INIT" -eq 1 ]; then
# ---------------------------------------------------------- first burn
# One run with the key set as it is: _sign_secure_boot.sh --pure builds the product
# image and the UNSIGNED burn image a blank card boots (it has no PPK hash yet).
say "== first burn: product + unsigned provision image =="
copy_tree "$AFTER" "${WORK}/keys-run1"
python3 "$HELP" mkinit --template "${AFTER}/efuse_keys.txt" --out "${WORK}/keys-run1/efuse_keys.txt" \
    --key "${AFTER}/secret_key.txt" --ppk "$PPK_AFTER" --iv-meta "$SB_METAHEADER_IV0" --iv-plm "$SB_PLM_IV0" > /dev/null || exit 1
sign_run run1-unpack --unpack-only --tgz "$TGZ" --package "${WORK}/run1" --keys "${WORK}/keys-run1"
f="${WORK}/run1/bifs/bootgen_secured.bif"
cp -p "$f" "${f}.rendered-orig"
python3 "$HELP" setrid --src "${f}.rendered-orig" --out "$f" --id "$PROD_RID" || exit 1
export SB_EFUSE_WRITE="$ARM"
# the AUTH_JTAG message must carry an ID the card will not have revoked: the one
# the production image is signed with
export SB_AUTHJTAG_REVOKE_ID="$PROD_RID"
sign_run run1 --no-unpack --pure --tgz "$TGZ" --package "${WORK}/run1" \
    --keys "${WORK}/keys-run1" --flash-tgz "${WORK}/run1/flash.tgz"
unset SB_EFUSE_WRITE SB_AUTHJTAG_REVOKE_ID
RUN1_LOGS=$LAST_LOGS
cp -p "$JTAG" "${OUT_TMP}/authenticatedJtagImage-rsa.after.bin"
if [ -f "${WORK}/authjtag.orig" ]; then cp -p "${WORK}/authjtag.orig" "$JTAG"; else rm -f "$JTAG"; fi
# --no-unpack: 1 AUTH_JTAG, 2 product, 3 inject, 4 burn images, 5 verify, 6 pack
ILOG="${RUN1_LOGS}/3-sb_step_inject.log"
[ -f "$ILOG" ] || die "no inject log at $ILOG"
LOGARM=$(sed -n -E 's/^[[:space:]]*OK[[:space:]]+armed:[[:space:]]*(.*)$/\1/p' "$ILOG" | head -1 | xargs -n1 | sort | xargs)
[ "$LOGARM" = "$(echo "$ARM" | xargs -n1 | sort | xargs)" ] || die "inject log arms '$LOGARM', efuse_keys.txt arms '$ARM'"
python3 "$HELP" blobcheck --fwtool "${WORK}/run1/common/fw-tool.py" \
    --elf "${WORK}/run1/mblp_prov/files/mblp-prov.elf" --request "${WORK}/keys-run1/efuse_keys.txt" \
    --arm "$ARM" --after-key "${AFTER}/secret_key.txt" || exit 1
[ "${WORK}/run1/BOOT_PROVISION.BIN" -nt "$ILOG" ] || die "burn image is older than the inject step"
IMG_PROV=$(grep -cE '^[[:space:]]*image[[:space:]]*$' "${WORK}/run1/bifs/bootgen_provision.bif")
IMG_PROD=$(grep -cE '^[[:space:]]*image[[:space:]]*$' "${WORK}/run1/bifs/bootgen_secured.bif")
cp -p "${WORK}/run1/BOOT_PROVISION.BIN" "${OUT_TMP}/provision_BOOT.BIN"
cp -p "${WORK}/run1/BOOT_SECURED.BIN" "${OUT_TMP}/production_BOOT.BIN"
NKY=$(find "${WORK}/keys-run1/AES" -name '*.nky' | wc -l)

say "== verify =="
python3 "$HELP" imgcheck unsigned "${OUT_TMP}/provision_BOOT.BIN" --images "$IMG_PROV" || exit 1
python3 "$HELP" imgcheck before "${OUT_TMP}/production_BOOT.BIN" --expect-ppk "$PPK_AFTER" \
    --images "$IMG_PROD" --revoke-id "$PROD_RID" || exit 1
python3 "$HELP" jtagcheck "${OUT_TMP}/authenticatedJtagImage-rsa.after.bin" --expect-ppk "$PPK_AFTER" \
    --revoke-id "$PROD_RID" || exit 1
SCAN_KEYS=(--key "${AFTER}/secret_key.txt" --pem "${AFTER}/RSA/psk1_rsa.pem" --pem "${AFTER}/RSA/ssk1_rsa.pem")
# the unsigned burn image carries the red key in its key blob, by design
python3 "$HELP" scan "$OUT_TMP" "${SCAN_KEYS[@]}" --allow "${OUT_TMP}/provision_BOOT.BIN" || exit 1
python3 "$HELP" scan "$WORK" "$RUN1_LOGS" "${SCAN_KEYS[@]}" \
    --allow "${WORK}/keys-run1" --allow "${OUT_TMP}/provision_BOOT.BIN" \
    --allow "${WORK}/run1/BOOT_PROVISION.BIN" --allow "${WORK}/run1/mblp_prov/files/mblp-prov.elf" \
    --allow "${WORK}/run1/flash.tgz" --allow "${WORK}/run1/pmc_data.nky" --list "${WORK}/scan-hits.txt" || exit 1
PROD_ENC="efuse_red_key, every block"
GOLDEN_NOTE="Until the burn lands, golden does not boot (the AES row is still blank)."
PROV_DESC="UNSIGNED, plaintext: its key blob carries the red key in the clear"
PROV_SIGN="unsigned (the card has no PPK yet)"
JTAG_NOTE="\`.after.bin\` (revoke_id ${PROD_RID}) unlocks the card once this burn has landed."
CHECK_ROWS="| burn request built from the key files: AES_KEY, PPK0_HASH, IVs, PPK0_WR_LK${REVOKE:+, $REVOKE} | PASS |
| _sign_secure_boot.sh --pure | PASS |
| key blob in mblp-prov.elf == request, crc, masks | PASS |
| provision image: unsigned, plaintext, ${IMG_PROV} images | PASS |
| production image: efuse_red_key, PPK == this key set, revoke_id ${PROD_RID} | PASS |
| AUTH_JTAG message: PPK == this key set, revoke_id ${PROD_RID} | PASS |
| no key outside provision_BOOT.BIN, logs clean | PASS |"
else
# -------------------------------------------------------------- 1. Run 1
# The burn image, signed and encrypted for the card as it is now (before keys).
say "== Run 1: provision image, before keys =="
copy_tree "$BEFORE" "${WORK}/keys-run1"
python3 "$HELP" mkrun1 --template "${BEFORE}/efuse_keys.txt" --out "${WORK}/keys-run1/efuse_keys.txt" \
    --before-key "${BEFORE}/secret_key.txt" --after-key "${AFTER}/secret_key.txt" --aes-slot "$AES_SLOT" \
    --revoke "$REVOKE" --ppk-before "$PPK_BEFORE" --iv-meta "$SB_METAHEADER_IV0" --iv-plm "$SB_PLM_IV0" || exit 1
sign_run run1-unpack --unpack-only --tgz "$TGZ" --package "${WORK}/run1" --keys "${WORK}/keys-run1"
for b in bootgen_secured.bif bootgen_provision_secured.bif; do
    f="${WORK}/run1/bifs/${b}"
    cp -p "$f" "${f}.rendered-orig"
    python3 "$HELP" setrid --src "${f}.rendered-orig" --out "$f" --id "$PROV_RID" || exit 1
done
export SB_EFUSE_WRITE="$ARM"
# the before message unlocks the card as it is now: an ID its REVOKE_ID rows do
# not have, the same one the provision image is signed with
export SB_AUTHJTAG_REVOKE_ID="$PROV_RID"
sign_run run1 --no-unpack --tgz "$TGZ" --package "${WORK}/run1" \
    --keys "${WORK}/keys-run1" --flash-tgz "${WORK}/run1/flash.tgz"
unset SB_EFUSE_WRITE SB_AUTHJTAG_REVOKE_ID
RUN1_LOGS=$LAST_LOGS
cp -p "$JTAG" "${OUT_TMP}/authenticatedJtagImage-rsa.before.bin"

# --no-unpack run: 1 AUTH_JTAG, 2 product, 3 inject, 4 burn images, 5 verify, 6 pack
VLOG="${RUN1_LOGS}/5-sb_step_verify.log"
[ -f "$VLOG" ] || die "no verify log at $VLOG"
BADWARN=$(sed -n -E 's/^[[:space:]]*WARN ([^ ].*)$/\1/p' "$VLOG" | awk '{print $1}' \
    | grep -vxE 'METAHEADER_IV|PLM_IV|AES_KEY' | sort -u | tr '\n' ' ')
[ -z "$BADWARN" ] || die "Run 1 verify raised unexpected warnings: $BADWARN(see $VLOG)"
ILOG="${RUN1_LOGS}/3-sb_step_inject.log"
[ -f "$ILOG" ] || die "no inject log at $ILOG"
LOGARM=$(sed -n -E 's/^[[:space:]]*OK[[:space:]]+armed:[[:space:]]*(.*)$/\1/p' "$ILOG" | head -1 | xargs -n1 | sort | xargs)
[ "$LOGARM" = "$(echo "$ARM" | xargs -n1 | sort | xargs)" ] || die "inject log arms '$LOGARM', plan arms '$ARM'"
python3 "$HELP" blobcheck --fwtool "${WORK}/run1/common/fw-tool.py" \
    --elf "${WORK}/run1/mblp_prov/files/mblp-prov.elf" --request "${WORK}/keys-run1/efuse_keys.txt" \
    --arm "$ARM" --after-key "${AFTER}/secret_key.txt" --aes-slot "$AES_SLOT" || exit 1

PBIF="${WORK}/run1/bifs/bootgen_provision_secured.bif"
[ "$(grep -c 'file = mblp_prov/files/mblp-prov.elf' "$PBIF")" -eq 1 ] || die "$PBIF: the app ELF is not named exactly once"
awk '/^[[:space:]]*image[[:space:]]*$/{inimg=1} inimg&&/name = efuse_prov_ss/{n=1} n&&/id = 0x1c000000/{i=1}
     i&&/authentication = rsa/{a=1} i&&/encryption = aes/{e=1} i&&/keysrc = efuse_red_key/{k=1}
     END{exit !(n&&i&&a&&e&&k)}' "$PBIF" || die "$PBIF: efuse_prov_ss image block is not authenticated+encrypted"
[ "${WORK}/run1/BOOT_PROVISION_SECURED.BIN" -nt "$ILOG" ] || die "burn image is older than the inject step"
IMG_PROV=$(grep -cE '^[[:space:]]*image[[:space:]]*$' "$PBIF")
IMG_PROD=$(grep -cE '^[[:space:]]*image[[:space:]]*$' "${WORK}/run1/bifs/bootgen_secured.bif")
cp -p "${WORK}/run1/BOOT_PROVISION_SECURED.BIN" "${OUT_TMP}/provision_BOOT.BIN"

# -------------------------------------------------------------- 2. Run 2
# The image the card boots once the burn has landed (after keys).
say "== Run 2: production image, after keys =="
copy_tree "$AFTER" "${WORK}/keys-run2"
python3 "$HELP" mkrun2 --src "${AFTER}/efuse_keys.txt" --out "${WORK}/keys-run2/efuse_keys.txt" || exit 1
sign_run run2-unpack --unpack-only --tgz "$TGZ" --package "${WORK}/run2" --keys "${WORK}/keys-run2"
RBIF="${WORK}/run2/bifs/bootgen_secured.bif"
cp -p "$RBIF" "${RBIF}.rendered-orig"
if [ "$AES_CHANGE" -eq 1 ]; then
    # the AES row still holds the before key: PLM/PMC CDO/metaheader go plaintext,
    # everything else opens with the user key
    python3 "$HELP" editbif --src "${RBIF}.rendered-orig" --out "${RBIF}.keysrc" --n "$USER_N" || exit 1
    python3 "$HELP" setrid --src "${RBIF}.keysrc" --out "$RBIF" --id "$PROD_RID" || exit 1
else
    python3 "$HELP" setrid --src "${RBIF}.rendered-orig" --out "$RBIF" --id "$PROD_RID" || exit 1
fi
# the after message unlocks the card once the burn has landed: the production ID
export SB_AUTHJTAG_REVOKE_ID="$PROD_RID"
sign_run run2 --no-unpack --product-only --tgz "$TGZ" --package "${WORK}/run2" \
    --keys "${WORK}/keys-run2" --flash-tgz "${WORK}/run2/flash.tgz"
unset SB_AUTHJTAG_REVOKE_ID
cp -p "$JTAG" "${OUT_TMP}/authenticatedJtagImage-rsa.after.bin"
cp -p "${WORK}/run2/BOOT_SECURED.BIN" "${OUT_TMP}/production_BOOT.BIN"
cp -p "$RBIF" "${OUT_TMP}/bootgen_secured_after.bif"
# both runs rewrote the shared AUTH_JTAG file; put the operator's copy back now
if [ -f "${WORK}/authjtag.orig" ]; then cp -p "${WORK}/authjtag.orig" "$JTAG"; else rm -f "$JTAG"; fi

AKEY_ID=$(grep -oE '[0-9A-Fa-f]{64}' "${AFTER}/secret_key.txt" | head -1 | tr a-f A-F | sha256sum | cut -c1-12)
shopt -s nullglob
NKY=0
for f in "${WORK}"/keys-run2/AES/*.nky "${WORK}/run2/pmc_data.nky"; do
    [ -f "$f" ] || continue
    NKY=$((NKY + 1))
    k=$(grep -E '^Key 0' "$f" | grep -oE '[0-9A-Fa-f]{64}' | tr a-f A-F | sha256sum | cut -c1-12)
    [ "$k" = "$AKEY_ID" ] || die "$f: Key 0 is not the after key"
done
shopt -u nullglob
[ "$NKY" -gt 0 ] || die "Run 2 produced no .nky files"

# -------------------------------------------------------------- 3. verify
say "== verify =="
python3 "$HELP" imgcheck prov "${OUT_TMP}/provision_BOOT.BIN" --expect-ppk "$PPK_BEFORE" \
    --images "$IMG_PROV" --revoke-id "$PROV_RID" || exit 1
if [ "$AES_CHANGE" -eq 1 ]; then
    python3 "$HELP" imgcheck after "${OUT_TMP}/production_BOOT.BIN" --expect-ppk "$PPK_AFTER" \
        --keysrc "$KEYSRC_AFTER" --revoke-id "$PROD_RID" || exit 1
else
    python3 "$HELP" imgcheck before "${OUT_TMP}/production_BOOT.BIN" --expect-ppk "$PPK_AFTER" \
        --images "$IMG_PROD" --revoke-id "$PROD_RID" || exit 1
fi
python3 "$HELP" jtagcheck "${OUT_TMP}/authenticatedJtagImage-rsa.before.bin" --expect-ppk "$PPK_BEFORE" \
    --revoke-id "$PROV_RID" || exit 1
python3 "$HELP" jtagcheck "${OUT_TMP}/authenticatedJtagImage-rsa.after.bin" --expect-ppk "$PPK_AFTER" \
    --revoke-id "$PROD_RID" || exit 1
SCAN_KEYS=(--key "${BEFORE}/secret_key.txt" --key "${AFTER}/secret_key.txt"
    --pem "${BEFORE}/RSA/psk1_rsa.pem" --pem "${BEFORE}/RSA/ssk1_rsa.pem"
    --pem "${AFTER}/RSA/psk1_rsa.pem" --pem "${AFTER}/RSA/ssk1_rsa.pem")
python3 "$HELP" scan "$OUT_TMP" "${SCAN_KEYS[@]}" || exit 1
python3 "$HELP" scan "$WORK" "$RUN1_LOGS" "$LAST_LOGS" "${SCAN_KEYS[@]}" \
    --allow "${WORK}/keys-run1" --allow "${WORK}/keys-run2" \
    --allow "${WORK}/run1/BOOT_PROVISION.BIN" --allow "${WORK}/run1/mblp_prov/files/mblp-prov.elf" \
    --allow "${WORK}/run1/flash.tgz" --allow "${WORK}/run1/pmc_data.nky" \
    --allow "${WORK}/run2/pmc_data.nky" --list "${WORK}/scan-hits.txt" || exit 1

if [ "$AES_CHANGE" -eq 1 ]; then
    PROD_ENC="PLM, PMC CDO, metaheader plaintext; ${IMG_PROD} images' other partitions efuse_user_key${USER_N}"
    if [ -n "$AES_SLOT" ]; then
        GOLDEN_NOTE="Until the burn lands, golden does not boot (its partitions need the new key)."
    else
        GOLDEN_NOTE="Golden boots before and after the burn (the key is already in USER_KEY${USER_N}; revoke_id ${PROD_RID} is not revoked)."
    fi
else
    PROD_ENC="efuse_red_key (unchanged AES key), every block"
    GOLDEN_NOTE="Golden boots before and after the burn (same AES key, revoke_id ${PROD_RID} is not revoked)."
fi
PROV_DESC="before red key; its key blob carries the burn"
PROV_SIGN="before PSK, revoke_id ${PROV_RID}"
JTAG_NOTE="\`.before.bin\` (revoke_id ${PROV_RID}) unlocks the card before this burn, \`.after.bin\` (revoke_id ${PROD_RID}) after it."
CHECK_ROWS="| PPK0/IVs unchanged, revoke bits only added (never cleared)${REVOKE_GROW:+; $REVOKE_GROW grows a row already burned} | PASS |
| Run 1 _sign_secure_boot.sh, verify warnings only for burned fields | PASS |
| key blob in mblp-prov.elf == request, crc, masks${AES_SLOT:+, $AES_SLOT value} | PASS |
| provision image: efuse_red_key, PPK == before PSK, revoke_id ${PROV_RID}, ${IMG_PROV} images | PASS |
| provisioning app payload == injected ELF | PARTIAL (payload not decrypted) |
| production image: ${PROD_ENC}, PPK == after PSK, revoke_id ${PROD_RID} | PASS |
| Run 2 .nky Key 0 == after key (${NKY} files) | PASS |
| AUTH_JTAG messages: before revoke_id ${PROV_RID}, after revoke_id ${PROD_RID}, PPK == PSK | PASS |
| no key or private exponent in any output, logs clean | PASS |"
fi

# -------------------------------------------------------------- 4. publish
if [ "$KEEP" -eq 0 ]; then
    clean_work
    [ "${#CLEAN_FAIL[@]}" -eq 0 ] || die "could not delete: ${CLEAN_FAIL[*]}"
    python3 "$HELP" scan "$WORK" "${SCAN_KEYS[@]}" --allow "${OUT_TMP}/provision_BOOT.BIN" \
        || die "key material left in $WORK after cleanup"
    CLEANED="work tree key copies shredded and rescanned clean"
else
    CLEANED="--keep-work: key copies LEFT in ${WORK} (keys-run1, keys-run2, run1/BOOT_PROVISION.BIN, run1/mblp_prov/files/mblp-prov.elf)"
fi
sha() { sha256sum "${OUT_TMP}/$1" | cut -c1-16; }
if [ -n "$BEFORE_KEY_ID" ]; then BEFORE_DESC="key id ${BEFORE_KEY_ID}, PPK ${PPK_BEFORE:0:12}"; else BEFORE_DESC="blank card"; fi
MODE=$([ "$INIT" -eq 1 ] && echo "first burn (blank card)" || echo "re-provision")
cat > "${OUT_TMP}/FLASH_NOTES.md" << EOF
# provision ${TS}: ${MODE}

| | |
|---|---|
| package | \`$(basename "$TGZ")\` |
| before | ${BEFORE_DESC} |
| after | key id ${AFTER_KEY_ID}, PPK ${PPK_AFTER:0:12} |
| burns | \`${ARM}\` |
| revoke rows | ${REVOKE:-none} |
| image revoke_id | provision ${PROV_RID}, production ${PROD_RID} |

## Files

| file | signed with | encrypted with | slot |
|---|---|---|---|
| production_BOOT.BIN ($(sha production_BOOT.BIN)) | after PSK, revoke_id ${PROD_RID} | ${PROD_ENC} | golden |
| provision_BOOT.BIN ($(sha provision_BOOT.BIN)) | ${PROV_SIGN} | ${PROV_DESC} | primary |

## Flash

1. golden <- production_BOOT.BIN
2. primary <- provision_BOOT.BIN, boot. It burns ${ARM}, copies golden to primary and
   resets. Keep power until the log shows
   \`key blob: valid\` -> \`burn stage 'values': programmed\` -> \`OSPI GOLDEN COPY: P.1 (golden) -> P.0 (primary)\` -> reset
3. after the reset both slots hold production_BOOT.BIN. Linux up = done.

${GOLDEN_NOTE} If production_BOOT.BIN fails to boot after the burn, both slots hold it:
recover over JTAG (AUTH_JTAG message).
$([ "$INIT" -eq 1 ] && echo "
provision_BOOT.BIN holds the red key in the clear: controlled path only, destroy it after the burn.")

## Checks

| check | result |
|---|---|
${CHECK_ROWS}
| cleanup | ${CLEANED} |

AUTH_JTAG messages are signed with a PSK: keep them with the key owner. The PLM checks
the revoke_id they carry against the card's REVOKE_ID rows, so a message unlocks one
state only and is refused once its ID is revoked: ${JTAG_NOTE}
EOF
(cd "$OUT_TMP" && find . -type f -printf '%P\n' | sort | xargs sha256sum > "${WORK}/SHA256SUMS" && mv "${WORK}/SHA256SUMS" SHA256SUMS)
chmod -R go-rwx "$OUT_TMP"
mv "$OUT_TMP" "$OUT" || die "cannot publish to $OUT"
PUBLISHED=1
tar -cf "$TAR" -C "$OUT" production_BOOT.BIN provision_BOOT.BIN || die "cannot write $TAR"
chmod 600 "$TAR"
say ""
say "RESULT: PASS"
say "  $TAR"
say "    production_BOOT.BIN -> golden"
say "    provision_BOOT.BIN  -> primary   (burns ${ARM}, then copies golden to primary)"
say "  package: $(basename "$TGZ")"
say "  notes  : ${OUT}/FLASH_NOTES.md (checks and hashes, kept out of the tar)"
if [ -n "$WS" ]; then
    ws_log "$WS" "${MODE_TAG}      PASS  $(basename "$TAR")  package=$(basename "$TGZ")  burns=${ARM}${WS_BEFORE:+  before=${WS_BEFORE}}"
    [ -z "$WS_BEFORE" ] || ws_log "$WS_BEFORE" "update      PASS  -> ${WS}  ($(basename "$TAR"))"
    [ -z "$WS_BEFORE" ] || say "  state  : once the burn is confirmed on the card, ${WS} is its current state; the next change takes it as before"
fi
