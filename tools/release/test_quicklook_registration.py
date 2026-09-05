import importlib.util
import plistlib
import subprocess
import tempfile
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
HELPER = ROOT / "tools/release/quicklook_registration.py"
EXPECTED_CONTENT_TYPES = (
    ("md", "net.daringfireball.markdown"),
    ("markdown", "net.daringfireball.markdown"),
    ("mdown", "dev.markdev.markdown-extended"),
    ("mdx", "dev.markdev.markdown-extended"),
    ("mkd", "dev.markdev.markdown-extended"),
    ("markdn", "dev.markdev.markdown-extended"),
)


def load_helper():
    spec = importlib.util.spec_from_file_location("quicklook_registration", HELPER)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load the Quick Look registration verifier")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class FakeCommandRunner:
    def __init__(
        self,
        appex,
        *,
        registered_path=None,
        registration_label="dev.markdev.MarkDev.QuickLook(0.0.4)",
        bad_extension=None,
        pluginkit_status=0,
    ):
        self.appex = str(appex)
        self.registered_path = str(registered_path or appex)
        self.registration_label = registration_label
        self.bad_extension = bad_extension
        self.pluginkit_status = pluginkit_status
        self.calls = []

    def __call__(self, command, **kwargs):
        self.calls.append(tuple(str(part) for part in command))
        executable = str(command[0])
        if executable == "/usr/bin/pluginkit":
            output = (
                f"     {self.registration_label}\tfixture-id\t"
                f"fixture-date\t{self.registered_path}\n (1 plug-in)\n"
            )
            return subprocess.CompletedProcess(
                command,
                self.pluginkit_status,
                stdout=output if self.pluginkit_status == 0 else "",
                stderr="fixture pluginkit failure" if self.pluginkit_status else "",
            )
        if executable == "/usr/bin/mdls":
            extension = Path(command[-1]).suffix.removeprefix(".")
            expected = dict(EXPECTED_CONTENT_TYPES)[extension]
            value = "com.example.wrong" if extension == self.bad_extension else expected
            return subprocess.CompletedProcess(command, 0, stdout=value + "\n", stderr="")
        raise AssertionError(f"unexpected command: {command!r}")


class QuickLookRegistrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary_directory.cleanup)
        self.appex = Path(self.temporary_directory.name).resolve() / "MarkDevQuickLook.appex"
        contents = self.appex / "Contents"
        contents.mkdir(parents=True)
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {"CFBundleIdentifier": "dev.markdev.MarkDev.QuickLook"},
                stream,
            )

    def test_preview_status_delegates_to_the_canonical_verifier(self):
        self.assertTrue(HELPER.is_file(), "Quick Look verification needs one canonical owner")
        justfile = (ROOT / "justfile").read_text()
        self.assertIn(
            'python3 tools/release/quicklook_registration.py check "$appex"',
            justfile,
        )

    def test_exact_six_extension_content_type_table_passes(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()
        self.assertEqual(helper.EXPECTED_CONTENT_TYPES, EXPECTED_CONTENT_TYPES)
        runner = FakeCommandRunner(self.appex)

        result = helper.verify_once(self.appex, run_command=runner)

        self.assertEqual(result.content_types, EXPECTED_CONTENT_TYPES)
        mdls_extensions = tuple(
            Path(call[-1]).suffix.removeprefix(".")
            for call in runner.calls
            if call[0] == "/usr/bin/mdls"
        )
        self.assertEqual(mdls_extensions, tuple(ext for ext, _ in EXPECTED_CONTENT_TYPES))

    def test_every_wrong_content_type_fails_closed(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()
        for extension, _ in EXPECTED_CONTENT_TYPES:
            with self.subTest(extension=extension):
                runner = FakeCommandRunner(self.appex, bad_extension=extension)
                with self.assertRaisesRegex(
                    helper.QuickLookVerificationError,
                    rf"\.{extension}.*expected",
                ):
                    helper.verify_once(self.appex, run_command=runner)

    def test_query_failure_and_wrong_registered_path_fail_closed(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "pluginkit query failed"):
            helper.verify_once(
                self.appex,
                run_command=FakeCommandRunner(self.appex, pluginkit_status=9),
            )
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "not registered"):
            helper.verify_once(
                self.appex,
                run_command=FakeCommandRunner(
                    self.appex,
                    registered_path=self.appex.parent / "other.appex",
                ),
            )

    def test_registration_identifier_field_must_match_in_full(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()
        runner = FakeCommandRunner(
            self.appex,
            registration_label="dev.markdev.MarkDev.QuickLook(0.0.4)-shadow",
        )
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "not registered"):
            helper.verify_once(self.appex, run_command=runner)

    def test_registration_retry_is_bounded_and_can_observe_propagation(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()

        class PropagatingRunner(FakeCommandRunner):
            def __init__(self, appex, succeeds_on_query):
                super().__init__(appex)
                self.succeeds_on_query = succeeds_on_query
                self.query_count = 0

            def __call__(self, command, **kwargs):
                if str(command[0]) == "/usr/bin/pluginkit":
                    self.query_count += 1
                    if self.query_count < self.succeeds_on_query:
                        original = self.registered_path
                        self.registered_path = str(self.appex) + ".stale"
                        try:
                            return super().__call__(command, **kwargs)
                        finally:
                            self.registered_path = original
                return super().__call__(command, **kwargs)

        sleeps = []
        succeeds = PropagatingRunner(self.appex, succeeds_on_query=2)
        helper.verify_with_retry(
            self.appex,
            attempts=2,
            delay_seconds=0.25,
            run_command=succeeds,
            sleep=sleeps.append,
        )
        self.assertEqual(succeeds.query_count, 2)
        self.assertEqual(sleeps, [0.25])

        exhausted = PropagatingRunner(self.appex, succeeds_on_query=99)
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "after 3 attempts"):
            helper.verify_with_retry(
                self.appex,
                attempts=3,
                delay_seconds=0.25,
                run_command=exhausted,
                sleep=lambda _: None,
            )
        self.assertEqual(exhausted.query_count, 3)

    def test_wait_uses_one_deadline_for_all_dependency_calls_and_sleeps(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()

        class FakeClock:
            def __init__(self):
                self.now = 100.0

            def monotonic(self):
                return self.now

            def sleep(self, duration):
                self.now += duration

        clock = FakeClock()
        observed_timeouts = []

        def timeout_runner(command, **kwargs):
            timeout = kwargs["timeout"]
            observed_timeouts.append(timeout)
            clock.now += timeout
            raise subprocess.TimeoutExpired(command, timeout)

        with self.assertRaisesRegex(helper.QuickLookVerificationError, "15.*seconds"):
            helper.verify_with_retry(
                self.appex,
                attempts=99,
                delay_seconds=0.5,
                overall_timeout_seconds=15.0,
                run_command=timeout_runner,
                sleep=clock.sleep,
                monotonic=clock.monotonic,
            )
        self.assertEqual(clock.now, 115.0)
        self.assertGreater(len(observed_timeouts), 1)
        self.assertTrue(all(0 < timeout <= 3.0 for timeout in observed_timeouts))
        self.assertLessEqual(sum(observed_timeouts), 15.0)

    def test_wait_does_not_retry_immutable_bundle_validation(self):
        if not HELPER.is_file():
            self.skipTest("production verifier not implemented yet")
        helper = load_helper()
        info_plist = self.appex / "Contents/Info.plist"
        with info_plist.open("wb") as stream:
            plistlib.dump({"CFBundleIdentifier": "com.example.wrong"}, stream)
        runner = FakeCommandRunner(self.appex)
        sleeps = []

        with self.assertRaisesRegex(helper.QuickLookVerificationError, "identifier mismatch"):
            helper.verify_with_retry(
                self.appex,
                attempts=21,
                delay_seconds=0.5,
                run_command=runner,
                sleep=sleeps.append,
            )
        self.assertEqual(runner.calls, [])
        self.assertEqual(sleeps, [])

    def test_absent_mode_requires_the_exact_retired_path_to_disappear(self):
        helper = load_helper()
        exact = FakeCommandRunner(self.appex)
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "still registered"):
            helper.verify_absent_with_retry(
                self.appex,
                attempts=2,
                delay_seconds=0,
                overall_timeout_seconds=1,
                run_command=exact,
                sleep=lambda _: None,
            )
        self.assertEqual(
            len([call for call in exact.calls if call[0] == "/usr/bin/pluginkit"]),
            2,
        )

        other_path = FakeCommandRunner(
            self.appex,
            registered_path=self.appex.parent / "other.appex",
        )
        helper.verify_absent_with_retry(
            self.appex,
            attempts=1,
            delay_seconds=0,
            overall_timeout_seconds=1,
            run_command=other_path,
            sleep=lambda _: None,
        )
        self.assertFalse(
            any(call[0] == "/usr/bin/mdls" for call in other_path.calls),
            "absence is an exact registration-path check, not a UTI ownership claim",
        )

        missing = self.appex.parent / "Removed.app/Contents/PlugIns/MarkDevQuickLook.appex"
        missing_runner = FakeCommandRunner(
            missing,
            registered_path=self.appex.parent / "other.appex",
        )
        helper.verify_absent_with_retry(
            missing,
            attempts=1,
            delay_seconds=0,
            overall_timeout_seconds=1,
            run_command=missing_runner,
            sleep=lambda _: None,
        )

    def test_absent_mode_fails_closed_on_query_failure_and_symlink_input(self):
        helper = load_helper()
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "query failed"):
            helper.verify_absent_with_retry(
                self.appex,
                attempts=1,
                delay_seconds=0,
                overall_timeout_seconds=1,
                run_command=FakeCommandRunner(self.appex, pluginkit_status=9),
                sleep=lambda _: None,
            )

        linked = self.appex.parent / "Linked.appex"
        linked.symlink_to(self.appex)
        runner = FakeCommandRunner(linked, registered_path=self.appex.parent / "other.appex")
        with self.assertRaisesRegex(helper.QuickLookVerificationError, "not a directory"):
            helper.verify_absent_with_retry(
                linked,
                attempts=3,
                delay_seconds=0,
                overall_timeout_seconds=1,
                run_command=runner,
                sleep=lambda _: None,
            )
        self.assertEqual(runner.calls, [])


if __name__ == "__main__":
    unittest.main()
