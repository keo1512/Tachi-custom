package dev.tachibooks.engine;

import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.atomic.AtomicInteger;
import okhttp3.*;
import android.graphics.Bitmap;
import android.graphics.BitmapFactory;

/** Unmodified requested APKs, original parsers/hooks, synthetic transport only. */
public final class RequestedSourcesReadProof {
    private static volatile String phase="";
    static JsonObject args(String... values){JsonObject o=new JsonObject();for(int i=0;i<values.length;i+=2)o.addProperty(values[i],values[i+1]);return o;}
    static JsonElement call(String method,JsonObject args){JsonObject req=new JsonObject();req.addProperty("method",method);req.add("args",args);JsonObject response=new JsonParser().parse(ExtensionHost.invoke(req.toString())).getAsJsonObject();if(!response.get("ok").getAsBoolean())throw new AssertionError(method+": "+response.get("error"));return response.get("result");}
    static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    static String text(JsonObject o,String name){return o.has(name)?o.get(name).getAsString():"";}
    public static void main(String[] argv)throws Exception{
        try{run(argv);}catch(Throwable error){error.printStackTrace();System.exit(1);}
    }
    static void run(String[] argv)throws Exception{
        require("1.8".equals(System.getProperty("java.specification.version")),"Java8 interpreter required");
        JsonArray options=new JsonParser().parse(new String(Files.readAllBytes(Paths.get(argv[1])),StandardCharsets.UTF_8)).getAsJsonArray();
        call("initialize",args("dataDirectory",Paths.get(argv[0]).toAbsolutePath().toString()));
        JsonArray results=new JsonArray();
        for(JsonElement entry:options){
            JsonObject option=entry.getAsJsonObject();String name=text(option,"name");
            try{
                Path apk=Paths.get(text(option,"apk"));
                require(text(option,"sha256").equals(EngineFiles.sha256(apk)),"Original APK checksum");
                JsonObject installed=call("install",args("apkPath",apk.toString(),"packageHash",EngineFiles.sha256(apk))).getAsJsonObject();
                JsonArray sourceIds=installed.getAsJsonArray("sourceIds");
                for(JsonElement idElement:sourceIds){
                    String id=idElement.getAsString();
                    Field reg=ExtensionHost.class.getDeclaredField("registry");reg.setAccessible(true);
                    CatalogueSource raw=((ExtensionRegistry)reg.get(null)).source(id);
                    require(raw instanceof HttpSource,"Original source has its HTTP image loader");
                    HttpSource source=(HttpSource)raw;
                    call("preferences",args("sourceId",id));
                    AtomicInteger requests=new AtomicInteger();
                    String[] lastImageToken={""};
                    OkHttpClient client=source.getClient();
                    require(client==source.getClient(),"Stable source client for hook fixture");
                    List<Interceptor> interceptors=new ArrayList<>(client.interceptors());
                    interceptors.add(chain->{
                        Request request=chain.request();requests.incrementAndGet();
                        if(request.url().encodedPath().endsWith("/get_token"))return response(request,"{\"action_token\":\"fixture-action\",\"is_bot\":false}".getBytes(StandardCharsets.UTF_8),"application/json");
                        if("image".equals(phase)){
                            lastImageToken[0]=request.header("Token");
                            return response(request,Base64.getDecoder().decode(text(option,"image")),"image/png");
                        }
                        String body=text(option,phase+"Body");
                        if("detail".equals(phase)&&name.equals("MiMi"))body=text(option,"mangaBody");
                        if("chapters".equals(phase)&&name.equals("MiMi"))body=text(option,"tocBody");
                        return response(request,body.getBytes(StandardCharsets.UTF_8),body.startsWith("{")||body.startsWith("[")?"application/json":"text/html");
                    });
                    Field field=OkHttpClient.class.getDeclaredField("interceptors");field.setAccessible(true);field.set(client,Collections.unmodifiableList(interceptors));
                    phase="search";
                    JsonArray books=call("search",args("sourceId",id,"mode","popular")).getAsJsonObject().getAsJsonArray("items");
                    require(books.size()>0,"Catalogue parser returns fixture title");
                    JsonObject book=books.get(0).getAsJsonObject();String bookRef=text(book,"ref");
                    JsonObject parent=args("sourceId",id,"ref",bookRef,"title","Fixture");if(book.has("memo"))parent.add("memo",book.get("memo"));
                    phase="detail";JsonObject detail=call("detail",parent).getAsJsonObject();if(detail.has("memo"))parent.add("memo",detail.get("memo"));
                    phase="chapters";JsonArray chapters=call("chapters",parent).getAsJsonArray();
                    require(chapters.size()>0,"TOC parser returns fixture chapter");
                    JsonObject chapter=chapters.get(0).getAsJsonObject();
                    JsonObject request=args("sourceId",id,"bookRef",bookRef,"ref",text(chapter,"ref"),"title",text(chapter,"title"));
                    if(chapter.has("memo"))request.add("chapterMemo",chapter.get("memo"));if(parent.has("memo"))request.add("bookMemo",parent.get("memo"));
                    phase="chapter";JsonArray pages=call("chapter",request).getAsJsonObject().getAsJsonArray("images");
                    require(pages.size()==2,"Complete fixture page list (2 pages)");
                    JsonObject image=args("sourceId",id,"ref",bookRef,"chapterRef",text(chapter,"ref"),"url",pages.get(0).getAsString());image.addProperty("index",0);
                    if(chapter.has("memo"))image.add("chapterMemo",chapter.get("memo"));if(parent.has("memo"))image.add("bookMemo",parent.get("memo"));
                    phase="image";JsonObject loaded=call("image",image).getAsJsonObject();byte[] bytes=Base64.getDecoder().decode(text(loaded,"base64"));
                    require(bytes.length>0,"Original source image hook returns bytes");
                    if(name.equals("LXManga"))require("fixture-action".equals(lastImageToken[0]),"LXManga original Page.url retains action-token metadata");
                    if(name.equals("CuuTruyen")||name.equals("MinoTruyen")){
                        Bitmap bitmap=BitmapFactory.decodeByteArray(bytes,0,bytes.length);require(bitmap!=null&&bitmap.getWidth()==16&&bitmap.getHeight()==32,"Decoded transformed dimensions");
                        int pixel=bitmap.getPixel(8,4);require((pixel&255)>180&&((pixel>>16)&255)<80,"Original strip transform moves blue lower band to top");bitmap.recycle();
                    }
                    call("clearSourceCache",args());
                    phase="chapter";require(call("chapter",request).getAsJsonObject().getAsJsonArray("images").size()==2,"Cold context read");
                    JsonObject result=args("name",source.getName(),"sourceId",id,"version",text(installed,"version"),"sha256",text(option,"sha256"));result.addProperty("requests",requests.get());result.addProperty("catalogue",true);result.addProperty("detail",true);result.addProperty("toc",true);result.addProperty("pages",2);result.addProperty("image",true);result.addProperty("coldCache",true);result.addProperty("iosRuntimeVerified",false);results.add(result);
                    System.out.println("REQUESTED_SOURCE_READ_OK "+source.getName()+" "+text(installed,"version"));
                }
            }catch(Throwable failure){JsonObject result=args("name",name,"failureType",failure.getClass().getSimpleName(),"failure",failure.toString());results.add(result);System.out.println("REQUESTED_SOURCE_READ_FAILED "+name+" "+failure);}
        }
        Files.write(Paths.get(argv[2]),new GsonBuilder().setPrettyPrinting().create().toJson(results).getBytes(StandardCharsets.UTF_8));
        for(JsonElement result:results)if(result.getAsJsonObject().has("failure"))System.exit(1);
        System.exit(0);
    }
    static Response response(Request request,byte[] body,String type){return new Response.Builder().request(request).protocol(Protocol.HTTP_1_1).code(200).message("OK").header("Content-Type",type).body(ResponseBody.create(MediaType.parse(type),body)).build();}
}
