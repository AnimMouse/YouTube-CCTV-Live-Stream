#!/usr/bin/env bash
#
# Tests livestream.sh against fake yutu/ffmpeg (test/bin), no YouTube needed.
#
# Usage: test/run.sh [case-name...]    (default: all cases, ~1 minute)

set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$TEST_DIR/../livestream.sh"
export PATH="$TEST_DIR/bin:$PATH"

PASSED=0 FAILED=0 FAILURES=()
CASE="" T="" RC=0 FAILURES_BEFORE=0

# ---- helpers ---------------------------------------------------------------

# Creates a temp dir with a config; extra config lines come from stdin.
setup() {
  CASE="$1"
  FAILURES_BEFORE=${#FAILURES[@]}
  T="$(mktemp -d)"
  export FAKE_DIR="$T/fake"
  mkdir -p "$FAKE_DIR" "$T/streams" "$T/state"
  echo '{"installed":{"client_id":"CLIENT-ID","client_secret":"CS-SECRET"}}' >"$T/client_secret.json"
  echo '{"access_token":"old","refresh_token":"RT-SECRET","expiry":"2020-01-01T00:00:00Z"}' >"$T/token.json"
  touch "$FAKE_DIR/calls" "$FAKE_DIR/ffmpeg.events"
  cat >"$T/streams/cam.conf" <<EOF
NAME="CCTV"
RTSP_URL="rtsp://camera/stream1"
STREAM_KEY="TEST-KEY"
DURATION="1h"
POLL_INTERVAL=1
RETRY_DELAY=1
FFMPEG_RESTART_DELAY=1
FFMPEG_CHECK_INTERVAL=1
GO_LIVE_TIMEOUT=3
CREDENTIAL_FILE="$T/client_secret.json"
TOKEN_FILE="$T/token.json"
LOG_DIR="$T/logs"
STATE_DIR="$T/state"
EOF
  cat >>"$T/streams/cam.conf"
}

# Runs the script for $1 seconds, then sends SIGTERM. Sets RC.
run_for() {
  "$SCRIPT" "$T/streams/cam.conf" >"$T/output" 2>&1 &
  local pid=$!
  sleep "$1"
  kill -TERM "$pid" 2>/dev/null
  wait "$pid"
  RC=$?
}

# Runs the script expecting it to exit by itself within 10s. Sets RC.
run_to_exit() {
  timeout 10 "$SCRIPT" "$T/streams/cam.conf" >"$T/output" 2>&1
  RC=$?
}

fail() { FAILURES+=("$CASE: $*"); }
expect() { [[ "$1" == "$2" ]] || fail "$3: expected '$2', got '$1'"; }
calls() { grep -c -E -- "$1" "$FAKE_DIR/calls"; }
events() { grep -c -E -- "$1" "$FAKE_DIR/ffmpeg.events"; }
output_has() { grep -q -E -- "$1" "$T/output" || fail "output lacks /$1/"; }
# Mutating yutu calls, without flags noise: "transition B1 testing", ...
actions() {
  sed -E 's/ \| token=.*//' "$FAKE_DIR/calls" | awk '
    /liveBroadcast insert/     { print "insert" }
    /liveBroadcast bind/       { print "bind" }
    /liveBroadcast delete/     { for (i=1;i<=NF;i++) if ($i=="--ids") print "delete " $(i+1) }
    /liveBroadcast transition/ { id=""; st=""; for (i=1;i<=NF;i++) { if ($i=="--ids") id=$(i+1); if ($i=="--broadcastStatus") st=$(i+1) } print "transition " id " " st }
    /playlistItem insert/      { for (i=1;i<=NF;i++) if ($i=="--playlistId") print "playlist " $(i+1) }
    /^curl PUT .*liveBroadcasts/ { print "settings" }'
}

finish() {
  # Every ffmpeg started must be gone (no orphans).
  local pid
  for pid in $(awk '$1=="start"{print $2}' "$FAKE_DIR/ffmpeg.events"); do
    kill -0 "$pid" 2>/dev/null && { fail "ffmpeg $pid still running"; kill -KILL "$pid"; }
  done
  if [[ ${#FAILURES[@]} -eq $FAILURES_BEFORE ]]; then
    PASSED=$((PASSED + 1)); echo "ok   $CASE"
  else
    FAILED=$((FAILED + 1)); echo "FAIL $CASE  (output: $T/output, calls: $FAKE_DIR/calls)"
    return
  fi
  rm -rf "$T"
}

# ---- cases -----------------------------------------------------------------

case_rotation() {
  setup rotation <<<'DURATION="2s"
PLAYLIST_ID="PL1, PL2"'
  run_for 8
  expect "$RC" 0 "exit code"
  (( $(calls 'liveBroadcast insert') >= 2 )) || fail "expected at least 2 broadcasts"
  expect "$(actions | head -6 | paste -sd,)" \
    "insert,bind,transition B1 testing,transition B1 live,playlist PL1,playlist PL2" "first cycle"
  expect "$(actions | grep -c 'transition B1 complete')" 1 "B1 completed once"
  grep -E -q -- "--title CCTV \([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}-[0-9]{2}\) " "$FAKE_DIR/calls" ||
    fail "title not in 'NAME (yyyy-mm-dd hh-mm)' format"
  grep -q -- "--streamId S1" "$FAKE_DIR/calls" || fail "bound to wrong stream"
  grep -q -- "--channelId UC-TEST --kVideoId B1" "$FAKE_DIR/calls" || fail "playlist insert args"
  (( $(events '^start') >= 2 )) || fail "ffmpeg should restart for each broadcast"
  grep -q "^start .* -i rtsp://camera/stream1 .*http_upload_hls?cid=TEST-KEY&" "$FAKE_DIR/ffmpeg.events" ||
    fail "ffmpeg args"
  grep -q "token=$T/token.json credential=$T/client_secret.json" "$FAKE_DIR/calls" ||
    fail "token/credential paths not passed to yutu"
  finish
}

case_shutdown() {
  setup shutdown </dev/null
  run_for 3
  expect "$RC" 0 "exit code"
  expect "$(actions | tail -1)" "transition B1 complete" "last action"
  expect "$(events '^term')" 1 "ffmpeg stopped"
  [[ ! -e "$T/state/cam.broadcast" ]] || fail "state file not removed"
  finish
}

case_leftover_broadcast() {
  setup leftover_broadcast </dev/null
  mkdir -p "$FAKE_DIR/broadcasts"
  echo live >"$FAKE_DIR/broadcasts/B9"
  echo B9 >"$T/state/cam.broadcast"
  run_for 3
  expect "$(actions | head -1)" "transition B9 complete" "first action"
  finish
}

case_ffmpeg_crash() {
  setup ffmpeg_crash </dev/null
  export FAKE_FFMPEG_LIFE=2
  run_for 7
  unset FAKE_FFMPEG_LIFE
  (( $(events '^start') >= 2 )) || fail "ffmpeg not restarted"
  expect "$(calls 'liveBroadcast insert')" 1 "broadcast kept across ffmpeg restarts"
  output_has "ffmpeg exited, restarting"
  finish
}

case_camera_unreachable() {
  setup camera_unreachable </dev/null
  export FAKE_FFMPEG_LIFE=0
  run_for 4
  unset FAKE_FFMPEG_LIFE
  # At most a check or two can slip in while ffmpeg is starting up.
  (( $(calls 'liveStream list --ids') <= 2 )) || fail "status checks made while ffmpeg is down"
  expect "$(calls 'liveBroadcast insert')" 0 "broadcasts created"
  finish
}

case_stream_never_active() {
  setup stream_never_active </dev/null
  export FAKE_STREAM_STATUS=inactive
  run_for 6
  unset FAKE_STREAM_STATUS
  expect "$(calls 'liveBroadcast insert')" 0 "broadcasts created"
  output_has "Timed out waiting for stream_status"
  output_has "retrying in 1s"
  finish
}

case_stuck_broadcast_deleted() {
  setup stuck_broadcast_deleted </dev/null
  export FAKE_STUCK=1
  run_for 5
  unset FAKE_STUCK
  actions | grep -q '^delete B1$' || fail "stuck broadcast B1 not deleted"
  output_has "Cycle failed"
  finish
}

case_monitor_off() {
  setup monitor_off </dev/null
  export FAKE_REJECT_TESTING=1
  run_for 3
  unset FAKE_REJECT_TESTING
  actions | grep -q '^transition B1 live$' || fail "did not go live without testing"
  output_has "Broadcast is live"
  finish
}

case_playlist_failure() {
  setup playlist_failure <<<'PLAYLIST_ID="PL1,BAD,PL2"'
  export FAKE_FAIL_PLAYLIST=BAD
  run_for 3
  unset FAKE_FAIL_PLAYLIST
  output_has "Added to playlist PL1"
  output_has "Could not add to playlist BAD"
  output_has "Added to playlist PL2"
  expect "$(calls 'liveBroadcast delete')" 0 "broadcast kept despite playlist error"
  finish
}

case_explicit_stream_id() {
  setup explicit_stream_id <<<'STREAM_ID="S2"'
  run_for 3
  expect "$(calls 'liveStream list --mine')" 0 "stream lookup"
  grep -q -- "--streamId S2" "$FAKE_DIR/calls" || fail "not bound to STREAM_ID"
  finish
}

case_stream_not_found() {
  setup stream_not_found </dev/null
  export FAKE_NO_STREAM=1
  run_to_exit
  unset FAKE_NO_STREAM
  expect "$RC" 1 "exit code"
  output_has "No YouTube live stream found"
  finish
}

case_missing_token() {
  setup missing_token </dev/null
  rm "$T/token.json"
  run_to_exit
  expect "$RC" 1 "exit code"
  output_has "Token file not found"
  expect "$(wc -l <"$FAKE_DIR/calls")" 0 "yutu calls"
  finish
}

case_relative_token_path() {
  # Relative TOKEN_FILE resolves against the script's folder, not the cwd.
  setup relative_token_path <<<'TOKEN_FILE="does-not-exist.token.json"'
  run_to_exit
  output_has "Token file not found: $(cd "$TEST_DIR/.." && pwd)/does-not-exist.token.json"
  finish
}

case_latency_and_captions() {
  setup latency_and_captions <<<'LATENCY="low"
CAPTIONS="embedded"'
  run_for 3
  expect "$(actions | head -5 | paste -sd,)" \
    "insert,settings,bind,transition B1 testing,transition B1 live" "settings applied before bind"
  local put="$FAKE_DIR/put.json"
  expect "$(jq -r .id "$put")" B1 "updated broadcast"
  expect "$(jq -r .contentDetails.latencyPreference "$put")" low "latencyPreference"
  expect "$(jq -r .contentDetails.closedCaptionsType "$put")" closedCaptionsEmbedded "closedCaptionsType"
  # Existing settings are kept; read-only and deprecated fields are dropped.
  expect "$(jq -c '.contentDetails | [.enableDvr, .monitorStream.enableMonitorStream, .recordFromStart]' "$put")" \
    "[true,true,true]" "existing contentDetails preserved"
  expect "$(jq -c '.contentDetails | [has("boundStreamId"), has("enableClosedCaptions")]' "$put")" \
    "[false,false]" "read-only/deprecated fields removed"
  grep -q 'client_id=CLIENT-ID&client_secret=CS-SECRET&refresh_token=RT-SECRET&grant_type=refresh_token' \
    "$FAKE_DIR/token.form" || fail "token refresh form"
  grep '^curl ' "$FAKE_DIR/calls" | grep -q -E 'SECRET' && fail "secret visible in curl arguments"
  grep -q '"access_token":"old"' "$T/token.json" || fail "token file was modified"
  output_has "Applied settings: latency=low captions=embedded"
  finish
}

case_latency_only() {
  setup latency_only <<<'LATENCY="ultraLow"'
  run_for 3
  expect "$(jq -r .contentDetails.latencyPreference "$FAKE_DIR/put.json")" ultraLow "latencyPreference"
  expect "$(jq -r .contentDetails.closedCaptionsType "$FAKE_DIR/put.json")" closedCaptionsDisabled "captions untouched"
  finish
}

case_no_settings_no_api_calls() {
  setup no_settings_no_api_calls </dev/null
  run_for 3
  expect "$(calls '^curl ')" 0 "direct API calls"
  output_has "Broadcast is live"
  finish
}

case_settings_failure_keeps_streaming() {
  setup settings_failure_keeps_streaming <<<'LATENCY="low"'
  export FAKE_API_FAIL=1
  run_for 3
  unset FAKE_API_FAIL
  output_has "YouTube API PUT liveBroadcasts failed: Invalid latency preference."
  output_has "Continuing with YouTube's default"
  output_has "Broadcast is live"
  expect "$(calls 'liveBroadcast delete')" 0 "broadcast kept"
  finish
}

case_token_refresh_failure() {
  setup token_refresh_failure <<<'CAPTIONS="http"'
  export FAKE_TOKEN_FAIL=1
  run_for 3
  unset FAKE_TOKEN_FAIL
  output_has "Could not refresh the access token"
  expect "$(calls '^curl PUT')" 0 "updates without a token"
  output_has "Broadcast is live"
  finish
}

case_invalid_settings() {
  setup invalid_settings <<<'LATENCY="fast"'
  run_to_exit
  expect "$RC" 1 "exit code (bad LATENCY)"
  output_has "Invalid LATENCY"
  cat >>"$T/streams/cam.conf" <<<'LATENCY=""
CAPTIONS="yes"'
  run_to_exit
  expect "$RC" 1 "exit code (bad CAPTIONS)"
  output_has "Invalid CAPTIONS"
  cat >>"$T/streams/cam.conf" <<<'LATENCY="ultraLow"
CAPTIONS="embedded"'
  run_to_exit
  expect "$RC" 1 "exit code (ultraLow + captions)"
  output_has "doesn't support closed captions with ultra low latency"
  finish
}

case_bad_duration() {
  setup bad_duration <<<'DURATION="12 hours"'
  run_to_exit
  expect "$RC" 1 "exit code"
  output_has "Invalid DURATION"
  finish
}

# ---- main ------------------------------------------------------------------

ALL=$(declare -F | awk '{print $3}' | sed -n 's/^case_//p')
for name in "${@:-$ALL}"; do
  for c in $name; do
    declare -F "case_$c" >/dev/null || { echo "Unknown case: $c" >&2; exit 2; }
    "case_$c"
  done
done

echo
for f in "${FAILURES[@]}"; do echo "  - $f"; done
echo "$PASSED passed, $FAILED failed"
[[ $FAILED -eq 0 ]]
