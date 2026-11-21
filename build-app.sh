#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
bin=$(swift build -c release --show-bin-path)
app="$PWD/.build/Capy Prompts.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/CapyPrompts" "$app/Contents/MacOS/CapyPrompts"
cp Info.plist "$app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist")
if [ "$bundle_id" != 'local.capyprompts.companion' ]; then
    printf 'Unexpected Capy Prompts bundle identifier: %s\n' "$bundle_id" >&2
    exit 1
fi
/usr/bin/codesign --force --sign - --identifier "$bundle_id" "$app"
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
