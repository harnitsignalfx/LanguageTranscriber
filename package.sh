#!/usr/bin/env bash
# Package the built .app into a shareable zip in dist/.
# Includes a short INSTALL.txt so peers know how to get past Gatekeeper.
#
# Usage:
#   ./package.sh                  # zip only
#   ./package.sh --dmg            # zip + a .dmg installer (drag-to-Applications)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$ROOT_DIR/build/LanguageTranscriber.app"
DIST="$ROOT_DIR/dist"
APP_NAME="LanguageTranscriber"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.0")"
STAMP="$(date +%Y%m%d)"
BASE="${APP_NAME}-${VERSION}-${STAMP}"

want_dmg=false
[[ "${1:-}" == "--dmg" ]] && want_dmg=true

if [[ ! -d "$APP" ]]; then
    echo "Error: $APP not found. Run ./build.sh first." >&2
    exit 1
fi

mkdir -p "$DIST"
rm -f "$DIST/${BASE}.zip" "$DIST/${BASE}.dmg"

# --- INSTALL.txt for peers ------------------------------------------------
INSTALL="$DIST/INSTALL.txt"
cat > "$INSTALL" <<EOF
LanguageTranscriber — install instructions
==========================================

1. Unzip this archive.
2. Drag LanguageTranscriber.app into /Applications.
3. First launch: this app is signed ad-hoc (no Apple Developer ID), so macOS
   will refuse to open it normally. Use ONE of the two workarounds below:

   a) Right-click → Open. In the warning dialog, click "Open Anyway".
      You only have to do this the first time.

   b) Or run in Terminal:
        xattr -cr /Applications/LanguageTranscriber.app
      Then double-click as usual.

4. After it launches, open Settings (⌘,) and paste your OpenAI API key.
   The key is stored in your macOS Keychain. It is NOT bundled with the app.

5. macOS will ask for Microphone permission the first time you press Start.
   For System Audio capture (Zoom/Meet/Webex), it will also ask for Screen
   Recording permission. After granting Screen Recording, fully quit and
   relaunch the app once so the new permission takes effect.

Requires macOS 13 (Ventura) or later.
Built on $(date +%Y-%m-%d).
EOF

# --- ZIP ------------------------------------------------------------------
echo "==> Building zip…"
# ditto preserves all macOS metadata (extended attributes, code signature, etc.)
ditto -c -k --keepParent "$APP" "$DIST/${BASE}.zip"
# Append INSTALL.txt to the zip so it travels with the .app
(cd "$DIST" && zip -j "${BASE}.zip" "INSTALL.txt" >/dev/null)

ZIP_SIZE=$(du -h "$DIST/${BASE}.zip" | awk '{print $1}')
echo "    Wrote dist/${BASE}.zip ($ZIP_SIZE)"

# --- DMG (optional) -------------------------------------------------------
if $want_dmg; then
    echo "==> Building dmg…"
    DMG_STAGE="$(mktemp -d)"
    cp -R "$APP" "$DMG_STAGE/"
    cp "$INSTALL" "$DMG_STAGE/INSTALL.txt"
    # Symlink /Applications so the user can drag the app into it
    ln -s /Applications "$DMG_STAGE/Applications"

    hdiutil create \
        -volname "$APP_NAME" \
        -srcfolder "$DMG_STAGE" \
        -ov -format UDZO \
        "$DIST/${BASE}.dmg" >/dev/null

    rm -rf "$DMG_STAGE"
    DMG_SIZE=$(du -h "$DIST/${BASE}.dmg" | awk '{print $1}')
    echo "    Wrote dist/${BASE}.dmg ($DMG_SIZE)"
fi

echo
echo "Done. Share these files:"
ls -lh "$DIST"/${BASE}.* | awk '{print "  " $NF, "(" $5 ")"}'
echo
echo "Recipient instructions are in INSTALL.txt (also bundled inside the zip)."
echo "They will need their own OpenAI API key — paste it via Settings (⌘,) on first run."
