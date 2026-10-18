package eu.kanade.tachiyomi.network;

import java.util.*;
import java.io.IOException;
import java.nio.file.Path;
import okhttp3.*;

/** Shared RFC cookie identities, including explicit browser logout/removal. */
public final class SourceCookieJar implements CookieJar {
    private final SourceCookieStore storage;
    private boolean invalidStorage,persistenceHealthy=true,legacyImportDisabled;
    private final Set<String> origins=new LinkedHashSet<>(),identities=new LinkedHashSet<>();
    public SourceCookieJar(){storage=null;}
    public SourceCookieJar(Path path){
        storage=new SourceCookieStore(path);
        try{SourceCookieStore.State state=storage.load();cookies.putAll(state.cookies);origins.addAll(state.origins);identities.addAll(state.identities);legacyImportDisabled=state.legacyImportDisabled;}
        catch(IOException invalid){invalidStorage=true;persistenceHealthy=false;}
    }
    public synchronized boolean isPersistenceHealthy(){return persistenceHealthy;}
    public synchronized void clear() {
        SourceCookieStore.State empty=new SourceCookieStore.State();empty.legacyImportDisabled=true;
        if(storage!=null){try{if(invalidStorage)storage.clearAfterInvalid(empty);else storage.write(empty);}catch(IOException failure){persistenceHealthy=false;throw new IllegalStateException("Private cookies could not be cleared",failure);}}
        cookies.clear();origins.clear();identities.clear();legacyImportDisabled=true;invalidStorage=false;persistenceHealthy=true;
    }
    private final Map<String,Cookie> cookies = new LinkedHashMap<>();
    private static String key(Cookie cookie) {
        return cookie.domain() + "\u0000" + cookie.path() + "\u0000" + cookie.name();
    }
    public synchronized void saveFromResponse(HttpUrl url, List<Cookie> incoming) {
        if(incoming.isEmpty())return;
        if(incoming.size()>SourceCookieStore.MAX_COOKIES)throw new IllegalArgumentException("Cookie response exceeds limits");
        for(Cookie cookie:incoming)SourceCookieStore.validateCookie(cookie);
        checkCapacity(url,incoming,false);
        long now = System.currentTimeMillis();
        for (Cookie cookie : incoming) {
            String key = key(cookie);
            identities.add(key);
            if (cookie.expiresAt() > now) cookies.put(key, cookie);
            else cookies.remove(key);
        }
        origins.add(url.host());persistBestEffort();
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
    /** Browser seeding includes path cookies, while keeping unrelated hosts private. */
    public synchronized List<Cookie> snapshotForBrowser(HttpUrl origin) {
        List<Cookie> result=new ArrayList<>();long now=System.currentTimeMillis();
        for(Cookie cookie:cookies.values())if(cookie.expiresAt()>now&&
            (cookie.domain().equals(origin.host())||(!cookie.hostOnly()&&origin.host().endsWith("."+cookie.domain()))))result.add(cookie);
        Collections.sort(result,new Comparator<Cookie>(){public int compare(Cookie a,Cookie b){return key(a).compareTo(key(b));}});
        return result;
    }
    public synchronized void replaceFromBrowser(HttpUrl origin, List<Cookie> incoming) {
        if(incoming.size()>SourceCookieStore.MAX_COOKIES)throw new IllegalArgumentException("Browser cookies exceed limits");
        for(Cookie cookie:incoming)SourceCookieStore.validateCookie(cookie);
        checkCapacity(origin,incoming,true);
        Iterator<Cookie> iterator = cookies.values().iterator();
        while (iterator.hasNext()) {
            Cookie cookie = iterator.next();
            if (cookie.domain().equals(origin.host()) ||
                (!cookie.hostOnly() && origin.host().endsWith("." + cookie.domain()))){identities.add(key(cookie));iterator.remove();}
        }
        long now=System.currentTimeMillis();
        for(Cookie cookie:incoming){identities.add(key(cookie));if(cookie.expiresAt()>now)cookies.put(key(cookie),cookie);}
        origins.add(origin.host());persistBestEffort();
    }
    /** Explicit browser publication validates all bounds before other state is written. */
    public synchronized void validateBrowserReplacement(HttpUrl origin,List<Cookie> incoming)throws IOException{
        SourceCookieStore.encode(browserReplacement(origin,incoming));
    }
    /** Unlike background HTTP persistence, explicit browser save must report disk failure. */
    public synchronized void replaceFromBrowserChecked(HttpUrl origin,List<Cookie> incoming)throws IOException{
        SourceCookieStore.State next=browserReplacement(origin,incoming);
        SourceCookieStore.encode(next);
        if(storage!=null){
            if(invalidStorage){persistenceHealthy=false;throw new IOException("Private cookie storage needs explicit cleanup");}
            try{storage.write(next);}catch(IOException failure){persistenceHealthy=false;throw failure;}
        }
        cookies.clear();cookies.putAll(next.cookies);origins.clear();origins.addAll(next.origins);
        identities.clear();identities.addAll(next.identities);persistenceHealthy=true;
    }
    private SourceCookieStore.State browserReplacement(HttpUrl origin,List<Cookie> incoming)throws IOException{
        if(incoming.size()>SourceCookieStore.MAX_COOKIES)throw new IllegalArgumentException("Browser cookies exceed limits");
        SourceCookieStore.State next=new SourceCookieStore.State();next.legacyImportDisabled=legacyImportDisabled;
        next.origins.addAll(origins);next.origins.add(origin.host());next.identities.addAll(identities);
        long now=System.currentTimeMillis();
        for(Cookie cookie:cookies.values()){
            boolean scoped=cookie.domain().equals(origin.host())||(!cookie.hostOnly()&&origin.host().endsWith("."+cookie.domain()));
            if(scoped)next.identities.add(key(cookie));else if(cookie.expiresAt()>now)next.cookies.put(key(cookie),cookie);
        }
        for(Cookie cookie:incoming){SourceCookieStore.validateCookie(cookie);next.identities.add(key(cookie));if(cookie.expiresAt()>now)next.cookies.put(key(cookie),cookie);}
        return next;
    }
    /** One-time fallback migration; refreshed/deleted HTTP identities win. */
    public synchronized void restoreFromBrowser(HttpUrl origin,List<Cookie> incoming){
        if(invalidStorage||legacyImportDisabled||origins.contains(origin.host()))return;
        if(incoming.size()>SourceCookieStore.MAX_COOKIES)throw new IllegalArgumentException("Browser cookies exceed limits");
        for(Cookie cookie:incoming)SourceCookieStore.validateCookie(cookie);
        List<Cookie> unseen=new ArrayList<>();for(Cookie cookie:incoming)if(!identities.contains(key(cookie)))unseen.add(cookie);
        checkCapacity(origin,unseen,false);
        long now=System.currentTimeMillis();
        for(Cookie cookie:incoming){SourceCookieStore.validateCookie(cookie);String key=key(cookie);if(!identities.contains(key)){identities.add(key);if(cookie.expiresAt()>now)cookies.put(key,cookie);}}
        origins.add(origin.host());persistBestEffort();
    }
    private void checkCapacity(HttpUrl origin,List<Cookie> incoming,boolean replace){
        Set<String> nextIdentities=new HashSet<>(identities),active=new HashSet<>();
        long now=System.currentTimeMillis();
        for(Cookie cookie:cookies.values()){
            boolean scoped=cookie.domain().equals(origin.host())||(!cookie.hostOnly()&&origin.host().endsWith("."+cookie.domain()));
            if(cookie.expiresAt()>now&&!(replace&&scoped))active.add(key(cookie));
        }
        for(Cookie cookie:incoming){String key=key(cookie);nextIdentities.add(key);if(cookie.expiresAt()>now)active.add(key);else active.remove(key);}
        if(nextIdentities.size()>SourceCookieStore.MAX_IDENTITIES||active.size()>SourceCookieStore.MAX_COOKIES||!origins.contains(origin.host())&&origins.size()>=SourceCookieStore.MAX_ORIGINS)throw new IllegalArgumentException("Private cookie storage exceeds limits");
        Iterator<Cookie> expired=cookies.values().iterator();while(expired.hasNext())if(expired.next().expiresAt()<=now)expired.remove();
    }
    private void persistBestEffort(){
        if(storage==null)return;
        if(invalidStorage){persistenceHealthy=false;return;}
        SourceCookieStore.State state=new SourceCookieStore.State();state.cookies.putAll(cookies);state.origins.addAll(origins);state.identities.addAll(identities);state.legacyImportDisabled=legacyImportDisabled;
        try{storage.write(state);persistenceHealthy=true;}catch(IOException failure){persistenceHealthy=false;}
    }
}
