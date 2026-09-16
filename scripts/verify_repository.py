#!/usr/bin/env python3
"""Verify publication names, resources, privacy paths and project identities.

This is a structural gate, not a substitute for Gitleaks or a security audit.
The historical-name deny list is encoded solely to avoid the gate matching itself;
there are no runtime aliases and no exclusions for product source or binaries.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import re
import sys
import zipfile
from publication_files import source_files

_DENY = (
    (98,108,117,101,119,104,97,108,101),
    (119,101,108,108,112,104,111,110,101),
    (119,104,111,108,101,119,104,97,108,101),
    (120,105,97,111,104,111,117),
    (23567,21518),
)
_NAMES = [''.join(map(chr, row)) for row in _DENY]
_LEGACY = re.compile('|'.join(re.escape(s) for s in _NAMES) + '|w[h]ole[ _-]+w[h]ale', re.I)
_H_PREFIX = re.compile(r'(?<![A-Za-z])' + ''.join(map(chr, (72,111,117))) + r'(?=[A-Z_]|\b)')
_PRIVATE_PATH = re.compile(r'/Users/[A-Za-z0-9_.-]+/')
_DEVICE_ID = re.compile(r'\b00008[0-9A-F]{3}-[0-9A-F]{16}\b', re.I)
_TUNNEL = re.compile(r'https?://[A-Za-z0-9-]+\.(?:trycloudflare\.com|ngrok-free\.app)')


def old_brand(text: str) -> bool:
    return bool(_LEGACY.search(text) or _H_PREFIX.search(text))


def inspect(root: Path) -> tuple[list[str], int]:
    root = root.resolve()
    errors: list[str] = []
    files = source_files(root)
    for p in files:
        rel = p.relative_to(root).as_posix()
        if old_brand(rel):
            errors.append(f'{rel}: historical brand in path')
        raw = p.read_bytes()
        text = raw.decode('utf-8', errors='ignore')
        # Long brand names are checked in every binary. Short Swift prefixes
        # only have identifier semantics in text and Rive, not compressed pixels.
        if _LEGACY.search(text):
            errors.append(f'{rel}: historical brand in content')
        # Do not mistake random bytes in PNG/JPEG payloads for private text.
        try:
            strict = raw.decode('utf-8')
        except UnicodeDecodeError:
            strict = ''
        if _H_PREFIX.search(strict) or (p.suffix == '.riv' and _H_PREFIX.search(raw.decode('latin1'))):
            errors.append(f'{rel}: historical Swift prefix in content')
        for rule, label in [(_PRIVATE_PATH, 'personal absolute path'),
                            (_DEVICE_ID, 'personal device identifier'),
                            (_TUNNEL, 'live personal tunnel URL')]:
            if rule.search(strict):
                errors.append(f'{rel}: {label}')
        # Project-authored OOXML fixtures are packaged data; inspect members too.
        if p.suffix.lower() in {'.docx', '.xlsx', '.pptx', '.zip'}:
            try:
                with zipfile.ZipFile(p) as z:
                    members = z.infolist()
                    if len(members) > 1000 or sum(x.file_size for x in members) > 32 * 1024 * 1024:
                        errors.append(f'{rel}: package exceeds scan bounds')
                        continue
                    for m in members:
                        if old_brand(m.filename) or old_brand(z.read(m).decode('utf-8', errors='ignore')):
                            errors.append(f'{rel}: historical brand in packaged content')
                            break
            except (OSError, zipfile.BadZipFile):
                errors.append(f'{rel}: unreadable package')
        if p.name == 'Contents.json' and p.parent.suffix in {'.imageset', '.appiconset'}:
            try:
                for image in json.loads(strict).get('images', []):
                    filename = image.get('filename')
                    if filename and not (p.parent / filename).is_file():
                        errors.append(f'{rel}: missing catalog image')
            except (ValueError, TypeError):
                errors.append(f'{rel}: invalid catalog JSON')
    return errors, len(files)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    args = parser.parse_args()
    root = args.root.resolve()
    try:
        errors, count = inspect(root)
    except (ValueError, OSError) as e:
        print(type(e).__name__ + ': ' + str(e), file=sys.stderr)
        return 1
    for error in errors:
        print('FAIL ' + error, file=sys.stderr)  # Never print matched secret values.
    print(f'Publication boundary: {count} files; {len(errors)} structural violations')
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
