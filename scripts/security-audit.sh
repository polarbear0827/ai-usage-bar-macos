#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

forbidden='Keychain|Cookies|sessionKey|encrypted_value|Safe Storage|AXIsProcessTrusted|ApplicationServices|Accessibility|Screen Recording|Full Disk Access|IndexedDB|Local Storage|Claude Safe Storage'

if rg -n -i "$forbidden" "$ROOT_DIR/CodexUsageBar/Sources" "$ROOT_DIR/scripts" "$ROOT_DIR/README.md" "$ROOT_DIR/SECURITY.md"; then
  echo
  echo "Review the matches above. Security documentation may mention forbidden storage only to document that the app does not read it."
else
  echo "No forbidden sensitive-storage access patterns found."
fi

if rg -n "sqlite3|security find-generic-password|osascript|curl|https?://|URLSession|NSAppleScript" "$ROOT_DIR/CodexUsageBar/Sources"; then
  echo
  echo "Review the matches above. Network, Keychain, shell, or AppleScript access should be intentional."
else
  echo "No network, Keychain CLI, AppleScript, or SQLite access found in app sources."
fi
