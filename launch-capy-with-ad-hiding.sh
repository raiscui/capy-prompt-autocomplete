#!/bin/sh
set -eu

if [ "${1-}" = "--install" ]; then
    launcher="$HOME/Applications/Capy (hide ads).app"
    if [ -e "$launcher" ]; then
        identifier=$(/usr/bin/defaults read "$launcher/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
        if [ "$identifier" != "local.capyprompts.adlauncher" ]; then
            printf 'Refusing to overwrite an unrelated app: %s\n' "$launcher" >&2
            exit 1
        fi
    fi
    /bin/mkdir -p "$launcher/Contents/MacOS"
    /bin/cp "$0" "$launcher/Contents/MacOS/CapyAdLauncher"
    /bin/chmod 755 "$launcher/Contents/MacOS/CapyAdLauncher"
    /bin/cat > "$launcher/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.capyprompts.adlauncher</string>
<key>CFBundleExecutable</key><string>CapyAdLauncher</string>
<key>CFBundleName</key><string>Capy (hide ads)</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    /usr/bin/codesign --force --sign - "$launcher"
    printf '%s\n' "$launcher"
    exit 0
fi

fail() {
    printf '%s\n' "$1" >&2
    /usr/bin/osascript -e 'on run argv' -e 'display alert "Capy (hide ads)" message (item 1 of argv) as warning' -e 'end run' "$1" >/dev/null 2>&1 || true
    exit 1
}

capy_app='/Applications/Capy.app'
capy_binary="$capy_app/Contents/MacOS/Capy"
prompts_app='/Applications/Capy Prompts.app'
[ -x "$capy_binary" ] || fail 'Capy was not found in /Applications.'
[ -d "$prompts_app" ] || fail 'Capy Prompts was not found in /Applications.'

listener=$(/usr/sbin/lsof -nP -t -iTCP:9333 -sTCP:LISTEN 2>/dev/null || true)
if [ -n "$listener" ]; then
    listener_command=$(/bin/ps -p "$listener" -o comm= 2>/dev/null || true)
    [ "$listener_command" = "$capy_binary" ] || fail 'Port 9333 is in use by another process. Quit that process or use Capy without ad hiding.'
    /usr/bin/open -a "$capy_app"
elif /usr/bin/pgrep -x Capy >/dev/null 2>&1; then
    fail 'Capy is already running without the ad-hiding connection. Quit Capy, then reopen it using Capy (hide ads).'
else
    /usr/bin/open -a "$capy_app" --args --remote-debugging-address=127.0.0.1 --remote-debugging-port=9333
fi
/usr/bin/open -g -a "$prompts_app"
