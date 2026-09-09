import fcntl
import json
from pathlib import Path

from fixture import Fixture


class ToolsChecks(Fixture):
    def configuration(self):
        return {"claudeHomes": [str(self.source)], "codexHomes": [str(self.target)],
                "skillsRoot": str(self.skills), "stateRoot": str(self.state)}

    def tools(self, verb, configuration=None, code=0):
        return self.run_cli("probe-tools", verb, input=configuration or self.configuration(), code=code)

    def test_one_install_makes_skill_available_to_both_without_adapting_policy(self):
        self.hook_source(command="echo source-policy")
        original = self.config.read_bytes()
        result = self.tools("install")
        self.assertEqual(result["state"], "installed")
        claude = self.source / "skills/tally-harness/SKILL.md"
        codex = self.skills / "tally-harness/SKILL.md"
        self.assertEqual(claude.read_text(), codex.read_text())
        self.assertIn("both Claude Code and Codex", claude.read_text())
        self.assertFalse((self.target / "AGENTS.md").exists())
        self.assertFalse((self.project / ".codex").exists())
        hooks = json.loads((self.target / "hooks.json").read_text())["hooks"]
        self.assertEqual(set(hooks), {"SessionStart", "Stop"})
        self.assertTrue(all("'inbox' 'hook'" in row["hooks"][0]["command"]
                            for groups in hooks.values() for row in groups))
        self.tools("remove")
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(claude.exists())
        self.assertFalse(codex.exists())
        self.assertFalse((self.target / "hooks.json").exists())

    def test_separate_account_homes_are_installed_together(self):
        config = self.configuration()
        second_claude, second_codex = self.root / "claude2", self.root / "codex2"
        config["claudeHomes"].append(str(second_claude))
        config["codexHomes"].append(str(second_codex))
        self.tools("install", config)
        self.assertTrue((second_claude / "skills/tally-harness/SKILL.md").exists())
        self.assertEqual(set(json.loads((second_codex / "hooks.json").read_text())["hooks"]), {"SessionStart", "Stop"})
        self.tools("remove", config)
        self.assertFalse((second_claude / "skills/tally-harness/SKILL.md").exists())
        self.assertFalse((second_codex / "hooks.json").exists())

    def test_shared_files_are_deduplicated_and_links_survive(self):
        config = self.configuration()
        second_claude, second_codex = self.root / "claude2", self.root / "codex2"
        second_claude.mkdir(); second_codex.mkdir()
        (second_claude / "settings.json").symlink_to(self.config)
        (second_claude / "skills").symlink_to(self.source / "skills")
        (second_codex / "hooks.json").symlink_to(self.target / "hooks.json")
        config["claudeHomes"].append(str(second_claude)); config["codexHomes"].append(str(second_codex))
        self.tools("install", config)
        receipt = json.loads((self.state / "tools/manifest.json").read_text())
        self.assertEqual(len(receipt["registrations"]), 4)
        self.assertEqual(len(receipt["files"]), 4)
        self.tools("remove", config)
        for path in [second_claude / "settings.json", second_claude / "skills", second_codex / "hooks.json"]:
            self.assertTrue(path.is_symlink())

    def test_foreign_skill_prevents_both_provider_writes(self):
        self.write(self.source / "skills/tally-harness/SKILL.md", "User-owned skill")
        original = self.config.read_bytes()
        self.tools("install", code=2)
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.skills / "tally-harness/SKILL.md").exists())
        self.assertFalse((self.target / "hooks.json").exists())

    def test_tools_then_adapter_can_be_removed_independently(self):
        self.hook_source()
        self.tools("install")
        self.assertEqual(len(self.harness("plan")["hooks"]), 1)
        self.install()
        self.tools("remove")
        self.assertTrue((self.skills / "tally-harness/SKILL.md").exists())
        self.assertFalse((self.source / "skills/tally-harness/SKILL.md").exists())
        self.bridge()
        self.harness("remove")
        self.assertFalse((self.skills / "tally-harness/SKILL.md").exists())

    def test_removed_source_abstains_but_changed_source_blocks_with_tools(self):
        self.hook_source()
        self.tools("install")
        self.install()
        source = json.loads(self.config.read_text())
        del source["hooks"]["PreToolUse"]
        self.write(self.config, source)
        self.assertIn("removed", json.dumps(self.bridge()))
        self.assertEqual(self.tools("status")["state"], "installed")
        source["hooks"]["PreToolUse"] = [{"hooks": [{"type": "command", "command": "echo changed"}]}]
        self.write(self.config, source)
        self.assertIn("definition changed", self.bridge(code=2))

    def test_adapter_then_tools_keep_shared_skill_until_both_removed(self):
        self.install()
        self.tools("install")
        self.harness("remove")
        self.assertTrue((self.skills / "tally-harness/SKILL.md").exists())
        self.assertEqual(self.tools("status")["state"], "installed")
        self.tools("remove")
        self.assertFalse((self.skills / "tally-harness/SKILL.md").exists())

    def test_unrelated_settings_survive_and_modified_owned_hook_retains_receipt(self):
        self.tools("install")
        path = self.target / "hooks.json"
        value = json.loads(path.read_text()); value["theme"] = "user"
        self.write(path, value)
        self.assertEqual(self.tools("status")["state"], "installed")
        value["hooks"]["Stop"][0]["hooks"][0]["timeout"] = 99
        self.write(path, value)
        self.tools("remove", code=2)
        self.assertTrue((self.state / "tools/manifest.json").exists())
        self.assertEqual(json.loads(path.read_text())["theme"], "user")

    def test_held_installation_lock_rejects_without_skill_writes(self):
        self.state.mkdir()
        with (self.state / ".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.tools("install", code=2)
        self.assertFalse((self.source / "skills/tally-harness/SKILL.md").exists())
        self.assertFalse((self.skills / "tally-harness/SKILL.md").exists())

    def test_public_tools_commands_install_and_remove_both_providers(self):
        options = self.options[2:]
        self.assertEqual(self.run_cli("harness", "tools", "install", *options)["state"], "installed")
        self.assertEqual(self.run_cli("harness", "tools", "remove", *options)["state"], "not-installed")

    def test_cli_status_uses_recorded_multi_home_configuration(self):
        config = self.configuration()
        config["claudeHomes"].append(str(self.root / "claude2"))
        config["codexHomes"].append(str(self.root / "codex2"))
        self.tools("install", config)
        status = self.run_cli("harness", "tools", "status", "--state-root", self.state)
        self.assertEqual(status["state"], "installed")
        self.assertEqual(set(status["codexHomes"]), set(config["codexHomes"]))

    def test_interrupted_tools_install_restores_original_files_on_remove(self):
        original = self.config.read_bytes()
        self.tools("install")
        path = self.state / "tools/manifest.json"
        receipt = json.loads(path.read_text())
        for row in receipt["files"][1:]:
            target = Path(row["path"])
            if row.get("backup"):
                target.write_bytes(Path(row["backup"]).read_bytes())
            else:
                target.unlink()
        receipt["phase"] = "installing"
        self.write(path, receipt)
        self.assertEqual(self.tools("status")["state"], "incomplete")
        self.tools("remove")
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse(path.exists())
        self.assertFalse((self.target / "hooks.json").exists())
        self.assertFalse((self.source / "skills/tally-harness/SKILL.md").exists())

    def test_modified_tools_skill_is_preserved_with_removal_receipt(self):
        self.tools("install")
        path = self.source / "skills/tally-harness/SKILL.md"
        original = path.read_text()
        path.write_text(original + "User changes\n")
        self.tools("remove", code=2)
        self.assertTrue(path.read_text().endswith("User changes\n"))
        self.assertTrue((self.state / "tools/manifest.json").exists())
        path.write_text(original)
        self.tools("remove")
        self.assertFalse(path.exists())
