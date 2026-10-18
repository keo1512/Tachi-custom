package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.network.SourceCookieJar;
import eu.kanade.tachiyomi.network.interceptor.CFClearance;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** Genuine original-APK cookie handoff proof; no external website or native iOS execution. */
public final class BrowserSeedProof {
    private static int assertions;
    private static final String ID="4508733312114627536", URL="https://fixture.example/reader";
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static JsonObject args(String... pairs){JsonObject v=new JsonObject();for(int i=0;i<pairs.length;i+=2)v.addProperty(pairs[i],pairs[i+1]);return v;}
    private static JsonObject request(String method,JsonObject args){JsonObject r=args("method",method);r.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(r.toString())).getAsJsonObject();}
    private static JsonElement call(String method,JsonObject args){JsonObject r=request(method,args);require(r.get("ok").getAsBoolean(),"Operation failed: "+method);return r.get("result");}
    private static JsonObject seed(){return call("browserSeed",args("sourceId",ID,"url",URL)).getAsJsonObject();}
    private static JsonObject session(JsonObject seed){JsonObject r=args("sourceId",ID,"url",URL,"userAgent","FixtureWebKit/1","seedToken",seed.get("seedToken").getAsString());r.add("cookies",seed.get("cookies").deepCopy());return r;}
    public static void main(String[] argv)throws Exception{
        require(argv.length==2||argv.length==3,"dataDirectory and immutable original APK required");
        require("1.8".equals(System.getProperty("java.specification.version")),"Java8 required");
        Path root=Paths.get(argv[0]),apk=Paths.get(argv[1]);call("initialize",args("dataDirectory",root.toString()));
        if(argv.length==3){
            JsonObject cold=seed();
            require(!cold.has("userAgent"),"Cold JVM must not restore reset browser UA");
            require(cold.getAsJsonArray("cookies").size()==1&&"path_cookie".equals(cold.getAsJsonArray("cookies").get(0).getAsJsonObject().get("name").getAsString()),"Cold reset preserves source cookie");
            System.out.println("BROWSER_UA_RESET_COLD_OK assertions="+assertions);System.exit(0);
        }
        call("install",args("apkPath",apk.toString(),"packageHash",EngineFiles.sha256(apk)));
        call("preferences",args("sourceId",ID));JsonObject preference=args("sourceId",ID,"key","Address");preference.addProperty("value","https://fixture.example");call("setPreference",preference);
        Field field=ExtensionHost.class.getDeclaredField("registry");field.setAccessible(true);
        HttpSource source=(HttpSource)((ExtensionRegistry)field.get(null)).source(ID);
        SourceCookieJar jar=(SourceCookieJar)source.getClient().cookieJar();HttpUrl url=HttpUrl.get(URL);
        Cookie path=new Cookie.Builder().name("path_cookie").value("fixture-only").hostOnlyDomain(url.host()).path("/private").secure().httpOnly().build();
        Cookie other=new Cookie.Builder().name("other").value("keep").hostOnlyDomain("other.example").path("/").build();
        jar.saveFromResponse(url,Arrays.asList(path));jar.saveFromResponse(HttpUrl.get("https://other.example/"),Arrays.asList(other));
        JsonObject first=seed();require(first.getAsJsonArray("cookies").size()==1,"Seed contains all source paths and no unrelated host");
        JsonObject item=first.getAsJsonArray("cookies").get(0).getAsJsonObject();
        require("/private".equals(item.get("path").getAsString())&&item.get("httpOnly").getAsBoolean()&&item.get("secure").getAsBoolean()&&item.get("hostOnly").getAsBoolean(),"Seed preserves path/security/host flags");
        require(!item.has("expiresAt"),"Session cookie is not silently made persistent");
        JsonObject foreign=args("sourceId",ID,"url","https://other.example/");
        require(!request("browserSeed",foreign).get("ok").getAsBoolean(),"Foreign origin refused before exporting private cookies");
        require(!request("browserSeed",args("sourceId",ID,"url","http://fixture.example/reader")).get("ok").getAsBoolean(),"Scheme downgrade refused");
        require(!request("browserSeed",args("sourceId",ID,"url","https://fixture.example:444/reader")).get("ok").getAsBoolean(),"Other port refused");
        call("browserSession",session(first));
        require(!request("browserSession",session(first)).get("ok").getAsBoolean(),"Seed cannot be replayed");
        JsonObject refreshed=seed();
        jar.saveFromResponse(url,Arrays.asList(new Cookie.Builder().name("http_refresh").value("new").hostOnlyDomain(url.host()).path("/").build()));
        require(!request("browserSession",session(refreshed)).get("ok").getAsBoolean(),"Late browser cannot roll back HTTP refresh");
        require(jar.loadForRequest(url).size()==1&&"http_refresh".equals(jar.loadForRequest(url).get(0).name()),"New HTTP cookie retained");
        JsonObject cleared=seed();call("clearCookies",new JsonObject());
        require(!request("browserSession",session(cleared)).get("ok").getAsBoolean(),"Clear invalidates pending browser and cannot resurrect deleted cookies");
        require(jar.snapshotForBrowser(url).isEmpty(),"Cleared cookies remain empty");
        JsonObject empty=seed();call("browserSession",session(empty));
        require(jar.snapshotForBrowser(url).isEmpty(),"Empty session remains empty");
        jar.saveFromResponse(url,Arrays.asList(path));
        JsonObject beforeReset=seed();call("browserSession",session(beforeReset));
        JsonObject pendingReset=seed();
        Path browserFile=root.resolve("browser-sessions.json"),cookieFile=root.resolve("source-cookies.json");
        byte[] cookieBytes=Files.readAllBytes(cookieFile);
        CFClearance.INSTANCE.setWebViewUserAgent("LegacyFixture/1");
        call("resetUserAgents",new JsonObject());
        require(CFClearance.INSTANCE.getWebViewUserAgentForHost(url.host())==null,"Live exact-host browser UA removed");
        require(!"LegacyFixture/1".equals(CFClearance.INSTANCE.getWebViewUserAgent()),"Legacy fallback restored to default without changing ABI");
        require(Arrays.equals(cookieBytes,Files.readAllBytes(cookieFile)),"Reset does not rewrite cookie bytes");
        require(!new String(Files.readAllBytes(browserFile),"UTF-8").contains("userAgent"),"Persisted browser UA removed");
        require(!request("browserSession",session(pendingReset)).get("ok").getAsBoolean(),"Reset invalidates pending browser token");
        require(!seed().has("userAgent"),"Next browser is not seeded with deleted override");
        require(jar.snapshotForBrowser(url).size()==1,"Reset preserves live scoped cookie");
        String java=Paths.get(System.getProperty("java.home"),"bin","java").toString();
        Process cold=new ProcessBuilder(java,"-Xint","-cp",System.getProperty("java.class.path"),BrowserSeedProof.class.getName(),root.toString(),apk.toString(),"cold-reset").redirectErrorStream(true).start();
        require(cold.waitFor(20,TimeUnit.SECONDS),"Cold reset proof finished");
        java.io.ByteArrayOutputStream output=new java.io.ByteArrayOutputStream();byte[] block=new byte[4096];int count;
        while((count=cold.getInputStream().read(block))!=-1)output.write(block,0,count);
        String coldOutput=new String(output.toByteArray(),"UTF-8");
        require(cold.exitValue()==0&&coldOutput.contains("BROWSER_UA_RESET_COLD_OK"),"Cold reset proof passed: "+coldOutput);
        System.out.print(coldOutput);
        JsonObject restored=seed();call("browserSession",session(restored));
        JsonObject pendingFailure=seed();
        byte[] beforeFailure=Files.readAllBytes(browserFile);Path saved=root.resolve("browser-sessions.saved");
        Files.move(browserFile,saved);Files.createDirectory(browserFile);
        try{
            require(!request("resetUserAgents",new JsonObject()).get("ok").getAsBoolean(),"Persistence failure cannot report reset success");
            require("FixtureWebKit/1".equals(CFClearance.INSTANCE.getWebViewUserAgentForHost(url.host())),"Failed reset preserves active UA");
            require(Arrays.equals(cookieBytes,Files.readAllBytes(cookieFile)),"Failed reset preserves cookies");
        }finally{Files.delete(browserFile);Files.move(saved,browserFile);}
        require(Arrays.equals(beforeFailure,Files.readAllBytes(browserFile)),"Failed reset preserves persisted session");
        call("browserSession",session(pendingFailure));
        require(!request("resetUserAgents",args("path","caller-cannot-select-files")).get("ok").getAsBoolean(),"Reset accepts no caller paths");
        System.out.println("BROWSER_SEED_PROOF_OK assertions="+assertions+" original-apk all-paths scoped stale-refresh replay logout flags");
        System.exit(0);
    }
}
