import importlib.util
from pathlib import Path
import shutil
import sys
import tempfile
import unittest


sys.path.insert(0, str(Path(__file__).parent))
spec = importlib.util.spec_from_file_location('native_journey', Path(__file__).with_name('native-journey.py'))
journey = importlib.util.module_from_spec(spec)
spec.loader.exec_module(journey)


class JourneyOracleChecks(unittest.TestCase):
    def fixture(self):
        root = Path(tempfile.mkdtemp()).resolve()
        self.addCleanup(shutil.rmtree, root)
        project = root / 'project'
        project.mkdir()
        patch = '*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch\n'
        preflight = 'cat /isolated/skill /isolated/instructions'
        thread, turn = 'thread-1', 'turn-1'
        return root, project, patch, preflight, thread, turn

    def source_event(self, thread, tool, tool_input):
        return {'session_id': thread, 'tool_name': tool, 'tool_input': tool_input}

    def hook(self, thread, turn, status, event='preToolUse'):
        return {'method': 'hook/completed', 'params': {'threadId': thread, 'turnId': turn,
                'run': {'eventName': event, 'handlerType': 'command', 'status': status,
                        'entries': [{'text': 'TALLY_NATIVE_STARTUP'}] if event == 'sessionStart' else []}}}

    def expected_events(self, project, preflight, patch, thread):
        return [
            self.source_event(thread, 'Bash', {'command': preflight}),
            self.source_event(thread, 'Bash', {'command': 'printf allowed > allowed.txt'}),
            self.source_event(thread, 'Bash', {'command': 'touch forbidden.txt'}),
            {'session_id': thread, 'tool_name': 'Write',
             'tool_input': {'content': '{}\n', 'file_path': str((project / 'config.json').resolve())},
             'tally_patch_operation': 'add', 'tally_original_tool': 'apply_patch'},
        ]

    def expected_notifications(self, thread, turn):
        return [self.hook(thread, None, 'completed', 'sessionStart'),
                *[self.hook(thread, turn, status) for status in ('completed', 'completed', 'blocked', 'blocked')]]

    def test_old_oracle_false_positive_is_rejected(self):
        root, project, patch, preflight, thread, turn = self.fixture()
        events = [self.source_event(thread, 'Bash', {'command': command})
                  for command in (preflight, 'printf allowed > allowed.txt',
                                  'printf allowed > allowed.txt', 'printf allowed > allowed.txt')]
        (project / 'allowed.txt').write_text('allowed')
        self.assertEqual(len(events), 4)
        self.assertEqual(events[0]['tool_input']['command'], preflight)
        self.assertEqual((project / 'allowed.txt').read_text(), 'allowed')
        self.assertFalse((project / 'forbidden.txt').exists())
        self.assertFalse((project / 'config.json').exists())
        with self.assertRaises(AssertionError):
            journey.assert_initial_acceptance_oracle(events, self.expected_notifications(thread, turn), project,
                                                     preflight, patch, thread, turn)

    def test_exact_translated_sequence_with_native_blocks_passes(self):
        root, project, patch, preflight, thread, turn = self.fixture()
        journey.assert_initial_acceptance_oracle(self.expected_events(project, preflight, patch, thread),
                                                 self.expected_notifications(thread, turn), project,
                                                 preflight, patch, thread, turn)

    def test_bash_payload_allows_only_fixture_location_metadata(self):
        root, project, patch, preflight, thread, turn = self.fixture()
        events = self.expected_events(project, preflight, patch, thread)
        for event in events[:3]:
            event['tool_input']['cwd'] = str(project)
            event['tool_input']['workdir'] = str(project)
        journey.assert_initial_acceptance_oracle(events, self.expected_notifications(thread, turn), project,
                                                 preflight, patch, thread, turn)

    def test_missing_native_block_events_are_rejected(self):
        root, project, patch, preflight, thread, turn = self.fixture()
        notifications = self.expected_notifications(thread, turn)
        for event in notifications[-2:]:
            event['params']['run']['status'] = 'completed'
        with self.assertRaises(AssertionError):
            journey.assert_initial_acceptance_oracle(self.expected_events(project, preflight, patch, thread),
                                                     notifications, project, preflight, patch, thread, turn)

    def test_wrong_action_payload_order_or_hook_identity_is_rejected(self):
        root, project, patch, preflight, thread, turn = self.fixture()
        for case in ('wrong-tool', 'wrong-payload', 'reordered-actions', 'foreign-hook-turn', 'foreign-bash-cwd',
                     'contradictory-bash-workdir'):
            with self.subTest(case=case):
                events = self.expected_events(project, preflight, patch, thread)
                notifications = self.expected_notifications(thread, turn)
                if case == 'wrong-tool':
                    events[-1]['tool_name'] = 'Edit'
                elif case == 'wrong-payload':
                    events[-1]['tool_input']['content'] = '{broken}\n'
                elif case == 'reordered-actions':
                    events[1], events[2] = events[2], events[1]
                elif case == 'foreign-bash-cwd':
                    events[1]['tool_input']['cwd'] = str(root / 'foreign')
                elif case == 'contradictory-bash-workdir':
                    events[1]['tool_input']['cwd'] = str(project)
                    events[1]['tool_input']['workdir'] = str(root / 'foreign')
                else:
                    for event in notifications[1:]:
                        event['params']['threadId'] = 'foreign-thread'
                        event['params']['turnId'] = 'foreign-turn'
                with self.assertRaises(AssertionError):
                    journey.assert_initial_acceptance_oracle(events, notifications, project,
                                                             preflight, patch, thread, turn)


if __name__ == '__main__':
    unittest.main()
