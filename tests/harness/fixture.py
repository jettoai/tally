import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

BIN = os.environ["TALLY_HARNESS_TEST_BINARY"]


class Fixture(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tally-harness-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.source, self.target = self.root / "claude", self.root / "codex"
        self.project, self.state = self.root / "project", self.root / "state"
        self.skills = self.root / "skills"
        for path in (self.source, self.target, self.project):
            path.mkdir()
        self.env = dict(os.environ, CODEX_HOME=str(self.target), CLAUDE_CONFIG_DIR=str(self.source))
        self.env.pop("TALLY_HARNESS_TEST_BINARY", None)
        self.config = self.source / "settings.json"
        self.write(self.config, {"hooks": {}})
        self.options = ["--scope", "user", "--source-home", str(self.source), "--target-home", str(self.target),
                        "--skills-root", str(self.skills), "--state-root", str(self.state)]

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value) if not isinstance(value, str) else value)

    def run_cli(self, *args, input=None, code=0, env=None):
        result = subprocess.run([BIN, *map(str, args)], input=json.dumps(input) if isinstance(input, (dict, list)) else input,
                                capture_output=True, text=True, cwd=self.project, env=env or self.env, timeout=15)
        self.assertEqual(result.returncode, code, (args, result.stdout, result.stderr))
        return json.loads(result.stdout) if result.stdout else result.stderr

    def harness(self, action, code=0):
        return self.run_cli("harness", action, *self.options, code=code)

    def hook_source(self, output=None, *, command=None, matcher="", event="PreToolUse", **handler):
        if command is None:
            script = self.source / "hooks/gate.sh"
            script.parent.mkdir(exist_ok=True)
            script.write_text("cat >/dev/null\ncat <<'TALLY_JSON'\n" + json.dumps(output or {}) + "\nTALLY_JSON\n")
            command = "/bin/bash " + str(script)
        row = dict(type="command", command=command, **handler)
        self.write(self.config, {"hooks": {event: [{"matcher": matcher, "hooks": [row]}]}})

    def install(self):
        result = self.harness("install")
        self.manifest_path = Path(result["manifest"])
        self.manifest = json.loads(self.manifest_path.read_text())
        return result

    def event(self, tool="Bash", **input):
        return {"hook_event_name": "PreToolUse", "session_id": "session-A", "cwd": str(self.project),
                "tool_name": tool, "tool_input": input or {"command": "true"}}

    def bridge(self, event=None, code=0, index=0, env=None):
        return self.run_cli("codex-hook", "--manifest", self.manifest_path, "--entry", self.manifest["hooks"][index]["id"],
                            input=event or self.event(), code=code, env=env)

    def inbox(self, verb, *args, code=0, home=None, provider="codex", project=None):
        return self.run_cli("inbox", verb, "--provider", provider, "--home", home or self.target,
                            "--project", project or self.project, "--root", self.root / "inbox", *args, code=code)
