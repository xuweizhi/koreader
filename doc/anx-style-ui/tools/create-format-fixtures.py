#!/usr/bin/env python3
"""Generate self-authored format fixtures; refuses to overwrite an existing set."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tarfile
import zipfile
from PIL import Image, ImageDraw, ImageFont


def epub(path, assets, *, english=False, chapters=3, paragraphs=30):
    title = "The quiet reading room" if english else "山间阅读：长书名、图片、脚注、原生批注与返回位置验证"
    manifest = ''.join(f'<item id="c{i}" href="c{i}.xhtml" media-type="application/xhtml+xml"/>' for i in range(1, chapters + 1))
    spine = ''.join(f'<itemref idref="c{i}"/>' for i in range(1, chapters + 1))
    entries = {
        'mimetype': b'application/epub+zip',
        'META-INF/container.xml': b'<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="OEBPS/book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>',
        'OEBPS/book.opf': (f'<package xmlns="http://www.idpf.org/2007/opf" version="2.0" unique-identifier="uid"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="uid">anx-self-authored-{chapters}-{english}</dc:identifier><dc:title>{title}</dc:title><dc:creator>Anx Fixture Author</dc:creator><dc:language>{"en" if english else "zh-CN"}</dc:language></metadata><manifest>{manifest}<item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/><item id="css" href="style.css" media-type="text/css"/><item id="font" href="serif.ttf" media-type="application/vnd.ms-opentype"/><item id="picture" href="picture.png" media-type="image/png"/></manifest><spine toc="ncx">{spine}</spine></package>').encode(),
        'OEBPS/style.css': b'@font-face{font-family:Fixture;src:url(serif.ttf)}body{font-family:Fixture,serif}p{hyphens:auto}img{width:120px}em{font-style:italic}',
        'OEBPS/serif.ttf': Path('/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf').read_bytes(),
        'OEBPS/picture.png': (assets / 'page-1.png').read_bytes(),
    }
    nav = ''.join(f'<navPoint id="n{i}" playOrder="{i}"><navLabel><text>Chapter {i}</text></navLabel><content src="c{i}.xhtml"/></navPoint>' for i in range(1, chapters + 1))
    entries['OEBPS/toc.ncx'] = (f'<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1"><head><meta name="dtb:uid" content="anx-fixture"/></head><docTitle><text>{title}</text></docTitle><navMap>{nav}</navMap></ncx>').encode()
    for chapter in range(1, chapters + 1):
        content = []
        for n in range(1, paragraphs + 1):
            text = ('A patient reader follows the needle through an extraordinary, carefully typeset page. '
                    '<em>Italic words</em> and long hyphenation examples accompany every paragraph. '
                    'This original text exercises selection, notes, search and returning to a remembered location. ' if english else
                    '读者在山间翻开书页，记录自己的理解。这个自制段落用于核对中文排版、笔记与位置恢复。'
                    '查找词 needle 出现在这里。每一段有明确编号，任何跳转都可以回到原处。')
            content.append(f'<p id="p{n}">{chapter}.{n}. {text}</p>')
        entries[f'OEBPS/c{chapter}.xhtml'] = (f'<html xmlns="http://www.w3.org/1999/xhtml"><head><title>Chapter {chapter}</title><link rel="stylesheet" href="style.css"/></head><body><h1>Chapter {chapter}</h1><p id="origin"><a href="#footnote">Footnote example / 脚注</a> · <a href="https://example.org/">External link</a></p><img src="picture.png" alt="Self-authored diagram"/>{"".join(content)}<p id="footnote">Footnote: the needle is a search marker. <a href="#origin">Return</a></p></body></html>').encode()
    with zipfile.ZipFile(path, 'w') as archive:
        for name, data in entries.items():
            info = zipfile.ZipInfo(name, (2000, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_STORED if name == 'mimetype' else zipfile.ZIP_DEFLATED
            archive.writestr(info, data)


def text_pdf(path):
    objects = [b'', b'', b'<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>']
    pages = []
    for page in range(1, 4):
        page_id, stream_id = len(objects) + 1, len(objects) + 2
        pages.append(page_id)
        width, height = (792, 612) if page == 2 else (612, 792)
        text = f'BT /F1 20 Tf 50 {height - 50} Td (Chapter {page}: original PDF text) Tj /F1 12 Tf '
        text += ''.join(f'0 -25 Td (Page {page}, line {n}: the needle marks a searchable reading location.) Tj ' for n in range(1, 16)) + 'ET'
        stream = text.encode()
        objects += [f'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {width} {height}] /Resources << /Font << /F1 3 0 R >> >> /Contents {stream_id} 0 R >>'.encode(), b'<< /Length ' + str(len(stream)).encode() + b' >>\nstream\n' + stream + b'\nendstream']
    outline_root = len(objects) + 1
    objects += [f'<< /Type /Outlines /First {outline_root + 1} 0 R /Last {outline_root + 2} 0 R /Count 2 >>'.encode(),
                f'<< /Title (Chapter 1) /Parent {outline_root} 0 R /Next {outline_root + 2} 0 R /Dest [{pages[0]} 0 R /Fit] >>'.encode(),
                f'<< /Title (Chapter 3) /Parent {outline_root} 0 R /Prev {outline_root + 1} 0 R /Dest [{pages[2]} 0 R /Fit] >>'.encode()]
    link_id = len(objects) + 1
    objects.append(f'<< /Type /Annot /Subtype /Link /Rect [50 720 400 760] /Border [0 0 1] /Dest [{pages[2]} 0 R /Fit] >>'.encode())
    objects[pages[0] - 1] = objects[pages[0] - 1][:-2] + f' /Annots [{link_id} 0 R] >>'.encode()
    objects[0] = f'<< /Type /Catalog /Pages 2 0 R /Outlines {outline_root} 0 R >>'.encode()
    objects[1] = ('<< /Type /Pages /Kids [' + ' '.join(f'{p} 0 R' for p in pages) + '] /Count 3 >>').encode()
    output, offsets = bytearray(b'%PDF-1.4\n'), []
    for number, obj in enumerate(objects, 1):
        offsets.append(len(output)); output.extend(f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n')
    xref = len(output)
    output.extend(f'xref\n0 {len(objects) + 1}\n0000000000 65535 f \n'.encode())
    for offset in offsets: output.extend(f'{offset:010} 00000 n \n'.encode())
    output.extend(f'trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    path.write_bytes(output)


def main():
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument('output', type=Path)
    args = parser.parse_args(); root = args.output
    if root.exists(): parser.error('output must not exist')
    assets = root / 'assets'; assets.mkdir(parents=True)
    font = ImageFont.truetype('/usr/share/fonts/truetype/dejavu/DejaVuSerif.ttf', 22)
    images = []
    for page in range(1, 4):
        image = Image.new('RGB', (800, 1000), 'white'); draw = ImageDraw.Draw(image)
        draw.text((40, 25), f'Self-authored scan, page {page}', fill='black', font=font)
        for column in range(2):
            for line in range(1, 25):
                draw.text((40 + 390 * column, 50 + line * 34), f'{page}.{column}.{line} A quiet reader.', fill='black', font=font)
        draw.rectangle((30, 915, 770, 970), outline='navy', width=3)
        if page == 2: image = image.rotate(1.5, fillcolor='white')
        image.save(assets / f'page-{page}.png'); image.save(assets / f'page-{page}.ppm'); images.append(image)
    epub(root / 'S01-中文-长标题-脚注-图片.epub', assets)
    epub(root / 'S02-English-fonts-links.epub', assets, english=True)
    epub(root / 'S03-large-300-chapters.epub', assets, english=True, chapters=300, paragraphs=20)
    text_pdf(root / 'S04-outline-links-landscape.pdf')
    images[0].save(root / 'S05-scanned-columns.pdf', save_all=True, append_images=images[1:], resolution=100)
    djvu_pages = []
    for page in range(1, 4):
        output = assets / f'page-{page}.djvu'
        subprocess.run(['c44', str(assets / f'page-{page}.ppm'), str(output)], check=True)
        djvu_pages.append(str(output))
    subprocess.run(['djvm', '-c', str(root / 'S06-scan.djvu'), *djvu_pages], check=True)
    with zipfile.ZipFile(root / 'S07-comic.cbz', 'w') as archive:
        for page in range(1, 4): archive.write(assets / f'page-{page}.png', f'{page:03}.png')
    with tarfile.open(root / 'S07-comic.cbt', 'w') as archive:
        for page in range(1, 4): archive.add(assets / f'page-{page}.png', arcname=f'{page:03}.png')
    paragraphs = [f'{n}. A quiet reader follows the needle. Original text for notes and navigation. ' * 4 for n in range(1, 150)]
    (root / 'S08-text.txt').write_text('\n\n'.join(paragraphs))
    (root / 'S08-book.fb2').write_text('<?xml version="1.0"?><FictionBook xmlns="http://www.gribuser.ru/xml/fictionbook/2.0"><description><title-info><genre>prose</genre><author><first-name>Anx</first-name><last-name>Fixture</last-name></author><book-title>Reading fixture</book-title><lang>en</lang></title-info></description><body><section><title><p>Original chapter</p></title>' + ''.join(f'<p>{p}</p>' for p in paragraphs) + '</section></body></FictionBook>')
    with (root / 'mobi-conversion.log').open('w') as log:
        subprocess.run(['ebook-convert', str(root / 'S02-English-fonts-links.epub'), str(root / 'S08-book.mobi')], stdout=log, stderr=subprocess.STDOUT, check=True)
    shutil.copy2(root / 'S02-English-fonts-links.epub', root / 'S09-同名测试.epub')
    with zipfile.ZipFile(root / 'S09-no-author.epub', 'w') as target, zipfile.ZipFile(root / 'S02-English-fonts-links.epub') as source:
        for entry in source.infolist():
            data = source.read(entry)
            if entry.filename.endswith('book.opf'): data = data.replace(b'<dc:creator>Anx Fixture Author</dc:creator>', b'')
            target.writestr(entry, data)
    (root / 'S09-broken.pdf').write_bytes(b'%PDF-1.4\ntruncated PDF with no pages\n')
    shutil.copy2('/usr/share/doc/fonts-dejavu-core/copyright', assets / 'DejaVu-font-license.txt')
    records = [{'id': p.name[:3], 'path': str(p.resolve()), 'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                'bytes': p.stat().st_size, 'source': 'self-authored; embedded DejaVu font license in assets; no personal books'}
               for p in sorted(root.glob('S*'))]
    (root / 'manifest.json').write_text(json.dumps(records, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps({'files': len(records), 'manifest': str(root / 'manifest.json')}, ensure_ascii=False))


if __name__ == '__main__': main()
