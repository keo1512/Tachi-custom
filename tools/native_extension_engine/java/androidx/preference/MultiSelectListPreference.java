package androidx.preference;

/* Copyright (C) Contributors to the Suwayomi project.
 * This Source Code Form is subject to the terms of the Mozilla Public License,
 * v. 2.0. https://mozilla.org/MPL/2.0/.
 * The upstream stub's metadata contract is retained; selected values and index
 * lookup are implemented for source-driven asynchronous preference updates. */

import android.content.Context;
import java.util.LinkedHashSet;
import java.util.Set;

public class MultiSelectListPreference extends DialogPreference {
    private CharSequence[] entries,entryValues;
    private Set<String> values;
    public MultiSelectListPreference(Context context){super(context);}
    public void setEntries(CharSequence[] value){entries=value;}
    public CharSequence[] getEntries(){return entries;}
    public void setEntryValues(CharSequence[] value){entryValues=value;}
    public CharSequence[] getEntryValues(){return entryValues;}
    public synchronized void setValues(Set<String> value){
        values=new LinkedHashSet<>(value);
        if(getSharedPreferences()!=null&&getKey()!=null)saveNewValue(values);
    }
    @SuppressWarnings("unchecked") public synchronized Set<String> getValues(){
        if(getSharedPreferences()!=null&&getKey()!=null){Object value=getCurrentValue();return value==null?new LinkedHashSet<String>():new LinkedHashSet<>((Set<String>)value);}
        return values==null?new LinkedHashSet<String>():new LinkedHashSet<>(values);
    }
    public int findIndexOfValue(String value){if(value==null||entryValues==null)return -1;for(int i=entryValues.length-1;i>=0;i--)if(value.contentEquals(entryValues[i]))return i;return -1;}
    public String getDefaultValueType(){return "Set<String>";}
}
