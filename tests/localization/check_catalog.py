"""Check Turkish coverage and printf argument safety without accessing user data."""
import json
from pathlib import Path
import re
import sys

root = Path(__file__).resolve().parents[2]
catalog = json.loads((root / "Tally/Resources/Localizable.xcstrings").read_text())
# Ignore literal percentages (e.g. "90% for") and %% escapes. Match only the
# format shapes used by this catalog, including explicit argument positions.
placeholder = re.compile(r"%(?:(\d+)\$)?(@|(?:ll|l)?[diu]|(?:\.\d+)?[fg])")


def arguments(text):
    result = {}
    implicit = 0
    for match in placeholder.finditer(text.replace("%%", "")):
        position, kind = match.groups()
        if position is None:
            implicit += 1
            position = str(implicit)
        result.setdefault(int(position), []).append(kind)
    return {position: sorted(kinds) for position, kinds in result.items()}


errors = []
for key, entry in catalog["strings"].items():
    unit = entry.get("localizations", {}).get("tr", {}).get("stringUnit", {})
    value = unit.get("value", "")
    if unit.get("state") != "translated" or not value.strip():
        errors.append(f"Missing Turkish translation: {key!r}")
        continue
    if arguments(key) != arguments(value):
        errors.append(f"Printf arguments changed: {key!r} -> {value!r}")
    # Paths, flags and slash commands are instructions, not prose to translate.
    for literal in re.findall(r"~/[A-Za-z0-9_./-]+|(?<!\w)/(?:tally[\w/-]*|clear|compact|login|limit-reset)\b|--[a-z][a-z-]*", key):
        if literal not in value:
            errors.append(f"Technical literal {literal!r} lost: {key!r}")

if errors:
    print("\n".join(errors))
    sys.exit(1)
print(f"PASS: {len(catalog['strings'])} Turkish translations, printf arguments and technical literals")
