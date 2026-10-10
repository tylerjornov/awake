#!/bin/bash
# Builds dist/Awake.app (menu-bar, no Dock icon) and dist/awake.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --product Awake --product awake
APP="dist/Awake.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist
cp ".build/release/Awake" "$APP/Contents/MacOS/Awake"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"
cp ".build/release/awake" "dist/awake"
chmod 755 "dist/awake" "$APP/Contents/MacOS/Awake"
ln -sfn awake "dist/asleep"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
  codesign --force --sign "$SIGN_IDENTITY" "dist/awake"
else
  codesign --force --sign - "$APP" || true
fi
echo "Built $APP and dist/awake (symlink dist/asleep)."
