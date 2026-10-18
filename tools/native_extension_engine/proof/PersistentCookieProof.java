package dev.tachibooks.engine;

import eu.kanade.tachiyomi.network.SourceCookieJar;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;
import okhttp3.*;

/** Real file/cold-JVM cookie regressions; no HTTP requests or original APKs. */
public final class PersistentCookieProof {
    private static final HttpUrl ORIGIN=HttpUrl.get("https://fixture.example/read/chapter");
    private static int assertions;
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static Cookie cookie(String value,long expiry){return new Cookie.Builder().name("session").value(value).domain("fixture.example").path("/read").secure().httpOnly().expiresAt(expiry).build();}
    private static String value(SourceCookieJar jar){List<Cookie> cookies=jar.loadForRequest(ORIGIN);return cookies.isEmpty()?"":cookies.get(0).value();}
    private static void child(Path file,String mode)throws Exception{
        String executable=System.getProperty("os.name").startsWith("Windows")?"java.exe":"java";
        Process child=new ProcessBuilder(Paths.get(System.getProperty("java.home"),"bin",executable).toString(),"-Xint","-cp",System.getProperty("java.class.path"),PersistentCookieProof.class.getName(),file.toString(),mode).inheritIO().start();
        boolean completed=child.waitFor(30,TimeUnit.SECONDS);if(!completed)child.destroyForcibly();
        require(completed&&child.exitValue()==0,"Fresh JVM preserves the committed cookie state: "+mode);
    }
    public static void main(String[] argv)throws Exception{
        require(argv.length>=1&&argv.length<=2,"Usage: isolatedCookieFile [restart|cleared]");
        require("1.8".equals(System.getProperty("java.specification.version")),"Use Java8");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Use interpreter");
        Path file=Paths.get(argv[0]).toAbsolutePath();
        long future=System.currentTimeMillis()+TimeUnit.DAYS.toMillis(1);
        if(argv.length==2){
            SourceCookieJar reopened=new SourceCookieJar(file);require(reopened.isPersistenceHealthy(),"Cold cookie store is valid");
            reopened.restoreFromBrowser(ORIGIN,Collections.singletonList(cookie("stale-browser",future)));
            if("restart".equals(argv[1])){
                require("server-refreshed".equals(value(reopened)),"Cold JVM retains refreshed server token over old browser snapshot");
                Cookie restored=reopened.loadForRequest(ORIGIN).get(0);
                require(restored.secure()&&restored.httpOnly()&&restored.persistent()&&!restored.hostOnly()&&"/read".equals(restored.path()),"Cookie scope and flags survive a fresh JVM");
                require(reopened.loadForRequest(HttpUrl.get("http://fixture.example/read")).isEmpty(),"Secure flag remains effective");
                require(reopened.loadForRequest(HttpUrl.get("https://fixture.example/other")).isEmpty(),"Path scope remains effective");
            }else{require("cleared".equals(argv[1])&&value(reopened).isEmpty(),"Cold JVM cannot resurrect an explicitly deleted cookie");}
            System.out.println("PERSISTENT_COOKIE_RESTART_OK mode="+argv[1]+" assertions="+assertions);System.exit(0);
        }
        Files.createDirectories(file.getParent());
        SourceCookieJar jar=new SourceCookieJar(file);
        jar.restoreFromBrowser(ORIGIN,Collections.singletonList(cookie("browser-original",future)));
        require("browser-original".equals(value(jar))&&Files.isRegularFile(file),"Legacy browser session migrates to the private store");
        jar.saveFromResponse(ORIGIN,Collections.singletonList(cookie("server-refreshed",future)));
        jar.restoreFromBrowser(ORIGIN,Collections.singletonList(cookie("browser-original",future)));
        require("server-refreshed".equals(value(jar)),"Reload keeps the server-refreshed token");
        child(file,"restart");
        jar.saveFromResponse(ORIGIN,Collections.singletonList(cookie("expired",1)));
        require(value(jar).isEmpty(),"HTTP expiry removes the live cookie");
        child(file,"cleared");
        jar.replaceFromBrowser(ORIGIN,Collections.singletonList(cookie("new-browser",future)));
        require("new-browser".equals(value(jar)),"An explicit browser login can replace a deleted cookie");
        jar.replaceFromBrowser(ORIGIN,Collections.emptyList());child(file,"cleared");
        jar.replaceFromBrowser(ORIGIN,Collections.singletonList(cookie("new-browser",future)));
        jar.clear();child(file,"cleared");
        Cookie hostCookie=new Cookie.Builder().name("host").value("session-only").hostOnlyDomain("fixture.example").path("/").build();
        jar.saveFromResponse(ORIGIN,Collections.singletonList(hostCookie));
        SourceCookieJar another=new SourceCookieJar(file);Cookie restored=another.loadForRequest(ORIGIN).get(0);
        require(restored.hostOnly()&&!restored.persistent()&&"session-only".equals(restored.value()),"Host-only and session-cookie flags round-trip");
        require(another.loadForRequest(HttpUrl.get("https://child.fixture.example/read")).isEmpty(),"Host-only cookie does not leak to a child host");
        Path emptyRegistryRoot=file.resolveSibling("empty-registry");Files.createDirectories(emptyRegistryRoot);
        ExtensionRegistry emptyRegistry=new ExtensionRegistry(emptyRegistryRoot);
        BrowserSession.initialize(emptyRegistryRoot,emptyRegistry);
        BrowserSession.clear(emptyRegistry,another);
        require(another.loadForRequest(ORIGIN).isEmpty(),"Clear removes shared cookies even when no source remains installed");
        require(new SourceCookieJar(file).loadForRequest(ORIGIN).isEmpty(),"Empty-registry clear is durable");
        byte[][] corrupt={"{".getBytes(StandardCharsets.UTF_8),"[]".getBytes(StandardCharsets.UTF_8),"null".getBytes(StandardCharsets.UTF_8),new byte[0],new byte[2*1024*1024+1],"{\"version\":2}".getBytes(StandardCharsets.UTF_8),
            "{\"version\":1,\"legacyImportDisabled\":false,\"cookies\":[],\"origins\":[123],\"identities\":[]}".getBytes(StandardCharsets.UTF_8),
            "{\"version\":1,\"legacyImportDisabled\":false,\"cookies\":[],\"origins\":[],\"identities\":[123]}".getBytes(StandardCharsets.UTF_8),
            "{\"version\":1,\"legacyImportDisabled\":false,\"cookies\":[],\"origins\":[\"fixture.example\",\"fixture.example\"],\"identities\":[]}".getBytes(StandardCharsets.UTF_8)};
        for(int i=0;i<corrupt.length;i++){
            Path bad=file.resolveSibling("invalid-"+i+".json");Files.write(bad,corrupt[i]);SourceCookieJar broken=new SourceCookieJar(bad);
            require(!broken.isPersistenceHealthy(),"Malformed or oversized cookie storage is reported unhealthy");
            broken.restoreFromBrowser(ORIGIN,Collections.singletonList(cookie("old-browser",future)));
            require(value(broken).isEmpty(),"Invalid storage does not silently replay old browser cookies");
            broken.saveFromResponse(ORIGIN,Collections.singletonList(cookie("live-only",future)));
            require("live-only".equals(value(broken)),"Optional bad storage does not disable current in-memory HTTP cookies");
            require(Arrays.equals(corrupt[i],Files.readAllBytes(bad)),"Bad input bytes remain unchanged until explicit clear");
            broken.clear();require(broken.isPersistenceHealthy()&&value(broken).isEmpty(),"Explicit clear recovers the optional store");
            try(DirectoryStream<Path> retained=Files.newDirectoryStream(bad.getParent(),bad.getFileName()+".invalid-*")){
                int count=0;for(Path snapshot:retained){count++;require(Arrays.equals(corrupt[i],Files.readAllBytes(snapshot)),"Explicit clear preserves the original invalid bytes in a separate owned file");}require(count==1,"One invalid input snapshot is retained");
            }
            require(new SourceCookieJar(bad).isPersistenceHealthy(),"Recovered cookie state can reopen");
        }
        Path directory=file.resolveSibling("not-a-cookie-file");Files.createDirectory(directory);
        SourceCookieJar invalidDirectory=new SourceCookieJar(directory);require(!invalidDirectory.isPersistenceHealthy(),"A directory is not accepted as a cookie file");
        boolean refused=false;try{invalidDirectory.clear();}catch(IllegalStateException expected){refused=true;}
        require(refused&&Files.isDirectory(directory),"Clear refuses to move or delete a directory at the private file path");
        Path blockedParent=file.resolveSibling("blocked-parent");Files.write(blockedParent,new byte[]{1});
        SourceCookieJar blocked=new SourceCookieJar(blockedParent.resolve("cookies.json"));
        blocked.saveFromResponse(ORIGIN,Collections.singletonList(cookie("memory-retained",future)));
        require(!blocked.isPersistenceHealthy()&&"memory-retained".equals(value(blocked)),"A disk write failure is visible while a finite live cookie remains usable");
        require(Arrays.equals(new byte[]{1},Files.readAllBytes(blockedParent)),"A failed store write preserves an unrelated parent file");
        SourceCookieJar bounded=new SourceCookieJar(file.resolveSibling("bounded.json"));
        List<Cookie> oversized=new ArrayList<>();for(int i=0;i<2049;i++)oversized.add(new Cookie.Builder().name("c"+i).value("v").hostOnlyDomain("fixture.example").path("/").build());
        boolean boundedFailure=false;try{bounded.saveFromResponse(ORIGIN,oversized);}catch(IllegalArgumentException expected){boundedFailure=true;}
        require(boundedFailure&&bounded.loadForRequest(ORIGIN).isEmpty(),"An over-count HTTP response is rejected before publishing a partial cookie set");
        System.out.println("PERSISTENT_COOKIE_PROOF_OK assertions="+assertions+" real-files cold-jvm expiry flags legacy-import corruption clear write-failure no-http");System.exit(0);
    }
}
