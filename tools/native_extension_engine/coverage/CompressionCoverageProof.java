import com.google.gson.JsonArray;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.security.MessageDigest;
import java.util.Arrays;
import java.util.Base64;
import okhttp3.CompressionInterceptor;
import okhttp3.Gzip;
import okhttp3.brotli.Brotli;
import okhttp3.zstd.Zstd;
import okio.Buffer;
import okio.BufferedSource;
import okio.Okio;

/** Exercises actual maintained decoder contracts; contains no mocked decompression. */
public final class CompressionCoverageProof {
    private static String hex(byte[] input) throws Exception {
        StringBuilder text = new StringBuilder();
        for (byte value : MessageDigest.getInstance("SHA-256").digest(input)) {
            text.append(String.format("%02x", value & 0xff));
        }
        return text.toString();
    }

    public static void main(String[] args) throws Exception {
        JsonObject fixture = new JsonParser().parse(new String(
                Files.readAllBytes(Paths.get(args[0])), StandardCharsets.UTF_8)).getAsJsonObject();
        byte[] expected = Base64.getDecoder().decode(fixture.get("plainBase64").getAsString());
        if (expected.length > 65536 || !hex(expected).equals(fixture.get("plainSha256").getAsString())) {
            throw new IllegalArgumentException("Fixture payload checksum or size mismatch");
        }
        JsonArray results = new JsonArray();
        CompressionInterceptor.DecompressionAlgorithm[] algorithms = {
                Gzip.INSTANCE, Brotli.INSTANCE, Zstd.INSTANCE
        };
        for (CompressionInterceptor.DecompressionAlgorithm algorithm : algorithms) {
            String name = algorithm.getEncoding();
            byte[] encoded = Base64.getDecoder().decode(fixture.getAsJsonObject("encodings").get(name).getAsString());
            byte[] actual;
            try (BufferedSource source = Okio.buffer(algorithm.decompress(new Buffer().write(encoded)))) {
                actual = source.readByteArray();
            }
            if (!Arrays.equals(expected, actual)) throw new IllegalStateException("Decoded bytes differ: " + name);
            JsonObject result = new JsonObject();
            result.addProperty("encoding", name);
            result.addProperty("encodedBytes", encoded.length);
            result.addProperty("decodedBytes", actual.length);
            result.addProperty("decodedSha256", hex(actual));
            result.addProperty("passed", true);
            results.add(result);
        }
        JsonObject result = new JsonObject();
        result.addProperty("passed", true);
        result.add("decoders", results);
        System.out.println("TACHI_COMPRESSION\t" + result);
        System.exit(0);
    }
}
