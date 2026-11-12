#!/usr/bin/env python3
"""Typed JSON bridge for AppKit. Scans are read-only; Trash requires GUI approval.

There is deliberately no automatic clean mode, no arbitrary path deletion, and no
write access to Reminders. Other AppKit / EventKit code handles those tasks.
"""
from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

import storage_manager as storage

LABELS = {
    'screenshots': 'Old screenshot',
    'installers': 'Old installer',
    'vscode_updater': 'VS Code update files',
    'vscode_vsix': 'VS Code extension installer',
    'partial_download': 'Unfinished download',
    'unpacked_zip': 'Zip already unpacked',
    'app_cache': 'App cache (quit the app first)',
    'npm_cache': 'npm download cache',
    'vscode_old_extension': 'Unused VS Code extension version',
    'node_modules': 'Project packages (npm install restores)',
    'application_support': 'Application data — review only',
    'browser_or_app_cache': 'Application cache — review only',
    'large_app': 'Large app',
    'app_data': 'App data',
    'icloud_archive': 'iCloud Drive (Archive) copy',
    'icloud_leftover': 'Old iCloud sync folder',
    'ios_backups': 'iPhone/iPad backups',
    'duplicate_project': 'Project copy',
}


def _display_name(category: str, path: Path) -> str:
    if category == 'node_modules':
        return f'{path.parent.name}/node_modules'
    if category == 'npm_cache':
        return '~/.npm cache'
    return path.name


def _report_name(record) -> str:
    """Duplicate projects often share a folder name, so show where each copy lives."""
    path = Path(record['path'])
    if record['category'] == 'duplicate_project':
        try:
            return str(path.relative_to(storage.HOME))
        except ValueError:
            return str(path)
    return path.name


def _size_label(size: int) -> str:
    if size >= 1024 ** 3:
        return f'{size / (1024 ** 3):.1f} GB'
    if size >= 1024 ** 2:
        return f'{size / (1024 ** 2):.0f} MB'
    return f'{size / 1024:.0f} KB'


def _fingerprint(path: Path, category: str) -> str:
    st = path.stat(follow_symlinks=False)
    raw = '\0'.join(map(str, (category, path, st.st_dev, st.st_ino, st.st_mtime_ns, st.st_size)))
    return hashlib.sha256(raw.encode('utf-8')).hexdigest()


def scanned_candidates(config_path: Path, with_sizes: bool = True):
    cfg = storage.config_load(config_path)
    items = []
    for obj in storage.candidates(cfg, time.time(), with_sizes=with_sizes):
        p = Path(obj['path'])
        try:
            stamp = _fingerprint(p, obj['category'])
        except OSError:
            continue
        items.append({
            'category': obj['category'], 'label': LABELS.get(obj['category'], 'File'),
            'path': obj['path'], 'name': _display_name(obj['category'], p), 'bytes': obj['bytes'],
            'size': _size_label(obj['bytes']), 'fingerprint': stamp,
            'requires_quit': obj.get('requires_quit'),
        })
    return items


def scan(config_path: Path):
    items = scanned_candidates(config_path)
    cfg = storage.config_load(config_path)
    report_only = [
        {
            'category': x['category'],
            'label': x.get('label') or LABELS.get(x['category'], 'Data to review'),
            'name': _report_name(x), 'path': x['path'],
            'size': _size_label(x['bytes']) if x.get('size_known', True) else 'size unknown',
            'bytes': x['bytes'], 'advice': x.get('advice', ''),
            'has_env': x.get('has_env'), 'last_touched': x.get('last_touched'),
        }
        for x in storage.reports(cfg)
    ]
    return {
        'candidates': items,
        'candidate_count': len(items),
        'potential_bytes': sum(x['bytes'] for x in items),
        'potential': _size_label(sum(x['bytes'] for x in items)),
        'report_only': report_only,
        'disk': storage.disk_state(),
        'deletion_mode': 'explicit_gui_approval_only',
    }


