#!/bin/zsh
# Builds a Developer ID signed, notarized PennyBar.dmg in ./build.
# Usage: scripts/release.sh
#   SIGN_IDENTITY   codesigning identity (default: the first "Developer ID Application" in the keychain)
#   NOTARY_PROFILE  notarytool keychain profile (default: pennybar), created once with
#                   xcrun notarytool store-credentials pennybar --apple-id <id> --team-id <team>
#   APP_STORE_CONNECT_KEY_ID, APP_STORE_CONNECT_ISSUER_ID, APP_STORE_CONNECT_API_KEY_BASE64
#                   notarize with an App Store Connect API key instead of the profile (used by CI)
#   VERSION, BUILD_NUMBER  passed through to bundle.sh to stamp Info.plist
set -euo pipefail

root=${0:A:h:h}
cd "$root"

identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Developer ID Application/ { print $2; exit }')}
[[ -n "$identity" ]] || { echo "error: no Developer ID Application identity found" >&2; exit 1 }

if [[ -n "${APP_STORE_CONNECT_KEY_ID:-}" ]]; then
    key_path="${RUNNER_TEMP:-$(mktemp -d)}/AuthKey_$APP_STORE_CONNECT_KEY_ID.p8"
    print -rn -- "$APP_STORE_CONNECT_API_KEY_BASE64" | base64 --decode > "$key_path"
    notary_auth=(--key "$key_path" --key-id "$APP_STORE_CONNECT_KEY_ID" --issuer "$APP_STORE_CONNECT_ISSUER_ID")
else
    notary_auth=(--keychain-profile "${NOTARY_PROFILE:-pennybar}")
fi

SIGN_IDENTITY="$identity" scripts/bundle.sh release
app="build/PennyBar.app"
codesign --verify --strict --deep "$app"

version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist")
dmg="build/PennyBar-$version.dmg"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
cp -R "$app" "$staging/"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
hdiutil create -volname PennyBar -srcfolder "$staging" -fs HFS+ -format UDZO "$dmg"
codesign --force --timestamp --sign "$identity" "$dmg"

# Notarizing the DMG covers the app inside it; staple both so they open offline.
xcrun notarytool submit "$dmg" "${notary_auth[@]}" --wait
xcrun stapler staple "$dmg"
xcrun stapler staple "$app"
spctl --assess --type open --context context:primary-signature -v "$dmg"

echo "Built $root/$dmg"
