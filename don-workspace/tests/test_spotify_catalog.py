import io
import json
import sys
import unittest
from pathlib import Path
from urllib.error import HTTPError
from unittest.mock import Mock

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from spotify_catalog import SpotifyCatalog, CatalogError, NoRedirects
import server


class SpotifyCatalogTests(unittest.TestCase):
    def setUp(self):
        self.now = 1000
        self.calls = []
        self.catalog = SpotifyCatalog(lambda: {"client_id": "test-id", "client_secret": "test-secret"},
                                      opener=self.open, clock=lambda: self.now)

    def open(self, request, timeout):
        self.calls.append(request)
        self.assertEqual(timeout, 8)
        if request.full_url == "https://accounts.spotify.com/api/token":
            return io.BytesIO(b'{"access_token":"private-test-token","expires_in":3600}')
        self.assertTrue(request.full_url.startswith("https://api.spotify.com/v1/search?"))
        self.assertEqual(request.headers["Authorization"], "Bearer private-test-token")
        return io.BytesIO(b'{"tracks":{"items":[{"id":"real-spotify-id","name":"Song"}]}}')

    def test_exact_ids_cached_and_tokens_never_returned(self):
        result = self.catalog.search("Song", "device")
        self.assertEqual(result["tracks"]["items"][0]["id"], "real-spotify-id")
        self.assertNotIn("token", json.dumps(result))
        self.assertEqual(self.catalog.search("Song", "device"), result)
        self.assertEqual(len(self.calls), 2)
        self.now += 61
        self.catalog.search("Song", "device")
        self.assertEqual(len(self.calls), 3)

    def test_input_limits_and_fixed_host_even_for_url_queries(self):
        for query in ["", " ", "a" * 161]:
            with self.assertRaises(CatalogError) as error:
                self.catalog.search(query, "device")
            self.assertEqual(error.exception.status, 400)
        self.catalog.search("http://127.0.0.1/private", "device")
        self.assertTrue(self.calls[-1].full_url.startswith("https://api.spotify.com/"))
        self.assertIsNone(NoRedirects().redirect_request(None, None, 302, "", {}, "http://127.0.0.1"))

    def test_rate_limit_applies_even_to_cached_queries(self):
        for _ in range(30):
            self.catalog.search("Song", "device")
        with self.assertRaises(CatalogError) as error:
            self.catalog.search("Song", "device")
        self.assertEqual(error.exception.status, 429)
        self.assertEqual(len(self.calls), 2)

    def test_upstream_error_is_redacted_and_retry_after_honored(self):
        def limited(request, timeout):
            raise HTTPError(request.full_url, 429, "private detail", {"Retry-After": "120"},
                            io.BytesIO(b'private-test-token'))
        self.catalog.opener = limited
        for _ in range(2):
            with self.assertRaises(CatalogError) as error:
                self.catalog.search("Song", "device")
            self.assertEqual(error.exception.status, 429)
            self.assertNotIn("private", str(error.exception))
        self.assertEqual(self.catalog.retry_at, self.now + 120)

    def test_missing_configuration_fails_closed(self):
        self.catalog.credentials = lambda: {}
        with self.assertRaises(CatalogError) as error:
            self.catalog.search("Song", "device")
        self.assertEqual(error.exception.status, 503)

    def test_device_auth_precedes_search_and_rejects_extra_parameters(self):
        handler = Mock()
        handler.device_authorized.return_value = False
        server.WallHandler.spotify_search(handler, {"q": ["Song"]})
        self.assertEqual(handler.reply.call_args.args[0], 401)
        handler.device_authorized.return_value = True
        for query in [{"q": ["Song"], "url": ["http://127.0.0.1"]}, {"q": ["a", "b"]}, {}]:
            server.WallHandler.spotify_search(handler, query)
            self.assertEqual(handler.reply.call_args.args[0], 400)


if __name__ == "__main__":
    unittest.main()
