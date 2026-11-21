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
signer_file="$HOME/Library/Application Support/CapyPrompts/signing-identity.sha1"
if [ -e "$signer_file" ]; then
    signer=$(cat "$signer_file" | tr 'A-F' 'a-f')
    case "$signer" in
        *[!0-9a-f]*|'') echo 'Invalid signing certificate fingerprint' >&2; exit 1 ;;
    esac
    [ "${#signer}" -eq 40 ] || { echo 'Expected a 40-digit certificate fingerprint' >&2; exit 1; }
    requirement="designated => identifier \"$bundle_id\" and certificate leaf = H\"$signer\""
    /usr/bin/codesign --force --sign "$signer" --identifier "$bundle_id" \
        --requirements "=$requirement" --timestamp=none "$app"
    actual=$(/usr/bin/codesign -d -r- "$app" 2>&1 | sed -n '/^designated => /p')
    [ "$actual" = "$requirement" ] || { echo 'Unexpected designated requirement' >&2; exit 1; }
else
    printf 'No local signer configured; using an ad-hoc signature tied to this build.\n' >&2
    /usr/bin/codesign --force --sign - --identifier "$bundle_id" "$app"
fi
/usr/bin/codesign --verify --strict "$app"
printf '%s\n' "$app"
