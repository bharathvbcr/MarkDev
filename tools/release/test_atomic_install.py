"""Exercise the real APFS rename primitive used by the installer."""

from pathlib import Path
import json
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

import atomic_install


class AtomicInstallTests(unittest.TestCase):
    INCOMING_COMMITMENT = "a" * 64
    PREVIOUS_COMMITMENT = "b" * 64

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="markdev atomic install ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.candidate = self.root / "candidate.app"
        self.destination = self.root / "MarkDev.app"
        self.candidate.mkdir()
        (self.candidate / "marker").write_text("new")

    def marker(self, path):
        return (path / "marker").read_text()

    def test_new_install_uses_exclusive_rename_and_rolls_back(self):
        outcome = atomic_install.install(self.candidate, self.destination)
        self.assertEqual(outcome, "installed")
        self.assertFalse(self.candidate.exists())
        self.assertEqual(self.marker(self.destination), "new")

        atomic_install.rollback(self.candidate, self.destination, outcome)
        self.assertEqual(self.marker(self.candidate), "new")
        self.assertFalse(self.destination.exists())

    def test_existing_install_swaps_without_a_missing_destination_window(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        outcome = atomic_install.install(self.candidate, self.destination)
        self.assertEqual(outcome, "swapped")
        self.assertEqual(self.marker(self.destination), "new")
        self.assertEqual(self.marker(self.candidate), "old")

        atomic_install.rollback(self.candidate, self.destination, outcome)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.marker(self.candidate), "new")

    def test_symlink_candidate_and_destination_fail_closed(self):
        real = self.root / "real.app"
        real.mkdir()
        linked_candidate = self.root / "linked.app"
        linked_candidate.symlink_to(real)
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.install(linked_candidate, self.destination)

        self.destination.symlink_to(real)
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.install(self.candidate, self.destination)

    def test_durable_journal_recovers_a_swap_after_helper_dies_before_result(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        state = self.root / "transaction.json"
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
renameatx = atomic_install.renameatx
def kill_after_rename(source, destination, flags):
    renameatx(source, destination, flags)
    os.kill(os.getpid(), signal.SIGKILL)
atomic_install.renameatx = kill_after_rename
atomic_install.install(
    {str(self.candidate)!r}, {str(self.destination)!r}, {str(state)!r},
    candidate_commitment={self.INCOMING_COMMITMENT!r},
    destination_commitment={self.PREVIOUS_COMMITMENT!r},
)
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertTrue(state.is_file(), "the pre-rename recovery journal must be durable")
        self.assertEqual(self.marker(self.destination), "new")
        self.assertEqual(self.marker(self.candidate), "old")

        self.assertEqual(
            atomic_install.rollback_transaction(state, self.candidate, self.destination),
            "swapped",
        )
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.marker(self.candidate), "new")

    def test_durable_journal_recovers_a_new_install_after_helper_dies(self):
        state = self.root / "transaction.json"
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
renameatx = atomic_install.renameatx
def kill_after_rename(source, destination, flags):
    renameatx(source, destination, flags)
    os.kill(os.getpid(), signal.SIGKILL)
