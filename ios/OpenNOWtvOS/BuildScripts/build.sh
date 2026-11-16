#!/bin/sh
# Regenerate the tvOS project, build for a generic tvOS device, summarise errors.
# Extra arguments go to xcodebuild, e.g. CODE_SIGNING_ALLOWED=NO.
ROOT=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
cd "$ROOT" || exit 1
mkdir -p Build
xcodegen generate --spec ios/OpenNOWtvOS/project.yml >/dev/null 2>&1 || { echo "xcodegen failed"; exit 1; }
xcodebuild build -project ios/OpenNOWtvOS/OpenNOWtvOS.xcodeproj -scheme OpenNOWtvOS -configuration Debug -destination 'generic/platform=tvOS' -derivedDataPath Build/DerivedData-tvOS "$@" > Build/tvos-build.log 2>&1
R=$?; echo "exit=$R"
grep -E "^/.*error:|^error:|ld: |Undefined symbol" Build/tvos-build.log | sed -E "s#$ROOT/ios/##" | sort -u > Build/tvos-errors.txt
echo "errors: $(wc -l < Build/tvos-errors.txt)"
cut -d: -f1 Build/tvos-errors.txt | sort | uniq -c | sort -rn | head -25
grep -E "BUILD (SUCCEEDED|FAILED)" Build/tvos-build.log
exit $R
