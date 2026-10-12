import eu.kanade.tachiyomi.source.Source;
import eu.kanade.tachiyomi.source.SourceFactory;
import eu.kanade.tachiyomi.source.model.*;
import java.lang.reflect.Modifier;
import java.net.URLClassLoader;
import java.nio.file.Paths;

/** Runs getFilterList from the converted original APK, without website requests. */
public final class OriginalFilterProof {
    private static void require(boolean result, String reason) {
        if (!result) throw new AssertionError(reason);
    }
    public static void main(String[] args) throws Exception {
        require(System.getProperty("java.specification.version").equals("1.8"), "Use Java8 verifier");
        require(Modifier.isAbstract(Filter.Select.class.getModifiers()), "Official Select must remain abstract");
        require(Modifier.isAbstract(Filter.Group.class.getModifiers()), "Official Group must remain abstract");
        require(Modifier.isAbstract(Filter.Sort.class.getModifiers()), "Official Sort must remain abstract");
        try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{Paths.get(args[0]).toUri().toURL()}, OriginalFilterProof.class.getClassLoader())) {
            Source source = (Source) loader.loadClass("keiyoushi.source.Generated").getConstructor().newInstance();
            require(Long.toString(source.getId()).equals("2553532324170433933"), "Original source ID");
            FilterList filters = source.getFilterList();
            require(filters.size() == 6, "Original filter count");
            require(filters.get(1) instanceof Filter.Select && !filters.get(1).getClass().equals(Filter.Select.class), "Concrete country filter");
            require(((Filter.Select<?>) filters.get(1)).getValues().length == 6, "Original country values");
            require(filters.get(4) instanceof Filter.Sort && !filters.get(4).getClass().equals(Filter.Sort.class), "Concrete sort filter");
            require(filters.get(5) instanceof Filter.Group && !filters.get(5).getClass().equals(Filter.Group.class), "Concrete genre group");
            System.out.println("JAVA8_ORIGINAL_APK_FILTER_PROOF_OK source=" + source.getName() + " id=" + source.getId() + " filters=" + filters.size());
        }
        if (args.length >= 3) {
            // Initialize the maintained host's Android preferences/injection,
            // then execute the original legacy factory without website traffic.
            com.google.gson.JsonObject values = new com.google.gson.JsonObject();
            values.addProperty("dataDirectory", Paths.get(args[2]).toAbsolutePath().toString());
            com.google.gson.JsonObject request = new com.google.gson.JsonObject();
            request.addProperty("method", "initialize"); request.add("args", values);
            Object initialized = Class.forName("dev.tachibooks.engine.ExtensionHost")
                    .getMethod("invoke", String.class).invoke(null, request.toString());
            require(!initialized.toString().contains("\"ok\":false"), "Host initialization");
            try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{Paths.get(args[1]).toUri().toURL()}, OriginalFilterProof.class.getClassLoader())) {
                SourceFactory factory = (SourceFactory) loader.loadClass("eu.kanade.tachiyomi.extension.all.komga.KomgaFactory")
                        .getConstructor().newInstance();
                java.util.List<Source> sources = factory.createSources();
                require(!sources.isEmpty(), "Legacy original factory sources");
                for (Source source : sources) {
                    require(source.getName().contains("Komga"), "Legacy source metadata");
                    require(source.getFilterList() != null, "Legacy original filter implementation");
                }
                System.out.println("JAVA8_LEGACY_ORIGINAL_APK_FACTORY_PROOF_OK sources=" + sources.size());
            }
        }
    }
}
