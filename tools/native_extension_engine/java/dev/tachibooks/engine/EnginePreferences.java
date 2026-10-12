package dev.tachibooks.engine;

import android.content.SharedPreferences;
import com.google.gson.*;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;

final class EnginePreferences implements SharedPreferences {
    private final Path file;
    private JsonObject values;
    private final Set<OnSharedPreferenceChangeListener> listeners = new HashSet<>();
    EnginePreferences(Path file) throws IOException {
        this.file = file;
        values = Files.exists(file) ? new JsonParser().parse(new String(Files.readAllBytes(file), StandardCharsets.UTF_8)).getAsJsonObject() : new JsonObject();
    }
    public synchronized Map<String, ?> getAll() {
        Map<String,Object> result = new HashMap<>();
        for (Map.Entry<String,JsonElement> value : values.entrySet()) result.put(value.getKey(), decoded(value.getValue()));
        return result;
    }
    private Object decoded(JsonElement value) {
        JsonObject item=value.getAsJsonObject(); String type=item.get("type").getAsString(); JsonElement raw=item.get("value");
        if (type.equals("String")) return raw.getAsString();
        if (type.equals("Integer")) return raw.getAsInt();
        if (type.equals("Long")) return raw.getAsLong();
        if (type.equals("Float")) return raw.getAsFloat();
        if (type.equals("Boolean")) return raw.getAsBoolean();
        if (type.equals("Set")) { Set<String> set=new HashSet<>(); for(JsonElement e:raw.getAsJsonArray())set.add(e.getAsString()); return set; }
        throw new IllegalStateException("Unsupported stored preference type");
    }
    private Object value(String key, Object fallback) { return values.has(key)?decoded(values.get(key)):fallback; }
    public synchronized String getString(String key,String fallback){return (String)value(key,fallback);}
    @SuppressWarnings("unchecked") public synchronized Set<String> getStringSet(String key,Set<String> fallback){Object v=value(key,fallback);return v==null?null:new HashSet<>((Set<String>)v);}
    public synchronized int getInt(String key,int fallback){return (Integer)value(key,fallback);}
    public synchronized long getLong(String key,long fallback){return (Long)value(key,fallback);}
    public synchronized float getFloat(String key,float fallback){return (Float)value(key,fallback);}
    public synchronized boolean getBoolean(String key,boolean fallback){return (Boolean)value(key,fallback);}
    public synchronized boolean contains(String key){return values.has(key);}
    public synchronized void registerOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l){listeners.add(l);}
    public synchronized void unregisterOnSharedPreferenceChangeListener(OnSharedPreferenceChangeListener l){listeners.remove(l);}
    public Editor edit(){return new Pending();}
    private final class Pending implements Editor {
        private final Map<String,Object> pending=new LinkedHashMap<>(); private boolean clear;
        private Editor put(String k,Object v){pending.put(k,v);return this;}
        public Editor putString(String k,String v){return put(k,v);}
        public Editor putStringSet(String k,Set<String> v){return put(k,v==null?null:new HashSet<>(v));}
        public Editor putInt(String k,int v){return put(k,v);}
        public Editor putLong(String k,long v){return put(k,v);}
        public Editor putFloat(String k,float v){return put(k,v);}
        public Editor putBoolean(String k,boolean v){return put(k,v);}
        public Editor remove(String k){return put(k,null);}
        public Editor clear(){clear=true;return this;}
        public boolean commit(){
            Set<String> changed=new HashSet<>(); OnSharedPreferenceChangeListener[] notify;
            synchronized(EnginePreferences.this){
                JsonObject next=clear?new JsonObject():new JsonParser().parse(values.toString()).getAsJsonObject();
                if(clear)changed.addAll(values.keySet());
                for(Map.Entry<String,Object> entry:pending.entrySet()){
                    changed.add(entry.getKey()); Object v=entry.getValue();
                    if(v==null){next.remove(entry.getKey());continue;}
                    JsonObject item=new JsonObject();item.addProperty("type",v instanceof Set?"Set":v.getClass().getSimpleName());item.add("value",EngineFiles.JSON.toJsonTree(v));next.add(entry.getKey(),item);
                }
                try{EngineFiles.write(file,next.toString());}catch(IOException failure){return false;}
                values=next;notify=listeners.toArray(new OnSharedPreferenceChangeListener[0]);
            }
            for(String key:changed)for(OnSharedPreferenceChangeListener listener:notify)listener.onSharedPreferenceChanged(EnginePreferences.this,key);
            return true;
        }
        public void apply(){if(!commit())throw new IllegalStateException("Preference persistence failed");}
    }
}
