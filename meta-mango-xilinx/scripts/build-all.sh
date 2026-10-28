#!/bin/bash

set -e

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
FIRMWARE=/etc/mango/firmware/mblp.elf
XSA=""
CLK=""
json_file=""
reason=""
batch=0
clean=0
secured=0
json_secured=false
positional=()
init_args=()
json_init=()
write_back=()
declare -A json_inputs=()

# name|flag|prompt|default
INPUTS=(
    "XSA|--xsa|XSA file|"
    "CLK|--clk|SMC clock MHz: 250, 238, 227 (Enter: not set)|"
)

RED=""
NC=""
if [ -t 2 ]; then
    RED='\033[1;31m'
    NC='\033[0m'
fi

die() {
    printf '%b%s%b\n' "$RED" "$*" "$NC" >&2
    exit 2
}

usage() {
    local f m
    cat << EOF
Usage: $(basename "$0") [PROJECT_DIR] [MACHINE] [options]

Build a PetaLinux project: apply the XSA, configure the machine,
run petalinux-build and package the boot image.

Arguments:
  PROJECT_DIR      PetaLinux project directory (default: current directory)
  MACHINE          machine from meta-mango-xilinx/conf/machine

Options (after -- when called through mango-build.sh):
  --xsa FILE       XSA file
  --clk MHZ        SMC clock: 250, 238 or 227
  --enable-emmc    ext4 rootfs on eMMC instead of initramfs
  --clean          run clean-build.sh on the project first
  --secured        also build the secure boot package (needs bootgen)
  --json FILE      read and save answers in FILE (set by mango-build.sh)
  --batch          with --json, use saved answers without asking
  -h, --help       this help

Machines:
EOF
    for f in "$SCRIPT_DIR"/../conf/machine/*.conf; do
        m=$(basename "$f" .conf)
        printf '  %s\n' "$m"
    done
}

while [ $# -gt 0 ]; do
    case "$1" in
        -h | --help)
            usage
            exit 0
            ;;
        --enable-emmc)
            init_args+=("$1")
            shift
            ;;
        --json)
            [ $# -ge 2 ] || die "$1 needs a value"
            json_file=$2
            shift 2
            ;;
        --batch)
            batch=1
            shift
            ;;
        --clean)
            clean=1
            shift
            ;;
        --secured)
            secured=1
            shift
            ;;
        -*)
            name=""
            for row in "${INPUTS[@]}"; do
                IFS='|' read -r name flag prompt default <<< "$row"
                [ "$1" = "$flag" ] && break
                name=""
            done
            [ -n "$name" ] || die "unknown option '$1'"
            [ $# -ge 2 ] || die "$1 needs a value"
            printf -v "$name" '%s' "$2"
            shift 2
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

PROJ_DIR=$(realpath "${positional[0]:-$PWD}")
MACHINE_TYPE=${positional[1]:-}

if [ ! -d "$PROJ_DIR/project-spec" ]; then
    echo "Cannot find the petalinux project: $PROJ_DIR"
    echo "Run petalinux-create/config with a valid .xsa file"
    echo ""
    echo "Usage: $0 [Project DIR]"
    exit 1
fi

command -v petalinux-build > /dev/null 2>&1 || die "petalinux-build is not in PATH; source the PetaLinux settings.sh first"

if [ "$clean" = 1 ]; then
    "$SCRIPT_DIR/clean-build.sh" "$PROJ_DIR"
fi

if [ -n "$json_file" ]; then
    trap '' TSTP
    command -v python3 > /dev/null 2>&1 || die "python3 is required for --json"
    if [ -f "$json_file" ]; then
        json_data=$(
            python3 - "$json_file" << 'EOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
for k, v in (d.get("inputs") or {}).items():
    print("I\t%s\t%s" % (k, v))
for a in d.get("init_args") or []:
    print("A\t%s" % a)
print("S\t%s" % ("true" if d.get("secured") else "false"))
EOF
        ) || die "cannot read $json_file"
        while IFS=$'\t' read -r kind key value; do
            case "$kind" in
                I)
                    json_inputs[$key]=$value
                    ;;
                A)
                    json_init+=("$key")
                    ;;
                S)
                    json_secured=$key
                    ;;
            esac
        done <<< "$json_data"
        if [ ${#init_args[@]} -eq 0 ] && [ ${#json_init[@]} -gt 0 ]; then
            init_args=("${json_init[@]}")
        fi
        if [ "$secured" = 0 ] && [ "$json_secured" = true ]; then
            secured=1
        fi
    fi
    for answer in "${init_args[@]}"; do
        case "$answer" in
            --enable-emmc) ;;
            *) die "init args: $answer is not supported (fix it in $json_file)" ;;
        esac
    done

    for row in "${INPUTS[@]}"; do
        IFS='|' read -r name flag prompt default <<< "$row"
        [ -n "${json_inputs[$name]+x}" ] && default=${json_inputs[$name]}
        [ "$name" = XSA ] && prompt="$prompt (current: ${default:-empty})"
        if [ -z "${!name}" ]; then
            if [ "$name" = XSA ] && [ -f "$PROJ_DIR/project-spec/hw-description/system.xsa" ] && [ -n "${json_inputs[XSA]:-}" ]; then
                XSA=$default
            elif { [ "$batch" = 0 ] || [ "$name:$default" = "XSA:" ]; } && [ -t 0 ]; then
                echo
                echo "$prompt"
                read -e -r -i "$default" -p "> " answer
                printf -v "$name" '%s' "$answer"
            else
                printf -v "$name" '%s' "$default"
            fi
        fi
        while :; do
            reason=""
            case "$name:${!name}" in
                XSA:)
                    reason="required"
                    ;;
                XSA:*)
                    [ -f "$XSA" ] || reason="$XSA not found"
                    ;;
                CLK: | CLK:250 | CLK:238 | CLK:227) ;;
                CLK:*)
                    reason="$CLK is not 250, 238 or 227"
                    ;;
            esac
            [ -z "$reason" ] && break
            printf '%b%s: %s%b\n' "$RED" "$name" "$reason" "$NC" >&2
            [ -t 0 ] || die "fix $name in $json_file or pass $flag"
            echo
            echo "$prompt"
            read -e -r -i "${!name}" -p "> " answer
            printf -v "$name" '%s' "$answer"
        done
    done
    [ -n "$XSA" ] || [ -f "$PROJ_DIR/project-spec/hw-description/system.xsa" ] \
        || die "no hw description in $PROJ_DIR; pass --xsa"
    [ -z "$XSA" ] || XSA=$(realpath "$XSA")

    if [ "$secured" = 1 ]; then
        unzip -l "${XSA:-$PROJ_DIR/project-spec/hw-description/system.xsa}" 2> /dev/null | grep -q '\.bif$' \
            || die "--secured: this XSA has no BIF, so the secure boot package cannot be built"
        command -v bootgen > /dev/null 2>&1 || die "--secured: bootgen is not in PATH (Vitis 2025.2.1)"
    fi

    for row in "${INPUTS[@]}"; do
        IFS='|' read -r name flag prompt default <<< "$row"
        write_back+=("$name=${!name}")
    done
    write_back+=("--")
    python3 - "$json_file" "$secured" "${write_back[@]}" "${init_args[@]}" << 'EOF'
import json, os, sys
p = sys.argv[1]
rest = sys.argv[3:]
i = rest.index("--")
d = {}
if os.path.exists(p):
    with open(p) as f:
        d = json.load(f)
d["inputs"] = dict(kv.split("=", 1) for kv in rest[:i])
d["init_args"] = rest[i + 1:]
d["secured"] = sys.argv[2] == "1"
d.pop("xsa_file", None)
with open(p, "w") as f:
    json.dump(d, f, indent=2)
    f.write("\n")
EOF
    trap - TSTP
fi

if [ -n "$XSA" ] && ! cmp -s "$XSA" "$PROJ_DIR/project-spec/hw-description/system.xsa"; then
    "$SCRIPT_DIR/config-build.sh" "$PROJ_DIR" "$XSA"
fi

if [ ! -z "$MACHINE_TYPE" ]; then
    $SCRIPT_DIR/init-plnx-config.sh $PROJ_DIR/project-spec/configs/config --machine $MACHINE_TYPE "${init_args[@]}"
fi

[ -f "$FIRMWARE" ] || die "SMC firmware not found: $FIRMWARE (sudo apt install mango-bsp)"

pushd $PROJ_DIR

petalinux-build

petalinux-package boot --uboot --force --add $FIRMWARE --file-attribute core=r5-0

"$SCRIPT_DIR/package-images.sh" ${CLK:+--clk "$CLK"}

if [ "$secured" = 1 ]; then
    petalinux-build -c plm-firmware-efuse
    "$SCRIPT_DIR/wrap-package.sh" -p "$PROJ_DIR" --secured
    "$SCRIPT_DIR/validate-package.sh"
fi

popd
