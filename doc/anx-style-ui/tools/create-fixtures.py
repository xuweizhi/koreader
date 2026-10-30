#!/usr/bin/env python3
"""Create deterministic, self-authored G0 fixtures without touching a personal library."""

import argparse
import hashlib
import json
from pathlib import Path
import zipfile


def create_epub(path):
    manifest = "".join(
        f'<item id="c{i}" href="chapter{i}.xhtml" media-type="application/xhtml+xml"/>'
        for i in range(1, 4)
    )
    spine = "".join(f'<itemref idref="c{i}"/>' for i in range(1, 4))
    entries = {
        "mimetype": "application/epub+zip",
        "META-INF/container.xml": '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile '
        'full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        "OEBPS/content.opf": f'<?xml version="1.0" encoding="UTF-8"?><package '
        'xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="id"><metadata '
        'xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="id">anxui-fixture-cn-v1</dc:identifier>'
        '<dc:title>山间阅读：界面与批注测试</dc:title><dc:creator>Anx UI Test</dc:creator>'
        f'<dc:language>zh-CN</dc:language></metadata><manifest>{manifest}<item id="ncx" '
        'href="toc.ncx" media-type="application/x-dtbncx+xml"/></manifest>'
        f'<spine toc="ncx">{spine}</spine></package>',
    }
    nav = "".join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>第{i}章 阅读练习</text>'
                  f'</navLabel><content src="chapter{i}.xhtml"/></navPoint>' for i in range(1, 4))
    entries["OEBPS/toc.ncx"] = '<?xml version="1.0" encoding="UTF-8"?><ncx '
    entries["OEBPS/toc.ncx"] += 'xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">'
    entries["OEBPS/toc.ncx"] += '<head><meta name="dtb:uid" content="anxui-fixture-cn-v1"/></head>'
    entries["OEBPS/toc.ncx"] += f'<docTitle><text>山间阅读</text></docTitle><navMap>{nav}</navMap></ncx>'
    for i in range(1, 4):
        paragraphs = "".join(
            f'<p id="p{j}">第{i}章，第{j}段。清晨，山间的小路铺满了柔和的光。'
            '读者翻开一本书，记录值得记住的句子。本段用于验证中文排版、文本选择、批注和阅读位置恢复。'
            f'每一段都有独立编号，重新打开时可以核对位置是否一致。 Reading sample {i}.{j}.</p>'
            for j in range(1, 31)
        )
        entries[f"OEBPS/chapter{i}.xhtml"] = '<?xml version="1.0" encoding="UTF-8"?><html '
        entries[f"OEBPS/chapter{i}.xhtml"] += f'xmlns="http://www.w3.org/1999/xhtml"><head><title>第{i}章</title>'
        entries[f"OEBPS/chapter{i}.xhtml"] += f'</head><body><h1>第{i}章 阅读练习</h1>{paragraphs}'
        entries[f"OEBPS/chapter{i}.xhtml"] += '<p><a href="#note">脚注示例</a></p><p id="note">'
        entries[f"OEBPS/chapter{i}.xhtml"] += '这是一条测试注释。<a href="#p1">返回第一段</a></p></body></html>'
    with zipfile.ZipFile(path, "w") as archive:
        for name, content in entries.items():
            info = zipfile.ZipInfo(name, date_time=(2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == "mimetype" else zipfile.ZIP_DEFLATED
            archive.writestr(info, content.encode("utf-8"))


def create_pdf(path):
    objects = [b"<< /Type /Catalog /Pages 2 0 R >>",
               b"<< /Type /Pages /Kids [4 0 R 6 0 R 8 0 R] /Count 3 >>",
               b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"]
    for page in range(1, 4):
        text = f"BT /F1 18 Tf 72 740 Td (Anx UI reading fixture - page {page}) Tj /F1 12 Tf "
        text += "".join(f"0 -28 Td (Page {page}, paragraph {j}: bookmark, select and restore this reading position.) Tj "
                        for j in range(1, 17))
        content = (text + "ET").encode("ascii")
        objects += [f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font "
                    f"<< /F1 3 0 R >> >> /Contents {len(objects) + 2} 0 R >>".encode("ascii"),
                    b"<< /Length " + str(len(content)).encode("ascii") + b" >>\nstream\n" + content + b"\nendstream"]
    pdf = bytearray(b"%PDF-1.4\n")
    offsets = []
    for index, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f"{index} 0 obj\n".encode("ascii") + obj + b"\nendobj\n")
    xref = len(pdf)
    pdf.extend(f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n".encode("ascii"))
    for offset in offsets:
        pdf.extend(f"{offset:010} 00000 n \n".encode("ascii"))
    pdf.extend(f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode("ascii"))
    path.write_bytes(pdf)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    if args.output.exists() and any(args.output.iterdir()):
        parser.error("output must be empty; never overwrite an existing fixture set")
    args.output.mkdir(parents=True, exist_ok=True)
    epub = args.output / "S01-中文阅读测试.epub"
    pdf = args.output / "S04-reading-test.pdf"
    create_epub(epub)
    create_pdf(pdf)
    records = [{"id": "S01" if path.suffix == ".epub" else "S04", "path": str(path.resolve()),
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "source": "self-authored synthetic G0 fixture; may be redistributed",
                "scope": "G0 opening, position and notes; does not cover all advanced format cases"}
               for path in (epub, pdf)]
    (args.output / "manifest.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(records, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
