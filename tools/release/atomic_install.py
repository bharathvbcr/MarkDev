#!/usr/bin/env python3
"""Durable, fail-closed installation transactions for a macOS app bundle."""

import argparse
import ctypes
import errno
import fcntl
import json
import os
from pathlib import Path
import re
import secrets
import stat
import subprocess
import sys


RENAME_SWAP = 0x00000002
RENAME_EXCL = 0x00000004
JOURNAL_VERSION = 2
MAX_JOURNAL_BYTES = 64 * 1024
MAX_STAGING_ENTRIES = 200_000
MAX_STAGING_DEPTH = 128
MAX_DISCOVERY_ENTRIES = 200_000
STAGING_PREFIX = ".MarkDev-install."
LOCK_NAME = ".MarkDev-install.lock"
COMMITMENT = re.compile(r"[0-9a-f]{64}")
STAGING_NAME = re.compile(r"\.MarkDev-install\.[A-Za-z0-9]+")
PHASES = {
    "allocating",
    "prepared",
    "pending_activation",
    "verified",
    "activated",
    "rolled_back",
    "rollback_preserve_pending",
    "quarantined",
    "cleaning_allocating",
    "cleaning_finalized",
    "cleaning_rolled_back",
}


class AtomicInstallError(Exception):
    pass


LIBC = ctypes.CDLL(None, use_errno=True)
RENAMEATX = LIBC.renameatx_np
RENAMEATX.argtypes = (
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
)
RENAMEATX.restype = ctypes.c_int


def _identity(status):
    return {"device": status.st_dev, "inode": status.st_ino}


def _same_identity(left, right):
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _require_absolute(path, owner):
    path = Path(path)
    if not path.is_absolute():
        raise AtomicInstallError(f"{owner} must be absolute: {path}")
    return path


def _open_real_directory(path, owner):
    path = Path(path)
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise AtomicInstallError(f"{owner} is not an available real directory: {path}") from error
    try:
        opened = os.fstat(descriptor)
        named = os.lstat(path)
        if not stat.S_ISDIR(opened.st_mode) or not _same_identity(opened, named):
            raise AtomicInstallError(f"{owner} changed while it was opened: {path}")
    except BaseException:
        os.close(descriptor)
        raise
    return descriptor


def require_real_directory(path, owner):
    descriptor = _open_real_directory(path, owner)
    os.close(descriptor)


def require_same_volume(source, destination):
    source_parent = _open_real_directory(Path(source).parent, "candidate parent")
    try:
        destination_parent = _open_real_directory(
            Path(destination).parent, "destination parent"
        )
        try:
            if os.fstat(source_parent).st_dev != os.fstat(destination_parent).st_dev:
                raise AtomicInstallError(
                    "candidate and destination must be staged on one volume"
                )
        finally:
            os.close(destination_parent)
    finally:
        os.close(source_parent)


