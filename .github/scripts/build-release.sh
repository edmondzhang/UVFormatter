#!/usr/bin/env bash
set -euo pipefail

# The runner's temporary keychain and credentials are removed on every exit path.
: "${DEVELOPER_ID_P12_BASE64:?Configure the Developer ID certificate secret}"
: "${DEVELOPER_ID_P12_PASSWORD:?Configure the certificate password}"
: "${APPLE_NOTARY_KEY_P8:?Configure the App Store Connect API key}"
: "${APPLE_NOTARY_KEY_ID:?Configure the API key ID}"
: "${APPLE_NOTARY_ISSUER_ID:?Configure the API issuer ID}"

work="$RUNNER_TEMP/uvformatter-release"
mkdir -p "$work"
credential_dir=$(mktemp -d "$RUNNER_TEMP/uvformatter-credentials.XXXXXX")
chmod 700 "$credential_dir"
keychain="$credential_dir/release.keychain-db"
trap 'security delete-keychain "$keychain" >/dev/null 2>&1 || true; rm -rf "$credential_dir"' EXIT
password=$(openssl rand -hex 32)
echo "::add-mask::$password"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security list-keychains -d user -s "$keychain"
printf '%s' "$DEVELOPER_ID_P12_BASE64" | base64 -D > "$credential_dir/certificate.p12"
security import "$credential_dir/certificate.p12" -k "$keychain" -P "$DEVELOPER_ID_P12_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
identity=$(security find-identity -p codesigning -v "$keychain" |
  awk '/"Developer ID Application:/ { identity=$2; count++ } END { if (count != 1) exit 1; print identity }')

version=${VERSION_TAG#v}
build_number=$(python3 .github/scripts/appcast.py build-number "$VERSION_TAG")
xcodebuild build -project UVFormatter.xcodeproj -scheme UVFormatter -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$work/build" \
  -onlyUsePackageVersionsFromResolvedFile ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$version" CURRENT_PROJECT_VERSION="$build_number" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$identity" CODE_SIGNING_ALLOWED=YES \
  ENABLE_HARDENED_RUNTIME=YES OTHER_CODE_SIGN_FLAGS="--timestamp --keychain $keychain" \
  SPARKLE_PUBLIC_KEY="$SPARKLE_PUBLIC_KEY"

app="$work/build/Build/Products/Release/UVFormatter.app"
plist="$app/Contents/Info.plist"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$plist")" = "$build_number"
test "$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$plist")" = "$version"
test "$(/usr/libexec/PlistBuddy -c 'Print SUPublicEDKey' "$plist")" = "$SPARKLE_PUBLIC_KEY"
lipo -verify_arch arm64 x86_64 "$app/Contents/MacOS/UVFormatter"
codesign --verify --deep --strict "$app"
codesign --display --verbose=4 "$app" 2>&1 | grep '^Authority=Developer ID Application:'

notary_key="$credential_dir/AuthKey.p8"
printf '%s\n' "$APPLE_NOTARY_KEY_P8" > "$notary_key"
chmod 600 "$notary_key"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/notarization.zip"
xcrun notarytool submit "$work/notarization.zip" --key "$notary_key" \
  --key-id "$APPLE_NOTARY_KEY_ID" --issuer "$APPLE_NOTARY_ISSUER_ID" \
  --wait --timeout 30m --output-format json > "$work/notary-result.json"
if ! jq -e '.status == "Accepted"' "$work/notary-result.json" > /dev/null; then
  jq '{id,status,message}' "$work/notary-result.json"
  exit 1
fi
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
ditto -c -k --sequesterRsrc --keepParent "$app" "$work/UVFormatter-$VERSION_TAG.zip"
