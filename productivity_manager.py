#!/usr/bin/env python3
"""macOS Notes -> Reminders task bridge. Python 3.9+. macOS only.

Task source is a plain-text Notes note. Only an explicitly named iCloud Notes account
is accepted. Reminders list must already exist in iCloud. No auto deletion, no overwrite
of Notes content, and no unattended task modifications.
"""
import argparse
import datetime as dt
from html.parser import HTMLParser
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path
import plistlib
import re
import subprocess
import sys
import uuid

BASE = Path.home() / '.mac-storage-manager'
CFG = Path(__file__).with_name('productivity_config.json')
PREFIX = 'com.local.mac-productivity-manager'
LINE = re.compile(r'^(TASK-[A-Za-z0-9_-]{4,40})\s*\|\s*(.*?)\s*\|\s*(\d{4}-\d\d-\d\d \d\d:\d\d)\s*\|\s*(OPEN|DONE)\s*$', re.I)
MARKER_PREFIX = 'MAC-STORAGE-MANAGER-TASK-ID:'

class TextFromHTML(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
    def handle_starttag(self, tag, attrs):
        if tag in {'p','div','li','br','h1','h2','h3'}:
            self.parts.append('\n')
    def handle_endtag(self, tag):
        if tag in {'p','div','li','h1','h2','h3'}:
            self.parts.append('\n')
    def handle_data(self, data):
        self.parts.append(data)
    def text(self):
        return ''.join(self.parts)

def parse_note(html):
    p = TextFromHTML(); p.feed(html)
    tasks = []
    errors = []
    seen = set()
    for index, raw in enumerate(p.text().splitlines(), 1):
        line = raw.strip().replace('\xa0',' ')
        if not line or line.startswith(('#', 'HOW TO', 'FORMAT:', 'EXAMPLE:')):
            continue
        if not line.upper().startswith('TASK-'):  # case-insensitive, matching LINE
            continue
        m = LINE.fullmatch(line)
        if not m:
            errors.append(f'Line {index}: invalid TASK format: {line[:100]}')
            continue
        task_id, title, when, status = m.groups()
        task_id = task_id.upper()
        if not title or len(title) > 200 or '\n' in title:
            errors.append(f'Line {index}: title missing or over 200 characters')
            continue
        if task_id in seen:
            errors.append(f'Line {index}: duplicate ID {task_id}')
            continue
        try:
            due = dt.datetime.strptime(when, '%Y-%m-%d %H:%M')
        except ValueError:
            errors.append(f'Line {index}: invalid date {when}')
            continue
        seen.add(task_id)
        tasks.append({'id':task_id,'title':title,'due':due,'status':status.upper()})
    if len(tasks) > 100:
        errors.append('Maximum 100 tasks per note')
    return tasks, errors

def applescript(script, *args, timeout=90):
    completed = subprocess.run(['osascript','-e',script,*map(str,args)],capture_output=True,text=True,timeout=timeout,check=False)
    if completed.returncode:
        raise RuntimeError((completed.stderr or completed.stdout).strip() or 'osascript failed')
    return completed.stdout.strip()

# Exact matching and iCloud requirement: never silently fall back to local accounts.
NOTES_FETCH = '''on run argv
    set n to item 1 of argv
    tell application "Notes"
        if not (exists account "iCloud") then error "Notes iCloud account missing; enable iCloud Notes"
        set a to account "iCloud"
        set foundNotes to (every note of a whose name is n)
        if (count foundNotes) is not 1 then error "Expected exactly one iCloud note named " & n & "; found " & (count foundNotes)
        return body of item 1 of foundNotes
    end tell
end run'''

# Only opens an existing note; create the note in Notes yourself to ensure iCloud storage.
NOTES_OPEN = '''on run argv
    set n to item 1 of argv
    tell application "Notes"
        activate
        if not (exists account "iCloud") then error "iCloud Notes account missing"
        set matches to (every note of account "iCloud" whose name is n)
        if (count matches) is not 1 then error "Create exactly one iCloud note named " & n
        show item 1 of matches
    end tell
end run'''

REMINDER_SYNC = '''on run argv
    set listName to item 1 of argv
    set taskID to item 2 of argv
    set taskTitle to item 3 of argv
    set dateString to item 4 of argv
    set marker to "MAC-STORAGE-MANAGER-TASK-ID:" & taskID
    set y to (text 1 thru 4 of dateString) as integer
    set m to (text 6 thru 7 of dateString) as integer
    set dd to (text 9 thru 10 of dateString) as integer
    set hh to (text 12 thru 13 of dateString) as integer
    set mm to (text 15 thru 16 of dateString) as integer
    set dueValue to current date
    set day of dueValue to 1
    set year of dueValue to y
    set month of dueValue to m
    set day of dueValue to dd
    set hours of dueValue to hh
    set minutes of dueValue to mm
    set seconds of dueValue to 0
    tell application "Reminders"
        if not (exists list listName) then error "Create the iCloud Reminders list first: " & listName
        set targetList to list listName
        set matches to {}
        repeat with r in reminders of targetList
            try
                if (body of r contains marker) then set end of matches to r
            end try
        end repeat
        if (count matches) > 1 then error "Duplicate task identifier in Reminders: " & taskID
        if (count matches) = 1 then
            set r to item 1 of matches
            if completed of r then return "completed-skip"
            if name of r is not taskTitle then set name of r to taskTitle
            set due date of r to dueValue
            set remind me date of r to dueValue
            return "updated"
        else
            make new reminder at end of reminders of targetList with properties {name:taskTitle, body:marker, due date:dueValue, remind me date:dueValue}
            return "created"
        end if
    end tell
end run'''

REMINDER_COMPLETE = '''on run argv
    set listName to item 1 of argv
    set marker to "MAC-STORAGE-MANAGER-TASK-ID:" & item 2 of argv
    tell application "Reminders"
        if not (exists list listName) then error "Reminders list missing"
        set matches to {}
        repeat with r in reminders of list listName
            try
                if (body of r contains marker) then set end of matches to r
            end try
        end repeat
        if (count matches) > 1 then error "Duplicate task ID; no changes made"
        if (count matches) = 0 then return "not-found"
        set completed of (item 1 of matches) to true
        return "completed"
    end tell
end run'''

REMINDER_STATUS = '''on run argv
    set listName to item 1 of argv
    set marker to "MAC-STORAGE-MANAGER-TASK-ID:" & item 2 of argv
    tell application "Reminders"
        if not (exists list listName) then error "Reminders list missing"
        set matches to {}
        repeat with r in reminders of list listName
            try
                if (body of r contains marker) then set end of matches to r
            end try
        end repeat
        if (count matches) = 0 then return "not-found"
        if (count matches) > 1 then error "Duplicate task identifier in Reminders"
        if completed of (item 1 of matches) then return "completed"
        return "open"
    end tell
end run'''

# Writes back the SAME note body with only status tokens changed; formatting is preserved.
NOTES_SET_BODY = '''on run argv
    set n to item 1 of argv
    set newBody to item 2 of argv
    tell application "Notes"
        if not (exists account "iCloud") then error "Notes iCloud account missing"
        set matches to (every note of account "iCloud" whose name is n)
        if (count matches) is not 1 then error "Expected exactly one iCloud note named " & n
        set body of item 1 of matches to newBody
    end tell
end run'''

PROMPT = '''on run argv
    set modeName to item 1 of argv
    if modeName is "morning" then
        set msg to "Good morning. Open your iCloud planning note, add/edit tasks, then sync to Apple Reminders?"
    else
        set msg to "Evening review: update your iCloud task note and mark completed reminders. Open your note now?"
    end if
    try
        set answer to display dialog msg buttons {"Later", "Open Notes", "Sync Now"} default button "Open Notes" with title "Daily Planning"
        return button returned of answer
    on error number -128
        return "Later"
    end try
end run'''


def notify_failure(summary):
    """Best-effort macOS notification so headless launchd failures aren't silent.
    Never raises: a broken notification must not mask the original error."""
    if sys.platform != 'darwin':
        return
    try:
        subprocess.run(['osascript', '-e',
            'on run argv\ndisplay notification (item 1 of argv) with title "Mac Planner Sync failed"\nend run',
            summary[:200]], capture_output=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        pass


def load_config(path=CFG):
    cfg = json.loads(path.read_text(encoding='utf-8'))
    if not isinstance(cfg,dict): raise ValueError('Configuration must be JSON object')
    for k in ('note_title','reminders_list'):
        if not isinstance(cfg.get(k),str) or not cfg[k].strip(): raise ValueError(f'Invalid {k}')
    for k in ('morning_hour','evening_hour','minute'):
        if not isinstance(cfg.get(k),int) or not 0 <= cfg[k] <= (59 if k == 'minute' else 23):
            raise ValueError(f'Invalid {k}')
    return cfg

def logger():
    BASE.mkdir(exist_ok=True,parents=True,mode=0o700)
    log = logging.getLogger('productivity')
    log.setLevel(logging.INFO)
    if not log.handlers:
        h = RotatingFileHandler(BASE/'productivity.log',maxBytes=1_000_000,backupCount=3)
        h.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
        log.addHandler(h)
    return log

def scan(cfg):
    html = applescript(NOTES_FETCH,cfg['note_title'])
    tasks,errors = parse_note(html)
    if errors: raise ValueError('Refusing sync until all invalid entries are fixed:\n'+'\n'.join(errors))
    return tasks

def synchronize(cfg,apply=False):
    tasks = scan(cfg)
    actions = []
    for t in tasks:
        if t['status']=='DONE':
            if apply: result=applescript(REMINDER_COMPLETE,cfg['reminders_list'],t['id'])
            else: result='would mark complete (if found)'
        else:
            if apply: result=applescript(REMINDER_SYNC,cfg['reminders_list'],t['id'],t['title'],t['due'].strftime('%Y-%m-%d %H:%M'))
            else: result='would create/update (or skip if completed)'
        actions.append({'id':t['id'],'title':t['title'],'due':t['due'].isoformat(timespec='minutes'),'action':result})
    return actions

def set_note_status(html, task_id, new_status):
    """Flip the trailing OPEN/DONE token for one task inside the note HTML.

    Matches only within a single text node ([^<] never crosses a tag) and only
    the status that ends that node, so surrounding formatting is untouched.
    Returns (new_html, replacement_count); callers treat count != 1 as ambiguous.
    """
    pattern = re.compile(r'(' + re.escape(task_id) + r'\b[^<]*?\|\s*)(OPEN|DONE)(\s*)(?=<|$)', re.IGNORECASE)
    new_html, count = pattern.subn(lambda m: m.group(1) + new_status + m.group(3), html)
    return new_html, count


def reflect(cfg, apply=False):
    """Reverse sync: when a reminder has been completed (e.g. on iPhone), mark the
    matching note task DONE. Only ever flips OPEN -> DONE, never the other way."""
    html = applescript(NOTES_FETCH, cfg['note_title'])
    tasks, errors = parse_note(html)
    if errors:
        raise ValueError('Refusing reflect until invalid entries are fixed:\n' + '\n'.join(errors))
    planned = []
    new_html = html
    for t in tasks:
        if t['status'] != 'OPEN':
            continue
        status = applescript(REMINDER_STATUS, cfg['reminders_list'], t['id'])
        if status != 'completed':
            continue
        updated, count = set_note_status(new_html, t['id'], 'DONE')
        if count == 1:
            new_html = updated
            planned.append({'id': t['id'], 'title': t['title'], 'action': 'mark DONE in note'})
        else:
            planned.append({'id': t['id'], 'title': t['title'], 'action': f'SKIP (ambiguous match x{count})'})
    changed = [p for p in planned if p['action'] == 'mark DONE in note']
    if apply and changed:
        applescript(NOTES_SET_BODY, cfg['note_title'], new_html)
    return planned


def prompt(cfg, mode):
    choice=applescript(PROMPT,mode)
    if choice == 'Open Notes':
        applescript(NOTES_OPEN,cfg['note_title'])
    elif choice == 'Sync Now':
        operations=synchronize(cfg,apply=True)
        applescript('on run argv\n display dialog (item 1 of argv) buttons {"OK"} default button "OK" with title "Planner Sync"\nend run', f'{len(operations)} task(s) checked in Apple Reminders.')
    return choice


def launcher_source(python, script):
    """Build the AppleScript source for the double-clickable sync launcher."""
    import shlex
    command=' '.join([shlex.quote(str(Path(python).resolve())), shlex.quote(str(script)), 'sync', '--apply'])
    # Shell escape is performed above; escape for AppleScript string syntax too.
    command=command.replace('\\','\\\\').replace('"','\\"')
    return f'''try
    set resultMessage to do shell script "{command}"
    display dialog resultMessage buttons {{"OK"}} default button "OK" with title "Planner Sync"
on error errText
    display dialog "Sync failed: " & errText buttons {{"OK"}} default button "OK" with icon caution
end try'''

def install_gui_launcher(python=sys.executable):
    """Compile a native double-clickable AppleScript app; no Terminal window."""
    if sys.platform != 'darwin': raise RuntimeError('macOS required')
    app_dir=Path.home()/'Applications'
    app_dir.mkdir(parents=True,exist_ok=True)
    target=app_dir/'Mac Planner Sync.app'
    source=launcher_source(python, Path(__file__).resolve())
    result=subprocess.run(['osacompile','-o',str(target),'-e',source],capture_output=True,text=True)
    if result.returncode: raise RuntimeError(result.stderr)
    return target

def install(cfg, python=sys.executable):
    if sys.platform!='darwin': raise RuntimeError('Install is supported only on macOS')
    agents=Path.home()/'Library'/'LaunchAgents'; agents.mkdir(parents=True,exist_ok=True)
    script=Path(__file__).resolve()
    paths=[]
    for period,hour in [('morning',cfg['morning_hour']),('evening',cfg['evening_hour'])]:
        label=f'{PREFIX}.{period}'
        dest=agents/f'{label}.plist'
        data={'Label':label,'ProgramArguments':[str(Path(python).resolve()),str(script),'prompt',period],
              'StartCalendarInterval':{'Hour':hour,'Minute':cfg['minute']},'RunAtLoad':False,
              'StandardOutPath':str(BASE/f'{period}.out.log'), 'StandardErrorPath':str(BASE/f'{period}.err.log')}
        dest.write_bytes(plistlib.dumps(data))
        subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(dest)],capture_output=True,check=False)
        res=subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(dest)],capture_output=True,text=True)
        if res.returncode: raise RuntimeError(f'{dest}: {res.stderr}')
        paths.append(str(dest))
    label=f'{PREFIX}.sync'
    dest=agents/f'{label}.plist'
    data={'Label':label,'ProgramArguments':[str(Path(python).resolve()),str(script),'sync','--apply'],
          'StartInterval':900,'RunAtLoad':False,
          'StandardOutPath':str(BASE/'sync.out.log'),'StandardErrorPath':str(BASE/'sync.err.log')}
    dest.write_bytes(plistlib.dumps(data))
    subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(dest)],capture_output=True,check=False)
    res=subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(dest)],capture_output=True,text=True)
    if res.returncode: raise RuntimeError(f'{dest}: {res.stderr}')
    paths.append(str(dest))
    paths.append(str(install_gui_launcher(python)))
    return paths

