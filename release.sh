#!/bin/sh
# Builds, signs and notarizes BlackHoleSaver.saver and BlackHoleTimer.app
# for distribution.
#
# One-time setup (account holder only):
#   1. Developer ID certificate: Xcode -> Settings -> Accounts -> (your team)
#      -> Manage Certificates… -> "+" -> "Developer ID Application".
#   2. Notarization credentials (app-specific password from
#      https://account.apple.com -> Sign-In and Security -> App-Specific Passwords):
#        xcrun notarytool store-credentials notary \
#            --apple-id <your-apple-id> --team-id 8PFT9GXT36
#
# Then:  ./release.sh
set -eu
cd "$(dirname "$0")"

IDENTITY="Developer ID Application"
PROFILE="notary"   # notarytool keychain profile name

command -v xcodegen >/dev/null || { echo "brew install xcodegen first"; exit 1; }
security find-identity -v -p codesigning | grep -q "$IDENTITY" || {
    echo "No '$IDENTITY' certificate in the keychain — create it in"
    echo "Xcode -> Settings -> Accounts -> Manage Certificates… first."
    exit 1
}

echo "==> Building"
xcodegen generate
for SCHEME in BlackHoleSaver BlackHoleTimer; do
    xcodebuild -project BlackHoleSaver.xcodeproj -scheme "$SCHEME" \
               -configuration Release -derivedDataPath build build -quiet
done

SAVER=build/Build/Products/Release/BlackHoleSaver.saver
APP=build/Build/Products/Release/BlackHoleTimer.app

echo "==> Signing with $IDENTITY"
for BUNDLE in "$SAVER" "$APP"; do
    codesign --force --deep --options runtime --timestamp \
             --sign "$IDENTITY" "$BUNDLE"
    codesign --verify --strict --verbose=2 "$BUNDLE"
done

echo "==> Zipping"
mkdir -p dist
ditto -c -k --keepParent "$SAVER" dist/BlackHoleSaver.saver.zip
ditto -c -k --keepParent "$APP" dist/BlackHoleTimer.app.zip

echo "==> Notarizing (this waits for Apple)"
xcrun notarytool submit dist/BlackHoleSaver.saver.zip \
      --keychain-profile "$PROFILE" --wait
xcrun notarytool submit dist/BlackHoleTimer.app.zip \
      --keychain-profile "$PROFILE" --wait

# .saver bundles can't be stapled (stapler only supports apps, pkgs, dmgs);
# Gatekeeper fetches the notarization ticket online on first launch instead.
# The app can be stapled — do it and re-zip so the ticket ships inside.
echo "==> Stapling the app"
xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" dist/BlackHoleTimer.app.zip

echo "==> Gatekeeper check"
spctl --assess --type install -v "$SAVER" || true
spctl --assess --type execute -v "$APP" || true

echo "==> Done: dist/BlackHoleSaver.saver.zip dist/BlackHoleTimer.app.zip"
