package eu.kanade.tachiyomi.network.interceptor;

/** Uses the native browser's actual user agent when sharing a verified session. */
public final class CFClearance {
    public static final CFClearance INSTANCE=new CFClearance();
    private volatile String userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 15_0 like Mac OS X) AppleWebKit/605.1.15 Version/15.0 Mobile/15E148 Safari/604.1";
    private CFClearance(){}
    public String getWebViewUserAgent(){return userAgent;}
    public void setWebViewUserAgent(String value) {
        if (value == null || value.isEmpty() || value.length() > 1024 || value.indexOf('\r') >= 0 || value.indexOf('\n') >= 0)
            throw new IllegalArgumentException("Invalid browser user agent");
        userAgent = value;
    }
}
