import json
import re
from pathlib import Path
import shlex
import subprocess

from fixture import Fixture


class ReviewChecks(Fixture):
    def test_claude_integrations_are_reported_but_not_bridged_or_removed(self):
        verbs = ["agents", "knock", "artifact", "notify", "tally", "switch", "model"]
        commands = [f"{binary} hook-{verb} Stop" for verb in verbs for binary in
                    ["/usr/local/bin/tally", '"/Applications/Tally Dev.app/Contents/MacOS/tally"',
                     "'/Applications/Tally Dev.app/Contents/MacOS/tally'", "tally"]]
        foreign = ["/opt/bin/my-hook-agents Stop", "/opt/bin/not-tally hook-agents Stop",
                   "/usr/local/bin/tally hook-agents-helper", "echo tally hook-agents Stop",
                   "/usr/local/bin/tally status"]
        self.write(self.config, {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": command} for command in commands + foreign]}]}})
        original = self.config.read_bytes()
        rows = self.harness("plan")["hooks"]
        self.assertEqual(len(rows), len(commands) + len(foreign))
        self.assertTrue(all(row["disposition"] == "needs-adaptation" and "Claude-specific" in row["reason"]
                            for row in rows[:len(commands)]))
        self.assertTrue(all(row["disposition"] == "protocol-candidate" for row in rows[len(commands):]))
        self.install()
        native = [row for row in self.manifest["registrations"] if row["provider"] == "codex"
                  and row["event"] == "PreToolUse" and "--entry" in row["command"]]
        self.assertEqual(len(native), len(foreign))
        self.harness("remove")
        self.assertEqual(self.config.read_bytes(), original)

    def test_harness_settings_labels_have_four_translated_localizations(self):
        root = Path(__file__).resolve().parents[2]
        source = (root / "Tally/Views/SettingsCodexHarness.swift").read_text()
        keys = set(re.findall(r'L\("([^"\\]*)"\)', source))
        self.assertIn("Checking…", keys)
        catalog = json.loads((root / "Tally/Resources/Localizable.xcstrings").read_text())["strings"]
        for key in keys:
            for locale in ["zh-Hant", "zh-Hans", "ja", "ko"]:
                with self.subTest(key=key, locale=locale):
                    unit = catalog[key]["localizations"][locale]["stringUnit"]
                    self.assertEqual(unit["state"], "translated")
                    self.assertTrue(unit["value"])

    def test_catch_all_and_named_matchers_receive_their_patch_representations(self):
        patch = "*** Begin Patch\n*** Add File: first.txt\n+first\n*** Add File: second.txt\n+second\n*** End Patch\n"
        log = self.root / "events.jsonl"
        command = "python3 -c " + shlex.quote(
            "import json,sys; x=json.load(sys.stdin); "
            f"open({str(log)!r},'a').write(json.dumps(x)+'\\n')")
        for matcher, names in [("", ["apply_patch", "Write", "Write"]),
                               ("*", ["apply_patch", "Write", "Write"]),
                               ("Bash|Edit|Write", ["Write", "Write"]),
                               ("apply_patch", ["apply_patch"])]:
            with self.subTest(matcher=matcher):
                self.hook_source(command=command, matcher=matcher)
                self.install()
                self.bridge(self.event("apply_patch", command=patch))
                rows = [json.loads(line) for line in log.read_text().splitlines()]
                self.assertEqual([row["tool_name"] for row in rows], names)
                if names[0] == "apply_patch":
                    self.assertEqual(rows[0]["tool_input"]["command"], patch)
                self.harness("remove")
                log.unlink()

    def test_catch_all_raw_patch_deny_is_not_lost_to_file_projection(self):
        self.hook_source(command="python3 -c 'import json,sys; x=json.load(sys.stdin); "
                         "print(json.dumps({\"decision\":\"block\",\"reason\":\"raw patch\"}) "
                         "if x[\"tool_input\"].get(\"command\") else \"{}\")'")
        self.install()
        patch = "*** Begin Patch\n*** Add File: first.txt\n+first\n*** End Patch\n"
        self.assertEqual(self.bridge(self.event("apply_patch", command=patch))
                         ["hookSpecificOutput"]["permissionDecisionReason"], "raw patch")

    def test_source_receives_custom_environment_and_provider_namespace(self):
        self.hook_source(command='test "$CUSTOM_SOURCE_CONTEXT" = retained && test "$TALLY_HARNESS_PROVIDER" = codex')
        self.install()
        self.bridge(env=dict(self.env, CUSTOM_SOURCE_CONTEXT="retained"))

    def test_other_state_root_does_not_bridge_product_inbox_hooks(self):
        self.hook_source(matcher="Bash")
        self.run_cli("harness", "tools", "install", *self.options[2:])
        self.options[self.options.index("--state-root") + 1] = str(self.root / "state-B")
        self.options[self.options.index("--target-home") + 1] = str(self.root / "codex-B")
        self.options[self.options.index("--skills-root") + 1] = str(self.root / "skills-B")
        plan = self.harness("plan")
        owned = [row for row in plan["hooks"] if row["event"] in ("SessionStart", "Stop")]
        self.assertEqual(len(owned), 2)
        self.assertTrue(all(row["disposition"] == "needs-adaptation" and "Tally-managed" in row["reason"] for row in owned))
        self.install()
        self.assertFalse(any("--entry" in row["command"] and row["event"] == "Stop"
                             for row in self.manifest["registrations"]))

    def test_user_local_settings_file_is_explicitly_reported(self):
        self.write(self.source / "settings.local.json", {"hooks": {"Stop": []}})
        plan = self.harness("plan")
        self.assertTrue(any("settings.local.json" in notice for notice in plan["notices"]))

    def test_native_deadline_exceeds_source_deadline(self):
        self.hook_source(timeout=12.5)
        self.install()
        handler = json.loads((self.target / "hooks.json").read_text())["hooks"]["PreToolUse"][0]["hooks"][0]
        self.assertGreater(handler["timeout"], 12.5)

    def test_executable_mode_only_change_reports_drift(self):
        self.hook_source()
        script = self.source / "hooks/gate.sh"
        script.chmod(0o600)
        self.install()
        script.chmod(0o700)
        self.assertIn(str(script), self.harness("status")["changes"])

    def test_observation_byte_budget_does_not_accept_partial_inventory(self):
        self.install()
        scripts = self.source / "scripts"
        scripts.mkdir()
        for index in range(17):
            with (scripts / str(index)).open("wb") as file:
                file.truncate(4_000_000)
        self.assertIn("limit", self.harness("status", code=2))

    def project_scope(self):
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        (self.project / ".claude").mkdir()
        self.options[self.options.index("--scope") + 1] = "project"
        self.options += ["--project", str(self.project)]

    def test_project_git_paths_require_confirmation_and_include_skill_links(self):
        self.project_scope()
        self.write(self.project / ".claude/skills/task/SKILL.md", "task")
        plan = self.harness("plan")
        self.assertEqual({str(Path(path).relative_to(self.project)) for path in plan["projectGitVisible"]},
                         {".codex/hooks.json", "AGENTS.md", ".agents/skills/tally-harness/SKILL.md", ".agents/skills/task"})
        self.harness("install", code=2)
        self.assertFalse((self.project / ".codex").exists())
        self.run_cli("harness", "install", *self.options, "--confirm-git-visible")
        self.harness("remove")

    def test_ignored_project_paths_need_no_confirmation_but_tracked_files_do(self):
        self.project_scope()
        self.write(self.project / ".gitignore", ".codex/\n.agents/\nAGENTS.md\n")
        self.assertEqual(self.harness("plan")["projectGitVisible"], [])
        self.install()
        self.harness("remove")
        self.write(self.project / "AGENTS.md", "tracked")
        subprocess.run(["git", "-C", str(self.project), "add", "-f", "AGENTS.md"], check=True)
        self.assertEqual(self.harness("plan")["projectGitVisible"], [str(self.project / "AGENTS.md")])
        self.harness("install", code=2)

    def test_project_git_failure_does_not_report_an_empty_safe_plan(self):
        self.project_scope()
        (self.project / ".git/config").write_text("[broken")
        self.assertIn("git visibility", self.harness("plan", code=2))
