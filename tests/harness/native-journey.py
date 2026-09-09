"""Opt-in real Codex hook acceptance. Prepare, use native /hooks trust, then exercise."""
import argparse
import json
from pathlib import Path
import shlex
import subprocess
import tempfile

from native_rpc import NativeRPC


def run(*args, input=None):
    result = subprocess.run(list(map(str, args)), input=input, text=True, capture_output=True, timeout=30)
    if result.returncode:
        raise RuntimeError(result.stderr)
    return json.loads(result.stdout) if result.stdout else None


def settings(path, hooks):
    path.write_text(json.dumps({'hooks': hooks}, indent=2) + '\n')


def prepare(args):
    root = Path(tempfile.mkdtemp(prefix='tally-native-harness-')).resolve()
    user = root / 'user'
    source, target, second = root / 'claude', user / '.codex', user / '.codex2'
    project, state = root / 'project', root / 'state/harness'
    if args.scope == 'project':
        source = project / '.claude'
    for path in (source / 'hooks', source / 'skills/example', target, second, project):
        path.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/git', 'init', '-q', str(project)], check=True)
    auth = Path(args.auth_home).expanduser().resolve() / 'auth.json'
    if not auth.is_file():
        raise RuntimeError('A signed-in Codex home with auth.json is required. No credentials are copied or printed.')
    for home in (target, second):
        (home / 'auth.json').symlink_to(auth)
        (home / 'config.toml').write_text('model = "' + args.model + '"\nmodel_reasoning_effort = "low"\n')
    (second / 'hooks.json').symlink_to(target / 'hooks.json')
    instructions = project / 'CLAUDE.md' if args.scope == 'project' else source / 'CLAUDE.md'
    instructions.write_text('Synthetic acceptance workspace. Follow the current test prompt exactly. Do not contact other sessions.\n')
    (source / 'skills/example/SKILL.md').write_text('---\nname: example\ndescription: Synthetic harness acceptance skill.\n---\nUse the fixture oracle and report actual outcomes.\n')
    gate = source / 'hooks/fixture-gate.sh'
    log = root / 'source-events.jsonl'
    gate.write_text('input=$(cat)\nprintf "%s\\n" "$input" >> ' + shlex.quote(str(log)) + '\n'
                    'case "$input" in\n'
                    '  *forbidden.txt*) echo "TALLY_NATIVE_DENY" >&2; exit 2;;\n'
                    '  *config.json*) printf \'%s\\n\' \'{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"TALLY_NATIVE_PATCH_APPROVAL"}}\';;\n'
                    'esac\n')
    command = '/bin/bash ' + shlex.quote(str(gate))
    hooks = {'PreToolUse': [{'matcher': 'Bash|Edit|Write', 'hooks': [{'type': 'command', 'command': command, 'timeout': 10}]}],
             'SessionStart': [{'hooks': [{'type': 'command', 'command': "printf 'TALLY_NATIVE_STARTUP\\n'"}]}]}
    settings(source / 'settings.json', hooks)
    observer = root / 'observe-stop.py'
    observer.write_text('import json,sys\nx=json.load(sys.stdin)\n'
                        'keys=["hook_event_name","session_id","stop_hook_active"]\n'
                        'with open(' + repr(str(root / 'native-stop-inputs.jsonl')) + ', "a") as f:\n'
                        '    f.write(json.dumps({k:x.get(k) for k in keys})+"\\n")\n')
    target_config = project / '.codex/hooks.json' if args.scope == 'project' else target / 'hooks.json'
    target_config.parent.mkdir(exist_ok=True)
    settings(target_config, {'Stop': [{'hooks': [{'type': 'command',
              'command': 'python3 ' + shlex.quote(str(observer)), 'timeout': 5}]}]})
    options = ['--scope', args.scope, '--source-home', str(source), '--target-home', str(target),
               '--skills-root', str(user / '.agents/skills'), '--state-root', str(state)]
    if args.scope == 'project':
        options += ['--project', str(project)]
    tools_options = ['--source-home', str(source), '--target-home', str(target),
                     '--skills-root', str(user / '.agents/skills'), '--state-root', str(state)]
    run(args.cli, 'harness', 'tools', 'install', *tools_options)
    installed = run(args.cli, 'harness', 'install', *options,
                    *(['--confirm-git-visible'] if args.scope == 'project' else []))
    fixture = {'root': str(root), 'user': str(user), 'source': str(source), 'target': str(target),
               'second': str(second), 'project': str(project), 'state': str(state),
               'manifest': installed['manifest'], 'cli': str(Path(args.cli).resolve()),
               'codex': str(Path(args.codex).resolve()), 'model': args.model, 'options': options,
               'scope': args.scope, 'instructions': str(instructions), 'toolsOptions': tools_options,
               'productSkill': str((project if args.scope == 'project' else user) / '.agents/skills/tally-harness/SKILL.md')}
    (root / 'fixture.json').write_text(json.dumps(fixture, indent=2) + '\n')
    print(json.dumps(fixture, indent=2))


