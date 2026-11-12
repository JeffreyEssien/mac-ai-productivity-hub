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


def _age(p, days):
    t = time.time() - days * 86400
    os.utime(p, (t, t))


class DeeperCleanupTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        for p in (patch.object(mod, 'HOME', self.home), patch.object(mod, 'APPLICATIONS', self.home / 'NoApps')):
            p.start(); self.addCleanup(p.stop)
        self.cfg = mod.config_example(); self.cfg['cache_min_mb'] = 0

    def cats(self):
        return {(x['category'], Path(x['path']).name) for x in mod.candidates(self.cfg, time.time())}

    def test_node_modules_only_in_idle_projects_and_source_kept_out(self):
        for name, days in (('old', 90), ('fresh', 0)):
            proj = self.home / 'Documents' / name
            (proj / 'node_modules' / 'pkg').mkdir(parents=True)
            for f in ('package.json', '.env.local'):
                (proj / f).write_text('{}'); _age(proj / f, days)
            _age(proj / 'node_modules', days); _age(proj, days)
        found = [x for x in mod.candidates(self.cfg, time.time()) if x['category'] == 'node_modules']
        self.assertEqual([Path(x['path']).parent.name for x in found], ['old'])
        self.assertTrue(all(Path(x['path']).name == 'node_modules' for x in found))

    def test_downloads_partial_and_unpacked_zip(self):
        down = self.home / 'Downloads'; down.mkdir()
        (down / 'movie.mp4.part').write_text('x'); _age(down / 'movie.mp4.part', 5)
        (down / 'busy.crdownload').write_text('x')  # still downloading
        (down / 'chat.zip').write_text('x'); _age(down / 'chat.zip', 30); (down / 'chat').mkdir()
        (down / 'lonely.zip').write_text('x'); _age(down / 'lonely.zip', 30)
        self.assertEqual(self.cats(), {('partial_download', 'movie.mp4.part'), ('unpacked_zip', 'chat.zip')})

    def test_vscode_unused_extension_fails_closed(self):
        ext = self.home / '.vscode' / 'extensions'
        (ext / 'pub.tool-1.0.0').mkdir(parents=True); (ext / 'pub.tool-2.0.0').mkdir()
        self.assertEqual(self.cats(), set())  # no extensions.json: nothing offered
        (ext / 'extensions.json').write_text('[{"relativeLocation": "pub.tool-2.0.0"}]')
        self.assertEqual(self.cats(), {('vscode_old_extension', 'pub.tool-1.0.0')})

    def test_app_caches_skip_apple_and_report_only(self):
        caches = self.home / 'Library' / 'Caches'
        for n in ('com.example.app', 'com.apple.Safari', 'com.spotify.client'):
            (caches / n).mkdir(parents=True); (caches / n / 'f').write_text('x')
        self.assertEqual(self.cats(), {('app_cache', 'com.example.app')})

    def test_still_eligible_rejects_changed_item(self):
        down = self.home / 'Downloads'; down.mkdir()
        part = down / 'a.part'; part.write_text('x'); _age(part, 5)
        item = mod.candidates(self.cfg, time.time())[0]
        self.assertTrue(mod.still_eligible(item, self.cfg, time.time()))
        part.write_text('new')  # touched again: no longer stale
        self.assertFalse(mod.still_eligible(item, self.cfg, time.time()))

    def test_duplicate_projects_reported_with_env_flag(self):
        for root, env in (('Documents', True), ('Developer', False)):
            proj = self.home / root / 'shop'
            proj.mkdir(parents=True)
            (proj / 'package.json').write_text('{"name": "shop-site"}')
            if env:
                (proj / '.env.local').write_text('KEY=1')
        dups = [r for r in mod.reports(self.cfg) if r['category'] == 'duplicate_project']
        self.assertEqual(sorted(r['has_env'] for r in dups), [False, True])
        self.assertEqual(mod.candidates(self.cfg, time.time()), [])  # never trash candidates


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
