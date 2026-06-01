#!/usr/bin/env bash
# Start the Java proxy.  Usage: run-proxy.sh [naive|fixed]
# naive -> :4001 (faulty, copies hop-by-hop headers)
# fixed -> :4002 (correct, strips hop-by-hop headers)
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
mode="${1:-naive}"
case "$mode" in
  naive) echo "[run-proxy] FAULTY (copies hop-by-hop Transfer-Encoding) -> :4001"; exec java java-proxy/NaiveProxy.java ;;
  fixed) echo "[run-proxy] FIXED (strips hop-by-hop headers) -> :4002";            exec java java-proxy/FixedProxy.java ;;
  *) echo "usage: $0 [naive|fixed]" >&2; exit 2 ;;
esac
