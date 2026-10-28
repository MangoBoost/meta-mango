#!/usr/bin/env bash
# Vivado 2025 XSA bug workaround for mango-versal-lp boards (2 GiB DDR_LOW0).
#
# Scope: this patch is hardcoded for axi_noc_mc_lpddr4_0 with a 2 GiB primary
# DDR window mapped at 0x0 (CPU view). It is mango-versal-lp specific and
# MUST NOT be used on other Versal boards without re-deriving the values.
#
# Background:
# HSI picks a PCIe/NoC aperture instead of the CPU-side view (0x0) for
# axi_noc_mc_lpddr4_0 DDR_LOW0, so the auto-generated
# project-spec/configs/configs/Kconfig.syshw ends up with wrong defaults and
# wrong range limits. Vivado 2024 produced correct values.
#
# Two apertures have been observed, depending on the block design:
#   0x20108000000 (CPM_PCIE_NOC_0) and 0x448000000. Both families share the
#   same layout: base+0x40000000 / +0x8000000 / +0x4000000 / +0x100000 for the
#   TEXTBASE defaults, so both are matched and rewritten to the same values.
#
# Re-run this after every `petalinux-config --get-hw-description=...` until
# the XSA itself is fixed (BD address editor: remove CPM_PCIE_NOC_0 -> DDR_LOW0
# segment, or open an AMD support ticket).
#
# Restored values for SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_*, chosen so
# the patched file is byte-identical to the Vivado 2024 output kept as
# project-spec/Kconfig_shellv1.syshw. The range upper bounds are the generator's
# own arithmetic for a 2 GiB bank, not simply size-1:
#   BASEADDR range end 0x7dffffff = 0x80000000 - 0x2000000 - 1
#                                   (bank size - 32 MiB minimum memory size)
#   TEXTBASE range end 0x7e0fffff = 0x7dffffff + 0x100000
#                                   (same, plus the 1 MiB minimum offset)
#   BASEADDR              default 0x0          range 0x0       0x7dffffff
#   SIZE                  default 0x80000000   range 0x2000000 0x80000000
#   U__BOOT_TEXTBASE_OFFSET
#     SYSTEM_VERSAL-2VE-2VM     0x40000000
#     SUBSYSTEM_ARCH_AARCH64    0x8000000
#     SUBSYSTEM_ARCH_ARM        0x4000000
#     SUBSYSTEM_ARCH_MICROBLAZE 0x100000
#     range 0x100000 0x7e0fffff
#
# Requirements: GNU sed (uses \t in regex).
#
# Usage:
#   ./init-plnx-config-syshw.helper.sh                                 # default path
#   ./init-plnx-config-syshw.helper.sh path/to/Kconfig.syshw           # explicit path

set -euo pipefail

KCONFIG="${1:-project-spec/configs/configs/Kconfig.syshw}"

if [[ ! -f "$KCONFIG" ]]; then
    echo "Error: '$KCONFIG' not found." >&2
    echo "Usage: $0 [path/to/Kconfig.syshw]" >&2
    exit 1
fi

# Board-scope gate: refuse to touch a file that is not the mango-versal-lp
# Kconfig.syshw. The axi_noc_mc_lpddr4_0 DDR_LOW0 block must be present.
if ! grep -q '^config SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_BASEADDR$' "$KCONFIG"; then
    echo "Error: '$KCONFIG' has no axi_noc_mc_lpddr4_0 DDR_LOW0 block." >&2
    echo "       This patch is mango-versal-lp specific (axi_noc_mc_lpddr4_0, 2 GiB)." >&2
    exit 1
fi

# Bug-side patterns: presence of ANY means the file is still broken.
BAD_PATTERNS='0x20108000000|0x20110000000|0x20148000000|0x2010c000000|0x20108100000|0x2010dffffff|0x402160fffff'
BAD_PATTERNS="$BAD_PATTERNS|0x448000000|0x450000000|0x488000000|0x44c000000|0x448100000|0x44dffffff|0x8960fffff"
# Patched-side markers: presence of ALL THREE uniquely identifies a fully
# patched file. Tied to specific blocks (AArch64 TEXTBASE default, BASEADDR
# range, TEXTBASE range) so they cannot collide with unrelated `default 0x0`
# lines elsewhere in the file; each occurs exactly once in the reference file.
# NOTE: `grep -E` does NOT interpret `\t` as a tab (unlike GNU sed); use $'\t'
# so the leading-tab anchor matches the literal indentation in Kconfig.syshw.
TAB=$'\t'
PATCHED_AARCH64="^${TAB}default 0x8000000 if SUBSYSTEM_ARCH_AARCH64$"
PATCHED_BASEADDR_RANGE="^${TAB}range 0x0 0x7dffffff$"
PATCHED_TBOFFSET_RANGE="^${TAB}range 0x100000 0x7e0fffff$"