def uninstall():
    agents=Path.home()/'Library'/'LaunchAgents'
    for period in ('morning','evening','sync'):
        path=agents/f'{PREFIX}.{period}.plist'
        if path.exists():
            subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(path)],capture_output=True,check=False)
            path.unlink()

def main():
    ap=argparse.ArgumentParser(description='iCloud Notes -> Apple Reminders planner')
    ap.add_argument('command',choices=['scan','sync','reflect','prompt','install','uninstall'])
    ap.add_argument('period',nargs='?',choices=['morning','evening'])
    ap.add_argument('--apply',action='store_true',help='Actually create/update reminders; default is preview')
    args=ap.parse_args()
    cfg=load_config(); log=logger()
    try:
        if args.command in ('scan','sync'):
            operations=synchronize(cfg,apply=(args.command=='sync' and args.apply))
            for op in operations: print(f"{op['id']} | {op['title']} | {op['due']} | {op['action']}")
            print(f'{len(operations)} task(s); '+('changes applied' if args.command=='sync' and args.apply else 'PREVIEW ONLY'))
            log.info('%s apply=%s count=%s',args.command,args.apply,len(operations))
        elif args.command=='reflect':
            results=reflect(cfg,apply=args.apply)
            for r in results: print(f"{r['id']} | {r['title']} | {r['action']}")
            done=sum(1 for r in results if r['action']=='mark DONE in note')
            print(f'{done} completion(s) reflected; '+('note updated' if args.apply and done else 'PREVIEW ONLY'))
            log.info('reflect apply=%s completions=%s',args.apply,done)
        elif args.command=='prompt':
            if not args.period: ap.error('prompt requires morning or evening')
            result=prompt(cfg,args.period); log.info('prompt %s: %s',args.period,result)
        elif args.command=='install':
            print('\n'.join(install(cfg))); print('Schedules installed. Notes and Reminders must be enabled in iCloud.')
        elif args.command=='uninstall': uninstall(); print('Planner schedules removed. Notes and reminders untouched.')
    except Exception as e:
        log.exception('Planner failed'); print(f'ERROR: {e}',file=sys.stderr)
        # Only sync runs headless under launchd; alert the user so a persistently
        # broken note or missing Reminders list doesn't fail silently every cycle.
        if args.command == 'sync' and args.apply:
            notify_failure(str(e))
        return 1
    return 0

if __name__=='__main__': raise SystemExit(main())
