#!/bin/bash
#
# Opens the built Origami app against the same pretend Mac that
# run-tests.sh uses, with Apple's installer "cancelled", and has the app click
# Get help from Claude by itself. Checks that the app's window ran the setup
# and handed the help message to Claude. A real window appears for about
# 30 seconds. Nothing on this computer is installed or changed.
#
#   bash app/build-app.sh      # first, if you haven't built the app
#   bash tests/test-app.sh
#
# Set SCREENSHOT=/path/to/file.png to save a picture of the failure screen.

HERE=$(cd "$(dirname "$0")" && pwd)
APP="$HERE/../dist/Origami.app"
BIN="$APP/Contents/MacOS/Origami"
SCRIPT="$APP/Contents/Resources/claude-setup.sh"
if [ ! -x "$BIN" ]; then
  echo "Build the app first: bash app/build-app.sh"
  exit 1
fi

RUN_TESTS_HELPERS_ONLY=1 source "$HERE/run-tests.sh"

app_window() {
  osascript -l JavaScript -e 'ObjC.import("CoreGraphics"); var l = ObjC.castRefToObject($.CGWindowListCopyWindowInfo($.kCGWindowListOptionOnScreenOnly, 0)); var out = []; for (var i = 0; i < l.count; i++) { var w = l.objectAtIndex(i); var b = ObjC.deepUnwrap(w.objectForKey("kCGWindowBounds")); if (ObjC.unwrap(w.objectForKey("kCGWindowOwnerName")) === "Origami" && b.Width > 600) out.push(ObjC.unwrap(w.objectForKey("kCGWindowNumber"))); } out.join(" ")'
}

echo "The app, on a pretend Mac where Apple's installer is cancelled"
new_sandbox
echo cancel > "$T/state/clt_mode"
env -i \
  HOME="$T/home" USER="$USER" LANG=en_US.UTF-8 TMPDIR="${TMPDIR:-/tmp}" \
  PATH="$T/bin:/usr/bin:/bin:/usr/sbin:/sbin" \
  SANDBOX="$T" \
  CLAUDE_SETUP_STUB_PATH="$T/bin" \
  CLAUDE_SETUP_APPS_DIR="$T/apps" \
  CLAUDE_SETUP_HOMEBREW_DIRS="$T/homebrew" \
  CLAUDE_SETUP_POLL_SECS=1 \
  CLAUDE_SETUP_DEVTOOLS_APPEAR=8 \
  "$BIN" --start --choose=help > "$T/app-output.txt" 2>&1 &
app_pid=$!

# Wait for the failure screen, then for the help hand-off.
for _ in $(seq 1 120); do
  grep -q 'claude://' "$T/state/open.log" 2>/dev/null && break
  # The app answers the failure screen 3 seconds after it appears.
  if [ -n "${SCREENSHOT:-}" ] && [ ! -e "$SCREENSHOT" ] && grep -q "Setup didn't finish" "$T/home/Library/Application Support/ClaudeSetup/logs"/*/setup.log 2>/dev/null; then
    sleep 1
    wid=$(app_window)
    [ -n "$wid" ] && screencapture -x -o -l "${wid%% *}" "$SCREENSHOT"
  fi
  sleep 0.5
done
sleep 1

check "the app ran setup in the pretend Mac" has "$T/home/Library/Application Support/ClaudeSetup/logs"/*/setup.log "Setup didn't finish"
check "the app opened Claude with the help message" has "$T/state/open.log" "claude://claude.ai/new?q="
check "the message says to reopen the app" has "$T/state/clipboard" "tell me to open the Origami app again and click Start setup"
check "the app is still open, showing what happened" kill -0 "$app_pid"

kill "$app_pid" 2>/dev/null
wait "$app_pid" 2>/dev/null
end_sandbox

# ---- Updates ----------------------------------------------------------------
# A copy of the app in a test folder, pointed at a pretend "99.0.0" release on
# disk made from the same signed app. The real GitHub release isn't involved.

inode() { stat -f %i "$1" 2>/dev/null; }

