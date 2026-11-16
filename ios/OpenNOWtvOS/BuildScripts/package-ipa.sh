#!/bin/sh
# Build an unsigned Release OpenNOW.app and zip it as Build/OpenNOW-tvOS-<version>-unsigned.ipa
# for sideloading tools, which re-sign it. Usage: package-ipa.sh
ROOT=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
cd "$ROOT" || exit 1
mkdir -p Build
xcodegen generate --spec ios/OpenNOWtvOS/project.yml >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }
xcodebuild build -project ios/OpenNOWtvOS/OpenNOWtvOS.xcodeproj -scheme OpenNOWtvOS -configuration Release -destination 'generic/platform=tvOS' -derivedDataPath Build/DerivedData-tvOS CODE_SIGNING_ALLOWED=NO > Build/tvos-ipa-build.log 2>&1
R=$?; echo "build exit=$R"
if [ $R -ne 0 ]; then grep -E "^/.*error:|^error:|ld: " Build/tvos-ipa-build.log | sed -E "s#$ROOT/ios/##" | sort -u | head -40; exit $R; fi
APP=Build/DerivedData-tvOS/Build/Products/Release-appletvos/OpenNOW.app
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Info.plist") || exit 1
IPA=Build/OpenNOW-tvOS-$VERSION-unsigned.ipa
STAGE=Build/ipa-stage
rm -rf "$STAGE" "$IPA"; mkdir -p "$STAGE/Payload" || exit 1
cp -R "$APP" "$STAGE/Payload/" || exit 1
(cd "$STAGE" && zip -qry "$ROOT/$IPA" Payload) || exit 1
rm -rf "$STAGE"
echo "$IPA"