def directory_identity(path, owner, allow_missing=False):
    path = Path(path)
    try:
        named = os.lstat(path)
    except FileNotFoundError:
        if allow_missing:
            return None
        raise AtomicInstallError(f"{owner} is missing: {path}")
    if not stat.S_ISDIR(named.st_mode):
        raise AtomicInstallError(f"{owner} is not a real directory: {path}")
    try:
        descriptor = os.open(
            path,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError as error:
        raise AtomicInstallError(f"{owner} could not be pinned: {path}") from error
    try:
        opened = os.fstat(descriptor)
        current = os.lstat(path)
        if not _same_identity(named, opened) or not _same_identity(opened, current):
            raise AtomicInstallError(f"{owner} changed while it was inspected: {path}")
        return _identity(opened)
    finally:
        os.close(descriptor)


def _sync_file(descriptor):
    os.fsync(descriptor)
    full_sync = getattr(fcntl, "F_FULLFSYNC", None)
    if full_sync is not None:
        fcntl.fcntl(descriptor, full_sync)


def _sync_directory(descriptor):
    os.fsync(descriptor)


def renameatx(source, destination, flags):
    source = Path(source)
    destination = Path(destination)
    source_parent = _open_real_directory(source.parent, "rename source parent")
    try:
        destination_parent = _open_real_directory(
            destination.parent, "rename destination parent"
        )
        try:
            result = RENAMEATX(
                source_parent,
                os.fsencode(source.name),
                destination_parent,
                os.fsencode(destination.name),
                flags,
            )
            if result != 0:
                code = ctypes.get_errno()
                raise OSError(
                    code, os.strerror(code), f"{source} -> {destination}"
                )
            # A successful atomic rename is not itself a power-loss durability
            # boundary. Sync both containing directories before the journal can
            # advance beyond its pre-rename phase.
            _sync_directory(source_parent)
            if source.parent != destination.parent:
                _sync_directory(destination_parent)
        finally:
            os.close(destination_parent)
    finally:
        os.close(source_parent)


def _regular_file_status(status, owner):
    if not stat.S_ISREG(status.st_mode):
        raise AtomicInstallError(f"{owner} is not a regular file")
    if status.st_nlink != 1:
        raise AtomicInstallError(f"{owner} must have exactly one link")
    if status.st_uid != os.geteuid():
        raise AtomicInstallError(f"{owner} is not owned by the installer user")


def _open_parent(path, owner):
    path = _require_absolute(path, owner)
    return path, _open_real_directory(path.parent, f"{owner} parent")


def write_journal(path, value):
    path, parent = _open_parent(path, "transaction journal")
    encoded = (json.dumps(value, sort_keys=True, separators=(",", ":")) + "\n").encode()
    if len(encoded) > MAX_JOURNAL_BYTES:
        os.close(parent)
        raise AtomicInstallError("transaction journal exceeds its safety limit")
    temporary = f".{path.name}.{os.getpid()}.{secrets.token_hex(8)}.tmp"
    descriptor = None
    try:
        try:
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        except FileNotFoundError:
            current = None
        if current is not None:
            _regular_file_status(current, f"transaction journal: {path}")
        descriptor = os.open(
            temporary,
            os.O_WRONLY
            | os.O_CREAT
            | os.O_EXCL
            | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent,
        )
        written = 0
        while written < len(encoded):
            count = os.write(descriptor, encoded[written:])
            if count <= 0:
                raise AtomicInstallError("transaction journal write made no progress")
            written += count
        _sync_file(descriptor)
        os.replace(
            temporary,
            path.name,
            src_dir_fd=parent,
            dst_dir_fd=parent,
        )
        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        opened = os.fstat(descriptor)
        _regular_file_status(named, f"transaction journal: {path}")
        if not _same_identity(named, opened):
            raise AtomicInstallError("transaction journal changed during durable replacement")
        _sync_directory(parent)
    finally:
        if descriptor is not None:
            os.close(descriptor)
        try:
            os.unlink(temporary, dir_fd=parent)
        except FileNotFoundError:
            pass
        os.close(parent)


def _reject_duplicate_object_keys(pairs):
    value = {}
    for key, item in pairs:
        if key in value:
            raise ValueError(f"duplicate transaction journal key: {key}")
        value[key] = item
    return value


def read_journal(path):
    path, parent = _open_parent(path, "transaction journal")
    descriptor = None
    try:
        try:
            descriptor = os.open(
                path.name,
                os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent,
            )
        except OSError as error:
            raise AtomicInstallError(f"transaction journal is unavailable: {path}") from error
        before = os.fstat(descriptor)
        _regular_file_status(before, f"transaction journal: {path}")
        if before.st_size > MAX_JOURNAL_BYTES:
            raise AtomicInstallError(
                f"transaction journal is not a bounded regular file: {path}"
            )
        blocks = []
        total = 0
        while total <= MAX_JOURNAL_BYTES:
            block = os.read(descriptor, min(16 * 1024, MAX_JOURNAL_BYTES + 1 - total))
            if not block:
                break
            blocks.append(block)
            total += len(block)
        if total > MAX_JOURNAL_BYTES:
            raise AtomicInstallError("transaction journal exceeds its safety limit")
        after = os.fstat(descriptor)
        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        stable_fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(before, field) != getattr(after, field) for field in stable_fields):
            raise AtomicInstallError("transaction journal changed while it was read")
        if not _same_identity(after, named):
            raise AtomicInstallError("transaction journal path changed while it was read")
        try:
            value = json.loads(
                b"".join(blocks), object_pairs_hook=_reject_duplicate_object_keys
            )
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as error:
            raise AtomicInstallError(f"transaction journal is invalid: {path}") from error
        if not isinstance(value, dict):
            raise AtomicInstallError("transaction journal root is not an object")
        return value
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def _valid_identity(identity, *, allow_none):
    if identity is None:
        return allow_none
    return (
        isinstance(identity, dict)
        and set(identity) == {"device", "inode"}
        and all(type(identity[name]) is int and identity[name] >= 0 for name in identity)
    )


def _valid_commitment(value, *, allow_none):
    return (value is None and allow_none) or (
        isinstance(value, str) and COMMITMENT.fullmatch(value) is not None
    )


def _transaction_paths(candidate, destination, journal_path):
    candidate = _require_absolute(candidate, "candidate")
    destination = _require_absolute(destination, "destination")
    journal_path = _require_absolute(journal_path, "transaction journal")
    if candidate.parent != journal_path.parent:
        raise AtomicInstallError("candidate and journal must share one staging directory")
    if candidate == destination:
        raise AtomicInstallError("candidate and destination must be distinct")
    return candidate, destination, journal_path


def validate_journal(journal, candidate, destination, journal_path=None):
    expected_keys = {
        "version",
        "phase",
        "outcome",
        "candidate",
        "destination",
        "staging_identity",
        "candidate_identity",
        "destination_identity",
        "candidate_commitment",
        "destination_commitment",
    }
    if set(journal) != expected_keys:
        raise AtomicInstallError("transaction journal shape does not match the contract")
    if type(journal["version"]) is not int or journal["version"] != JOURNAL_VERSION:
        raise AtomicInstallError("transaction journal version is unsupported")
    if not isinstance(journal["phase"], str) or journal["phase"] not in PHASES:
        raise AtomicInstallError("transaction journal phase is invalid")
    if (
        not isinstance(journal["outcome"], str)
        or journal["outcome"] not in {"installed", "swapped"}
    ):
        raise AtomicInstallError("transaction journal outcome is invalid")
    if journal["candidate"] != str(candidate) or journal["destination"] != str(destination):
        raise AtomicInstallError(
            "transaction journal paths do not match the requested recovery"
        )
    if not _valid_identity(journal["staging_identity"], allow_none=False):
        raise AtomicInstallError("transaction journal has an invalid staging identity")
    allocating = journal["phase"] in {"allocating", "cleaning_allocating"}
    if not _valid_identity(journal["candidate_identity"], allow_none=allocating):
        raise AtomicInstallError("transaction journal has an invalid candidate identity")
    if not _valid_identity(journal["destination_identity"], allow_none=True):
        raise AtomicInstallError("transaction journal has an invalid destination identity")
    if not _valid_commitment(journal["candidate_commitment"], allow_none=allocating):
        raise AtomicInstallError("transaction journal has an invalid candidate commitment")
    if not _valid_commitment(journal["destination_commitment"], allow_none=True):
        raise AtomicInstallError("transaction journal has an invalid destination commitment")
    if (journal["outcome"] == "swapped") != (
        journal["destination_identity"] is not None
    ):
        raise AtomicInstallError(
            "transaction journal outcome contradicts the prior destination"
        )
    if not allocating:
        if journal["candidate_identity"] is None or journal["candidate_commitment"] is None:
            raise AtomicInstallError("prepared transaction omits the incoming bundle")
        if (journal["destination_identity"] is None) != (
            journal["destination_commitment"] is None
        ):
            raise AtomicInstallError(
                "previous bundle identity and commitment must either both exist or both be absent"
            )
    if journal_path is not None:
        staging_now = directory_identity(
            Path(journal_path).parent, "transaction staging directory"
        )
        if staging_now != journal["staging_identity"]:
            raise AtomicInstallError("transaction staging directory identity changed")