def trash_one(config_path: Path, fingerprint: str):
    """Recompute the allowlist, reject changed files, and move one item to Trash.

    This subcommand is called only after a separate AppKit approval dialog. No
    background/launchd job or system maintenance flow invokes it.
    """
    if not re.fullmatch(r'[0-9a-f]{64}', fingerprint):
        raise ValueError('Invalid candidate token')
    # Sizes aren't needed to match the token, and measuring big folders again is slow.
    items = scanned_candidates(config_path, with_sizes=False)
    item = next((x for x in items if x['fingerprint'] == fingerprint), None)
    if item is None:
        raise ValueError('File changed or no longer qualifies. Scan again; nothing moved.')
    path = Path(item['path'])
    if item['category'].startswith('vscode') and storage.app_running('Visual Studio Code|Code Helper'):
        raise ValueError('Quit VS Code before removing its old installers or extensions.')
    # Revalidation and Finder Trash live in storage_manager. This does NOT call
    # rm, empty Trash, or permanently remove a file.
    storage.trash_with_finder(path)
    storage.setup_log().info('GUI_APPROVED_TRASH %s', path)
    return {'status': 'moved_to_trash', 'name': item['name']}


def command_output(args, timeout=8):
    try:
        result = subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)
        return result.stdout if result.returncode == 0 else ''
    except (OSError, subprocess.TimeoutExpired):
        return ''


def _swap_gb():
    text = command_output(['sysctl', '-n', 'vm.swapusage'])
    # Apple returns total = 1024.00M used = 320.00M free = ...
    match = re.search(r'used\s*=\s*([\d.]+)([KMG])', text)
    if not match:
        return None
    multiplier = {'K': 1 / 1024 ** 2, 'M': 1 / 1024, 'G': 1}[match.group(2)]
    return round(float(match.group(1)) * multiplier, 2)


def _heavy_processes():
    text = command_output(['ps', '-axo', 'rss=,comm='], timeout=8)
    entries = []
    for line in text.splitlines():
        m = re.match(r'\s*(\d+)\s+(.+)', line)
        if not m:
            continue
        rss_mb = int(m.group(1)) / 1024
        path = m.group(2)
        # Ignore raw helper paths in UI; use simple names only.
        if 'Google Chrome' in path: name = 'Google Chrome'
        elif 'Visual Studio Code' in path or 'Code Helper' in path: name = 'Visual Studio Code'
        elif 'Spotify' in path: name = 'Spotify'
        elif 'Docker' in path or 'com.docker' in path: name = 'Docker'
        elif 'Arc.app' in path: name = 'Arc'
        elif 'Claude' in path: name = 'Claude'
        elif 'Safari' in path or 'WebKit' in path: name = 'Safari / WebKit'
        else:
            name = Path(path).name.split(' (')[0] or 'Background app'
        entries.append((name, rss_mb))
    by_app = {}
    for name, mb in entries:
        by_app[name] = by_app.get(name, 0) + mb
    return [{'name': name, 'memory_mb': round(mb)} for name, mb in sorted(by_app.items(), key=lambda kv: kv[1], reverse=True)[:5]]


def health():
    disk = storage.disk_state()
    raw = command_output(['sysctl', '-n', 'hw.memsize']).strip()
    ram_gb = round(int(raw) / (1024 ** 3), 1) if raw.isdigit() else None
    swap = _swap_gb()
    free_percentage = disk['free_gb'] / disk['total_gb'] if disk['total_gb'] else 0
    if free_percentage < .10: disk_status = 'Low free space'
    elif free_percentage < .20: disk_status = 'Getting full'
    else: disk_status = 'Storage looks comfortable'
    # Swap itself is not memory pressure, so avoid falsely saying RAM is high.
    memory_status = ('Swap use is elevated — review your open apps' if swap is not None and swap >= 4
                     else 'Swap use is modest' if swap is not None else 'Memory status unavailable')
    return {
        'disk': disk, 'storage_status': disk_status,
        'total_ram_gb': ram_gb, 'swap_gb': swap,
        'memory_status': memory_status, 'top_apps': _heavy_processes(),
        'explanation': 'Swap alone does not prove memory pressure. Use Activity Monitor’s Memory Pressure graph for confirmation.',
        'safe': 'No files or processes were deleted. This is a read-only assessment.',
    }


