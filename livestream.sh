#!/usr/bin/env bash
#
# livestream.sh - stream an RTSP camera to YouTube in back-to-back broadcasts.
#
# Each broadcast is ended after DURATION (default 11h55m, so YouTube's DVR keeps
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
DURATION="11h55m"       # time live per broadcast (e.g. 11h55m, 6h, 3600); keep under 12h
PRIVACY="unlisted"      # public | unlisted | private
DESCRIPTION=""
PLAYLIST_ID=""          # optional; playlist(s) to add each broadcast to (comma separated)
LATENCY=""              # optional; normal | low | ultraLow (empty: YouTube default, normal)
CAPTIONS=""             # optional; disabled | embedded | http (empty: YouTube default, disabled)
GO_LIVE_TIMEOUT=300     # seconds to wait for the stream/broadcast to become live
POLL_INTERVAL=10        # seconds between status checks while waiting
RETRY_DELAY=120         # seconds to wait before retrying a failed cycle
FFMPEG_RESTART_DELAY=5  # seconds to wait before restarting a crashed ffmpeg
FFMPEG_CHECK_INTERVAL=10 # seconds between ffmpeg health checks while live
FFMPEG_INPUT_ARGS=(-rtsp_transport tcp)
FFMPEG_OUTPUT_ARGS=(-c:v copy -c:a libopus -b:a 96k)
YUTU_BIN="yutu"
LOG_DIR="$SCRIPT_DIR/logs"
STATE_DIR="$SCRIPT_DIR/state"
# YouTube account: use a different TOKEN_FILE per account. Relative paths are
# resolved against this script's folder.
CREDENTIAL_FILE="client_secret.json"
TOKEN_FILE="youtube.token.json"

# shellcheck source=/dev/null
source "$CONFIG"

[[ -n "$NAME" ]]       || { echo "NAME is not set in $CONFIG" >&2; exit 1; }
[[ -n "$RTSP_URL" ]]   || { echo "RTSP_URL is not set in $CONFIG" >&2; exit 1; }
[[ -n "$STREAM_KEY" || -n "$INGEST_URL" ]] || { echo "STREAM_KEY is not set in $CONFIG" >&2; exit 1; }
case "$LATENCY" in
  ""|normal|low|ultraLow) ;;
  *) echo "Invalid LATENCY: $LATENCY (use normal, low or ultraLow)" >&2; exit 1 ;;
esac
case "$CAPTIONS" in
  "")       CAPTIONS_TYPE="" ;;
  disabled) CAPTIONS_TYPE="closedCaptionsDisabled" ;;
  embedded) CAPTIONS_TYPE="closedCaptionsEmbedded" ;;
  http)     CAPTIONS_TYPE="closedCaptionsHttpPost" ;;
  *) echo "Invalid CAPTIONS: $CAPTIONS (use disabled, embedded or http)" >&2; exit 1 ;;
esac
if [[ "$LATENCY" == ultraLow && ( "$CAPTIONS" == embedded || "$CAPTIONS" == http ) ]]; then
  echo "YouTube doesn't support closed captions with ultra low latency" >&2; exit 1
fi

deps=(ffmpeg jq "$YUTU_BIN")
[[ -n "$LATENCY$CAPTIONS" ]] && deps+=(curl)
for bin in "${deps[@]}"; do
  command -v "$bin" >/dev/null || { echo "Missing dependency: $bin" >&2; exit 1; }
done

