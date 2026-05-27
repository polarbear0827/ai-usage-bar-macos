#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$ROOT_DIR/build/CodexUsageBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
HELPER_DIR="$ROOT_DIR/build/helper"

clean_bundle_xattrs() {
  command -v xattr >/dev/null 2>&1 || return 0
  xattr -cr "$APP_DIR" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
    xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" >/dev/null 2>&1 || true
    sleep 0.05
  done
  xattr -d com.apple.FinderInfo "$APP_DIR" >/dev/null 2>&1 || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_DIR" >/dev/null 2>&1 || true
}

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$APP_DIR/Contents/Resources" "$HELPER_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

swiftc \
  -swift-version 5 \
  -O \
  "$ROOT_DIR/Sources/statusline_bridge.swift" \
  -o "$HELPER_DIR/statusline-bridge"

cp "$HELPER_DIR/statusline-bridge" "$APP_DIR/Contents/Resources/statusline-bridge"

swiftc \
  -swift-version 5 \
  -O \
  -framework Cocoa \
  "$ROOT_DIR/Sources/main.swift" \
  -o "$MACOS_DIR/CodexUsageBar"

chmod +x "$MACOS_DIR/CodexUsageBar"

clean_bundle_xattrs

if command -v codesign >/dev/null 2>&1; then
  rm -rf "$APP_DIR/Contents/_CodeSignature"
  codesign --remove-signature "$MACOS_DIR/CodexUsageBar" >/dev/null 2>&1 || true
  clean_bundle_xattrs
  codesign --force --deep --sign - "$APP_DIR"
  clean_bundle_xattrs
fi

echo "$APP_DIR"
