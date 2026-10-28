#!/bin/bash
# mango-build.sh - single entry point for the meta-mango sub-layer builds.
# It only picks a BSP sub-layer and one of its machines, then hands over to
# meta-mango-<arch>/scripts/build-all.sh, which owns the build itself.
# meta-mango-core is part of every build and is never a choice here; a
# sub-layer is offered only when it has conf/machine/.
#
# Usage:
#   ./scripts/mango-build.sh [--proj DIR] [<arch>] [<machine>] [-- <args for build-all.sh>]
#   ./scripts/mango-build.sh --list
#
# The chosen arch, machine and the sub-layer answers are remembered in
# <proj>/mango-build.json, so the next run only asks whether to reuse them.
# The file also records the meta-mango commit (with -dirty) it was written
# from; a mismatch is reported before reuse.

set -euo pipefail

ROOT_DIR=$(dirname "$(dirname "$(readlink -f "$0")")")
RED=""
YELLOW=""
NC=""
if [ -t 2 ]; then
    RED='\033[1;31m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
fi

die() {
    printf '%b%s%b\n' "$RED" "$*" "$NC" >&2
    exit 1
}

usage() {
    local d platforms=""
    for d in "$ROOT_DIR"/meta-mango-*/scripts/build-all.sh; do
        [ -x "$d" ] || continue
        d=${d#"$ROOT_DIR"/meta-mango-}
        platforms="$platforms ${d%%/*}"
    done
    cat << EOF
Usage: $(basename "$0") [options] [<arch> [<machine>]] [-- <arch options>]
       $(basename "$0") -h [<arch>]

Pick a platform and machine, then build with meta-mango-<arch>/scripts/build-all.sh.
Missing values are asked on a terminal.

Options:
  --proj DIR      PetaLinux project directory (default: current directory)
  --clean         clean the project before building (not saved)
  -l, --list      list platforms and their machines
  -h, --help      this help; with <arch>, that platform's options

Settings:
  Answers are saved in <proj>/mango-build.json and offered for reuse.
  A different machine starts new settings; the old file goes to
  <proj>/.backup/project_configurations/.

Examples:
  $(basename "$0")
  $(basename "$0") xilinx mango-versal-lp-boostx-base -- --xsa <file>
  $(basename "$0") --clean

Platforms:${platforms:- none}  (see: $(basename "$0") <arch> --help)
EOF
}

list_machines() {
    local f
    for f in "$ROOT_DIR/meta-mango-$1/conf/machine"/*.conf; do
        [ -f "$f" ] || continue
        basename "$f" .conf
    done
}

arch=""
machine=""
proj=""
do_list=0
do_help=0
PROJ=""
JSON=""
cur_commit=""
cur_describe=""
cur_dirty=""
j_arch=""
j_machine=""
positional=()
extra_args=()
arches=()
machines=()
batch_args=()
clean_args=()

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            -h | --help)
                do_help=1
                shift
                ;;
            -l | --list)
                do_list=1
                shift
                ;;
            --clean)
                clean_args=(--clean)
                shift
                ;;
            --proj)
                [ $# -ge 2 ] || die "--proj needs a value"
                proj=$2
                shift 2
                ;;
            --)
                shift
                extra_args=("$@")
                break
                ;;
            -*)
                usage >&2
                exit 2
                ;;
            *)
                positional+=("$1")
                shift
                ;;
        esac
    done

    [ ${#positional[@]} -ge 1 ] && arch=${positional[0]}
    [ ${#positional[@]} -ge 2 ] && machine=${positional[1]}
    [ ${#positional[@]} -gt 2 ] && {
        usage >&2
        exit 2
    }
    return 0
}

show_help() {
    if [ -z "$arch" ]; then
        usage
        exit 0
    fi
    [ -x "$ROOT_DIR/meta-mango-$arch/scripts/build-all.sh" ] \
        && exec "$ROOT_DIR/meta-mango-$arch/scripts/build-all.sh" --help
    [ -d "$ROOT_DIR/meta-mango-$arch" ] && die "meta-mango-$arch has no build-all.sh yet"
    die "unknown arch '$arch'; try --list"
}

find_arches() {
    local d
    mapfile -t arches < <(for d in "$ROOT_DIR"/meta-mango-*/; do
        [ -d "$d/conf/machine" ] || continue
        basename "${d%/}" | sed 's/^meta-mango-//'
    done)
    [ ${#arches[@]} -gt 0 ] || die "no meta-mango-* sub-layer with conf/machine in $ROOT_DIR"
}

list_platforms() {
    local a m board prev
    for a in "${arches[@]}"; do
        if [ -x "$ROOT_DIR/meta-mango-$a/scripts/build-all.sh" ]; then
            echo "$a"
        else
            echo "$a (no build-all.sh yet)"
        fi
        mapfile -t machines < <(list_machines "$a")
        prev=""
        for m in "${machines[@]}"; do
            board=${m#mango-*-}
            board=${board%%-*}
            [ -n "$prev" ] && [ "$board" != "$prev" ] && echo
            prev=$board
            echo "    $m"
        done
    done
    exit 0
}

choose_project() {
    if [ -n "$proj" ]; then
        PROJ=$proj
    elif [ -t 0 ]; then
        echo
        echo "Project directory"
        read -e -r -i "$PWD" -p "> " PROJ
    else
        PROJ=$PWD
    fi
    [ -d "$PROJ" ] || die "no such directory: $PROJ"
    PROJ=$(cd "$PROJ" && pwd -P)
    JSON=$PROJ/mango-build.json
    command -v python3 > /dev/null 2>&1 || die "python3 is required for mango-build.json"
}

read_checkout_rev() {
    cur_commit=$(git -C "$ROOT_DIR" rev-parse HEAD 2> /dev/null) || cur_commit=unknown
    cur_describe=$(git -C "$ROOT_DIR" describe --tags --always --dirty 2> /dev/null) || cur_describe=unknown
    if [ -n "$(git -C "$ROOT_DIR" status --porcelain 2> /dev/null)" ]; then
        cur_dirty=true
    else
        cur_dirty=false
    fi
}

load_settings() {
    local json_info rec_commit rec_describe json_lines=()

    [ ! -e "$JSON" ] || [ -r "$JSON" ] || die "cannot read $JSON"
    [ -r "$JSON" ] || return 1
    json_info=$(
        python3 - "$JSON" << 'EOF'
import json, os, sys
def bad(msg):
    print(msg)
    sys.exit(1)
try:
    with open(sys.argv[1]) as f:
        d = json.load(f)
except OSError as e:
    bad(e.strerror)
except ValueError as e:
    bad("not valid JSON (%s)" % e)
if not isinstance(d, dict):
    bad("not a JSON object")
for k in ("arch", "machine"):
    if not isinstance(d.get(k), str) or not d.get(k):
        bad("%s is missing" % k)
for k in ("inputs", "meta_mango"):
    if not isinstance(d.get(k) or {}, dict):
        bad("%s is not an object" % k)
if not isinstance(d.get("init_args") or [], list) or not all(isinstance(a, str) for a in d.get("init_args") or []):
    bad("init_args is not a list of strings")
if not isinstance(d.get("secured", False), bool):
    bad("secured is not true or false")
inputs = d.get("inputs") or {}
meta = d.get("meta_mango") or {}
print(d.get("arch", ""))
print(d.get("machine", ""))
print(meta.get("commit", ""))
print(meta.get("describe", ""))
print("true" if meta.get("dirty") else "false")
rows = [("platform", d.get("arch", "")), ("machine", d.get("machine", "")),
        ("meta-mango", "%s  (commit %s, %s)" % (meta.get("describe", "?"), (meta.get("commit") or "?")[:12],
                                                "dirty" if meta.get("dirty") else "clean"))]
rows += [(k, v if v != "" else "(empty)") for k, v in inputs.items()]
rows.append(("init args", " ".join(d.get("init_args") or []) or "(none)"))
rows.append(("secure boot", "yes" if d.get("secured") else "no"))
print("")
print("Found mango-build.json in %s:" % os.path.dirname(os.path.abspath(sys.argv[1])))
print("")
for k, v in rows:
    print("  %-12s %s" % (k, v))
print("")
EOF
    ) || die "invalid $JSON: $json_info"
    mapfile -t json_lines <<< "$json_info"
    j_arch=${json_lines[0]}
    j_machine=${json_lines[1]}
    rec_commit=${json_lines[2]}
    rec_describe=${json_lines[3]}
    printf '%s\n' "${json_lines[@]:5}"
    if [ "$rec_commit" != "$cur_commit" ]; then
        printf '%bWARNING: settings were saved with meta-mango %s; this checkout is %s%b\n' \
            "$YELLOW" "${rec_describe%-dirty}" "${cur_describe%-dirty}" "$NC" >&2
    fi
    if [ "$cur_dirty" = true ]; then
        printf '%bWARNING: meta-mango has uncommitted changes%b\n' "$YELLOW" "$NC" >&2
    fi
}

ask_reuse() {
    local answer=y backup

    if [ -n "$machine" ] && [ "$arch/$machine" != "$j_arch/$j_machine" ]; then
        echo "machine changes from $j_machine to $machine; starting new settings"
        answer=n
    elif [ -t 0 ]; then
        while :; do
            echo
            echo "Reuse these settings? [Y/n]"
            read -r -p "> " answer || answer=y
            case "$answer" in
                "" | y | Y | n | N) break ;;
            esac
        done
    fi
    case "${answer:-y}" in
        y | Y)
            arch=${arch:-$j_arch}
            machine=${machine:-$j_machine}
            batch_args=(--batch)
            ;;
        *)
            backup=$PROJ/.backup/project_configurations/mango-build-$(date +%y%m%d-%H%M%S).json
            mkdir -p "$(dirname "$backup")"
            mv "$JSON" "$backup"
            echo "Previous settings backed up to $backup"
            ;;
    esac
}

