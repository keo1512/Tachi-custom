package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.network.SourceCookieJar;
import eu.kanade.tachiyomi.network.interceptor.CFClearance;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.io.IOException;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** Deterministic HTTP callback/file failures; no public website or native execution. */
public final class BrowserCookieAtomicProof {
    private static int assertions;
    private static final String URL="https://atomic.fixture.invalid/";
    private static final HttpUrl ORIGIN=HttpUrl.get(URL);
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static Cookie cookie(String value){return new Cookie.Builder().name("session").value(value).hostOnlyDomain(ORIGIN.host()).path("/").build();}
    private static final class Source extends HttpSource {
        final SourceCookieJar jar;final OkHttpClient client;
        int clients;boolean seedRace,applyRace,lockedDuringApply;Thread response;
        Source(SourceCookieJar jar){this.jar=jar;client=new OkHttpClient.Builder().cookieJar(jar).build();}
        public long getId(){
            if(applyRace){
                applyRace=false;lockedDuringApply=Thread.holdsLock(jar);
                CountDownLatch entered=new CountDownLatch(1);
                response=new Thread(()->{entered.countDown();jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("http-new")));});
                response.start();
                try{
                    if(!entered.await(2,TimeUnit.SECONDS))throw new AssertionError("HTTP callback did not start");
                    if(!lockedDuringApply)response.join(2000);
                    else{
                        long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(2);
                        while(response.getState()!=Thread.State.BLOCKED&&System.nanoTime()<until)Thread.yield();
                        if(response.getState()!=Thread.State.BLOCKED)throw new AssertionError("HTTP callback did not wait for cookie publication");
                    }
                }catch(InterruptedException error){throw new AssertionError(error);}
            }
            return 77;
        }
        public String getName(){return "Atomic cookie fixture";}
        public String getLang(){return "vi";}
        public boolean getSupportsLatest(){return false;}
        public String getBaseUrl(){return URL;}
        public OkHttpClient getClient(){
            if(seedRace&&++clients==2){
                Thread callback=new Thread(()->jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("http-new"))));callback.start();
                try{callback.join(2000);}catch(InterruptedException error){throw new AssertionError(error);}
                if(callback.isAlive())throw new AssertionError("HTTP callback stuck during seed");
            }
            return client;
        }
    }
    private static JsonObject origin(){JsonObject args=new JsonObject();args.addProperty("url",URL);return args;}
    private static JsonObject session(JsonObject seed,String agent,String value){
        JsonObject args=origin();args.addProperty("userAgent",agent);
        if(seed!=null)args.addProperty("seedToken",seed.get("seedToken").getAsString());
        JsonArray cookies=new JsonArray();JsonObject cookie=new JsonObject();cookie.addProperty("name","session");cookie.addProperty("value",value);cookie.addProperty("domain",ORIGIN.host());cookie.addProperty("path","/");cookie.addProperty("hostOnly",true);cookies.add(cookie);args.add("cookies",cookies);return args;
    }
    private static void seedRace(Path root)throws Exception{
        BrowserSession.initialize(root,new ExtensionRegistry(root));Source source=new Source(new SourceCookieJar());
        source.jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("old-browser")));source.seedRace=true;
        JsonObject seed=BrowserSession.seed(origin(),source);source.seedRace=false;
        require(source.clients==1,"Seed must export and fingerprint one captured jar/snapshot");
        source.jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("http-new")));
        boolean rejected=false;try{BrowserSession.apply(session(seed,"Fixture/1","old-browser"),source);}catch(IllegalArgumentException expected){rejected=true;}
        require(rejected,"A post-seed HTTP update invalidates browser publication");
        require("http-new".equals(source.jar.loadForRequest(ORIGIN).get(0).value()),"HTTP cookie remains authoritative");
    }
    private static void applyRace(Path root)throws Exception{
        BrowserSession.initialize(root,new ExtensionRegistry(root));Source source=new Source(new SourceCookieJar());
        source.jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("old-browser")));
        JsonObject seed=BrowserSession.seed(origin(),source);source.applyRace=true;
        BrowserSession.apply(session(seed,"Fixture/1","browser-new"),source);
        source.response.join(3000);
        require(!source.response.isAlive(),"HTTP callback completed after browser publication");
        require(source.lockedDuringApply,"The same jar monitor spans token check and publication");
        require("http-new".equals(source.jar.loadForRequest(ORIGIN).get(0).value()),"Concurrent HTTP refresh is never overwritten by the browser");
    }
    private static void persistence(Path root)throws Exception{
        BrowserSession.initialize(root,new ExtensionRegistry(root));Path cookieFile=root.resolve("source-cookies.json"),browserFile=root.resolve("browser-sessions.json");
        Source source=new Source(new SourceCookieJar(cookieFile));source.jar.saveFromResponse(ORIGIN,Arrays.asList(cookie("old")));
        BrowserSession.apply(session(null,"Before/1","old"),source);
        byte[] cookieBytes=Files.readAllBytes(cookieFile),browserBytes=Files.readAllBytes(browserFile);
        JsonObject seeded=BrowserSession.seed(origin(),source);Path saved=root.resolve("cookie.saved");
        Files.move(cookieFile,saved);Files.createDirectory(cookieFile);
        try{
            boolean rejected=false;try{BrowserSession.apply(session(seeded,"After/2","new"),source);}catch(IOException expected){rejected=true;}
            require(rejected,"Explicit cookie write failure is reported");
            require(Arrays.equals(browserBytes,Files.readAllBytes(browserFile)),"Cookie failure rolls back browser bytes exactly");
            require("old".equals(source.jar.loadForRequest(ORIGIN).get(0).value()),"Cookie failure retains live RAM");
            require("Before/1".equals(CFClearance.INSTANCE.getWebViewUserAgentForHost(ORIGIN.host())),"Cookie failure retains live UA");
            require(!source.jar.isPersistenceHealthy(),"Cookie disk failure has a finite health signal");
        }finally{Files.delete(cookieFile);Files.move(saved,cookieFile);}
        require(Arrays.equals(cookieBytes,Files.readAllBytes(cookieFile)),"Original cookie file remains unchanged");
        seeded=BrowserSession.seed(origin(),source);saved=root.resolve("browser.saved");Files.move(browserFile,saved);Files.createDirectory(browserFile);
        try{
            boolean rejected=false;try{BrowserSession.apply(session(seeded,"After/2","new"),source);}catch(IOException expected){rejected=true;}
            require(rejected,"Browser-file write failure is reported");
            require(Arrays.equals(cookieBytes,Files.readAllBytes(cookieFile)),"Browser failure never changes cookie file");
            require("old".equals(source.jar.loadForRequest(ORIGIN).get(0).value()),"Browser failure never changes RAM");
        }finally{Files.delete(browserFile);Files.move(saved,browserFile);}
        require(Arrays.equals(browserBytes,Files.readAllBytes(browserFile)),"Original browser file remains unchanged");
        // Validate capacity before browser metadata is published.
        Source full=new Source(new SourceCookieJar());List<Cookie> all=new ArrayList<>();
        for(int i=0;i<2048;i++)all.add(new Cookie.Builder().name("cookie"+i).value("fixture").hostOnlyDomain("unrelated.fixture.invalid").path("/").build());
        full.jar.saveFromResponse(HttpUrl.get("https://unrelated.fixture.invalid/"),all);
        boolean rejected=false;try{BrowserSession.apply(session(null,"After/2","new"),full);}catch(IOException expected){rejected=true;}
        require(rejected,"Capacity is checked before browser-file publication");
        require(Arrays.equals(browserBytes,Files.readAllBytes(browserFile)),"Capacity failure preserves browser bytes");
        require(full.jar.snapshotForBrowser(ORIGIN).isEmpty(),"Capacity failure preserves RAM");
        try(java.util.stream.Stream<Path> files=Files.list(root)){require(!files.anyMatch(p->p.getFileName().toString().startsWith(".browser-session-rollback-")),"Successful rollback leaves no private temporary copy");}
        BrowserSession.apply(session(BrowserSession.seed(origin(),source),"After/2","new"),source);
        require("new".equals(source.jar.loadForRequest(ORIGIN).get(0).value())&&source.jar.isPersistenceHealthy(),"A later explicit retry can persist successfully");
    }
    public static void main(String[] argv)throws Exception{
        require(argv.length==2,"Temporary directory and mode required");
        require("1.8".equals(System.getProperty("java.specification.version")),"Java8 required");
        Path root=Paths.get(argv[0]);Files.createDirectories(root);
        if("seed".equals(argv[1]))seedRace(root);else if("apply".equals(argv[1]))applyRace(root);else if("persistence".equals(argv[1]))persistence(root);else throw new AssertionError("Unknown mode");
        System.out.println("BROWSER_COOKIE_ATOMIC_OK mode="+argv[1]+" assertions="+assertions+" deterministic-http-callback private-file-rollback");System.exit(0);
    }
}