# Idempotency: skip only when no bug values remain AND all patched markers are
# present. A partial state (some bad lines surviving a previous edit, or the
# looser size-1 range bounds emitted by an earlier revision of this script)
# will fail this check and be re-patched cleanly.
if ! grep -qE "$BAD_PATTERNS" "$KCONFIG" \
    && grep -qE "$PATCHED_AARCH64" "$KCONFIG" \
    && grep -qE "$PATCHED_BASEADDR_RANGE" "$KCONFIG" \
    && grep -qE "$PATCHED_TBOFFSET_RANGE" "$KCONFIG"; then
    echo "Note: '$KCONFIG' is already patched (skipping)." >&2
    exit 0
fi

BACKUP="${KCONFIG}.bak.$(date +%y%m%d_%H%M%S)"
cp -p "$KCONFIG" "$BACKUP"
echo "Backup of '$KCONFIG' created at '$BACKUP'"

# GNU sed: \t in regex matches a literal tab. All three blocks are scoped by
# their `config <NAME>` line down to the next `depends on ... DDR_LOW0_SELECT`
# anchor so substitutions cannot leak into unrelated entries.
sed -i \
    -e '/^config SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_BASEADDR$/,/^\tdepends on SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_SELECT$/{
        s/^\tdefault \(0x20108000000\|0x448000000\)$/\tdefault 0x0/;
        s/^\trange \(0x20108000000 0x2010dffffff\|0x448000000 0x44dffffff\)$/\trange 0x0 0x7dffffff/;
        s/^\trange 0x0 0x7fffffff$/\trange 0x0 0x7dffffff/;
      }' \
    -e '/^config SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_SIZE$/,/^\tdepends on SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_SELECT$/{
        s/^\tdefault 0x8000000$/\tdefault 0x80000000/;
        s/^\trange 0x2000000 0x8000000$/\trange 0x2000000 0x80000000/;
      }' \
    -e '/^config SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_U__BOOT_TEXTBASE_OFFSET$/,/^\tdepends on SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_SELECT$/{
        s/^\tdefault \(0x20148000000\|0x488000000\) if SYSTEM_VERSAL-2VE-2VM$/\tdefault 0x40000000 if SYSTEM_VERSAL-2VE-2VM/;
        s/^\tdefault \(0x20110000000\|0x450000000\) if SUBSYSTEM_ARCH_AARCH64$/\tdefault 0x8000000 if SUBSYSTEM_ARCH_AARCH64/;
        s/^\tdefault \(0x2010c000000\|0x44c000000\) if SUBSYSTEM_ARCH_ARM$/\tdefault 0x4000000 if SUBSYSTEM_ARCH_ARM/;
        s/^\tdefault \(0x20108100000\|0x448100000\) if SUBSYSTEM_ARCH_MICROBLAZE$/\tdefault 0x100000 if SUBSYSTEM_ARCH_MICROBLAZE/;
        s/^\trange \(0x20108100000 0x402160fffff\|0x448100000 0x8960fffff\)$/\trange 0x100000 0x7e0fffff/;
        s/^\trange 0x100000 0x7fffffff$/\trange 0x100000 0x7e0fffff/;
      }' \
    "$KCONFIG"

# Sanity: nothing should reference the bad base any more.
if grep -qE "$BAD_PATTERNS" "$KCONFIG"; then
    echo "Warning: Vivado-2025-bug values still remain in '$KCONFIG':" >&2
    grep -nE "$BAD_PATTERNS" "$KCONFIG" >&2
    echo "         Review the file - the pattern matchers may need updating." >&2
    exit 2
fi

# Sanity: both patched markers must have landed.
if ! grep -qE "$PATCHED_AARCH64" "$KCONFIG" \
    || ! grep -qE "$PATCHED_BASEADDR_RANGE" "$KCONFIG" \
    || ! grep -qE "$PATCHED_TBOFFSET_RANGE" "$KCONFIG"; then
    echo "Warning: '$KCONFIG' was modified but patched markers are missing." >&2
    echo "         The DDR_LOW0 block structure may have changed in this PetaLinux release." >&2
    exit 2
fi

echo "File '$KCONFIG' has been patched."
echo
echo "--- DDR_LOW0 block ---"
sed -n '/^config SUBSYSTEM_MEMORY_AXI_NOC_MC_LPDDR4_0_DDR_LOW0_BASEADDR$/,/^config SUBSYSTEM_MEMORY_IP_NAME$/p' "$KCONFIG"
