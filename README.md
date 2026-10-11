# YouTube CCTV livestream

`livestream.sh` streams an RTSP camera to YouTube and starts a fresh broadcast
every 12 hours (YouTube's DVR stops working after 12h). Broadcasts are titled
`<NAME> (yyyy-mm-dd hh-mm)`, e.g. `CCTV (2026-08-30 10-30)`.

## How a cycle works

1. Start ffmpeg and wait until YouTube reports the stream as `active`.
2. Create a broadcast and bind it to the stream key's stream.
3. Transition it `testing` → `live`.
4. If `PLAYLIST_ID` is set, add the broadcast to that playlist.
5. After `DURATION` live, transition it to `complete`, stop ffmpeg, and repeat.

If ffmpeg crashes it's restarted within ~15s, and the broadcast stays live.
If something fails (camera offline, API error), the broadcast is cleaned up
and the cycle is retried after `RETRY_DELAY`. On Ctrl-C or SIGTERM the current
broadcast is ended. A broadcast left behind by a killed run is ended the next
time the script starts.

Between broadcasts there's a gap of roughly 20–60s while the new one goes live.

## Setup

1. Install the dependencies: `ffmpeg`, `jq` and [yutu](https://github.com/eat-pray-ai/yutu).

   ```sh
   curl -sSfL https://raw.githubusercontent.com/eat-pray-ai/yutu/main/scripts/install.sh | bash
   ```

2. In Google Cloud: create a project, enable **YouTube Data API v3**, and
   create an OAuth client of type **Desktop app**. Download it as
   `client_secret.json` into this folder.
3. Authenticate once (opens a browser) to create `youtube.token.json`:

   ```sh
   cd /path/to/yt-livestream
   yutu auth --credential client_secret.json
   ```

   Do this on a machine with a browser if the server has none, then copy both
   JSON files over.

   **Multiple YouTube accounts:** create one token per account (sign in with
   that account when the browser opens), then set `TOKEN_FILE` in each
   camera's config:

   ```sh
   yutu auth --credential client_secret.json --cacheToken tokens/home.token.json
   yutu auth --credential client_secret.json --cacheToken tokens/shop.token.json
   ```

   ```sh
   TOKEN_FILE="tokens/shop.token.json"   # in streams/<camera>.conf
   ```

   Configs without `TOKEN_FILE` use `youtube.token.json`. One OAuth client
   (`client_secret.json`) works for all accounts. If its consent screen is in
   "Testing" mode, add each account as a test user.
4. Create one config per camera:

   ```sh
   cp streams/cctv.conf.example streams/cctv.conf
   chmod 600 streams/*.conf
   ```

   Each camera needs its **own stream key**. Create extra keys in YouTube
   Studio → Go live → Stream → "Create new stream key".

## Running

```sh
./livestream.sh streams/cctv.conf
```

For two or more cameras, run one instance per config, e.g. with systemd
(see `livestream@.service`):

```sh
sudo systemctl enable --now livestream@cctv livestream@garage
```

Or without systemd:

```sh
for c in streams/*.conf; do nohup ./livestream.sh "$c" >>"logs/$(basename "$c" .conf).log" 2>&1 & done
```

Logs: the script logs to stderr; ffmpeg output goes to `logs/<id>.ffmpeg.log`.

## API quota

The YouTube Data API allows 10,000 units/day by default. Each broadcast costs
about 270 units (create, bind, 3 transitions, status checks), plus 50 per
playlist, so many cameras fit comfortably. While a camera is unreachable, no API calls are made.
