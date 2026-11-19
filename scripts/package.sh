#!/bin/bash
# 릴리스 번들을 만들고 배포용 zip 을 build/ 에 만든다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="$ROOT/build/Explorer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Explorer.app "$ZIP"
shasum -a 256 "$ZIP"
