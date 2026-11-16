#!/bin/sh
# Build signed (Release; --debug for Debug) for a paired Apple TV, install, launch.
# Usage: deploy.sh [--debug] [--no-launch]   (--no-launch only installs)
# The Apple TV is OPENNOW_TVOS_DEVICE (a devicectl identifier, see `xcrun devicectl list devices`),
# from the environment or from BuildScripts/deploy.local. Signing comes from Signing.local.xcconfig.
ROOT=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
cd "$ROOT" || exit 1
[ -f ios/OpenNOWtvOS/BuildScripts/deploy.local ] && . ios/OpenNOWtvOS/BuildScripts/deploy.local
DEV=${OPENNOW_TVOS_DEVICE:?set OPENNOW_TVOS_DEVICE or write it to ios/OpenNOWtvOS/BuildScripts/deploy.local}
CONFIG=Release; LAUNCH=1
for A in "$@"; do case $A in --debug) CONFIG=Debug;; --no-launch) LAUNCH=0;; *) echo "usage: deploy.sh [--debug] [--no-launch]"; exit 2;; esac; done
mkdir -p Build
xcodegen generate --spec ios/OpenNOWtvOS/project.yml >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }
xcodebuild build -project ios/OpenNOWtvOS/OpenNOWtvOS.xcodeproj -scheme OpenNOWtvOS -configuration $CONFIG -destination "platform=tvOS,id=$DEV" -derivedDataPath Build/DerivedData-tvOS -allowProvisioningUpdates > Build/tvos-device-build.log 2>&1
R=$?; echo "build exit=$R"
if [ $R -ne 0 ]; then grep -E "^/.*error:|^error:|ld: " Build/tvos-device-build.log | sed -E "s#$ROOT/ios/##" | sort -u | head -40; exit $R; fi
APP=Build/DerivedData-tvOS/Build/Products/$CONFIG-appletvos/OpenNOW.app
xcrun devicectl device install app --device "$DEV" "$APP" 2>&1 | grep -E "bundleID|error|Error" | head -3
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")
[ $LAUNCH -eq 0 ] || xcrun devicectl device process launch --terminate-existing --device "$DEV" "$BUNDLE" 2>&1 | tail -1
