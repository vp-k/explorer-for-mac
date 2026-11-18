#!/bin/bash
# swift build -c release 후 build/Explorer.app 번들을 만들고 ad-hoc 서명한다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Explorer.app"
CONTENTS="$APP/Contents"

echo "==> swift build -c release"
swift build -c release --product Explorer
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> 번들 생성: $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/Explorer" "$CONTENTS/MacOS/Explorer"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$CONTENTS/PkgInfo"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "==> ad-hoc 서명"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> 완료: $APP"
