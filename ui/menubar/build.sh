#!/usr/bin/env bash
# ui/menubar/build.sh - build KachingBar.app (the Kaching menu bar dot) from every ui/menubar/*.swift.
#
#   build.sh <target-dir> [--force]   builds <target-dir>/KachingBar.app; prints its path
#   build.sh --hash                   prints the source hash only (install.sh compares it with the installed app)
#
# Idempotent: the bundle's Info.plist carries KachingSourceHash (sha256 of every .swift file, this script and the
# swiftc version). When the bundle in <target-dir> already has the current hash, nothing is compiled or written
# ("up to date"); --force rebuilds anyway. A new bundle is built next to the target and swapped in with mv, so a
# failed build leaves the old one in place. Needs /usr/bin/swiftc (Xcode command line tools); no Xcode project.
# Env: SWIFTC (default /usr/bin/swiftc, else swiftc on PATH)
set -euo pipefail
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(find "$HERE" -maxdepth 1 -name '*.swift' | LC_ALL=C sort)
BUNDLE_ID=org.kaching.menubar
NAME=KachingBar

SWIFTC=${SWIFTC:-}
if [ -z "$SWIFTC" ]; then
  if [ -x /usr/bin/swiftc ]; then SWIFTC=/usr/bin/swiftc; else SWIFTC=$(command -v swiftc 2>/dev/null || true); fi
fi
[ -n "$SWIFTC" ] && [ -x "$SWIFTC" ] || { echo "build: swiftc not found (install the Xcode command line tools: xcode-select --install)" >&2; exit 2; }

src_hash() {
  { cat "${SRCS[@]}" "$HERE/build.sh"; "$SWIFTC" --version 2>/dev/null; } | shasum -a 256 | cut -c1-16
}

TARGET=""; FORCE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --hash) src_hash; exit 0 ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^set -euo/p' "${BASH_SOURCE[0]}" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    -*) echo "build: unknown argument $1" >&2; exit 64 ;;
    *) [ -z "$TARGET" ] || { echo "build: one target dir only" >&2; exit 64; }; TARGET=$1; shift ;;
  esac
done
[ -n "$TARGET" ] || { echo "usage: build.sh <target-dir> [--force] | --hash" >&2; exit 64; }

mkdir -p "$TARGET"
TARGET=$(cd "$TARGET" && pwd -P)
APP="$TARGET/$NAME.app"
HASH=$(src_hash)

if [ "$FORCE" -eq 0 ] && [ -f "$APP/Contents/Info.plist" ] && [ -x "$APP/Contents/MacOS/$NAME" ] \
   && [ "$(/usr/bin/plutil -extract KachingSourceHash raw "$APP/Contents/Info.plist" 2>/dev/null || true)" = "$HASH" ]; then
  echo "up to date: $APP"; exit 0
fi

STAGE=$(mktemp -d "$TARGET/.$NAME.build.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
NEW="$STAGE/$NAME.app"
mkdir -p "$NEW/Contents/MacOS" "$NEW/Contents/Resources"
"$SWIFTC" -O -swift-version 6 -parse-as-library -module-name "$NAME" -framework AppKit -framework ApplicationServices \
  -framework Carbon "${SRCS[@]}" -o "$NEW/Contents/MacOS/$NAME"

cat >"$NEW/Contents/Info.plist" <<EOP
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>Kaching menu bar dot</string>
  <key>CFBundleExecutable</key><string>$NAME</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSAppleEventsUsageDescription</key><string>The Kaching hotkeys move and raise your Terminal windows; the voice shortcut reads which Terminal tab is in front and wakes the voice dispatcher in its tab.</string>
  <key>KachingSourceHash</key><string>$HASH</string>
</dict>
</plist>
EOP
/usr/bin/plutil -lint -s "$NEW/Contents/Info.plist"
printf 'APPL????' >"$NEW/Contents/PkgInfo"
# ad-hoc signature over the whole bundle (binds Info.plist); the linker's own ad-hoc signature covers only the binary
if [ -x /usr/bin/codesign ]; then /usr/bin/codesign --force --sign - "$NEW" >/dev/null 2>&1 || true; fi

if [ -e "$APP" ]; then
  mv "$APP" "$STAGE/old.app"
fi
mv "$NEW" "$APP"
echo "built: $APP"
