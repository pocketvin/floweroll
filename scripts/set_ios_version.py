#!/usr/bin/env python3
from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PROJECT_YML = ROOT / "ios" / "project.yml"
PBXPROJ = ROOT / "ios" / "Floweroll.xcodeproj" / "project.pbxproj"

VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


def read_values() -> tuple[str, int]:
    project = PROJECT_YML.read_text()
    version_match = re.search(r"^\s*MARKETING_VERSION:\s*([^\s]+)\s*$", project, re.M)
    build_match = re.search(r"^\s*CURRENT_PROJECT_VERSION:\s*(\d+)\s*$", project, re.M)
    if not version_match or not build_match:
        raise SystemExit("Unable to read version/build from ios/project.yml")
    return version_match.group(1), int(build_match.group(1))


def check_consistency(version: str, build: int) -> None:
    pbx = PBXPROJ.read_text()
    pbx_versions = set(re.findall(r"MARKETING_VERSION = ([^;]+);", pbx))
    pbx_builds = {int(x) for x in re.findall(r"CURRENT_PROJECT_VERSION = (\d+);", pbx)}
    if pbx_versions != {version}:
        raise SystemExit(f"MARKETING_VERSION mismatch: project.yml={version}, pbxproj={sorted(pbx_versions)}")
    if pbx_builds != {build}:
        raise SystemExit(f"CURRENT_PROJECT_VERSION mismatch: project.yml={build}, pbxproj={sorted(pbx_builds)}")


def set_values(version: str, build: int) -> None:
    project = PROJECT_YML.read_text()
    project, n1 = re.subn(r"(^\s*MARKETING_VERSION:\s*)[^\s]+(\s*$)", rf"\g<1>{version}\g<2>", project, count=1, flags=re.M)
    project, n2 = re.subn(r"(^\s*CURRENT_PROJECT_VERSION:\s*)\d+(\s*$)", rf"\g<1>{build}\g<2>", project, count=1, flags=re.M)
    if n1 != 1 or n2 != 1:
        raise SystemExit("Failed to update ios/project.yml")
    PROJECT_YML.write_text(project)

    pbx = PBXPROJ.read_text()
    pbx, n3 = re.subn(r"MARKETING_VERSION = [^;]+;", f"MARKETING_VERSION = {version};", pbx)
    pbx, n4 = re.subn(r"CURRENT_PROJECT_VERSION = \d+;", f"CURRENT_PROJECT_VERSION = {build};", pbx)
    if n3 < 1 or n4 < 1:
        raise SystemExit("Failed to update Xcode project version/build")
    PBXPROJ.write_text(pbx)


def main() -> None:
    parser = argparse.ArgumentParser(description="Set/check Floweroll iOS marketing version and integration build number.")
    parser.add_argument("--marketing-version")
    parser.add_argument("--build", type=int)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    current_version, current_build = read_values()
    if args.marketing_version is None and args.build is None:
        check_consistency(current_version, current_build)
        print(f"{current_version} ({current_build})")
        return

    version = args.marketing_version or current_version
    build = args.build if args.build is not None else current_build
    if not VERSION_RE.fullmatch(version):
        raise SystemExit("marketing version must be X.Y.Z")
    if build < 1:
        raise SystemExit("build must be >= 1")
    set_values(version, build)
    check_consistency(version, build)
    print(f"{version} ({build})")

if __name__ == "__main__":
    main()