def initialize_transaction(candidate, destination, journal_path):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    if os.path.lexists(journal_path):
        raise AtomicInstallError(f"transaction journal already exists: {journal_path}")
    if os.path.lexists(candidate):
        raise AtomicInstallError(f"install candidate already exists: {candidate}")
    destination_identity = directory_identity(
        destination, "existing application", allow_missing=True
    )
    journal = {
        "version": JOURNAL_VERSION,
        "phase": "allocating",
        "outcome": "swapped" if destination_identity is not None else "installed",
        "candidate": str(candidate),
        "destination": str(destination),
        "staging_identity": directory_identity(
            journal_path.parent, "transaction staging directory"
        ),
        "candidate_identity": None,
        "destination_identity": destination_identity,
        "candidate_commitment": None,
        "destination_commitment": None,
    }
    write_journal(journal_path, journal)
    return journal


def prepare_transaction(
    candidate,
    destination,
    journal_path,
    *,
    candidate_commitment=None,
    destination_commitment=None,
):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    if candidate_commitment is None:
        raise AtomicInstallError("incoming bundle commitment is required")
    if COMMITMENT.fullmatch(candidate_commitment) is None:
        raise AtomicInstallError("incoming bundle commitment is invalid")
    if os.path.lexists(journal_path):
        journal = read_journal(journal_path)
        validate_journal(journal, candidate, destination, journal_path)
        if journal["phase"] != "allocating":
            raise AtomicInstallError("transaction is not in its allocating phase")
        destination_now = directory_identity(
            destination, "existing application", allow_missing=True
        )
        if destination_now != journal["destination_identity"]:
            raise AtomicInstallError("destination changed while the candidate was staged")
    else:
        destination_now = directory_identity(
            destination, "existing application", allow_missing=True
        )
        journal = {
            "version": JOURNAL_VERSION,
            "outcome": "swapped" if destination_now is not None else "installed",
            "candidate": str(candidate),
            "destination": str(destination),
            "staging_identity": directory_identity(
                journal_path.parent, "transaction staging directory"
            ),
            "destination_identity": destination_now,
        }
    if (destination_now is None) != (destination_commitment is None):
        raise AtomicInstallError(
            "previous bundle commitment does not match destination presence"
        )
    if destination_commitment is not None and COMMITMENT.fullmatch(
        destination_commitment
    ) is None:
        raise AtomicInstallError("previous bundle commitment is invalid")
    journal.update(
        {
            "phase": "prepared",
            "candidate_identity": directory_identity(candidate, "install candidate"),
            "candidate_commitment": candidate_commitment,
            "destination_commitment": destination_commitment,
        }
    )
    write_journal(journal_path, journal)
    return journal


def transaction_position(journal_path, candidate, destination):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    journal = read_journal(journal_path)
    validate_journal(journal, candidate, destination, journal_path)
    if journal["phase"] in {"allocating", "cleaning_allocating"}:
        raise AtomicInstallError("allocating transaction has no install position")
    candidate_now = directory_identity(
        candidate, "candidate recovery path", allow_missing=True
    )
    destination_now = directory_identity(
        destination, "destination recovery path", allow_missing=True
    )
    candidate_before = journal["candidate_identity"]
    destination_before = journal["destination_identity"]
    if candidate_now == candidate_before and destination_now == destination_before:
        return "not-installed", journal
    if journal["outcome"] == "swapped":
        if candidate_now == destination_before and destination_now == candidate_before:
            return "swapped", journal
    elif candidate_now is None and destination_now == candidate_before:
        return "installed", journal
    raise AtomicInstallError(
        "transaction paths no longer match either the pre-install or pending identities"
    )


def _post_rename_position(journal, candidate, destination):
    candidate_now = directory_identity(
        candidate, "post-install candidate", allow_missing=True
    )
    destination_now = directory_identity(
        destination, "post-install destination", allow_missing=True
    )
    if journal["outcome"] == "swapped":
        valid = (
            candidate_now == journal["destination_identity"]
            and destination_now == journal["candidate_identity"]
        )
    else:
        valid = candidate_now is None and destination_now == journal["candidate_identity"]
    if not valid:
        raise AtomicInstallError(
            "post-rename paths do not contain the exact recorded bundle identities; "
            "preserving every root for manual recovery"
        )


