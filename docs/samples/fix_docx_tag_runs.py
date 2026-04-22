#!/usr/bin/env python3
"""
Fix Word run-splitting inside {{...}} and [[...]] tags.

Microsoft Word often stores a single DocuSeal/SealRoute tag
({{FieldName;type=text;role=X}}) as multiple <w:r>/<w:t> XML runs
because of edits, spell-check, or mid-tag formatting changes, e.g.

    <w:t>{{Kewajiban</w:t>
    <w:t>1;type</w:t>
    <w:t>=</w:t>
    <w:t>text;role</w:t>
    <w:t>=Petugas;required=false}}</w:t>

DocuSeal's tag parser looks for a complete {{...}} inside a single
text run. Any tag that Word split is rendered as literal text in the
signed PDF.

This script opens a .docx, walks each <w:p>, joins all <w:t> nodes,
and for every paragraph that contains a tag that spans runs, it:
  - writes the full merged paragraph text back into the FIRST <w:t>
    (keeping that run's formatting, i.e. font/size/color/bold/italic),
  - clears all remaining <w:t> nodes in the paragraph,
  - preserves xml:space="preserve" so spaces are not collapsed.

Usage:
    python3 fix_docx_tag_runs.py <input.docx> [output.docx]

If output.docx is omitted, the fixed file is written to
<input>.fixed.docx next to the source.
"""

from __future__ import annotations

import sys
import re
import shutil
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET


W_NS = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
XML_NS = "http://www.w3.org/XML/1998/namespace"
W = f"{{{W_NS}}}"
XML_SPACE = f"{{{XML_NS}}}space"

# Register so ET keeps the "w:" prefix when serializing. Must be called before
# any parse() so the prefix map is applied to the output.
ET.register_namespace("w", W_NS)
ET.register_namespace("xml", XML_NS)

TAG_REGEX = re.compile(r"\{\{[^}]+\}\}|\[\[[^\]]+\]\]")

# XML parts inside a .docx that can contain body text with tags.
TARGET_PART_PATTERNS = (
    re.compile(r"^word/document\d*\.xml$"),
    re.compile(r"^word/header\d+\.xml$"),
    re.compile(r"^word/footer\d+\.xml$"),
)


def target_part(name: str) -> bool:
    return any(p.match(name) for p in TARGET_PART_PATTERNS)


def normalize_paragraph(paragraph: ET.Element) -> tuple[bool, int]:
    """
    If paragraph contains a tag split across runs, collapse those runs.

    Returns (modified, tags_fixed).
    """
    t_nodes = paragraph.findall(f".//{W}t")
    if not t_nodes:
        return False, 0

    texts = [n.text or "" for n in t_nodes]
    full_text = "".join(texts)
    if "{{" not in full_text and "[[" not in full_text:
        return False, 0

    # Compute, for each char position, which <w:t> it belongs to.
    # We then flag a tag as "split" when its span crosses more than one node.
    boundaries = []  # (start, end, node_idx)
    offset = 0
    for idx, text in enumerate(texts):
        boundaries.append((offset, offset + len(text), idx))
        offset += len(text)

    def node_of(pos: int) -> int:
        for start, end, idx in boundaries:
            if start <= pos < end:
                return idx
        return boundaries[-1][2]

    split_tags = 0
    has_split = False
    for m in TAG_REGEX.finditer(full_text):
        start_node = node_of(m.start())
        # end-1 because end is exclusive and may land on the next node's start
        end_node = node_of(max(m.start(), m.end() - 1))
        if end_node != start_node:
            has_split = True
            split_tags += 1

    if not has_split:
        return False, 0

    # Collapse: put the whole paragraph text into the first <w:t>, keeping its
    # parent <w:r>'s formatting. Clear all subsequent <w:t> nodes.
    first = t_nodes[0]
    first.text = full_text
    # Always preserve spaces so leading/trailing whitespace around tags survives.
    first.set(XML_SPACE, "preserve")

    for node in t_nodes[1:]:
        node.text = ""
        # Setting xml:space preserve on empty nodes is harmless but keeps the
        # serializer from emitting a self-closing <w:t/> that Word sometimes
        # re-splits on the next save.
        node.set(XML_SPACE, "preserve")

    return True, split_tags


def normalize_xml_bytes(data: bytes) -> tuple[bytes, int, int]:
    """
    Normalize every <w:p> in an OOXML part.

    Returns (new_bytes, paragraphs_fixed, tags_fixed).
    """
    root = ET.fromstring(data)
    paragraphs_fixed = 0
    tags_fixed = 0
    for paragraph in root.iter(f"{W}p"):
        changed, fixed = normalize_paragraph(paragraph)
        if changed:
            paragraphs_fixed += 1
            tags_fixed += fixed
    if paragraphs_fixed == 0:
        return data, 0, 0
    # ET.tostring without xml_declaration drops the <?xml ?> header Word wants,
    # so we add it back manually to stay byte-for-byte compatible with Word.
    body = ET.tostring(root, encoding="utf-8", xml_declaration=False)
    header = b'<?xml version="1.0" encoding="UTF-8" standalone="yes"?>\n'
    return header + body, paragraphs_fixed, tags_fixed


def fix_docx(src: Path, dst: Path) -> None:
    if src.resolve() == dst.resolve():
        raise SystemExit("Refusing to overwrite the source DOCX in place. "
                         "Pass a different output path.")

    total_parts = 0
    fixed_parts = 0
    total_paragraphs = 0
    total_tags = 0

    with zipfile.ZipFile(src, "r") as zin, \
            zipfile.ZipFile(dst, "w", compression=zipfile.ZIP_DEFLATED) as zout:
        for item in zin.infolist():
            data = zin.read(item.filename)
            if target_part(item.filename):
                total_parts += 1
                new_data, pfix, tfix = normalize_xml_bytes(data)
                if pfix:
                    fixed_parts += 1
                    total_paragraphs += pfix
                    total_tags += tfix
                    print(f"  {item.filename}: fixed {pfix} paragraph(s), {tfix} tag(s)")
                data = new_data
            zout.writestr(item, data)

    print()
    print(f"Scanned {total_parts} body XML part(s); "
          f"normalized {fixed_parts} part(s), "
          f"{total_paragraphs} paragraph(s), "
          f"{total_tags} split tag(s).")
    print(f"Wrote: {dst}")


def main(argv: list[str]) -> int:
    if len(argv) < 2 or argv[1] in {"-h", "--help"}:
        print(__doc__)
        return 0 if len(argv) >= 2 else 1

    src = Path(argv[1])
    if not src.is_file():
        print(f"ERROR: not a file: {src}", file=sys.stderr)
        return 1

    if len(argv) >= 3:
        dst = Path(argv[2])
    else:
        dst = src.with_suffix("")
        dst = dst.with_name(dst.name + ".fixed.docx")

    # Quick sanity: reject non-zip (DOCX must be a ZIP container).
    with open(src, "rb") as f:
        if f.read(4) != b"PK\x03\x04":
            print(f"ERROR: {src} is not a valid DOCX (missing PK header)", file=sys.stderr)
            return 1

    print(f"Fixing: {src}")
    print(f"Output: {dst}")
    print()
    fix_docx(src, dst)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
