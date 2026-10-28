# meta-mango

Collection of Yocto/PetaLinux layers that enable MangoBoost card products.
The repository root is not a layer itself; it holds these sub-layers:

| Sub-layer           | Contents                                                                 |
| ------------------- | ------------------------------------------------------------------------ |
| `meta-mango-core`   | Architecture-neutral SDK recipes (mango-cli, mango-mgmt).                |
| `meta-mango-xilinx` | PetaLinux / Versal machine confs, device tree, U-Boot and kernel appends. Depends on `meta-mango-core` and `meta-xilinx`. |

## Prerequisites

- AMD PetaLinux Tools v2025.2: [link](https://www.xilinx.com/support/download/index.html/content/xilinx/en/downloadNav/embedded-design-tools/2025-2.html).
  Source its `settings.sh` so `petalinux-*` and `bootgen` are in `PATH`.
- Hardware design file (`.xsa`) exported from AMD Vivado.
- The MangoBoost software package (`mango-bsp`), which installs the SMC
  firmware under `/etc/mango/firmware/`. `BOOT.BIN` carries that firmware.
- `python3`; for `--secured` also `zip`, `unzip` and `openssl`.
- Access to `https://repo.mangoboost.io`, which serves the mango-cli tarball
  and the signing key. If your access needs the guest credentials from
  contact@mangoboost.io, put them in `~/.netrc` of the user that runs the
  build; the fetchers read it, so nothing else has to change:
  ```
  machine repo.mangoboost.io
  login <guest-username>
  password <guest-password>
  ```
  and `chmod 600 ~/.netrc`. Do not put credentials in a URL.

## Supported machines

| Machine                   | Description                |
| ------------------------- | -------------------------- |
| `mango-versal-lp-generic` | MangoBoost Versal LP board |
| `mango-versal-lp-boostx-base` | BoostX Base |

## Build guide

1. Create the PetaLinux project and clone this repository into it:
   ```
   petalinux-create project --template versal --name test_proj
   cd test_proj
   git clone https://github.com/MangoBoost/meta-mango
   ```

2. Build with `mango-build.sh`. It imports the XSA, applies the machine
   (layers, flash layout, U-Boot device tree), runs `petalinux-build` and
   packages the boot image:
   ```
   ./meta-mango/scripts/mango-build.sh --proj . xilinx mango-versal-lp-boostx-base \
       -- --xsa YOUR_HARDWARE.xsa
   ```
   The answers are kept in `mango-build.json`; the next run offers to reuse
   them, so `./meta-mango/scripts/mango-build.sh --proj .` is enough after
   the first build. Options after `--`:
   - `--clk MHZ`      — SMC clock: 250, 238 or 227 (default: unchanged).
   - `--enable-emmc`  — use an EXT4 rootfs on `/dev/mmcblk0p2` instead of initramfs.
   - `--secured`      — also stage the secure boot signing materials
     (`deliverable/<date>_<machine>-secured-img.tgz`); see
     [`meta-mango-xilinx/scripts/secure_boot/README.md`](meta-mango-xilinx/scripts/secure_boot/README.md).
   - `--clean`        — distclean the project first.

   `./meta-mango/scripts/mango-build.sh --list` prints the machines and
   `-h xilinx` the full option list.

### Using another package build

The recipes pin the mango-cli tarball and the mango-mgmt source they were
verified with, so nothing has to be set before the first build. To use
another build, override the pins in
`project-spec/meta-user/conf/petalinuxbsp.conf`:
```
MANGO_CLI_URI = "https://repo.mangoboost.io/artifactory/public-generic/petalinux-2025.2/mango-cli-boostx-0.8.6-0.petalinux-2025.2-aarch64.tar.gz"
MANGO_CLI_SHA256 = "<sha256 of the tarball, also served at <MANGO_CLI_URI>.sha256>"
MANGO_MGMT_URI = "git://github.com/MangoBoost/mango-drivers.git;protocol=https;branch=main"
MANGO_MGMT_SRCREV = "<commit>"
```

To check that the mango-cli tarball came from MangoBoost, download it
together with its signature (`<MANGO_CLI_URI>.asc`) and verify it with
the MangoBoost signing key:
```
curl -sn https://repo.mangoboost.io/artifactory/api/security/keypair/mb-gpg/public | gpg --import
gpg --verify <tarball>.asc <tarball>
```

### Building by hand

The steps `mango-build.sh` runs are plain PetaLinux commands and can be
run one by one. `init-plnx-config.sh` patches `project-spec/configs/config`
so the project uses the MangoBoost machine, flash layout and user layers
(`meta-mango-core` and `meta-mango-xilinx` as `CONFIG_USER_LAYER_0/1`):
```
petalinux-config --get-hw-description YOUR_HARDWARE.xsa --silentconfig
./meta-mango/meta-mango-xilinx/scripts/init-plnx-config.sh --machine mango-versal-lp-boostx-base
petalinux-build
petalinux-package boot --uboot --force --add /etc/mango/firmware/mblp.elf --file-attribute core=r5-0
./meta-mango/meta-mango-xilinx/scripts/package-images.sh
```
A project configured by an older layout of this repository keeps the
old layer path in `build/conf/bblayers.conf`, and `petalinux-config`
fails on it. Remove that `meta-mango` line, then run the script again.

## Expected binaries

Generated under `images/linux/` (see [`licenses/`](licenses/) for the
redistribution terms of each component):

- `BOOT.BIN` — PDI, PLM, PSM firmware, U-Boot DT, TF-A, U-Boot and the SMC
  firmware, with a 72-byte SHA-256 footer
- `image.ub` — kernel, device tree and rootfs, with the same footer
- `bl31.elf`
- `plm.elf`
- `psmfw.elf`
- `u-boot.elf`
- `system.dtb`
