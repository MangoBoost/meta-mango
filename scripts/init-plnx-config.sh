#!/bin/bash
# This script transforms a given configuration file.

# Exit immediately if a command exits with a non-zero status.
set -euo pipefail

# Find the root directory of meta-mango
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
ROOT_DIR=$(dirname "$SCRIPT_DIR")
MACHINE_DIR="$ROOT_DIR/conf/machine"

validate_machine_name() {
    local name="$1"
    if [[ ! -f "$MACHINE_DIR/${name}.conf" ]]; then
        echo "Error: unsupported machine '$name'." >&2
        echo "No '$MACHINE_DIR/${name}.conf' found." >&2
        echo "Supported machine types:" >&2
        local supported=()
        for f in "$MACHINE_DIR"/*.conf; do
            [[ -f "$f" ]] || continue
            supported+=("$(basename "$f" .conf)")
        done
        printf '  - %s\n' "${supported[@]}" | sort >&2
        exit 1
    fi
}

# --- Usage information function ---
usage() {
    echo "Usage: $0 [--machine <name>] [--enable-emmc] [<config_file>]"
    echo "Transforms a given configuration file in-place."
    echo "If <config_file> is omitted, defaults to 'project-spec/configs/config'."
    echo
    echo "Options:"
    echo "  --machine <name>   Set the Yocto machine name (default: mango-versal-lp-generic)."
    echo "  --enable-emmc      Configure EXT4 rootfs on eMMC (/dev/mmcblk0p2) instead of initramfs."
}

# --- Main logic function ---
main() {
    local config_file=""
    local tmp_output_file=""
    local machine_name="mango-versal-lp-generic"
    local enable_emmc=false

    # --- Cleanup function definition ---
    # This function is called on script exit to safely remove the temporary file.
    cleanup() {
        # It attempts to delete the temp file only if the variable is not empty and the file actually exists.
        # The ${tmp_output_file:-} syntax prevents an error if the variable is unset.
        if [[ -n "${tmp_output_file:-}" && -f "$tmp_output_file" ]]; then
            rm -f "$tmp_output_file"
        fi
    }
    # Set a trap to call the cleanup function on EXIT, for any reason.
    trap cleanup EXIT

    # --- 1. Parse options ---
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine)
                if [[ -z "${2:-}" ]]; then
                    echo "Error: --machine option requires an argument." >&2
                    usage
                    exit 1
                fi
                machine_name="$2"
                shift 2
                ;;
            --enable-emmc)
                enable_emmc=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            -*)
                echo "Error: Unknown option: $1" >&2
                usage
                exit 1
                ;;
            *)
                if [[ -n "$config_file" ]]; then
                    echo "Error: Only one configuration file can be specified." >&2
                    usage
                    exit 1
                fi
                config_file="$1"
                shift
                ;;
        esac
    done

    # --- 2. Validate input file ---
    if [[ -z "$config_file" ]]; then
        config_file="project-spec/configs/config"
        echo "Note: no config file given; defaulting to '$config_file'." >&2
    fi
    if [[ ! -f "$config_file" ]]; then
        echo "Error: File not found: $config_file" >&2
        exit 1
    fi

    # --- 2a. Validate machine against conf/machine ---
    validate_machine_name "$machine_name"

    # --- 2b. Print the resolved target ---
    echo "----------------------------------------------------------------------"
    printf "  %-12s : %s\n" "Machine" "$machine_name"
    printf "  %-12s : %s\n" "Config" "$config_file"
    echo "----------------------------------------------------------------------"

    # --- 3. Create a backup of the input file ---
    local backup_num=0
    local backup_file
    while :; do
        backup_file="${config_file}.old.${backup_num}"
        if [[ ! -e "$backup_file" ]]; then
            cp "$config_file" "$backup_file"
            echo "Backup of '$config_file' created at '$backup_file'"
            break
        fi
        backup_num=$((backup_num + 1))
    done

    # --- 4. Define configuration values (using an associative array) ---
    declare -A config
    local pfx="CONFIG_SUBSYSTEM_FLASH_CIPS_PSPMC_0_PSV_PMC_QSPI_OSPI_FLASH_0"

    config["${pfx}_PART0_SIZE"]="0x2f80000"
    config["${pfx}_PART1_NAME"]='"spi0-bootenv"'
    config["${pfx}_PART1_SIZE"]="0x40000"
    config["${pfx}_PART2_NAME"]='"spi0-bootscr"'
    config["${pfx}_PART2_SIZE"]="0x40000"
    config["${pfx}_PART3_NAME"]='"spi0-kernel"'
    config["${pfx}_PART3_SIZE"]="0x1A00000"
    config["${pfx}_PART4_NAME"]='"spi0-rootfs"'
    config["${pfx}_PART4_SIZE"]="0xAE00000"
    config["${pfx}_PART5_NAME"]='""'
    config["CONFIG_SUBSYSTEM_FLASH_IP_NAME"]='"cips_pspmc_0_psv_pmc_qspi_ospi_flash_0"'
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_KERNEL_OFFSET"]="0x6000000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_KERNEL_SIZE"]="0x1A00000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_RAMDISK_OFFSET"]="0x7A00000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_RAMDISK_SIZE"]="0x7E00000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_FIT_IMAGE_OFFSET"]="0x6000000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_FIT_IMAGE_SIZE"]="0x9800000"
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_BOOTSCR_OFFSET"]='"0x20000"'
    config["CONFIG_SUBSYSTEM_UBOOT_QSPI_BOOTSCR_SIZE"]='"0x20000"'
    config["CONFIG_YOCTO_MACHINE_NAME"]="\"$machine_name\""
    config["CONFIG_USER_LAYER_0"]=\"$ROOT_DIR\"
    config["CONFIG_USER_LAYER_1"]='""'
    config["CONFIG_SUBSYSTEM_HOSTNAME"]='"mango-versal"'
    config["CONFIG_SUBSYSTEM_PRODUCT"]='"mango-versal-lp"'

    # --- 5. Create a temporary file ---
    tmp_output_file=$(mktemp)

    # --- 6. Dynamically generate a list of sed commands ---
    declare -a sed_expressions

    for key in "${!config[@]}"; do
        local delimiter='/'
        if [[ "$key" == *"USER_LAYER"* ]]; then
            delimiter='|'
        fi
        sed_expressions+=(-e "s${delimiter}^\\(${key}=\\).*${delimiter}\\1${config[$key]}${delimiter}")
    done

    sed_expressions+=(-e 's/^CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT=y/# CONFIG_SUBSYSTEM_COPY_TO_TFTPBOOT is not set/')
    sed_expressions+=(-e '/^CONFIG_SUBSYSTEM_TFTPBOOT_DIR=.*/d')

    # Logic for adding the partition block
    # Create a single multi-line string for sed's 'a' (append) command.
    # This method is highly compatible with both GNU and BSD sed, making it robust.
    # A backslash at the end of each line treats multiple lines as a single command.
    if ! grep -q "^${pfx}_PART4_NAME=" "$config_file"; then
        sed_expressions+=(-e "/^CONFIG_SUBSYSTEM_FLASH_IP_NAME=.*/d")

        local append_command
        append_command="/^${pfx}_PART3_NAME=.*/a \\
CONFIG_SUBSYSTEM_FLASH_CIPS_PSPMC_0_PSV_PMC_QSPI_OSPI_FLASH_0_PART3_SIZE=${config[${pfx}_PART3_SIZE]}\\
\\
#\\
# partition 4\\
#\\
CONFIG_SUBSYSTEM_FLASH_CIPS_PSPMC_0_PSV_PMC_QSPI_OSPI_FLASH_0_PART4_NAME=${config[${pfx}_PART4_NAME]}\\
CONFIG_SUBSYSTEM_FLASH_CIPS_PSPMC_0_PSV_PMC_QSPI_OSPI_FLASH_0_PART4_SIZE=${config[${pfx}_PART4_SIZE]}\\
\\
#\\
# partition 5\\
#\\
CONFIG_SUBSYSTEM_FLASH_CIPS_PSPMC_0_PSV_PMC_QSPI_OSPI_FLASH_0_PART5_NAME=${config[${pfx}_PART5_NAME]}\\
CONFIG_SUBSYSTEM_FLASH_IP_NAME=${config[CONFIG_SUBSYSTEM_FLASH_IP_NAME]}"

        sed_expressions+=(-e "$append_command")
    fi

    if ! grep -q "^CONFIG_USER_LAYER_1=" "$config_file"; then
        sed_expressions+=(-e "/^CONFIG_USER_LAYER_0=.*/a CONFIG_USER_LAYER_1=${config[CONFIG_USER_LAYER_1]}")
    fi

    if [[ "$enable_emmc" == true ]]; then
        sed_expressions+=(-e 's/^CONFIG_SUBSYSTEM_ROOTFS_INITRD=y/# CONFIG_SUBSYSTEM_ROOTFS_INITRD is not set/')
        sed_expressions+=(-e 's/^# CONFIG_SUBSYSTEM_ROOTFS_EXT4 is not set/CONFIG_SUBSYSTEM_ROOTFS_EXT4=y/')
        sed_expressions+=(-e '/^CONFIG_SUBSYSTEM_INITRD_RAMDISK_LOADADDR=.*/d')
        sed_expressions+=(-e '/^CONFIG_SUBSYSTEM_INITRAMFS_IMAGE_NAME=.*/d')
        sed_expressions+=(-e 's/root=\/dev\/ram0 rw/root=\/dev\/mmcblk0p2 ro rootwait/')
        if ! grep -q "^CONFIG_SUBSYSTEM_SDROOT_DEV=" "$config_file"; then
            sed_expressions+=(-e '/^CONFIG_SUBSYSTEM_ROOTFS_EXT4=.*/a CONFIG_SUBSYSTEM_SDROOT_DEV="\/dev\/mmcblk0p2"')
        fi
    fi

    # Pin PACKAGE_FEED_ARCHS so the on-target dnf repo list only points to
    # the tune arch on petalinux.xilinx.com. Writing this in machine conf
    # has no effect because gen-machine-conf generates a shadow machine.conf
    # under build/conf/machine/ that does not include our user layer's conf.
    local bsp_conf
    bsp_conf="$(dirname "$(dirname "$config_file")")/meta-user/conf/petalinuxbsp.conf"

    if [[ -f "$bsp_conf" ]]; then
        sed -i '/^PACKAGE_FEED_ARCHS[[:space:]]*=/d' "$bsp_conf"
        echo 'PACKAGE_FEED_ARCHS = "cortexa72_cortexa53"' >> "$bsp_conf"
        echo "PACKAGE_FEED_ARCHS pinned in '$bsp_conf'"
    fi

    # --- 7. Execute transformation ---
    sed "${sed_expressions[@]}" "$config_file" > "$tmp_output_file"

    # --- 8. Overwrite the original file ---
    mv "$tmp_output_file" "$config_file"
    echo "File '$config_file' has been updated."
    # Since the file was moved with mv, there's no need to clean up the temp file anymore.
    # Disable the trap to prevent any action on script exit.
    trap - EXIT
}

# --- Execute script ---
main "$@"
