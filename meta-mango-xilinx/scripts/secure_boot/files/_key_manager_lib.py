#!/usr/bin/env python3
"""Helpers for key_manager.sh. Parsing, slot choice, BIF editing and image checks live
here so the shell script only sequences runs. Nothing in this file prints a key
value: keys are identified by the first 12 hex digits of their sha256.

Every subcommand exits 0 on success and 1 with a message on stderr otherwise.
"""
import argparse
import hashlib
import importlib.util
import os
import re
import struct
import subprocess
import sys

# Versal key-source words as stored in the image (read little-endian).
KEYSRC_NONE = 0x00000000
KEYSRC_EFUSE_RED = 0xA5C3C5A3
KEYSRC_EFUSE_USER_KEY0 = 0x5C3CA5A3   # 2026-09-22 build, bootgen 2025.2.1, 14 partitions
# Not confirmed. Fill in only when a test build and UG1283 agree; until then the
# USER_KEY1 path is refused for real runs (dry runs still report it).
KEYSRC_EFUSE_USER_KEY1 = None
KEYSRC_USER = {0: KEYSRC_EFUSE_USER_KEY0, 1: KEYSRC_EFUSE_USER_KEY1}

# Boot header / IHT / PHT offsets, confirmed against 'bootgen -read'.
BH_KEYSRC = 0x18
BH_METAHDR_OFF = 0xC4
PLM_AC_OFF = 0xF80
IHT_TOTAL_IMAGES = 0x04
IHT_TOTAL_PARTS = 0x0C
IHT_PHT_OFF = 0x10          # words
IHT_KEYSRC = 0x40
IHT_HDR_AC = 0x48           # words
PHT_NEXT = 0x0C             # words
PHT_ID = 0x30
PHT_AC_OFF = 0x34           # words
PHT_KEYSRC = 0x44
AC_PPK = 0x40
AC_PPK_LEN = 0x404          # mod 512 + mod ext 512 + exp 4

NO_VALUE = ('-', '0', '')
LINE_RE = re.compile(r'^([A-Z0-9_]+)\s*=\s*([^#]*?)\s*(?:#\s?(.*))?$')
HEADER_KEYS = ('FORMAT', 'GENERATED', 'PROJECT', 'ARMED')


def die(msg):
    print(f"key_manager: {msg}", file=sys.stderr)
    sys.exit(1)


def fid(data):
    """Identifier for key material: sha256 prefix, never the value."""
    if isinstance(data, str):
        data = data.encode()
    return hashlib.sha256(data).hexdigest()[:12]


def read_hex(path, nibbles):
    try:
        txt = open(path).read()
    except OSError as e:
        die(f"cannot read {path}: {e}")
    m = re.search(r'[0-9A-Fa-f]{%d}' % nibbles, txt)
    if not m:
        die(f"no {nibbles}-hex value in {path}")
    v = m.group(0).upper()
    if set(v) == {'0'}:
        die(f"{path}: value is all zeros")
    return v


