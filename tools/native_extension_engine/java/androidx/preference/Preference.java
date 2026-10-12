package androidx.preference;

/*
 * Copyright (C) Contributors to the Suwayomi project
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 *
 * Java 8 port of the minimal Suwayomi Preference implementation. Android
 * view creation is separate from these metadata, listener and storage APIs.
 */

import android.content.Context;
import android.content.SharedPreferences;
import com.fasterxml.jackson.annotation.JsonIgnore;
import java.util.HashSet;
import java.util.Set;

public class Preference {
    @JsonIgnore protected Context context;
    private boolean visible=true,enabled=true;
    private String key;
    private CharSequence title,summary;
    private Object defaultValue;
    @JsonIgnore private SharedPreferences sharedPreferences;
    @JsonIgnore public OnPreferenceChangeListener onChangeListener;
    @JsonIgnore private OnPreferenceClickListener onClickListener;
    public Preference(Context context){this.context=context;}
    public Context getContext(){return context;}
    public void setOnPreferenceChangeListener(OnPreferenceChangeListener listener){onChangeListener=listener;}
    public void setOnPreferenceClickListener(OnPreferenceClickListener listener){onClickListener=listener;}
    public CharSequence getTitle(){return title;}
    public void setTitle(CharSequence value){title=value;}
    public CharSequence getSummary(){return summary;}
    public void setSummary(CharSequence value){summary=value;}
    public void setEnabled(boolean value){enabled=value;}
    public boolean isEnabled(){return enabled;}
    public String getKey(){return key;}
    public void setKey(String value){key=value;}
    public void setDefaultValue(Object value){defaultValue=value;}
    public boolean callChangeListener(Object value){return onChangeListener==null||onChangeListener.onPreferenceChange(this,value);}
    public Object getDefaultValue(){return defaultValue;}
    public String getDefaultValueType(){return defaultValue==null?"String":defaultValue instanceof Set?"Set<String>":defaultValue.getClass().getSimpleName();}
    public SharedPreferences getSharedPreferences(){return sharedPreferences;}
    public void setSharedPreferences(SharedPreferences value){sharedPreferences=value;}
    public void setVisible(boolean value){visible=value;}
    public boolean getVisible(){return visible;}
    public boolean hasClickListener(){return onClickListener!=null;}
    public boolean callClickListener(){return onClickListener!=null&&onClickListener.onPreferenceClick(this);}
    public interface OnPreferenceChangeListener{boolean onPreferenceChange(Preference preference,Object newValue);}
    public interface OnPreferenceClickListener{boolean onPreferenceClick(Preference preference);}
    @SuppressWarnings("unchecked") public Object getCurrentValue(){
        String type=getDefaultValueType();
        if(key==null||sharedPreferences==null){
            if(defaultValue!=null)return defaultValue;
            if("Boolean".equals(type))return false;
            if("Set<String>".equals(type))return new HashSet<String>();
            if("Integer".equals(type))return 0;
            if("Long".equals(type))return 0L;
            if("Float".equals(type))return 0f;
            return "";
        }
        switch(type){
            case "String":return sharedPreferences.getString(key,(String)defaultValue);
            case "Boolean":return sharedPreferences.getBoolean(key,defaultValue==null?false:(Boolean)defaultValue);
            case "Set<String>":return sharedPreferences.getStringSet(key,(Set<String>)defaultValue);
            case "Integer":return sharedPreferences.getInt(key,defaultValue==null?0:(Integer)defaultValue);
            case "Long":return sharedPreferences.getLong(key,defaultValue==null?0L:(Long)defaultValue);
            case "Float":return sharedPreferences.getFloat(key,defaultValue==null?0f:(Float)defaultValue);
            default:throw new IllegalArgumentException("Unsupported preference type: "+type);
        }
    }
    @SuppressWarnings("unchecked") public void saveNewValue(Object value){
        if(key==null)return;
        if(sharedPreferences==null)throw new IllegalStateException("Preference storage was not assigned");
        SharedPreferences.Editor editor=sharedPreferences.edit();
        switch(getDefaultValueType()){
            case "String":editor.putString(key,(String)value);break;
            case "Boolean":editor.putBoolean(key,(Boolean)value);break;
            case "Set<String>":editor.putStringSet(key,(Set<String>)value);break;
            case "Integer":editor.putInt(key,(Integer)value);break;
            case "Long":editor.putLong(key,(Long)value);break;
            case "Float":editor.putFloat(key,(Float)value);break;
            default:throw new IllegalArgumentException("Unsupported preference type");
        }
        editor.apply();
    }
}
