package dev.tachibooks.engine;

import com.google.gson.*;
import java.nio.file.*;
import java.util.Base64;

/** Unchanged CBHentai1.6.96 APK against a non-content loopback fixture. */
public final class OriginalCbhentaiContextProof {
    static JsonObject args(String... values){JsonObject o=new JsonObject();for(int i=0;i<values.length;i+=2)o.addProperty(values[i],values[i+1]);return o;}
    static JsonObject rpc(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}
    static JsonElement call(String method,JsonObject args){JsonObject value=rpc(method,args);if(!value.get("ok").getAsBoolean())throw new AssertionError(method+": "+value.getAsJsonObject("error"));return value.get("result");}
    static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] argv)throws Exception{
        try{run(argv);}catch(Throwable error){error.printStackTrace();System.exit(1);}
    }
    static void run(String[] argv)throws Exception{
        require("1.8".equals(System.getProperty("java.specification.version")),"Java8 required");
        String id="823638192569572166",base=argv[2];
        Path apk=Paths.get(argv[1]);
        require("ebbc170abc008257a34f358e0f15850615b0e34a33917f65bc1662c8a991e5e2".equals(EngineFiles.sha256(apk)),"Original CBHentai APK checksum");
        call("initialize",args("dataDirectory",Paths.get(argv[0]).toAbsolutePath().toString()));
        call("install",args("apkPath",apk.toAbsolutePath().toString(),"packageHash",EngineFiles.sha256(apk)));
        call("preferences",args("sourceId",id));
        // The production source validates public HTTPS preferences. Write the
        // disposable fixture's loopback address directly to its own store.
        java.lang.reflect.Field app=ExtensionHost.class.getDeclaredField("application");app.setAccessible(true);
        ((EngineApplication)app.get(null)).getSharedPreferences("source_"+id,0).edit().putString("overrideBaseUrl",base).commit();
        java.lang.reflect.Field reg=ExtensionHost.class.getDeclaredField("registry");reg.setAccessible(true);
        eu.kanade.tachiyomi.source.online.HttpSource source=(eu.kanade.tachiyomi.source.online.HttpSource)((ExtensionRegistry)reg.get(null)).source(id);
        require(base.equals(source.getBaseUrl()),"Fixture base must be selected before network work: "+source.getBaseUrl());
        // This is the full URL kept by old libraries. The source now expects a
        // short ID plus SChapter.memo; its old-shaped input really fails.
        JsonObject before=rpc("chapter",args("sourceId",id,"ref",base+"/read/fixture/oneshot/","title","Fixture"));
        require(!before.get("ok").getAsBoolean(),"Old URL-only chapter reproduces the source failure");
        require("IllegalStateException".equals(before.getAsJsonObject("error").get("type").getAsString()),"Observed error type reproduced");
        JsonObject memo=args("mangaPath","/read/fixture");
        JsonObject chapter=args("sourceId",id,"bookRef","123","ref","oneshot","title","Fixture");chapter.add("chapterMemo",memo);
        JsonObject parentMemo=args("mangaPath","/read/fixture");chapter.add("bookMemo",parentMemo);
        JsonArray images=call("chapter",chapter).getAsJsonObject().getAsJsonArray("images");
        require(images.size()==2,"Every token-paginated page is returned");
        JsonObject image=args("sourceId",id,"ref","123","chapterRef","oneshot","url",images.get(0).getAsString());image.add("chapterMemo",memo);image.addProperty("index",0);
        require(Base64.getDecoder().decode(call("image",image).getAsJsonObject().get("base64").getAsString()).length>0,"Original image loader reads fixture bytes");
        call("clearSourceCache",args());
        require(call("chapter",chapter).getAsJsonObject().getAsJsonArray("images").size()==2,"Persisted memo restores context after cache eviction");
        call("clearSourceCache",args());
        require(Base64.getDecoder().decode(call("image",image).getAsJsonObject().get("base64").getAsString()).length>0,"Cold partial download retains source context");
        System.out.println("ORIGINAL_CBHENTAI_CONTEXT_OK version=1.6.96 original-apk token-pagination cookies image cold-cache iosRuntimeVerified=false");System.exit(0);
    }
}
