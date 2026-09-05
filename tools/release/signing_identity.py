#!/usr/bin/env python3
"""Resolve one codesigning identity and verify the exact signed Release bundle."""

import argparse
import hashlib
import os
from pathlib import Path
import plistlib
from pathlib import PurePosixPath
import re
import ssl
import stat
import subprocess
import sys
import tempfile

from release import (
    RELEASE_ARCHITECTURES,
    ReleaseError,
    metadata,
    run as release_run,
    verify_bundle,
)


IDENTITY_LINE = re.compile(
    r'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"(.*)"\s*$'
)
PEM_CERTIFICATE = re.compile(
    r"-----BEGIN CERTIFICATE-----\s+.*?\s+-----END CERTIFICATE-----",
    re.DOTALL,
)
IDENTITY_CLASSES = {"Apple Development", "Developer ID Application"}
MAX_CERTIFICATE_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_EMBEDDED_CERTIFICATE_BYTES = 1024 * 1024
MAX_RESTORABLE_ENTRIES = 200_000
MAX_RESTORABLE_BYTES = 1024 * 1024 * 1024
MAX_RESTORABLE_DEPTH = 128
MAX_RESTORABLE_PLIST_BYTES = 4 * 1024 * 1024
MAX_RESTORABLE_SYMLINK_BYTES = 4096
MAX_ARCHITECTURE_OUTPUT_BYTES = 1024
RESTORABLE_ARCHITECTURES = frozenset(("arm64", "x86_64"))
MAIN_BUNDLE_ID = "dev.markdev.MarkDev"
QUICKLOOK_BUNDLE_ID = "dev.markdev.MarkDev.QuickLook"


class SigningIdentityError(Exception):
    pass


def command(*args, input_text=None, timeout=30):
    result = subprocess.run(
        args,
        input=input_text,
        text=True,
        capture_output=True,
        timeout=timeout,
    )
    if result.returncode:
        detail = result.stderr.strip() or result.stdout.strip()
        raise SigningIdentityError(f"{args[0]} failed ({result.returncode}): {detail}")
    return result


def parse_valid_identities(output):
    identities = []
    for line in output.splitlines():
        match = IDENTITY_LINE.fullmatch(line)
        if match is not None:
            identities.append((match.group(1).upper(), match.group(2)))
    return identities


def choose_identity(selector, identities):
    if re.fullmatch(r"[0-9A-Fa-f]{40}", selector):
        matches = [item for item in identities if item[0] == selector.upper()]
    elif selector in IDENTITY_CLASSES:
        matches = [item for item in identities if item[1].startswith(selector + ": ")]
    else:
        matches = [item for item in identities if item[1] == selector]
    if len(matches) != 1:
        raise SigningIdentityError(
            f"signing selector must resolve to exactly one valid identity; found {len(matches)}"
        )
    return matches[0]


def certificate_blocks(output):
    if len(output.encode("utf-8")) > MAX_CERTIFICATE_OUTPUT_BYTES:
        raise SigningIdentityError("keychain certificate output exceeds the safety limit")
    return PEM_CERTIFICATE.findall(output)


def certificate_fingerprint(pem):
    try:
        der = ssl.PEM_cert_to_DER_cert(pem)
    except ValueError as error:
        raise SigningIdentityError("security returned an invalid PEM certificate") from error
    return hashlib.sha1(der).hexdigest().upper()


def certificate_for_fingerprint(output, fingerprint):
    matches = [
        pem for pem in certificate_blocks(output)
        if certificate_fingerprint(pem) == fingerprint.upper()
    ]
    if len(matches) != 1:
        raise SigningIdentityError(
            f"valid identity certificate must appear exactly once in the keychain; found {len(matches)}"
        )
    return matches[0]


def team_identifier(pem):
    subject = command(
        "/usr/bin/openssl", "x509", "-noout", "-subject", "-nameopt", "RFC2253",
        input_text=pem,
    ).stdout.strip()
    subject = re.sub(r"^subject\s*=\s*", "", subject)
    teams = re.findall(r"(?:^|,)OU=([A-Z0-9]{10})(?=,|$)", subject)
    if len(teams) != 1:
        raise SigningIdentityError(
            f"signing certificate must contain one ten-character team identifier; found {len(teams)}"
        )
    return teams[0]


