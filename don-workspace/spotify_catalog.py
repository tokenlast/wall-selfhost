"""Fixed-host, device-authenticated Spotify catalog broker. No user account data."""
import base64
import json
import threading
import time
from collections import OrderedDict, deque
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, HTTPRedirectHandler, build_opener


class CatalogError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status


class NoRedirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class SpotifyCatalog:
    def __init__(self, credentials, opener=None, clock=time.monotonic):
        self.credentials = credentials
        self.opener = opener or build_opener(NoRedirects()).open
        self.clock = clock
        self.lock = threading.Lock()
        self.token = None
        self.token_expiry = 0
        self.retry_at = 0
        self.cache = OrderedDict()
        self.attempts = deque()

    def search(self, query, device):
        query = " ".join(query.split())
        if not 1 <= len(query) <= 160:
            raise CatalogError(400, "Search must contain 1–160 characters.")
        if not self.lock.acquire(timeout=0.1):
            raise CatalogError(429, "Spotify search is busy. Try again shortly.")
        try:
            now = self.clock()
            while self.attempts and self.attempts[0][0] <= now - 86400:
                self.attempts.popleft()
            minute = [key for when, key in self.attempts if when > now - 60]
            if len(self.attempts) >= 4000 or len(minute) >= 60 or minute.count(device) >= 30:
                raise CatalogError(429, "Spotify search limit reached. Try again later.")
            self.attempts.append((now, device))
            cached = self.cache.get(query)
            if cached and cached[0] > now:
                self.cache.move_to_end(query)
                return cached[1]
            if self.retry_at > now:
                raise CatalogError(429, "Spotify asked Wall to wait before searching again.")
            for attempt in range(2):
                if not self.token or self.token_expiry <= now:
                    self._authorize()
                url = "https://api.spotify.com/v1/search?" + urlencode({
                    "q": query, "type": "track", "limit": 10, "market": "US",
                })
                try:
                    document = self._json(Request(url, headers={"Authorization": "Bearer " + self.token}))
                    break
                except CatalogError as error:
                    if error.status == 401 and attempt == 0:
                        self.token = None
                        continue
                    raise
            items = document.get("tracks", {}).get("items")
            if not isinstance(items, list):
                raise CatalogError(502, "Spotify returned an unreadable catalog response.")
            result = {"tracks": {"items": items[:10]}}
            self.cache[query] = (self.clock() + 60, result)
            self.cache.move_to_end(query)
            while len(self.cache) > 128:
                self.cache.popitem(last=False)
            return result
        finally:
            self.lock.release()

    def _authorize(self):
        try:
            config = self.credentials()
            client_id, secret = config["client_id"], config["client_secret"]
            if not client_id or not secret:
                raise ValueError()
        except (OSError, ValueError, KeyError, TypeError):
            raise CatalogError(503, "Wall’s Spotify API credentials are not configured.") from None
        basic = base64.b64encode((client_id + ":" + secret).encode()).decode()
        result = self._json(Request(
            "https://accounts.spotify.com/api/token", data=b"grant_type=client_credentials",
            headers={"Authorization": "Basic " + basic, "Content-Type": "application/x-www-form-urlencoded"},
        ))
        if not isinstance(result.get("access_token"), str) or not result["access_token"]:
            raise CatalogError(502, "Spotify returned an invalid app token.")
        self.token = result["access_token"]
        self.token_expiry = self.clock() + max(1, min(3600, int(result.get("expires_in", 3600))) - 60)

    def _json(self, request):
        try:
            with self.opener(request, timeout=8) as response:
                data = response.read(1_048_577)
            if len(data) > 1_048_576:
                raise ValueError()
            result = json.loads(data)
            if not isinstance(result, dict):
                raise ValueError()
            return result
        except HTTPError as error:
            if error.code == 429:
                try:
                    delay = max(1, min(86400, int(error.headers.get("Retry-After", "60"))))
                except ValueError:
                    delay = 60
                self.retry_at = self.clock() + delay
            # Never echo upstream bodies, access tokens, or client credentials.
            raise CatalogError(error.code, f"Spotify catalog request failed (HTTP {error.code}).") from None
        except (URLError, TimeoutError, OSError):
            raise CatalogError(502, "Wall could not reach Spotify. Try again shortly.") from None
        except (ValueError, TypeError):
            raise CatalogError(502, "Spotify returned an unreadable catalog response.") from None
