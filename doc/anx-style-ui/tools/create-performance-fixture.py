#!/usr/bin/env python3
"""Create a self-authored PDF with real vector rendering work for cancellation tests."""

import hashlib
import json
from pathlib import Path
import zlib


def main():
    directory = Path('/data/koreader-anx-work/fixtures/performance-v1')
    directory.mkdir(parents=True, exist_ok=False)
    # 500,000 separate vector fills. No artificial delay, external resources,
    # huge decoded bitmap or embedded font is involved.
    content = bytearray(b'0.15 0.35 0.65 rg\n')
    for row in range(1000):
        for column in range(500):
            content.extend(f'{column * 2.4:.1f} {row * 1.6:.1f} 1.2 0.8 re f\n'.encode())
    stream = zlib.compress(content, 9)
    objects = [
        b'<< /Type /Catalog /Pages 2 0 R >>',
        b'<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
        b'<< /Type /Page /Parent 2 0 R /MediaBox [0 0 1200 1600] /Resources << >> /Contents 4 0 R >>',
        b'<< /Length ' + str(len(stream)).encode() + b' /Filter /FlateDecode >>\nstream\n' + stream + b'\nendstream',
        b'<< /Title (Anx native cover cancellation vector fixture) /Author (Anx UI test fixture) >>',
    ]
    pdf = bytearray(b'%PDF-1.4\n%\xe2\xe3\xcf\xd3\n')
    offsets = [0]
    for number, obj in enumerate(objects, 1):
        offsets.append(len(pdf))
        pdf.extend(f'{number} 0 obj\n'.encode() + obj + b'\nendobj\n')
    xref = len(pdf)
    pdf.extend(f'xref\n0 {len(offsets)}\n0000000000 65535 f \n'.encode())
    for offset in offsets[1:]:
        pdf.extend(f'{offset:010d} 00000 n \n'.encode())
    pdf.extend(f'trailer\n<< /Size {len(offsets)} /Root 1 0 R /Info 5 0 R >>\nstartxref\n{xref}\n%%EOF\n'.encode())
    target = directory / 'complex-vector-cover.pdf'
    target.write_bytes(pdf)
    metadata = {'path': str(target), 'sha256': hashlib.sha256(pdf).hexdigest(),
                'bytes': len(pdf), 'pages': 1, 'vector_rectangles': 500000,
                'uncompressed_stream_bytes': len(content), 'self_authored': True,
                'purpose': 'Additional real rendering workload to observe a live native cover worker during cancel; not a delay or mock.',
                'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest()}
    (directory / 'manifest.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print(json.dumps(metadata, indent=2))


if __name__ == '__main__':
    main()