def inspect(fixture, name):
    root = Path(fixture['root'])
    output = root / ('native-' + name)
    output.mkdir(exist_ok=True)
    client = NativeRPC(fixture['codex'], fixture[name], fixture['user'], output)
    try:
        result = client.call('hooks/list', {'cwds': [fixture['project']]})
        (output / 'hooks.json').write_text(json.dumps(result, indent=2) + '\n')
        hooks = result['data'][0]['hooks']
        owned = [row for row in hooks if fixture['cli'] in (row.get('command') or '')]
        skills = client.call('skills/list', {'cwds': [fixture['project']], 'forceReload': True})
        (output / 'skills.json').write_text(json.dumps(skills, indent=2) + '\n')
        discovered = [skill for item in skills['data'] for skill in item['skills']
                      if skill['name'] == 'tally-harness']
        assert discovered, 'The installed workflow must be discovered by native Codex'
        return {'home': fixture[name], 'registered': len(owned),
                'trusted': sum(row['trustStatus'] == 'trusted' for row in owned),
                'enabled': sum(row['enabled'] for row in owned), 'skillsDiscovered': len(discovered)}
    finally:
        client.close()


def exercise(fixture):
    root, project = Path(fixture['root']), Path(fixture['project'])
    statuses = [inspect(fixture, name) for name in ('target', 'second')]
    if not all(row['registered'] > 0 and row['registered'] == row['trusted'] == row['enabled'] for row in statuses):
        raise RuntimeError('Review and trust the fixture hooks in native Codex /hooks for both homes first: ' + json.dumps(statuses))
    output = root / 'exercise'
    output.mkdir(exist_ok=True)
    client = NativeRPC(fixture['codex'], fixture['target'], fixture['user'], output)
    report = {'nativeTrust': statuses, 'turns': [], 'modelRequested': fixture['model'], 'modelActual': None,
              'effort': 'low', 'costUSD': None}
    try:
        started = client.call('thread/start', {'cwd': str(project), 'model': fixture['model'],
                              'sandbox': 'workspace-write', 'approvalPolicy': 'never',
                              'config': {'model_reasoning_effort': 'low'}})
        thread = started['thread']['id']
        report['thread'] = thread
        report['modelActual'] = started.get('model')
        patch = '*** Begin Patch\n*** Add File: config.json\n+{}\n*** End Patch\n'
        common = 'This is an authorized isolated Tally product acceptance test. Work only in ' + str(project) + '. '
        preflight = 'cat ' + ' '.join(map(shlex.quote, [fixture.get('productSkill', str(Path(fixture['user']) / '.agents/skills/tally-harness/SKILL.md')),
                                                      fixture.get('instructions', str(Path(fixture['source']) / 'CLAUDE.md'))]))
        prompt = common + ('Use native tools, not shell replacements for file edits. First read the required harness instructions '
            'with one Bash call using exactly `' + preflight + '`. Then make exactly these three acceptance tool calls, in order: '
            '1. Bash command `printf allowed > allowed.txt`. 2. Bash command `touch forbidden.txt` once, even though the test hook will deny it. '
            '3. One native apply_patch call with tool_input.command exactly the following patch, including its final newline:\n'
            + patch + '\nDo not retry, grant approval, modify hooks, use another file writer, or spawn agents. '
            'After the three attempts, report the native startup marker and each result. A denial is an expected test result.')
        report['turns'].append(client.turn(thread, prompt, root))
        def source_events():
            return [row for row in map(json.loads, (root / 'source-events.jsonl').read_text().splitlines())
                    if row.get('session_id') == thread]
        events = source_events()
        assert len(events) == 4, 'One instruction read and three acceptance attempts are required'
        assert events[0]['tool_input']['command'] == preflight
        assert (project / 'allowed.txt').read_text() == 'allowed'
        assert not (project / 'forbidden.txt').exists()
        assert not (project / 'config.json').exists()
        manifest = json.loads(Path(fixture['manifest']).read_text())
        requests = [path for path in (Path(fixture['manifest']).parent / 'approvals' / manifest['generation']).glob('*.json')
                    if json.loads(path.read_text())['binding']['session'] == thread]
        assert len(requests) == 1, 'One exact native approval request is required'
        request = json.loads(requests[0].read_text())
        assert request['state'] == 'pending'
        request_id = requests[0].stem
        run(fixture['cli'], 'harness', 'grant', '--manifest', fixture['manifest'], '--request', request_id,
            '--authorization', 'User-authorized isolated product acceptance: one config.json retry')
        report['turns'].append(client.turn(thread, common + 'The test coordinator recorded the authorized one-use grant. '
            'Retry the identical native apply_patch call exactly once, with no other tools or fallback. Patch including final newline:\n' + patch, root))
        assert (project / 'config.json').read_text() == '{}\n'
        assert len(source_events()) == 5, 'Exactly one native retry is required'
        assert json.loads(requests[0].read_text())['state'] == 'consumed'
        (project / 'config.json').unlink()
        report['turns'].append(client.turn(thread, common + 'Replay protection check: make the identical native apply_patch call once. '
            'The file was removed by the test coordinator to recreate the original preimage. Do not grant, retry, or use a fallback.\n' + patch, root))
        assert not (project / 'config.json').exists()
        assert len(source_events()) == 6, 'Exactly one native replay attempt is required'
        report['patchRequest'] = request_id
        report['sourceEvents'] = len(source_events())
        report['procedure'] = 'One required instruction read, three initial attempts, one granted retry, one denied replay'
        assert any('TALLY_NATIVE_STARTUP' in str(event) for event in client.notifications), 'Native startup marker was not observed'
        report['state'] = 'passed'
    finally:
        client.close()
        (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('action', choices=['prepare', 'inspect', 'exercise'])
parser.add_argument('--cli', type=Path)
parser.add_argument('--codex', type=Path)
parser.add_argument('--auth-home', default=str(Path.home() / '.codex'))
parser.add_argument('--model', default='gpt-6-astra')
parser.add_argument('--scope', choices=['user', 'project'], default='user')
parser.add_argument('--root', type=Path)
args = parser.parse_args()
if args.action == 'prepare':
    if not args.cli or not args.codex:
        parser.error('prepare requires --cli and --codex')
    prepare(args)
else:
    if not args.root:
        parser.error('inspect/exercise requires --root')
    fixture = json.loads((args.root / 'fixture.json').read_text())
    if args.action == 'inspect':
        print(json.dumps([inspect(fixture, name) for name in ('target', 'second')], indent=2))
    else:
        exercise(fixture)
