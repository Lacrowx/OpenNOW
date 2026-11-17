#!/bin/sh
# One-command install of OpenNOW on your Apple TV.
# Usage: sh ios/OpenNOWtvOS/BuildScripts/install.sh
#
# It checks the tools, builds the native libraries once, asks which Apple account team and
# which Apple TV to use (remembered in Signing.local.xcconfig and BuildScripts/deploy.local),
# then builds, installs and launches the app through deploy.sh.
# Delete those two files to choose again.
ROOT=$(cd "$(dirname "$0")/../../.." && pwd) || exit 1
cd "$ROOT" || exit 1
TV=ios/OpenNOWtvOS
SIGNING=$TV/Signing.local.xcconfig
DEPLOY=$TV/BuildScripts/deploy.local

step() { printf '\n==> %s\n' "$1"; }
fail() { printf '\nProblem: %s\n' "$1"; exit 1; }
ask() { # ask <prompt> <count>: prints the chosen number (1..count)
    if [ "$2" -eq 1 ]; then echo 1; return; fi
    while :; do
        printf '%s [1-%s]: ' "$1" "$2" >&2
        read -r N || exit 1
        case $N in ''|*[!0-9]*) ;; *) [ "$N" -ge 1 ] && [ "$N" -le "$2" ] && { echo "$N"; return; } ;; esac
    done
}

step "Checking Xcode and tools"
case $(xcode-select -p 2>/dev/null) in
    *.app/Contents/Developer) ;;
    *) fail "Xcode is not installed or not selected. Install Xcode from the App Store, open it once, then run:
    sudo xcode-select -s /Applications/Xcode.app" ;;
esac
SDK=$(xcodebuild -showsdks 2>/dev/null | sed -n 's/.*-sdk appletvos\([0-9.]*\).*/\1/p' | tail -1)
[ -n "$SDK" ] || fail "Xcode has no tvOS platform. Open Xcode → Settings → Components and get tvOS."
python3 -c "import sys; sys.exit(tuple(map(int, '$SDK'.split('.'))) < (27, 1))" \
    || fail "Xcode has the tvOS $SDK SDK; OpenNOW needs tvOS 27.1 or later. Update Xcode."
MISSING=
for T in xcodegen cmake; do command -v $T >/dev/null 2>&1 || MISSING="$MISSING $T"; done
if [ -n "$MISSING" ]; then
    command -v brew >/dev/null 2>&1 || fail "Missing:$MISSING. Install Homebrew from https://brew.sh, then run this again."
    echo "Installing$MISSING with Homebrew…"
    brew install $MISSING || fail "brew install$MISSING failed."
fi
echo "Xcode with tvOS $SDK, xcodegen and cmake: OK"

if [ -d $TV/Frameworks/OpenSSL.xcframework ] && [ -d $TV/Frameworks/usrsctp.xcframework ]; then
    step "Native libraries already built"
else
    step "Building native libraries (one time, takes a few minutes)"
    mkdir -p Build
    python3 $TV/BuildScripts/build-native-protocol-libs-tvos.py > Build/tvos-native-libs.log 2>&1 \
        || { tail -20 Build/tvos-native-libs.log 2>/dev/null; fail "native library build failed, see Build/tvos-native-libs.log"; }
fi

if [ -f "$SIGNING" ]; then
    step "Using the team in $SIGNING"
else
    step "Choosing your Apple account team"
    TEAMS=$(defaults export com.apple.dt.Xcode - 2>/dev/null | python3 -c '
import plistlib, sys
try: data = plistlib.loads(sys.stdin.buffer.read())
except Exception: data = {}
seen = set()
for teams in data.get("IDEProvisioningTeamByIdentifier", {}).values():
    for t in teams:
        tid = t.get("teamID")
        if tid and tid not in seen:
            seen.add(tid)
            print(tid + "\t" + (t.get("teamName") or "Apple account"))
')
    [ -n "$TEAMS" ] || fail "Xcode has no Apple account yet. Open Xcode → Settings → Accounts, press + and
sign in with your Apple ID (a free one works), then run this again."
    COUNT=$(printf '%s\n' "$TEAMS" | wc -l | tr -d ' ')
    printf '%s\n' "$TEAMS" | cut -f2 | awk '{ printf "  %d) %s\n", NR, $0 }'
    PICK=$(ask "Which team?" "$COUNT") || exit 1
    TEAM=$(printf '%s\n' "$TEAMS" | sed -n "${PICK}p" | cut -f1)
    # A bundle id no other team has registered, so a free team can sign it.
    BUNDLE="com.opennow.tvos.$(printf '%s' "$TEAM" | tr 'A-Z' 'a-z')"
    printf 'DEVELOPMENT_TEAM = %s\nOPENNOW_TVOS_BUNDLE_ID = %s\n' "$TEAM" "$BUNDLE" > "$SIGNING"
    echo "Saved to $SIGNING"
fi

if [ -f "$DEPLOY" ]; then
    step "Using the Apple TV in $DEPLOY"
else
    step "Finding your Apple TV"
    LIST=$(mktemp) || exit 1
    xcrun devicectl list devices --json-output "$LIST" >/dev/null 2>&1
    TVS=$(python3 - "$LIST" <<'EOF'
import json, sys
try: devices = json.load(open(sys.argv[1]))["result"]["devices"]
except Exception: devices = []
for d in devices:
    hw, conn = d.get("hardwareProperties", {}), d.get("connectionProperties", {})
    if hw.get("platform") == "tvOS" and conn.get("pairingState") == "paired":
        state = "connected" if conn.get("tunnelState") == "connected" else "not connected right now"
        print(f"{d['identifier']}\t{d.get('deviceProperties', {}).get('name', 'Apple TV')} ({state})")
EOF
)
    rm -f "$LIST"
    [ -n "$TVS" ] || fail "No Apple TV is paired with this Mac. On the Apple TV open
Settings → Remotes and Devices → Remote App and Devices. On the Mac open Xcode → Window →
Devices and Simulators, select the Apple TV and pair with the code it shows. Then run this again."
    COUNT=$(printf '%s\n' "$TVS" | wc -l | tr -d ' ')
    printf '%s\n' "$TVS" | cut -f2 | awk '{ printf "  %d) %s\n", NR, $0 }'
    PICK=$(ask "Which Apple TV?" "$COUNT") || exit 1
    printf 'OPENNOW_TVOS_DEVICE=%s\n' "$(printf '%s\n' "$TVS" | sed -n "${PICK}p" | cut -f1)" > "$DEPLOY"
    echo "Saved to $DEPLOY"
fi

step "Building and installing (the first build takes several minutes; keep the Apple TV awake)"
sh $TV/BuildScripts/deploy.sh || fail "the build or install failed. The full log is Build/tvos-device-build.log.
If it mentions signing or provisioning, open Xcode → Settings → Accounts and check that you are signed in."
printf '\nDone. OpenNOW is on your Apple TV.\n'
echo "With a free Apple account the app stops opening after 7 days; run this again to reinstall it."