def install(
    candidate,
    destination,
    journal_path=None,
    *,
    candidate_commitment=None,
    destination_commitment=None,
):
    candidate = Path(candidate)
    destination = Path(destination)
    require_real_directory(candidate, "install candidate")
    require_same_volume(candidate, destination)
    if journal_path is not None:
        journal = prepare_transaction(
            candidate,
            destination,
            journal_path,
            candidate_commitment=candidate_commitment,
            destination_commitment=destination_commitment,
        )
        outcome = journal["outcome"]
    elif os.path.lexists(destination):
        require_real_directory(destination, "existing application")
        journal = None
        outcome = "swapped"
    else:
        journal = None
        outcome = "installed"
    if outcome == "swapped":
        renameatx(candidate, destination, RENAME_SWAP)
    else:
        try:
            renameatx(candidate, destination, RENAME_EXCL)
        except OSError as error:
            if error.errno == errno.EEXIST:
                raise AtomicInstallError(
                    "application appeared during installation; refusing to overwrite"
                ) from error
            raise
    if journal_path is not None:
        _post_rename_position(journal, candidate, destination)
        journal["phase"] = "pending_activation"
        write_journal(journal_path, journal)
    return outcome


def rollback(candidate, destination, outcome):
    candidate = Path(candidate)
    destination = Path(destination)
    require_real_directory(destination, "installed application")
    require_same_volume(destination, candidate)
    if outcome == "swapped":
        require_real_directory(candidate, "previous application")
        renameatx(candidate, destination, RENAME_SWAP)
    elif outcome == "installed":
        if os.path.lexists(candidate):
            raise AtomicInstallError("rollback destination unexpectedly exists")
        renameatx(destination, candidate, RENAME_EXCL)
    else:
        raise AtomicInstallError(f"unknown install outcome: {outcome}")


def rollback_transaction(
    journal_path, candidate, destination, *, preserve_candidate=False
):
    position, journal = transaction_position(journal_path, candidate, destination)
    if journal["phase"] == "activated":
        raise AtomicInstallError("activated transaction must be finalized, not rolled back")
    if journal["phase"] == "quarantined":
        if position != "not-installed":
            raise AtomicInstallError(
                "quarantined transaction contradicts the restored filesystem position"
            )
        return position
    if journal["phase"] == "rollback_preserve_pending":
        preserve_candidate = True
    if position == "not-installed":
        target_phase = "quarantined" if preserve_candidate else "rolled_back"
        if journal["phase"] != target_phase:
            journal["phase"] = target_phase
            write_journal(journal_path, journal)
        return position
    if preserve_candidate and journal["phase"] != "rollback_preserve_pending":
        journal["phase"] = "rollback_preserve_pending"
        write_journal(journal_path, journal)
    rollback(candidate, destination, position)
    recovered, _ = transaction_position(journal_path, candidate, destination)
    if recovered != "not-installed":
        raise AtomicInstallError("rollback did not restore the recorded filesystem identities")
    journal["phase"] = "quarantined" if preserve_candidate else "rolled_back"
    write_journal(journal_path, journal)
    return position


def mark_phase(journal_path, candidate, destination, phase):
    if phase not in {"verified", "activated"}:
        raise AtomicInstallError(f"phase cannot be advanced externally: {phase}")
    position, journal = transaction_position(journal_path, candidate, destination)
    if position != journal["outcome"]:
        raise AtomicInstallError("transaction is not in its pending filesystem position")
    required = "pending_activation" if phase == "verified" else "verified"
    if journal["phase"] != required:
        raise AtomicInstallError(
            f"transaction must be {required} before advancing to {phase}"
        )
    journal["phase"] = phase
    write_journal(journal_path, journal)


def expected_commitment(journal_path, candidate, destination, role):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    journal = read_journal(journal_path)
    validate_journal(journal, candidate, destination, journal_path)
    key = {
        "incoming": "candidate_commitment",
        "previous": "destination_commitment",
    }.get(role)
    if key is None:
        raise AtomicInstallError(f"unknown commitment role: {role}")
    return journal[key]


def _validate_staging_inventory(journal_path, candidate):
    staging = Path(journal_path).parent
    allowed = {Path(journal_path).name}
    if os.path.lexists(candidate):
        allowed.add(Path(candidate).name)
    inspected = 0
    with os.scandir(staging) as entries:
        for entry in entries:
            inspected += 1
            if inspected > MAX_STAGING_ENTRIES:
                raise AtomicInstallError(
                    "transaction staging directory exceeds its entry limit"
                )
            if entry.name in allowed:
                continue
            temporary_prefix = f".{Path(journal_path).name}."
            if entry.name.startswith(temporary_prefix) and entry.name.endswith(".tmp"):
                status = entry.stat(follow_symlinks=False)
                _regular_file_status(status, f"journal temporary file: {entry.path}")
                if status.st_size <= MAX_JOURNAL_BYTES:
                    continue
            raise AtomicInstallError(
                f"transaction staging directory contains an unknown root: {entry.name}"
            )


def _cleaning_position(journal, candidate, destination):
    candidate_now = directory_identity(
        candidate, "candidate cleanup path", allow_missing=True
    )
    destination_now = directory_identity(
        destination, "destination cleanup path", allow_missing=True
    )
    phase = journal["phase"]
    outcome = journal["outcome"]
    if phase == "cleaning_allocating":
        if destination_now != journal["destination_identity"]:
            raise AtomicInstallError(
                "destination changed during abandoned-copy cleanup"
            )
        return "resume-cleanup-allocating"
    if phase == "cleaning_finalized":
        if destination_now != journal["candidate_identity"]:
            raise AtomicInstallError(
                "activated destination changed during transaction cleanup"
            )
        expected_candidate = (
            journal["destination_identity"] if outcome == "swapped" else None
        )
        if candidate_now not in (expected_candidate, None):
            raise AtomicInstallError(
                "held previous bundle changed during finalized cleanup"
            )
        return f"resume-cleanup-finalized-{outcome}"
    if phase == "cleaning_rolled_back":
        if destination_now != journal["destination_identity"]:
            raise AtomicInstallError(
                "restored destination changed during transaction cleanup"
            )
        if candidate_now not in (journal["candidate_identity"], None):
            raise AtomicInstallError(
                "withdrawn incoming bundle changed during rollback cleanup"
            )
        return f"resume-cleanup-rolledback-{outcome}"
    raise AtomicInstallError(f"unknown cleanup phase: {phase}")


