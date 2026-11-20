"""Checks and reports the cloud split inventory (ADR 0043 of hexagon-template-ng).

Every tracked file must match a rule of scripts/cloud-classification.json; the first match wins.
A common file must not name services of any cloud, and a file of one cloud must not name the
other. Mixed files must say how they are split. Usage:

    python scripts/cloud_classification.py check
    python scripts/cloud_classification.py report
"""
from __future__ import annotations

import argparse
import fnmatch
import json
import re
import subprocess
import sys
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

SCOPES = ('common', 'history', 'repository', 'aws', 'azure', 'mixed')
AWS = re.compile(r'(?i)\b(aws[a-z0-9]*|amazon|cloudfront|fargate|sns|sqs|ecs|ecr|rds|s3|secretsmanager)\b')
AZURE = re.compile(r'(?i)(azure[a-z0-9]*|azapi|servicebus|service bus|container ?apps?|static ?web ?apps?|staticwebapp|key ?vault|\bentra\b)')
FORBIDDEN = {'common': (AWS, AZURE), 'aws': (AZURE,), 'azure': (AWS,)}
# Logical messaging providers of the backend contract (BE-0022): the core validates them by name.
PROVIDERS = re.compile(r'(?i)aws-sns-sqs|azure-service-bus|AwsSnsSqs|AzureServiceBus')


@dataclass(frozen=True)
class Classified:
    path: str
    scope: str
    pattern: str


def load(root: Path) -> list[dict]:
    rules = json.loads((root / 'scripts' / 'cloud-classification.json').read_text(encoding='utf-8'))['rules']
    for rule in rules:
        if rule.get('scope') not in SCOPES:
            raise ValueError(f"Unknown scope in rule {rule.get('pattern')!r}.")
        if rule['scope'] == 'mixed' and not rule.get('split'):
            raise ValueError(f"Mixed rule {rule['pattern']!r} must say how it is split.")
    return rules


def tracked(root: Path) -> list[str]:
    output = subprocess.run(['git', '-C', str(root), 'ls-files', '-z'], check=True, capture_output=True).stdout
    return sorted(path for path in output.decode('utf-8').split('\0') if path)


def classify(files: list[str], rules: list[dict]) -> tuple[list[Classified], list[str], list[str]]:
    classified, unmatched, used = [], [], set()
    for path in files:
        rule = next((rule for rule in rules if fnmatch.fnmatchcase(path, rule['pattern'])), None)
        if rule is None:
            unmatched.append(path)
            continue
        used.add(rule['pattern'])
        classified.append(Classified(path, rule['scope'], rule['pattern']))
    unused = [rule['pattern'] for rule in rules if rule['pattern'] not in used]
    return classified, unmatched, unused


def violations(root: Path, classified: list[Classified]) -> list[str]:
    found = []
    for item in classified:
        patterns = FORBIDDEN.get(item.scope)
        if not patterns:
            continue
        try:
            text = PROVIDERS.sub('', (root / item.path).read_text(encoding='utf-8'))
        except UnicodeDecodeError:
            continue
        for pattern in patterns:
            match = pattern.search(text) or pattern.search(PROVIDERS.sub('', item.path))
            if match:
                found.append(f'{item.path} ({item.scope}) names {match.group(0)!r}')
                break
    return found


def imports(root: Path, classified: list[Classified]) -> list[str]:
    """A common script imports only common or mixed modules; a cloud never imports the other."""
    by_name = {Path(item.path).stem: item for item in classified
               if item.path.startswith('scripts/') and item.path.endswith(('.ps1', '.psm1'))}
    allowed = {'common': {'common', 'mixed'}, 'aws': {'common', 'mixed', 'aws'}, 'azure': {'common', 'mixed', 'azure'}}
    found = []
    for item in classified:
        if item.scope not in allowed or not item.path.endswith(('.ps1', '.psm1')):
            continue
        text = (root / item.path).read_text(encoding='utf-8')
        names = set(re.findall(r"'([A-Za-z.-]+)'", text)) | set(re.findall(r'([A-Za-z.-]+)[.]psm1', text))
        for name in sorted(names & by_name.keys()):
            target = by_name[name]
            if target.path != item.path and target.scope not in allowed[item.scope]:
                found.append(f'{item.path} ({item.scope}) imports {target.path} ({target.scope})')
    return found


def check(root: Path) -> list[str]:
    rules = load(root)
    classified, unmatched, unused = classify(tracked(root), rules)
    errors = [f'{path} matches no rule' for path in unmatched]
    errors += [f'rule {pattern!r} matches no tracked file' for pattern in unused]
    errors += violations(root, classified)
    errors += imports(root, classified)
    return errors


def base(root: Path) -> list[str]:
    """Files of the base that every cloud template copies: common and history, except the changelog,
    which each repository keeps for itself."""
    classified, unmatched, _ = classify(tracked(root), load(root))
    if unmatched:
        raise SystemExit(f'{len(unmatched)} files match no rule; classify them first.')
    return sorted(item.path for item in classified if item.scope in ('common', 'history') and item.path != 'CHANGELOG.md')


def report(root: Path) -> str:
    classified, _, _ = classify(tracked(root), load(root))
    counts = Counter(item.scope for item in classified)
    lines = ['| Clase | Archivos |', '| --- | --- |']
    lines += [f'| {scope} | {counts.get(scope, 0)} |' for scope in SCOPES]
    lines += ['', '| Archivo mixto |', '| --- |']
    lines += [f'| `{item.path}` |' for item in classified if item.scope == 'mixed']
    return '\n'.join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument('command', choices=['check', 'report', 'base'])
    parser.add_argument('--root', default=str(Path(__file__).resolve().parents[1]))
    args = parser.parse_args()
    root = Path(args.root)
    if args.command == 'report':
        print(report(root))
        return 0
    if args.command == 'base':
        print('\n'.join(base(root)))
        return 0
    errors = check(root)
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print('Cloud classification is complete and consistent.')
    return 0


if __name__ == '__main__':
    sys.exit(main())