choose_arch() {
    local a

    [ -z "$arch" ] || return 0
    [ -t 0 ] || {
        usage >&2
        exit 2
    }
    echo
    echo "Platform"
    PS3="> "
    select a in "${arches[@]}"; do
        [ -n "$a" ] && arch=$a && break
    done
    return 0
}

choose_machine() {
    local m board boards=()

    printf '%s\n' "${arches[@]}" | grep -qx -- "$arch" || return 0
    mapfile -t machines < <(list_machines "$arch")
    [ -z "$machine" ] || return 0
    [ ${#machines[@]} -gt 0 ] || return 0
    [ -t 0 ] || {
        usage >&2
        exit 2
    }
    mapfile -t boards < <(for m in "${machines[@]}"; do
        m=${m#mango-*-}
        echo "${m%%-*}"
    done | sort -u)
    if [ ${#boards[@]} -gt 1 ]; then
        echo
        echo "Board"
        PS3="> "
        select board in "${boards[@]}"; do
            [ -n "$board" ] && break
        done
        [ -n "${board:-}" ] || die "no board selected"
        mapfile -t machines < <(printf '%s\n' "${machines[@]}" | grep -E -- "^mango-[^-]*-$board(-|\$)")
    fi
    echo
    echo "Machine"
    PS3="> "
    select m in "${machines[@]}"; do
        [ -n "$m" ] && machine=$m && break
    done
    [ -n "$machine" ] || die "no machine selected"
}

check_settings() {
    printf '%s\n' "${arches[@]}" | grep -qx -- "$arch" || die "unknown arch '$arch'; try --list"
    [ -x "$ROOT_DIR/meta-mango-$arch/scripts/build-all.sh" ] \
        || die "meta-mango-$arch has no executable scripts/build-all.sh yet"
    [ ${#machines[@]} -gt 0 ] || die "no machines in meta-mango-$arch/conf/machine"
    printf '%s\n' "${machines[@]}" | grep -qx -- "$machine" || die "unknown machine '$machine' for arch '$arch'; try --list"
}

save_settings() {
    python3 - "$JSON" "$arch" "$machine" "$cur_commit" "$cur_describe" "$cur_dirty" << 'EOF'
import json, os, sys
p, arch, machine, commit, describe, dirty = sys.argv[1:7]
d = {}
if os.path.exists(p):
    with open(p) as f:
        d = json.load(f)
d["arch"] = arch
d["machine"] = machine
d["meta_mango"] = {"commit": commit, "describe": describe, "dirty": dirty == "true"}
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
EOF
}

run_build() {
    trap - TSTP
    exec "$ROOT_DIR/meta-mango-$arch/scripts/build-all.sh" "$PROJ" "$machine" --json "$JSON" \
        ${batch_args[@]+"${batch_args[@]}"} ${clean_args[@]+"${clean_args[@]}"} ${extra_args[@]+"${extra_args[@]}"}
}

main() {
    trap '' TSTP
    parse_args "$@"
    [ "$do_help" = 1 ] && show_help
    find_arches
    [ "$do_list" = 1 ] && list_platforms

    # 1. collect
    choose_project
    read_checkout_rev
    if load_settings; then
        ask_reuse
    fi
    choose_arch
    choose_machine

    # 2. check
    check_settings

    # 3. build
    save_settings
    run_build
}

main "$@"
