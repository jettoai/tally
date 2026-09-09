import json

from fixture import Fixture


class BridgeChecks(Fixture):
    def test_canonical_bash_payload_reaches_source(self):
        self.hook_source(command="python3 -c 'import json,sys; x=json.load(sys.stdin); assert x[\"tool_name\"] == \"Bash\"'", matcher="Bash")
        self.install()
        self.bridge(self.event(command="printf ok"))

    def test_deny_and_continue_false_block(self):
        for output in ({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "no"}},
                       {"continue": False, "stopReason": "stop"}):
            with self.subTest(output=output):
                self.hook_source(output)
                self.install()
                result = self.bridge()
                self.assertEqual(result["hookSpecificOutput"]["permissionDecision"], "deny")
                self.harness("remove")

    def test_allow_is_abstention_not_global_approval(self):
        self.hook_source({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}})
        self.install()
        self.assertEqual(self.bridge(), "")

    def test_updated_bash_input_survives(self):
        self.hook_source({"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "updatedInput": {"command": "printf safe"}}})
        self.install()
        result = self.bridge()
        self.assertEqual(result["hookSpecificOutput"]["updatedInput"], {"command": "printf safe"})

    def test_nonzero_source_exit_fails_closed(self):
        self.hook_source(command="echo failure >&2; exit 7")
        self.install()
        self.assertIn("exit 7", self.bridge(code=2))

    def test_exit_two_without_stderr_gets_reason(self):
        self.hook_source(command="exit 2")
        self.install()
        self.assertIn("blocked", self.bridge(code=2))

    def test_malformed_output_fails_closed(self):
        self.hook_source(command="printf 'bad-json'")
        self.install()
        self.bridge(code=2)

    def test_malformed_decision_fields_do_not_silently_abstain(self):
        self.hook_source()
        self.install()
        for output in [{"continue": "false"}, {"continue": 0}, {"decision": 7},
                       {"hookSpecificOutput": {"hookEventName": 5}}]:
            with self.subTest(output=output):
                self.hook_source(output)
                self.bridge(code=2)

    def test_optional_null_fields_are_ignored(self):
        self.hook_source({"decision": None, "continue": None, "hookSpecificOutput": None})
        self.install()
        self.assertEqual(self.bridge(), "")

    def test_stop_continue_false_takes_precedence_over_block(self):
        self.hook_source({"decision": "block", "continue": False, "stopReason": "end"}, event="Stop")
        self.install()
        result = self.bridge({"hook_event_name": "Stop", "cwd": str(self.project)})
        self.assertFalse(result["continue"])
        self.assertNotIn("decision", result)

    def test_wrong_event_identity_fails_closed(self):
        self.hook_source()
        self.install()
        event = self.event()
        event["hook_event_name"] = "Stop"
        self.bridge(event, code=2)

    def test_reordered_definition_still_runs(self):
        self.hook_source({"decision": "block", "reason": "kept"})
        self.install()
        data = json.loads(self.config.read_text())
        data["hooks"]["PreToolUse"].insert(0, {"hooks": [{"type": "command", "command": "true"}]})
        self.write(self.config, data)
        self.assertEqual(self.bridge()["hookSpecificOutput"]["permissionDecision"], "deny")

    def test_removed_source_abstains_but_changed_definition_blocks(self):
        self.hook_source()
        self.install()
        self.write(self.config, {"hooks": {}})
        self.assertIn("removed", json.dumps(self.bridge()))
        self.hook_source(command="echo changed")
        self.assertIn("definition changed", self.bridge(code=2))

    def test_changed_script_body_runs_and_status_reports_drift(self):
        self.hook_source()
        self.install()
        script = self.source / "hooks/gate.sh"
        script.write_text("echo changed >&2; exit 2\n")
        self.assertIn("changed", self.bridge(code=2))
        self.assertIn(str(script), self.harness("status")["changes"])

    def test_process_timeout_is_bounded(self):
        result = self.run_cli("probe-process", "sleep 20", "0.08")
        self.assertTrue(result["failure"])

    def test_concurrent_large_input_and_output_does_not_deadlock(self):
        command = "python3 -c 'import sys; sys.stdout.write(\"o\"*180000); sys.stdout.flush(); print(len(sys.stdin.read()))'"
        result = self.run_cli("probe-process", command, "3", input="i" * 180000)
        self.assertEqual(result["failure"], "")
        self.assertTrue(result["stdout"].endswith("180000\n"))

    def test_output_limit_fails_closed(self):
        result = self.run_cli("probe-process", "yes x", "3")
        self.assertTrue(result["failure"])

    def test_descendant_holding_stdout_is_bounded(self):
        result = self.run_cli("probe-process", "sleep 20 & exit 0", "3")
        self.assertTrue(result["failure"])

    def test_stop_reentry_does_not_run_source(self):
        marker = self.project / "ran"
        self.hook_source(command="touch " + str(marker), event="Stop")
        self.install()
        event = {"hook_event_name": "Stop", "cwd": str(self.project), "stop_hook_active": True}
        self.assertEqual(self.bridge(event), "")
        self.assertFalse(marker.exists())

    def test_shared_home_environment_is_not_overwritten(self):
        second = self.root / "codex2"
        second.mkdir()
        self.hook_source(command="test \"$CODEX_HOME\" = '" + str(second) + "' || exit 2")
        self.install()
        self.bridge(env=dict(self.env, CODEX_HOME=str(second)))

    def test_codex_transcript_does_not_reach_claude_parser(self):
        self.hook_source(command="python3 -c 'import json,sys; x=json.load(sys.stdin); assert x[\"transcript_path\"] == \"\"; assert x[\"tally_codex_transcript_path\"] == \"native.jsonl\"'")
        self.install()
        event = self.event()
        event["transcript_path"] = "native.jsonl"
        self.bridge(event)
