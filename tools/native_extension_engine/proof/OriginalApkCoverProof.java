package dev.tachibooks.engine;

import com.google.gson.*;
import java.awt.image.BufferedImage;
import java.io.ByteArrayInputStream;
import java.nio.file.*;
import java.util.Base64;
import javax.imageio.ImageIO;

/** Opt-in original TruyenQQ cover RPC proof; only the mainstream One Piece cover is fetched. */
public final class OriginalApkCoverProof {
    private static final String SOURCE_ID="2553532324170433933";
    private static JsonObject args(String... pairs){JsonObject result=new JsonObject();for(int i=0;i<pairs.length;i+=2)result.addProperty(pairs[i],pairs[i+1]);return result;}
    private static JsonElement call(String method,JsonObject args){
        JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);
        JsonObject response=new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();
        if(!response.get("ok").getAsBoolean())throw new IllegalStateException("Cover proof operation failed: "+method+" ("+response.getAsJsonObject("error").get("type").getAsString()+")");
        return response.get("result");
    }
    public static void main(String[] argv)throws Exception{
        if(argv.length!=3)throw new IllegalArgumentException("Usage: dataDirectory originalTruyenQQAPK outputReport");
        if(!"1.8".equals(System.getProperty("java.specification.version"))||!java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"))throw new IllegalStateException("Use Java8 -Xint");
        Path directory=Paths.get(argv[0]).toAbsolutePath(),apk=Paths.get(argv[1]).toAbsolutePath();
        call("initialize",args("dataDirectory",directory.toString()));
        JsonObject installed=call("install",args("apkPath",apk.toString(),"packageHash",EngineFiles.sha256(apk))).getAsJsonObject();
        JsonArray items=call("search",args("sourceId",SOURCE_ID,"mode","popular")).getAsJsonObject().getAsJsonArray("items");
        JsonObject book=null;
        for(JsonElement item:items){JsonObject candidate=item.getAsJsonObject();if("One Piece".equals(candidate.get("title").getAsString())){book=candidate;break;}}
        if(book==null)throw new IllegalStateException("Mainstream cover fixture unavailable; no cover downloaded");
        JsonObject image=call("cover",args("sourceId",SOURCE_ID,"url",book.get("coverUrl").getAsString())).getAsJsonObject();
        byte[] bytes=Base64.getDecoder().decode(image.get("base64").getAsString());
        if(bytes.length==0||bytes.length>8*1024*1024)throw new IllegalStateException("Cover size invalid");
        BufferedImage decoded=ImageIO.read(new ByteArrayInputStream(bytes));
        if(decoded==null||decoded.getWidth()<=0||decoded.getHeight()<=0)throw new IllegalStateException("Cover could not fully decode");
        JsonObject report=new JsonObject();report.addProperty("originalApkSha256",EngineFiles.sha256(apk));report.add("installedVersion",installed.get("version"));report.addProperty("sourceId",SOURCE_ID);report.addProperty("title","One Piece");report.addProperty("catalogueCount",items.size());report.addProperty("rpcMethod","cover");report.addProperty("mimeType",image.get("mimeType").getAsString());report.addProperty("bytes",bytes.length);report.addProperty("sha256",EngineFiles.sha256(bytes));report.addProperty("decoded",true);report.addProperty("width",decoded.getWidth());report.addProperty("height",decoded.getHeight());report.addProperty("imageSavedOrDisplayed",false);report.addProperty("javaExecution",System.getProperty("os.name")+" Java8 -Xint; runtime bundle truststore");report.addProperty("deviceRuntimeVerified",false);
        EngineFiles.write(Paths.get(argv[2]),new GsonBuilder().setPrettyPrinting().create().toJson(report));
        System.out.println("ORIGINAL_APK_COVER_RPC_PROOF_OK bytes="+bytes.length+" width="+decoded.getWidth()+" height="+decoded.getHeight());System.exit(0);
    }
}
