#!/usr/bin/env bash
# End-to-end reproduction + fix verification:
#   client -> NGINX(:4088) -> Java proxy(:4001 naive / :4002 fixed) -> Uvicorn(:4000)
#
# Proves: Uvicorn=1 TE, NAIVE proxy=2 TE -> NGINX 502, FIXED proxy=1 TE -> NGINX 200.
# Prereq: run ./scripts/setup.sh once first.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
PY="./.venv/Scripts/python.exe"; [ -x "$PY" ] || PY="./.venv/bin/python"
ERR="nginx-1.31.1/logs/error.log"

UV=""; PROXY=""
cleanup() {
  [ -n "$UV" ]    && kill "$UV"    2>/dev/null
  [ -n "$PROXY" ] && kill "$PROXY" 2>/dev/null
  powershell -NoProfile -File scripts/run-nginx.ps1 stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_port() { for _ in $(seq 1 60); do curl -s -o /dev/null "http://127.0.0.1:$1$2" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
count_te()  { curl -s -D - -N -o /dev/null "$1" | grep -ci '^Transfer-Encoding:'; }
status()    { curl -s -o /dev/null -w '%{http_code}' "$1"; }

echo "==> starting Uvicorn :4000"
"$PY" -m uvicorn app:app --app-dir python-app --host 127.0.0.1 --port 4000 --log-level warning & UV=$!
wait_port 4000 /plain || { echo "uvicorn failed to start"; exit 1; }
U=$(count_te http://127.0.0.1:4000/sse)
echo "    [1] Uvicorn direct           Transfer-Encoding count = $U   (expect 1)"

echo "==> starting NAIVE proxy :4001"
java java-proxy/NaiveProxy.java & PROXY=$!
wait_port 4001 /sse || { echo "naive proxy failed to start"; exit 1; }
N=$(count_te http://127.0.0.1:4001/sse)
echo "    [2] Through NAIVE proxy      Transfer-Encoding count = $N   (expect 2)"

echo "==> starting NGINX :4088"
: > "$ERR" 2>/dev/null || true
powershell -NoProfile -File scripts/run-nginx.ps1 start >/dev/null 2>&1 &
wait_port 4088 / >/dev/null 2>&1 || true; sleep 1
S=$(status http://127.0.0.1:4088/sse)
echo "    [3] NGINX -> NAIVE           HTTP status = $S          (expect 502)"
echo -n "        log: "; grep -a 'duplicate header line' "$ERR" | tail -1 | sed 's/^[0-9/ :]*//'

echo "==> swapping NAIVE -> FIXED proxy on :4002"
kill "$PROXY" 2>/dev/null; PROXY=""; sleep 1
java java-proxy/FixedProxy.java & PROXY=$!
wait_port 4002 /sse || { echo "fixed proxy failed to start"; exit 1; }

# Point nginx at the fixed proxy (:4002)
sed -i 's|proxy_pass http://127.0.0.1:4001|proxy_pass http://127.0.0.1:4002|' nginx/sse.conf
powershell -NoProfile -File scripts/run-nginx.ps1 stop >/dev/null 2>&1 || true; sleep 1
powershell -NoProfile -File scripts/run-nginx.ps1 start >/dev/null 2>&1 &
wait_port 4088 / >/dev/null 2>&1 || true; sleep 1

S2=$(status http://127.0.0.1:4088/sse)
echo "    [4] NGINX -> FIXED           HTTP status = $S2          (expect 200)"

# Restore nginx config
sed -i 's|proxy_pass http://127.0.0.1:4002|proxy_pass http://127.0.0.1:4001|' nginx/sse.conf

echo
echo "==================================== RESULT ===================================="
if [ "$U" = "1" ] && [ "$N" = "2" ] && [ "$S" = "502" ] && [ "$S2" = "200" ]; then
  echo "PASS  uvicorn=1 TE | naive=2 TE -> nginx 502 | fixed=1 TE -> nginx 200"
else
  echo "CHECK uvicorn=$U naive=$N nginx(naive)=$S nginx(fixed)=$S2"
fi
echo "================================================================================"
