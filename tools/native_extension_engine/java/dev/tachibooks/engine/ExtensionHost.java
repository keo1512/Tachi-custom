package dev.tachibooks.engine;

import android.app.Application;
import androidx.preference.*;
import com.google.gson.*;
import eu.kanade.tachiyomi.network.NetworkHelper;
import eu.kanade.tachiyomi.source.*;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.io.*;
import java.lang.reflect.Method;
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
        final String sourceId,ref;final List<? extends Page> pages;
        CachedChapter(String sourceId,String ref,List<? extends Page> pages){this.sourceId=sourceId;this.ref=ref;this.pages=pages;}
    }
    private ExtensionHost(){}
    // Covers only read the loaded registry and use OkHttp's thread-safe client.
    // Everything that can mutate registry/page/metadata state stays exclusive.
    // A fair lock lets a waiting reader-page request run before newer covers.
    private static final ReentrantReadWriteLock requests=new ReentrantReadWriteLock(true);
    public static String invoke(String requestJson){
        Lock lock=requests.writeLock();
        try{if(requestJson!=null&&requestJson.length()<=1024*1024&&"cover".equals(new JsonParser().parse(requestJson).getAsJsonObject().get("method").getAsString()))lock=requests.readLock();}catch(RuntimeException invalid){}
        lock.lock();
        try{return invokeLocked(requestJson);}finally{lock.unlock();}
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
                if(registry==null)throw new IllegalStateException("Engine must be initialized first");
                switch(method){
                    case "sources":result=sources();break;
                    case "health":result=status();break;
                    case "clearSourceCache":
                        if(!args.entrySet().isEmpty())throw new IllegalArgumentException("Cache cleanup accepts no paths");
                        mangaMetadata.clear();chapterPages.clear();result=new JsonPrimitive(true);break;
                    case "clearCookies":
                        if(!args.entrySet().isEmpty())throw new IllegalArgumentException("Cookie cleanup accepts no paths");
                        result=BrowserSession.clear(registry);break;
                    case "extensions":result=registry.extensions();break;
                    case "inspectPackage":result=registry.inspect(Paths.get(required(args,"apkPath")));break;
                    case "install":result=registry.install(Paths.get(required(args,"apkPath")),optional(args,"packageUrl"),optional(args,"iconUrl"),optional(args,"packageHash"));chapterPages.clear();mangaMetadata.clear();BrowserSession.initialize(dataDirectory,registry);break;
                    case "uninstall":result=new JsonPrimitive(registry.uninstall(required(args,"id")));chapterPages.clear();mangaMetadata.clear();break;
                    case "search":result=search(args);break;
                    case "filters":result=SourceFilterCodec.encode(registry.source(required(args,"sourceId")).getFilterList());break;
                    case "detail":result=detail(args);break;
                    case "chapters":result=chapters(args);break;
                    case "chapter":result=chapter(args);break;
                    case "image":result=image(args);break;
                    case "cover":result=cover(args);break;
                    case "browserSession":result=BrowserSession.apply(args,registry.source(required(args,"sourceId")));break;
                    case "preferences":result=preferences(args);break;
                    case "setPreference":result=setPreference(args);break;
                    default:throw new IllegalArgumentException("Unsupported engine method");
                }
            }
            response.addProperty("ok",true);response.add("result",result);
        }catch(Throwable failure){
            JsonObject error=new JsonObject();String code,message;
            if(requiresBrowser(failure)){code="source_requires_browser";message="The source requires an interactive browser session.";}
            else if(failure instanceof HttpStatusException){code="http_error";message="Source returned an HTTP error";error.addProperty("httpStatus",((HttpStatusException)failure).status);}
            else if(failure instanceof SourceNotLoadedException){code="source_not_installed";message="Required source extension is not loaded.";}
            else if(failure instanceof LinkageError){code="unsupported_extension";message="The extension requires an Android or Java API that this engine does not provide.";}
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
        if(GlobalContext.INSTANCE.getOrNull()==null)GlobalContext.INSTANCE.startKoin(KoinApplication.Companion.init());
        register(Application.class,application);register(NetworkHelper.class,new NetworkHelper(application));
        Json json=JsonKt.Json(Json.Default,new Function1<JsonBuilder,Unit>(){public Unit invoke(JsonBuilder builder){builder.setIgnoreUnknownKeys(true);return Unit.INSTANCE;}});
        register(Json.class,json);ExtensionRegistry loaded=new ExtensionRegistry(requested);BrowserSession.initialize(requested,loaded);registry=loaded;dataDirectory=requested;return status();
    }
    private static JsonObject status(){JsonObject result=new JsonObject();result.addProperty("engine","tachi");result.addProperty("protocolVersion",1);result.addProperty("sourceCount",registry.sources().size());result.addProperty("execution","java-interpreter");return result;}
    private static <T>void register(final Class<T> type,final T value){
        org.koin.core.Koin koin=GlobalContext.INSTANCE.get();
        Qualifier root=koin.getScopeRegistry().getRootScope().getScopeQualifier();
        BeanDefinition<T> definition=new BeanDefinition<>(root,JvmClassMappingKt.getKotlinClass(type),null,
            (scope,parameters)->value,Kind.Singleton,Collections.emptyList(),true);
        koin.getInstanceRegistry().saveMapping(true,BeanDefinitionKt.indexKey(JvmClassMappingKt.getKotlinClass(type),null,root),new SingleInstanceFactory<>(definition),false);
    }
    private static JsonArray sources(){JsonArray result=new JsonArray();for(CatalogueSource source:registry.sources()){
        JsonObject item=new JsonObject();item.addProperty("id",Long.toString(source.getId()));item.addProperty("name",source.getName());item.addProperty("lang",source.getLang());item.addProperty("baseUrl",source instanceof HttpSource?((HttpSource)source).getBaseUrl():"");item.addProperty("iconUrl",registry.iconUrl(Long.toString(source.getId())));item.addProperty("engine","tachi");item.addProperty("kind","manga");item.addProperty("configurable",source instanceof ConfigurableSource);result.add(item);
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
        JsonArray genres=new JsonArray();if(manga.getGenre()!=null)for(String genre:manga.getGenre().split(","))if(!genre.trim().isEmpty())genres.add(genre.trim());result.add("genres",genres);return result;
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
        return book(source,updated);
    }
    private static JsonArray chapters(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));
        SMangaUpdate update=SuspendBridge.await(completion->source.getMangaUpdate(manga(args),Collections.emptyList(),false,true,completion));
        List<SChapter> chapters=new ArrayList<>(update.getChapters());Collections.reverse(chapters);JsonArray result=new JsonArray();int ordinal=0;
        for(SChapter chapter:chapters){JsonObject value=new JsonObject();value.addProperty("ref",chapter.getUrl());value.addProperty("title",chapter.getName());value.addProperty("index",ordinal++);value.addProperty("number",chapter.getChapter_number());value.addProperty("uploadedAt",chapter.getDate_upload());value.addProperty("scanlator",chapter.getScanlator());result.add(value);}return result;
    }
    private static JsonObject chapter(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));String ref=required(args,"ref");
        List<? extends Page> pages=loadPages(source,ref,optional(args,"title"));JsonArray images=new JsonArray();JsonObject imageHeaders=new JsonObject();
        for(Page page:pages){String image=page.getImageUrl();if(image==null||image.isEmpty()){if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source did not return image URLs");image=SuspendBridge.await(completion->((HttpSource)source).getImageUrl(page,completion));page.setImageUrl(image);}
            if(image==null||image.isEmpty())throw new IllegalArgumentException("Extension returned an empty image URL");images.add(image);
            if(source instanceof HttpSource){Request request=imageRequest((HttpSource)source,page);imageHeaders.add(image,requestHeaders((HttpSource)source,request));}
        }
        JsonObject result=new JsonObject();result.addProperty("kind","manga");result.add("images",images);result.add("headers",new JsonObject());result.add("imageHeaders",imageHeaders);return result;
    }
    private static List<? extends Page> loadPages(CatalogueSource source,String ref,String title)throws Exception{
        SChapter chapter=SChapter.Companion.create();chapter.setUrl(ref);chapter.setName(title);
        List<? extends Page> pages=SuspendBridge.await(completion->source.getPageList(chapter,completion));
        if(pages==null||pages.size()>10000)throw new IllegalArgumentException("Source returned an invalid page count");
        List<? extends Page> retained=new ArrayList<>(pages);
        String sourceId=Long.toString(source.getId());chapterPages.put(sourceId+"\n"+ref,new CachedChapter(sourceId,ref,retained));
        return retained;
    }
    private static Request imageRequest(HttpSource source,Page page)throws Exception{
        // The official API protects this hook; reflective invocation preserves overrides
        // in the original package and exposes its exact headers to the native image loader.
        Method method=HttpSource.class.getDeclaredMethod("imageRequest",Page.class);
        method.setAccessible(true);return (Request)method.invoke(source,page);
    }
    private static JsonObject requestHeaders(HttpSource source,Request request){
        JsonObject headers=new JsonObject();for(String name:request.headers().names())headers.addProperty(name,request.header(name));
        List<Cookie> cookies=source.getClient().cookieJar().loadForRequest(request.url());
        if(!cookies.isEmpty()&&!headers.has("Cookie")){StringBuilder value=new StringBuilder();for(Cookie cookie:cookies){if(value.length()>0)value.append("; ");value.append(cookie.name()).append('=').append(cookie.value());}headers.addProperty("Cookie",value.toString());}
        return headers;
    }
    private static JsonObject image(JsonObject args)throws Exception{
        CatalogueSource source=registry.source(required(args,"sourceId"));if(!(source instanceof HttpSource))throw new IllegalArgumentException("Source has no HTTP image loader");
        String url=required(args,"url"),chapterRef=optional(args,"chapterRef"),sourceId=Long.toString(source.getId());
        int ordinal=args.has("index")?args.get("index").getAsInt():0;Page page=null;
        if(!chapterRef.isEmpty()){
            CachedChapter cached=chapterPages.get(sourceId+"\n"+chapterRef);
            List<? extends Page> pages=cached!=null?cached.pages:loadPages(source,chapterRef,optional(args,"chapterTitle"));
            if(ordinal<0||ordinal>=pages.size())throw new IllegalArgumentException("Page index is invalid");page=pages.get(ordinal);
        }else{
            // Compatibility for clients that obtained a chapter immediately before
            // requesting its image. A cache miss needs the stable chapter identity.
            for(CachedChapter cached:chapterPages.values())if(cached.sourceId.equals(sourceId)&&ordinal>=0&&ordinal<cached.pages.size()){
                Page candidate=cached.pages.get(ordinal);
                if(url.equals(candidate.getImageUrl())){if(page!=null&&page!=candidate)throw new IllegalArgumentException("Image belongs to more than one cached chapter");page=candidate;}
            }
            if(page==null)throw new IllegalArgumentException("Image request requires its chapter reference");
        }
        final Page originalPage=page;
        if(page.getImageUrl()==null||page.getImageUrl().isEmpty())page.setImageUrl(SuspendBridge.await(completion->((HttpSource)source).getImageUrl(originalPage,completion)));
        if(!url.equals(page.getImageUrl()))throw new IllegalArgumentException("Image URL no longer matches the source page");
        try(Response response=SuspendBridge.await(completion->((HttpSource)source).getImage(originalPage,completion))){
            if(!response.isSuccessful())throw new HttpStatusException(response.code());
            if(response.body()==null)throw new IOException("Image HTTP response is empty");
            if(response.body().contentLength()>MAX_IMAGE_BYTES)throw new IOException("Image size exceeds native response limit");
            ByteArrayOutputStream output=new ByteArrayOutputStream();try(InputStream input=response.body().byteStream()){byte[] block=new byte[32768];int read;while((read=input.read(block))!=-1){if(output.size()+(long)read>MAX_IMAGE_BYTES)throw new IOException("Image size exceeds native response limit");output.write(block,0,read);}}
            JsonObject result=new JsonObject();result.addProperty("base64",Base64.getEncoder().encodeToString(output.toByteArray()));result.addProperty("mimeType",response.header("Content-Type","application/octet-stream"));return result;
        }
    }
    private static JsonObject cover(JsonObject args)throws Exception{
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
        Request request=new Request.Builder().url(url).headers(http.getHeaders()).build();
        try(Response response=http.getClient().newBuilder().callTimeout(20,java.util.concurrent.TimeUnit.SECONDS).build().newCall(request).execute()){
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
            if(!preference.callChangeListener(typed))throw new IllegalArgumentException("Source rejected the preference value");preference.saveNewValue(typed);registry.reload();chapterPages.clear();mangaMetadata.clear();try{BrowserSession.initialize(dataDirectory,registry);}catch(IOException failure){throw new IllegalStateException("Saved browser session could not be restored",failure);}return new JsonPrimitive(true);
        }
        throw new IllegalArgumentException("Source preference does not exist");
    }
    private static SManga manga(JsonObject args){String ref=required(args,"ref");SManga cached=mangaMetadata.get(required(args,"sourceId")+"\n"+ref);if(cached!=null)return cached;SManga value=SManga.Companion.create();value.setUrl(ref);value.setTitle(optional(args,"title"));return value;}
    private static SChapter schapter(JsonObject args){SChapter value=SChapter.Companion.create();value.setUrl(required(args,"ref"));value.setName(optional(args,"title"));return value;}
    private static String required(JsonObject value,String key){String result=optional(value,key);if(result.isEmpty()||result.length()>16384)throw new IllegalArgumentException("Required argument is missing or invalid: "+key);return result;}
    private static String optional(JsonObject value,String key){return !value.has(key)||value.get(key).isJsonNull()?"":value.get(key).getAsString();}
}
