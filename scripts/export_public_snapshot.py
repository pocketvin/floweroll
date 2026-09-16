#!/usr/bin/env python3
"""Export a verified current source tree, without history, credentials or work data."""
from __future__ import annotations
import argparse
import hashlib
from pathlib import Path
import shutil
import sys
from publication_files import DIRECTORIES, source_files
from verify_repository import inspect


def export(root: Path, output: Path) -> int:
    root, output = root.resolve(), output.resolve()
    if output.exists():
        raise ValueError('Destination already exists; refusing to overwrite it')
    if output == root or root.is_relative_to(output):
        raise ValueError('Destination must not contain the source repository')
    if any(output.is_relative_to(root / name) for name in DIRECTORIES):
        raise ValueError('Destination must not be inside maintained source directories')
    errors, _ = inspect(root)
    if errors:
        raise ValueError('Source failed structural gate; run verify_repository.py')
    files = source_files(root)
    before = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    output.mkdir(parents=True)
    for p in files:
        dest = output / p.relative_to(root)
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, dest)
    after = {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in source_files(root)}
    if before != after:
        raise ValueError('Source changed during export; this output is NOT accepted')
    for rel, expected in before.items():
        if hashlib.sha256((output / rel).read_bytes()).hexdigest() != expected:
            raise ValueError('Exported file hash mismatch: ' + rel)
    errors, _ = inspect(output)
    if errors:
        raise ValueError('Export failed structural gate')
    (output / 'SOURCE-MANIFEST.sha256').write_text(''.join(f'{sha}  {rel}\n' for rel, sha in sorted(before.items())))
    print(f'EXPORTED {len(files)} files with verified SHA-256 manifest: {output}')
    print('No Git history copied; no remote created and nothing pushed.')
    return len(files)


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    p.add_argument('--output', type=Path, required=True)
    args = p.parse_args()
    try:
        export(args.root, args.output)
    except (ValueError, OSError) as e:
        print(str(e), file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
