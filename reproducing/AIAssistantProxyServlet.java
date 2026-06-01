import javax.servlet.http.HttpServlet;
import javax.servlet.http.HttpServletRequest;
import javax.servlet.http.HttpServletResponse;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.Locale;
import java.util.Set;

/**
 * Faithful, self-contained reproduction of ThingWorx's AIAssistantProxyServlet.
 *
 * The header-copy + streaming logic is identical to the production servlet; the
 * ThingWorx-only pieces (LogUtilities, AIAssistantSubsystem, assistantURL...) are
 * replaced with tiny stubs so this runs on a stock JDK + embedded Tomcat.
 *
 * Behavior is toggled by a system property so ONE build demonstrates both states:
 *   -DstripHopByHop=false  -> FAULTY: forwards Transfer-Encoding -> Tomcat emits a
 *                             second one -> nginx returns 502 "duplicate header line".
 *   -DstripHopByHop=true   -> FIXED : strips hop-by-hop headers -> single TE -> 200.
 *
 * NOTE: ThingWorx on Tomcat 10+ uses jakarta.servlet.*; swap the javax imports if so.
 */
public class AIAssistantProxyServlet extends HttpServlet {

    /**
     * Hop-by-hop headers (RFC 2616 §13.5.1) that the servlet container manages itself.
     * These must NOT be forwarded from the upstream response — doing so creates duplicates.
     * In particular, forwarding "transfer-encoding" causes Tomcat to emit a second
     * "Transfer-Encoding: chunked" header when flushing a streaming response, which
     * nginx rejects as invalid HTTP (RFC 7230 §3.3.1) and returns 502 Bad Gateway.
     */
    private static final Set<String> HOP_BY_HOP_HEADERS = Set.of(
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailer", "transfer-encoding", "upgrade", "content-length");

    // ---- stubs for ThingWorx internals (kept so the proxy logic reads like production) ----
    private static final SimpleLog _logger = new SimpleLog();
    private static final long REQUEST_TIMEOUT_MS = 30_000;                 // subsystem.getRequestTimeoutInMS()
    private static final String ASSISTANT_BASE = "http://127.0.0.1:4000";  // assistantURL (the Python app)
    private static final boolean STRIP_HOP_BY_HOP = Boolean.getBoolean("stripHopByHop");

    private final HttpClient httpClient =
        HttpClient.newBuilder().version(HttpClient.Version.HTTP_1_1).build();

    @Override protected void doGet(HttpServletRequest req, HttpServletResponse resp) throws IOException { proxy(req, resp); }
    @Override protected void doPost(HttpServletRequest req, HttpServletResponse resp) throws IOException { proxy(req, resp); }

    private void proxy(HttpServletRequest req, HttpServletResponse resp) throws IOException {
        String targetUri = ASSISTANT_BASE + req.getRequestURI()
            + (req.getQueryString() != null ? "?" + req.getQueryString() : "");
        try {
            HttpRequest.Builder requestBuilder = HttpRequest.newBuilder(URI.create(targetUri));

            String accept = req.getHeader("Accept");
            if (accept != null) requestBuilder.header("Accept", accept);
            // generate and set cookie header for request builder
            setCookieHeader(requestBuilder, req);

            if ("POST".equalsIgnoreCase(req.getMethod())) {
                requestBuilder.POST(HttpRequest.BodyPublishers.ofInputStream(() -> {
                    try { return req.getInputStream(); } catch (IOException e) { throw new RuntimeException(e); }
                }));
                String ct = req.getHeader("Content-Type");
                if (ct != null) requestBuilder.header("Content-Type", ct);
            } else {
                requestBuilder.GET();
            }

            // Skip timeout for streaming requests (SSE/ndjson) — they are long-lived connections
            if (!isStreamingRequest(req)) {
                requestBuilder.timeout(Duration.ofMillis(REQUEST_TIMEOUT_MS));
            }

            HttpRequest proxyRequest = requestBuilder.build();
            HttpResponse<InputStream> response =
                httpClient.send(proxyRequest, HttpResponse.BodyHandlers.ofInputStream());

            resp.setStatus(response.statusCode());

            // Copy response headers, excluding hop-by-hop headers that the
            // servlet container (Tomcat) manages itself. Forwarding "transfer-encoding"
            // from the upstream response causes a duplicate header which nginx
            // rejects with 502 Bad Gateway.
            response.headers().map().forEach((name, values) -> {
                if ("set-cookie".equalsIgnoreCase(name)) {
                    return;
                }
                // ---- THE FIX (gated so the demo can show both states) ----
                if (STRIP_HOP_BY_HOP && HOP_BY_HOP_HEADERS.contains(name.toLowerCase(Locale.ROOT))) {
                    return;
                }
                for (String value : values) {
                    resp.addHeader(name, value);
                    _logger.debug("Response header: {}={}", name, value);
                }
            });

            // Detect streaming from upstream response content-type (SSE or ndjson)
            String responseContentType = response.headers().firstValue("content-type")
                .map(s -> s.toLowerCase(Locale.ROOT)).orElse("");
            boolean isSseStream = responseContentType.contains("text/event-stream");
            boolean isNdjson = responseContentType.contains("application/x-ndjson");
            boolean isStreaming = isSseStream || isNdjson;

            // Instruct any reverse proxy (nginx, etc.) in front of ThingWorx to disable
            // response buffering. Must be set before the first write (before commit).
            if (isStreaming) {
                resp.setHeader("X-Accel-Buffering", "no");
            }

            // Copy response body
            try (InputStream in = response.body()) {
                if (in != null) {
                    OutputStream out = resp.getOutputStream();
                    if (isStreaming) {
                        // Read and flush promptly so complete events reach the client in
                        // real time without waiting for servlet output buffers to fill.
                        byte[] buffer = new byte[8192];
                        int len;
                        while ((len = in.read(buffer)) != -1) {
                            out.write(buffer, 0, len);
                            out.flush();
                        }
                    } else {
                        in.transferTo(out);
                    }
                    out.flush();
                }
            }
        } catch (Exception e) {
            _logger.error("Unable to proxy request: {} {}, error: {}", req.getMethod(), targetUri, e.getMessage());
            // If the response is already committed (always true once streaming has started
            // flushing), sendError() would throw "Cannot call sendError() after the response
            // has been committed". For streaming the connection is simply gone.
            if (!resp.isCommitted()) {
                resp.sendError(HttpServletResponse.SC_INTERNAL_SERVER_ERROR);
            }
        }
    }

    /**
     * Returns true if the incoming request explicitly accepts a streaming response,
     * detected exclusively via the Accept request header.
     */
    private static boolean isStreamingRequest(HttpServletRequest req) {
        String accept = req.getHeader("Accept");
        return accept != null &&
            (accept.contains("text/event-stream") || accept.contains("application/x-ndjson"));
    }

    private void setCookieHeader(HttpRequest.Builder requestBuilder, HttpServletRequest req) {
        String cookie = req.getHeader("Cookie");
        if (cookie != null && !cookie.isEmpty()) {
            requestBuilder.header("Cookie", cookie);
        }
    }

    /** Minimal SLF4J-style logger shim so the proxy code reads exactly like production. */
    static final class SimpleLog {
        void debug(String fmt, Object... args) { /* quiet */ }
        void error(String fmt, Object... args) { System.err.println("[servlet] " + fmt(fmt, args)); }
        private static String fmt(String f, Object... a) {
            StringBuilder sb = new StringBuilder(); int ai = 0;
            for (int i = 0; i < f.length(); i++) {
                if (i + 1 < f.length() && f.charAt(i) == '{' && f.charAt(i + 1) == '}') {
                    sb.append(ai < a.length ? String.valueOf(a[ai++]) : "{}"); i++;
                } else sb.append(f.charAt(i));
            }
            return sb.toString();
        }
    }
}
