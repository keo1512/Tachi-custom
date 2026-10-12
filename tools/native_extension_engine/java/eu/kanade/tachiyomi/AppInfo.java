package eu.kanade.tachiyomi;

/** Host identity exposed through the extension API's historical singleton ABI. */
public final class AppInfo {
    public static final AppInfo INSTANCE = new AppInfo();
    private AppInfo() {}
    public int getVersionCode() { return 7; }
    public String getVersionName() { return "TachiBooks 1.0.0"; }
}
