package okhttp3.zstd;

import io.airlift.compress.zstd.ZstdInputStream;
import okhttp3.CompressionInterceptor;
import okio.BufferedSource;
import okio.Okio;
import okio.Source;

/** Portable host implementation of OkHttp's Zstandard decoder contract. */
public final class Zstd implements CompressionInterceptor.DecompressionAlgorithm {
    public static final Zstd INSTANCE = new Zstd();
    private Zstd() {}
    public String getEncoding() { return "zstd"; }
    public Source decompress(BufferedSource compressedSource) {
        return Okio.source(new ZstdInputStream(compressedSource.inputStream()));
    }
}
