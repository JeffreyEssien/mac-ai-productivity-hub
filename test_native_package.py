import pathlib
import plistlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parent
APPKIT = ROOT / 'native' / 'AppKit' / 'MacAIHub.swift'


class NativePackageTests(unittest.TestCase):
    def test_bundle_reminders_permissions(self):
        info = plistlib.loads((ROOT / 'native' / 'Info.plist').read_bytes())
        self.assertIn('NSRemindersFullAccessUsageDescription', info)
        self.assertEqual(info['CFBundlePackageType'], 'APPL')
        self.assertEqual(info['LSMinimumSystemVersion'], '14.0')

    def test_installer_has_no_swiftui_or_launchd_mutations(self):
        installer = (ROOT / 'native' / 'install_mac_app.sh').read_text()
        self.assertIn('AppKit/MacAIHub.swift', installer)
        self.assertIn('-framework AppKit', installer)
        self.assertNotIn('-framework SwiftUI', installer)
        self.assertNotIn('launchctl', installer)
        self.assertNotIn('rm -rf "$HOME/Tools', installer)

    def test_native_ui_reminder_list_picker_and_date(self):
        source = APPKIT.read_text()
        self.assertIn('NSPopUpButton', source)
        self.assertIn('NSDatePicker', source)
        self.assertIn('Today", "Tomorrow", "Next Week', source)
        self.assertIn('Set due date', source)
        self.assertIn('Remind at a specific time', source)

    def test_reminders_authoritative_and_duplicate_guard(self):
        source = APPKIT.read_text()
        self.assertIn('EKEventStore()', source)
        self.assertIn('calendarItemIdentifier', source)
        self.assertIn('normalizedTitle(reminderTitle($0)) == normalizedTitle(title)', source)
        self.assertIn('store.calendars(for: .reminder)', source)
        self.assertNotIn('saveCalendar', source)
        self.assertNotIn('removeCalendar', source)
        self.assertNotIn('EKCalendar(for:', source)

    def test_all_day_date_not_marked_overdue_before_next_day(self):
        source = APPKIT.read_text()
        self.assertIn('cal.startOfDay(for: due) < cal.startOfDay(for: now)', source)
        self.assertIn('reminderHasTime(item)', source)

    def test_swift6_main_actor_entry_point(self):
        source = APPKIT.read_text()
        installer = (ROOT / 'native' / 'install_mac_app.sh').read_text()
        self.assertIn('@main\nstruct MacAIHubEntryPoint', source)
        self.assertIn('@MainActor\n    static func main()', source)
        self.assertIn('let contentViews: [NSView]', source)
        self.assertIn('taskTitle = raw.isEmpty ? "(Untitled reminder)" : raw', source)
        self.assertIn('-parse-as-library', installer)

    def test_nil_reminder_title_is_not_force_unwrapped(self):
        # Regression: EKReminder.title is String!; search, sort and dedupe
        # must read it through the nil-safe helper or a nil title crashes.
        source = APPKIT.read_text()
        self.assertIn('func reminderTitle(_ item: EKReminder) -> String', source)
        self.assertIn('reminderTitle(item).localizedCaseInsensitiveContains(query)', source)
        self.assertIn('reminderTitle(a).localizedCaseInsensitiveCompare(reminderTitle(b))', source)
        self.assertNotIn('item.title.localizedCaseInsensitiveContains', source)
        self.assertNotIn('a.title.localizedCaseInsensitiveCompare', source)

    def test_snooze_controls_present(self):
        source = APPKIT.read_text()
        self.assertIn('Snooze +1 day', source)
        self.assertIn('Snooze +1 week', source)
        self.assertIn('func snooze(byDays days: Int)', source)

    def test_menu_bar_live_counts(self):
        source = APPKIT.read_text()
        self.assertIn('func updateStatusBarTitle(open: Int, overdue: Int)', source)
        self.assertIn('NSStatusItem.variableLength', source)

    def test_url_scheme_tab_opening(self):
        source = APPKIT.read_text()
        self.assertIn('handleURLEvent', source)
        self.assertIn('func selectTab(host: String)', source)
        self.assertIn('"overdue": 2', source)
        info = plistlib.loads((ROOT / 'native' / 'Info.plist').read_bytes())
        schemes = info['CFBundleURLTypes'][0]['CFBundleURLSchemes']
        self.assertIn('macaihub', schemes)

    def test_no_swiftui_framework_or_macros(self):
        source = APPKIT.read_text()
        self.assertNotIn('import SwiftUI', source)
        self.assertNotIn('@State ', source)
        self.assertNotIn('@Published ', source)


if __name__ == '__main__':
    unittest.main()
