package dev.tachibooks.engine;

import java.io.*;
import java.lang.reflect.*;

/** ImageIO on iOS; reflective desktop fallback is only for host verification. */
public final class ImageCodec {
    public static final int MAX_PIXELS=8*1024*1024;
    private ImageCodec(){}
    private static native int[] decodeNative(byte[] bytes);
    private static native byte[] encodeNative(int[] argb,int width,int height,String format,int quality);
    public static int[] decode(byte[] bytes)throws IOException{
        if(bytes==null||bytes.length==0||bytes.length>8*1024*1024)throw new IOException("Invalid image byte count");
        try{return decodeNative(bytes);}catch(UnsatisfiedLinkError desktop){return desktopDecode(bytes);}
    }
    public static byte[] encode(int[] argb,int width,int height,String format,int quality)throws IOException{
        if(argb==null||width<1||height<1||(long)width*height>MAX_PIXELS||argb.length<(long)width*height||quality<0||quality>100)throw new IOException("Invalid bitmap dimensions or quality");
        try{return encodeNative(argb,width,height,format,quality);}catch(UnsatisfiedLinkError desktop){return desktopEncode(argb,width,height,format);}
    }
    private static int[] desktopDecode(byte[] bytes)throws IOException{
        try{
            Class<?> io=Class.forName("javax.imageio.ImageIO");
            Object image=io.getMethod("read",InputStream.class).invoke(null,new ByteArrayInputStream(bytes));
            if(image==null)return null;
            Class<?> type=image.getClass();int width=(Integer)type.getMethod("getWidth").invoke(image),height=(Integer)type.getMethod("getHeight").invoke(image);
            if(width<1||height<1||(long)width*height>MAX_PIXELS)throw new IOException("Image dimensions exceed limit");
            int[] output=new int[2+width*height];output[0]=width;output[1]=height;
            type.getMethod("getRGB",int.class,int.class,int.class,int.class,int[].class,int.class,int.class).invoke(image,0,0,width,height,output,2,width);return output;
        }catch(ReflectiveOperationException failure){throw new IOException("Image decoder is unavailable",failure);}
    }
    private static byte[] desktopEncode(int[] pixels,int width,int height,String format)throws IOException{
        try{
            Class<?> type=Class.forName("java.awt.image.BufferedImage");
            Object image=type.getConstructor(int.class,int.class,int.class).newInstance(width,height,"jpeg".equals(format)?1:2);
            type.getMethod("setRGB",int.class,int.class,int.class,int.class,int[].class,int.class,int.class).invoke(image,0,0,width,height,pixels,0,width);
            ByteArrayOutputStream output=new ByteArrayOutputStream();
            boolean success=(Boolean)Class.forName("javax.imageio.ImageIO").getMethod("write",Class.forName("java.awt.image.RenderedImage"),String.class,OutputStream.class).invoke(null,image,format,output);
            if(!success)throw new IOException("Image encoder format is unavailable");return output.toByteArray();
        }catch(ReflectiveOperationException failure){throw new IOException("Image encoder is unavailable",failure);}
    }
}
