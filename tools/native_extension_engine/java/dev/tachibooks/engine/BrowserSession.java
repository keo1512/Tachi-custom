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
import okhttp3.*;

/** Shares only the selected website's cookies after an explicit native browser action. */
final class BrowserSession {
    private static Path storage;
    private static JsonObject sessions = new JsonObject();
    static JsonPrimitive clear(ExtensionRegistry registry) throws IOException {
        // Persist logout before clearing live jars so a restart cannot restore
        // cookies the user explicitly removed. Package preferences stay intact.
        EngineFiles.write(storage, "{}");
        sessions = new JsonObject();
        Set<SourceCookieJar> cleared = Collections.newSetFromMap(new IdentityHashMap<SourceCookieJar,Boolean>());
        for (CatalogueSource source : registry.sources()) {
            if (source instanceof HttpSource) {
                CookieJar jar = ((HttpSource)source).getClient().cookieJar();
                if (jar instanceof SourceCookieJar && cleared.add((SourceCookieJar)jar)) ((SourceCookieJar)jar).clear();
            }
        }
        return new JsonPrimitive(true);
    }
    static void initialize(Path directory, ExtensionRegistry registry) throws IOException {
        storage = directory.resolve("browser-sessions.json");
        sessions = new JsonObject();
        if (Files.exists(storage)) {
            if (Files.size(storage) > 1024 * 1024) throw new IOException("Browser session file exceeds limit");
            try {
                sessions = new JsonParser().parse(new String(Files.readAllBytes(storage), StandardCharsets.UTF_8)).getAsJsonObject();
            } catch (RuntimeException invalid) {
                throw new IOException("Saved browser sessions are invalid; input retained", invalid);
            }
            for (Map.Entry<String,JsonElement> entry : sessions.entrySet()) {
                try { publish(prepare(entry.getValue().getAsJsonObject(), registry.source(entry.getKey()))); }
                catch (IllegalArgumentException ignored) { /* An uninstalled source retains its saved session. */ }
            }
        }
    }
    static JsonPrimitive apply(JsonObject args, CatalogueSource source) throws IOException {
        Session prepared = prepare(args, source);
        JsonObject next = sessions.deepCopy();
        next.add(Long.toString(source.getId()), args.deepCopy());
        String encoded = EngineFiles.JSON.toJson(next);
        if (encoded.getBytes(StandardCharsets.UTF_8).length > 1024 * 1024) throw new IOException("Browser sessions exceed limit");
        EngineFiles.write(storage, encoded);
        sessions = next;
        publish(prepared);
        return new JsonPrimitive(true);
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
        if (!(source instanceof HttpSource)) throw new IllegalArgumentException("Source has no HTTP cookie store");
        HttpSource http = (HttpSource)source;
        HttpUrl origin = HttpUrl.get(required(args,"url"));
        HttpUrl base = HttpUrl.get(http.getBaseUrl());
        if (!origin.host().equals(base.host()) || !origin.username().isEmpty() || !origin.password().isEmpty()) throw new IllegalArgumentException("Browser origin does not match source");
        JsonArray values = args.getAsJsonArray("cookies");
        if (values == null || values.size() > 512) throw new IllegalArgumentException("Invalid browser cookie count");
        String agent = required(args,"userAgent");
        if (agent.isEmpty() || agent.length()>1024 || agent.indexOf('\r')>=0 || agent.indexOf('\n')>=0)
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
    private static void publish(Session session) {
        CFClearance.INSTANCE.setWebViewUserAgent(session.agent);
        CookieJar jar = session.source.getClient().cookieJar();
        if (jar instanceof SourceCookieJar) ((SourceCookieJar)jar).replaceFromBrowser(session.origin,session.cookies);
        else jar.saveFromResponse(session.origin,session.cookies);
    }
}
