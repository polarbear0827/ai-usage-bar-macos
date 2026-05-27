#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="0.1.0"
APP_SOURCE="$ROOT_DIR/CodexUsageBar/build/CodexUsageBar.app"
DIST_DIR="$ROOT_DIR/dist"
PKGROOT="$DIST_DIR/pkgroot"
APP_TARGET="$PKGROOT/Applications/AI Usage Bar.app"
PKG_PATH="$DIST_DIR/AIUsageBar-macOS-$VERSION.pkg"

"$ROOT_DIR/CodexUsageBar/build.sh" >/dev/null

rm -rf "$PKGROOT"
mkdir -p "$PKGROOT/Applications" "$DIST_DIR"
ditto --norsrc "$APP_SOURCE" "$APP_TARGET"

if command -v xattr >/dev/null 2>&1; then
  xattr -cr "$APP_TARGET" >/dev/null 2>&1 || true
  xattr -d com.apple.FinderInfo "$APP_TARGET" >/dev/null 2>&1 || true
  xattr -d 'com.apple.fileprovider.fpfs#P' "$APP_TARGET" >/dev/null 2>&1 || true
  find "$PKGROOT" -print0 | xargs -0 xattr -c >/dev/null 2>&1 || true
fi

find "$PKGROOT" -name '._*' -delete

pkgbuild \
  --root "$PKGROOT" \
  --identifier "local.aiusagebar.pkg" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG_PATH"

rm -rf "$PKGROOT"

echo "$PKG_PATH"
