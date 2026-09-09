"""Open the real Codex trust UI in this terminal for one isolated fixture home."""
import argparse
import json
import os

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--fixture', required=True)
parser.add_argument('--home', choices=['target', 'second'], default='target')
args = parser.parse_args()
with open(args.fixture) as file:
    fixture = json.load(file)
environment = dict(os.environ, HOME=fixture['user'], CODEX_HOME=fixture[args.home], TERM='xterm-256color')
os.execve(fixture['codex'], [fixture['codex'], '-C', fixture['project'], '--no-alt-screen'], environment)
