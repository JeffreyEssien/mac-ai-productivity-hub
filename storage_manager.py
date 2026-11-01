#!/usr/bin/env python3
"""Conservative macOS storage report/cleanup. Python 3.9+, standard library only.

Scheduled runs ALWAYS report only. Interactive --execute allows allowlisted cleanup.
Application Support and browser/Spotify caches are intentionally report-only.
"""
import argparse
import datetime as dt
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import time

HOME = Path.home()
BASE = HOME / '.mac-storage-manager'
HISTORY = BASE / 'history.jsonl'
HISTORY_MAX = 500
DEFAULT_CONFIG = Path(__file__).with_name('config.json')
SCREENSHOT = re.compile(r'^(?:Screen Shot|Screenshot) .+\.(?:png|jpe?g|heic)$', re.I)
INSTALLERS = {'.dmg', '.pkg', '.mpkg'}
APP_SUPPORT_NAMES = ('Claude', 'Code', 'Google', 'Arc', 'Spotify', 'Antigravity', 'Figma', 'Cypress', 'Cursor')
REPORT_CACHE_NAMES = ('com.spotify.client', 'Arc', 'Google', 'Cypress', 'ms-playwright', 'ms-playwright-go')
VS_CODE = 'Visual Studio Code'
LABEL = 'com.local.mac-storage-manager'


def config_load(path):
    with path.open(encoding='utf-8') as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError('Config must be an object')
    for key in ('screenshot_days', 'installer_days', 'vscode_cache_days', 'large_support_gb', 'homebrew_prune_days'):
        if not isinstance(cfg.get(key), int) or isinstance(cfg[key], bool) or cfg[key] < 1:
            raise ValueError(f'Config {key} must be a positive integer')
    return cfg


def setup_log():
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    logger = logging.getLogger('storage_manager')
    logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler = RotatingFileHandler(BASE / 'manager.log', maxBytes=2_000_000, backupCount=4)
        handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
        logger.addHandler(handler)
    return logger


def run_cmd(args, timeout=45):
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout, check=False)


def disk_state():
    usage = shutil.disk_usage(HOME)
    return {'total_gb': round(usage.total / 1e9, 2), 'used_gb': round(usage.used / 1e9, 2), 'free_gb': round(usage.free / 1e9, 2)}


def size_bytes(path):
    """Never traverse directory symlinks; skip unreadable items."""
    if path.is_symlink():
        return 0
    try:
        if path.is_file():
            return path.stat(follow_symlinks=False).st_size
        if not path.is_dir():
            return 0
    except OSError:
        return 0
    total = 0
    for root, dirs, files in os.walk(path, followlinks=False, onerror=lambda e: None):
        dirs[:] = [d for d in dirs if not (Path(root) / d).is_symlink()]
        for name in files:
            p = Path(root) / name
            try:
                if not p.is_symlink():
                    total += p.stat(follow_symlinks=False).st_size
            except OSError:
                continue
    return total


def mib(b):
    return f'{b / 1024**2:.1f} MiB'


def safe_child(p, parent):
    """Require an actual immediate child of allowed parent, never symlink."""
    return (p.parent == parent and not p.is_symlink() and parent.is_dir()
            and not parent.is_symlink() and p.exists())


def older(p, days, now):
    return p.stat(follow_symlinks=False).st_mtime < now - days * 86400


def app_running(pattern):
    # pattern is an extended regex: pgrep -f matches the full command line and
    # treats '|' as alternation (BSD pgrep on macOS), so a caller can pass
    # 'Visual Studio Code|Code Helper' to catch either process name.
    try:
        res = run_cmd(['pgrep', '-if', pattern], timeout=5)
        return res.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return True  # fail closed


