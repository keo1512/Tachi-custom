package dev.tachibooks.engine;

import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.Page;
import eu.kanade.tachiyomi.source.model.SChapter;
import eu.kanade.tachiyomi.source.online.HttpSource;
import eu.kanade.tachiyomi.network.SourceCookieJar;
import java.io.*;
import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.*;
import okhttp3.*;
import kotlin.coroutines.Continuation;

/** Loopback-only proof for cover headers/client/cookies, bounds and page-hook isolation. */
public final class CoverImageProof {
    private static final String ID="9223372036854775806";
    private static final byte[] PNG=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a0foAAAAASUVORK5CYII=");
    private static int assertions;
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static JsonObject args(String... pairs){JsonObject result=new JsonObject();for(int i=0;i<pairs.length;i+=2)result.addProperty(pairs[i],pairs[i+1]);return result;}
    private static JsonObject rpc(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}
    private static JsonObject cover(String url){return rpc("cover",args("sourceId",ID,"url",url));}
    private static final class Source extends HttpSource {
        final String base;
        final AtomicInteger intercepted=new AtomicInteger();
        final AtomicInteger imageHooks=new AtomicInteger();
        final SourceCookieJar cookies;
        private OkHttpClient newClient(){return new OkHttpClient.Builder().cookieJar(cookies).addInterceptor(chain->{
            intercepted.incrementAndGet();return chain.proceed(chain.request().newBuilder().header("X-Source-Client","fixture").build());
        }).build();}
        final OkHttpClient client;
        Source(String base,Path cookieFile){
            this.base=base;this.cookies=new SourceCookieJar(cookieFile);
            cookies.saveFromResponse(HttpUrl.get(base),Collections.singletonList(new Cookie.Builder().name("cover_cookie").value("fixture").hostOnlyDomain("127.0.0.1").path("/").build()));
            this.client=newClient();
        }
        public long getId(){return Long.parseLong(ID);}
        public String getName(){return "Cover fixture";}
        public String getLang(){return "vi";}
        public boolean getSupportsLatest(){return false;}
        public String getBaseUrl(){return base;}
        public OkHttpClient getClient(){return client;}
        protected Headers.Builder headersBuilder(){return new Headers.Builder().add("Referer",base+"/").add("Origin",base).add("User-Agent","Cover-Fixture-UA");}
        public Object getPageList(SChapter chapter,Continuation<? super List<? extends Page>> completion){
            return Collections.singletonList(new Page(0,"/page",base+"/page.png",null));
        }
        protected Request imageRequest(Page page){imageHooks.incrementAndGet();return super.imageRequest(page);}
    }
    @SuppressWarnings("unchecked")
    public static void main(String[] argv)throws Exception{
        require("1.8".equals(System.getProperty("java.specification.version")),"Proof must run on Java8");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Proof must use interpreter");
        require(argv.length==1,"Usage: dataDirectory");
        require(rpc("initialize",args("dataDirectory",Paths.get(argv[0]).toAbsolutePath().toString())).get("ok").getAsBoolean(),"Initialize engine");
        HttpServer server=HttpServer.create(new InetSocketAddress("127.0.0.1",0),0);
        String base="http://127.0.0.1:"+server.getAddress().getPort();
        AtomicInteger requests=new AtomicInteger();
        ExecutorService serverWorkers=Executors.newFixedThreadPool(4),rpcWorkers=Executors.newFixedThreadPool(3);
        server.setExecutor(serverWorkers);
        CountDownLatch parallelStarted=new CountDownLatch(2),releaseParallel=new CountDownLatch(1);
        server.createContext("/",exchange->{
            requests.incrementAndGet();
            boolean correct=(base+"/").equals(exchange.getRequestHeaders().getFirst("Referer"))&&base.equals(exchange.getRequestHeaders().getFirst("Origin"))&&"Cover-Fixture-UA".equals(exchange.getRequestHeaders().getFirst("User-Agent"))&&"cover_cookie=fixture".equals(exchange.getRequestHeaders().getFirst("Cookie"))&&"fixture".equals(exchange.getRequestHeaders().getFirst("X-Source-Client"));
            if(!correct){exchange.sendResponseHeaders(403,-1);exchange.close();return;}
            String path=exchange.getRequestURI().getPath();
            if(path.equals("/parallel")){
                parallelStarted.countDown();
                try{if(!releaseParallel.await(8,TimeUnit.SECONDS))throw new IOException("Parallel cover deadline");}
                catch(InterruptedException interrupted){Thread.currentThread().interrupt();throw new IOException(interrupted);}
                exchange.getResponseHeaders().add("Set-Cookie","late_cookie=refreshed; Path=/");
            }
            if(path.equals("/status")){exchange.sendResponseHeaders(403,-1);exchange.close();return;}
            exchange.getResponseHeaders().add("Content-Type","image/png");
            if(path.equals("/empty")){exchange.sendResponseHeaders(200,-1);exchange.close();return;}
            int length=path.equals("/oversized")||path.equals("/chunked")?8*1024*1024+1:PNG.length;
            exchange.sendResponseHeaders(200,path.equals("/chunked")?0:length);
            try(OutputStream output=exchange.getResponseBody()){
                if(length==PNG.length)output.write(PNG);
                else {byte[] block=new byte[32768];for(int sent=0;sent<length;){int count=Math.min(block.length,length-sent);output.write(block,0,count);sent+=count;}}
            }catch(IOException expectedOnBoundedClose){}finally{exchange.close();}
        });
        server.start();
        try{
            Path cookieFile=Paths.get(argv[0]).resolve("cover-cookies.json");
            Source source=new Source(base,cookieFile);
            Field registryField=ExtensionHost.class.getDeclaredField("registry");registryField.setAccessible(true);
            Object registry=registryField.get(null);Field sourcesField=ExtensionRegistry.class.getDeclaredField("sources");sourcesField.setAccessible(true);
            ((Map<String,CatalogueSource>)sourcesField.get(registry)).put(ID,source);
            for(String url:new String[]{base+"/cover.png","/cover.png","cover.png","//127.0.0.1:"+server.getAddress().getPort()+"/cover.png"}){
                JsonObject response=cover(url);require(response.get("ok").getAsBoolean(),"Cover succeeds with headers/client/cookies and relative URL");
                JsonObject image=response.getAsJsonObject("result");require(Arrays.equals(PNG,Base64.getDecoder().decode(image.get("base64").getAsString())),"Exact cover bytes returned");
                require("image/png".equals(image.get("mimeType").getAsString()),"Cover MIME retained");
            }
            require(source.intercepted.get()==4&&requests.get()==4,"Every cover uses original source client");
            require(source.imageHooks.get()==0,"Covers never invoke chapter image hooks");
            for(String url:new String[]{"file:///cover.png","data:image/png;base64,AA==",base+"/cover.png#fragment","http://user:password@127.0.0.1/cover.png",base+"/co\nver.png","\\cover.png"}){
                JsonObject response=cover(url);require(!response.get("ok").getAsBoolean(),"Invalid URL refused");require("invalid_request".equals(response.getAsJsonObject("error").get("code").getAsString()),"Invalid URL is bounded request error");
            }
            require(requests.get()==4,"Invalid cover URLs make no network requests");
            for(String path:new String[]{"/status","/empty","/oversized","/chunked"})require(!cover(path).get("ok").getAsBoolean(),"Failed or unbounded cover body refused");
            JsonObject missing=rpc("cover",args("sourceId","1","url",base+"/cover.png"));
            require(!missing.get("ok").getAsBoolean()&&"source_not_installed".equals(missing.getAsJsonObject("error").get("code").getAsString()),"Uninstalled source cannot load cover");
            require(requests.get()==8,"Uninstalled source makes no network requests");
            require(cover("/cover.png").get("ok").getAsBoolean(),"Failure closes body and leaves cover loader usable");
            JsonObject status=cover("/status");
            require(status.getAsJsonObject("error").get("httpStatus").getAsInt()==403,"Cover HTTP status survives the RPC boundary without URLs");
            require(source.client.callTimeoutMillis()==0,"Bounded cover timeout does not mutate the source client");
            Future<JsonObject> first=rpcWorkers.submit(()->cover("/parallel?one"));
            Future<JsonObject> second=rpcWorkers.submit(()->cover("/parallel?two"));
            require(parallelStarted.await(5,TimeUnit.SECONDS),"Two covers reach the server concurrently");
            Future<JsonObject> chapter=rpcWorkers.submit(()->rpc("chapter",args("sourceId",ID,"ref","/chapter/1","title","Fixture chapter")));
            JsonObject opened=chapter.get(2,TimeUnit.SECONDS);
            require(opened.get("ok").getAsBoolean(),"Chapter opens without waiting for slow covers");
            JsonObject imageArgs=args("sourceId",ID,"chapterRef","/chapter/1","url",base+"/page.png");imageArgs.addProperty("index",0);
            Future<JsonObject> image=rpcWorkers.submit(()->rpc("image",imageArgs));
            JsonObject firstPage=image.get(2,TimeUnit.SECONDS);
            require(firstPage.get("ok").getAsBoolean(),"First page downloads while both covers remain blocked");
            require(Arrays.equals(PNG,Base64.getDecoder().decode(firstPage.getAsJsonObject("result").get("base64").getAsString())),"Reader keeps exact original source page bytes");
            require(source.imageHooks.get()==1,"First page uses original source image hook");
            require(!first.isDone()&&!second.isDone(),"Reader did not cancel or release unrelated cover downloads");
            JsonObject wrong=imageArgs.deepCopy();wrong.addProperty("url",base+"/unrelated.png");
            require(!rpc("image",wrong).get("ok").getAsBoolean(),"Reader priority preserves source page identity checks");
            CountDownLatch cleanupStarted=new CountDownLatch(1);
            Future<JsonObject> exclusive=rpcWorkers.submit(()->{cleanupStarted.countDown();return rpc("clearCookies",new JsonObject());});
            require(cleanupStarted.await(2,TimeUnit.SECONDS),"Cookie cleanup reached the host");
            Thread.sleep(50);
            require(!exclusive.isDone(),"Cookie cleanup still waits for cover session leases");
            releaseParallel.countDown();
            require(first.get(5,TimeUnit.SECONDS).get("ok").getAsBoolean(),"First concurrent cover succeeds");
            require(second.get(5,TimeUnit.SECONDS).get("ok").getAsBoolean(),"Second concurrent cover succeeds");
            require(exclusive.get(5,TimeUnit.SECONDS).get("ok").getAsBoolean(),"Exclusive worker resumes after both covers");
            require(source.cookies.loadForRequest(HttpUrl.get(base)).isEmpty(),"Late cover Set-Cookie cannot resurrect cleared live cookies");
            require(new SourceCookieJar(cookieFile).loadForRequest(HttpUrl.get(base)).isEmpty(),"Late cover cookies remain cleared after loading the private store again");
            System.out.println("JAVA8_COVER_IMAGE_PROOF_OK assertions="+assertions+" loopback-only headers client cookies relative-urls bounds page-hook-isolation");
        }finally{releaseParallel.countDown();server.stop(0);serverWorkers.shutdownNow();rpcWorkers.shutdownNow();}
        System.exit(0);
    }
}