def recovery_action(journal_path, candidate, destination):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    if not os.path.lexists(journal_path):
        _validate_empty_staging(journal_path.parent)
        return "cleanup-empty"
    journal = read_journal(journal_path)
    validate_journal(journal, candidate, destination, journal_path)
    if journal_path.parent.name.startswith(STAGING_PREFIX):
        _validate_staging_inventory(journal_path, candidate)
    if journal["phase"].startswith("cleaning_"):
        return _cleaning_position(journal, candidate, destination)
    if journal["phase"] == "allocating":
        destination_now = directory_identity(
            destination, "destination recovery path", allow_missing=True
        )
        if destination_now != journal["destination_identity"]:
            raise AtomicInstallError(
                "destination changed while an allocating transaction was abandoned"
            )
        return "cleanup-allocating"
    position, journal = transaction_position(journal_path, candidate, destination)
    phase = journal["phase"]
    if phase == "rollback_preserve_pending":
        if position == journal["outcome"]:
            return f"rollback-preserve-{journal['outcome']}"
        if position == "not-installed":
            return f"preserve-{journal['outcome']}"
        raise AtomicInstallError("preserved rollback has no safe filesystem position")
    if phase == "quarantined":
        if position != "not-installed":
            raise AtomicInstallError(
                "quarantined journal contradicts the filesystem position"
            )
        return f"preserve-{journal['outcome']}"
    if position == journal["outcome"]:
        if phase in {"prepared", "pending_activation", "verified"}:
            return f"rollback-{journal['outcome']}"
        if phase == "activated":
            return f"finalize-{journal['outcome']}"
        raise AtomicInstallError(
            "rolled-back journal contradicts the pending filesystem position"
        )
    if position == "not-installed":
        if phase == "activated":
            raise AtomicInstallError(
                "activated journal contradicts the restored filesystem position"
            )
        return f"cleanup-{journal['outcome']}"
    raise AtomicInstallError("transaction has no safe recovery action")


def _bounded_directory_names(descriptor, accounting, limit, owner):
    observed = []
    with os.scandir(descriptor) as entries:
        for entry in entries:
            accounting["entries"] += 1
            if accounting["entries"] > limit:
                raise AtomicInstallError(f"{owner} exceeds its entry limit")
            observed.append(entry.name)
    return sorted(observed, key=os.fsencode)


def _preflight_tree(descriptor, root_device, accounting=None, depth=0):
    if depth > MAX_STAGING_DEPTH:
        raise AtomicInstallError("transaction staging tree exceeds its depth limit")
    if accounting is None:
        accounting = {"entries": 0}
    observed = _bounded_directory_names(
        descriptor,
        accounting,
        MAX_STAGING_ENTRIES,
        "transaction staging tree",
    )
    for name in observed:
        status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if status.st_dev != root_device:
            raise AtomicInstallError(
                f"refusing to clean a cross-device staging entry: {name}"
            )
        if stat.S_ISDIR(status.st_mode):
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                if not _same_identity(status, os.fstat(child)):
                    raise AtomicInstallError(
                        f"staging directory changed during cleanup preflight: {name}"
                    )
                _preflight_tree(child, root_device, accounting, depth + 1)
            finally:
                os.close(child)
        elif not (stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode)):
            raise AtomicInstallError(
                f"refusing to clean a special staging entry: {name}"
            )


def _remove_tree_contents(
    descriptor, root_device=None, accounting=None, depth=0
):
    if depth > MAX_STAGING_DEPTH:
        raise AtomicInstallError("transaction staging tree exceeds its depth limit")
    if root_device is None:
        root_device = os.fstat(descriptor).st_dev
    if accounting is None:
        accounting = {"entries": 0}
    observed = _bounded_directory_names(
        descriptor,
        accounting,
        MAX_STAGING_ENTRIES,
        "transaction staging removal",
    )
    for name in observed:
        status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if status.st_dev != root_device:
            raise AtomicInstallError(
                f"refusing to remove a cross-device staging entry: {name}"
            )
        if stat.S_ISDIR(status.st_mode):
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                if not _same_identity(status, os.fstat(child)):
                    raise AtomicInstallError(
                        f"staging directory changed during cleanup: {name}"
                    )
                _remove_tree_contents(
                    child, root_device, accounting, depth + 1
                )
                _sync_directory(child)
            finally:
                os.close(child)
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not _same_identity(status, current):
                raise AtomicInstallError(
                    f"staging directory changed before removal: {name}"
                )
            os.rmdir(name, dir_fd=descriptor)
        elif stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode):
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not _same_identity(status, current):
                raise AtomicInstallError(
                    f"staging entry changed before removal: {name}"
                )
            os.unlink(name, dir_fd=descriptor)
        else:
            raise AtomicInstallError(
                f"refusing to remove a special staging entry: {name}"
            )
    _sync_directory(descriptor)