def load_fwtool(path):
    spec = importlib.util.spec_from_file_location('fwtool', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --------------------------------------------------------------- key files
class KeyFile:
    """A mango-efuse-keys/1 file as lines, so it can be rewritten in place."""

    def __init__(self, path):
        self.path = path
        try:
            self.lines = open(path).read().splitlines()
        except OSError as e:
            die(f"cannot read {path}: {e}")
        self.header, self.fields = {}, {}      # name -> (index, value, comment)
        for i, raw in enumerate(self.lines):
            if raw.lstrip().startswith('#') or not raw.strip():
                continue
            m = LINE_RE.match(raw.strip())
            if not m:
                die(f"{path}:{i + 1}: not 'NAME = VALUE': {raw!r}")
            name, value, comment = m.group(1), m.group(2).strip(), (m.group(3) or '').strip()
            if name in HEADER_KEYS:
                self.header[name] = (i, value)
            else:
                if name in self.fields:
                    die(f"{path}:{i + 1}: {name} appears twice")
                self.fields[name] = (i, value, comment)
        if self.header.get('FORMAT', (0, ''))[1] != 'mango-efuse-keys/1':
            die(f"{path}: FORMAT is not mango-efuse-keys/1")

    def value(self, name):
        v = self.fields.get(name, (0, '-', ''))[1]
        return None if v in NO_VALUE else v.upper()

    def armed(self):
        v = self.header.get('ARMED', (0, ''))[1]
        return [] if v in ('', '<none>') else v.split()

    def set_header(self, key, value):
        if key in self.header:
            i = self.header[key][0]
            self.lines[i] = f"{key:<9} = {value}"
        else:
            self.lines.insert(1, f"{key:<9} = {value}")
            self.__init__from_lines()

    def __init__from_lines(self):
        tmp = self.lines
        self.header, self.fields = {}, {}
        for i, raw in enumerate(tmp):
            if raw.lstrip().startswith('#') or not raw.strip():
                continue
            m = LINE_RE.match(raw.strip())
            name, value, comment = m.group(1), m.group(2).strip(), (m.group(3) or '').strip()
            if name in HEADER_KEYS:
                self.header[name] = (i, value)
            else:
                self.fields[name] = (i, value, comment)

    def set_field(self, name, value, comment):
        line = f"{name:<17} = {value}" + (f"   # {comment}" if comment else '')
        if name in self.fields:
            self.lines[self.fields[name][0]] = line
        else:
            self.lines.append(line)
        self.__init__from_lines()

    def insert_comment(self, text_lines):
        """After the header block, before the first comment/field."""
        at = max(i for i, _ in self.header.values()) + 1
        self.lines[at:at] = ['#'] + [f"# {t}" if t else '#' for t in text_lines] + ['#']
        self.__init__from_lines()

    def write(self, path):
        body = '\n'.join(self.lines) + '\n'
        if re.search(r'#[^\n]*\barmed\s*:', body, re.I):
            die(f"refusing to write {path}: a comment says 'armed:', which fw-tool "
                f"reads as an advisory arm list")
        fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as f:
            f.write(body)


def source_tail(comment):
    """The provenance part of a field comment: what follows the first ';'."""
    return comment.split(';', 1)[1].strip() if ';' in comment else ''


# ------------------------------------------------------------------ plan
# Fields the before key set burned at provisioning and that no later burn may change.
FIXED = ('PPK0_HASH', 'METAHEADER_IV', 'PLM_IV', 'BLACK_IV', 'DATA_PARTITION_IV')


def provisioned(a):
    """What the before key set burned at provisioning, from its own sources (the key
    files and _efuse_iv.sh), not from efuse_keys.txt edit history."""
    return {'AES_KEY': read_hex(a.before_key, 64), 'PPK0_HASH': a.ppk_before.upper(),
            'METAHEADER_IV': a.iv_meta.upper(), 'PLM_IV': a.iv_plm.upper()}


REVOKE_ROWS = tuple(f"REVOKE_ID_{i}" for i in range(8))
# Revoke IDs 0..239 belong to production images. 240..255 (REVOKE_ID_7 bits 16..31) are
# reserved: no production rule may ever burn them, and production images never carry
# them. What uses that range is decided separately; the reservation is decided now.
REVOKE_PROD_MAX = 239
REVOKE_RESERVED_MASK_ROW7 = 0xFFFF0000


def revoke_rows(kf):
    """The eight revocation rows of a key file as ints (a '-' row is 0)."""
    return [int(kf.value(r) or '0', 16) for r in REVOKE_ROWS]


def next_id(rows):
    """The revoke ID a new production image is signed with: one above the highest
    revoked production ID (0 when none is revoked). IDs are used in sequence 0, 1, 2,
    ...; every ID at or below the highest revoked one counts as spent, so a new image
    never reuses one. The reserved range 240..255 is neither counted nor returned."""
    top = max((i for i in range(REVOKE_PROD_MAX + 1) if (rows[i // 32] >> (i % 32)) & 1), default=-1)
    if top >= REVOKE_PROD_MAX:
        die(f"revoke ID {REVOKE_PROD_MAX} is revoked - no production ID is left to sign a new image with "
            f"(240..255 are reserved)")
    return top + 1


def reserved_bits(rows):
    """The reserved IDs (240..255) set in a row set, as a list, for refusals."""
    return [240 + b for b in range(16) if (rows[7] >> (16 + b)) & 1]


def revoke_mask_upto(n):
    """The eight REVOKE_ID rows with every ID 0..n set. Revoking an ID revokes every
    lower one too: a board that refuses ID n must not accept an older image either, and
    a register of which lower IDs were skipped is exactly what nobody keeps."""
    if not 0 <= n <= REVOKE_PROD_MAX - 1:
        die(f"revoke ID {n}: production IDs are 0..{REVOKE_PROD_MAX}, and {REVOKE_PROD_MAX} itself cannot be "
            f"revoked (no ID would be left to sign with); 240..255 are reserved")
    rows = []
    for i in range(8):
        lo, hi = 32 * i, 32 * i + 31
        if n >= hi:
            rows.append(0xFFFFFFFF)
        elif n >= lo:
            rows.append((1 << (n - lo + 1)) - 1)
        else:
            rows.append(0)
    return rows


def revoke_holes(rows):
    """IDs below the highest revoked one that are NOT revoked - a non-cumulative mask."""
    top = max((i for i in range(REVOKE_PROD_MAX + 1) if (rows[i // 32] >> (i % 32)) & 1), default=-1)
    return [i for i in range(top) if not (rows[i // 32] >> (i % 32)) & 1]


def cmd_revoke(a):
    """Set the REVOKE_ID rows of a key file so that IDs 0..N are revoked (cumulative),
    keeping any bit already set. Rewrites only those eight lines."""
    kf = KeyFile(a.file)
    have = revoke_rows(kf)
    want = revoke_mask_upto(a.upto)
    new = [h | w for h, w in zip(have, want)]
    if new == have:
        print(f"revoke: IDs 0..{a.upto} already revoked in {a.file}; nothing to change")
        return
    for i, (r, h, v) in enumerate(zip(REVOKE_ROWS, have, new)):
        if r not in kf.fields:
            die(f"{a.file}: no {r} line")
        idx = kf.fields[r][0]
        if v == 0:
            continue
        note = f"IDs 0..{a.upto} revoked (cumulative, key_manager.sh --revoke {a.upto})"
        if h and h != v:
            note += f"; was {h:08X}"
        kf.lines[idx] = f"{r:<17} = {v:08X}   # {note}"
    kf.write(a.file)
    changed = [f"{r}={v:08X}" for r, h, v in zip(REVOKE_ROWS, have, new) if h != v]
    print(f"revoke: {' '.join(changed)}  (IDs 0..{a.upto}); new images will be signed with revoke_id {next_id(new)}")


def cmd_plan(a):
    """Decide what the burn image writes, from the two key sets alone. The card is not
    known here: it is assumed to be in the state the before key set describes - its
    provisioning (red key, PSK in PPK0, IVs) plus any revoke rows its efuse_keys.txt
    carries - with the user slots empty. --user-slot 1 picks USER_KEY1 for a card
    that already used USER_KEY0."""
    burned = provisioned(a)
    after_key = read_hex(a.after_key, 64)
    before, after = KeyFile(a.before_efuse), KeyFile(a.after_efuse)

    # 1. nothing the before set burned may change
    after_vals = {f: after.value(f) for f in FIXED}
    after_vals['PPK0_HASH'] = a.ppk_after.upper()      # from the PSK, not the text file
    bad = [f"{f} is burned by the before key set; the after key set wants a different value"
           for f in FIXED if burned.get(f) and after_vals.get(f) and burned[f] != after_vals[f]]

    # 2. revoke rows: fuses only go 0 -> 1, so the after row must keep every bit the
    #    before row has. Adding bits to a row that already has some needs a
    #    provisioning firmware that writes only the new bits (mango-bsp gate 4 revoke
    #    rule); a row that is blank on the card works with any firmware.
    b_rows, a_rows = revoke_rows(before), revoke_rows(after)
    new_reserved = reserved_bits([0] * 7 + [(a_rows[7] & ~b_rows[7]) & REVOKE_RESERVED_MASK_ROW7])
    if new_reserved:
        bad.append(f"REVOKE_ID_7: the after set revokes reserved ID(s) {new_reserved} (240..255 are "
                   f"reserved and never burned by a production rule)")
    rv_arm, rv_grow = [], []
    for i, (bv, av) in enumerate(zip(b_rows, a_rows)):
        if bv & ~av:
            bad.append(f"REVOKE_ID_{i}: the after set clears bits the before set revoked "
                       f"({bv:08X} -> {av:08X}); a revoke cannot be undone")
        elif av != bv:
            rv_arm.append((f"REVOKE_ID_{i}", f"{av:08X}"))
            if bv:
                rv_grow.append(f"REVOKE_ID_{i}")
    if bad:
        die("the after key set asks for something the card cannot do:\n  " + "\n  ".join(bad)
            + "\n  (eFUSE is one-time: keep the before tree's RSA pair and IVs, and only add revoke bits)")

    # 3. the AES key must be the same: a different one would mean a USER_KEY burn, and
    #    the card's AES row is never moved off the red key (decided 2026-10-07).
    if burned['AES_KEY'] != after_key:
        die(f"FAIL: the AES key differs between before (secret_key.txt id {fid(burned['AES_KEY'])}) "
            f"and after (id {fid(after_key)}). The red key is burned once and never changes; "
            f"a re-provision only adds revoke bits. Restore the before tree's secret_key.txt.")
    aes_change = False
    user_n, burn_slot = a.user_slot, None
    if aes_change:
        held = {n: before.value(f"USER_KEY{n}") for n in (0, 1)}
        have = [n for n, v in held.items() if v == after_key]
        if have:
            user_n = have[0]                       # already there: structure only
        else:
            if held[user_n]:
                other = 1 - user_n
                die(f"USER_KEY{user_n} already holds a different key on this card (per the before "
                    f"tree's efuse_keys.txt); a user key cannot be rewritten"
                    + (f" - use --user-slot {other}" if not held[other] else ""))
            burn_slot = f"USER_KEY{user_n}"
    arm = ([burn_slot] if burn_slot else []) + [r for r, _ in rv_arm]
    if not arm:
        die("the after key set is the same as the before one - nothing to burn")
    prov_rid, prod_rid = next_id(b_rows), next_id(a_rows)
    ks = KEYSRC_USER[user_n] if aes_change else KEYSRC_EFUSE_RED
    print(f"AES_CHANGE={1 if aes_change else 0}")
    print(f"AES_SLOT={burn_slot or ''}")
    print(f"USER_N={user_n}")
    print(f"ARM='{' '.join(arm)}'")
    print(f"REVOKE='{' '.join(f'{r}={v}' for r, v in rv_arm)}'")
    print(f"PROV_RID={prov_rid}")
    print(f"PROD_RID={prod_rid}")
    print(f"KEYSRC_AFTER={'' if ks is None else f'0x{ks:08X}'}")
    print(f"BEFORE_KEY_ID={fid(burned['AES_KEY'])}")
    print(f"AFTER_KEY_ID={fid(after_key)}")
    print(f"REVOKE_GROW='{' '.join(rv_grow)}'")
    print(f"REVOKE_HOLES='{' '.join(str(i) for i in revoke_holes(a_rows))}'")


def cmd_mkinit(a):
    _tpl = KeyFile(a.template)
    _res = reserved_bits(revoke_rows(_tpl))
    if _res:
        die(f"{a.template}: REVOKE_ID_7 carries reserved ID(s) {_res} (240..255 are reserved)")
    """First provisioning: the burn request is built from the key set itself, never
    from efuse_keys.txt's ARMED line. It writes this set's red key, PPK0 hash, the
    pinned IVs and PPK0_WR_LK, plus any REVOKE_ID rows the file carries a value for.
    efuse_keys.txt serves as the format template and the source of revoke rows."""
    kf = KeyFile(a.template)
    rows = revoke_rows(kf)
    for name, (_i, value, _c) in list(kf.fields.items()):
        if value not in NO_VALUE:
            kf.set_field(name, '-', '')
    burn = [('AES_KEY', read_hex(a.key, 64), f"armed; {a.key}"),
            ('PPK0_HASH', a.ppk.upper(), "armed; derived from RSA/psk1_rsa.pem"),
            ('METAHEADER_IV', a.iv_meta.upper(), "armed; _efuse_iv.sh"),
            ('PLM_IV', a.iv_plm.upper(), "armed; _efuse_iv.sh"),
            ('PPK0_WR_LK', '1', "armed; seals the PPK0 hash")]
    burn += [(r, f"{v:08X}", "armed; revoke bits") for r, v in zip(REVOKE_ROWS, rows) if v]
    for name, value, comment in burn:
        kf.set_field(name, value, comment)
    arm = [n for n, _v, _c in burn]
    kf.set_header('ARMED', ' '.join(arm))
    kf.insert_comment(["key_manager.sh first-burn request, built from the key files: only the ARMED fields are burned."])
    kf.write(a.out)
    print(f"ARM='{' '.join(arm)}'")
    print(f"REVOKE='{' '.join(f'{r}={v:08X}' for r, v in zip(REVOKE_ROWS, rows) if v)}'")
    print(f"PROD_RID={next_id(rows)}")
    print(f"AFTER_KEY_ID={fid(read_hex(a.key, 64))}")


# ------------------------------------------------------------- mkrun1 / mkrun2
def cmd_mkrun1(a):
    """The burn request for Run 1: the before tree's efuse_keys.txt as a format
    template, the provisioning values restored from the before key files (verify
    compares the image against them), every other field cleared, and the fields
    this burn writes."""
    kf = KeyFile(a.template)
    after_key = read_hex(a.after_key, 64)
    for name, (_i, value, _c) in list(kf.fields.items()):
        if value not in NO_VALUE:
            kf.set_field(name, '-', '')
    for name, value in provisioned(a).items():
        kf.set_field(name, value, "burned at provisioning, NOT armed this run")
    arm = []
    if a.aes_slot:
        kf.set_field(a.aes_slot, after_key, f"armed; {a.after_key}")
        arm.append(a.aes_slot)
    for item in (a.revoke or '').split():
        row, value = item.split('=')
        kf.set_field(row, value, "armed; revoke bits from the after key set")
        arm.append(row)
    kf.set_header('ARMED', ' '.join(arm))
    kf.insert_comment([
        "key_manager.sh Run 1 burn request: only the ARMED fields are burned.",
        f"  before key id {fid(read_hex(a.before_key, 64))}, after key id {fid(after_key)}",
    ])
    kf.write(a.out)


def cmd_mkrun2(a):
    kf = KeyFile(a.src)
    kf.set_header('ARMED', '<none>')
    kf.insert_comment(["key_manager.sh Run 2 work tree. NOT a burn request: no inject runs from it.",
                       "Value fields are reference only."])
    kf.write(a.out)


# ------------------------------------------------------------------ editbif
def cmd_editbif(a):
    lines = open(a.src).read().split('\n')
    keysrc_new = f"efuse_user_key{a.n}"
    out, i, drops, swaps = [], 0, 0, 0
    enc_re = re.compile(r'^\s*(encryption|blocks|keysrc|aeskeyfile)\s*=')
    while i < len(lines):
        line = lines[i]
        code = line.split('//', 1)[0]
        if re.match(r'^\s*(metaheader|partition)\s*$', code):
            kind = code.strip()
            j = i + 1
            while '{' not in lines[j].split('//', 1)[0]:
                j += 1
            depth, k = 0, j
            while True:
                c = lines[k].split('//', 1)[0]
                depth += c.count('{') - c.count('}')
                if depth == 0:
                    break
                k += 1
            body = lines[i:k + 1]
            plain = kind == 'metaheader' or any(
                re.search(r'type\s*=\s*(bootloader|pmcdata)\b', b.split('//', 1)[0]) for b in body)
            for b in body:
                if plain and enc_re.match(b):
                    drops += 1
                    continue
                if not plain and re.match(r'^\s*keysrc\s*=\s*efuse_red_key\s*$', b):
                    b = b.replace('efuse_red_key', keysrc_new)
                    swaps += 1
                out.append(b)
            i = k + 1
        else:
            out.append(line)
            i += 1
    text = '\n'.join(out)
    code_only = '\n'.join(l.split('//', 1)[0] for l in out)
    if 'efuse_red_key' in code_only:
        die("editbif: efuse_red_key still present after the edit")
    n_aes = len(re.findall(r'^\s*aeskeyfile\s*=', code_only, re.M))
    n_user = len(re.findall(r'^\s*keysrc\s*=\s*' + keysrc_new + r'\s*$', code_only, re.M))
    if n_aes != n_user or n_user == 0:
        die(f"editbif: {n_aes} aeskeyfile lines but {n_user} keysrc = {keysrc_new}")
    if drops != 12:
        die(f"editbif: removed {drops} encryption lines, expected 12 "
            f"(4 each from metaheader, bootloader, pmcdata)")
    open(a.out, 'w').write(text)
    print(f"editbif : {drops} lines removed, {swaps} keysrc -> {keysrc_new}")


# ------------------------------------------------------------------ setrid
def cmd_setrid(a):
    """Put revoke_id = N on the metaheader and on every authenticated partition, so
    every certificate in the image carries an ID the card has not revoked."""
    lines = open(a.src).read().split('\n')
    out, i, n_meta, n_part = [], 0, 0, 0
    rid = f"0x{a.id:x}"
    while i < len(lines):
        code = lines[i].split('//', 1)[0]
        if re.match(r'^\s*(metaheader|partition)\s*$', code):
            kind = code.strip()
            j = i + 1
            while '{' not in lines[j].split('//', 1)[0]:
                j += 1
            depth, k = 0, j
            while True:
                c = lines[k].split('//', 1)[0]
                depth += c.count('{') - c.count('}')
                if depth == 0:
                    break
                k += 1
            body = [b for b in lines[i:k + 1] if not re.match(r'^\s*revoke_id\s*=', b)]
            auth = [n for n, b in enumerate(body) if re.match(r'^\s*authentication\s*=\s*rsa\s*$', b)]
            if auth:
                ind = re.match(r'^(\s*)', body[auth[0]]).group(1)
                body.insert(auth[0] + 1, f"{ind}revoke_id = {rid}")
                n_meta += kind == 'metaheader'
                n_part += kind == 'partition'
            out += body
            i = k + 1
        else:
            out.append(lines[i])
            i += 1
    if n_meta != 1 or n_part == 0:
        die(f"setrid: {a.src}: revoke_id set on {n_meta} metaheader(s) and {n_part} partition(s)")
    open(a.out, 'w').write('\n'.join(out))
    print(f"setrid  : {os.path.basename(a.out)} revoke_id = {a.id} on the metaheader and {n_part} partitions")


# ---------------------------------------------------------------- blobcheck
def cmd_blobcheck(a):
    fw = load_fwtool(a.fwtool)
    values, _adv = fw.parse_efuse_key_file(a.request)
    arm = a.arm.split()
    expect = fw.build_efuse_blob(values, arm)
    with open(a.elf, 'rb') as f:
        off, size = fw.find_section(f, fw.EFUSE_KEYS_SECTION)
        f.seek(off)
        got = f.read(len(expect))
    fails = []
    if size < len(expect):
        fails.append(f"section {size} B < blob {len(expect)} B")
    magic, ver, hlen, blen, present, armm, crc = struct.unpack(fw.FMT_EFUSE_KEYS_HDR, got[:24])
    mask = sum(1 << fw.EFUSE_BIT[n] for n in arm)
    if (magic, ver, hlen, blen) != (fw.EFUSE_KEYS_MAGIC, fw.EFUSE_KEYS_VER, 24, len(expect)):
        fails.append("header magic/version/lengths")
    if present != mask or armm != mask:
        fails.append("present/arm mask != arm list")
    if fw.efuse_blob_crc(got) != crc:
        fails.append("crc32")
    # independent of the key file: the slot holds exactly the after key
    if a.aes_slot:
        at = fw.EFUSE_SLOT_AT[a.aes_slot] * 4 + 24
        want = struct.pack('<8I', *fw._efuse_hex_to_words(read_hex(a.after_key, 64), 8, fw.CONV_LE))
        if got[at:at + 32] != want:
            fails.append(f"{a.aes_slot} slot != after secret_key.txt")
    if a.ppk_slot:
        at = fw.EFUSE_SLOT_AT[a.ppk_slot] * 4 + 24
        want = struct.pack('<8I', *fw._efuse_hex_to_words(a.ppk_after.upper(), 8, fw.CONV_BE))
        if got[at:at + 32] != want:
            fails.append(f"{a.ppk_slot} slot != after PPK hash")
    if got != expect:
        fails.append("blob bytes != blob rebuilt from the request file")
    if fails:
        die("blobcheck FAIL: " + '; '.join(fails))
    print(f"blobcheck: PASS ({' '.join(arm)}; other slots zero)")


# ---------------------------------------------------------------- imgcheck
def u32(b, off):
    return struct.unpack_from('<I', b, off)[0]


def ac_ppk_hash(b, ac):
    return hashlib.sha3_384(b[ac + AC_PPK:ac + AC_PPK + AC_PPK_LEN]).hexdigest().upper()[:64]


def cmd_imgcheck(a):
    b = open(a.bin, 'rb').read()
    fails, info = [], []
    mh = u32(b, BH_METAHDR_OFF)
    bh_ks, iht_ks = u32(b, BH_KEYSRC), u32(b, mh + IHT_KEYSRC)
    n_img, n_part = u32(b, mh + IHT_TOTAL_IMAGES), u32(b, mh + IHT_TOTAL_PARTS)
    info.append(f"images/partitions {n_img}/{n_part}")
    meta_ac = u32(b, mh + IHT_HDR_AC) * 4
    if a.kind == 'unsigned':
        if bh_ks != KEYSRC_NONE or iht_ks != KEYSRC_NONE:
            fails.append(f"keysrc BH 0x{bh_ks:08X} IHT 0x{iht_ks:08X}, expected 0 (plaintext)")
        if meta_ac:
            fails.append("the image carries an authentication certificate - it should be unsigned")
        if a.images is not None and n_img != a.images:
            fails.append(f"total_images {n_img} != bif image blocks {a.images}")
        if fails:
            die("imgcheck unsigned FAIL: " + '; '.join(fails))
        print(f"imgcheck unsigned: PASS (images/partitions {n_img}/{n_part}, no signature, plaintext)")
        return
    for label, ac in (('meta AC', meta_ac), ('PLM AC', PLM_AC_OFF)):
        h = ac_ppk_hash(b, ac)
        if h != a.expect_ppk.upper():
            fails.append(f"{label} PPK hash != expected (got id {fid(h)})")
        if u32(b, ac + 4) != a.revoke_id:
            fails.append(f"{label} revoke_id {u32(b, ac + 4)}, expected {a.revoke_id}")
    info.append(f"revoke_id {a.revoke_id}")
    if a.kind in ('before', 'prov'):
        if bh_ks != KEYSRC_EFUSE_RED or iht_ks != KEYSRC_EFUSE_RED:
            fails.append(f"keysrc BH 0x{bh_ks:08X} IHT 0x{iht_ks:08X}, expected efuse_red_key")
        if a.images is not None and n_img != a.images:
            fails.append(f"total_images {n_img} != bif image blocks {a.images}")
    else:
        want = int(a.keysrc, 16)
        if bh_ks != KEYSRC_NONE or iht_ks != KEYSRC_NONE:
            fails.append(f"keysrc BH 0x{bh_ks:08X} IHT 0x{iht_ks:08X}, expected 0 (plaintext)")
        pht = u32(b, mh + IHT_PHT_OFF) * 4
        if pht == 0:
            fails.append("pht_offset is 0 - partition headers unreadable")
        seen, first = 0, True
        while pht and seen <= n_part:
            ks = u32(b, pht + PHT_KEYSRC)
            if first:
                if ks != KEYSRC_NONE:
                    fails.append(f"PLM partition keysrc 0x{ks:08X}, expected 0")
                if u32(b, pht + PHT_AC_OFF) * 4 != PLM_AC_OFF:
                    fails.append(f"PLM AC at 0x{u32(b, pht + PHT_AC_OFF) * 4:X}, not 0x{PLM_AC_OFF:X}")
                first = False
            elif ks != want:
                fails.append(f"partition {seen} keysrc 0x{ks:08X}, expected 0x{want:08X}")
            ac = u32(b, pht + PHT_AC_OFF) * 4
            if ac and u32(b, ac + 4) != a.revoke_id:
                fails.append(f"partition {seen} certificate revoke_id {u32(b, ac + 4)}, expected {a.revoke_id}")
            seen += 1
            pht = u32(b, pht + PHT_NEXT) * 4
        if seen != n_part:
            fails.append(f"walked {seen} partition headers, IHT says {n_part}")
        info.append(f"{n_part - 1} partitions at 0x{want:08X}, PLM plaintext")
    if fails:
        die(f"imgcheck {a.kind} FAIL: " + '; '.join(fails))
    print(f"imgcheck {a.kind}: PASS ({', '.join(info)})")


# ---------------------------------------------------------------- jtagcheck
JTAG_REVOKE_ID = 0x04   # revoke ID the message is signed over (u32 LE); offset confirmed
                        # by diffing builds of one BIF with revoke_id 0x00 / 0x05 / 0x1f
JTAG_PPK = 0x68   # PPK block in the 2048-byte AUTH_JTAG message; the signature
                  # (0x478..0x677) is RSA-PSS and differs on every build


def cmd_jtagcheck(a):
    b = open(a.bin, 'rb').read()
    if len(b) != 2048:
        die(f"jtagcheck: {a.bin} is {len(b)} bytes, expected 2048")
    fails = []
    h = hashlib.sha3_384(b[JTAG_PPK:JTAG_PPK + AC_PPK_LEN]).hexdigest().upper()[:64]
    if h != a.expect_ppk.upper():
        fails.append(f"signed by PPK {fid(h)}, not the expected one")
    rid = u32(b, JTAG_REVOKE_ID)
    if rid != a.revoke_id:
        fails.append(f"revoke_id {rid}, expected {a.revoke_id} (a revoked ID makes the message useless "
                     f"on that card)")
    if fails:
        die(f"jtagcheck: {os.path.basename(a.bin)}: " + '; '.join(fails))
    print(f"jtagcheck: PASS ({os.path.basename(a.bin)} PPK {h[:12]}, revoke_id {rid})")


# -------------------------------------------------------------------- scan
def private_exponent(pem):
    out = subprocess.run(['openssl', 'rsa', '-in', pem, '-noout', '-text'],
                         capture_output=True, text=True).stdout
    m = re.search(r'privateExponent:\s*\n((?:\s+[0-9a-f:]+\n)+)', out)
    if not m:
        die(f"cannot read the private exponent of {pem}")
    d = bytes.fromhex(re.sub(r'[\s:]', '', m.group(1)))
    return d.lstrip(b'\x00')[:64]


def cmd_scan(a):
    pats = []
    for kf in a.key:
        k = bytes.fromhex(read_hex(kf, 64))
        for form, v in (('raw', k), ('rev', k[::-1]),
                        ('wordrev', b''.join(k[i:i + 4][::-1] for i in range(0, 32, 4)))):
            pats.append((f"{fid(k)}:{form}", v))
        hx = k.hex()
        pats += [(f"{fid(k)}:hex", hx.encode()), (f"{fid(k)}:HEX", hx.upper().encode())]
    for pem in a.pem:
        d = private_exponent(pem)
        pats += [(f"{os.path.basename(pem)}:d", d), (f"{os.path.basename(pem)}:d-rev", d[::-1])]
    pats.append(('PEM', b'-----BEGIN'))
    files = []
    for root in a.path:
        if os.path.isfile(root) and not os.path.islink(root):
            files.append(root)
        for dp, dn, fn in os.walk(root, followlinks=False):
            for f in fn:
                p = os.path.join(dp, f)
                if not os.path.islink(p):
                    files.append(p)
    allow = [os.path.abspath(x) for x in (a.allow or [])]
    bad, hits = [], []
    for p in files:
        try:
            data = open(p, 'rb').read()
        except OSError:
            continue
        found = [n for n, v in pats if v in data]
        if found:
            ap = os.path.abspath(p)
            hits.append(ap)
            if not any(ap == x or ap.startswith(x.rstrip('/') + '/') for x in allow):
                bad.append(f"{ap} [{', '.join(found)}]")
    if a.list:
        with open(a.list, 'w') as f:
            f.write('\n'.join(hits) + ('\n' if hits else ''))
    if bad:
        die("scan: key material outside the allow list:\n  " + '\n  '.join(bad))
    print(f"scan    : {len(files)} files, {len(hits)} allowed hit(s), 0 outside the allow list")


# -------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest='cmd', required=True)

    p = sp.add_parser('plan')
    for k in ('before-key', 'after-key', 'ppk-before', 'ppk-after', 'iv-meta', 'iv-plm', 'before-efuse', 'after-efuse'):
        p.add_argument('--' + k, required=True)
    p.add_argument('--user-slot', type=int, choices=(0, 1), default=0)
    p.set_defaults(fn=cmd_plan)

    p = sp.add_parser('mkinit')
    for k in ('template', 'out', 'key', 'ppk', 'iv-meta', 'iv-plm'):
        p.add_argument('--' + k, required=True)
    p.set_defaults(fn=cmd_mkinit)

    p = sp.add_parser('mkrun1')
    for k in ('template', 'out', 'before-key', 'after-key', 'ppk-before', 'iv-meta', 'iv-plm'):
        p.add_argument('--' + k, required=True)
    p.add_argument('--aes-slot', default='')
    p.add_argument('--revoke', default='')
    p.set_defaults(fn=cmd_mkrun1)

    p = sp.add_parser('mkrun2')
    p.add_argument('--src', required=True)
    p.add_argument('--out', required=True)
    p.set_defaults(fn=cmd_mkrun2)

    p = sp.add_parser('editbif')
    p.add_argument('--src', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--n', type=int, choices=(0, 1), required=True)
    p.set_defaults(fn=cmd_editbif)

    p = sp.add_parser('blobcheck')
    for k in ('fwtool', 'elf', 'request', 'arm', 'after-key'):
        p.add_argument('--' + k, required=True)
    p.add_argument('--aes-slot', default='')
    for k in ('ppk-slot', 'ppk-after'):
        p.add_argument('--' + k, default='')
    p.set_defaults(fn=cmd_blobcheck)

    p = sp.add_parser('imgcheck')
    p.add_argument('kind', choices=('before', 'prov', 'after', 'unsigned'))
    p.add_argument('bin')
    p.add_argument('--expect-ppk', default='')
    p.add_argument('--keysrc', default='')
    p.add_argument('--images', type=int)
    p.add_argument('--revoke-id', type=int, default=0)
    p.set_defaults(fn=cmd_imgcheck)

    p = sp.add_parser('setrid')
    p.add_argument('--src', required=True)
    p.add_argument('--out', required=True)
    p.add_argument('--id', type=int, required=True)
    p.set_defaults(fn=cmd_setrid)

    p = sp.add_parser('jtagcheck')
    p.add_argument('bin')
    p.add_argument('--expect-ppk', required=True)
    p.add_argument('--revoke-id', type=int, required=True)
    p.set_defaults(fn=cmd_jtagcheck)

    p = sp.add_parser('revoke')
    p.add_argument('--file', required=True)
    p.add_argument('--upto', type=int, required=True)
    p.set_defaults(fn=cmd_revoke)

    p = sp.add_parser('scan')
    p.add_argument('path', nargs='+')
    p.add_argument('--key', action='append', default=[])
    p.add_argument('--pem', action='append', default=[])
    p.add_argument('--allow', action='append')
    p.add_argument('--list')
    p.set_defaults(fn=cmd_scan)

    a = ap.parse_args()
    a.fn(a)


if __name__ == '__main__':
    main()
