package dev.tachibooks.engine;

import android.content.SharedPreferences;
import androidx.preference.*;
import com.google.gson.*;
import eu.kanade.tachiyomi.source.ConfigurableSource;
import eu.kanade.tachiyomi.source.online.HttpSource;
import java.lang.reflect.Field;
import java.nio.file.*;
import java.util.zip.*;

/** Constructor-failure fixture on the actual registry and preference RPC. No HTTP. */
public final class PreferenceReloadProof {
    private static int assertions;
    private static final String ID="741234567891234567";
    private static EngineApplication application() {
        try{Field field=ExtensionHost.class.getDeclaredField("application");field.setAccessible(true);return (EngineApplication)field.get(null);}
        catch(Exception failure){throw new IllegalStateException(failure);}
    }
    public static final class Source extends HttpSource implements ConfigurableSource {
        public Source(){if(application().getSharedPreferences("source_"+ID,0).getBoolean("break-on-reload",false))throw new IllegalStateException("Fixture constructor refuses new preferences");}
        public long getId(){return Long.parseLong(ID);}
        public String getName(){return "Reload fixture";}
        public String getLang(){return "vi";}
        public String getBaseUrl(){return "https://fixture.invalid";}
        public boolean getSupportsLatest(){return false;}
        public void setupPreferenceScreen(PreferenceScreen screen){
            Preference preference=new Preference(application());preference.setKey("break-on-reload");
            preference.setTitle("Break constructor");preference.setDefaultValue(Boolean.FALSE);screen.addPreference(preference);
        }
    }
    private static void require(boolean valid,String message){assertions++;if(!valid)throw new AssertionError(message);}
    private static JsonObject args(String... values){JsonObject args=new JsonObject();for(int i=0;i<values.length;i+=2)args.addProperty(values[i],values[i+1]);return args;}
    private static JsonObject rpc(String method,JsonObject args){JsonObject request=new JsonObject();request.addProperty("method",method);request.add("args",args);return new JsonParser().parse(ExtensionHost.invoke(request.toString())).getAsJsonObject();}
    private static Path archive(Path root,String suffix)throws Exception{
        Path temporary=root.resolve("fixture"+suffix);
        try(ZipOutputStream zip=new ZipOutputStream(Files.newOutputStream(temporary))){zip.putNextEntry(new ZipEntry("fixture.txt"));zip.write(new byte[]{1,2,3});zip.closeEntry();}
        return Files.move(temporary,root.resolve(EngineFiles.sha256(temporary)+suffix));
    }
    public static void main(String[] argv)throws Exception{
        try{run(argv);}catch(Throwable failure){failure.printStackTrace();System.exit(1);}
    }
    private static void run(String[] argv)throws Exception{
        Path root=Paths.get(argv[0]).toAbsolutePath();
        require(rpc("initialize",args("dataDirectory",root.toString())).get("ok").getAsBoolean(),"Engine initializes");
        Path apk=archive(root.resolve("packages"),".apk"),jar=archive(root.resolve("packages"),".jar");
        JsonObject metadata=args("id","eu.kanade.tachiyomi.extension.fixture.reload","apk",apk.getFileName().toString(),"jar",jar.getFileName().toString(),
            "apkSha256",EngineFiles.sha256(apk),"jarSha256",EngineFiles.sha256(jar),
            "conversionProfile","dex2jar-2.4.38-constructorsCFG-originalNames-computeFrames-arrayTemplate-v5");
        JsonArray classes=new JsonArray();classes.add(Source.class.getName());metadata.add("classes",classes);
        JsonArray ids=new JsonArray();ids.add(ID);metadata.add("sourceIds",ids);
        JsonObject entries=new JsonObject();entries.add(metadata.get("id").getAsString(),metadata);
        Field field=ExtensionHost.class.getDeclaredField("registry");field.setAccessible(true);ExtensionRegistry registry=(ExtensionRegistry)field.get(null);
        field=ExtensionRegistry.class.getDeclaredField("entries");field.setAccessible(true);field.set(registry,entries);registry.reload();
        require(registry.source(ID)!=null,"Fixture source initially loads");
        SharedPreferences prefs=application().getSharedPreferences("source_"+ID,0);
        require(prefs.edit().putString("unrelated","retained").putBoolean("break-on-reload",false).commit(),"Original source preferences persist");
        JsonObject request=args("sourceId",ID,"key","break-on-reload");request.addProperty("value",true);
        JsonObject response=rpc("setPreference",request);
        require(!response.get("ok").getAsBoolean(),"Constructor failure must not report successful preference update");
        require(!prefs.getBoolean("break-on-reload",true),"Previous usable preference is restored");
        require("retained".equals(prefs.getString("unrelated","")),"Other preference values survive rollback");
        require(registry.source(ID)!=null,"Source remains available for repair after a rejected update");
        request.addProperty("value",false);
        require(rpc("setPreference",request).get("ok").getAsBoolean(),"A valid follow-up preference can still apply");
        System.out.println("PREFERENCE_RELOAD_ROLLBACK_OK assertions="+assertions);System.exit(0);
    }
}
