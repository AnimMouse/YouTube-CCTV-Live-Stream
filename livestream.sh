#!/usr/bin/env bash
#
# livestream.sh - stream an RTSP camera to YouTube in back-to-back broadcasts.
#
# Each broadcast is ended after DURATION (default 12h, so YouTube's DVR keeps
# working) and a new one is created right away, titled "<NAME> (yyyy-mm-dd hh-mm)".
#
# Usage:   ./livestream.sh streams/cctv.conf
# Run one instance per config file to stream several cameras at the same time.
#
# Requires: bash, ffmpeg, jq, yutu (https://github.com/eat-pray-ai/yutu)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -ne 1 || ! -f "$1" ]]; then
  echo "Usage: $0 <config-file>" >&2
  exit 1
fi
CONFIG="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"

# ---- defaults (override in the config file) --------------------------------
NAME=""
RTSP_URL=""
STREAM_KEY=""
STREAM_ID=""            # optional; looked up from STREAM_KEY when empty
INGEST_URL=""           # optional; defaults to YouTube's HLS ingest for STREAM_KEY
DURATION="12h"          # length of each broadcast (e.g. 12h, 11h50m, 3600)
PRIVACY="unlisted"      # public | unlisted | private
DESCRIPTION=""
GO_LIVE_TIMEOUT=300     # seconds to wait for the stream/broadcast to become live
POLL_INTERVAL=10        # seconds between status checks while waiting
RETRY_DELAY=120         # seconds to wait before retrying a failed cycle
FFMPEG_RESTART_DELAY=5  # seconds to wait before restarting a crashed ffmpeg
FFMPEG_INPUT_ARGS=(-rtsp_transport tcp)
FFMPEG_OUTPUT_ARGS=(-c:v copy -c:a libopus -b:a 96k)
YUTU_BIN="yutu"
LOG_DIR="$SCRIPT_DIR/logs"
STATE_DIR="$SCRIPT_DIR/state"
export YUTU_CREDENTIAL="${YUTU_CREDENTIAL:-$SCRIPT_DIR/client_secret.json}"
export YUTU_CACHE_TOKEN="${YUTU_CACHE_TOKEN:-$SCRIPT_DIR/youtube.token.json}"

# shellcheck source=/dev/null
source "$CONFIG"

[[ -n "$NAME" ]]       || { echo "NAME is not set in $CONFIG" >&2; exit 1; }
[[ -n "$RTSP_URL" ]]   || { echo "RTSP_URL is not set in $CONFIG" >&2; exit 1; }
[[ -n "$STREAM_KEY" || -n "$INGEST_URL" ]] || { echo "STREAM_KEY is not set in $CONFIG" >&2; exit 1; }
for bin in ffmpeg jq "$YUTU_BIN"; do
  command -v "$bin" >/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

INGEST_URL="${INGEST_URL:-https://a.upload.youtube.com/http_upload_hls?cid=${STREAM_KEY}&copy=0&file=index.m3u8}"

# A file-safe id for logs/state, derived from the config file name.
ID="$(basename "$CONFIG" .conf)"
mkdir -p "$LOG_DIR" "$STATE_DIR"
FFMPEG_LOG="$LOG_DIR/$ID.ffmpeg.log"
STATE_FILE="$STATE_DIR/$ID.broadcast"
# Shared by every instance so concurrent yutu calls don't race on the token file.
YUTU_LOCK="$STATE_DIR/yutu.lock"
YUTU_ERR="$STATE_DIR/$ID.yutu.err"

FFMPEG_PID=""
BROADCAST_ID=""

# ---- helpers ---------------------------------------------------------------
log() { printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$NAME" "$*" >&2; }

to_seconds() {
  local s="$1" total=0
  if [[ "$s" =~ ^[0-9]+$ ]]; then echo "$s"; return; fi
  while [[ "$s" =~ ^([0-9]+)([hms])(.*)$ ]]; do
    case "${BASH_REMATCH[2]}" in
      h) total=$((total + BASH_REMATCH[1] * 3600)) ;;
      m) total=$((total + BASH_REMATCH[1] * 60)) ;;
      s) total=$((total + BASH_REMATCH[1])) ;;
    esac
    s="${BASH_REMATCH[3]}"
  done
  [[ -z "$s" && $total -gt 0 ]] || { echo "Invalid DURATION: $1" >&2; exit 1; }
  echo "$total"
}

