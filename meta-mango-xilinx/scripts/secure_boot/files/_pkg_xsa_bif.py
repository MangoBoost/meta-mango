#!/usr/bin/env python3
"""Read the BIF Vivado shipped inside the board XSA and re-express it for us.

Step helper for ../_make_zip.sh; see ../README.md. The PL/PMC/PSM partition set
differs per board, so it is derived from the XSA's own .bif - hardcoding it fails
silently, bootgen drops a partition it cannot place and still exits 0. Paths
inside the XSA's BIF resolve against pdi_files/ (verified on two boards).
"""

import argparse
import json
import os
import re
import sys

# --------------------------------------------------------------- substitutions

# The partition files we do NOT take from the XSA: the image must boot the
# PLM/PSM PetaLinux built (the eFUSE-capable PLM for the provision profile),
# not Vivado's. Keyed by the path as it appears in the XSA's BIF.
SUBSTITUTE = {
    "gen_files/plm.elf": {
        "golden": ("mblp/files/plm.elf", "mango_plm"),
        "provision": ("mblp_prov/files/plm-prov.elf", "mango_plm"),
    },
    "static_files/psm_fw.elf": {
        "golden": ("common/files/psmfw.elf", "mango_psmfw"),
        "provision": ("common/files/psmfw.elf", "mango_psmfw"),
    },
}

# Everything else lands here, under its own basename.
PDI_DEST = "common/pdi_files"


def key_name(basename):
    """AES key file stem for a partition file.

    'mango_' + the basename with dots turned into underscores. The extension is
    kept on purpose: dropping it collides on nrt, where the PL stage is one
    block holding <design>.rcdo and <design>.rnpi - both would become
    'mango_<design>'. Uniqueness is asserted by the caller either way.
    """
    return "mango_" + basename.replace(".", "_").replace("-", "_")


# --------------------------------------------------------------------- parsing
_TOKEN = re.compile(r"[{}=,]|[^\s{}=,]+")


def tokenize(text):
    out = []
    for raw in text.splitlines():
        line = raw.split("//", 1)[0]
        out.extend(_TOKEN.findall(line))
    return out


class BifSyntaxError(Exception):
    pass


class _Parser:
    def __init__(self, tokens):
        self.t = tokens
        self.i = 0

    def peek(self, n=0):
        j = self.i + n
        return self.t[j] if j < len(self.t) else None

    def take(self):
        tok = self.peek()
        if tok is None:
            raise BifSyntaxError("unexpected end of file")
        self.i += 1
        return tok

    def expect(self, want):
        tok = self.take()
        if tok != want:
            raise BifSyntaxError(f"expected {want!r}, found {tok!r}")
        return tok

    def body(self):
        """Attributes and nested blocks up to the closing brace."""
        attrs, blocks = {}, []
        while True:
            tok = self.peek()
            if tok is None:
                raise BifSyntaxError("unterminated block")
            if tok == "}":
                self.take()
                return attrs, blocks
            if tok == ",":
                self.take()
                continue
            if tok in ("image", "partition") and self.peek(1) == "{":
                kind = self.take()
                self.expect("{")
                sub_attrs, sub_blocks = self.body()
                blocks.append((kind, sub_attrs, sub_blocks))
                continue
            name = self.take()
            if self.peek() == "=":
                self.take()
                attrs[name] = self.take()
            else:
                # A bare flag. None of the XSA BIFs seen use one; keep it rather
                # than drop it, so nothing vanishes silently.
                attrs[name] = True


def parse_bif(text):
    tokens = tokenize(text)
    p = _Parser(tokens)
    p.take()  # 'new_bif:' or whatever the header is called
    p.expect("{")
    attrs, blocks = p.body()

    images = []
    for kind, iattrs, iblocks in blocks:
        if kind != "image":
            raise BifSyntaxError(f"unexpected {kind!r} block at top level")
        partitions = []
        for pkind, pattrs, pblocks in iblocks:
            if pkind != "partition" or pblocks:
                raise BifSyntaxError(f"unexpected {pkind!r} inside image")
            if "file" not in pattrs:
                raise BifSyntaxError(
                    f"partition with no file= in image {iattrs.get('name')!r}")
            partitions.append(pattrs)
        images.append({
            "name": iattrs.get("name"),
            "id": iattrs.get("id"),
            "partitions": partitions,
        })
    return attrs, images


# ------------------------------------------------------------------- discovery
def find_xsa_bif(xsa_dir):
    """The single .bif at the XSA root.

    Matched by position, not by name: bnic calls it '..._tandemPROM.bif' and nrt
    calls it '<design>.bif'. Both have exactly one.
    """
    hits = sorted(f for f in os.listdir(xsa_dir) if f.endswith(".bif"))
    if len(hits) != 1:
        sys.exit(f"ERROR: expected exactly one .bif in {xsa_dir}, "
                 f"found {len(hits)}: {', '.join(hits) or 'none'}")
    return hits[0]


def load(xsa_dir):
    name = find_xsa_bif(xsa_dir)
    with open(os.path.join(xsa_dir, name)) as fh:
        try:
            attrs, images = parse_bif(fh.read())
        except BifSyntaxError as exc:
            sys.exit(f"ERROR: cannot parse {name}: {exc}")
    if not images:
        sys.exit(f"ERROR: {name} declares no image blocks")
    return name, attrs, images


