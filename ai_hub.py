#!/usr/bin/env python3
"""Text-only macOS productivity hub. Python 3.9+, stdlib. Reminders is authoritative.
Uses macOS AppleScript and optional user-built Apple Intelligence Shortcut.
Scheduled check-ins are read-only and do not change reminders or cleanup storage.
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
import uuid

ROOT = Path(__file__).resolve().parent
STATE = Path.home() / '.mac-storage-manager'
LABEL = 'com.local.mac-ai-hub'
CONFIG = ROOT / 'hub_config.json'
FIELD = chr(31)
RECORD = chr(30)

READ_REMINDERS = r'''on run argv
    set fieldSep to ASCII character 31
    set recSep to ASCII character 30
    set resultText to ""
    tell application "Reminders"
        repeat with li in lists
            set listTitle to name of li
            repeat with rr in reminders of li
                try
                    set doneFlag to completed of rr
                    set reminderTitle to name of rr
                    set reminderIdentifier to id of rr
                    set dateText to ""
                    try
                        set dueValue to due date of rr
                        if dueValue is not missing value then
                            set yy to year of dueValue as integer
                            set mo to month of dueValue as integer
                            set da to day of dueValue as integer
                            set hh to hours of dueValue as integer
                            set mi to minutes of dueValue as integer
                            set dateText to (yy as string) & "-" & text -2 thru -1 of ("0" & (mo as string)) & "-" & text -2 thru -1 of ("0" & (da as string)) & " " & text -2 thru -1 of ("0" & (hh as string)) & ":" & text -2 thru -1 of ("0" & (mi as string))
                        end if
                    end try
                    set safeTitle to my scrub(reminderTitle)
                    set safeList to my scrub(listTitle)
                    set safeID to my scrub(reminderIdentifier as string)
                    set resultText to resultText & safeID & fieldSep & safeList & fieldSep & safeTitle & fieldSep & (doneFlag as string) & fieldSep & dateText & recSep
                end try
            end repeat
        end repeat
    end tell
    return resultText
end run
on scrub(t)
    set AppleScript's text item delimiters to {ASCII character 31, ASCII character 30, return, linefeed}
    set xs to text items of (t as string)
    set AppleScript's text item delimiters to " "
    set cleanText to xs as string
    set AppleScript's text item delimiters to ""
    return cleanText
end scrub'''

ADD_REMINDER = r'''on run argv
    set listName to item 1 of argv
    set taskTitle to item 2 of argv
    set dueString to item 3 of argv
    set marker to item 4 of argv
    tell application "Reminders"
        if not (exists list listName) then error "Create the iCloud Reminders list first: " & listName
        set targetList to list listName
        repeat with r in reminders of targetList
            try
                if body of r contains marker then return "already-exists"
            end try
            if (name of r) is taskTitle and (completed of r) is false then return "already-exists"
        end repeat
        if dueString is "" then
            make new reminder at end of reminders of targetList with properties {name:taskTitle, body:marker}
        else
            set y to (text 1 thru 4 of dueString) as integer
            set m to (text 6 thru 7 of dueString) as integer
            set dd to (text 9 thru 10 of dueString) as integer
            set hh to (text 12 thru 13 of dueString) as integer
            set mm to (text 15 thru 16 of dueString) as integer
            set dueValue to current date
            set day of dueValue to 1
            set year of dueValue to y
            set month of dueValue to m
            set day of dueValue to dd
            set hours of dueValue to hh
            set minutes of dueValue to mm
            set seconds of dueValue to 0
            make new reminder at end of reminders of targetList with properties {name:taskTitle, body:marker, due date:dueValue, remind me date:dueValue}
        end if
        return "created"
    end tell
end run'''

DIALOG = r'''on run argv
    set promptText to item 1 of argv
    set defaultText to item 2 of argv
    try
        set response to display dialog promptText default answer defaultText buttons {"Cancel", "Continue"} default button "Continue" with title "Mac Productivity Hub"
        return text returned of response
    on error number -128
        return "__CANCEL__"
    end try
end run'''

READ_LIST_NAMES = r'''on run argv
    set separator to ASCII character 30
    set outputText to ""
    tell application "Reminders"
        repeat with li in lists
            set outputText to outputText & (name of li) & separator
        end repeat
    end tell
    return outputText
end run'''

CHOOSE_LIST = r'''on run argv
    set rawNames to item 1 of argv
    set defaultName to item 2 of argv
    set AppleScript's text item delimiters to ASCII character 30
    set namesList to text items of rawNames
    set AppleScript's text item delimiters to ""
    if (count of namesList) is 0 then return "__CANCEL__"
    if defaultName is in namesList then
        set selectedName to choose from list namesList with prompt "Save in which Reminders list? Prefer an iCloud list for iPhone sync." default items {defaultName} with title "Mac Productivity Hub"
    else
        set selectedName to choose from list namesList with prompt "Save in which Reminders list? Prefer an iCloud list for iPhone sync." with title "Mac Productivity Hub"
    end if
    if selectedName is false then return "__CANCEL__"
    return item 1 of selectedName
end run'''

NOTICE = r'''on run argv
    display notification (item 1 of argv) with title (item 2 of argv)
end run'''


def config():
    cfg = json.loads(CONFIG.read_text())
    if not isinstance(cfg.get('reminders_list'), str) or not cfg['reminders_list'].strip():
        raise ValueError('reminders_list must be set')
    for key in ('morning', 'midday', 'evening'):
        value=cfg.get(key)
        if not isinstance(value,str) or not re.fullmatch(r'(?:[01]\d|2[0-3]):[0-5]\d',value):
            raise ValueError('Invalid HH:MM: '+key)
    return cfg


def log():
    STATE.mkdir(parents=True,exist_ok=True,mode=0o700)
    logger=logging.getLogger('ai_hub');logger.setLevel(logging.INFO)
    if not logger.handlers:
        handler=RotatingFileHandler(STATE/'ai_hub.log',maxBytes=1_000_000,backupCount=4)
        handler.setFormatter(logging.Formatter('%(asctime)s %(levelname)s %(message)s'))
        logger.addHandler(handler)
    return logger


def osa(script,*args,timeout=120):
    if sys.platform != 'darwin': raise RuntimeError('Apple integration requires macOS')
    p=subprocess.run(['osascript','-e',script,*map(str,args)],capture_output=True,text=True,timeout=timeout)
    if p.returncode: raise RuntimeError((p.stderr or p.stdout).strip())
    return p.stdout.rstrip('\n')


def parse_records(raw):
    out=[]
    for record in raw.split(RECORD):
        if not record.strip(): continue
        parts=record.split(FIELD)
        if len(parts)!=5: continue
        ident,list_name,title,completed,when=parts
        try: due=dt.datetime.strptime(when,'%Y-%m-%d %H:%M') if when else None
        except ValueError: due=None
        out.append({'id':ident,'list':list_name,'title':title,'completed':completed.lower()=='true','due':due})
    return out


def reminders():
    return parse_records(osa(READ_REMINDERS))


def classify(items,now=None):
    now=now or dt.datetime.now()
    today=now.date()
    pending=[t for t in items if not t['completed']]
    overdue=sorted([t for t in pending if t['due'] and t['due']<now],key=lambda t:t['due'])
    upcoming=sorted([t for t in pending if t['due'] and t['due']>=now and t['due'].date()==today],key=lambda t:t['due'])
    undated=[t for t in pending if not t['due']]
    later=[t for t in pending if t['due'] and t['due'].date()>today]
    return {'overdue':overdue,'today':upcoming,'undated':undated,'later':later,'completed':len(items)-len(pending),'open':len(pending)}


def brief(items,period,limit=8):
    buckets=classify(items)
    lines=[f'{period.title()} | {buckets["open"]} open · {len(buckets["overdue"])} overdue · {len(buckets["today"])} due later today']
    for key,label in [('overdue','OVERDUE'),('today','TODAY'),('later','UPCOMING'),('undated','NO DUE DATE')]:
        if buckets[key]:
            lines.append(label+':')
            for item in buckets[key][:limit]:
                lines.append(' • '+item['title']+(f' ({item["due"]:%b %d %H:%M})' if item['due'] else '')+' ['+item['list']+']')
    if len(lines)==1:lines.append('Nothing urgent found. Review your lists for future tasks.')
    return '\n'.join(lines)


def interactive_add(cfg):
    """Legacy text dialogs; the native AppKit app offers a date picker instead."""
    title=osa(DIALOG,'What do you need to do? (Type the task title)','')
    if title=='__CANCEL__':return 'Cancelled'
    title=title.strip()
    if not title or len(title)>250:raise ValueError('Task title must contain 1–250 characters')
    raw_lists=osa(READ_LIST_NAMES)
    choices=[x for x in raw_lists.split(RECORD) if x.strip()]
    if not choices:raise ValueError('No Reminders lists found. Enable Reminders in iCloud.')
    list_name=osa(CHOOSE_LIST,RECORD.join(choices),cfg['reminders_list'])
    if list_name=='__CANCEL__':return 'Cancelled'
    if list_name not in choices:raise ValueError('Selected Reminders list was not found')
    if any((not t['completed'] and t['list']==list_name and
            normalized_title(t['title'])==normalized_title(title)) for t in reminders()):
        return f'Already exists in {list_name}: {title}'
    when=osa(DIALOG,'Due date/time: YYYY-MM-DD HH:MM, or leave blank for no due date','')
    if when=='__CANCEL__':return 'Cancelled'
    when=when.strip()
    if when:
        try: due=dt.datetime.strptime(when,'%Y-%m-%d %H:%M')
        except ValueError:raise ValueError('Use YYYY-MM-DD HH:MM')
        if due < dt.datetime.now():raise ValueError('Due time must be in future')
    confirmation=osa(DIALOG, f'Create in {list_name}:\n{title}\nDue: {when or "None"}\nType YES to approve','')
    if confirmation.strip()!='YES':return 'No changes made'
    marker='MAC-AI-HUB-ID:'+str(uuid.uuid4())
    status=osa(ADD_REMINDER,list_name,title,when,marker)
    return f'{status}: {title}'


def normalized_title(value):
    return ' '.join(value.casefold().split())


def checkin(period,notify=True):
    items=reminders()
    message=brief(items,period)
    print(message)
    if notify:
        buckets=classify(items)
        excerpt=f'{buckets["open"]} open, {len(buckets["overdue"])} overdue, {len(buckets["today"])} remaining today. Open Reminders for details.'
        osa(NOTICE,excerpt,f'{period.title()} Task Review')
    return message


def diagnostic():
    usage=shutil.disk_usage(Path.home())
    result={'free_gb':round(usage.free/1e9,2),'total_gb':round(usage.total/1e9,2)}
    for name,args in [('swap',['sysctl','vm.swapusage']),('memory_pressure',['memory_pressure','-Q'])]:
        try:
            proc=subprocess.run(args,capture_output=True,text=True,timeout=12)
            result[name]=proc.stdout.strip()[:1200] if proc.returncode==0 else 'unavailable'
        except (OSError,subprocess.TimeoutExpired):result[name]='unavailable'
    return result


def ai_brief(shortcut_name):
    """Explicitly configured, pre-existing Apple Shortcut; does not expose an unrestricted model API.
    The Shortcut is expected to run an on-device Apple Intelligence model over this payload."""
    items=reminders()
    buckets=classify(items)
    payload={'generated_at':dt.datetime.now().isoformat(),
             'summary':{'open':buckets['open'],'overdue':len(buckets['overdue']),
                        'due_today':len(buckets['today']),'upcoming':len(buckets['later']),
                        'no_due_date':len(buckets['undated']),'completed':buckets['completed']},
             'tasks':[{'title':t['title'],'list':t['list'],'completed':t['completed'],'due':t['due'].isoformat() if t['due'] else None} for t in items]}
    STATE.mkdir(parents=True,exist_ok=True)
    tmp=STATE/'ai-brief-input.json';tmp.write_text(json.dumps(payload,ensure_ascii=False))
    os.chmod(tmp,0o600)
    try:
        result=subprocess.run(['shortcuts','run',shortcut_name,'-i',str(tmp)],capture_output=True,text=True,timeout=120)
        if result.returncode:raise RuntimeError(result.stderr.strip() or 'Shortcut failed')
        return result.stdout.strip()
    finally:tmp.unlink(missing_ok=True)


WEEKDAYS={'monday':0,'tuesday':1,'wednesday':2,'thursday':3,'friday':4,'saturday':5,'sunday':6}


def parse_natural_when(phrase,now=None):
    """Best-effort local parse of a natural phrase into (title, due|None).

    Handles today/tonight/tomorrow, weekday names, 'in N days/weeks', and times
    like 'at 3', 'at 3pm', 'at 15:30'. Used as a fallback when the Apple
    Intelligence Shortcut is unavailable, and standalone with --local.
    """
    now=now or dt.datetime.now()
    s=phrase.strip()
    low=s.lower()
    spans=[]
    time_part=None
    m=re.search(r'\bat\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b',low)
    if m:
        h=int(m.group(1));mi=int(m.group(2) or 0);ap=m.group(3)
        if ap=='pm' and h<12:h+=12
        if ap=='am' and h==12:h=0
        if 0<=h<=23 and 0<=mi<=59:
            time_part=(h,mi);spans.append(m.span())
    for word,hour in (('noon',12),('midnight',0)):
        mw=re.search(r'\b'+word+r'\b',low)
        if mw and not time_part:
            time_part=(hour,0);spans.append(mw.span())
    base=None
    md=re.search(r'\b(today|tonight|tomorrow)\b',low)
    if md:
        w=md.group(1)
        base=now.date() if w in ('today','tonight') else (now+dt.timedelta(days=1)).date()
        if w=='tonight' and not time_part:time_part=(19,0)
        spans.append(md.span())
    else:
        mw=re.search(r'\b(next\s+)?('+'|'.join(WEEKDAYS)+r')\b',low)
        mr=re.search(r'\bin\s+(\d{1,3})\s+(day|days|week|weeks)\b',low)
        if mw:
            days=(WEEKDAYS[mw.group(2)]-now.weekday())%7
            if days==0:days=7
            base=(now+dt.timedelta(days=days)).date();spans.append(mw.span())
        elif mr:
            mult=7 if mr.group(2).startswith('week') else 1
            base=(now+dt.timedelta(days=int(mr.group(1))*mult)).date();spans.append(mr.span())
    due=None
    if base:
        h,mi=time_part or (9,0)
        due=dt.datetime(base.year,base.month,base.day,h,mi)
    elif time_part:
        h,mi=time_part
        cand=now.replace(hour=h,minute=mi,second=0,microsecond=0)
        due=cand if cand>now else cand+dt.timedelta(days=1)
    title=s
    for a,b in sorted(spans,reverse=True):
        title=title[:a]+title[b:]
    title=re.sub(r'^(remind me to|remind me|remember to|remember|task)\b[:,]?\s*','',title,flags=re.I)
    title=re.sub(r'\s{2,}',' ',title).strip(' ,.-')
    return title,due


def parse_shortcut_task(output):
    """Parse 'title | YYYY-MM-DD HH:MM' (or just 'title') returned by the Shortcut."""
    output=output.strip()
    title,sep,when=output.partition('|')
    title=title.strip();when=when.strip()
    due=None
    if sep and when:
        try:due=dt.datetime.strptime(when,'%Y-%m-%d %H:%M')
        except ValueError:due=None
    return title,due


def nl_shortcut(phrase,shortcut_name):
    """Pass the phrase to an on-device Apple Intelligence Shortcut and read its text output."""
    STATE.mkdir(parents=True,exist_ok=True)
    tmp=STATE/'nl-input.txt';tmp.write_text(phrase,encoding='utf-8');os.chmod(tmp,0o600)
    try:
        result=subprocess.run(['shortcuts','run',shortcut_name,'-i',str(tmp)],capture_output=True,text=True,timeout=120)
        if result.returncode:raise RuntimeError(result.stderr.strip() or 'Shortcut failed')
        return result.stdout.strip()
    finally:tmp.unlink(missing_ok=True)


def add_nl(cfg,phrase,shortcut='Mac AI Task Parser',use_local=False,logger=None):
    """Create a reminder from natural language, preferring the Apple Intelligence Shortcut."""
    phrase=phrase.strip()
    if not phrase:raise ValueError('Provide a task phrase')
    title,due,source=None,None,'local'
    if not use_local:
        try:
            title,due=parse_shortcut_task(nl_shortcut(phrase,shortcut))
            source='apple-intelligence'
        except Exception as exc:
            if logger:logger.warning('NL Shortcut unavailable, using local parser: %s',exc)
            title=None
    if not title:
        title,due=parse_natural_when(phrase);source='local'
    if not title or len(title)>250:raise ValueError('Could not derive a 1–250 character task title')
    if due and due<dt.datetime.now():raise ValueError(f'Parsed due time is in the past: {due:%Y-%m-%d %H:%M}')
    list_name=cfg['reminders_list']
    if any((not t['completed'] and t['list']==list_name and
            normalized_title(t['title'])==normalized_title(title)) for t in reminders()):
        return f'Already exists in {list_name}: {title}'
    when=due.strftime('%Y-%m-%d %H:%M') if due else ''
    marker='MAC-AI-HUB-ID:'+str(uuid.uuid4())
    status=osa(ADD_REMINDER,list_name,title,when,marker)
    due_str=f'{due:%b %d %H:%M}' if due else 'no due date'
    return f'{status} [{source}]: {title} ({due_str}) in {list_name}'


def agent_loaded(label):
    try:
        res=subprocess.run(['launchctl','print',f'gui/{os.getuid()}/{label}'],capture_output=True,text=True,timeout=10)
        return res.returncode==0
    except (OSError,subprocess.TimeoutExpired):
        return False


KNOWN_AGENTS=[f'{LABEL}.morning',f'{LABEL}.midday',f'{LABEL}.evening',
              'com.local.mac-productivity-manager.morning','com.local.mac-productivity-manager.evening',
              'com.local.mac-productivity-manager.sync','com.local.mac-storage-manager']


def doctor():
    """One-shot health check: config, Reminders access, scheduled agents, recent errors."""
    ok=True
    print('Mac AI Productivity Hub — doctor')
    print(f'platform        : {sys.platform}'+('' if sys.platform=='darwin' else '  (Apple features unavailable off macOS)'))
    cfg=None
    try:
        cfg=config();print(f'config          : OK (list="{cfg["reminders_list"]}", {cfg["morning"]}/{cfg["midday"]}/{cfg["evening"]})')
    except Exception as exc:
        ok=False;print(f'config          : ERROR {exc}')
    if sys.platform=='darwin':
        try:
            names=[x for x in osa(READ_LIST_NAMES).split(RECORD) if x.strip()]
            print(f'reminders access: OK ({len(names)} list(s))')
            if cfg and cfg['reminders_list'] not in names:
                ok=False;print(f'  WARNING: configured list "{cfg["reminders_list"]}" not found among {names[:8]}')
        except Exception as exc:
            ok=False;print(f'reminders access: ERROR {exc}')
    agents=Path.home()/'Library'/'LaunchAgents'
    print('scheduled agents:')
    for label in KNOWN_AGENTS:
        installed=(agents/(label+'.plist')).exists()
        state='not installed'
        if installed:
            state='installed'+(' + loaded' if sys.platform=='darwin' and agent_loaded(label) else ' (not loaded)')
        print(f'  {label:<48} {state}')
    errlog=STATE/'ai_hub.log'
    if errlog.exists():
        tail=[l for l in errlog.read_text(errors='replace').splitlines() if 'ERROR' in l or 'Traceback' in l]
        if tail:
            print(f'recent errors   : {len(tail)} in {errlog.name}; last: {tail[-1][:120]}')
        else:
            print('recent errors   : none logged')
    print('\nStatus:',('OK' if ok else 'ATTENTION NEEDED'))
    return 0 if ok else 1


def install(cfg):
    if sys.platform!='darwin':raise RuntimeError('Install requires macOS')
    STATE.mkdir(parents=True,exist_ok=True)
    agents=Path.home()/'Library'/'LaunchAgents';agents.mkdir(parents=True,exist_ok=True)
    created=[]
    for period in ('morning','midday','evening'):
        hour,minute=map(int,cfg[period].split(':'))
        label=f'{LABEL}.{period}';dest=agents/(label+'.plist')
        info={'Label':label,'ProgramArguments':[str(Path(sys.executable).resolve()),str(Path(__file__).resolve()),'checkin',period,'--notify'],
              'StartCalendarInterval':{'Hour':hour,'Minute':minute},'RunAtLoad':False,
              'StandardOutPath':str(STATE/f'{period}.log'),'StandardErrorPath':str(STATE/f'{period}.error.log')}
        dest.write_bytes(plistlib.dumps(info))
        subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(dest)],capture_output=True)
        result=subprocess.run(['launchctl','bootstrap',f'gui/{os.getuid()}',str(dest)],capture_output=True,text=True)
        if result.returncode:raise RuntimeError(result.stderr)
        created.append(dest)
    return created


def uninstall():
    for period in ('morning','midday','evening'):
        dest=Path.home()/'Library'/'LaunchAgents'/f'{LABEL}.{period}.plist'
        if dest.exists():
            subprocess.run(['launchctl','bootout',f'gui/{os.getuid()}',str(dest)],capture_output=True)
            dest.unlink()


def main():
    ap=argparse.ArgumentParser(description='Text-first Apple Reminders assistant; no voice capture')
    sub=ap.add_subparsers(dest='command',required=True)
    sub.add_parser('list');sub.add_parser('add');sub.add_parser('diagnose');sub.add_parser('install');sub.add_parser('uninstall');sub.add_parser('doctor')
    check=sub.add_parser('checkin');check.add_argument('period',choices=['morning','midday','evening']);check.add_argument('--notify',action='store_true')
    ai=sub.add_parser('ai-brief');ai.add_argument('--shortcut',default='Mac AI Task Briefing')
    nl=sub.add_parser('add-nl',help='Create a reminder from a natural-language phrase')
    nl.add_argument('phrase');nl.add_argument('--shortcut',default='Mac AI Task Parser');nl.add_argument('--local',action='store_true',help='Skip the Apple Intelligence Shortcut; parse locally')
    args=ap.parse_args();logger=log()
    try:
        if args.command=='doctor':
            rc=doctor();logger.info('Completed doctor');return rc
        cfg=config()
        if args.command=='list':print(brief(reminders(),'Task List',limit=30))
        elif args.command=='add':print(interactive_add(cfg))
        elif args.command=='add-nl':print(add_nl(cfg,args.phrase,args.shortcut,args.local,logger))
        elif args.command=='checkin':checkin(args.period,args.notify)
        elif args.command=='diagnose':print(json.dumps(diagnostic(),indent=2))
        elif args.command=='ai-brief':print(ai_brief(args.shortcut))
        elif args.command=='install':print('\n'.join(map(str,install(cfg))))
        elif args.command=='uninstall':uninstall();print('Removed scheduled check-ins; reminders untouched.')
        logger.info('Completed %s',args.command)
        return 0
    except Exception as exc:
        logger.exception('Failure in %s',args.command)
        print('ERROR:',exc,file=sys.stderr)
        return 1

if __name__=='__main__':raise SystemExit(main())
