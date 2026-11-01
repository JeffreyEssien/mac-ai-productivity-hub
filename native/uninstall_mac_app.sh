#!/bin/bash
set -euo pipefail
TARGET="$HOME/Applications/Mac AI Productivity Hub.app"
if [[ -d "$TARGET" ]]; then
  echo "Move this app to Trash in Finder to uninstall: $TARGET"
  echo "Your Apple Reminders and existing Python launchd schedules are not deleted."
else
  echo "Native app is not installed at $TARGET"
fi
