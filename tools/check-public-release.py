#!/usr/bin/env python3
"""Check a working tree for common accidental disclosures before public release.

This is a heuristic, not a security audit. It does not contact the network.
It reports filenames and categories only, never matching values.
"""
from pathlib import Path
import ipaddress
import re
import sys

ROOT = Path(__file__).resolve().parent.parent
SKIP_DIRS = {'.git', 'node_modules', '__pycache__'}
BLOCKED_PARTS = {'local-codex-chat-state', 'local-codex-chat-work', 'backup-galgame-20261105'}
BLOCKED_NAMES = {'installation.json', 'deepseek-key.dat', 'chat-history.dat', 'binding.json', 'update-preferences.json'}
RULES = {
    'API token': re.compile(rb'\b(?:sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})\b'),
    'private key': re.compile(rb'-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----'),
    'Windows personal path': re.compile(rb'(?i)(?:[A-Z]:\\{1,2}Users\\{1,2}(?!Public\\|Default\\)[^\\\s"\x27]+\\{1,2}|[A-Z]:\\{1,2}ChatGPT)'),
}
IP = re.compile(rb'(?<![\w.])(?:\d{1,3}\.){3}\d{1,3}(?![\w.])')
findings = []
for path in ROOT.rglob('*'):
    rel = path.relative_to(ROOT)
    if set(rel.parts) & SKIP_DIRS:
        continue
    if set(rel.parts) & BLOCKED_PARTS or path.name in BLOCKED_NAMES or path.name.startswith('.env'):
        findings.append((rel, 'local data or configuration'))
        continue
    if not path.is_file():
        continue
    try:
        data = path.read_bytes()
    except OSError:
        findings.append((rel, 'unreadable file'))
        continue
    for label, pattern in RULES.items():
        if pattern.search(data):
            findings.append((rel, label))
    if path.suffix.lower() not in {'.png', '.jpg', '.jpeg', '.ico', '.wav', '.webp'}:
        for match in IP.findall(data):
            try:
                if not ipaddress.ip_address(match.decode('ascii')).is_loopback:
                    findings.append((rel, 'non-loopback IP literal'))
                    break
            except ValueError:
                pass
if findings:
    for path, category in findings:
        print(f'{category}: {path}')
    print('检查未通过：请审阅上述路径；不要公开本机数据。')
    sys.exit(1)
print('未发现所检查类型的本机数据、常见密钥、个人路径或非回环 IP。仍需人工审阅。')
