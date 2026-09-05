"""Check effective Xcode settings so target presets cannot override release metadata."""
import json
from pathlib import Path
import plistlib
import re
import unittest

from release import EXPECTED_PRIVACY_MANIFEST, metadata, run

LOCKED_PACKAGE_FLAGS = (
    "-onlyUsePackageVersionsFromResolvedFile",
    "-skipPackageUpdates",
)


class ProjectVersionTests(unittest.TestCase):
    def test_contract_suite_does_not_depend_on_ignored_local_instruction_files(self):
        source = Path(__file__).read_text()
        ignored_reference = 'Path("CLAUDE' + '.md")'
        self.assertNotIn(
            ignored_reference,
            source,
            "clean CI checkouts do not contain the ignored local instruction mirror",
        )

    def test_privacy_manifest_omits_empty_optional_categories(self):
        with Path("app/PrivacyInfo.xcprivacy").open("rb") as stream:
            manifest = plistlib.load(stream)

        self.assertNotIn(
            "NSPrivacyAccessedAPITypes",
            manifest,
            "Apple rejects an empty required-reason API array; macOS does not require one",
        )
        self.assertNotIn(
            "NSPrivacyTrackingDomains",
            manifest,
            "a non-tracking app must omit the tracking-domain list",
        )

    def test_every_shipping_bundle_declares_the_same_no_collection_privacy_manifest(self):
        manifest_path = Path("app/PrivacyInfo.xcprivacy")
        self.assertTrue(
            manifest_path.is_file(),
            "shipping bundles need a machine-readable privacy declaration",
        )
        with manifest_path.open("rb") as stream:
            manifest = plistlib.load(stream)
        self.assertEqual(
            manifest,
            EXPECTED_PRIVACY_MANIFEST,
            "MarkDev diagnostics stay local and must not claim tracking or collection",
        )

        source = Path("project.yml").read_text()
        for target in ("MarkDev", "MarkDevKit", "MarkDevQuickLook"):
            with self.subTest(target=target):
                block = self._target_block(source, target)
                self.assertRegex(
                    block,
                    r"- path: app/PrivacyInfo\.xcprivacy\s+buildPhase: resources",
                    "every executable or dynamic-library bundle needs the canonical manifest",
                )

    def test_swift_packages_are_fully_locked(self):
        source = Path("project.yml").read_text()
        packages_source = source.split("packages:\n", 1)[1].split("\ntargets:\n", 1)[0]
        package_blocks = {
            match.group("name"): match.group("body")
            for match in re.finditer(
                r"^  (?P<name>[A-Za-z0-9_-]+):\n(?P<body>(?:    [^\n]*\n)+)",
                packages_source,
                re.MULTILINE,
            )
        }
        self.assertTrue(package_blocks, "project.yml must declare its package inputs")

        expected_by_url = {}
        for name, body in package_blocks.items():
            with self.subTest(package=name):
                self.assertNotRegex(
                    body,
                    r"^    (?:from|majorVersion|minorVersion|minVersion|maxVersion|branch):",
                    "release inputs must not float to a different source version",
                )
                url = re.search(r"^    url:\s*(\S+)\s*$", body, re.MULTILINE)
                version = re.search(r"^    exactVersion:\s*(\S+)\s*$", body, re.MULTILINE)
                self.assertIsNotNone(url, "remote packages need an auditable source URL")
                self.assertIsNotNone(version, "direct packages must use exactVersion")
                if url is not None and version is not None:
                    expected_by_url[url.group(1).removesuffix(".git")] = version.group(1)

        lock_path = Path(
            "MarkDev.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
        )
        self.assertTrue(lock_path.is_file(), "the transitive SwiftPM lock must ship with the source")
        ignored = run("git", "check-ignore", "-q", str(lock_path), check=False)
        self.assertNotEqual(
            ignored.returncode,
            0,
            "Package.resolved must be visible to source control rather than hidden as generated output",
        )
        resolved = json.loads(lock_path.read_text())
        pins = resolved.get("pins")
        self.assertIsInstance(pins, list)
        by_url = {
            pin.get("location", "").removesuffix(".git"): pin.get("state", {})
            for pin in pins
        }
        for url, version in expected_by_url.items():
            with self.subTest(url=url):
                self.assertIn(url, by_url, "every direct package must be in Package.resolved")
                state = by_url[url]
                self.assertEqual(state.get("version"), version)
                self.assertRegex(
                    state.get("revision", ""),
                    r"^[0-9a-f]{40}$",
                    "the lock must bind the exact source revision, not only a tag",
                )
        for pin in pins:
            with self.subTest(pin=pin.get("identity")):
                self.assertRegex(pin.get("state", {}).get("revision", ""), r"^[0-9a-f]{40}$")

    def test_clean_recipe_preserves_the_transitive_package_lock(self):
        source = Path("justfile").read_text()
        match = re.search(
            r"^clean:\n(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)",
            source,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match)
        if match is not None:
            self.assertNotIn(
                "rm -rf MarkDev.xcodeproj",
                match.group("body"),
                "clean must not delete the committed Package.resolved inside the generated project",
            )

    def test_owned_xcodebuild_paths_refuse_package_drift(self):
        required = LOCKED_PACKAGE_FLAGS
        just_source = re.sub(r"\\\n\s*", " ", Path("justfile").read_text())
        flag_definition = re.search(
            r'^locked_package_flags\s*:=\s*"(?P<flags>[^"]+)"$',
            just_source,
            re.MULTILINE,
        )
        self.assertIsNotNone(flag_definition)
        if flag_definition is not None:
            for flag in required:
                self.assertIn(flag, flag_definition.group("flags"))
        commands = re.findall(
            r"xcodebuild -project MarkDev\.xcodeproj[^\n]*",
            just_source,
        )
        self.assertTrue(commands, "Justfile must own the app's Xcode invocations")
        for command in commands:
            with self.subTest(command=command):
                self.assertRegex(
                    command,
                    r"\{\{\s*locked_package_flags\s*\}\}",
                    "every build, test, or settings lookup must honor Package.resolved",
                )

        release_source = Path("tools/release/release.py").read_text()
        for flag in required:
            self.assertIn(f'"{flag}"', release_source)
        release_settings_call = re.search(
            r"settings = json\.loads\(run\(\"xcodebuild\".*?\)\.stdout\)",
            release_source,
            re.DOTALL,
        )
        self.assertIsNotNone(release_settings_call)
        if release_settings_call is not None:
            self.assertIn(
                "*LOCKED_PACKAGE_FLAGS",
                release_settings_call.group(0),
                "release staging must not mutate the dependency graph while locating products",
            )

    def test_release_core_recipe_builds_and_verifies_the_exact_universal_archive(self):
        source = Path("justfile").read_text()
        match = re.search(
            r"^build-core:\n(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)",
            source,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match, "justfile must own the release Rust build")
        if match is None:
            return

        body = match.group("body")
        for target in ("aarch64-apple-darwin", "x86_64-apple-darwin"):
            with self.subTest(target=target):
                self.assertIn(target, body)
        self.assertIn("lipo -create", body)
        self.assertIn("core/target/release/libmarkdev.a", body)
        self.assertNotIn(
            "TMPDIR", body,
            "the staged archive must share a filesystem with its atomic destination",
        )
        self.assertRegex(
            body,
            r"mktemp -d [^\n]*\$\{output:h\}",
            "the universal archive must be staged alongside its final path",
        )
        self.assertIn(
            "arm64", body,
            "the combined Rust archive must be checked for its Apple Silicon slice",
        )
        self.assertIn(
            "x86_64", body,
            "the combined Rust archive must be checked for its Intel slice",
        )
        self.assertRegex(
            body,
            r"(?:lipo[^\n]*-verify_arch[^\n]*arm64[^\n]*x86_64|"
            r"lipo[^\n]*-archs)",
            "the release recipe must verify the combined archive before publishing it",
        )

        for workflow in (Path(".github/workflows/ci.yml"), Path(".github/workflows/release.yml")):
            workflow_source = workflow.read_text()
            with self.subTest(workflow=workflow):
                self.assertIn("aarch64-apple-darwin", workflow_source)
                self.assertIn("x86_64-apple-darwin", workflow_source)

    def test_every_dependency_consuming_cargo_recipe_refuses_lockfile_drift(self):
        source = re.sub(r"\\\n\s*", " ", Path("justfile").read_text())
        commands = []
        for line in source.splitlines():
            match = re.search(r"\bcargo\s+(?:build|test|clippy)\b.*", line)
            if match is not None:
                commands.append(match.group(0))
        self.assertTrue(commands, "justfile must own Cargo dependency resolution")
        for command in commands:
            with self.subTest(command=command):
                self.assertRegex(
                    command,
                    r"(?:^|\s)--locked(?:\s|$)",
                    "Cargo must fail rather than rewriting the committed lockfile",
                )

    def test_documented_dependency_consuming_cargo_commands_refuse_lockfile_drift(self):
        documentation = (
            Path("README.md"),
            Path("CONTRIBUTING.md"),
            Path(".github/pull_request_template.md"),
            *sorted(Path("docs").rglob("*.md")),
        )
        commands = []
        for path in documentation:
            for line_number, line in enumerate(path.read_text().splitlines(), start=1):
                if re.search(r"\bcargo\s+(?:build|test|clippy)\b", line):
                    commands.append((path, line_number, line))
        self.assertTrue(commands, "documentation must expose runnable Cargo commands")
        for path, line_number, command in commands:
            with self.subTest(path=path, line=line_number):
                self.assertRegex(
                    command,
                    r"(?:^|\s)--locked(?:\s|[`)]|$)",
                    f"{path}:{line_number} must refuse Cargo.lock drift",
                )

    def test_repository_rust_override_and_release_cli_are_exactly_documented(self):
        override_path = Path("rust-toolchain.toml")
        self.assertTrue(override_path.is_file(), "the repository must own its Rust selection")
        override = override_path.read_text() if override_path.is_file() else ""
        self.assertEqual(
            override,
            "[toolchain]\n"
            'channel = "1.98.0"\n'
            'profile = "minimal"\n'
            'components = ["rustfmt", "clippy"]\n'
            'targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"]\n',
        )

        documented = (
            Path("README.md"),
            Path("CONTRIBUTING.md"),
            *sorted(Path("docs").rglob("*.md")),
        )
        for path in documented:
            with self.subTest(path=path):
                self.assertNotIn(
                    "rustup default",
                    path.read_text(),
                    "setup must not mutate the developer's global Rust default",
                )

        getting_started = Path("docs/getting-started.md").read_text()
        contributing = Path("CONTRIBUTING.md").read_text()
        for source in (getting_started, contributing):
            self.assertIn("gh 2.95.0", source)
            self.assertIn("tools/ci/install-pinned-tools.sh release", source)

    def test_swift_package_lock_refresh_is_documented_as_an_explicit_resolution(self):
        source = Path("docs/getting-started.md").read_text()
        self.assertNotIn(
            "`just generate` materializes",
            source,
            "XcodeGen preserves project structure but does not resolve Swift packages",
        )
        self.assertIn("-resolvePackageDependencies", source)
        self.assertIn("review the lock diff", source.lower())

    def test_ci_installs_checksum_pinned_build_tools_from_one_owner(self):
        installer = Path("tools/ci/install-pinned-tools.sh")
        self.assertTrue(installer.is_file(), "CI needs a canonical pinned-tool installer")
        installer_source = installer.read_text() if installer.is_file() else ""
        for required in (
            "just 1.58.0",
            "50ae3e996c974a0bf32ea7d10f495070df33f1b43e0616b2769e3d4821ed8f48",
            "9a09cfef66aaa79da58203970103a0684307716caaabd3e9844cacc4dc0f4023",
            "Version: 2.45.4",
            "090ec29491aad50aec10631bf6e62253fed733c50f3aab0f5ffc86bc170bdbef",
        ):
            with self.subTest(required=required):
                self.assertIn(required, installer_source)

        for workflow in (Path(".github/workflows/ci.yml"), Path(".github/workflows/release.yml")):
            source = workflow.read_text()
            with self.subTest(workflow=workflow):
                self.assertNotIn("brew install just", source)
                self.assertIn("tools/ci/install-pinned-tools.sh", source)

    def test_pinned_tool_installer_is_also_a_local_bootstrap(self):
        source = Path("tools/ci/install-pinned-tools.sh").read_text()
        self.assertNotIn(
            '${RUNNER_TEMP:?',
            source,
            "the canonical pinned installer must not require GitHub Actions state",
        )
        self.assertNotIn(
            '${GITHUB_PATH:?',
            source,
            "local installation must work without GitHub Actions' PATH command file",
        )
        self.assertIn(
            "MARKDEV_PINNED_BIN",
            source,
            "local callers need an explicit, deterministic output override",
        )
        self.assertIn(
            'build/pinned-tools/bin',
            source,
            "the no-argument local destination must be repo-owned and cleanable",
        )

    def test_pinned_tool_downloads_have_time_and_exact_size_bounds(self):
        source = Path("tools/ci/install-pinned-tools.sh").read_text()
        for option in (
            "--connect-timeout",
            "--max-time",
            "--retry-max-time",
            "--max-filesize",
        ):
            with self.subTest(option=option):
                self.assertIn(option, source)
        for exact_size in (
            "2146038",
            "2330963",
            "4319508",
            "13944744",
            "15285963",
        ):
            with self.subTest(exact_size=exact_size):
                self.assertIn(
                    exact_size,
                    source,
                    "every checksum-pinned archive also needs an exact byte count",
                )
        self.assertIn(
            'actual_size=$(stat -f %z "$destination")',
            source,
            "a completed response must equal the audited asset size",
        )

    def test_pinned_xcodegen_preserves_and_exercises_its_vendor_resource_layout(self):
        source = Path("tools/ci/install-pinned-tools.sh").read_text()
        for required in (
            "xcodegen_archive_entry_count=44",
            "f54b3b8571f9309605e44c358a98e3fdf4b27066ce4633d08b86889130e28928",
            "share/xcodegen/SettingPresets",
            'No "base" settings found',
            'No "debug config" settings found',
            'No "release config" settings found',
            'No "macOS" settings found',
            "productName = MarkDev;",
            "productName = MarkDevKit;",
            "productName = MarkDevKitTests;",
        ):
            with self.subTest(required=required):
                self.assertIn(
                    required,
                    source,
                    "the pinned binary is incomplete without its audited SettingPresets tree",
                )
        self.assertNotIn(
            'ditto "$xcodegen_binary" "$pinned_bin/xcodegen"',
            source,
            "copying only the executable breaks XcodeGen's prefix-relative resource lookup",
        )
        for required in (
            'xcodegen_install_staging=$(mktemp -d "$pinned_prefix/.xcodegen-install.XXXXXX")',
            'exercise_xcodegen_layout "$xcodegen_install_staging/bin/xcodegen" staged',
            'exercise_xcodegen_layout "$pinned_bin/xcodegen" installed',
            'mv "$xcodegen_staged_resources" "$xcodegen_resources"',
            'mv -f "$xcodegen_install_staging/bin/xcodegen" "$pinned_bin/xcodegen"',
        ):
            with self.subTest(required=required):
                self.assertIn(
                    required,
                    source,
                    "XcodeGen must be validated in staging and committed resources-first",
                )
        self.assertLess(
            source.index('exercise_xcodegen_layout "$xcodegen_install_staging/bin/xcodegen" staged'),
            source.index('mv "$xcodegen_staged_resources" "$xcodegen_resources"'),
            "the complete staged prefix must generate a project before installation",
        )
        self.assertLess(
            source.index('mv "$xcodegen_staged_resources" "$xcodegen_resources"'),
            source.index('mv -f "$xcodegen_install_staging/bin/xcodegen" "$pinned_bin/xcodegen"'),
            "resources must become durable before the executable is exposed on PATH",
        )

    def test_pull_request_ci_builds_the_actual_universal_release_app(self):
        source = Path(".github/workflows/ci.yml").read_text()
        self.assertRegex(
            source,
            r"(?m)^\s*run:\s*just build-release\s*$",
            "Debug tests cannot prove the universal optimized Release bundle links",
        )

    def test_ci_executes_core_and_app_suites_on_apple_silicon_and_intel(self):
        source = Path(".github/workflows/ci.yml").read_text()
        for job in ("rust-checks", "macos-app"):
            with self.subTest(job=job):
                match = re.search(
                    rf"(?ms)^  {re.escape(job)}:\n(?P<body>.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)",
                    source,
                )
                self.assertIsNotNone(match, f"missing CI job: {job}")
                if match is None:
                    continue
                body = match.group("body")
                self.assertIn("fail-fast: false", body)
                self.assertRegex(
                    body,
                    r"runner:\s*\[\s*macos-26\s*,\s*macos-26-intel\s*\]",
                    "universal slices are not runtime proof on both CPU families",
                )
                self.assertIn("runs-on: ${{ matrix.runner }}", body)

    def test_release_publisher_uses_a_checksum_pinned_github_cli(self):
        installer = Path("tools/ci/install-pinned-tools.sh").read_text()
        for required in (
            "gh_version=2.95.0",
            "3677f9c27965825f9c7d50395473c134edaea4b484373ef6b25de653570a0489",
            "985707e9ac60c95ed51cddd808c338b481abe69fffa77e9d6547c3750045f77e",
        ):
            with self.subTest(required=required):
                self.assertIn(required, installer)

        workflow = Path(".github/workflows/release.yml").read_text()
        self.assertIn("tools/ci/install-pinned-tools.sh release", workflow)
        self.assertIn("just verify-release-toolchain", workflow)
        just_source = Path("justfile").read_text()
        self.assertRegex(
            just_source,
            r"(?m)^release-draft\s+\$TAG:\s+verify-github-cli\s*$",
            "local publishing must not bypass the pinned GitHub CLI check",
        )

    def test_release_build_steps_never_receive_persisted_write_credentials(self):
        workflow = Path(".github/workflows/release.yml").read_text()
        checkout_count = workflow.count("uses: actions/checkout@")
        self.assertGreater(checkout_count, 0)
        self.assertEqual(
            workflow.count("persist-credentials: false"),
            checkout_count,
            "each release checkout must withhold Git credentials from build and package code",
        )

    def test_all_ci_build_checkouts_withhold_git_credentials(self):
        for workflow_path in (
            Path(".github/workflows/ci.yml"),
            Path(".github/workflows/release.yml"),
        ):
            source = workflow_path.read_text()
            checkout_count = source.count("uses: actions/checkout@")
            with self.subTest(workflow=workflow_path):
                self.assertGreater(checkout_count, 0)
                self.assertEqual(
                    source.count("persist-credentials: false"),
                    checkout_count,
                    "build and test processes must not inherit a persisted repository token",
                )

    def test_signed_release_resolves_one_exact_certificate_and_rechecks_the_result(self):
        helper = Path("tools/release/signing_identity.py")
        self.assertTrue(helper.is_file(), "signed builds need one canonical identity resolver")
        source = Path("justfile").read_text()
        match = re.search(
            r'^build-release-signed[^\n]*:\s*[^\n]*\n(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)',
            source,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(match)
        if match is None:
            return
        body = match.group("body")
        self.assertNotIn('grep -q "{{ IDENTITY }}"', body)
        self.assertIn("identity={{ quote(IDENTITY) }}", body)
        self.assertIn("signing_identity.py resolve", body)
        self.assertIn('CODE_SIGN_IDENTITY="$fingerprint"', body)
        self.assertIn("signing_identity.py verify", body)

    def test_install_only_uses_verified_same_filesystem_staging_and_rollback(self):
        helper = Path("tools/release/install-app.sh")
        self.assertTrue(helper.is_file(), "installation needs one testable atomic owner")
        source = helper.read_text() if helper.is_file() else ""
        self.assertNotIn("rm -rf /Applications/MarkDev.app", source)
        for required in (
            "mktemp -d /Applications/.MarkDev-install.",
            '"$signing_helper" verify-installable',
            '"$signing_helper" verify-restorable',
            "transaction.json",
            "--state-file",
            "rollback-transaction",
            "--preserve-candidate",
            "lock-run",
            "assert-lock-session",
            "cleanup-empty-staging",
            "discover",
            'mark-phase "$transaction" "$candidate" "$destination" verified',
            'mark-phase "$transaction" "$candidate" "$destination" activated',
            '"$quicklook_helper" absent',
            "pluginkit",
            "MarkDevQuickLook.appex",
            '"$quicklook_helper" wait "$appex"',
        ):
            with self.subTest(required=required):
                self.assertIn(required, source)
        self.assertNotIn('rm -rf "$staging"', source)
        self.assertNotIn("MARKDEV_INSTALL_LOCK_FD", source)
        self.assertIn(
            'run_bounded 300 /usr/bin/ditto "$source_app" "$candidate"',
            source,
        )
        self.assertLess(
            source.index("discover"),
            source.index("mktemp -d /Applications/.MarkDev-install."),
            "abandoned transactions must be resolved under the lock before new staging",
        )
        activated = source.index(
            'mark-phase "$transaction" "$candidate" "$destination" activated'
        )
        self.assertLess(
            source.index(
                'verify_commitment "$destination" "$incoming_commitment" '
                '"registered installed app"'
            ),
            activated,
            "activation cannot become durable until registration and content verification complete",
        )
        self.assertLess(
            activated,
            source.rindex('"$python" "$atomic_helper" cleanup-transaction'),
            "cleanup must retain the durable activated phase until final removal",
        )
        just_source = Path("justfile").read_text()
        self.assertIn('tools/release/install-app.sh "$app"', just_source)

    def test_release_builds_use_one_clean_owned_derived_data_directory(self):
        source = Path("justfile").read_text()
        for recipe_name in ("build-release", "build-release-signed"):
            match = re.search(
                rf"^{recipe_name}[^\n]*:\s*[^\n]*\n(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)",
                source,
                re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(match, f"missing {recipe_name} recipe")
            if match is None:
                continue
            body = match.group("body")
            with self.subTest(recipe=recipe_name):
                self.assertIn("-derivedDataPath", body)
                self.assertIn("build/DerivedData/Release", body)
                self.assertRegex(body, r"\bclean\s+build\b")

        release_source = Path("tools/release/release.py").read_text()
        self.assertIn('RELEASE_DERIVED_DATA = "build/DerivedData/Release"', release_source)
        self.assertIsNotNone(
            re.search(
            r"settings = json\.loads\(run\(\"xcodebuild\".*?"
            r"RELEASE_DERIVED_DATA.*?-showBuildSettings",
                release_source,
                re.DOTALL,
            ),
            "staging must locate products in the same owned release directory",
        )

    def test_debug_builds_and_cleaning_are_confined_to_repo_owned_outputs(self):
        source = Path("justfile").read_text()
        clean = re.search(
            r"^clean:\n(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)",
            source,
            re.MULTILINE | re.DOTALL,
        )
        self.assertIsNotNone(clean)
        if clean is not None:
            body = clean.group("body")
            self.assertNotIn("~/", body)
            self.assertNotIn("$HOME", body)
            self.assertNotIn("/Users/", body)
            self.assertNotIn(
                "Library/Developer/Xcode/DerivedData",
                body,
                "one checkout must never clean another checkout's global DerivedData",
            )
        for recipe_name in ("build", "test-app", "run"):
            recipe = re.search(
                rf"^{re.escape(recipe_name)}(?:\s+[^\n:]*)?:[^\n]*\n"
                rf"(?P<body>.*?)(?=^[A-Za-z][A-Za-z0-9_-]*(?:[^\n]*):)",
                source,
                re.MULTILINE | re.DOTALL,
            )
            self.assertIsNotNone(recipe, f"missing {recipe_name} recipe")
            if recipe is not None:
                with self.subTest(recipe=recipe_name):
                    self.assertIn(
                        "-derivedDataPath build/DerivedData/Debug",
                        recipe.group("body"),
                    )

    @staticmethod
    def _target_block(source, target):
        match = re.search(
            rf"^  {re.escape(target)}:\n(?P<body>.*?)(?=^  [A-Za-z][A-Za-z0-9]*:\n|^schemes:\n)",
            source,
            re.MULTILINE | re.DOTALL,
        )
        if match is None:
            raise AssertionError(f"missing target in project.yml: {target}")
        return match.group("body")

    def test_every_owned_target_uses_the_project_version(self):
        source = Path("project.yml").read_text()
        version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', source).group(1)
        expected = metadata("v" + version)
        owned = {"MarkDev", "MarkDevKit", "MarkDevQuickLook"}
        for configuration in ("Debug", "Release"):
            settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-alltargets",
                                      *LOCKED_PACKAGE_FLAGS, "-configuration", configuration,
                                      "-showBuildSettings", "-json").stdout)
            self.assertTrue(owned.issubset({item["target"] for item in settings}))
            for item in settings:
                if item["target"] in owned:
                    with self.subTest(configuration=configuration, target=item["target"]):
                        build_settings = item["buildSettings"]
                        self.assertEqual(build_settings["CURRENT_PROJECT_VERSION"], expected["build"])
                        self.assertEqual(build_settings["MARKETING_VERSION"], expected["version"])
                        self.assertEqual(
                            build_settings.get("MACOSX_DEPLOYMENT_TARGET"),
                            "26.0",
                            "every shipped Mach-O must match the manifest's minimum macOS",
                        )
                        if configuration == "Debug":
                            self.assertEqual(
                                build_settings.get("ONLY_ACTIVE_ARCH"),
                                "YES",
                                "local Debug builds should stay on the active architecture",
                            )
                        else:
                            self.assertEqual(
                                build_settings.get("ONLY_ACTIVE_ARCH"),
                                "NO",
                                "Release must build every declared distribution architecture",
                            )
                            architectures = build_settings.get("ARCHS", "").split()
                            self.assertEqual(
                                len(architectures),
                                2,
                                "Release must declare exactly two architecture slices",
                            )
                            self.assertEqual(set(architectures), {"arm64", "x86_64"})
                            self.assertEqual(
                                build_settings.get("CODE_SIGN_INJECT_BASE_ENTITLEMENTS"),
                                "NO",
                                "Release signatures must contain only explicitly declared authority",
                            )
                        if item["target"] == "MarkDevQuickLook":
                            self.assertEqual(
                                item["buildSettings"].get("APPLICATION_EXTENSION_API_ONLY"),
                                "YES")
                            self.assertEqual(
                                item["buildSettings"].get("DEAD_CODE_STRIPPING"),
                                "YES")

    def test_main_app_stays_unsandboxed_and_quicklook_is_read_only_sandboxed(self):
        with Path("app/MarkDevQuickLook/MarkDevQuickLook.entitlements").open("rb") as stream:
            entitlements = plistlib.load(stream)
        self.assertEqual(entitlements, {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-only": True,
        })

        settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-alltargets",
                                  *LOCKED_PACKAGE_FLAGS, "-configuration", "Release",
                                  "-showBuildSettings", "-json").stdout)
        by_target = {item["target"]: item["buildSettings"] for item in settings}
        self.assertEqual(by_target["MarkDev"].get("ENABLE_APP_SANDBOX"), "NO")
        self.assertEqual(by_target["MarkDev"].get("CODE_SIGN_ENTITLEMENTS", ""), "")
        self.assertEqual(by_target["MarkDevQuickLook"].get("ENABLE_APP_SANDBOX"), "YES")
        self.assertEqual(
            by_target["MarkDevQuickLook"].get("APPLICATION_EXTENSION_API_ONLY"),
            "YES")
        self.assertEqual(
            by_target["MarkDevQuickLook"].get("DEAD_CODE_STRIPPING"),
            "YES")
        self.assertEqual(
            by_target["MarkDevQuickLook"].get("CODE_SIGN_ENTITLEMENTS"),
            "app/MarkDevQuickLook/MarkDevQuickLook.entitlements")

    def test_quicklook_has_an_extension_safe_renderer_boundary(self):
        source = Path("project.yml").read_text()
        quicklook = self._target_block(source, "MarkDevQuickLook")

        self.assertNotIn(
            "- target: MarkDevKit",
            quicklook,
            "Quick Look must not link the app framework and its terminal/process surface",
        )
        self.assertNotIn(
            "SwiftTerm",
            quicklook,
            "Quick Look must not link the terminal dependency",
        )
        self.assertRegex(
            quicklook,
            r"APPLICATION_EXTENSION_API_ONLY:\s*(?:true|YES)",
            "the extension-safety compiler check must be an explicit project contract",
        )
        self.assertRegex(
            quicklook,
            r"DEAD_CODE_STRIPPING:\s*(?:true|YES)",
            "unused Rust exports and runtime authority must be removed from Quick Look",
        )
        self.assertRegex(
            quicklook,
            r"- path: app/MarkDevKit/",
            "Quick Look must compile the canonical read-only renderer instead of a duplicate",
        )
        self.assertIn(
            "MARKDEV_QUICKLOOK",
            quicklook,
            "the renderer authority split must be selected at compile time",
        )
        for forbidden in (
            "app/MarkDevKit/Diagnostics/",
            "app/MarkDevKit/Editor/ContentPrefetcher.swift",
            "app/MarkDevKit/Editor/MarkdownEditorView.swift",
            "app/MarkDevKit/Render/ContentZoomViewer.swift",
            "app/MarkDevKit/Terminal/",
            "app/MarkDevKit/Workspace/",
        ):
            with self.subTest(forbidden=forbidden):
                self.assertNotIn(
                    forbidden,
                    quicklook,
                    f"Quick Look source membership grants app-only authority: {forbidden}",
                )
        controller = Path("app/MarkDevQuickLook/PreviewViewController.swift").read_text()
        self.assertNotIn(
            "import MarkDevKit",
            controller,
            "the extension must not gain the full app framework through its controller",
        )
        renderer = Path("app/MarkDevKit/Editor/RichContentRenderer.swift").read_text()
        self.assertNotIn(
            "MTFontManager.manager",
            renderer,
            "the renderer must not reach SwiftMath's process-global mutable font manager",
        )

    def test_settings_diagnostic_exports_use_one_exact_native_panel_lease(self):
        source = Path("app/MarkDev/SettingsView.swift").read_text()

        self.assertIn(
            "TransientPresentationCoordinator",
            source,
            "Settings must reuse the app's typed transient-presentation owner",
        )
        self.assertIn(
            ".nativePanel(",
            source,
            "support export must reserve one protected native-panel generation",
        )
        self.assertIn(
            "supportPanelIsCurrent",
            source,
            "late panel completions must verify the exact generation and identity",
        )
        self.assertGreaterEqual(
            source.count("supportPanelIsCurrent(lease)"),
            2,
            "both the AppKit completion and the export task must reject a stale lease",
        )
        self.assertIn(
            "defer { finishSupportPanel(lease) }",
            source,
            "the accepted destination must retain its lease through export settlement",
        )
        self.assertRegex(
            source,
            r"\.disabled\(\s*diagnosticsModel\.exportState\.isExporting\s*"
            r"\|\|\s*diagnosticsModel\.historyExportState\.isExporting\s*"
            r"\|\|\s*supportPanelIsPresented\s*\)",
            "support export must stay disabled while either diagnostic export or chooser owns it",
        )
        self.assertIn(
            "supportSavePanel?.cancel(nil)",
            source,
            "teardown must actively close the AppKit panel instead of only forgetting it",
        )
        self.assertIn(
            "supportPresentation.invalidateAll()",
            source,
            "teardown must invalidate every late panel completion",
        )


if __name__ == "__main__":
    unittest.main()
