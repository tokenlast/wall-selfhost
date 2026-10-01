#!/usr/bin/env bash
set -Eeuo pipefail
wall_source_dir="$(cd -- "$(dirname -- "$0")" && pwd)"
cd "$wall_source_dir"
if [[ -x "$wall_source_dir/.venv/bin/python" ]]; then
  exec "$wall_source_dir/.venv/bin/python" "$wall_source_dir/server.py"
fi
exec python3 "$wall_source_dir/server.py"
