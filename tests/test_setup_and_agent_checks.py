"""Exercise launch/setup decisions without changing the host configuration."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = shutil.which("bash")
MOCK = textwrap.dedent("""\
    import json
    import os
    from pathlib import Path
    import sys

    name = Path(sys.argv[0]).name
    args = sys.argv[1:]
    scenario = json.loads(os.environ["TEST_SCENARIO"])
    with open(os.environ["TEST_CALLS"], "a") as log:
        log.write(json.dumps([name, *args]) + "\\n")
    if name == "chezmoi":
        command = args[0]
        if command == "source-path":
            print("mock dotfiles")
        elif command == "status":
            print(scenario.get("changed", ""), end="")
        elif command == "unmanaged":
            print(scenario.get("new", ""), end="")
        else:
            sys.exit("Unexpected chezmoi command")
        sys.exit(scenario.get(command + "_exit", 0))
    elif name == "getent":
        if scenario.get("getent_exit", 0):
            sys.exit(scenario["getent_exit"])
        print("audit:x:1000:1000::" + os.environ["HOME"] + ":/bin/bash")
    elif name == "lsattr":
        print(scenario.get("attributes", "----------------------") + " " + args[-1])
        sys.exit(scenario.get("lsattr_exit", 0))
    elif name == "ujust":
        sys.exit(scenario.get("ujust_exit", 0))
    else:
        sys.exit("Unexpected mock command")
    """)


class ScriptTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="myblue-script-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.calls.write_text("")
        for name in ("chezmoi", "getent", "lsattr", "ujust"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o755)

    def run_script(self, script, *, answer="", env=None, **scenario):
        environment = os.environ | {
            "HOME": str(self.home),
            "XDG_CONFIG_HOME": str(self.home / ".config"),
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TEST_SCENARIO": json.dumps(scenario),
            "TEST_CALLS": str(self.calls),
            "PYTHONDONTWRITEBYTECODE": "1",
        } | (env or {})
        result = subprocess.run([BASH, "-c", script], env=environment, input=answer,
                                capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        return result, calls


class AgentCheckTests(ScriptTests):
    def setUp(self):
        super().setUp()
        self.script = (ROOT / "files/system/usr/bin/myblue-agent-check").read_text()
        self.skills = self.home / ".config/opencode/skills"
        self.skills.mkdir(parents=True)

    def test_clean_config_starts_without_confirmation_and_checks_opencode_skills(self):
        result, calls = self.run_script(self.script)
        self.assertEqual(result.returncode, 0, result.stderr)
        for command in ("status", "unmanaged"):
            self.assertIn(str(self.skills), next(call for call in calls if call[:2] ==
                                                ["chezmoi", command]))

    def test_custom_xdg_config_directory_is_checked(self):
        config = self.home / "custom-config"
        skills = config / "opencode/skills"
        skills.mkdir(parents=True)
        result, calls = self.run_script(self.script, env={"XDG_CONFIG_HOME": str(config)})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(str(skills), next(call for call in calls if call[:2] ==
                                       ["chezmoi", "status"]))
        self.assertIn(str(skills), next(call for call in calls if call[:2] ==
                                       ["chezmoi", "unmanaged"]))

    def test_changed_or_new_skills_need_explicit_confirmation(self):
        for scenario in ({"changed": " M .config/opencode/skills/example/SKILL.md\n"},
                         {"new": ".config/opencode/skills/example/SKILL.md\n"}):
            for answer, expected in (("", 1), ("n\n", 1), ("y\n", 0)):
                with self.subTest(scenario=scenario, answer=answer):
                    result, _ = self.run_script(self.script, answer=answer, **scenario)
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertIn("example/SKILL.md", result.stderr)

    def test_unavailable_chezmoi_needs_confirmation(self):
        (self.bin / "chezmoi").unlink()
        for answer, expected in (("", 1), ("n\n", 1), ("y\n", 0)):
            with self.subTest(answer=answer):
                result, _ = self.run_script(self.script, answer=answer,
                                            env={"PATH": str(self.bin)})
                self.assertEqual(result.returncode, expected, result.stderr)
                self.assertIn("chezmoi is unavailable", result.stderr)

    def test_failed_chezmoi_checks_need_confirmation_even_with_empty_output(self):
        for command in ("source-path", "status", "unmanaged"):
            for answer, expected in (("", 1), ("y\n", 0)):
                with self.subTest(command=command, answer=answer):
                    result, _ = self.run_script(self.script, answer=answer,
                                                **{command + "_exit": 1})
                    self.assertEqual(result.returncode, expected, result.stderr)
                    self.assertIn("not fully checked", result.stderr)

    def test_synced_claude_skills_exception_is_preserved_but_not_extended(self):
        result, _ = self.run_script(self.script, new=".claude/skills/synced\n")
        self.assertEqual(result.returncode, 0, result.stderr)
        result, _ = self.run_script(self.script, new=".claude/skills/synced\n.config/opencode/skills/new\n")
        self.assertNotEqual(result.returncode, 0)


class SetupTests(ScriptTests):
    def setUp(self):
        super().setUp()
        self.policy = self.root / "usbguard.conf"
        self.mac = self.root / "rand_mac.conf"
        self.bashrc = self.home / ".bashrc"
        self.bashrc.write_text("# test shell config\n")
        self.script = (ROOT / "files/system/usr/bin/myblue-setup").read_text()
        self.script = self.script.replace("/etc/usbguard/rules.conf", str(self.policy))
        self.script = self.script.replace("/etc/NetworkManager/conf.d/rand_mac.conf", str(self.mac))

    def setup_calls(self, **scenario):
        result, calls = self.run_script(self.script, answer="y\n" * 30, **scenario)
        self.assertEqual(result.returncode, 0, result.stderr)
        return [call[1:] for call in calls if call[0] == "ujust"]

    def test_fresh_setup_offers_hardening(self):
        calls = self.setup_calls()
        for command in ("setup-usbguard", "toggle-mac-randomization", "toggle-bash-environment-lockdown"):
            self.assertIn([command], calls)

    def test_existing_hardening_is_never_toggled_off_or_policy_regenerated(self):
        self.policy.write_text("existing USB policy\n")
        self.mac.write_text("existing MAC config\n")
        calls = self.setup_calls(attributes="----i-----------------")
        for command in ("setup-usbguard", "toggle-mac-randomization", "toggle-bash-environment-lockdown"):
            self.assertNotIn([command], calls)
        self.assertEqual(self.policy.read_text(), "existing USB policy\n")
        self.assertEqual(self.mac.read_text(), "existing MAC config\n")
        self.assertIn(["set-container-userns", "on"], calls)

    def test_missing_bashrc_can_be_locked(self):
        self.bashrc.unlink()
        self.assertIn(["toggle-bash-environment-lockdown"], self.setup_calls())

    def test_unknown_bash_lockdown_state_is_not_toggled(self):
        calls = self.setup_calls(lsattr_exit=1)
        self.assertNotIn(["toggle-bash-environment-lockdown"], calls)

    def test_missing_attribute_output_does_not_toggle_bash_lockdown(self):
        calls = self.setup_calls(attributes="")
        self.assertNotIn(["toggle-bash-environment-lockdown"], calls)

    def test_unknown_home_directory_does_not_toggle_bash_lockdown(self):
        calls = self.setup_calls(getent_exit=1)
        self.assertNotIn(["toggle-bash-environment-lockdown"], calls)

    def test_declining_setup_does_not_change_anything(self):
        result, calls = self.run_script(self.script, answer="n\n" * 30)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(call[0] == "ujust" for call in calls))


if __name__ == "__main__":
    unittest.main()
