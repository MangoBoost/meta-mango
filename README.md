# meta-mango

Collection of Yocto/PetaLinux layers that enable MangoBoost card products.

## Prerequisites

- AMD PetaLinux Tools v2024.02: [link](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/embedded-design-tools/2024-2.html)
- Hardware design file (`.xsa`) exported from AMD Vivado.

## Supported machines

| Machine                   | Description                |
| ------------------------- | -------------------------- |
| `mango-versal-lp-generic` | MangoBoost Versal LP board |

## Build guide

1. Create the PetaLinux project and import the hardware description:
   ```
   petalinux-create project --template versal --name test_proj
   petalinux-config -p test_proj --get-hw-description YOUR_HARDWARE.xsa
   ```

2. Add this layer and apply the MangoBoost configuration. The
   `init-plnx-config.sh` script patches `project-spec/configs/config` so the
   project uses the MangoBoost machine, flash layout, and user layer:
   ```
   cd test_proj
   git clone https://github.mangoboost.io/MangoBoost/meta-mango
   ./meta-mango/scripts/init-plnx-config.sh
   ```

   Options:
   - `--machine <name>` — select a supported machine (default: `mango-versal-lp-generic`).
   - `--enable-emmc`    — use an EXT4 rootfs on `/dev/mmcblk0p2` instead of initramfs.

3. Build and inspect the generated images:
   ```
   petalinux-build
   ls -al images/linux
   ```

## Expected binaries

Generated under `images/linux/` (see [`licenses/`](licenses/) for the
redistribution terms of each component):

- `bl31.elf`
- `plm.elf`
- `psmfw.elf`
- `u-boot.elf`
- `system.dtb`
