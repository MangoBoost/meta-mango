# Versal Secure Boot

Key generation, signing, eFUSE provisioning and secure `BOOT.BIN` generation for
the Versal board.

---

## Roles

| Role | Tools | Scope |
| :--- | :--- | :--- |
| **Developer** | bitbake, XSA | build the sources, produce the unsigned package |
| **Key Manager** | bootgen, openssl | own the keys, sign/encrypt, build the burn images |

The Developer never sees a key. The Key Manager never runs bitbake. Every eFUSE
value is an *input*, so the key half needs nothing from a build to have happened.

---

## Quick start

### 1. Developer — build machine

```bash
petalinux-build
petalinux-build -c plm-firmware-efuse       # plm-prov.elf, needs no key

cd meta-mango
./meta-mango-xilinx/scripts/wrap-package.sh -p .. --secured
#  -> deliverable/<date>_<machine>-secured-img.tgz   hand this to the Key Manager
```

### 2. Key Manager — key machine

Work happens in **state directories**: `files/workspaces/<project>/<package name>/`, one
per Developer package, holding the key set the card holds (or will hold) with it. A
project is any directory under `files/workspaces/` with a name of your choosing
(`boostx`, `boostx-acme`, `test`, ...). A card's history is the sequence of its state
directories; a re-provision names two of them, before and after.

One command makes every state. The first state of a project gets a new key set; every
later one copies the keys of the project's latest state. A state is named after its
package, and a taken name gets `-1`, `-2`, ... appended.

```bash
cd meta-mango/meta-mango-xilinx/scripts/secure_boot

# first board family: a project's first state = new key set, then the first burn
./key_manager.sh --gen-keys <path>/261001_mango-versal-lp-boostx-base-secured-img.tgz --from boostx
#  -> files/workspaces/boostx/261001_mango-versal-lp-boostx-base/   package copied in, keys/ generated
./key_manager.sh --init files/workspaces/boostx/261001_mango-versal-lp-boostx-base
#  -> files/workspaces/boostx/261001_mango-versal-lp-boostx-base/out/flash-init-<time>.tar

# re-provision: the next state copies the latest state's keys, never generates
./key_manager.sh --gen-keys <path>/261001_mango-versal-lp-boostx-base-secured-img.tgz --from boostx --revoke 3
#  -> files/workspaces/boostx/261001_mango-versal-lp-boostx-base-1/   (same package: -1)  keys/ COPIED,
#     REVOKE_ID rows set so IDs 0..3 are revoked (cumulative - see below)
#  never replace keys/secret_key.txt: a before/after pair with different AES keys is refused
./key_manager.sh files/workspaces/boostx/261001_mango-versal-lp-boostx-base \
                 files/workspaces/boostx/261001_mango-versal-lp-boostx-base-1
#  -> files/workspaces/boostx/261001_mango-versal-lp-boostx-base-1/out/flash-update-<time>.tar
#  once the burn is confirmed, -1 is the card's state; the next --gen-keys copies from it

# a new Developer package: same command, the state takes the new package's name
./key_manager.sh --gen-keys <path>/261015_mango-versal-lp-boostx-base-secured-img.tgz --from boostx
#  -> files/workspaces/boostx/261015_mango-versal-lp-boostx-base/   keys/ copied from 261001_..-1
```

