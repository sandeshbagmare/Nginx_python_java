#!/usr/bin/env bash
# Faithful end-to-end repro on a REAL servlet container:
#   client -> NGINX(:8088) -> Tomcat + AIAssistantProxyServlet(:8080) -> Uvicorn(:8000)
#
# Phase 1 runs the servlet FAULTY  (stripHopByHop=false) -> duplicate TE -> nginx 502.
# Phase 2 runs the servlet FIXED   (stripHopByHop=true)  -> single TE   -> nginx 200.
#
# Reuses ../.venv (FastAPI/Uvicorn) and ../nginx-1.31.1 from the parent repo.
# If those are missing, run ../scripts/setup.sh once first.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; cd "$HERE"
PARENT="$(cd .. && pwd)"
PY="$PARENT/.venv/Scripts/python.exe"; [ -x "$PY" ] || PY="$PARENT/.venv/bin/python"
ERR="$PARENT/nginx-1.31.1/logs/error.log"
CP="out;lib/*"

UV=""; TC=""
cleanup() {
  [ -n "$UV" ] && kill "$UV" 2>/dev/null
  [ -n "$TC" ] && kill "$TC" 2>/dev/null
  MSYS_NO_PATHCONV=1 powershell -NoProfile -File run-nginx.ps1 stop >/dev/null 2>&1 || true
}
trap cleanup EXIT

wait_port()   { for _ in $(seq 1 80); do curl -s -o /dev/null "http://127.0.0.1:$1$2" 2>/dev/null && return 0; sleep 0.5; done; return 1; }
count_te()    { curl -s -D - -N -o /dev/null "$1" | grep -ci '^Transfer-Encoding:'; }
http_status() { curl -s -o /dev/null -w '%{http_code}' "$1"; }

start_tomcat() { # $1 = true|false
  MSYS_NO_PATHCONV=1 java -DstripHopByHop="$1" -Dport=8080 -cp "$CP" EmbeddedProxy >/dev/null 2>&1 & TC=$!
  wait_port 8080 /sse
}

TCV=9.0.118
if ! ls lib/tomcat-embed-core-*.jar >/dev/null 2>&1; then
  echo "==> downloading embedded Tomcat $TCV"
  mkdir -p lib
  curl -fsSL -o "lib/tomcat-embed-core-$TCV.jar"     "https://repo1.maven.org/maven2/org/apache/tomcat/embed/tomcat-embed-core/$TCV/tomcat-embed-core-$TCV.jar"
  curl -fsSL -o "lib/tomcat-annotations-api-$TCV.jar" "https://repo1.maven.org/maven2/org/apache/tomcat/tomcat-annotations-api/$TCV/tomcat-annotations-api-$TCV.jar"
fi

echo "==> compiling servlet + Tomcat bootstrap"
mkdir -p out
MSYS_NO_PATHCONV=1 javac -cp "lib/*" -d out AIAssistantProxyServlet.java EmbeddedProxy.java || { echo "compile failed"; exit 1; }

echo "==> starting Uvicorn :8000"
"$PY" -m uvicorn app:app --app-dir . --host 127.0.0.1 --port 8000 --log-level warning & UV=$!
wait_port 8000 /plain || { echo "uvicorn failed"; exit 1; }

echo "==> starting NGINX :8088"
: > "$ERR" 2>/dev/null || true
MSYS_NO_PATHCONV=1 powershell -NoProfile -File run-nginx.ps1 start >/dev/null 2>&1 &
sleep 1

echo
echo "################ PHASE 1 — FAULTY servlet (stripHopByHop=false) ################"
start_tomcat false || { echo "tomcat failed"; exit 1; }
echo "  servlet direct :8080   Transfer-Encoding count = $(count_te http://127.0.0.1:8080/sse)   (expect 2)"
S1=$(http_status http://127.0.0.1:8088/sse)
echo "  via NGINX :8088        HTTP $S1                          (expect 502)"
echo -n "  nginx error.log      : "; grep -a 'duplicate header line' "$ERR" | tail -1 | sed 's/^[0-9/ :]*//'
kill "$TC" 2>/dev/null; TC=""; sleep 1

echo
echo "################ PHASE 2 — FIXED servlet (stripHopByHop=true) ################"
start_tomcat true || { echo "tomcat failed"; exit 1; }
echo "  servlet direct :8080   Transfer-Encoding count = $(count_te http://127.0.0.1:8080/sse)   (expect 1)"
S2=$(http_status http://127.0.0.1:8088/sse)
echo "  via NGINX :8088        HTTP $S2                          (expect 200)"
echo "  stream via NGINX:"
curl -s -N --max-time 3 http://127.0.0.1:8088/sse | sed 's/^/      /' | head -6

echo
echo "============================= RESULT ============================="
if [ "$S1" = "502" ] && [ "$S2" = "200" ]; then
  echo "PASS  faulty -> 502 (duplicate Transfer-Encoding) ; fixed -> 200 (single TE, SSE streams)"
else
  echo "CHECK phase1(nginx)=$S1  phase2(nginx)=$S2"
fi
echo "=================================================================="
