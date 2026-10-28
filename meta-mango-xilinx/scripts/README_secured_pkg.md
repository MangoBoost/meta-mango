# Mango-versal secure boot package

Everything needed to sign a secure boot image for this board, and to flash the
result. Built by `meta-mango-xilinx/scripts/wrap-package.sh --secured`.

**This package contains no key material.** It is the Developer half of the flow:
the person who builds never sees a key, and the person who holds the keys never
runs a build.

## Layout

```
bifs/              rendered BIFs, package-relative paths
  bootgen_secured.bif              golden image, authenticated + encrypted
  bootgen_provision.bif           production image, unsigned
  bootgen_provision_secured.bif   production image, signed
  _selftest.bif                    golden with the key lines removed
common/            read by both boot images
  pdi_files/       PL partitions: cdo, rnpi, rcdo
  files/           psmfw.elf
  fw-tool.py       the .efuse_keys injector - you run it, bootgen never sees it
mblp/files/        plm.elf bl31.elf u-boot.elf u-boot.dtb mblp.elf
mblp_prov/files/   plm-prov.elf mblp-prov.elf
nonsecured/        BOOT_PROVISION.BIN - the unsigned provisioning image
images/linux/      what gets flashed: boot.scr, image.ub, fpt.bin, flash_map.txt
                   boot.scr and fpt.bin are mango-bsp's, not build output
manifest.txt       every file's sha256, plus where the inputs came from
```

No flashing tool ships here - the four files under `images/linux/` are the
content, and the deployer writes them with whatever they already use.

## Key Manager: signing

Create your key tree at the package root - the BIFs reference `keys/AES/*.nky`
and `keys/RSA/*.pem` relative to it. A symlink works:

```bash
ln -s ~/secure_boot_keys keys
```

Then run bootgen from the package root, because bootgen resolves BIF paths
against its own working directory and not against the BIF's location:

```bash
cd <this directory>
bootgen -arch versal -image bifs/bootgen_secured.bif -w -o BOOT_SECURED.BIN -p xcvp1202
```

The golden image needs the two-pass key procedure that
`meta-mango/meta-mango-xilinx/scripts/secure_boot/files/_sign_secure_boot.sh` runs as its build step:
delete the old `.nky` files, build once to generate them, patch Key 0 and the
two pinned IVs, then build again. Skipping the delete fails with *"AES Key file
has less keys than the number of blocks"* whenever the ELFs have changed size.

Before signing, check `manifest.txt` against what you were told to expect -
`board_xsa` in particular. Signing the wrong XSA produces an image that builds
clean and does not boot.

## Key Manager: injecting the eFUSE keys

`mblp_prov/files/mblp-prov.elf` ships with its `.efuse_keys` slot unprogrammed
(328 bytes of `0xff`) - the ELF is linked without key material so the build never
holds a key. `common/fw-tool.py` stamps the values in afterwards, here, with no
compiler in the room:

```bash
python3 common/fw-tool.py mblp_prov/files/mblp-prov.elf get efuse_keys
python3 common/fw-tool.py mblp_prov/files/mblp-prov.elf set efuse_keys <key_file> --arm <FIELD>[,<FIELD>...]
```

Inject **before** building `bifs/bootgen_provision_secured.bif`, or the signed
image carries an empty slot - the firmware refuses a blob that is still the
placeholder, so it would burn nothing.

Only the fields you `--arm` get a value written into the slot; the rest of the key
file is read and left out. So `--arm AES_KEY ...` makes that ELF key material -
it belongs in your key tree, not back in the package - and an arm list without
`AES_KEY` does not put the red key in the file at all. Either way the values are
raw bytes in a binary slot, not text: `strings` shows nothing before or after
injection, and `get efuse_keys` is what reads the slot back.

`manifest.txt` pins both this tool's sha256 and the slot's contents at handover,
because a mismatched pair burns values at the wrong offset.

## Verifying the materials without keys

`bifs/_selftest.bif` is the golden BIF with the authentication, encryption and
key lines removed. Building it needs no keys, and it exercises the same
partition set the signed image will:

```bash
bootgen -arch versal -image bifs/_selftest.bif -w -o /tmp/selftest.bin -p xcvp1202
```

That is how to tell "my keys are wrong" from "the materials are wrong". The
packaging step already ran exactly this and checked every partition came back;
its output is not shipped, because a 22MB image that cannot be signed and only
boots an unprovisioned board is not worth carrying.

## Flashing

`images/linux/flash_map.txt` has the partition table, the offsets, the size
limits and which slot each image belongs in - four regions make a bootable
device, and this package carries three of them:

| offset | file | from |
| --- | --- | --- |
| `0x0` | `fpt.bin` | `images/linux/` |
| `0x20000` | `boot.scr` | `images/linux/` |
| `0x60000` | `BOOT.BIN` | **not here** - see below |
| `0x06000000` | `image.ub` | `images/linux/` |

There is deliberately no `BOOT.BIN`, because which one you mean is the whole
question: `nonsecured/BOOT_PROVISION.BIN` before the eFUSEs are burned, and the
image you signed afterwards.

The two boot slots are separate writes. `0x60000` is the **primary** slot;
`0x03000000` is **golden** and takes the signed image on its own:

```bash
mango-ctl mgmt flash <dev> BOOT_SECURED.BIN golden
```

## Order

Get a signed image booting from the golden slot first, then burn the eFUSEs,
then move the board fully to the secure image. eFUSE is one-time programmable: a
wrong burn bricks the board, and once PPK0 is burned JTAG boot mode is refused
(`0x203`), so there is no recovery path.
