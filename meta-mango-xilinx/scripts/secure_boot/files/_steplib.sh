# shellcheck shell=bash
# Shared step runner. Sourced, not executed. Caller: cd to SCRIPT_DIR, fill STEPS
# with "name|fn-or-script|args", set LOG_DIR/VERBOSE, call sb_run_steps+sb_summary.

sb_colors() {
    if [ -t 1 ]; then
        C_RED=$'\033[31m'
        C_GRN=$'\033[32m'
        C_YEL=$'\033[33m'
        C_BLD=$'\033[1m'
        C_OFF=$'\033[0m'
    else
        C_RED=
        C_GRN=
        C_YEL=
        C_BLD=
        C_OFF=
    fi
}

# ------------------------------------------------------------------ preflight
# Up front, so a missing tool fails in one line - not mid-step with a half image.
sb_pf_init() {
    SB_PREFLIGHT_FAIL=0
    printf '%s== preflight ==%s\n' "$C_BLD" "$C_OFF"
}
sb_pf_ok() { printf '  %sOK  %s %s\n' "$C_GRN" "$C_OFF" "$1"; }
sb_pf_bad() {
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
    SB_PREFLIGHT_FAIL=1
}
# Hints on stdout, under their FAIL. sb_pf_cmd colours rather than quotes: quotes
# get copy-pasted with the command.
sb_pf_hint() { printf '       %s\n' "$1"; }
sb_pf_cmd() { printf '       %s %s%s%s%s\n' "$1" "$C_GRN" "$C_BLD" "$2" "$C_OFF"; }

sb_pf_tools() {
    local tool
    for tool in "$@"; do
        if command -v "$tool" > /dev/null 2>&1; then
            sb_pf_ok "$tool: $(command -v "$tool")"
        else
            sb_pf_bad "$tool not found in PATH"
            [ "$tool" = bootgen ] \
                && sb_pf_cmd "Please source the Vitis/PetaLinux settings:" "source <vitis>/settings64.sh"
        fi
    done
}

# Gate the installed mango-bsp on the release date in its Debian revision
sb_pf_bsp_min() {
    local want=$1 status ver rel
    SB_BSP_VER=

    # SB_BSP_VER_OVERRIDE (wrap-package.sh --bsp-ver): the staged firmware is not the
    # installed mango-bsp but a local build, and this is the version the manifest
    # must record for it. Its date field is checked like a release's.
    if [ -n "${SB_BSP_VER_OVERRIDE:-}" ]; then
        status=installed
        ver=$SB_BSP_VER_OVERRIDE
        sb_pf_hint "mango-bsp version overridden: $ver (locally built firmware staged)"
    else
        read -r status ver < <(dpkg-query -W -f='${db:Status-Status} ${Version}\n' \
            mango-bsp 2> /dev/null) || true
    fi
    if [ "${status:-}" != installed ] || [ -z "${ver:-}" ]; then
        if [ "$want" = 0 ]; then
            sb_pf_ok "mango-bsp: not installed (--bsp-min 0, not checked)"
        else
            sb_pf_bad "mango-bsp is not installed - needs $want or newer"
            sb_pf_cmd "Please run:" "sudo apt update && sudo apt install mango-bsp"
        fi
        return
    fi
    # read by the caller - _make_zip.sh exports it for the manifest
    # shellcheck disable=SC2034
    SB_BSP_VER=$ver

    rel=${ver##*-}
    case "$rel" in
        [0-9][0-9][0-9][0-9][0-9][0-9]) ;;
        *)
            if [ "$want" = 0 ]; then
                sb_pf_ok "mango-bsp: $ver (--bsp-min 0, not checked)"
            else
                sb_pf_bad "mango-bsp $ver has no YYMMDD release date to check against $want"
                sb_pf_hint "Expected a version like 1.0.0-${want}; --bsp-min 0 skips the check"
            fi
            return
            ;;
    esac

    if [ "$want" = 0 ]; then
        sb_pf_ok "mango-bsp: $ver (--bsp-min 0, not checked)"
    elif [ "$rel" -ge "$want" ]; then
        sb_pf_ok "mango-bsp: $ver (>= $want)"
    else
        sb_pf_bad "mango-bsp $ver is older than $want"
        sb_pf_cmd "Please run:" "sudo apt update && sudo apt install --only-upgrade mango-bsp"
    fi
}

sb_pf_done() {
    if [ "$SB_PREFLIGHT_FAIL" -ne 0 ]; then
        printf '\n%sRESULT: FAIL%s - preflight; nothing was run.\n' "$C_RED" "$C_OFF"
        exit 1
    fi
    echo
}

