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
trap 'rm -rf "$STAGE"' EXIT
UPDATES="$ROOT/updates"
DMG_NAME="Reset-${VERSION}.dmg"
DMG="$UPDATES/$DMG_NAME"
ZIP_NAME="Reset-${VERSION}.zip"
ZIP="$UPDATES/$ZIP_NAME"
KEY_FILE="$ROOT/Secrets/sparkle_ed25519"
SPARKLE_TOOLS="$ROOT/tools/sparkle/bin"
RELEASE_NOTES="$ROOT/RELEASE_NOTES_${VERSION}.md"

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
mkdir -p "$DERIVED"
BUILD_LOG="$DERIVED/build.log"
if ! xcodebuild \
    -scheme Reset \
    -configuration Release \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED" \
    ONLY_ACTIVE_ARCH=NO ARCHS="arm64 x86_64" \
    clean build > "$BUILD_LOG" 2>&1; then
  rg 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' "$BUILD_LOG" || true
  exit 1
fi
rg 'error:|warning:|BUILD SUCCEEDED|BUILD FAILED' "$BUILD_LOG" || true

APP="$DERIVED/Build/Products/Release/Reset!.app"
if [[ ! -d "$APP" ]]; then
  echo "Build failed: missing $APP" >&2
  exit 1
fi

SHORT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$SHORT_VERSION" != "$VERSION" ]]; then
  echo "Version mismatch: release is ${VERSION}, app reports ${SHORT_VERSION}" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Packaging DMG and Sparkle ZIP"
mkdir -p "$UPDATES"
ditto "$APP" "$STAGE/Reset!.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -ov -volname "Reset!" -srcfolder "$STAGE" -format UDZO "$DMG"
hdiutil verify "$DMG"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

NOTES_HTML="$ROOT/RELEASE_NOTES_${VERSION}.html"
if [[ ! -f "$NOTES_HTML" ]]; then
  NOTES_HTML="$UPDATES/Reset-${VERSION}.html"
  cat > "$NOTES_HTML" <<EOF
<!DOCTYPE html>
<html lang="zh-Hans">
<body>
  <h2>Reset! ${VERSION}</h2>
  <ul>
    <li>功能改进与问题修复。</li>
  </ul>
</body>
</html>
EOF
fi

echo "==> Signing Sparkle update"
SIGNATURE_OUTPUT="$("$SPARKLE_TOOLS/sign_update" --ed-key-file "$KEY_FILE" "$ZIP")"
ED_SIGNATURE="$(printf '%s\n' "$SIGNATURE_OUTPUT" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
ARCHIVE_LENGTH="$(printf '%s\n' "$SIGNATURE_OUTPUT" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"
if [[ -z "$ED_SIGNATURE" || -z "$ARCHIVE_LENGTH" ]]; then
  echo "Unable to parse Sparkle signature output" >&2
  exit 1
fi

PUB_DATE="$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')"
cat > "$ROOT/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Reset!</title>
    <link>https://github.com/${REPO}</link>
    <description>Reset! Sparkle appcast</description>
    <language>zh-Hans</language>
    <item>
      <title>Version ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD_VERSION}</sparkle:version>
      <sparkle:shortVersionString>${SHORT_VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
      <description><![CDATA[$(sed -n '/<body>/,/<\/body>/p' "$NOTES_HTML")]]></description>
      <enclosure
        url="https://github.com/${REPO}/releases/download/${TAG}/${ZIP_NAME}"
        length="${ARCHIVE_LENGTH}"
        type="application/octet-stream"
        sparkle:edSignature="${ED_SIGNATURE}" />
    </item>
  </channel>
</rss>
EOF

if [[ -f "$RELEASE_NOTES" ]]; then
  NOTES_FILE="$RELEASE_NOTES"
else
  NOTES_FILE="$UPDATES/Reset-${VERSION}.md"
  printf '# Reset! %s\n\n功能改进与问题修复。\n' "$VERSION" > "$NOTES_FILE"
fi

echo "==> Publishing GitHub Release ${TAG}"
cp -f "$DMG" "$ROOT/Reset!.dmg"
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" "$DMG" "$ZIP" "$ROOT/appcast.xml" -R "$REPO" --clobber
  gh release edit "$TAG" -R "$REPO" --title "Reset! ${VERSION}" --notes-file "$NOTES_FILE" --latest
else
  gh release create "$TAG" "$DMG" "$ZIP" "$ROOT/appcast.xml" \
    -R "$REPO" \
    --target "$(git rev-parse HEAD)" \
    --latest \
    --title "Reset! ${VERSION}" \
    --notes-file "$NOTES_FILE"
fi

echo "==> Done"
echo "Release: https://github.com/${REPO}/releases/tag/${TAG}"
echo "Appcast: https://raw.githubusercontent.com/${REPO}/main/appcast.xml"
echo "Remember to commit and push updated appcast.xml to main."
