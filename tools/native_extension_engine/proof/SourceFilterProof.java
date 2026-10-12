package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import okhttp3.Request;
import okhttp3.OkHttpClient;
import okhttp3.Interceptor;
import okio.Buffer;

/** Java8 typed-state regression plus filters from original installed APKs. */
public final class SourceFilterProof {
    private static void require(boolean valid, String message) { if (!valid) throw new AssertionError(message); }
    private static JsonElement call(String method, JsonObject args) {
        JsonObject request = new JsonObject(); request.addProperty("method", method); request.add("args", args);
        JsonObject response = new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();
        require(response.get("ok").getAsBoolean(), method + " failed: " + response.get("error"));
        return response.get("result");
    }
    private static JsonObject args(String key, String value) { JsonObject result = new JsonObject(); result.addProperty(key, value); return result; }
    private static void reject(FilterList list, String schema, JsonArray nodes) throws Exception {
        try { SourceFilterCodec.apply(list, schema, nodes); throw new AssertionError("Invalid filter was accepted"); }
        catch (IllegalArgumentException expected) {}
    }
    public static void main(String[] argv) throws Exception {
        require("1.8".equals(System.getProperty("java.specification.version")), "Java8 required");
        Filter.Text text = new Filter.Text("Title", "") {};
        Filter.CheckBox checkbox = new Filter.CheckBox("Only available", false) {};
        Filter.Select<String> select = new Filter.Select<String>("Status", new String[]{"Any", "Completed"}, 0) {};
        Filter.TriState genre = new Filter.TriState("Adventure", 0) {};
        Filter.Group<Filter<?>> group = new Filter.Group<Filter<?>>("Genres", Arrays.asList(genre)) {};
        Filter.Sort sort = new Filter.Sort("Order", new String[]{"Name", "Updated"}, null) {};
        Filter<Object> custom = new Filter<Object>("Unknown original control", new Object());
        FilterList list = new FilterList(Arrays.asList(text, checkbox, select, group, sort, custom));
        JsonObject descriptor = SourceFilterCodec.encode(list);
        String schema = descriptor.get("schema").getAsString();
        JsonArray nodes = descriptor.getAsJsonArray("filters").deepCopy();
        nodes.get(0).getAsJsonObject().addProperty("state", "selected title");
        nodes.get(1).getAsJsonObject().addProperty("state", true);
        nodes.get(2).getAsJsonObject().addProperty("state", 1);
        nodes.get(3).getAsJsonObject().getAsJsonArray("children").get(0).getAsJsonObject().addProperty("state", 2);
        JsonObject sorting = new JsonObject(); sorting.addProperty("index", 1); sorting.addProperty("ascending", true);
        nodes.get(4).getAsJsonObject().add("state", sorting);
        require(!nodes.get(5).getAsJsonObject().get("supported").getAsBoolean(), "Unknown filters must be explicit");
        require(SourceFilterCodec.apply(list, schema, nodes) == list, "Must use original Filter objects");
        require(text.getState().equals("selected title") && checkbox.getState() && select.getState() == 1 && genre.isExcluded() && sort.getState().getAscending(), "Typed states reached original objects");
        require(schema.equals(SourceFilterCodec.encode(list).get("schema").getAsString()), "State must not change structural schema");
        JsonArray invalid = nodes.deepCopy(); invalid.get(0).getAsJsonObject().addProperty("state", "must not partially apply"); invalid.get(2).getAsJsonObject().addProperty("state", 999);
        reject(list, schema, invalid); require(text.getState().equals("selected title"), "Invalid tree must not mutate original filters");
        invalid = nodes.deepCopy(); invalid.get(1).getAsJsonObject().addProperty("state", "true"); reject(list, schema, invalid);
        invalid = nodes.deepCopy(); invalid.get(2).getAsJsonObject().addProperty("state", 0.5); reject(list, schema, invalid);
        invalid = nodes.deepCopy(); invalid.get(3).getAsJsonObject().getAsJsonArray("children").get(0).getAsJsonObject().addProperty("state", 3); reject(list, schema, invalid);
        invalid = nodes.deepCopy(); invalid.get(5).getAsJsonObject().addProperty("state", "fake"); reject(list, schema, invalid);
        invalid = nodes.deepCopy(); invalid.get(2).getAsJsonObject().getAsJsonArray("values").set(1, new JsonPrimitive("Forged option")); reject(list, schema, invalid);
        reject(list, "outdated", nodes);
        System.out.println("SOURCE_FILTER_TYPED_PROOF_OK text checkbox select tristate nested sort unsupported stale atomic");
        if (argv.length == 0) return;
        require(argv.length == 3 || argv.length == 4, "dataDirectory originalAPK outputJSON [localOptionsJSON]");
        call("initialize", args("dataDirectory", Paths.get(argv[0]).toAbsolutePath().toString()));
        JsonObject installedArgs = args("apkPath", Paths.get(argv[1]).toAbsolutePath().toString()); installedArgs.addProperty("packageHash", EngineFiles.sha256(Paths.get(argv[1])));
        JsonObject installed = call("install", installedArgs).getAsJsonObject();
        String sourceId = installed.getAsJsonArray("sourceIds").get(0).getAsString();
        if (argv.length == 4) {
            JsonObject options = new JsonParser().parse(new String(Files.readAllBytes(Paths.get(argv[3])), java.nio.charset.StandardCharsets.UTF_8)).getAsJsonObject();
            if (options.has("sourceId")) sourceId = options.get("sourceId").getAsString();
            if (options.has("preferences")) for (Map.Entry<String,JsonElement> value : options.getAsJsonObject("preferences").entrySet()) {
                JsonObject preference = args("sourceId", sourceId); preference.addProperty("key", value.getKey()); preference.add("value", value.getValue()); call("setPreference", preference);
            }
        }
        JsonObject filters = call("filters", args("sourceId", sourceId)).getAsJsonObject();
        Field registryField = ExtensionHost.class.getDeclaredField("registry"); registryField.setAccessible(true);
        CatalogueSource source = ((ExtensionRegistry)registryField.get(null)).source(sourceId);
        JsonObject proof = new JsonObject(); proof.addProperty("sourceId", sourceId); proof.addProperty("originalApkSha256", EngineFiles.sha256(Paths.get(argv[1]))); proof.add("descriptor", filters); proof.addProperty("iosRuntimeVerified", false);
        OkHttpClient client = ((HttpSource)source).getClient();
        Field interceptors = OkHttpClient.class.getDeclaredField("interceptors"); interceptors.setAccessible(true);
        List<Interceptor> previous = client.interceptors(), observed = new ArrayList<>(previous);
        final List<String> requests = Collections.synchronizedList(new ArrayList<String>());
        observed.add(chain -> {
            Request request = chain.request(); Buffer body = new Buffer();
            if (request.body() != null) request.body().writeTo(body);
            String description = request.method()+"\n"+request.url()+"\n"+body.readUtf8();
            try { requests.add(EngineFiles.sha256(description.getBytes(java.nio.charset.StandardCharsets.UTF_8))); }
            catch (Exception failure) { throw new java.io.IOException(failure); }
            // Observes requests only: original HTTP client/response parser remain in use.
            return chain.proceed(request);
        });
        interceptors.set(client, Collections.unmodifiableList(observed));
        JsonObject search = args("sourceId", sourceId); search.addProperty("query", ""); search.addProperty("page", 1);
        JsonObject before = call("search", search).getAsJsonObject();
        require(!requests.isEmpty(), "Original source must make a real search HTTP request");
        String firstRequest = requests.get(requests.size()-1);
        // Current Komga refreshes options asynchronously during the first search.
        Thread.sleep(3000);
        filters = call("filters", args("sourceId", sourceId)).getAsJsonObject();
        JsonArray selected = filters.getAsJsonArray("filters").deepCopy();
        require(changeFirst(selected), "Original package must expose a selectable filter");
        search.addProperty("filterSchema", filters.get("schema").getAsString()); search.add("filters", selected);
        requests.clear();
        JsonObject after = call("search", search).getAsJsonObject();
        require(!requests.isEmpty(), "Filtered search must execute original HTTP");
        String secondRequest = requests.get(requests.size()-1);
        require(!firstRequest.equals(secondRequest), "Original HTTP request must observe selected filters");
        interceptors.set(client, previous);
        proof.addProperty("originalRequestChanged", true);
        proof.addProperty("defaultSearchCount", before.getAsJsonArray("items").size());
        proof.addProperty("filteredSearchCount", after.getAsJsonArray("items").size());
        proof.addProperty("defaultRequestSha256", firstRequest); proof.addProperty("filteredRequestSha256", secondRequest);
        proof.add("descriptor", filters); proof.addProperty("filterCount", selected.size());
        proof.addProperty("hostClassSha256", EngineFiles.sha256(Paths.get(SourceFilterProof.class.getProtectionDomain().getCodeSource().getLocation().toURI()).resolveSibling("extension-host.jar")));
        EngineFiles.write(Paths.get(argv[2]), new GsonBuilder().setPrettyPrinting().create().toJson(proof));
        System.out.println("ORIGINAL_APK_FILTER_REQUEST_PROOF_OK source=" + sourceId + " filters=" + selected.size());
        System.exit(0);
    }

    private static boolean changeFirst(JsonArray nodes) {
        for (JsonElement entry : nodes) {
            JsonObject node = entry.getAsJsonObject(); String type = node.get("type").getAsString();
            if ("select".equals(type) && node.getAsJsonArray("values").size() > 1) { node.addProperty("state", (node.get("state").getAsInt()+1)%node.getAsJsonArray("values").size()); return true; }
            if ("sort".equals(type) && node.getAsJsonArray("values").size() > 1) { JsonObject value = new JsonObject(); value.addProperty("index", 1); value.addProperty("ascending", true); node.add("state", value); return true; }
            if ("checkbox".equals(type)) { node.addProperty("state", !node.get("state").getAsBoolean()); return true; }
            if ("tristate".equals(type)) { node.addProperty("state", (node.get("state").getAsInt()+1)%3); return true; }
            if ("group".equals(type) && changeFirst(node.getAsJsonArray("children"))) return true;
        }
        return false;
    }
}