# Interruptible sleep, so SIGTERM/SIGINT are handled immediately.
nap() { sleep "$1" & wait $!; }

# Runs yutu under a shared lock. Prints stdout; logs output on failure.
yutu() {
  local out rc
  out="$(flock "$YUTU_LOCK" "$YUTU_BIN" "$@" 2>"$YUTU_ERR")"
  rc=$?
  if [[ $rc -ne 0 ]]; then
    log "yutu $1 $2 failed (exit $rc): $(grep -h -m1 -i 'error' "$YUTU_ERR" - <<<"$out")"
    return $rc
  fi
  printf '%s\n' "$out"
}

# First item of a yutu JSON result, whether it's an object or an array.
first_item() { jq -c 'if type == "array" then .[0] else . end' 2>/dev/null; }

lookup_stream_id() {
  yutu liveStream list --mine --maxResults 0 --output json |
    jq -r --arg key "$STREAM_KEY" \
      '[.[]? | select(.cdn.ingestionInfo.streamName == $key) | .id][0] // empty' 2>/dev/null
}

stream_status() {
  yutu liveStream list --ids "$STREAM_ID" --output json | first_item |
    jq -r '.status.streamStatus // empty'
}

broadcast_status() {
  yutu liveBroadcast list --ids "$1" --output json | first_item |
    jq -r '.status.lifeCycleStatus // empty'
}

create_broadcast() {
  local title="$1" start
  start="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  yutu liveBroadcast insert --yes --output json \
    --title "$title" --description "$DESCRIPTION" \
    --privacyStatus "$PRIVACY" --scheduledStartTime "$start" |
    first_item | jq -r '.id // empty'
}

transition() {
  yutu liveBroadcast transition --yes --output silent --ids "$1" --broadcastStatus "$2" >/dev/null
}

# Waits until `$1 args...` prints one of the wanted values (space separated in $2).
wait_for() {
  local wanted="$2" fn="$1" deadline=$(( $(date +%s) + GO_LIVE_TIMEOUT )) value
  shift 2
  while (( $(date +%s) < deadline )); do
    # Skip the API call while ffmpeg is down (e.g. camera unreachable).
    if [[ -n "$FFMPEG_PID" ]] && kill -0 "$FFMPEG_PID" 2>/dev/null; then
      value="$("$fn" "$@")"
      [[ " $wanted " == *" $value "* ]] && return 0
    fi
    ensure_ffmpeg
    nap "$POLL_INTERVAL"
  done
  log "Timed out waiting for $fn to become '$wanted' (last: '${value:-unknown}')"
  return 1
}

start_ffmpeg() {
  log "Starting ffmpeg"
  ffmpeg -nostdin -hide_banner -stats_period 60 \
    "${FFMPEG_INPUT_ARGS[@]}" -i "$RTSP_URL" \
    "${FFMPEG_OUTPUT_ARGS[@]}" "$INGEST_URL" >>"$FFMPEG_LOG" 2>&1 &
  FFMPEG_PID=$!
}

ensure_ffmpeg() {
  if [[ -z "$FFMPEG_PID" ]] || ! kill -0 "$FFMPEG_PID" 2>/dev/null; then
    [[ -n "$FFMPEG_PID" ]] && { log "ffmpeg exited, restarting in ${FFMPEG_RESTART_DELAY}s (see $FFMPEG_LOG)"; nap "$FFMPEG_RESTART_DELAY"; }
    start_ffmpeg
  fi
}

