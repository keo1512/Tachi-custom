import java.io.BufferedReader;
import java.io.InputStreamReader;
import java.io.PrintStream;
import java.lang.reflect.Method;
import java.nio.charset.StandardCharsets;
import java.util.concurrent.atomic.AtomicBoolean;

/** Line transport for the real host. Deliberately has no mock/source implementations. */
public final class HostCoverageBridge {
    public static void main(String[] args) throws Exception {
        // The Dart/Python transports use UTF-8 on every host. Java8 on Windows
        // otherwise inherits the local code page and corrupts preference labels.
        System.setOut(new PrintStream(System.out, true, "UTF-8"));
        System.setErr(new PrintStream(System.err, true, "UTF-8"));
        final AtomicBoolean backgroundFailure = new AtomicBoolean(false);
        Thread.setDefaultUncaughtExceptionHandler((thread, failure) -> {
            backgroundFailure.set(true);
            System.err.println("TACHI_UNCAUGHT\t" + thread.getName() + "\t" + failure.getClass().getName());
            failure.printStackTrace(System.err);
        });
        Method invoke = Class.forName("dev.tachibooks.engine.ExtensionHost")
                .getMethod("invoke", String.class);
        BufferedReader input = new BufferedReader(
                new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = input.readLine()) != null) {
            System.out.println("TACHI_COVERAGE\t" + invoke.invoke(null, line));
            System.out.flush();
        }
        // Factories may schedule asynchronous requests. Observe a bounded interval
        // and retain their real diagnostics rather than exit immediately on JSON success.
        Thread.sleep(Long.parseLong(args[0]));
        System.out.println("TACHI_BACKGROUND_OBSERVED\t" + args[0]);
        System.out.flush();
        System.exit(backgroundFailure.get() ? 2 : 0);
    }
}
