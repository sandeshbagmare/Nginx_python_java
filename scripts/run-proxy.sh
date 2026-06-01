#!/usr/bin/env bash
# Start the Java proxy on 127.0.0.1:8080.  Usage: run-proxy.sh [naive|fixed]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mode="${1:-naive}"
case "$mode" in
  naive) echo "[run-proxy] FAULTY (copies hop-by-hop Transfer-Encoding)"; exec java java-proxy/NaiveProxy.java ;;
  fixed) echo "[run-proxy] FIXED (strips hop-by-hop headers)";            exec java java-proxy/FixedProxy.java ;;
  *) echo "usage: $0 [naive|fixed]" >&2; exit 2 ;;
esac
