import datetime as dt
import unittest
import ai_hub

class TestHub(unittest.TestCase):
    def test_record_roundtrip(self):
        raw=ai_hub.FIELD.join(['id1','Work','Review build','false','2026-10-12 09:00'])+ai_hub.RECORD
        r=ai_hub.parse_records(raw)
        self.assertEqual(len(r),1)
        self.assertEqual(r[0]['title'],'Review build')
        self.assertFalse(r[0]['completed'])
        self.assertEqual(r[0]['due'].hour,9)
    def test_completed_excluded(self):
        items=[{'id':'1','title':'Done','list':'Home','completed':True,'due':None},
        {'id':'2','title':'Open','list':'Home','completed':False,'due':None}]
        result=ai_hub.classify(items)
        self.assertEqual(result['open'],1)
        self.assertEqual(len(result['undated']),1)
        self.assertEqual(result['completed'],1)
    def test_overdue_and_upcoming(self):
        now=dt.datetime(2026,10,11,10,0)
        def task(hours):return {'id':str(hours),'title':'Task','list':'Work','completed':False,'due':now+dt.timedelta(hours=hours)}
        buckets=ai_hub.classify([task(-1),task(3),task(48)],now)
        self.assertEqual([len(buckets[k]) for k in ['overdue','today','later']],[1,1,1])
    def test_invalid_parse_skipped(self):
        self.assertEqual(ai_hub.parse_records('broken')[0:1],[])
    def test_schedule_format(self):
        cfg=ai_hub.config()
        self.assertRegex(cfg['morning'],r'^\d\d:\d\d$')

if __name__=='__main__':unittest.main()

class TestNativeMigration(unittest.TestCase):
    def test_normalized_duplicates(self):
        self.assertEqual(ai_hub.normalized_title('  Send  Flyers '), ai_hub.normalized_title('send flyers'))
    def test_upcoming_is_displayed(self):
        item={'id':'2','title':'Next-week task','list':'REMINDER','completed':False,
              'due':dt.datetime.now()+dt.timedelta(days=7)}
        self.assertIn('UPCOMING:', ai_hub.brief([item],'task list'))

class TestNaturalLanguage(unittest.TestCase):
    MON = dt.datetime(2026, 10, 26, 8, 0)  # a Monday 08:00
    def test_tomorrow_default_time(self):
        title, due = ai_hub.parse_natural_when('buy milk tomorrow', self.MON)
        self.assertEqual(title, 'buy milk')
        self.assertEqual((due.year, due.month, due.day, due.hour, due.minute), (2026, 10, 27, 9, 0))
    def test_next_weekday_with_pm_time(self):
        title, due = ai_hub.parse_natural_when('remind me to call the dentist next tuesday at 3pm', self.MON)
        self.assertEqual(title, 'call the dentist')
        self.assertEqual((due.month, due.day, due.hour), (10, 27, 15))
    def test_tonight_is_evening(self):
        _, due = ai_hub.parse_natural_when('dinner tonight', self.MON)
        self.assertEqual((due.day, due.hour), (26, 19))
    def test_in_n_weeks(self):
        _, due = ai_hub.parse_natural_when('pay invoice in 2 weeks', self.MON)
        self.assertEqual((due.month, due.day), (11, 9))
    def test_no_temporal_phrase_has_no_due(self):
        title, due = ai_hub.parse_natural_when('water plants', self.MON)
        self.assertEqual(title, 'water plants')
        self.assertIsNone(due)
    def test_time_only_rolls_to_future(self):
        # 07:00 already passed at 08:00 today, so it rolls to tomorrow.
        _, due = ai_hub.parse_natural_when('standup at 7', self.MON)
        self.assertEqual((due.day, due.hour), (27, 7))
    def test_shortcut_output_parsing(self):
        self.assertEqual(ai_hub.parse_shortcut_task('Call dentist | 2026-10-27 15:00'),
                         ('Call dentist', dt.datetime(2026, 10, 27, 15, 0)))
        self.assertEqual(ai_hub.parse_shortcut_task('Water plants |'), ('Water plants', None))
        self.assertEqual(ai_hub.parse_shortcut_task('Just a title'), ('Just a title', None))

class TestAddNaturalLanguage(unittest.TestCase):
    def test_local_parse_creates_reminder(self):
        from unittest.mock import patch
        now_future = dt.datetime.now() + dt.timedelta(days=400)
        phrase = f'review budget on {now_future:%Y-%m-%d}'  # won't parse date, but no past-due
        with patch.object(ai_hub, 'reminders', return_value=[]), \
             patch.object(ai_hub, 'osa', return_value='created') as osa:
            result = ai_hub.add_nl({'reminders_list': 'REMINDER'}, 'water plants', use_local=True)
            self.assertIn('[local]', result)
            self.assertIn('water plants', result)
            osa.assert_called_once()
    def test_duplicate_is_not_created(self):
        from unittest.mock import patch
        existing = [{'id': '1', 'title': 'Water plants', 'list': 'REMINDER', 'completed': False, 'due': None}]
        with patch.object(ai_hub, 'reminders', return_value=existing), \
             patch.object(ai_hub, 'osa') as osa:
            result = ai_hub.add_nl({'reminders_list': 'REMINDER'}, 'water plants', use_local=True)
            self.assertIn('Already exists', result)
            osa.assert_not_called()
    def test_shortcut_failure_falls_back_to_local(self):
        from unittest.mock import patch
        with patch.object(ai_hub, 'nl_shortcut', side_effect=RuntimeError('no shortcuts')), \
             patch.object(ai_hub, 'reminders', return_value=[]), \
             patch.object(ai_hub, 'osa', return_value='created') as osa:
            result = ai_hub.add_nl({'reminders_list': 'REMINDER'}, 'water plants', use_local=False)
            self.assertIn('[local]', result)
            osa.assert_called_once()
