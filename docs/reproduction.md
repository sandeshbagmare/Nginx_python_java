# Reproduction — step by step

## Prerequisites

- **JDK 11+** (tested on Corretto 21) — proxies run via single‑file launch, no Maven/Gradle.
- **Python 3.x** (tested on 3.13).
- **curl**.
- **NGINX ≥ 1.23** — `scripts/setup.sh` downloads the native Windows build 1.31.1. On Linux/macOS use
  your package manager's nginx (see [Non‑Windows](#non-windows--docker) below).
- Windows users: **PowerShell** (to launch the native nginx) and **Git Bash** (for the `.sh` scripts).

Ports used: Uvicorn **4000**, Java proxy **4001**, NGINX **4088**.

## One command

```bash
./scripts/setup.sh        # once: venv + deps + nginx download
./scripts/reproduce.sh    # full chain, prints PASS/FAIL
```

Expected final line:

```
PASS  uvicorn=1 TE | naive=2 TE -> nginx 502 | fixed=1 TE -> nginx 200
```

`reproduce.sh` starts Uvicorn, the NaiveProxy, and NGINX; checks the 502; then swaps in the FixedProxy
and checks the 200; then tears everything down.

## Manual walk‑through (four terminals)

### Step 0 — start Uvicorn
```bash
./scripts/run-uvicorn.sh
```

### Step 1 — Uvicorn is correct (one TE)
```bash
curl -s -D - -N -o /dev/null http://127.0.0.1:4000/sse | grep -ci '^Transfer-Encoding:'
# => 1
```
Full capture: [`evidence/1-uvicorn-direct.txt`](../evidence/1-uvicorn-direct.txt). Note `/plain` has
`content-length` and **no** TE — that's why non‑streaming routes never break.

### Step 2 — the NAIVE proxy duplicates it (two TE)
```bash
./scripts/run-proxy.sh naive        # in another terminal
curl -s -D - -N -o /dev/null http://127.0.0.1:4001/sse | grep -in 'transfer-encoding'
# 7:transfer-encoding: chunked      <- copied from Uvicorn
# 8:Transfer-Encoding: chunked      <- the proxy's own framing
```
Full capture: [`evidence/2-naive-proxy-2x-te.txt`](../evidence/2-naive-proxy-2x-te.txt).

### Step 3 — NGINX rejects it (502 + the reported log line)
```bash
powershell -File scripts/run-nginx.ps1 start    # or: nginx -p nginx-1.31.1 -c nginx/sse.conf
curl -s -i -N http://127.0.0.1:4088/sse | head -1
# HTTP/1.1 502 Bad Gateway
grep 'duplicate header line' nginx-1.31.1/logs/error.log | tail -1
```
Full capture: [`evidence/3-nginx-502-error.log`](../evidence/3-nginx-502-error.log).

### Step 4 — the FIXED proxy resolves it (200 + stream)
```bash
# stop the naive proxy (Ctrl-C), then:
./scripts/run-proxy.sh fixed
curl -s -i -N http://127.0.0.1:4088/sse
# HTTP/1.1 200 OK
# Transfer-Encoding: chunked        <- single
# data: message 0 ... (stream flows)
```
Full capture: [`evidence/4-fixed-200-ok.txt`](../evidence/4-fixed-200-ok.txt).

## Reading the NGINX error line, field by field

```
upstream sent duplicate header line: "Transfer-Encoding: chunked",   <- the offending (2nd) header
        previous value: "transfer-encoding: chunked"                 <- Uvicorn's original (lowercase)
        while reading response header from upstream,                 <- it's a RESPONSE-side problem
        request: "GET /sse HTTP/1.1",                                <- only the streaming route
        upstream: "http://127.0.0.1:4001/sse"                        <- NGINX's real peer = the Java proxy
```

The `upstream:` field is the proof of which layer NGINX actually talked to. It is **4001 (the Java
proxy)**, not 4000 (Uvicorn).

## Non‑Windows / Docker

The Python app and Java proxies are OS‑agnostic. Only the nginx launch differs:

```bash
# Linux/macOS with system nginx:
nginx -p "$PWD/nginx-run" -c "$PWD/nginx/sse.conf"      # ensure nginx-run/logs exists

# or run nginx in Docker, pointing at the host proxy:
docker run --rm -p 4088:4088 \
  -v "$PWD/nginx/sse.conf:/etc/nginx/nginx.conf:ro" \
  --add-host host.docker.internal:host-gateway nginx:1.27
# (change proxy_pass to http://host.docker.internal:4001 for the container case)
```
Any nginx ≥ 1.23 reproduces the 502; the behavior is not Windows‑specific.

## Teardown
```bash
powershell -File scripts/run-nginx.ps1 stop
# Ctrl-C the Uvicorn and Java terminals
```
