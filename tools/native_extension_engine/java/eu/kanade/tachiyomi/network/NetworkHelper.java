package eu.kanade.tachiyomi.network;

import android.content.Context;
import okhttp3.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Host-wide networking service for extension bytecode; no website adapters. */
public final class NetworkHelper {
    private final OkHttpClient client;
    private static final class SourceUserAgent {
        final String value;
        SourceUserAgent(String value){this.value=value;}
    }
    private final kotlin.jvm.functions.Function0<String> defaultUserAgentProvider =
        new kotlin.jvm.functions.Function0<String>() {
            public String invoke() {
                return eu.kanade.tachiyomi.network.interceptor.CFClearance.INSTANCE.getWebViewUserAgent();
            }
        };
    public NetworkHelper(Context context){
        client=new OkHttpClient.Builder().addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor()).addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor(defaultUserAgentProvider)).addInterceptor(chain->chain.proceed(chain.request().newBuilder().tag(SourceUserAgent.class,null).build())).addNetworkInterceptor(chain->{
            Request request=chain.request();
            SourceUserAgent original=request.tag(SourceUserAgent.class);
            if(original==null)original=new SourceUserAgent(request.header("User-Agent"));
            String agent=eu.kanade.tachiyomi.network.interceptor.CFClearance.INSTANCE.getWebViewUserAgentForHost(request.url().host());
            // Explicit browser UA and its clearance cookies must travel
            // together. Source-defined/default headers remain unchanged for
            // every host without a browser session, including redirect targets.
            // Follow-up requests retain this per-call tag so a previous host's
            // browser override cannot become the next host's default.
            Request.Builder outgoing=request.newBuilder().tag(SourceUserAgent.class,original);
            if(agent!=null)outgoing.header("User-Agent",agent);
            else if(original.value!=null)outgoing.header("User-Agent",original.value);
            else outgoing.removeHeader("User-Agent");
            return chain.proceed(outgoing.build());
        }).connectTimeout(30,TimeUnit.SECONDS).readTimeout(30,TimeUnit.SECONDS).callTimeout(45,TimeUnit.SECONDS).cookieJar(new SourceCookieJar(context.getFilesDir().toPath().resolve("source-cookies.json"))).addInterceptor(new eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor()).build();
    }
    public OkHttpClient getClient(){return client;}
    public OkHttpClient getCloudflareClient(){return client;}
    public kotlin.jvm.functions.Function0<String> getDefaultUserAgentProvider(){return defaultUserAgentProvider;}
}
