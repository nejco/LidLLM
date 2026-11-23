#!/bin/sh
# Builds LidLLM.app next to this script.  ./build.sh [--install]  (--install copies it to /Applications)
set -e
cd "$(dirname "$0")"
APP=LidLLM.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target arm64-apple-macos14 Sources/main.swift -o "$APP/Contents/MacOS/LidLLM"
cp Resources/Info.plist "$APP/Contents/"
cp Resources/setup-sudo.sh slack-app-manifest.yml "$APP/Contents/Resources/"
codesign --force --sign - "$APP"
echo "Built $APP"
if [ "$1" = "--install" ]; then
  pkill -x LidLLM 2>/dev/null || true
  rm -rf /Applications/LidLLM.app && cp -R "$APP" /Applications/
  echo "Installed to /Applications/LidLLM.app"
fi