Each tar holds `production_BOOT.BIN` (golden) and `provision_BOOT.BIN` (primary). See
[Provision](#provision-the-two-images-a-card-is-flashed-with) below for what each mode
burns and how to flash it.

```
files/workspaces/<project>/<state>/            <state> = <date>_<machine>, from the package name
├── <state>-secured-img.tgz    the Developer's package, copied in
├── keys/                      the key set. THE ONLY COPY - back it up off this checkout
├── out/                       flash-*.tar, and <time>/FLASH_NOTES.md + SHA256SUMS per run
├── .work/                     work trees; key copies are shredded on exit, the rest is kept
├── workspace.txt              PROJECT, STATE, CREATED, FROM, PSK_FPR - the register entry
└── history.log                one line per action
```

**Revoking is cumulative.** `--revoke N` (on `--gen-keys`, or `./key_manager.sh --revoke N
<state>` on an existing state) sets every `REVOKE_ID` bit for IDs `0..N`, keeping bits
already set, and the next images are signed with `N+1`. A board that refuses ID N must not
accept an older image either, and a register of which lower IDs were skipped is exactly
what nobody keeps for boards in the field. A hand-edited mask with holes is accepted but
the before/after plan warns about it. `--revoke` is refused on a state that has already
produced a flash tar; make the next state instead.

**IDs 240..255 are reserved.** Production images use revoke IDs 0..239. The top sixteen
(`REVOKE_ID_7` bits 16..31) are never burned by this tool; what uses them is decided
separately. `--revoke` stops at 238, the plan refuses an after set that adds a reserved
bit, `--init` refuses a template that carries one, and the next production ID is never
taken from that range.

`workspace.txt` keeps `STATE` and `PACKAGE` separately, and `FROM` names the state the
keys were copied from. `--gen-keys` never hands an existing `keys/` to the generator and
never copies over one; on a provisioned board's tree `efuse_keys.txt` *is* the board
state. Generator options (`--efuse-write`) are accepted only for a project's first state.
A before/after run refuses two states from different projects and signs with the
**after** state's package; the before state's package stays as the record of how that
state was made.

A bare key tree (`secret_key.txt` at its top) still works wherever a workspace does,
with `--tgz` naming the package; the tar then lands in the current directory.

**Importing a key set that predates state directories** (a board already provisioned
from a bare tree): make the project's first state from that tree with `--keys-from`, as a
`.tar` of the tree or the tree itself. It is taken as the card's state: `efuse_keys.txt`
is not regenerated. Every later `--gen-keys … --from <project>` then copies from it.

```bash
./key_manager.sh --gen-keys <path>/<date>_<machine>-secured-img.tgz --from <project> --keys-from <old-tree.tar>
```

| Script | Options |
| :--- | :--- |
| `key_manager.sh` | `--gen-keys <tgz> --from <project-dir> [--revoke <N>]` (+ `--efuse-write "<fields>"`, `-v`, first state only) · `--revoke <N> <state>` · `--init <state\|dir>` · `<before-state> <after-state>` · `--dry-run` · `--tgz <path>` · `--user-slot 1` · `-v` |

`key_manager.sh` is the only script a Key Manager runs. It hands key generation to
`files/_gen_keys.sh` and signing to `files/_sign_secure_boot.sh` (unpack, verify, sign,
inject, build). Both are internal; run them by hand only to debug one step.

`--efuse-write` defaults to the blank-board list for **A-HWRoT with red-key
encryption**. One burn, three stages:

| stage | fields | what it does |
| :--- | :--- | :--- |
| values | `AES_KEY` `PPK0_HASH` `METAHEADER_IV` `PLM_IV` | the red key, the PPK0 hash, the two boot-image IVs |
| policy | — | none: `DEC_ONLY` is refused, see below |
| locks | `PPK0_WR_LK` | seals the PPK0 hash this burn wrote |

The firmware issues the three stages as three separate `XNvm_EfuseWrite` calls and
stops at the first that fails, so a lock can never land before the field it seals —
arming `PPK0_WR_LK` alongside `PPK0_HASH` in one request is safe. See mango-bsp
`provision_endpoint.cpp` (`stageValues && stagePolicy && stageLocks`). xilnvm orders
the same way inside one request: keys, hashes and IVs are programmed first and
`XNvm_EfuseWriteSecCtrl` — every `*_WR_LK` — runs last
(`versal/server/xnvm_efuse.c:255`).

On a board that already holds some of those, drop them: arming a burned fuse makes
xilnvm refuse the whole write (`0x2B060010`), so nothing else gets burned either.
Dropping `AES_KEY` is only correct on a part that already holds that exact key — both
signed images are encrypted with `keysrc = efuse_red_key` and open with nothing else,
so on a part whose AES row is empty they stop booting the moment `PPK0_HASH` is burned
and the ROM starts enforcing RSA. `files/_sign_secure_boot.sh` says which case a run is in.

**What the default leaves out, and why:**

- `AES_WR_LK` — settable, **not armed by default.** Sealing the AES row gives up ever
  loading it with a PUF-wrapped black key, which is the only path to S-HWRoT — the
  path `DEC_ONLY` would need. Add it to `--efuse-write` once a part's key burn is
  confirmed and that path is not wanted. `efuse_keys.txt` still carries
  `AES_WR_LK = 1`; a line without an `armed` note is not written.
- `PPK1_WR_LK` `PPK2_WR_LK` — PPK1/PPK2 stay open so the RSA key set can be rotated
  later, and so a botched `PPK0_HASH` burn still has a recovery path. What stops that
  being an opening is that an image signed under a hash burned into PPK1 by someone
  else still has to be encrypted with a red key they cannot read out of the part.
- `USER_KEY0_WR_LK` `USER_KEY1_WR_LK` — the user-key slots are unused; locking them
  would seal them empty for nothing.
- `AES_CRC_LK` — **refused, not merely unset.** The AES row is write-only in silicon,
  so its CRC check is the only channel that can ever say anything about the stored
  key — on this board or on an RMA return. Locking it seals the check, not the key.
  What it would buy is closing a key-confirmation oracle: someone who already holds a
  candidate red key and can reach the fuses gets a repeatable yes/no on whether *this*
  part uses it. That is the weaker threat. Arm it explicitly in a later burn once a
  CRC-check op exists in the provisioning app and a part has passed it.

### `DEC_ONLY` must never be armed in this flow

**It is incompatible with the red key, and burning it ends the board.** `files/_gen_keys.sh`
refuses it, and `files/_sign_secure_boot.sh` fails preflight and verify on a key file that
carries it.

`DEC_ONLY` puts the part in **S-HWRoT**, and per AMD's *Cumulative Secure Boot
Operations* table S-HWRoT decryption **must use a PUF KEK** — the eFUSE *black* key.
Every BIF here says `keysrc = efuse_red_key`. So after the burn the ROM refuses every
image this flow can build:

- `0x308` *eFUSE key not selected for S-HWRoT boot mode* — on each candidate
- `0x30F` *No image found after searching the supported address range* — the golden
  fallback then walks the whole range and every slot fails the same check

That is a board that boots nothing. **LP R.2 was lost this way on 2026-08-05.** This
flow is A-HWRoT (PPK0 hash burned, RSA enforced) with red-key encryption as defence in
depth — encryption is *used*, just not *mandated by the ROM*.

Arming it would first need the whole PUF/black-key architecture: PUF registration,
`BLACK_IV` burned, the black key in the AES row, and `keysrc = efuse_black_key` through
every BIF. That is a different key design, not a fuse to flip — and it is why
`AES_WR_LK` is not armed by default either.

> The provisioning firmware's own vet (`provision_endpoint.cpp:987-994`) lets
> `DEC_ONLY` through whenever `AES_KEY` is armed in the same request — it checks that a
> key exists, not that the key is a PUF KEK. mango-bsp should refuse it outright.

`files/_gen_keys.sh` refuses a lock whose subject this flow does not write, and warns when a
lock is armed without its subject — correct only on a board that already holds it,
which the script cannot see. The firmware makes the same call against the real part.

`key_manager.sh` must print `RESULT: PASS` before anything reaches a board.

### 3. Board — irreversible from here

> **eFUSE is one-time programmable.** A wrong burn ends the board. Once PPK0 is
> burned, unsigned images are refused (`0x30F` / `0x345`) and JTAG boot mode is
> disabled (`0x203`) — there is no recovery path.
>
> With the default arm list the same burn writes the red key and sets `PPK0_WR_LK`, so
> the PPK0 hash is unwritable for good. From then on the board boots only images signed
> with this key set and encrypted with that red key — both signed images in the package
> are encrypted throughout and the verify step re-checks that, but a board whose burn
> landed wrong is scrap, not a re-run.

```bash
tar xf flash-init-<time>.tar            # production_BOOT.BIN, provision_BOOT.BIN

# 1. golden slot first
#    It is encrypted with the eFUSE red key, so on a blank part it does not boot
#    until step 2's burn has written AES_KEY.
mango-ctl mgmt flash <dev> production_BOOT.BIN golden

# 2. provisioning image to the primary slot (the default - no slot argument), boot
mango-ctl mgmt flash <dev> provision_BOOT.BIN
mango-ctl dev reset <dev>
#    The provisioning app burns, copies golden to primary and resets. Keep power until
#    the UART shows, in order:
#      key blob: valid
#      burn stage 'values': programmed
#      OSPI GOLDEN COPY: P.1 (golden) -> P.0 (primary)
#    After the reset both slots hold production_BOOT.BIN. Linux up = done.
```

Never have both slots unsigned at burn time. After the burn the only update path
is in-band flash.

---

## Layout

```
key_manager.sh           Key Manager: workspaces, --gen-keys, and the two flash images (first burn or re-provision)
files/
├── workspaces/<project>/<state>/   Key Manager state dirs (git-ignored): package, keys/, out/, .work/
├── _gen_keys.sh         key generator key_manager.sh --gen-keys runs: keys, ppk0_hash, efuse_keys.txt
├── _sign_secure_boot.sh signing engine key_manager.sh runs: unpack, sign, inject, verify
├── _key_manager_lib.py  key_manager.sh's planner and image checks
├── _make_zip.sh         Developer's package builder (wrap-package.sh calls it)
├── _steplib.sh          shared PASS/FAIL step runner
├── _efuse_iv.sh         the two pinned IVs. One copy, two readers
├── _pkg_xsa_bif.py      XSA BIF parser
└── bifs/                BIF templates + the AUTH_JTAG BIF
```

The top level is what a human types. Everything else lives under `files/` with a
leading `_`, including `_make_zip.sh` - the Developer's entry point is
`meta-mango-xilinx/scripts/wrap-package.sh --secured`, one level up, which calls it.

Each wrapper holds its own steps as `sb_step_*` functions, run in subshells by
`_steplib.sh`, with per-step logs under `files/logs/<timestamp>/` whether or not
`-v` is given.

---

## Outputs

What the signing engine `files/_sign_secure_boot.sh` leaves in its package directory.
`key_manager.sh` runs it inside `<workspace>/.work/`, keeps only the two images it verified,
renames them `production_BOOT.BIN` / `provision_BOOT.BIN` and packs them into the
`flash-*.tar` described under [Provision](#provision-the-two-images-a-card-is-flashed-with).

| File | What it is |
| :--- | :--- |
| `sign/BOOT_SECURED.BIN` | production image, signed + encrypted. **No key inside** (`keysrc = efuse_red_key`) |
| `sign/BOOT_PROVISION.BIN` | unsigned burn image, for a board whose PPK0 is not burned yet |
| `sign/BOOT_PROVISION_SECURED.BIN` | signed burn image, for eFUSE work *after* the burn |
| `<proj>/<date>_<machine>-secured-boot.tgz` | the flashing half, packed by step 7 |
| `authenticatedJtagImage-rsa.bin` | JTAG unlock for a provisioned board. Never ship it |

Step 7 packs `BOOT_SECURED.BIN`, `BOOT_PROVISION_SECURED.BIN` and a
`flash_notes.txt` — board, `psk_fpr`, the sha256s and the slot order. Handing
over images without that order is how a board gets bricked.

**Deliver as two packages, never one.** The production image carries no key and can
go through normal channels. Both burn images carry the red key when `AES_KEY` is
armed — controlled path, once per board family, destroyed after the burn.

`--first-burn` packs `BOOT_PROVISION.BIN` into the tgz as well, for the early
stage where the flashing operator also burns the eFUSEs. That collapses the
two-package rule into one: with `AES_KEY` armed the whole tgz is key material,
so it takes the controlled path end to end. Drop the flag once flashing and
burning become separate roles.

`--pure` packs `BOOT_PROVISION.BIN` **instead of** `BOOT_PROVISION_SECURED.BIN`, so
the tgz is the product image plus the unsigned burn image and nothing else. Use it
for a board whose PPK0 is not burned yet — that board refuses the signed burn image,
so shipping it is noise the flashing operator has to reason about. Same red-key
handling as `--first-burn`: with `AES_KEY` armed the whole tgz is key material. The
two flags are exclusive.

Keep `sign/BOOT_PROVISION_SECURED.BIN` out of band when you use `--pure`: after the
burn it is the only provisioning image the board still boots, and it cannot be
rebuilt from a later package.

The signed burn image cannot be made later: it needs this package and this key set,
and the package is replaced every build.

---

## Keys

`files/workspaces/<project>/<state>/keys/` — `secret_key.txt`, `RSA/psk1_rsa.pem`,
`RSA/ssk1_rsa.pem`, `ppk0_hash.txt`, `efuse_keys.txt`, `AES/`. Git-ignored. A bare tree
anywhere else (`--gen-keys <dir>`) has the same layout.

- **Back up the whole tree together, off this checkout.** It sits inside the repo
  working tree, so `git clean -xfd` or a fresh clone takes it with everything else.
  `psk1_rsa.pem` cannot be regenerated: lose it and every board burned with its
  PPK0 hash is permanently unbootable.
- **The tree is complete or empty.** `files/_gen_keys.sh` refuses a partial one rather
  than regenerating a missing key beside the survivors — that pairing signs for a
  key no board was burned with, and nothing downstream can tell.
- To make a *different* set, move the tree aside first. Never for a board family
  whose PPK0 hash is already burned.
- `efuse_keys.txt` holds the red key in the clear (mode `600`). Do not copy it out
  of the key tree.
- Record `psk_fpr` from `files/_gen_keys.sh` in the board-family register and compare it
  on every signing run. `files/_sign_secure_boot.sh` prints it in preflight.

---

## Provision: the two images a card is flashed with

```
./key_manager.sh --init <state>                       # blank card, first provisioning
./key_manager.sh <before-state> <after-state>         # provisioned card, move to the after state
./key_manager.sh --init <keys-dir> --tgz <pkg>                       # the same, bare key trees
./key_manager.sh <before-keys-dir> <after-keys-dir> --tgz <pkg>
```

Both produce `flash-init-<time>.tar` (`--init`, blank card) or `flash-update-<time>.tar`
(already provisioned card) in the (after) state's `out/` (bare trees: the directory it was
run from), holding `production_BOOT.BIN` (golden) and `provision_BOOT.BIN` (primary), and
both flash the same way: golden first, then primary, boot; the provisioning app burns,
copies golden to primary and resets.

**First provisioning (`--init`).** The key set is the state's `keys/`, fresh from
`--gen-keys`. The burn is what its `efuse_keys.txt` arms (red key, PPK0 hash, IVs, `PPK0_WR_LK`).
`provision_BOOT.BIN` is unsigned and plaintext, because a blank card has no PPK hash to
check a signature against; its key blob holds the red key in the clear, so it takes the
controlled path and is destroyed after the burn. The production image is `efuse_red_key`
throughout and does not boot until the burn lands.

**Re-provision (`<before-state> <after-state>`).** The before state's `keys/` is the tree
the cards were provisioned with. The after state is made with `--gen-keys <pkg> --from
<project>`, which copies the project's latest state's tree, and then given the revoke bits
to add. Nothing is promoted or moved: once the burn is confirmed on the card,
the after state is simply the card's current state. With bare trees the two are
`<before-keys-dir> <after-keys-dir>`.

| change in the after tree | what is burned | production image |
|---|---|---|
| `REVOKE_ID_<n>` filled in `efuse_keys.txt` | that row | `efuse_red_key`, signed with the highest revoked ID + 1 |
| a different `secret_key.txt` (AES key) | nothing: the run fails with `FAIL: the AES key differs` | the red key is burned once and never changes |

The build does not know which card it is for. It assumes the state the before tree
describes: its provisioning (red key, its PSK in PPK0, the IVs) plus any `REVOKE_ID` rows its
`efuse_keys.txt` carries. Refused, because a fuse only goes 0 -> 1:

- a different AES key, RSA pair or IV in the after tree (the AES row, PPK0 and the IVs are burned);
- a revoke row that clears a bit the before tree has, or adds bits to a row the before tree
  already has bits in (the provisioning firmware only writes a blank row; use the next row);
- an after tree identical to the before tree.

The package to sign is the **after** state's `*-secured-img.tgz` (bare trees: the one in
the project root of this clone or of the clone the key trees live in; `--tgz` to name
another).

