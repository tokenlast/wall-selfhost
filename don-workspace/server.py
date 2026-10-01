#!/usr/bin/env python3
import base64
import hashlib
import hmac
import io
import json
import os
import secrets
import re
import threading
import time
import uuid
import math
from collections import defaultdict, deque
from datetime import date, datetime, timedelta, timezone
from http import cookies
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import parse_qs, quote, unquote, urlencode, urlparse
from urllib.request import Request, urlopen
from zoneinfo import ZoneInfo
from spotify_catalog import SpotifyCatalog, CatalogError

try:
    from PIL import Image, ImageStat, UnidentifiedImageError
    PIL_AVAILABLE = True
except ImportError:
    Image = ImageStat = None
    UnidentifiedImageError = OSError
    PIL_AVAILABLE = False

SOURCE = Path(__file__).resolve().parent
PUBLIC = SOURCE / "public"
DATA = Path(os.environ.get("WALL_DATA_DIR", SOURCE / "data")).resolve()
PHOTOS = DATA / "photos"
TRASH = DATA / "Trash"
PENDING = DATA / "pending-devices.json"
APPROVED = DATA / "approved-devices.json"
SPOTIFY_CATALOG = SpotifyCatalog(lambda: json.loads((DATA / "spotify-credentials.json").read_text()))
SPOTIFY_CREDENTIALS = DATA / "spotify-credentials.json"
SPOTIFY_ACCOUNT = DATA / "spotify-account.json"
SPOTIFY_OAUTH_STATES = DATA / "spotify-oauth-states.json"
SOUNDCLOUD_CREDENTIALS = DATA / "soundcloud-credentials.json"
SOUNDCLOUD_ACCOUNT = DATA / "soundcloud-account.json"
SOUNDCLOUD_OAUTH_STATES = DATA / "soundcloud-oauth-states.json"
GOON_EVENTS = DATA / "goon-events.json"
PHOTO_METADATA = DATA / "photo-metadata.json"
PHOTO_BOOTH_GUESTS = DATA / "photo-booth-guests.json"
CANVAS = DATA / "canvas.json"
CANVAS_ASSETS = DATA / "canvas-assets"
CANVAS_HISTORY = DATA / "canvas-history"
DEVICE_CANVAS_SNAPSHOTS = DATA / "device-canvas-snapshots"
PHOTO_EDITS = DATA / "photo-edits"
SONOS_COMMANDS = DATA / "sonos-commands.json"
SONOS_STATE = DATA / "sonos-state.json"
MAX_PHOTO_BYTES = 12 * 1024 * 1024
MAX_GIF_BYTES = 15 * 1024 * 1024
MAX_CANVAS_BYTES = 2 * 1024 * 1024
MAX_PHOTO_EDIT_BYTES = 2 * 1024 * 1024
MAX_CANVAS_ASSETS = 300
MAX_CANVAS_ASSET_BYTES = 512 * 1024 * 1024
MAX_CANVAS_HISTORY = 100
MAX_GOON_EVENTS = 10_000
MAX_PHOTO_BOOTH_GUESTS = 10_000
PBKDF2_ROUNDS = 310_000
LOGIN_ATTEMPTS = defaultdict(deque)
GOON_ATTEMPTS = defaultdict(deque)
CANVAS_ATTEMPTS = defaultdict(deque)
GOON_LOCK = threading.Lock()
PHOTO_LOCK = threading.Lock()
PHOTO_BOOTH_GUEST_LOCK = threading.Lock()
CANVAS_LOCK = threading.Lock()
SPOTIFY_OAUTH_LOCK = threading.Lock()
SOUNDCLOUD_OAUTH_LOCK = threading.Lock()
DASHBOARD_LOCK = threading.Lock()
SONOS_LOCK = threading.Lock()
GOON_PEOPLE = {"alex", "blake", "casey", "drew", "ellis"}
GOON_ACTIONS = {"add", "remove"}
CAPTURE_SOURCES = {"automatic", "manual", "photo_booth"}
NIGHT_PATTERN = re.compile(r"^20\d{2}-(0[1-9]|1[0-2])-([0-2]\d|3[01])$")
EMAIL_PATTERN = re.compile(r"^[^\s@]{1,64}@[^\s@]{1,189}\.[^\s@]{1,63}$")
ASSET_PATTERN = re.compile(r"^[a-f0-9]{64}$")
DASHBOARD_CACHE = {"expires": 0.0, "value": None}
HOROSCOPE_CACHE = {"day": "", "value": None}
WALL_TIME_ZONE = ZoneInfo("America/New_York")
WEATHER_URL = (
    "https://api.open-meteo.com/v1/forecast?latitude=40.7128&longitude=-74.0060"
    "&current=temperature_2m,weather_code"
    "&hourly=temperature_2m,precipitation_probability,weather_code"
    "&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max,rain_sum"
    "&temperature_unit=fahrenheit&precipitation_unit=inch&timezone=America%2FNew_York&forecast_days=2"
)
TRANSIT_URL = "https://api-endpoint.mta.info/Dataservice/mtagtfsfeeds/camsys%2Fsubway-alerts.json"
HOROSCOPE_URL = "https://freehoroscopeapi.com/api/v1/get-horoscope/daily?sign="
SPOTIFY_SCOPE = "playlist-read-private playlist-read-collaborative user-read-private"
STATIC = {
    "/": ("index.html", "text/html; charset=utf-8"),
    "/app.css": ("app.css", "text/css; charset=utf-8"),
    "/app.js": ("app.js", "application/javascript; charset=utf-8"),
}


def password_hash(password, salt=None):
    salt = salt or secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PBKDF2_ROUNDS)
    return "$".join((base64.urlsafe_b64encode(salt).decode(), str(PBKDF2_ROUNDS), base64.urlsafe_b64encode(digest).decode()))


def password_valid(password, stored):
    try:
        salt64, rounds, expected64 = stored.split("$")
        digest = hashlib.pbkdf2_hmac("sha256", password.encode(), base64.urlsafe_b64decode(salt64), int(rounds))
        return hmac.compare_digest(base64.urlsafe_b64encode(digest).decode(), expected64)
    except (ValueError, TypeError):
        return False


def token_hash(token):
    return hashlib.sha256(token.encode()).hexdigest()


def valid_photo_name(name):
    return (
        isinstance(name, str)
        and name.startswith("fit-")
        and name.endswith(".jpg")
        and "/" not in name
        and "\\" not in name
        and ".." not in name
    )


def jpeg_luma_metrics(body):
    if not PIL_AVAILABLE:
        raise RuntimeError("Pillow is required for JPEG validation")
    try:
        with Image.open(io.BytesIO(body)) as image:
            gray = image.convert("L")
            gray.thumbnail((64, 64))
            stat = ImageStat.Stat(gray)
            histogram = gray.histogram()
    except (OSError, UnidentifiedImageError, ValueError):
        raise ValueError("invalid jpeg")
    total = sum(histogram)
    if not total:
        raise ValueError("empty jpeg")
    return stat.mean[0], sum(histogram[:12]) / total, gray.getextrema()[1]


def jpeg_is_usable(body):
    mean, near_black, maximum = jpeg_luma_metrics(body)
    return not (mean < 2.5 and near_black > 0.995 and maximum < 40)


def csrf_token(secret, session_payload):
    return hmac.new(secret.encode(), f"csrf:{session_payload}".encode(), hashlib.sha256).hexdigest()


def move_photo_to_trash(name, now=None):
    if not valid_photo_name(name):
        return None
    source = PHOTOS / name
    if source.is_symlink() or not source.is_file() or source.resolve().parent != PHOTOS.resolve():
        return None
    destination_root = TRASH / "photos"
    destination_root.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = (now or datetime.now(timezone.utc)).strftime("%Y%m%dT%H%M%SZ")
    destination = destination_root / f"{stamp}-{uuid.uuid4().hex[:8]}-{name}"
    source.replace(destination)
    destination.chmod(0o600)
    with PHOTO_LOCK:
        metadata = read_json(PHOTO_METADATA, {})
        if isinstance(metadata, dict) and name in metadata:
            del metadata[name]
            atomic_json(PHOTO_METADATA, metadata)
    return destination


def capture_metadata(source, night=None):
    source = source if source in CAPTURE_SOURCES else "manual"
    if source != "photo_booth" or not isinstance(night, str) or not NIGHT_PATTERN.fullmatch(night):
        night = None
    return {"source": source, "photo_booth_night": night, "hidden": False}


def set_photo_hidden(name, hidden):
    if not valid_photo_name(name) or not (PHOTOS / name).is_file():
        return False
    with PHOTO_LOCK:
        metadata = read_json(PHOTO_METADATA, {})
        if not isinstance(metadata, dict):
            metadata = {}
        entry = metadata.get(name, capture_metadata("manual"))
        entry["hidden"] = bool(hidden)
        metadata[name] = entry
        atomic_json(PHOTO_METADATA, metadata)
    return True


def photo_is_in_booth_night(name, night):
    if not valid_photo_name(name) or not isinstance(night, str) or not NIGHT_PATTERN.fullmatch(night):
        return False
    with PHOTO_LOCK:
        metadata = read_json(PHOTO_METADATA, {})
    if not isinstance(metadata, dict):
        return False
    value = metadata.get(name, {})
    return (
        isinstance(value, dict)
        and value.get("source") == "photo_booth"
        and value.get("photo_booth_night") == night
        and (PHOTOS / name).is_file()
    )


