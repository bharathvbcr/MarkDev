"""Exercise release boundaries through the same just recipes used by CI."""
from contextlib import contextmanager
import json
import hashlib
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock
import zipfile

from tools.release import release as release_module

REPO = Path(__file__).resolve().parents[2]


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="markdev release test ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copy(REPO / "justfile", self.root)
        shutil.copytree(REPO / "tools/release", self.root / "tools/release")
        (self.root / "project.yml").write_text(
            'settings:\n  base:\n    MARKETING_VERSION: "0.1.4"\n'
            '    CURRENT_PROJECT_VERSION: "9"\n'
        )
        (self.root / "docs/releases").mkdir(parents=True)
        (self.root / "docs/releases/v0.1.4.md").write_text("# MarkDev v0.1.4\nRelease notes.\n")
        (self.root / ".gitignore").write_text("__pycache__/\nbin/\nproducts/\ndist/\nstate.json\ncommands.jsonl\n")
        self.app = self.root / "products/MarkDev.app"
        self.plists = []
        for folder, executable, identifier in [
            ("Contents", "MarkDev", "dev.markdev.MarkDev"),
            ("Contents/PlugIns/MarkDevQuickLook.appex/Contents", "MarkDevQuickLook", "dev.markdev.MarkDev.QuickLook"),
            ("Contents/Frameworks/MarkDevKit.framework/Versions/A/Resources", "MarkDevKit", "dev.markdev.MarkDevKit"),
        ]:
            directory = self.app / folder
            directory.mkdir(parents=True)
            path = directory / "Info.plist"
            info = {
                "CFBundleShortVersionString": "0.1.4", "CFBundleVersion": "9",
                "CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                "LSMinimumSystemVersion": "26.0",
                "DTXcode": "2660",
                "DTXcodeBuild": "17F113",
                "DTSDKBuild": "25F70",
                "CFBundlePackageType": {
                    "MarkDev": "APPL",
                    "MarkDevQuickLook": "XPC!",
                    "MarkDevKit": "FMWK",
                }[executable],
            }
            if executable == "MarkDev":
                info.update({
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
                                "public.filename-extension": [
                                    "mdown", "mdx", "mkd", "markdn",
                                ],
                            },
                        },
                    ],
                })
            if executable == "MarkDevQuickLook":
                info["NSExtension"] = {
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
            path.write_bytes(plistlib.dumps(info))
            self.plists.append(path)
            binary = directory / "MacOS" / executable if folder.endswith("Contents") else directory.parent / executable
            binary.parent.mkdir(exist_ok=True)
            binary.write_text("fixture executable\n")
        self.privacy_manifests = [
            self.app / "Contents/Resources/PrivacyInfo.xcprivacy",
            self.app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Resources/PrivacyInfo.xcprivacy",
            self.app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/Resources/PrivacyInfo.xcprivacy",
        ]
        privacy_manifest = {
            "NSPrivacyTracking": False,
            "NSPrivacyCollectedDataTypes": [],
        }
        for path in self.privacy_manifests:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(privacy_manifest))

        math_payload = (
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
        )
        def resource_bundle_info(identifier, name, minimum_system):
            return {
                "CFBundleIdentifier": identifier,
                "CFBundleName": name,
                "CFBundlePackageType": "BNDL",
                "CFBundleSupportedPlatforms": ["MacOSX"],
                "DTPlatformBuild": "25F70",
                "DTPlatformName": "macosx",
                "DTPlatformVersion": "26.5",
                "DTSDKBuild": "25F70",
                "DTSDKName": "macosx26.5",
                "DTXcode": "2660",
                "DTXcodeBuild": "17F113",
                "LSMinimumSystemVersion": minimum_system,
            }
        for resources in (
            self.app / "Contents/Resources",
            self.app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Resources",
        ):
            swift_math = resources / "SwiftMath_SwiftMath.bundle/Contents"
            fonts = swift_math / "Resources/mathFonts.bundle"
            fonts.mkdir(parents=True)
            (swift_math / "Info.plist").write_bytes(plistlib.dumps(
                resource_bundle_info(
                    "swiftmath.SwiftMath.resources", "SwiftMath_SwiftMath", "12.0"
                )
            ))
            for name in math_payload:
                (fonts / name).write_text(f"fixture {name}\n")

        main_resources = self.app / "Contents/Resources"
        for name in ("AppIcon.icns", "Assets.car", "DocumentIcon.icns"):
            (main_resources / name).write_text(f"fixture {name}\n")
        swift_term = main_resources / "SwiftTerm_SwiftTerm.bundle/Contents"
        (swift_term / "Resources").mkdir(parents=True)
        (swift_term / "Info.plist").write_bytes(plistlib.dumps(
            resource_bundle_info(
                "swiftterm.SwiftTerm.resources", "SwiftTerm_SwiftTerm", "11.0"
            )
        ))
        (swift_term / "Resources/default.metallib").write_text("fixture metallib\n")

        for signature in (
            self.app / "Contents/_CodeSignature/CodeResources",
            self.app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/_CodeSignature/CodeResources",
            self.app / "Contents/Frameworks/MarkDevKit.framework/Versions/A/_CodeSignature/CodeResources",
        ):
            signature.parent.mkdir(parents=True)
            signature.write_text("fixture signature\n")

        framework = self.app / "Contents/Frameworks/MarkDevKit.framework"
        (framework / "Versions/Current").symlink_to("A")
        (framework / "MarkDevKit").symlink_to("Versions/Current/MarkDevKit")
        (framework / "Resources").symlink_to("Versions/Current/Resources")
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        fake = binary_dir / "fake"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, plistlib, sys
root = pathlib.Path.cwd()
state_path = root / "state.json"
state = json.loads(state_path.read_text()) if state_path.exists() else {}
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "commands.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\\n")
if name == "xcodebuild":
    if state.get("settings_fail"):
        sys.exit(65)
    if "-json" in args:
        print(json.dumps([{"target": "MarkDev", "buildSettings": {
            "BUILT_PRODUCTS_DIR": str(root / "products"),
            "ONLY_ACTIVE_ARCH": state.get("only_active_arch", "NO"),
            "ARCHS": state.get("build_architectures", "arm64 x86_64"),
            "MACOSX_DEPLOYMENT_TARGET": state.get("deployment_target", "26.0"),
        }}]))
    else:
        print(" BUILT_PRODUCTS_DIR = " + str(root / "products"))
