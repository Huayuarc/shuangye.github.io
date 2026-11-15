#!/usr/bin/env python3
"""Exercise the shipped postinst lifecycle against a deterministic launchctl."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
SCRIPT = (ROOT / "Packaging/DEBIAN/postinst").read_text()
LIFECYCLE = "label=wiki.qaq.apelind" + SCRIPT.split("label=wiki.qaq.apelind", 1)[1]
MOCK = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ["MOCK_STATE"])
s = json.loads(p.read_text())
args = sys.argv[1:]
s["calls"].append(args)
code = 0
if args[0] == "bootout":
    if s["mode"] != "old-job-stuck":
        s["loaded"] = False
elif args[0] == "print":
    code = 0 if s["loaded"] else 113
elif args[0] == "bootstrap":
    s["attempts"] += 1
    if s["mode"] == "delayed" and s["attempts"] >= 4:
        s["loaded"] = True
    elif s["mode"] == "registered-with-error":
        s["loaded"] = True
    code = 0 if s["mode"] == "false-success" else 37
p.write_text(json.dumps(s))
sys.exit(code)
'''


class DaemonRegistrationTests(unittest.TestCase):
    def run_lifecycle(self, mode):
        with tempfile.TemporaryDirectory(prefix="apelin-launchctl-test-") as directory:
            base = Path(directory)
            state = base / "state.json"
            state.write_text(json.dumps({"mode": mode, "loaded": True, "attempts": 0, "calls": []}))
            executable = base / "launchctl"
            executable.write_text(MOCK)
            executable.chmod(0o755)
            lookup = "return 1" if mode == "no-tool" else "printf '%s\\n' " + shlex.quote(str(executable))
            script = "find_tool() { " + lookup + "; }\nsleep() { :; }\n" + LIFECYCLE
            result = subprocess.run(["/bin/sh", "-c", script], env={**os.environ, "MOCK_STATE": str(state)}, capture_output=True, text=True)
            return result, json.loads(state.read_text())

    def test_retries_in_progress_until_a_job_is_registered(self):
        result, state = self.run_lifecycle("delayed")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["attempts"], 4)
        self.assertIn(["bootout", "system", "@PREFIX@/Library/LaunchDaemons/wiki.qaq.apelind.plist"], state["calls"])

    def test_nonzero_bootstrap_with_a_registered_job_is_accepted(self):
        result, state = self.run_lifecycle("registered-with-error")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["loaded"])

    def test_success_reply_without_registration_fails(self):
        result, state = self.run_lifecycle("false-success")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["attempts"], 30)
        self.assertIn("could not be registered", result.stderr)

    def test_an_old_job_never_counts_as_the_new_install(self):
        result, state = self.run_lifecycle("old-job-stuck")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["attempts"], 0)
        self.assertIn("did not finish unloading", result.stderr)

    def test_a_missing_launchctl_fails_configuration(self):
        result, state = self.run_lifecycle("no-tool")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(state["calls"], [])
        self.assertIn("launchctl is required", result.stderr)


if __name__ == "__main__":
    unittest.main()
