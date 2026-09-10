import fcntl
import hashlib
import json
from pathlib import Path
import subprocess

from fixture import Fixture


class SkillUpdateChecks(Fixture):
    def tools(self, verb):
        return self.run_cli("probe-tools", verb, input={
            "claudeHomes": [str(self.source)], "codexHomes": [str(self.target)],
            "skillsRoot": str(self.skills), "stateRoot": str(self.state)})

    def refresh(self):
        return self.run_cli("probe-skill-update", self.state)

    def receipts(self):
        return {p: json.loads(p.read_text()) for p in self.state.glob("*/manifest.json")}

    def downgrade(self):
        # Exact product text from commit 57ce816, before launch-time updates shipped.
        old = (Path(__file__).parent / "fixtures/skill-57ce816.md").read_bytes()
        old_hash = hashlib.sha256(old).hexdigest()
        paths = set()
        for receipt_path, receipt in self.receipts().items():
            for row in receipt["files"]:
                if row["kind"] in ("tools-skill", "shared-skill"):
                    path = Path(row["path"])
                    self.current = path.read_bytes() if path not in paths else self.current
                    paths.add(path)
                    previous = row["afterHash"]
                    row["afterHash"] = old_hash
                    for key, value in receipt.get("observations", {}).items():
                        receipt["observations"][key] = value.replace(previous, old_hash)
            self.write(receipt_path, receipt)
        for path in paths:
            path.write_bytes(old)
        self.assertNotEqual(old, self.current)
        return paths

    def test_shared_user_and_project_owners_refresh_once_and_remove_cleanly(self):
        self.tools("install")
        self.install()
        user_options = list(self.options)
        other = self.root / "codex2"
        other.mkdir()
        second = list(self.options)
        second[second.index("--target-home") + 1] = str(other)
        self.run_cli("harness", "install", *second)
        project_options = list(self.options)
        project_options[1] = "project"
        project_options += ["--project", str(self.project), "--confirm-git-visible"]
        self.write(self.project / ".claude/settings.json", {"hooks": {}})
        subprocess.run(["git", "init", "-q", self.project], check=True)
        self.run_cli("harness", "install", *project_options)
        paths = self.downgrade()
        before = self.receipts()
        result = self.refresh()
        self.assertEqual(result["errors"], [])
        self.assertEqual(set(result["updated"]), set(map(str, paths)))
        self.assertEqual(len(result["updated"]), 3)
        new_hash = hashlib.sha256(self.current).hexdigest()
        for path, receipt in self.receipts().items():
            for index, row in enumerate(receipt["files"]):
                original = before[path]["files"][index]
                self.assertEqual(row.get("backup"), original.get("backup"))
                self.assertEqual(row.get("beforeHash"), original.get("beforeHash"))
                if row["kind"] in ("tools-skill", "shared-skill"):
                    self.assertEqual(row["afterHash"], new_hash)
                    self.assertEqual(Path(row["path"]).read_bytes(), self.current)
        self.assertEqual(self.harness("status")["state"], "installed")
        self.assertEqual(self.refresh(), {"updated": [], "errors": []})
        self.run_cli("harness", "remove", *second)
        self.run_cli("harness", "remove", *project_options[:-1])
        self.tools("remove")
        self.assertTrue((self.skills / "tally-harness/SKILL.md").exists())
        self.run_cli("harness", "remove", *user_options)
        self.assertTrue(all(not path.exists() for path in paths))

    def test_modified_missing_and_unowned_files_remain_untouched(self):
        self.tools("install")
        self.downgrade()
        modified = self.source / "skills/tally-harness/SKILL.md"
        modified.write_text(modified.read_text() + "User changes\n")
        missing = self.skills / "tally-harness/SKILL.md"
        missing.unlink()
        unowned = self.project / ".agents/skills/tally-harness/SKILL.md"
        self.write(unowned, "User-owned skill\n")
        before = modified.read_bytes(), unowned.read_bytes(), self.receipts()
        result = self.refresh()
        self.assertEqual(result["updated"], [])
        self.assertIn("Modified skill was preserved", "\n".join(result["errors"]))
        self.assertFalse(missing.exists())
        self.assertEqual((modified.read_bytes(), unowned.read_bytes(), self.receipts()), before)

    def test_source_hook_and_mode_drift_survive_skill_refresh(self):
        self.hook_source()
        self.tools("install")
        self.install()
        self.downgrade()
        hook = self.source / "hooks/gate.sh"
        hook.write_text("echo changed\n")
        skill = self.skills / "tally-harness/SKILL.md"
        skill.chmod(0o644)
        self.write(self.source / "CLAUDE.md", "Changed source rules\n")
        before = self.receipts()[self.manifest_path]["observations"]
        self.assertEqual(self.refresh()["errors"], [])
        after = self.receipts()[self.manifest_path]["observations"]
        self.assertEqual(after[str(hook)], before[str(hook)])
        self.assertEqual(after[str(self.source / "CLAUDE.md")], before[str(self.source / "CLAUDE.md")])
        changes = self.harness("status")["changes"]
        self.assertIn(str(hook), changes)
        self.assertIn(str(self.source / "CLAUDE.md"), changes)
        self.assertIn(str(skill), changes)
        self.assertNotIn(str(self.source / "skills/tally-harness/SKILL.md"), changes)

    def test_interrupted_file_write_repairs_all_receipts_and_observations(self):
        self.tools("install")
        self.install()
        paths = self.downgrade()
        for path in paths:
            path.write_bytes(self.current)
        result = self.refresh()
        self.assertEqual(result, {"updated": [], "errors": []})
        self.assertEqual(self.harness("status")["state"], "installed")
        self.tools("remove")
        self.harness("remove")
        self.assertTrue(all(not path.exists() for path in paths))

    def test_failed_receipt_write_can_retry_without_losing_the_old_hash(self):
        self.tools("install")
        self.install()
        paths = self.downgrade()
        # A directory can be read while refusing the temporary file for atomic rename.
        folder = self.manifest_path.parent
        folder.chmod(0o500)
        try:
            result = self.refresh()
            self.assertTrue(result["errors"])
            self.assertTrue(any(path.read_bytes() == self.current for path in paths))
        finally:
            folder.chmod(0o700)
        self.assertEqual(self.refresh()["errors"], [])
        self.assertEqual(self.harness("status")["state"], "installed")
        self.tools("remove")
        self.harness("remove")

    def test_symlink_and_unreadable_skill_preserved_while_independent_skill_updates(self):
        for shape in ("symlink", "unreadable", "parent-link"):
            with self.subTest(shape=shape):
                self.tools("install")
                self.downgrade()
                path = self.source / "skills/tally-harness/SKILL.md"
                original = path.read_bytes()
                moved = self.root / "saved"
                if shape == "symlink":
                    path.rename(moved)
                    path.symlink_to(moved)
                elif shape == "parent-link":
                    path.parent.rename(moved)
                    path.parent.symlink_to(moved, target_is_directory=True)
                else:
                    path.chmod(0)
                result = self.refresh()
                self.assertTrue(result["errors"])
                self.assertEqual(result["updated"], [str(self.skills / "tally-harness/SKILL.md")])
                if shape == "symlink":
                    self.assertTrue(path.is_symlink())
                    path.unlink()
                    moved.rename(path)
                elif shape == "parent-link":
                    self.assertTrue(path.parent.is_symlink())
                    path.parent.unlink()
                    moved.rename(path.parent)
                else:
                    path.chmod(0o600)
                self.assertEqual(path.read_bytes(), original)
                self.refresh()
                self.tools("remove")

    def test_held_lock_and_uninstalled_state_write_no_skills(self):
        self.assertEqual(self.refresh(), {"updated": [], "errors": []})
        self.assertFalse(self.state.exists())
        self.tools("install")
        paths = self.downgrade()
        before = {path: path.read_bytes() for path in paths}
        with (self.state / ".lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assertIn("Another Tally operation", "\n".join(self.refresh()["errors"]))
        self.assertEqual({path: path.read_bytes() for path in paths}, before)

    def test_partial_owner_receipt_save_repairs_remaining_owners(self):
        self.tools("install")
        self.install()
        self.downgrade()
        old_adapter = self.manifest_path.read_bytes()
        self.assertEqual(self.refresh()["errors"], [])
        # File and tools receipt survived a crash, while the adapter receipt did not.
        self.manifest_path.write_bytes(old_adapter)
        self.assertEqual(self.refresh(), {"updated": [], "errors": []})
        self.assertEqual(self.harness("status")["state"], "installed")
        self.tools("remove")
        self.harness("remove")

    def test_incomplete_owner_blocks_only_its_shared_skill(self):
        self.tools("install")
        self.install()
        self.downgrade()
        receipt = json.loads(self.manifest_path.read_text())
        receipt["phase"] = "removing"
        self.write(self.manifest_path, receipt)
        skill = self.skills / "tally-harness/SKILL.md"
        before = skill.read_bytes()
        result = self.refresh()
        self.assertIn("incomplete installation", "\n".join(result["errors"]))
        self.assertEqual(result["updated"], [str(self.source / "skills/tally-harness/SKILL.md")])
        self.assertEqual(skill.read_bytes(), before)