# ------------------------------------------------------------- step reporting
# sb_bad sets `fail`; a step using it must end `exit "$fail"` to report every check.
sb_pass() { printf '  %sOK  %s %s\n' "$C_GRN" "$C_OFF" "$1"; }
# shellcheck disable=SC2034  # read by the step that sourced this, not here
sb_bad() {
    printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$1"
    fail=1
}
sb_warn() { printf '  %sWARN%s %s\n' "$C_YEL" "$C_OFF" "$1"; }
sb_die() {
    echo "ERROR: $*" >&2
    exit 2
}

# ---------------------------------------------------------------------- steps
# In order, stopping at the first failure. Sets SB_FAILED_STEP, SB_RESULTS.
sb_run_steps() {
    local total=${#STEPS[@]}
    local n=0 entry name script args log start elapsed rc nlines
    SB_FAILED_STEP=
    SB_RESULTS=()

    for entry in "${STEPS[@]}"; do
        IFS='|' read -r name script args <<< "$entry"
        n=$((n + 1))
        log="${LOG_DIR}/${n}-$(basename "$script" .sh).log"

        # Function (normal) or script path. Subshell: a step's exit and cd stay local.
        # word splitting on $args is intended - it carries the step's arguments
        # shellcheck disable=SC2086
        if declare -F "$script" > /dev/null 2>&1; then
            sb_step_run() { ("$script" $args); }
        else
            sb_step_run() { ("./$script" $args); }
        fi

        printf '[%d/%d] %-22s ' "$n" "$total" "$name"
        [ "$VERBOSE" -eq 1 ] && printf '\n'

        start=$SECONDS
        if [ "$VERBOSE" -eq 1 ]; then
            sb_step_run 2>&1 | tee "$log"
            rc=${PIPESTATUS[0]}
        else
            sb_step_run > "$log" 2>&1
            rc=$?
        fi
        elapsed=$((SECONDS - start))
        # a checker's log is a few dozen lines and worth quoting; a bootgen
        # -log debug or bitbake run is thousands and is only ever tailed
        nlines=$(wc -l < "$log")

        [ "$VERBOSE" -eq 1 ] && printf '[%d/%d] %-22s ' "$n" "$total" "$name"
        if [ "$rc" -eq 0 ]; then
            printf '%sPASS%s  (%ds)\n' "$C_GRN" "$C_OFF" "$elapsed"
            SB_RESULTS+=("PASS|$name")
        else
            printf '%sFAIL%s  (%ds, exit %d)\n' "$C_RED" "$C_OFF" "$elapsed" "$rc"
            SB_RESULTS+=("FAIL|$name")
            SB_FAILED_STEP=$name
            # Short logs (the checkers) are shown whole - which check failed is
            # the whole message. Long ones are tailed.
            if [ "$VERBOSE" -eq 0 ]; then
                echo
                if [ "$nlines" -le 60 ]; then
                    printf '%s--- %s ---%s\n' "$C_YEL" "$log" "$C_OFF"
                    cat "$log"
                else
                    printf '%s--- last 40 of %d lines, full log: %s/%s ---%s\n' \
                        "$C_YEL" "$nlines" "$SCRIPT_DIR" "$log" "$C_OFF"
                    tail -n 40 "$log"
                fi
            fi
            return 1
        fi

        # Surface "new/keep/set :" and WARN even on PASS - an unburned fuse or a red
        # key landing in the ELF. Short logs only; bootgen debug is all noise.
        if [ "$VERBOSE" -eq 0 ] && [ "$nlines" -le 60 ]; then
            grep -E 'WARN|^(new|keep|set)[[:space:]]*:' "$log" | sed 's/^/       /'
        fi
    done
    return 0
}

# --------------------------------------------------------------------- summary
# One line per step, skipped ones marked. Returns 1 if any failed.
sb_summary() {
    local i=0 entry name r
    echo
    printf '%s== summary ==%s\n' "$C_BLD" "$C_OFF"
    for entry in "${STEPS[@]}"; do
        IFS='|' read -r name _ _ <<< "$entry"
        i=$((i + 1))
        if [ "$i" -le "${#SB_RESULTS[@]}" ]; then
            r=${SB_RESULTS[$((i - 1))]%%|*}
            case "$r" in
                PASS) printf '  %sPASS%s %s\n' "$C_GRN" "$C_OFF" "$name" ;;
                *) printf '  %sFAIL%s %s\n' "$C_RED" "$C_OFF" "$name" ;;
            esac
        else
            printf '  %s----%s %s (skipped)\n' "$C_YEL" "$C_OFF" "$name"
        fi
    done
    echo

    if [ -n "$SB_FAILED_STEP" ]; then
        printf '%sRESULT: FAIL%s - "%s" failed. Do NOT burn eFUSEs or flash. eFUSE is OTP.\n' \
            "$C_RED" "$C_OFF" "$SB_FAILED_STEP"
        return 1
    fi
    return 0
}
