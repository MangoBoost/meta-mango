Redistribution terms of the binaries the build writes to `images/linux/`.

[GNU General Public License v2.0](./GPL-2.0)
- u-boot.elf (v2.0 or later)
- system.dtb (v2.0 or later)
- image.ub: the Linux kernel (v2.0 only)
- image.ub: the mango-mgmt kernel module (v2.0 only; source at
  https://github.com/MangoBoost/mango-drivers)

[BSD-3-Clause License](./BSD-3-Clause)
- bl31.elf

[MIT License](./MIT)
- plm.elf
- psmfw.elf
- the parts of the mango-mgmt module taken from the AMD AVED GCQ driver
  (listed in NOTICE of mango-drivers)

MangoBoost Software License Agreement
- image.ub: mango-cli-boostx, installed from a prebuilt tarball. The
  tarball carries the agreement and the third-party notices of the code
  compiled into it, and the image installs both under
  /usr/share/licenses/mango-cli-boostx/.
- the SMC firmware in BOOT.BIN (mblp.elf), taken from the mango-bsp package
  and redistributed under the terms that package is delivered with

The remaining packages in the image.ub rootfs come from the PetaLinux and
OpenEmbedded layers. The build collects their license texts under
`tmp/deploy/licenses/` of the PetaLinux project.
