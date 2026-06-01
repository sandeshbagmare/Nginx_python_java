# `reproducing/` — faithful repro on a REAL Tomcat, using your servlet's logic

This folder reproduces the duplicate‑`Transfer-Encoding` 502 **and** cures it, on an actual
**embedded Apache Tomcat** running a faithful copy of your `AIAssistantProxyServlet`
(`java.net.http.HttpClient` upstream + servlet response copy + SSE flushing). Unlike the JDK's
`com.sun.net.httpserver.HttpServer` (which silently de‑dups), Tomcat behaves exactly like your
production container — so the bug and the fix both show up for real.

```
client ──▶ NGINX :8088 ──▶ Tomcat + AIAssistantProxyServlet :8080 ──▶ Uvicorn/FastAPI :8000 (SSE)
```

## Run it

```bash
# from this folder (reuses ../.venv and ../nginx-1.31.1; run ../scripts/setup.sh once if missing)
./run.sh
```

`run.sh` downloads embedded Tomcat (first run), compiles the servlet, starts Uvicorn + Tomcat +
NGINX, then runs **two phases** against the same NGINX and tears everything down.

### Proven output (captured on Tomcat 9.0.118 + nginx 1.31.1)

```
################ PHASE 1 — FAULTY servlet (stripHopByHop=false) ################
  servlet direct :8080   Transfer-Encoding count = 2   (expect 2)
  via NGINX :8088        HTTP 502                          (expect 502)
  nginx error.log      : *1 upstream sent duplicate header line: "Transfer-Encoding: chunked",
                         previous value: "transfer-encoding: chunked" ... upstream: "http://127.0.0.1:8080/sse"

################ PHASE 2 — FIXED servlet (stripHopByHop=true) ################
  servlet direct :8080   Transfer-Encoding count = 1   (expect 1)
  via NGINX :8088        HTTP 200                          (expect 200)
  stream via NGINX:
      data: message 0
      data: message 1
      data: message 2

PASS  faulty -> 502 (duplicate Transfer-Encoding) ; fixed -> 200 (single TE, SSE streams)
```

## Where the bug and the fix live

Both states are the **same servlet**, toggled by a system property so you can see cause and cure:

| Mode | Flag | Header‑copy behavior | Result |
|------|------|----------------------|--------|
| FAULTY | `-DstripHopByHop=false` | forwards upstream `Transfer-Encoding` | Tomcat adds a 2nd → **502** |
| FIXED  | `-DstripHopByHop=true`  | skips hop‑by‑hop headers | single TE → **200** |

The decisive lines in `AIAssistantProxyServlet.java`:

```java
response.headers().map().forEach((name, values) -> {
    if ("set-cookie".equalsIgnoreCase(name)) return;
    // THE FIX: never forward hop-by-hop headers (Transfer-Encoding is the one that bites).
    if (STRIP_HOP_BY_HOP && HOP_BY_HOP_HEADERS.contains(name.toLowerCase(Locale.ROOT))) return;
    for (String value : values) resp.addHeader(name, value);
});
```

In your production servlet you simply keep the `HOP_BY_HOP_HEADERS.contains(...)` skip
**always on** (no flag) — that is the entire fix.

## Mapping this to your real `AIAssistantProxyServlet`

- The stubs here (`SimpleLog _logger`, `REQUEST_TIMEOUT_MS`, `ASSISTANT_BASE`, `setCookieHeader`)
  stand in for `LogUtilities`, `subsystem.getRequestTimeoutInMS()`, `assistantURL`, and your real
  cookie logic. **Delete the stubs and keep your originals** — the header/body code is unchanged.
- **`javax.servlet` vs `jakarta.servlet`:** this repro targets Tomcat 9 (javax). If your ThingWorx
  runs on Tomcat 10+, change the three `javax.servlet.*` imports to `jakarta.servlet.*`.
- Use `name.toLowerCase(Locale.ROOT)` (not the default locale) — see `../docs/the-fix.md`.

## Files
```
AIAssistantProxyServlet.java   faithful servlet; STRIP_HOP_BY_HOP gates faulty/fixed
EmbeddedProxy.java             boots embedded Tomcat, mounts the servlet at /*
app.py                         FastAPI SSE upstream (correct; one Transfer-Encoding)
sse.conf                       NGINX :8088 -> servlet :8080
run-nginx.ps1                  start/stop nginx (reuses ../nginx-1.31.1)
run.sh                         downloads Tomcat, compiles, runs both phases, prints PASS
lib/  out/                     downloaded jars + compiled classes (git-ignored)
```
