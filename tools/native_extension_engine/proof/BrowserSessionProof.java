package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.network.NetworkHelper;
import eu.kanade.tachiyomi.network.SourceCookieJar;
import eu.kanade.tachiyomi.network.interceptor.CFClearance;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** Opt-in cookie proof against an installed original APK. It makes no HTTP requests. */
public final class BrowserSessionProof {
    private static final String ORIGIN="https://fixture.example/reader";
    private static final String CHILD="https://child.fixture.example/reader";
    private static final String USER_AGENT="TachiBooks-Browser-Session-Proof/2";
    private static final String SOURCE_ID="4508733312114627536";
    private static int assertions;
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static JsonObject args(String... pairs){JsonObject value=new JsonObject();for(int i=0;i<pairs.length;i+=2)value.addProperty(pairs[i],pairs[i+1]);return value;}
    private static JsonObject request(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}
    private static JsonElement call(String method,JsonObject args){JsonObject response=request(method,args);require(response.get("ok").getAsBoolean(),"Engine operation failed: "+method);return response.get("result");}
    private static HttpSource source()throws Exception{Field field=ExtensionHost.class.getDeclaredField("registry");field.setAccessible(true);return (HttpSource)((ExtensionRegistry)field.get(null)).source(SOURCE_ID);}
    private static SourceCookieJar jar()throws Exception{CookieJar jar=source().getClient().cookieJar();require(jar instanceof SourceCookieJar,"Original source uses the maintained cookie store");return (SourceCookieJar)jar;}
    private static Cookie named(List<Cookie> cookies,String name){for(Cookie cookie:cookies)if(cookie.name().equals(name))return cookie;return null;}
    private static Cookie cookie(String name,String value,boolean hostOnly,long expiry){Cookie.Builder builder=new Cookie.Builder().name(name).value(value).path("/").secure().httpOnly().expiresAt(expiry);if(hostOnly)builder.hostOnlyDomain("fixture.example");else builder.domain("fixture.example");return builder.build();}
    private static JsonObject browserCookie(String name,String value,boolean hostOnly,long expiry){JsonObject cookie=args("name",name,"value",value,"domain",hostOnly?"fixture.example":".fixture.example","path","/");cookie.addProperty("hostOnly",hostOnly);cookie.addProperty("secure",true);cookie.addProperty("httpOnly",true);cookie.addProperty("expiresAt",expiry);return cookie;}
    private static JsonObject session(String agent,JsonObject... cookies){JsonObject args=args("sourceId",SOURCE_ID,"url",ORIGIN,"userAgent",agent);JsonArray values=new JsonArray();for(JsonObject cookie:cookies)values.add(cookie);args.add("cookies",values);return args;}
    private static void verifyRestored()throws Exception{
        SourceCookieJar jar=jar();List<Cookie> parent=jar.loadForRequest(HttpUrl.get(ORIGIN)),child=jar.loadForRequest(HttpUrl.get(CHILD));
        Cookie host=named(parent,"host_cookie"),domain=named(parent,"domain_cookie");
        require(parent.size()==2&&host!=null&&domain!=null,"Browser cookies restored without stale values");
        require(host.hostOnly()&&!domain.hostOnly(),"Cookie scope survives persistence");
        require(host.secure()&&host.httpOnly()&&domain.secure()&&domain.httpOnly(),"Cookie flags survive persistence");
        require(child.size()==1&&named(child,"domain_cookie")!=null,"Host-only cookie does not leak to a child host");
        require(jar.loadForRequest(HttpUrl.get("https://other.example/reader")).isEmpty(),"Unrelated website receives no restored cookies");
        require(jar.loadForRequest(HttpUrl.get("http://fixture.example/reader")).isEmpty(),"Secure cookies do not leak to HTTP");
        require(USER_AGENT.equals(CFClearance.INSTANCE.getWebViewUserAgent()),"Browser user agent restored");
        Field field=ExtensionHost.class.getDeclaredField("application");field.setAccessible(true);
        NetworkHelper helper=new NetworkHelper((EngineApplication)field.get(null));
        require(USER_AGENT.equals(helper.getDefaultUserAgentProvider().invoke()),"Networking uses the actual restored browser user agent");
    }
    private static void rejectWithoutMutation(Path directory,JsonObject invalid)throws Exception{
        String stored=EngineFiles.sha256(directory.resolve("browser-sessions.json"));
        JsonObject response=request("browserSession",invalid);require(!response.get("ok").getAsBoolean(),"Invalid browser input is rejected");
        require(stored.equals(EngineFiles.sha256(directory.resolve("browser-sessions.json"))),"Invalid input does not replace the saved session");
        require(USER_AGENT.equals(CFClearance.INSTANCE.getWebViewUserAgent()),"Invalid input does not publish a new user agent");
        require(jar().loadForRequest(HttpUrl.get(ORIGIN)).size()==2,"Invalid input does not publish a partial cookie set");
    }
    public static void main(String[] argv)throws Exception{
        require(argv.length==3,"Usage: dataDirectory originalLegacyKomgaAPK initial|restart");
        require("1.8".equals(System.getProperty("java.specification.version")),"Use Java8 -Xint");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Interpreter proof requires -Xint");
        Path directory=Paths.get(argv[0]).toAbsolutePath();call("initialize",args("dataDirectory",directory.toString()));
        if("restart".equals(argv[2])){verifyRestored();System.out.println("BROWSER_SESSION_FRESH_JVM_RESTART_OK assertions="+assertions);System.exit(0);}
        if("cleared".equals(argv[2])){require(jar().loadForRequest(HttpUrl.get(ORIGIN)).isEmpty(),"Cookies stay cleared in fresh JVM");require("{}".equals(new String(Files.readAllBytes(directory.resolve("browser-sessions.json")),java.nio.charset.StandardCharsets.UTF_8)),"Durable browser logout remains empty");System.out.println("BROWSER_SESSION_CLEARED_RESTART_OK assertions="+assertions);System.exit(0);}
        require("initial".equals(argv[2]),"Unknown proof mode");
        Path apk=Paths.get(argv[1]).toAbsolutePath();call("install",args("apkPath",apk.toString(),"packageHash",EngineFiles.sha256(apk)));
        call("preferences",args("sourceId",SOURCE_ID));JsonObject preference=args("sourceId",SOURCE_ID,"key","Address");preference.addProperty("value","https://fixture.example");call("setPreference",preference);
        long future=System.currentTimeMillis()+TimeUnit.HOURS.toMillis(1);
        call("browserSession",session(USER_AGENT,browserCookie("host_cookie","host",true,future),browserCookie("domain_cookie","domain",false,future)));
        verifyRestored();SourceCookieJar jar=jar();
        jar.saveFromResponse(HttpUrl.get(CHILD),Collections.singletonList(cookie("domain_cookie","replacement",false,future)));
        List<Cookie> cookies=jar.loadForRequest(HttpUrl.get(ORIGIN));require(cookies.size()==2&&"replacement".equals(named(cookies,"domain_cookie").value()),"One cookie identity replaces an earlier parent/child response");
        jar.saveFromResponse(HttpUrl.get(ORIGIN),Collections.singletonList(cookie("domain_cookie","expired",false,1)));
        require(named(jar.loadForRequest(HttpUrl.get(ORIGIN)),"domain_cookie")==null,"Expired Set-Cookie removes an existing identity");
        Cookie unrelated=new Cookie.Builder().name("other_cookie").value("retained").hostOnlyDomain("other.example").path("/").expiresAt(future).build();
        jar.saveFromResponse(HttpUrl.get("https://other.example/"),Collections.singletonList(unrelated));
        call("browserSession",session(USER_AGENT));
        require(jar.loadForRequest(HttpUrl.get(ORIGIN)).isEmpty()&&jar.loadForRequest(HttpUrl.get(CHILD)).isEmpty(),"Browser logout removes stale website cookies");
        require(jar.loadForRequest(HttpUrl.get("https://other.example/")).size()==1,"Browser logout preserves unrelated website cookies");
        jar.saveFromResponse(HttpUrl.get("https://other.example/"),Collections.singletonList(new Cookie.Builder().name("other_cookie").value("expired").hostOnlyDomain("other.example").path("/").expiresAt(1).build()));
        call("browserSession",session(USER_AGENT,browserCookie("host_cookie","host",true,future),browserCookie("domain_cookie","domain",false,future),browserCookie("expired_cookie","expired",false,1)));
        require(jar.loadForRequest(HttpUrl.get(ORIGIN)).size()==2,"Expired browser cookie is not published");
        JsonObject credentials=session("Changed-Agent");credentials.addProperty("url","https://user:password@fixture.example/reader");rejectWithoutMutation(directory,credentials);
        JsonObject wrongHost=session("Changed-Agent");wrongHost.addProperty("url","https://other.example/reader");rejectWithoutMutation(directory,wrongHost);
        rejectWithoutMutation(directory,session("Bad\r\nAgent"));
        rejectWithoutMutation(directory,session(""));
        // Preferences recreate original source instances; saved browser state must be restored too.
        call("setPreference",preference);verifyRestored();
        String executable=System.getProperty("os.name").startsWith("Windows")?"java.exe":"java";
        String java=Paths.get(System.getProperty("java.home"),"bin",executable).toString();
        Process child=new ProcessBuilder(java,"-Xint","-cp",System.getProperty("java.class.path"),BrowserSessionProof.class.getName(),directory.toString(),apk.toString(),"restart").inheritIO().start();
        boolean completed=child.waitFor(60,TimeUnit.SECONDS);if(!completed)child.destroyForcibly();
        require(completed,"Fresh JVM proof completes");require(child.exitValue()==0,"Fresh JVM reloads original extension and browser session");
        call("clearSourceCache",new JsonObject());
        require(!request("clearSourceCache",args("path","/untrusted")).get("ok").getAsBoolean(),"Cleanup rejects caller paths");
        call("clearCookies",new JsonObject());
        require(jar.loadForRequest(HttpUrl.get(ORIGIN)).isEmpty(),"All shared source cookies cleared");
        call("setPreference",preference);
        require(jar.loadForRequest(HttpUrl.get(ORIGIN)).isEmpty(),"Reload cannot resurrect cleared cookies");
        Process clearedChild=new ProcessBuilder(java,"-Xint","-cp",System.getProperty("java.class.path"),BrowserSessionProof.class.getName(),directory.toString(),apk.toString(),"cleared").inheritIO().start();
        boolean clearedCompleted=clearedChild.waitFor(60,TimeUnit.SECONDS);if(!clearedCompleted)clearedChild.destroyForcibly();
        require(clearedCompleted&&clearedChild.exitValue()==0,"Fresh JVM preserves durable logout");
        System.out.println("JAVA8_BROWSER_SESSION_PROOF_OK assertions="+assertions+" no-http host-scope domain-scope dedup expiry logout atomic-validation source-reload disk-restart");System.exit(0);
    }
}
