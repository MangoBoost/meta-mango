# plm-firmware-efuse (provisioning PLM)

A second Versal PLM, built only to host the XilNvm eFUSE write server. Deployed
as `plm-prov.elf` and **never part of any product image**.

The eFUSE app that talks to it is not here. It comes from mango-bsp as
`mblp-prov.elf`, shipped with an empty `.efuse_keys` slot the Key Manager fills
with `fw-tool.py` — see `meta-mango-xilinx/scripts/secure_boot/README.md`. The baremetal app recipe
that used to live in this directory was removed: its `do_compile` refused to
build on placeholder keys, so the build itself demanded the red key, which is
exactly the coupling the two-role split exists to break.

## Build

```
petalinux-build -c plm-firmware-efuse
```

`images/linux/plm-prov.elf` is the result. It references no key, so the Developer
can build it without holding one.

`rm_work` is enabled project-wide, so once this recipe has been built its
`do_build` stamp alone survives and a plain rebuild reports success without
re-running anything. After editing the recipe, force it:

```
petalinux-build -c plm-firmware-efuse -x cleansstate
petalinux-build -c plm-firmware-efuse
```

Plain `-f` does not help: with no `-x` it only invalidates the stamp of
`do_build`, which is a noexec task.

## Why a second PLM

The product `plm.elf` cannot be used for provisioning, and that is deliberate.
It is built with the stock defaults, and two independent gates are off:

- `plm_nvm_en` (xilplmi) is false, which emits `#define PLM_NVM_EXCLUDE`. The
  PLM only calls `XNvm_Init()` under `#ifdef PLM_NVM`
  (`versal_plm/src/common/xplm_module.c`), so the XilNvm IPI module is never
  registered and a client request is rejected before reaching any handler.
- `xnvm_en_write_sec_crit_efuse` and `xnvm_en_write_key_management_efuse`
  (xilnvm) are false, leaving `XNVM_WRITE_SECURITY_CRITICAL_EFUSE` /
  `XNVM_WRITE_KEY_MANAGEMENT_EFUSE` undefined. The server's command-validity
  switch (`xilnvm/src/versal_gen/versal/server/xnvm_cmd.c`) then drops
  `WRITE_AES_KEYS`, `WRITE_IV` and `WRITE_PPK_HASH` to its default case —
  "Cmd not supported", `XST_INVALID_PARAM`. Those three are every write a burn
  performs.

So a shipped product cannot be talked into burning eFUSEs over IPI. Keep it that
way: do **not** enable these in `plm-firmware`.

`plm-firmware-efuse_2025.2.bb` flips exactly those knobs in its own `${S}` copy
of `versal_plm.mss` — in `do_configure:prepend`, never as a patch, because a patch
would go through `embeddedsw-source` into the shared tree and turn eFUSE writes on
in the product PLM too. Its `do_compile:append` then asserts the resulting macros,
so a mis-configured provisioning PLM fails the build instead of failing at burn
time.

## Fitting it in memory

Enabling the write paths pushed `.stack` past the end of `tmr_ram_cntlr_Mem`
("overflowed by 4192 bytes"), so the recipe disables what a one-shot burn does not
use: `plm_sem_en` (CRAM/NPI scanning) and `plm_ecdsa_en` (this project
authenticates with RSA only), plus `plm_ocp_en` and the unused boot modes.
`plm_ospi_en`, `plm_auth_jtag_en`, `plm_rsa_en` and `plm_secure_en` are held on
explicitly — see the comments in the recipe before trading any of them for space.

If it overflows again, look for dead weight before re-enabling any of the
above.

## Deployment

The recipe adds itself to `PACKAGES_LIST`, so PetaLinux's `plnx-deploy` class
copies the ELF into the project's `images/linux/` next to `plm.elf` and
`psmfw.elf`. The bitbake-native copy stays under `<TMPDIR>/deploy/images/`, which
is outside the project tree wherever `CONFIG_TMP_DIR_LOCATION` points, so `find`
from the project root will not see it.
