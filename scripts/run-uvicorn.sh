#!/usr/bin/env bash
# Start the FastAPI/Uvicorn app on 127.0.0.1:4000
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PY="./.venv/Scripts/python.exe"; [ -x "$PY" ] || PY="./.venv/bin/python"
exec "$PY" -m uvicorn app:app --app-dir python-app --host 127.0.0.1 --port 4000 "$@"
