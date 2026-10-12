package eu.kanade.tachiyomi.network;

import java.util.*;
import okhttp3.*;

/** Shared RFC cookie identities, including explicit browser logout/removal. */
public final class SourceCookieJar implements CookieJar {
    public synchronized void clear() { cookies.clear(); }
    private final Map<String,Cookie> cookies = new LinkedHashMap<>();
    private static String key(Cookie cookie) {
        return cookie.domain() + "\u0000" + cookie.path() + "\u0000" + cookie.name();
    }
    public synchronized void saveFromResponse(HttpUrl url, List<Cookie> incoming) {
        long now = System.currentTimeMillis();
        for (Cookie cookie : incoming) {
            String key = key(cookie);
            if (cookie.expiresAt() > now) cookies.put(key, cookie);
            else cookies.remove(key);
        }
    }
    public synchronized List<Cookie> loadForRequest(HttpUrl url) {
        List<Cookie> result = new ArrayList<>();
        Iterator<Cookie> iterator = cookies.values().iterator();
        long now = System.currentTimeMillis();
        while (iterator.hasNext()) {
            Cookie cookie = iterator.next();
            if (cookie.expiresAt() <= now) iterator.remove();
            else if (cookie.matches(url)) result.add(cookie);
        }
        Collections.sort(result, new Comparator<Cookie>() {
            public int compare(Cookie left, Cookie right) {
                return Integer.compare(right.path().length(), left.path().length());
            }
        });
        return result;
    }
    public synchronized void replaceFromBrowser(HttpUrl origin, List<Cookie> incoming) {
        Iterator<Cookie> iterator = cookies.values().iterator();
        while (iterator.hasNext()) {
            Cookie cookie = iterator.next();
            if (cookie.domain().equals(origin.host()) ||
                (!cookie.hostOnly() && origin.host().endsWith("." + cookie.domain()))) iterator.remove();
        }
        saveFromResponse(origin, incoming);
    }
}