def _remove_staging_payload(descriptor, journal_name, candidate_name, root_device):
    accounting = {"entries": 0}
    observed = _bounded_directory_names(
        descriptor,
        accounting,
        MAX_STAGING_ENTRIES,
        "transaction staging removal",
    )
    temporary_prefix = f".{journal_name}."
    for name in observed:
        if name == journal_name:
            continue
        if name != candidate_name and not (
            name.startswith(temporary_prefix) and name.endswith(".tmp")
        ):
            raise AtomicInstallError(
                f"transaction staging directory gained an unknown root: {name}"
            )
        status = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if status.st_dev != root_device:
            raise AtomicInstallError(
                f"refusing to remove a cross-device staging entry: {name}"
            )
        if stat.S_ISDIR(status.st_mode):
            if name != candidate_name:
                raise AtomicInstallError(
                    f"journal temporary path is unexpectedly a directory: {name}"
                )
            child = os.open(
                name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=descriptor,
            )
            try:
                if not _same_identity(status, os.fstat(child)):
                    raise AtomicInstallError(
                        f"candidate changed during cleanup: {name}"
                    )
                _remove_tree_contents(child, root_device, accounting, 1)
                _sync_directory(child)
            finally:
                os.close(child)
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not _same_identity(status, current):
                raise AtomicInstallError(
                    f"candidate changed before cleanup removal: {name}"
                )
            os.rmdir(name, dir_fd=descriptor)
        elif stat.S_ISREG(status.st_mode) or stat.S_ISLNK(status.st_mode):
            if name == candidate_name:
                raise AtomicInstallError("candidate cleanup path is not a real directory")
            current = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
            if not _same_identity(status, current):
                raise AtomicInstallError(
                    f"journal temporary changed before removal: {name}"
                )
            os.unlink(name, dir_fd=descriptor)
        else:
            raise AtomicInstallError(
                f"refusing to remove a special staging entry: {name}"
            )
    _sync_directory(descriptor)


def _cleanup_checkpoint(_name):
    """Test seam for injected process death at durable cleanup boundaries."""


def _open_safe_staging_root(staging):
    staging = _require_absolute(staging, "transaction staging directory")
    if STAGING_NAME.fullmatch(staging.name) is None:
        raise AtomicInstallError(
            f"transaction staging directory has an unsafe name: {staging}"
        )
    parent = _open_real_directory(staging.parent, "staging parent")
    root = None
    try:
        named = os.stat(staging.name, dir_fd=parent, follow_symlinks=False)
        if (
            not stat.S_ISDIR(named.st_mode)
            or named.st_uid != os.geteuid()
            or stat.S_IMODE(named.st_mode) & 0o077
        ):
            raise AtomicInstallError(
                f"transaction staging directory ownership or permissions are unsafe: {staging}"
            )
        root = os.open(
            staging.name,
            os.O_RDONLY
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent,
        )
        opened = os.fstat(root)
        if not _same_identity(named, opened):
            raise AtomicInstallError(
                f"transaction staging directory changed while it was opened: {staging}"
            )
        result = (parent, root, _identity(opened))
        parent = None
        root = None
        return result
    finally:
        if root is not None:
            os.close(root)
        if parent is not None:
            os.close(parent)


def _validate_empty_staging(staging):
    parent, root, _ = _open_safe_staging_root(staging)
    try:
        names = _bounded_directory_names(
            root,
            {"entries": 0},
            MAX_STAGING_ENTRIES,
            "empty transaction staging directory",
        )
        if names:
            raise AtomicInstallError(
                "transaction journal is missing but the staging root is not empty; "
                "preserving it for manual recovery"
            )
    finally:
        os.close(root)
        os.close(parent)


def cleanup_empty_staging(staging):
    staging = Path(staging)
    parent, root, identity = _open_safe_staging_root(staging)
    try:
        names = _bounded_directory_names(
            root,
            {"entries": 0},
            MAX_STAGING_ENTRIES,
            "empty transaction staging directory",
        )
        if names:
            raise AtomicInstallError(
                "refusing to remove a nonempty journal-less staging root"
            )
        named = os.stat(staging.name, dir_fd=parent, follow_symlinks=False)
        if _identity(named) != identity:
            raise AtomicInstallError("empty staging root changed before removal")
        os.rmdir(staging.name, dir_fd=parent)
        _sync_directory(parent)
    finally:
        os.close(root)
        os.close(parent)


def cleanup_transaction(journal_path, candidate, destination):
    candidate, destination, journal_path = _transaction_paths(
        candidate, destination, journal_path
    )
    action = recovery_action(journal_path, candidate, destination)
    phase_for_action = {
        "cleanup-allocating": "cleaning_allocating",
        "finalize-installed": "cleaning_finalized",
        "finalize-swapped": "cleaning_finalized",
        "cleanup-installed": "cleaning_rolled_back",
        "cleanup-swapped": "cleaning_rolled_back",
    }
    resumed = action.startswith("resume-cleanup-")
    if action not in phase_for_action and not resumed:
        raise AtomicInstallError(f"transaction is not safe to clean: {action}")
    _validate_staging_inventory(journal_path, candidate)
    staging = journal_path.parent
    journal = read_journal(journal_path)
    validate_journal(journal, candidate, destination, journal_path)
    if not resumed:
        journal["phase"] = phase_for_action[action]
        write_journal(journal_path, journal)
        _cleanup_checkpoint("after-cleaning-phase")
        journal = read_journal(journal_path)
        validate_journal(journal, candidate, destination, journal_path)
    parent, root, staging_identity = _open_safe_staging_root(staging)
    try:
        if staging_identity != journal["staging_identity"]:
            raise AtomicInstallError("staging identity changed before cleanup")
        _preflight_tree(root, os.fstat(root).st_dev)
        _remove_staging_payload(
            root, journal_path.name, candidate.name, os.fstat(root).st_dev
        )
        remaining = _bounded_directory_names(
            root,
            {"entries": 0},
            MAX_STAGING_ENTRIES,
            "transaction staging directory",
        )
        if remaining != [journal_path.name]:
            raise AtomicInstallError(
                "transaction staging directory is not journal-only after payload cleanup"
            )
        _sync_directory(root)
        _cleanup_checkpoint("after-payload-removal")
        journal_status = os.stat(
            journal_path.name, dir_fd=root, follow_symlinks=False
        )
        _regular_file_status(
            journal_status, f"transaction journal: {journal_path}"
        )
        current = os.stat(journal_path.name, dir_fd=root, follow_symlinks=False)
        if not _same_identity(journal_status, current):
            raise AtomicInstallError("transaction journal changed before final removal")
        os.unlink(journal_path.name, dir_fd=root)
        _sync_directory(root)
        _cleanup_checkpoint("after-journal-removal")
        named = os.stat(staging.name, dir_fd=parent, follow_symlinks=False)
        if _identity(named) != journal["staging_identity"]:
            raise AtomicInstallError("staging root changed before final removal")
        os.rmdir(staging.name, dir_fd=parent)
        _sync_directory(parent)
        _cleanup_checkpoint("after-root-removal")
    finally:
        os.close(root)
        os.close(parent)


