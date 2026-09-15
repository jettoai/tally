import hashlib
import json
from pathlib import Path
import shlex

from fixture import Fixture


class DefaultChecks(Fixture):
    def prepare_candidates(self):
        self.write(self.config, {"hooks": {
            "PreToolUse": [{"hooks": [{"type": "command", "command": "true"},
                                       {"type": "command", "command": "false"}]}],
            "Stop": [{"hooks": [{"type": "prompt", "prompt": "unsupported"}]}]}})
        self.write(self.source / "skills/one/SKILL.md", "one")
        self.write(self.source / "skills/two/SKILL.md", "two")
        self.write(self.source / "CLAUDE.md", "Private source rules\n")

    def load_install(self, *selection):
        result = self.harness("install", *selection)
        self.manifest_path = Path(result["manifest"])
        self.manifest = json.loads(self.manifest_path.read_text())

    def test_default_selects_no_hooks_or_source_skills_and_preserves_foreign_files(self):
        self.prepare_candidates()
        self.write(self.target / "hooks.json", '{"theme": "foreign", "hooks": {}}\n')
        self.write(self.skills / "one/SKILL.md", "foreign one")
        self.write(self.target / "AGENTS.md", "Native target rules\n")
        sources = {p: p.read_bytes() for p in self.source.rglob("*") if p.is_file()}
        foreign_hooks = (self.target / "hooks.json").read_bytes()
        plan = self.harness("plan")
        self.assertEqual(len(plan["hooks"]), 3)
        self.assertEqual(len(plan["skillCandidates"]), 2)
        self.assertEqual(plan["conflicts"], [])
        for key in ("selectedHookIDs", "selectedSkillNames", "links"):
            self.assertEqual(plan[key], [])
        self.load_install()
        self.assertEqual(self.manifest["registrations"], [])
        self.assertEqual(self.harness("status")["nativeTrust"], "not-required")
        self.assertEqual(self.manifest["links"], [])
        self.assertEqual((self.target / "hooks.json").read_bytes(), foreign_hooks)
        self.assertFalse((self.skills / "two").exists())
        instructions = (self.target / "AGENTS.md").read_text()
        self.assertTrue(instructions.startswith("Native target rules\n"))
        self.assertIn("load relevant skills on demand", instructions)
        self.assertNotIn("Private source rules", instructions)
        self.assertEqual({p: p.read_bytes() for p in sources}, sources)
        before = self.manifest_path.read_bytes()
        self.harness("install")
        self.assertEqual(self.manifest_path.read_bytes(), before)
        self.harness("remove")
        self.assertEqual((self.target / "hooks.json").read_bytes(), foreign_hooks)
        self.assertEqual((self.skills / "one/SKILL.md").read_text(), "foreign one")
        self.assertEqual((self.target / "AGENTS.md").read_text(), "Native target rules\n")

    def test_empty_default_does_not_create_hooks_file(self):
        self.prepare_candidates()
        self.load_install()
        self.assertFalse((self.target / "hooks.json").exists())
        self.assertEqual(list(self.skills.iterdir()), [self.skills / "tally-harness"])

    def test_opt_in_only_registers_selected_hook_and_links_selected_skill(self):
        self.prepare_candidates()
        candidates = self.harness("plan")["hooks"]
        selected = candidates[0]["id"]
        selection = ("--hook", selected, "--skill", "two")
        plan = self.harness("plan", *selection)
        self.assertEqual(plan["selectedHookIDs"], [selected])
        self.assertEqual(plan["selectedSkillNames"], ["two"])
        self.assertEqual([Path(row["target"]).name for row in plan["links"]], ["two"])
        self.load_install(*selection)
        self.assertEqual(len(self.manifest["registrations"]), 1)
        self.assertEqual(set(json.loads((self.target / "hooks.json").read_text())["hooks"]), {"PreToolUse"})
        self.assertTrue((self.skills / "two").is_symlink())
        self.assertFalse((self.skills / "one").exists())
        self.bridge(index=0)
        self.bridge(index=1, code=2)
        before = self.manifest_path.read_bytes(), (self.target / "hooks.json").read_bytes()
        self.harness("install")
        self.harness("install", *selection)
        self.assertEqual((self.manifest_path.read_bytes(), (self.target / "hooks.json").read_bytes()), before)
        self.assertEqual(self.harness("plan")["selectedHookIDs"], [selected])
        self.harness("install", "--hook", candidates[1]["id"], code=2)
        self.assertEqual((self.manifest_path.read_bytes(), (self.target / "hooks.json").read_bytes()), before)
        self.harness("remove")
        self.assertFalse((self.skills / "two").exists())

    def test_repeatable_selections_and_unknown_items(self):
        self.prepare_candidates()
        hooks = self.harness("plan")["hooks"]
        for selection in [("--hook", "unknown"), ("--hook", hooks[2]["id"]),
                          ("--skill", "missing"), ("--skill", "../one"), ("--skill", "tally-harness")]:
            for verb in ("plan", "install"):
                with self.subTest(verb=verb, selection=selection):
                    self.harness(verb, *selection, code=2)
                    self.assertFalse(self.state.exists())
        self.load_install("--hook", hooks[0]["id"], "--hook", hooks[1]["id"],
                          "--skill", "one", "--skill", "two")
        self.assertEqual(len(self.manifest["registrations"]), 2)
        self.assertEqual(len(self.manifest["links"]), 2)
        self.harness("status", "--skill", "one", code=2)
        self.harness("remove", "--hook", hooks[0]["id"], code=2)

    def test_legacy_receipt_and_instruction_block_are_preserved_then_removed(self):
        self.hook_source()
        self.write(self.source / "skills/one/SKILL.md", "one")
        self.install()
        instructions = self.target / "AGENTS.md"
        original = instructions.read_text()
        old_block = ("\n<!-- tally-harness:begin -->\n"
                     "Tally connects this workspace to the user's Claude harness. Read the applicable\n"
                     f"source instructions at `{self.source / 'CLAUDE.md'}` when present, alongside existing Codex instructions.\n"
                     "Use the tally-harness skill for tool-specific adaptation, verification, and inbox handling.\n"
                     "Claude framework mechanisms are not Codex tool contracts. Current user authorization takes precedence.\n"
                     "<!-- tally-harness:end -->\n")
        instructions.write_text(old_block)
        old_hash = hashlib.sha256(original.encode()).hexdigest()
        new_hash = hashlib.sha256(old_block.encode()).hexdigest()
        for row in self.manifest["files"]:
            if row["kind"] == "instructions":
                row["afterHash"] = new_hash
        for key, value in self.manifest["observations"].items():
            self.manifest["observations"][key] = value.replace(old_hash, new_hash)
        # Legacy installs also registered a lifecycle hook independently of source hooks.
        hooks_path = self.target / "hooks.json"
        before_hooks = hooks_path.read_bytes()
        hooks = json.loads(before_hooks)
        command = ("TALLY_HARNESS_ENTRY=1 " + shlex.quote(self.manifest["executable"])
                   + " codex-hook --manifest " + shlex.quote(str(self.manifest_path)) + " --entry lifecycle")
        handler = {"type": "command", "command": command, "timeout": 15}
        hooks["hooks"]["SessionStart"] = [{"matcher": "", "hooks": [handler]}]
        self.write(hooks_path, hooks)
        definition = {"event": "SessionStart", "matcher": "", "handler": handler}
        definition_hash = hashlib.sha256(json.dumps(definition, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        self.manifest["registrations"].append({"provider": "codex", "path": str(hooks_path),
                                               "event": "SessionStart", "command": command,
                                               "definitionHash": definition_hash})
        old_hooks_hash = hashlib.sha256(before_hooks).hexdigest()
        new_hooks_hash = hashlib.sha256(hooks_path.read_bytes()).hexdigest()
        for row in self.manifest["files"]:
            if row["kind"] == "hooks":
                row["afterHash"] = new_hooks_hash
        for key, value in self.manifest["observations"].items():
            self.manifest["observations"][key] = value.replace(old_hooks_hash, new_hooks_hash)
        # Pre-selection schema-1 receipts have neither of these optional fields.
        del self.manifest["selectedHookIDs"]
        del self.manifest["selectedSkillNames"]
        self.write(self.manifest_path, self.manifest)
        before = self.manifest_path.read_bytes(), instructions.read_bytes(), hooks_path.read_bytes()
        self.harness("install")
        self.assertEqual((self.manifest_path.read_bytes(), instructions.read_bytes(), hooks_path.read_bytes()), before)
        self.assertEqual(self.harness("plan")["selectedHookIDs"], [self.manifest["hooks"][0]["id"]])
        instructions.write_text("User addition\n" + old_block)
        self.harness("remove")
        self.assertEqual(instructions.read_text(), "User addition\n")
        self.assertFalse((self.target / "hooks.json").exists())
        self.assertFalse((self.skills / "one").exists())
