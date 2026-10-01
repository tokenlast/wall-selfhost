#!/usr/bin/env python3
"""Convert an iOS Wall app-domain export into the cloud canvas format."""

import argparse
import hashlib
import json
import plistlib
import shutil
from datetime import datetime, timezone
from pathlib import Path


def json_bytes(value, default):
    if not isinstance(value, (bytes, bytearray)):
        return default
    try:
        return json.loads(value.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        return default


def source_value(source):
    if not isinstance(source, dict) or len(source) != 1:
        raise ValueError(f"unsupported GIF source: {source!r}")
    kind, payload = next(iter(source.items()))
    if kind not in {"bundled", "downloaded"} or not isinstance(payload, dict):
        raise ValueError(f"unsupported GIF source: {source!r}")
    value = payload.get("_0")
    if not isinstance(value, str) or not value:
        raise ValueError(f"unsupported GIF source: {source!r}")
    return kind, value


def convert_gifs(metadata_path, bundled_root, asset_output):
    items = json.loads(metadata_path.read_text())
    converted = []
    for item in items:
        kind, value = source_value(item["source"])
        source = bundled_root / f"{value}.gif" if kind == "bundled" else metadata_path.parent / value
        if not source.is_file() or source.is_symlink():
            raise FileNotFoundError(f"missing GIF payload for {item['id']}: {source}")
        body = source.read_bytes()
        if body[:6] not in (b"GIF87a", b"GIF89a"):
            raise ValueError(f"not a GIF: {source}")
        digest = hashlib.sha256(body).hexdigest()
        destination = asset_output / f"{digest}.gif"
        if not destination.exists():
            shutil.copy2(source, destination)
            destination.chmod(0o600)
        converted.append({
            "id": str(item["id"]).lower(),
            "asset": digest,
            "naturalWidth": float(item["naturalWidth"]),
            "naturalHeight": float(item["naturalHeight"]),
            "normalizedX": float(item["normalizedX"]),
            "normalizedY": float(item["normalizedY"]),
            "scale": float(item["scale"]),
            "rotationDegrees": float(item["rotationDegrees"]),
            "originalSource": {"kind": kind, "value": value},
        })
    return converted


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("backup", type=Path, help="Readable Wall app-domain export")
    parser.add_argument("output", type=Path, help="New migration output directory")
    parser.add_argument(
        "--resources",
        type=Path,
        default=Path(__file__).resolve().parents[1] / "WipeWall" / "Resources",
    )
    args = parser.parse_args()

    backup = args.backup.resolve()
    output = args.output.resolve()
    resources = args.resources.resolve()
    if output.exists():
        raise SystemExit(f"refusing to overwrite: {output}")

    support = backup / "Library" / "Application Support" / "Wall"
    prefs_path = backup / "Library" / "Preferences" / "org.example.wall.wipewall.plist"
    if not support.is_dir() or not prefs_path.is_file() or not resources.is_dir():
        raise SystemExit("backup or bundled resource directory is incomplete")

    assets = output / "canvas-assets"
    assets.mkdir(parents=True, mode=0o700)
    with prefs_path.open("rb") as stream:
        prefs = plistlib.load(stream)

    wall_gifs = convert_gifs(support / "GIFs" / "wall-gifs.json", resources, assets)
    booth_gifs = convert_gifs(support / "PhotoBoothGIFs" / "wall-gifs.json", resources, assets)
    drawings = json.loads((support / "drawings.json").read_text())

    wall = {
        "gifs": wall_gifs,
        "drawings": drawings,
        "elements": json_bytes(prefs.get("wall.element.transforms.v1"), {}),
        "widgets": json_bytes(prefs.get("wall.widgets.v1"), []),
        "layers": list(prefs.get("wall.global-layers.v1", [])),
        "note": {
            "text": str(prefs.get("wall.note", "")),
            "font": str(prefs.get("wall.note.font", "Helvetica")),
            "size": float(prefs.get("wall.note.size", 28)),
        },
    }
    booth = {
        "gifs": booth_gifs,
        "elements": json_bytes(prefs.get("wall.photo-booth.element.transforms.v1"), {}),
        "layers": list(prefs.get("wall.photo-booth.global-layers.v1", [])),
    }
    document = {
        "version": 1,
        "revision": 1,
        "updated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "state": {"schema": 1, "wall": wall, "photoBooth": booth},
    }
    canvas_path = output / "canvas.json"
    canvas_path.write_text(json.dumps(document, separators=(",", ":")))
    canvas_path.chmod(0o600)

    manifest = {
        "source": str(backup),
        "wallGIFs": len(wall_gifs),
        "photoBoothGIFs": len(booth_gifs),
        "drawings": len(drawings),
        "uniqueAssets": len(list(assets.glob("*.gif"))),
        "canvasSHA256": hashlib.sha256(canvas_path.read_bytes()).hexdigest(),
    }
    manifest_path = output / "migration-manifest.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    manifest_path.chmod(0o600)
    print(json.dumps(manifest, indent=2))


if __name__ == "__main__":
    main()
