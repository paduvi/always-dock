#!/bin/bash
# Builds build/AlwaysDock.app.
#
#   ./build.sh                    build only
#   ./build.sh --install          also install and launch it: /Applications, or ~/Applications
#                                 when /Applications is not writable (no admin rights)
#   ./build.sh --install DIR      install into DIR instead
#
# Builds are signed with a self-signed identity made on first use, so macOS keeps AlwaysDock's Accessibility
# access across rebuilds. SIGN_IDENTITY="Apple Development: …" signs with another identity; SIGN_IDENTITY=- ad hoc.
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
        sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
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

# macOS ties Accessibility access to the signature. An ad-hoc signature changes with every build, so each
# build would be a new app to macOS and lose it. The self-signed identity lives in a keychain of its own with
# an empty password, so signing never asks for one.
KEYCHAIN="$HOME/Library/Keychains/AlwaysDock-Signing.keychain-db"
LOCAL_IDENTITY="AlwaysDock Local Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --sign "$SIGN_IDENTITY" "$APP" >/dev/null
else
    if [[ ! -f "$KEYCHAIN" ]]; then
        TMP="$(mktemp -d)"
        /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 36500 -subj "/CN=$LOCAL_IDENTITY" \
            -addext "basicConstraints=critical,CA:false" -addext "keyUsage=critical,digitalSignature" \
            -addext "extendedKeyUsage=critical,codeSigning" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
        /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/identity.p12" \
            -passout pass:import
        security create-keychain -p "" "$KEYCHAIN"
        security set-keychain-settings "$KEYCHAIN"  # never locks by itself
        security import "$TMP/identity.p12" -k "$KEYCHAIN" -P import -T /usr/bin/codesign >/dev/null
        security set-key-partition-list -S apple-tool:,apple: -s -k "" "$KEYCHAIN" >/dev/null
        rm -r "$TMP"
        echo "Created the signing identity \"$LOCAL_IDENTITY\" in $KEYCHAIN"
    fi
    security unlock-keychain -p "" "$KEYCHAIN"
    codesign --force --keychain "$KEYCHAIN" --sign "$LOCAL_IDENTITY" "$APP" >/dev/null
fi

if [[ "$INSTALL" == 0 ]]; then
    echo "Built $APP"
    exit 0
fi

mkdir -p "$DEST"
# Let the running copy quit cleanly (it restores the system Dock) before replacing it.
pkill -x AlwaysDock || true
for _ in {1..50}; do pgrep -x AlwaysDock >/dev/null || break; sleep 0.1; done
if pgrep -x AlwaysDock >/dev/null; then
    echo "AlwaysDock did not quit. Quit it from its menu bar icon and run this again." >&2
    exit 1
fi
rm -rf "$DEST/AlwaysDock.app"
cp -R "$APP" "$DEST/"
open "$DEST/AlwaysDock.app"
echo "Installed and launched $DEST/AlwaysDock.app"

for other in /Applications/AlwaysDock.app "$HOME/Applications/AlwaysDock.app"; do
    if [[ -d "$other" && "$other" != "$DEST/AlwaysDock.app" ]]; then
        echo "Note: another copy is still at $other; delete it to avoid launching the old one."
    fi
done
