package dev.tachibooks.engine;

import android.app.Application;
import android.content.Context;
import android.content.SharedPreferences;
import java.io.File;
import java.nio.file.Path;
import java.util.*;

final class EngineApplication extends Application {
    private final Path root;
    private final Map<String,SharedPreferences> preferences=new HashMap<>();
    EngineApplication(Path root){this.root=root;}
    public Context getApplicationContext(){return this;}
    public String getPackageName(){return "dev.tachibooks.tachiBooks";}
    public File getFilesDir(){return root.toFile();}
    public File getCacheDir(){File file=root.resolve("cache").toFile();file.mkdirs();return file;}
    public synchronized SharedPreferences getSharedPreferences(String name,int mode){
        if(!name.matches("[A-Za-z0-9_.-]{1,200}"))throw new IllegalArgumentException("Invalid preference namespace");
        SharedPreferences value=preferences.get(name);
        if(value==null){try{value=new EnginePreferences(root.resolve("preferences").resolve(name+".json"));}catch(Exception e){throw new IllegalStateException("Preference load failed",e);}preferences.put(name,value);}
        return value;
    }
}
