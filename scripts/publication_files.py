"""Explicit publication boundary shared by the verifier and snapshot exporter."""
from __future__ import annotations
import os
from pathlib import Path

DIRECTORIES = ('.github', 'ios', 'host', 'shared', 'assets', 'scripts', 'dev', 'docs')
ROOT_FILES = ('README.md', 'AGENTS.md', 'LICENSE', 'ASSETS-LICENSE.md',
              'THIRD_PARTY_NOTICES.md', 'SECURITY.md', 'CONTRIBUTING.md',
              '.gitignore', '.gitattributes', '.python-version', '.env.example')
EXCLUDED_DIRS = {'.git', '.venv', '__pycache__', 'xcuserdata', 'DerivedData', '.build',
                 '.pytest_cache', '.mypy_cache', '.ruff_cache', 'work', 'outputs', 'test-results', 'node_modules'}
GENERATED_PATHS = {Path('dev/observability/web/dist')}
PRIVATE_FILES = {'Local.xcconfig', 'Secrets.xcconfig', '.DS_Store'}
DANGEROUS_SUFFIXES = {'.p8', '.p12', '.pem', '.key', '.mobileprovision', '.pfx',
                      '.sqlite', '.sqlite3', '.db', '.sqlite-shm', '.sqlite-wal', '.sqlite-journal',
                      '.sqlite3-shm', '.sqlite3-wal', '.sqlite3-journal',
                      '.db-shm', '.db-wal', '.db-journal', '.ipa', '.log'}


def source_files(root: Path) -> list[Path]:
    """Return the actual worktree, including maintained files not yet committed.

    Never follows symlinks, walks private work/, or consults an obsolete Git HEAD.
    Unexpected signing/runtime files in maintained source directories fail closed.
    """
    root = root.resolve()
    result = []
    for name in ROOT_FILES:
        p = root / name
        if p.is_symlink():
            raise ValueError(f'Publication refuses symlink: {name}')
        if p.is_file():
            result.append(p)
    for name in DIRECTORIES:
        base = root / name
        if base.is_symlink():
            raise ValueError(f'Publication refuses symlink: {name}')
        if not base.exists():
            continue
        for folder, directories, names in os.walk(base, followlinks=False):
            for d in list(directories):
                if d in EXCLUDED_DIRS or (Path(folder) / d).relative_to(root) in GENERATED_PATHS or d.endswith(('.xcresult', '.xcarchive')):
                    directories.remove(d)
                    continue
                p = Path(folder) / d
                if p.is_symlink():
                    raise ValueError(f'Publication refuses symlink: {p.relative_to(root)}')
            for filename in names:
                p = Path(folder) / filename
                if p.is_symlink():
                    raise ValueError(f'Publication refuses symlink: {p.relative_to(root)}')
                if filename in PRIVATE_FILES or filename.endswith(('.pyc', '.pyo', '.xcuserstate')):
                    continue
                if filename.startswith('.env') and not filename.endswith('.example'):
                    continue
                if p.suffix.lower() in DANGEROUS_SUFFIXES:
                    raise ValueError(f'Unexpected private/runtime file: {p.relative_to(root)}')
                result.append(p)
    return sorted(set(result), key=lambda p: p.relative_to(root).as_posix())
