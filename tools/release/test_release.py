"""Exercise release boundaries through the same just recipes used by CI."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

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
            path.write_bytes(plistlib.dumps({
                "CFBundleShortVersionString": "0.1.4", "CFBundleVersion": "9",
                "CFBundleExecutable": executable, "CFBundleIdentifier": identifier,
                "LSMinimumSystemVersion": "26.0",
            }))
            self.plists.append(path)
            binary = directory / "MacOS" / executable if folder.endswith("Contents") else directory.parent / executable
            binary.parent.mkdir(exist_ok=True)
            binary.write_text("fixture executable\n")
        binary_dir = self.root / "bin"
        binary_dir.mkdir()
        fake = binary_dir / "fake"
        fake.write_text('''#!/usr/bin/env python3
import json, os, pathlib, sys
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
        print(json.dumps([{"target": "MarkDev", "buildSettings": {"BUILT_PRODUCTS_DIR": str(root / "products")}}]))
    else:
        print(" BUILT_PRODUCTS_DIR = " + str(root / "products"))
elif name == "codesign":
    if state.get("signature_fail"):
        sys.exit(1)
elif name == "lipo":
    print(state.get("architecture", "arm64"))
elif name == "ditto":
    if state.get("zip_fail"):
        sys.exit(1)
    os.execv("/usr/bin/ditto", ["ditto", *args])
elif name == "gh":
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
            release["assets"].append({"name": p.name, "size": p.stat().st_size, "digest": "sha256:" + hashlib.sha256(p.read_bytes()).hexdigest(), "state": "uploaded"})
    state_path.write_text(json.dumps(state))
''')
        fake.chmod(0o755)
        for name in ["xcodebuild", "codesign", "lipo", "ditto", "gh"]:
            (binary_dir / name).symlink_to(fake)
        self.env = {**os.environ, "PATH": str(binary_dir) + os.pathsep + os.environ["PATH"]}
        for command in [["git", "init", "-q"], ["git", "add", "."],
                        ["git", "-c", "user.name=Release Test", "-c", "user.email=test@example.test", "-c", "commit.gpgsign=false", "commit", "-qm", "fixture"],
                        ["git", "tag", "v0.1.4"], ["git", "remote", "add", "origin", str(self.root)]]:
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

    def test_matching_bundle_stages(self):
        result = self.run_recipe("release-stage")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.root / "dist/MarkDev-0.1.4-macos.zip").is_file())

    def test_wrong_marketing_version_is_rejected(self):
        self.change_plist(0, "CFBundleShortVersionString", "0.1.3")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_stale_build_is_rejected(self):
        self.change_plist(0, "CFBundleVersion", "8")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_stale_extension_is_rejected(self):
        self.change_plist(1, "CFBundleVersion", "8")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_wrong_architecture_is_rejected(self):
        self.state(architecture="x86_64")
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_signature_failure_is_rejected(self):
        self.state(signature_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_settings_failure_is_rejected(self):
        self.state(settings_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)

    def test_packaging_failure_preserves_previous_stage(self):
        (self.root / "dist").mkdir()
        previous = self.root / "dist/previous.zip"
        previous.write_text("previous good artifact")
        self.state(zip_fail=True)
        self.assertNotEqual(self.run_recipe("release-stage").returncode, 0)
        self.assertTrue(previous.exists(), "failed staging destroyed the previous artifact")

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

    def test_remote_asset_mismatch_is_not_overwritten(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        self.state(release={"isDraft": True, "tagName": "v0.1.4", "assets": [
            {"name": "MarkDev-0.1.4-macos.zip", "size": 1, "digest": "sha256:wrong", "state": "uploaded"}
        ]})
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(c[:3] == ["gh", "release", "upload"] for c in self.commands()))

    def test_corrupt_local_archive_never_reaches_github(self):
        self.assertEqual(self.run_recipe("release-stage").returncode, 0)
        (self.root / "dist/MarkDev-0.1.4-macos.zip").write_bytes(b"corrupt")
        self.assertNotEqual(self.attach().returncode, 0)
        self.assertFalse(any(c[0] == "gh" for c in self.commands()))

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
