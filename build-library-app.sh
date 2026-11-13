#!/bin/zsh
# Builds Nearloop.app with the Kapitsa engine bundled inside, ad-hoc signed for this Mac.
# For a signed, notarized DMG to share, run scripts/package.sh afterwards.
set -euo pipefail
project_dir=${0:A:h}
app="$project_dir/Nearloop.app"
version=${APP_VERSION:-3.7}
build=${APP_BUILD:-15}

# The Kapitsa binary to bundle: KAPITSA_BIN, else the installed Homebrew copy, else vendor/kapitsa
# (bin/kapitsa with share/kapitsa/LICENSE and THIRD_PARTY_NOTICES beside it, as Homebrew lays it out).
kapitsa_bin=${KAPITSA_BIN:-$(/usr/bin/readlink -f /opt/homebrew/bin/kapitsa 2>/dev/null || true)}
[[ -x "$kapitsa_bin" ]] || kapitsa_bin="$project_dir/vendor/kapitsa/bin/kapitsa"
if [[ ! -x "$kapitsa_bin" ]]; then
  print -u2 "Set KAPITSA_BIN to a kapitsa executable to bundle (brew install nace-ai/tap/kapitsa provides one)."
  exit 1
fi
kapitsa_share=${kapitsa_bin:h:h}/share/kapitsa

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources/kapitsa-licenses"
/usr/bin/swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macosx14.0 \
  -framework SwiftUI -framework AppKit \
  "$project_dir"/App/*.swift -o "$app/Contents/MacOS/Nearloop"
cp "$kapitsa_bin" "$app/Contents/MacOS/kapitsa"
chmod 755 "$app/Contents/MacOS/kapitsa"
for notice in LICENSE THIRD_PARTY_NOTICES; do
  [[ -f "$kapitsa_share/$notice" ]] && cp "$kapitsa_share/$notice" "$app/Contents/Resources/kapitsa-licenses/"
done
"$kapitsa_bin" --version > "$app/Contents/Resources/kapitsa-licenses/VERSION" 2>/dev/null || true
# Icon source: icon/make-icon.swift renders the PNGs that iconutil packs into AppIcon.icns.
cp "$project_dir/icon/AppIcon.icns" "$app/Contents/Resources/AppIcon.icns"
# Experimental › iPhone Offload: the Python side, run with the user's installed oMLX.
mkdir -p "$app/Contents/Resources/offload"
cp "$project_dir"/App/Offload/*.py "$app/Contents/Resources/offload/"

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Nearloop</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundleIdentifier</key><string>${BUNDLE_ID:-com.adityak2128.nearloop}</string>
<key>CFBundleName</key><string>Nearloop</string>
<key>CFBundleDisplayName</key><string>Nearloop</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>NearloopUpdateRepository</key><string>${UPDATE_REPOSITORY:-AdityaK2128/nearloop}</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
<key>NSPrincipalClass</key><string>NSApplication</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>Read models you keep on external drives.</string>
<key>NSNetworkVolumesUsageDescription</key><string>Read models you keep on network drives.</string>
<key>NSDownloadsFolderUsageDescription</key><string>Read models you keep in Downloads.</string>
<key>NSDocumentsFolderUsageDescription</key><string>Read models you keep in Documents.</string>
<key>NSDesktopFolderUsageDescription</key><string>Read models you keep on the Desktop.</string>
<key>NSAppleEventsUsageDescription</key><string>Open coding agents in Terminal.</string>
</dict></plist>
PLIST
/usr/bin/codesign --force --sign - "$app/Contents/MacOS/kapitsa"
/usr/bin/codesign --force --sign - "$app"
print "Built $app (Kapitsa: $("$kapitsa_bin" --version 2>/dev/null | head -1))"
