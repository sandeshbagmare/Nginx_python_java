import com.sun.net.httpserver.*;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;
import java.util.concurrent.Executors;

/**
 * ===================== REALISTIC VARIANT (instructive nuance) =====================
 *
 * A proxy built on the JDK's own `com.sun.net.httpserver.HttpServer`. It fetches the
 * upstream response and (in NAIVE mode) copies every header, then streams the body --
 * the HttpServer applies chunked framing via sendResponseHeaders(status, 0).
 *
 * FINDING: the JDK HttpServer happens to DE-DUPLICATE the Transfer-Encoding header
 *          (copied + framing collapse to a single line), so this particular server
 *          does NOT reproduce the duplicate. Tomcat / Jetty / Netty -- the servers real
 *          Java proxies actually run on -- do NOT dedup; they emit both. NaiveProxy.java
 *          reproduces their wire output deterministically.
 *
 * The lesson is the same either way: copying the hop-by-hop Transfer-Encoding header
 * is incorrect; whether it manifests as a duplicate depends on the downstream server.
 *
 * Run:  MODE=naive java HttpServerProxy.java       (or MODE=fixed)
 */
public class HttpServerProxy {
    static final String UP_HOST = "127.0.0.1";
    static final int    UP_PORT = 4000;

    static final Set<String> HOP_BY_HOP = new HashSet<>(Arrays.asList(
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade", "content-length"));

    static boolean FIXED;

    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(env("PROXY_PORT", "4003"));
        FIXED = "fixed".equalsIgnoreCase(env("MODE", "naive"));
        HttpServer s = HttpServer.create(new InetSocketAddress("127.0.0.1", port), 0);
        s.createContext("/", HttpServerProxy::handle);
        s.setExecutor(Executors.newCachedThreadPool());
        s.start();
        System.out.println("[HttpServerProxy] listening 127.0.0.1:" + port
            + "  MODE=" + (FIXED ? "FIXED" : "NAIVE") + "  (note: JDK HttpServer de-dups TE)");
    }

    static String env(String k, String d) { String v = System.getenv(k); return v == null ? d : v; }

    static void handle(HttpExchange ex) {
        try {
            Up up = fetch(ex.getRequestMethod(), raw(ex.getRequestURI()));
            Headers out = ex.getResponseHeaders();
            for (String[] h : up.headers) {
                if (FIXED && HOP_BY_HOP.contains(h[0].toLowerCase(Locale.ROOT))) continue;
                out.add(h[0], h[1]);
            }
            ex.sendResponseHeaders(up.status, 0); // 0 => HttpServer frames body as chunked
            try (OutputStream b = ex.getResponseBody()) { b.write(up.body); }
        } catch (Exception e) {
            e.printStackTrace();
            try { ex.sendResponseHeaders(502, -1); } catch (IOException ignore) {}
        } finally {
            ex.close();
        }
    }

    static String raw(URI u) { return u.getRawQuery() == null ? u.getRawPath() : u.getRawPath() + "?" + u.getRawQuery(); }

    static class Up { int status; List<String[]> headers = new ArrayList<>(); byte[] body; }

    static Up fetch(String method, String path) throws IOException {
        try (Socket sock = new Socket(UP_HOST, UP_PORT)) {
            sock.getOutputStream().write((method + " " + path + " HTTP/1.1\r\nHost: " + UP_HOST + ":" + UP_PORT
                    + "\r\nAccept: text/event-stream\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            sock.getOutputStream().flush();
            InputStream in = new BufferedInputStream(sock.getInputStream());
            Up up = new Up();
            up.status = Integer.parseInt(readLine(in).split(" ")[1]);
            boolean chunked = false; int cl = -1; String line;
            while ((line = readLine(in)) != null && !line.isEmpty()) {
                int c = line.indexOf(':');
                String name = line.substring(0, c).trim(), val = line.substring(c + 1).trim();
                up.headers.add(new String[]{name, val});
                if (name.equalsIgnoreCase("transfer-encoding") && val.toLowerCase(Locale.ROOT).contains("chunked")) chunked = true;
                if (name.equalsIgnoreCase("content-length")) cl = Integer.parseInt(val);
            }
            ByteArrayOutputStream body = new ByteArrayOutputStream();
            if (chunked) {
                while (true) {
                    String s = readLine(in); int semi = s.indexOf(';'); if (semi >= 0) s = s.substring(0, semi);
                    int size = Integer.parseInt(s.trim(), 16);
                    if (size == 0) { String t; while ((t = readLine(in)) != null && !t.isEmpty()) {} break; }
                    body.write(readN(in, size)); readN(in, 2);
                }
            } else if (cl >= 0) { body.write(readN(in, cl)); }
            else { int b; while ((b = in.read()) != -1) body.write(b); }
            up.body = body.toByteArray();
            return up;
        }
    }

    static String readLine(InputStream in) throws IOException {
        ByteArrayOutputStream b = new ByteArrayOutputStream();
        int prev = -1, c;
        while ((c = in.read()) != -1) {
            if (prev == '\r' && c == '\n') { byte[] a = b.toByteArray(); return new String(a, 0, a.length - 1, StandardCharsets.ISO_8859_1); }
            b.write(c); prev = c;
        }
        return b.size() == 0 ? null : new String(b.toByteArray(), StandardCharsets.ISO_8859_1);
    }

    static byte[] readN(InputStream in, int n) throws IOException {
        byte[] buf = new byte[n]; int off = 0;
        while (off < n) { int r = in.read(buf, off, n - off); if (r < 0) throw new EOFException(); off += r; }
        return buf;
    }
}
