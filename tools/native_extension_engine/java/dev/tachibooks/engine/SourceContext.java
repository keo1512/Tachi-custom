package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.nio.charset.StandardCharsets;
import java.util.*;
import okhttp3.HttpUrl;

/** Source-owned context is opaque; never rebuild an SChapter using only its URL. */
final class SourceContext {
    static final class Missing extends IllegalStateException { Missing(){super("Source chapter context must be restored");} }
    private static final Map<String,SChapter> chapters=new LinkedHashMap<String,SChapter>(128,0.75f,true){
        protected boolean removeEldestEntry(Map.Entry<String,SChapter> entry){return size()>2048;}
    };
    private SourceContext(){}
    static void clear(){chapters.clear();}
    static String key(String source,String book,String chapter){return source+"\n"+book+"\n"+chapter;}
    static JsonObject encode(kotlinx.serialization.json.JsonObject memo){
        String json=memo.toString();
        if(json.getBytes(StandardCharsets.UTF_8).length>65536)throw new IllegalArgumentException("Source context exceeds limit");
        return new JsonParser().parse(json).getAsJsonObject();
    }
    static kotlinx.serialization.json.JsonObject decode(JsonElement memo){
        if(memo==null||memo.isJsonNull())memo=new JsonObject();
        if(!memo.isJsonObject()||memo.toString().getBytes(StandardCharsets.UTF_8).length>65536)throw new IllegalArgumentException("Invalid source context");
        return (kotlinx.serialization.json.JsonObject)kotlinx.serialization.json.Json.Default.parseToJsonElement(memo.toString());
    }
    static void remember(CatalogueSource source,String book,List<? extends SChapter> values){
        for(SChapter chapter:values)chapters.put(key(Long.toString(source.getId()),book,chapter.getUrl()),chapter);
    }
    static String url(CatalogueSource source,SChapter chapter){
        if(!(source instanceof HttpSource))return "";
        try{HttpUrl url=HttpUrl.parse(((HttpSource)source).getChapterUrl(chapter));return url!=null&&url.username().isEmpty()&&url.password().isEmpty()&&url.fragment()==null?url.toString():"";}catch(RuntimeException|LinkageError unavailable){return "";}
    }
    static SChapter chapter(CatalogueSource source,String book,String ref,String title,JsonElement memo){
        SChapter saved=chapters.get(key(Long.toString(source.getId()),book,ref));
        if(saved!=null)return saved;
        // Legacy backups retain a canonical URL while newer extensions use a
        // short ID plus memo. Only an exact source-generated URL is an alias.
        for(Map.Entry<String,SChapter> entry:chapters.entrySet()){
            if(entry.getKey().startsWith(key(Long.toString(source.getId()),book,""))&&sameUrl(source,ref,url(source,entry.getValue())))return entry.getValue();
        }
        SChapter chapter=SChapter.Companion.create();chapter.setUrl(ref);chapter.setName(title);chapter.setMemo(decode(memo));return chapter;
    }
    static SChapter match(CatalogueSource source,String ref,List<? extends SChapter> values){
        SChapter found=null;
        for(SChapter candidate:values)if(ref.equals(candidate.getUrl())||sameUrl(source,ref,url(source,candidate))){
            if(found!=null&&found!=candidate)throw new IllegalArgumentException("Chapter context is ambiguous");
            found=candidate;
        }
        return found;
    }
    private static boolean sameUrl(CatalogueSource source,String left,String right){
        if(left.equals(right))return !left.isEmpty();
        HttpUrl a=HttpUrl.parse(left),b=HttpUrl.parse(right);
        if(a==null&&source instanceof HttpSource){
            HttpUrl base=HttpUrl.parse(((HttpSource)source).getBaseUrl());
            if(base!=null)a=base.resolve(left);
        }
        if(a==null||b==null||!a.scheme().equals(b.scheme())||!a.host().equals(b.host())||a.port()!=b.port()||!a.username().isEmpty()||!a.password().isEmpty()||a.fragment()!=null)return false;
        return a.encodedPath().replaceAll("/+$","").equals(b.encodedPath().replaceAll("/+$",""))&&Objects.equals(a.encodedQuery(),b.encodedQuery());
    }
}
