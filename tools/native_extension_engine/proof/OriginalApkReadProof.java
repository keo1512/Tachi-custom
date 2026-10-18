package dev.tachibooks.engine;

import com.google.gson.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Base64;

/** Opt-in original-APK read proof. Options are read from a local file and never logged. */
public final class OriginalApkReadProof {
    private static JsonElement call(String method,JsonObject args)throws Exception{
        JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);
        JsonObject response=new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();
        if(!response.get("ok").getAsBoolean())throw new Exception("Original APK operation failed: "+method+" ("+response.getAsJsonObject("error").get("type").getAsString()+")");
        return response.get("result");
    }
    private static JsonObject args(String... values){JsonObject result=new JsonObject();for(int i=0;i<values.length;i+=2)result.addProperty(values[i],values[i+1]);return result;}
    public static void main(String[] argv)throws Exception{
        // An extension can start non-daemon workers. Report a failed proof and
        // terminate its disposable JVM instead of hiding the failure in a timeout.
        try{run(argv);}catch(Throwable failure){failure.printStackTrace();System.exit(1);}
    }
    private static void run(String[] argv)throws Exception{
        if(argv.length!=4)throw new IllegalArgumentException("Usage: dataDirectory originalAPK localOptionsJSON outputReport");
        if(!"1.8".equals(System.getProperty("java.specification.version")))throw new IllegalStateException("Run with Java8 -Xint");
        if(!java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"))throw new IllegalStateException("Interpreter proof requires -Xint");
        Path directory=Paths.get(argv[0]).toAbsolutePath(),apk=Paths.get(argv[1]).toAbsolutePath();
        JsonObject options=new JsonParser().parse(new String(Files.readAllBytes(Paths.get(argv[2])),StandardCharsets.UTF_8)).getAsJsonObject();
        call("initialize",args("dataDirectory",directory.toString()));
        String apkHash=EngineFiles.sha256(apk);
        JsonObject installed=call("install",args("apkPath",apk.toString(),"packageHash",apkHash)).getAsJsonObject();
        JsonArray sources=call("sources",args()).getAsJsonArray();
        String id=options.has("sourceId")?options.get("sourceId").getAsString():installed.getAsJsonArray("sourceIds").get(0).getAsString();
        call("preferences",args("sourceId",id));
        if(options.has("preferences"))for(java.util.Map.Entry<String,JsonElement> preference:options.getAsJsonObject("preferences").entrySet()){
            JsonObject value=args("sourceId",id,"key",preference.getKey());value.add("value",preference.getValue());call("setPreference",value);
        }
        String query=options.has("query")?options.get("query").getAsString():"";
        JsonArray items=call("search",args("sourceId",id,"query",query)).getAsJsonObject().getAsJsonArray("items");int searchCount=items.size();
        if(items.size()==0&&options.has("fallbackPopular")&&options.get("fallbackPopular").getAsBoolean())items=call("search",args("sourceId",id,"mode","popular")).getAsJsonObject().getAsJsonArray("items");
        if(items.size()==0)throw new IllegalStateException("Original extension returned no title for the requested catalogue");
        String book=items.get(0).getAsJsonObject().get("ref").getAsString();call("detail",args("sourceId",id,"ref",book));
        JsonArray chapters=call("chapters",args("sourceId",id,"ref",book)).getAsJsonArray();if(chapters.size()==0)throw new IllegalStateException("Original extension returned no chapter");
        String chapter=chapters.get(0).getAsJsonObject().get("ref").getAsString();JsonObject content=call("chapter",args("sourceId",id,"ref",chapter)).getAsJsonObject();JsonArray images=content.getAsJsonArray("images");if(images.size()==0)throw new IllegalStateException("Original extension returned no page image");
        int maximum=options.has("maximumImages")?options.get("maximumImages").getAsInt():1;if(maximum<1||maximum>8)throw new IllegalArgumentException("Bounded image count must be 1 to 8");
        JsonArray downloaded=new JsonArray();
        for(int i=0;i<Math.min(images.size(),maximum);i++){
            JsonObject value=args("sourceId",id,"url",images.get(i).getAsString(),"chapterRef",chapter);value.addProperty("index",i);
            JsonObject image=call("image",value).getAsJsonObject();byte[] bytes=Base64.getDecoder().decode(image.get("base64").getAsString());
            if(bytes.length==0)throw new IllegalStateException("Original source image body is empty");
            JsonObject entry=new JsonObject();entry.addProperty("bytes",bytes.length);entry.addProperty("mimeType",image.get("mimeType").getAsString());entry.addProperty("sha256",EngineFiles.sha256(bytes));downloaded.add(entry);
        }
        JsonObject report=new JsonObject();report.addProperty("originalApkSha256",apkHash);report.add("conversionProfile",installed.get("conversionProfile"));report.addProperty("sourceId",id);report.addProperty("loadedSourceCount",sources.size());report.addProperty("searchCount",searchCount);report.addProperty("catalogueCount",items.size());report.addProperty("chapters",chapters.size());report.addProperty("pages",images.size());report.add("downloadedImages",downloaded);report.addProperty("javaExecution",System.getProperty("os.name")+" Java8 -Xint original APK");report.addProperty("iosRuntimeVerified",false);
        EngineFiles.write(Paths.get(argv[3]),new GsonBuilder().setPrettyPrinting().create().toJson(report));
        System.out.println("ORIGINAL_APK_READ_PROOF_OK source="+id+" search="+searchCount+" catalogue="+items.size()+" chapters="+chapters.size()+" pages="+images.size()+" images="+downloaded.size());System.exit(0);
    }
}
