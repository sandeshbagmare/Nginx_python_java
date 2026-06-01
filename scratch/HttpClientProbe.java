import java.net.URI;
import java.net.http.*;

// Does java.net.http.HttpClient (what AIAssistantProxyServlet uses) expose
// transfer-encoding / content-length in response.headers().map()?
// That decides whether stripping them in the servlet actually does anything.
public class HttpClientProbe {
    public static void main(String[] args) throws Exception {
        HttpClient client = HttpClient.newHttpClient();
        HttpRequest req = HttpRequest.newBuilder(URI.create("http://127.0.0.1:8000/sse"))
            .header("Accept", "text/event-stream").GET().build();
        HttpResponse<String> resp = client.send(req, HttpResponse.BodyHandlers.ofString());
        System.out.println("status=" + resp.statusCode());
        System.out.println("HTTP version=" + resp.version());
        System.out.println("---- headers().map() as the servlet would iterate it ----");
        resp.headers().map().forEach((k, v) -> System.out.println("  " + k + " = " + v));
        System.out.println("---- checks ----");
        System.out.println("exposes transfer-encoding? " + resp.headers().firstValue("transfer-encoding").isPresent());
        System.out.println("exposes content-length?    " + resp.headers().firstValue("content-length").isPresent());
    }
}
