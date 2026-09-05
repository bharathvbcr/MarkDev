#!/usr/bin/env python3
"""Fail-closed verification of MarkDev's installed Quick Look registration."""

from dataclasses import dataclass
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time


BUNDLE_ID = "dev.markdev.MarkDev.QuickLook"
EXPECTED_CONTENT_TYPES = (
    ("md", "net.daringfireball.markdown"),
    ("markdown", "net.daringfireball.markdown"),
    ("mdown", "dev.markdev.markdown-extended"),
    ("mdx", "dev.markdev.markdown-extended"),
    ("mkd", "dev.markdev.markdown-extended"),
    ("markdn", "dev.markdev.markdown-extended"),
)
PLUGIN_KIT = "/usr/bin/pluginkit"
MDLS = "/usr/bin/mdls"
COMMAND_TIMEOUT_SECONDS = 3.0
INSTALL_ATTEMPTS = 21
INSTALL_RETRY_DELAY_SECONDS = 0.5
INSTALL_OVERALL_TIMEOUT_SECONDS = 15.0


class QuickLookVerificationError(RuntimeError):
    """The installed extension does not satisfy the Quick Look contract."""


@dataclass(frozen=True)
class VerificationResult:
    registration: str
    content_types: tuple


def _bounded_diagnostic(value):
    normalized = " ".join((value or "").split())
    return normalized[:512] or "no diagnostic output"


def _require_real_path(path, *, directory):
    description = "directory" if directory else "regular file"
    try:
        metadata = path.lstat()
        resolved = path.resolve(strict=True)
    except OSError as error:
        raise QuickLookVerificationError(
            f"required {description} is unavailable: {path}: {error}"
        ) from error

    expected_kind = stat.S_ISDIR if directory else stat.S_ISREG
    if not expected_kind(metadata.st_mode):
        raise QuickLookVerificationError(f"required path is not a {description}: {path}")
    if resolved != path.absolute():
        raise QuickLookVerificationError(f"required path traverses a symbolic link: {path}")


