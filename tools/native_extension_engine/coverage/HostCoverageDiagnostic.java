import java.lang.reflect.Field;
import java.lang.reflect.InvocationTargetException;
import java.lang.reflect.Method;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Collection;

/** Debug-only stack evidence for a real installation or preference failure. */
public final class HostCoverageDiagnostic {
    public static void main(String[] args) {
        int status = 0;
        try {
            Class<?> host = Class.forName("dev.tachibooks.engine.ExtensionHost");
            String data = Paths.get(args[0]).toAbsolutePath().toString()
                    .replace("\\", "\\\\").replace("\"", "\\\"");
            System.out.println(host.getMethod("invoke", String.class).invoke(null,
                    "{\"method\":\"initialize\",\"args\":{\"dataDirectory\":\"" + data + "\"}}"));
            Field field = host.getDeclaredField("registry");
            field.setAccessible(true);
            Object registry = field.get(null);
            Method install = registry.getClass().getDeclaredMethod("install", Path.class,
                    String.class, String.class, String.class);
            install.setAccessible(true);
            System.out.println(install.invoke(registry, Paths.get(args[1]), "", "", args[2]));
            Method sources = registry.getClass().getDeclaredMethod("sources");
            sources.setAccessible(true);
            Field application = host.getDeclaredField("application");
            application.setAccessible(true);
            Class<?> screen = Class.forName("androidx.preference.PreferenceScreen");
            Class<?> configurable = Class.forName("eu.kanade.tachiyomi.source.ConfigurableSource");
            int count = 0;
            for (Object source : (Collection<?>) sources.invoke(registry)) {
                if (!configurable.isInstance(source)) continue;
                Object value = screen.getConstructor(Class.forName("android.content.Context"))
                        .newInstance(application.get(null));
                configurable.getMethod("setupPreferenceScreen", screen).invoke(source, value);
                System.out.println("PREFERENCE_SCREEN_PASS=" + source.getClass().getName());
                if (++count == 3) break;
            }
        } catch (Throwable failure) {
            status = 1;
            while (failure instanceof InvocationTargetException && failure.getCause() != null) {
                failure = failure.getCause();
            }
            failure.printStackTrace();
        }
        System.exit(status);
    }
}
