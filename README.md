# meta-mango

Collection of Yocto/PetaLinux layers that enable MangoBoost card products.
The repository root is not a layer itself; it holds these sub-layers:

| Sub-layer           | Contents                                                                 |
| ------------------- | ------------------------------------------------------------------------ |
| `meta-mango-core`   | Architecture-neutral SDK recipes (mango-cli, mango-mgmt).                |
| `meta-mango-xilinx` | PetaLinux / Versal machine confs, device tree, U-Boot and kernel appends. Depends on `meta-mango-core` and `meta-xilinx`. |

## Prerequisites

- AMD PetaLinux Tools v2025.2: [link](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/embedded-design-tools/2025-2.html)
- Hardware design file (`.xsa`) exported from AMD Vivado.

## Supported machines

| Machine                   | Description                |
| ------------------------- | -------------------------- |
| `mango-versal-lp-generic` | MangoBoost Versal LP board |
| `mango-versal-lp-boostx-base` | BoostX Base |

## Build guide

1. Create the PetaLinux project and import the hardware description:
   ```
   petalinux-create project --template versal --name test_proj
   petalinux-config -p test_proj --get-hw-description YOUR_HARDWARE.xsa
   ```

2. Add the layers and apply the MangoBoost configuration. The
   `init-plnx-config.sh` script patches `project-spec/configs/config` so the
   project uses the MangoBoost machine, flash layout, and user layers
   (`meta-mango-core` and `meta-mango-xilinx` as `CONFIG_USER_LAYER_0/1`):
   ```
   cd test_proj
   git clone https://github.com/MangoBoost/meta-mango
   ./meta-mango/meta-mango-xilinx/scripts/init-plnx-config.sh
   ```
   A project configured by an older layout of this repository keeps the
   old layer path in `build/conf/bblayers.conf`, and `petalinux-config`
   fails on it. Remove that `meta-mango` line, then run the script again.

   Options:
   - `--machine <name>` — select a supported machine (default: `mango-versal-lp-generic`).
   - `--enable-emmc`    — use an EXT4 rootfs on `/dev/mmcblk0p2` instead of initramfs.

3. Point the build at the prebuilt MangoBoost packages. The recipes carry
   defaults; to use another build, override them in
   `project-spec/meta-user/conf/petalinuxbsp.conf`:
   ```
   MANGO_CLI_URI = "https://repo.mangoboost.io/artifactory/public-generic/petalinux-2025.2/mango-cli-boostx-0.8.3-0.petalinux-2025.2-aarch64.tar.gz"
   MANGO_CLI_SHA256 = "<sha256 of the tarball, also served at <MANGO_CLI_URI>.sha256>"
   MANGO_MGMT_URI = "git://<host>/mango-mgmt.git;protocol=https;branch=main"
   MANGO_MGMT_SRCREV = "<commit>"
   ```

   To check that the mango-cli tarball came from MangoBoost, download it
   together with its signature (`<MANGO_CLI_URI>.asc`) and verify it with
   the MangoBoost signing key:
   ```
   curl -s https://repo.mangoboost.io/artifactory/api/security/keypair/mb-gpg/public | gpg --import
   gpg --verify <tarball>.asc <tarball>
   ```

4. Build and inspect the generated images:
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
