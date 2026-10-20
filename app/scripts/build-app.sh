#!/usr/bin/env bash
# Builds "Little CI.app" (release, ad-hoc signed) into app/build/.
#   app/scripts/build-app.sh            build
#   app/scripts/build-app.sh --install  also copy it to /Applications, replacing a quit copy
set -euo pipefail

app_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bundle="$app_dir/build/Little CI.app"

swift build --package-path "$app_dir" -c release --product LittleCI
binary="$(swift build --package-path "$app_dir" -c release --show-bin-path)/LittleCI"

rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp "$binary" "$bundle/Contents/MacOS/LittleCI"
cat >"$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>LittleCI</string>
  <key>CFBundleIdentifier</key><string>dev.little-ci.menubar</string>
  <key>CFBundleName</key><string>Little CI</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$bundle"
echo "built $bundle"

if [ "${1:-}" = --install ]; then
  if pgrep -x LittleCI >/dev/null; then
    echo "Little CI is running; quit it first" >&2
    exit 1
  fi
  rm -rf "/Applications/Little CI.app.new"
  cp -R "$bundle" "/Applications/Little CI.app.new"
  rm -rf "/Applications/Little CI.app"
  mv "/Applications/Little CI.app.new" "/Applications/Little CI.app"
  echo "installed /Applications/Little CI.app"
fi
