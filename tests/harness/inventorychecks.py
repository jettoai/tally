import json
import subprocess
from pathlib import Path

from fixture import Fixture


class InventoryChecks(Fixture):
    def test_plan_does_not_write_targets(self):
        self.hook_source()
        plan = self.harness("plan")
        self.assertEqual(len(plan["hooks"]), 1)
        self.assertFalse(self.state.exists())
        self.assertEqual(list(self.target.iterdir()), [])

    def test_unsupported_forms_are_reported(self):
        hooks = {
            "Notification": [{"hooks": [{"type": "command", "command": "true"}]}],
            "PreToolUse": [{"hooks": [{"type": "prompt", "prompt": "check"},
                                      {"type": "command", "command": "true", "async": True},
                                      {"type": "command", "command": "true", "timeout": True},
                                      {"type": "command", "command": "true", "timeout": "10"}]}],
            "Stop": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "true"}]}],
        }
        self.write(self.config, {"hooks": hooks})
        plan = self.harness("plan")
        self.assertEqual(len(plan["hooks"]), 6)
        self.assertTrue(all(row["disposition"] == "needs-adaptation" for row in plan["hooks"]))

    def test_invalid_settings_are_not_empty_success(self):
        for value in ("{bad", {"hooks": []}, {"hooks": {"Stop": [7]}}):
            with self.subTest(value=value):
                self.write(self.config, value)
                self.harness("plan", code=2)

    def test_skill_conflict_prevents_install(self):
        self.write(self.source / "skills/task/SKILL.md", "source")
        self.write(self.skills / "task/SKILL.md", "target")
        self.assertEqual(len(self.harness("plan")["conflicts"]), 1)
        self.harness("install", code=2)
        self.assertFalse((self.target / "hooks.json").exists())

    def test_install_remove_restores_original_bytes(self):
        self.hook_source()
        self.write(self.target / "hooks.json", '{ "theme": "user" }\n')
        self.write(self.target / "AGENTS.md", "User instructions\n")
        originals = {p: p.read_bytes() for p in (self.config, self.target / "hooks.json", self.target / "AGENTS.md")}
        self.write(self.source / "skills/task/SKILL.md", "task")
        self.install()
        self.assertEqual(self.harness("status")["state"], "installed")
        self.assertTrue((self.skills / "task").is_symlink())
        self.assertEqual(self.harness("install")["manifest"], str(self.manifest_path))
        self.harness("remove")
        for path, value in originals.items():
            self.assertEqual(path.read_bytes(), value)
        self.assertFalse((self.skills / "task").exists())
        self.assertFalse((self.skills / "tally-harness").exists())

    def test_remove_preserves_unrelated_post_install_changes(self):
        self.hook_source()
        self.install()
        path = self.target / "hooks.json"
        data = json.loads(path.read_text())
        data["hooks"]["PreToolUse"].append({"matcher": "Bash", "hooks": [{"type": "command", "command": "echo foreign"}]})
        data["theme"] = "new"
        self.write(path, data)
        instructions = self.target / "AGENTS.md"
        instructions.write_text("new before\n" + instructions.read_text() + "new after\n")
        self.harness("remove")
        remaining = json.loads(path.read_text())
        self.assertEqual(remaining["theme"], "new")
        self.assertEqual(remaining["hooks"]["PreToolUse"][-1]["hooks"][0]["command"], "echo foreign")
        self.assertEqual(instructions.read_text(), "new before\nnew after\n")

    def test_changed_owned_hook_blocks_removal_with_receipt(self):
        self.hook_source()
        self.install()
        path = self.target / "hooks.json"
        data = json.loads(path.read_text())
        data["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"] = 99
        self.write(path, data)
        self.harness("remove", code=2)
        self.assertTrue(self.manifest_path.exists())
        self.assertEqual(json.loads(path.read_text())["hooks"]["PreToolUse"][0]["hooks"][0]["timeout"], 99)

    def test_shared_native_config_is_installed_once(self):
        self.hook_source()
        self.install()
        sibling = self.root / "codex2"
        sibling.mkdir()
        (sibling / "hooks.json").symlink_to(self.target / "hooks.json")
        self.options[self.options.index("--target-home") + 1] = str(sibling)
        before = (self.target / "hooks.json").read_bytes()
        self.assertEqual(self.harness("install")["manifest"], str(self.manifest_path))
        self.assertEqual((sibling / "hooks.json").read_bytes(), before)
        self.assertTrue((sibling / "hooks.json").is_symlink())

    def test_shared_skills_remain_until_last_install_removed(self):
        self.write(self.source / "skills/task/SKILL.md", "shared task")
        self.install()
        first = list(self.options)
        sibling = self.root / "codex2"
        sibling.mkdir()
        self.options[self.options.index("--target-home") + 1] = str(sibling)
        self.install()
        self.run_cli("harness", "remove", *first)
        self.assertTrue((self.skills / "task/SKILL.md").exists())
        self.assertTrue((self.skills / "tally-harness/SKILL.md").exists())
        self.harness("remove")
        self.assertFalse((self.skills / "task").exists())
        self.assertFalse((self.skills / "tally-harness").exists())

    def test_preexisting_shared_link_is_not_adopted(self):
        self.write(self.source / "skills/task/SKILL.md", "task")
        self.skills.mkdir()
        (self.skills / "task").symlink_to(self.source / "skills/task")
        self.install()
        self.harness("remove")
        self.assertTrue((self.skills / "task").is_symlink())

    def test_identical_preexisting_product_skill_is_not_adopted(self):
        self.install()
        skill = self.skills / "tally-harness/SKILL.md"
        original = skill.read_text()
        self.harness("remove")
        self.write(skill, original)
        self.assertTrue(self.harness("plan")["conflicts"])
        self.harness("install", code=2)
        self.assertEqual(self.harness("remove")["state"], "not-installed")
        self.assertEqual(skill.read_text(), original)

    def test_installing_receipt_with_only_first_write_can_be_removed(self):
        self.hook_source()
        original = self.config.read_bytes()
        self.install()
        # Reconstruct an interruption immediately after the first journaled write.
        for row in self.manifest["files"][1:]:
            path = Path(row["path"])
            if row.get("backup"):
                path.write_bytes(Path(row["backup"]).read_bytes())
            else:
                path.unlink()
        self.manifest["phase"] = "installing"
        self.write(self.manifest_path, self.manifest)
        self.assertEqual(self.harness("status")["state"], "incomplete")
        self.harness("remove")
        self.assertEqual(self.config.read_bytes(), original)
        self.assertFalse((self.target / "hooks.json").exists())
        self.assertFalse((self.target / "AGENTS.md").exists())
        self.assertFalse(self.manifest_path.exists())

    def test_source_instruction_alias_stays_unchanged(self):
        self.write(self.source / "CLAUDE.md", "source policy")
        (self.target / "AGENTS.md").symlink_to(self.source / "CLAUDE.md")
        self.install()
        self.assertEqual((self.source / "CLAUDE.md").read_text(), "source policy")
        self.harness("remove")
        self.assertTrue((self.target / "AGENTS.md").is_symlink())

    def test_script_and_symlink_file_drift_is_observed(self):
        scripts = self.source / "scripts"
        scripts.mkdir()
        actual = self.root / "actual.sh"
        actual.write_text("before")
        (scripts / "gate.sh").symlink_to(actual)
        self.install()
        actual.write_text("after")
        self.assertIn(str(scripts / "gate.sh"), self.harness("status")["changes"])
        self.harness("install", code=2)

    def test_project_scope_requires_explicit_checkout(self):
        self.options[self.options.index("--scope") + 1] = "project"
        self.harness("plan", code=2)
        (self.project / ".claude").mkdir()
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        self.options += ["--project", str(self.project)]
        self.harness("install", code=2)
        self.run_cli("harness", "install", *self.options, "--confirm-git-visible")
        self.assertTrue((self.project / ".codex/hooks.json").exists())
        self.assertFalse((self.target / "hooks.json").exists())
        self.harness("remove")

    def test_malformed_manifest_does_not_crash_on_missing_project(self):
        self.install()
        self.manifest["location"]["scope"] = "project"
        self.write(self.manifest_path, self.manifest)
        self.harness("status", code=2)

    def test_repointed_hooks_link_retains_drift_and_removal_receipt(self):
        self.install()
        hooks = self.target / "hooks.json"
        saved = self.root / "saved-hooks.json"
        hooks.rename(saved)
        hooks.symlink_to(saved)
        self.assertEqual(self.harness("status")["state"], "drift")
        self.harness("remove", code=2)
        self.assertTrue(self.manifest_path.exists())
        hooks.unlink()
        saved.rename(hooks)
        self.harness("remove")
