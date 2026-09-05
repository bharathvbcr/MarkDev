#!/usr/bin/env python3
"""Validated release staging and retry-safe draft uploads; Python standard library only."""
import argparse
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from types import MappingProxyType
import zipfile

LOCKED_PACKAGE_FLAGS = (
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
)

EXPECTED_PRIVACY_MANIFEST = {
    "NSPrivacyTracking": False,
    "NSPrivacyCollectedDataTypes": [],
}

RELEASE_ARCHITECTURES = ("arm64", "x86_64")
RELEASE_DERIVED_DATA = "build/DerivedData/Release"
RELEASE_MINIMUM_MACOS = "26.0"
RELEASE_SDK_VERSION = "26.5"
AUTOMATED_DISTRIBUTION = MappingProxyType({
    "signature": "ad-hoc",
    "hardened_runtime": False,
    "notarized": False,
})
RELEASE_TOOLCHAIN = MappingProxyType({
    "xcode": "2660",
    "xcode_build": "17F113",
    "sdk_build": "25F70",
})
EXPECTED_MAIN_FINDER_METADATA = {
    "CFBundleName": "MarkDev",
    "CFBundleDisplayName": "MarkDev",
    "CFBundleIconName": "AppIcon",
    "CFBundleIconFile": "AppIcon",
    "NSSupportsAutomaticTermination": False,
    "NSSupportsSuddenTermination": False,
    "CFBundleDocumentTypes": [
        {
            "CFBundleTypeName": "Markdown Document",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Owner",
            "CFBundleTypeIconFile": "DocumentIcon",
            "LSItemContentTypes": [
                "net.daringfireball.markdown",
                "dev.markdev.markdown-extended",
            ],
        },
        {
            "CFBundleTypeName": "Plain Text",
            "CFBundleTypeRole": "Editor",
            "LSHandlerRank": "Alternate",
            "LSItemContentTypes": ["public.plain-text"],
        },
    ],
    "UTImportedTypeDeclarations": [
        {
            "UTTypeIdentifier": "net.daringfireball.markdown",
            "UTTypeDescription": "Markdown Document",
            "UTTypeConformsTo": ["public.plain-text"],
            "UTTypeTagSpecification": {
                "public.filename-extension": ["md", "markdown"],
            },
        },
    ],
    "UTExportedTypeDeclarations": [
        {
            "UTTypeIdentifier": "dev.markdev.markdown-extended",
            "UTTypeDescription": "Markdown Document",
            "UTTypeConformsTo": ["net.daringfireball.markdown"],
            "UTTypeTagSpecification": {
                "public.filename-extension": ["mdown", "mdx", "mkd", "markdn"],
            },
        },
    ],
}
RESOURCE_BUNDLE_TOOLCHAIN_METADATA = {
    "CFBundlePackageType": "BNDL",
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "DTPlatformBuild": "25F70",
    "DTPlatformName": "macosx",
    "DTPlatformVersion": "26.5",
    "DTSDKBuild": "25F70",
    "DTSDKName": "macosx26.5",
    "DTXcode": "2660",
    "DTXcodeBuild": "17F113",
}
SWIFTMATH_RESOURCE_METADATA = {
    **RESOURCE_BUNDLE_TOOLCHAIN_METADATA,
    "CFBundleIdentifier": "swiftmath.SwiftMath.resources",
    "CFBundleName": "SwiftMath_SwiftMath",
    "LSMinimumSystemVersion": "12.0",
}
SWIFTTERM_RESOURCE_METADATA = {
    **RESOURCE_BUNDLE_TOOLCHAIN_METADATA,
    "CFBundleIdentifier": "swiftterm.SwiftTerm.resources",
    "CFBundleName": "SwiftTerm_SwiftTerm",
    "LSMinimumSystemVersion": "11.0",
}
MAX_RELEASE_ARCHIVE_BYTES = 1024 * 1024 * 1024
MAX_RELEASE_ARCHIVE_ENTRIES = 100_000
MAX_RELEASE_UNCOMPRESSED_BYTES = 4 * 1024 * 1024 * 1024
RELEASE_LOCK_TIMEOUT_SECONDS = 600.0
RELEASE_LOCK_POLL_SECONDS = 0.05
MAX_STALE_GENERATIONS_PER_TAG = 8
MAX_STALE_BYTES_PER_TAG = MAX_RELEASE_ARCHIVE_BYTES + (1024 * 1024)
MAX_DIST_ENTRIES = 256
MAX_RELEASE_CHECKSUM_BYTES = 4096
MAX_RELEASE_MANIFEST_BYTES = 64 * 1024
RELEASE_TAG_PATTERN = re.compile(
    r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"
)
ASSET_SUFFIXES = (".zip", ".zip.sha256", ".json")
AT_FDCWD = -2
RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
MATH_FONT_PAYLOAD = {
    "Asana-Math.otf", "Asana-Math.plist", "Euler-Math.otf",
    "Euler-Math.plist", "FiraMath-Regular.otf", "FiraMath-Regular.plist",
    "GUST-FONT-LICENSE.txt", "Garamond-Math.otf", "Garamond-Math.plist",
    "KpMath-Light.otf", "KpMath-Light.plist", "KpMath-Sans.otf",
    "KpMath-Sans.plist", "LICENSE", "LeteSansMath.otf",
    "LeteSansMath.plist", "LibertinusMath-Regular.otf",
    "LibertinusMath-Regular.plist", "NotoSansMath-Regular.otf",
    "NotoSansMath-Regular.plist", "OFL.txt", "latinmodern-math.otf",
    "latinmodern-math.plist", "math_table_to_plist.py",
    "texgyretermes-math.otf", "texgyretermes-math.plist",
    "xits-math.otf", "xits-math.plist",
}


class ReleaseError(Exception):
    pass


def asset_stem(tag):
    if not isinstance(tag, str) or RELEASE_TAG_PATTERN.fullmatch(tag) is None:
        raise ReleaseError("release tag must be vMAJOR.MINOR.PATCH")
    return f"MarkDev-{tag[1:]}-macos"


