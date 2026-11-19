#!/bin/bash
# swift build -c release 후 build/Explorer.app 번들을 만들고 ad-hoc 서명한다.
# CONFIG=debug 로 실행하면 디버그 빌드로 번들을 만든다 (스냅숏·하네스 확인용).
# release 는 Apple Silicon 과 Intel 을 함께 담은 유니버설 바이너리다.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Explorer.app"
CONTENTS="$APP/Contents"

CONFIG="${CONFIG:-release}"
echo "==> swift build -c $CONFIG"
ARCH_FLAGS=()
[[ "$CONFIG" == release ]] && ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" --product Explorer ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

echo "==> 번들 생성: $APP"
rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$BIN_DIR/Explorer" "$CONTENTS/MacOS/Explorer"
cp "$ROOT/Resources/Info.plist" "$CONTENTS/Info.plist"
if [[ -f "$ROOT/Resources/AppIcon.icns" ]]; then
    cp "$ROOT/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"
fi
for lproj in "$ROOT"/Resources/*.lproj; do
    cp -R "$lproj" "$CONTENTS/Resources/"
done
printf 'APPL????' > "$CONTENTS/PkgInfo"
plutil -lint "$CONTENTS/Info.plist" >/dev/null

echo "==> ad-hoc 서명"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --strict "$APP"

echo "==> 완료: $APP"
