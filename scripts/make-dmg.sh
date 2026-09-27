#!/bin/zsh
# Builds a release PF-Terminal.dmg (app + Applications shortcut) and its SHA-256.
#
#   scripts/make-dmg.sh
#
# The app is archived with automatic signing and exported for Developer ID: the App Group
# (group.io.github.troskinpavel.pf) needs a Developer ID provisioning profile, which
# -allowProvisioningUpdates creates/renews on the team.
#
# Environment (all optional):
#   SIGN_IDENTITY   identity for signing the DMG, default "Developer ID Application"
#   TEAM_ID         development team (otherwise taken from Config/Signing.local.xcconfig)
#   ICLOUD=1        include iCloud sync (Production CloudKit environment; deploy the schema first)
#   NOTARY_PROFILE  `xcrun notarytool store-credentials` profile; when set, the DMG is
#                   notarized and stapled. Without it the DMG is signed but NOT notarized.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY=${SIGN_IDENTITY:-"Developer ID Application"}
TEAM_ID=${TEAM_ID:-$(sed -n 's/^DEVELOPMENT_TEAM *= *//p' Config/Signing.local.xcconfig 2>/dev/null | head -1)}
[[ -n "$TEAM_ID" ]] || { echo "set TEAM_ID or DEVELOPMENT_TEAM in Config/Signing.local.xcconfig"; exit 1; }
OUT=build/release
ARCHIVE="$OUT/PF Terminal.xcarchive"
APP="$OUT/export/PF Terminal.app"
DMG="$OUT/PF-Terminal.dmg"

entitlements=Config/PFTerminal.entitlements
env=Development
if [[ "${ICLOUD:-}" == 1 ]]; then entitlements=Config/PFTerminal-iCloud.entitlements; env=Production; fi

rm -rf "$ARCHIVE" "$OUT/export"
xcodebuild -project PFTerminal.xcodeproj -scheme PFTerminal -configuration Release -archivePath "$ARCHIVE" archive \
  -allowProvisioningUpdates CODE_SIGN_STYLE=Automatic DEVELOPMENT_TEAM="$TEAM_ID" CODE_SIGN_IDENTITY="Apple Development" \
  PF_APP_ENTITLEMENTS="$entitlements" PF_ICLOUD_ENV="$env" | grep -E "error:|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || { echo "archive failed"; exit 1; }

opts=$(mktemp -t pf-export).plist
cat > "$opts" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUT/export" -exportOptionsPlist "$opts" -allowProvisioningUpdates \
  | grep -E "error:|EXPORT" || true
rm -f "$opts"
[[ -d "$APP" ]] || { echo "export failed"; exit 1; }
codesign --verify --deep --strict "$APP"

# Submit to Apple and require the final status "Accepted" (a successful upload proves nothing).
notarize() {
  local out id st
  out=$(xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json)
  id=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')
  st=$(print -r -- "$out" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')
  echo "notarization $id: $st ($1:t)"
  if [[ "$st" != "Accepted" ]]; then
    [[ -n "$id" ]] && xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" "$OUT/notary-$id.json" && echo "log: $OUT/notary-$id.json"
    exit 1
  fi
}

# Notarize and staple the app itself first, so a copy dragged out of the DMG validates offline.
if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  ditto -c -k --keepParent "$APP" "$OUT/app.zip"
  notarize "$OUT/app.zip"
  rm -f "$OUT/app.zip"
  xcrun stapler staple "$APP"
  xcrun stapler validate "$APP"
fi

stage=$(mktemp -d)
cp -R "$APP" "$stage/"
ln -s /Applications "$stage/Applications"
rm -f "$DMG"
hdiutil create -volname "PF Terminal" -srcfolder "$stage" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$stage"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

if [[ -n "${NOTARY_PROFILE:-}" ]]; then
  notarize "$DMG"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -vvv -t open --context context:primary-signature "$DMG"   # fails the script if Gatekeeper rejects
  echo "notarized, stapled and accepted by Gatekeeper"
else
  echo "signed, NOT notarized (set NOTARY_PROFILE to notarize)"
fi

(cd "$OUT" && shasum -a 256 PF-Terminal.dmg > PF-Terminal.dmg.sha256)
version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist")
echo "$DMG ($version)"
cat "$OUT/PF-Terminal.dmg.sha256"