stop_ffmpeg() {
  [[ -n "$FFMPEG_PID" ]] || return 0
  if kill -0 "$FFMPEG_PID" 2>/dev/null; then
    log "Stopping ffmpeg"
    kill -TERM "$FFMPEG_PID" 2>/dev/null
    for _ in {1..10}; do kill -0 "$FFMPEG_PID" 2>/dev/null || break; sleep 1; done
    kill -KILL "$FFMPEG_PID" 2>/dev/null
  fi
  wait "$FFMPEG_PID" 2>/dev/null
  FFMPEG_PID=""
}

# Ends a broadcast; deletes it instead if it never went live.
end_broadcast() {
  local id="$1"
  [[ -n "$id" ]] || return 0
  log "Ending broadcast $id"
  if ! transition "$id" complete; then
    local status
    status="$(broadcast_status "$id")"
    case "$status" in
      complete|revoked|"") ;;
      *) log "Deleting broadcast $id (status: $status)"
         yutu liveBroadcast delete --yes --ids "$id" >/dev/null ;;
    esac
  fi
  rm -f "$STATE_FILE"
}

shutdown() {
  log "Shutting down"
  trap - INT TERM
  end_broadcast "$BROADCAST_ID"
  stop_ffmpeg
  exit 0
}
trap shutdown INT TERM

# ---- one broadcast ---------------------------------------------------------
run_cycle() {
  local deadline title remaining

  # Wait for the camera feed to reach YouTube before creating a broadcast, so a
  # camera outage only costs cheap status checks instead of API quota.
  ensure_ffmpeg
  log "Waiting for YouTube to receive the stream"
  wait_for stream_status "active" || return 1

  title="$NAME ($(date '+%Y-%m-%d %H-%M'))"
  log "Creating broadcast \"$title\""
  BROADCAST_ID="$(create_broadcast "$title")"
  [[ -n "$BROADCAST_ID" ]] || { log "Could not create broadcast"; return 1; }
  echo "$BROADCAST_ID" >"$STATE_FILE"
  log "Broadcast id: $BROADCAST_ID  https://youtu.be/$BROADCAST_ID"

  yutu liveBroadcast bind --yes --output silent --ids "$BROADCAST_ID" --streamId "$STREAM_ID" >/dev/null ||
    { log "Could not bind broadcast to stream $STREAM_ID"; return 1; }

  # With stream monitoring on (YouTube's default) a broadcast must go through
  # "testing" before "live"; with it off, the testing transition is rejected.
  if transition "$BROADCAST_ID" testing; then
    wait_for broadcast_status "testing" "$BROADCAST_ID" || return 1
  fi
  transition "$BROADCAST_ID" live || return 1
  wait_for broadcast_status "live" "$BROADCAST_ID" || return 1
  deadline=$(( $(date +%s) + DURATION_SECS ))
  log "Broadcast is live; ending at $(date -d "@$deadline" '+%Y-%m-%d %H:%M:%S')"

  while remaining=$(( deadline - $(date +%s) )); (( remaining > 0 )); do
    nap $(( remaining < 10 ? remaining : 10 ))
    ensure_ffmpeg
  done
  return 0
}

# ---- main ------------------------------------------------------------------
DURATION_SECS="$(to_seconds "$DURATION")" || exit 1

if [[ -z "$STREAM_ID" ]]; then
  STREAM_ID="$(lookup_stream_id)"
  [[ -n "$STREAM_ID" ]] || { log "No YouTube live stream found for STREAM_KEY; set STREAM_ID in $CONFIG"; exit 1; }
fi
log "Using YouTube stream $STREAM_ID, broadcasts of ${DURATION_SECS}s"

# Clean up a broadcast left behind by a previous run that was killed.
if [[ -s "$STATE_FILE" ]]; then
  end_broadcast "$(cat "$STATE_FILE")"
fi

while true; do
  if run_cycle; then
    end_broadcast "$BROADCAST_ID"
    BROADCAST_ID=""
    # ffmpeg is restarted for each broadcast so YouTube sees a fresh stream.
    stop_ffmpeg
  else
    log "Cycle failed, retrying in ${RETRY_DELAY}s"
    end_broadcast "$BROADCAST_ID"
    BROADCAST_ID=""
    stop_ffmpeg
    nap "$RETRY_DELAY"
  fi
done
