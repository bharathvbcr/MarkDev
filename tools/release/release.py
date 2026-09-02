#!/usr/bin/env python3
"""Validated release staging and retry-safe draft uploads; Python standard library only."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import tempfile
import zipfile


class ReleaseError(Exception):
    pass


def run(*args, timeout=300, check=True):
    result = subprocess.run(args, text=True, capture_output=True, timeout=timeout)
    if check and result.returncode:
        raise ReleaseError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def metadata(tag):
    if not re.fullmatch(r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", tag):
        raise ReleaseError("release tag must be vMAJOR.MINOR.PATCH")
    source = Path("project.yml").read_text()
    values = {}
    for key in ("MARKETING_VERSION", "CURRENT_PROJECT_VERSION"):
        matches = re.findall(rf'^\s*{key}:\s*"([^"\n]+)"\s*(?:#.*)?$', source, re.MULTILINE)
        if len(matches) != 1:
            raise ReleaseError(f"expected exactly one quoted {key} in project.yml")
        values[key] = matches[0]
    if values["MARKETING_VERSION"] != tag[1:]:
        raise ReleaseError(f"tag {tag} does not match MARKETING_VERSION {values['MARKETING_VERSION']}")
    if not re.fullmatch(r"[1-9][0-9]*", values["CURRENT_PROJECT_VERSION"]):
        raise ReleaseError("CURRENT_PROJECT_VERSION must be a positive integer")
    return {"tag": tag, "version": tag[1:], "build": values["CURRENT_PROJECT_VERSION"]}


def preflight(tag):
    result = metadata(tag)
    result["commit"] = run("git", "rev-parse", "HEAD").stdout.strip()
    tagged = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip()
    if tagged != result["commit"]:
        raise ReleaseError(f"{tag} does not point to HEAD")
    if run("git", "status", "--porcelain", "--untracked-files=all").stdout.strip():
        raise ReleaseError("release requires a clean committed worktree")
    notes = Path(f"docs/releases/{tag}.md")
    if not notes.is_file() or not notes.read_text().strip():
        raise ReleaseError(f"missing release notes: {notes}")
    return result


def verify_bundle(app, expected):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    bundles = [
        (app / "Contents/Info.plist", app / "Contents/MacOS/MarkDev", "dev.markdev.MarkDev"),
        (app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Info.plist",
         app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/MacOS/MarkDevQuickLook", "dev.markdev.MarkDev.QuickLook"),
        (app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/Resources/Info.plist",
         app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/MarkDevKit", "dev.markdev.MarkDevKit"),
    ]
    for path, executable, identifier in bundles:
        with path.open("rb") as stream:
            info = plistlib.load(stream)
        if path == app / "Contents/Info.plist" and info.get("MarkDevSourceCommit") != expected["commit"]:
            raise ReleaseError("app was built from a different commit; run just build-release again")
        for key, value in {"CFBundleShortVersionString": expected["version"],
                           "CFBundleVersion": expected["build"],
                           "CFBundleIdentifier": identifier,
                           "LSMinimumSystemVersion": "26.0"}.items():
            if info.get(key) != value:
                raise ReleaseError(f"{path}: {key} is {info.get(key)!r}; expected {value!r}")
        if not executable.is_file():
            raise ReleaseError(f"missing executable: {executable}")
        arch = run("lipo", "-archs", str(executable)).stdout.split()
        if arch != ["arm64"]:
            raise ReleaseError(f"{executable}: expected arm64, got {arch}")


def digest(path):
    value = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            value.update(block)
    return value.hexdigest()


def asset_paths(tag):
    stem = f"MarkDev-{tag[1:]}-macos"
    return [Path("dist") / (stem + suffix) for suffix in (".zip", ".zip.sha256", ".json")]


def stage(tag):
    expected = preflight(tag)
    settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-scheme", "MarkDev",
                              "-configuration", "Release", "-showBuildSettings", "-json").stdout)
    targets = [item for item in settings if item.get("target") == "MarkDev"]
    if len(targets) != 1:
        raise ReleaseError("build settings must contain exactly one MarkDev target")
    products = targets[0]["buildSettings"]["BUILT_PRODUCTS_DIR"]
    if not products or not Path(products).is_absolute():
        raise ReleaseError("BUILT_PRODUCTS_DIR must be an absolute directory")
    app = Path(products) / "MarkDev.app"
    verify_bundle(app, expected)
    Path("dist").mkdir(exist_ok=True)
    # Complete and verify the new package before replacing any previous asset.
    with tempfile.TemporaryDirectory(prefix=".stage-", dir="dist") as directory:
        staging = Path(directory)
        archive, checksum, manifest = [staging / path.name for path in asset_paths(tag)]
        run("ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(app), str(archive))
        with zipfile.ZipFile(archive) as bundle:
            if bundle.testzip() is not None:
                raise ReleaseError("archive CRC verification failed")
        extracted = staging / "extracted"
        run("ditto", "-x", "-k", str(archive), str(extracted))
        verify_bundle(extracted / "MarkDev.app", expected)
        sha = digest(archive)
        checksum.write_text(f"{sha}  {archive.name}\n")
        manifest.write_text(json.dumps({**expected, "architecture": "arm64", "minimum_macos": "26.0",
                                       "archive": archive.name, "sha256": sha}, indent=2) + "\n")
        # Detect edits or a moved tag while packaging. An interrupted replacement
        # is caught by verify_assets before any network mutation.
        if preflight(tag) != expected:
            raise ReleaseError("source changed while packaging")
        for source, destination in zip((archive, checksum, manifest), asset_paths(tag)):
            os.replace(source, destination)
    verify_assets(tag)
    print(f"staged {asset_paths(tag)[0]} ({expected['commit']}, build {expected['build']})")


def verify_assets(tag):
    expected = preflight(tag)
    archive, checksum, manifest = asset_paths(tag)
    recorded = json.loads(manifest.read_text())
    sha = digest(archive)
    required = {**expected, "architecture": "arm64", "minimum_macos": "26.0",
                "archive": archive.name, "sha256": sha}
    if recorded != required or checksum.read_text() != f"{sha}  {archive.name}\n":
        raise ReleaseError("staged assets do not match the checked-out release or checksum")
    return expected


def release_view(tag, allow_missing=False):
    result = run("gh", "release", "view", tag, "--json", "tagName,isDraft,assets,url", timeout=120, check=False)
    if result.returncode:
        # An authorization failure, timeout, or outage is not evidence of absence.
        if allow_missing and result.returncode == 1 and result.stderr.strip() == "release not found":
            return None
        raise ReleaseError(f"cannot inspect release: {result.stderr.strip()}")
    release = json.loads(result.stdout)
    if release.get("tagName") != tag or release.get("isDraft") is not True:
        raise ReleaseError("refusing to modify a published or mismatched release")
    return release


def verify_remote_assets(release, paths, require_all=True):
    expected = {path.name: path for path in paths}
    seen = set()
    for asset in release["assets"]:
        name = asset["name"]
        if name not in expected or name in seen:
            raise ReleaseError(f"unexpected or duplicate remote asset: {name}")
        path = expected[name]
        if (asset.get("state") != "uploaded" or asset.get("size") != path.stat().st_size
                or asset.get("digest") != "sha256:" + digest(path)):
            raise ReleaseError(f"remote asset differs or upload is incomplete: {name}; refusing to overwrite")
        seen.add(name)
    if require_all and seen != set(expected):
        raise ReleaseError("release is missing required assets")
    return seen


def draft(tag):
    expected = verify_assets(tag)
    remote = run("git", "ls-remote", "origin", f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}", timeout=120).stdout.splitlines()
    refs = dict(line.split()[::-1] for line in remote)
    if refs.get(f"refs/tags/{tag}^{{}}", refs.get(f"refs/tags/{tag}")) != expected["commit"]:
        raise ReleaseError("remote release tag does not point to the staged commit")
    release = release_view(tag, allow_missing=True)
    notes = f"docs/releases/{tag}.md"
    if release is None:
        run("gh", "release", "create", tag, "--draft", "--verify-tag", "--target", expected["commit"],
            "--title", f"MarkDev {tag}", "--notes-file", notes, timeout=120)
        release = release_view(tag)
    paths = asset_paths(tag)
    seen = verify_remote_assets(release, paths, require_all=False)
    missing = [str(path) for path in paths if path.name not in seen]
    if missing:
        release_view(tag)  # Recheck the draft boundary immediately before writing.
        run("gh", "release", "upload", tag, *missing, timeout=600)
    release = release_view(tag)
    verify_remote_assets(release, paths)
    run("gh", "release", "edit", tag, "--title", f"MarkDev {tag}", "--notes-file", notes, timeout=120)
    print(f"verified draft and all {len(paths)} assets: {release['url']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=["verify-tag", "preflight", "stage", "verify-assets", "draft"])
    parser.add_argument("tag")
    args = parser.parse_args()
    actions = {"verify-tag": metadata, "preflight": preflight, "stage": stage,
               "verify-assets": verify_assets, "draft": draft}
    try:
        result = actions[args.command](args.tag)
        if result is not None:
            print(json.dumps(result, sort_keys=True))
    except (ReleaseError, OSError, ValueError, KeyError, TypeError, zipfile.BadZipFile, subprocess.TimeoutExpired) as error:
        print(f"release: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
