"""Offline control-flow tests; RPM cryptography is also tested with real RPMs."""

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

# No real package manager runs, and no system keyring or file is modified:
# rm only runs for real on the scripts' own temporary directories.
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
    if name == "rpmkeys":
        if "--import" in args:
            sys.exit(scenario.get("import_exit", 0))
        if "--list" in args:
            print(scenario["fingerprints"])
        elif "--checksig" in args:
            if scenario.get("wrong_signer") and "--dbpath" in args:
                print(f"{args[-1]}: NOTTRUSTED")
                sys.exit(1)
            print(f"{args[-1]}: {scenario.get('signature_text', 'digests signatures OK')}")
            sys.exit(scenario.get("signature_exit", 0))
    elif name == "rpm":
        if "-qp" in args:
            print(scenario["identity"], end="")
        elif "--import" not in args:
            sys.exit("Unexpected RPM command")
    elif name == "curl":
        if "-w" in args:
            print(scenario["url"], end="")
        elif "-o" in args:
            Path(args[args.index("-o") + 1]).write_bytes(b"mock download")
        else:
            print(json.dumps({"RpmFile": scenario["url"]}))
    elif name == "rm":
        paths = [arg for arg in args if not arg.startswith("-")]
        if paths and all(Path(path).is_relative_to(os.environ["TMPDIR"]) for path in paths):
            os.execv(os.environ["TEST_REAL_RM"], ["rm", *args])
    elif name not in ("dnf", "mkdir", "ln", "find", "systemctl", "mullvad", "mullvad-daemon"):
        sys.exit("Unexpected mock command")
    """)
MOCKED = ["rpmkeys", "rpm", "curl", "dnf", "rm", "mkdir", "ln", "find", "systemctl",
          "mullvad", "mullvad-daemon"]
# Commands that change the image; none may run before verification passes.
INSTALLING = ("dnf", "mkdir", "ln", "systemctl")


class SignedRpmTests:
    """Shared by both installers; subclasses name the package."""

    install_script: str
    key: str
    fingerprint: str
    name: str
    url: str
    bad_urls: list[str]

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="myblue-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.work = self.root / "work"
        self.work.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.package = self.root / f"{self.name}.rpm"
        self.package.write_bytes(b"mock RPM")
        self.real_rm = shutil.which("rm")
        for name in MOCKED:
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o755)

    def run_case(self, *, install=False, **scenario):
        self.calls.write_text("")
        env = os.environ | {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TMPDIR": str(self.work),
            "CONFIG_DIRECTORY": str(ROOT / "files"),
            "TEST_CALLS": str(self.calls),
            "TEST_REAL_RM": self.real_rm,
            "TEST_SCENARIO": json.dumps({"fingerprints": self.fingerprint,
                                         "identity": f"{self.name} x86_64",
                                         "url": self.url, **scenario}),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        if install:
            command = ["bash", str(ROOT / "files/scripts" / self.install_script)]
        else:
            command = ["bash", str(ROOT / "files/scripts/verify-rpm.sh"), str(self.package),
                       str(ROOT / "files/keys" / self.key), self.fingerprint, self.name]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(list(self.work.iterdir()), [], "Temporary verification/download files leaked")
        return result, calls

    def assert_no_install(self, calls):
        self.assertFalse(any(call[0] in INSTALLING for call in calls))
        self.assertFalse(any(call[0] == "rpm" and "--import" in call for call in calls))

    def test_valid_package_uses_only_isolated_rpmdb(self):
        result, calls = self.run_case()
        self.assertEqual(result.returncode, 0, result.stderr)
        rpm_calls = [call for call in calls if call[0] in ("rpm", "rpmkeys")]
        databases = set()
        for call in rpm_calls:
            self.assertEqual(call[call.index("--define") + 1], "_keyring rpmdb")
            database = Path(call[call.index("--dbpath") + 1])
            self.assertTrue(database.is_relative_to(self.work))
            databases.add(database)
        self.assertEqual(len(databases), 1)

    def test_wrong_or_multiple_keys_are_rejected(self):
        for fingerprints in ["0" * 40, self.fingerprint + "\n" + "0" * 40]:
            with self.subTest(fingerprints=fingerprints):
                result, calls = self.run_case(install=True, fingerprints=fingerprints)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_install(calls)
                self.assertFalse(any("--checksig" in call for call in calls))

    def test_key_import_failure_is_rejected(self):
        result, calls = self.run_case(install=True, import_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_install(calls)

    def test_unsigned_package_is_rejected_even_with_success_exit(self):
        result, calls = self.run_case(install=True, signature_text="digests OK")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_install(calls)

    def test_signature_failure_is_rejected_even_with_success_text(self):
        result, calls = self.run_case(install=True, signature_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_install(calls)

    def test_other_signer_is_rejected_even_if_system_trusts_it(self):
        # The mock accepts this signer only when the global keyring is used.
        result, calls = self.run_case(install=True, wrong_signer=True)
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_install(calls)

    def test_wrong_package_identity_is_rejected(self):
        for identity in ["other-package x86_64", f"{self.name} aarch64"]:
            with self.subTest(identity=identity):
                result, calls = self.run_case(install=True, identity=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_install(calls)

    def test_unexpected_download_url_is_rejected(self):
        for url in self.bad_urls:
            with self.subTest(url=url):
                result, calls = self.run_case(install=True, url=url)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_install(calls)
                self.assertFalse(any(call[0] == "rpmkeys" for call in calls))

    def test_install_only_after_verification_and_without_weak_deps(self):
        result, calls = self.run_case(install=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        check = next(i for i, call in enumerate(calls) if "--checksig" in call)
        identity = next(i for i, call in enumerate(calls) if "-qp" in call)
        system_import = next(i for i, call in enumerate(calls)
                             if call[0] == "rpm" and "--import" in call)
        install = next(i for i, call in enumerate(calls) if call[0] == "dnf")
        changes = [i for i, call in enumerate(calls) if call[0] in INSTALLING]
        self.assertLess(check, identity)
        self.assertLess(identity, system_import)
        self.assertLess(identity, min(changes))
        self.assertLess(system_import, install)
        self.assertIn("--setopt=localpkg_gpgcheck=1", calls[install])
        self.assertIn("--setopt=install_weak_deps=False", calls[install])


class BridgeTests(SignedRpmTests, unittest.TestCase):
    install_script = "install-proton-bridge.sh"
    key = "proton-bridge.asc"
    fingerprint = "D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07"
    name = "protonmail-bridge"
    url = "https://proton.me/download/bridge/protonmail-bridge-3.27.1-1.x86_64.rpm"
    bad_urls = ["https://example.com/bridge.rpm"]


class MullvadTests(SignedRpmTests, unittest.TestCase):
    install_script = "install-mullvad.sh"
    key = "mullvad.asc"
    fingerprint = "A1198702FC3E0A09A9AE5B75D5A1D4F266DE8DDF"
    name = "mullvad-vpn"
    url = "https://cdn.mullvad.net/app/desktop/releases/2026.5/MullvadVPN-2026.5_x86_64.rpm"
    # No redirect, another host, and the ARM package.
    bad_urls = ["",
                "https://example.com/app/desktop/releases/2026.5/MullvadVPN-2026.5_x86_64.rpm",
                "https://cdn.mullvad.net/app/desktop/releases/2026.5/MullvadVPN-2026.5_aarch64.rpm"]

    def test_installs_into_usr_lib_opt_without_gui(self):
        result, calls = self.run_case(install=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        opt = "/usr/lib/opt/Mullvad VPN"
        link = calls.index(["ln", "-s", opt, "/var/opt/Mullvad VPN"])
        install = next(i for i, call in enumerate(calls) if call[0] == "dnf")
        unlink = calls.index(["rm", "/var/opt/Mullvad VPN"])
        gui = next(i for i, call in enumerate(calls) if call[0] == "find")
        self.assertLess(link, install)
        self.assertLess(install, unlink)
        self.assertLess(install, gui)
        # Everything in the package's folder but resources/ goes.
        self.assertEqual(calls[gui], ["find", opt, "-mindepth", "1", "-maxdepth", "1",
                                      "!", "-name", "resources",
                                      "-exec", "rm", "-rf", "--", "{}", "+"])
        self.assertIn(f"{opt}/resources/app.asar", next(
            call for call in calls[gui:] if call[0] == "rm"))
        self.assertIn(["systemctl", "enable", "mullvad-daemon.service",
                       "mullvad-early-boot-blocking.service"], calls)


if __name__ == "__main__":
    unittest.main()
