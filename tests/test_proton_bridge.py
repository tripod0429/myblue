"""Offline control-flow tests; RPM cryptography is also tested with real RPMs."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import textwrap
import unittest


ROOT = Path(__file__).resolve().parents[1]
FINGERPRINT = "D51E64D3E63EDC3EEF7864CEE2C75D68E6234B07"


class BridgeVerificationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="myblue-test-")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.work = self.root / "work"
        self.work.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.package = self.root / "protonmail-bridge.rpm"
        self.package.write_bytes(b"mock RPM")
        # No real package manager runs, and no system keyring is modified.
        mock = textwrap.dedent("""\
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
                    print(scenario.get("identity", "protonmail-bridge x86_64"), end="")
                elif "--import" not in args:
                    sys.exit("Unexpected RPM command")
            elif name == "curl":
                if "-o" in args:
                    Path(args[args.index("-o") + 1]).write_bytes(b"mock download")
                else:
                    print(json.dumps({"RpmFile": scenario.get("url",
                        "https://proton.me/download/bridge/protonmail-bridge-3.27.1-1.x86_64.rpm")}))
            elif name != "dnf":
                sys.exit("Unexpected mock command")
            """)
        for name in ["rpmkeys", "rpm", "curl", "dnf"]:
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + mock)
            path.chmod(0o755)

    def run_case(self, *, install=False, **scenario):
        self.calls.write_text("")
        env = os.environ | {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TMPDIR": str(self.work),
            "CONFIG_DIRECTORY": str(ROOT / "files"),
            "TEST_CALLS": str(self.calls),
            "TEST_SCENARIO": json.dumps({"fingerprints": FINGERPRINT, **scenario}),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        script = "install-proton-bridge.sh" if install else "verify-proton-bridge.sh"
        command = ["bash", str(ROOT / "files/scripts" / script)]
        if not install:
            command += [str(self.package), str(ROOT / "files/keys/proton-bridge.asc")]
        result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(list(self.work.iterdir()), [], "Temporary verification/download files leaked")
        return result, calls

    def assert_no_install(self, calls):
        self.assertFalse(any(call[0] == "dnf" for call in calls))
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
        for fingerprints in ["0" * 40, FINGERPRINT + "\n" + "0" * 40]:
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
        for identity in ["other-package x86_64", "protonmail-bridge aarch64"]:
            with self.subTest(identity=identity):
                result, calls = self.run_case(install=True, identity=identity)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_install(calls)

    def test_unexpected_download_url_is_rejected(self):
        result, calls = self.run_case(install=True, url="https://example.com/bridge.rpm")
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
        self.assertLess(check, identity)
        self.assertLess(identity, system_import)
        self.assertLess(system_import, install)
        self.assertIn("--setopt=localpkg_gpgcheck=1", calls[install])
        self.assertIn("--setopt=install_weak_deps=False", calls[install])


if __name__ == "__main__":
    unittest.main()
