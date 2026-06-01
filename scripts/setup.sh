#!/usr/bin/env bash
# One-time setup: Python venv + deps, and the native nginx build.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "[setup] creating Python venv + installing deps..."
python -m venv .venv
PY="./.venv/Scripts/python.exe"; [ -x "$PY" ] || PY="./.venv/bin/python"   # Windows vs *nix
"$PY" -m pip install --upgrade pip >/dev/null
"$PY" -m pip install -r python-app/requirements.txt

NGINX_VER=1.31.1
if [ ! -e "nginx-${NGINX_VER}/nginx.exe" ] && [ ! -e "nginx-${NGINX_VER}/sbin/nginx" ]; then
  echo "[setup] downloading nginx ${NGINX_VER} (Windows build)..."
  curl -fsSL -o nginx.zip "http://nginx.org/download/nginx-${NGINX_VER}.zip"
  powershell -NoProfile -Command "Expand-Archive -Path nginx.zip -DestinationPath . -Force"
fi

echo "[setup] done. Next: ./scripts/reproduce.sh"