def resolve(selector):
    if not selector:
        raise SigningIdentityError("signing selector must not be empty")
    identities = parse_valid_identities(
        command("/usr/bin/security", "find-identity", "-v", "-p", "codesigning").stdout
    )
    fingerprint, name = choose_identity(selector, identities)
    certificates = command("/usr/bin/security", "find-certificate", "-a", "-p").stdout
    certificate = certificate_for_fingerprint(certificates, fingerprint)
    return fingerprint, team_identifier(certificate), name


def signature_profile(path, architecture):
    result = command(
        "/usr/bin/codesign", "--display", "--arch", architecture, "--verbose=4", str(path)
    )
    output = result.stdout + result.stderr
    ad_hoc_signatures = re.findall(r"(?m)^Signature=(adhoc)$", output)
    certificate_signatures = re.findall(r"(?m)^Signature size=([0-9]+)$", output)
    flags = re.findall(r"(?m)^CodeDirectory\b[^\n]*\bflags=([^\s]+)", output)
    teams = re.findall(r"(?m)^TeamIdentifier=([^\n]+)$", output)
    if len(ad_hoc_signatures) + len(certificate_signatures) != 1 or len(flags) != 1 or len(teams) != 1:
        raise SigningIdentityError(
            f"codesign returned an ambiguous {architecture} profile for {path}"
        )
    signature = "adhoc" if ad_hoc_signatures else "size=" + certificate_signatures[0]
    return signature, flags[0], teams[0]


def embedded_leaf_fingerprint(path, architecture):
    with tempfile.TemporaryDirectory(prefix="markdev-signature-") as directory:
        prefix = str(Path(directory) / "certificate")
        command(
            "/usr/bin/codesign", "--display", "--arch", architecture,
            "--extract-certificates", prefix, str(path),
        )
        leaf = Path(prefix + "0")
        if leaf.is_symlink() or not leaf.is_file():
            raise SigningIdentityError(
                f"codesign did not extract a {architecture} leaf certificate for {path}"
            )
        certificate = _read_bounded_regular_file(
            leaf,
            f"extracted {architecture} signing certificate",
            MAX_EMBEDDED_CERTIFICATE_BYTES,
        )
        return hashlib.sha1(certificate).hexdigest().upper()


def verify_exact_signature(path, fingerprint, team):
    for architecture in RELEASE_ARCHITECTURES:
        signature, flags, actual_team = signature_profile(path, architecture)
        if signature == "adhoc":
            raise SigningIdentityError(
                f"signed Release {architecture} slice is still ad-hoc: {path}"
            )
        if actual_team != team:
            raise SigningIdentityError(
                f"signed Release {architecture} team mismatch for {path}: {actual_team!r}"
            )
        if "runtime" not in flags:
            raise SigningIdentityError(
                f"hardened runtime is missing from the {architecture} slice of {path}"
            )

        actual = embedded_leaf_fingerprint(path, architecture)
        if actual != fingerprint.upper():
            raise SigningIdentityError(
                f"signed Release {architecture} certificate mismatch for {path}: {actual}"
            )


def _same_file(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _stable_metadata(left, right):
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    return all(getattr(left, name) == getattr(right, name) for name in fields)


def _read_bounded_regular_file(path, owner, limit):
    path = Path(path)
    try:
        before = path.lstat()
    except OSError as error:
        raise SigningIdentityError(f"{owner} is unavailable: {path}") from error
    if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > limit:
        raise SigningIdentityError(f"{owner} is not a bounded single-link regular file: {path}")
    descriptor = None
    try:
        descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
        opened = os.fstat(descriptor)
        if not _same_file(before, opened):
            raise SigningIdentityError(f"{owner} changed while it was opened: {path}")
        blocks = []
        total = 0
        while total <= limit:
            block = os.read(descriptor, min(1024 * 1024, limit + 1 - total))
            if not block:
                break
            blocks.append(block)
            total += len(block)
        if total > limit:
            raise SigningIdentityError(f"{owner} exceeds its safety limit: {path}")
        after = os.fstat(descriptor)
        current = path.lstat()
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(opened, name) != getattr(after, name) for name in fields):
            raise SigningIdentityError(f"{owner} changed while it was read: {path}")
        if not _same_file(after, current):
            raise SigningIdentityError(f"{owner} path changed while it was read: {path}")
        return b"".join(blocks)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _bundle_plist(path, owner):
    try:
        value = plistlib.loads(
            _read_bounded_regular_file(path, owner, MAX_RESTORABLE_PLIST_BYTES)
        )
    except plistlib.InvalidFileException as error:
        raise SigningIdentityError(f"{owner} is not a valid plist: {path}") from error
    if not isinstance(value, dict):
        raise SigningIdentityError(f"{owner} root is not a dictionary: {path}")
    return value


