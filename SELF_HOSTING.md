# Self-hosting the Wall server

Use a Linux/macOS host with Python 3.10+ and a writable private data directory. The server uses Python's standard library and Pillow for JPEG validation. requirements.txt pins Pillow; the image checks must not be skipped on a deployed photo server. Linux needs a working timezone database (the default display is New York).

From don-workspace on your own host:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python -m unittest discover -s tests -v
```

Set these privately in your service manager or hosting environment:

| Variable | Meaning |
|---|---|
| WALL_DATA_DIR | Absolute writable directory outside the checkout, such as /var/lib/wall |
| WALL_ORIGIN | Your HTTPS origin, without a trailing path; e.g. https://wall.example.org |
| WALL_PASSWORD_HASH | Hash of your own browser password using server.password_hash |
| WALL_SESSION_SECRET | Your own random session-signing secret, at least 32 characters |
| PORT | Loopback listener port, default 4422 |

config.env.example has blank authentication fields and an invalid example domain; it intentionally fails startup. It is not a functioning credential file. The server does not load it automatically. Fill your private copy outside the checkout and load it through EnvironmentFile/systemd or your platform's environment configuration. Keep the private file readable only by the required service user. Do not use shell tracing with credentials.

To create a password hash on your own host without putting the password into shell history:

```sh
.venv/bin/python -c 'from getpass import getpass; from server import password_hash; print(password_hash(getpass("New Wall password: ")))'
```

Store that output and a freshly generated session secret in your private service configuration. This distribution contains neither. Run .venv/bin/python server.py after supplying the required environment. The listener binds to 127.0.0.1 and requires HTTPS in front of it: browser login cookies are Secure, so plain HTTP browser login will not work.

The systemd example assumes source at /opt/wall, a dedicated unprivileged wall user, environment at /etc/wall/config.env, and writable state at /var/lib/wall. Create and grant ownership to those directories on your own host; do not run the service as root. Adapt the paths if needed. The Supervisor snippet is an alternative. Neither example is installed or enabled by this export. The portable run-don-wall.sh wrapper also expects its environment to be supplied beforehand.

Use Caddyfile.snippet as the site's HTTPS reverse proxy, replacing the invalid hostname and matching PORT. The X-Wall-Client-IP header must be replaced by the proxy with the real client IP; the backend should remain loopback-only. Check /healthz, visit /login, and log in through HTTPS. Fresh storage starts empty; backing it up later includes private photos, account grants, guest details, device registries and layout data. Keep those backups separate from Git.

## Enroll your iPad

Build the app with WallServerURL set to the same HTTPS origin. Launch it and allow its enrollment request. It creates a device token locally and submits a hash for approval. On the server, inspect your private pending-devices.json and identify the intended device. Pause the service while updating its registry to avoid concurrent writes, then run as the service user:

```sh
.venv/bin/python approve_device.py --data-dir /var/lib/wall --hash FULL_PENDING_DEVICE_SHA256
```

The helper approves only the selected existing pending hash; it does not approve every device or accept a raw token. Restart the server and retry/relaunch the app so enrollment observes approval. Never commit the registries. Follow with a real-device test of canvas sync, a photo upload, and browser gallery access.

## Optional services

- Spotify: register your own provider app and HTTPS callback WALL_ORIGIN/api/spotify/callback. Place your own client_id/client_secret JSON in the private data directory as spotify-credentials.json with mode 0600, then visit /api/spotify/login after browser login. The broker reads private/collaborative playlists and account metadata. Native PKCE login is optional and has separate iPad configuration. Provider app availability/scopes are subject to your account's approval.
- SoundCloud: register your own app and callback WALL_ORIGIN/api/soundcloud/callback, then configure its credentials using the authenticated browser settings and sign in. State remains in the private data directory.
- Sonos: the iPad must share the speaker LAN and have Local Network permission. The app discovers speakers or uses its saved host; there is no home-IP fallback. Some controls still prefer a room named Living Room. Adapt the room selection in source for your installation. Playback identity is discovered from the speaker; optional fallback IDs belong to your own account.
- Sift: set WallSiftServerURL before building and connect your own compatible account in app settings. A Sift service is not included in this repository. No embedded credential remains.
- Voice: leave disabled until you have your own OpenAI access. Development-only key injection is described in IPAD_SETUP.md. A short-lived token broker is needed before distributing voice-enabled app builds; it is not implemented here.
- Weather/transit/horoscopes use public endpoints and default NYC/fixed fictional-person settings. Customize locations, people and horoscope signs consistently in server.py, browser source and native widgets. External network calls remain unverified in this export.

The omitted audio effect can be replaced with your own licensed resource; its absence does not prevent building. The historical photo-booth website at wall-9-29.charlieyat.es is not included or assumed to be this server.
