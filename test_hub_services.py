import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch

import hub_services
import storage_manager


class HubServiceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        (self.home / 'Desktop').mkdir()
        (self.home / 'Downloads').mkdir()
        self.config = self.home / 'config.json'
        self.config.write_text(json.dumps(storage_manager.config_example()))
        self.home_patcher = patch.object(storage_manager, 'HOME', self.home)
        self.home_patcher.start()
        self.addCleanup(self.home_patcher.stop)

    def make_old(self, path):
        path.write_text('example')
        old = time.time() - 90 * 86400
        os.utime(path, (old, old))

    def test_only_allowlisted_items_in_scan(self):
        self.make_old(self.home / 'Desktop' / 'Screenshot 2026-04-10 at 10.00.00.png')
        self.make_old(self.home / 'Downloads' / 'installer.dmg')
        self.make_old(self.home / 'Desktop' / 'My Project.png')
        self.make_old(self.home / 'Downloads' / 'private-data.txt')
        items = hub_services.scanned_candidates(self.config)
        assert {i['category'] for i in items} == {'screenshots', 'installers'}

    def test_changed_candidate_refuses_trash(self):
        target = self.home / 'Downloads' / 'install.pkg'
        self.make_old(target)
        token = hub_services.scanned_candidates(self.config)[0]['fingerprint']
        target.write_text('new contents')
        with patch.object(storage_manager, 'trash_with_finder') as trash:
            with self.assertRaisesRegex(ValueError, 'changed'):
                hub_services.trash_one(self.config, token)
            trash.assert_not_called()

    def test_selected_candidate_only_moves_when_invoked(self):
        target = self.home / 'Downloads' / 'install.pkg'
        self.make_old(target)
        token = hub_services.scanned_candidates(self.config)[0]['fingerprint']
        with patch.object(storage_manager, 'trash_with_finder') as trash:
            hub_services.scan(self.config)
            trash.assert_not_called()
            result = hub_services.trash_one(self.config, token)
            trash.assert_called_once_with(target)
            self.assertEqual(result['status'], 'moved_to_trash')

    def test_symlink_not_allowed(self):
        other = self.home / 'private.docx'
        self.make_old(other)
        (self.home / 'Downloads' / 'install.dmg').symlink_to(other)
        self.assertEqual(hub_services.scanned_candidates(self.config), [])

    def test_ai_status_detects_shortcut_without_running_it(self):
        from subprocess import CompletedProcess
        listing = CompletedProcess(['shortcuts', 'list'], 0,
                                   stdout='Quick Add Task\nMac Hub AI Plan\nDaily Task Review\n', stderr='')
        with patch.object(hub_services.shutil, 'which', return_value='/usr/bin/printf'), \
             patch.object(hub_services.subprocess, 'run', return_value=listing) as runner:
            result = hub_services.ai_status()
        self.assertTrue(result['installed'])
        runner.assert_called_once()
        self.assertEqual(runner.call_args.args[0], ['/usr/bin/printf', 'list'])

    def test_ai_status_missing_shortcut_is_not_confused_by_partial_name(self):
        from subprocess import CompletedProcess
        listing = CompletedProcess(['shortcuts', 'list'], 0,
                                   stdout='Mac Hub AI Planner Backup\n', stderr='')
        with patch.object(hub_services.shutil, 'which', return_value='/usr/bin/printf'), \
             patch.object(hub_services.subprocess, 'run', return_value=listing):
            result = hub_services.ai_status()
        self.assertFalse(result['installed'])

    def test_ai_status_shortcuts_failure_is_safe(self):
        from subprocess import CompletedProcess
        listing = CompletedProcess(['shortcuts', 'list'], 1, stdout='', stderr='permission denied')
        with patch.object(hub_services.shutil, 'which', return_value='/usr/bin/printf'), \
             patch.object(hub_services.subprocess, 'run', return_value=listing):
            result = hub_services.ai_status()
        self.assertFalse(result['installed'])
        self.assertNotIn('permission denied', str(result))

    def test_bad_candidate_id_does_not_move_file(self):
        with self.assertRaisesRegex(ValueError, 'Invalid'):
            hub_services.trash_one(self.config, '../../Documents')


if __name__ == '__main__':
    unittest.main()