def device(xsa_dir):
    """fpgaDevice out of xsa.json - what bootgen -p wants."""
    path = os.path.join(xsa_dir, "xsa.json")
    try:
        with open(path) as fh:
            return json.load(fh).get("fpgaDevice") or ""
    except (OSError, ValueError):
        return ""


# -------------------------------------------------------------------- emitters
def dest_for(src, profile):
    """(package path, key stem) for a partition file, and whether it is ours."""
    if src in SUBSTITUTE:
        path, key = SUBSTITUTE[src][profile]
        return path, key, True
    base = os.path.basename(src)
    return f"{PDI_DEST}/{base}", key_name(base), False


def emit_copy_list(images):
    """'<path under pdi_files>\t<path in package>' for every file we take.

    The substituted two are left out - they come from images/linux instead. This
    is the whole rule for what gets staged: no cdo name list, no _markers
    exclusion, no tandem globbing. If the BIF does not name it, it is not a
    partition of this design.
    """
    seen, rows = set(), []
    for img in images:
        for part in img["partitions"]:
            src = part["file"]
            if src in SUBSTITUTE or src in seen:
                continue
            seen.add(src)
            dest, _, _ = dest_for(src, "golden")
            rows.append(f"{src}\t{dest}")
    return "\n".join(rows)


def emit_pl_images(images, profile, secure):
    """The image blocks, rendered in our BIF style.

    secure: 'full'  authentication + encryption + AES key. Both signed images.
            None    nothing. The self-test, which is built without keys.

    There is no authenticate-only mode. Both images that are signed are also
    encrypted, and the one that is not signed is the unsigned provisioning image
    for a blank board - it cannot be encrypted, because the key it would need is
    the one it exists to burn.
    """
    keys, out = {}, []
    for img in images:
        out.append("  image")
        out.append("  {")
        out.append(f"    name = {img['name']}")
        out.append(f"    id = {img['id']}")
        for part in img["partitions"]:
            src = part["file"]
            dest, keystem, _ = dest_for(src, profile)

            if keystem in keys and keys[keystem] != dest:
                sys.exit(f"ERROR: AES key name {keystem!r} claimed by both "
                         f"{keys[keystem]} and {dest}")
            keys[keystem] = dest

            out.append("    partition")
            out.append("    {")
            if "id" in part:
                out.append(f"      id = {part['id']}")
            # 'type = pmcdata, load = 0x...' is one directive in bootgen's eyes
            if part.get("type") and "load" in part:
                out.append(f"      type = {part['type']}, load = {part['load']}")
            elif part.get("type"):
                out.append(f"      type = {part['type']}")
            if part.get("core"):
                out.append(f"      core = {part['core']}")
            out.append(f"      file = {dest}")

            # pmcdata is merged into the bootloader partition and covered by its
            # certificate, so it takes no authentication of its own. It does get
            # its own AES key.
            pmcdata = part.get("type") == "pmcdata"
            if secure == "full" and not pmcdata:
                out.append("      authentication = rsa")
            if secure == "full":
                out.append("      encryption = aes")
                out.append("      blocks = 1728(*)")
                out.append("      keysrc = efuse_red_key")
                out.append(f"      aeskeyfile = keys/AES/{keystem}.nky")
            out.append("    }")
        out.append("  }")
        out.append("")
    return "\n".join(out).rstrip("\n")


def sh_quote(value):
    return "'" + str(value).replace("'", "'\\''") + "'"


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("xsa_dir", help="the unpacked XSA (files/xsa_files)")
    ap.add_argument("--emit", required=True,
                    choices=["json", "copy-list", "pl-images", "meta", "part-names"])
    ap.add_argument("--profile", default="golden", choices=["golden", "provision"])
    ap.add_argument("--secure", default="full", choices=["full", "none"])
    args = ap.parse_args()

    if not os.path.isdir(args.xsa_dir):
        sys.exit(f"ERROR: {args.xsa_dir} not found - "
                 "run wrap-package.sh --secured first (it unpacks the XSA).")

    name, attrs, images = load(args.xsa_dir)

    if args.emit == "json":
        print(json.dumps({
            "source_bif": name,
            "path_base": "pdi_files",
            "id_code": attrs.get("id_code"),
            "extended_id_code": attrs.get("extended_id_code"),
            "id": attrs.get("id"),
            "device": device(args.xsa_dir),
            "images": images,
        }, indent=2))
    elif args.emit == "copy-list":
        print(emit_copy_list(images))
    elif args.emit == "pl-images":
        print(emit_pl_images(images, args.profile,
                             None if args.secure == "none" else args.secure))
    elif args.emit == "meta":
        # eval'able in sh
        print(f"SB_BIF_SRC={sh_quote(name)}")
        print(f"SB_ID_CODE={sh_quote(attrs.get('id_code', ''))}")
        print(f"SB_EXT_ID_CODE={sh_quote(attrs.get('extended_id_code', ''))}")
        print(f"SB_BIF_ID={sh_quote(attrs.get('id', ''))}")
        print(f"SB_DEVICE={sh_quote(device(args.xsa_dir))}")
    elif args.emit == "part-names":
        print("\n".join(img["name"] for img in images))


if __name__ == "__main__":
    main()
