#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Confetti"
BUILD_DIR=".build/release"
APP_BUNDLE="build/${APP_NAME}.app"

echo "==> Compiling (release)…"
swift build -c release

echo "==> Assembling .app bundle at ${APP_BUNDLE}"
rm -rf "${APP_BUNDLE}"
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

cp "${BUILD_DIR}/${APP_NAME}" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
cp "Resources/Info.plist"    "${APP_BUNDLE}/Contents/Info.plist"

if [ ! -f "Resources/AppIcon.icns" ]; then
  echo "==> Generating AppIcon.icns from emoji"
  ./generate-icon.sh
fi
cp "Resources/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"

echo "==> Ad-hoc signing"
codesign --force --deep --sign - "${APP_BUNDLE}"

echo "==> Done. Launch with:"
echo "    open ${APP_BUNDLE}"
echo "    # or move it: mv ${APP_BUNDLE} /Applications/"
