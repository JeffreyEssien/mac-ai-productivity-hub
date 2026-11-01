import importlib.util
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('storage_manager', Path(__file__).with_name('storage_manager.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

class StorageManagerTests(unittest.TestCase):
    def test_filters_symlinks_and_recent_files(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            desk = home / 'Desktop'
            down = home / 'Downloads'
            desk.mkdir(); down.mkdir()
            old = desk / 'Screenshot 2026-01-01 at 12.00.00.png'
            old.write_bytes(b'screenshot')
            os.utime(old, (time.time()-40*86400, time.time()-40*86400))
            recent = desk / 'Screenshot now.png'
            recent.write_bytes(b'recent')
            ignored = desk / 'family.jpg'
            ignored.write_bytes(b'private')
            link = desk / 'Screenshot symlink.png'
            link.symlink_to(old)
            install = down / 'setup.dmg'
            install.write_bytes(b'installer')
            os.utime(install, (time.time()-65*86400, time.time()-65*86400))
            cfg = mod.config_example()
            with patch.object(mod, 'HOME', home):
                found = mod.candidates(cfg, time.time())
            self.assertEqual({Path(x['path']).name for x in found}, {old.name, install.name})
            self.assertFalse(mod.safe_child(link, desk))

    def test_reporting_does_not_make_support_deletable(self):
        with tempfile.TemporaryDirectory() as d:
            home = Path(d)
            claude = home / 'Library' / 'Application Support' / 'Claude'
            claude.mkdir(parents=True)
            (claude/'important.db').write_bytes(b'X'*100)
            cfg = mod.config_example(); cfg['large_support_gb'] = 1
            with patch.object(mod, 'HOME', home):
                self.assertEqual(mod.candidates(cfg, time.time()), [])

    def test_config_validation(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d)/'config.json'
            p.write_text('{"screenshot_days":-5}')
            with self.assertRaises(ValueError):
                mod.config_load(p)


class TrendHistoryTests(unittest.TestCase):
    def _payload(self, day, free):
        return {'date': f'2026-10-{day:02d}T00:00:00+00:00', 'mode': 'scan',
                'after': {'free_gb': free, 'used_gb': 50.0, 'total_gb': 500.0},
                'eligible_bytes': 1000, 'trash_count': 0}

    def test_append_read_and_cap(self):
        with tempfile.TemporaryDirectory() as d:
            base = Path(d)
            with patch.object(mod, 'BASE', base), patch.object(mod, 'HISTORY', base/'history.jsonl'), \
                 patch.object(mod, 'HISTORY_MAX', 5):
                for i in range(8):
                    mod.append_history(self._payload(i+1, 100.0+i))
                rows = mod.read_history()
            self.assertEqual(len(rows), 5)                 # capped
            self.assertEqual(rows[-1]['free_gb'], 107.0)   # newest kept
            self.assertEqual(rows[0]['free_gb'], 103.0)    # oldest dropped

    def test_history_record_shape(self):
        rec = mod.history_record(self._payload(1, 42.0))
        self.assertEqual(rec['free_gb'], 42.0)
        self.assertEqual(rec['mode'], 'scan')
        self.assertIn('date', rec)

    def test_read_history_skips_corrupt_lines(self):
        with tempfile.TemporaryDirectory() as d:
            hist = Path(d)/'history.jsonl'
            hist.write_text('{"free_gb": 1.0}\nnot json\n\n{"free_gb": 2.0}\n')
            with patch.object(mod, 'HISTORY', hist):
                rows = mod.read_history()
            self.assertEqual([r['free_gb'] for r in rows], [1.0, 2.0])


if __name__ == '__main__':
    unittest.main()
