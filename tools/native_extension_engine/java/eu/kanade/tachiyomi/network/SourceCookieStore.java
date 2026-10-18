package eu.kanade.tachiyomi.network;

import com.google.gson.*;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import okhttp3.Cookie;

/** Private device-local cookie persistence. Never part of portable preferences. */
final class SourceCookieStore {
    static final int MAX_BYTES=2*1024*1024,MAX_COOKIES=2048,MAX_IDENTITIES=8192,MAX_ORIGINS=2048;
    final Path path;
    SourceCookieStore(Path path){this.path=path.toAbsolutePath().normalize();}
    static final class State {
        final Map<String,Cookie> cookies=new LinkedHashMap<>();
        final Set<String> origins=new LinkedHashSet<>(),identities=new LinkedHashSet<>();
        boolean legacyImportDisabled;
    }
    State load()throws IOException{
        State state=new State();
        if(!Files.exists(path,LinkOption.NOFOLLOW_LINKS))return state;
        if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS)||Files.size(path)>MAX_BYTES)throw new IOException("Invalid private cookie storage");
        try{
            JsonObject root=new JsonParser().parse(new String(Files.readAllBytes(path),StandardCharsets.UTF_8)).getAsJsonObject();
            if(!root.get("version").isJsonPrimitive()||!root.get("version").getAsJsonPrimitive().isNumber()||root.get("version").getAsBigDecimal().intValueExact()!=1)throw new IllegalArgumentException("Unsupported cookie storage version");
            state.legacyImportDisabled=bool(root,"legacyImportDisabled");
            JsonArray cookies=root.getAsJsonArray("cookies"),origins=root.getAsJsonArray("origins"),identities=root.getAsJsonArray("identities");
            if(cookies==null||origins==null||identities==null||cookies.size()>MAX_COOKIES||origins.size()>MAX_ORIGINS||identities.size()>MAX_IDENTITIES)throw new IllegalArgumentException("Invalid cookie storage counts");
            for(JsonElement value:cookies){
                JsonObject item=value.getAsJsonObject();String domain=text(item,"domain"),name=text(item,"name"),content=text(item,"value"),cookiePath=text(item,"path");
                Cookie.Builder builder=new Cookie.Builder().name(name).value(content).path(cookiePath);
                if(bool(item,"hostOnly"))builder.hostOnlyDomain(domain);else builder.domain(domain);
                if(bool(item,"secure"))builder.secure();if(bool(item,"httpOnly"))builder.httpOnly();
                if(!item.get("expiresAt").isJsonPrimitive()||!item.get("expiresAt").getAsJsonPrimitive().isNumber())throw new IllegalArgumentException("Invalid cookie expiry");
                long expiry=item.get("expiresAt").getAsBigDecimal().longValueExact();
                if(expiry<0)throw new IllegalArgumentException("Invalid cookie expiry");
                boolean persistent=bool(item,"persistent");
                if(persistent)builder.expiresAt(expiry);
                Cookie cookie=builder.build();validateCookie(cookie);
                if(!persistent&&cookie.expiresAt()!=expiry)throw new IllegalArgumentException("Invalid session cookie expiry");
                if(state.cookies.put(key(cookie),cookie)!=null)throw new IllegalArgumentException("Duplicate cookie identity");
            }
            for(JsonElement origin:origins){if(!origin.isJsonPrimitive()||!origin.getAsJsonPrimitive().isString())throw new IllegalArgumentException("Invalid cookie origin type");String host=origin.getAsString();if(host.isEmpty()||host.length()>253||!host.equals(new okhttp3.HttpUrl.Builder().scheme("https").host(host).build().host())||!state.origins.add(host))throw new IllegalArgumentException("Invalid cookie origin");}
            for(JsonElement identity:identities){if(!identity.isJsonPrimitive()||!identity.getAsJsonPrimitive().isString())throw new IllegalArgumentException("Invalid cookie identity type");String key=identity.getAsString();if(key.length()>4608||key.split("\u0000",-1).length!=3||!state.identities.add(key))throw new IllegalArgumentException("Invalid cookie identity");}
            if(!state.identities.containsAll(state.cookies.keySet()))throw new IllegalArgumentException("Missing cookie identity authority");
            return state;
        }catch(RuntimeException invalid){throw new IOException("Invalid private cookie storage",invalid);}
    }
    void write(State state)throws IOException{
        byte[] bytes=encode(state);
        Files.createDirectories(path.getParent());
        Path pending=Files.createTempFile(path.getParent(),".cookie-pending-",".json");
        try{
            try(FileOutputStream stream=new FileOutputStream(pending.toFile())){stream.write(bytes);stream.getFD().sync();}
            Files.move(pending,path,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);
        }finally{Files.deleteIfExists(pending);}
    }
    void clearAfterInvalid(State empty)throws IOException{
        Path retained=null;
        if(Files.exists(path,LinkOption.NOFOLLOW_LINKS)){
            if(!Files.isRegularFile(path,LinkOption.NOFOLLOW_LINKS))throw new IOException("Private cookie storage is not a file");
            retained=path.resolveSibling(path.getFileName()+".invalid-"+UUID.randomUUID().toString());
            Files.move(path,retained,StandardCopyOption.ATOMIC_MOVE);
        }
        try{write(empty);}catch(IOException failure){
            if(retained!=null&&!Files.exists(path,LinkOption.NOFOLLOW_LINKS)){
                try{Files.move(retained,path,StandardCopyOption.ATOMIC_MOVE);}catch(IOException restore){failure.addSuppressed(restore);}
            }
            throw failure;
        }
    }
    static byte[] encode(State state)throws IOException{
        if(state.cookies.size()>MAX_COOKIES||state.origins.size()>MAX_ORIGINS||state.identities.size()>MAX_IDENTITIES)throw new IOException("Private cookie storage exceeds limits");
        JsonObject root=new JsonObject();root.addProperty("version",1);root.addProperty("legacyImportDisabled",state.legacyImportDisabled);
        JsonArray cookies=new JsonArray(),origins=new JsonArray(),identities=new JsonArray();
        for(Cookie cookie:state.cookies.values()){
            validateCookie(cookie);JsonObject item=new JsonObject();item.addProperty("name",cookie.name());item.addProperty("value",cookie.value());item.addProperty("domain",cookie.domain());item.addProperty("path",cookie.path());item.addProperty("expiresAt",cookie.expiresAt());item.addProperty("secure",cookie.secure());item.addProperty("httpOnly",cookie.httpOnly());item.addProperty("hostOnly",cookie.hostOnly());item.addProperty("persistent",cookie.persistent());cookies.add(item);
        }
        for(String host:state.origins)origins.add(host);for(String key:state.identities)identities.add(key);
        root.add("cookies",cookies);root.add("origins",origins);root.add("identities",identities);
        byte[] encoded=new Gson().toJson(root).getBytes(StandardCharsets.UTF_8);
        if(encoded.length>MAX_BYTES)throw new IOException("Private cookie storage exceeds limits");
        return encoded;
    }
    static String key(Cookie cookie){return cookie.domain()+"\u0000"+cookie.path()+"\u0000"+cookie.name();}
    static void validateCookie(Cookie cookie){if(cookie.domain().length()>253||cookie.path().length()>4096||cookie.name().length()+cookie.value().length()>4096)throw new IllegalArgumentException("Cookie exceeds limits");}
    private static String text(JsonObject object,String key){JsonElement value=object.get(key);if(value==null||!value.isJsonPrimitive()||!value.getAsJsonPrimitive().isString())throw new IllegalArgumentException("Invalid cookie field");return value.getAsString();}
    private static boolean bool(JsonObject object,String key){JsonElement value=object.get(key);if(value==null||!value.isJsonPrimitive()||!value.getAsJsonPrimitive().isBoolean())throw new IllegalArgumentException("Invalid cookie flag");return value.getAsBoolean();}
}
