import json
import re

from fixture import Fixture


class ApprovalChecks(Fixture):
    def prepare(self):
        self.hook_source({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "review patch"}})
        self.install()
        return self.event("apply_patch", command="*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch\n")

    def request(self, event):
        result = self.bridge(event)
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        return re.search(r"Request: ([a-f0-9]{64})", result["hookSpecificOutput"]["permissionDecisionReason"]).group(1)

    def grant(self, request, code=0):
        return self.run_cli("harness", "grant", "--manifest", self.manifest_path, "--request", request,
                            "--authorization", "fixture-user-turn", code=code)

    def test_deny_grant_one_retry_then_replay_denied(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        self.assertEqual(self.bridge(event), "")
        self.assertEqual(self.request(event), request)

    def test_grant_requires_authorization_reference(self):
        event = self.prepare()
        request = self.request(event)
        self.run_cli("harness", "grant", "--manifest", self.manifest_path, "--request", request, code=2)

    def test_change_to_file_state_rejects_grant(self):
        event = self.prepare()
        request = self.request(event)
        (self.project / "config.json").write_text("changed")
        self.grant(request, code=2)

    def test_different_session_cannot_consume_grant(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        other = dict(event, session_id="session-B")
        self.assertNotEqual(self.request(other), request)
        self.assertEqual(self.bridge(event), "")

    def test_different_patch_cannot_consume_grant(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        other = dict(event, tool_input={"command": event["tool_input"]["command"].replace("+{}", "+{\"different\":true}")})
        self.assertNotEqual(self.request(other), request)
        self.assertEqual(self.bridge(event), "")

    def test_actual_codex_home_is_part_of_binding(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        second = self.root / "codex2"
        second.mkdir()
        result = self.bridge(event, env=dict(self.env, CODEX_HOME=str(second)))
        self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
        self.assertEqual(self.bridge(event), "")

    def test_expired_grant_denies_again(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        path = self.manifest_path.parent / "approvals" / self.manifest["generation"] / (request + ".json")
        value = json.loads(path.read_text())
        value["expires"] = 0
        self.write(path, value)
        self.assertEqual(self.request(event), request)

    def test_reinstall_does_not_reuse_old_grant(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        self.harness("remove")
        self.install()
        self.assertNotEqual(self.request(event), request)

    def test_changed_source_deny_cannot_be_overridden(self):
        event = self.prepare()
        request = self.request(event)
        self.grant(request)
        self.hook_source({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "hard deny"}})
        self.assertEqual(self.bridge(event)["hookSpecificOutput"]["permissionDecisionReason"], "hard deny")

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