def _require_real_directory(path, owner):
    path = Path(path)
    try:
        status = path.lstat()
    except OSError as error:
        raise SigningIdentityError(f"{owner} is unavailable: {path}") from error
    if not stat.S_ISDIR(status.st_mode):
        raise SigningIdentityError(f"{owner} is not a real directory: {path}")
    return status


def _require_executable(path, owner):
    status = Path(path).lstat()
    if not stat.S_ISREG(status.st_mode) or status.st_nlink != 1:
        raise SigningIdentityError(f"{owner} is not a single-link regular file: {path}")
    if not status.st_mode & stat.S_IXUSR:
        raise SigningIdentityError(f"{owner} is not executable: {path}")


def _require_identity_fields(info, expected, owner):
    for key, value in expected.items():
        if info.get(key) != value:
            raise SigningIdentityError(
                f"{owner} {key} is {info.get(key)!r}; expected {value!r}"
            )


def _validate_restorable_layout(app):
    app = Path(app)
    _require_real_directory(app, "restorable MarkDev app")
    contents = app / "Contents"
    _require_real_directory(contents, "restorable MarkDev Contents")
    main_info = _bundle_plist(contents / "Info.plist", "restorable MarkDev metadata")
    _require_identity_fields(
        main_info,
        {
            "CFBundleIdentifier": MAIN_BUNDLE_ID,
            "CFBundleExecutable": "MarkDev",
            "CFBundlePackageType": "APPL",
        },
        "restorable MarkDev",
    )
    for key in ("CFBundleShortVersionString", "CFBundleVersion"):
        value = main_info.get(key)
        if not isinstance(value, str) or not value or len(value.encode("utf-8")) > 256:
            raise SigningIdentityError(f"restorable MarkDev has an invalid {key}")
    main_executable = contents / "MacOS/MarkDev"
    _require_executable(main_executable, "restorable MarkDev executable")
    owned = [(app, main_executable)]

    appex = contents / "PlugIns/MarkDevQuickLook.appex"
    if not os.path.lexists(appex):
        return tuple(owned)
    _require_real_directory(appex, "restorable Quick Look extension")
    appex_info = _bundle_plist(
        appex / "Contents/Info.plist", "restorable Quick Look metadata"
    )
    _require_identity_fields(
        appex_info,
        {
            "CFBundleIdentifier": QUICKLOOK_BUNDLE_ID,
            "CFBundleExecutable": "MarkDevQuickLook",
            "CFBundlePackageType": "XPC!",
        },
        "restorable Quick Look extension",
    )
    extension = appex_info.get("NSExtension")
    if (
        not isinstance(extension, dict)
        or extension.get("NSExtensionPointIdentifier") != "com.apple.quicklook.preview"
    ):
        raise SigningIdentityError(
            "restorable Quick Look extension has the wrong extension point"
        )
    appex_executable = appex / "Contents/MacOS/MarkDevQuickLook"
    _require_executable(appex_executable, "restorable Quick Look executable")
    owned.append((appex, appex_executable))
    return tuple(owned)


