package dev.tachibooks.engine;

import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.Page;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.io.*;
import java.lang.reflect.Field;
import java.net.InetSocketAddress;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.*;

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
        final CookieJar cookies=new CookieJar(){
            public void saveFromResponse(HttpUrl url,List<Cookie> cookies){}
            public List<Cookie> loadForRequest(HttpUrl url){return Collections.singletonList(new Cookie.Builder().name("cover_cookie").value("fixture").hostOnlyDomain("127.0.0.1").path("/").build());}
        };
        final OkHttpClient client=new OkHttpClient.Builder().cookieJar(cookies).addInterceptor(chain->{
            intercepted.incrementAndGet();return chain.proceed(chain.request().newBuilder().header("X-Source-Client","fixture").build());
        }).build();
        Source(String base){this.base=base;}
        public long getId(){return Long.parseLong(ID);}
        public String getName(){return "Cover fixture";}
        public String getLang(){return "vi";}
        public boolean getSupportsLatest(){return false;}
        public String getBaseUrl(){return base;}
        public OkHttpClient getClient(){return client;}
        protected Headers.Builder headersBuilder(){return new Headers.Builder().add("Referer",base+"/").add("Origin",base).add("User-Agent","Cover-Fixture-UA");}
        protected Request imageRequest(Page page){throw new AssertionError("A cover must not invoke chapter image hooks");}
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
        server.createContext("/",exchange->{
            requests.incrementAndGet();
            boolean correct=(base+"/").equals(exchange.getRequestHeaders().getFirst("Referer"))&&base.equals(exchange.getRequestHeaders().getFirst("Origin"))&&"Cover-Fixture-UA".equals(exchange.getRequestHeaders().getFirst("User-Agent"))&&"cover_cookie=fixture".equals(exchange.getRequestHeaders().getFirst("Cookie"))&&"fixture".equals(exchange.getRequestHeaders().getFirst("X-Source-Client"));
            if(!correct){exchange.sendResponseHeaders(403,-1);exchange.close();return;}
            String path=exchange.getRequestURI().getPath();
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
            Source source=new Source(base);
            Field registryField=ExtensionHost.class.getDeclaredField("registry");registryField.setAccessible(true);
            Object registry=registryField.get(null);Field sourcesField=ExtensionRegistry.class.getDeclaredField("sources");sourcesField.setAccessible(true);
            ((Map<String,CatalogueSource>)sourcesField.get(registry)).put(ID,source);
            for(String url:new String[]{base+"/cover.png","/cover.png","cover.png","//127.0.0.1:"+server.getAddress().getPort()+"/cover.png"}){
                JsonObject response=cover(url);require(response.get("ok").getAsBoolean(),"Cover succeeds with headers/client/cookies and relative URL");
                JsonObject image=response.getAsJsonObject("result");require(Arrays.equals(PNG,Base64.getDecoder().decode(image.get("base64").getAsString())),"Exact cover bytes returned");
                require("image/png".equals(image.get("mimeType").getAsString()),"Cover MIME retained");
            }
            require(source.intercepted.get()==4&&requests.get()==4,"Every cover uses original source client");
            for(String url:new String[]{"file:///cover.png","data:image/png;base64,AA==",base+"/cover.png#fragment","http://user:password@127.0.0.1/cover.png",base+"/co\nver.png","\\cover.png"}){
                JsonObject response=cover(url);require(!response.get("ok").getAsBoolean(),"Invalid URL refused");require("invalid_request".equals(response.getAsJsonObject("error").get("code").getAsString()),"Invalid URL is bounded request error");
            }
            require(requests.get()==4,"Invalid cover URLs make no network requests");
            for(String path:new String[]{"/status","/empty","/oversized","/chunked"})require(!cover(path).get("ok").getAsBoolean(),"Failed or unbounded cover body refused");
            JsonObject missing=rpc("cover",args("sourceId","1","url",base+"/cover.png"));
            require(!missing.get("ok").getAsBoolean()&&"source_not_installed".equals(missing.getAsJsonObject("error").get("code").getAsString()),"Uninstalled source cannot load cover");
            require(requests.get()==8,"Uninstalled source makes no network requests");
            require(cover("/cover.png").get("ok").getAsBoolean(),"Failure closes body and leaves cover loader usable");
            System.out.println("JAVA8_COVER_IMAGE_PROOF_OK assertions="+assertions+" loopback-only headers client cookies relative-urls bounds page-hook-isolation");
        }finally{server.stop(0);}
        System.exit(0);
    }
}
