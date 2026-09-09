from fixture import Fixture


class NativeChecks(Fixture):
    def response(self):
        registrations = [row for row in self.manifest['registrations'] if row['provider'] == 'codex']
        return {'result': {'data': [{'cwd': str(self.project), 'hooks': [
            {'command': row['command'], 'sourcePath': row['path'], 'eventName': row['event'],
             'enabled': True, 'trustStatus': 'trusted'} for row in registrations]}]}}

    def test_trust_requires_matching_enabled_native_entries(self):
        self.install()
        response = self.response()
        self.assertEqual(self.run_cli('probe-trust', self.manifest_path, input=response)['state'], 'trusted-enabled')
        response['result']['data'][0]['hooks'][0]['enabled'] = False
        self.assertEqual(self.run_cli('probe-trust', self.manifest_path, input=response)['state'], 'needs-review')

    def test_missing_untrusted_or_duplicate_entries_need_review(self):
        self.install()
        for variant in ['missing', 'untrusted', 'duplicate', 'wrong-event', 'wrong-path']:
            with self.subTest(variant=variant):
                response = self.response()
                hooks = response['result']['data'][0]['hooks']
                if variant == 'missing':
                    hooks.pop()
                elif variant == 'untrusted':
                    hooks[0]['trustStatus'] = 'untrusted'
                elif variant == 'duplicate':
                    hooks.append(dict(hooks[0]))
                elif variant == 'wrong-event':
                    hooks[0]['eventName'] = 'different'
                else:
                    hooks[0]['sourcePath'] = '/other/hooks.json'
                self.assertEqual(self.run_cli('probe-trust', self.manifest_path, input=response)['state'], 'needs-review')

    def test_native_error_is_not_trusted(self):
        self.install()
        self.run_cli('probe-trust', self.manifest_path, input={'error': {'message': 'unavailable'}}, code=2)

    def test_lifecycle_uses_source_guidance_and_reports_drift(self):
        self.install()
        self.write(self.source / 'CLAUDE.md', 'changed instructions')
        event = {'hook_event_name': 'SessionStart', 'cwd': str(self.project), 'session_id': 'native-fixture'}
        result = self.run_cli('codex-hook', '--manifest', self.manifest_path, '--entry', 'lifecycle', input=event)
        text = result['hookSpecificOutput']['additionalContext']
        self.assertIn(str(self.source / 'CLAUDE.md'), text)
        self.assertIn('Drift observed', text)
        self.assertIn('Registration is not behavioral validation', text)