def parse_restorable_architectures(output, owner):
    if not isinstance(output, bytes) or len(output) > MAX_ARCHITECTURE_OUTPUT_BYTES:
        raise SigningIdentityError(
            f"{owner} architecture inventory exceeds its safety limit"
        )
    if re.fullmatch(rb"(?:arm64|x86_64)(?: (?:arm64|x86_64))*\n?", output) is None:
        raise SigningIdentityError(f"{owner} has an invalid Mach-O architecture inventory")
    try:
        architectures = tuple(output.rstrip(b"\n").decode("ascii").split(" "))
    except UnicodeDecodeError as error:
        raise SigningIdentityError(
            f"{owner} has a non-ASCII Mach-O architecture inventory"
        ) from error
    if (
        not architectures
        or len(set(architectures)) != len(architectures)
        or any(item not in RESTORABLE_ARCHITECTURES for item in architectures)
    ):
        raise SigningIdentityError(f"{owner} has an unsupported Mach-O slice set")
    return architectures


def _bounded_command_output(command_args, owner, limit, timeout=30):
    with tempfile.TemporaryFile() as standard_output, tempfile.TemporaryFile() as standard_error:
        try:
            result = subprocess.run(
                command_args,
                stdout=standard_output,
                stderr=standard_error,
                timeout=timeout,
                check=False,
            )
        except subprocess.TimeoutExpired as error:
            raise SigningIdentityError(f"{owner} inspection timed out") from error

        standard_output.seek(0)
        output = standard_output.read(limit + 1)
        standard_error.seek(0)
        error_output = standard_error.read(limit + 1)
        if len(output) > limit or len(error_output) > limit:
            raise SigningIdentityError(f"{owner} inspection output exceeds its safety limit")
        if result.returncode:
            detail = (error_output or output).decode("utf-8", errors="replace").strip()
            raise SigningIdentityError(
                f"{owner} inspection failed ({result.returncode}): {detail}"
            )
        return output


def executable_architectures(path):
    path = Path(path)
    output = _bounded_command_output(
        ("/usr/bin/lipo", "-archs", str(path)),
        f"restorable executable {path}",
        MAX_ARCHITECTURE_OUTPUT_BYTES,
    )
    return parse_restorable_architectures(output, f"restorable executable {path}")


def verify_restorable_signature(app):
    app = Path(app)
    owned = _validate_restorable_layout(app)
    command(
        "/usr/bin/codesign",
        "--verify",
        "--all-architectures",
        "--deep",
        "--strict=all",
        str(app),
    )
    for bundle, executable in owned:
        architectures = executable_architectures(executable)
        profiles = [signature_profile(bundle, architecture) for architecture in architectures]
        signatures = [profile[0] for profile in profiles]
        teams = {profile[2] for profile in profiles}
        if signatures == ["adhoc"] * len(architectures):
            if teams != {"not set"}:
                raise SigningIdentityError(
                    f"ad-hoc restorable bundle has an unexpected team identity: {bundle}"
                )
            continue
        if "adhoc" in signatures or len(teams) != 1 or "not set" in teams:
            raise SigningIdentityError(
                f"restorable signature kind or team differs between slices: {bundle}"
            )
        fingerprints = {
            embedded_leaf_fingerprint(bundle, architecture)
            for architecture in architectures
        }
        if len(fingerprints) != 1:
            raise SigningIdentityError(
                f"restorable certificate differs between slices: {bundle}"
            )


def _commitment_field(digest, kind, path, payload=b""):
    for value in (kind, os.fsencode(path), payload):
        digest.update(len(value).to_bytes(8, "big"))
        digest.update(value)


def _safe_symlink_target(relative, target):
    target_path = PurePosixPath(target)
    if target_path.is_absolute() or len(os.fsencode(target)) > MAX_RESTORABLE_SYMLINK_BYTES:
        return False
    depth = len(PurePosixPath(relative).parent.parts)
    for component in target_path.parts:
        if component in ("", "."):
            continue
        if component == "..":
            depth -= 1
            if depth < 0:
                return False
        else:
            depth += 1
    return True


