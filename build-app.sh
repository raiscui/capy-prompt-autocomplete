#!/bin/sh
set -eu
cd "$(dirname "$0")"
swift build -c release
bin=$(swift build -c release --show-bin-path)
app="$PWD/.build/Capy Prompts.app"
mkdir -p "$app/Contents/MacOS"
cp "$bin/CapyPrompts" "$app/Contents/MacOS/CapyPrompts"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
printf '%s\n' "$app"
