package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.model.Filter;
import eu.kanade.tachiyomi.source.model.FilterList;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Describes original Filter subclasses and applies typed state to those same objects. */
final class SourceFilterCodec {
    private static final int MAX_NODES = 2048, MAX_DEPTH = 8, MAX_VALUES = 1024;
    private SourceFilterCodec() {}

    static JsonObject encode(FilterList filters) throws Exception {
        JsonArray nodes = describe(filters, 0, new int[]{0});
        JsonObject result = new JsonObject();
        result.addProperty("schema", EngineFiles.sha256(shape(nodes).toString().getBytes(StandardCharsets.UTF_8)));
        result.add("filters", nodes);
        return result;
    }

    private static JsonArray describe(List<?> filters, int depth, int[] count) {
        if (depth > MAX_DEPTH) throw new IllegalArgumentException("Source filter nesting is too deep");
        JsonArray result = new JsonArray();
        for (Object object : filters) {
            if (++count[0] > MAX_NODES) throw new IllegalArgumentException("Source has too many filters");
            if (!(object instanceof Filter)) throw new IllegalArgumentException("Source group contains a non-filter value");
            Filter<?> filter = (Filter<?>)object;
            JsonObject node = new JsonObject();
            node.addProperty("name", text(filter.getName()));
            String type;
            if (filter instanceof Filter.Header) type = "header";
            else if (filter instanceof Filter.Separator) type = "separator";
            else if (filter instanceof Filter.Text) type = "text";
            else if (filter instanceof Filter.CheckBox) type = "checkbox";
            else if (filter instanceof Filter.TriState) type = "tristate";
            else if (filter instanceof Filter.Select) {
                type = "select";
                node.add("values", values(((Filter.Select<?>)filter).getValues()));
            } else if (filter instanceof Filter.Sort) {
                type = "sort";
                node.add("values", values(((Filter.Sort)filter).getValues()));
            } else if (filter instanceof Filter.Group) {
                List<?> children = ((Filter.Group<?>)filter).getState();
                boolean compatible = true;
                for (Object child : children) if (!(child instanceof Filter)) compatible = false;
                type = compatible ? "group" : "unsupported";
                if (compatible) node.add("children", describe(children, depth + 1, count));
            } else type = "unsupported";
            node.addProperty("type", type);
            node.addProperty("supported", !"unsupported".equals(type));
            if ("unsupported".equals(type)) node.addProperty("className", filter.getClass().getName());
            else if (!"group".equals(type) && !"header".equals(type) && !"separator".equals(type)) {
                if (filter instanceof Filter.Sort) {
                    Filter.Sort.Selection selection = ((Filter.Sort)filter).getState();
                    if (selection == null) node.add("state", JsonNull.INSTANCE);
                    else {
                        JsonObject state = new JsonObject();
                        state.addProperty("index", selection.getIndex());
                        state.addProperty("ascending", selection.getAscending());
                        node.add("state", state);
                    }
                } else node.add("state", EngineFiles.JSON.toJsonTree(filter.getState()));
            }
            result.add(node);
        }
        return result;
    }

    private static String text(Object value) {
        String text = value == null ? "" : value.toString();
        if (text.length() > 8192) throw new IllegalArgumentException("Source filter text is too long");
        return text;
    }

    private static JsonArray values(Object[] values) {
        if (values.length > MAX_VALUES) throw new IllegalArgumentException("Source filter has too many options");
        JsonArray result = new JsonArray();
        for (Object value : values) result.add(text(value));
        return result;
    }

    private static JsonArray shape(JsonArray nodes) {
        return shape(nodes, 0, new int[]{0});
    }

    private static JsonArray shape(JsonArray nodes, int depth, int[] count) {
        if (depth > MAX_DEPTH) throw new IllegalArgumentException("Source filter nesting is too deep");
        JsonArray result = new JsonArray();
        for (JsonElement element : nodes) {
            if (++count[0] > MAX_NODES) throw new IllegalArgumentException("Source has too many filters");
            JsonObject node = element.getAsJsonObject().deepCopy();
            node.remove("state");
            if (node.has("children")) node.add("children", shape(node.getAsJsonArray("children"), depth + 1, count));
            result.add(node);
        }
        return result;
    }

    static FilterList apply(FilterList originals, String schema, JsonArray selected) throws Exception {
        JsonObject current = encode(originals);
        if (!current.get("schema").getAsString().equals(schema))
            throw new IllegalArgumentException("Source filters changed. Reload filters before searching.");
        if (!shape(current.getAsJsonArray("filters")).equals(shape(selected)))
            throw new IllegalArgumentException("Selected filters do not match the original source filters");
        List<Runnable> updates = new ArrayList<>();
        applyNodes(originals, selected, updates);
        // Validate the whole tree before changing cached original Filter objects.
        for (Runnable update : updates) update.run();
        return originals;
    }

    @SuppressWarnings({"rawtypes", "unchecked"})
    private static void applyNodes(List<?> originals, JsonArray selected, List<Runnable> updates) {
        for (int i = 0; i < originals.size(); i++) {
            final Filter filter = (Filter)originals.get(i);
            JsonObject node = selected.get(i).getAsJsonObject();
            String type = node.get("type").getAsString();
            if ("group".equals(type)) { applyNodes((List<?>)filter.getState(), node.getAsJsonArray("children"), updates); continue; }
            if ("header".equals(type) || "separator".equals(type) || "unsupported".equals(type)) {
                if (node.has("state")) throw new IllegalArgumentException("This filter cannot be changed by the engine");
                continue;
            }
            JsonElement state = node.get("state");
            if (state == null) throw new IllegalArgumentException("Filter state is missing");
            final Object typed;
            switch (type) {
                case "text":
                    if (!state.isJsonPrimitive() || !state.getAsJsonPrimitive().isString()) throw new IllegalArgumentException("Text filter requires a string");
                    typed = text(state.getAsString()); break;
                case "checkbox":
                    typed = bool(state); break;
                case "tristate":
                    typed = integer(state, 3); break;
                case "select":
                    typed = integer(state, ((Filter.Select<?>)filter).getValues().length); break;
                case "sort":
                    if (state.isJsonNull()) typed = null;
                    else {
                        JsonObject value = state.getAsJsonObject();
                        if (value.size() != 2) throw new IllegalArgumentException("Sort state requires index and direction");
                        typed = new Filter.Sort.Selection(integer(value.get("index"), ((Filter.Sort)filter).getValues().length), bool(value.get("ascending")));
                    }
                    break;
                default: throw new IllegalArgumentException("Unsupported source filter type");
            }
            updates.add(() -> filter.setState(typed));
        }
    }

    private static boolean bool(JsonElement value) {
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isBoolean())
            throw new IllegalArgumentException("Boolean filter requires true or false");
        return value.getAsBoolean();
    }

    private static int integer(JsonElement value, int bound) {
        if (value == null || !value.isJsonPrimitive() || !value.getAsJsonPrimitive().isNumber())
            throw new IllegalArgumentException("Filter index requires a number");
        double number = value.getAsDouble();
        if (!Double.isFinite(number) || number != Math.floor(number) || number < 0 || number >= bound)
            throw new IllegalArgumentException("Filter index is outside its original options");
        return (int)number;
    }
}