def _run(command, *, run_command, deadline=None, monotonic=time.monotonic):
    timeout = COMMAND_TIMEOUT_SECONDS
    if deadline is not None:
        remaining = deadline - monotonic()
        if remaining <= 0:
            raise QuickLookVerificationError("Quick Look dependency deadline expired")
        timeout = min(timeout, remaining)
    try:
        return run_command(
            command,
            check=False,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise QuickLookVerificationError(
            f"command could not complete: {command[0]}: {error}"
        ) from error


def _exact_registration_lines(output, appex):
    identifier_field = re.compile(rf"{re.escape(BUNDLE_ID)}\([^()\t]+\)")
    expected_path = str(appex)
    matches = []
    for line in output.splitlines():
        fields = line.split("\t")
        if len(fields) < 2:
            continue
        if identifier_field.fullmatch(fields[0].strip()) and fields[-1].strip() == expected_path:
            matches.append(line)
    return tuple(matches)


def _validate_extension(appex):
    appex = Path(appex)
    if not appex.is_absolute():
        raise QuickLookVerificationError(f"extension path must be absolute: {appex}")
    _require_real_path(appex, directory=True)

    info_plist = appex / "Contents/Info.plist"
    _require_real_path(info_plist, directory=False)
    try:
        with info_plist.open("rb") as stream:
            bundle_id = plistlib.load(stream).get("CFBundleIdentifier")
    except (OSError, plistlib.InvalidFileException, AttributeError) as error:
        raise QuickLookVerificationError(f"could not read {info_plist}: {error}") from error
    if bundle_id != BUNDLE_ID:
        raise QuickLookVerificationError(
            f"Quick Look bundle identifier mismatch: expected {BUNDLE_ID}, "
            f"got {bundle_id or 'missing'}"
        )
    return appex


def _validate_absent_target(appex):
    appex = Path(appex)
    if not appex.is_absolute() or ".." in appex.parts:
        raise QuickLookVerificationError(
            f"retired extension path must be absolute and normalized: {appex}"
        )
    if appex.exists() or appex.is_symlink():
        return _validate_extension(appex)
    ancestor = appex.parent
    while not ancestor.exists() and ancestor != ancestor.parent:
        ancestor = ancestor.parent
    _require_real_path(ancestor, directory=True)
    return appex


def _verify_registration_and_content_types(
    appex,
    *,
    run_command,
    deadline=None,
    monotonic=time.monotonic,
):
    registration = _run(
        (
            PLUGIN_KIT,
            "-mAD",
            "-p",
            "com.apple.quicklook.preview",
            "-i",
            BUNDLE_ID,
            "-v",
        ),
        run_command=run_command,
        deadline=deadline,
        monotonic=monotonic,
    )
    if registration.returncode != 0:
        raise QuickLookVerificationError(
            f"pluginkit query failed with status {registration.returncode}: "
            f"{_bounded_diagnostic(registration.stderr)}"
        )
    matches = _exact_registration_lines(registration.stdout, appex)
    if len(matches) != 1:
        raise QuickLookVerificationError(
            f"Quick Look is not registered exactly once at {appex}; "
            f"found {len(matches)} exact records"
        )

    observed = []
    with tempfile.TemporaryDirectory(prefix="MarkDev-QuickLook-types-") as directory:
        probe_root = Path(directory)
        for extension, expected_type in EXPECTED_CONTENT_TYPES:
            probe = probe_root / f"probe.{extension}"
            probe.touch(exist_ok=False)
            resolution = _run(
                (MDLS, "-name", "kMDItemContentType", "-raw", str(probe)),
                run_command=run_command,
                deadline=deadline,
                monotonic=monotonic,
            )
            if resolution.returncode != 0:
                raise QuickLookVerificationError(
                    f"content-type query for .{extension} failed with status "
                    f"{resolution.returncode}: {_bounded_diagnostic(resolution.stderr)}"
                )
            actual_type = resolution.stdout.strip()
            if actual_type != expected_type:
                raise QuickLookVerificationError(
                    f".{extension} resolved as {actual_type or 'missing'}; "
                    f"expected {expected_type}"
                )
            observed.append((extension, actual_type))

    return VerificationResult(matches[0], tuple(observed))


def _verify_exact_path_absent(
    appex,
    *,
    run_command,
    deadline=None,
    monotonic=time.monotonic,
):
    registration = _run(
        (
            PLUGIN_KIT,
            "-mAD",
            "-p",
            "com.apple.quicklook.preview",
            "-i",
            BUNDLE_ID,
            "-v",
        ),
        run_command=run_command,
        deadline=deadline,
        monotonic=monotonic,
    )
    if registration.returncode != 0:
        raise QuickLookVerificationError(
            f"pluginkit query failed with status {registration.returncode}: "
            f"{_bounded_diagnostic(registration.stderr)}"
        )
    matches = _exact_registration_lines(registration.stdout, appex)
    if matches:
        raise QuickLookVerificationError(
            f"retired Quick Look path is still registered at {appex}; "
            f"found {len(matches)} exact records"
        )


def verify_once(appex, *, run_command=subprocess.run):
    validated_appex = _validate_extension(appex)
    return _verify_registration_and_content_types(
        validated_appex,
        run_command=run_command,
    )


def verify_with_retry(
    appex,
    *,
    attempts,
    delay_seconds,
    overall_timeout_seconds=None,
    run_command=subprocess.run,
    sleep=time.sleep,
    monotonic=time.monotonic,
):
    if attempts < 1:
        raise ValueError("attempts must be positive")
    if delay_seconds < 0:
        raise ValueError("delay_seconds must be non-negative")
    if overall_timeout_seconds is not None and overall_timeout_seconds <= 0:
        raise ValueError("overall_timeout_seconds must be positive")

    validated_appex = _validate_extension(appex)
    deadline = (
        monotonic() + overall_timeout_seconds
        if overall_timeout_seconds is not None
        else None
    )
    last_error = None
    completed_attempts = 0
    for attempt in range(1, attempts + 1):
        if deadline is not None and monotonic() >= deadline:
            break
        try:
            result = _verify_registration_and_content_types(
                validated_appex,
                run_command=run_command,
                deadline=deadline,
                monotonic=monotonic,
            )
        except QuickLookVerificationError as error:
            completed_attempts = attempt
            last_error = error
            if attempt < attempts:
                if deadline is None:
                    sleep(delay_seconds)
                else:
                    remaining = deadline - monotonic()
                    if remaining <= 0:
                        break
                    sleep(min(delay_seconds, remaining))
            continue

        # A path or plist failure is immutable registration input, not a
        # propagation delay. Recheck it only after a successful dependency
        # observation and surface any change immediately rather than retrying.
        _validate_extension(validated_appex)
        return result

    if deadline is not None and monotonic() >= deadline:
        raise QuickLookVerificationError(
            "Quick Look verification did not converge within "
            f"{overall_timeout_seconds:g} seconds after {completed_attempts} attempts: "
            f"{last_error}"
        ) from last_error
    raise QuickLookVerificationError(
        f"Quick Look verification failed after {attempts} attempts: {last_error}"
    ) from last_error


def verify_absent_with_retry(
    appex,
    *,
    attempts,
    delay_seconds,
    overall_timeout_seconds=None,
    run_command=subprocess.run,
    sleep=time.sleep,
    monotonic=time.monotonic,
):
    if attempts < 1:
        raise ValueError("attempts must be positive")
    if delay_seconds < 0:
        raise ValueError("delay_seconds must be non-negative")
    if overall_timeout_seconds is not None and overall_timeout_seconds <= 0:
        raise ValueError("overall_timeout_seconds must be positive")

    validated_appex = _validate_absent_target(appex)
    deadline = (
        monotonic() + overall_timeout_seconds
        if overall_timeout_seconds is not None
        else None
    )
    last_error = None
    completed_attempts = 0
    for attempt in range(1, attempts + 1):
        if deadline is not None and monotonic() >= deadline:
            break
        try:
            _verify_exact_path_absent(
                validated_appex,
                run_command=run_command,
                deadline=deadline,
                monotonic=monotonic,
            )
        except QuickLookVerificationError as error:
            completed_attempts = attempt
            last_error = error
            if attempt < attempts:
                if deadline is None:
                    sleep(delay_seconds)
                else:
                    remaining = deadline - monotonic()
                    if remaining <= 0:
                        break
                    sleep(min(delay_seconds, remaining))
            continue

        _validate_absent_target(validated_appex)
        return

    if deadline is not None and monotonic() >= deadline:
        raise QuickLookVerificationError(
            "Quick Look removal did not converge within "
            f"{overall_timeout_seconds:g} seconds after {completed_attempts} attempts: "
            f"{last_error}"
        ) from last_error
    raise QuickLookVerificationError(
        f"Quick Look removal failed after {attempts} attempts: {last_error}"
    ) from last_error


def _print_result(result):
    print("Installed MarkDev Quick Look registration:")
    print(result.registration)
    print("Registration is necessary but does not prove which provider Finder served.")
    print("Type resolution:")
    for extension, content_type in result.content_types:
        print(f"  .{extension:<9} {content_type}")


def main(arguments):
    if len(arguments) != 2 or arguments[0] not in {"check", "wait", "absent"}:
        print(
            f"usage: {Path(sys.argv[0]).name} check|wait|absent "
            "/absolute/path/to/extension.appex",
            file=sys.stderr,
        )
        return 2

    mode, raw_path = arguments
    try:
        if mode == "check":
            result = verify_once(Path(raw_path))
        elif mode == "wait":
            result = verify_with_retry(
                Path(raw_path),
                attempts=INSTALL_ATTEMPTS,
                delay_seconds=INSTALL_RETRY_DELAY_SECONDS,
                overall_timeout_seconds=INSTALL_OVERALL_TIMEOUT_SECONDS,
            )
        else:
            verify_absent_with_retry(
                Path(raw_path),
                attempts=INSTALL_ATTEMPTS,
                delay_seconds=INSTALL_RETRY_DELAY_SECONDS,
                overall_timeout_seconds=INSTALL_OVERALL_TIMEOUT_SECONDS,
            )
            print(f"verified retired Quick Look path is absent: {raw_path}")
            return 0
    except QuickLookVerificationError as error:
        print(f"Quick Look verification failed: {error}", file=sys.stderr)
        return 1

    _print_result(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