def candidates(cfg, now):
    result = []
    desktop = HOME / 'Desktop'
    downloads = HOME / 'Downloads'
    caches = HOME / 'Library' / 'Caches'
    code = HOME / 'Library' / 'Application Support' / 'Code'
    if desktop.is_dir() and not desktop.is_symlink():
        for p in desktop.iterdir():
            try:
                if safe_child(p, desktop) and p.is_file() and SCREENSHOT.fullmatch(p.name) and older(p, cfg['screenshot_days'], now):
                    result.append({'category': 'screenshots', 'path': str(p), 'bytes': size_bytes(p), 'age_days': cfg['screenshot_days'], 'requires_quit': None})
            except OSError:
                continue
    if downloads.is_dir() and not downloads.is_symlink():
        for p in downloads.iterdir():
            try:
                if (safe_child(p, downloads) and p.is_file() and p.suffix.lower() in INSTALLERS
                        and older(p, cfg['installer_days'], now)):
                    result.append({'category': 'installers', 'path': str(p), 'bytes': size_bytes(p), 'age_days': cfg['installer_days'], 'requires_quit': None})
            except OSError:
                continue
    # VSCode updater cache, or aged top-level VSIX installer archives. Avoid clearing extension settings.
    shipit = caches / 'com.microsoft.VSCode.ShipIt'
    try:
        if safe_child(shipit, caches) and older(shipit, cfg['vscode_cache_days'], now):
            result.append({'category': 'vscode_updater', 'path': str(shipit), 'bytes': size_bytes(shipit), 'age_days': cfg['vscode_cache_days'], 'requires_quit': VS_CODE})
    except OSError:
        pass
    vsix = code / 'CachedExtensionVSIXs'
    if vsix.is_dir() and not vsix.is_symlink():
        for p in vsix.iterdir():
            try:
                if (safe_child(p, vsix) and p.is_file() and p.suffix.lower() == '.vsix'
                        and older(p, cfg['vscode_cache_days'], now)):
                    result.append({'category': 'vscode_vsix', 'path': str(p), 'bytes': size_bytes(p), 'age_days': cfg['vscode_cache_days'], 'requires_quit': VS_CODE})
            except OSError:
                continue
    return sorted(result, key=lambda x: x['bytes'], reverse=True)


def reports(cfg):
    support = HOME / 'Library' / 'Application Support'
    caches = HOME / 'Library' / 'Caches'
    records = []
    for group, root, names in (('application_support', support, APP_SUPPORT_NAMES), ('browser_or_app_cache', caches, REPORT_CACHE_NAMES)):
        for name in names:
            p = root / name
            if p.exists() and not p.is_symlink():
                sz = size_bytes(p)
                if group != 'application_support' or sz >= cfg['large_support_gb'] * 1e9:
                    records.append({'category': group, 'path': str(p), 'bytes': sz, 'policy': 'report_only'})
    return sorted(records, key=lambda x: x['bytes'], reverse=True)


def trash_with_finder(path):
    """Finder Trash, with no shell expansion or AppleScript interpolated paths."""
    script = ('on run argv\n'
              'tell application "Finder"\n'
              'delete (POSIX file (item 1 of argv) as alias)\n'
              'end tell\n'
              'end run')
    proc = run_cmd(['osascript', '-e', script, str(path)], timeout=60)
    if proc.returncode != 0:
        raise RuntimeError(proc.stderr.strip() or 'Finder Trash failed')


def native_ops(dry_run, approve, prune_days):
    tasks = [
        ('pip', [sys.executable, '-m', 'pip', 'cache', 'info'] if dry_run else [sys.executable, '-m', 'pip', 'cache', 'purge']),
    ]
    brew = shutil.which('brew')
    if brew:
        tasks.append(('homebrew', [brew, 'cleanup', f'--prune={prune_days}'] + (['--dry-run'] if dry_run else [])))
    for name, args in tasks:
        print(f'[{name}] {" ".join(args)}')
        if not dry_run and not approve:
            print('  SKIPPED: native cleanup requires --approve-native')
            continue
        try:
            p = run_cmd(args, timeout=180)
            print((p.stdout or p.stderr or '(no output)')[:2500].strip())
            if p.returncode:
                print(f'  WARNING: returned {p.returncode} (nothing inferred as cleaned)')
        except (OSError, subprocess.TimeoutExpired) as e:
            print(f'  WARNING: {e}')


def config_example():
    return {'screenshot_days': 30, 'installer_days': 60, 'vscode_cache_days': 30, 'large_support_gb': 1, 'homebrew_prune_days': 30}


def history_record(payload):
    """Flatten a scan/cleanup payload into one compact trend row."""
    after = payload.get('after', {})
    return {'date': payload['date'], 'mode': payload['mode'],
            'free_gb': after.get('free_gb'), 'used_gb': after.get('used_gb'),
            'total_gb': after.get('total_gb'), 'eligible_bytes': payload.get('eligible_bytes', 0),
            'trashed': payload.get('trash_count', 0)}


