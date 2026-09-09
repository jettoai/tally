import hashlib
import json
import subprocess

from fixture import BIN, Fixture


class InboxChecks(Fixture):
    def post(self, **kwargs):
        path = self.root / "body.txt"
        path.write_text("External instruction, unverified.")
        return self.inbox("post", "--file", path, **kwargs)["id"]

    def claim(self, id):
        return self.inbox("claim", "--id", id, "--owner", "session-A")["claim"]["nonce"]

    def test_post_is_pending_and_metadata_does_not_leak_body(self):
        id = self.post()
        listing = self.inbox("list")
        self.assertEqual(listing[0]["state"], "pending")
        self.assertNotIn("External instruction", json.dumps(listing))
        self.assertFalse(self.inbox("status", "--id", id)["acknowledged"])

    def test_claim_read_ack_requires_nonce_and_owner(self):
        id = self.post()
        nonce = self.claim(id)
        self.inbox("read", "--id", id, "--owner", "session-A", "--nonce", "wrong", code=2)
        self.inbox("read", "--id", id, "--owner", "session-B", "--nonce", nonce, code=2)
        value = self.inbox("read", "--id", id, "--owner", "session-A", "--nonce", nonce)
        self.assertEqual(value["trust"], "external-unverified")
        self.assertEqual(value["body"], "External instruction, unverified.")
        self.inbox("ack", "--id", id, "--owner", "session-A", "--nonce", nonce)
        self.assertEqual(self.inbox("list"), [])
        self.assertTrue(self.inbox("status", "--id", id)["acknowledged"])

    def test_concurrent_claim_has_exactly_one_owner(self):
        id = self.post()
        base = [BIN, "inbox", "claim", "--provider", "codex", "--home", str(self.target),
                "--project", str(self.project), "--root", str(self.root / "inbox"), "--id", id, "--owner"]
        a = subprocess.Popen(base + ["A"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        b = subprocess.Popen(base + ["B"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=self.env)
        a.communicate(timeout=5)
        b.communicate(timeout=5)
        self.assertEqual(sorted([a.returncode, b.returncode]), [0, 2])

    def test_release_returns_to_pending(self):
        id = self.post()
        nonce = self.claim(id)
        self.inbox("release", "--id", id, "--owner", "session-A", "--nonce", nonce)
        self.assertEqual(self.inbox("list")[0]["state"], "pending")
        self.assertNotEqual(self.claim(id), nonce)

    def test_recovery_requires_confirmation_and_exact_previous_owner(self):
        id = self.post()
        nonce = self.claim(id)
        args = ["--id", id, "--owner", "session-B", "--previous-owner", "session-A", "--reason", "previous session ended"]
        self.inbox("recover", *args, code=2)
        new = self.inbox("recover", *args, "--confirm-abandoned")
        self.assertNotEqual(new["claim"]["nonce"], nonce)
        self.inbox("read", "--id", id, "--owner", "session-A", "--nonce", nonce, code=2)

    def test_provider_project_and_home_boundaries(self):
        self.post()
        self.assertEqual(self.inbox("list", provider="claude"), [])
        second = self.root / "second"
        second.mkdir()
        self.assertEqual(self.inbox("list", project=second), [])
        self.assertEqual(self.inbox("list", home=second), [])
        self.assertEqual(len(self.inbox("list", "--all-homes", home=second)), 1)

    def test_git_subdirectory_resolves_same_checkout(self):
        subprocess.run(["git", "init", "-q", self.project], check=True)
        self.post()
        nested = self.project / "nested"
        nested.mkdir()
        self.assertEqual(len(self.inbox("list", project=nested)), 1)

    def test_non_ascii_identity_matches_python_v1(self):
        home = self.root / "帳號😀"
        home.mkdir()
        self.post(home=home)
        address = {"provider": "codex", "home": str(home), "project": str(self.project)}
        key = hashlib.sha256(json.dumps(address, sort_keys=True).encode()).hexdigest()
        self.assertTrue((self.root / "inbox/codex" / key / ".address").exists())

    def test_session_start_metadata_and_stop_reentry(self):
        self.post()
        args = ["inbox", "hook", "--provider", "codex", "--fallback-home", self.target, "--root", self.root / "inbox"]
        event = {"hook_event_name": "SessionStart", "cwd": str(self.project), "session_id": "A"}
        result = self.run_cli(*args, input=event)
        self.assertIn("external-unverified", result["hookSpecificOutput"]["additionalContext"])
        self.assertNotIn("External instruction", json.dumps(result))
        event["hook_event_name"] = "Stop"
        self.assertEqual(self.run_cli(*args, input=event)["decision"], "block")
        event["stop_hook_active"] = True
        self.assertEqual(self.run_cli(*args, input=event), "")

    def test_stop_does_not_interrupt_another_claim_owner(self):
        self.claim(self.post())
        args = ["inbox", "hook", "--provider", "codex", "--root", self.root / "inbox"]
        event = {"hook_event_name": "Stop", "cwd": str(self.project), "session_id": "session-B"}
        self.assertEqual(self.run_cli(*args, input=event), "")
        event["session_id"] = "session-A"
        self.assertEqual(self.run_cli(*args, input=event)["decision"], "block")

    def test_unreadable_message_is_reported_at_start(self):
        id = self.post()
        file = next((self.root / "inbox").rglob(id + ".json"))
        file.write_text("bad-json")
        self.assertEqual(self.inbox("list")[0]["state"], "unreadable")
        self.inbox("status", "--id", id, code=2)

    def test_invalid_message_uuid_cannot_escape_mailbox(self):
        self.inbox("status", "--id", "../../outside", code=2)

    def test_symlink_message_is_not_read(self):
        id = self.post()
        file = next((self.root / "inbox").rglob(id + ".json"))
        other = self.root / "outside.json"
        file.rename(other)
        file.symlink_to(other)
        self.inbox("status", "--id", id, code=2)