def _manifest_directory(descriptor, relative, digest, accounting, depth=0):
    if depth > MAX_RESTORABLE_DEPTH:
        raise SigningIdentityError("restorable bundle exceeds its directory depth limit")
    directory_before = os.fstat(descriptor)
    observed = []
    with os.scandir(descriptor) as entries:
        for entry in entries:
            accounting["entries"] += 1
            if accounting["entries"] > MAX_RESTORABLE_ENTRIES:
                raise SigningIdentityError("restorable bundle contains too many entries")
            observed.append(entry.name)
    for name in sorted(observed, key=os.fsencode):
        child_relative = (
            PurePosixPath(name)
            if relative == PurePosixPath(".")
            else relative / name
        )
        status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        mode = stat.S_IMODE(status.st_mode).to_bytes(4, "big")
        if stat.S_ISDIR(status.st_mode):
            _commitment_field(digest, b"directory", str(child_relative), mode)
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if not _stable_metadata(status, opened):
                    raise SigningIdentityError(
                        f"restorable directory changed while it was opened: {child_relative}"
                    )
                _manifest_directory(
                    child, child_relative, digest, accounting, depth + 1
                )
                after = os.fstat(child)
                named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not _stable_metadata(opened, after) or not _same_file(after, named):
                    raise SigningIdentityError(
                        f"restorable directory changed while it was hashed: {child_relative}"
                    )
            finally:
                os.close(child)
        elif stat.S_ISREG(status.st_mode):
            if status.st_nlink != 1:
                raise SigningIdentityError(
                    f"restorable file has multiple links: {child_relative}"
                )
            accounting["bytes"] += status.st_size
            if accounting["bytes"] > MAX_RESTORABLE_BYTES:
                raise SigningIdentityError("restorable bundle exceeds its byte limit")
            _commitment_field(
                digest,
                b"file",
                str(child_relative),
                mode + status.st_size.to_bytes(8, "big"),
            )
            child = os.open(
                name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                opened = os.fstat(child)
                if not _stable_metadata(status, opened):
                    raise SigningIdentityError(
                        f"restorable file changed while it was opened: {child_relative}"
                    )
                remaining = opened.st_size
                while remaining:
                    block = os.read(child, min(1024 * 1024, remaining))
                    if not block or len(block) > remaining:
                        raise SigningIdentityError(
                            f"restorable file changed size while it was hashed: {child_relative}"
                        )
                    digest.update(block)
                    remaining -= len(block)
                if os.read(child, 1):
                    raise SigningIdentityError(
                        f"restorable file grew while it was hashed: {child_relative}"
                    )
                after = os.fstat(child)
                fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
                if any(getattr(opened, name) != getattr(after, name) for name in fields):
                    raise SigningIdentityError(
                        f"restorable file changed while it was hashed: {child_relative}"
                    )
                named = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
                if not _same_file(after, named):
                    raise SigningIdentityError(
                        f"restorable file path changed while it was hashed: {child_relative}"
                    )
            finally:
                os.close(child)
        elif stat.S_ISLNK(status.st_mode):
            target = os.readlink(name, dir_fd=descriptor)
            if not _safe_symlink_target(child_relative, target):
                raise SigningIdentityError(
                    f"restorable symlink escapes or exceeds its limit: {child_relative}"
                )
            _commitment_field(
                digest, b"symlink", str(child_relative), os.fsencode(target)
            )
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not _stable_metadata(status, current) or os.readlink(
                name, dir_fd=descriptor
            ) != target:
                raise SigningIdentityError(
                    f"restorable symlink changed while it was hashed: {child_relative}"
                )
        else:
            raise SigningIdentityError(
                f"restorable bundle contains a special file: {child_relative}"
            )
    directory_after = os.fstat(descriptor)
    if not _stable_metadata(directory_before, directory_after):
        raise SigningIdentityError(
            f"restorable directory changed while it was enumerated: {relative}"
        )


def bundle_commitment(app):
    app = Path(app)
    before = _require_real_directory(app, "restorable MarkDev app")
    descriptor = os.open(
        app,
        os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
    try:
        opened = os.fstat(descriptor)
        if not _stable_metadata(before, opened):
            raise SigningIdentityError("restorable app changed while it was opened")
        digest = hashlib.sha256()
        _commitment_field(
            digest,
            b"root",
            ".",
            stat.S_IMODE(before.st_mode).to_bytes(4, "big"),
        )
        _manifest_directory(
            descriptor,
            PurePosixPath("."),
            digest,
            {"entries": 0, "bytes": 0},
        )
        after = os.fstat(descriptor)
        current = app.lstat()
        if not _stable_metadata(opened, after) or not _stable_metadata(after, current):
            raise SigningIdentityError("restorable app root changed while it was hashed")
        return digest.hexdigest()
    finally:
        os.close(descriptor)


def verify_restorable(app):
    app = Path(app)
    if not app.is_absolute():
        raise SigningIdentityError(f"restorable app path must be absolute: {app}")
    _validate_restorable_layout(app)
    before = bundle_commitment(app)
    verify_restorable_signature(app)
    _validate_restorable_layout(app)
    after = bundle_commitment(app)
    if before != after:
        raise SigningIdentityError(
            "restorable app changed between content commitment and signature verification"
        )
    return after


def current_release_metadata():
    source = Path("project.yml").read_text()
    versions = re.findall(
        r'^\s*MARKETING_VERSION:\s*"([^"\n]+)"\s*(?:#.*)?$',
        source,
        re.MULTILINE,
    )
    if len(versions) != 1:
        raise SigningIdentityError("project.yml must contain one quoted MARKETING_VERSION")
    expected = metadata("v" + versions[0])
    expected["commit"] = release_run("git", "rev-parse", "HEAD").stdout.strip()
    return expected


def verify(app, fingerprint, team):
    if not re.fullmatch(r"[0-9A-Fa-f]{40}", fingerprint):
        raise SigningIdentityError("expected signing fingerprint must be forty hexadecimal characters")
    if not re.fullmatch(r"[A-Z0-9]{10}", team):
        raise SigningIdentityError("expected signing team must be ten uppercase letters or digits")
    app = Path(app)
    command(
        "/usr/bin/codesign", "--verify", "--all-architectures", "--deep", "--strict=all",
        str(app),
    )
    verify_bundle(
        app,
        current_release_metadata(),
        signature_verifier=lambda bundle: verify_exact_signature(bundle, fingerprint, team),
    )


def verify_installable(app):
    app = Path(app)
    profiles = [signature_profile(app, architecture) for architecture in RELEASE_ARCHITECTURES]
    signatures = [profile[0] for profile in profiles]
    if signatures == ["adhoc"] * len(RELEASE_ARCHITECTURES):
        verify_bundle(app, current_release_metadata())
        return "ad-hoc"
    if "adhoc" in signatures:
        raise SigningIdentityError("Release signature kind differs between architecture slices")
    teams = {profile[2] for profile in profiles}
    if len(teams) != 1 or "not set" in teams:
        raise SigningIdentityError("Release signing team differs between architecture slices")
    fingerprints = {
        embedded_leaf_fingerprint(app, architecture)
        for architecture in RELEASE_ARCHITECTURES
    }
    if len(fingerprints) != 1:
        raise SigningIdentityError("Release signing certificate differs between architecture slices")
    fingerprint = fingerprints.pop()
    team = teams.pop()
    verify(app, fingerprint, team)
    return f"certificate {fingerprint} team {team} with hardened runtime"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    resolve_parser = subparsers.add_parser("resolve")
    resolve_parser.add_argument("selector")
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("app")
    verify_parser.add_argument("fingerprint")
    verify_parser.add_argument("team")
    installable_parser = subparsers.add_parser("verify-installable")
    installable_parser.add_argument("app")
    restorable_parser = subparsers.add_parser("verify-restorable")
    restorable_parser.add_argument("app")
    args = parser.parse_args()
    try:
        if args.command == "resolve":
            fingerprint, team, _ = resolve(args.selector)
            print(f"{fingerprint}\t{team}")
        elif args.command == "verify":
            verify(args.app, args.fingerprint, args.team)
            print(f"verified exact signing identity {args.fingerprint.upper()} (team {args.team})")
        elif args.command == "verify-installable":
            profile = verify_installable(args.app)
            print(f"verified installable Release profile: {profile}")
        else:
            print(verify_restorable(args.app))
    except (
        OSError,
        ReleaseError,
        SigningIdentityError,
        subprocess.TimeoutExpired,
        ValueError,
    ) as error:
        print(f"signing identity: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
