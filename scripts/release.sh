#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
  VERSION="$(python3 - <<'PY'
import re, pathlib
text = pathlib.Path("project.yml").read_text()
m = re.search(r'MARKETING_VERSION:\s*"([^"]+)"', text)
print(m.group(1) if m else "")
PY
)"
fi

if [[ -z "$VERSION" ]]; then
  echo "Usage: $0 <version>" >&2
  exit 1
fi

TAG="v${VERSION#v}"
VERSION="${TAG#v}"
REPO="EEliberto/Reset-macOS"
DERIVED="/tmp/Reset-Release-${VERSION}"
STAGE="$(mktemp -d /tmp/reset-dmg.XXXXXX)"
UPDATES="$ROOT/updates"
DMG_NAME="Reset!-${VERSION}.dmg"
DMG="$UPDATES/$DMG_NAME"
KEY_FILE="$ROOT/Secrets/sparkle_ed25519"
SPARKLE_TOOLS="$ROOT/tools/sparkle/bin"

echo "==> Version ${VERSION}  Tag ${TAG}"

if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
  echo "==> Fetching Sparkle tools"
  mkdir -p "$ROOT/tools/sparkle"
  curl -sL "https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-2.8.1.tar.xz" \
    | tar -xJ -C "$ROOT/tools/sparkle" --strip-components=0
  # tarball extracts bin/ at top level of tools/sparkle or nested — normalize
  if [[ ! -x "$SPARKLE_TOOLS/generate_appcast" ]]; then
    FOUND="$(find "$ROOT/tools/sparkle" -type f -name generate_appcast | head -1)"
    SPARKLE_TOOLS="$(dirname "$FOUND")"
  fi
fi

if [[ ! -f "$KEY_FILE" ]]; then
  echo "Missing Sparkle private key at Secrets/sparkle_ed25519 (see LOCAL_NOTES.md)" >&2
  exit 1
fi

command -v xcodegen >/dev/null && xcodegen generate

echo "==> Building Release"
xcodebuild \
  -scheme Reset \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  clean build | rg 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' || true

APP="$DERIVED/Build/Products/Release/Reset!.app"
if [[ ! -d "$APP" ]]; then
  echo "Build failed: missing $APP" >&2
  exit 1
fi

echo "==> Packaging DMG"
mkdir -p "$UPDATES"
rm -f "$DMG"
ditto "$APP" "$STAGE/Reset!.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -ov -volname "Reset!" -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
hdiutil verify "$DMG"

NOTES_HTML="$UPDATES/Reset!-${VERSION}.html"
cat > "$NOTES_HTML" <<EOF
<!DOCTYPE html>
<html lang="zh-Hans">
<body>
  <h2>Reset! ${VERSION}</h2>
  <ul>
    <li>菜单栏额度监控（Codex / Claude Code / Cursor / Antigravity）</li>
    <li>Telegram 推送与多设备协调</li>
    <li>Sparkle 自动更新</li>
  </ul>
</body>
</html>
EOF

echo "==> Generating Sparkle appcast"
DOWNLOAD_PREFIX="https://github.com/${REPO}/releases/download/${TAG}/"
"$SPARKLE_TOOLS/generate_appcast" \
  --ed-key-file "$KEY_FILE" \
  --download-url-prefix "$DOWNLOAD_PREFIX" \
  -o appcast.xml \
  "$UPDATES"
cp -f "$UPDATES/appcast.xml" "$ROOT/appcast.xml" 2>/dev/null || true
# generate_appcast writes into archives dir using -o name
if [[ -f "$UPDATES/appcast.xml" ]]; then
  cp -f "$UPDATES/appcast.xml" "$ROOT/appcast.xml"
fi

NOTES="$(cat <<EOF
## Reset! ${VERSION}

- Sparkle 自动更新（appcast）
- Telegram「确认并测试推送」
- 本机额度监控 + iCloud 推送协调

安装：打开 DMG，将 Reset! 拖到 Applications。
EOF
)"

echo "==> Publishing GitHub Release ${TAG}"
cp -f "$DMG" "$ROOT/Reset!.dmg"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$ROOT/appcast.xml" -R "$REPO" --clobber
else
  gh release create "$TAG" "$DMG" "$ROOT/appcast.xml" \
    -R "$REPO" \
    --title "Reset! ${VERSION}" \
    --notes "$NOTES"
fi

echo "==> Done"
echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Appcast: https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
echo "Remember to commit and push updated appcast.xml to main."
