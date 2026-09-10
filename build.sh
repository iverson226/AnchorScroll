#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p .build/module-cache
swiftc -swift-version 5 -O -parse-as-library -module-cache-path .build/module-cache \
  Sources/Core.swift Tests/CoreTests.swift -o .build/CoreTests
.build/CoreTests > .build/core-tests.log
tail -1 .build/core-tests.log
swiftc -swift-version 5 -O -parse-as-library -module-cache-path .build/module-cache \
  -target arm64-apple-macos14.0 Sources/*.swift -o .build/AnchorScroll \
  -framework AppKit -framework SwiftUI -framework ApplicationServices -framework ServiceManagement
APP="${ANCHORSCROLL_APP_OUTPUT:-dist/AnchorScroll.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/AnchorScroll "$APP/Contents/MacOS/AnchorScroll"
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/AnchorScroll.icns "$APP/Contents/Resources/AnchorScroll.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built: $APP"
