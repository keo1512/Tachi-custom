import com.google.gson.*;
import dev.tachibooks.engine.ExtensionHost;
import java.nio.file.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

/** Opt-in original APK registry migration proof; it performs no catalogue/image requests. */
public final class ConversionMigrationProof {
    static JsonObject request(String method,JsonObject args){
        JsonObject value=new JsonObject();value.addProperty("method",method);value.add("args",args);
        return new JsonParser().parse(ExtensionHost.invoke(value.toString())).getAsJsonObject();
    }
    static void require(boolean value,String reason){if(!value)throw new AssertionError(reason);}
    static JsonObject read(Path file)throws Exception{return new JsonParser().parse(new String(Files.readAllBytes(file),StandardCharsets.UTF_8)).getAsJsonObject();}
    public static void main(String[] argv)throws Exception{
        require(System.getProperty("java.specification.version").equals("1.8"),"Java8 verifier required");
        Path root=Paths.get(argv[0]).toAbsolutePath();boolean expectFailure=argv[1].equals("missing-resource");
        JsonObject before=read(root.resolve("registry.json"));Map<Path,byte[]> files=new LinkedHashMap<>();
        try(java.util.stream.Stream<Path> walk=Files.walk(root)){walk.filter(Files::isRegularFile).forEach(path->{try{files.put(path,Files.readAllBytes(path));}catch(Exception e){throw new RuntimeException(e);}});}
        JsonObject initialize=new JsonObject();initialize.addProperty("dataDirectory",root.toString());
        JsonObject started=request("initialize",initialize);require(started.get("ok").getAsBoolean(),"Registry initializes with per-package failures isolated");
        JsonObject after=read(root.resolve("registry.json"));
        if(expectFailure){
            require(before.equals(after),"Failed conversion preserves original registry");
            JsonArray extensions=request("extensions",new JsonObject()).getAsJsonArray("result");
            for(JsonElement extension:extensions){JsonObject e=extension.getAsJsonObject();require(!e.get("installed").getAsBoolean(),"Invalid conversion is not installed");require(e.get("loadError").getAsString().equals("MissingRuntimeResourceException"),"Missing converter resource is classified");}
        }else{
            JsonObject oldEntries=before.getAsJsonObject("packages"),newEntries=after.getAsJsonObject("packages");
            require(oldEntries.keySet().equals(newEntries.keySet()),"Package identities preserved");
            for(Map.Entry<String,JsonElement> entry:oldEntries.entrySet()){
                JsonObject old=entry.getValue().getAsJsonObject().deepCopy(),updated=newEntries.getAsJsonObject(entry.getKey()).deepCopy();
                require(updated.get("conversionProfile").getAsString().endsWith("arrayTemplate-v5"),"Conversion profile advances");
                require(!old.get("jar").equals(updated.get("jar")),"Old broken conversion cache replaced");
                for(String field:Arrays.asList("jar","jarSha256","conversionProfile")){old.remove(field);updated.remove(field);}
                require(old.equals(updated),"Original APK identity/source metadata preserved");
            }
            require(started.getAsJsonObject("result").get("sourceCount").getAsInt()>0,"Migrated original factory loads");
        }
        for(Map.Entry<Path,byte[]> file:files.entrySet()){
            if(!expectFailure&&file.getKey().equals(root.resolve("registry.json")))continue;
            require(Arrays.equals(file.getValue(),Files.readAllBytes(file.getKey())),"Original APK/cache/preference bytes preserved");
        }
        JsonObject missing=new JsonObject();missing.addProperty("sourceId","9223372036854775807");missing.addProperty("mode","popular");
        JsonObject response=request("search",missing);require(!response.get("ok").getAsBoolean(),"Missing source does not execute");
        require(response.getAsJsonObject("error").get("code").getAsString().equals("source_not_installed"),"Missing-source RPC keeps actionable code");
        System.out.println("JAVA8_CONVERSION_MIGRATION_PROOF_OK mode="+argv[1]+" sourceIDs/APK/preferences/originalcache preserved and missing-source classified");
        System.exit(0);
    }
}