def record_photo_booth_guest(email, photo_name, night, now=None):
    normalized_email = email.strip().lower() if isinstance(email, str) else ""
    if not EMAIL_PATTERN.fullmatch(normalized_email):
        return False
    if not photo_is_in_booth_night(photo_name, night):
        return False
    with PHOTO_BOOTH_GUEST_LOCK:
        guests = read_json(PHOTO_BOOTH_GUESTS, [])
        if not isinstance(guests, list):
            guests = []
        entry = {
            "email": normalized_email,
            "photo_name": photo_name,
            "night": night,
            "recorded_at": (now or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z"),
        }
        if not any(
            isinstance(item, dict)
            and item.get("email") == normalized_email
            and item.get("photo_name") == photo_name
            for item in guests
        ):
            guests.append(entry)
            atomic_json(PHOTO_BOOTH_GUESTS, guests[-MAX_PHOTO_BOOTH_GUESTS:])
        return True


def read_json(path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def atomic_json(path, value):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_name(f".{path.name}.{uuid.uuid4().hex}.tmp")
    temporary.write_text(json.dumps(value, separators=(",", ":")))
    temporary.chmod(0o600)
    temporary.replace(path)


SONOS_ACTIONS = {
    "previous", "play_pause", "next", "shuffle", "volume",
    "spotify_radio", "spotify_queue", "soundcloud_play", "soundcloud_queue",
}


def validate_sonos_command(value):
    if not isinstance(value, dict) or set(value) - {"action", "value", "reference", "title"}:
        raise ValueError("invalid Sonos command")
    action = value.get("action")
    if action not in SONOS_ACTIONS:
        raise ValueError("invalid Sonos action")
    command = {"action": action}
    if action == "volume":
        amount = value.get("value")
        if not isinstance(amount, int) or isinstance(amount, bool) or not 0 <= amount <= 100:
            raise ValueError("invalid Sonos volume")
        command["value"] = amount
    elif action in {"spotify_radio", "spotify_queue"}:
        reference = value.get("reference")
        title = value.get("title")
        if not isinstance(reference, str) or not re.fullmatch(r"spotify:track:[A-Za-z0-9]{22}", reference):
            raise ValueError("invalid Spotify track")
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 300:
            raise ValueError("invalid track title")
        command.update(reference=reference, title=title.strip())
    elif action in {"soundcloud_play", "soundcloud_queue"}:
        reference = value.get("reference")
        title = value.get("title")
        if not isinstance(reference, str) or not re.fullmatch(r"soundcloud:tracks:[0-9]+", reference):
            raise ValueError("invalid SoundCloud track")
        if not isinstance(title, str) or not 1 <= len(title.strip()) <= 300:
            raise ValueError("invalid track title")
        command.update(reference=reference, title=title.strip())
    return command


def sanitize_sonos_state(value):
    if not isinstance(value, dict):
        raise ValueError("invalid Sonos state")
    def text_value(name, maximum=300):
        item = value.get(name, "")
        if not isinstance(item, str):
            raise ValueError("invalid Sonos state")
        return item[:maximum]
    volume = value.get("volume", 0)
    if not isinstance(volume, int) or isinstance(volume, bool) or not 0 <= volume <= 100:
        raise ValueError("invalid Sonos state")
    if not isinstance(value.get("isPlaying", False), bool) or not isinstance(value.get("isShuffleEnabled", False), bool):
        raise ValueError("invalid Sonos state")
    return {
        "title": text_value("title"), "artist": text_value("artist"),
        "album": text_value("album"), "speaker": text_value("speaker", 100),
        "isPlaying": value.get("isPlaying", False),
        "isShuffleEnabled": value.get("isShuffleEnabled", False),
        "volume": volume,
        "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    }


def enqueue_sonos_command(value, now=None):
    command = validate_sonos_command(value)
    command.update({
        "id": uuid.uuid4().hex, "status": "pending",
        "created_at": (now or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z"),
    })
    with SONOS_LOCK:
        commands = read_json(SONOS_COMMANDS, [])
        if not isinstance(commands, list):
            commands = []
        commands.append(command)
        atomic_json(SONOS_COMMANDS, commands[-100:])
    return command


def pending_sonos_commands(now=None):
    now = now or datetime.now(timezone.utc)
    with SONOS_LOCK:
        commands = read_json(SONOS_COMMANDS, [])
        pending = []
        changed = False
        for item in commands:
            if not isinstance(item, dict) or item.get("status") != "pending":
                continue
            try:
                created = datetime.fromisoformat(item["created_at"].replace("Z", "+00:00"))
            except (KeyError, TypeError, ValueError):
                created = datetime.fromtimestamp(0, timezone.utc)
            if (now - created).total_seconds() > 120:
                item["status"] = "expired"
                changed = True
            elif len(pending) < 10:
                pending.append(item)
        if changed:
            atomic_json(SONOS_COMMANDS, commands[-100:])
        return pending


def complete_sonos_command(identifier, ok, message=""):
    if not re.fullmatch(r"[a-f0-9]{32}", identifier) or not isinstance(ok, bool):
        return False
    with SONOS_LOCK:
        commands = read_json(SONOS_COMMANDS, [])
        found = False
        for command in commands:
            if isinstance(command, dict) and command.get("id") == identifier:
                command["status"] = "complete" if ok else "failed"
                command["message"] = str(message)[:300]
                found = True
                break
        if found:
            atomic_json(SONOS_COMMANDS, commands[-100:])
        return found


class SpotifyOAuthError(Exception):
    pass


def spotify_client_config():
    value = read_json(SPOTIFY_CREDENTIALS, {})
    try:
        client_id = str(value["client_id"])
        client_secret = str(value["client_secret"])
    except (KeyError, TypeError):
        raise SpotifyOAuthError("Spotify is not configured") from None
    if not re.fullmatch(r"[A-Za-z0-9]{16,128}", client_id) or not 16 <= len(client_secret) <= 256:
        raise SpotifyOAuthError("Spotify is not configured")
    return client_id, client_secret


def spotify_redirect_uri():
    origin = os.environ.get("WALL_ORIGIN", "https://wall.example.invalid").rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
        raise SpotifyOAuthError("Wall origin is invalid")
    return origin + "/api/spotify/callback"


def spotify_authorization_url(now=None):
    client_id, _ = spotify_client_config()
    now = int(time.time() if now is None else now)
    state = secrets.token_urlsafe(32)
    with SPOTIFY_OAUTH_LOCK:
        states = read_json(SPOTIFY_OAUTH_STATES, [])
        if not isinstance(states, list):
            states = []
        states = [
            item for item in states
            if isinstance(item, dict)
            and isinstance(item.get("created_at"), int)
            and item["created_at"] >= now - 600
            and isinstance(item.get("state_hash"), str)
        ]
        states.append({"state_hash": token_hash(state), "created_at": now})
        atomic_json(SPOTIFY_OAUTH_STATES, states[-20:])
    return "https://accounts.spotify.com/authorize?" + urlencode({
        "client_id": client_id,
        "response_type": "code",
        "redirect_uri": spotify_redirect_uri(),
        "scope": SPOTIFY_SCOPE,
        "state": state,
        "show_dialog": "true",
    })


def spotify_consume_oauth_state(state, now=None):
    if not isinstance(state, str) or not 20 <= len(state) <= 200:
        return False
    now = int(time.time() if now is None else now)
    supplied_hash = token_hash(state)
    found = False
    with SPOTIFY_OAUTH_LOCK:
        states = read_json(SPOTIFY_OAUTH_STATES, [])
        kept = []
        if not isinstance(states, list):
            states = []
        for item in states:
            if not isinstance(item, dict) or not isinstance(item.get("created_at"), int):
                continue
            stored_hash = item.get("state_hash", "")
            if item["created_at"] < now - 600 or not isinstance(stored_hash, str):
                continue
            if not found and hmac.compare_digest(stored_hash, supplied_hash):
                found = True
                continue
            kept.append(item)
        atomic_json(SPOTIFY_OAUTH_STATES, kept[-20:])
    return found


def spotify_json_request(request, opener=urlopen):
    try:
        with opener(request, timeout=10) as response:
            body = response.read(1_048_577)
        if len(body) > 1_048_576:
            raise ValueError
        value = json.loads(body)
        if not isinstance(value, dict):
            raise ValueError
        return value
    except HTTPError as error:
        raise SpotifyOAuthError(f"Spotify request failed ({error.code})") from None
    except (URLError, TimeoutError, OSError, ValueError, TypeError, json.JSONDecodeError):
        raise SpotifyOAuthError("Spotify request failed") from None


def spotify_exchange_authorization_code(code, opener=urlopen, now=None):
    if not isinstance(code, str) or not 1 <= len(code) <= 4096:
        raise SpotifyOAuthError("Spotify returned an invalid code")
    client_id, client_secret = spotify_client_config()
    basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    request = Request(
        "https://accounts.spotify.com/api/token",
        data=urlencode({
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": spotify_redirect_uri(),
        }).encode(),
        headers={
            "Authorization": "Basic " + basic,
            "Content-Type": "application/x-www-form-urlencoded",
        },
    )
    token = spotify_json_request(request, opener=opener)
    access_token = token.get("access_token")
    refresh_token = token.get("refresh_token")
    if not isinstance(access_token, str) or not access_token or not isinstance(refresh_token, str) or not refresh_token:
        raise SpotifyOAuthError("Spotify returned an invalid account token")
    profile = {}
    try:
        profile = spotify_json_request(Request(
            "https://api.spotify.com/v1/me",
            headers={"Authorization": "Bearer " + access_token},
        ), opener=opener)
    except SpotifyOAuthError:
        pass
    now = int(time.time() if now is None else now)
    expires_in = token.get("expires_in", 3600)
    if not isinstance(expires_in, int) or isinstance(expires_in, bool):
        expires_in = 3600
    account = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "token_type": "Bearer",
        "scope": str(token.get("scope", "")),
        "expires_at": now + max(60, min(expires_in, 86400)),
        "connected_at": datetime.fromtimestamp(now, timezone.utc).isoformat().replace("+00:00", "Z"),
        "spotify_user_id": str(profile.get("id", ""))[:200],
        "display_name": str(profile.get("display_name", ""))[:200],
    }
    atomic_json(SPOTIFY_ACCOUNT, account)
    return account


def spotify_account_status():
    account = read_json(SPOTIFY_ACCOUNT, {})
    connected = isinstance(account, dict) and isinstance(account.get("refresh_token"), str) and bool(account["refresh_token"])
    return {
        "connected": connected,
        "display_name": str(account.get("display_name", ""))[:200] if connected else "",
    }


def spotify_account_access_token(opener=urlopen, now=None):
    now = int(time.time() if now is None else now)
    with SPOTIFY_OAUTH_LOCK:
        account = read_json(SPOTIFY_ACCOUNT, {})
        if not isinstance(account, dict):
            raise SpotifyOAuthError("Spotify is not connected")
        access_token = account.get("access_token")
        expires_at = account.get("expires_at", 0)
        if (
            isinstance(access_token, str) and access_token
            and isinstance(expires_at, int) and not isinstance(expires_at, bool)
            and expires_at > now + 60
        ):
            return access_token
        refresh_token = account.get("refresh_token")
        if not isinstance(refresh_token, str) or not refresh_token:
            raise SpotifyOAuthError("Spotify is not connected")
        client_id, client_secret = spotify_client_config()
        basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
        refreshed = spotify_json_request(Request(
            "https://accounts.spotify.com/api/token",
            data=urlencode({"grant_type": "refresh_token", "refresh_token": refresh_token}).encode(),
            headers={
                "Authorization": "Basic " + basic,
                "Content-Type": "application/x-www-form-urlencoded",
            },
        ), opener=opener)
        next_access_token = refreshed.get("access_token")
        if not isinstance(next_access_token, str) or not next_access_token:
            raise SpotifyOAuthError("Spotify returned an invalid account token")
        expires_in = refreshed.get("expires_in", 3600)
        if not isinstance(expires_in, int) or isinstance(expires_in, bool):
            expires_in = 3600
        account["access_token"] = next_access_token
        account["refresh_token"] = refreshed.get("refresh_token") or refresh_token
        account["scope"] = str(refreshed.get("scope", account.get("scope", "")))
        account["expires_at"] = now + max(60, min(expires_in, 86400))
        atomic_json(SPOTIFY_ACCOUNT, account)
        return next_access_token


def spotify_account_get(url, opener=urlopen):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "api.spotify.com":
        raise SpotifyOAuthError("Spotify request was rejected")
    token = spotify_account_access_token(opener=opener)
    return spotify_json_request(Request(url, headers={"Authorization": "Bearer " + token}), opener=opener)


def spotify_account_playlists(opener=urlopen):
    next_url = "https://api.spotify.com/v1/me/playlists?limit=50"
    rows = []
    seen = set()
    for _ in range(20):
        if not next_url:
            break
        page = spotify_account_get(next_url, opener=opener)
        for item in page.get("items", []):
            if not isinstance(item, dict):
                continue
            identifier = item.get("id")
            name = item.get("name")
            if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9]{22}", identifier):
                continue
            if not isinstance(name, str) or not name or identifier in seen:
                continue
            seen.add(identifier)
            owner = item.get("owner") if isinstance(item.get("owner"), dict) else {}
            images = item.get("images") if isinstance(item.get("images"), list) else []
            image = next((value.get("url") for value in images if isinstance(value, dict) and isinstance(value.get("url"), str)), None)
            contents = item.get("items") if isinstance(item.get("items"), dict) else item.get("tracks") if isinstance(item.get("tracks"), dict) else {}
            rows.append({
                "id": identifier,
                "name": name[:300],
                "uri": f"spotify:playlist:{identifier}",
                "ownerName": str(owner.get("display_name") or owner.get("id") or "")[:200],
                "artworkURL": image,
                "trackCount": int(contents.get("total", 0)) if isinstance(contents.get("total", 0), int) else 0,
            })
        candidate = page.get("next")
        next_url = candidate if isinstance(candidate, str) and candidate.startswith("https://api.spotify.com/") else None
    # Spotify returns the current user's library in its account order, with
    # recently added/reordered playlists first. Preserve that sequence instead
    # of replacing it with Wall's former alphabetical sort.
    return rows


def spotify_account_playlist_tracks(identifier, opener=urlopen):
    if not isinstance(identifier, str) or not re.fullmatch(r"[A-Za-z0-9]{22}", identifier):
        raise SpotifyOAuthError("Spotify playlist is invalid")
    next_url = f"https://api.spotify.com/v1/playlists/{identifier}/items?limit=50&additional_types=track"
    references = []
    seen = set()
    for _ in range(20):
        if not next_url:
            break
        page = spotify_account_get(next_url, opener=opener)
        for row in page.get("items", []):
            if not isinstance(row, dict):
                continue
            item = row.get("item") if isinstance(row.get("item"), dict) else row.get("track")
            track_id = item.get("id") if isinstance(item, dict) else None
            if isinstance(track_id, str) and re.fullmatch(r"[A-Za-z0-9]{22}", track_id) and track_id not in seen:
                seen.add(track_id)
                references.append(f"spotify:track:{track_id}")
        candidate = page.get("next")
        next_url = candidate if isinstance(candidate, str) and candidate.startswith("https://api.spotify.com/") else None
    return references


class SoundCloudOAuthError(Exception):
    pass


def soundcloud_client_config():
    value = read_json(SOUNDCLOUD_CREDENTIALS, {})
    try:
        client_id = str(value["client_id"])
        client_secret = str(value["client_secret"])
    except (KeyError, TypeError):
        raise SoundCloudOAuthError("SoundCloud is not configured") from None
    if not re.fullmatch(r"[A-Za-z0-9_-]{8,256}", client_id) or not 8 <= len(client_secret) <= 512:
        raise SoundCloudOAuthError("SoundCloud is not configured")
    return client_id, client_secret


def soundcloud_save_client_config(client_id, client_secret):
    if not isinstance(client_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{8,256}", client_id.strip()):
        raise ValueError("invalid SoundCloud client ID")
    existing = read_json(SOUNDCLOUD_CREDENTIALS, {})
    if not isinstance(client_secret, str):
        raise ValueError("invalid SoundCloud client secret")
    secret = client_secret.strip() or (existing.get("client_secret", "") if isinstance(existing, dict) else "")
    if not 8 <= len(secret) <= 512 or any(ord(character) < 33 for character in secret):
        raise ValueError("invalid SoundCloud client secret")
    atomic_json(SOUNDCLOUD_CREDENTIALS, {"client_id": client_id.strip(), "client_secret": secret})


def soundcloud_redirect_uri():
    origin = os.environ.get("WALL_ORIGIN", "https://wall.example.invalid").rstrip("/")
    parsed = urlparse(origin)
    if parsed.scheme != "https" or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
        raise SoundCloudOAuthError("Wall origin is invalid")
    return origin + "/api/soundcloud/callback"


def soundcloud_authorization_url(now=None):
    client_id, _ = soundcloud_client_config()
    now = int(time.time() if now is None else now)
    state = secrets.token_urlsafe(32)
    verifier = secrets.token_urlsafe(64)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
    with SOUNDCLOUD_OAUTH_LOCK:
        states = read_json(SOUNDCLOUD_OAUTH_STATES, [])
        if not isinstance(states, list):
            states = []
        states = [
            item for item in states
            if isinstance(item, dict)
            and isinstance(item.get("created_at"), int)
            and item["created_at"] >= now - 600
            and isinstance(item.get("state_hash"), str)
            and isinstance(item.get("code_verifier"), str)
        ]
        states.append({"state_hash": token_hash(state), "code_verifier": verifier, "created_at": now})
        atomic_json(SOUNDCLOUD_OAUTH_STATES, states[-20:])
    return "https://secure.soundcloud.com/authorize?" + urlencode({
        "client_id": client_id,
        "redirect_uri": soundcloud_redirect_uri(),
        "response_type": "code",
        "code_challenge": challenge,
        "code_challenge_method": "S256",
        "state": state,
    })


def soundcloud_consume_oauth_state(state, now=None):
    if not isinstance(state, str) or not 20 <= len(state) <= 200:
        return None
    now = int(time.time() if now is None else now)
    supplied_hash = token_hash(state)
    verifier = None
    with SOUNDCLOUD_OAUTH_LOCK:
        states = read_json(SOUNDCLOUD_OAUTH_STATES, [])
        kept = []
        if not isinstance(states, list):
            states = []
        for item in states:
            if not isinstance(item, dict) or not isinstance(item.get("created_at"), int):
                continue
            stored_hash = item.get("state_hash", "")
            candidate = item.get("code_verifier")
            if item["created_at"] < now - 600 or not isinstance(stored_hash, str) or not isinstance(candidate, str):
                continue
            if verifier is None and hmac.compare_digest(stored_hash, supplied_hash):
                verifier = candidate
                continue
            kept.append(item)
        atomic_json(SOUNDCLOUD_OAUTH_STATES, kept[-20:])
    return verifier


def soundcloud_json_request(request, opener=urlopen):
    try:
        with opener(request, timeout=12) as response:
            body = response.read(4_194_305)
        if len(body) > 4_194_304:
            raise ValueError
        value = json.loads(body)
        if not isinstance(value, (dict, list)):
            raise ValueError
        return value
    except HTTPError as error:
        raise SoundCloudOAuthError(f"SoundCloud request failed ({error.code})") from None
    except (URLError, TimeoutError, OSError, ValueError, TypeError, json.JSONDecodeError):
        raise SoundCloudOAuthError("SoundCloud request failed") from None


def soundcloud_exchange_authorization_code(code, verifier, opener=urlopen, now=None):
    if not isinstance(code, str) or not 1 <= len(code) <= 4096 or not isinstance(verifier, str):
        raise SoundCloudOAuthError("SoundCloud returned an invalid code")
    client_id, client_secret = soundcloud_client_config()
    token = soundcloud_json_request(Request(
        "https://secure.soundcloud.com/oauth/token",
        data=urlencode({
            "grant_type": "authorization_code",
            "client_id": client_id,
            "client_secret": client_secret,
            "redirect_uri": soundcloud_redirect_uri(),
            "code_verifier": verifier,
            "code": code,
        }).encode(),
        headers={"Accept": "application/json; charset=utf-8", "Content-Type": "application/x-www-form-urlencoded"},
    ), opener=opener)
    access_token = token.get("access_token") if isinstance(token, dict) else None
    refresh_token = token.get("refresh_token") if isinstance(token, dict) else None
    if not isinstance(access_token, str) or not access_token or not isinstance(refresh_token, str) or not refresh_token:
        raise SoundCloudOAuthError("SoundCloud returned an invalid account token")
    profile = {}
    try:
        profile = soundcloud_json_request(Request(
            "https://api.soundcloud.com/me",
            headers={"Accept": "application/json; charset=utf-8", "Authorization": "OAuth " + access_token},
        ), opener=opener)
    except SoundCloudOAuthError:
        pass
    now = int(time.time() if now is None else now)
    expires_in = token.get("expires_in", 3600)
    if not isinstance(expires_in, int) or isinstance(expires_in, bool):
        expires_in = 3600
    account = {
        "access_token": access_token,
        "refresh_token": refresh_token,
        "scope": str(token.get("scope", "")),
        "expires_at": now + max(60, min(expires_in, 86400)),
        "connected_at": datetime.fromtimestamp(now, timezone.utc).isoformat().replace("+00:00", "Z"),
        "soundcloud_user_id": str(profile.get("urn") or profile.get("id") or "")[:200] if isinstance(profile, dict) else "",
        "display_name": str(profile.get("username") or profile.get("full_name") or "")[:200] if isinstance(profile, dict) else "",
    }
    atomic_json(SOUNDCLOUD_ACCOUNT, account)
    return account


def soundcloud_account_status():
    account = read_json(SOUNDCLOUD_ACCOUNT, {})
    configured = True
    try:
        client_id, _ = soundcloud_client_config()
    except SoundCloudOAuthError:
        configured = False
        client_id = ""
    connected = isinstance(account, dict) and isinstance(account.get("refresh_token"), str) and bool(account["refresh_token"])
    return {
        "configured": configured,
        "client_id": client_id if configured else "",
        "connected": connected,
        "display_name": str(account.get("display_name", ""))[:200] if connected else "",
        "redirect_uri": soundcloud_redirect_uri(),
    }


def soundcloud_account_access_token(opener=urlopen, now=None):
    now = int(time.time() if now is None else now)
    with SOUNDCLOUD_OAUTH_LOCK:
        account = read_json(SOUNDCLOUD_ACCOUNT, {})
        if not isinstance(account, dict):
            raise SoundCloudOAuthError("SoundCloud is not connected")
        access_token = account.get("access_token")
        expires_at = account.get("expires_at", 0)
        if isinstance(access_token, str) and access_token and isinstance(expires_at, int) and expires_at > now + 60:
            return access_token
        refresh_token = account.get("refresh_token")
        if not isinstance(refresh_token, str) or not refresh_token:
            raise SoundCloudOAuthError("SoundCloud is not connected")
        client_id, client_secret = soundcloud_client_config()
        refreshed = soundcloud_json_request(Request(
            "https://secure.soundcloud.com/oauth/token",
            data=urlencode({
                "grant_type": "refresh_token",
                "client_id": client_id,
                "client_secret": client_secret,
                "refresh_token": refresh_token,
            }).encode(),
            headers={"Accept": "application/json; charset=utf-8", "Content-Type": "application/x-www-form-urlencoded"},
        ), opener=opener)
        next_access = refreshed.get("access_token") if isinstance(refreshed, dict) else None
        next_refresh = refreshed.get("refresh_token") if isinstance(refreshed, dict) else None
        if not isinstance(next_access, str) or not next_access or not isinstance(next_refresh, str) or not next_refresh:
            raise SoundCloudOAuthError("SoundCloud returned an invalid account token")
        expires_in = refreshed.get("expires_in", 3600)
        if not isinstance(expires_in, int) or isinstance(expires_in, bool):
            expires_in = 3600
        account["access_token"] = next_access
        account["refresh_token"] = next_refresh
        account["scope"] = str(refreshed.get("scope", account.get("scope", "")))
        account["expires_at"] = now + max(60, min(expires_in, 86400))
        atomic_json(SOUNDCLOUD_ACCOUNT, account)
        return next_access


def soundcloud_account_get(url, opener=urlopen):
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.netloc != "api.soundcloud.com":
        raise SoundCloudOAuthError("SoundCloud request was rejected")
    token = soundcloud_account_access_token(opener=opener)
    return soundcloud_json_request(Request(
        url,
        headers={"Accept": "application/json; charset=utf-8", "Authorization": "OAuth " + token},
    ), opener=opener)


def soundcloud_collection(value):
    if isinstance(value, list):
        return value
    if isinstance(value, dict) and isinstance(value.get("collection"), list):
        return value["collection"]
    return []


def soundcloud_track_row(item):
    if not isinstance(item, dict):
        return None
    identifier = item.get("urn") or (f"soundcloud:tracks:{item['id']}" if isinstance(item.get("id"), int) else "")
    title = item.get("title")
    user = item.get("user") if isinstance(item.get("user"), dict) else {}
    publisher = item.get("publisher_metadata") if isinstance(item.get("publisher_metadata"), dict) else {}
    artist = user.get("username") or publisher.get("artist")
    access = item.get("access")
    if not isinstance(identifier, str) or not identifier.startswith("soundcloud:tracks:") or not isinstance(title, str) or not title:
        return None
    if access == "blocked" or item.get("streamable") is False:
        return None
    artwork = item.get("artwork_url") or user.get("avatar_url")
    permalink = item.get("permalink_url")
    return {
        "id": identifier,
        "title": title[:300],
        "artist": str(artist or "")[:200],
        "album": "SoundCloud",
        "artworkURL": artwork if isinstance(artwork, str) and artwork.startswith("https://") else None,
        "permalinkURL": permalink if isinstance(permalink, str) and permalink.startswith("https://soundcloud.com/") else None,
    }


def soundcloud_search_tracks(query, opener=urlopen):
    if not isinstance(query, str) or not 1 <= len(query.strip()) <= 160:
        raise ValueError("Provide one search query of 1-160 characters.")
    value = soundcloud_account_get("https://api.soundcloud.com/tracks?" + urlencode({
        "q": query.strip(), "access": "playable", "limit": 30, "linked_partitioning": "true",
    }), opener=opener)
    rows = []
    seen = set()
    for item in soundcloud_collection(value):
        row = soundcloud_track_row(item)
        if row and row["id"] not in seen:
            seen.add(row["id"])
            rows.append(row)
    return rows


def soundcloud_account_playlists(opener=urlopen):
    value = soundcloud_account_get(
        "https://api.soundcloud.com/me/playlists?show_tracks=false&linked_partitioning=true&limit=50",
        opener=opener,
    )
    rows = []
    seen = set()
    for item in soundcloud_collection(value):
        if not isinstance(item, dict):
            continue
        identifier = item.get("urn") or (f"soundcloud:playlists:{item['id']}" if isinstance(item.get("id"), int) else "")
        title = item.get("title")
        if not isinstance(identifier, str) or not identifier.startswith("soundcloud:playlists:") or not isinstance(title, str) or not title or identifier in seen:
            continue
        seen.add(identifier)
        rows.append({
            "id": identifier, "title": title[:300], "subtitle": "SoundCloud",
            "artworkURL": item.get("artwork_url") if isinstance(item.get("artwork_url"), str) else None,
        })
    return rows


def default_canvas():
    return {
        "version": 1,
        "revision": 0,
        "updated_at": None,
        "state": {
            "schema": 1,
            "wall": {},
            "photoBooth": {},
        },
    }


def canvas_document():
    value = read_json(CANVAS, default_canvas())
    if not isinstance(value, dict) or value.get("version") != 1:
        return default_canvas()
    return value


def validate_json_tree(value, depth=0):
    if depth > 14:
        raise ValueError("canvas is too deeply nested")
    if value is None or isinstance(value, (bool, str)):
        if isinstance(value, str) and len(value) > 200_000:
            raise ValueError("canvas string is too long")
        return
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if not math.isfinite(value):
            raise ValueError("canvas contains a non-finite number")
        return
    if isinstance(value, list):
        if len(value) > 20_000:
            raise ValueError("canvas list is too long")
        for item in value:
            validate_json_tree(item, depth + 1)
        return
    if isinstance(value, dict):
        if len(value) > 1_000:
            raise ValueError("canvas object has too many keys")
        for key, item in value.items():
            if not isinstance(key, str) or not key or len(key) > 100:
                raise ValueError("canvas key is invalid")
            validate_json_tree(item, depth + 1)
        return
    raise ValueError("canvas contains an unsupported value")


def validate_canvas_state(state):
    if not isinstance(state, dict) or state.get("schema") != 1:
        raise ValueError("canvas schema is invalid")
    if not isinstance(state.get("wall"), dict) or not isinstance(state.get("photoBooth"), dict):
        raise ValueError("canvas scopes are invalid")
    validate_json_tree(state)
    for scope_name in ("wall", "photoBooth"):
        gifs = state[scope_name].get("gifs", [])
        if not isinstance(gifs, list) or len(gifs) > 200:
            raise ValueError("canvas GIF list is invalid")
        for item in gifs:
            if not isinstance(item, dict) or not ASSET_PATTERN.fullmatch(str(item.get("asset", ""))):
                raise ValueError("canvas GIF asset is invalid")
            for key in ("normalizedX", "normalizedY", "scale", "rotationDegrees"):
                number = item.get(key)
                if not isinstance(number, (int, float)) or isinstance(number, bool) or not math.isfinite(number):
                    raise ValueError("canvas GIF transform is invalid")
            if not 0 <= item["normalizedX"] <= 1 or not 0 <= item["normalizedY"] <= 1:
                raise ValueError("canvas GIF position is invalid")
            if not 0.05 <= item["scale"] <= 20:
                raise ValueError("canvas GIF scale is invalid")
    return state


def validate_photo_edit(record, expected_id):
    if not isinstance(record, dict) or record.get("id") != expected_id:
        raise ValueError("photo edit id is invalid")
    photo_name = record.get("photoName")
    if not valid_photo_name(photo_name) or token_hash(photo_name) != expected_id:
        raise ValueError("photo edit name is invalid")
    drawings = record.get("drawings", [])
    gifs = record.get("gifs", [])
    layers = record.get("layers", [])
    if not isinstance(drawings, list) or not isinstance(gifs, list) or not isinstance(layers, list):
        raise ValueError("photo edit content is invalid")
    if len(gifs) > 200 or len(layers) > 500:
        raise ValueError("photo edit content is too large")
    for item in gifs:
        if not isinstance(item, dict) or not ASSET_PATTERN.fullmatch(str(item.get("asset", ""))):
            raise ValueError("photo edit GIF is invalid")
        for key in ("normalizedX", "normalizedY", "scale", "rotationDegrees"):
            number = item.get(key)
            if not isinstance(number, (int, float)) or isinstance(number, bool) or not math.isfinite(number):
                raise ValueError("photo edit GIF transform is invalid")
        if not 0 <= item["normalizedX"] <= 1 or not 0 <= item["normalizedY"] <= 1:
            raise ValueError("photo edit GIF position is invalid")
        if not 0.05 <= item["scale"] <= 20:
            raise ValueError("photo edit GIF scale is invalid")
    if any(not isinstance(layer, str) or len(layer) > 100 for layer in layers):
        raise ValueError("photo edit layer is invalid")
    validate_json_tree(record)
    return record


def save_canvas(state, base_revision):
    with CANVAS_LOCK:
        current = canvas_document()
        if base_revision != current.get("revision"):
            return None, current
        if CANVAS.is_file():
            CANVAS_HISTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            history = CANVAS_HISTORY / f"canvas-{current.get('revision', 0):08d}-{stamp}.json"
            history.write_bytes(CANVAS.read_bytes())
            history.chmod(0o600)
            histories = sorted(CANVAS_HISTORY.glob("canvas-*.json"))
            if len(histories) > MAX_CANVAS_HISTORY:
                overflow = TRASH / "canvas-history"
                overflow.mkdir(parents=True, exist_ok=True, mode=0o700)
                for old in histories[:-MAX_CANVAS_HISTORY]:
                    old.replace(overflow / f"{uuid.uuid4().hex}-{old.name}")
        next_document = {
            "version": 1,
            "revision": int(current.get("revision", 0)) + 1,
            "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "state": state,
        }
        atomic_json(CANVAS, next_document)
        return next_document, None


def canvas_write_allowed(client_ip):
    now = time.time()
    attempts = CANVAS_ATTEMPTS[client_ip]
    while attempts and attempts[0] < now - 60:
        attempts.popleft()
    if len(attempts) >= 120:
        return False
    attempts.append(now)
    return True


def valid_asset_name(name):
    return isinstance(name, str) and ASSET_PATTERN.fullmatch(name) is not None


def gif_is_valid(body):
    if len(body) < 14 or body[:6] not in (b"GIF87a", b"GIF89a"):
        return False
    try:
        with Image.open(io.BytesIO(body)) as image:
            width, height = image.size
            return image.format == "GIF" and 0 < width <= 8_192 and 0 < height <= 8_192
    except (OSError, UnidentifiedImageError, ValueError):
        return False


def normalize_iso8601(value):
    if not isinstance(value, str) or not 10 <= len(value) <= 40:
        raise ValueError("invalid timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        raise ValueError("timezone required")
    return parsed.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def record_goon_event(event, now=None):
    with GOON_LOCK:
        events = read_json(GOON_EVENTS, [])
        if not isinstance(events, list):
            events = []
        if any(item.get("id") == event["id"] for item in events if isinstance(item, dict)):
            return False
        stored = {
            "id": event["id"],
            "person": event["person"],
            "action": event["action"],
            "occurred_at": event["occurred_at"],
            "recorded_at": (now or datetime.now(timezone.utc)).isoformat().replace("+00:00", "Z"),
        }
        events.append(stored)
        atomic_json(GOON_EVENTS, events[-MAX_GOON_EVENTS:])
        return True


def fixed_json_request(url, maximum=2 * 1024 * 1024):
    request = Request(url, headers={"Accept": "application/json", "User-Agent": "Wall/4"})
    with urlopen(request, timeout=8) as response:
        if response.status != 200:
            raise ValueError("upstream rejected")
        body = response.read(maximum + 1)
    if len(body) > maximum:
        raise ValueError("upstream response too large")
    return json.loads(body)


def weather_status(code):
    if code == 0:
        return "clear"
    if code in {1, 2}:
        return "partly cloudy"
    if code == 3:
        return "cloudy"
    if code in {45, 48}:
        return "fog"
    if 51 <= code <= 57:
        return "drizzle"
    if 61 <= code <= 67 or 80 <= code <= 82:
        return "rain"
    if 71 <= code <= 77 or code in {85, 86}:
        return "snow"
    if 95 <= code <= 99:
        return "storm"
    return "cloudy"


def dashboard_payload(fetch=fixed_json_request, now=None):
    current = time.time() if now is None else now
    with DASHBOARD_LOCK:
        cached = DASHBOARD_CACHE.get("value")
        if cached is not None and DASHBOARD_CACHE.get("expires", 0) > current:
            return cached
    result = {"weather": None, "transit": []}
    try:
        forecast = fetch(WEATHER_URL)
        current_weather = forecast["current"]
        hourly = forecast["hourly"]
        daily = forecast["daily"]
        high = float(daily["temperature_2m_max"][0])
        low = float(daily["temperature_2m_min"][0])
        chance = int(daily["precipitation_probability_max"][0])
        amount = float(daily["rain_sum"][0])
        current_time = str(current_weather["time"])
        current_temperature = float(current_weather["temperature_2m"])
        current_code = int(current_weather["weather_code"])
        hourly_count = min(
            len(hourly["time"]), len(hourly["temperature_2m"]),
            len(hourly["precipitation_probability"]), len(hourly["weather_code"]),
        )
        periods = []
        for index in range(hourly_count):
            period_time = str(hourly["time"][index])
            if period_time < current_time:
                continue
            try:
                hour = int(period_time[11:13])
            except (TypeError, ValueError):
                continue
            if hour % 2:
                continue
            code = int(hourly["weather_code"][index])
            periods.append({
                "time": period_time,
                "temperature": float(hourly["temperature_2m"][index]),
                "rainChance": int(hourly["precipitation_probability"][index]),
                "weatherCode": code,
                "status": weather_status(code),
            })
            if len(periods) == 6:
                break
        result["weather"] = {
            "currentTemperature": current_temperature,
            "currentCode": current_code,
            "status": weather_status(current_code),
            "high": high,
            "low": low,
            "rainChance": chance,
            "rainAmount": amount,
            "expectsRain": amount >= 0.01 or chance >= 25,
            "periods": periods,
        }
    except (KeyError, IndexError, TypeError, ValueError, OSError, json.JSONDecodeError):
        pass
    try:
        feed = fetch(TRANSIT_URL)
        alerts = []
        for entity in feed.get("entity", []):
            alert = entity.get("alert", {})
            routes = sorted({
                item.get("route_id", "").strip().upper()
                for item in alert.get("informed_entity", [])
                if item.get("route_id", "").strip().upper() in {"L", "M"}
            })
            if not routes:
                continue
            periods = alert.get("active_period", [])
            if periods and not any(
                float(period.get("start", 0) or 0) <= current
                and (not period.get("end") or current <= float(period["end"]))
                for period in periods
            ):
                continue
            translations = alert.get("header_text", {}).get("translation", [])
            headline = next(
                (item.get("text", "") for item in translations if item.get("language") == "en"),
                translations[0].get("text", "") if translations else "",
            ).replace("[", "").replace("]", "").strip()
            if headline:
                alerts.append({"id": str(entity.get("id", ""))[:120], "routes": routes, "headline": headline[:800]})
        result["transit"] = alerts[:20]
    except (KeyError, TypeError, ValueError, OSError, json.JSONDecodeError):
        pass
    # Do not pin a failed weather request for a full refresh cycle. Successful
    # weather expires before the browser's ten-minute poll so each poll can
    # actually obtain a new observation.
    weather_ttl = 9 * 60 if result["weather"] is not None else 60
    with DASHBOARD_LOCK:
        DASHBOARD_CACHE.update({"expires": current + weather_ttl, "value": result})
    return result


def horoscope_payload(fetch=fixed_json_request, today=None):
    day = today or datetime.now(WALL_TIME_ZONE).date().isoformat()
    with DASHBOARD_LOCK:
        if HOROSCOPE_CACHE.get("day") == day and HOROSCOPE_CACHE.get("value") is not None:
            return HOROSCOPE_CACHE["value"]
    signs = {
        "casey": "aquarius", "drew": "pisces", "alex": "cancer",
        "blake": "sagittarius", "ellis": "taurus",
    }
    fallback = "The sky is checking its notes."
    readings = {}
    successful = 0
    try:
        next_day = (date.fromisoformat(day) + timedelta(days=1)).isoformat()
    except ValueError:
        next_day = day
    for person, sign in signs.items():
        try:
            response = fetch(HOROSCOPE_URL + quote(sign) + "&wall_day=" + quote(day)).get("data", {})
            value = response.get("horoscope", "")
            response_day = str(response.get("date", ""))
            cleaned = " ".join(str(value).split())
            if cleaned and response_day in {day, next_day}:
                readings[person] = cleaned[:2_000]
                successful += 1
            else:
                readings[person] = fallback
        except (TypeError, ValueError, OSError, json.JSONDecodeError):
            readings[person] = fallback
    payload = {"date": day, "readings": readings}
    # A transient failure should never freeze placeholder text for the whole
    # day. Only a complete current-day response earns the daily cache.
    if successful == len(signs):
        with DASHBOARD_LOCK:
            HOROSCOPE_CACHE.update({"day": day, "value": payload})
    return payload


def save_device_canvas_snapshot(state, now=None):
    state = validate_canvas_state(state)
    stamp_time = now or datetime.now(timezone.utc)
    DEVICE_CANVAS_SNAPSHOTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    stamp = stamp_time.strftime("%Y%m%dT%H%M%S.%fZ")
    destination = DEVICE_CANVAS_SNAPSHOTS / f"wall-ipad-{stamp}.json"
    atomic_json(destination, {
        "captured_at": stamp_time.isoformat().replace("+00:00", "Z"),
        "state": state,
    })
    snapshots = sorted(DEVICE_CANVAS_SNAPSHOTS.glob("wall-ipad-*.json"))
    if len(snapshots) > 30:
        overflow = TRASH / "device-canvas-snapshots"
        overflow.mkdir(parents=True, exist_ok=True, mode=0o700)
        for old in snapshots[:-30]:
            old.replace(overflow / f"{uuid.uuid4().hex}-{old.name}")
    current = canvas_document()
    document, conflict = save_canvas(state, int(current.get("revision", 0)))
    if conflict is not None:
        current = canvas_document()
        document, conflict = save_canvas(state, int(current.get("revision", 0)))
    if conflict is not None or document is None:
        raise RuntimeError("canvas snapshot conflict")
    return document, destination


class WallHandler(BaseHTTPRequestHandler):
    server_version = "Wall/3"
    sys_version = ""

    @property
    def client_ip(self):
        forwarded = self.headers.get("CF-Connecting-IP", "").strip()
        return forwarded if forwarded and len(forwarded) < 80 else self.client_address[0]

    def log_message(self, format, *args):
        # Deliberately omit URLs, cookies, authorization, and photo names.
        print(f"{self.client_ip} {self.command} {getattr(self, '_status', '-')}" , flush=True)

    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
        self.send_header("Content-Security-Policy", "default-src 'self'; img-src 'self' blob:; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'")
        super().end_headers()

    def send_response(self, code, message=None):
        self._status = code
        super().send_response(code, message)

    def do_GET(self):
        parsed_url = urlparse(self.path)
        path = parsed_url.path
        if path == "/healthz":
            return self.reply(200, b'{"ok":true}', "application/json")
        if path == "/login":
            return self.serve_public("login.html", "text/html; charset=utf-8")
        if path == "/app.css":
            return self.serve_public("app.css", "text/css; charset=utf-8")
        if path == "/api/spotify/callback":
            return self.spotify_callback(parse_qs(parsed_url.query, keep_blank_values=True))
        if path == "/api/soundcloud/callback":
            return self.soundcloud_callback(parse_qs(parsed_url.query, keep_blank_values=True))
        if path == "/api/device/photo-booth":
            return self.photo_booth_index(parse_qs(parsed_url.query))
        if path == "/api/device/photo-edits":
            return self.photo_edit_index()
        if path == "/api/device/spotify/search":
            return self.spotify_search(parse_qs(parsed_url.query, keep_blank_values=True))
        if path == "/api/device/soundcloud/search":
            return self.device_soundcloud_search(parse_qs(parsed_url.query, keep_blank_values=True))
        if path == "/api/device/soundcloud/account/status":
            return self.device_soundcloud_status()
        if path == "/api/device/soundcloud/account/playlists":
            return self.device_soundcloud_playlists()
        if path == "/api/device/spotify/account/status":
            return self.spotify_account_status()
        if path == "/api/device/spotify/account/playlists":
            return self.spotify_account_playlists()
        if path == "/api/device/sonos/commands":
            return self.device_sonos_commands()
        if path.startswith("/api/device/spotify/account/playlists/") and path.endswith("/tracks"):
            identifier = path.removeprefix("/api/device/spotify/account/playlists/").removesuffix("/tracks")
            return self.spotify_account_playlist_tracks(identifier)
        if path.startswith("/api/device/photos/"):
            return self.device_photo_file(path.removeprefix("/api/device/photos/"))
        if path.startswith("/api/device/photo-edits/"):
            return self.photo_edit_file(path.removeprefix("/api/device/photo-edits/"))
        if path.startswith("/api/device/photo-booth/photos/"):
            return self.device_photo_file(path.removeprefix("/api/device/photo-booth/photos/"))
        if path == "/api/canvas":
            return self.canvas_index()
        if path.startswith("/canvas-assets/"):
            return self.canvas_asset(path.removeprefix("/canvas-assets/"))
        if not self.session_valid():
            return self.redirect("/login")
        if path == "/api/spotify/login":
            return self.spotify_login()
        if path == "/api/spotify/status":
            return self.reply(200, json.dumps(spotify_account_status()).encode(), "application/json")
        if path == "/api/soundcloud/login":
            return self.soundcloud_login()
        if path == "/api/soundcloud/status":
            return self.reply(200, json.dumps(soundcloud_account_status()).encode(), "application/json")
        if path == "/api/soundcloud/search":
            return self.browser_soundcloud_search(parse_qs(parsed_url.query, keep_blank_values=True))
        if path == "/api/soundcloud/playlists":
            return self.browser_soundcloud_playlists()
        if path == "/api/sonos/state":
            return self.browser_sonos_state()
        if path == "/api/sonos/search":
            return self.browser_spotify_search(parse_qs(parsed_url.query, keep_blank_values=True))
        if path in STATIC:
            return self.serve_public(*STATIC[path])
        if path == "/api/photos":
            return self.photo_index(parse_qs(parsed_url.query))
        if path == "/api/goons":
            return self.goon_index()
        if path == "/api/dashboard":
            return self.dashboard_index()
        if path == "/api/horoscopes":
            return self.horoscope_index()
        if path.startswith("/photos/"):
            return self.photo_file(path.removeprefix("/photos/"))
        return self.reply(404, b"not found", "text/plain; charset=utf-8")

    def do_POST(self):
        path = urlparse(self.path).path
        if path == "/login":
            return self.login()
        if path == "/logout":
            return self.logout()
        if path == "/api/device/enroll":
            return self.enroll_device()
        if path == "/api/device/photos":
            return self.receive_photo()
        if path == "/api/device/photo-booth/guests":
            return self.receive_photo_booth_guest()
        if path == "/api/device/goons":
            return self.receive_goon_event()
        if path == "/api/device/canvas-snapshot":
            return self.receive_device_canvas_snapshot()
        if path == "/api/device/sonos/state":
            return self.receive_device_sonos_state()
        if path.startswith("/api/device/sonos/commands/"):
            return self.complete_device_sonos_command(path.removeprefix("/api/device/sonos/commands/"))
        if path.startswith("/api/device/photo-edits/"):
            return self.receive_photo_edit(path.removeprefix("/api/device/photo-edits/"))
        if path == "/api/goons":
            return self.receive_browser_goon_event()
        if path == "/api/sonos/commands":
            return self.receive_browser_sonos_command()
        if path == "/api/soundcloud/settings":
            return self.receive_soundcloud_settings()
        if path == "/api/canvas/assets":
            return self.receive_canvas_asset()
        if path.startswith("/api/photos/") and path.endswith("/visibility"):
            return self.change_photo_visibility(path)
        return self.reply(404, b"not found", "text/plain; charset=utf-8")

    def do_PUT(self):
        if urlparse(self.path).path == "/api/canvas":
            return self.replace_canvas()
        self.reply(405, b"method not allowed", "text/plain; charset=utf-8")

    do_PATCH = do_PUT

    def do_DELETE(self):
        parsed_url = urlparse(self.path)
        path = parsed_url.path
        if path.startswith("/api/device/photo-booth/photos/"):
            return self.delete_device_photo_booth(
                path.removeprefix("/api/device/photo-booth/photos/"),
                parse_qs(parsed_url.query),
            )
        if not path.startswith("/api/photos/"):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        payload = self.session_payload()
        if payload is None:
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        expected_origin = os.environ.get("WALL_ORIGIN", "https://wall.example.invalid")
        if self.headers.get("Origin", "") != expected_origin:
            return self.reply(403, b'{"error":"origin rejected"}', "application/json")
        expected_csrf = csrf_token(self.session_secret().decode(), payload)
        if not hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), expected_csrf):
            return self.reply(403, b'{"error":"csrf rejected"}', "application/json")
        name = path.removeprefix("/api/photos/")
        if move_photo_to_trash(name) is None:
            return self.reply(404, b'{"error":"not found"}', "application/json")
        return self.reply(200, json.dumps({"deleted": True, "name": name}).encode(), "application/json")

    def delete_device_photo_booth(self, raw_name, query):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        name = unquote(raw_name)
        night = query.get("night", [""])[0]
        if not NIGHT_PATTERN.fullmatch(night):
            return self.reply(400, b'{"error":"invalid night"}', "application/json")
        # The device token is intentionally narrow: it may only remove a photo
        # that provenance metadata assigns to the requested booth night.
        if not photo_is_in_booth_night(name, night):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        if move_photo_to_trash(name) is None:
            return self.reply(404, b'{"error":"not found"}', "application/json")
        return self.reply(
            200,
            json.dumps({"deleted": True, "name": name, "night": night}).encode(),
            "application/json",
        )

    def browser_mutation_authorized(self):
        payload = self.session_payload()
        if payload is None:
            return False
        expected_origin = os.environ.get("WALL_ORIGIN", "https://wall.example.invalid")
        if self.headers.get("Origin", "") != expected_origin:
            return False
        expected_csrf = csrf_token(self.session_secret().decode(), payload)
        return hmac.compare_digest(self.headers.get("X-CSRF-Token", ""), expected_csrf)

    def canvas_read_authorized(self):
        return self.session_payload() is not None or self.device_authorized()

    def canvas_write_authorized(self):
        return self.device_authorized() or self.browser_mutation_authorized()

    def canvas_index(self):
        if not self.canvas_read_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        document = canvas_document()
        payload = self.session_payload()
        if payload is not None:
            document = dict(document)
            document["csrf"] = csrf_token(self.session_secret().decode(), payload)
        return self.reply(200, json.dumps(document).encode(), "application/json")

    def replace_canvas(self):
        if not self.canvas_write_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        if not canvas_write_allowed(self.client_ip):
            return self.reply(429, b'{"error":"try again later"}', "application/json")
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.reply(415, b'{"error":"json required"}', "application/json")
        body = self.read_body(MAX_CANVAS_BYTES)
        if body is None:
            return
        try:
            request = json.loads(body)
            base_revision = request["base_revision"]
            if not isinstance(base_revision, int) or isinstance(base_revision, bool) or base_revision < 0:
                raise ValueError("invalid revision")
            state = validate_canvas_state(request["state"])
        except (ValueError, KeyError, TypeError, json.JSONDecodeError) as error:
            return self.reply(
                400,
                json.dumps({"error": str(error) or "invalid canvas"}).encode(),
                "application/json",
            )
        document, conflict = save_canvas(state, base_revision)
        if conflict is not None:
            return self.reply(
                409,
                json.dumps({"error": "revision conflict", "current": conflict}).encode(),
                "application/json",
            )
        return self.reply(200, json.dumps(document).encode(), "application/json")

    def receive_canvas_asset(self):
        if not self.canvas_write_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        if not canvas_write_allowed(self.client_ip):
            return self.reply(429, b'{"error":"try again later"}', "application/json")
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "image/gif":
            return self.reply(415, b'{"error":"gif required"}', "application/json")
        body = self.read_body(MAX_GIF_BYTES)
        if body is None:
            return
        if not gif_is_valid(body):
            return self.reply(400, b'{"error":"invalid gif"}', "application/json")
        asset = hashlib.sha256(body).hexdigest()
        CANVAS_ASSETS.mkdir(parents=True, exist_ok=True, mode=0o700)
        destination = CANVAS_ASSETS / f"{asset}.gif"
        with CANVAS_LOCK:
            if not destination.exists():
                existing = list(CANVAS_ASSETS.glob("*.gif"))
                total = sum(item.stat().st_size for item in existing if item.is_file())
                if len(existing) >= MAX_CANVAS_ASSETS or total + len(body) > MAX_CANVAS_ASSET_BYTES:
                    return self.reply(507, b'{"error":"canvas asset storage full"}', "application/json")
                temporary = CANVAS_ASSETS / f".{uuid.uuid4().hex}.tmp"
                temporary.write_bytes(body)
                temporary.chmod(0o600)
                temporary.replace(destination)
        response = {"asset": asset, "url": f"/canvas-assets/{asset}.gif", "bytes": len(body)}
        return self.reply(201, json.dumps(response).encode(), "application/json")

    def canvas_asset(self, raw_name):
        if not self.canvas_read_authorized():
            return self.reply(401, b"unauthorized", "text/plain; charset=utf-8")
        name = unquote(raw_name)
        if not name.endswith(".gif") or not valid_asset_name(name[:-4]):
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        path = CANVAS_ASSETS / name
        if path.is_symlink() or not path.is_file() or path.resolve().parent != CANVAS_ASSETS.resolve():
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        return self.reply(200, path.read_bytes(), "image/gif")

    def change_photo_visibility(self, path):
        if not self.browser_mutation_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        body = self.read_body(2048)
        if body is None:
            return
        try:
            hidden = json.loads(body)["hidden"]
            if not isinstance(hidden, bool):
                raise ValueError
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            return self.reply(400, b'{"error":"invalid request"}', "application/json")
        name = path.removeprefix("/api/photos/").removesuffix("/visibility")
        if not set_photo_hidden(name, hidden):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        return self.reply(
            200,
            json.dumps({"name": name, "hidden": hidden}).encode(),
            "application/json",
        )

    def login(self):
        now = time.time()
        attempts = LOGIN_ATTEMPTS[self.client_ip]
        while attempts and attempts[0] < now - 600:
            attempts.popleft()
        if len(attempts) >= 5:
            return self.reply(429, b"try again later", "text/plain; charset=utf-8")
        body = self.read_body(4096)
        if body is None:
            return
        password = parse_qs(body.decode(errors="ignore")).get("password", [""])[0]
        expected = os.environ.get("WALL_PASSWORD_HASH", "")
        if not expected or not password_valid(password, expected):
            attempts.append(now)
            time.sleep(0.35)
            return self.redirect("/login?error=1")
        attempts.clear()
        expiry = int(now + 12 * 60 * 60)
        payload = f"wall:{expiry}"
        signature = hmac.new(self.session_secret(), payload.encode(), hashlib.sha256).hexdigest()
        self.send_response(303)
        self.send_header("Location", "/")
        self.send_header("Set-Cookie", f"wall_session={payload}.{signature}; Path=/; Max-Age=43200; HttpOnly; Secure; SameSite=Strict")
        self.end_headers()

    def logout(self):
        if not self.session_valid():
            return self.reply(401, b"unauthorized", "text/plain; charset=utf-8")
        self.send_response(303)
        self.send_header("Location", "/login")
        self.send_header("Set-Cookie", "wall_session=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict")
        self.end_headers()

    def session_secret(self):
        value = os.environ.get("WALL_SESSION_SECRET", "")
        if len(value) < 32:
            raise RuntimeError("WALL_SESSION_SECRET must be at least 32 characters")
        return value.encode()

    def session_valid(self):
        return self.session_payload() is not None

    def session_payload(self):
        raw = cookies.SimpleCookie(self.headers.get("Cookie", "")).get("wall_session")
        if not raw:
            return None
        try:
            payload, signature = raw.value.rsplit(".", 1)
            subject, expiry = payload.split(":", 1)
            expected = hmac.new(self.session_secret(), payload.encode(), hashlib.sha256).hexdigest()
            if subject == "wall" and int(expiry) >= int(time.time()) and hmac.compare_digest(signature, expected):
                return payload
            return None
        except (ValueError, RuntimeError):
            return None

    def enroll_device(self):
        body = self.read_body(4096)
        if body is None:
            return
        try:
            request = json.loads(body)
            token = request["token"]
            label = str(request.get("label", "Wall iPad"))[:80]
            if not isinstance(token, str) or not 32 <= len(token) <= 200:
                raise ValueError
        except (ValueError, KeyError, TypeError):
            return self.reply(400, b'{"error":"invalid request"}', "application/json")
        digest = token_hash(token)
        approved = read_json(APPROVED, [])
        if any(entry.get("hash") == digest for entry in approved):
            return self.reply(200, b'{"status":"approved"}', "application/json")
        pending = read_json(PENDING, [])
        if not any(entry.get("hash") == digest for entry in pending):
            pending.append({"hash": digest, "label": label, "created_at": datetime.now(timezone.utc).isoformat()})
            atomic_json(PENDING, pending[-20:])
        return self.reply(202, b'{"status":"pending"}', "application/json")

    def device_authorized(self):
        header = self.headers.get("Authorization", "")
        if not header.startswith("Bearer "):
            return False
        digest = token_hash(header[7:])
        return any(hmac.compare_digest(entry.get("hash", ""), digest) for entry in read_json(APPROVED, []))

    def browser_sonos_state(self):
        state = read_json(SONOS_STATE, {})
        if not isinstance(state, dict):
            state = {}
        return self.reply(200, json.dumps({"state": state, "pending": len(pending_sonos_commands())}).encode(), "application/json")

    def browser_spotify_search(self, query):
        if set(query) != {"q"} or len(query["q"]) != 1 or not 1 <= len(query["q"][0].strip()) <= 160:
            return self.reply(400, b'{"error":"Provide one search query of 1-160 characters."}', "application/json")
        try:
            result = SPOTIFY_CATALOG.search(query["q"][0], "browser:" + token_hash(self.client_ip))
            return self.reply(200, json.dumps(result).encode(), "application/json")
        except CatalogError as error:
            status = error.status if error.status in {400, 429, 503} else 502
            return self.reply(status, json.dumps({"error": str(error)}).encode(), "application/json")

    def browser_soundcloud_search(self, query):
        if set(query) != {"q"} or len(query["q"]) != 1:
            return self.reply(400, b'{"error":"Provide one search query of 1-160 characters."}', "application/json")
        try:
            rows = soundcloud_search_tracks(query["q"][0])
            return self.reply(200, json.dumps({"tracks": rows}).encode(), "application/json")
        except ValueError as error:
            return self.reply(400, json.dumps({"error": str(error)}).encode(), "application/json")
        except SoundCloudOAuthError:
            return self.reply(503, b'{"error":"Connect SoundCloud in settings first."}', "application/json")

    def browser_soundcloud_playlists(self):
        try:
            rows = soundcloud_account_playlists()
            return self.reply(200, json.dumps({"playlists": rows}).encode(), "application/json")
        except SoundCloudOAuthError:
            return self.reply(503, b'{"error":"Connect SoundCloud in settings first."}', "application/json")

    def receive_browser_sonos_command(self):
        if not self.browser_mutation_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        body = self.read_body(4096)
        if body is None:
            return
        try:
            command = enqueue_sonos_command(json.loads(body))
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            return self.reply(400, json.dumps({"error": str(error)}).encode(), "application/json")
        return self.reply(202, json.dumps({"command": command}).encode(), "application/json")

    def device_sonos_commands(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.reply(200, json.dumps({"commands": pending_sonos_commands()}).encode(), "application/json")

    def receive_device_sonos_state(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        body = self.read_body(4096)
        if body is None:
            return
        try:
            state = sanitize_sonos_state(json.loads(body))
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            return self.reply(400, json.dumps({"error": str(error)}).encode(), "application/json")
        atomic_json(SONOS_STATE, state)
        return self.reply(200, b'{"saved":true}', "application/json")

    def complete_device_sonos_command(self, identifier):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        body = self.read_body(2048)
        if body is None:
            return
        try:
            value = json.loads(body)
            ok = value["ok"]
            message = value.get("message", "")
            if not isinstance(ok, bool) or not isinstance(message, str):
                raise ValueError
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            return self.reply(400, b'{"error":"invalid completion"}', "application/json")
        if not complete_sonos_command(identifier, ok, message):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        return self.reply(200, b'{"saved":true}', "application/json")

    def spotify_search(self, query):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"Wall device is not approved for catalog search."}', "application/json")
        if set(query) != {"q"} or len(query["q"]) != 1 or len(query["q"][0]) > 160:
            return self.reply(400, b'{"error":"Provide one search query of 1-160 characters."}', "application/json")
        try:
            result = SPOTIFY_CATALOG.search(query["q"][0], token_hash(self.headers["Authorization"][7:]))
            return self.reply(200, json.dumps(result).encode(), "application/json")
        except CatalogError as error:
            # Upstream authentication failures describe server credentials, not
            # the caller's device token. Keep the distinction on the iPad.
            status = error.status if error.status in {400, 429, 503} else 502
            return self.reply(status, json.dumps({"error": str(error)}).encode(), "application/json")

    def device_soundcloud_search(self, query):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"Wall device is not approved for SoundCloud search."}', "application/json")
        if set(query) != {"q"} or len(query["q"]) != 1:
            return self.reply(400, b'{"error":"Provide one search query of 1-160 characters."}', "application/json")
        try:
            rows = soundcloud_search_tracks(query["q"][0])
            return self.reply(200, json.dumps({"tracks": rows}).encode(), "application/json")
        except ValueError as error:
            return self.reply(400, json.dumps({"error": str(error)}).encode(), "application/json")
        except SoundCloudOAuthError:
            return self.reply(503, b'{"error":"Connect SoundCloud at wall.example.invalid/settings."}', "application/json")

    def device_soundcloud_status(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.reply(200, json.dumps(soundcloud_account_status()).encode(), "application/json")

    def device_soundcloud_playlists(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        try:
            rows = soundcloud_account_playlists()
            return self.reply(200, json.dumps({"playlists": rows}).encode(), "application/json")
        except SoundCloudOAuthError:
            return self.reply(503, b'{"error":"SoundCloud account is unavailable"}', "application/json")

    def spotify_account_status(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.reply(200, json.dumps(spotify_account_status()).encode(), "application/json")

    def spotify_account_playlists(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        try:
            rows = spotify_account_playlists()
            return self.reply(200, json.dumps({"playlists": rows}).encode(), "application/json")
        except SpotifyOAuthError:
            return self.reply(502, b'{"error":"Spotify account is unavailable"}', "application/json")

    def spotify_account_playlist_tracks(self, identifier):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        try:
            references = spotify_account_playlist_tracks(identifier)
            return self.reply(200, json.dumps({"references": references}).encode(), "application/json")
        except SpotifyOAuthError:
            return self.reply(502, b'{"error":"Spotify playlist is unavailable"}', "application/json")

    def spotify_login(self):
        try:
            return self.redirect(spotify_authorization_url())
        except SpotifyOAuthError:
            return self.redirect("/?spotify=unavailable")

    def spotify_callback(self, query):
        state = query.get("state", [""])[0] if len(query.get("state", [])) == 1 else ""
        if not spotify_consume_oauth_state(state):
            return self.redirect("/?spotify=invalid")
        if query.get("error"):
            return self.redirect("/?spotify=cancelled")
        code = query.get("code", [""])[0] if len(query.get("code", [])) == 1 else ""
        try:
            spotify_exchange_authorization_code(code)
        except SpotifyOAuthError:
            return self.redirect("/?spotify=failed")
        return self.redirect("/?spotify=connected")

    def receive_soundcloud_settings(self):
        if not self.browser_mutation_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        body = self.read_body(4096)
        if body is None:
            return
        try:
            value = json.loads(body)
            if not isinstance(value, dict) or set(value) - {"client_id", "client_secret"}:
                raise ValueError("invalid settings")
            soundcloud_save_client_config(value.get("client_id"), value.get("client_secret", ""))
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            return self.reply(400, json.dumps({"error": str(error)}).encode(), "application/json")
        return self.reply(200, json.dumps(soundcloud_account_status()).encode(), "application/json")

    def soundcloud_login(self):
        try:
            return self.redirect(soundcloud_authorization_url())
        except SoundCloudOAuthError:
            return self.redirect("/?soundcloud=unavailable")

    def soundcloud_callback(self, query):
        state = query.get("state", [""])[0] if len(query.get("state", [])) == 1 else ""
        verifier = soundcloud_consume_oauth_state(state)
        if verifier is None:
            return self.redirect("/?soundcloud=invalid")
        if query.get("error"):
            return self.redirect("/?soundcloud=cancelled")
        code = query.get("code", [""])[0] if len(query.get("code", [])) == 1 else ""
        try:
            soundcloud_exchange_authorization_code(code, verifier)
        except SoundCloudOAuthError:
            return self.redirect("/?soundcloud=failed")
        return self.redirect("/?soundcloud=connected")

    def receive_photo(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "image/jpeg":
            return self.reply(415, b'{"error":"jpeg required"}', "application/json")
        body = self.read_body(MAX_PHOTO_BYTES)
        if body is None:
            return
        if len(body) < 4 or not body.startswith(b"\xff\xd8\xff") or not body.endswith(b"\xff\xd9"):
            return self.reply(400, b'{"error":"invalid jpeg"}', "application/json")
        try:
            usable = jpeg_is_usable(body)
        except ValueError:
            return self.reply(400, b'{"error":"invalid jpeg"}', "application/json")
        if not usable:
            return self.reply(422, b'{"error":"black frame"}', "application/json")
        PHOTOS.mkdir(parents=True, exist_ok=True, mode=0o700)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        name = f"fit-{stamp}-{uuid.uuid4().hex[:10]}.jpg"
        destination = PHOTOS / name
        destination.write_bytes(body)
        destination.chmod(0o600)
        metadata = capture_metadata(
            self.headers.get("X-Wall-Capture-Source", "manual"),
            self.headers.get("X-Wall-Photo-Booth-Night"),
        )
        with PHOTO_LOCK:
            all_metadata = read_json(PHOTO_METADATA, {})
            if not isinstance(all_metadata, dict):
                all_metadata = {}
            all_metadata[name] = metadata
            atomic_json(PHOTO_METADATA, all_metadata)
        response = json.dumps({"saved": True, "name": name}).encode()
        self.reply(201, response, "application/json")

    def receive_photo_booth_guest(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.reply(415, b'{"error":"json required"}', "application/json")
        body = self.read_body(2048)
        if body is None:
            return
        try:
            request = json.loads(body)
            email = request["email"]
            photo_name = request["photo_name"]
            night = request["night"]
        except (KeyError, TypeError, json.JSONDecodeError):
            return self.reply(400, b'{"error":"invalid guest"}', "application/json")
        if not record_photo_booth_guest(email, photo_name, night):
            return self.reply(400, b'{"error":"invalid guest"}', "application/json")
        return self.reply(201, b'{"saved":true}', "application/json")

    def receive_goon_event(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.receive_goon_event_payload()

    def receive_browser_goon_event(self):
        if not self.browser_mutation_authorized():
            return self.reply(403, b'{"error":"rejected"}', "application/json")
        return self.receive_goon_event_payload()

    def receive_goon_event_payload(self):
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.reply(415, b'{"error":"json required"}', "application/json")
        now = time.time()
        attempts = GOON_ATTEMPTS[self.client_ip]
        while attempts and attempts[0] < now - 600:
            attempts.popleft()
        if len(attempts) >= 240:
            return self.reply(429, b'{"error":"try again later"}', "application/json")
        body = self.read_body(4096)
        if body is None:
            return
        try:
            request = json.loads(body)
            event_id = str(uuid.UUID(request["id"]))
            person = request["person"]
            action = request["action"]
            occurred_at = normalize_iso8601(request["occurred_at"])
            if person not in GOON_PEOPLE or action not in GOON_ACTIONS:
                raise ValueError
        except (ValueError, KeyError, TypeError, json.JSONDecodeError):
            return self.reply(400, b'{"error":"invalid event"}', "application/json")
        attempts.append(now)
        created = record_goon_event({
            "id": event_id,
            "person": person,
            "action": action,
            "occurred_at": occurred_at,
        })
        status = 201 if created else 200
        self.reply(status, json.dumps({"saved": True, "duplicate": not created}).encode(), "application/json")

    def receive_device_canvas_snapshot(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        if self.headers.get("Content-Type", "").split(";", 1)[0].strip().lower() != "application/json":
            return self.reply(415, b'{"error":"json required"}', "application/json")
        body = self.read_body(MAX_CANVAS_BYTES)
        if body is None:
            return
        try:
            request = json.loads(body)
            document, _ = save_device_canvas_snapshot(request["state"])
        except (ValueError, KeyError, TypeError, json.JSONDecodeError, RuntimeError) as error:
            return self.reply(400, json.dumps({"error": str(error) or "invalid snapshot"}).encode(), "application/json")
        return self.reply(201, json.dumps({
            "saved": True,
            "revision": document["revision"],
            "updated_at": document["updated_at"],
        }).encode(), "application/json")

    def photo_index(self, query=None):
        PHOTOS.mkdir(parents=True, exist_ok=True, mode=0o700)
        payload = self.session_payload()
        if payload is None:
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        results = []
        include_hidden = (query or {}).get("include_hidden", [""])[0] == "1"
        with PHOTO_LOCK:
            all_metadata = read_json(PHOTO_METADATA, {})
        if not isinstance(all_metadata, dict):
            all_metadata = {}
        for path in sorted(PHOTOS.glob("fit-*.jpg"), reverse=True):
            stat = path.stat()
            metadata = all_metadata.get(path.name, capture_metadata("manual"))
            if metadata.get("hidden", False) and not include_hidden:
                continue
            results.append({
                "name": path.name,
                "url": "/photos/" + quote(path.name),
                "created": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(),
                "bytes": stat.st_size,
                "hidden": bool(metadata.get("hidden", False)),
                "source": metadata.get("source", "manual"),
            })
        token = csrf_token(self.session_secret().decode(), payload)
        self.reply(200, json.dumps({"photos": results, "csrf": token}).encode(), "application/json")

    def photo_booth_index(self, query):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        night = query.get("night", [""])[0]
        if not NIGHT_PATTERN.fullmatch(night):
            return self.reply(400, b'{"error":"invalid night"}', "application/json")
        with PHOTO_LOCK:
            all_metadata = read_json(PHOTO_METADATA, {})
        if not isinstance(all_metadata, dict):
            all_metadata = {}
        results = []
        for path in sorted(PHOTOS.glob("fit-*.jpg"), reverse=True):
            metadata = all_metadata.get(path.name, {})
            if metadata.get("source") != "photo_booth" or metadata.get("photo_booth_night") != night:
                continue
            if metadata.get("hidden", False):
                continue
            stat = path.stat()
            results.append({
                "name": path.name,
                "url": "/api/device/photo-booth/photos/" + quote(path.name),
                "created": datetime.fromtimestamp(stat.st_mtime, timezone.utc).isoformat(),
            })
            if len(results) >= 50:
                break
        return self.reply(200, json.dumps({"night": night, "photos": results}).encode(), "application/json")

    def device_photo_file(self, name):
        if not self.device_authorized():
            return self.reply(401, b"unauthorized", "text/plain; charset=utf-8")
        return self.photo_file(name)

    def photo_edit_index(self):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        PHOTO_EDITS.mkdir(parents=True, exist_ok=True, mode=0o700)
        edits = []
        for path in sorted(PHOTO_EDITS.glob("*.json")):
            identifier = path.stem
            if not ASSET_PATTERN.fullmatch(identifier) or path.is_symlink() or not path.is_file():
                continue
            record = read_json(path, None)
            try:
                validate_photo_edit(record, identifier)
            except ValueError:
                continue
            edits.append({"id": identifier, "photoName": record["photoName"]})
        return self.reply(200, json.dumps({"edits": edits[:500]}).encode(), "application/json")

    def photo_edit_file(self, identifier):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        identifier = unquote(identifier)
        if not ASSET_PATTERN.fullmatch(identifier):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        path = PHOTO_EDITS / f"{identifier}.json"
        if path.is_symlink() or not path.is_file() or path.resolve().parent != PHOTO_EDITS.resolve():
            return self.reply(404, b'{"error":"not found"}', "application/json")
        body = path.read_bytes()
        if len(body) > MAX_PHOTO_EDIT_BYTES:
            return self.reply(500, b'{"error":"stored edit is too large"}', "application/json")
        return self.reply(200, body, "application/json")

    def receive_photo_edit(self, identifier):
        if not self.device_authorized():
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        identifier = unquote(identifier)
        if not ASSET_PATTERN.fullmatch(identifier):
            return self.reply(404, b'{"error":"not found"}', "application/json")
        body = self.read_body(MAX_PHOTO_EDIT_BYTES)
        if body is None:
            return
        try:
            record = validate_photo_edit(json.loads(body), identifier)
        except (ValueError, TypeError, json.JSONDecodeError):
            return self.reply(400, b'{"error":"invalid photo edit"}', "application/json")
        PHOTO_EDITS.mkdir(parents=True, exist_ok=True, mode=0o700)
        atomic_json(PHOTO_EDITS / f"{identifier}.json", record)
        return self.reply(201, json.dumps({"saved": True, "id": identifier}).encode(), "application/json")

    def goon_index(self):
        if self.session_payload() is None:
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        with GOON_LOCK:
            events = read_json(GOON_EVENTS, [])
        if not isinstance(events, list):
            events = []
        totals = {person: 0 for person in sorted(GOON_PEOPLE)}
        for event in events:
            if not isinstance(event, dict) or event.get("person") not in totals:
                continue
            totals[event["person"]] = max(
                0,
                totals[event["person"]] + (1 if event.get("action") == "add" else -1),
            )
        self.reply(
            200,
            json.dumps({"events": list(reversed(events)), "totals": totals}).encode(),
            "application/json",
        )

    def dashboard_index(self):
        if self.session_payload() is None:
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.reply(200, json.dumps(dashboard_payload()).encode(), "application/json")

    def horoscope_index(self):
        if self.session_payload() is None:
            return self.reply(401, b'{"error":"unauthorized"}', "application/json")
        return self.reply(200, json.dumps(horoscope_payload()).encode(), "application/json")

    def photo_file(self, name):
        if not valid_photo_name(name):
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        path = PHOTOS / name
        if path.is_symlink() or not path.is_file() or path.resolve().parent != PHOTOS.resolve():
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        self.reply(200, path.read_bytes(), "image/jpeg")

    def read_body(self, maximum):
        try:
            length = int(self.headers.get("Content-Length", "-1"))
        except ValueError:
            length = -1
        if length < 0 or length > maximum:
            self.reply(413, b"payload too large", "text/plain; charset=utf-8")
            return None
        return self.rfile.read(length)

    def serve_public(self, name, content_type):
        if name not in {value[0] for value in STATIC.values()} | {"login.html"}:
            return self.reply(404, b"not found", "text/plain; charset=utf-8")
        self.reply(200, (PUBLIC / name).read_bytes(), content_type)

    def redirect(self, location):
        self.send_response(303)
        self.send_header("Location", location)
        self.end_headers()

    def reply(self, status, body, content_type):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    DATA.mkdir(parents=True, exist_ok=True, mode=0o700)
    PHOTOS.mkdir(parents=True, exist_ok=True, mode=0o700)
    CANVAS_ASSETS.mkdir(parents=True, exist_ok=True, mode=0o700)
    CANVAS_HISTORY.mkdir(parents=True, exist_ok=True, mode=0o700)
    DEVICE_CANVAS_SNAPSHOTS.mkdir(parents=True, exist_ok=True, mode=0o700)
    PHOTO_EDITS.mkdir(parents=True, exist_ok=True, mode=0o700)
    if not os.environ.get("WALL_PASSWORD_HASH") or len(os.environ.get("WALL_SESSION_SECRET", "")) < 32:
        raise SystemExit("WALL_PASSWORD_HASH and a 32+ character WALL_SESSION_SECRET are required")
    if not PIL_AVAILABLE:
        raise SystemExit("Pillow is required for JPEG validation")
    port = int(os.environ.get("PORT", "4422"))
    ThreadingHTTPServer(("127.0.0.1", port), WallHandler).serve_forever()


if __name__ == "__main__":
    main()
