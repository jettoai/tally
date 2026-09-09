"""Opt-in two-turn Codex Stop reentry check with one deliberately pending fixture message."""
import argparse
import json
from pathlib import Path
import subprocess

from native_rpc import NativeRPC

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixture', type=Path, required=True)
args = parser.parse_args()
fixture = json.loads(args.fixture.read_text())
root = Path(fixture['root'])
output = root / 'stop-inbox'
output.mkdir(exist_ok=True)
body = output / 'message.txt'
body.write_text('Synthetic pending Stop reminder. Do not process during this acceptance test.\n')
address = ['--provider', 'codex', '--home', fixture['target'], '--project', fixture['project'],
           '--root', str(root / 'state/inbox')]


def tally(*words):
    result = subprocess.run([fixture['cli'], 'inbox', *words, *address], text=True,
                            capture_output=True, timeout=10, check=True)
    return json.loads(result.stdout)


posted = tally('post', '--file', str(body))
client = NativeRPC(fixture['codex'], fixture['target'], fixture['user'], output)
report = {'state': 'started', 'modelRequested': fixture['model'], 'effort': 'low', 'costUSD': None}
try:
    started = client.call('thread/start', {'cwd': fixture['project'], 'model': fixture['model'],
                          'sandbox': 'workspace-write', 'approvalPolicy': 'never'})
    owner = started['thread']['id']
    report.update(session=owner, modelActual=started.get('model'), turns=[])
    for index in range(2):
        prompt = ('Authorized synthetic Stop reentry acceptance. Leave the pending inbox item unclaimed and unacknowledged '
                  'for this test only. Do not use any tools or read files. Respond TALLY_STOP_TURN_' + str(index + 1)
                  + '. If a Stop hook reminds you again, respond with the same marker without processing the message.')
        report['turns'].append(client.turn(owner, prompt, root))
        rows = [json.loads(line) for line in (root / 'native-stop-inputs.jsonl').read_text().splitlines()]
        rows = [row for row in rows if row['session_id'] == owner]
        expected = [False, True] * (index + 1)
        assert [row['stop_hook_active'] for row in rows] == expected, rows
        assert tally('status', '--id', posted['id'])['state'] == 'pending'
    report.update(state='passed', stopInputs=rows, message=posted['id'])
finally:
    client.close()
    (output / 'result.json').write_text(json.dumps(report, indent=2) + '\n')
print(json.dumps(report, indent=2))
