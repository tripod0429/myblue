"""Run the build workflow's own shell steps, taken from build.yml as they are."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
IMAGE = "ghcr.io/tripod0429/myblue"
TAG = IMAGE + ":build"
DIGEST = "sha256:" + "1" * 64


def step_script(name):
    lines = (ROOT / ".github/workflows/build.yml").read_text().splitlines()
    start = lines.index("        run: |", lines.index(f"      - name: {name}")) + 1
    commands = []
    for line in lines[start:]:
        if line.strip() and not line.startswith("          "):
            break
        commands.append(line[10:])
    return "\n".join(commands)


class DigestReaderTests(unittest.TestCase):
    """The digest this step outputs is the one CI signs, attests and tags latest."""

    @classmethod
    def setUpClass(cls):
        if not shutil.which("jq"):
            raise RuntimeError("These tests require jq")
        cls.script = step_script("Read pushed digest")

    def setUp(self):
        directory = tempfile.TemporaryDirectory(prefix="myblue-digest-test-")
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.digests = self.root / "digests.json"
        self.output = self.root / "output"

    def read(self, content):
        if content is None:
            self.digests.unlink(missing_ok=True)
        else:
            self.digests.write_text(content)
        self.output.write_text("")
        # The shell GitHub runs `run:` steps with.
        result = subprocess.run(["bash", "--noprofile", "--norc", "-eo", "pipefail", "-c", self.script],
                                env=os.environ | {"RUNNER_TEMP": str(self.root),
                                                  "GITHUB_OUTPUT": str(self.output),
                                                  "IMAGE": IMAGE},
                                capture_output=True, text=True, timeout=30)
        return result, self.output.read_text()

    def test_accepts_one_digest_for_a_tag_of_the_image(self):
        for tag in (TAG, IMAGE + ":br-main-build-44"):
            with self.subTest(tag=tag):
                result, output = self.read(json.dumps({tag: DIGEST}))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(output, f"digest={DIGEST}\n")

    def test_rejects_anything_else(self):
        cases = {
            "missing file": None,
            "empty file": "",
            "not JSON": "garbage",
            "empty map": "{}",
            "two images": json.dumps({TAG: DIGEST, IMAGE + "-other:build": DIGEST}),
            "map, then an empty object": json.dumps({TAG: DIGEST}) + "{}",
            "map, then another map": json.dumps({TAG: DIGEST}) * 2,
            "array": json.dumps([DIGEST]),
            "other owner": json.dumps({"ghcr.io/someone-else/myblue:build": DIGEST}),
            "look-alike name": json.dumps({IMAGE + "-evil:build": DIGEST}),
            "no tag": json.dumps({IMAGE: DIGEST}),
            "short digest": json.dumps({TAG: "sha256:12"}),
            "null digest": json.dumps({TAG: None}),
            "digest and newline": json.dumps({TAG: DIGEST + "\n"}),
            "two digests": json.dumps({TAG: DIGEST + "\n" + DIGEST}),
        }
        for name, content in cases.items():
            with self.subTest(name):
                result, output = self.read(content)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("::error::", result.stdout)
                self.assertEqual(output, "")


if __name__ == "__main__":
    unittest.main()
