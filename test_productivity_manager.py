import unittest
from unittest.mock import patch
import productivity_manager as pm

class PlannerTests(unittest.TestCase):
    def test_valid_note_and_dates(self):
        html='<div>TASK-0001 | Review deployment | 2026-10-12 10:30 | OPEN</div><div>TASK-0002 | Pay rent | 2026-10-14 18:00 | DONE</div>'
        tasks, errors=pm.parse_note(html)
        self.assertEqual(errors, [])
        self.assertEqual([t['id'] for t in tasks],['TASK-0001','TASK-0002'])
        self.assertEqual(tasks[1]['status'],'DONE')
    def test_lowercase_task_prefix_is_parsed(self):
        # The pre-filter is case-insensitive, matching the case-insensitive LINE regex.
        html='<div>task-0001 | Review deployment | 2026-10-12 10:30 | open</div>'
        tasks, errors=pm.parse_note(html)
        self.assertEqual(errors, [])
        self.assertEqual(len(tasks), 1)
        self.assertEqual(tasks[0]['id'], 'TASK-0001')  # normalized to uppercase
        self.assertEqual(tasks[0]['status'], 'OPEN')

    def test_invalid_and_duplicate_fail_closed(self):
        html='<div>TASK-0001 | One | 2026-02-30 19:00 | OPEN</div><div>TASK-0002 | Two | 2026-10-12 10:00 | OPEN</div><div>TASK-0002 | Three | 2026-10-12 10:00 | OPEN</div>'
        tasks, errors=pm.parse_note(html)
        self.assertEqual(len(tasks),1)
        self.assertEqual(len(errors),2)
    def test_dry_run_never_calls_reminders(self):
        t=[{'id':'TASK-0001','title':'Test','due':pm.dt.datetime(2026,10,12,10,30),'status':'OPEN'}]
        with patch.object(pm,'scan',return_value=t),patch.object(pm,'applescript') as cmd:
            result=pm.synchronize({'reminders_list':'Mac Planner'}, apply=False)
            cmd.assert_not_called()
            self.assertIn('would',result[0]['action'])
    def test_completed_task_preview(self):
        t=[{'id':'TASK-0001','title':'Test','due':pm.dt.datetime(2026,10,12,10,30),'status':'DONE'}]
        with patch.object(pm,'scan',return_value=t),patch.object(pm,'applescript') as cmd:
            r=pm.synchronize({'reminders_list':'Mac Planner'},apply=False)
            cmd.assert_not_called()
            self.assertIn('complete',r[0]['action'])

class ReflectTests(unittest.TestCase):
    # parse_note's pre-filter requires an uppercase TASK- prefix, so the note body
    # uses uppercase IDs; set_note_status itself matches IDs case-insensitively.
    HTML = ('<div>TASK-0001 | Review | 2026-10-12 10:30 | OPEN</div>'
            '<div>TASK-0002 | Pay rent | 2026-10-14 18:00 | OPEN</div>')

    def test_set_note_status_flips_one_task(self):
        out, n = pm.set_note_status(self.HTML, 'TASK-0001', 'DONE')
        self.assertEqual(n, 1)
        self.assertIn('TASK-0001 | Review | 2026-10-12 10:30 | DONE', out)
        self.assertIn('| OPEN', out)  # the other task untouched

    def test_set_note_status_is_case_insensitive_on_id(self):
        html = '<div>task-0002 | Pay rent | 2026-10-14 18:00 | OPEN</div>'
        out, n = pm.set_note_status(html, 'TASK-0002', 'DONE')
        self.assertEqual(n, 1)
        self.assertIn('task-0002 | Pay rent | 2026-10-14 18:00 | DONE', out)

    def test_set_note_status_no_match_is_safe(self):
        out, n = pm.set_note_status(self.HTML, 'TASK-9999', 'DONE')
        self.assertEqual(n, 0)
        self.assertEqual(out, self.HTML)

    def test_reflect_only_flips_completed_reminders(self):
        captured = {}
        def fake(script, *args, **kw):
            if script is pm.NOTES_FETCH:
                return self.HTML
            if script is pm.REMINDER_STATUS:
                return 'completed' if args[1] == 'TASK-0001' else 'open'
            if script is pm.NOTES_SET_BODY:
                captured['body'] = args[1]
                return ''
            return ''
        with patch.object(pm, 'applescript', side_effect=fake):
            planned = pm.reflect({'note_title': 'N', 'reminders_list': 'L'}, apply=True)
        self.assertEqual([p['id'] for p in planned], ['TASK-0001'])
        self.assertIn('TASK-0001 | Review | 2026-10-12 10:30 | DONE', captured['body'])
        self.assertIn('| OPEN', captured['body'])

    def test_reflect_preview_does_not_write(self):
        def fake(script, *args, **kw):
            if script is pm.NOTES_FETCH:
                return self.HTML
            if script is pm.REMINDER_STATUS:
                return 'completed'
            if script is pm.NOTES_SET_BODY:
                raise AssertionError('preview must not write the note body')
            return ''
        with patch.object(pm, 'applescript', side_effect=fake):
            planned = pm.reflect({'note_title': 'N', 'reminders_list': 'L'}, apply=False)
        self.assertEqual(len(planned), 2)


class LauncherSourceTests(unittest.TestCase):
    def test_command_is_interpolated_not_literal(self):
        # Regression: the AppleScript source once contained the literal
        # text "' + command + '" instead of the real command, so the
        # compiled launcher always failed. Guard against that returning.
        src=pm.launcher_source('/usr/bin/python3','/path/to/productivity_manager.py')
        self.assertNotIn("' + command + '", src)
        self.assertIn('/usr/bin/python3', src)
        self.assertIn('/path/to/productivity_manager.py', src)
        self.assertIn('sync --apply', src)
        self.assertIn('do shell script "', src)

    def test_paths_with_spaces_are_quoted(self):
        src=pm.launcher_source('/usr/bin/python3','/Users/me/My Scripts/productivity_manager.py')
        # shlex.quote wraps the space-containing path in single quotes.
        self.assertIn("'/Users/me/My Scripts/productivity_manager.py'", src)

if __name__=='__main__': unittest.main()
