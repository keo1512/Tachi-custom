package android.graphics;

import dev.tachibooks.engine.ImageCodec;
import java.io.*;
import java.util.Arrays;

public class BitmapFactory {
    public static class Options{public boolean inJustDecodeBounds,inMutable;public int inSampleSize=1,outWidth,outHeight;public String outMimeType;public Bitmap.Config inPreferredConfig=Bitmap.Config.ARGB_8888;}
    public static Bitmap decodeStream(InputStream input){return decodeStream(input,null,null);}
    public static Bitmap decodeStream(InputStream input,Rect padding,Options options){
        if(input==null)return null;
        try{ByteArrayOutputStream output=new ByteArrayOutputStream();byte[] block=new byte[16384];int count;while((count=input.read(block))!=-1){if(output.size()+(long)count>8*1024*1024)return null;output.write(block,0,count);}return decodeByteArray(output.toByteArray(),0,output.size(),options);}catch(IOException invalid){return null;}
    }
    public static Bitmap decodeByteArray(byte[] bytes,int offset,int length){return decodeByteArray(bytes,offset,length,null);}
    public static Bitmap decodeByteArray(byte[] bytes,int offset,int length,Options options){
        if(offset<0||length<0||offset+(long)length>bytes.length)throw new ArrayIndexOutOfBoundsException();
        try{Bitmap result=Bitmap.decoded(ImageCodec.decode(offset==0&&length==bytes.length?bytes:Arrays.copyOfRange(bytes,offset,offset+length)));
            if(result==null)return null;
            if(options!=null){options.outWidth=result.getWidth();options.outHeight=result.getHeight();if(options.inJustDecodeBounds){result.recycle();return null;}if(options.inSampleSize>1){int factor=options.inSampleSize;Bitmap scaled=Bitmap.createBitmap(Math.max(1,result.getWidth()/factor),Math.max(1,result.getHeight()/factor),Bitmap.Config.ARGB_8888);new Canvas(scaled).drawBitmap(result,null,new Rect(0,0,scaled.getWidth(),scaled.getHeight()),null);result.recycle();result=scaled;}}
            return result;
        }catch(IOException invalid){return null;}
    }
}