atomic_install.renameatx = kill_after_rename
atomic_install.install(
    {str(self.candidate)!r}, {str(self.destination)!r}, {str(state)!r},
    candidate_commitment={self.INCOMING_COMMITMENT!r},
)
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertTrue(state.is_file())
        self.assertFalse(self.candidate.exists())
        self.assertEqual(self.marker(self.destination), "new")

        self.assertEqual(
            atomic_install.rollback_transaction(state, self.candidate, self.destination),
            "installed",
        )
        self.assertEqual(self.marker(self.candidate), "new")
        self.assertFalse(self.destination.exists())

    def test_prepared_but_uncommitted_transaction_is_a_safe_no_op(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        state = self.root / "transaction.json"
        atomic_install.prepare_transaction(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
            destination_commitment=self.PREVIOUS_COMMITMENT,
        )

        self.assertEqual(
            atomic_install.rollback_transaction(state, self.candidate, self.destination),
            "not-installed",
        )
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.marker(self.candidate), "new")

    def test_changed_transaction_paths_fail_closed_without_renaming(self):
        state = self.root / "transaction.json"
        atomic_install.prepare_transaction(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        self.destination.mkdir()
        (self.destination / "marker").write_text("intruder")

        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.rollback_transaction(state, self.candidate, self.destination)
        self.assertEqual(self.marker(self.destination), "intruder")
        self.assertEqual(self.marker(self.candidate), "new")

    def test_recovery_is_idempotent_if_rollback_helper_dies_after_rename(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        state = self.root / "transaction.json"
        self.assertEqual(
            atomic_install.install(
                self.candidate,
                self.destination,
                state,
                candidate_commitment=self.INCOMING_COMMITMENT,
                destination_commitment=self.PREVIOUS_COMMITMENT,
            ),
            "swapped",
        )
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
renameatx = atomic_install.renameatx
def kill_after_rename(source, destination, flags):
    renameatx(source, destination, flags)
    os.kill(os.getpid(), signal.SIGKILL)
atomic_install.renameatx = kill_after_rename
atomic_install.rollback_transaction({str(state)!r}, {str(self.candidate)!r}, {str(self.destination)!r})
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.marker(self.candidate), "new")
        self.assertEqual(
            atomic_install.rollback_transaction(state, self.candidate, self.destination),
            "not-installed",
        )
        self.assertEqual(self.marker(self.destination), "old")
        self.assertEqual(self.marker(self.candidate), "new")

    def test_journal_read_stays_on_the_checked_descriptor_during_leaf_substitution(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        state = self.root / "transaction.json"
        atomic_install.prepare_transaction(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
            destination_commitment=self.PREVIOUS_COMMITMENT,
        )
        oversized = self.root / "oversized.json"
        oversized.write_bytes(
            state.read_bytes() + b" " * (atomic_install.MAX_JOURNAL_BYTES + 1)
        )
        real_open = atomic_install.os.open
        substituted = False

        def substitute_after_open(path, flags, *args, **kwargs):
            nonlocal substituted
            descriptor = real_open(path, flags, *args, **kwargs)
            if Path(path).name == state.name and not substituted:
                substituted = True
                state.unlink()
                state.symlink_to(oversized)
            return descriptor

        with mock.patch.object(atomic_install.os, "open", side_effect=substitute_after_open):
            with self.assertRaises(atomic_install.AtomicInstallError):
                atomic_install.read_journal(state)

        self.assertTrue(substituted, "the regression must exercise an open/read race")
        self.assertTrue(state.is_symlink())

    def test_journal_hardlinks_are_rejected(self):
        state = self.root / "transaction.json"
        atomic_install.prepare_transaction(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        os.link(state, self.root / "transaction-copy.json")

        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.read_journal(state)

    def test_destination_substitution_at_swap_never_commits(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        displaced = self.root / "displaced.app"
        state = self.root / "transaction.json"
        real_renameatx = atomic_install.renameatx

        def substitute_destination(source, destination, flags):
            Path(destination).rename(displaced)
            Path(destination).mkdir()
            (Path(destination) / "marker").write_text("intruder")
            real_renameatx(source, destination, flags)

        with mock.patch.object(
            atomic_install, "renameatx", side_effect=substitute_destination
        ):
            with self.assertRaises(atomic_install.AtomicInstallError):
                atomic_install.install(
                    self.candidate,
                    self.destination,
                    state,
                    candidate_commitment=self.INCOMING_COMMITMENT,
                    destination_commitment=self.PREVIOUS_COMMITMENT,
                )

        self.assertEqual(json.loads(state.read_text())["phase"], "prepared")
        self.assertEqual(self.marker(self.destination), "new")
        self.assertEqual(self.marker(self.candidate), "intruder")
        self.assertEqual(self.marker(displaced), "old")

    def test_lock_is_exclusive_and_rejects_a_symlink(self):
        lock = self.root / "install.lock"
        first = atomic_install.acquire_install_lock(lock)
        self.addCleanup(os.close, first)
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.acquire_install_lock(lock)

        linked = self.root / "linked.lock"
        linked.symlink_to(lock)
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.acquire_install_lock(linked)

    def test_recovery_policy_rolls_back_until_activation_then_finalizes(self):
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        state = self.root / "transaction.json"
        self.assertEqual(
            atomic_install.install(
                self.candidate,
                self.destination,
                state,
                candidate_commitment=self.INCOMING_COMMITMENT,
                destination_commitment=self.PREVIOUS_COMMITMENT,
            ),
            "swapped",
        )
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "rollback-swapped",
        )

        atomic_install.mark_phase(state, self.candidate, self.destination, "verified")
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "rollback-swapped",
        )

        atomic_install.mark_phase(state, self.candidate, self.destination, "activated")
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "finalize-swapped",
        )

    def test_allocating_phase_recovers_a_partial_copy_without_touching_destination(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir()
        staging.chmod(0o700)
        candidate = staging / "candidate.app"
        state = staging / "transaction.json"
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        atomic_install.initialize_transaction(candidate, self.destination, state)
        candidate.mkdir()
        (candidate / "partial").write_text("not a complete app")

        self.assertEqual(
            atomic_install.recovery_action(state, candidate, self.destination),
            "cleanup-allocating",
        )
        self.assertEqual(self.marker(self.destination), "old")

    def test_cleanup_refuses_an_unknown_staging_root_entry(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir()
        staging.chmod(0o700)
        candidate = staging / "candidate.app"
        state = staging / "transaction.json"
        atomic_install.initialize_transaction(candidate, self.destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        (staging / "unknown-root").write_text("preserve me")

        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.cleanup_transaction(state, candidate, self.destination)
        self.assertTrue(staging.is_dir())
        self.assertEqual((staging / "unknown-root").read_text(), "preserve me")

    def test_discovery_fails_closed_for_multiple_or_malformed_staging_roots(self):
        first = self.root / ".MarkDev-install.ABC123"
        second = self.root / ".MarkDev-install.DEF456"
        first.mkdir()
        second.mkdir()
        first.chmod(0o700)
        second.chmod(0o700)
        self.assertEqual(
            atomic_install.discover_transactions(self.root),
            [first, second],
        )

        malformed = self.root / ".MarkDev-install.not-safe!"
        malformed.mkdir()
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.discover_transactions(self.root)

    def test_known_allocating_staging_tree_is_cleaned_without_following_symlinks(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        state = staging / "transaction.json"
        outside = self.root / "outside"
        outside.mkdir()
        (outside / "preserve").write_text("outside")
        atomic_install.initialize_transaction(candidate, self.destination, state)
        candidate.mkdir()
        (candidate / "payload").write_text("partial")
        (candidate / "linked").symlink_to(outside, target_is_directory=True)

        atomic_install.cleanup_transaction(state, candidate, self.destination)

        self.assertFalse(staging.exists())
        self.assertEqual((outside / "preserve").read_text(), "outside")

    def test_malformed_journal_value_types_fail_closed(self):
        state = self.root / "transaction.json"
        atomic_install.prepare_transaction(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        baseline = json.loads(state.read_text())
        for field, value in (("phase", []), ("outcome", {}), ("version", True)):
            with self.subTest(field=field):
                journal = dict(baseline)
                journal[field] = value
                atomic_install.write_journal(state, journal)
                with self.assertRaises(atomic_install.AtomicInstallError):
                    atomic_install.transaction_position(
                        state, self.candidate, self.destination
                    )

    def test_new_install_crash_policy_is_rollback_before_activation_and_finalize_after(self):
        state = self.root / "transaction.json"
        atomic_install.install(
            self.candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "rollback-installed",
        )
        atomic_install.mark_phase(state, self.candidate, self.destination, "verified")
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "rollback-installed",
        )
        atomic_install.mark_phase(state, self.candidate, self.destination, "activated")
        self.assertEqual(
            atomic_install.recovery_action(state, self.candidate, self.destination),
            "finalize-installed",
        )

    def test_lock_run_refuses_a_concurrent_process_and_releases_on_close(self):
        lock = self.root / "install.lock"
        descriptor = atomic_install.acquire_install_lock(lock)
        helper = Path(atomic_install.__file__).resolve()
        blocked = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                "/usr/bin/true",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(blocked.returncode, 1)
        self.assertIn("already running", blocked.stderr)
        os.close(descriptor)

        released = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                "/usr/bin/true",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(released.returncode, 0, released.stderr)

    def test_lock_run_never_exposes_the_lock_descriptor_to_its_worker(self):
        lock = self.root / "install.lock"
        helper = Path(atomic_install.__file__).resolve()
        probe = """
import os
import sys
lock = os.stat(sys.argv[1], follow_symlinks=False)
for descriptor in range(3, 256):
    try:
        opened = os.fstat(descriptor)
    except OSError:
        continue
    if (opened.st_dev, opened.st_ino) == (lock.st_dev, lock.st_ino):
        raise SystemExit(19)
"""

        result = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                sys.executable,
                "-c",
                probe,
                str(lock),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_detached_worker_descendant_cannot_extend_the_lock_lifetime(self):
        lock = self.root / "install.lock"
        helper = Path(atomic_install.__file__).resolve()
        spawn_detached = """
import subprocess
import sys
subprocess.Popen(
    [sys.executable, "-c", "import time; time.sleep(2)"],
    close_fds=False,
    start_new_session=True,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
)
"""
        first = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                sys.executable,
                "-c",
                spawn_detached,
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(first.returncode, 0, first.stderr)

        second = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                "/usr/bin/true",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(second.returncode, 0, second.stderr)

    def test_lock_run_serializes_only_the_live_worker_lifecycle(self):
        lock = self.root / "install.lock"
        ready = self.root / "worker-ready"
        release = self.root / "worker-release"
        helper = Path(atomic_install.__file__).resolve()
        worker_script = """
from pathlib import Path
import sys
import time
Path(sys.argv[1]).write_text("ready")
deadline = time.monotonic() + 5
release = Path(sys.argv[2])
while not release.exists() and time.monotonic() < deadline:
    time.sleep(0.01)
"""
        first = subprocess.Popen(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                sys.executable,
                "-c",
                worker_script,
                str(ready),
                str(release),
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        try:
            for _ in range(100):
                if ready.is_file():
                    break
                if first.poll() is not None:
                    break
                time.sleep(0.01)
            self.assertTrue(ready.is_file(), "lock worker did not signal readiness")
            blocked = subprocess.run(
                [
                    sys.executable,
                    str(helper),
                    "lock-run",
                    str(lock),
                    "--",
                    "/usr/bin/true",
                ],
                capture_output=True,
                text=True,
                check=False,
            )
            self.assertEqual(blocked.returncode, 1)
            self.assertIn("already running", blocked.stderr)
            release.write_text("release")
            stdout, stderr = first.communicate(timeout=2)
            self.assertEqual(first.returncode, 0, stdout + stderr)
        finally:
            if first.poll() is None:
                release.write_text("release")
                first.terminate()
                first.communicate(timeout=2)
            else:
                if first.stdout is not None:
                    first.stdout.close()
                if first.stderr is not None:
                    first.stderr.close()

        released = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                "/usr/bin/true",
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(released.returncode, 0, released.stderr)

    def test_lock_worker_consumes_one_shot_proof_without_receiving_flock(self):
        lock = self.root / "install.lock"
        helper = Path(atomic_install.__file__).resolve()
        module_directory = helper.parent
        worker = f"""
import os
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
descriptor = int(os.environ["MARKDEV_INSTALL_GUARD_FD"])
atomic_install.assert_lock_session(
    sys.argv[1], descriptor, os.environ["MARKDEV_INSTALL_GUARD_TOKEN"]
)
lock = os.stat(sys.argv[1], follow_symlinks=False)
for candidate in range(3, 256):
    try:
        opened = os.fstat(candidate)
    except OSError:
        continue
    if (opened.st_dev, opened.st_ino) == (lock.st_dev, lock.st_ino):
        raise SystemExit(23)
"""

        result = subprocess.run(
            [
                sys.executable,
                str(helper),
                "lock-run",
                str(lock),
                "--",
                sys.executable,
                "-c",
                worker,
                str(lock),
            ],
            capture_output=True,
            text=True,
            check=False,
        )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_incomplete_lock_session_pipe_fails_without_waiting_for_eof(self):
        lock = self.root / "install.lock"
        reader, writer = os.pipe()
        self.addCleanup(os.close, writer)

        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.assert_lock_session(lock, reader, "a" * 64)

    def test_bounded_commands_fail_on_nonzero_status_and_timeout(self):
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.run_bounded(
                1, [sys.executable, "-c", "raise SystemExit(7)"]
            )
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.run_bounded(
                0.01,
                [sys.executable, "-c", "import time; time.sleep(10)"],
            )

    def test_staging_walks_are_bounded_without_materializing_unbounded_scandir(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        for index in range(3):
            (staging / f"entry-{index}").write_text("payload")
        descriptor = os.open(staging, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        self.addCleanup(os.close, descriptor)

        with mock.patch.object(
            atomic_install, "MAX_STAGING_ENTRIES", 2, create=True
        ):
            with self.assertRaises(atomic_install.AtomicInstallError):
                atomic_install._preflight_tree(
                    descriptor, os.fstat(descriptor).st_dev
                )

    def test_staging_walks_reject_excessive_depth(self):
        staging = self.root / ".MarkDev-install.ABC123"
        leaf = staging
        for index in range(4):
            leaf = leaf / f"level-{index}"
            leaf.mkdir(parents=True, mode=0o700)
        descriptor = os.open(staging, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        self.addCleanup(os.close, descriptor)

        with mock.patch.object(
            atomic_install, "MAX_STAGING_DEPTH", 2, create=True
        ):
            with self.assertRaises(atomic_install.AtomicInstallError):
                atomic_install._preflight_tree(
                    descriptor, os.fstat(descriptor).st_dev
                )

    def test_discovery_bounds_even_non_transaction_root_entries(self):
        for index in range(3):
            (self.root / f"ordinary-{index}").mkdir()

        with mock.patch.object(
            atomic_install, "MAX_DISCOVERY_ENTRIES", 2, create=True
        ):
            with self.assertRaises(atomic_install.AtomicInstallError):
                atomic_install.discover_transactions(self.root)

    def test_mutated_pending_swap_restores_prior_and_quarantines_incoming(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        destination = self.root / "MarkDev.app"
        state = staging / "transaction.json"
        destination.mkdir()
        (destination / "marker").write_text("old")
        atomic_install.initialize_transaction(candidate, destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        atomic_install.install(
            candidate,
            destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
            destination_commitment=self.PREVIOUS_COMMITMENT,
        )
        destination_identity = destination.stat()
        (destination / "marker").write_text("mutated")
        self.assertEqual(
            (destination.stat().st_dev, destination.stat().st_ino),
            (destination_identity.st_dev, destination_identity.st_ino),
        )

        atomic_install.rollback_transaction(
            state, candidate, destination, preserve_candidate=True
        )

        self.assertEqual((destination / "marker").read_text(), "old")
        self.assertEqual((candidate / "marker").read_text(), "mutated")
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, destination),
            "preserve-swapped",
        )

    def test_mutated_pending_first_install_is_withdrawn_and_quarantined(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        destination = self.root / "MarkDev.app"
        state = staging / "transaction.json"
        atomic_install.initialize_transaction(candidate, destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        atomic_install.install(
            candidate,
            destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        destination_identity = destination.stat()
        (destination / "marker").write_text("mutated")
        self.assertEqual(
            (destination.stat().st_dev, destination.stat().st_ino),
            (destination_identity.st_dev, destination_identity.st_ino),
        )

        atomic_install.rollback_transaction(
            state, candidate, destination, preserve_candidate=True
        )

        self.assertFalse(destination.exists())
        self.assertEqual((candidate / "marker").read_text(), "mutated")
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, destination),
            "preserve-installed",
        )

    def test_preserve_intent_survives_sigkill_after_rollback_rename(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        destination = self.root / "MarkDev.app"
        state = staging / "transaction.json"
        destination.mkdir()
        (destination / "marker").write_text("old")
        atomic_install.initialize_transaction(candidate, destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        atomic_install.install(
            candidate,
            destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
            destination_commitment=self.PREVIOUS_COMMITMENT,
        )
        (destination / "marker").write_text("mutated")
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
renameatx = atomic_install.renameatx
def kill_after_rename(source, destination, flags):
    renameatx(source, destination, flags)
    os.kill(os.getpid(), signal.SIGKILL)
atomic_install.renameatx = kill_after_rename
atomic_install.rollback_transaction(
    {str(state)!r}, {str(candidate)!r}, {str(destination)!r},
    preserve_candidate=True,
)
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)

        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertEqual((destination / "marker").read_text(), "old")
        self.assertEqual((candidate / "marker").read_text(), "mutated")
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, destination),
            "preserve-swapped",
        )
        atomic_install.rollback_transaction(
            state, candidate, destination, preserve_candidate=True
        )
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, destination),
            "preserve-swapped",
        )

    def test_cleanup_covers_activated_and_rolled_back_new_and_swap_positions(self):
        for prior_exists in (False, True):
            for activated in (False, True):
                with self.subTest(prior_exists=prior_exists, activated=activated):
                    with tempfile.TemporaryDirectory(
                        prefix="markdev cleanup matrix "
                    ) as directory:
                        root = Path(directory)
                        staging = root / ".MarkDev-install.ABC123"
                        staging.mkdir(mode=0o700)
                        candidate = staging / "candidate.app"
                        destination = root / "MarkDev.app"
                        state = staging / "transaction.json"
                        if prior_exists:
                            destination.mkdir()
                            (destination / "marker").write_text("old")
                        atomic_install.initialize_transaction(candidate, destination, state)
                        candidate.mkdir()
                        (candidate / "marker").write_text("new")
                        atomic_install.install(
                            candidate,
                            destination,
                            state,
                            candidate_commitment=self.INCOMING_COMMITMENT,
                            destination_commitment=(
                                self.PREVIOUS_COMMITMENT if prior_exists else None
                            ),
                        )
                        if activated:
                            atomic_install.mark_phase(
                                state, candidate, destination, "verified"
                            )
                            atomic_install.mark_phase(
                                state, candidate, destination, "activated"
                            )
                        else:
                            atomic_install.rollback_transaction(
                                state, candidate, destination
                            )

                        atomic_install.cleanup_transaction(
                            state, candidate, destination
                        )

                        self.assertFalse(staging.exists())
                        if prior_exists:
                            expected = "new" if activated else "old"
                            self.assertEqual((destination / "marker").read_text(), expected)
                        else:
                            self.assertEqual(destination.exists(), activated)

    def test_cleanup_resumes_after_sigkill_with_journal_retained(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        state = staging / "transaction.json"
        self.destination.mkdir()
        (self.destination / "marker").write_text("old")
        atomic_install.initialize_transaction(candidate, self.destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        atomic_install.install(
            candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
            destination_commitment=self.PREVIOUS_COMMITMENT,
        )
        atomic_install.mark_phase(state, candidate, self.destination, "verified")
        atomic_install.mark_phase(state, candidate, self.destination, "activated")
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
def kill_at_checkpoint(name):
    if name == "after-payload-removal":
        os.kill(os.getpid(), signal.SIGKILL)
atomic_install._cleanup_checkpoint = kill_at_checkpoint
atomic_install.cleanup_transaction(
    {str(state)!r}, {str(candidate)!r}, {str(self.destination)!r}
)
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertTrue(state.is_file())
        self.assertFalse(candidate.exists())
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, self.destination),
            "resume-cleanup-finalized-swapped",
        )

        atomic_install.cleanup_transaction(state, candidate, self.destination)
        self.assertFalse(staging.exists())
        self.assertEqual(self.marker(self.destination), "new")

    def test_empty_staging_root_after_cleanup_sigkill_is_safely_discoverable(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        state = staging / "transaction.json"
        atomic_install.initialize_transaction(candidate, self.destination, state)
        candidate.mkdir()
        (candidate / "marker").write_text("new")
        atomic_install.install(
            candidate,
            self.destination,
            state,
            candidate_commitment=self.INCOMING_COMMITMENT,
        )
        atomic_install.mark_phase(state, candidate, self.destination, "verified")
        atomic_install.mark_phase(state, candidate, self.destination, "activated")
        module_directory = Path(atomic_install.__file__).resolve().parent
        program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
def kill_at_checkpoint(name):
    if name == "after-journal-removal":
        os.kill(os.getpid(), signal.SIGKILL)
atomic_install._cleanup_checkpoint = kill_at_checkpoint
atomic_install.cleanup_transaction(
    {str(state)!r}, {str(candidate)!r}, {str(self.destination)!r}
)
"""
        result = subprocess.run([sys.executable, "-c", program], check=False)
        self.assertEqual(result.returncode, -signal.SIGKILL)
        self.assertTrue(staging.is_dir())
        self.assertEqual(list(staging.iterdir()), [])
        self.assertEqual(
            atomic_install.recovery_action(state, candidate, self.destination),
            "cleanup-empty",
        )

        atomic_install.cleanup_empty_staging(staging)
        self.assertFalse(staging.exists())
        self.assertEqual(self.marker(self.destination), "new")

    def test_rolled_back_cleanup_resumes_after_sigkill_for_install_and_swap(self):
        module_directory = Path(atomic_install.__file__).resolve().parent
        for prior_exists in (False, True):
            with self.subTest(prior_exists=prior_exists):
                with tempfile.TemporaryDirectory(
                    prefix="markdev rolled back cleanup crash "
                ) as directory:
                    root = Path(directory)
                    staging = root / ".MarkDev-install.ABC123"
                    staging.mkdir(mode=0o700)
                    candidate = staging / "candidate.app"
                    destination = root / "MarkDev.app"
                    state = staging / "transaction.json"
                    if prior_exists:
                        destination.mkdir()
                        (destination / "marker").write_text("old")
                    atomic_install.initialize_transaction(candidate, destination, state)
                    candidate.mkdir()
                    (candidate / "marker").write_text("new")
                    atomic_install.install(
                        candidate,
                        destination,
                        state,
                        candidate_commitment=self.INCOMING_COMMITMENT,
                        destination_commitment=(
                            self.PREVIOUS_COMMITMENT if prior_exists else None
                        ),
                    )
                    atomic_install.rollback_transaction(state, candidate, destination)
                    program = f"""
import os
import signal
import sys
sys.path.insert(0, {str(module_directory)!r})
import atomic_install
def kill_at_checkpoint(name):
    if name == "after-payload-removal":
        os.kill(os.getpid(), signal.SIGKILL)
atomic_install._cleanup_checkpoint = kill_at_checkpoint
atomic_install.cleanup_transaction(
    {str(state)!r}, {str(candidate)!r}, {str(destination)!r}
)
"""
                    result = subprocess.run(
                        [sys.executable, "-c", program], check=False
                    )
                    self.assertEqual(result.returncode, -signal.SIGKILL)
                    self.assertTrue(state.is_file())
                    self.assertFalse(candidate.exists())
                    outcome = "swapped" if prior_exists else "installed"
                    self.assertEqual(
                        atomic_install.recovery_action(
                            state, candidate, destination
                        ),
                        f"resume-cleanup-rolledback-{outcome}",
                    )
                    atomic_install.cleanup_transaction(
                        state, candidate, destination
                    )
                    self.assertFalse(staging.exists())
                    if prior_exists:
                        self.assertEqual(
                            (destination / "marker").read_text(), "old"
                        )
                    else:
                        self.assertFalse(destination.exists())

    def test_journal_less_nonempty_staging_root_is_preserved(self):
        staging = self.root / ".MarkDev-install.ABC123"
        staging.mkdir(mode=0o700)
        candidate = staging / "candidate.app"
        candidate.mkdir()
        (candidate / "marker").write_text("unknown")
        state = staging / "transaction.json"

        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.recovery_action(state, candidate, self.destination)
        with self.assertRaises(atomic_install.AtomicInstallError):
            atomic_install.cleanup_empty_staging(staging)

        self.assertEqual((candidate / "marker").read_text(), "unknown")


if __name__ == "__main__":
    unittest.main()