Output: `flash-update-<time>.tar` in `<after-state>/out/`, written only when every check passes:

| file | slot |
|---|---|
| `production_BOOT.BIN` | golden |
| `provision_BOOT.BIN` | primary: burns the change, copies golden to primary, resets |

Flash golden first, then primary, boot, and keep power until `burn stage 'values':
programmed` and the golden copy finish. After the reset both slots hold the production image.
The golden image boots before and after the burn (same AES key, its revoke ID not yet
revoked). If the production image fails after the burn, recovery is over
JTAG. `--dry-run` prints what would be burned. Notes and checks stay in
`<after-state>/out/<time>/` (bare trees: `<project>/.provision-work/`).

Limits: changing the AES key (moving a card to `USER_KEY0`/`1`) is out of scope: the plan step
refuses it; PPK revocation (`PPKx_INVLD`) is not supported by the provisioning firmware.

Known behaviour:
- The inject and pack steps print "no red key in this ELF". When the AES key changes the key
  blob holds the after AES key, so `mblp-prov.elf` and the unsigned `BOOT_PROVISION.BIN` carry it in
  plaintext. `key_manager.sh` shreds both (and every key copy in its work tree) on exit unless
  `--keep-work`.
- Run 2 uses `files/_sign_secure_boot.sh --product-only`. Without it, "build burn images" fails
  with `Key0 must be same across the BIF`: the unedited provisioning BIF makes new random
  `.nky` files next to ones already set to the after key.
