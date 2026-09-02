"""Check effective Xcode settings so target presets cannot override release metadata."""
import json
from pathlib import Path
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


if __name__ == "__main__":
    unittest.main()
