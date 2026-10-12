#!/bin/sh
# Builds a Release archive and uploads it to App Store Connect for TestFlight.
#
# One-time setup (needs you, in a browser):
#   1. appstoreconnect.apple.com → Apps → + → New App: iOS, name "Herdr"
#      (or any free name), bundle ID dev.bal.herdr.app, SKU anything.
#   2. Xcode stays signed in to the team's Apple ID (Settings → Accounts).
# The first run lets Xcode create an Apple Distribution certificate and App
# Store profiles for the app and its widget (-allowProvisioningUpdates).
#
# Release builds register for production APNs; the gateway picks the right
# APNs host per device, so nothing changes on the Mac.
set -eu
cd "$(dirname "$0")/../App"
command -v xcodegen >/dev/null || { echo "needs xcodegen (brew install xcodegen)"; exit 1; }
xcodegen generate --quiet
BUILD=$(date +%Y%m%d%H%M)
ARCHIVE=build/Herdr-$BUILD.xcarchive
echo "Archiving build $BUILD…"
xcodebuild -project Herdr.xcodeproj -scheme Herdr -configuration Release \
  -destination generic/platform=iOS -archivePath "$ARCHIVE" \
  CURRENT_PROJECT_VERSION="$BUILD" -allowProvisioningUpdates -quiet archive
echo "Uploading to App Store Connect…"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export -allowProvisioningUpdates
echo "Uploaded build $BUILD. It shows up in TestFlight after Apple finishes processing (a few minutes)."
