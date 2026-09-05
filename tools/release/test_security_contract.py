"""Static authority-boundary checks that must hold in every shipped build."""

from pathlib import Path
import unittest


class TerminalLaunchSecurityTests(unittest.TestCase):
    def test_harness_terminal_launch_is_typed_and_not_workspace_shell_source(self):
        workspace = Path("app/MarkDev/WorkspaceView.swift").read_text()
        session = Path("app/MarkDevKit/Terminal/TerminalSession.swift").read_text()
        host = Path("app/MarkDevKit/Terminal/TerminalProcessHost.swift").read_text()

        self.assertNotIn(
            "harnessBinary",
            workspace,
            "Workspace must consume the HarnessAssistant identity owner, not cache a raw path",
        )
        self.assertNotIn(
            "findHarness()",
            workspace,
            "Workspace must not start an untracked duplicate locator task",
        )
        self.assertNotIn(
            "initialCommand",
            session,
            "terminal startup must be a closed typed action, not arbitrary shell source",
        )
        self.assertIn("TerminalStartupAction", session)
        self.assertIn("executableEnvironmentKey", session)
        self.assertNotIn("view.send(txt: command", host)


if __name__ == "__main__":
    unittest.main()
