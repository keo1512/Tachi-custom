package eu.kanade.tachiyomi.network;

import android.content.Context;
import okhttp3.*;
import java.util.*;
import java.util.concurrent.TimeUnit;

/** Host-wide networking service for extension bytecode; no website adapters. */
public final class NetworkHelper {
    private final OkHttpClient client;
    private final kotlin.jvm.functions.Function0<String> defaultUserAgentProvider =
        new kotlin.jvm.functions.Function0<String>() {
            public String invoke() {
                return eu.kanade.tachiyomi.network.interceptor.CFClearance.INSTANCE.getWebViewUserAgent();
            }
        };
    public NetworkHelper(Context context){
        client=new OkHttpClient.Builder().addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor()).addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor(defaultUserAgentProvider)).connectTimeout(30,TimeUnit.SECONDS).readTimeout(30,TimeUnit.SECONDS).callTimeout(45,TimeUnit.SECONDS).cookieJar(new SourceCookieJar()).addInterceptor(new eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor()).build();
    }
    public OkHttpClient getClient(){return client;}
    public OkHttpClient getCloudflareClient(){return client;}
    public kotlin.jvm.functions.Function0<String> getDefaultUserAgentProvider(){return defaultUserAgentProvider;}
}