def ai_status(shortcut: str = 'Mac Hub AI Plan'):
    """Check presence only; never execute a Shortcut or read private task data."""
    executable = shutil.which('shortcuts') or '/usr/bin/shortcuts'
    if not Path(executable).exists():
        return {'installed': False, 'shortcut_name': shortcut,
                'reason': 'The Shortcuts command is not available on this Mac.'}
    try:
        proc = subprocess.run([executable, 'list'], capture_output=True,
                              text=True, timeout=12, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return {'installed': False, 'shortcut_name': shortcut,
                'reason': 'Could not check Shortcuts. Open the Shortcuts app and try again.'}
    if proc.returncode != 0:
        return {'installed': False, 'shortcut_name': shortcut,
                'reason': 'Could not read your Shortcuts list. Open the app and try again.'}
    present = any(line.strip().casefold() == shortcut.casefold()
                  for line in proc.stdout.splitlines())
    return {'installed': present, 'shortcut_name': shortcut,
            'reason': 'Shortcut found. Its model and output actions still require testing.'
                      if present else 'Create a shortcut named exactly Mac Hub AI Plan.'}


def ai_plan(shortcut: str, content_path: Path):
    if not content_path.is_file() or content_path.is_symlink():
        raise ValueError('Missing task briefing input')
    if content_path.stat().st_size > 32_000:
        raise ValueError('Briefing too long; shorten task details first')
    executable = shutil.which('shortcuts') or '/usr/bin/shortcuts'
    if not Path(executable).exists():
        raise ValueError('Shortcuts command unavailable on this Mac.')
    with tempfile.TemporaryDirectory(prefix='mac-hub-ai-') as temp:
        out = Path(temp) / 'result.txt'
        try:
            proc = subprocess.run([executable, 'run', shortcut, '-i', str(content_path), '-o', str(out)],
                                  capture_output=True, text=True, timeout=100, check=False)
        except subprocess.TimeoutExpired:
            raise ValueError('AI Shortcut took too long. Retry from the Shortcuts app.')
        if proc.returncode != 0:
            raise ValueError('AI Shortcut failed. Create and test “' + shortcut + '” in Shortcuts first.')
        if not out.exists():
            raise ValueError('AI Shortcut produced no output. Add Stop and Output to the Shortcut.')
        response = out.read_text(encoding='utf-8', errors='replace').strip()[:6000]
        if not response:
            raise ValueError('AI Shortcut returned an empty result.')
        return {'summary': response, 'mode': 'user_configured_apple_shortcuts'}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=storage.DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest='command', required=True)
    sub.add_parser('health')
    sub.add_parser('scan')
    sub.add_parser('ai_status')
    trash = sub.add_parser('trash')
    trash.add_argument('fingerprint')
    ai = sub.add_parser('ai')
    ai.add_argument('input_path', type=Path)
    ai.add_argument('--shortcut', default='Mac Hub AI Plan')
    args = parser.parse_args(argv)
    try:
        if args.command == 'health': result = health()
        elif args.command == 'scan': result = scan(args.config)
        elif args.command == 'ai_status': result = ai_status()
        elif args.command == 'trash': result = trash_one(args.config, args.fingerprint)
        else: result = ai_plan(args.shortcut, args.input_path)
        print(json.dumps({'ok': True, 'data': result}, ensure_ascii=False))
        return 0
    except (ValueError, RuntimeError, OSError) as e:
        print(json.dumps({'ok': False, 'error': str(e)}, ensure_ascii=False))
        return 1


if __name__ == '__main__':
    sys.exit(main())
