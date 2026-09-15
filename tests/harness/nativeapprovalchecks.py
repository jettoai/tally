import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location('approval_ablation', Path(__file__).with_name('approval-ablation.py'))
ablation = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ablation)


class NativeApprovalChecks(unittest.TestCase):
    def test_fixture_approval_accepts_only_exact_command_and_native_shell_transport(self):
        project = Path('/isolated/project')
        command = 'scripts/release.sh accepted.txt'
        for actual in (command, "/bin/bash -c 'scripts/release.sh accepted.txt'",
                       "/bin/zsh -lc 'scripts/release.sh accepted.txt'"):
            self.assertTrue(ablation.matches_approval({'cwd': str(project), 'command': actual}, command, project))
        for actual in (command + '; echo extra', '/bin/bash -c "' + command + '; echo extra"',
                       '/bin/bash -c "' + command + '" extra', 'env ' + command,
                       '/unknown/bash -c "' + command + '"', 'scripts/release.sh other.txt',
                       '/bin/bash -c "unfinished', None, [command]):
            self.assertFalse(ablation.matches_approval({'cwd': str(project), 'command': actual}, command, project))
        self.assertFalse(ablation.matches_approval({'cwd': '/other', 'command': command}, command, project))
        self.assertFalse(ablation.matches_approval({'command': command}, command, project))