elif name == "codesign":
    if state.get("signature_fail"):
        sys.exit(1)
    if state.get("extracted_signature_fail") and "markdev-release-verify-" in args[-1]:
        sys.exit(1)
    architecture = args[args.index("--arch") + 1] if "--arch" in args else None
    def option(key, default=False):
        return state.get(f"{architecture}_{key}", state.get(key, default))
    if "--entitlements" in args:
        if "MarkDevQuickLook.appex" in args[-1]:
            entitlements = {
                "com.apple.security.app-sandbox": not option("quicklook_unsandboxed"),
                "com.apple.security.files.user-selected.read-only": not option("quicklook_no_read"),
            }
            if option("quicklook_read_write"):
                entitlements["com.apple.security.files.user-selected.read-write"] = True
            if option("quicklook_get_task_allow"):
                entitlements["com.apple.security.get-task-allow"] = True
        else:
            entitlements = {"com.apple.security.app-sandbox": True} if option("main_sandboxed") else {}
            if option("main_get_task_allow"):
                entitlements["com.apple.security.get-task-allow"] = True
        print(plistlib.dumps(entitlements).decode())
    elif "--verbose=4" in args:
        target = "quicklook" if "MarkDevQuickLook.appex" in args[-1] else (
            "framework" if "MarkDevKit.framework" in args[-1] else "main")
        signature = option(target + "_signature", "adhoc")
        flags = option(target + "_flags", "0x2(adhoc)")
        team = option(target + "_team", "not set")
        print("CodeDirectory v=20400 size=123 flags=" + flags + " hashes=1+1 location=embedded", file=sys.stderr)
        print("Signature=" + signature, file=sys.stderr)
        print("TeamIdentifier=" + team, file=sys.stderr)
elif name == "lipo":
    executable = pathlib.Path(args[-1]).name
    architectures = state.get("architectures", {})
    print(architectures.get(executable, state.get("architecture", "arm64 x86_64")))
elif name == "otool":
    print(state.get("quicklook_links", "@rpath/SwiftMath.framework/SwiftMath"))
elif name == "nm":
    print(state.get("quicklook_symbols", "U _$s10Foundation3URLV"))
elif name == "vtool":
    architecture = args[args.index("-arch") + 1]
    executable = pathlib.Path(args[-1]).name
    target = {"MarkDev": "main", "MarkDevQuickLook": "quicklook", "MarkDevKit": "framework"}[executable]
    def build_option(key, default):
        return state.get(
            f"{architecture}_{target}_{key}",
            state.get(f"{target}_{key}", state.get(key, default)),
        )
    for index in range(build_option("build_commands", 1)):
        print(f"Load command {index}")
        print("      cmd LC_BUILD_VERSION")
        print("  cmdsize 32")
        print(" platform " + build_option("platform", "MACOS"))
        print("    minos " + build_option("minos", "26.0"))
        print("      sdk " + build_option("sdk", "26.5"))
        print("   ntools 1")
elif name == "ditto":
    if state.get("zip_fail"):
        sys.exit(1)
    os.execv("/usr/bin/ditto", ["ditto", *args])