def discover_transactions(root):
    root = _require_absolute(root, "installation root")
    descriptor = _open_real_directory(root, "installation root")
    try:
        discovered = []
        inspected = 0
        with os.scandir(descriptor) as entries:
            for entry in entries:
                inspected += 1
                if inspected > MAX_DISCOVERY_ENTRIES:
                    raise AtomicInstallError(
                        "installation root exceeds the bounded discovery inventory"
                    )
                if not entry.name.startswith(STAGING_PREFIX) or entry.name == LOCK_NAME:
                    continue
                if STAGING_NAME.fullmatch(entry.name) is None:
                    raise AtomicInstallError(
                        f"ambiguous installer-owned path must be preserved: {entry.name}"
                    )
                status = entry.stat(follow_symlinks=False)
                if (
                    not stat.S_ISDIR(status.st_mode)
                    or status.st_uid != os.geteuid()
                    or stat.S_IMODE(status.st_mode) & 0o077
                ):
                    raise AtomicInstallError(
                        f"ambiguous staging root must be preserved: {entry.name}"
                    )
                discovered.append(root / entry.name)
        return sorted(discovered, key=lambda path: path.name)
    finally:
        os.close(descriptor)


def acquire_install_lock(path):
    path, parent = _open_parent(path, "installer lock")
    descriptor = None
    try:
        flags = os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = os.open(path.name, flags, dir_fd=parent)
        except FileNotFoundError:
            try:
                descriptor = os.open(
                    path.name,
                    flags | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=parent,
                )
                _sync_directory(parent)
            except FileExistsError:
                descriptor = os.open(path.name, flags, dir_fd=parent)
        except OSError as error:
            raise AtomicInstallError(f"installer lock is unavailable: {path}") from error
        status = os.fstat(descriptor)
        named = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        _regular_file_status(status, f"installer lock: {path}")
        if not _same_identity(status, named) or stat.S_IMODE(status.st_mode) & 0o077:
            raise AtomicInstallError("installer lock path or permissions are unsafe")
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as error:
            raise AtomicInstallError("another MarkDev installation is already running") from error
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if not _same_identity(status, current):
            raise AtomicInstallError("installer lock path changed during acquisition")
        result = descriptor
        descriptor = None
        return result
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def assert_install_lock_held(path):
    descriptor = None
    try:
        descriptor = acquire_install_lock(path)
    except AtomicInstallError as error:
        if str(error) == "another MarkDev installation is already running":
            return
        raise
    else:
        raise AtomicInstallError("installer lock is not held by the lifecycle owner")
    finally:
        if descriptor is not None:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            finally:
                os.close(descriptor)


def assert_lock_session(path, descriptor, token):
    if not isinstance(token, str) or re.fullmatch(r"[0-9a-f]{64}", token) is None:
        raise AtomicInstallError("installer lock session token is invalid")
    try:
        status = os.fstat(descriptor)
        if not (stat.S_ISFIFO(status.st_mode) or stat.S_ISSOCK(status.st_mode)):
            raise AtomicInstallError("installer lock session descriptor has the wrong type")
        os.set_blocking(descriptor, False)
        expected = (token + "\n").encode("ascii")
        observed = bytearray()
        while len(observed) <= len(expected):
            try:
                block = os.read(descriptor, len(expected) + 1 - len(observed))
            except BlockingIOError as error:
                raise AtomicInstallError(
                    "installer lock session proof is incomplete"
                ) from error
            if not block:
                break
            observed.extend(block)
        if bytes(observed) != expected:
            raise AtomicInstallError("installer lock session proof is invalid")
        assert_install_lock_held(path)
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass


def lock_and_run(path, command):
    if not command:
        raise AtomicInstallError("locked installer command is empty")
    if not Path(command[0]).is_absolute():
        raise AtomicInstallError("locked installer command must be absolute")
    lock_descriptor = acquire_install_lock(path)
    guard_descriptor = None
    guard_writer = None
    try:
        guard_descriptor, guard_writer = os.pipe()
        token = secrets.token_hex(32)
        encoded = (token + "\n").encode("ascii")
        written = 0
        while written < len(encoded):
            count = os.write(guard_writer, encoded[written:])
            if count <= 0:
                raise AtomicInstallError("installer lock session proof made no progress")
            written += count
        os.close(guard_writer)
        guard_writer = None
        environment = os.environ.copy()
        environment["MARKDEV_INSTALL_GUARD_FD"] = str(guard_descriptor)
        environment["MARKDEV_INSTALL_GUARD_TOKEN"] = token
        process = None
        try:
            process = subprocess.Popen(
                command,
                close_fds=True,
                pass_fds=(guard_descriptor,),
                env=environment,
            )
            return process.wait()
        except OSError as error:
            raise AtomicInstallError(
                f"locked installer command could not start: {command[0]}"
            ) from error
        except BaseException:
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            raise
    finally:
        if guard_writer is not None:
            os.close(guard_writer)
        if guard_descriptor is not None:
            os.close(guard_descriptor)
        os.close(lock_descriptor)