def run(*args, timeout=300, check=True, pass_fds=()):
    result = subprocess.run(
        args,
        text=True,
        capture_output=True,
        timeout=timeout,
        pass_fds=tuple(pass_fds),
    )
    if check and result.returncode:
        raise ReleaseError(f"{args[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result


def metadata(tag):
    asset_stem(tag)
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
    tag_type = run("git", "cat-file", "-t", f"refs/tags/{tag}").stdout.strip()
    if tag_type != "tag":
        raise ReleaseError(f"{tag} must be an annotated tag")
    tagged = run("git", "rev-parse", f"refs/tags/{tag}^{{commit}}").stdout.strip()
    if tagged != result["commit"]:
        raise ReleaseError(f"{tag} does not point to HEAD")
    if run("git", "status", "--porcelain", "--untracked-files=all").stdout.strip():
        raise ReleaseError("release requires a clean committed worktree")
    notes = Path(f"docs/releases/{tag}.md")
    if not notes.is_file() or not notes.read_text().strip():
        raise ReleaseError(f"missing release notes: {notes}")
    return result


def signed_entitlements(bundle, architecture):
    result = run(
        "codesign", "--display", "--arch", architecture,
        "--xml", "--entitlements", "-", str(bundle),
    )
    output = result.stdout + result.stderr
    start = output.find("<?xml")
    end = output.rfind("</plist>")
    if start == -1 or end == -1:
        return {}
    try:
        value = plistlib.loads(output[start:end + len("</plist>")].encode())
    except plistlib.InvalidFileException as error:
        raise ReleaseError(f"cannot decode signed entitlements for {bundle}: {error}") from error
    if not isinstance(value, dict):
        raise ReleaseError(f"signed entitlements for {bundle} are not a dictionary")
    return value


def verify_quicklook_link_surface(executable):
    linked = run("otool", "-L", str(executable)).stdout
    for forbidden in ("MarkDevKit.framework", "SwiftTerm"):
        if forbidden in linked:
            raise ReleaseError(
                f"Quick Look executable links forbidden app authority: {forbidden}")

    symbol_output = run("nm", "-gj", str(executable)).stdout
    symbols = {
        line.split()[-1] for line in symbol_output.splitlines() if line.split()
    }
    for forbidden in (
        "_OBJC_CLASS_$_NSApplication",
        "_NSApp",
        "_OBJC_CLASS_$_NSPasteboard",
        "_OBJC_CLASS_$_NSTask",
        "_OBJC_CLASS_$_NSWorkspace",
    ):
        if forbidden in symbols:
            raise ReleaseError(
                f"Quick Look executable references forbidden app authority: {forbidden}")
    for symbol in symbols:
        if "SwiftTerm" in symbol:
            raise ReleaseError(
                "Quick Look executable references forbidden app authority: SwiftTerm")
        if symbol.startswith("_md_vault_"):
            raise ReleaseError(
                f"Quick Look executable retains forbidden vault authority: {symbol}")
        if (
            symbol in {"_fork", "_vfork", "_popen", "_system"}
            or symbol.startswith("_exec")
            or symbol.startswith("_posix_spawn")
            or "std3sys7process" in symbol
        ):
            raise ReleaseError(
                f"Quick Look executable retains forbidden process authority: {symbol}")


def verify_macho_build_version(executable):
    expected = {
        "platform": "MACOS",
        "minos": RELEASE_MINIMUM_MACOS,
        "sdk": RELEASE_SDK_VERSION,
    }
    for architecture in RELEASE_ARCHITECTURES:
        output = run(
            "vtool", "-show-build", "-arch", architecture, str(executable)
        ).stdout
        blocks = re.split(r"(?=^Load command [0-9]+\s*$)", output, flags=re.MULTILINE)
        build_versions = [
            block for block in blocks
            if re.search(r"(?m)^\s*cmd\s+LC_BUILD_VERSION\s*$", block)
        ]
        if len(build_versions) != 1:
            raise ReleaseError(
                f"{executable}: expected one {architecture} LC_BUILD_VERSION, "
                f"got {len(build_versions)}"
            )
        block = build_versions[0]
        for field, value in expected.items():
            observed = re.findall(
                rf"(?m)^\s*{field}\s+(\S+)\s*$", block
            )
            if observed != [value]:
                raise ReleaseError(
                    f"{executable}: {architecture} {field} is {observed}; "
                    f"expected {[value]}"
                )


def verify_privacy_manifest(path):
    try:
        with path.open("rb") as stream:
            manifest = plistlib.load(stream)
    except FileNotFoundError as error:
        raise ReleaseError(f"missing privacy manifest: {path}") from error
    except plistlib.InvalidFileException as error:
        raise ReleaseError(f"invalid privacy manifest: {path}") from error
    if manifest != EXPECTED_PRIVACY_MANIFEST:
        raise ReleaseError(
            f"{path}: privacy declaration does not match MarkDev's local-only behavior")


def require_exact_release_architectures(architectures, owner):
    architectures = tuple(architectures)
    if (
        len(architectures) != len(RELEASE_ARCHITECTURES)
        or set(architectures) != set(RELEASE_ARCHITECTURES)
    ):
        raise ReleaseError(
            f"{owner}: expected exactly {list(RELEASE_ARCHITECTURES)}, "
            f"got {list(architectures)}"
        )


def require_children(path, required, owner, optional=()):
    if path.is_symlink() or not path.is_dir():
        raise ReleaseError(f"missing release directory: {path}")
    observed = {child.name for child in path.iterdir()}
    missing = sorted(set(required) - observed)
    if missing:
        raise ReleaseError(f"{owner} is missing required staged output: {missing}")
    unexpected = sorted(observed - set(required) - set(optional))
    if unexpected:
        raise ReleaseError(f"{owner} contains unexpected staged output: {unexpected}")


def require_regular_file(path, owner):
    if path.is_symlink() or not path.is_file():
        raise ReleaseError(f"{owner} is missing or is not a regular file: {path}")


def require_symlink(path, target, owner):
    if not path.is_symlink() or os.readlink(path) != target:
        actual = os.readlink(path) if path.is_symlink() else "not a symlink"
        raise ReleaseError(f"{owner} must be a symlink to {target!r}; got {actual!r}")


def verify_plist_metadata(path, expected, owner):
    require_regular_file(path, f"{owner} metadata")
    try:
        with path.open("rb") as stream:
            info = plistlib.load(stream)
    except (OSError, plistlib.InvalidFileException) as error:
        raise ReleaseError(f"{owner} metadata is not a valid property list: {path}") from error
    if not isinstance(info, dict):
        raise ReleaseError(f"{owner} metadata root is not a dictionary: {path}")
    for key, value in expected.items():
        if info.get(key) != value:
            raise ReleaseError(
                f"{path}: {key} is {info.get(key)!r}; expected {value!r}"
            )


def verify_math_resource_bundle(path, owner):
    require_children(path, {"Contents"}, owner)
    contents = path / "Contents"
    require_children(contents, {"Info.plist", "Resources"}, f"{owner}/Contents")
    verify_plist_metadata(
        contents / "Info.plist", SWIFTMATH_RESOURCE_METADATA, owner
    )
    resources = contents / "Resources"
    require_children(resources, {"mathFonts.bundle"}, f"{owner}/Contents/Resources")
    fonts = resources / "mathFonts.bundle"
    require_children(fonts, MATH_FONT_PAYLOAD, f"{owner} math font payload")
    for name in MATH_FONT_PAYLOAD:
        require_regular_file(fonts / name, f"{owner} math font payload")


def verify_swiftterm_resource_bundle(path):
    owner = "SwiftTerm_SwiftTerm.bundle"
    require_children(path, {"Contents"}, owner)
    contents = path / "Contents"
    require_children(contents, {"Info.plist", "Resources"}, f"{owner}/Contents")
    verify_plist_metadata(
        contents / "Info.plist", SWIFTTERM_RESOURCE_METADATA, owner
    )
    resources = contents / "Resources"
    require_children(resources, {"default.metallib"}, f"{owner}/Contents/Resources")
    require_regular_file(resources / "default.metallib", f"{owner} Metal library")


def verify_automated_signature(bundle):
    for architecture in RELEASE_ARCHITECTURES:
        result = run(
            "codesign", "--display", "--arch", architecture, "--verbose=4", str(bundle)
        )
        output = result.stdout + result.stderr
        signatures = re.findall(r"(?m)^Signature=([^\n]+)$", output)
        flags = re.findall(r"(?m)^CodeDirectory\b[^\n]*\bflags=([^\s]+)", output)
        teams = re.findall(r"(?m)^TeamIdentifier=([^\n]+)$", output)
        if signatures != ["adhoc"]:
            raise ReleaseError(
                f"automated release must be ad-hoc signed for {architecture}: {bundle}")
        if len(flags) != 1 or "adhoc" not in flags[0] or "runtime" in flags[0]:
            raise ReleaseError(
                f"automated release has unexpected {architecture} signing flags {flags}: {bundle}")
        if teams != ["not set"]:
            raise ReleaseError(
                f"automated release unexpectedly carries a {architecture} team identity: {bundle}")


def verify_bundle(app, expected, signature_verifier=verify_automated_signature):
    run("codesign", "--verify", "--deep", "--strict", str(app))
    signature_verifier(app)
    contents = app / "Contents"
    require_children(
        contents,
        {"Frameworks", "Info.plist", "MacOS", "PlugIns", "Resources", "_CodeSignature"},
        "MarkDev.app/Contents",
        optional={"PkgInfo"},
    )
    if os.path.lexists(contents / "PkgInfo"):
        require_regular_file(contents / "PkgInfo", "MarkDev.app/Contents/PkgInfo")
    require_children(contents / "MacOS", {"MarkDev"}, "MarkDev.app/Contents/MacOS")
    require_children(
        contents / "Frameworks", {"MarkDevKit.framework"}, "MarkDev.app/Contents/Frameworks")
    require_children(
        contents / "PlugIns", {"MarkDevQuickLook.appex"}, "MarkDev.app/Contents/PlugIns")
    require_children(
        contents / "Resources",
        {
            "AppIcon.icns",
            "Assets.car",
            "DocumentIcon.icns",
            "PrivacyInfo.xcprivacy",
            "SwiftMath_SwiftMath.bundle",
            "SwiftTerm_SwiftTerm.bundle",
        },
        "MarkDev.app/Contents/Resources",
    )
    for name in ("AppIcon.icns", "Assets.car", "DocumentIcon.icns", "PrivacyInfo.xcprivacy"):
        require_regular_file(contents / "Resources" / name, f"MarkDev resource {name}")
    require_children(
        contents / "_CodeSignature", {"CodeResources"}, "MarkDev.app code signature")
    require_regular_file(
        contents / "_CodeSignature/CodeResources", "MarkDev.app code signature")
    verify_math_resource_bundle(
        contents / "Resources/SwiftMath_SwiftMath.bundle",
        "MarkDev SwiftMath_SwiftMath.bundle",
    )
    verify_swiftterm_resource_bundle(contents / "Resources/SwiftTerm_SwiftTerm.bundle")
    for architecture in RELEASE_ARCHITECTURES:
        main_entitlements = signed_entitlements(app, architecture)
        if main_entitlements:
            raise ReleaseError(
                f"main app {architecture} slice has unexpected signed entitlements: "
                f"{sorted(main_entitlements)}")
    quicklook = app / "Contents/PlugIns/MarkDevQuickLook.appex"
    require_children(quicklook, {"Contents"}, "MarkDevQuickLook.appex")
    signature_verifier(quicklook)
    require_children(
        quicklook / "Contents",
        {"Info.plist", "MacOS", "Resources", "_CodeSignature"},
        "MarkDevQuickLook.appex/Contents",
    )
    require_children(
        quicklook / "Contents/MacOS",
        {"MarkDevQuickLook"},
        "MarkDevQuickLook.appex/Contents/MacOS",
    )
    require_children(
        quicklook / "Contents/Resources",
        {"PrivacyInfo.xcprivacy", "SwiftMath_SwiftMath.bundle"},
        "MarkDevQuickLook.appex/Contents/Resources",
    )
    require_regular_file(
        quicklook / "Contents/Resources/PrivacyInfo.xcprivacy",
        "MarkDevQuickLook privacy manifest",
    )
    require_children(
        quicklook / "Contents/_CodeSignature",
        {"CodeResources"},
        "MarkDevQuickLook code signature",
    )
    require_regular_file(
        quicklook / "Contents/_CodeSignature/CodeResources",
        "MarkDevQuickLook code signature",
    )
    verify_math_resource_bundle(
        quicklook / "Contents/Resources/SwiftMath_SwiftMath.bundle",
        "MarkDevQuickLook SwiftMath_SwiftMath.bundle",
    )
    required_quicklook = {
        "com.apple.security.app-sandbox": True,
        "com.apple.security.files.user-selected.read-only": True,
    }
    for architecture in RELEASE_ARCHITECTURES:
        quicklook_entitlements = signed_entitlements(quicklook, architecture)
        if quicklook_entitlements != required_quicklook:
            raise ReleaseError(
                f"Quick Look {architecture} signed entitlements must exactly match its "
                f"read-only sandbox authority; got {sorted(quicklook_entitlements)}")
    framework = app / "Contents/Frameworks/MarkDevKit.framework"
    require_children(
        framework,
        {"MarkDevKit", "Resources", "Versions"},
        "MarkDevKit.framework",
    )
    require_symlink(framework / "MarkDevKit", "Versions/Current/MarkDevKit", "framework executable")
    require_symlink(framework / "Resources", "Versions/Current/Resources", "framework resources")
    require_children(
        framework / "Versions",
        {"A", "Current"},
        "MarkDevKit.framework/Versions",
    )
    require_symlink(framework / "Versions/Current", "A", "framework current version")
    require_children(
        framework / "Versions/A",
        {"MarkDevKit", "Resources", "_CodeSignature"},
        "MarkDevKit.framework/Versions/A",
    )
    require_children(
        framework / "Versions/A/Resources",
        {"Info.plist", "PrivacyInfo.xcprivacy"},
        "MarkDevKit.framework/Versions/A/Resources",
    )
    require_regular_file(
        framework / "Versions/A/Resources/PrivacyInfo.xcprivacy",
        "MarkDevKit privacy manifest",
    )
    require_children(
        framework / "Versions/A/_CodeSignature",
        {"CodeResources"},
        "MarkDevKit code signature",
    )
    require_regular_file(
        framework / "Versions/A/_CodeSignature/CodeResources",
        "MarkDevKit code signature",
    )
    signature_verifier(framework)
    for architecture in RELEASE_ARCHITECTURES:
        framework_entitlements = signed_entitlements(framework, architecture)
        if framework_entitlements:
            raise ReleaseError(
                f"MarkDevKit {architecture} slice has unexpected signed entitlements: "
                f"{sorted(framework_entitlements)}")
    quicklook_executable = quicklook / "Contents/MacOS/MarkDevQuickLook"
    verify_quicklook_link_surface(quicklook_executable)
    bundles = [
        (app / "Contents/Info.plist", app / "Contents/MacOS/MarkDev", "dev.markdev.MarkDev",
         "MarkDev", "APPL", app / "Contents/Resources/PrivacyInfo.xcprivacy"),
        (app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Info.plist",
         app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/MacOS/MarkDevQuickLook", "dev.markdev.MarkDev.QuickLook",
         "MarkDevQuickLook", "XPC!",
         app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Resources/PrivacyInfo.xcprivacy"),
        (app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/Resources/Info.plist",
         app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/MarkDevKit", "dev.markdev.MarkDevKit",
         "MarkDevKit", "FMWK",
         app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/Resources/PrivacyInfo.xcprivacy"),
    ]
    for path, executable, identifier, executable_name, package_type, privacy_manifest in bundles:
        require_regular_file(path, f"{identifier} Info.plist")
        with path.open("rb") as stream:
            info = plistlib.load(stream)
        verify_privacy_manifest(privacy_manifest)
        if path == app / "Contents/Info.plist":
            if info.get("MarkDevSourceCommit") != expected["commit"]:
                raise ReleaseError("app was built from a different commit; run just build-release again")
            for key, value in EXPECTED_MAIN_FINDER_METADATA.items():
                if info.get(key) != value:
                    raise ReleaseError(
                        f"{path}: {key} does not match the exact Finder release contract"
                    )
        for key, value in {"CFBundleShortVersionString": expected["version"],
                           "CFBundleVersion": expected["build"],
                           "CFBundleIdentifier": identifier,
                           "CFBundleExecutable": executable_name,
                           "CFBundlePackageType": package_type,
                           "DTXcode": RELEASE_TOOLCHAIN["xcode"],
                           "DTXcodeBuild": RELEASE_TOOLCHAIN["xcode_build"],
                           "DTSDKBuild": RELEASE_TOOLCHAIN["sdk_build"],
                           "LSMinimumSystemVersion": "26.0"}.items():
            if info.get(key) != value:
                raise ReleaseError(f"{path}: {key} is {info.get(key)!r}; expected {value!r}")
        require_regular_file(executable, f"{identifier} executable")
        require_exact_release_architectures(
            run("lipo", "-archs", str(executable)).stdout.split(),
            executable,
        )
        verify_macho_build_version(executable)

    with (quicklook / "Contents/Info.plist").open("rb") as stream:
        quicklook_info = plistlib.load(stream)
    expected_extension = {
        "NSExtensionPointIdentifier": "com.apple.quicklook.preview",
        "NSExtensionPrincipalClass": "MarkDevQuickLook.PreviewViewController",
        "NSExtensionAttributes": {
            "QLSupportedContentTypes": [
                "net.daringfireball.markdown",
                "dev.markdev.markdown-extended",
            ],
            "QLSupportsSearchableItems": False,
        },
    }
    if quicklook_info.get("NSExtension") != expected_extension:
        raise ReleaseError("Quick Look extension registration metadata does not match the release contract")


def _file_state(info):
    """Return mutation-relevant metadata, excluding read-updated access time."""
    return (
        info.st_dev,
        info.st_ino,
        info.st_mode,
        info.st_nlink,
        info.st_uid,
        info.st_gid,
        info.st_size,
        info.st_mtime_ns,
        info.st_ctime_ns,
    )


def _open_bounded_regular_file(path, maximum_bytes, label):
    path = Path(path)
    if (
        not isinstance(maximum_bytes, int)
        or isinstance(maximum_bytes, bool)
        or maximum_bytes < 0
    ):
        raise ValueError("maximum_bytes must be a non-negative integer")
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as error:
        raise ReleaseError(f"cannot open {label} as a regular file: {path}: {error}") from error
    try:
        opened = os.fstat(descriptor)
        try:
            linked = path.lstat()
        except FileNotFoundError as error:
            raise ReleaseError(f"{label} changed while opening: {path}") from error
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or not stat.S_ISREG(linked.st_mode)
            or linked.st_nlink != 1
            or opened.st_dev != linked.st_dev
            or opened.st_ino != linked.st_ino
        ):
            raise ReleaseError(f"{label} must be a single-link regular file: {path}")
        if opened.st_size > maximum_bytes:
            raise ReleaseError(
                f"{label} exceeds its maximum size of {maximum_bytes} bytes: "
                f"{opened.st_size}"
            )
        return descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def _require_open_file_unchanged(path, descriptor, opened, action, label):
    try:
        current = os.fstat(descriptor)
        linked = Path(path).lstat()
    except OSError as error:
        raise ReleaseError(f"{label} changed while {action}: {path}") from error
    if (
        _file_state(current) != _file_state(opened)
        or current.st_dev != linked.st_dev
        or current.st_ino != linked.st_ino
        or not stat.S_ISREG(linked.st_mode)
        or linked.st_nlink != 1
    ):
        raise ReleaseError(f"{label} changed while {action}: {path}")


def _read_regular_file(path, maximum_bytes, label, _checkpoint=lambda _phase: None):
    """Read one private regular file without following links or accepting races."""
    path = Path(path)
    descriptor, opened = _open_bounded_regular_file(path, maximum_bytes, label)
    try:
        _checkpoint("after-open")
        _require_open_file_unchanged(path, descriptor, opened, "reading", label)
        remaining = opened.st_size
        chunks = []
        while remaining:
            block = os.read(descriptor, min(1024 * 1024, remaining))
            if not block:
                raise ReleaseError(f"{label} changed while reading: {path}")
            chunks.append(block)
            remaining -= len(block)
        if os.read(descriptor, 1):
            raise ReleaseError(f"{label} changed while reading: {path}")
        _checkpoint("after-read")
        _require_open_file_unchanged(path, descriptor, opened, "reading", label)
        return b"".join(chunks)
    finally:
        os.close(descriptor)


def _digest_regular_file(
    path,
    maximum_bytes=MAX_RELEASE_ARCHIVE_BYTES,
    label="release asset",
    _checkpoint=lambda _phase: None,
):
    path = Path(path)
    descriptor, opened = _open_bounded_regular_file(path, maximum_bytes, label)
    try:
        return _digest_open_regular_file(
            path,
            descriptor,
            opened,
            label,
            _checkpoint=_checkpoint,
        )
    finally:
        os.close(descriptor)


def _digest_open_regular_file(
    path,
    descriptor,
    opened,
    label,
    _checkpoint=lambda _phase: None,
):
    os.lseek(descriptor, 0, os.SEEK_SET)
    value = hashlib.sha256()
    _checkpoint("after-open")
    _require_open_file_unchanged(path, descriptor, opened, "hashing", label)
    remaining = opened.st_size
    while remaining:
        block = os.read(descriptor, min(1024 * 1024, remaining))
        if not block:
            raise ReleaseError(f"{label} changed while hashing: {path}")
        value.update(block)
        remaining -= len(block)
    if os.read(descriptor, 1):
        raise ReleaseError(f"{label} changed while hashing: {path}")
    _checkpoint("after-read")
    _require_open_file_unchanged(path, descriptor, opened, "hashing", label)
    return value.hexdigest(), opened.st_size


def digest(
    path,
    maximum_bytes=MAX_RELEASE_ARCHIVE_BYTES,
    _checkpoint=lambda _phase: None,
):
    return _digest_regular_file(
        path,
        maximum_bytes=maximum_bytes,
        _checkpoint=_checkpoint,
    )[0]


@contextmanager
def _verified_archive(archive, expected):
    """Keep one archive inode authoritative through hash, inspection, and extraction."""
    archive = Path(archive)
    descriptor, opened = _open_bounded_regular_file(
        archive,
        MAX_RELEASE_ARCHIVE_BYTES,
        "release archive",
    )
    try:
        archive_size = opened.st_size
        if archive_size <= 0:
            raise ReleaseError(
                f"release archive size is outside the allowed range: {archive_size}"
            )
        sha, _ = _digest_open_regular_file(
            archive,
            descriptor,
            opened,
            "release archive",
        )
        os.lseek(descriptor, 0, os.SEEK_SET)
        duplicate = os.dup(descriptor)
        try:
            stream = os.fdopen(duplicate, "rb")
            duplicate = -1
            with stream, zipfile.ZipFile(stream) as bundle:
                members = bundle.infolist()
                if not members or len(members) > MAX_RELEASE_ARCHIVE_ENTRIES:
                    raise ReleaseError(
                        f"release archive has an invalid entry count: {len(members)}")
                uncompressed_size = 0
                roots = set()
                names = set()
                for member in members:
                    member_path = PurePosixPath(member.filename)
                    if (
                        member_path.is_absolute()
                        or not member_path.parts
                        or ".." in member_path.parts
                        or "\x00" in member.filename
                    ):
                        raise ReleaseError(
                            f"release archive contains an unsafe path: {member.filename!r}")
                    if member.filename in names:
                        raise ReleaseError(
                            f"release archive contains a duplicate path: {member.filename!r}")
                    names.add(member.filename)
                    roots.add(member_path.parts[0])
                    uncompressed_size += member.file_size
                    if uncompressed_size > MAX_RELEASE_UNCOMPRESSED_BYTES:
                        raise ReleaseError("release archive expands beyond the allowed size")
                    mode = (member.external_attr >> 16) & 0o177777
                    if stat.S_IFMT(mode) == stat.S_IFLNK:
                        if member.file_size > 4096:
                            raise ReleaseError(
                                f"release archive has an oversized symlink: {member.filename!r}")
                        try:
                            target = PurePosixPath(bundle.read(member).decode("utf-8"))
                        except UnicodeDecodeError as error:
                            raise ReleaseError(
                                f"release archive has an invalid symlink: {member.filename!r}") from error
                        if target.is_absolute():
                            raise ReleaseError(
                                f"release archive symlink escapes the app: {member.filename!r}")
                        normalized = list(member_path.parent.parts)
                        for part in target.parts:
                            if part in ("", "."):
                                continue
                            if part == "..":
                                if len(normalized) <= 1:
                                    raise ReleaseError(
                                        f"release archive symlink escapes the app: {member.filename!r}")
                                normalized.pop()
                            else:
                                normalized.append(part)
                        if not normalized or normalized[0] != "MarkDev.app":
                            raise ReleaseError(
                                f"release archive symlink escapes the app: {member.filename!r}")
                if roots != {"MarkDev.app"}:
                    raise ReleaseError(
                        f"release archive contains unexpected top-level entries: {sorted(roots)}")
                if not any(
                    PurePosixPath(member.filename).parts[:2]
                    == ("MarkDev.app", "Contents")
                    for member in members
                ):
                    raise ReleaseError("release archive does not contain MarkDev.app/Contents")
                corrupt_member = bundle.testzip()
                if corrupt_member is not None:
                    raise ReleaseError(f"archive CRC verification failed: {corrupt_member}")
        finally:
            if duplicate >= 0:
                os.close(duplicate)

        _require_open_file_unchanged(
            archive,
            descriptor,
            opened,
            "verifying",
            "release archive",
        )

        # Verification must not add transient children to an already-published
        # generation. A killed verifier therefore cannot make the exact published
        # inventory look corrupt on the next run. `ditto` reads the descriptor we
        # inspected, not a pathname that another process can swap between phases.
        with tempfile.TemporaryDirectory(prefix="markdev-release-verify-") as directory:
            extracted = Path(directory) / "extracted"
            os.lseek(descriptor, 0, os.SEEK_SET)
            run(
                "ditto",
                "-x",
                "-k",
                f"/dev/fd/{descriptor}",
                str(extracted),
                pass_fds=(descriptor,),
            )
            _require_open_file_unchanged(
                archive,
                descriptor,
                opened,
                "verifying",
                "release archive",
            )
            app = extracted / "MarkDev.app"
            if app.is_symlink() or not app.is_dir():
                raise ReleaseError(
                    "release archive does not contain a regular MarkDev.app bundle")
            verify_bundle(app, expected)

        yield sha, archive_size
        _require_open_file_unchanged(
            archive,
            descriptor,
            opened,
            "verifying",
            "release archive",
        )
    finally:
        os.close(descriptor)


def verify_archive(archive, expected):
    with _verified_archive(archive, expected) as result:
        return result


def asset_directory(tag):
    return Path("dist") / asset_stem(tag)


def asset_paths(tag, directory=None):
    stem = asset_stem(tag)
    root = asset_directory(tag) if directory is None else Path(directory)
    return [root / (stem + suffix) for suffix in ASSET_SUFFIXES]


def _ensure_real_directory(path, mode=0o755):
    try:
        path.mkdir(mode=mode)
    except FileExistsError:
        pass
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise ReleaseError(f"required directory disappeared: {path}") from error
    if not stat.S_ISDIR(info.st_mode):
        raise ReleaseError(f"expected a real directory, not a link or other object: {path}")


def _git_common_directory():
    value = run("git", "rev-parse", "--git-common-dir").stdout.strip()
    if not value:
        raise ReleaseError("git did not report a common metadata directory")
    path = Path(value)
    if not path.is_absolute():
        path = Path.cwd() / path
    path = Path(os.path.abspath(path))
    if not path.is_dir():
        raise ReleaseError(f"git common metadata directory is missing: {path}")
    return path


@contextmanager
def release_lock(tag):
    """Serialize every local and remote release operation for one tag."""
    stem = asset_stem(tag)
    lock_directory = _git_common_directory() / "markdev-release-locks"
    _ensure_real_directory(lock_directory, mode=0o700)
    lock_path = lock_directory / f"{stem}.lock"
    flags = os.O_RDWR | os.O_CREAT | getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(lock_path, flags, 0o600)
    acquired = False
    try:
        os.fchmod(descriptor, 0o600)
        opened = os.fstat(descriptor)
        linked = lock_path.lstat()
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_dev != linked.st_dev
            or opened.st_ino != linked.st_ino
            or opened.st_nlink != 1
        ):
            raise ReleaseError(f"release lock is not a private regular file: {lock_path}")

        deadline = time.monotonic() + RELEASE_LOCK_TIMEOUT_SECONDS
        while True:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                acquired = True
                break
            except OSError as error:
                if error.errno not in (errno.EACCES, errno.EAGAIN, errno.EWOULDBLOCK):
                    raise
                if time.monotonic() >= deadline:
                    raise ReleaseError(
                        f"release operation for {tag} is already in progress"
                    ) from error
                time.sleep(min(RELEASE_LOCK_POLL_SECONDS, max(0, deadline - time.monotonic())))
        yield
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _require_real_directory(path, label):
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise ReleaseError(f"missing {label}: {path}") from error
    if not stat.S_ISDIR(info.st_mode):
        raise ReleaseError(f"{label} must be a real directory: {path}")


def _require_private_regular_file(path, label):
    try:
        info = path.lstat()
    except FileNotFoundError as error:
        raise ReleaseError(f"missing {label}: {path}") from error
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise ReleaseError(f"{label} must be a single-link regular file: {path}")


def _fsync_file(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise ReleaseError(f"cannot publish non-private release asset: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _fsync_directory(path):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(path, flags)
    try:
        if not stat.S_ISDIR(os.fstat(descriptor).st_mode):
            raise ReleaseError(f"cannot synchronize non-directory: {path}")
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def _renameatx(source, destination, flags):
    if sys.platform != "darwin":
        raise ReleaseError("atomic release generation publication requires macOS")
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        renameatx_np = libc.renameatx_np
    except AttributeError as error:
        raise ReleaseError("macOS renameatx_np is unavailable") from error
    renameatx_np.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    renameatx_np.restype = ctypes.c_int
    result = renameatx_np(
        AT_FDCWD,
        os.fsencode(os.path.abspath(source)),
        AT_FDCWD,
        os.fsencode(os.path.abspath(destination)),
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), str(destination))


def _atomic_publish_generation(staging, destination):
    staging = Path(staging)
    destination = Path(destination)
    try:
        same_parent = os.path.samefile(staging.parent, destination.parent)
    except OSError as error:
        raise ReleaseError("cannot resolve the release publication directory") from error
    if not same_parent:
        raise ReleaseError("release generation must be published within one directory")
    _require_real_directory(staging, "staged release generation")
    try:
        destination_info = destination.lstat()
    except FileNotFoundError:
        flags = RENAME_EXCL
    else:
        if not stat.S_ISDIR(destination_info.st_mode):
            raise ReleaseError(
                f"published release generation must be a real directory: {destination}"
            )
        flags = RENAME_SWAP
    _renameatx(staging, destination, flags)
    _fsync_directory(destination.parent)


def _remove_stale_generation(path):
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    if stat.S_ISDIR(info.st_mode):
        shutil.rmtree(path)
    else:
        path.unlink()
    return True


def _required_manifest(expected, archive, sha):
    return {
        **expected,
        "architectures": list(RELEASE_ARCHITECTURES),
        "minimum_macos": RELEASE_MINIMUM_MACOS,
        "distribution": dict(AUTOMATED_DISTRIBUTION),
        "toolchain": dict(RELEASE_TOOLCHAIN),
        "archive": archive.name,
        "sha256": sha,
    }


def _unique_json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ReleaseError(f"release manifest contains duplicate JSON key: {key!r}")
        result[key] = value
    return result


def _reject_json_constant(value):
    raise ReleaseError(f"release manifest contains nonstandard JSON constant: {value}")


def _load_release_manifest(contents):
    try:
        source = contents.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ReleaseError("release manifest is not valid UTF-8") from error
    try:
        return json.loads(
            source,
            object_pairs_hook=_unique_json_object,
            parse_constant=_reject_json_constant,
        )
    except json.JSONDecodeError as error:
        raise ReleaseError(f"release manifest is not valid JSON: {error.msg}") from error


def _same_json_value(actual, expected):
    if type(actual) is not type(expected):
        return False
    if isinstance(expected, dict):
        return actual.keys() == expected.keys() and all(
            _same_json_value(actual[key], value) for key, value in expected.items()
        )
    if isinstance(expected, list):
        return len(actual) == len(expected) and all(
            _same_json_value(actual_item, expected_item)
            for actual_item, expected_item in zip(actual, expected)
        )
    return actual == expected


def _verify_generation(directory, tag, expected):
    directory = Path(directory)
    _require_real_directory(directory, "published release generation")
    archive, checksum, manifest = asset_paths(tag, directory)
    expected_names = {path.name for path in (archive, checksum, manifest)}
    actual_names = set()
    for path in directory.iterdir():
        if path.name not in expected_names or len(actual_names) >= len(expected_names):
            raise ReleaseError(
                "release generation has an unexpected inventory: "
                f"expected exactly {sorted(expected_names)}"
            )
        actual_names.add(path.name)
    if actual_names != expected_names:
        raise ReleaseError(
            "release generation has an unexpected inventory: "
            f"expected {sorted(expected_names)}, found {sorted(actual_names)}"
        )
    for path, label in (
        (archive, "release archive"),
        (checksum, "release checksum"),
        (manifest, "release manifest"),
    ):
        _require_private_regular_file(path, label)
    with _verified_archive(archive, expected) as (sha, archive_size):
        if archive_size <= 0 or archive_size > MAX_RELEASE_ARCHIVE_BYTES:
            raise ReleaseError(
                f"release archive size is outside the allowed range: {archive_size}"
            )
        checksum_contents = _read_regular_file(
            checksum,
            MAX_RELEASE_CHECKSUM_BYTES,
            "release checksum",
        )
        manifest_contents = _read_regular_file(
            manifest,
            MAX_RELEASE_MANIFEST_BYTES,
            "release manifest",
        )
        recorded = _load_release_manifest(manifest_contents)
        required = _required_manifest(expected, archive, sha)
        try:
            recorded_checksum = checksum_contents.decode("utf-8")
        except UnicodeDecodeError as error:
            raise ReleaseError("release checksum is not valid UTF-8") from error
        if (
            not _same_json_value(recorded, required)
            or recorded_checksum != f"{sha}  {archive.name}\n"
        ):
            raise ReleaseError(
                "staged assets do not match the checked-out release or checksum")
    return expected


def _stale_generation_paths(tag):
    dist = Path("dist")
    prefix = f".stage-{asset_stem(tag)}."
    expected_names = {path.name for path in asset_paths(tag, dist)}
    matches = []
    total_bytes = 0
    with os.scandir(dist) as entries:
        entry_count = 0
        for entry in entries:
            entry_count += 1
            if entry_count > MAX_DIST_ENTRIES:
                raise ReleaseError(
                    "distribution directory has too many entries; refusing release recovery"
                )
            if not entry.name.startswith(prefix):
                continue
            if len(matches) >= MAX_STALE_GENERATIONS_PER_TAG:
                raise ReleaseError(
                    f"too many stale release generations for {tag}; refusing cleanup"
                )
            info = entry.stat(follow_symlinks=False)
            if not stat.S_ISDIR(info.st_mode):
                raise ReleaseError(
                    f"stale release generation is not a real directory: {entry.path}"
                )
            candidate = Path(entry.path)
            with os.scandir(candidate) as children:
                child_count = 0
                for child in children:
                    child_count += 1
                    child_info = child.stat(follow_symlinks=False)
                    if (
                        child_count > len(expected_names)
                        or child.name not in expected_names
                        or not stat.S_ISREG(child_info.st_mode)
                        or child_info.st_nlink != 1
                    ):
                        raise ReleaseError(
                            "stale release generation contains an unexpected object: "
                            f"{child.path}"
                        )
                    total_bytes += child_info.st_size
                    if total_bytes > MAX_STALE_BYTES_PER_TAG:
                        raise ReleaseError(
                            f"stale release generations for {tag} exceed the size limit"
                        )
            matches.append(candidate)
    return sorted(matches, key=lambda path: path.name)


def _recover_stale_generations(tag, expected):
    """Recover one complete generation and discard tag-scoped crash debris."""
    dist = Path("dist")
    _ensure_real_directory(dist)
    destination = asset_directory(tag)
    stale = _stale_generation_paths(tag)
    if not stale:
        try:
            destination_info = destination.lstat()
        except FileNotFoundError:
            return
        if not stat.S_ISDIR(destination_info.st_mode):
            raise ReleaseError(
                f"published release generation must be a real directory: {destination}"
            )
        return

    try:
        destination.lstat()
    except FileNotFoundError:
        pass
    else:
        _require_real_directory(destination, "published release generation")
        # If a published generation exists, prove it is complete before
        # discarding any possible recovery material. Dependency failures and
        # corrupt external mutations therefore preserve every candidate.
        _verify_generation(destination, tag, expected)
        removed = False
        for candidate in stale:
            removed = _remove_stale_generation(candidate) or removed
        if removed:
            _fsync_directory(dist)
        return

    expected_names = {path.name for path in asset_paths(tag, dist)}
    full_shape = []
    partial = []
    for candidate in stale:
        names = {path.name for path in candidate.iterdir()}
        (full_shape if names == expected_names else partial).append(candidate)

    complete = []
    failures = []
    for candidate in full_shape:
        try:
            _verify_generation(candidate, tag, expected)
        except (
            ReleaseError,
            OSError,
            ValueError,
            KeyError,
            TypeError,
            zipfile.BadZipFile,
            subprocess.TimeoutExpired,
        ) as error:
            failures.append(error)
        else:
            complete.append(candidate)

    selected = None
    if complete:
        selected = max(
            complete,
            key=lambda path: (path.lstat().st_mtime_ns, path.name),
        )
        _atomic_publish_generation(selected, destination)

    removed = False
    removable = stale if selected is not None else partial
    for candidate in removable:
        if candidate == selected and not candidate.exists():
            continue
        removed = _remove_stale_generation(candidate) or removed
    if removed:
        _fsync_directory(dist)
    if selected is None and full_shape:
        raise ReleaseError(
            f"no complete stale release generation for {tag} could be validated"
        ) from failures[0]


def _publication_checkpoint(_phase):
    """Fault-injection seam for crash-consistency tests."""


def stage(tag):
    with release_lock(tag):
        return _stage_locked(tag)


def _stage_locked(tag):
    expected = preflight(tag)
    _recover_stale_generations(tag, expected)
    settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-scheme", "MarkDev",
                              *LOCKED_PACKAGE_FLAGS, "-configuration", "Release", "-derivedDataPath",
                              RELEASE_DERIVED_DATA,
                              "-showBuildSettings", "-json").stdout)
    targets = [item for item in settings if item.get("target") == "MarkDev"]
    if len(targets) != 1:
        raise ReleaseError("build settings must contain exactly one MarkDev target")
    build_settings = targets[0]["buildSettings"]
    if build_settings.get("ONLY_ACTIVE_ARCH") != "NO":
        raise ReleaseError("Release ONLY_ACTIVE_ARCH must be NO")
    if build_settings.get("MACOSX_DEPLOYMENT_TARGET") != RELEASE_MINIMUM_MACOS:
        raise ReleaseError(
            "Release MACOSX_DEPLOYMENT_TARGET must match the declared minimum macOS"
        )
    require_exact_release_architectures(
        build_settings.get("ARCHS", "").split(),
        "Release ARCHS",
    )
    products = build_settings["BUILT_PRODUCTS_DIR"]
    if not products or not Path(products).is_absolute():
        raise ReleaseError("BUILT_PRODUCTS_DIR must be an absolute directory")
    app = Path(products) / "MarkDev.app"
    verify_bundle(app, expected)
    dist = Path("dist")
    _ensure_real_directory(dist)
    directory = tempfile.mkdtemp(prefix=f".stage-{asset_stem(tag)}.", dir=dist)
    staging = Path(directory)
    # This is deliberately not a TemporaryDirectory: if the process fails, a
    # later locked operation validates the tag-scoped generation before either
    # recovering or removing it.
    archive, checksum, manifest = asset_paths(tag, staging)
    run("ditto", "-c", "-k", "--keepParent", str(app), str(archive))
    _require_private_regular_file(archive, "release archive")
    archive_size = archive.stat().st_size
    if archive_size <= 0 or archive_size > MAX_RELEASE_ARCHIVE_BYTES:
        raise ReleaseError(
            f"release archive size is outside the allowed range: {archive_size}"
        )
    _publication_checkpoint("archive-ready")
    sha = digest(archive)
    checksum.write_text(f"{sha}  {archive.name}\n")
    _publication_checkpoint("checksum-ready")
    manifest.write_text(
        json.dumps(_required_manifest(expected, archive, sha), indent=2) + "\n"
    )
    _publication_checkpoint("manifest-ready")
    _verify_generation(staging, tag, expected)
    for path in (archive, checksum, manifest):
        _fsync_file(path)
    _fsync_directory(staging)
    _fsync_directory(dist)
    # Detect edits or a moved tag after the generation is durable but before
    # the one atomic namespace transition.
    if preflight(tag) != expected:
        raise ReleaseError("source changed while packaging")
    _publication_checkpoint("before-publish")
    _atomic_publish_generation(staging, asset_directory(tag))
    _publication_checkpoint("after-publish")
    # A swap leaves the old generation at the staging name. Revalidate its
    # bounded, generated-only shape before recursively removing it.
    _stale_generation_paths(tag)
    if _remove_stale_generation(staging):
        _fsync_directory(dist)
    _verify_assets_locked(tag)
    print(f"staged {asset_paths(tag)[0]} ({expected['commit']}, build {expected['build']})")


