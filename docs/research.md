# Research notes & citations

## What exactly emits the error

The message

```
upstream sent duplicate header line: "Transfer-Encoding: chunked", previous value: "..."
while reading response header from upstream
```

is produced by NGINX's **upstream response header parser** (`ngx_http_upstream_process_header` /
`ngx_http_upstream_process_transfer_encoding` in `ngx_http_upstream.c`). When a response carries a
second `Transfer-Encoding`, or `Transfer-Encoding` together with `Content-Length`, or a
`Transfer-Encoding` value other than `chunked`, NGINX aborts with **502** and logs this line. Because
it happens during upstream header parsing, it precedes content/header filters (and Lua), so it can't be
patched away downstream.

## NGINX Transfer‑Encoding hardening timeline

From the official changelog (`http://nginx.org/en/CHANGES`) and release history:

| Version | Date | Change |
|---|---|---|
| 1.17.9 | 2020‑03‑03 | nginx no longer **ignores** additional `Transfer-Encoding` request header lines |
| **1.21.1** | 2021‑07‑06 | always errors if both `Content-Length` **and** `Transfer-Encoding` are present (request); part of the request‑smuggling hardening that also tightened **upstream/response** `Transfer-Encoding` handling |
| 1.21.2 | 2021‑08‑31 | rejects HTTP/1.0 requests carrying `Transfer-Encoding` |
| 1.23.0 | 2022‑06‑21 | response header handling reworked (header lines as linked lists; combining duplicates) — the release around which many users first observed stricter upstream behavior |
| 1.25.3 | 2023 | bundled by **ingress‑nginx controller 1.10.0** — where most Kubernetes users first hit the duplicate‑TE **502** |
| 1.29.4 | 2025‑12‑09 | a lone `LF` in a chunked request/response body is an error |
| 1.31.0 | 2026‑05‑13 | rejects HTTP/2 & HTTP/3 requests with `Transfer-Encoding`/`Connection`/`Upgrade`/`TE≠trailers` |
| **1.31.1** | — | **verified in this repo**: duplicate response TE → 502 |

Note: the changelog itemizes the **request‑side** changes; rejection of an invalid/duplicate
`Transfer-Encoding` in an **upstream response** lives in the upstream module and is present in all
current releases (confirmed live here on 1.31.1). Community reports cluster the first‑hit at
nginx ≥ 1.23 and at ingress‑nginx ≥ 1.10.0 (nginx 1.25.3).

## The relevant RFC rules

- **RFC 7230 §3.3.1** — `Transfer-Encoding` is a property of the *message*, not the representation; any
  recipient may decode/re‑encode it provided it updates the field. (⇒ it's per‑hop.)
- **RFC 7230 §6.1** — proxies **MUST** remove hop‑by‑hop headers (`Connection` and everything it lists,
  plus `Transfer-Encoding`, `TE`, `Keep-Alive`, `Upgrade`, …) before forwarding.
- **RFC 7230 §3.3.3** — a message with both `Content-Length` and `Transfer-Encoding` must be treated as
  potentially smuggled; recipients reject or sanitize it.

## Why the strictness exists — request smuggling

Duplicated/ambiguous framing headers are the raw material of **HTTP request smuggling** (CL.TE / TE.TE
desync). After the 2019–2021 research wave, servers and proxies stopped tolerating ambiguity:
Go's `net/http` dropped `Transfer-Encoding: identity` and got strict (Go 1.15), Envoy and Apache
Traffic Server treat `Transfer-Encoding` as hop‑by‑hop, and NGINX rejects malformed framing outright.
Hence: no opt‑out, and the only correct fix is to stop the proxy from producing the malformed response.

## Sources

- **RFC 7230** (HTTP/1.1 message syntax & routing; §3.3.1 Transfer‑Encoding, §6.1 hop‑by‑hop) —
  https://tools.ietf.org/html/rfc7230
- **mnot — "What Proxies Must Do"** (proxies MUST remove hop‑by‑hop headers) —
  https://www.mnot.net/blog/2011/07/11/what_proxies_must_do
- **kubernetes/ingress‑nginx #11162** — controller 1.10.0 / nginx 1.25.3 returns 502 on duplicate TE;
  no suppression setting; fix the upstream —
  https://github.com/kubernetes/ingress-nginx/issues/11162
- **spring‑projects/spring‑boot #37646** — duplicate `Transfer-Encoding: chunked`; closed as
  external/proxy‑layer (not Spring Boot core) —
  https://github.com/spring-projects/spring-boot/issues/37646
- **"The Case of Duplicate Transfer‑Encoding Header"** (Furkan Yaman) — a proxy/gateway copying the
  hop‑by‑hop header is the cause; it must not be copied —
  https://medium.com/@furkanyaman319/an-unexpected-bug-the-case-of-duplicate-transfer-encoding-header-86604ff56421
- **Apache Traffic Server PR #6908** — handling `Transfer-Encoding` as a hop‑by‑hop header —
  https://github.com/apache/trafficserver/pull/6908
- **"Fixing the NGINX Error: upstream sent duplicate header line"** (T3CH) — version context & fix
  direction — https://medium.com/h7w/fixing-the-nginx-error-upstream-sent-duplicate-header-line-transfer-encoding-chunked-a66d73b21927
- **nginx CHANGES** — request‑side `Transfer-Encoding` hardening (1.17.9, 1.21.1, 1.21.2, …) —
  http://nginx.org/en/CHANGES
- Related community reports: honojs/hono #4273 (streamSSE behind nginx), trpc/trpc #6909
  (duplicate TE, also rejected by Traefik and Caddy), freenginx #14 (avoiding duplicate TE in upstream).
