package eu.kanade.tachiyomi.network.interceptor;

import java.util.Locale;
import java.util.concurrent.ConcurrentHashMap;

/** Uses the native browser's actual user agent when sharing a verified session. */
public final class CFClearance {
    public static final CFClearance INSTANCE=new CFClearance();
    private static final String DEFAULT_USER_AGENT = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Version/15.0 Mobile/15E148 Safari/604.1";
    private volatile String userAgent = DEFAULT_USER_AGENT;
    private final ConcurrentHashMap<String,String> hostUserAgents=new ConcurrentHashMap<>();
    private CFClearance(){}
    public String getWebViewUserAgent(){return userAgent;}
    public void setWebViewUserAgent(String value) {
        validateUserAgent(value);
        userAgent = value;
    }
    // Keep the legacy fallback getter/setter ABI for extension compatibility.
    // A browser session belongs only to its exact origin host and must not
    // change the default used by unrelated sources or their CDN requests.
    public String getWebViewUserAgentForHost(String host) {
        return hostUserAgents.get(normalizeHost(host));
    }
    public void setWebViewUserAgentForHost(String host,String value) {
        validateUserAgent(value);
        hostUserAgents.put(normalizeHost(host),value);
    }
    public void resetWebViewUserAgents() {
        hostUserAgents.clear();
        userAgent = DEFAULT_USER_AGENT;
    }
    private static void validateUserAgent(String value) {
        if (value == null || value.isEmpty() || value.length() > 1024 || value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0)
            throw new IllegalArgumentException("Invalid browser user agent");
    }
    private static String normalizeHost(String host) {
        if(host==null||host.isEmpty()||host.length()>253)throw new IllegalArgumentException("Invalid browser host");
        for(int i=0;i<host.length();i++)if(host.charAt(i)<=32||"/\\@?#".indexOf(host.charAt(i))>=0)throw new IllegalArgumentException("Invalid browser host");
        return host.toLowerCase(Locale.ROOT);
    }
}
