"""Real Git/SSH checks; registry, approval signing and system services are mocked."""

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
IMAGE = "ghcr.io/tripod0429/myblue"
DIGEST = "sha256:" + "1" * 64
CHILD_DIGEST = "sha256:" + "2" * 64
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
    if name == "git":
        if "fetch" in args:
            if scenario.get("fetch_exit", 0):
                sys.exit(scenario["fetch_exit"])
            args = [os.environ["TEST_REMOTE"] if arg == "https://github.com/tripod0429/myblue"
                    else arg for arg in args]
        os.execv(os.environ["TEST_GIT"], [os.environ["TEST_GIT"], *args])
    elif name == "rpm-ostree":
        print(json.dumps({"deployments": [{"container-image-reference":
            scenario.get("ref", "ostree-image-signed:docker://ghcr.io/tripod0429/myblue:latest")}]}))
    elif name == "crane":
        print(scenario.get("digest", "sha256:" + "1" * 64))
    elif name == "slsa-verifier":
        print(json.dumps({"predicate": {"invocation": {"configSource": {
            "digest": {"sha1": scenario["commit"]}}}}}))
        sys.exit(scenario.get("provenance_exit", 0))
    elif name == "gpg":
        if "--list-secret-keys" in args:
            print("sec:::::::::")
            print("fpr:::::::::" + "A" * 40 + ":")
        elif "--export" in args:
            print("mock public approval key")
        elif "--quick-gen-key" not in args:
            sys.exit("Unexpected gpg command")
    elif name == "skopeo":
        if args[:2] == ["inspect", "--raw"]:
            manifest = {"schemaVersion": 2}
            if scenario.get("index") and args[-1].endswith("@" + "sha256:" + "1" * 64):
                manifest["manifests"] = [
                    {"platform": {"os": "linux", "architecture": "amd64"},
                     "digest": "sha256:" + "2" * 64},
                    {"platform": {"os": "linux", "architecture": "arm64"},
                     "digest": "sha256:" + "3" * 64}]
            print(json.dumps(manifest))
        elif args[0] == "standalone-sign":
            if scenario.get("approval_exit", 0):
                sys.exit(scenario["approval_exit"])
            Path(args[args.index("-o") + 1]).write_bytes(b"mock approval")
        else:
            sys.exit("Unexpected skopeo command")
    elif name == "systemctl":
        sys.exit(scenario.get("service_exit", 0))
    elif name == "journalctl":
        print("mock approval service output")
    elif name not in ("chmod", "flock", "gpgconf"):
        sys.exit("Unexpected mock command")
    """)


class ProvenanceTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.git_program = shutil.which("git")
        if not all(shutil.which(tool) for tool in ("git", "ssh-keygen", "jq")):
            raise RuntimeError("These tests require git, ssh-keygen and jq")
        directory = tempfile.TemporaryDirectory(prefix="myblue-history-test-")
        cls.addClassCleanup(directory.cleanup)
        cls.fixture = Path(directory.name)
        cls.env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
        cls.env.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL="/dev/null",
                       GIT_ALLOW_PROTOCOL="file",
                       GIT_AUTHOR_NAME="Audit", GIT_AUTHOR_EMAIL="audit@example.invalid",
                       GIT_COMMITTER_NAME="Audit", GIT_COMMITTER_EMAIL="audit@example.invalid")
        cls.key = cls.fixture / "signing-key"
        cls.other_key = cls.fixture / "other-key"
        for key in (cls.key, cls.other_key):
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                           env=cls.env, check=True, capture_output=True)
        cls.remote = cls.fixture / "remote.git"
        subprocess.run([cls.git_program, "init", "-q", "--bare", "--template=", str(cls.remote)],
                       env=cls.env, check=True, capture_output=True)
        cls.tree = cls.git("hash-object", "-t", "tree", "-w", "--stdin", data="").strip()
        cls.old = cls.commit("old")
        cls.installed = cls.commit("installed", cls.old)
        middle = cls.commit("middle", cls.installed)
        cls.new = cls.commit("new", middle)
        cls.divergent = cls.commit("divergent", cls.old)
        cls.unrelated = cls.commit("unrelated")
        cls.merge = cls.commit("merge", cls.divergent, cls.installed)
        cls.unsigned = cls.commit("unsigned", cls.installed, signed=False)
        cls.wrong_signer = cls.commit("wrong-signer", cls.installed, key=cls.other_key)
        cls.git("symbolic-ref", "HEAD", "refs/heads/new")

    @classmethod
    def git(cls, *args, data=None):
        return subprocess.run([cls.git_program, "-C", str(cls.remote), *args], input=data,
                              text=True, capture_output=True, env=cls.env, check=True).stdout

    @classmethod
    def commit(cls, name, *parents, signed=True, key=None):
        args = ["-c", "gpg.format=ssh", "-c", f"user.signingkey={key or cls.key}",
                "commit-tree", cls.tree, "-m", name]
        if signed:
            args.append("-S")
        for parent in parents:
            args.extend(["-p", parent])
        commit = cls.git(*args).strip()
        cls.git("update-ref", "refs/heads/" + name, commit)
        return commit

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="myblue-provenance-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.work = self.root / "work"
        self.work.mkdir()
        self.calls = self.root / "calls.jsonl"
        self.calls.write_text("")
        self.anchor = self.root / "source-commit"
        self.anchor.write_text(self.installed + "\n")
        self.signers = self.root / "allowed_signers"
        self.signers.write_text('audit@example.invalid namespaces="git" ' +
                                self.key.with_suffix(".pub").read_text())
        self.containers = self.root / "containers"
        registries = self.containers / "registries.d"
        registries.mkdir(parents=True)
        self.keyring = self.root / "approval.gpg"
        self.keyring.write_text("mock public approval key")
        self.signatures = self.root / "sigstore"
        self.gnupg = self.root / "approval-gnupg"
        self.gnupg.mkdir(mode=0o700)
        self.policy = self.containers / "policy.json"
        self.policy.write_text(json.dumps({"transports": {"docker": {IMAGE: [
            {"type": "sigstoreSigned", "keyPath": "unused-mock-cosign-key"},
            {"type": "signedBy", "keyPath": str(self.keyring), "keyType": "GPGKeys"}]}}}))
        (registries / "myblue.yaml").write_text(
            f"docker:\n  {IMAGE}:\n    use-sigstore-attachments: true\n"
            f"    lookaside: file://{self.signatures}\n")
        for name in ("git", "rpm-ostree", "crane", "slsa-verifier", "chmod", "skopeo",
                     "gpg", "gpgconf", "flock", "systemctl", "journalctl"):
            path = self.bin / name
            path.write_text(f"#!{sys.executable}\n" + MOCK)
            path.chmod(0o755)

    def run_script(self, script, *, arguments=(), **scenario):
        env = self.env | {
            "PATH": f"{self.bin}{os.pathsep}{os.environ['PATH']}",
            "TMPDIR": str(self.work),
            "TEST_SCENARIO": json.dumps({"commit": self.new, **scenario}),
            "TEST_CALLS": str(self.calls),
            "TEST_REMOTE": str(self.remote),
            "TEST_GIT": self.git_program,
            "TEST_EUID": str(scenario.get("euid", 0)),
            "PYTHONDONTWRITEBYTECODE": "1",
        }
        result = subprocess.run(["bash", "-c", script, "myblue-test", *arguments], env=env,
                                capture_output=True, text=True, timeout=30)
        calls = [json.loads(line) for line in self.calls.read_text().splitlines()]
        self.assertEqual(list(self.work.iterdir()), [], "Temporary checkout leaked")
        return result, calls

    def verify(self, *, bootstrap=False, bootstrap_signers=None, **scenario):
        script = (ROOT / "files/system/usr/libexec/secureblue/verify-provenance.sh").read_text()
        # Redirect every privileged path to this test's temporary directory.
        # Simulate EUID only in this copy; production exposes no such override.
        replacements = {
            "readonly SOURCE_COMMIT_FILE=/usr/share/myblue/source-commit":
                f"readonly SOURCE_COMMIT_FILE={self.anchor}",
            "ALLOWED_SIGNERS=/usr/share/myblue/allowed_signers": f"ALLOWED_SIGNERS={self.signers}",
            "readonly CONTAINERS=/etc/containers": f"readonly CONTAINERS={self.containers}",
            "readonly KEYRING=/etc/pki/containers/myblue-approval.gpg": f"readonly KEYRING={self.keyring}",
            "readonly SIGNATURES=/var/lib/containers/sigstore": f"readonly SIGNATURES={self.signatures}",
            "readonly GNUPG=/var/lib/myblue/approval-gnupg": f"readonly GNUPG={self.gnupg}",
            "/run/myblue-approval.lock": str(self.root / "approval.lock"),
            "-x /usr/bin/rpm-ostree": f"-x {self.bin}/rpm-ostree",
            "if (( EUID != 0 )); then": "if (( TEST_EUID != 0 )); then",
        }
        for original, replacement in replacements.items():
            self.assertEqual(script.count(original), 1, f"Unrecognized script fixture: {original}")
            script = script.replace(original, replacement)
        arguments = (["--bootstrap", str(bootstrap_signers or self.signers), scenario.get("digest", DIGEST)]
                     if bootstrap else [])
        return self.run_script(script, arguments=arguments, **scenario)

    def assert_no_approval(self, calls):
        self.assertFalse(any(call[0] in ("gpg", "skopeo", "flock") for call in calls),
                         "Rejected image reached machine approval")

    def approval_path(self, digest):
        return self.signatures / (IMAGE.split("/", 1)[1] + "@" + digest.replace(":", "="))

    def test_same_source_rebuild_is_allowed(self):
        result, _ = self.verify(commit=self.installed)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.approval_path(DIGEST) / "signature-1").exists())

    def test_signed_descendant_is_allowed_with_complete_ancestry(self):
        result, calls = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        fetch = next(call for call in calls if call[0] == "git" and "fetch" in call)
        self.assertIn("--no-tags", fetch)
        self.assertFalse(any(arg.startswith("--depth") for arg in fetch))
        self.assertIn(f"{IMAGE}@{DIGEST}",
                      next(call for call in calls if call[0] == "slsa-verifier"))
        signature_check = next(i for i, call in enumerate(calls) if "verify-commit" in call)
        ancestry_check = next(i for i, call in enumerate(calls) if "merge-base" in call)
        first_approval = next(i for i, call in enumerate(calls) if call[0] == "flock")
        self.assertLess(signature_check, ancestry_check)
        self.assertLess(ancestry_check, first_approval)

    def test_signed_merge_descending_from_installed_source_is_allowed(self):
        result, _ = self.verify(commit=self.merge)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_installing_a_new_source_advances_the_floor(self):
        self.anchor.write_text(self.new + "\n")
        result, calls = self.verify(commit=self.installed)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("refusing older or unrelated source history", result.stderr)
        self.assert_no_approval(calls)
        result, _ = self.verify(commit=self.new)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_old_divergent_and_unrelated_signed_sources_are_rejected(self):
        for commit in (self.old, self.divergent, self.unrelated):
            with self.subTest(commit=commit):
                result, calls = self.verify(commit=commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("refusing older or unrelated source history", result.stderr)
                self.assert_no_approval(calls)

    def test_unsigned_and_wrong_signer_descendants_are_rejected(self):
        for commit in (self.unsigned, self.wrong_signer):
            with self.subTest(commit=commit):
                result, calls = self.verify(commit=commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("is not signed by a key", result.stderr)
                self.assert_no_approval(calls)

    def test_missing_source_anchor_fails_before_network_checks(self):
        self.anchor.unlink()
        result, calls = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing or invalid installed source commit", result.stderr)
        self.assertEqual(calls, [])

    def test_invalid_source_anchor_fails_before_network_checks(self):
        for value in ("", "not-a-commit", self.installed + "\n" + self.old):
            with self.subTest(value=value):
                self.anchor.write_text(value)
                result, calls = self.verify()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("missing or invalid installed source commit", result.stderr)
                self.assertEqual(calls, [])

    def test_invalid_provenance_commit_is_rejected(self):
        for commit in (None, "", "not-a-commit"):
            with self.subTest(commit=commit):
                result, calls = self.verify(commit=commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any(call[0] == "git" for call in calls))
                self.assert_no_approval(calls)

    def test_provenance_or_fetch_failure_is_rejected(self):
        for scenario in ({"provenance_exit": 1}, {"fetch_exit": 1}):
            with self.subTest(scenario=scenario):
                result, calls = self.verify(**scenario)
                self.assertNotEqual(result.returncode, 0)
                self.assert_no_approval(calls)

    def test_explicit_root_bootstrap_does_not_require_an_installed_source_marker(self):
        self.anchor.unlink()
        result, calls = self.verify(bootstrap=True, commit=self.old)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any("verify-commit" in call for call in calls))
        self.assertFalse(any("merge-base" in call for call in calls))
        self.assertFalse(any(call[0] in ("rpm-ostree", "crane") for call in calls))
        self.assertTrue((self.approval_path(DIGEST) / "signature-1").exists())

    def test_bootstrap_still_requires_an_allowed_commit_signature(self):
        self.anchor.unlink()
        for commit in (self.unsigned, self.wrong_signer):
            with self.subTest(commit=commit):
                result, calls = self.verify(bootstrap=True, commit=commit)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("is not signed by a key", result.stderr)
                self.assert_no_approval(calls)

    def test_explicit_root_recovery_uses_the_supplied_trusted_signers(self):
        recovery_signers = self.root / "recovery_signers"
        recovery_signers.write_text('audit@example.invalid namespaces="git" ' +
                                    self.other_key.with_suffix(".pub").read_text())
        self.anchor.unlink()
        result, calls = self.verify(bootstrap=True, bootstrap_signers=recovery_signers,
                                    commit=self.wrong_signer)
        self.assertEqual(result.returncode, 0, result.stderr)
        check = next(call for call in calls if "verify-commit" in call)
        self.assertIn(f"gpg.ssh.allowedSignersFile={recovery_signers}", check)
        self.assertTrue((self.approval_path(DIGEST) / "signature-1").exists())

    def test_bootstrap_rejects_invalid_digest_before_fetching(self):
        result, calls = self.verify(bootstrap=True, digest="not-a-digest")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_unprivileged_run_delegates_to_the_fixed_service(self):
        self.anchor.unlink()  # The privileged service checks its own installed floor.
        result, calls = self.verify(euid=1000)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls[0], ["systemctl", "start", "myblue-approve.service"])
        self.assertTrue(all(call[0] in ("systemctl", "journalctl") for call in calls))

    def test_unprivileged_bootstrap_cannot_choose_what_the_service_approves(self):
        result, calls = self.verify(bootstrap=True, euid=1000)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("--bootstrap must run as root", result.stderr)
        self.assertEqual(calls, [])

    def test_service_failure_is_propagated_without_local_approval(self):
        result, calls = self.verify(euid=1000, service_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [["systemctl", "start", "myblue-approve.service"]])

    def test_normal_updates_require_signed_image_transport(self):
        result, calls = self.verify(ref=f"ostree-unverified-image:docker://{IMAGE}:latest")
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_approval(calls)
        self.assertFalse(any(call[0] == "slsa-verifier" for call in calls))

    def test_missing_approval_policy_or_lookaside_is_rejected(self):
        policy = self.policy.read_text()
        self.policy.write_text(json.dumps({"transports": {"docker": {IMAGE: [
            {"type": "sigstoreSigned"}]}}}))
        result, calls = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])
        self.policy.write_text(policy)
        (self.containers / "registries.d/myblue.yaml").unlink()
        result, calls = self.verify()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_index_approves_only_itself_and_amd64_child_and_retires_old_approvals(self):
        old = self.approval_path("sha256:" + "f" * 64)
        old.mkdir(parents=True)
        (old / "signature-1").write_text("old mock approval")
        result, calls = self.verify(index=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.approval_path(DIGEST) / "signature-1").exists())
        self.assertTrue((self.approval_path(CHILD_DIGEST) / "signature-1").exists())
        self.assertFalse(old.exists())
        self.assertEqual(sum(call[:2] == ["skopeo", "standalone-sign"] for call in calls), 2)

    def test_first_use_generates_approval_key_only_after_ancestry_check(self):
        self.keyring.unlink()
        result, calls = self.verify()
        self.assertEqual(result.returncode, 0, result.stderr)
        ancestry = next(i for i, call in enumerate(calls) if "merge-base" in call)
        generation = next(i for i, call in enumerate(calls) if "--quick-gen-key" in call)
        self.assertLess(ancestry, generation)
        self.assertEqual(self.keyring.read_text(), "mock public approval key\n")
        self.assertTrue((self.approval_path(DIGEST) / "signature-1").exists())

    def test_failed_approval_does_not_report_success(self):
        result, _ = self.verify(approval_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse((self.approval_path(DIGEST) / "signature-1").exists())
        self.assertNotIn(f"approved {DIGEST} for this machine", result.stdout)

    def test_ci_records_only_the_workflow_source_commit(self):
        lines = (ROOT / ".github/workflows/build.yml").read_text().splitlines()
        start = lines.index("      - name: Record image source commit") + 2
        self.assertLess(start, lines.index("      - name: Build"))
        commands = []
        for line in lines[start:]:
            if line.strip() and not line.startswith("          "):
                break
            commands.append(line[10:])
        script = "\n".join(commands)
        checkout = self.root / "checkout"
        subprocess.run([self.git_program, "clone", "-q", "--no-hardlinks", str(self.remote),
                        str(checkout)], env=self.env, check=True, capture_output=True)
        marker = checkout / "files/system/usr/share/myblue/source-commit"
        marker.parent.mkdir(parents=True)
        for sha, expected_exit in ((self.old, 1), (self.new, 0)):
            with self.subTest(sha=sha):
                result = subprocess.run(["bash", "-e", "-c", script], cwd=checkout,
                                        env=self.env | {"GITHUB_SHA": sha},
                                        capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, expected_exit, result.stderr)
                if expected_exit:
                    self.assertFalse(marker.exists())
                else:
                    self.assertEqual(marker.read_text(), sha + "\n")

    def test_build_rejects_missing_or_invalid_source_metadata(self):
        script = (ROOT / "files/scripts/myblue-image-setup.sh").read_text()
        script = script.replace("/usr/share/myblue/source-commit", str(self.anchor))
        policy = self.root / "policy.json"
        original = '{"default":[{"type":"reject"}],"transports":{"docker":{}}}'
        policy.write_text(original)
        script = script.replace("/etc/containers/policy.json", str(policy))
        script = script.replace("/tmp/policy.json", str(self.root / "policy.tmp"))
        for value in (None, "not-a-commit", self.installed):
            with self.subTest(value=value):
                self.calls.write_text("")
                if value is None:
                    self.anchor.unlink()
                else:
                    self.anchor.write_text(value + "\n")
                result, calls = self.run_script(script)
                self.assertEqual(result.returncode, int(value != self.installed), result.stderr)
                if value != self.installed:
                    self.assertEqual(policy.read_text(), original)
                    self.assertFalse(any(call[0] == "chmod" for call in calls))
                else:
                    self.assertIn(["chmod", "0644", str(self.anchor)], calls)


if __name__ == "__main__":
    unittest.main()
