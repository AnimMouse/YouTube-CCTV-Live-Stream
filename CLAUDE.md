# CLAUDE.md

Bash script that streams RTSP cameras to YouTube with ffmpeg and uses
[yutu](https://github.com/eat-pray-ai/yutu) (YouTube Data API CLI) to rotate
broadcasts every 12h, because YouTube's DVR stops working past 12 hours.
User-facing docs are in `README.md`.

## Files

- `livestream.sh`: everything. One process per camera config, run as `./livestream.sh streams/<id>.conf`.
- `streams/cctv.conf.example`: documents every config option. Real `streams/*.conf` are gitignored.
- `livestream@.service`: systemd template, one instance per config (`livestream@<id>`).
- `test/`: `run.sh` (test cases) and `bin/` (fake `yutu`, `ffmpeg` and `curl`). See Testing.

## Behaviour that must be preserved

- Title format is `<NAME> (yyyy-mm-dd hh-mm)`, e.g. `CCTV (2026-08-30 10-30)`.
- Cycle order: start ffmpeg → wait for stream `active` → insert broadcast → apply `LATENCY`/`CAPTIONS` → bind → `testing` → `live` → add to playlists → wait `DURATION` → `complete` → stop ffmpeg.
  The broadcast is created only after the stream is active, so a camera outage doesn't burn API quota. Keep it that way.
- `DURATION` counts from when the broadcast becomes live, not from when it's created. The default is 11h55m, not 12h: broadcasts slightly past 12h got stuck on "Processing will begin shortly" in real use (testing and ending add time on top of `DURATION`). The script warns when `DURATION` leaves under a minute of margin.
- Several instances run at once (multiple cameras, possibly multiple accounts via `TOKEN_FILE`). Logs, state and locks are keyed by the config file's basename (`$ID`).
- The current broadcast ID is kept in `state/<id>.broadcast`, so a killed run's broadcast is ended on the next start.

## Non-obvious gotchas

- **yutu needs `--yes`** on every mutating command (insert, bind, transition, delete), or it fails with "operation not confirmed".
- **yutu prints usage text to stdout on errors.** The `yutu()` wrapper checks the exit code before anything parses its JSON. Always call yutu through that wrapper.
- **`yutu liveBroadcast insert` doesn't send `contentDetails`**, so YouTube defaults apply: no auto-start/auto-stop, DVR on, stream monitor on. That's why the script transitions manually, and why it tries `testing` before `live` (with the monitor on, going straight to `live` is rejected).
- **Latency and captions bypass yutu.** yutu can't set `contentDetails`, so `set_broadcast_settings` calls the YouTube API with `curl`:
  - `access_token` refreshes a token from `TOKEN_FILE`'s `refresh_token` and the client id/secret, and never writes it back (so it can't race with yutu).
  - Secrets go through stdin (`--data @-`) and a file descriptor (`-H @<(...)`), not arguments, so they don't show up in `ps`.
  - `liveBroadcasts.update` replaces all of `contentDetails`, so it GETs the current values, merges, and drops read-only `boundStream*` and the deprecated `enableClosedCaptions`.
  - It must run before going live. Failures are logged, not fatal.
- **`yutu playlistItem insert` requires `--channelId`.** It comes from `snippet.channelId` in the broadcast-insert response.
- **`log()` writes to stderr on purpose.** Many functions return values via `$(...)`, so logging to stdout would corrupt them.
- **ffmpeg is stopped with SIGTERM, not SIGINT.** Non-interactive bash starts background jobs with SIGINT ignored.
- **Waits use `nap`** (`sleep & wait`), so SIGTERM/SIGINT run the `shutdown` trap immediately.
- **yutu calls go through `flock`**, with one lock per token file, so instances sharing an account don't race when yutu refreshes the token.
- **API quota is 10,000 units/day per Google Cloud project.** insert/bind/transition/delete/playlistItem insert cost 50 each, list costs 1. Avoid adding polling or retries that call mutating endpoints in a loop. `wait_for` skips API calls while ffmpeg isn't running.
- The default ingest is YouTube's HLS endpoint (`http_upload_hls?cid=<key>`); the stream ID is looked up by matching `cdn.ingestionInfo.streamName` to `STREAM_KEY`.

## Conventions

- Plain bash, with `set -uo pipefail` (no `-e`; errors are handled explicitly). Dependencies are ffmpeg, jq, yutu, flock and GNU date, plus curl when `LATENCY`/`CAPTIONS` are set.
- New options get a default in the "defaults" block of `livestream.sh` (with an inline comment), a commented entry in `streams/cctv.conf.example`, and a README mention if they're user-facing.
- Relative file paths in configs resolve against the script's folder (`abs_path`).
- Never commit real configs, `client_secret*.json`, token files, `tokens/`, `logs/` or `state/`.

## Testing

```sh
test/run.sh                  # all cases, ~1 minute
test/run.sh rotation shutdown  # selected cases
```

Tests run `livestream.sh` against fakes in `test/bin/` (put first on `PATH`), so no YouTube account is needed:

- `test/bin/yutu` records every call in `$FAKE_DIR/calls`, returns JSON shaped like the real API, and enforces the real transition rules (`ready→testing→live→complete`; anything else fails like the API). It requires `--yes` on mutating commands. It reports the stream `active` only while a fake ffmpeg is running. Behaviour knobs (`FAKE_STREAM_STATUS`, `FAKE_REJECT_TESTING`, `FAKE_STUCK`, `FAKE_FAIL_PLAYLIST`, `FAKE_NO_STREAM`) are documented at the top of the file.
- `test/bin/curl` fakes Google's OAuth token endpoint and `liveBroadcasts` GET/PUT. PUT bodies go to `$FAKE_DIR/put.json` and the token form to `$FAKE_DIR/token.form`. It checks the bearer token, and its knobs are `FAKE_TOKEN_FAIL` and `FAKE_API_FAIL`. Test credentials contain `*-SECRET` values, so a case can assert they never appear in arguments.
- `test/bin/ffmpeg` logs `start`/`term`/`exit` events to `$FAKE_DIR/ffmpeg.events`. `FAKE_FFMPEG_LIFE=<s>` makes it exit early (crash), and `0` simulates an unreachable camera.
- Each case in `test/run.sh` (`case_<name>`) gets a temp dir with a config using short timeouts (`POLL_INTERVAL=1`, `FFMPEG_CHECK_INTERVAL=1`, etc.). Extra config lines are passed to `setup` on stdin. Cases assert on the recorded calls (`actions` condenses them to e.g. `transition B1 live`), the ffmpeg events and the script output. `finish` also fails a case that leaves an ffmpeg running.
- Failed cases keep their temp dir and print its path.

When changing behaviour, add or update a case. Run `bash -n livestream.sh` (and `shellcheck` if available) after edits. Real YouTube behaviour can still differ from the fakes, so changes to the API flow need a real run before release.
