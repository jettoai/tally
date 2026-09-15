import hashlib
import json
import time

from fixture import Fixture


class ApprovalChecks(Fixture):
    def prepare(self):
        self.hook_source({"hookSpecificOutput": {
            "hookEventName": "PreToolUse", "permissionDecision": "ask",
            "permissionDecisionReason": "sudo approve-mint fixture; CLAUDE_APPROVED=fixture",
            "additionalContext": "source approval context"}, "systemMessage": "source approval message"})
        self.install()
        return self.event("apply_patch", command="*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch\n")

    def assert_unsupported(self, event):
        result = self.bridge(event)
        specific = result["hookSpecificOutput"]
        self.assertEqual(specific["permissionDecision"], "deny")
        self.assertIn("does not support", specific["permissionDecisionReason"])
        self.assertNotIn("additionalContext", specific)
        self.assertNotIn("systemMessage", result)
        for instruction in ("sudo", "CLAUDE_APPROVED", "Request:", "source approval"):
            self.assertNotIn(instruction, json.dumps(result))

    def test_ask_blocks_commands_and_file_tools_without_relaying_approval_instructions(self):
        patch = self.prepare()
        events = [self.event(), patch,
                  self.event("Write", file_path=str(self.project / "config.json"), content="{}"),
                  self.event("Edit", file_path=str(self.project / "config.json"), old_string="a", new_string="b")]
        for event in events:
            with self.subTest(tool=event["tool_name"]):
                self.assert_unsupported(event)
        self.assertFalse((self.manifest_path.parent / "approvals").exists())

    def legacy_grant(self, event):
        # Reproduce the schema-1 binding emitted by the retired file-approval adapter.
        def digest(value):
            return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        entry = self.manifest["hooks"][0]
        path = str(self.project / "config.json")
        binding = {"session": event["session_id"], "cwd": str(self.project.resolve()),
                   "tool": event["tool_name"], "codexHome": str(self.target.resolve()),
                   "agentID": None, "agentType": None, "inputHash": digest(event["tool_input"]),
                   "files": [{"path": path, "resolved": path, "state": "missing"}],
                   "entry": entry["id"], "definitionHash": entry["definitionHash"],
                   "installation": self.manifest["location"]["identifier"], "generation": self.manifest["generation"]}
        record = self.manifest_path.parent / "approvals" / self.manifest["generation"] / (digest(binding) + ".json")
        self.write(record, {"schema": 1, "binding": binding, "state": "granted", "created": time.time(),
                            "expires": time.time() + 900, "authorizationReference": "fixture-user-turn"})
        return record

    def test_historical_grant_is_preserved_but_cannot_authorize_or_be_consumed(self):
        event = self.prepare()
        record = self.legacy_grant(event)
        before = record.read_bytes()
        self.assert_unsupported(event)
        self.assert_unsupported(event)
        self.assertEqual(record.read_bytes(), before)
        self.assertFalse((self.project / "config.json").exists())

    def test_removed_grant_command_cannot_change_historical_record(self):
        event = self.prepare()
        record = self.legacy_grant(event)
        before = record.read_bytes()
        self.run_cli("harness", "grant", code=2)
        self.run_cli("harness", "grant", "--manifest", self.manifest_path, "--request", record.stem,
                     "--authorization", "fixture-user-turn", code=2)
        self.assertEqual(record.read_bytes(), before)

    def test_hard_deny_remains_enforced_despite_historical_grant(self):
        event = self.prepare()
        self.legacy_grant(event)
        self.hook_source({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                                "permissionDecisionReason": "hard deny"}})
        self.assertEqual(self.bridge(event)["hookSpecificOutput"]["permissionDecisionReason"], "hard deny")

    def test_hard_deny_on_second_file_takes_priority_over_first_file_ask(self):
        script = self.source / "decision.py"
        self.write(script, 'import json,sys\nx=json.load(sys.stdin)\np=x["tool_input"]["file_path"]\n'
                   'decision="deny" if p.endswith("second.txt") else "ask"\n'
                   'print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse",'
                   '"permissionDecision":decision,"permissionDecisionReason":decision}}))\n')
        self.hook_source(command="python3 " + str(script), matcher="Write|Edit")
        self.install()
        patch = "*** Begin Patch\n*** Add File: first.txt\n+first\n*** Add File: second.txt\n+second\n*** End Patch\n"
        self.assertEqual(self.bridge(self.event("apply_patch", command=patch))["hookSpecificOutput"]["permissionDecisionReason"], "deny")
        self.assertFalse((self.manifest_path.parent / "approvals").exists())

    def test_multi_file_patch_checks_second_file(self):
        command = "python3 -c 'import json,sys; x=json.load(sys.stdin); p=x[\"tool_input\"][\"file_path\"]; print(json.dumps({\"decision\":\"block\",\"reason\":\"second\"}) if p.endswith(\"second.txt\") else \"{}\")'"
        self.hook_source(command=command, matcher="Write|Edit")
        self.install()
        patch = "*** Begin Patch\n*** Add File: first.txt\n+first\n*** Add File: second.txt\n+second\n*** End Patch\n"
        result = self.bridge(self.event("apply_patch", command=patch))
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_hunks_do_not_join_across_files(self):
        patch = "*** Begin Patch\n*** Update File: first.txt\n@@\n-old\n+new\n@@\n-older\n+newer\n*** Add File: second.txt\n+second\n*** End Patch\n"
        rows = self.run_cli("probe-patch", input=self.event("apply_patch", command=patch))
        self.assertEqual(len(rows), 3)
        self.assertEqual(rows[0]["tool_input"]["old_string"], "old\n")
        self.assertEqual(rows[1]["tool_input"]["old_string"], "older\n")
        self.assertEqual(rows[2]["tool_input"]["content"], "second\n")

    def test_delete_move_and_empty_file_have_path_events(self):
        patch = "*** Begin Patch\n*** Delete File: deleted.txt\n*** Update File: old.txt\n*** Move to: moved.txt\n@@\n-old\n+new\n*** Add File: empty.txt\n*** End Patch\n"
        rows = self.run_cli("probe-patch", input=self.event("apply_patch", command=patch))
        self.assertEqual(len(rows), 4)
        self.assertEqual(rows[0]["tally_patch_operation"], "delete")
        self.assertNotIn("content", rows[0]["tool_input"])
        self.assertEqual(rows[2]["tally_patch_operation"], "move-destination")
        self.assertTrue(rows[3]["tool_input"]["file_path"].endswith("empty.txt"))
        self.assertEqual(rows[3]["tool_input"]["content"], "")

    def test_move_without_text_changes_still_checks_edit_source(self):
        patch = "*** Begin Patch\n*** Update File: old.txt\n*** Move to: moved.txt\n*** End Patch\n"
        rows = self.run_cli("probe-patch", input=self.event("apply_patch", command=patch))
        self.assertEqual([row["tool_name"] for row in rows], ["Edit", "Write"])

    def test_patch_with_unrecognized_envelope_fails_closed(self):
        self.run_cli("probe-patch", input=self.event("apply_patch", command="*** Begin Patch\n*** Unknown: a\n*** End Patch\n"), code=2)
