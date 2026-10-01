#!/usr/bin/env python3
"""Approve one explicitly selected pending device hash on your own server."""
import argparse
import re
from pathlib import Path

from server import atomic_json, read_json


def approve(data_dir, selected_hash):
    if not re.fullmatch(r"[a-f0-9]{64}", selected_hash):
        raise ValueError("Provide the full SHA-256 hash of the intended pending device")
    pending_path = data_dir / "pending-devices.json"
    approved_path = data_dir / "approved-devices.json"
    pending = read_json(pending_path, [])
    approved = read_json(approved_path, [])
    if not isinstance(pending, list) or not isinstance(approved, list):
        raise ValueError("Invalid device registry")
    matches = [item for item in pending if isinstance(item, dict) and item.get("hash") == selected_hash]
    if len(matches) != 1:
        raise ValueError("Exactly one matching pending device is required")
    if not any(isinstance(item, dict) and item.get("hash") == selected_hash for item in approved):
        atomic_json(approved_path, approved + matches)
    atomic_json(pending_path, [item for item in pending if item != matches[0]])


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, required=True)
    parser.add_argument("--hash", required=True, dest="selected_hash")
    args = parser.parse_args()
    try:
        approve(args.data_dir.resolve(), args.selected_hash)
    except ValueError as error:
        parser.exit(1, str(error) + "\n")
    print("Selected device approved")
