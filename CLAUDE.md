# CLAUDE.md

Bash script that streams RTSP cameras to YouTube with ffmpeg and uses
[yutu](https://github.com/eat-pray-ai/yutu) (YouTube Data API CLI) to rotate
broadcasts every 12h, because YouTube's DVR stops working past 12 hours.
User-facing docs are in `README.md`.

## Files

- `livestream.sh`: everything. One process per camera config, run as `./livestream.sh streams/<id>.conf`.
- `streams/cctv.conf.example`: documents every config option. Real `streams/*.conf` are gitignored.
- `livestream@.service`: systemd template, one instance per config (`livestream@<id>`).

## Behaviour that must be preserved

- Title format is `<NAME> (yyyy-mm-dd hh-mm)`, e.g. `CCTV (2026-08-30 10-30)`.
- Cycle order: start ffmpeg → wait for stream `active` → insert broadcast → bind → `testing` → `live` → add to playlists → wait `DURATION` → `complete` → stop ffmpeg.
  The broadcast is created only after the stream is active, so a camera outage doesn't burn API quota. Keep it that way.
- `DURATION` counts from when the broadcast becomes live, not from when it's created.
- Several instances run at once (multiple cameras, possibly multiple accounts via `TOKEN_FILE`). Logs, state and locks are keyed by the config file's basename (`$ID`).
- The current broadcast ID is kept in `state/<id>.broadcast`, so a killed run's broadcast is ended on the next start.

## Non-obvious gotchas

- **yutu needs `--yes`** on every mutating command (insert, bind, transition, delete), or it fails with "operation not confirmed".
- **yutu prints usage text to stdout on errors.** The `yutu()` wrapper checks the exit code before anything parses its JSON. Always call yutu through that wrapper.
- **`yutu liveBroadcast insert` doesn't send `contentDetails`**, so YouTube defaults apply: no auto-start/auto-stop, DVR on, stream monitor on. That's why the script transitions manually, and why it tries `testing` before `live` (with the monitor on, going straight to `live` is rejected).
- **`yutu playlistItem insert` requires `--channelId`.** It comes from `snippet.channelId` in the broadcast-insert response.
- **`log()` writes to stderr on purpose.** Many functions return values via `$(...)`, so logging to stdout would corrupt them.
- **ffmpeg is stopped with SIGTERM, not SIGINT.** Non-interactive bash starts background jobs with SIGINT ignored.
- **Waits use `nap`** (`sleep & wait`), so SIGTERM/SIGINT run the `shutdown` trap immediately.
- **yutu calls go through `flock`**, with one lock per token file, so instances sharing an account don't race when yutu refreshes the token.
- **API quota is 10,000 units/day per Google Cloud project.** insert/bind/transition/delete/playlistItem insert cost 50 each, list costs 1. Avoid adding polling or retries that call mutating endpoints in a loop. `wait_for` skips API calls while ffmpeg isn't running.
- The default ingest is YouTube's HLS endpoint (`http_upload_hls?cid=<key>`); the stream ID is looked up by matching `cdn.ingestionInfo.streamName` to `STREAM_KEY`.

## Conventions

- Plain bash, with `set -uo pipefail` (no `-e`; errors are handled explicitly). Dependencies are ffmpeg, jq, yutu, flock and GNU date.
- New options get a default in the "defaults" block of `livestream.sh` (with an inline comment), a commented entry in `streams/cctv.conf.example`, and a README mention if they're user-facing.
- Relative file paths in configs resolve against the script's folder (`abs_path`).
- Never commit real configs, `client_secret*.json`, token files, `tokens/`, `logs/` or `state/`.

## Testing

There's no test suite, and real runs need a YouTube account. To verify changes
without one, put stub `yutu` and `ffmpeg` executables first on `PATH`:

- The `yutu` stub records its arguments and returns JSON shaped like the real API (`[{"id":…,"status":{"streamStatus":"active"}}]` for lists, `{"id":…,"snippet":{"channelId":…}}` for insert), keeping each broadcast's lifecycle status in a temp dir.
- The `ffmpeg` stub sleeps and traps TERM. Make it exit early to simulate crashes or an unreachable camera.

Run the script with a test config that sets a short duration (`DURATION="10s"`, `POLL_INTERVAL=1`) and temp `LOG_DIR`/`STATE_DIR`. Then check the recorded yutu calls and the log, and send SIGTERM to check the shutdown path. Run `bash -n livestream.sh` (and `shellcheck` if available) after edits.
