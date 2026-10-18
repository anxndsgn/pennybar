#!/bin/zsh
# Builds PennyBar.app into ./build. Usage: scripts/bundle.sh [debug|release]
set -euo pipefail

config=${1:-release}
root=${0:A:h:h}
cd "$root"

# SwiftPM links through clang with --sysroot, which leaves the SDK version unset, so ld stamps
# the deployment target (26.0) as the SDK. AppKit gates new designs, such as the current
# Liquid Glass treatment, on the linked SDK, so pass -isysroot to record the real one.
sdk_path=$(xcrun --show-sdk-path)
swift build -c "$config" --product PennyBar \
    -Xswiftc -Xclang-linker -Xswiftc -isysroot -Xswiftc -Xclang-linker -Xswiftc "$sdk_path"
bin_dir=$(swift build -c "$config" --show-bin-path)

linked_sdk=$(vtool -show-build "$bin_dir/PennyBar" | awk '/sdk/ { print $2 }')
if [[ "$linked_sdk" != "$(xcrun --show-sdk-version)" ]]; then
    echo "warning: binary records SDK $linked_sdk, expected $(xcrun --show-sdk-version)" >&2
fi

app="build/PennyBar.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/PennyBar" "$app/Contents/MacOS/PennyBar"
cp Resources/Info.plist "$app/Contents/Info.plist"

# Ad-hoc signature by default so the app launches locally. Each rebuild changes the signature,
# so macOS may ask once more for Keychain access to saved tokens. Set SIGN_IDENTITY to a
# Developer ID to sign for distribution (hardened runtime and a secure timestamp, as notarization requires).
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$app"
else
    codesign --force --sign - "$app"
fi

echo "Built $root/$app"
