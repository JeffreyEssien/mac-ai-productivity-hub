#!/usr/bin/env python3
"""Conservative macOS storage report/cleanup. Python 3.9+, standard library only.

Scheduled runs ALWAYS report only. Interactive --execute allows allowlisted cleanup.
Application Support and browser/Spotify caches are intentionally report-only.

Trash candidates (rebuildable or leftover data only):
  screenshots, installers, VS Code updater/VSIX caches, app caches in
  ~/Library/Caches, the npm download cache, unfinished downloads, zips that are
  already unpacked, VS Code extension versions VS Code no longer uses, and
  node_modules in projects that haven't been touched for a while.
Report-only (with advice, never removed): large apps, chat/Docker app data,
  iCloud leftovers, iPhone backups and the same project copied to several places.
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
PARTIAL_SUFFIXES = {'.part', '.crdownload', '.download', '.partial'}
# Caches that belong to the system, are already handled elsewhere, or stay report-only.
CACHE_SKIP = set(REPORT_CACHE_NAMES) | {'com.microsoft.VSCode.ShipIt', 'Homebrew', 'pip', 'CloudKit'}
EXTENSION_DIR = re.compile(r'^[\w-]+\.[\w.-]+-\d+\.\d+\.\d+[\w.-]*$')
ENV_TEMPLATES = {'.env.example', '.env.sample', '.env.template', '.env.dist'}
DEFAULT_PROJECT_ROOTS = ('Documents', 'Developer', 'Desktop', 'Projects', 'code', 'iCloud Drive (Archive)')
PROJECT_SKIP_DIRS = {'node_modules', 'Library', 'Applications', '__pycache__', 'venv', '.venv', 'dist', 'build'}
PROJECT_MAX_DEPTH = 5
# App data that only the app itself can clean safely. (path under ~/Library, label, advice)
APP_DATA_REPORTS = (
    ('Group Containers/group.net.whatsapp.WhatsApp.shared', 'WhatsApp media',
     'In WhatsApp: Settings → Storage and Data → Manage Storage, then delete large videos.'),
    ('Group Containers/*.ru.keepcoder.Telegram', 'Telegram cache',
     'In Telegram: Settings → Data and Storage → Storage Usage → Clear Cache.'),
    ('Containers/com.docker.docker', 'Docker disk image',
     'If you are not using containers now, run: docker system prune -a'),
    ('Containers/com.microsoft.teams2', 'Microsoft Teams data',
     'Sign out of Teams and clear its cache from Teams settings.'),
)
# Optional settings, so older config.json files keep working.
OPTIONAL_DEFAULTS = {
    'cache_min_mb': 100,           # app caches smaller than this aren't listed
    'partial_download_days': 2,    # unfinished downloads untouched for this long
    'unpacked_zip_days': 7,        # zips whose folder is already unpacked next to them
    'node_modules_days': 30,       # project untouched for this long
    'large_app_gb': 2,             # report apps at least this big
    'app_data_report_gb': 1,       # report chat/Docker data at least this big
}


def opt(cfg, key):
    return cfg.get(key, OPTIONAL_DEFAULTS[key])


def config_load(path):
    with path.open(encoding='utf-8') as f:
        cfg = json.load(f)
    if not isinstance(cfg, dict):
        raise ValueError('Config must be an object')
    for key in ('screenshot_days', 'installer_days', 'vscode_cache_days', 'large_support_gb', 'homebrew_prune_days'):
        if not isinstance(cfg.get(key), int) or isinstance(cfg[key], bool) or cfg[key] < 1:
            raise ValueError(f'Config {key} must be a positive integer')
    for key in OPTIONAL_DEFAULTS:
        if key in cfg and (not isinstance(cfg[key], int) or isinstance(cfg[key], bool) or cfg[key] < 1):
            raise ValueError(f'Config {key} must be a positive integer')
    roots = cfg.get('project_roots')
    if roots is not None and (not isinstance(roots, list) or not all(isinstance(r, str) and r for r in roots)):
        raise ValueError('Config project_roots must be a list of folder names')
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


def du_bytes(path):
    """Disk space a folder really uses, via du (fast for big trees, never follows symlinks).

    du still prints a total when some files are unreadable; 0 means unknown.
    """
    if path.is_symlink():
        return 0
    try:
        res = run_cmd(['du', '-sk', str(path)], timeout=180)
    except (OSError, subprocess.TimeoutExpired):
        return 0
    lines = res.stdout.strip().splitlines()
    first = lines[-1].split('\t', 1)[0].strip() if lines else ''
    return int(first) * 1024 if first.isdigit() else 0


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


APPLICATIONS = Path('/Applications')
GENERIC_PROJECT_NAMES = {'app', 'my-app', 'web', 'frontend', 'backend', 'client', 'server', 'api',
                         'vite-project', 'next-app', 'my-next-app', 'nextjs', 'react-app', 'test', 'demo'}


def project_roots(cfg):
    """Folders to look for projects in. Always inside HOME and never ~/Library (iCloud sync, app data)."""
    roots = []
    library = HOME / 'Library'
    for name in cfg.get('project_roots') or DEFAULT_PROJECT_ROOTS:
        p = Path(name).expanduser()
        p = p if p.is_absolute() else HOME / p
        if p == HOME or HOME not in p.parents or p == library or library in p.parents:
            continue
        if p.is_dir() and not p.is_symlink() and p not in roots:
            roots.append(p)
    return roots


def find_projects(cfg):
    """Map each top-level JavaScript project (has package.json) to the node_modules folders inside it."""
    projects = {}
    for root in project_roots(cfg):
        for dirpath, dirs, files in os.walk(root, followlinks=False, onerror=lambda e: None):
            d = Path(dirpath)
            depth = len(d.relative_to(root).parts)
            if 'package.json' in files:
                owner = next((a for a in (d, *d.parents) if a in projects), None)
                if owner is None:
                    owner = d
                    projects[d] = []
                nm = d / 'node_modules'
                if 'node_modules' in dirs and nm.is_dir() and not nm.is_symlink():
                    projects[owner].append(nm)
            if depth >= PROJECT_MAX_DEPTH:
                dirs[:] = []
            else:
                dirs[:] = [x for x in dirs if not x.startswith('.') and x not in PROJECT_SKIP_DIRS
                           and not (d / x).is_symlink()]
    return projects


def project_last_touched(project):
    """Newest change time in a project's own files (ignores node_modules and .git contents)."""
    newest = 0.0
    seen = 0
    for extra in (project / '.git' / 'index', project / '.git' / 'HEAD'):
        try:
            newest = max(newest, extra.stat(follow_symlinks=False).st_mtime)
        except OSError:
            pass
    for dirpath, dirs, files in os.walk(project, followlinks=False, onerror=lambda e: None):
        d = Path(dirpath)
        try:
            newest = max(newest, d.stat(follow_symlinks=False).st_mtime)
        except OSError:
            pass
        depth = len(d.relative_to(project).parts)
        dirs[:] = [] if depth >= 3 else [x for x in dirs if x not in ('node_modules', '.git')
                                         and not (d / x).is_symlink()]
        for name in files:
            try:
                newest = max(newest, (d / name).stat(follow_symlinks=False).st_mtime)
            except OSError:
                continue
            seen += 1
            if seen >= 5000:
                return newest
    return newest