def verify_assets(tag):
    with release_lock(tag):
        return _verify_assets_locked(tag)


def _verify_assets_locked(tag):
    expected = preflight(tag)
    _recover_stale_generations(tag, expected)
    return _verify_generation(asset_directory(tag), tag, expected)


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


def asset_snapshot(paths):
    return {
        path.name: {
            "size": path.stat().st_size,
            "digest": "sha256:" + digest(path),
        }
        for path in paths
    }


def require_unchanged_assets(paths, expected):
    if asset_snapshot(paths) != expected:
        raise ReleaseError("local release assets changed during the remote operation")


def verify_remote_assets(release, expected, require_all=True):
    seen = set()
    for asset in release["assets"]:
        name = asset["name"]
        if name not in expected or name in seen:
            raise ReleaseError(f"unexpected or duplicate remote asset: {name}")
        recorded = expected[name]
        if (asset.get("state") != "uploaded" or asset.get("size") != recorded["size"]
                or asset.get("digest") != recorded["digest"]):
            raise ReleaseError(f"remote asset differs or upload is incomplete: {name}; refusing to overwrite")
        seen.add(name)
    if require_all and seen != set(expected):
        raise ReleaseError("release is missing required assets")
    return seen


def draft(tag):
    with release_lock(tag):
        return _draft_locked(tag)


def _draft_locked(tag):
    expected = _verify_assets_locked(tag)
    paths = asset_paths(tag)
    frozen_assets = asset_snapshot(paths)
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
    require_unchanged_assets(paths, frozen_assets)
    seen = verify_remote_assets(release, frozen_assets, require_all=False)
    missing = [str(path) for path in paths if path.name not in seen]
    if missing:
        _verify_assets_locked(tag)
        require_unchanged_assets(paths, frozen_assets)
        release_view(tag)  # Recheck the draft boundary immediately before writing.
        run("gh", "release", "upload", tag, *missing, timeout=600)
    _verify_assets_locked(tag)
    require_unchanged_assets(paths, frozen_assets)
    release = release_view(tag)
    verify_remote_assets(release, frozen_assets)
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