abs_path() { [[ "$1" == /* ]] && echo "$1" || echo "$SCRIPT_DIR/$1"; }
export YUTU_CREDENTIAL="$(abs_path "$CREDENTIAL_FILE")"
export YUTU_CACHE_TOKEN="$(abs_path "$TOKEN_FILE")"
[[ -f "$YUTU_CREDENTIAL" ]] || { echo "Credential file not found: $YUTU_CREDENTIAL" >&2; exit 1; }
[[ -f "$YUTU_CACHE_TOKEN" ]] || { echo "Token file not found: $YUTU_CACHE_TOKEN (run: yutu auth --credential $YUTU_CREDENTIAL --cacheToken $YUTU_CACHE_TOKEN)" >&2; exit 1; }

INGEST_URL="${INGEST_URL:-https://a.upload.youtube.com/http_upload_hls?cid=${STREAM_KEY}&copy=0&file=index.m3u8}"

# A file-safe id for logs/state, derived from the config file name.
ID="$(basename "$CONFIG" .conf)"
mkdir -p "$LOG_DIR" "$STATE_DIR"
FFMPEG_LOG="$LOG_DIR/$ID.ffmpeg.log"
STATE_FILE="$STATE_DIR/$ID.broadcast"
# One lock per token file, so instances sharing an account don't race when
# yutu refreshes the token.
YUTU_LOCK="$STATE_DIR/yutu-$(printf '%s' "$YUTU_CACHE_TOKEN" | md5sum | cut -c1-12).lock"
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

# Creates a broadcast; prints "<broadcast id> <channel id>".
create_broadcast() {
  local title="$1" start
  start="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  yutu liveBroadcast insert --yes --output json \
    --title "$title" --description "$DESCRIPTION" \
    --privacyStatus "$PRIVACY" --scheduledStartTime "$start" |
    first_item | jq -r 'select(.id) | "\(.id) \(.snippet.channelId // "")"'
}

# Adds the broadcast to each playlist in PLAYLIST_ID. Failures are only logged.
add_to_playlists() {
  local video_id="$1" channel_id="$2" playlist playlists
  [[ -n "$PLAYLIST_ID" ]] || return 0
  IFS=', ' read -ra playlists <<<"$PLAYLIST_ID"
  for playlist in "${playlists[@]}"; do
    [[ -n "$playlist" ]] || continue
    if yutu playlistItem insert --yes --output silent --kind video \
        --playlistId "$playlist" --channelId "$channel_id" --kVideoId "$video_id" >/dev/null; then
      log "Added to playlist $playlist"
    else
      log "Could not add to playlist $playlist"
    fi
  done
}

# yutu can't set contentDetails (latency, captions), so those go straight to
# the YouTube API with an access token refreshed from TOKEN_FILE. The new token
# isn't written back, so this never races with yutu over the token file.
access_token() {
  local form
  form="$(jq -rn --slurpfile cred "$YUTU_CREDENTIAL" --slurpfile tok "$YUTU_CACHE_TOKEN" '
    ($cred[0].installed // $cred[0].web) as $c
    | "client_id=\($c.client_id | @uri)&client_secret=\($c.client_secret | @uri)" +
      "&refresh_token=\($tok[0].refresh_token | @uri)&grant_type=refresh_token"' 2>/dev/null)" ||
    { log "Could not read client id/secret or refresh token"; return 1; }
  # Secrets go through stdin, not arguments, so they don't show up in `ps`.
  curl -sS --fail-with-body --data @- https://oauth2.googleapis.com/token <<<"$form" 2>&1 |
    jq -r '.access_token // empty' 2>/dev/null | grep . ||
    { log "Could not refresh the access token"; return 1; }
}

# youtube_api METHOD PATH TOKEN [JSON_BODY]
youtube_api() {
  local out body_args=()
  [[ -n "${4:-}" ]] && body_args=(-H 'Content-Type: application/json' --data-binary "$4")
  # The token is passed via a file descriptor so it doesn't show up in `ps`.
  if ! out="$(curl -sS --fail-with-body -X "$1" \
      -H @<(printf 'Authorization: Bearer %s\n' "$3") "${body_args[@]}" \
      "https://www.googleapis.com/youtube/v3/$2" 2>&1)"; then
    log "YouTube API $1 ${2%%\?*} failed: $(jq -r '.error.message // empty' <<<"$out" 2>/dev/null || head -c 200 <<<"$out")"
    return 1
  fi
  printf '%s\n' "$out"
}

# Applies LATENCY/CAPTIONS to a broadcast. The update replaces all of
# contentDetails, so the current values are fetched and merged first.
set_broadcast_settings() {
  local id="$1" token current body
  [[ -n "$LATENCY$CAPTIONS_TYPE" ]] || return 0
  token="$(access_token)" || return 1
  current="$(youtube_api GET "liveBroadcasts?part=contentDetails&id=$id" "$token")" || return 1
  body="$(jq -c --arg id "$id" --arg latency "$LATENCY" --arg captions "$CAPTIONS_TYPE" '
    .items[0].contentDetails // empty
    | del(.boundStreamId, .boundStreamLastUpdateTimeMs)
    | if $latency != "" then .latencyPreference = $latency else . end
    | if $captions != "" then .closedCaptionsType = $captions | del(.enableClosedCaptions) else . end
    | {id: $id, contentDetails: .}' <<<"$current")"
  [[ -n "$body" ]] || { log "Broadcast $id not found when applying settings"; return 1; }
  youtube_api PUT "liveBroadcasts?part=contentDetails" "$token" "$body" >/dev/null || return 1
  log "Applied settings:${LATENCY:+ latency=$LATENCY}${CAPTIONS:+ captions=$CAPTIONS}"
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
  local deadline title remaining channel_id

  # Wait for the camera feed to reach YouTube before creating a broadcast, so a
  # camera outage only costs cheap status checks instead of API quota.
  ensure_ffmpeg
  log "Waiting for YouTube to receive the stream"
  wait_for stream_status "active" || return 1

  title="$NAME ($(date '+%Y-%m-%d %H-%M'))"
  log "Creating broadcast \"$title\""
  read -r BROADCAST_ID channel_id <<<"$(create_broadcast "$title")"
  [[ -n "$BROADCAST_ID" ]] || { log "Could not create broadcast"; return 1; }
  echo "$BROADCAST_ID" >"$STATE_FILE"
  log "Broadcast id: $BROADCAST_ID  https://youtu.be/$BROADCAST_ID"

  # Must happen before going live (latency can't change after). A failure is
  # only logged: the stream still works with YouTube's defaults, and retrying
  # the cycle would cost quota on every attempt.
  set_broadcast_settings "$BROADCAST_ID" || log "Continuing with YouTube's default latency/captions"

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
  # Added only once live, so failed attempts don't leave playlist entries behind.
  add_to_playlists "$BROADCAST_ID" "$channel_id"

  while remaining=$(( deadline - $(date +%s) )); (( remaining > 0 )); do
    nap $(( remaining < FFMPEG_CHECK_INTERVAL ? remaining : FFMPEG_CHECK_INTERVAL ))
    ensure_ffmpeg
  done
  return 0
}

# ---- main ------------------------------------------------------------------
DURATION_SECS="$(to_seconds "$DURATION")" || exit 1
# Broadcasts past 12h can get stuck on "Processing will begin shortly", and the
# testing phase and ending add a little on top of DURATION.
if (( DURATION_SECS > 12 * 3600 - 60 )); then
  log "Warning: DURATION of ${DURATION_SECS}s leaves under a minute before YouTube's 12h limit; 11h55m is safer"
fi

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
