#!/bin/zsh
# Builds Nearloop, signs it with your Developer ID, notarizes it, and makes a DMG to share.
#
# One-time setup:
#   1. A "Developer ID Application" certificate in your login keychain (Apple Developer account).
#   2. Notary credentials saved under a profile name:
#        xcrun notarytool store-credentials kapitsa-notary --apple-id you@example.com --team-id TEAMID
#
# Usage:
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=kapitsa-notary scripts/package.sh
#
# The app's bundle ID is com.adityak2128.nearloop; a fork sets BUNDLE_ID to one it owns.
#
# Without SIGN_IDENTITY it still makes a DMG, ad-hoc signed: other Macs then need right-click → Open.
set -euo pipefail
project_dir=${0:A:h:h}
app="$project_dir/Nearloop.app"
dist="$project_dir/dist"
export APP_VERSION=${APP_VERSION:-3.7}
identity=${SIGN_IDENTITY:-}
profile=${NOTARY_PROFILE:-}

if [[ -n "$profile" && -z "$identity" ]]; then
  print -u2 "Notarization needs SIGN_IDENTITY as well."
  exit 1
fi

"$project_dir/build-library-app.sh"
mkdir -p "$dist"

if [[ -n "$identity" ]]; then
  # Inner executables first, then the bundle; hardened runtime is required for notarization.
  # Kapitsa was checked to load and serve under the hardened runtime without extra entitlements.
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$app/Contents/MacOS/kapitsa"
  /usr/bin/codesign --force --timestamp --options runtime --sign "$identity" "$app"
  /usr/bin/codesign --verify --strict --verbose=2 "$app"
else
  print "No SIGN_IDENTITY: the app stays ad-hoc signed."
fi

if [[ -n "$profile" ]]; then
  zip="$dist/Nearloop-$APP_VERSION.zip"
  /usr/bin/ditto -c -k --keepParent "$app" "$zip"
  /usr/bin/xcrun notarytool submit "$zip" --keychain-profile "$profile" --wait
  /usr/bin/xcrun stapler staple "$app"
  rm -f "$zip"
fi

dmg="$dist/Nearloop-$APP_VERSION.dmg"
staging=$(/usr/bin/mktemp -d)
/usr/bin/ditto "$app" "$staging/Nearloop.app"
ln -s /Applications "$staging/Applications"
rm -f "$dmg"
/usr/bin/hdiutil create -quiet -volname "Nearloop" -srcfolder "$staging" -ov -format UDZO "$dmg"
rm -rf "$staging"

if [[ -n "$identity" ]]; then
  /usr/bin/codesign --force --timestamp --sign "$identity" "$dmg"
fi
if [[ -n "$profile" ]]; then
  /usr/bin/xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
  /usr/bin/xcrun stapler staple "$dmg"
  /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose "$dmg"
fi
print "Created $dmg"
