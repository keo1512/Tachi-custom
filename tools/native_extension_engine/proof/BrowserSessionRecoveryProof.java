package dev.tachibooks.engine;

import com.google.gson.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** No HTTP/APK required: corrupt optional browser state must not disable the engine. */
public final class BrowserSessionRecoveryProof {
    private static int assertions;
    private static void require(boolean value, String message) {
        assertions++;
        if (!value) throw new AssertionError(message);
    }
    private static JsonObject args(String key, String value) {
        JsonObject result = new JsonObject(); result.addProperty(key, value); return result;
    }
    private static JsonElement call(String method, JsonObject args) {
        JsonObject request = new JsonObject(); request.addProperty("method", method); request.add("args", args);
        JsonObject result = new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();
        require(result.get("ok").getAsBoolean(), method + " failed: " + result.get("error"));
        return result.get("result");
    }
    public static void main(String[] argv) throws Exception {
        require(argv.length == 2, "Usage: temporaryDirectory malformed|oversize|array|null|empty|unknown|entry|restart");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"), "Use interpreter mode");
        Path root = Paths.get(argv[0]).toAbsolutePath(); Files.createDirectories(root);
        Path storage = root.resolve("browser-sessions.json"); String mode = argv[1];
        if ("restart".equals(mode)) {
            call("initialize", args("dataDirectory", root.toString()));
            call("health", new JsonObject());
            require("{}".equals(new String(Files.readAllBytes(storage), StandardCharsets.UTF_8)), "Cleared state survives fresh JVM");
            System.out.println("BROWSER_RECOVERY_RESTART_OK assertions=" + assertions); return;
        }
        byte[] original;
        switch (mode) {
            case "malformed": original = "{\"partial\":".getBytes(StandardCharsets.UTF_8); break;
            case "array": original = "[]".getBytes(StandardCharsets.UTF_8); break;
            case "null": original = "null".getBytes(StandardCharsets.UTF_8); break;
            case "oversize": original = new byte[1024 * 1024 + 1]; Arrays.fill(original, (byte)' '); break;
            case "empty": original = "{}".getBytes(StandardCharsets.UTF_8); break;
            case "unknown": original = "{\"12345\":{}}".getBytes(StandardCharsets.UTF_8); break;
            case "entry": original = "{\"12345\":null}".getBytes(StandardCharsets.UTF_8); break;
            default: throw new AssertionError("Unknown mode");
        }
        require(!Files.exists(storage), "Proof must use a fresh temporary directory");
        Files.write(storage, original);
        byte[] sentinel = "library-and-offline-content".getBytes(StandardCharsets.UTF_8);
        Path library = root.resolve("unrelated-library-sentinel"); Files.write(library, sentinel);
        call("initialize", args("dataDirectory", root.toString()));
        call("health", new JsonObject()); call("sources", new JsonObject());
        require(Arrays.equals(Files.readAllBytes(library), sentinel), "Recovery preserves unrelated files");
        boolean corrupt = Arrays.asList("malformed", "oversize", "array", "null").contains(mode);
        List<Path> quarantined = new ArrayList<>();
        try (DirectoryStream<Path> paths = Files.newDirectoryStream(root, "browser-sessions.corrupt-*.json")) {
            for (Path path : paths) quarantined.add(path);
        }
        if (corrupt) {
            require(quarantined.size() == 1, "Corrupt bytes must be retained in one recovery file");
            require(Arrays.equals(Files.readAllBytes(quarantined.get(0)), original), "Recovery file is byte-identical");
        } else {
            require(quarantined.isEmpty(), "A valid session document is not quarantined");
            require(Arrays.equals(Files.readAllBytes(storage), original), "Valid/unknown session bytes are retained");
        }
        call("initialize", args("dataDirectory", root.toString()));
        call("clearCookies", new JsonObject());
        require("{}".equals(new String(Files.readAllBytes(storage), StandardCharsets.UTF_8)), "Cookie cleanup remains usable");
        if (corrupt) require(Arrays.equals(Files.readAllBytes(quarantined.get(0)), original), "Cleanup preserves recovery evidence");
        String executable = System.getProperty("os.name").startsWith("Windows") ? "java.exe" : "java";
        String java = Paths.get(System.getProperty("java.home"), "bin", executable).toString();
        Process restart = new ProcessBuilder(java, "-Xint", "-cp", System.getProperty("java.class.path"),
            BrowserSessionRecoveryProof.class.getName(), root.toString(), "restart").inheritIO().start();
        boolean completed = restart.waitFor(30, TimeUnit.SECONDS);
        if (!completed) restart.destroyForcibly();
        require(completed && restart.exitValue() == 0, "Fresh JVM can reopen after cleanup");
        System.out.println("BROWSER_SESSION_RECOVERY_OK mode=" + mode + " assertions=" + assertions);
    }
}
