package dev.tachibooks.engine;

import android.app.Application;
import android.content.SharedPreferences;
import androidx.preference.*;
import com.google.gson.*;
import eu.kanade.tachiyomi.network.NetworkHelper;
import eu.kanade.tachiyomi.source.*;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.io.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.locks.Lock;
import java.util.concurrent.locks.ReentrantReadWriteLock;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;
import kotlinx.serialization.json.Json;
import kotlinx.serialization.json.JsonBuilder;
import kotlinx.serialization.json.JsonKt;
import okhttp3.*;
import kotlin.jvm.JvmClassMappingKt;
import org.koin.core.KoinApplication;
import org.koin.core.context.GlobalContext;
import org.koin.core.definition.BeanDefinition;
import org.koin.core.definition.BeanDefinitionKt;
import org.koin.core.definition.Kind;
import org.koin.core.instance.SingleInstanceFactory;
import org.koin.core.qualifier.Qualifier;

/** JNI entry point. Original APK classes execute here; this host contains no website parsers. */
public final class ExtensionHost {
    private static ExtensionRegistry registry;
    private static EngineApplication application;
    private static NetworkHelper networking;
    private static Path dataDirectory;
    private static final Map<String,CachedChapter> chapterPages=new LinkedHashMap<String,CachedChapter>(16,0.75f,true){
        protected boolean removeEldestEntry(Map.Entry<String,CachedChapter> item){return size()>8;}
    };
    private static final long MAX_IMAGE_BYTES=8L*1024*1024;
    private static final class HttpStatusException extends IOException{
        final int status;
        HttpStatusException(int status){super("Source returned an HTTP error");this.status=status;}
    }
    private static final Map<String,SManga> mangaMetadata=new LinkedHashMap<String,SManga>(256,0.75f,true){
        protected boolean removeEldestEntry(Map.Entry<String,SManga> item){return size()>256;}
    };
    private static final class CachedChapter{
        final String sourceId,bookRef,ref;final List<? extends Page> pages;
        boolean restoredForImages;
        CachedChapter(String sourceId,String bookRef,String ref,List<? extends Page> pages){this.sourceId=sourceId;this.bookRef=bookRef;this.ref=ref;this.pages=pages;}
    }
    private ExtensionHost(){}
    // Keep source/page state exclusive, but do not hold that lock during cover
    // HTTP. A separate lease still orders privacy/preferences/package mutations
    // after in-flight covers, so those requests cannot restore an older session.
    private static final ReentrantReadWriteLock requests=new ReentrantReadWriteLock(true);
    private static final ReentrantReadWriteLock coverSessions=new ReentrantReadWriteLock(true);
    public static String invoke(String requestJson){
        String method="";
        try{if(requestJson!=null&&requestJson.length()<=1024*1024)method=required(new JsonParser().parse(requestJson).getAsJsonObject(),"method");}catch(RuntimeException invalid){}
        boolean cover="cover".equals(method);
        Lock session=cover?coverSessions.readLock():changesCoverSession(method)?coverSessions.writeLock():null;
        Lock lock=cover?null:requests.writeLock();
        // Lock order is always session -> source state. Reader calls only take
        // source state; covers release it before doing any network I/O.
        if(session!=null)session.lock();
        if(lock!=null)lock.lock();
        try{return invokeLocked(requestJson);}finally{if(lock!=null)lock.unlock();if(session!=null)session.unlock();}
    }
    private static boolean changesCoverSession(String method){
        return "initialize".equals(method)||"install".equals(method)||"uninstall".equals(method)||"setPreference".equals(method)||"browserSession".equals(method)||"clearCookies".equals(method)||"clearSourceCache".equals(method)||"resetUserAgents".equals(method);
    }
    private static String invokeLocked(String requestJson){
        JsonObject response=new JsonObject();
        try{
            if(requestJson==null||requestJson.length()>1024*1024)throw new IllegalArgumentException("Invalid request size");
            JsonObject request=new JsonParser().parse(requestJson).getAsJsonObject();
            String method=required(request,"method");JsonObject args=request.has("args")?request.getAsJsonObject("args"):new JsonObject();
            JsonElement result;
            if("initialize".equals(method))result=initialize(required(args,"dataDirectory"));
            else{
                if(!"cover".equals(method)&&registry==null)throw new IllegalStateException("Engine must be initialized first");
                switch(method){
                    case "sources":result=sources();break;
                    case "health":result=status();break;
                    case "clearSourceCache":
                        if(!args.entrySet().isEmpty())throw new IllegalArgumentException("Cache cleanup accepts no paths");
                        mangaMetadata.clear();chapterPages.clear();SourceContext.clear();result=new JsonPrimitive(true);break;
                    case "clearCookies":
                        if(!args.entrySet().isEmpty())throw new IllegalArgumentException("Cookie cleanup accepts no paths");
                        result=BrowserSession.clear(registry,networking.getClient().cookieJar());break;
                    case "resetUserAgents":
                        if(!args.entrySet().isEmpty())throw new IllegalArgumentException("User-agent reset accepts no paths");
                        result=BrowserSession.resetUserAgents();break;
                    case "extensions":result=registry.extensions();break;
                    case "inspectPackage":result=registry.inspect(Paths.get(required(args,"apkPath")));break;
                    case "install":result=registry.install(Paths.get(required(args,"apkPath")),optional(args,"packageUrl"),optional(args,"iconUrl"),optional(args,"packageHash"));chapterPages.clear();mangaMetadata.clear();SourceContext.clear();BrowserSession.initialize(dataDirectory,registry);break;
                    case "uninstall":result=new JsonPrimitive(registry.uninstall(required(args,"id")));chapterPages.clear();mangaMetadata.clear();SourceContext.clear();break;
                    case "search":result=search(args);break;
                    case "filters":result=SourceFilterCodec.encode(registry.source(required(args,"sourceId")).getFilterList());break;
                    case "detail":result=detail(args);break;
                    case "chapters":result=chapters(args);break;
                    case "chapter":result=chapter(args);break;
                    case "image":result=image(args);break;
                    case "cover":result=cover(args);break;
                    case "browserSession":result=BrowserSession.apply(args,registry.source(required(args,"sourceId")));break;
                    case "browserSeed":result=BrowserSession.seed(args,registry.source(required(args,"sourceId")));break;
                    case "preferences":result=preferences(args);break;
                    case "setPreference":result=setPreference(args);break;
                    default:throw new IllegalArgumentException("Unsupported engine method");
                }
            }
            response.addProperty("ok",true);response.add("result",result);
        }catch(Throwable failure){
            JsonObject error=new JsonObject();String code,message;
            if(requiresBrowser(failure)){code="source_requires_browser";message="The source requires an interactive browser session.";}
            else if(failure instanceof SourceContext.Missing){code="source_context_missing";message="The source needs its original chapter context.";}
            else if(failure instanceof HttpStatusException){code="http_error";message="Source returned an HTTP error";error.addProperty("httpStatus",((HttpStatusException)failure).status);}
            else if(failure instanceof SourceNotLoadedException){code="source_not_installed";message="Required source extension is not loaded.";}
            else if(failure instanceof LinkageError||failure instanceof UnsupportedExtensionVersionException){code="unsupported_extension";message="The extension requires an Android or Java API that this engine does not provide.";}
            else if(failure instanceof IllegalArgumentException){code="invalid_request";message=failure.getMessage();}
            else if(failure instanceof IllegalStateException&&registry==null){code="engine_unavailable";message="The native extension engine could not initialize.";}
            else{code="extension_failed";message="The extension operation failed. Check the source settings and network connection.";}
            error.addProperty("code",code);error.addProperty("message",message);error.addProperty("type",failure.getClass().getSimpleName());
            response.addProperty("ok",false);response.add("error",error);
        }
        return EngineFiles.JSON.toJson(response);
    }
    private static boolean requiresBrowser(Throwable failure){for(int depth=0;failure!=null&&depth<8;depth++,failure=failure.getCause())if(failure instanceof BrowserChallengeException)return true;return false;}
    private static JsonObject initialize(String directory)throws Exception{
        Path requested=Paths.get(directory).toAbsolutePath().normalize();
        if(registry!=null){if(!dataDirectory.equals(requested))throw new IllegalArgumentException("Engine is already initialized with another data directory");return status();}
        Files.createDirectories(requested);application=new EngineApplication(requested);
        AndroidCryptoProvider.install();
        if(GlobalContext.INSTANCE.getOrNull()==null)GlobalContext.INSTANCE.startKoin(KoinApplication.Companion.init());
        networking=new NetworkHelper(application);
        register(Application.class,application);register(NetworkHelper.class,networking);
        Json json=JsonKt.Json(Json.Default,new Function1<JsonBuilder,Unit>(){public Unit invoke(JsonBuilder builder){builder.setIgnoreUnknownKeys(true);return Unit.INSTANCE;}});
        register(Json.class,json);ExtensionRegistry loaded=new ExtensionRegistry(requested);BrowserSession.initialize(requested,loaded);registry=loaded;dataDirectory=requested;return status();
    }
    private static JsonObject status(){
        JsonObject result=new JsonObject();result.addProperty("engine","tachi");result.addProperty("protocolVersion",1);result.addProperty("sourceCount",registry.sources().size());result.addProperty("execution","java-interpreter");
        boolean cookieHealthy=true;
        List<CookieJar> jars=new ArrayList<>();jars.add(networking.getClient().cookieJar());
        for(CatalogueSource source:registry.sources())if(source instanceof HttpSource)jars.add(((HttpSource)source).getClient().cookieJar());
        for(CookieJar jar:jars)if(jar instanceof eu.kanade.tachiyomi.network.SourceCookieJar&&!((eu.kanade.tachiyomi.network.SourceCookieJar)jar).isPersistenceHealthy())cookieHealthy=false;
        result.addProperty("cookiePersistenceHealthy",cookieHealthy);return result;
    }
    private static <T>void register(final Class<T> type,final T value){
        org.koin.core.Koin koin=GlobalContext.INSTANCE.get();
        Qualifier root=koin.getScopeRegistry().getRootScope().getScopeQualifier();
        BeanDefinition<T> definition=new BeanDefinition<>(root,JvmClassMappingKt.getKotlinClass(type),null,
            (scope,parameters)->value,Kind.Singleton,Collections.emptyList(),true);
        koin.getInstanceRegistry().saveMapping(true,BeanDefinitionKt.indexKey(JvmClassMappingKt.getKotlinClass(type),null,root),new SingleInstanceFactory<>(definition),false);
    }
    private static JsonArray sources(){JsonArray result=new JsonArray();for(CatalogueSource source:registry.sources()){
        JsonObject item=new JsonObject();item.addProperty("id",Long.toString(source.getId()));item.addProperty("name",source.getName());item.addProperty("lang",source.getLang());item.addProperty("baseUrl",source instanceof HttpSource?((HttpSource)source).getBaseUrl():"");item.addProperty("iconUrl",registry.iconUrl(Long.toString(source.getId())));item.addProperty("engine","tachi");item.addProperty("kind","manga");item.addProperty("configurable",source instanceof ConfigurableSource);item.addProperty("supportsLatest",source.getSupportsLatest());result.add(item);
    }return result;}
    private static JsonObject search(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));int page=args.has("page")?args.get("page").getAsInt():1;
        if(page<1||page>100000)throw new IllegalArgumentException("Invalid search page");String mode=optional(args,"mode"),query=optional(args,"query");MangasPage found;
        if("popular".equals(mode))found=SuspendBridge.await(completion->source.getPopularManga(page,completion));
        else if("latest".equals(mode)){if(!source.getSupportsLatest())throw new IllegalArgumentException("Source does not provide latest updates");found=SuspendBridge.await(completion->source.getLatestUpdates(page,completion));}
        else {
            FilterList filters=source.getFilterList();
            if(args.has("filters"))filters=SourceFilterCodec.apply(filters,required(args,"filterSchema"),args.getAsJsonArray("filters"));
            final FilterList applied=filters;
            found=SuspendBridge.await(completion->source.getSearchManga(page,query,applied,completion));
        }
        JsonObject result=new JsonObject();JsonArray books=new JsonArray();for(SManga value:found.getMangas())books.add(book(source,value));result.add("items",books);result.addProperty("hasNextPage",found.getHasNextPage());result.addProperty("page",page);return result;
    }
    private static JsonObject book(CatalogueSource source,SManga manga){
        mangaMetadata.put(source.getId()+"\n"+manga.getUrl(),manga);
        JsonObject result=new JsonObject();result.addProperty("ref",manga.getUrl());result.addProperty("title",manga.getTitle());result.addProperty("author",manga.getAuthor());result.addProperty("artist",manga.getArtist());result.addProperty("description",manga.getDescription());result.addProperty("coverUrl",manga.getThumbnail_url());result.addProperty("status",manga.getStatus());result.addProperty("sourceId",Long.toString(source.getId()));result.addProperty("kind","manga");result.addProperty("engine","tachi");
        JsonArray genres=new JsonArray();if(manga.getGenre()!=null)for(String genre:manga.getGenre().split(","))if(!genre.trim().isEmpty())genres.add(genre.trim());result.add("genres",genres);
        if(!manga.getMemo().isEmpty())result.add("memo",SourceContext.encode(manga.getMemo()));return result;
    }
    private static JsonObject detail(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));
        SManga original=manga(args);
        SMangaUpdate update=SuspendBridge.await(completion->source.getMangaUpdate(original,Collections.emptyList(),true,false,completion));
        SManga updated=update.getManga();
        // Source detail responses can omit list metadata such as title/URL.
        // Keep the stable request identity and the actual catalogue metadata.
        updated.setUrl(original.getUrl());
        try{if(updated.getTitle().isEmpty())updated.setTitle(original.getTitle());}
        catch(kotlin.UninitializedPropertyAccessException missing){updated.setTitle(original.getTitle());}
        if(updated.getThumbnail_url()==null)updated.setThumbnail_url(original.getThumbnail_url());
        JsonObject memo=SourceContext.encode(original.getMemo());
        for(Map.Entry<String,JsonElement> entry:SourceContext.encode(updated.getMemo()).entrySet())memo.add(entry.getKey(),entry.getValue());
        updated.setMemo(SourceContext.decode(memo));
        return book(source,updated);
    }
    private static JsonArray chapters(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));
        SMangaUpdate update=SuspendBridge.await(completion->source.getMangaUpdate(manga(args),Collections.emptyList(),false,true,completion));
        List<SChapter> chapters=new ArrayList<>(update.getChapters());Collections.reverse(chapters);JsonArray result=new JsonArray();int ordinal=0;
        SourceContext.remember(source,required(args,"ref"),chapters);
        for(SChapter chapter:chapters){JsonObject value=new JsonObject();value.addProperty("ref",chapter.getUrl());value.addProperty("title",chapter.getName());value.addProperty("index",ordinal++);value.addProperty("number",chapter.getChapter_number());value.addProperty("uploadedAt",chapter.getDate_upload());value.addProperty("scanlator",chapter.getScanlator());
            if(!chapter.getMemo().isEmpty())value.add("memo",SourceContext.encode(chapter.getMemo()));
            String url=SourceContext.url(source,chapter);if(!url.isEmpty())value.addProperty("sourceUrl",url);
            result.add(value);}return result;
    }
    private static JsonObject chapter(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));String ref=required(args,"ref");
        // Metadata does not execute image request hooks. getImage() invokes the
        // original source's request/headers/cookies only for the requested page.
        // Empty header envelopes retain transport compatibility; Flutter does
        // not issue raw image HTTP requests for this native engine.
        String bookRef=optional(args,"bookRef");
        List<? extends Page> pages=loadPages(source,bookRef,ref,optional(args,"title"),args);JsonArray images=new JsonArray();JsonObject imageHeaders=new JsonObject();
        int ordinal=0;
        for(Page page:pages){String image=page.getImageUrl();if(image==null||image.isEmpty()){
                if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source did not return image URLs");
                // The image RPC owns resolution. A slow/broken later page must
                // not keep an already-readable first page from opening.
                images.add(deferredPageUrl(Long.toString(source.getId()),bookRef,ref,ordinal++));continue;
            }
            ordinal++;images.add(image);
        }
        JsonObject result=new JsonObject();result.addProperty("kind","manga");result.add("images",images);result.add("headers",new JsonObject());result.add("imageHeaders",imageHeaders);return result;
    }
    private static String deferredPageUrl(String sourceId,String bookRef,String ref,int ordinal)throws Exception{
        // This reserved, non-network locator preserves the existing string-list
        // transport and partial-download format. Only image(source,chapter,index)
        // consumes it; it is never passed to the source's HTTP image request.
        String identity=bookRef.isEmpty()?sourceId+"\n"+ref:SourceContext.key(sourceId,bookRef,ref);
        return "https://page.tachibooks.invalid/"+EngineFiles.sha256((identity+"\n"+ordinal).getBytes(java.nio.charset.StandardCharsets.UTF_8));
    }
    private static List<? extends Page> loadPages(CatalogueSource source,String bookRef,String ref,String title,JsonObject args)throws Exception{
        SChapter chapter=SourceContext.chapter(source,bookRef,ref,title,args.get("chapterMemo"));
        List<? extends Page> pages;
        try{final SChapter original=chapter;pages=SuspendBridge.await(completion->source.getPageList(original,completion));}
        catch(IllegalStateException missing){
            // A restored URL can precede a source's switch to short chapter IDs
            // plus memo. Recover only from the same parent's original TOC and
            // an exact source URL, never a title/ordinal guess.
            if(bookRef.isEmpty()||!chapter.getMemo().isEmpty())throw missing;
            JsonObject parent=new JsonObject();parent.addProperty("sourceId",Long.toString(source.getId()));parent.addProperty("ref",bookRef);parent.addProperty("title",optional(args,"bookTitle"));
            if(args.has("bookMemo"))parent.add("memo",args.get("bookMemo"));
            if(bookRef.matches("[0-9]+")&&!args.has("bookMemo"))throw new SourceContext.Missing();
            SMangaUpdate update;
            try{update=SuspendBridge.await(completion->source.getMangaUpdate(manga(parent),Collections.emptyList(),false,true,completion));}
            catch(IllegalStateException context){if(!args.has("bookMemo"))throw new SourceContext.Missing();throw context;}
            SourceContext.remember(source,bookRef,update.getChapters());
            final SChapter restored=SourceContext.match(source,ref,update.getChapters());
            if(restored==null)throw missing;
            pages=SuspendBridge.await(completion->source.getPageList(restored,completion));
        }
        if(pages==null||pages.size()>10000)throw new IllegalArgumentException("Source returned an invalid page count");
        List<? extends Page> retained=new ArrayList<>(pages);
        String sourceId=Long.toString(source.getId());chapterPages.put(SourceContext.key(sourceId,bookRef,ref),new CachedChapter(sourceId,bookRef,ref,retained));
        return retained;
    }
    private static JsonObject image(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source has no HTTP image loader");
        String url=required(args,"url"),chapterRef=optional(args,"chapterRef"),sourceId=Long.toString(source.getId()),bookRef=optional(args,"ref");
        int ordinal=args.has("index")?args.get("index").getAsInt():0;Page page=null;boolean refreshed=false;
        // Validate caller metadata before a cache miss can trigger source work.
        // The supplied URL identifies old cached content; it never chooses the
        // network destination after we refresh a stable chapter/page identity.
        if(ordinal<0||ordinal>=10000)throw new IllegalArgumentException("Page index is invalid");
        for(int i=0;i<url.length();i++)if(url.charAt(i)<=32||url.charAt(i)=='\\')throw new IllegalArgumentException("Image URL is invalid");
        HttpUrl supplied=HttpUrl.parse(url);
        if(supplied==null||!supplied.username().isEmpty()||!supplied.password().isEmpty())throw new IllegalArgumentException("Image URL is invalid");
        boolean deferred="page.tachibooks.invalid".equals(supplied.host());
        if(deferred&&(chapterRef.isEmpty()||!url.equals(deferredPageUrl(sourceId,bookRef,chapterRef,ordinal))&&!url.equals(deferredPageUrl(sourceId,"",chapterRef,ordinal))))throw new IllegalArgumentException("Deferred page identity is invalid");
        if(!chapterRef.isEmpty()){
            CachedChapter cached=chapterPages.get(SourceContext.key(sourceId,bookRef,chapterRef));
            if(cached==null&&bookRef.isEmpty())for(CachedChapter candidate:chapterPages.values())if(candidate.sourceId.equals(sourceId)&&candidate.ref.equals(chapterRef)){
                if(cached!=null)throw new IllegalArgumentException("Chapter image identity is ambiguous");cached=candidate;
            }
            List<? extends Page> pages=cached!=null?cached.pages:loadPages(source,bookRef,chapterRef,optional(args,"chapterTitle"),args);
            if(cached==null){cached=chapterPages.get(SourceContext.key(sourceId,bookRef,chapterRef));cached.restoredForImages=true;}
            // Every remaining page in a persisted partial chapter can have an
            // expired signature. Retain the reload's stable-identity authority
            // for the whole chapter, rather than only its first image request.
            // A normal chapter() metadata fetch replaces this cache entry and
            // restores strict URL matching. The caller URL never drives HTTP.
            refreshed=cached.restoredForImages;
            if(ordinal<0||ordinal>=pages.size())throw new IllegalArgumentException("Page index is invalid");page=pages.get(ordinal);
        }else{
            // Compatibility for clients that obtained a chapter immediately before
            // requesting its image. A cache miss needs the stable chapter identity.
            for(CachedChapter cached:chapterPages.values())if(cached.sourceId.equals(sourceId)&&(bookRef.isEmpty()||cached.bookRef.equals(bookRef))&&ordinal>=0&&ordinal<cached.pages.size()){
                Page candidate=cached.pages.get(ordinal);
                if(url.equals(candidate.getImageUrl())){if(page!=null&&page!=candidate)throw new IllegalArgumentException("Image belongs to more than one cached chapter");page=candidate;}
            }
            if(page==null)throw new IllegalArgumentException("Image request requires its chapter reference");
        }
        final Page originalPage=page;
        if(page.getImageUrl()==null||page.getImageUrl().isEmpty())page.setImageUrl(SuspendBridge.await(completion->((HttpSource)source).getImageUrl(originalPage,completion)));
        if(page.getImageUrl()==null||page.getImageUrl().isEmpty())throw new IllegalArgumentException("Extension returned an empty image URL");
        // A persisted partial download can outlive CDN signatures and this
        // process's Page cache. The extension's fresh Page is authoritative in
        // that case. A warm cache still rejects an unrelated caller URL.
        if(!deferred&&!refreshed&&!url.equals(page.getImageUrl()))throw new IllegalArgumentException("Image URL no longer matches the source page");
        try(Response response=SuspendBridge.await(completion->((HttpSource)source).getImage(originalPage,completion))){
            if(!response.isSuccessful())throw new HttpStatusException(response.code());
            if(response.body()==null)throw new IOException("Image HTTP response is empty");
            if(response.body().contentLength()>MAX_IMAGE_BYTES)throw new IOException("Image size exceeds native response limit");
            ByteArrayOutputStream output=new ByteArrayOutputStream();try(InputStream input=response.body().byteStream()){byte[] block=new byte[32768];int read;while((read=input.read(block))!=-1){if(output.size()+(long)read>MAX_IMAGE_BYTES)throw new IOException("Image size exceeds native response limit");output.write(block,0,read);}}
            JsonObject result=new JsonObject();result.addProperty("base64",Base64.getEncoder().encodeToString(output.toByteArray()));result.addProperty("mimeType",response.header("Content-Type","application/octet-stream"));return result;
        }
    }
    private static JsonObject cover(JsonObject args)throws Exception{
        final Request request;final OkHttpClient client;
        Lock state=requests.readLock();state.lock();
        try{
        if(registry==null)throw new IllegalStateException("Engine must be initialized first");
        CatalogueSource source=registry.source(required(args,"sourceId"));
        if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source has no HTTP cover loader");
        HttpSource http=(HttpSource)source;String raw=required(args,"url");
        // Thumbnail URLs may point at a CDN or be relative to the source base.
        // Reject schemes, credentials, fragments and controls before OkHttp
        // normalizes them; never accept a caller-provided header or client.
        for(int i=0;i<raw.length();i++)if(raw.charAt(i)<=32||raw.charAt(i)=='\\')throw new IllegalArgumentException("Cover URL is invalid");
        java.net.URI parsed;
        try{parsed=new java.net.URI(raw);}catch(java.net.URISyntaxException invalid){throw new IllegalArgumentException("Cover URL is invalid");}
        if(parsed.getRawUserInfo()!=null||parsed.getRawFragment()!=null||parsed.getScheme()!=null&&!("http".equalsIgnoreCase(parsed.getScheme())||"https".equalsIgnoreCase(parsed.getScheme())))throw new IllegalArgumentException("Cover URL is invalid");
        HttpUrl base=HttpUrl.parse(http.getBaseUrl());
        HttpUrl url=parsed.isAbsolute()?HttpUrl.parse(raw):base==null?null:base.resolve(raw);
        if(url==null||!url.username().isEmpty()||!url.password().isEmpty())throw new IllegalArgumentException("Cover URL is invalid");
        // Mihon covers use GET(thumbnailUrl, source.headers) with source.client;
        // chapter getImage/imageRequest overrides can transform page URLs and
        // must not be applied to a cover. The client retains its cookie jar and
        // source interceptors, including browser clearance when available.
        request=new Request.Builder().url(url).headers(http.getHeaders()).build();
        client=http.getClient().newBuilder().callTimeout(8,java.util.concurrent.TimeUnit.SECONDS).build();
        }finally{state.unlock();}
        try(Response response=client.newCall(request).execute()){
            if(!response.isSuccessful())throw new HttpStatusException(response.code());
            if(response.body()==null)throw new IOException("Cover HTTP response is empty");
            if(response.body().contentLength()>MAX_IMAGE_BYTES)throw new IOException("Cover size exceeds native response limit");
            ByteArrayOutputStream output=new ByteArrayOutputStream();try(InputStream input=response.body().byteStream()){byte[] block=new byte[32768];int read;while((read=input.read(block))!=-1){if(output.size()+(long)read>MAX_IMAGE_BYTES)throw new IOException("Cover size exceeds native response limit");output.write(block,0,read);}}
            if(output.size()==0)throw new IOException("Cover response is empty");
            JsonObject result=new JsonObject();result.addProperty("base64",Base64.getEncoder().encodeToString(output.toByteArray()));result.addProperty("mimeType",response.header("Content-Type","application/octet-stream"));return result;
        }
    }
    private static PreferenceScreen screen(CatalogueSource source){
        PreferenceScreen result=new PreferenceScreen(application);
        result.setSharedPreferences(application.getSharedPreferences("source_"+source.getId(),0));
        if(source instanceof ConfigurableSource)((ConfigurableSource)source).setupPreferenceScreen(result);
        android.content.SharedPreferences preferences=application.getSharedPreferences("source_"+source.getId(),0);
        for(Preference preference:result.getPreferences())preference.setSharedPreferences(preferences);
        return result;
    }
    private static JsonArray preferences(JsonObject args){
        CatalogueSource source=registry.source(required(args,"sourceId"));JsonArray result=new JsonArray();int position=0;for(Preference preference:screen(source).getPreferences()){
            JsonObject item=new JsonObject();item.addProperty("key",preference.getKey());item.addProperty("position",position++);item.addProperty("title",String.valueOf(preference.getTitle()));item.addProperty("summary",preference.getSummary()==null?"":preference.getSummary().toString());item.addProperty("type",preference instanceof ListPreference?"ListPreference":preference instanceof TwoStatePreference?"SwitchPreferenceCompat":preference instanceof EditTextPreference?"EditTextPreference":preference.getClass().getSimpleName());item.addProperty("valueType",preference.getDefaultValueType());item.addProperty("enabled",preference.isEnabled());item.addProperty("visible",preference.getVisible());item.addProperty("hasClickListener",preference.hasClickListener());item.add("value",EngineFiles.JSON.toJsonTree(preference.getCurrentValue()));item.add("defaultValue",EngineFiles.JSON.toJsonTree(preference.getDefaultValue()));
            if(preference instanceof ListPreference){item.add("entries",EngineFiles.JSON.toJsonTree(((ListPreference)preference).getEntries()));item.add("entryValues",EngineFiles.JSON.toJsonTree(((ListPreference)preference).getEntryValues()));}
            if(preference instanceof MultiSelectListPreference){item.add("entries",EngineFiles.JSON.toJsonTree(((MultiSelectListPreference)preference).getEntries()));item.add("entryValues",EngineFiles.JSON.toJsonTree(((MultiSelectListPreference)preference).getEntryValues()));}
            JsonObject props=item.deepCopy();props.remove("type");props.remove("position");props.add("currentValue",props.remove("value"));item.add("props",props);result.add(item);
        }return result;
    }
    private static JsonPrimitive setPreference(JsonObject args){
        CatalogueSource source=registry.source(required(args,"sourceId"));String key=required(args,"key");JsonElement value=args.get("value");if(value==null||value.isJsonNull())throw new IllegalArgumentException("Preference value is missing");
        for(Preference preference:screen(source).getPreferences())if(key.equals(preference.getKey())){
            if(!preference.isEnabled()||!preference.getVisible())throw new IllegalArgumentException("Source preference is disabled or hidden");
            Object typed;String type=preference.getDefaultValueType();
            if("Boolean".equalsIgnoreCase(type)||"bool".equalsIgnoreCase(type))typed=value.getAsBoolean();else if("Set<String>".equals(type)){Set<String> strings=new LinkedHashSet<>();for(JsonElement item:value.getAsJsonArray())strings.add(item.getAsString());typed=strings;}else if("Int".equalsIgnoreCase(type)||"Integer".equalsIgnoreCase(type))typed=value.getAsInt();else if("Long".equalsIgnoreCase(type))typed=value.getAsLong();else if("Float".equalsIgnoreCase(type))typed=value.getAsFloat();else typed=value.getAsString();
            SharedPreferences store=preference.getSharedPreferences();
            Map<String,?> before=store.getAll();
            try{
                if(!preference.callChangeListener(typed))throw new IllegalArgumentException("Source rejected the preference value");
                preference.saveNewValue(typed);registry.reload();
                // reload isolates package errors, so explicitly require this
                // source to remain usable before confirming the update.
                registry.source(Long.toString(source.getId()));
                BrowserSession.initialize(dataDirectory,registry);
                return new JsonPrimitive(true);
            }catch(Exception failure){
                try{restorePreferences(store,before);registry.reload();BrowserSession.initialize(dataDirectory,registry);}
                catch(Exception recovery){failure.addSuppressed(recovery);}
                throw new IllegalStateException("Source preference could not be applied",failure);
            }finally{chapterPages.clear();mangaMetadata.clear();SourceContext.clear();}
        }
        throw new IllegalArgumentException("Source preference does not exist");
    }
    @SuppressWarnings("unchecked")
    private static void restorePreferences(SharedPreferences store,Map<String,?> before){
        SharedPreferences.Editor editor=store.edit().clear();
        for(Map.Entry<String,?> item:before.entrySet()){
            String key=item.getKey();Object value=item.getValue();
            if(value instanceof String)editor.putString(key,(String)value);
            else if(value instanceof Boolean)editor.putBoolean(key,(Boolean)value);
            else if(value instanceof Integer)editor.putInt(key,(Integer)value);
            else if(value instanceof Long)editor.putLong(key,(Long)value);
            else if(value instanceof Float)editor.putFloat(key,(Float)value);
            else if(value instanceof Set)editor.putStringSet(key,(Set<String>)value);
            else if(value!=null)throw new IllegalStateException("Unsupported preference recovery type");
        }
        if(!editor.commit())throw new IllegalStateException("Source preference recovery failed");
    }
    private static SManga manga(JsonObject args){String ref=required(args,"ref");SManga cached=mangaMetadata.get(required(args,"sourceId")+"\n"+ref);if(cached!=null)return cached;SManga value=SManga.Companion.create();value.setUrl(ref);value.setTitle(optional(args,"title"));value.setMemo(SourceContext.decode(args.get("memo")));return value;}
    private static SChapter schapter(JsonObject args){SChapter value=SChapter.Companion.create();value.setUrl(required(args,"ref"));value.setName(optional(args,"title"));return value;}
    private static String required(JsonObject value,String key){String result=optional(value,key);if(result.isEmpty()||result.length()>16384)throw new IllegalArgumentException("Required argument is missing or invalid: "+key);return result;}
    private static String optional(JsonObject value,String key){return !value.has(key)||value.get(key).isJsonNull()?"":value.get(key).getAsString();}
}