def run_bounded(timeout_seconds, command):
    if timeout_seconds <= 0 or timeout_seconds > 300:
        raise AtomicInstallError(
            "bounded command timeout must be greater than zero and at most 300 seconds"
        )
    if not command or not Path(command[0]).is_absolute():
        raise AtomicInstallError("bounded command must name an absolute executable")
    try:
        result = subprocess.run(command, check=False, timeout=timeout_seconds)
    except subprocess.TimeoutExpired as error:
        raise AtomicInstallError(
            f"bounded command timed out after {timeout_seconds:g} seconds: {command[0]}"
        ) from error
    if result.returncode != 0:
        raise AtomicInstallError(
            f"bounded command failed with status {result.returncode}: {command[0]}"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    initialize_parser = subparsers.add_parser("initialize")
    initialize_parser.add_argument("candidate")
    initialize_parser.add_argument("destination")
    initialize_parser.add_argument("--state-file", required=True)

    install_parser = subparsers.add_parser("install")
    install_parser.add_argument("candidate")
    install_parser.add_argument("destination")
    install_parser.add_argument("--state-file", required=True)
    install_parser.add_argument("--candidate-commitment", required=True)
    install_parser.add_argument("--destination-commitment")

    rollback_parser = subparsers.add_parser("rollback-transaction")
    rollback_parser.add_argument("state_file")
    rollback_parser.add_argument("candidate")
    rollback_parser.add_argument("destination")
    rollback_parser.add_argument("--preserve-candidate", action="store_true")

    phase_parser = subparsers.add_parser("mark-phase")
    phase_parser.add_argument("state_file")
    phase_parser.add_argument("candidate")
    phase_parser.add_argument("destination")
    phase_parser.add_argument("phase", choices=("verified", "activated"))

    action_parser = subparsers.add_parser("recovery-action")
    action_parser.add_argument("state_file")
    action_parser.add_argument("candidate")
    action_parser.add_argument("destination")

    commitment_parser = subparsers.add_parser("commitment")
    commitment_parser.add_argument("state_file")
    commitment_parser.add_argument("candidate")
    commitment_parser.add_argument("destination")
    commitment_parser.add_argument("role", choices=("incoming", "previous"))

    cleanup_parser = subparsers.add_parser("cleanup-transaction")
    cleanup_parser.add_argument("state_file")
    cleanup_parser.add_argument("candidate")
    cleanup_parser.add_argument("destination")

    empty_cleanup_parser = subparsers.add_parser("cleanup-empty-staging")
    empty_cleanup_parser.add_argument("staging")

    discover_parser = subparsers.add_parser("discover")
    discover_parser.add_argument("root")

    locked_parser = subparsers.add_parser("lock-run")
    locked_parser.add_argument("lock_file")
    locked_parser.add_argument("locked_command", nargs=argparse.REMAINDER)

    assert_parser = subparsers.add_parser("assert-lock-session")
    assert_parser.add_argument("lock_file")
    assert_parser.add_argument("descriptor", type=int)
    assert_parser.add_argument("token")

    bounded_parser = subparsers.add_parser("run-bounded")
    bounded_parser.add_argument("timeout", type=float)
    bounded_parser.add_argument("bounded_command", nargs=argparse.REMAINDER)

    args = parser.parse_args()
    try:
        if args.command == "initialize":
            initialize_transaction(args.candidate, args.destination, args.state_file)
        elif args.command == "install":
            print(
                install(
                    args.candidate,
                    args.destination,
                    args.state_file,
                    candidate_commitment=args.candidate_commitment,
                    destination_commitment=args.destination_commitment,
                )
            )
        elif args.command == "rollback-transaction":
            print(
                rollback_transaction(
                    args.state_file,
                    args.candidate,
                    args.destination,
                    preserve_candidate=args.preserve_candidate,
                )
            )
        elif args.command == "mark-phase":
            mark_phase(
                args.state_file, args.candidate, args.destination, args.phase
            )
        elif args.command == "recovery-action":
            print(
                recovery_action(args.state_file, args.candidate, args.destination)
            )
        elif args.command == "commitment":
            value = expected_commitment(
                args.state_file, args.candidate, args.destination, args.role
            )
            print(value if value is not None else "-")
        elif args.command == "cleanup-transaction":
            cleanup_transaction(args.state_file, args.candidate, args.destination)
        elif args.command == "cleanup-empty-staging":
            cleanup_empty_staging(args.staging)
        elif args.command == "discover":
            for path in discover_transactions(args.root):
                print(path)
        elif args.command == "assert-lock-session":
            assert_lock_session(args.lock_file, args.descriptor, args.token)
        elif args.command == "run-bounded":
            command = args.bounded_command
            if command and command[0] == "--":
                command = command[1:]
            run_bounded(args.timeout, command)
        else:
            command = args.locked_command
            if command and command[0] == "--":
                command = command[1:]
            return lock_and_run(args.lock_file, command)
    except (AtomicInstallError, OSError, ValueError) as error:
        print(f"atomic install: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
