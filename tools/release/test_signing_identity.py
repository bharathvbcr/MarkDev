"""Adversarial tests for exact codesigning identity resolution."""

from pathlib import Path
import plistlib
import sys
from types import SimpleNamespace
import tempfile
import unittest
from unittest import mock

import signing_identity


class SigningIdentityTests(unittest.TestCase):
    IDENTITIES = [
        ("A" * 40, "Apple Development: First (AAAAAAAAAA)"),
        ("B" * 40, "Developer ID Application: Release (BBBBBBBBBB)"),
    ]

    def make_restorable_bundle(self, root, *, bundle_id="dev.markdev.MarkDev"):
        app = root / "Previous MarkDev.app"
        contents = app / "Contents"
        executable = contents / "MacOS/MarkDev"
        appex_contents = contents / "PlugIns/MarkDevQuickLook.appex/Contents"
        appex_executable = appex_contents / "MacOS/MarkDevQuickLook"
        executable.parent.mkdir(parents=True)
        appex_executable.parent.mkdir(parents=True)
        executable.write_bytes(b"previous main executable")
        appex_executable.write_bytes(b"previous quick look executable")
        executable.chmod(0o755)
        appex_executable.chmod(0o755)
        with (contents / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": bundle_id,
                    "CFBundleExecutable": "MarkDev",
                    "CFBundlePackageType": "APPL",
                    "CFBundleShortVersionString": "0.0.1",
                    "CFBundleVersion": "old-build",
                    "MarkDevSourceCommit": "older-source-commit",
                },
                stream,
            )
        with (appex_contents / "Info.plist").open("wb") as stream:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "dev.markdev.MarkDev.QuickLook",
                    "CFBundleExecutable": "MarkDevQuickLook",
                    "CFBundlePackageType": "XPC!",
                    "NSExtension": {
                        "NSExtensionPointIdentifier": "com.apple.quicklook.preview"
                    },
                },
                stream,
            )
        return app

    def test_parser_ignores_summary_and_malformed_identity_lines(self):
        output = (
            f'  1) {"A" * 40} "Apple Development: First (AAAAAAAAAA)"\n'
            "  malformed identity\n"
            "     1 valid identities found\n"
        )
        self.assertEqual(signing_identity.parse_valid_identities(output), self.IDENTITIES[:1])

    def test_selector_is_exact_or_one_unambiguous_recognized_class(self):
        self.assertEqual(
            signing_identity.choose_identity("a" * 40, self.IDENTITIES),
            self.IDENTITIES[0],
        )
        self.assertEqual(
            signing_identity.choose_identity(self.IDENTITIES[1][1], self.IDENTITIES),
            self.IDENTITIES[1],
        )
        self.assertEqual(
            signing_identity.choose_identity("Apple Development", self.IDENTITIES),
            self.IDENTITIES[0],
        )
        with self.assertRaises(signing_identity.SigningIdentityError):
            signing_identity.choose_identity("Release", self.IDENTITIES)

    def test_ambiguous_identity_class_fails_closed(self):
        identities = self.IDENTITIES + [
            ("C" * 40, "Apple Development: Second (CCCCCCCCCC)")
        ]
        with self.assertRaises(signing_identity.SigningIdentityError):
            signing_identity.choose_identity("Apple Development", identities)

    def test_certificate_fingerprint_must_match_once(self):
        blocks = ["certificate one", "certificate two"]
        output = "\n".join(
            f"-----BEGIN CERTIFICATE-----\n{value}\n-----END CERTIFICATE-----"
            for value in blocks
        )
        with mock.patch.object(
            signing_identity,
            "certificate_fingerprint",
            side_effect=["A" * 40, "B" * 40],
        ):
            selected = signing_identity.certificate_for_fingerprint(output, "B" * 40)
        self.assertIn("certificate two", selected)

        duplicate = output + "\n-----BEGIN CERTIFICATE-----\nthird\n-----END CERTIFICATE-----"
        with mock.patch.object(
            signing_identity,
            "certificate_fingerprint",
            side_effect=["A" * 40, "A" * 40, "B" * 40],
        ):
            with self.assertRaises(signing_identity.SigningIdentityError):
                signing_identity.certificate_for_fingerprint(duplicate, "A" * 40)

    def test_team_identifier_must_be_one_exact_ten_character_ou(self):
        with mock.patch.object(
            signing_identity,
            "command",
            return_value=SimpleNamespace(stdout="subject=CN=Signer,OU=ABCDEFGHIJ,O=Example\n"),
        ):
            self.assertEqual(signing_identity.team_identifier("pem"), "ABCDEFGHIJ")

        for subject in (
            "subject=CN=Signer,O=Example\n",
            "subject=CN=Signer,OU=SHORT,O=Example\n",
            "subject=CN=Signer,OU=ABCDEFGHIJ,OU=KLMNOPQRST,O=Example\n",
        ):
            with self.subTest(subject=subject):
                with mock.patch.object(
                    signing_identity,
                    "command",
                    return_value=SimpleNamespace(stdout=subject),
                ):
                    with self.assertRaises(signing_identity.SigningIdentityError):
                        signing_identity.team_identifier("pem")

    def test_signature_profile_parses_real_codesign_shape(self):
        output = (
            "CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=1+1 location=embedded\n"
            "Signature size=4812\n"
            "TeamIdentifier=ABCDEFGHIJ\n"
        )
        with mock.patch.object(
            signing_identity,
            "command",
            return_value=SimpleNamespace(stdout="", stderr=output),
        ):
            self.assertEqual(
                signing_identity.signature_profile(Path("MarkDev.app"), "arm64"),
                ("size=4812", "0x10000(runtime)", "ABCDEFGHIJ"),
            )

    def test_signed_verification_rejects_ad_hoc_wrong_team_and_missing_runtime(self):
        cases = (
            ("adhoc", "0x10002(adhoc,runtime)", "ABCDEFGHIJ"),
            ("size=4812", "0x10000(runtime)", "ZZZZZZZZZZ"),
            ("size=4812", "0x0(none)", "ABCDEFGHIJ"),
        )
        for profile in cases:
            with self.subTest(profile=profile):
                with mock.patch.object(
                    signing_identity,
                    "signature_profile",
                    return_value=profile,
                ):
                    with self.assertRaises(signing_identity.SigningIdentityError):
                        signing_identity.verify_exact_signature(
                            Path("MarkDev.app"), "A" * 40, "ABCDEFGHIJ"
                        )

    def test_generic_restorable_verification_accepts_older_metadata_and_commits_all_content(self):
        with tempfile.TemporaryDirectory(prefix="markdev restorable ") as directory:
            app = self.make_restorable_bundle(Path(directory))
            with (
                mock.patch.object(signing_identity, "verify_restorable_signature"),
                mock.patch.object(
                    signing_identity,
                    "current_release_metadata",
                    side_effect=AssertionError("generic rollback must not read current metadata"),
                ),
            ):
                before = signing_identity.verify_restorable(app)
                (app / "Contents/MacOS/MarkDev").write_bytes(b"mutated but still same root")
                after = signing_identity.verify_restorable(app)

        self.assertRegex(before, r"^[0-9a-f]{64}$")
        self.assertRegex(after, r"^[0-9a-f]{64}$")
        self.assertNotEqual(before, after)

    def test_generic_restorable_verification_rejects_wrong_identity_and_root_symlink(self):
        with tempfile.TemporaryDirectory(prefix="markdev restorable ") as directory:
            root = Path(directory)
            wrong = self.make_restorable_bundle(root, bundle_id="example.attacker")
            with mock.patch.object(signing_identity, "verify_restorable_signature"):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.verify_restorable(wrong)

            linked = root / "Linked.app"
            linked.symlink_to(wrong)
            with mock.patch.object(signing_identity, "verify_restorable_signature"):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.verify_restorable(linked)

    def test_restorable_signature_uses_the_actual_thin_arm64_slice_set(self):
        with tempfile.TemporaryDirectory(prefix="markdev thin restorable ") as directory:
            app = self.make_restorable_bundle(Path(directory))
            with (
                mock.patch.object(
                    signing_identity,
                    "executable_architectures",
                    return_value=("arm64",),
                    create=True,
                ) as architectures,
                mock.patch.object(
                    signing_identity,
                    "command",
                    return_value=SimpleNamespace(stdout="", stderr=""),
                ),
                mock.patch.object(
                    signing_identity,
                    "signature_profile",
                    return_value=("adhoc", "0x2(adhoc)", "not set"),
                ) as profile,
            ):
                signing_identity.verify_restorable_signature(app)

        self.assertEqual(architectures.call_count, 2)
        self.assertEqual(profile.call_count, 2)
        self.assertEqual(
            [call.args[1] for call in profile.call_args_list],
            ["arm64", "arm64"],
        )

    def test_restorable_architecture_output_is_exact_nonempty_and_allowed(self):
        self.assertEqual(
            signing_identity.parse_restorable_architectures(b"arm64\n", "main"),
            ("arm64",),
        )
        self.assertEqual(
            signing_identity.parse_restorable_architectures(
                b"arm64 x86_64\n", "main"
            ),
            ("arm64", "x86_64"),
        )
        for malformed in (
            b"",
            b"arm64 arm64\n",
            b"x86_64 arm64 trailing\n",
            b"ppc\n",
            b" arm64\n",
            b"arm64 \n",
            b"arm64\x00\n",
            b"a" * (signing_identity.MAX_ARCHITECTURE_OUTPUT_BYTES + 1),
        ):
            with self.subTest(malformed=malformed):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.parse_restorable_architectures(
                        malformed, "main"
                    )

    def test_architecture_subprocess_output_is_bounded_before_parsing(self):
        with self.assertRaises(signing_identity.SigningIdentityError):
            signing_identity._bounded_command_output(
                (sys.executable, "-c", "print('x' * 4096)"),
                "architecture",
                32,
            )

    def test_restorable_certificate_identity_must_match_across_actual_slices(self):
        with tempfile.TemporaryDirectory(prefix="markdev sliced restorable ") as directory:
            app = self.make_restorable_bundle(Path(directory))
            with (
                mock.patch.object(
                    signing_identity,
                    "executable_architectures",
                    return_value=("arm64", "x86_64"),
                ),
                mock.patch.object(
                    signing_identity,
                    "command",
                    return_value=SimpleNamespace(stdout="", stderr=""),
                ),
                mock.patch.object(
                    signing_identity,
                    "signature_profile",
                    side_effect=[
                        ("size=1", "0x10000(runtime)", "AAAAAAAAAA"),
                        ("size=1", "0x10000(runtime)", "BBBBBBBBBB"),
                    ],
                ),
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.verify_restorable_signature(app)

    def test_restorable_certificate_fingerprint_must_match_actual_slices(self):
        with tempfile.TemporaryDirectory(prefix="markdev sliced restorable ") as directory:
            app = self.make_restorable_bundle(Path(directory))
            with (
                mock.patch.object(
                    signing_identity,
                    "executable_architectures",
                    return_value=("arm64", "x86_64"),
                ),
                mock.patch.object(
                    signing_identity,
                    "command",
                    return_value=SimpleNamespace(stdout="", stderr=""),
                ),
                mock.patch.object(
                    signing_identity,
                    "signature_profile",
                    return_value=(
                        "size=1",
                        "0x10000(runtime)",
                        "AAAAAAAAAA",
                    ),
                ),
                mock.patch.object(
                    signing_identity,
                    "embedded_leaf_fingerprint",
                    side_effect=("A" * 40, "B" * 40),
                ),
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.verify_restorable_signature(app)

    def test_restorable_verification_binds_signature_to_one_stable_commitment(self):
        with tempfile.TemporaryDirectory(prefix="markdev raced restorable ") as directory:
            app = self.make_restorable_bundle(Path(directory))
            with (
                mock.patch.object(signing_identity, "_validate_restorable_layout"),
                mock.patch.object(signing_identity, "verify_restorable_signature"),
                mock.patch.object(
                    signing_identity,
                    "bundle_commitment",
                    side_effect=["a" * 64, "b" * 64],
                ) as commitment,
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.verify_restorable(app)

        self.assertEqual(commitment.call_count, 2)

    def test_manifest_rejects_fanout_before_sorting_the_unbounded_inventory(self):
        with tempfile.TemporaryDirectory(prefix="markdev manifest fanout ") as directory:
            app = Path(directory) / "Bundle.app"
            app.mkdir()
            for index in range(4):
                (app / f"entry-{index}").write_text("payload")
            with (
                mock.patch.object(signing_identity, "MAX_RESTORABLE_ENTRIES", 3),
                mock.patch.object(
                    signing_identity,
                    "sorted",
                    side_effect=AssertionError("unbounded inventory reached sorting"),
                    create=True,
                ),
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.bundle_commitment(app)

    def test_manifest_reads_exact_recorded_size_then_probes_for_growth(self):
        with tempfile.TemporaryDirectory(prefix="markdev manifest growth ") as directory:
            app = Path(directory) / "Bundle.app"
            app.mkdir()
            (app / "payload").write_bytes(b"x")
            real_read = signing_identity.os.read
            reads = 0

            def simulate_growth(descriptor, count):
                nonlocal reads
                reads += 1
                if reads <= 2:
                    return b"x"
                return real_read(descriptor, count)

            with mock.patch.object(
                signing_identity.os, "read", side_effect=simulate_growth
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.bundle_commitment(app)

        self.assertEqual(reads, 2)

    def test_manifest_rejects_excessive_directory_depth(self):
        with tempfile.TemporaryDirectory(prefix="markdev manifest depth ") as directory:
            app = Path(directory) / "Bundle.app"
            leaf = app
            for index in range(4):
                leaf = leaf / f"level-{index}"
                leaf.mkdir(parents=True)
            with mock.patch.object(
                signing_identity, "MAX_RESTORABLE_DEPTH", 2, create=True
            ):
                with self.assertRaises(signing_identity.SigningIdentityError):
                    signing_identity.bundle_commitment(app)


if __name__ == "__main__":
    unittest.main()