# make_release FOLDER [CHECKSUM]: the checksum defaults to the zip's real one.
make_release() {
  mkdir -p "$1/release"
  ditto -c -k --keepParent "$APP" "$1/release/Origami.zip"
  local sum=${2:-$(shasum -a 256 "$1/release/Origami.zip" | awk '{print $1}')}
  printf '{"version": "99.0.0", "url": "file://%s/release/Origami.zip", "sha256": "%s", "notes": "Test release."}' \
    "$1" "$sum" > "$1/release/latest.json"
}

echo
echo "Updating: a newer release is offered, checked, and installed"
U=$(mktemp -d "${TMPDIR:-/tmp}/set-up-claude-update-test.XXXXXX")
U=$(cd "$U" && pwd -P)
ditto "$APP" "$U/Origami.app"
make_release "$U"
before=$(inode "$U/Origami.app")
SET_UP_CLAUDE_UPDATE_URL="file://$U/release/latest.json" \
  "$U/Origami.app/Contents/MacOS/Origami" --choose-update > "$U/app-output.txt" 2>&1 &
old_pid=$!
for _ in $(seq 1 60); do
  kill -0 "$old_pid" 2>/dev/null || break
  sleep 0.5
done
sleep 3
new_pid=$(pgrep -f "$U/Origami.app/Contents/MacOS/Origami" | head -n 1)
check "the old version quit to make way for the update" sh -c "! kill -0 $old_pid 2>/dev/null"
check "the app in its folder was replaced" [ "$(inode "$U/Origami.app")" != "$before" ]
check "the replacement is still signed by the same developer" sh -c "codesign -dv '$U/Origami.app' 2>&1 | grep -q TeamIdentifier=YX5UZDLY5F"
check "the updated app reopened by itself" [ -n "$new_pid" ]
check "no update files were left next to the app" sh -c "! ls -a '$U' | grep -q 'update-'"
[ -n "$new_pid" ] && kill "$new_pid" 2>/dev/null

echo
echo "Updating: a copy with the old name comes back as Origami.app"
# The old copy goes to this Mac's Trash, as it would for a person.
U3=$(mktemp -d "${TMPDIR:-/tmp}/set-up-claude-update-test.XXXXXX")
U3=$(cd "$U3" && pwd -P)
ditto "$APP" "$U3/Set Up Claude.app"
make_release "$U3"
SET_UP_CLAUDE_UPDATE_URL="file://$U3/release/latest.json" \
  "$U3/Set Up Claude.app/Contents/MacOS/Origami" --choose-update > "$U3/app-output.txt" 2>&1 &
old_pid=$!
for _ in $(seq 1 60); do
  kill -0 "$old_pid" 2>/dev/null || break
  sleep 0.5
done
sleep 3
new_pid=$(pgrep -f "$U3/Origami.app/Contents/MacOS/Origami" | head -n 1)
check "the update is installed as Origami.app" [ -d "$U3/Origami.app" ]
check "the copy with the old name is gone" [ ! -e "$U3/Set Up Claude.app" ]
check "Origami reopened by itself" [ -n "$new_pid" ]
[ -n "$new_pid" ] && kill "$new_pid" 2>/dev/null

echo
echo "Updating: a download that doesn't match its checksum is refused"
U2=$(mktemp -d "${TMPDIR:-/tmp}/set-up-claude-update-test.XXXXXX")
U2=$(cd "$U2" && pwd -P)
ditto "$APP" "$U2/Origami.app"
make_release "$U2" "0000000000000000000000000000000000000000000000000000000000000000"
before=$(inode "$U2/Origami.app")
SET_UP_CLAUDE_UPDATE_URL="file://$U2/release/latest.json" \
  "$U2/Origami.app/Contents/MacOS/Origami" --choose-update > "$U2/app-output.txt" 2>&1 &
bad_pid=$!
sleep 8
check "the app keeps running" kill -0 "$bad_pid"
check "the app in its folder wasn't touched" [ "$(inode "$U2/Origami.app")" = "$before" ]
if [ -n "${SCREENSHOT_UPDATE_FAILED:-}" ]; then
  wid=$(app_window)
  [ -n "$wid" ] && screencapture -x -o -l "${wid%% *}" "$SCREENSHOT_UPDATE_FAILED"
fi
kill "$bad_pid" 2>/dev/null
wait "$bad_pid" 2>/dev/null

printf '\n%s passed, %s failed\n' "$PASS" "$FAILS"
[ "$FAILS" = 0 ]
