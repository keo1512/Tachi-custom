package dev.tachibooks.engine;

import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import eu.kanade.tachiyomi.network.NetworkHelper;
import eu.kanade.tachiyomi.network.interceptor.CFClearance;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** Cookie/UA regression proof using only a bound loopback HTTP server. */
public final class BrowserSessionIsolationProof {
    private static int assertions;
    private static void require(boolean value, String message) { assertions++;if (!value) throw new AssertionError(message); }
    private static final class Source extends HttpSource {
        final long id; final String base; final OkHttpClient client;
        Source(long id, String base, OkHttpClient client) { this.id=id; this.base=base; this.client=client; }
        public long getId() { return id; }
        public String getName() { return "Cookie isolation fixture"; }
        public String getLang() { return "vi"; }
        public boolean getSupportsLatest() { return false; }
        public String getBaseUrl() { return base; }
        public OkHttpClient getClient() { return client; }
    }
    private static JsonObject session(Source source, String agent) {
        JsonObject value = new JsonObject(); value.addProperty("url", source.base);
        value.addProperty("userAgent", agent); JsonArray cookies = new JsonArray();
        JsonObject cookie = new JsonObject(); cookie.addProperty("domain", HttpUrl.get(source.base).host());
        cookie.addProperty("hostOnly", true); cookie.addProperty("name", "session");
        cookie.addProperty("value", "browser-original"); cookie.addProperty("path", "/");
        cookies.add(cookie); value.add("cookies", cookies); return value;
    }
    private static void fetch(OkHttpClient client,String url,String agent)throws Exception{
        Request.Builder request=new Request.Builder().url(url);
        if(agent!=null)request.header("User-Agent",agent);
        try(Response response=client.newCall(request.build()).execute()){
            require(response.isSuccessful(),"Loopback request succeeds");
            response.body().string();
        }
    }
    @SuppressWarnings("unchecked")
    public static void main(String[] argv) throws Exception {
        require(argv.length==2, "Usage: freshTemporaryDirectory user-agent|refresh");
        require("1.8".equals(System.getProperty("java.specification.version")),"Use Java8");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Use interpreter");
        Path root=Paths.get(argv[0]).toAbsolutePath(); Files.createDirectories(root);
        EngineApplication application=new EngineApplication(root);
        NetworkHelper helper=new NetworkHelper(application);
        OkHttpClient client=helper.getClient().newBuilder().dns(host->Collections.singletonList(InetAddress.getByName("127.0.0.1"))).callTimeout(5,TimeUnit.SECONDS).build();
        final List<String> agents=Collections.synchronizedList(new ArrayList<String>());
        HttpServer server=null;
        String firstBase="https://first.fixture.invalid",secondBase="https://second.fixture.invalid",unconfigured="";
        if("user-agent".equals(argv[1])){
            server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
            final int port=server.getAddress().getPort();
            firstBase="http://127.0.0.1:"+port;secondBase="http://localhost:"+port;
            unconfigured="http://unconfigured.fixture.invalid:"+port;
            server.createContext("/",exchange->{
                agents.add(exchange.getRequestHeaders().getFirst("User-Agent"));
                String path=exchange.getRequestURI().getPath();
                if(path.startsWith("/redirect")){
                    String host=path.equals("/redirect-second")?"localhost":"unconfigured.fixture.invalid";
                    exchange.getResponseHeaders().set("Location","http://"+host+":"+port+"/end");
                    exchange.sendResponseHeaders(302,-1);
                }else{byte[] bytes={1};exchange.sendResponseHeaders(200,bytes.length);exchange.getResponseBody().write(bytes);}
                exchange.close();
            });
            server.start();
        }
        Source first=new Source(1,firstBase,client);
        Source second=new Source(2,secondBase,client);
        ExtensionRegistry registry=new ExtensionRegistry(root);
        Field field=ExtensionRegistry.class.getDeclaredField("sources"); field.setAccessible(true);
        Map<String,CatalogueSource> sources=(Map<String,CatalogueSource>)field.get(registry);
        sources.put("1",first); sources.put("2",second);
        BrowserSession.initialize(root, registry);
        BrowserSession.apply(session(first,"Fixture-Agent-A"), first);
        try{if ("user-agent".equals(argv[1])) {
            String fallback=helper.getDefaultUserAgentProvider().invoke();
            BrowserSession.apply(session(second,"Fixture-Agent-B"), second);
            fetch(client,first.base,"Source-Header-UA");
            System.out.println("SOURCE_A_AGENT="+agents.get(0));
            require("Fixture-Agent-A".equals(agents.get(0)), "Changing source B must not replace source A user agent");
            fetch(client,second.base,null);
            require("Fixture-Agent-B".equals(agents.get(1)),"Source B retains its own browser user agent");
            fetch(client,unconfigured,null);
            require(fallback.equals(agents.get(2)),"An unrelated host retains the fallback user agent");
            fetch(client,unconfigured,"Source-Header-UA");
            require("Source-Header-UA".equals(agents.get(3)),"An unrelated host retains an explicit source header");
            int before=agents.size();
            fetch(client,first.base+"/redirect-unconfigured","Source-Header-UA");
            require(agents.subList(before,agents.size()).equals(Arrays.asList("Fixture-Agent-A","Source-Header-UA")),"Cross-host redirect restores original source header instead of leaking source A browser UA");
            before=agents.size();fetch(client,first.base+"/redirect-unconfigured",null);
            require(agents.subList(before,agents.size()).equals(Arrays.asList("Fixture-Agent-A",fallback)),"Cross-host redirect restores fallback when no explicit source UA existed");
            before=agents.size();fetch(client,first.base+"/redirect-second",null);
            require(agents.subList(before,agents.size()).equals(Arrays.asList("Fixture-Agent-A","Fixture-Agent-B")),"Redirect to another configured host uses that host's browser UA");
            OkHttpClient modified=client.newBuilder().addInterceptor(chain->chain.proceed(chain.request().newBuilder().header("User-Agent","Source-Interceptor-UA").build())).build();
            before=agents.size();fetch(modified,first.base,null);fetch(modified,unconfigured,null);
            require(agents.subList(before,agents.size()).equals(Arrays.asList("Fixture-Agent-A","Source-Interceptor-UA")),"A source interceptor remains effective only on unconfigured hosts");
            require(fallback.equals(helper.getDefaultUserAgentProvider().invoke()),"Browser sessions never change the legacy fallback ABI");
            require("Fixture-Agent-B".equals(CFClearance.INSTANCE.getWebViewUserAgentForHost("LOCALHOST")),"Host keys normalize case without widening their scope");
            before=agents.size();fetch(client,second.base.replace("localhost","child.localhost"),null);
            require(fallback.equals(agents.get(before)),"A parent browser session does not override an unconfigured child host");
            CFClearance.INSTANCE.setWebViewUserAgent("Legacy-ABI-Fallback");
            before=agents.size();fetch(client,unconfigured,null);fetch(client,first.base,null);
            require(agents.subList(before,agents.size()).equals(Arrays.asList("Legacy-ABI-Fallback","Fixture-Agent-A")),"Legacy fallback setter remains compatible without replacing a host's explicit browser UA");
        } else {
            require("refresh".equals(argv[1]), "Unknown proof mode");
            Cookie cookie=new Cookie.Builder().hostOnlyDomain(HttpUrl.get(first.base).host()).name("session")
                .value("server-refreshed").path("/").build();
            client.cookieJar().saveFromResponse(HttpUrl.get(first.base), Collections.singletonList(cookie));
            BrowserSession.initialize(root,registry);
            List<Cookie> restored=client.cookieJar().loadForRequest(HttpUrl.get(first.base));
            require(restored.size()==1, "One cookie identity");
            System.out.println("REFRESHED_COOKIE_RETAINED="+"server-refreshed".equals(restored.get(0).value()));
            require("server-refreshed".equals(restored.get(0).value()), "Reload must not restore stale browser cookies over refreshed server cookies");
        }}finally{if(server!=null)server.stop(0);}
        System.out.println("BROWSER_SESSION_ISOLATION_OK mode="+argv[1]+" assertions="+assertions);
        System.exit(0);
    }
}
