import io
import json
import os
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import server

if server.PIL_AVAILABLE:
    from PIL import Image


class WallServerTests(unittest.TestCase):
    def test_web_chrome_is_borderless_and_video_has_no_delete_control(self):
        public = Path(__file__).resolve().parents[1] / "public"
        html = (public / "index.html").read_text()
        css = (public / "app.css").read_text()
        script = (public / "app.js").read_text()
        self.assertNotIn('id="delete-current"', html)
        self.assertNotIn("deleteCurrent", script)
        self.assertIn("padding: 32px 32px 18px;", css)
        self.assertNotIn("header { display: flex; align-items: baseline; justify-content: space-between; gap: 24px; padding: 32px 32px 18px; border-bottom", css)
        self.assertIn("button.active { font-weight: 700; }", css)
        self.assertIn('id="spotify-connect" href="/api/spotify/login"', html)
        self.assertIn('id="soundcloud-connect" href="/api/soundcloud/login"', html)
        self.assertIn('id="soundcloud-settings-form"', html)

    def test_navigation_keeps_video_first_and_canvas_views_last(self):
        public = Path(__file__).resolve().parents[1] / "public"
        html = (public / "index.html").read_text()
        script = (public / "app.js").read_text()
        order = [
            html.index('id="video"'),
            html.index('id="gallery"'),
            html.index('id="icons"'),
            html.index('id="goons"'),
            html.index('id="wall"'),
            html.index('id="booth"'),
        ]
        self.assertEqual(order, sorted(order))
        self.assertIn('id="video" class="active"', html)
        self.assertIn("setView('video');", script)
        self.assertIn("messageHandlers?.wallPhotoEdit", script)
        self.assertIn("event.preventDefault();", script)

    def test_password_hash_round_trip(self):
        stored = server.password_hash("correct horse")
        self.assertTrue(server.password_valid("correct horse", stored))
        self.assertFalse(server.password_valid("wrong", stored))

    def test_token_hash_is_stable_without_storing_token(self):
        self.assertEqual(server.token_hash("device-token"), server.token_hash("device-token"))
        self.assertNotIn("device-token", server.token_hash("device-token"))

    def test_atomic_json(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "state.json"
            server.atomic_json(path, [{"ok": True}])
            self.assertEqual(server.read_json(path, []), [{"ok": True}])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_sonos_command_queue_is_bounded_and_strict(self):
        with tempfile.TemporaryDirectory() as directory:
            old_path = server.SONOS_COMMANDS
            try:
                server.SONOS_COMMANDS = Path(directory) / "sonos-commands.json"
                command = server.enqueue_sonos_command({"action": "volume", "value": 42})
                self.assertEqual(server.pending_sonos_commands()[0]["value"], 42)
                self.assertTrue(server.complete_sonos_command(command["id"], True, "done"))
                self.assertEqual(server.pending_sonos_commands(), [])
                server.enqueue_sonos_command(
                    {"action": "next"}, now=datetime(2026, 9, 14, 12, tzinfo=timezone.utc)
                )
                self.assertEqual(
                    server.pending_sonos_commands(now=datetime(2026, 9, 14, 12, 3, tzinfo=timezone.utc)),
                    [],
                )
                with self.assertRaises(ValueError):
                    server.validate_sonos_command({"action": "volume", "value": 101})
                with self.assertRaises(ValueError):
                    server.validate_sonos_command({"action": "launch_url", "value": "http://lan"})
            finally:
                server.SONOS_COMMANDS = old_path

    def test_sonos_radio_command_only_accepts_canonical_track(self):
        command = server.validate_sonos_command({
            "action": "spotify_radio",
            "reference": "spotify:track:59BNro4EvYBdUzW8SKvvl8",
            "title": "Is There Really No Happiness? by Porter Robinson",
        })
        self.assertEqual(command["action"], "spotify_radio")
        with self.assertRaises(ValueError):
            server.validate_sonos_command({"action": "spotify_radio", "reference": "https://example.com", "title": "bad"})
        soundcloud = server.validate_sonos_command({
            "action": "soundcloud_play",
            "reference": "soundcloud:tracks:123456789",
            "title": "Track by Artist",
        })
        self.assertEqual(soundcloud["action"], "soundcloud_play")
        with self.assertRaises(ValueError):
            server.validate_sonos_command({"action": "soundcloud_play", "reference": "https://evil.test", "title": "bad"})

    def test_sonos_state_is_sanitized(self):
        state = server.sanitize_sonos_state({
            "title": "Track", "artist": "Artist", "album": "Album", "speaker": "Living Room",
            "isPlaying": True, "isShuffleEnabled": False, "volume": 63,
        })
        self.assertEqual(state["volume"], 63)
        self.assertIn("updated_at", state)

    def test_spotify_browser_authorization_state_is_private_and_single_use(self):
        with tempfile.TemporaryDirectory() as directory:
            old_values = server.SPOTIFY_CREDENTIALS, server.SPOTIFY_OAUTH_STATES
            old_origin = os.environ.get("WALL_ORIGIN")
            try:
                root = Path(directory)
                server.SPOTIFY_CREDENTIALS = root / "spotify-credentials.json"
                server.SPOTIFY_OAUTH_STATES = root / "spotify-oauth-states.json"
                server.atomic_json(server.SPOTIFY_CREDENTIALS, {
                    "client_id": "a" * 32,
                    "client_secret": "b" * 32,
                })
                os.environ["WALL_ORIGIN"] = "https://wall.example.invalid"
                url = server.spotify_authorization_url(now=1000)
                self.assertTrue(url.startswith("https://accounts.spotify.com/authorize?"))
                self.assertIn("redirect_uri=https%3A%2F%2Fwall.example.invalid%2Fapi%2Fspotify%2Fcallback", url)
                state = url.split("state=", 1)[1].split("&", 1)[0]
                stored = server.read_json(server.SPOTIFY_OAUTH_STATES, [])
                self.assertNotIn(state, json.dumps(stored))
                self.assertEqual(server.SPOTIFY_OAUTH_STATES.stat().st_mode & 0o777, 0o600)
                self.assertTrue(server.spotify_consume_oauth_state(state, now=1001))
                self.assertFalse(server.spotify_consume_oauth_state(state, now=1002))
            finally:
                server.SPOTIFY_CREDENTIALS, server.SPOTIFY_OAUTH_STATES = old_values
                if old_origin is None:
                    os.environ.pop("WALL_ORIGIN", None)
                else:
                    os.environ["WALL_ORIGIN"] = old_origin

    def test_spotify_browser_exchange_stores_refresh_token_privately(self):
        class Response:
            def __init__(self, value):
                self.value = value
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self, _maximum):
                return json.dumps(self.value).encode()

        calls = []
        def opener(request, timeout):
            calls.append((request, timeout))
            if request.full_url.endswith("/api/token"):
                return Response({
                    "access_token": "access",
                    "refresh_token": "refresh",
                    "expires_in": 3600,
                    "scope": server.SPOTIFY_SCOPE,
                })
            return Response({"id": "spotify-user", "display_name": "Alex"})

        with tempfile.TemporaryDirectory() as directory:
            old_values = server.SPOTIFY_CREDENTIALS, server.SPOTIFY_ACCOUNT
            old_origin = os.environ.get("WALL_ORIGIN")
            try:
                root = Path(directory)
                server.SPOTIFY_CREDENTIALS = root / "spotify-credentials.json"
                server.SPOTIFY_ACCOUNT = root / "spotify-account.json"
                server.atomic_json(server.SPOTIFY_CREDENTIALS, {
                    "client_id": "a" * 32,
                    "client_secret": "b" * 32,
                })
                os.environ["WALL_ORIGIN"] = "https://wall.example.invalid"
                account = server.spotify_exchange_authorization_code("authorization-code", opener=opener, now=1000)
                self.assertEqual(account["display_name"], "Alex")
                self.assertEqual(server.spotify_account_status(), {"connected": True, "display_name": "Alex"})
                self.assertEqual(server.SPOTIFY_ACCOUNT.stat().st_mode & 0o777, 0o600)
                self.assertEqual(len(calls), 2)
            finally:
                server.SPOTIFY_CREDENTIALS, server.SPOTIFY_ACCOUNT = old_values
                if old_origin is None:
                    os.environ.pop("WALL_ORIGIN", None)
                else:
                    os.environ["WALL_ORIGIN"] = old_origin

    def test_spotify_cloud_playlists_are_sanitized_for_the_ipad(self):
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self, _maximum):
                return json.dumps({
                    "items": [{
                        "id": "P" * 22,
                        "name": "z newest",
                        "owner": {"display_name": "Alex"},
                        "images": [{"url": "https://i.scdn.co/image/cover"}],
                        "items": {"total": 12},
                    }, {
                        "id": "Q" * 22,
                        "name": "a older",
                        "owner": {"display_name": "Alex"},
                        "images": [],
                        "items": {"total": 3},
                    }],
                    "next": None,
                }).encode()

        with tempfile.TemporaryDirectory() as directory:
            old_account = server.SPOTIFY_ACCOUNT
            try:
                server.SPOTIFY_ACCOUNT = Path(directory) / "spotify-account.json"
                server.atomic_json(server.SPOTIFY_ACCOUNT, {
                    "access_token": "private-access-token",
                    "refresh_token": "private-refresh-token",
                    "expires_at": 9_999_999_999,
                })
                rows = server.spotify_account_playlists(opener=lambda request, timeout: Response())
                self.assertEqual([row["name"] for row in rows], ["z newest", "a older"])
                self.assertEqual(rows[0]["trackCount"], 12)
                self.assertNotIn("private-access-token", json.dumps(rows))
                self.assertNotIn("private-refresh-token", json.dumps(rows))
            finally:
                server.SPOTIFY_ACCOUNT = old_account

    def test_soundcloud_pkce_state_is_private_and_single_use(self):
        with tempfile.TemporaryDirectory() as directory:
            old_values = server.SOUNDCLOUD_CREDENTIALS, server.SOUNDCLOUD_OAUTH_STATES
            old_origin = os.environ.get("WALL_ORIGIN")
            try:
                root = Path(directory)
                server.SOUNDCLOUD_CREDENTIALS = root / "soundcloud-credentials.json"
                server.SOUNDCLOUD_OAUTH_STATES = root / "soundcloud-oauth-states.json"
                server.atomic_json(server.SOUNDCLOUD_CREDENTIALS, {
                    "client_id": "soundcloud-client-id",
                    "client_secret": "soundcloud-client-secret",
                })
                os.environ["WALL_ORIGIN"] = "https://wall.example.invalid"
                url = server.soundcloud_authorization_url(now=1000)
                self.assertTrue(url.startswith("https://secure.soundcloud.com/authorize?"))
                self.assertIn("code_challenge_method=S256", url)
                self.assertIn("redirect_uri=https%3A%2F%2Fwall.example.invalid%2Fapi%2Fsoundcloud%2Fcallback", url)
                state = url.split("state=", 1)[1].split("&", 1)[0]
                stored = server.read_json(server.SOUNDCLOUD_OAUTH_STATES, [])
                self.assertNotIn(state, json.dumps(stored))
                verifier = server.soundcloud_consume_oauth_state(state, now=1001)
                self.assertIsInstance(verifier, str)
                self.assertGreater(len(verifier), 40)
                self.assertIsNone(server.soundcloud_consume_oauth_state(state, now=1002))
            finally:
                server.SOUNDCLOUD_CREDENTIALS, server.SOUNDCLOUD_OAUTH_STATES = old_values
                if old_origin is None:
                    os.environ.pop("WALL_ORIGIN", None)
                else:
                    os.environ["WALL_ORIGIN"] = old_origin

    def test_soundcloud_account_search_is_normalized_without_tokens(self):
        class Response:
            def __enter__(self):
                return self
            def __exit__(self, *args):
                return False
            def read(self, _maximum):
                return json.dumps({"collection": [{
                    "urn": "soundcloud:tracks:123",
                    "title": "Exact track",
                    "access": "playable",
                    "streamable": True,
                    "artwork_url": "https://i1.sndcdn.com/artworks-test-large.jpg",
                    "permalink_url": "https://soundcloud.com/artist/exact-track",
                    "user": {"username": "Artist"},
                }, {
                    "urn": "soundcloud:tracks:456",
                    "title": "Blocked track",
                    "access": "blocked",
                    "user": {"username": "Artist"},
                }]}).encode()

        with tempfile.TemporaryDirectory() as directory:
            old_account = server.SOUNDCLOUD_ACCOUNT
            try:
                server.SOUNDCLOUD_ACCOUNT = Path(directory) / "soundcloud-account.json"
                server.atomic_json(server.SOUNDCLOUD_ACCOUNT, {
                    "access_token": "private-access-token",
                    "refresh_token": "private-refresh-token",
                    "expires_at": 9_999_999_999,
                })
                rows = server.soundcloud_search_tracks("exact", opener=lambda request, timeout: Response())
                self.assertEqual(len(rows), 1)
                self.assertEqual(rows[0]["artist"], "Artist")
                self.assertEqual(rows[0]["id"], "soundcloud:tracks:123")
                self.assertNotIn("private-access-token", json.dumps(rows))
            finally:
                server.SOUNDCLOUD_ACCOUNT = old_account

    @unittest.skipUnless(server.PIL_AVAILABLE, "Pillow is not installed locally")
    def test_black_jpeg_is_rejected_but_dark_detail_is_kept(self):
        def jpeg(values):
            image = Image.new("L", (16, 16))
            image.putdata(values)
            output = io.BytesIO()
            image.save(output, format="JPEG", quality=92)
            return output.getvalue()

        self.assertFalse(server.jpeg_is_usable(jpeg([0] * 256)))
        detailed = [6] * 256
        detailed[120:136] = [180] * 16
        self.assertTrue(server.jpeg_is_usable(jpeg(detailed)))

    def test_photo_delete_moves_file_to_private_trash(self):
        with tempfile.TemporaryDirectory() as directory:
            old_photos, old_trash = server.PHOTOS, server.TRASH
            try:
                root = Path(directory)
                server.PHOTOS = root / "photos"
                server.TRASH = root / "Trash"
                server.PHOTOS.mkdir()
                name = "fit-20260823T120000Z-test.jpg"
                (server.PHOTOS / name).write_bytes(b"photo")
                destination = server.move_photo_to_trash(
                    name,
                    now=datetime(2026, 8, 23, 12, tzinfo=timezone.utc),
                )
                self.assertIsNotNone(destination)
                self.assertFalse((server.PHOTOS / name).exists())
                self.assertTrue(destination.is_file())
                self.assertIn(name, destination.name)
                self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
            finally:
                server.PHOTOS, server.TRASH = old_photos, old_trash

    def test_photo_name_rejects_traversal(self):
        self.assertTrue(server.valid_photo_name("fit-20260823T120000Z-safe.jpg"))
        self.assertFalse(server.valid_photo_name("../fit-evil.jpg"))
        self.assertFalse(server.valid_photo_name("fit-evil.jpg/other"))

    def test_photo_booth_metadata_requires_valid_night(self):
        self.assertEqual(
            server.capture_metadata("photo_booth", "2026-08-28"),
            {"source": "photo_booth", "photo_booth_night": "2026-08-28", "hidden": False},
        )
        self.assertIsNone(server.capture_metadata("photo_booth", "tonight")["photo_booth_night"])
        self.assertIsNone(server.capture_metadata("automatic", "2026-08-28")["photo_booth_night"])

    def test_photo_visibility_persists_without_deleting_file(self):
        with tempfile.TemporaryDirectory() as directory:
            old_photos, old_metadata = server.PHOTOS, server.PHOTO_METADATA
            try:
                root = Path(directory)
                server.PHOTOS = root / "photos"
                server.PHOTO_METADATA = root / "photo-metadata.json"
                server.PHOTOS.mkdir()
                name = "fit-20260828T120000Z-visible.jpg"
                (server.PHOTOS / name).write_bytes(b"photo")
                self.assertTrue(server.set_photo_hidden(name, True))
                self.assertTrue((server.PHOTOS / name).is_file())
                self.assertTrue(server.read_json(server.PHOTO_METADATA, {})[name]["hidden"])
                self.assertTrue(server.set_photo_hidden(name, False))
                self.assertFalse(server.read_json(server.PHOTO_METADATA, {})[name]["hidden"])
            finally:
                server.PHOTOS, server.PHOTO_METADATA = old_photos, old_metadata

    def test_booth_delete_scope_requires_matching_source_and_night(self):
        with tempfile.TemporaryDirectory() as directory:
            old_photos, old_metadata = server.PHOTOS, server.PHOTO_METADATA
            try:
                root = Path(directory)
                server.PHOTOS = root / "photos"
                server.PHOTO_METADATA = root / "photo-metadata.json"
                server.PHOTOS.mkdir()
                booth = "fit-20260828T230000Z-booth.jpg"
                manual = "fit-20260828T230100Z-manual.jpg"
                (server.PHOTOS / booth).write_bytes(b"photo")
                (server.PHOTOS / manual).write_bytes(b"photo")
                server.atomic_json(server.PHOTO_METADATA, {
                    booth: server.capture_metadata("photo_booth", "2026-08-28"),
                    manual: server.capture_metadata("manual"),
                })
                self.assertTrue(server.photo_is_in_booth_night(booth, "2026-08-28"))
                self.assertFalse(server.photo_is_in_booth_night(booth, "2026-08-29"))
                self.assertFalse(server.photo_is_in_booth_night(manual, "2026-08-28"))
                self.assertFalse(server.photo_is_in_booth_night("../fit-evil.jpg", "2026-08-28"))
            finally:
                server.PHOTOS, server.PHOTO_METADATA = old_photos, old_metadata

    def test_photo_booth_guest_is_scoped_to_a_real_booth_photo(self):
        with tempfile.TemporaryDirectory() as directory:
            old_photos = server.PHOTOS
            old_metadata = server.PHOTO_METADATA
            old_guests = server.PHOTO_BOOTH_GUESTS
            try:
                root = Path(directory)
                server.PHOTOS = root / "photos"
                server.PHOTO_METADATA = root / "photo-metadata.json"
                server.PHOTO_BOOTH_GUESTS = root / "photo-booth-guests.json"
                server.PHOTOS.mkdir()
                name = "fit-20260828T230000Z-booth.jpg"
                (server.PHOTOS / name).write_bytes(b"photo")
                server.atomic_json(server.PHOTO_METADATA, {
                    name: server.capture_metadata("photo_booth", "2026-08-28")
                })
                now = datetime(2026, 8, 28, 23, 1, tzinfo=timezone.utc)
                self.assertTrue(server.record_photo_booth_guest("Guest@Example.com", name, "2026-08-28", now=now))
                self.assertTrue(server.record_photo_booth_guest("guest@example.com", name, "2026-08-28", now=now))
                guests = server.read_json(server.PHOTO_BOOTH_GUESTS, [])
                self.assertEqual(len(guests), 1)
                self.assertEqual(guests[0]["email"], "guest@example.com")
                self.assertFalse(server.record_photo_booth_guest("not-an-email", name, "2026-08-28"))
                self.assertFalse(server.record_photo_booth_guest("guest@example.com", name, "2026-08-29"))
                self.assertEqual(server.PHOTO_BOOTH_GUESTS.stat().st_mode & 0o777, 0o600)
            finally:
                server.PHOTOS = old_photos
                server.PHOTO_METADATA = old_metadata
                server.PHOTO_BOOTH_GUESTS = old_guests

    def test_goon_event_is_durable_and_duplicate_safe(self):
        with tempfile.TemporaryDirectory() as directory:
            old_events = server.GOON_EVENTS
            try:
                server.GOON_EVENTS = Path(directory) / "goon-events.json"
                event = {
                    "id": "1f81fc83-b7bd-49ed-bcf7-eaa774177559",
                    "person": "casey",
                    "action": "add",
                    "occurred_at": "2026-08-24T14:20:00Z",
                }
                now = datetime(2026, 8, 24, 14, 21, tzinfo=timezone.utc)
                self.assertTrue(server.record_goon_event(event, now=now))
                self.assertFalse(server.record_goon_event(event, now=now))
                stored = server.read_json(server.GOON_EVENTS, [])
                self.assertEqual(len(stored), 1)
                self.assertEqual(stored[0]["person"], "casey")
                self.assertEqual(stored[0]["action"], "add")
                self.assertEqual(server.GOON_EVENTS.stat().st_mode & 0o777, 0o600)
            finally:
                server.GOON_EVENTS = old_events

    def test_goon_timestamp_requires_timezone_and_normalizes_utc(self):
        self.assertEqual(
            server.normalize_iso8601("2026-08-24T10:00:00-04:00"),
            "2026-08-24T14:00:00Z",
        )
        with self.assertRaises(ValueError):
            server.normalize_iso8601("2026-08-24T10:00:00")

    def test_dashboard_payload_scopes_weather_and_transit_to_l_and_m(self):
        old_cache = dict(server.DASHBOARD_CACHE)
        try:
            server.DASHBOARD_CACHE.update({"expires": 0.0, "value": None})
            def fetch(url):
                if url == server.WEATHER_URL:
                    return {
                        "current": {"time": "2026-09-03T14:00", "temperature_2m": 79.4, "weather_code": 2},
                        "hourly": {
                            "time": ["2026-09-03T13:00", "2026-09-03T14:00", "2026-09-03T15:00", "2026-09-03T16:00"],
                            "temperature_2m": [78.0, 79.4, 80.0, 81.2],
                            "precipitation_probability": [10, 20, 25, 40],
                            "weather_code": [1, 2, 2, 61],
                        },
                        "daily": {
                        "temperature_2m_max": [81.2], "temperature_2m_min": [63.4],
                        "precipitation_probability_max": [40], "rain_sum": [0.02],
                    }}
                return {"entity": [{"id": "alert-1", "alert": {
                    "active_period": [],
                    "informed_entity": [{"route_id": "L"}, {"route_id": "A"}],
                    "header_text": {"translation": [{"language": "en", "text": "[L] delayed"}]},
                }}]}
            payload = server.dashboard_payload(fetch=fetch, now=1_800_000_000)
            self.assertTrue(payload["weather"]["expectsRain"])
            self.assertEqual(payload["weather"]["currentTemperature"], 79.4)
            self.assertEqual(payload["weather"]["status"], "partly cloudy")
            self.assertEqual([period["time"] for period in payload["weather"]["periods"]], [
                "2026-09-03T14:00", "2026-09-03T16:00",
            ])
            self.assertEqual(payload["transit"][0]["routes"], ["L"])
            self.assertEqual(payload["transit"][0]["headline"], "L delayed")
        finally:
            server.DASHBOARD_CACHE.clear()
            server.DASHBOARD_CACHE.update(old_cache)

    def test_horoscope_payload_maps_the_five_wall_names(self):
        old_cache = dict(server.HOROSCOPE_CACHE)
        try:
            server.HOROSCOPE_CACHE.update({"day": "", "value": None})
            payload = server.horoscope_payload(
                fetch=lambda url: {"data": {"date": "2026-08-30", "horoscope": "  keep  moving  "}},
                today="2026-08-29",
            )
            self.assertEqual(set(payload["readings"]), {"alex", "blake", "casey", "drew", "ellis"})
            self.assertTrue(all(value == "keep moving" for value in payload["readings"].values()))
        finally:
            server.HOROSCOPE_CACHE.clear()
            server.HOROSCOPE_CACHE.update(old_cache)

    def test_horoscope_payload_does_not_cache_a_failed_daily_fetch(self):
        old_cache = dict(server.HOROSCOPE_CACHE)
        calls = []
        try:
            server.HOROSCOPE_CACHE.update({"day": "", "value": None})

            def unavailable(url):
                calls.append(url)
                return {"data": {}}

            first = server.horoscope_payload(fetch=unavailable, today="2026-09-02")
            second = server.horoscope_payload(fetch=unavailable, today="2026-09-02")

            self.assertEqual(len(calls), 10)
            self.assertEqual(first, second)
            self.assertIsNone(server.HOROSCOPE_CACHE["value"])
        finally:
            server.HOROSCOPE_CACHE.clear()
            server.HOROSCOPE_CACHE.update(old_cache)

    def test_horoscope_payload_rejects_stale_provider_dates(self):
        old_cache = dict(server.HOROSCOPE_CACHE)
        try:
            server.HOROSCOPE_CACHE.update({"day": "", "value": None})
            payload = server.horoscope_payload(
                fetch=lambda url: {"data": {"date": "2026-09-02", "horoscope": "stale words"}},
                today="2026-09-03",
            )
            self.assertTrue(all(value == "The sky is checking its notes." for value in payload["readings"].values()))
            self.assertIsNone(server.HOROSCOPE_CACHE["value"])
        finally:
            server.HOROSCOPE_CACHE.clear()
            server.HOROSCOPE_CACHE.update(old_cache)

    def test_canvas_validation_accepts_normalized_gifs_and_rejects_bad_assets(self):
        state = {
            "schema": 1,
            "wall": {"gifs": [{
                "id": "70000000-0000-0000-0000-000000000001",
                "asset": "a" * 64,
                "normalizedX": 0.25,
                "normalizedY": 0.5,
                "scale": 1.0,
                "rotationDegrees": 0.0,
            }]},
            "photoBooth": {"gifs": []},
        }
        self.assertIs(server.validate_canvas_state(state), state)
        state["wall"]["gifs"][0]["asset"] = "../secret"
        with self.assertRaises(ValueError):
            server.validate_canvas_state(state)

    def test_photo_edit_validation_is_scoped_to_hashed_photo_name(self):
        name = "fit-20260910T120000Z-photo.jpg"
        identifier = server.token_hash(name)
        record = {
            "id": identifier,
            "photoName": name,
            "drawings": [],
            "gifs": [],
            "layers": [],
        }
        self.assertEqual(server.validate_photo_edit(record, identifier), record)
        with self.assertRaises(ValueError):
            server.validate_photo_edit({**record, "photoName": "../fit-bad.jpg"}, identifier)
        with self.assertRaises(ValueError):
            server.validate_photo_edit({**record, "id": "0" * 64}, identifier)

    def test_canvas_save_uses_optimistic_revision_and_keeps_history(self):
        with tempfile.TemporaryDirectory() as directory:
            old_canvas = server.CANVAS
            old_history = server.CANVAS_HISTORY
            old_trash = server.TRASH
            try:
                root = Path(directory)
                server.CANVAS = root / "canvas.json"
                server.CANVAS_HISTORY = root / "history"
                server.TRASH = root / "Trash"
                state = {"schema": 1, "wall": {"gifs": []}, "photoBooth": {"gifs": []}}
                first, conflict = server.save_canvas(state, 0)
                self.assertIsNone(conflict)
                self.assertEqual(first["revision"], 1)
                stale, conflict = server.save_canvas(state, 0)
                self.assertIsNone(stale)
                self.assertEqual(conflict["revision"], 1)
                second, conflict = server.save_canvas(state, 1)
                self.assertIsNone(conflict)
                self.assertEqual(second["revision"], 2)
                self.assertEqual(len(list(server.CANVAS_HISTORY.glob("canvas-*.json"))), 1)
                self.assertEqual(server.CANVAS.stat().st_mode & 0o777, 0o600)
            finally:
                server.CANVAS = old_canvas
                server.CANVAS_HISTORY = old_history
                server.TRASH = old_trash

    def test_daily_device_snapshot_is_recoverable_and_updates_cloud_canvas(self):
        with tempfile.TemporaryDirectory() as directory:
            old_values = (server.CANVAS, server.CANVAS_HISTORY, server.DEVICE_CANVAS_SNAPSHOTS, server.TRASH)
            try:
                root = Path(directory)
                server.CANVAS = root / "canvas.json"
                server.CANVAS_HISTORY = root / "history"
                server.DEVICE_CANVAS_SNAPSHOTS = root / "device-snapshots"
                server.TRASH = root / "Trash"
                state = {"schema": 1, "wall": {"gifs": [], "widgets": []}, "photoBooth": {"gifs": []}}
                document, snapshot = server.save_device_canvas_snapshot(
                    state,
                    now=datetime(2026, 8, 29, 20, tzinfo=timezone.utc),
                )
                self.assertEqual(document["revision"], 1)
                self.assertTrue(snapshot.is_file())
                self.assertEqual(server.canvas_document()["state"], state)
                self.assertEqual(snapshot.stat().st_mode & 0o777, 0o600)
            finally:
                server.CANVAS, server.CANVAS_HISTORY, server.DEVICE_CANVAS_SNAPSHOTS, server.TRASH = old_values

    @unittest.skipUnless(server.PIL_AVAILABLE, "Pillow is not installed locally")
    def test_canvas_gif_validation_rejects_non_gif(self):
        self.assertFalse(server.gif_is_valid(b"not a gif"))
        output = io.BytesIO()
        Image.new("RGB", (4, 3), "white").save(output, format="GIF")
        self.assertTrue(server.gif_is_valid(output.getvalue()))


if __name__ == "__main__":
    unittest.main()
