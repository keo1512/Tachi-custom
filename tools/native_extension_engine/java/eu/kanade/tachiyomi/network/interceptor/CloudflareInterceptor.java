package eu.kanade.tachiyomi.network.interceptor;

import dev.tachibooks.engine.BrowserChallengeException;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;
import okhttp3.Interceptor;
import okhttp3.Response;
import java.io.IOException;
import java.util.Locale;

/** Native host challenge detection; challenge resolution needs an interactive browser. */
public final class CloudflareInterceptor implements Interceptor {
    public CloudflareInterceptor() {}
    public CloudflareInterceptor(Function1<? super String,Unit> setUserAgent) {}
    public Response intercept(Chain chain) throws IOException {
        Response response=chain.proceed(chain.request());
        String server=response.header("Server","").toLowerCase(Locale.ROOT);
        boolean challenge="challenge".equalsIgnoreCase(response.header("cf-mitigated")) ||
            ((response.code()==403 || response.code()==503) && server.contains("cloudflare"));
        if(challenge){response.close();throw new BrowserChallengeException();}
        return response;
    }
}
