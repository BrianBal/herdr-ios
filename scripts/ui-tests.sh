#!/bin/sh
# Runs the app's whole test suite (UI tests included) against this Mac's herdr.
#
#   HERDR_PAIR_LINK='herdr-ios://pair?…' scripts/ui-tests.sh ["iPhone 18 Pro"] [xcodebuild args…]
#
# HERDR_PAIR_LINK is this Mac's gateway pairing link (it holds the token, so
# it comes from the environment, never a file). The simulator defaults to an
# iPhone 18 Pro: the iPhone Duo simulator's folded screen shows no keyboard,
# so the keyboard test skips its drag there. Extra arguments go to xcodebuild,
# e.g. -only-testing:HerdrUITests/TabsFlowTests.
#
# Some tests need things on the Mac: workspaces named ios-clear-test and
# ios-photo-test running Claude, shells named ios-return-test and
# ios-complete-test, and a notification pushed to the simulator while
# NotificationTapTests waits for it. This sets them up, and closes every
# ios-*-test workspace afterwards (including ones the tests make), even on failure.
set -eu
: "${HERDR_PAIR_LINK:?set HERDR_PAIR_LINK to the pairing link of this Mac gateway}"
SIM_NAME=${1:-iPhone 18 Pro}
[ $# -gt 0 ] && shift
ROOT=$(cd "$(dirname "$0")/.." && pwd)
LOG=$(mktemp -t herdr-ui-tests)

# The newest iOS runtime's simulator with that name.
find_sim() {
  xcrun simctl list devices available -j | python3 -c 'import json, sys; ds = json.load(sys.stdin)["devices"]; print(next((d["udid"] for rt in sorted(ds, reverse=True) for d in ds[rt] if d["name"] == sys.argv[1]), ""))' "$1"
}
SIM=$(find_sim "$SIM_NAME")
[ -n "$SIM" ] || { echo "no simulator named $SIM_NAME"; exit 1; }

# The test workspaces (ios-*-test), as "id label" lines.
workspaces() {
  herdr workspace list | python3 -c 'import json, sys; [print(w["workspace_id"], w["label"]) for w in json.load(sys.stdin)["result"]["workspaces"] if w["label"].startswith("ios-") and w["label"].endswith("-test")]'
}

cleanup() {
  workspaces | while read -r id _; do herdr workspace close "$id" >/dev/null 2>&1 || true; done
  rm -f "$LOG" "$LOG.json"
}
trap cleanup EXIT
cleanup

make_workspace() { # label [agent]
  id=$(herdr workspace create --cwd "$ROOT" --label "$1" | python3 -c 'import json,sys; print(json.load(sys.stdin)["result"]["workspace"]["workspace_id"])')
  if [ -n "${2:-}" ]; then
    sleep 2 # the shell starts first
    herdr agent start "$1" --kind "$2" --pane "$id:p1" >/dev/null
  fi
  echo "$id"
}
make_workspace ios-clear-test claude >/dev/null
make_workspace ios-photo-test claude >/dev/null
RETURN_WS=$(make_workspace ios-return-test)
make_workspace ios-complete-test >/dev/null
sleep 10 # Claude starting up

echo "Simulator: $SIM_NAME ($SIM)"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null
# The on-screen keyboard, not a minimized bar for a Mac keyboard.
xcrun simctl spawn "$SIM" defaults write com.apple.Preferences HardwareKeyboardLastSeen -bool NO
xcrun simctl spawn "$SIM" defaults write com.apple.Preferences AutomaticMinimizationEnabled -bool NO

# NotificationTapTests waits on the home screen for a banner; send it one.
cat > "$LOG.json" <<EOF
{"aps":{"alert":{"title":"claude · ios-return-test","body":"Finished: ui test"},"sound":"default"},"pane_id":"$RETURN_WS:p1"}
EOF
(
  until grep -q "testTappingNotificationOpensPane\]' started" "$LOG" 2>/dev/null; do sleep 2; done
  sleep 20
  xcrun simctl push "$SIM" dev.bal.herdr.app "$LOG.json" >/dev/null
) &
PUSHER=$!

cd "$ROOT/App"
xcodegen generate --quiet
status=0
TEST_RUNNER_HERDR_PAIR_LINK="$HERDR_PAIR_LINK" \
  xcodebuild -project Herdr.xcodeproj -scheme Herdr -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath build test "$@" > "$LOG" 2>&1 || status=$?
kill "$PUSHER" 2>/dev/null || true
wait "$PUSHER" 2>/dev/null || true
grep -E "^Test Case .*(passed|failed|skipped)|error: -\[|^Executed|\*\* TEST" "$LOG" || tail -40 "$LOG"
exit $status
