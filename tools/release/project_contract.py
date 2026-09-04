"""Check effective Xcode settings so target presets cannot override release metadata."""
import json
from pathlib import Path
import plistlib
import re
import unittest

from release import metadata, run


class ProjectVersionTests(unittest.TestCase):
    def test_every_owned_target_uses_the_project_version(self):
        source = Path("project.yml").read_text()
        version = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', source).group(1)
        expected = metadata("v" + version)
        owned = {"MarkDev", "MarkDevKit", "MarkDevQuickLook"}
        for configuration in ("Debug", "Release"):
            settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-alltargets",
                                      "-configuration", configuration, "-showBuildSettings", "-json").stdout)
            self.assertTrue(owned.issubset({item["target"] for item in settings}))
            for item in settings:
                if item["target"] in owned:
                    with self.subTest(configuration=configuration, target=item["target"]):
                        self.assertEqual(item["buildSettings"]["CURRENT_PROJECT_VERSION"], expected["build"])
                        self.assertEqual(item["buildSettings"]["MARKETING_VERSION"], expected["version"])

    def test_main_app_stays_unsandboxed_and_quicklook_is_read_only_sandboxed(self):
        with Path("app/MarkDevQuickLook/MarkDevQuickLook.entitlements").open("rb") as stream:
            entitlements = plistlib.load(stream)
        self.assertEqual(entitlements, {
            "com.apple.security.app-sandbox": True,
            "com.apple.security.files.user-selected.read-only": True,
        })

        settings = json.loads(run("xcodebuild", "-project", "MarkDev.xcodeproj", "-alltargets",
                                  "-configuration", "Release", "-showBuildSettings", "-json").stdout)
        by_target = {item["target"]: item["buildSettings"] for item in settings}
        self.assertEqual(by_target["MarkDev"].get("ENABLE_APP_SANDBOX"), "NO")
        self.assertEqual(by_target["MarkDev"].get("CODE_SIGN_ENTITLEMENTS", ""), "")
        self.assertEqual(by_target["MarkDevQuickLook"].get("ENABLE_APP_SANDBOX"), "YES")
        self.assertEqual(
            by_target["MarkDevQuickLook"].get("CODE_SIGN_ENTITLEMENTS"),
            "app/MarkDevQuickLook/MarkDevQuickLook.entitlements")


if __name__ == "__main__":
    unittest.main()
