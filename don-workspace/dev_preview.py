#!/usr/bin/env python3
"""Local, read-only preview of a private Wall cloud migration bundle."""

import argparse
from http.server import ThreadingHTTPServer
from pathlib import Path

import server


class PreviewHandler(server.WallHandler):
    def session_payload(self):
        return "preview:4102444800"

    def session_secret(self):
        return b"wall-local-preview-secret-do-not-deploy"

    def do_PUT(self):
        self.reply(405, b"read only preview", "text/plain; charset=utf-8")

    def do_POST(self):
        self.reply(405, b"read only preview", "text/plain; charset=utf-8")

    def do_DELETE(self):
        self.reply(405, b"read only preview", "text/plain; charset=utf-8")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("bundle", type=Path)
    parser.add_argument("--port", type=int, default=4423)
    args = parser.parse_args()
    bundle = args.bundle.resolve()
    if not (bundle / "canvas.json").is_file() or not (bundle / "canvas-assets").is_dir():
        raise SystemExit("preview bundle is incomplete")
    server.CANVAS = bundle / "canvas.json"
    server.CANVAS_ASSETS = bundle / "canvas-assets"
    server.PHOTOS = bundle / "preview-photos"
    server.GOON_EVENTS = bundle / "preview-goons.json"
    ThreadingHTTPServer(("127.0.0.1", args.port), PreviewHandler).serve_forever()


if __name__ == "__main__":
    main()