def append_history(payload):
    """Append one trend row, keeping only the most recent HISTORY_MAX lines."""
    BASE.mkdir(mode=0o700, parents=True, exist_ok=True)
    lines = HISTORY.read_text(encoding='utf-8').splitlines() if HISTORY.exists() else []
    lines.append(json.dumps(history_record(payload)))
    HISTORY.write_text('\n'.join(lines[-HISTORY_MAX:]) + '\n', encoding='utf-8')


def read_history():
    if not HISTORY.exists():
        return []
    rows = []
    for line in HISTORY.read_text(encoding='utf-8').splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            rows.append(json.loads(line))
        except ValueError:
            continue
    return rows


def show_trend():
    rows = read_history()
    if not rows:
        print('No history yet. Run a scan to start tracking free-space trend.')
        return
    print(f'STORAGE TREND ({len(rows)} scans) — oldest to newest:')
    for r in rows[-30:]:
        free = f'{r["free_gb"]:.2f}' if isinstance(r.get('free_gb'), (int, float)) else '  n/a'
        print(f' {r["date"][:19]}  free={free:>8} GB  [{r["mode"]}]  eligible={mib(r.get("eligible_bytes", 0))}')
    first, last = rows[0], rows[-1]
    if isinstance(first.get('free_gb'), (int, float)) and isinstance(last.get('free_gb'), (int, float)):
        delta = last['free_gb'] - first['free_gb']
        print(f'\nFree space change across window: {delta:+.2f} GB '
              f'({first["date"][:10]} → {last["date"][:10]})')


def install_agent(script, config_path, hour):
    agent_dir = HOME / 'Library' / 'LaunchAgents'
    agent_dir.mkdir(parents=True, exist_ok=True)
    path = agent_dir / (LABEL + '.plist')
    data = {'Label': LABEL,
            'ProgramArguments': [sys.executable, str(script.resolve()), '--config', str(config_path.resolve()), 'scan'],
            'StartCalendarInterval': {'Hour': hour, 'Minute': 0},
            'RunAtLoad': False,
            'StandardOutPath': str(BASE / 'launchd.out.log'),
            'StandardErrorPath': str(BASE / 'launchd.err.log')}
    path.write_bytes(plistlib.dumps(data))
    run_cmd(['launchctl', 'bootout', f'gui/{os.getuid()}', str(path)], timeout=10)
    p = run_cmd(['launchctl', 'bootstrap', f'gui/{os.getuid()}', str(path)], timeout=10)
    if p.returncode:
        raise RuntimeError('launchd bootstrap failed: ' + p.stderr)
    print(f'Installed daily scan at {hour:02d}:00: {path}')
    print('Scheduled run is report-only and never requests approval or deletes files.')


