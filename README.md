# Duplicate `Transfer-Encoding: chunked` on an SSE endpoint — reproduced, isolated, and fixed

A minimal, runnable reproduction of the production error

```
nginx: upstream sent duplicate header line: "Transfer-Encoding: chunked",
       previous value: "transfer-encoding: chunked" while reading response header from upstream
```

…for the stack **NGINX → Java proxy → FastAPI/Uvicorn (SSE)**, with the faulty code, the
one‑line fix, captured evidence, and the research behind it.

---

## Verdict

> **The Java proxy creates the duplicate. NGINX only reports it. Uvicorn/FastAPI is innocent.**

`Transfer-Encoding` is a **hop‑by‑hop** header (RFC 7230 §6.1). A proxy must **not** forward it.
The faulty proxy forwards Uvicorn's `Transfer-Encoding: chunked` **and** its own server adds another
when it streams the body → **two** header lines → modern NGINX returns **502**.

```
            ┌──────────┐        ┌──────────────────┐        ┌──────────────────┐
 client ───▶│  NGINX   │ ─────▶ │   Java proxy     │ ─────▶ │  FastAPI/Uvicorn │
            │  :8088   │        │   :8080          │        │  :8000  (SSE)    │
            └──────────┘        └──────────────────┘        └──────────────────┘
                 ▲                       │                          │
                 │                       │ (1) copies upstream      │ sends ONE
   502 + "duplicate header line"         │     Transfer-Encoding ───┘ Transfer-Encoding
   ◀─────────────┘                       │ (2) adds its OWN framing Transfer-Encoding
                                         ▼
                              TWO Transfer-Encoding: chunked  ✗
```

## The fix (TL;DR)

In the Java proxy, **stop forwarding the `Transfer-Encoding` header** (ideally all hop‑by‑hop headers).
The entire diff between the broken and fixed proxy in this repo is:

```diff
  for (String[] h : up.headers) {
+     // RFC 7230 §6.1: never forward hop-by-hop headers (Transfer-Encoding, Connection, ...)
+     if (HOP_BY_HOP.contains(h[0].toLowerCase(Locale.ROOT))) continue;
      hdr.append(h[0]).append(": ").append(h[1]).append("\r\n");
  }
  hdr.append("Transfer-Encoding: chunked\r\n");   // the server's own framing — the only one we want
```

Nothing changes in Python. Framework‑specific patches (Spring MVC/servlet, `WebClient`/`RestTemplate`,
Spring Cloud Gateway, Zuul, Reactor Netty, Apache HttpClient) are in **[docs/the-fix.md](docs/the-fix.md)**.

## Evidence (captured live on nginx 1.31.1, JDK 21, Python 3.13 — see [`evidence/`](evidence/))

| # | Hop | `Transfer-Encoding` lines | Result |
|---|-----|---------------------------|--------|
| [1](evidence/1-uvicorn-direct.txt) | Uvicorn `/sse` direct (httptools **and** h11) | **1** | ✅ correct |
| [2](evidence/2-naive-proxy-2x-te.txt) | through **NaiveProxy** | **2** | ❌ the bug |
| [3](evidence/3-nginx-502-error.log) | NGINX → NaiveProxy | — | **502** + `duplicate header line` |
| [4](evidence/4-fixed-200-ok.txt) | NGINX → **FixedProxy** | **1** | ✅ **200**, SSE streams |

The proxy logs its own accounting ([evidence 5](evidence/5-proxy-accounting.txt)):

```
[NAIVE] copied-TE-from-upstream=1 + framing-TE=1  => Transfer-Encoding lines on wire=2
[FIXED] copied-TE-from-upstream=0 + framing-TE=1  => Transfer-Encoding lines on wire=1
```

## Repository layout

```
.
├── README.md                  ← you are here
├── python-app/
│   ├── app.py                 FastAPI SSE app (correct; never sets Transfer-Encoding)
│   └── requirements.txt
├── java-proxy/
│   ├── NaiveProxy.java        ❌ FAULTY  — copies all headers (reproduces the duplicate)
│   ├── FixedProxy.java        ✅ FIXED   — strips hop-by-hop headers (the one-block diff)
│   └── HttpServerProxy.java   realistic JDK variant + the "HttpServer de-dups" nuance
├── nginx/
│   └── sse.conf               NGINX front door (:8088 → :8080)
├── evidence/                  captured outputs (1–5) proving each step
├── scripts/
│   ├── setup.sh               venv + deps + download nginx
│   ├── run-uvicorn.sh / run-proxy.sh [naive|fixed] / run-nginx.ps1 [start|stop]
│   └── reproduce.sh           one-command end-to-end PASS/FAIL
└── docs/
    ├── root-cause.md          the deep technical explanation
    ├── reproduction.md        step-by-step with expected output
    ├── the-fix.md             the fix + per-framework patches + why-not-nginx/uvicorn
    └── research.md            citations, nginx version history, request-smuggling background
```

## Quickstart

Prereqs: **JDK 11+** (tested on 21), **Python 3.x** (tested on 3.13), **curl**, and either Windows
(PowerShell, for the bundled native nginx) or any nginx ≥ 1.23.

```bash
./scripts/setup.sh        # one time: venv + deps + download nginx 1.31.1
./scripts/reproduce.sh    # starts the full chain and prints PASS
```

Expected tail:

```
PASS  uvicorn=1 TE | naive=2 TE -> nginx 502 | fixed=1 TE -> nginx 200
```

Or drive it by hand — see **[docs/reproduction.md](docs/reproduction.md)**.

## Why only the SSE endpoint?

Non‑streaming routes return a fixed‑length body → `Content-Length`, **no** `Transfer-Encoding`, so there
is nothing for the proxy to duplicate. Only the streaming SSE response is sent chunked, so only it carries
a `Transfer-Encoding` header for the proxy to (wrongly) copy. See **[docs/root-cause.md](docs/root-cause.md)**.

## "But the NGINX error mentions Uvicorn!"

A red herring. The lowercase `previous value: "transfer-encoding: chunked"` is literally Uvicorn's header
(Uvicorn writes lowercase names), and the faulty proxy also forwards `Server: uvicorn`. NGINX's real peer
is the **Java proxy** — see the `upstream: "http://127.0.0.1:8080/sse"` field in
[evidence 3](evidence/3-nginx-502-error.log). Full explanation in
**[docs/root-cause.md](docs/root-cause.md#why-nginx-seems-to-blame-uvicorn)**.

## License / use

Educational reproduction built to diagnose and fix the duplicate `Transfer-Encoding` bug on an SSE
stream behind a chained proxy. Use freely; add your preferred license before publishing.
