import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * ============================ FAULTY PROXY (the bug) ============================
 *
 * Topology:  client -> [this proxy : 8080] -> Uvicorn/FastAPI : 8000
 *
 * This models a Java proxy running on a NON-deduplicating HTTP server
 * (Tomcat / Jetty / Netty -- i.e. Spring MVC, Zuul, Spring Cloud Gateway, or a
 * hand-rolled servlet proxy). It makes the TWO independent contributions to the
 * response framing explicit:
 *
 *   (1) HEADER-FORWARDING LOOP  -> copies EVERY upstream header verbatim,
 *                                  including Uvicorn's hop-by-hop
 *                                  `Transfer-Encoding: chunked`.            <-- THE BUG
 *   (2) THE SERVER FRAMING LAYER -> adds its OWN `Transfer-Encoding: chunked`
 *                                  because it streams a body of unknown length.
 *
 * Result: TWO `Transfer-Encoding: chunked` header lines on the wire.
 * Modern NGINX rejects that with 502 ("upstream sent duplicate header line").
 *
 * The body is de-chunked from upstream and re-chunked exactly ONCE here, so only
 * the HEADER is duplicated -- exactly the real-world symptom.
 *
 * Compare with FixedProxy.java: the ONLY difference is the `HOP_BY_HOP` filter in
 * the header-forwarding loop.
 *
 * Run (JDK 11+, no build tool needed):  java NaiveProxy.java
 */
public class NaiveProxy {
    static final String UP_HOST = "127.0.0.1";
    static final int    UP_PORT = 8000;
    static final int    LISTEN  = 8080;

    public static void main(String[] a) throws Exception {
        ServerSocket ss = new ServerSocket();
        ss.setReuseAddress(true);
        ss.bind(new InetSocketAddress("127.0.0.1", LISTEN));
        System.out.println("[NAIVE] listening 127.0.0.1:" + LISTEN
            + " -> upstream " + UP_HOST + ":" + UP_PORT + "   (copies ALL headers -- FAULTY)");
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

            // (1) Forward upstream response headers -- NAIVELY copy EVERYTHING.
            //     This is the defect: Transfer-Encoding is hop-by-hop and must NOT be copied.
            for (String[] h : up.headers) {
                if (h[0].equalsIgnoreCase("transfer-encoding")) teCopied++;
                hdr.append(h[0]).append(": ").append(h[1]).append("\r\n");
            }
            // (2) The server's OWN chunked framing for an unknown-length body.
            hdr.append("Transfer-Encoding: chunked\r\n");
            hdr.append("Connection: close\r\n\r\n");

            System.out.println("[NAIVE] copied-TE-from-upstream=" + teCopied
                + " + framing-TE=1  => Transfer-Encoding lines on wire=" + (teCopied + 1));

            OutputStream out = cl.getOutputStream();
            out.write(hdr.toString().getBytes(StandardCharsets.ISO_8859_1));
            // Body re-chunked exactly once (valid framing); only the HEADER is duplicated.
            byte[] body = up.body;
            out.write((Integer.toHexString(body.length) + "\r\n").getBytes(StandardCharsets.US_ASCII));
            out.write(body);
            out.write("\r\n0\r\n\r\n".getBytes(StandardCharsets.US_ASCII));
            out.flush();
        } catch (Exception e) {
            // NGINX aborts the connection after it rejects the headers -> expected during repro.
            System.out.println("[NAIVE] " + e);
        }
    }

    // ----------------------- upstream fetch + helpers -----------------------

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
