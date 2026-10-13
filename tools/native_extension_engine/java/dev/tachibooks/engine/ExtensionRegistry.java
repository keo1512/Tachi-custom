package dev.tachibooks.engine;

import com.google.gson.*;
import com.googlecode.d2j.dex.Dex2jar;
import eu.kanade.tachiyomi.source.*;
import java.io.*;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import javax.xml.parsers.DocumentBuilderFactory;
import net.dongliu.apk.parser.ApkFile;
import net.dongliu.apk.parser.bean.ApkMeta;
import org.w3c.dom.*;
import org.xml.sax.InputSource;

/** Own installation catalogue. APK source code is loaded only after conversion and factory validation. */
final class ExtensionRegistry {
    private static final String ANDROID="http://schemas.android.com/apk/res/android";
    private static final String CONVERSION_PROFILE="dex2jar-2.4.38-constructorsCFG-originalNames-computeFrames-arrayTemplate-v5";
    private final Path root;
    private JsonObject entries=new JsonObject();
    private final Map<String,CatalogueSource> sources=new LinkedHashMap<>();
    private final Map<String,URLClassLoader> loaders=new HashMap<>();
    private final Map<String,String> failures=new HashMap<>();
    ExtensionRegistry(Path root) throws Exception {
        this.root=root;Files.createDirectories(root.resolve("packages"));
        Path file=root.resolve("registry.json");
        if(Files.exists(file)){
            JsonObject document=new JsonParser().parse(new String(Files.readAllBytes(file),StandardCharsets.UTF_8)).getAsJsonObject();
            if(document.get("version").getAsInt()!=1)throw new IOException("Unsupported extension registry version");
            entries=document.getAsJsonObject("packages");
            if(entries==null)throw new IOException("Invalid extension registry");
        }
        reload();
    }
    synchronized void reload(){
        // Some original sources start asynchronous work in their constructor. Dropping our
        // references permits normal JVM collection; closing a live loader would break that work.
        sources.clear();loaders.clear();failures.clear();
        for(Map.Entry<String,JsonElement> item:entries.entrySet()){
            try{
                JsonObject original=item.getValue().getAsJsonObject(),metadata=migrateConversion(original);
                Loaded loaded=load(metadata);
                if(metadata!=original){
                    JsonObject next=entries.deepCopy();next.add(item.getKey(),metadata);
                    try{persist(next);}catch(Exception failure){loaded.loader.close();throw failure;}
                    entries=next;
                }
                adopt(item.getKey(),loaded);
            }
            catch(Throwable failure){failures.put(item.getKey(),failure.getClass().getSimpleName());}
        }
    }
    CatalogueSource source(String id){CatalogueSource result=sources.get(id);if(result==null)throw new SourceNotLoadedException();return result;}
    Collection<CatalogueSource> sources(){return new ArrayList<>(sources.values());}
    String iconUrl(String sourceId){for(Map.Entry<String,JsonElement> entry:entries.entrySet()){JsonObject item=entry.getValue().getAsJsonObject();if(item.has("sourceIds"))for(JsonElement id:item.getAsJsonArray("sourceIds"))if(sourceId.equals(id.getAsString()))return item.has("iconUrl")?item.get("iconUrl").getAsString():"";}return "";}
    synchronized JsonArray extensions(){
        JsonArray result=new JsonArray();
        for(Map.Entry<String,JsonElement> item:entries.entrySet()){
            JsonObject value=item.getValue().getAsJsonObject().deepCopy();
            value.remove("classes");value.remove("jar");value.remove("apk");
            value.addProperty("installed",loaders.containsKey(item.getKey()));
            if(failures.containsKey(item.getKey()))value.addProperty("loadError",failures.get(item.getKey()));
            result.add(value);
        }
        return result;
    }
    synchronized JsonObject install(Path input,String packageUrl,String iconUrl,String expectedHash) throws Exception {
        if(!Files.isRegularFile(input)||Files.size(input)==0||Files.size(input)>32L*1024*1024)throw new IllegalArgumentException("APK size is invalid");
        validateArchive(input);
        JsonObject metadata=metadata(input);
        String id=metadata.get("id").getAsString(),digest=EngineFiles.sha256(input);
        if(!expectedHash.isEmpty()&&(!expectedHash.matches("(?i)[a-f0-9]{64}")||!expectedHash.equalsIgnoreCase(digest)))throw new IllegalArgumentException("Downloaded APK checksum does not match the catalogue");
        String convertedName=EngineFiles.sha256((digest+CONVERSION_PROFILE).getBytes(StandardCharsets.US_ASCII));
        Path directory=root.resolve("packages"),apk=directory.resolve(digest+".apk"),jar=directory.resolve(convertedName+".jar");
        if(!Files.exists(apk)){
            Path pending=Files.createTempFile(directory,".pending-",".apk");
            try{Files.copy(input,pending,StandardCopyOption.REPLACE_EXISTING);if(!EngineFiles.sha256(pending).equals(digest))throw new IOException("APK changed during installation");Files.move(pending,apk,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(pending);}
        }
        if(!Files.exists(jar)){
            convert(apk,jar);
        }
        metadata.addProperty("apk",apk.getFileName().toString());metadata.addProperty("jar",jar.getFileName().toString());
        metadata.addProperty("apkSha256",digest);metadata.addProperty("jarSha256",EngineFiles.sha256(jar));
        metadata.addProperty("conversionProfile",CONVERSION_PROFILE);
        metadata.addProperty("packageUrl",packageUrl);metadata.addProperty("iconUrl",iconUrl);
        Loaded loaded=load(metadata);
        Set<String> oldIds=new HashSet<>();
        if(entries.has(id))for(JsonElement oldId:entries.getAsJsonObject(id).getAsJsonArray("sourceIds"))oldIds.add(oldId.getAsString());
        for(CatalogueSource source:loaded.sources)if(sources.containsKey(Long.toString(source.getId()))&&!oldIds.contains(Long.toString(source.getId()))){loaded.loader.close();throw new IllegalArgumentException("Source identity collides with another installed package");}
        JsonArray ids=new JsonArray();for(CatalogueSource source:loaded.sources)ids.add(Long.toString(source.getId()));metadata.add("sourceIds",ids);
        JsonObject next=entries.deepCopy();next.add(id,metadata);persist(next);
        loaders.remove(id);for(String sourceId:oldIds)sources.remove(sourceId);
        entries=next;failures.remove(id);adopt(id,loaded);
        JsonObject result=metadata.deepCopy();result.remove("classes");result.remove("jar");result.remove("apk");result.addProperty("installed",true);return result;
    }
    /** Checks the original archive and Android manifest without changing the registry. */
    synchronized JsonObject inspect(Path input) throws Exception {
        if(!Files.isRegularFile(input)||Files.size(input)==0||Files.size(input)>32L*1024*1024)throw new IllegalArgumentException("APK size is invalid");
        validateArchive(input);JsonObject result=metadata(input);
        result.remove("classes");result.addProperty("apkSha256",EngineFiles.sha256(input));
        return result;
    }
    synchronized boolean uninstall(String id)throws Exception{
        if(!entries.has(id))return false;
        JsonObject next=entries.deepCopy();JsonObject removed=next.remove(id).getAsJsonObject();persist(next);entries=next;
        for(JsonElement sourceId:removed.getAsJsonArray("sourceIds"))sources.remove(sourceId.getAsString());
        loaders.remove(id);failures.remove(id);return true;
    }
    private void persist(JsonObject next)throws IOException{JsonObject document=new JsonObject();document.addProperty("version",1);document.add("packages",next);EngineFiles.write(root.resolve("registry.json"),EngineFiles.JSON.toJson(document));}
    private void adopt(String id,Loaded loaded){
        for(CatalogueSource source:loaded.sources)if(sources.containsKey(Long.toString(source.getId())))throw new IllegalArgumentException("Duplicate source identity");
        loaders.put(id,loaded.loader);for(CatalogueSource source:loaded.sources)sources.put(Long.toString(source.getId()),source);
    }
    private JsonObject migrateConversion(JsonObject original)throws Exception{
        if(original.has("conversionProfile")&&CONVERSION_PROFILE.equals(original.get("conversionProfile").getAsString()))return original;
        String apkName=original.get("apk").getAsString(),oldJarName=original.get("jar").getAsString();
        if(!apkName.matches("[a-f0-9]{64}\\.apk")||!oldJarName.matches("[a-f0-9]{64}\\.jar"))throw new IOException("Invalid installed package filename");
        Path apk=root.resolve("packages").resolve(apkName),oldJar=root.resolve("packages").resolve(oldJarName);
        if(!Files.isRegularFile(apk)||!EngineFiles.sha256(apk).equals(original.get("apkSha256").getAsString())||
            !Files.isRegularFile(oldJar)||!EngineFiles.sha256(oldJar).equals(original.get("jarSha256").getAsString()))throw new IOException("Installed package checksum mismatch");
        validateArchive(apk);
        String name=EngineFiles.sha256((original.get("apkSha256").getAsString()+CONVERSION_PROFILE).getBytes(StandardCharsets.US_ASCII));
        Path jar=root.resolve("packages").resolve(name+".jar");
        convert(apk,jar);
        JsonObject next=original.deepCopy();next.addProperty("jar",jar.getFileName().toString());next.addProperty("jarSha256",EngineFiles.sha256(jar));next.addProperty("conversionProfile",CONVERSION_PROFILE);
        return next;
    }
    private static void convert(Path apk,Path jar)throws Exception{
        Path pending=Files.createTempFile(jar.getParent(),".pending-",".jar");
        try{Files.delete(pending);Dex2jar converter=Dex2jar.from(apk.toFile());Dex2jar.from(DexCompatibility.prepare(converter.getReader())).skipDebug().dontSanitizeNames(true).computeFrames(true).to(pending);validateArchive(pending);Files.move(pending,jar,StandardCopyOption.ATOMIC_MOVE,StandardCopyOption.REPLACE_EXISTING);}finally{Files.deleteIfExists(pending);}
    }
    private Loaded load(JsonObject metadata)throws Exception{
        String name=metadata.get("jar").getAsString();if(!name.matches("[a-f0-9]{64}\\.jar"))throw new IOException("Invalid package filename");
        Path jar=root.resolve("packages").resolve(name);
        if(!Files.isRegularFile(jar)||!EngineFiles.sha256(jar).equals(metadata.get("jarSha256").getAsString()))throw new IOException("Installed package checksum mismatch");
        String apkName=metadata.get("apk").getAsString();
        if(!apkName.matches("[a-f0-9]{64}\\.apk"))throw new IOException("Invalid original package filename");
        Path apk=root.resolve("packages").resolve(apkName);
        if(!Files.isRegularFile(apk)||!EngineFiles.sha256(apk).equals(metadata.get("apkSha256").getAsString()))throw new IOException("Original package checksum mismatch");
        // DEX conversion emits classes. Original packaged assets remain available through
        // the same loader, including properties read by the extension's own i18n code.
        URLClassLoader loader=new URLClassLoader(new java.net.URL[]{jar.toUri().toURL(),apk.toUri().toURL()},ExtensionHost.class.getClassLoader());
        List<CatalogueSource> result=new ArrayList<>();Set<String> ids=new HashSet<>();
        try{
            for(JsonElement className:metadata.getAsJsonArray("classes")){
                Object instance=Class.forName(className.getAsString(),true,loader).getDeclaredConstructor().newInstance();
                List<Source> found;
                if(instance instanceof SourceFactory)found=((SourceFactory)instance).createSources();
                else if(instance instanceof Source)found=Collections.singletonList((Source)instance);
                else throw new IllegalArgumentException("Extension entry is not a source or factory");
                for(Source source:found){if(!(source instanceof CatalogueSource))throw new IllegalArgumentException("Unsupported source interface");if(!ids.add(Long.toString(source.getId())))throw new IllegalArgumentException("Duplicate source identity in extension");result.add((CatalogueSource)source);}
            }
            if(result.isEmpty()||result.size()>2048)throw new IllegalArgumentException("Extension returned an invalid source count");
            return new Loaded(loader,result);
        }catch(Throwable failure){loader.close();throw failure;}
    }
    private static JsonObject metadata(Path file)throws Exception{
        try(ApkFile parser=new ApkFile(file.toFile())){
            ApkMeta meta=parser.getApkMeta();String id=meta.getPackageName();
            if(id==null||!id.matches("eu\\.kanade\\.tachiyomi\\.extension\\.[A-Za-z0-9_.]+"))throw new IllegalArgumentException("APK is not a Tachiyomi extension package");
            DocumentBuilderFactory factory=DocumentBuilderFactory.newInstance();factory.setNamespaceAware(true);
            factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);factory.setFeature("http://xml.org/sax/features/external-general-entities",false);factory.setFeature("http://xml.org/sax/features/external-parameter-entities",false);factory.setXIncludeAware(false);factory.setExpandEntityReferences(false);
            Document document=factory.newDocumentBuilder().parse(new InputSource(new StringReader(parser.getManifestXml())));
            boolean extension=false;NodeList features=document.getElementsByTagName("uses-feature");
            for(int i=0;i<features.getLength();i++)if("tachiyomi.extension".equals(((Element)features.item(i)).getAttributeNS(ANDROID,"name")))extension=true;
            if(!extension)throw new IllegalArgumentException("APK extension feature declaration is missing");
            JsonArray classes=new JsonArray();NodeList metadata=document.getElementsByTagName("meta-data");
            for(int i=0;i<metadata.getLength();i++){
                Element element=(Element)metadata.item(i);
                if("tachiyomi.extension.class".equals(element.getAttributeNS(ANDROID,"name"))){
                    for(String value:element.getAttributeNS(ANDROID,"value").split(";")){
                        String fqn=value.startsWith(".")?id+value:value;
                        if(!fqn.matches("[A-Za-z_$][A-Za-z0-9_$.]{1,250}"))throw new IllegalArgumentException("Invalid extension class");classes.add(fqn);
                    }
                }
            }
            if(classes.size()==0||classes.size()>128)throw new IllegalArgumentException("Extension entry classes are missing");
            JsonObject result=new JsonObject();result.addProperty("id",id);result.addProperty("pkgName",id);result.addProperty("name",meta.getLabel());result.addProperty("version",meta.getVersionName());result.addProperty("versionCode",meta.getVersionCode());result.add("classes",classes);return result;
        }
    }
    private static void validateArchive(Path file)throws IOException{
        try(ZipFile zip=new ZipFile(file.toFile())){
            Set<String> names=new HashSet<>();Enumeration<? extends ZipEntry> entries=zip.entries();long total=0;int count=0;
            while(entries.hasMoreElements()){
                ZipEntry entry=entries.nextElement();String name=entry.getName();
                if(!names.add(name)||name.startsWith("/")||name.contains("\\")||Arrays.asList(name.split("/")).contains(".."))throw new IOException("Invalid package ZIP entry");
                if(++count>100000||entry.getSize()<0||(total+=entry.getSize())>128L*1024*1024)throw new IOException("Extension archive exceeds limits");
                try(InputStream input=zip.getInputStream(entry)){byte[] block=new byte[32768];CRC32 crc=new CRC32();long actual=0;int read;while((read=input.read(block))!=-1){actual+=read;if(actual>entry.getSize())throw new IOException("Package size mismatch");crc.update(block,0,read);}if(actual!=entry.getSize()||crc.getValue()!=entry.getCrc())throw new IOException("Extension CRC mismatch");}
            }
        }
    }
    private static final class Loaded{final URLClassLoader loader;final List<CatalogueSource> sources;Loaded(URLClassLoader loader,List<CatalogueSource> sources){this.loader=loader;this.sources=sources;}}
}
