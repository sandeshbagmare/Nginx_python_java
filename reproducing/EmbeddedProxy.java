import org.apache.catalina.Context;
import org.apache.catalina.startup.Tomcat;

/**
 * Boots a real embedded Apache Tomcat and mounts AIAssistantProxyServlet at /*.
 * This is the "Java proxy on Tomcat" layer from the bug report.
 *
 * Run:
 *   java -DstripHopByHop=false -Dport=4003 -cp "out;lib/*" EmbeddedProxy   # FAULTY
 *   java -DstripHopByHop=true  -Dport=4003 -cp "out;lib/*" EmbeddedProxy   # FIXED
 */
public class EmbeddedProxy {
    public static void main(String[] args) throws Exception {
        int port = Integer.parseInt(System.getProperty("port", "4003"));
        Tomcat tomcat = new Tomcat();
        tomcat.setBaseDir(System.getProperty("java.io.tmpdir") + "/embedtc-" + port);
        tomcat.setPort(port);
        tomcat.getConnector();                       // create the HTTP/1.1 connector
        Context ctx = tomcat.addContext("", null);
        Tomcat.addServlet(ctx, "ai", new AIAssistantProxyServlet());
        ctx.addServletMappingDecoded("/*", "ai");
        tomcat.start();
        System.out.println("[tomcat] :" + port
            + "  stripHopByHop=" + Boolean.getBoolean("stripHopByHop")
            + "  -> upstream http://127.0.0.1:4000");
        tomcat.getServer().await();
    }
}