- The product build logs `sed: can't read keys/AES/mango_metaheader.nky` and
  `mango_plm.nky`: those blocks are plaintext in the after BIF, so bootgen makes no key
  file for them.
- The provisioning app's payload is not decrypted; the notes mark that check PARTIAL.
- The AUTH_JTAG messages in `out/<time>/` carry a revoke ID (the PLM checks it against the
  `REVOKE_ID` rows before the signature): `.before.bin` the provision image's ID, `.after.bin`
  the production image's. Keep the one that matches the card's state; a message whose ID
  the card has revoked is refused however good its PPK.
- Do not run `files/_sign_secure_boot.sh` in the same clone while `key_manager.sh` runs: both write
  `files/logs/<second>/` and `authenticatedJtagImage-rsa.bin` (key_manager.sh restores the latter).

---

## Open item

The word order inside a key-blob slot is **not confirmed against silicon**. The
injector and the firmware agree with each other; whether that matches what XilNvm
expects is unverified. A reversed PPK0 hash is a board that boots nothing.

Settle it non-destructively before the first burn: the provisioning app has a
read-only eFUSE mode, so a board already holding a known PPK0 can be read back.

This is a one-time check per key set, not per board — confirm it on a pilot board and
the whole production run can burn everything in one pass. Until it is confirmed, the
open `PPK1_WR_LK` / `PPK2_WR_LK` are the only thing standing between a reversed
`PPK0_HASH` and a dead board: burn PPK1 with the order you learned and sign with
`ppkselect`. Do not add those two locks to the arm list before the read-back is done.
