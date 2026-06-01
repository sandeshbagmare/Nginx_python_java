# The fix — and why this layer

## Principle

`Transfer-Encoding` is **hop‑by‑hop** (RFC 7230 §6.1). A proxy must **strip** hop‑by‑hop headers from
the upstream response and apply its **own** framing for its own outbound connection. The proxy is the
only layer that can fix this correctly, because it is the layer that (a) violates the spec by copying
the header and (b) physically emits the second copy.

Canonical set to strip when forwarding a response (and a request):

```
Connection, Keep-Alive, Proxy-Authenticate, Proxy-Authorization,
TE, Trailers, Transfer-Encoding, Upgrade
```

Also do **not** copy `Content-Length` when you re‑stream the body — let your outbound server set
framing. And strip whatever is named in the upstream `Connection` header.

## The minimal diff in this repo

`NaiveProxy.java` → `FixedProxy.java` is a single block:

```diff
+ static final Set<String> HOP_BY_HOP = Set.of(
+     "connection","keep-alive","proxy-authenticate","proxy-authorization",
+     "te","trailers","transfer-encoding","upgrade","content-length");

  for (String[] h : up.headers) {
+     if (HOP_BY_HOP.contains(h[0].toLowerCase(Locale.ROOT))) continue;   // <-- the fix
      hdr.append(h[0]).append(": ").append(h[1]).append("\r\n");
  }
  hdr.append("Transfer-Encoding: chunked\r\n");   // server's own framing — the only TE we want
```

## Framework‑specific patches

Pick the one that matches your proxy.

### A. Hand‑rolled servlet / `HttpServletResponse` copy (most common cause of this exact bug)
```java
private static final Set<String> HOP_BY_HOP = Set.of(
    "connection","keep-alive","proxy-authenticate","proxy-authorization",
    "te","trailers","transfer-encoding","upgrade","content-length");

// copying upstream (java.net.http.HttpResponse) headers to the servlet response:
upstream.headers().map().forEach((name, values) -> {
    if (!HOP_BY_HOP.contains(name.toLowerCase(Locale.ROOT)))
        values.forEach(v -> servletResponse.addHeader(name, v));
});
// then stream the body; let the container chunk it (do NOT setHeader("Transfer-Encoding", ...))
```

### B. Spring MVC + `RestTemplate` / `WebClient` returning a `ResponseEntity`
Don't rebuild the `ResponseEntity` from the upstream headers wholesale:
```java
HttpHeaders out = new HttpHeaders();
upstream.getHeaders().forEach((k, v) -> {
    if (!HOP_BY_HOP.contains(k.toLowerCase(Locale.ROOT))) out.put(k, v);
});
return new ResponseEntity<>(upstream.getBody(), out, upstream.getStatusCode());
// or simply: out.remove(HttpHeaders.TRANSFER_ENCODING);
//            out.remove(HttpHeaders.CONTENT_LENGTH);
//            out.remove(HttpHeaders.CONNECTION);
```

### C. Spring Cloud Gateway
Gateway strips standard hop‑by‑hop headers by default, so if you see the duplicate, a **custom response
filter** is almost certainly re‑adding/copying it. Remove it there:
```java
@Bean
GlobalFilter stripTransferEncoding() {
    return (exchange, chain) -> chain.filter(exchange).then(Mono.fromRunnable(() ->
        exchange.getResponse().getHeaders().remove(HttpHeaders.TRANSFER_ENCODING)));
}
```
Audit any `setResponseHeaders` / `addAll(upstreamHeaders)` you added.

### D. Netflix Zuul 1 (Spring Cloud Netflix)
Zuul's routing filters exclude `Transfer-Encoding` by default. If you customized `ProxyResponseFilter`
/ `SimpleHostRoutingFilter` or copy origin headers yourself, preserve that exclusion (keep
`transfer-encoding` out of the forwarded set). The principle in (A) applies.

### E. Reactor Netty / raw Netty
Never set the header yourself *and* forward the upstream one. Let Netty manage a single header:
```java
HttpUtil.setTransferEncodingChunked(response, true);   // Netty emits exactly one TE
// or set a real Content-Length — but never both, and never two TE lines
```

### F. Apache HttpClient–based proxy
HttpClient 4.x/5.x usually de‑chunks and may drop `Transfer-Encoding` from `getAllHeaders()`, but don't
rely on it — apply the `HOP_BY_HOP` filter from (A) when copying headers onward.

## Why NOT fix it at NGINX

- **There is no directive to accept a duplicate `Transfer-Encoding`.** The ingress‑nginx maintainers
  state it directly: *"There is no setting in ingress‑nginx that suppresses this behaviour."* The
  rejection is deliberate request‑smuggling defense.
- **You can't strip it with Lua either.** NGINX validates the upstream response headers in its upstream
  parser and generates the 502 *before* `header_filter_by_lua` runs, so a Lua header filter never gets
  the chance.
- **`chunked_transfer_encoding off;` does not help** — it controls NGINX's *own* client‑facing chunked
  framing, not how it parses the upstream response.
- **Buffering is irrelevant** — `proxy_buffering on|off` changes nothing; this is a header‑parsing
  rejection, not a buffering issue.

Fixing it at NGINX would also be wrong in principle: the response on the wire is genuinely malformed.

## Why NOT fix it at Uvicorn/FastAPI

Uvicorn already emits exactly **one** `Transfer-Encoding` and you correctly never set it — the ASGI
server owns body framing. There is nothing to change, and you can't give an open‑ended stream a
`Content-Length`. The Python layer is spec‑correct.

## Verify the fix
```bash
# through the proxy directly: expect 1
curl -s -D - -N -o /dev/null http://<proxy>/sse | grep -ci '^Transfer-Encoding:'
# end-to-end through nginx: expect 200 and a flowing stream
curl -s -i -N http://<nginx>/sse | head -1
```
