import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * ============================ FIXED PROXY (the fix) ============================
 *
 * Identical to NaiveProxy.java EXCEPT for one thing: the header-forwarding loop
 * skips hop-by-hop headers (RFC 7230 6.1) -- most importantly `Transfer-Encoding`.
 *
 *   THE FIX (diff vs NaiveProxy):
 *     for (String[] h : up.headers) {
 *   +     if (HOP_BY_HOP.contains(h[0].toLowerCase(Locale.ROOT))) continue;  // don't forward hop-by-hop
 *         hdr.append(h[0]).append(": ").append(h[1]).append("\r\n");
 *     }
 *
 * Now only the server's OWN framing emits `Transfer-Encoding: chunked` -> ONE line
 * on the wire -> NGINX returns 200 and the SSE stream flows.
 *
 * Run (JDK 11+, no build tool needed):  java FixedProxy.java
 * Topology:  client -> [this proxy : 4002] -> Uvicorn/FastAPI : 4000
 */
public class FixedProxy {
    static final String UP_HOST = "127.0.0.1";
    static final int    UP_PORT = 4000;
    static final int    LISTEN  = 4002;

    // RFC 7230 6.1 hop-by-hop headers + length/framing headers a proxy must NOT copy verbatim.
    // A correct proxy strips these and applies its own framing for its own outbound hop.
    static final Set<String> HOP_BY_HOP = new HashSet<>(Arrays.asList(
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
        "te", "trailers", "transfer-encoding", "upgrade",
        "content-length"));   // re-streamed body -> let our server set framing

    public static void main(String[] a) throws Exception {
        ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        ss.bind(new InetSocketAddress("127.0.0.1", LISTEN));
        System.out.println("[FIXED] listening 127.0.0.1:" + LISTEN
            + " -> upstream " + UP_HOST + ":" + UP_PORT + "   (strips hop-by-hop -- CORRECT)");
        while (true) { Socket c = ss.accept(); new Thread(() -> serve(c)).start(); }
    }

    static void serve(Socket client) {
        try (Socket cl = client) {
            InputStream cin = new BufferedInputStream(cl.getInputStream());
            String reqLine = readLine(cin);
            if (reqLine == null) return;
            String[] rl = reqLine.split(" ");
            String method = rl[0], path = rl[1];
            while (true) { String h = readLine(cin); if (h == null || h.isEmpty()) break; } // drain request headers

            Up up = fetch(method, path);

            int teCopied = 0;
            StringBuilder hdr = new StringBuilder("HTTP/1.1 " + up.status + " OK\r\n");

            // (1) Forward upstream response headers -- but SKIP hop-by-hop headers.  <-- THE FIX
            for (String[] h : up.headers) {
                if (HOP_BY_HOP.contains(h[0].toLowerCase(Locale.ROOT))) continue;
                hdr.append(h[0]).append(": ").append(h[1]).append("\r\n");
            }
            // (2) The server's OWN chunked framing -- the only Transfer-Encoding now.
            hdr.append("Transfer-Encoding: chunked\r\n");
            hdr.append("Connection: close\r\n\r\n");

            System.out.println("[FIXED] copied-TE-from-upstream=" + teCopied
                + " + framing-TE=1  => Transfer-Encoding lines on wire=" + (teCopied + 1));

            OutputStream out = cl.getOutputStream();
            out.write(hdr.toString().getBytes(StandardCharsets.ISO_8859_1));
            byte[] body = up.body;
            out.write((Integer.toHexString(body.length) + "\r\n").getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.write("\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();
        } catch (Exception e) {
            System.out.println("[FIXED] " + e);
        }
    }

    // ----------------------- upstream fetch + helpers (identical to NaiveProxy) -----------------------

    static class Up { int status; List<String[]> headers = new ArrayList<>(); byte[] body; }

    static Up fetch(String method, String path) throws IOException {
        try (Socket sock = new Socket(UP_HOST, UP_PORT)) {
            OutputStream o = sock.getOutputStream();
            o.write((method + " " + path + " HTTP/1.1\r\nHost: " + UP_HOST + ":" + UP_PORT
                    + "\r\nAccept: text/event-stream\r\n\r\n").getBytes(StandardCharsets.US_ASCII));
            o.flush();
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
