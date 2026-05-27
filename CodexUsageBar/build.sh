#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="${AI_USAGE_BAR_BUILD_DIR:-$ROOT_DIR/build}"
APP_DIR="$BUILD_DIR/CodexUsageBar.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
HELPER_DIR="$BUILD_DIR/helper"
ARCHES=("arm64" "x86_64")
DEPLOYMENT_TARGET="13.0"

export MACOSX_DEPLOYMENT_TARGET="$DEPLOYMENT_TARGET"

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

build_universal() {
  local output="$1"
  shift
  local slices=()

  for arch in "${ARCHES[@]}"; do
    local slice="$HELPER_DIR/$(basename "$output").$arch"
    swiftc \
      -swift-version 5 \
      -O \
      -target "$arch-apple-macos$DEPLOYMENT_TARGET" \
      "$@" \
      -o "$slice"
    slices+=("$slice")
  done

  lipo -create "${slices[@]}" -output "$output"
}

rm -rf "$APP_DIR" "$HELPER_DIR"
mkdir -p "$MACOS_DIR" "$APP_DIR/Contents/Resources" "$HELPER_DIR"
cp "$ROOT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"

build_universal \
  "$HELPER_DIR/statusline-bridge" \
  "$ROOT_DIR/Sources/statusline_bridge.swift" \

cp "$HELPER_DIR/statusline-bridge" "$APP_DIR/Contents/Resources/statusline-bridge"

build_universal \
  "$MACOS_DIR/CodexUsageBar" \
  -framework Cocoa \
  "$ROOT_DIR/Sources/main.swift"

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
