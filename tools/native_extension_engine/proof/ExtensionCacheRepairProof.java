package dev.tachibooks.engine;

import android.content.SharedPreferences;
import com.google.gson.*;
import java.io.*;
import java.lang.reflect.Field;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;

/** Original APK reinstall/cache-corruption proof in an isolated data directory. */
public final class ExtensionCacheRepairProof {
    private static int assertions;
    private static void require(boolean value,String message){assertions++;if(!value)throw new AssertionError(message);}
    private static JsonObject args(String... pairs){JsonObject value=new JsonObject();for(int i=0;i<pairs.length;i+=2)value.addProperty(pairs[i],pairs[i+1]);return value;}
    private static JsonObject rpc(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}
    private static JsonObject metadata(Path root)throws Exception{return new JsonParser().parse(new String(Files.readAllBytes(root.resolve("registry.json")),StandardCharsets.UTF_8)).getAsJsonObject().getAsJsonObject("packages").entrySet().iterator().next().getValue().getAsJsonObject();}
    private static ExtensionRegistry registry()throws Exception{Field field=ExtensionHost.class.getDeclaredField("registry");field.setAccessible(true);return (ExtensionRegistry)field.get(null);}
    private static SharedPreferences preferences(String id)throws Exception{Field field=ExtensionHost.class.getDeclaredField("application");field.setAccessible(true);return ((EngineApplication)field.get(null)).getSharedPreferences("source_"+id,0);}
    private static void rewriteZip(Path input,Path output,boolean badDex)throws Exception{
        try(ZipFile source=new ZipFile(input.toFile());ZipOutputStream target=new ZipOutputStream(Files.newOutputStream(output))){
            Enumeration<? extends ZipEntry> entries=source.entries();byte[] block=new byte[32768];
            while(entries.hasMoreElements()){
                ZipEntry original=entries.nextElement();target.putNextEntry(new ZipEntry(original.getName()));
                if(!original.isDirectory()){
                    if(badDex&&original.getName().endsWith(".dex"))target.write("Invalid DEX fixture".getBytes(StandardCharsets.US_ASCII));
                    else try(InputStream bytes=source.getInputStream(original)){int count;while((count=bytes.read(block))!=-1)target.write(block,0,count);}
                }
                target.closeEntry();
            }
            if(!badDex){target.putNextEntry(new ZipEntry("cache-corruption-fixture.txt"));target.write(new byte[]{1,2,3});target.closeEntry();}
        }
    }
    private static void corruptJar(Path jar,boolean validZip)throws Exception{
        if(!validZip){Files.write(jar,"Truncated converted JAR fixture".getBytes(StandardCharsets.US_ASCII));return;}
        Path changed=jar.resolveSibling("valid-zip-corruption.pending");rewriteZip(jar,changed,false);
        // An active URLClassLoader holds its JAR open on Windows. Simulate disk
        // damage in place rather than requiring an unrelated rename operation.
        Files.write(jar,Files.readAllBytes(changed));Files.delete(changed);
    }
    public static void main(String[] argv)throws Exception{
        try{run(argv);}catch(Throwable failure){failure.printStackTrace();System.exit(1);}
    }
    private static void run(String[] argv)throws Exception{
        require(argv.length==3,"Usage: isolatedDataDirectory originalKomgaAPK malformed|validzip|apk");
        require("1.8".equals(System.getProperty("java.specification.version")),"Use Java8");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Use interpreter");
        Path root=Paths.get(argv[0]).toAbsolutePath(),input=Paths.get(argv[1]).toAbsolutePath();
        String inputHash=EngineFiles.sha256(input);
        require("6f38dd36eebe00beb1b5bc074435855c13e3e214961e109eae7726540b2bb11d".equals(inputHash),"Use the exact original Komga1.4.47 APK");
        require(rpc("initialize",args("dataDirectory",root.toString())).get("ok").getAsBoolean(),"Initialize engine");
        JsonObject install=args("apkPath",input.toString(),"packageHash",inputHash);
        require(rpc("install",install).get("ok").getAsBoolean(),"Original APK initially installs");
        JsonObject before=metadata(root);String id=before.get("id").getAsString(),sourceId=before.getAsJsonArray("sourceIds").get(0).getAsString();
        SharedPreferences preferences=preferences(sourceId);require(preferences.edit().putString("cache-repair-sentinel","retained").commit(),"Persist existing user preference");
        Path damaged=root.resolve("packages").resolve(before.get("jar").getAsString());
        if("apk".equals(argv[2])){damaged=root.resolve("packages").resolve(before.get("apk").getAsString());Files.write(damaged,new byte[]{1,2,3});}
        else{require("malformed".equals(argv[2])||"validzip".equals(argv[2]),"Known corruption case");corruptJar(damaged,"validzip".equals(argv[2]));}
        String damagedHash=EngineFiles.sha256(damaged);
        JsonObject repaired=rpc("install",install);
        require(repaired.get("ok").getAsBoolean(),"Reinstall must repair corrupted "+argv[2]+" package cache");
        JsonObject after=metadata(root);Path activeJar=root.resolve("packages").resolve(after.get("jar").getAsString());
        require(EngineFiles.sha256(activeJar).equals(after.get("jarSha256").getAsString()),"Published JAR bytes match the committed hash");
        try(ZipFile zip=new ZipFile(activeJar.toFile())){require(zip.getEntry("cache-corruption-fixture.txt")==null,"A ZIP-valid changed cache is rebuilt instead of accepted as a new checksum baseline");}
        require(!EngineFiles.sha256(activeJar).equals(damagedHash),"Active artifact no longer uses the damaged cache bytes");
        require(before.get("sourceIds").equals(after.get("sourceIds")),"Reinstall preserves exact String source identities");
        require("retained".equals(preferences.getString("cache-repair-sentinel","")),"Reinstall preserves existing user preferences");
        require(EngineFiles.sha256(root.resolve("packages").resolve(after.get("apk").getAsString())).equals(inputHash),"Retained APK is repaired from verified original input");
        if(!"apk".equals(argv[2])){
            corruptJar(activeJar,"validzip".equals(argv[2]));
            require(rpc("uninstall",args("id",id)).get("ok").getAsBoolean(),"Uninstall succeeds without removing the caller's input");
            require(rpc("install",install).get("ok").getAsBoolean(),"Reinstall after metadata removal also repairs a leftover damaged JAR");
        }
        byte[] registered=Files.readAllBytes(root.resolve("registry.json"));Object source=registry().source(sourceId);
        Path invalid=root.resolve("invalid-dex-input.apk");rewriteZip(input,invalid,true);
        JsonObject rejected=rpc("install",args("apkPath",invalid.toString(),"packageHash",EngineFiles.sha256(invalid)));
        require(!rejected.get("ok").getAsBoolean(),"Conversion failure is reported");
        require(Arrays.equals(registered,Files.readAllBytes(root.resolve("registry.json"))),"Conversion failure preserves exact registered package metadata");
        require(registry().source(sourceId)==source,"Conversion failure preserves the previous live source instance");
        require("retained".equals(preferences.getString("cache-repair-sentinel","")),"Conversion failure preserves user preferences");
        Path saved=root.resolve("registry.retained-test");Files.move(root.resolve("registry.json"),saved);Files.createDirectory(root.resolve("registry.json"));
        try{
            require(!rpc("install",install).get("ok").getAsBoolean(),"Registry write failure is reported after conversion/source validation");
            require(registry().source(sourceId)==source,"Registry write failure preserves the previous source instance");
            require("retained".equals(preferences.getString("cache-repair-sentinel","")),"Registry write failure preserves user preferences");
        }finally{Files.delete(root.resolve("registry.json"));Files.move(saved,root.resolve("registry.json"));}
        require(Arrays.equals(registered,Files.readAllBytes(root.resolve("registry.json"))),"Registry write failure preserves the previous durable metadata");
        require(inputHash.equals(EngineFiles.sha256(input)),"Original APK input remains byte-identical");
        System.out.println("EXTENSION_CACHE_REPAIR_OK mode="+argv[2]+" assertions="+assertions+" original-apk immutable-cache user-preferences conversion-failure registry-write-failure");System.exit(0);
    }
}
