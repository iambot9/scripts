#!/bin/bash
# Builds FocusBar.app next to this script.
# Needs Apple's command line tools (xcode-select --install); nothing else.
#
#   ./build.sh          build and run the self-test
#   ./build.sh run      build, then launch (replacing any running copy)

set -euo pipefail
cd "$(dirname "$0")"

APP="FocusBar.app"
BIN="$APP/Contents/MacOS/FocusBar"
ICON="FocusBar.icns"

# Build the app icon once, and again only if its generator changed. Without an
# icon in the bundle, notification banners fall back to a blank placeholder.
if [ ! -f "$ICON" ] || [ make_icon.swift -nt "$ICON" ]; then
  echo "Drawing $ICON"
  gen=$(mktemp -d)
  trap 'rm -rf "$gen"' EXIT
  swiftc -O make_icon.swift -o "$gen/icongen"
  "$gen/icongen" "$gen/FocusBar.iconset" >/dev/null
  iconutil -c icns "$gen/FocusBar.iconset" -o "$ICON"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ICON" "$APP/Contents/Resources/$ICON"

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FocusBar</string>
    <key>CFBundleIdentifier</key><string>local.focusbar</string>
    <key>CFBundleExecutable</key><string>FocusBar</string>
    <key>CFBundleIconFile</key><string>FocusBar</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <!-- Menu bar only: no Dock icon. -->
    <key>LSUIElement</key><true/>
</dict>
</plist>
EOF

# The default SDK can be newer than the installed compiler (after a macOS
# update, before the command line tools catch up), so fall back to the other
# installed SDKs until one compiles.
compile() {
  swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" "$@" FocusBar.swift -o "$BIN"
}
# A code error is reported straight away; only an SDK mismatch moves on.
built=""
for sdk in default $(ls -d /Library/Developer/CommandLineTools/SDKs/MacOSX[0-9]*.[0-9]*.sdk 2>/dev/null | sort -rV); do
  if [ "$sdk" = default ]; then args=(); else args=(-sdk "$sdk"); fi
  if out=$(compile ${args[@]+"${args[@]}"} 2>&1); then built="$sdk"; break; fi
  if ! grep -q "not supported by the compiler" <<<"$out"; then
    echo "$out" >&2
    exit 1
  fi
done
if [ -z "$built" ]; then
  echo "No installed SDK works with this Swift compiler. Update the command line tools." >&2
  exit 1
fi
[ "$built" = default ] || echo "Compiled with $(basename "$built")"
codesign --force --sign - "$APP"

"$BIN" --selftest

if [ "${1:-}" = "run" ]; then
  pkill -x FocusBar 2>/dev/null || true
  open "$APP"
  echo "FocusBar is running; look for the tomato in the menu bar."
else
  echo "Built $PWD/$APP"
fi
