package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.online.HttpSource;
import eu.kanade.tachiyomi.network.SourceCookieJar;
import eu.kanade.tachiyomi.network.interceptor.CFClearance;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.security.MessageDigest;
import okhttp3.*;

/** Shares only the selected website's cookies after an explicit native browser action. */
final class BrowserSession {
    private static Path storage;
    private static JsonObject sessions = new JsonObject();
    private static final Map<String,Seed> seeds=new LinkedHashMap<>();
    private static final class Seed {
        final CatalogueSource source;final HttpUrl origin;final SourceCookieJar jar;final String fingerprint;final long created;
        Seed(CatalogueSource source,HttpUrl origin,SourceCookieJar jar,String fingerprint){this.source=source;this.origin=origin;this.jar=jar;this.fingerprint=fingerprint;this.created=System.currentTimeMillis();}
    }
    static JsonPrimitive clear(ExtensionRegistry registry) throws IOException {
        return clear(registry,null);
    }
    static JsonPrimitive clear(ExtensionRegistry registry,CookieJar shared) throws IOException {
        // Persist logout before clearing live jars so a restart cannot restore
        // cookies the user explicitly removed. Package preferences stay intact.
        EngineFiles.write(storage, "{}");
        sessions = new JsonObject();
        seeds.clear();
        Set<SourceCookieJar> cleared = Collections.newSetFromMap(new IdentityHashMap<SourceCookieJar,Boolean>());
        if(shared instanceof SourceCookieJar){cleared.add((SourceCookieJar)shared);((SourceCookieJar)shared).clear();}
        for (CatalogueSource source : registry.sources()) {
            if (source instanceof HttpSource) {
                CookieJar jar = ((HttpSource)source).getClient().cookieJar();
                if (jar instanceof SourceCookieJar && cleared.add((SourceCookieJar)jar)) ((SourceCookieJar)jar).clear();
            }
        }
        return new JsonPrimitive(true);
    }
    static JsonPrimitive resetUserAgents() throws IOException {
        JsonObject next=sessions.deepCopy();
        for(Map.Entry<String,JsonElement> entry:next.entrySet())
            if(entry.getValue().isJsonObject())entry.getValue().getAsJsonObject().remove("userAgent");
        // Publish only after persistence succeeds: a cold restart must not
        // resurrect an override reported as reset. Cookie fields stay intact.
        EngineFiles.write(storage,EngineFiles.JSON.toJson(next));
        sessions=next;
        seeds.clear();
        CFClearance.INSTANCE.resetWebViewUserAgents();
        return new JsonPrimitive(true);
    }
    static void initialize(Path directory, ExtensionRegistry registry) throws IOException {
        storage = directory.resolve("browser-sessions.json");
        sessions = new JsonObject();
        if (Files.exists(storage)) {
            if (Files.size(storage) > 1024 * 1024) {
                retainCorruptStorage();
            } else {
                try {
                    sessions = new JsonParser().parse(new String(Files.readAllBytes(storage), StandardCharsets.UTF_8)).getAsJsonObject();
                } catch (RuntimeException invalid) {
                    retainCorruptStorage();
                }
            }
            for (Map.Entry<String,JsonElement> entry : sessions.entrySet()) {
                // Retain unknown/malformed records for compatibility, without
                // letting optional browser state prevent registry startup.
                if (!entry.getValue().isJsonObject()) continue;
                try { publish(prepare(entry.getValue().getAsJsonObject(), registry.source(entry.getKey()),true),true); }
                catch (IllegalArgumentException ignored) { /* An uninstalled source retains its saved session. */ }
            }
        }
    }
    private static void retainCorruptStorage() throws IOException {
        // Browser cookies are optional. Preserve the exact invalid input before
        // starting without it, so health/cleanup and offline reading stay usable.
        // An I/O error still aborts initialization; never overwrite unreadable data.
        Path retained = storage.resolveSibling("browser-sessions.corrupt-" + UUID.randomUUID() + ".json");
        Files.move(storage, retained, StandardCopyOption.ATOMIC_MOVE);
        sessions = new JsonObject();
    }
    static JsonPrimitive apply(JsonObject args, CatalogueSource source) throws IOException {
        Session prepared = prepare(args, source);
        CookieJar jar=prepared.source.getClient().cookieJar();
        // SourceCookieJar's HTTP callbacks use this same monitor. A refresh
        // cannot land between the token comparison and browser replacement.
        synchronized(jar){
            if(args.has("seedToken")){
                Seed seed=seeds.remove(required(args,"seedToken"));
                if(seed==null||seed.source!=source||seed.jar!=jar||!seed.origin.equals(prepared.origin)||System.currentTimeMillis()-seed.created>5*60*1000||
                    !seed.fingerprint.equals(fingerprint(seed.jar,prepared.origin)))
                    throw new IllegalArgumentException("The source session changed. Open the browser again.");
            }
            if(jar instanceof SourceCookieJar)((SourceCookieJar)jar).validateBrowserReplacement(prepared.origin,prepared.cookies);
            JsonObject next = sessions.deepCopy();
            next.add(Long.toString(source.getId()), args.deepCopy());
            String encoded = EngineFiles.JSON.toJson(next);
            if (encoded.getBytes(StandardCharsets.UTF_8).length > 1024 * 1024) throw new IOException("Browser sessions exceed limit");
            Path rollback=null;boolean preserveRollback=false;
            boolean existed=Files.exists(storage,LinkOption.NOFOLLOW_LINKS);
            if(existed){
                if(!Files.isRegularFile(storage,LinkOption.NOFOLLOW_LINKS))throw new IOException("Browser sessions are not a file");
                rollback=Files.createTempFile(storage.getParent(),".browser-session-rollback-",".json");
                Files.copy(storage,rollback,StandardCopyOption.REPLACE_EXISTING);
            }
            try{
                EngineFiles.write(storage, encoded);
                try{
                    if(jar instanceof SourceCookieJar)((SourceCookieJar)jar).replaceFromBrowserChecked(prepared.origin,prepared.cookies);
                    else jar.saveFromResponse(prepared.origin,prepared.cookies);
                }catch(IOException|RuntimeException failure){
                    try{if(existed){Files.move(rollback,storage,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);rollback=null;}else Files.deleteIfExists(storage);}
                    catch(IOException recovery){preserveRollback=true;failure.addSuppressed(recovery);}
                    throw failure;
                }
                CFClearance.INSTANCE.setWebViewUserAgentForHost(prepared.origin.host(),prepared.agent);
                sessions = next;
                return new JsonPrimitive(true);
            }finally{if(rollback!=null&&!preserveRollback)Files.deleteIfExists(rollback);}
        }
    }
    static JsonObject seed(JsonObject args,CatalogueSource source)throws IOException{
        if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source has no HTTP cookie store");
        HttpSource http=(HttpSource)source;HttpUrl base=HttpUrl.get(http.getBaseUrl()),origin=HttpUrl.get(required(args,"url"));
        if(!base.host().equals(origin.host())||!base.scheme().equals(origin.scheme())||base.port()!=origin.port()||!origin.username().isEmpty()||!origin.password().isEmpty())
            throw new IllegalArgumentException("Browser origin does not match source");
        CookieJar jar=http.getClient().cookieJar();
        if(!(jar instanceof SourceCookieJar))throw new IllegalArgumentException("Source cookie store cannot export a complete browser session");
        synchronized(jar){
            JsonObject result=new JsonObject();result.addProperty("url",origin.toString());
            String agent=CFClearance.INSTANCE.getWebViewUserAgentForHost(origin.host());
            if(agent!=null)result.addProperty("userAgent",agent);
            JsonArray cookies=cookieValues(((SourceCookieJar)jar).snapshotForBrowser(origin));
            result.add("cookies",cookies);
            String token=UUID.randomUUID().toString();
            while(seeds.size()>=32)seeds.remove(seeds.keySet().iterator().next());
            seeds.put(token,new Seed(source,origin,(SourceCookieJar)jar,fingerprint(cookies,agent)));
            result.addProperty("seedToken",token);return result;
        }
    }
    private static JsonArray cookieValues(List<Cookie> cookies){
        JsonArray result=new JsonArray();
        for(Cookie cookie:cookies){JsonObject item=new JsonObject();item.addProperty("name",cookie.name());item.addProperty("value",cookie.value());item.addProperty("domain",cookie.domain());item.addProperty("path",cookie.path());item.addProperty("hostOnly",cookie.hostOnly());item.addProperty("secure",cookie.secure());item.addProperty("httpOnly",cookie.httpOnly());if(cookie.persistent())item.addProperty("expiresAt",cookie.expiresAt());result.add(item);}
        return result;
    }
    private static String fingerprint(SourceCookieJar jar,HttpUrl origin)throws IOException{
        return fingerprint(cookieValues(jar.snapshotForBrowser(origin)),CFClearance.INSTANCE.getWebViewUserAgentForHost(origin.host()));
    }
    private static String fingerprint(JsonArray cookies,String agent)throws IOException{
        String snapshot=cookies.toString()+"\n"+agent;
        try{byte[] value=MessageDigest.getInstance("SHA-256").digest(snapshot.getBytes(StandardCharsets.UTF_8));StringBuilder out=new StringBuilder();for(byte b:value)out.append(String.format(Locale.ROOT,"%02x",b&255));return out.toString();}
        catch(java.security.NoSuchAlgorithmException impossible){throw new IOException(impossible);}
    }
    private static final class Session {
        final HttpSource source;
        final HttpUrl origin;
        final List<Cookie> cookies;
        final String agent;
        Session(HttpSource source, HttpUrl origin, List<Cookie> cookies, String agent) {
            this.source=source;this.origin=origin;this.cookies=cookies;this.agent=agent;
        }
    }
    private static Session prepare(JsonObject args, CatalogueSource source) {
        return prepare(args,source,false);
    }
    private static Session prepare(JsonObject args, CatalogueSource source,boolean restoring) {
        if (!(source instanceof HttpSource)) throw new IllegalArgumentException("Source has no HTTP cookie store");
        HttpSource http = (HttpSource)source;
        HttpUrl origin = HttpUrl.get(required(args,"url"));
        HttpUrl base = HttpUrl.get(http.getBaseUrl());
        if (!origin.host().equals(base.host()) || !origin.username().isEmpty() || !origin.password().isEmpty()) throw new IllegalArgumentException("Browser origin does not match source");
        JsonArray values = args.getAsJsonArray("cookies");
        if (values == null || values.size() > 512) throw new IllegalArgumentException("Invalid browser cookie count");
        String agent = restoring&&!args.has("userAgent")?null:required(args,"userAgent");
        if (agent!=null&&(agent.isEmpty() || agent.length()>1024 || agent.indexOf('\r')>=0 || agent.indexOf('\n')>=0))
            throw new IllegalArgumentException("Invalid browser user agent");
        List<Cookie> cookies = new ArrayList<>();
        for (JsonElement value : values) {
            JsonObject item = value.getAsJsonObject();
            String domain = required(item,"domain").toLowerCase(Locale.ROOT);
            while (domain.startsWith(".")) domain = domain.substring(1);
            boolean hostOnly = item.has("hostOnly") && item.get("hostOnly").getAsBoolean();
            if (!origin.host().equals(domain) && (hostOnly || !origin.host().endsWith("." + domain))) continue;
            String name = required(item,"name"), text = required(item,"value");
            if (name.length() + text.length() > 4096) throw new IllegalArgumentException("Browser cookie exceeds limit");
            Cookie.Builder builder = new Cookie.Builder().name(name).value(text);
            if (hostOnly) builder.hostOnlyDomain(domain); else builder.domain(domain);
            builder.path(item.has("path") ? required(item,"path") : "/");
            if (item.has("secure") && item.get("secure").getAsBoolean()) builder.secure();
            if (item.has("httpOnly") && item.get("httpOnly").getAsBoolean()) builder.httpOnly();
            if (item.has("expiresAt") && !item.get("expiresAt").isJsonNull()) builder.expiresAt(item.get("expiresAt").getAsLong());
            Cookie cookie = builder.build();
            if (cookie.expiresAt() > System.currentTimeMillis()) cookies.add(cookie);
        }
        return new Session(http,origin,cookies,agent);
    }
    private static String required(JsonObject object, String key) {
        JsonElement value=object.get(key);
        if(value==null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isString())
            throw new IllegalArgumentException("Invalid browser field: "+key);
        return value.getAsString();
    }
    private static void publish(Session session,boolean restoring) {
        if(session.agent!=null)CFClearance.INSTANCE.setWebViewUserAgentForHost(session.origin.host(),session.agent);
        CookieJar jar = session.source.getClient().cookieJar();
        if (jar instanceof SourceCookieJar) {if(restoring)((SourceCookieJar)jar).restoreFromBrowser(session.origin,session.cookies);else ((SourceCookieJar)jar).replaceFromBrowser(session.origin,session.cookies);}
        else jar.saveFromResponse(session.origin,session.cookies);
    }
}
