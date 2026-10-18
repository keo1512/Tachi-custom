package dev.tachibooks.engine;

import android.graphics.*;
import com.google.gson.*;
import eu.kanade.tachiyomi.source.CatalogueSource;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.io.*;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.*;
import kotlin.coroutines.Continuation;
import okhttp3.*;

/** No website data. Exercise source-owned identity and portable pixel contracts. */
public final class SourceContextAndGraphicsProof {
    static final String ID="9223372036854775601";
    static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    static JsonObject args(String... values){JsonObject o=new JsonObject();for(int i=0;i<values.length;i+=2)o.addProperty(values[i],values[i+1]);return o;}
    static JsonElement call(String method,JsonObject args){JsonObject req=new JsonObject();req.addProperty("method",method);req.add("args",args);JsonObject response=new JsonParser().parse(ExtensionHost.invoke(req.toString())).getAsJsonObject();if(!response.get("ok").getAsBoolean())throw new AssertionError(method+": "+response.get("error"));return response.get("result");}
    static final class Source extends HttpSource {
        String lastImage="";
        final OkHttpClient client=new OkHttpClient.Builder().addInterceptor(chain->{
            lastImage=chain.request().url().encodedPath();
            return new Response.Builder().request(chain.request()).protocol(Protocol.HTTP_1_1).code(200).message("OK").body(ResponseBody.create(MediaType.parse("image/png"),new byte[]{1,2,3})).build();
        }).build();
        public long getId(){return Long.parseLong(ID);}
        public String getName(){return "Context fixture";}
        public String getLang(){return "vi";}
        public boolean getSupportsLatest(){return false;}
        public String getBaseUrl(){return "https://fixture.invalid";}
        public OkHttpClient getClient(){return client;}
        String parent(SChapter chapter){return SourceContext.encode(chapter.getMemo()).get("book").getAsString();}
        public String getChapterUrl(SChapter chapter){return getBaseUrl()+"/read/"+parent(chapter)+"/"+chapter.getUrl()+"/";}
        public Object getPageList(SChapter chapter,Continuation<? super List<? extends Page>> completion){return Collections.singletonList(new Page(0,"original-page-context",getBaseUrl()+"/image/"+parent(chapter)+".png",null));}
    }
    public static void main(String[] argv)throws Exception{try{if("graphics".equals(argv[1]))graphics();else context(argv[0]);}catch(Throwable failure){failure.printStackTrace();System.exit(1);}System.exit(0);}
    @SuppressWarnings("unchecked") static void context(String directory)throws Exception{
        call("initialize",args("dataDirectory",Paths.get(directory).toAbsolutePath().toString()));
        Source source=new Source();Field registryField=ExtensionHost.class.getDeclaredField("registry");registryField.setAccessible(true);Object registry=registryField.get(null);Field sources=ExtensionRegistry.class.getDeclaredField("sources");sources.setAccessible(true);((Map<String,CatalogueSource>)sources.get(registry)).put(ID,source);
        JsonObject a=args("sourceId",ID,"bookRef","book-a","ref","oneshot","title","Fixture");a.add("chapterMemo",args("book","a"));
        JsonObject b=args("sourceId",ID,"bookRef","book-b","ref","oneshot","title","Fixture");b.add("chapterMemo",args("book","b"));
        String imageA=call("chapter",a).getAsJsonObject().getAsJsonArray("images").get(0).getAsString();
        call("chapter",b);
        JsonObject image=args("sourceId",ID,"ref","book-a","chapterRef","oneshot","url",imageA);image.addProperty("index",0);image.add("chapterMemo",a.get("chapterMemo"));
        call("image",image);require("/image/a.png".equals(source.lastImage),"An identical short chapter ID in another book cannot replace original Page context");
        call("clearSourceCache",args());call("image",image);require("/image/a.png".equals(source.lastImage),"Cold image reload retains chapter memo");
        SChapter chapter=SChapter.Companion.create();chapter.setUrl("oneshot");chapter.setName("Fixture");chapter.setMemo(SourceContext.decode(args("book","a")));
        SourceContext.remember(source,"book-a",Collections.singletonList(chapter));
        require(SourceContext.chapter(source,"book-a","oneshot","Ignored",null)==chapter,"Original cached SChapter survives");
        require(SourceContext.match(source,"/read/a/oneshot",Collections.singletonList(chapter))==chapter,"Relative backup URL resolves against this source origin");
        require(SourceContext.match(source,"https://other.invalid/read/a/oneshot/",Collections.singletonList(chapter))==null,"A different authority cannot become an alias");
        require(SourceContext.match(source,"https://fixture.invalid/read/a/oneshot/?different=1",Collections.singletonList(chapter))==null,"Query identity is preserved");
        StringBuilder large=new StringBuilder();for(int i=0;i<66000;i++)large.append('x');boolean bounded=false;try{SourceContext.decode(args("large",large.toString()));}catch(IllegalArgumentException expected){bounded=true;}require(bounded,"Source memo bytes are bounded");
        System.out.println("SOURCE_CONTEXT_ISOLATION_OK short-ids parent memo relative-url authority cold-cache iosRuntimeVerified=false");
    }
    static void graphics()throws Exception{
        Bitmap bitmap=Bitmap.createBitmap(8,4,Bitmap.Config.ARGB_8888);for(int y=0;y<4;y++)for(int x=0;x<8;x++)bitmap.setPixel(x,y,y<2?0xffff0000:0xff0000ff);
        ByteArrayOutputStream encoded=new ByteArrayOutputStream();require(bitmap.compress(Bitmap.CompressFormat.PNG,100,encoded),"PNG encode");byte[] bytes=encoded.toByteArray();Bitmap decoded=BitmapFactory.decodeByteArray(bytes,0,bytes.length);require(decoded.getPixel(3,0)==0xffff0000&&decoded.getPixel(3,3)==0xff0000ff,"ARGB scanline decode");require(decoded.getByteCount()==8*4*4,"Logical pixel count excludes transport dimensions");
        Bitmap copy=decoded.copy(Bitmap.Config.ARGB_8888,true);require(copy.getPixel(3,3)==0xff0000ff,"Copy after zero-copy header removal");
        Bitmap output=Bitmap.createBitmap(8,4,Bitmap.Config.ARGB_8888);Canvas canvas=new Canvas(output);canvas.drawBitmap(decoded,new Rect(0,2,8,4),new Rect(0,0,8,2),null);canvas.drawBitmap(decoded,new Rect(0,0,8,2),new Rect(0,2,8,4),null);require(output.getPixel(3,0)==0xff0000ff&&output.getPixel(3,3)==0xffff0000,"Source strip rectangle rearrangement");
        BitmapFactory.Options bounds=new BitmapFactory.Options();bounds.inJustDecodeBounds=true;require(BitmapFactory.decodeByteArray(bytes,0,bytes.length,bounds)==null&&bounds.outWidth==8&&bounds.outHeight==4,"Decode bounds");
        BitmapFactory.Options sampled=new BitmapFactory.Options();sampled.inSampleSize=2;Bitmap small=BitmapFactory.decodeByteArray(bytes,0,bytes.length,sampled);require(small.getWidth()==4&&small.getHeight()==2,"Bounded sample scaling");
        require(BitmapFactory.decodeByteArray(new byte[]{1,2,3},0,3)==null,"Invalid image rejected");
        boolean rejected=false;try{Bitmap.createBitmap(16384,16384,Bitmap.Config.ARGB_8888);}catch(IllegalArgumentException expected){rejected=true;}require(rejected,"Oversized pixel allocation rejected before allocation");
        for(Bitmap value:Arrays.asList(bitmap,decoded,copy,output,small)){value.recycle();require(value.isRecycled(),"Pixel buffers released");}
        System.out.println("PORTABLE_GRAPHICS_OK decode encode copy strips bounds sampling recycle desktopCodec=true iosRuntimeVerified=false");
    }
}
