import json
from pathlib import Path

from fixture import Fixture


class MigrationChecks(Fixture):
    def prepare(self):
        self.write(self.config, {"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [
            {"type": "command", "command": "true"},
            {"type": "command", "command": "printf '%s' '{\"hookSpecificOutput\":{\"permissionDecision\":\"deny\",\"permissionDecisionReason\":\"retained guard\"}}'"}]}]}})
        for name in ("one", "two"):
            self.write(self.source / f"skills/{name}/SKILL.md", name)
        self.install()
        self.drop = self.manifest["hooks"][0]["id"]
        self.keep = self.manifest["hooks"][1]["id"]
        self.hooks_path = self.target / "hooks.json"

    def snapshot(self):
        return {str(p): ("link", str(p.readlink())) if p.is_symlink() else ("file", p.read_bytes())
                for root in (self.source, self.target, self.skills, self.state) if root.exists()
                for p in root.rglob("*") if p.is_file() or p.is_symlink()}

    def reload_manifest(self):
        self.manifest = json.loads(self.manifest_path.read_text())

    def test_inventory_and_preview_are_read_only_and_apply_requires_selection(self):
        self.prepare()
        before = self.snapshot()
        inventory = self.harness("migrate")
        self.assertEqual(inventory["state"], "unchanged")
        self.assertEqual([row["definitionMatches"] for row in inventory["hooks"]], [1, 1])
        preview = self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one")
        self.assertEqual(preview["state"], "planned")
        self.assertEqual(preview["retainedHookIDs"], [self.keep])
        self.assertEqual(set(preview["changedPaths"]), {str(self.hooks_path), str(self.skills / "one")})
        self.harness("migrate", "--apply", code=2)
        self.assertEqual(self.snapshot(), before)

    def test_selective_retirement_preserves_guard_foreign_entries_and_removal_backup(self):
        self.prepare()
        hooks = json.loads(self.hooks_path.read_text())
        retained = hooks["hooks"]["PreToolUse"][1]
        hooks["foreign"] = "keep"
        hooks["hooks"]["PreToolUse"].append({"hooks": [{"type": "command", "command": "echo foreign"}]})
        self.write(self.hooks_path, hooks)
        before = self.hooks_path.read_bytes()
        result = self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one", "--apply")
        self.assertEqual(result["state"], "migrated")
        self.assertEqual((Path(result["backup"]) / "file-0").read_bytes(), before)
        after = json.loads(self.hooks_path.read_text())
        self.assertEqual(after["foreign"], "keep")
        self.assertEqual(after["hooks"]["PreToolUse"][0]["hooks"], [])
        self.assertEqual(after["hooks"]["PreToolUse"][1], retained)
        self.assertEqual(after["hooks"]["PreToolUse"][2], hooks["hooks"]["PreToolUse"][2])
        self.assertFalse((self.skills / "one").exists())
        self.assertTrue((self.skills / "two").is_symlink())
        self.reload_manifest()
        self.assertEqual(self.manifest["selectedHookIDs"], [self.keep])
        self.assertEqual(self.bridge(index=1)["hookSpecificOutput"]["permissionDecisionReason"], "retained guard")
        self.bridge(index=0, code=2)
        before_repeat = self.snapshot()
        self.assertEqual(self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one", "--apply")["state"], "unchanged")
        self.assertEqual(self.snapshot(), before_repeat)
        self.harness("remove")
        remaining = json.loads(self.hooks_path.read_text())
        self.assertEqual(remaining["foreign"], "keep")
        self.assertEqual(remaining["hooks"]["PreToolUse"][2], hooks["hooks"]["PreToolUse"][2])

    def test_owned_changes_refresh_only_affected_observations(self):
        self.prepare()
        self.write(self.source / "CLAUDE.md", "unrelated drift")
        before = self.harness("status")["changes"]
        result = self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one", "--apply")
        self.assertEqual(result["remainingDrift"], before)
        self.harness("remove")
        self.assertFalse(self.hooks_path.exists())

    def test_modified_selected_hook_or_skill_prevents_all_target_writes(self):
        for conflict in ("hook", "skill"):
            with self.subTest(conflict=conflict):
                if not hasattr(self, "manifest_path"):
                    self.prepare()
                hooks = json.loads(self.hooks_path.read_text())
                if conflict == "hook":
                    hooks["hooks"]["PreToolUse"][0]["matcher"] = "Write"
                    self.write(self.hooks_path, hooks)
                else:
                    hooks["hooks"]["PreToolUse"][0]["matcher"] = "Bash"
                    self.write(self.hooks_path, hooks)
                    (self.skills / "one").unlink()
                    self.write(self.skills / "one/SKILL.md", "foreign")
                before = self.snapshot()
                self.assertEqual(self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one")["state"], "conflict")
                self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one", "--apply", code=2)
                self.assertEqual(self.snapshot(), before)

    def test_missing_entries_are_retired_without_resurrecting_them_or_clearing_drift(self):
        self.prepare()
        hooks = json.loads(self.hooks_path.read_text())
        hooks["hooks"]["PreToolUse"][0]["hooks"] = []
        self.write(self.hooks_path, hooks)
        (self.skills / "one").unlink()
        # Legacy receipt fields are absent, not an explicit empty selection.
        del self.manifest["selectedHookIDs"]
        del self.manifest["selectedSkillNames"]
        self.write(self.manifest_path, self.manifest)
        self.assertEqual(self.harness("status")["selectionPolicy"], "legacy")
        before_hooks = self.hooks_path.read_bytes()
        before_drift = self.harness("status")["changes"]
        result = self.harness("migrate", "--drop-hook", self.drop, "--drop-skill", "one", "--apply")
        self.assertEqual(result["changedPaths"], [])
        self.assertTrue(result["receiptWillChange"])
        self.assertEqual(self.hooks_path.read_bytes(), before_hooks)
        self.assertEqual(result["remainingDrift"], before_drift)
        self.assertEqual(self.harness("status")["selectionPolicy"], "explicit")
        self.assertEqual(self.harness("plan")["selectedHookIDs"], [self.keep])

    def test_invalid_selectors_and_wrong_verb_flags_are_rejected(self):
        self.prepare()
        before = self.snapshot()
        for args in (("migrate", "--drop-hook", "unknown"), ("migrate", "--drop-skill", "../one"),
                     ("migrate", "--hook", self.drop), ("status", "--apply"),
                     ("install", "--drop-hook", self.drop)):
            self.harness(*args, code=2)
        self.assertEqual(self.snapshot(), before)

    def test_shared_skill_link_is_retained_for_other_owner(self):
        self.prepare()
        second = self.root / "codex-second"
        second.mkdir()
        options = list(self.options)
        options[options.index("--target-home") + 1] = str(second)
        self.run_cli("harness", "install", *options, "--skill", "one")
        result = self.harness("migrate", "--drop-skill", "one", "--apply")
        self.assertEqual(result["changedPaths"], [])
        self.assertTrue((self.skills / "one").is_symlink())
        self.run_cli("harness", "remove", *options)
        self.assertFalse((self.skills / "one").exists())

    def test_project_requires_reviewed_git_visible_paths(self):
        self.run_cli("harness", "migrate", *self.options, code=2)
        import subprocess
        subprocess.run(["git", "init", "-q", str(self.project)], check=True)
        self.source = self.project / ".claude"
        self.target = self.project / ".codex"
        self.skills = self.project / ".agents/skills"
        self.source.mkdir()
        self.target.mkdir()
        self.config = self.source / "settings.json"
        self.options += ["--project", str(self.project)]
        self.options[self.options.index("--scope") + 1] = "project"
        self.options += ["--confirm-git-visible"]
        # The fixture adds install-only flags to every command, so install manually.
        self.write(self.config, {"hooks": {"PreToolUse": [{"hooks": [{"type": "command", "command": "true"}]}]}})
        plan_options = self.options[:-1]
        hook = self.run_cli("harness", "plan", *plan_options)["hooks"][0]["id"]
        result = self.run_cli("harness", "install", *self.options, "--hook", hook)
        self.manifest_path = Path(result["manifest"])
        self.options = plan_options
        before = self.snapshot()
        preview = self.harness("migrate", "--drop-hook", hook)
        self.assertEqual(preview["projectGitVisible"], [str(self.target / "hooks.json")])
        self.harness("migrate", "--drop-hook", hook, "--apply", code=2)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(self.harness("migrate", "--drop-hook", hook, "--apply", "--confirm-git-visible")["state"], "migrated")

    def test_repointed_hooks_file_is_not_followed(self):
        self.prepare()
        original = self.hooks_path.read_bytes()
        other = self.root / "foreign-hooks.json"
        other.write_bytes(original)
        self.hooks_path.unlink()
        self.hooks_path.symlink_to(other)
        before = self.snapshot()
        self.harness("migrate", "--drop-hook", self.drop, "--apply", code=2)
        self.assertEqual(self.snapshot(), before)
        self.assertEqual(other.read_bytes(), original)

    def test_repointed_skill_parent_is_preserved(self):
        self.prepare()
        moved = self.root / "moved-skills"
        self.skills.rename(moved)
        self.skills.symlink_to(moved, target_is_directory=True)
        before = self.snapshot()
        self.harness("migrate", "--drop-skill", "one", code=2)
        self.harness("migrate", "--drop-skill", "one", "--apply", code=2)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue((moved / "one").is_symlink())
