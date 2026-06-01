# Root cause — in detail

## 1. HTTP/1.1 body framing: two ways to delimit a response body

An HTTP/1.1 response body must be delimited so the recipient knows where it ends. There are two
mechanisms, and they are **mutually exclusive**:

- **`Content-Length: N`** — the body is exactly `N` bytes. Used when the size is known up front
  (a JSON document, a file).
- **`Transfer-Encoding: chunked`** — the body is sent as a series of size‑prefixed chunks ending
  with a zero‑size chunk. Used when the size is **not** known up front — i.e. **streaming**, such as SSE.

An SSE response is open‑ended, so there is no `Content-Length`; the HTTP/1.1 server frames it as
`chunked`. That is correct and unavoidable.

```
$ curl -D - http://uvicorn/sse
content-type: text/event-stream; charset=utf-8
transfer-encoding: chunked          # exactly one — added by Uvicorn, correct
```

## 2. End‑to‑end vs hop‑by‑hop headers

RFC 7230 splits headers into two classes:

- **End‑to‑end** headers describe the *message/representation* and must be forwarded unchanged by
  proxies (`Content-Type`, `Cache-Control`, `Content-Length`…).
- **Hop‑by‑hop** headers describe *this single transport connection only* and **must be removed by a
  proxy before forwarding** (RFC 7230 §6.1):

  > `Connection`, `Keep-Alive`, `Proxy-Authenticate`, `Proxy-Authorization`, `TE`, `Trailers`,
  > `Transfer-Encoding`, `Upgrade`.

`Transfer-Encoding` is explicitly hop‑by‑hop. RFC 7230 §3.3.1 says it plainly:

> *Transfer-Encoding is a property of the message, not of the representation … A recipient MAY decode
> the received transfer coding … or apply additional transfer coding(s) … assuming that corresponding
> changes are made to the Transfer-Encoding field‑value.*

Translation: each hop decides its own body framing. A proxy that **copies** the upstream's
`Transfer-Encoding` to the next hop is violating the spec, because it has no control over how the
*next* connection's body is framed.

## 3. The two contributors to the duplicate

When the faulty proxy returns the SSE response, **two independent code paths** each emit a
`Transfer-Encoding: chunked`:

1. **Header forwarding** — the proxy copies *every* upstream response header to the client, including
   Uvicorn's hop‑by‑hop `Transfer-Encoding: chunked`. **This is the bug.**
2. **Server framing** — the proxy streams a body of unknown length, so its own HTTP server
   (Tomcat / Jetty / Netty) frames it as chunked and adds *another* `Transfer-Encoding: chunked`.
   This part is correct on its own.

```
[NAIVE] copied-TE-from-upstream=1 + framing-TE=1  => Transfer-Encoding lines on wire=2
[FIXED] copied-TE-from-upstream=0 + framing-TE=1  => Transfer-Encoding lines on wire=1
```

The body itself is chunked **once** (valid); only the **header** is duplicated — which is exactly why
NGINX complains about a *header*, not about the body.

## 4. Why only the SSE endpoint breaks

A normal JSON endpoint returns a fixed‑length body, so Uvicorn sends `Content-Length` and **no**
`Transfer-Encoding`. There is no hop‑by‑hop framing header for the proxy to copy, so path (1) above
contributes nothing and there is no duplicate. Only the streaming SSE route carries a
`Transfer-Encoding` header in the first place. (See `evidence/1-uvicorn-direct.txt`: `/plain` has
`content-length: 11` and no TE; `/sse` has one TE and no length.)

## 5. Why NGINX seems to blame Uvicorn
<a id="why-nginx-seems-to-blame-uvicorn"></a>

The error log reads:

```
upstream sent duplicate header line: "Transfer-Encoding: chunked",
        previous value: "transfer-encoding: chunked"
        ... request: "GET /sse HTTP/1.1", upstream: "http://127.0.0.1:4001/sse"
```

Three things make people wrongly blame the Python app:

1. **The `previous value` is literally Uvicorn's header.** Uvicorn emits **lowercase** header names
   (`transfer-encoding`). NGINX quotes that as the "previous" value; the **duplicate** (often a
   different casing, `Transfer-Encoding`) is the one the Java server added. So Uvicorn's text appears
   in the error even though Uvicorn only ever sent one header.
2. **The faulty proxy forwards `Server: uvicorn`.** Inspecting the response (or
   `$upstream_http_server`) shows `uvicorn`, making it look like the response came straight from Python.
3. **But `upstream:` tells the truth.** That field is the address NGINX actually connected to —
   `http://127.0.0.1:4001/sse`, the **Java proxy** (port 4001), not Uvicorn (port 4000).

Decisive test: `curl` Uvicorn directly → **one** TE; `curl` the Java proxy directly → **two** TE. The
duplication appears only across the Java hop.

## 6. Nuance: not every server emits the duplicate

The JDK's own `com.sun.net.httpserver.HttpServer` happens to **de‑duplicate**: if you copy the
upstream `Transfer-Encoding` *and* it frames the body as chunked, it still emits a single header.
`java-proxy/HttpServerProxy.java` demonstrates this. But the servers real Java proxies actually run on
— **Tomcat, Jetty, Netty** — do **not** dedup; they emit both, which is what the public bug reports
([Spring Boot #37646], [ingress‑nginx #11162]) describe. `NaiveProxy.java` reproduces that
non‑deduping wire output deterministically. The lesson is the same either way: **copying the
hop‑by‑hop `Transfer-Encoding` is wrong**; whether it visibly duplicates just depends on the server.

## 7. Bonus failure mode: `Content-Length` *and* `Transfer-Encoding` together

During reproduction, a request to `/` (a fixed‑length 404 that the proxy *also* chunk‑framed) produced
a second, related NGINX rejection:

```
upstream sent "Content-Length" and "Transfer-Encoding" headers at the same time
```

Same root cause — a proxy mismanaging framing headers — but a different RFC rule (a message must not
carry both). Real frameworks only add chunked framing when there is no `Content-Length`, so this one
doesn't usually occur in production; it's an artifact of the minimal proxy. Stripping hop‑by‑hop
headers (and not force‑chunking a fixed‑length body) fixes both.

## 8. Why NGINX is so strict — HTTP request/response smuggling

This is not NGINX being fussy. Ambiguous or duplicated framing headers (`Content-Length` vs
`Transfer-Encoding`, or two `Transfer-Encoding` lines) are the basis of **HTTP request smuggling**:
two servers in a chain disagree about where one message ends and the next begins, letting an attacker
sneak a second request past a front‑end. Since the 2019–2021 wave of smuggling research, NGINX, Go's
`net/http`, Envoy, Apache Traffic Server and others tightened up and now **reject** such messages
instead of guessing. That is why there is no "just allow it" switch — see
[docs/research.md](research.md).

[Spring Boot #37646]: https://github.com/spring-projects/spring-boot/issues/37646
[ingress‑nginx #11162]: https://github.com/kubernetes/ingress-nginx/issues/11162
