package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.Page;
import eu.kanade.tachiyomi.source.model.SChapter;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import kotlin.coroutines.Continuation;
import okhttp3.*;

/** Deterministic, no-network regression: a later page cannot block chapter opening. */
public final class ChapterPageIsolationProof {
    private static final String ID="9223372036854775701";
    private static int assertions;
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static JsonObject args(String... pairs){JsonObject value=new JsonObject();for(int i=0;i<pairs.length;i+=2)value.addProperty(pairs[i],pairs[i+1]);return value;}
    private static JsonObject rpc(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}

    private static final class Source extends HttpSource {
        final AtomicInteger resolutions=new AtomicInteger();
        final AtomicInteger imageCalls=new AtomicInteger();
        final AtomicInteger pageListCalls=new AtomicInteger();
        String lastImageUrl="";
        final boolean lazy;
        boolean rotated;
        boolean resolverFails=true;
        boolean badHeaderHook;
        protected Request imageRequest(Page page) {
            if(badHeaderHook&&page.getIndex()==1)throw new IllegalStateException("Later page request hook failed");
            return super.imageRequest(page).newBuilder().header("X-Page-Fixture","source-hook").build();
        }
        final OkHttpClient client=new OkHttpClient.Builder().addInterceptor(chain->{
            require("source-hook".equals(chain.request().header("X-Page-Fixture")),"Source image request headers reach its actual HTTP client");
            imageCalls.incrementAndGet();
            lastImageUrl=chain.request().url().toString();
            return new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1)
                .code(200).message("OK").header("Content-Type","image/png")
                .body(ResponseBody.create(MediaType.parse("image/png"),new byte[]{1,2,3})).build();
        }).build();
        Source(boolean lazy){this.lazy=lazy;}
        public long getId(){return Long.parseLong(ID);}
        public String getName(){return "Page isolation fixture";}
        public String getLang(){return "vi";}
        public boolean getSupportsLatest(){return false;}
        public String getBaseUrl(){return "https://fixture.invalid";}
        public OkHttpClient getClient(){return client;}
        public Object getPageList(SChapter chapter,Continuation<? super List<? extends Page>> completion){
            pageListCalls.incrementAndGet();
            if(!"/chapter/1".equals(chapter.getUrl()))throw new IllegalArgumentException("Unknown fixture chapter");
            return Arrays.asList(new Page(0,"/page/0","https://fixture.invalid/first.png?token="+(rotated?"new":"old"),null),
                                 new Page(1,"/page/1",lazy?null:"https://fixture.invalid/second.png?token="+(rotated?"new":"old"),null));
        }
        public Object getImageUrl(Page page,Continuation<? super String> completion){
            resolutions.incrementAndGet();
            if(resolverFails)throw new IllegalStateException("A later page has a deterministic resolver failure");
            return "https://fixture.invalid/second-resolved.png";
        }
    }

    public static void main(String[] argv)throws Exception{
        try{run(argv);}catch(Throwable failure){failure.printStackTrace();System.exit(1);}
    }
    @SuppressWarnings("unchecked")
    private static void run(String[] argv)throws Exception{
        require(argv.length>=1&&argv.length<=2,"Usage: isolatedDataDirectory [eager|rotated|headers]");
        require("1.8".equals(System.getProperty("java.specification.version")),"Use Java8");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Use interpreter");
        require(rpc("initialize",args("dataDirectory",Paths.get(argv[0]).toAbsolutePath().toString())).get("ok").getAsBoolean(),"Initialize current engine");
        boolean rotated=argv.length==2&&"rotated".equals(argv[1]);
        boolean headers=argv.length==2&&"headers".equals(argv[1]);
        Source source=new Source(!rotated&&!headers);source.badHeaderHook=headers;
        Field registryField=ExtensionHost.class.getDeclaredField("registry");registryField.setAccessible(true);
        Object registry=registryField.get(null);
        Field sourcesField=ExtensionRegistry.class.getDeclaredField("sources");sourcesField.setAccessible(true);
        ((Map<String,CatalogueSource>)sourcesField.get(registry)).put(ID,source);
        JsonObject result=rpc("chapter",args("sourceId",ID,"ref","/chapter/1","title","Fixture chapter"));
        if(headers){
            require(result.get("ok").getAsBoolean(),"A later image request hook cannot prevent chapter metadata from opening");
            JsonObject first=args("sourceId",ID,"chapterRef","/chapter/1","url",result.getAsJsonObject("result").getAsJsonArray("images").get(0).getAsString());first.addProperty("index",0);
            require(rpc("image",first).get("ok").getAsBoolean(),"The first image still uses the actual source client");
            JsonObject second=args("sourceId",ID,"chapterRef","/chapter/1","url",result.getAsJsonObject("result").getAsJsonArray("images").get(1).getAsString());second.addProperty("index",1);
            require(!rpc("image",second).get("ok").getAsBoolean(),"The failing request hook remains isolated to its own page");
            require(source.imageCalls.get()==1,"The invalid later page sends no HTTP request");
            System.out.println("PAGE_REQUEST_HOOK_ISOLATION_OK assertions="+assertions);System.exit(0);
        }
        if(rotated){
            require(result.get("ok").getAsBoolean(),"Open original chapter with old CDN token");
            String old=result.getAsJsonObject("result").getAsJsonArray("images").get(0).getAsString();
            String oldSecond=result.getAsJsonObject("result").getAsJsonArray("images").get(1).getAsString();
            source.rotated=true;
            require(rpc("clearSourceCache",args()).get("ok").getAsBoolean(),"Simulate expired page cache before persisted partial retry");
            JsonObject retryArgs=args("sourceId",ID,"chapterRef","/chapter/1","url",old);
            retryArgs.addProperty("index",0);
            JsonObject retry=rpc("image",retryArgs);
            if(!retry.get("ok").getAsBoolean())System.out.println("ROTATED_PAGE_RETRY_FAILED "+retry.getAsJsonObject("error").get("code").getAsString()+" imageCalls="+source.imageCalls.get());
            require(retry.get("ok").getAsBoolean(),"Stable chapter and ordinal must retry via freshly resolved source page after CDN token rotation");
            require(source.imageCalls.get()==1,"Retry invokes original source image client exactly once");
            require(source.lastImageUrl.equals("https://fixture.invalid/first.png?token=new"),"Only the freshly resolved source URL reaches the image client");
            JsonObject secondRetry=args("sourceId",ID,"chapterRef","/chapter/1","url",oldSecond);secondRetry.addProperty("index",1);
            require(rpc("image",secondRetry).get("ok").getAsBoolean(),"A second old URL in the same partial chapter also resumes after cache reload");
            require(source.lastImageUrl.equals("https://fixture.invalid/second.png?token=new"),"The second retry also uses its fresh source-owned URL");
            require(source.imageCalls.get()==2,"Both missing pages resume exactly once");
            require(rpc("chapter",args("sourceId",ID,"ref","/chapter/1","title","Fixture chapter")).get("ok").getAsBoolean(),"Normal chapter metadata restores strict warm-cache URL validation");
            int baseline=source.imageCalls.get();
            JsonObject invalid=args("sourceId",ID,"chapterRef","/chapter/1","url","https://unrelated.invalid/old.png");invalid.addProperty("index",0);
            require(!rpc("image",invalid).get("ok").getAsBoolean(),"Warm page cache refuses an unrelated supplied URL");
            invalid=args("sourceId",ID,"chapterRef","/chapter/1","url",source.lastImageUrl);invalid.addProperty("index",-1);
            int listBaseline=source.pageListCalls.get();
            require(!rpc("image",invalid).get("ok").getAsBoolean(),"Negative page index is refused");
            invalid.addProperty("index",10000);
            require(!rpc("image",invalid).get("ok").getAsBoolean(),"Out-of-range page index is refused before page-list loading");
            rpc("clearSourceCache",args());
            for(String bad:new String[]{"file:///local.png","https://user:secret@fixture.invalid/image.png","https://fixture.invalid/line\nbreak.png"}){
                invalid=args("sourceId",ID,"chapterRef","/chapter/1","url",bad);invalid.addProperty("index",0);
                require(!rpc("image",invalid).get("ok").getAsBoolean(),"Malformed caller URL is refused on a cold cache");
            }
            require(source.pageListCalls.get()==listBaseline,"Invalid metadata does not load a source page list");
            invalid=args("sourceId",ID,"chapterRef","/chapter/missing","url",old);invalid.addProperty("index",0);
            require(!rpc("image",invalid).get("ok").getAsBoolean(),"Unknown chapter cannot download an image");
            invalid=args("sourceId","1","chapterRef","/chapter/1","url",old);invalid.addProperty("index",0);
            require(!rpc("image",invalid).get("ok").getAsBoolean(),"Uninstalled source cannot download an image");
            require(source.imageCalls.get()==baseline,"Rejected image requests do not reach any HTTP image client");
            JsonObject legacy=args("sourceId",ID,"url",old);legacy.addProperty("index",0);
            require(!rpc("image",legacy).get("ok").getAsBoolean(),"Legacy request cannot guess a missing chapter cache");
            JsonObject reopened=rpc("chapter",args("sourceId",ID,"ref","/chapter/1","title","Fixture chapter"));
            require(reopened.get("ok").getAsBoolean(),"Open refreshed chapter after rejected requests");
            legacy.addProperty("url",reopened.getAsJsonObject("result").getAsJsonArray("images").get(0).getAsString());
            require(rpc("image",legacy).get("ok").getAsBoolean(),"Legacy request still matches an unambiguous cached URL");
            require(source.imageCalls.get()==baseline+1,"Legacy valid request reaches the original source client once");
            System.out.println("ROTATED_PAGE_RETRY_PROOF_OK assertions="+assertions+" no-network fixture");
            System.exit(0);
        }
        if(!result.get("ok").getAsBoolean())System.out.println("CHAPTER_OPEN_FAILED "+result.getAsJsonObject("error").get("code").getAsString()+" imageUrlResolutions="+source.resolutions.get());
        require(result.get("ok").getAsBoolean(),"A valid chapter with a readable first page must open before resolving an unrelated later page");
        require(source.resolutions.get()==0,"Opening a chapter must not eagerly resolve every lazy page");
        require(result.getAsJsonObject("result").getAsJsonArray("images").size()==2,"Both page identities remain available");
        String first=result.getAsJsonObject("result").getAsJsonArray("images").get(0).getAsString();
        String second=result.getAsJsonObject("result").getAsJsonArray("images").get(1).getAsString();
        require(second.startsWith("https://page.tachibooks.invalid/"),"A lazy page has a stable non-network locator");
        JsonObject firstArgs=args("sourceId",ID,"chapterRef","/chapter/1","url",first);firstArgs.addProperty("index",0);
        require(rpc("image",firstArgs).get("ok").getAsBoolean(),"Readable first page loads while later resolver is broken");
        int imageBaseline=source.imageCalls.get();
        JsonObject later=args("sourceId",ID,"chapterRef","/chapter/1","url",second);later.addProperty("index",1);
        require(!rpc("image",later).get("ok").getAsBoolean(),"Broken later page reports its own error");
        require(source.imageCalls.get()==imageBaseline,"Failed resolution does not send the locator over HTTP");
        JsonObject mismatched=later.deepCopy();mismatched.addProperty("index",0);
        int resolutions=source.resolutions.get();
        require(!rpc("image",mismatched).get("ok").getAsBoolean(),"Deferred locator cannot select another page");
        mismatched=later.deepCopy();mismatched.addProperty("chapterRef","/chapter/other");
        require(!rpc("image",mismatched).get("ok").getAsBoolean(),"Deferred locator cannot select another chapter");
        mismatched=later.deepCopy();mismatched.remove("chapterRef");
        require(!rpc("image",mismatched).get("ok").getAsBoolean(),"Deferred locator requires explicit stable chapter identity");
        require(source.resolutions.get()==resolutions,"Mismatched locators do not execute the source resolver");
        source.resolverFails=false;
        require(rpc("image",later).get("ok").getAsBoolean(),"Retry resolves only the failed page");
        require("https://fixture.invalid/second-resolved.png".equals(source.lastImageUrl),"Image client receives only the real source URL");
        require(source.imageCalls.get()==imageBaseline+1,"Retry downloads one actual page");
        rpc("clearSourceCache",args());
        require(rpc("image",later).get("ok").getAsBoolean(),"Deferred locator survives page-cache loss and partial-download resume");
        require("https://fixture.invalid/second-resolved.png".equals(source.lastImageUrl),"A cold-cache retry also uses the resolved URL");
        System.out.println("CHAPTER_PAGE_ISOLATION_PROOF_OK assertions="+assertions+" no-network fixture");
        System.exit(0);
    }
}
