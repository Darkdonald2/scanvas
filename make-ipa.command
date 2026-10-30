#!/bin/bash
# Builds Scanvas.ipa for AltStore / SideStore. Double-click in Finder, or run: bash make-ipa.command
# The .ipa is unsigned on purpose: AltStore signs it with your own Apple ID when you install it.
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "Installing XcodeGen with Homebrew…"
  brew install xcodegen
fi

echo "Generating the Xcode project…"
xcodegen

echo "Building (this takes a few minutes the first time)…"
rm -rf build Scanvas.ipa
mkdir -p build
xcodebuild \
  -project Scanvas.xcodeproj \
  -scheme Scanvas \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedData \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" \
  build > build/xcodebuild.log 2>&1 || true
grep -E "error:|BUILD (SUCCEEDED|FAILED)" build/xcodebuild.log | sort -u | head -40 || true

APP="build/DerivedData/Build/Products/Release-iphoneos/Scanvas.app"
if [ ! -d "$APP" ]; then
  echo ""
  echo "Build failed. The full log is in build/xcodebuild.log."
  echo "Send Claude the error lines above (or the log file)."
  exit 1
fi

mkdir -p build/Payload
cp -R "$APP" build/Payload/
(cd build && zip -qry ../Scanvas.ipa Payload)
rm -rf build

echo ""
echo "Done: $(pwd)/Scanvas.ipa"
echo "AirDrop it to your iPhone (or save it to iCloud Drive), then in AltStore: My Apps › + › Scanvas.ipa"
open -R Scanvas.ipa || true
