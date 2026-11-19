#!/bin/bash
# 릴리스 번들을 만들고 배포용 zip 을 build/ 에 만든다.
# SIGN_IDENTITY 와 NOTARY_PROFILE(notarytool store-credentials 로 저장한 이름)을 주면
# Developer ID 로 서명하고 공증을 받은 뒤 앱에 공증 티켓을 붙여 zip 을 다시 만든다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

scripts/build-app.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="$ROOT/build/Explorer-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent build/Explorer.app "$ZIP"
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
    [[ -n "${SIGN_IDENTITY:-}" ]] || { echo "NOTARY_PROFILE 은 SIGN_IDENTITY 와 함께 써야 합니다" >&2; exit 1; }
    echo "==> 공증 요청"
    xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple build/Explorer.app
    rm -f "$ZIP"
    ditto -c -k --sequesterRsrc --keepParent build/Explorer.app "$ZIP"
    spctl --assess --type execute --verbose build/Explorer.app
fi
shasum -a 256 "$ZIP"
