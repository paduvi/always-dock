#!/bin/bash
# Builds build/AlwaysDock.app.
#
#   ./build.sh                    build only
#   ./build.sh --install          also install and launch it: /Applications, or ~/Applications
#                                 when /Applications is not writable (no admin rights)
#   ./build.sh --install DIR      install into DIR instead
#
# A stable identity (SIGN_IDENTITY="Apple Development: …") keeps the Accessibility grant across rebuilds.
set -euo pipefail

INSTALL=0
DEST=""
case "${1:-}" in
    "") ;;
    --install)
        INSTALL=1
        if [[ -n "${2:-}" ]]; then
            # Resolve now, relative to where the script was called from.
            DEST="$(mkdir -p "$2" && cd "$2" && pwd)"
        elif [[ -w /Applications ]]; then
            DEST=/Applications
        else
            DEST="$HOME/Applications"
        fi
        ;;
    *)
        sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
        exit 1
        ;;
esac

cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/AlwaysDock"

APP=build/AlwaysDock.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AlwaysDock"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP" >/dev/null

if [[ "$INSTALL" == 0 ]]; then
    echo "Built $APP"
    exit 0
fi

mkdir -p "$DEST"
# Let the running copy quit cleanly (it restores the system Dock) before replacing it.
pkill -x AlwaysDock || true
for _ in {1..50}; do pgrep -x AlwaysDock >/dev/null || break; sleep 0.1; done
rm -rf "$DEST/AlwaysDock.app"
cp -R "$APP" "$DEST/"
open "$DEST/AlwaysDock.app"
echo "Installed and launched $DEST/AlwaysDock.app"

for other in /Applications/AlwaysDock.app "$HOME/Applications/AlwaysDock.app"; do
    if [[ -d "$other" && "$other" != "$DEST/AlwaysDock.app" ]]; then
        echo "Note: another copy is still at $other; delete it to avoid launching the old one."
    fi
done
