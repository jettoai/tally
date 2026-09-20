import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('approval_ablation', Path(__file__).with_name('approval-ablation.py'))
ablation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ablation)


class AblationPathChecks(unittest.TestCase):
    def test_regular_fixture_paths_allow_report_and_rule_writes(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            fixture = {key: str(root / key) for key in ('home', 'source', 'project', 'user')}
            for value in fixture.values():
                Path(value).mkdir()
            fixture['codex'] = '/unused/mock-codex'
            script = root / 'project/scripts/release.sh'
            script.parent.mkdir()
            script.write_text(ablation.FIXTURE_SCRIPT)
            (root / 'fixture.json').write_text(json.dumps(fixture))
            with patch.object(ablation, 'artifact_hashes', return_value={}), \
                 patch.object(ablation, 'NativeRPC') as rpc, patch('builtins.print'):
                rpc.return_value.call.side_effect = RuntimeError('Offline fixture hook unavailable')
                self.assertFalse(ablation.run(root, 1))
            self.assertEqual(rpc.call_count, 20)
            self.assertEqual(json.loads((root / 'source/mode.json').read_text()), {'variant': 'combined'})
            self.assertIn('prefix_rule', (root / 'home/rules/experiment.rules').read_text())
            self.assertEqual(len(json.loads((root / 'ablation-result.json').read_text())['rows']), 20)

    def test_symlink_mutable_targets_are_rejected_before_any_write(self):
        for relative in ('home/rules', 'home/rules/experiment.rules', 'source/mode.json',
                         'source/events.jsonl', 'project/normal.txt',
                         'out', 'out/0-baseline-normal/native-events.json', 'ablation-result.json'):
            with self.subTest(path=relative), tempfile.TemporaryDirectory() as temporary:
                base = Path(temporary).resolve()
                root, external = base / 'experiment', base / 'external'
                root.mkdir()
                external.mkdir()
                sentinel = external / 'sentinel'
                sentinel.write_text('external rules must survive\n')
                fixture = {key: str(root / key) for key in ('home', 'source', 'project', 'user')}
                for value in fixture.values():
                    Path(value).mkdir()
                fixture['codex'] = '/unused/mock-codex'
                script = root / 'project/scripts/release.sh'
                script.parent.mkdir()
                script.write_text(ablation.FIXTURE_SCRIPT)
                (root / 'fixture.json').write_text(json.dumps(fixture))
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(external if relative in ('home/rules', 'out') else sentinel)
                with patch.object(ablation, 'artifact_hashes', return_value={}), \
                     patch.object(ablation, 'NativeRPC', side_effect=RuntimeError('RPC must not start')) as rpc:
                    error = None
                    try:
                        ablation.run(root, 1)
                    except Exception as caught:
                        error = caught
                    self.assertEqual(sentinel.read_text(), 'external rules must survive\n')
                    self.assertIsInstance(error, ValueError)
                    rpc.assert_not_called()
                if relative != 'source/mode.json':
                    self.assertFalse((root / 'source/mode.json').exists())


if __name__ == '__main__':
    unittest.main()