def has_real_env(project):
    try:
        return any(p.name.startswith('.env') and p.name not in ENV_TEMPLATES and p.is_file()
                   for p in project.iterdir())
    except OSError:
        return False


def vscode_extensions_in_use(ext_dir):
    """Folder names VS Code lists in extensions.json, or None when it can't be read (fail closed)."""
    try:
        data = json.loads((ext_dir / 'extensions.json').read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return None
    if not isinstance(data, list):
        return None
    used = set()
    for entry in data:
        if not isinstance(entry, dict):
            return None
        rel = entry.get('relativeLocation')
        loc = entry.get('location')
        if isinstance(rel, str):
            used.add(rel)
        elif isinstance(loc, dict) and isinstance(loc.get('path'), str):
            used.add(Path(loc['path']).name)
        elif isinstance(loc, str):
            used.add(Path(loc).name)
    return used or None


def candidates(cfg, now, with_sizes=True):
    """Everything the tool may move to Trash after approval.

    with_sizes=False skips measuring (used to re-check a single item quickly). It can
    only add items that are under a size threshold; every path rule still applies.
    """
    sz = size_bytes if with_sizes else (lambda p: 0)
    dsz = du_bytes if with_sizes else (lambda p: 0)
    result = []

    def add(category, p, size, age_days=0, requires_quit=None, **extra):
        result.append({'category': category, 'path': str(p), 'bytes': size, 'age_days': age_days,
                       'requires_quit': requires_quit, **extra})

    desktop = HOME / 'Desktop'
    downloads = HOME / 'Downloads'
    caches = HOME / 'Library' / 'Caches'
    code = HOME / 'Library' / 'Application Support' / 'Code'
    if desktop.is_dir() and not desktop.is_symlink():
        for p in desktop.iterdir():
            try:
                if safe_child(p, desktop) and p.is_file() and SCREENSHOT.fullmatch(p.name) and older(p, cfg['screenshot_days'], now):
                    add('screenshots', p, sz(p), cfg['screenshot_days'])
            except OSError:
                continue
    if downloads.is_dir() and not downloads.is_symlink():
        for p in downloads.iterdir():
            try:
                if not safe_child(p, downloads):
                    continue
                suffix = p.suffix.lower()
                if p.is_file() and suffix in INSTALLERS and older(p, cfg['installer_days'], now):
                    add('installers', p, sz(p), cfg['installer_days'])
                elif (suffix in PARTIAL_SUFFIXES and (p.is_file() or (p.is_dir() and suffix == '.download'))
                        and older(p, opt(cfg, 'partial_download_days'), now)):
                    add('partial_download', p, dsz(p) if p.is_dir() else sz(p), opt(cfg, 'partial_download_days'))
                elif suffix == '.zip' and p.is_file() and older(p, opt(cfg, 'unpacked_zip_days'), now):
                    unpacked = downloads / p.stem
                    if unpacked.is_dir() and not unpacked.is_symlink():
                        add('unpacked_zip', p, sz(p), opt(cfg, 'unpacked_zip_days'))
            except OSError:
                continue
    # VSCode updater cache, or aged top-level VSIX installer archives. Avoid clearing extension settings.
    shipit = caches / 'com.microsoft.VSCode.ShipIt'
    try:
        if safe_child(shipit, caches) and older(shipit, cfg['vscode_cache_days'], now):
            add('vscode_updater', shipit, sz(shipit), cfg['vscode_cache_days'], VS_CODE)
    except OSError:
        pass
    vsix = code / 'CachedExtensionVSIXs'
    if vsix.is_dir() and not vsix.is_symlink():
        for p in vsix.iterdir():
            try:
                if (safe_child(p, vsix) and p.is_file() and p.suffix.lower() == '.vsix'
                        and older(p, cfg['vscode_cache_days'], now)):
                    add('vscode_vsix', p, sz(p), cfg['vscode_cache_days'], VS_CODE)
            except OSError:
                continue
    # Per-app caches. Apps rebuild these; the app itself should be closed first.
    min_cache = opt(cfg, 'cache_min_mb') * 1024 ** 2
    if caches.is_dir() and not caches.is_symlink():
        for p in caches.iterdir():
            try:
                if (safe_child(p, caches) and p.is_dir() and not p.name.startswith(('com.apple.', '.'))
                        and p.name not in CACHE_SKIP):
                    size = dsz(p)
                    if not with_sizes or size >= min_cache:
                        add('app_cache', p, size)
            except OSError:
                continue
    npm_root = HOME / '.npm'
    npm_cache = npm_root / '_cacache'
    try:
        if safe_child(npm_cache, npm_root) and npm_cache.is_dir() and not npm_root.is_symlink():
            size = dsz(npm_cache)
            if not with_sizes or size >= min_cache:
                add('npm_cache', npm_cache, size)
    except OSError:
        pass
    # Extension versions VS Code itself no longer lists (left behind after updates).
    ext = HOME / '.vscode' / 'extensions'
    if ext.is_dir() and not ext.is_symlink():
        used = vscode_extensions_in_use(ext)
        if used:
            for p in ext.iterdir():
                try:
                    if (safe_child(p, ext) and p.is_dir() and EXTENSION_DIR.fullmatch(p.name)
                            and p.name not in used):
                        add('vscode_old_extension', p, dsz(p), 0, VS_CODE)
                except OSError:
                    continue
    # node_modules in projects nobody has touched for a while. Source code and .env stay.
    days = opt(cfg, 'node_modules_days')
    for project, folders in find_projects(cfg).items():
        if not folders:
            continue
        try:
            if project_last_touched(project) >= now - days * 86400:
                continue
        except OSError:
            continue
        for nm in folders:
            if nm.name == 'node_modules' and nm.is_dir() and not nm.is_symlink() and (nm.parent / 'package.json').is_file():
                add('node_modules', nm, dsz(nm), days, project=str(project))
    return sorted(result, key=lambda x: x['bytes'], reverse=True)


def still_eligible(item, cfg, now):
    """Re-run the allowlist for one previously listed item, without measuring sizes."""
    return any(x['path'] == item['path'] and x['category'] == item['category']
               for x in candidates(cfg, now, with_sizes=False))


def _report(records, category, p, size, advice, label=None, **extra):
    rec = {'category': category, 'path': str(p), 'bytes': size, 'policy': 'report_only', 'advice': advice}
    if label:
        rec['label'] = label
    rec.update(extra)
    records.append(rec)


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
                    advice = ('Clear it from inside the app, not by deleting the folder.'
                              if group == 'application_support' else 'Clear it from the browser or app settings.')
                    _report(records, group, p, sz, advice)
    # Big apps and games: only you know which ones you still use.
    min_app = opt(cfg, 'large_app_gb') * 1e9
    for apps in (APPLICATIONS, HOME / 'Applications'):
        if not apps.is_dir():
            continue
        try:
            entries = list(apps.iterdir())
        except OSError:
            continue
        for p in entries:
            if p.name.startswith('.') or p.is_symlink() or not p.is_dir():
                continue
            size = du_bytes(p)
            if size >= min_app:
                _report(records, 'large_app', p, size,
                        'Uninstall it if you no longer use it (drag to Trash or use its uninstaller).')
    # App data only the app can clean safely.
    library = HOME / 'Library'
    min_data = opt(cfg, 'app_data_report_gb') * 1e9
    for pattern, label, advice in APP_DATA_REPORTS:
        for p in sorted(library.glob(pattern)):
            if p.is_dir() and not p.is_symlink():
                size = du_bytes(p)
                if size >= min_data:
                    _report(records, 'app_data', p, size, advice, label=label)
    # iCloud leftovers: local copies macOS keeps after iCloud Drive is turned off or re-synced.
    archive = HOME / 'iCloud Drive (Archive)'
    if archive.is_dir() and not archive.is_symlink():
        _report(records, 'icloud_archive', archive, du_bytes(archive),
                'A local copy macOS made when iCloud Drive was turned off. Check the files are in iCloud, then delete what you no longer need.')
    cloud = library / 'CloudStorage'
    try:
        cloud_entries = list(cloud.iterdir()) if cloud.is_dir() else []
    except OSError:
        cloud_entries = []
    for p in cloud_entries:
        if p.name.startswith('iCloudDrive-iCloudDrive (') and not p.is_symlink():
            size = du_bytes(p)
            if size >= 100 * 1024 ** 2:
                _report(records, 'icloud_leftover', p, size,
                        'Left over from an earlier iCloud Drive sync. Make sure iCloud Drive is fully synced, then restart; if it stays, remove it in Finder.')
    # iPhone and iPad backups. Measuring them needs Full Disk Access.
    backups = support / 'MobileSync' / 'Backup'
    try:
        has_backups = any(backups.iterdir())
        size = du_bytes(backups) if has_backups else 0
        if has_backups:
            _report(records, 'ios_backups', backups, size,
                    'Finder → your iPhone → Manage Backups, then delete old backups.')
    except PermissionError:
        _report(records, 'ios_backups', backups, 0,
                'Could not measure without Full Disk Access. Check Finder → your iPhone → Manage Backups.',
                size_known=False)
    except OSError:
        pass
    # The same project copied to several places.
    groups = {}
    for project in find_projects(cfg):
        key = None
        try:
            data = json.loads((project / 'package.json').read_text(encoding='utf-8'))
            if isinstance(data, dict) and isinstance(data.get('name'), str):
                key = data['name'].strip().lower()
        except (OSError, ValueError):
            pass
        key = key or project.name.lower()
        if len(key) >= 3 and key not in GENERIC_PROJECT_NAMES:
            groups.setdefault(key, []).append(project)
    for key, copies in groups.items():
        if len(copies) < 2:
            continue
        for project in copies:
            env = has_real_env(project)
            touched = dt.datetime.fromtimestamp(project_last_touched(project)).strftime('%Y-%m-%d')
            advice = (f'Same project ("{key}") found in {len(copies)} places. Keep the one you use; '
                      'copy its .env files into it before deleting the others.')
            _report(records, 'duplicate_project', project, du_bytes(project), advice,
                    project_name=key, has_env=env, last_touched=touched)
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
    return {'screenshot_days': 30, 'installer_days': 60, 'vscode_cache_days': 30, 'large_support_gb': 1,
            'homebrew_prune_days': 30, **OPTIONAL_DEFAULTS}


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
        size = mib(r['bytes']) if r.get('size_known', True) else 'unknown'
        env = ''
        if r['category'] == 'duplicate_project':
            env = f' (has .env: {"yes" if r["has_env"] else "no"}, last changed {r["last_touched"]})'
        print(f' [{r.get("label", r["category"])}] {size:>12} {r["path"]}{env}')
        print(f'      → {r["advice"]}')
    moved = []
    if args.action == 'execute':
        if not sys.stdin.isatty():
            print('REFUSED: execute requires an interactive terminal; scheduled tasks cannot delete.')
            return 2
        print('\nCAUTION: deleting a downloaded installer or cache can cause re-downloads.')
        print('Quit an app before removing its cache. Run npm install in a project to restore node_modules.')
        for c in items:
            p = Path(c['path'])
            if c['requires_quit'] and app_running('Visual Studio Code|Code Helper'):
                print(f'SKIP (VS Code may be running): {p}')
                continue
            answer = input(f'Move to Trash? [{c["category"]}] {p.name} ({mib(c["bytes"])}) [y/N]: ').strip().lower()
            if answer != 'y':
                continue
            # Re-run every allowlist rule (location, type, age, symlinks) after confirmation.
            if not still_eligible(c, cfg, time.time()):
                print(f'SKIP changed/unsafe: {p}')
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