def uninstall_agent():
    path = HOME / 'Library' / 'LaunchAgents' / (LABEL + '.plist')
    if path.exists():
        run_cmd(['launchctl', 'bootout', f'gui/{os.getuid()}', str(path)], timeout=10)
        path.unlink()
    print('LaunchAgent removed. Logs, settings and files have been retained.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=DEFAULT_CONFIG)
    sub = parser.add_subparsers(dest='action', required=True)
    sub.add_parser('scan', help='Read-only preview and report (default recommended)')
    exe = sub.add_parser('execute', help='Interactive, explicitly approved cleanup')
    exe.add_argument('--approve-native', action='store_true', help='Also run pip purge and brew cleanup')
    inst = sub.add_parser('install', help='Install a daily read-only launchd agent')
    inst.add_argument('--hour', type=int, default=9)
    sub.add_parser('uninstall', help='Remove launchd agent')
    sub.add_parser('trend', help='Show recorded free-space history over time')
    args = parser.parse_args(argv)
    logger = setup_log()
    if args.action == 'uninstall':
        uninstall_agent()
        return 0
    if args.action == 'trend':
        show_trend()
        return 0
    cfg = config_load(args.config)
    if args.action == 'install':
        if not 0 <= args.hour <= 23:
            parser.error('--hour must be 0..23')
        install_agent(Path(__file__), args.config, args.hour)
        return 0
    start = disk_state()
    now = time.time()
    items = candidates(cfg, now)
    report = reports(cfg)
    total = sum(x['bytes'] for x in items)
    print(f'BEFORE: {start}')
    print(f'ELIGIBLE TRASH CANDIDATES: {len(items)} ({mib(total)})')
    for i, c in enumerate(items, 1):
        print(f' {i:3d}. [{c["category"]}] {mib(c["bytes"]):>12} {c["path"]}')
    print('\nREPORT-ONLY STORAGE (never removed by this tool):')
    for r in report:
        print(f' [{r["category"]}] {mib(r["bytes"]):>12} {r["path"]}')
    moved = []
    if args.action == 'execute':
        if not sys.stdin.isatty():
            print('REFUSED: execute requires an interactive terminal; scheduled tasks cannot delete.')
            return 2
        print('\nCAUTION: deleting a downloaded installer or cache can cause re-downloads.')
        for c in items:
            p = Path(c['path'])
            if c['requires_quit'] and app_running('Visual Studio Code|Code Helper'):
                print(f'SKIP (VS Code may be running): {p}')
                continue
            answer = input(f'Move to Trash? [{c["category"]}] {p.name} ({mib(c["bytes"])}) [y/N]: ').strip().lower()
            if answer != 'y':
                continue
            # Revalidate allowed paths and age after confirmation.
            category = c['category']
            parent = {'screenshots': HOME / 'Desktop', 'installers': HOME / 'Downloads',
                      'vscode_updater': HOME / 'Library' / 'Caches',
                      'vscode_vsix': HOME / 'Library' / 'Application Support' / 'Code' / 'CachedExtensionVSIXs'}[category]
            if not safe_child(p, parent) or not older(p, c['age_days'], now):
                print(f'SKIP changed/unsafe: {p}')
                continue
            if category == 'screenshots' and not (p.is_file() and SCREENSHOT.fullmatch(p.name)):
                continue
            if category == 'installers' and not (p.is_file() and p.suffix.lower() in INSTALLERS):
                continue
            if category == 'vscode_vsix' and not (p.is_file() and p.suffix.lower() == '.vsix'):
                continue
            try:
                trash_with_finder(p)
                moved.append(c)
                logger.info('TRASHED %s size=%s', p, c['bytes'])
                print(f'TRASHED {p}')
            except (OSError, RuntimeError, subprocess.TimeoutExpired) as e:
                logger.warning('FAILED %s: %s', p, e)
                print(f'ERROR {p}: {e}')
        if args.approve_native:
            ack = input('Type PURGE to run pip cache purge + Homebrew cleanup (may delete directly): ').strip()
            if ack == 'PURGE':
                native_ops(False, True, cfg['homebrew_prune_days'])
            else:
                print('Native cleanup skipped')
        else:
            print('Native cleanup is opt-in: execute --approve-native')
    else:
        print('\nNative-tool preview:')
        native_ops(True, False, cfg['homebrew_prune_days'])
    end = disk_state()
    payload = {'date': dt.datetime.now(dt.timezone.utc).isoformat(), 'mode': args.action,
               'before': start, 'after': end, 'trash_count': len(moved),
               'eligible_count': len(items), 'eligible_bytes': total,
               'recovered_free_gb': round(end['free_gb'] - start['free_gb'], 3),
               'report_only': report, 'candidates': items}
    report_path = BASE / ('latest-scan.json' if args.action == 'scan' else 'latest-cleanup.json')
    report_path.write_text(json.dumps(payload, indent=2), encoding='utf-8')
    append_history(payload)
    logger.info('mode=%s candidates=%s trashed=%s free_before=%s free_after=%s', args.action, len(items), len(moved), start['free_gb'], end['free_gb'])
    print(f'\nAFTER: {end} | Free space change: {payload["recovered_free_gb"]:+.3f} GB')
    print(f'Report: {report_path} | Log: {BASE / "manager.log"}')
    print('Files moved to Trash continue to consume space until Trash is emptied.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled; remaining files unchanged.', file=sys.stderr)
        sys.exit(130)
    except (OSError, ValueError, RuntimeError) as e:
        print(f'ERROR: {e}', file=sys.stderr)
        sys.exit(1)
