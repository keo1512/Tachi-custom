package dev.tachibooks.engine;

import com.google.gson.Gson;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;

final class EngineFiles {
    static final Gson JSON = new Gson();
    static void write(Path path, String value) throws IOException {
        Files.createDirectories(path.getParent());
        Path pending = Files.createTempFile(path.getParent(), ".pending-", ".json");
        try {
            try (FileOutputStream output = new FileOutputStream(pending.toFile())) {
                output.write(value.getBytes(StandardCharsets.UTF_8));
                output.getFD().sync();
            }
            Files.move(pending, path, StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } finally { Files.deleteIfExists(pending); }
    }
    static String sha256(Path path) throws Exception {
        MessageDigest hash = MessageDigest.getInstance("SHA-256");
        try (InputStream input = Files.newInputStream(path)) {
            byte[] block = new byte[32768]; int read;
            while ((read = input.read(block)) != -1) hash.update(block, 0, read);
        }
        StringBuilder text = new StringBuilder();
        for (byte value : hash.digest()) text.append(String.format("%02x", value & 255));
        return text.toString();
    }
    static String sha256(byte[] bytes) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(bytes))
            text.append(String.format("%02x", value & 255));
        return text.toString();
    }
}
