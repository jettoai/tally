import hashlib
import json
from pathlib import Path
import subprocess

from fixture import Fixture


class RoutingPreservationChecks(Fixture):
    """The adapter must leave Codex-native model routing under user ownership."""

    def native_routing(self, home, *, shared=None):
        owner = shared or home
        config = owner / "config.toml"
        agents = owner / "agents"
        self.write(config, 'model = "model-alpha"\nmodel_reasoning_effort = "medium"\n')
        self.write(agents / "coordinator.toml", self.agent("coordinator", "model-coordinator", "high"))
        self.write(agents / "review.toml", self.agent("review", "model-review", "low"))
        if shared:
            (home / "config.toml").symlink_to(config)
            (home / "agents").symlink_to(agents, target_is_directory=True)
        return home / "config.toml", home / "agents"

    @staticmethod
    def agent(name, model, effort):
        return ('name = "' + name + '"\n'
                + 'description = "A fixture ' + name + ' role."\n'
                + 'developer_instructions = "Follow the fixture routing policy."\n'
                + 'model = "' + model + '"\n'
                + 'model_reasoning_effort = "' + effort + '"\n')

    @staticmethod
    def link_target(path):
        return str(path.readlink()) if path.is_symlink() else None

    def native_snapshot(self, config, agents):
        return {"configPath": config, "configExists": config.exists(), "configLink": self.link_target(config),
                "configBytes": config.read_bytes() if config.exists() else None,
                "agentsPath": agents, "agentsExists": agents.exists(), "agentsLink": self.link_target(agents),
                "agentFiles": {path.relative_to(agents): path.read_bytes()
                               for path in sorted(agents.rglob("*")) if path.is_file()}}

    def assert_native_untouched(self, expected, *, status=None):
        self.assertEqual(self.native_snapshot(expected["configPath"], expected["agentsPath"]), expected)
        if status:
            self.assertEqual(status["state"], "installed")
            paths = [expected["configPath"], expected["agentsPath"]] + [expected["agentsPath"] / path
                for path in expected["agentFiles"]]
            self.assertTrue(all(str(path) not in status["changes"] for path in paths))

    def assert_native_absent(self, config, agents, *, status=None):
        self.assertFalse(config.exists())
        self.assertFalse(config.is_symlink())
        self.assertFalse(agents.exists())
        self.assertFalse(agents.is_symlink())
        if status:
            self.assertEqual(status["state"], "installed")
            self.assertNotIn(str(config), status["changes"])
            self.assertNotIn(str(agents), status["changes"])

    def refresh_product_skill(self, manifest_path, skill):
        """Simulate the previous bundled skill so refresh has a real write to make."""
        current = skill.read_bytes()
        stale = b"---\nname: tally-harness\ndescription: previous product skill\n---\n"
        self.assertNotEqual(stale, current)
        current_hash, stale_hash = hashlib.sha256(current).hexdigest(), hashlib.sha256(stale).hexdigest()
        manifest = json.loads(manifest_path.read_text())
        owned = [row for row in manifest["files"] if row["kind"] == "shared-skill"]
        self.assertEqual([row["path"] for row in owned], [str(skill)])
        for row in owned:
            self.assertEqual(row["afterHash"], current_hash)
            row["afterHash"] = stale_hash
        self.assertTrue(any(current_hash in value for value in manifest["observations"].values()))
        manifest["observations"] = {path: value.replace(current_hash, stale_hash)
                                    for path, value in manifest["observations"].items()}
        self.write(manifest_path, manifest)
        skill.write_bytes(stale)
        result = self.run_cli("probe-skill-update", self.state)
        self.assertEqual(result, {"updated": [str(skill)], "errors": []})
        self.assertEqual(skill.read_bytes(), current)

    def test_user_lifecycle_preserves_shared_native_routing_and_post_install_edits(self):
        shared = self.root / "shared-codex-routing"
        config, agents = self.native_routing(self.target, shared=shared)
        self.assertTrue(config.is_symlink())
        self.assertTrue(agents.is_symlink())
        original = self.native_snapshot(config, agents)

        self.harness("plan")
        self.assertFalse(self.state.exists())
        self.assert_native_untouched(original)

        installed = self.harness("install")
        manifest_path = Path(installed["manifest"])
        self.assert_native_untouched(original, status=self.harness("status"))

        self.write(config, 'model = "model-beta"\nmodel_reasoning_effort = "xhigh"\n')
        self.write(agents / "coordinator.toml", self.agent("coordinator", "model-implementation", "medium"))
        post_install = self.native_snapshot(config, agents)
        self.assert_native_untouched(post_install, status=self.harness("status"))

        self.assertEqual(self.harness("install")["manifest"], str(manifest_path))
        self.assert_native_untouched(post_install, status=self.harness("status"))

        skill = self.skills / "tally-harness/SKILL.md"
        self.refresh_product_skill(manifest_path, skill)
        self.assert_native_untouched(post_install, status=self.harness("status"))

        self.harness("remove")
        self.assert_native_untouched(post_install)
        self.assertTrue(config.is_symlink())
        self.assertTrue(agents.is_symlink())
        self.assertFalse(skill.exists())

    def test_project_lifecycle_preserves_native_routing_and_post_install_edits(self):
        subprocess.run(["git", "init", "-q", self.project], check=True)
        source = self.project / ".claude"
        target = self.project / ".codex"
        self.write(source / "settings.json", {"hooks": {}})
        config, agents = self.native_routing(target)
        original = self.native_snapshot(config, agents)
        options = ["--scope", "project", "--source-home", str(self.source), "--target-home", str(self.target),
                   "--skills-root", str(self.skills), "--state-root", str(self.state), "--project", str(self.project)]

        self.run_cli("harness", "plan", *options)
        self.assertFalse(self.state.exists())
        self.assert_native_untouched(original)

        installed = self.run_cli("harness", "install", *options, "--confirm-git-visible")
        manifest_path = Path(installed["manifest"])
        self.assert_native_untouched(original, status=self.run_cli("harness", "status", *options))

        self.write(config, 'model = "model-project"\nmodel_reasoning_effort = "low"\n')
        self.write(agents / "review.toml", self.agent("review", "model-project-review", "high"))
        post_install = self.native_snapshot(config, agents)
        self.assert_native_untouched(post_install, status=self.run_cli("harness", "status", *options))

        self.assertEqual(self.run_cli("harness", "install", *options, "--confirm-git-visible")["manifest"],
                         str(manifest_path))
        self.assert_native_untouched(post_install, status=self.run_cli("harness", "status", *options))

        skill = self.project / ".agents/skills/tally-harness/SKILL.md"
        self.refresh_product_skill(manifest_path, skill)
        self.assert_native_untouched(post_install, status=self.run_cli("harness", "status", *options))

        self.run_cli("harness", "remove", *options)
        self.assert_native_untouched(post_install)
        self.assertFalse(skill.exists())

    def test_user_lifecycle_leaves_absent_native_routing_absent(self):
        config, agents = self.target / "config.toml", self.target / "agents"
        self.harness("plan")
        self.assertFalse(self.state.exists())
        self.assert_native_absent(config, agents)

        installed = self.harness("install")
        manifest_path = Path(installed["manifest"])
        self.assert_native_absent(config, agents, status=self.harness("status"))
        self.assertEqual(self.harness("install")["manifest"], str(manifest_path))
        self.assert_native_absent(config, agents, status=self.harness("status"))

        skill = self.skills / "tally-harness/SKILL.md"
        self.refresh_product_skill(manifest_path, skill)
        self.assert_native_absent(config, agents, status=self.harness("status"))
        self.harness("remove")
        self.assert_native_absent(config, agents)
        self.assertFalse(skill.exists())

    def test_project_lifecycle_leaves_absent_native_routing_absent(self):
        subprocess.run(["git", "init", "-q", self.project], check=True)
        source = self.project / ".claude"
        target = self.project / ".codex"
        self.write(source / "settings.json", {"hooks": {}})
        config, agents = target / "config.toml", target / "agents"
        options = ["--scope", "project", "--source-home", str(self.source), "--target-home", str(self.target),
                   "--skills-root", str(self.skills), "--state-root", str(self.state), "--project", str(self.project)]

        self.run_cli("harness", "plan", *options)
        self.assertFalse(self.state.exists())
        self.assert_native_absent(config, agents)

        installed = self.run_cli("harness", "install", *options, "--confirm-git-visible")
        manifest_path = Path(installed["manifest"])
        self.assert_native_absent(config, agents, status=self.run_cli("harness", "status", *options))
        self.assertEqual(self.run_cli("harness", "install", *options, "--confirm-git-visible")["manifest"],
                         str(manifest_path))
        self.assert_native_absent(config, agents, status=self.run_cli("harness", "status", *options))

        skill = self.project / ".agents/skills/tally-harness/SKILL.md"
        self.refresh_product_skill(manifest_path, skill)
        self.assert_native_absent(config, agents, status=self.run_cli("harness", "status", *options))
        self.run_cli("harness", "remove", *options)
        self.assert_native_absent(config, agents)
        self.assertFalse(skill.exists())