elif name == "gh":
    if args == ["--version"]:
        print("gh version 2.95.0 (2026-08-27)")
        sys.exit(0)
    if state.get("api_fail"):
        print("service unavailable (HTTP 503)", file=sys.stderr)
        sys.exit(1)
    release = state.get("release")
    if args[:2] == ["release", "view"]:
        if release is None:
            print("release not found", file=sys.stderr)
            sys.exit(1)
        print(json.dumps(release))
    elif args[:2] == ["release", "create"]:
        state["release"] = {"isDraft": True, "tagName": "v0.1.4", "assets": [], "url": "https://example.test/release"}
    elif args[:2] == ["release", "upload"]:
        import hashlib
        for value in args[3:]:
            if value.startswith("-"):
                continue
            p = pathlib.Path(value)
            if state.get("mutate_during_upload") and p.suffix == ".zip":
                p.write_bytes(p.read_bytes() + b"changed during upload")
            release["assets"].append({"name": p.name, "size": p.stat().st_size, "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(), "state": "uploaded"})
    state_path.write_text(json.dumps(state))
''')
        fake.chmod(0o755)
        for name in ["xcodebuild", "codesign", "lipo", "otool", "nm", "vtool", "ditto", "gh"]:
            (binary_dir / name).symlink_to(fake)
        self.env = {**os.environ, "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"]}
        for command in [["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.test", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
                        ["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.test",
                         "tag", "-am", "v0.1.4", "v0.1.4"],
                        ["git", "remote", "add", "origin", str(self.root)]]:
            subprocess.run(command, cwd=self.root, check=True, capture_output=True)
        commit = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=self.root, text=True).strip()
        self.change_plist(0, "MarkDevSourceCommit", commit)

    def state(self, **values):
        (self.root / "state.json").write_text(json.dumps(values))

    def run_recipe(self, name, tag="v0.1.4"):
        return subprocess.run(["just", name, tag], cwd=self.root, env=self.env,
                              text=True, capture_output=True, timeout=30)

    def change_plist(self, index, key, value):
        path = self.plists[index]
        plist = plistlib.loads(path.read_bytes())
        plist[key] = value
        path.write_bytes(plistlib.dumps(plist))

    def commands(self):
        path = self.root / "commands.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def staged_directory(self):
        return self.root / "dist/MarkDev-0.1.4-macos"

    def staged_asset(self, suffix):
        stem = "MarkDev-0.1.4-macos"
        return self.staged_directory() / f"{stem}{suffix}"

    def staged_snapshot(self):
        directory = self.staged_directory()
        expected_names = {
            "MarkDev-0.1.4-macos.zip",
            "MarkDev-0.1.4-macos.zip.sha256",
            "MarkDev-0.1.4-macos.json",
        }
        self.assertEqual({path.name for path in directory.iterdir()}, expected_names)
        return {
            path.name: hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.iterdir()
        }

    def stale_generations(self):
        dist = self.root / "dist"
        return sorted(dist.glob(".stage-MarkDev-0.1.4-macos.*")) if dist.exists() else []

    @contextmanager
    def direct_release_context(self):
        previous = Path.cwd()
        os.chdir(self.root)
        try:
            with mock.patch.dict(os.environ, self.env, clear=True):
                yield
        finally:
            os.chdir(previous)

    def test_matching_bundle_stages(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(self.staged_asset(".zip").is_file())
        self.staged_snapshot()

    def test_matching_bundle_accepts_architectures_in_either_lipo_order(self):
        self.state(architecture="x86_64 arm64")
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_staged_manifest_records_the_exact_release_architectures(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.staged_asset(".json").read_text())
        self.assertEqual(manifest["architectures"], ["arm64", "x86_64"])
        self.assertNotIn("architecture", manifest)

    def test_staged_manifest_reports_automated_distribution_limits(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = json.loads(self.staged_asset(".json").read_text())
        self.assertEqual(manifest["distribution"], {
            "signature": "ad-hoc",
            "hardened_runtime": False,
            "notarized": False,
        })
        self.assertEqual(manifest["toolchain"], {
            "xcode": "2660",
            "xcode_build": "17F113",
            "sdk_build": "25F70",
        })

    def test_automated_distribution_profile_is_verified_for_every_owned_bundle(self):
        for target in ("main", "quicklook", "framework"):
            for field, value in (
                ("signature", "certificate"),
                ("flags", "0x10002(adhoc,runtime)"),
                ("team", "ABCDEFGHIJ"),
            ):
                with self.subTest(target=target, field=field):
                    self.state(**{f"{target}_{field}": value})
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_wrong_marketing_version_is_rejected(self):
        self.change_plist(0, "CFBundleShortVersionString", "0.1.3")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_stale_build_is_rejected(self):
        self.change_plist(0, "CFBundleVersion", "8")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_stale_extension_is_rejected(self):
        self.change_plist(1, "CFBundleVersion", "8")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_each_owned_executable_rejects_missing_extra_or_wrong_architectures(self):
        executables = ("MarkDev", "MarkDevQuickLook", "MarkDevKit")
        invalid_architectures = {
            "missing-arm64": "x86_64",
            "missing-x86_64": "arm64",
            "extra": "arm64 x86_64 i386",
            "wrong": "i386 ppc7400",
            "duplicate": "arm64 x86_64 arm64",
        }
        for executable in executables:
            for failure, architectures in invalid_architectures.items():
                with self.subTest(executable=executable, failure=failure):
                    self.state(architectures={executable: architectures})
                    self.assertNotEqual(
                        self.run_recipe("release-stage").returncode,
                        0,
                    )

    def test_tampered_manifest_architectures_are_rejected(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        path = self.staged_asset(".json")
        original = json.loads(path.read_text())
        for failure, architectures in {
            "missing": ["arm64"],
            "extra": ["arm64", "x86_64", "i386"],
            "wrong": ["i386", "ppc7400"],
            "reordered": ["x86_64", "arm64"],
        }.items():
            with self.subTest(failure=failure):
                tampered = {**original, "architectures": architectures}
                path.write_text(json.dumps(tampered))
                self.assertNotEqual(self.run_recipe("release-verify").returncode, 0)
        path.write_text(json.dumps(original))

    def test_signature_failure_is_rejected(self):
        self.state(signature_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_missing_quicklook_sandbox_entitlement_is_rejected(self):
        self.state(quicklook_unsandboxed=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_missing_or_mismatched_privacy_manifest_is_rejected(self):
        for index, path in enumerate(self.privacy_manifests):
            with self.subTest(bundle=index, failure="missing"):
                original = path.read_bytes()
                path.unlink()
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                path.write_bytes(original)
            with self.subTest(bundle=index, failure="tracking"):
                path.write_bytes(plistlib.dumps({
                    "NSPrivacyTracking": True,
                    "NSPrivacyTrackingDomains": ["tracker.example"],
                    "NSPrivacyCollectedDataTypes": [],
                }))
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                path.write_bytes(original)

    def test_missing_quicklook_read_entitlement_is_rejected(self):
        self.state(quicklook_no_read=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_write_entitlement_is_rejected(self):
        self.state(quicklook_read_write=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_nondefault_slice_cannot_gain_quicklook_write_authority(self):
        self.state(x86_64_quicklook_read_write=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_unexpected_quicklook_entitlement_is_rejected(self):
        self.state(quicklook_get_task_allow=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_unexpected_main_entitlement_is_rejected(self):
        self.state(main_get_task_allow=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_app_framework_link_is_rejected(self):
        self.state(
            quicklook_links=(
                "@rpath/MarkDevKit.framework/Versions/A/MarkDevKit\n"
                "@rpath/SwiftMath.framework/SwiftMath"))
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_terminal_link_is_rejected(self):
        self.state(quicklook_links="@rpath/SwiftTerm.framework/SwiftTerm")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_appkit_authority_symbols_are_rejected(self):
        for symbol in (
            "_OBJC_CLASS_$_NSApplication",
            "_NSApp",
            "_OBJC_CLASS_$_NSPasteboard",
            "_OBJC_CLASS_$_NSTask",
            "_OBJC_CLASS_$_NSWorkspace",
        ):
            with self.subTest(symbol=symbol):
                self.state(quicklook_symbols=f"U {symbol}")
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_swiftterm_symbol_is_rejected(self):
        self.state(quicklook_symbols="U _$s9SwiftTerm12LocalProcessC5startyyF")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_process_launch_symbols_are_rejected(self):
        for symbol in (
            "_fork",
            "_vfork",
            "_execvp",
            "_posix_spawnp",
            "_posix_spawn_file_actions_init",
            "__RNvMNtNtNtNtCs7mRY9FNn263_3std3sys7process4unix4unix",
        ):
            with self.subTest(symbol=symbol):
                self.state(quicklook_symbols=f"U {symbol}")
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_vault_exports_are_rejected(self):
        self.state(quicklook_symbols="_md_vault_rename")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_quicklook_allows_rust_abort_runtime(self):
        self.state(
            quicklook_symbols="U __RNvNtCs7mRY9FNn263_3std7process5abort")
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_quicklook_allows_other_nsapp_prefix_symbols(self):
        self.state(quicklook_symbols="U _OBJC_CLASS_$_NSAppearance")
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_sandboxing_the_main_app_is_rejected(self):
        self.state(main_sandboxed=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_settings_failure_is_rejected(self):
        self.state(settings_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_nonuniversal_release_build_settings_are_rejected(self):
        for failure, state in {
            "active-only": {"only_active_arch": "YES"},
            "missing-slice": {"build_architectures": "arm64"},
            "extra-slice": {"build_architectures": "arm64 x86_64 i386"},
            "wrong-slices": {"build_architectures": "i386 ppc7400"},
            "duplicate-slice": {"build_architectures": "arm64 x86_64 arm64"},
        }.items():
            with self.subTest(failure=failure):
                self.state(**state)
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_release_build_settings_cannot_raise_the_claimed_minimum_macos(self):
        self.state(deployment_target="27.0")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_owned_macho_build_versions_are_exact_for_every_slice(self):
        for field, value in (
            ("platform", "IOS"),
            ("minos", "27.0"),
            ("sdk", "27.0"),
            ("build_commands", 0),
            ("build_commands", 2),
        ):
            with self.subTest(field=field, value=value):
                self.state(**{field: value})
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
        for target in ("main", "quicklook", "framework"):
            with self.subTest(target=target, architecture="x86_64"):
                self.state(**{f"x86_64_{target}_minos": "27.0"})
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_packaging_failure_preserves_previous_stage(self):
        first = self.run_recipe("release-stage")
        self.assertEqual(first.returncode, 0, first.stderr)
        previous = self.staged_snapshot()
        self.state(zip_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
        self.assertEqual(
            self.staged_snapshot(),
            previous,
            "failed staging changed the previously verified generation",
        )

    def test_failures_after_each_generated_asset_preserve_the_previous_set(self):
        first = self.run_recipe("release-stage")
        self.assertEqual(first.returncode, 0, first.stderr)
        previous = self.staged_snapshot()

        for phase in (
            "archive-ready",
            "checksum-ready",
            "manifest-ready",
            "before-publish",
        ):
            with self.subTest(phase=phase):
                def fail_at(actual_phase):
                    if actual_phase == phase:
                        raise RuntimeError(f"injected failure at {phase}")

                with self.direct_release_context(), mock.patch.object(
                    release_module,
                    "_publication_checkpoint",
                    side_effect=fail_at,
                ):
                    with self.assertRaisesRegex(RuntimeError, phase):
                        release_module.stage("v0.1.4")

                self.assertEqual(self.staged_snapshot(), previous)
                with self.direct_release_context():
                    release_module.verify_assets("v0.1.4")
                self.assertFalse(self.stale_generations())

    def test_exception_after_atomic_publish_leaves_one_complete_generation(self):
        first = self.run_recipe("release-stage")
        self.assertEqual(first.returncode, 0, first.stderr)

        def fail_after_publish(phase):
            if phase == "after-publish":
                raise RuntimeError("injected failure after-publish")

        with self.direct_release_context(), mock.patch.object(
            release_module,
            "_publication_checkpoint",
            side_effect=fail_after_publish,
        ):
            with self.assertRaisesRegex(RuntimeError, "after-publish"):
                release_module.stage("v0.1.4")

        self.staged_snapshot()
        self.assertEqual(len(self.stale_generations()), 1)
        with self.direct_release_context():
            release_module.verify_assets("v0.1.4")
        self.assertFalse(self.stale_generations())

    def test_parent_directory_fsync_failure_leaves_one_complete_generation(self):
        first = self.run_recipe("release-stage")
        self.assertEqual(first.returncode, 0, first.stderr)
        original_fsync_directory = release_module._fsync_directory
        injected = False
        publication_parent_syncs = 0

        def fail_post_rename_parent_fsync(path):
            nonlocal injected, publication_parent_syncs
            if Path(path).resolve() == (self.root / "dist").resolve():
                publication_parent_syncs += 1
                if publication_parent_syncs == 2:
                    injected = True
                    raise OSError("injected parent directory fsync failure")
            return original_fsync_directory(path)

        with self.direct_release_context(), mock.patch.object(
            release_module,
            "_fsync_directory",
            side_effect=fail_post_rename_parent_fsync,
        ):
            with self.assertRaisesRegex(OSError, "parent directory fsync"):
                release_module.stage("v0.1.4")

        self.assertTrue(injected)
        self.staged_snapshot()
        self.assertEqual(len(self.stale_generations()), 1)
        with self.direct_release_context():
            release_module.verify_assets("v0.1.4")
        self.assertFalse(self.stale_generations())

    def test_complete_interrupted_first_stage_is_recovered(self):
        def fail_before_publish(phase):
            if phase == "before-publish":
                raise RuntimeError("injected failure before-publish")

        with self.direct_release_context(), mock.patch.object(
            release_module,
            "_publication_checkpoint",
            side_effect=fail_before_publish,
        ):
            with self.assertRaisesRegex(RuntimeError, "before-publish"):
                release_module.stage("v0.1.4")

        self.assertFalse(self.staged_directory().exists())
        self.assertEqual(len(self.stale_generations()), 1)
        with self.direct_release_context():
            release_module.verify_assets("v0.1.4")
        self.staged_snapshot()
        self.assertFalse(self.stale_generations())

    def test_sigkill_before_and_after_publish_never_exposes_a_mixed_set(self):
        first = self.run_recipe("release-stage")
        self.assertEqual(first.returncode, 0, first.stderr)

        child = r'''
import os
import signal
from tools.release import release

phase_to_kill = os.environ["MARKDEV_TEST_KILL_PHASE"]
def kill_at(phase):
    if phase == phase_to_kill:
        os.kill(os.getpid(), signal.SIGKILL)
release._publication_checkpoint = kill_at
release.stage("v0.1.4")
'''
        for phase in ("before-publish", "after-publish"):
            with self.subTest(phase=phase):
                result = subprocess.run(
                    [sys.executable, "-c", child],
                    cwd=self.root,
                    env={**self.env, "MARKDEV_TEST_KILL_PHASE": phase},
                    text=True,
                    capture_output=True,
                    timeout=30,
                )
                self.assertEqual(result.returncode, -signal.SIGKILL, result.stderr)
                self.staged_snapshot()
                self.assertEqual(len(self.stale_generations()), 1)
                verify = self.run_recipe("release-verify")
                self.assertEqual(verify.returncode, 0, verify.stderr)
                self.assertFalse(self.stale_generations())

    def test_concurrent_publishers_are_serialized_per_tag(self):
        ready = self.root / "dist/concurrent.ready"
        resume = self.root / "dist/concurrent.resume"
        child = r'''
import os
from pathlib import Path
import time
from tools.release import release

ready = Path("dist/concurrent.ready")
resume = Path("dist/concurrent.resume")
def wait_at(phase):
    if phase == "before-publish":
        ready.write_text("ready\n")
        deadline = time.monotonic() + 20
        while not resume.exists():
            if time.monotonic() >= deadline:
                raise RuntimeError("timed out waiting for concurrent publisher test")
            time.sleep(0.01)
release._publication_checkpoint = wait_at
release.stage("v0.1.4")
'''
        publisher = subprocess.Popen(
            [sys.executable, "-c", child],
            cwd=self.root,
            env=self.env,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self.addCleanup(lambda: publisher.poll() is None and publisher.kill())
        for _ in range(1500):
            if ready.exists():
                break
            if publisher.poll() is not None:
                break
            time.sleep(0.01)
        self.assertTrue(ready.exists(), publisher.stderr.read() if publisher.poll() is not None else "")

        with self.direct_release_context(), mock.patch.object(
            release_module,
            "RELEASE_LOCK_TIMEOUT_SECONDS",
            0.1,
        ):
            for operation in (
                release_module.stage,
                release_module.verify_assets,
                release_module.draft,
            ):
                with self.subTest(blocked_operation=operation.__name__):
                    with self.assertRaisesRegex(
                        release_module.ReleaseError,
                        "already in progress",
                    ):
                        operation("v0.1.4")

        resume.write_text("resume\n")
        stdout, stderr = publisher.communicate(timeout=30)
        self.assertEqual(publisher.returncode, 0, stdout + stderr)
        self.staged_snapshot()

    def test_verify_recovers_complete_stale_generation_and_removes_partial_stale(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        dist = self.root / "dist"
        recoverable = dist / ".stage-MarkDev-0.1.4-macos.recoverable"
        self.staged_directory().rename(recoverable)
        partial = dist / ".stage-MarkDev-0.1.4-macos.partial"
        partial.mkdir()
        (partial / "MarkDev-0.1.4-macos.zip").write_text("partial")

        verify = self.run_recipe("release-verify")
        self.assertEqual(verify.returncode, 0, verify.stderr)
        self.staged_snapshot()
        self.assertFalse(self.stale_generations())

    def test_stale_generation_scan_is_bounded(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        for index in range(release_module.MAX_STALE_GENERATIONS_PER_TAG + 1):
            (self.root / "dist" / f".stage-MarkDev-0.1.4-macos.{index:03d}").mkdir()

        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("too many stale release generations", verify.stderr)

    def test_stale_generation_scan_bounds_total_bytes_before_hashing(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        oversized = (
            self.root
            / "dist/.stage-MarkDev-0.1.4-macos.oversized/MarkDev-0.1.4-macos.zip"
        )
        oversized.parent.mkdir()
        with oversized.open("wb") as stream:
            stream.truncate(release_module.MAX_STALE_BYTES_PER_TAG + 1)

        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("exceed the size limit", verify.stderr)

    def test_unexpected_stale_generation_objects_fail_closed(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        dist = self.root / "dist"
        for kind in ("symlink", "file"):
            with self.subTest(kind=kind):
                unexpected = dist / f".stage-MarkDev-0.1.4-macos.{kind}"
                if kind == "symlink":
                    unexpected.symlink_to(self.staged_directory())
                else:
                    unexpected.write_text("not a generation directory\n")
                try:
                    verify = self.run_recipe("release-verify")
                    self.assertNotEqual(verify.returncode, 0)
                    self.assertIn("not a real directory", verify.stderr)
                    self.assertTrue(unexpected.is_symlink() or unexpected.is_file())
                finally:
                    unexpected.unlink()

        nested = dist / ".stage-MarkDev-0.1.4-macos.nested-link"
        nested.mkdir()
        linked_asset = nested / "MarkDev-0.1.4-macos.zip"
        linked_asset.symlink_to(self.staged_asset(".zip"))
        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("unexpected object", verify.stderr)
        self.assertTrue(linked_asset.is_symlink(), "cleanup must not follow a stale link")

    def test_published_generation_requires_exact_private_regular_assets(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        extra = self.staged_directory() / "unpublished.txt"
        extra.write_text("not part of the release set\n")
        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("unexpected inventory", verify.stderr)
        extra.unlink()

        archive = self.staged_asset(".zip")
        outside_link = self.root / "dist/release-archive-hardlink"
        os.link(archive, outside_link)
        try:
            verify = self.run_recipe("release-verify")
            self.assertNotEqual(verify.returncode, 0)
            self.assertIn("single-link regular file", verify.stderr)
        finally:
            outside_link.unlink()

    def test_published_generation_inventory_stops_at_the_first_excess_entry(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        for index in range(32):
            (self.staged_directory() / f"unexpected-{index:02d}").write_text("extra\n")

        original_iterdir = Path.iterdir
        examined = 0

        def fail_if_fully_enumerated(path):
            iterator = original_iterdir(path)
            if Path(path).resolve() != self.staged_directory().resolve():
                return iterator

            def guarded():
                nonlocal examined
                for entry in iterator:
                    examined += 1
                    if examined > 4:
                        raise AssertionError("published inventory enumeration was unbounded")
                    yield entry

            return guarded()

        with self.direct_release_context(), mock.patch.object(
            Path,
            "iterdir",
            fail_if_fully_enumerated,
        ):
            with self.assertRaisesRegex(release_module.ReleaseError, "unexpected inventory"):
                release_module.verify_assets("v0.1.4")
        self.assertLessEqual(examined, 4)

    def test_dist_inventory_scan_has_an_overall_fanout_limit(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        for index in range(256):
            (self.root / "dist" / f"unrelated-{index:03d}").write_text("unrelated\n")

        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("distribution directory has too many entries", verify.stderr)

    def test_hashing_rejects_growth_and_path_replacement_on_the_open_descriptor(self):
        path = self.root / "growing-release-asset"
        path.write_bytes(b"a" * (2 * 1024 * 1024))

        def grow(phase):
            if phase == "after-open":
                with path.open("ab") as stream:
                    stream.write(b"growth")

        with self.assertRaisesRegex(release_module.ReleaseError, "changed while hashing"):
            release_module.digest(
                path,
                maximum_bytes=4 * 1024 * 1024,
                _checkpoint=grow,
            )

        path.write_bytes(b"stable bytes")
        moved = self.root / "original-release-asset"

        def replace(phase):
            if phase == "after-open":
                path.rename(moved)
                path.write_bytes(b"stable bytes")

        try:
            with self.assertRaisesRegex(
                release_module.ReleaseError,
                "changed while hashing",
            ):
                release_module.digest(path, _checkpoint=replace)
        finally:
            path.unlink(missing_ok=True)
            moved.rename(path)

    def test_archive_extraction_is_bound_to_the_verified_descriptor(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        archive = self.staged_asset(".zip")
        displaced = archive.with_name("displaced-release-archive.zip")
        replacement = archive.with_name("replacement-release-archive.zip")
        shutil.copy2(archive, replacement)
        original_run = release_module.run
        swapped = False

        def swap_before_extract(*args, **kwargs):
            nonlocal swapped
            if args[:3] == ("ditto", "-x", "-k") and not swapped:
                archive.rename(displaced)
                replacement.rename(archive)
                swapped = True
            return original_run(*args, **kwargs)

        try:
            with self.direct_release_context(), mock.patch.object(
                release_module,
                "run",
                side_effect=swap_before_extract,
            ):
                expected = release_module.preflight("v0.1.4")
                with self.assertRaisesRegex(
                    release_module.ReleaseError,
                    "changed while verifying",
                ):
                    release_module.verify_archive(archive, expected)
            self.assertTrue(swapped, "the regression did not reach archive extraction")
        finally:
            archive.unlink(missing_ok=True)
            replacement.unlink(missing_ok=True)
            if displaced.exists():
                displaced.rename(archive)

    def test_bounded_regular_file_reads_reject_initial_and_concurrent_growth(self):
        path = self.root / "bounded-sidecar"
        path.write_bytes(b"12345")
        with self.assertRaisesRegex(release_module.ReleaseError, "exceeds"):
            release_module._read_regular_file(path, 4, "test sidecar")

        def grow(phase):
            if phase == "after-open":
                with path.open("ab") as stream:
                    stream.write(b"6")

        with self.assertRaisesRegex(release_module.ReleaseError, "changed while reading"):
            release_module._read_regular_file(
                path,
                16,
                "test sidecar",
                _checkpoint=grow,
            )

    def test_manifest_duplicate_keys_are_rejected_at_every_object_depth(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.staged_asset(".json")
        original = manifest.read_text()
        ambiguous = (
            original.replace(
                '"sha256":',
                '"sha256": "ignored-first-value",\n  "sha256":',
                1,
            ),
            original.replace(
                '"signature": "ad-hoc"',
                '"signature": "ignored-first-value",\n    "signature": "ad-hoc"',
                1,
            ),
        )
        for value in ambiguous:
            with self.subTest(manifest=value):
                manifest.write_text(value)
                verify = self.run_recipe("release-verify")
                self.assertNotEqual(verify.returncode, 0)
                self.assertIn("duplicate JSON key", verify.stderr)
        manifest.write_text(original)

    def test_manifest_rejects_nonstandard_json_constants_and_type_confusion(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        manifest = self.staged_asset(".json")
        original = manifest.read_text()
        for constant in ("NaN", "Infinity", "-Infinity"):
            with self.subTest(constant=constant):
                manifest.write_text(
                    original.replace('"build": "9"', f'"build": {constant}', 1)
                )
                verify = self.run_recipe("release-verify")
                self.assertNotEqual(verify.returncode, 0)
                self.assertIn("nonstandard JSON constant", verify.stderr)

        manifest.write_text(
            original.replace('"hardened_runtime": false', '"hardened_runtime": 0', 1)
        )
        verify = self.run_recipe("release-verify")
        self.assertNotEqual(verify.returncode, 0)
        self.assertIn("do not match", verify.stderr)
        manifest.write_text(original)

    def test_manifest_contract_constants_are_immutable(self):
        cases = (
            (release_module.AUTOMATED_DISTRIBUTION, "signature", "ad-hoc"),
            (release_module.RELEASE_TOOLCHAIN, "xcode", "2660"),
        )
        for values, key, expected in cases:
            with self.subTest(key=key):
                try:
                    with self.assertRaises(TypeError):
                        values[key] = "mutated"
                finally:
                    if values[key] != expected:
                        values[key] = expected

    def test_stale_extra_code_or_resource_is_rejected(self):
        extras = (
            self.app / "Contents/MacOS/StaleHelper",
            self.app / "Contents/Resources/stale.txt",
        )
        for extra in extras:
            with self.subTest(extra=extra.relative_to(self.app)):
                extra.parent.mkdir(parents=True, exist_ok=True)
                extra.write_text("stale build output\n")
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                extra.unlink()

    def test_optional_pkginfo_must_be_a_regular_file(self):
        pkginfo = self.app / "Contents/PkgInfo"
        pkginfo.mkdir()
        self.assertNotEqual(
            self.run_recipe("release-stage").returncode,
            0,
            "an optional name must not become an unconstrained directory namespace",
        )

    def test_quicklook_bundle_leaf_cannot_be_a_symlink_into_optional_payload(self):
        quicklook = self.app / "Contents/PlugIns/MarkDevQuickLook.appex"
        hidden = self.root / "hidden-MarkDevQuickLook.appex"
        quicklook.rename(hidden)
        quicklook.symlink_to(hidden)
        main_info = plistlib.loads(self.plists[0].read_bytes())
        expected = {
            "version": "0.1.4",
            "build": "9",
            "commit": main_info["MarkDevSourceCommit"],
        }
        with self.direct_release_context():
            with self.assertRaises(
                release_module.ReleaseError,
                msg="the extension leaf itself must be a real directory",
            ):
                release_module.verify_bundle(self.app, expected)

    def test_direct_release_verification_never_writes_to_the_source_checkout(self):
        source_log = REPO / "commands.jsonl"
        before = source_log.read_bytes() if source_log.exists() else None
        main_info = plistlib.loads(self.plists[0].read_bytes())
        expected = {
            "version": "0.1.4",
            "build": "9",
            "commit": main_info["MarkDevSourceCommit"],
        }

        with self.direct_release_context():
            release_module.verify_bundle(self.app, expected)

        after = source_log.read_bytes() if source_log.exists() else None
        self.assertEqual(after, before, "fixture commands escaped into the source checkout")
        fixture_log = self.root / "commands.jsonl"
        self.assertTrue(fixture_log.is_file())
        self.assertTrue(
            all(
                str(self.root) in argument
                for command in self.commands()
                for argument in command[1:]
                if argument.startswith("/")
            )
        )

    def test_missing_required_release_payload_is_rejected(self):
        required = (
            self.app / "Contents/Resources/AppIcon.icns",
            self.app / "Contents/Resources/Assets.car",
            self.app / "Contents/Resources/DocumentIcon.icns",
            self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle",
            self.app / "Contents/Resources/SwiftTerm_SwiftTerm.bundle",
            self.app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Resources/SwiftMath_SwiftMath.bundle",
            self.app / "Contents/Resources/SwiftTerm_SwiftTerm.bundle/Contents/Resources/default.metallib",
            self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle/Contents/Resources/mathFonts.bundle/latinmodern-math.otf",
        )
        for index, path in enumerate(required):
            with self.subTest(path=path.relative_to(self.app)):
                backup = self.root / "products" / f"required-payload-backup-{index}"
                path.rename(backup)
                try:
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                finally:
                    backup.rename(path)

    def test_required_top_level_resources_must_be_regular_files(self):
        for index, path in enumerate((
            self.app / "Contents/Resources/AppIcon.icns",
            self.app / "Contents/Resources/Assets.car",
            self.app / "Contents/Resources/DocumentIcon.icns",
            *self.privacy_manifests,
        )):
            with self.subTest(path=path.relative_to(self.app)):
                backup = self.root / "products" / f"regular-file-backup-{index}"
                path.rename(backup)
                path.symlink_to(backup)
                try:
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                finally:
                    path.unlink()
                    backup.rename(path)

    def test_package_resource_bundle_metadata_is_exact_and_decodable(self):
        cases = (
            (
                self.app / "Contents/Resources/SwiftMath_SwiftMath.bundle",
                lambda path: release_module.verify_math_resource_bundle(path, "SwiftMath"),
                {
                    "CFBundleIdentifier": "swiftmath.SwiftMath.resources",
                    "CFBundleName": "SwiftMath_SwiftMath",
                    "CFBundlePackageType": "BNDL",
                    "CFBundleSupportedPlatforms": ["MacOSX"],
                    "DTPlatformBuild": "25F70",
                    "DTPlatformName": "macosx",
                    "DTPlatformVersion": "26.5",
                    "DTSDKBuild": "25F70",
                    "DTSDKName": "macosx26.5",
                    "DTXcode": "2660",
                    "DTXcodeBuild": "17F113",
                    "LSMinimumSystemVersion": "12.0",
                },
            ),
            (
                self.app / "Contents/PlugIns/MarkDevQuickLook.appex/Contents/Resources/SwiftMath_SwiftMath.bundle",
                lambda path: release_module.verify_math_resource_bundle(path, "Quick Look SwiftMath"),
                {
                    "CFBundleIdentifier": "swiftmath.SwiftMath.resources",
                    "CFBundleName": "SwiftMath_SwiftMath",
                    "CFBundlePackageType": "BNDL",
                    "CFBundleSupportedPlatforms": ["MacOSX"],
                    "DTPlatformBuild": "25F70",
                    "DTPlatformName": "macosx",
                    "DTPlatformVersion": "26.5",
                    "DTSDKBuild": "25F70",
                    "DTSDKName": "macosx26.5",
                    "DTXcode": "2660",
                    "DTXcodeBuild": "17F113",
                    "LSMinimumSystemVersion": "12.0",
                },
            ),
            (
                self.app / "Contents/Resources/SwiftTerm_SwiftTerm.bundle",
                release_module.verify_swiftterm_resource_bundle,
                {
                    "CFBundleIdentifier": "swiftterm.SwiftTerm.resources",
                    "CFBundleName": "SwiftTerm_SwiftTerm",
                    "CFBundlePackageType": "BNDL",
                    "CFBundleSupportedPlatforms": ["MacOSX"],
                    "DTPlatformBuild": "25F70",
                    "DTPlatformName": "macosx",
                    "DTPlatformVersion": "26.5",
                    "DTSDKBuild": "25F70",
                    "DTSDKName": "macosx26.5",
                    "DTXcode": "2660",
                    "DTXcodeBuild": "17F113",
                    "LSMinimumSystemVersion": "11.0",
                },
            ),
        )
        for bundle, verify, expected in cases:
            metadata = bundle / "Contents/Info.plist"
            original = metadata.read_bytes()
            with self.subTest(bundle=bundle.name, failure="malformed"):
                metadata.write_bytes(b"not a property list")
                try:
                    with self.assertRaises(release_module.ReleaseError):
                        verify(bundle)
                finally:
                    metadata.write_bytes(original)
            for key in expected:
                with self.subTest(bundle=bundle.name, failure=f"missing {key}"):
                    changed = plistlib.loads(original)
                    changed.pop(key)
                    metadata.write_bytes(plistlib.dumps(changed))
                    try:
                        with self.assertRaises(release_module.ReleaseError):
                            verify(bundle)
                    finally:
                        metadata.write_bytes(original)

    def test_framework_symlink_contract_is_required(self):
        link = self.app / "Contents/Frameworks/MarkDevKit.framework/Versions/Current"
        link.unlink()
        link.symlink_to("B")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_owned_plist_runtime_contracts_are_required(self):
        mutations = (
            (0, "CFBundleExecutable", "OtherApp"),
            (0, "CFBundlePackageType", "BNDL"),
            (1, "CFBundlePackageType", "APPL"),
            (2, "CFBundlePackageType", "BNDL"),
        )
        for index, key, value in mutations:
            with self.subTest(bundle=index, key=key):
                original = self.plists[index].read_bytes()
                self.change_plist(index, key, value)
                try:
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                finally:
                    self.plists[index].write_bytes(original)

        original = self.plists[1].read_bytes()
        plist = plistlib.loads(original)
        for key, value in (
            ("NSExtensionPointIdentifier", "com.apple.wrong"),
            ("NSExtensionPrincipalClass", "Wrong.Controller"),
        ):
            with self.subTest(quicklook=key):
                changed = plistlib.loads(original)
                changed["NSExtension"][key] = value
                self.plists[1].write_bytes(plistlib.dumps(changed))
                self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
        self.plists[1].write_bytes(original)

    def test_main_bundle_finder_metadata_is_exact(self):
        original = self.plists[0].read_bytes()
        mutations = {
            "wrong app icon name": ("CFBundleIconName", "StaleIcon"),
            "wrong icon file": ("CFBundleIconFile", "MissingIcon"),
            "missing document claims": ("CFBundleDocumentTypes", []),
            "broadened imported type": (
                "UTImportedTypeDeclarations",
                [{
                    "UTTypeIdentifier": "net.daringfireball.markdown",
                    "UTTypeDescription": "Markdown Document",
                    "UTTypeConformsTo": ["public.plain-text"],
                    "UTTypeTagSpecification": {
                        "public.filename-extension": ["md", "markdown", "mdx"],
                    },
                }],
            ),
            "incomplete exported type": (
                "UTExportedTypeDeclarations",
                [{
                    "UTTypeIdentifier": "dev.markdev.markdown-extended",
                    "UTTypeDescription": "Markdown Document",
                    "UTTypeConformsTo": ["net.daringfireball.markdown"],
                    "UTTypeTagSpecification": {
                        "public.filename-extension": ["mdown", "mdx", "mkd"],
                    },
                }],
            ),
        }
        for failure, (key, value) in mutations.items():
            with self.subTest(failure=failure):
                changed = plistlib.loads(original)
                changed[key] = value
                self.plists[0].write_bytes(plistlib.dumps(changed))
                try:
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                finally:
                    self.plists[0].write_bytes(original)

        for key in (
            "CFBundleIconName",
            "CFBundleIconFile",
            "CFBundleDocumentTypes",
            "UTImportedTypeDeclarations",
            "UTExportedTypeDeclarations",
        ):
            with self.subTest(failure=f"missing {key}"):
                changed = plistlib.loads(original)
                changed.pop(key)
                self.plists[0].write_bytes(plistlib.dumps(changed))
                try:
                    self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                finally:
                    self.plists[0].write_bytes(original)

    def test_main_bundle_cannot_reenable_termination_that_bypasses_close_review(self):
        original = self.plists[0].read_bytes()
        for key in (
            "NSSupportsAutomaticTermination",
            "NSSupportsSuddenTermination",
        ):
            for failure in ("enabled", "missing"):
                with self.subTest(key=key, failure=failure):
                    changed = plistlib.loads(original)
                    if failure == "enabled":
                        changed[key] = True
                    else:
                        changed.pop(key)
                    self.plists[0].write_bytes(plistlib.dumps(changed))
                    try:
                        self.assertNotEqual(
                            self.run_recipe("release-stage").returncode,
                            0,
                        )
                    finally:
                        self.plists[0].write_bytes(original)

    def test_owned_bundle_toolchain_provenance_is_required(self):
        for index in range(len(self.plists)):
            for key, value in (
                ("DTXcode", "9999"),
                ("DTXcodeBuild", "wrong"),
                ("DTSDKBuild", "wrong"),
            ):
                with self.subTest(bundle=index, key=key, failure="wrong"):
                    original = self.plists[index].read_bytes()
                    self.change_plist(index, key, value)
                    try:
                        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                    finally:
                        self.plists[index].write_bytes(original)
                with self.subTest(bundle=index, key=key, failure="missing"):
                    original = self.plists[index].read_bytes()
                    changed = plistlib.loads(original)
                    changed.pop(key)
                    self.plists[index].write_bytes(plistlib.dumps(changed))
                    try:
                        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
                    finally:
                        self.plists[index].write_bytes(original)

    def test_tag_is_data_not_shell_code(self):
        self.run_recipe("verify-tag", "v$(touch injected).1.4")
        self.assertFalse((self.root / "injected").exists())

    def test_invalid_version_is_rejected(self):
        path = self.root / "project.yml"
        path.write_text(path.read_text().replace("0.1.4", "banana"))
        self.assertNotEqual(self.run_recipe("verify-tag", "vbanana").returncode, 0)

    def test_bundle_from_different_commit_is_rejected(self):
        self.change_plist(0, "MarkDevSourceCommit", "0" * 40)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_dirty_source_is_rejected(self):
        with (self.root / "project.yml").open("a") as stream:
            stream.write("# changed after build\n")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_missing_notes_are_rejected(self):
        (self.root / "docs/releases/v0.1.4.md").unlink()
        self.assertNotEqual(self.run_recipe("release-preflight").returncode, 0)

    def test_lightweight_release_tag_is_rejected(self):
        subprocess.run(
            ["git", "tag", "-d", "v0.1.4"],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        subprocess.run(
            ["git", "tag", "v0.1.4"],
            cwd=self.root,
            check=True,
            capture_output=True,
        )
        self.assertNotEqual(self.run_recipe("release-preflight").returncode, 0)

    def test_duplicate_metadata_is_rejected(self):
        with (self.root / "project.yml").open("a") as stream:
            stream.write('    MARKETING_VERSION: "0.1.4"\n')
        self.assertNotEqual(self.run_recipe("verify-tag").returncode, 0)

    def test_invalid_build_number_is_rejected(self):
        path = self.root / "project.yml"
        path.write_text(path.read_text().replace('"9"', '"0"'))
        self.assertNotEqual(self.run_recipe("verify-tag").returncode, 0)

    def test_new_draft_uploads_once_and_retry_is_idempotent(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        result = self.attach()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.attach().returncode, 0)
        uploads = [c for c in self.commands() if c[:3] == ["gh", "release", "upload"]]
        self.assertEqual(len(uploads), 1)
        self.assertNotIn("--clobber", uploads[0])
        state = json.loads((self.root / "state.json").read_text())
        self.assertEqual(len(state["release"]["assets"]), 3)
        self.assertEqual(
            {asset["name"] for asset in state["release"]["assets"]},
            {
                "MarkDev-0.1.4-macos.zip",
                "MarkDev-0.1.4-macos.zip.sha256",
                "MarkDev-0.1.4-macos.json",
            },
            "the local generation directory must not change GitHub asset names",
        )
        self.assertTrue(state["release"]["isDraft"])

    def test_partial_upload_resumes_only_missing_assets(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.assertEqual(self.attach().returncode, 0)
        state = json.loads((self.root / "state.json").read_text())
        state["release"]["assets"] = state["release"]["assets"][:1]
        self.state(**state)
        result = self.attach()
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [c for c in self.commands() if c[:3] == ["gh", "release", "upload"]]
        self.assertEqual(len(uploads[-1][4:]), 2)
        self.assertFalse(any(value.endswith(".zip") for value in uploads[-1][4:]))

    def test_local_asset_mutation_during_upload_is_rejected(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(mutate_during_upload=True)
        result = self.attach()
        self.assertNotEqual(
            result.returncode,
            0,
            "remote bytes matching a locally mutated asset must not bless stale sidecars",
        )

    def test_remote_asset_mismatch_is_not_overwritten(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(release={"isDraft": True, "tagName": "v0.1.4", "assets": [
            {"name": "MarkDev-0.1.4-macos.zip", "size": 1, "digest": "sha256:wrong", "state": "uploaded"}
        ]})
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(c[:3] == ["gh", "release", "upload"] for c in self.commands()))

    def test_corrupt_local_archive_never_reaches_github(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.staged_asset(".zip").write_bytes(b"corrupt")
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(c[:2] == ["gh", "release"] for c in self.commands()))

    def test_coordinated_archive_checksum_and_manifest_tamper_is_rejected(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        archive = self.staged_asset(".zip")
        checksum = self.staged_asset(".zip.sha256")
        manifest = self.staged_asset(".json")
        with zipfile.ZipFile(archive, "a") as bundle:
            bundle.writestr("attacker.txt", "coordinated replacement")
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum.write_text(f"{sha}  {archive.name}\n")
        recorded = json.loads(manifest.read_text())
        recorded["sha256"] = sha
        manifest.write_text(json.dumps(recorded))

        self.assertNotEqual(
            self.run_recipe("release-verify").returncode,
            0,
            "matching sidecar hashes must not substitute for reopening the app bundle",
        )

    def test_coordinated_macosx_sidecar_tamper_is_rejected(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        archive = self.staged_asset(".zip")
        checksum = self.staged_asset(".zip.sha256")
        manifest = self.staged_asset(".json")
        with zipfile.ZipFile(archive, "a") as bundle:
            bundle.writestr("__MACOSX/unsealed-payload.txt", "outside the app seal")
        sha = hashlib.sha256(archive.read_bytes()).hexdigest()
        checksum.write_text(f"{sha}  {archive.name}\n")
        recorded = json.loads(manifest.read_text())
        recorded["sha256"] = sha
        manifest.write_text(json.dumps(recorded))

        self.assertNotEqual(self.run_recipe("release-verify").returncode, 0)

    def test_release_verify_rechecks_the_extracted_bundle_signature(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(extracted_signature_fail=True)
        self.assertNotEqual(self.run_recipe("release-verify").returncode, 0)

    def attach(self):
        if "release-draft" in (self.root / "justfile").read_text():
            return self.run_recipe("release-draft")
        # Exercise the original workflow before the upload logic has a recipe.
        workflow = (REPO / ".github/workflows/release.yml").read_text()
        body = workflow.split("      - name: Attach to Draft Release", 1)[1].split("        run: |\n", 1)[1]
        script = "\n".join(line[10:] for line in body.splitlines())
        return subprocess.run(["bash", "-euo", "pipefail", "-c", script],
                              cwd=self.root, env={**self.env, "TAG": "v0.1.4"},
                              text=True, capture_output=True, timeout=30)

    def test_published_release_is_never_overwritten(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(release={"isDraft": False, "tagName": "v0.1.4", "assets": []})
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(command[:3] == ["gh", "release", "upload"] for command in self.commands()))

    def test_api_failure_does_not_attempt_creation(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(api_fail=True)
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(command[:3] == ["gh", "release", "create"] for command in self.commands()))


if __name__ == "__main__":
    unittest.main()
