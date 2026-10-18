package android.graphics;

import dev.tachibooks.engine.ImageCodec;
import java.io.*;
import java.util.Arrays;

/** CPU pixel operations keep extension strip/tile transforms portable to iOS. */
public final class Bitmap {
    public enum Config{ALPHA_8,RGB_565,ARGB_4444,ARGB_8888,RGBA_F16,HARDWARE}
    public enum CompressFormat{JPEG,PNG,WEBP,WEBP_LOSSY,WEBP_LOSSLESS}
    final int width,height;int[] pixels;
    private Bitmap(int width,int height,int[] pixels){this.width=width;this.height=height;this.pixels=pixels;}
    static Bitmap decoded(int[] decoded){if(decoded==null||decoded.length<3)return null;int w=decoded[0],h=decoded[1];if(w<1||h<1||(long)w*h>ImageCodec.MAX_PIXELS||decoded.length!=2L+w*(long)h)throw new IllegalArgumentException("Invalid decoded bitmap");System.arraycopy(decoded,2,decoded,0,w*h);return new Bitmap(w,h,decoded);}
    public static Bitmap createBitmap(int width,int height,Config config){if(config==null)throw new NullPointerException("Bitmap config");if(width<1||height<1||(long)width*height>ImageCodec.MAX_PIXELS)throw new IllegalArgumentException("Bitmap dimensions exceed limit");return new Bitmap(width,height,new int[width*height]);}
    public static Bitmap createBitmap(Bitmap source,int x,int y,int width,int height){source.require();if(x<0||y<0||width<1||height<1||x+(long)width>source.width||y+(long)height>source.height)throw new IllegalArgumentException("Bitmap crop bounds");Bitmap out=createBitmap(width,height,Config.ARGB_8888);for(int row=0;row<height;row++)System.arraycopy(source.pixels,(y+row)*source.width+x,out.pixels,row*width,width);return out;}
    public static Bitmap createBitmap(int[] colors,int width,int height,Config config){Bitmap result=createBitmap(width,height,config);if(colors.length<result.pixels.length)throw new IllegalArgumentException("Bitmap pixel count");System.arraycopy(colors,0,result.pixels,0,result.pixels.length);return result;}
    void require(){if(pixels==null)throw new IllegalStateException("Bitmap is recycled");}
    public int getWidth(){require();return width;}
    public int getHeight(){require();return height;}
    public Config getConfig(){return Config.ARGB_8888;}
    public int getByteCount(){require();return width*height*4;}
    public int getAllocationByteCount(){require();return pixels.length*4;}
    public int getRowBytes(){return width*4;}
    public boolean isMutable(){return true;}
    public boolean isRecycled(){return pixels==null;}
    public void recycle(){pixels=null;}
    public void eraseColor(int color){require();Arrays.fill(pixels,color);}
    public int getPixel(int x,int y){require();bounds(x,y,1,1);return pixels[y*width+x];}
    public void setPixel(int x,int y,int color){require();bounds(x,y,1,1);pixels[y*width+x]=color;}
    private void bounds(int x,int y,int w,int h){if(x<0||y<0||w<0||h<0||x+(long)w>width||y+(long)h>height)throw new IllegalArgumentException("Bitmap pixel bounds");}
    public void getPixels(int[] destination,int offset,int stride,int x,int y,int w,int h){require();bounds(x,y,w,h);copy(pixels,y*width+x,width,destination,offset,stride,w,h);}
    public void setPixels(int[] source,int offset,int stride,int x,int y,int w,int h){require();bounds(x,y,w,h);copy(source,offset,stride,pixels,y*width+x,width,w,h);}
    private static void copy(int[] src,int start,int stride,int[] dst,int offset,int outStride,int w,int h){if(Math.abs((long)stride)<w||Math.abs((long)outStride)<w)throw new IllegalArgumentException("Bitmap stride");for(int row=0;row<h;row++)System.arraycopy(src,start+row*stride,dst,offset+row*outStride,w);}
    public Bitmap copy(Config config,boolean mutable){require();Bitmap result=createBitmap(width,height,config);System.arraycopy(pixels,0,result.pixels,0,width*height);return result;}
    public boolean compress(CompressFormat format,int quality,OutputStream output){require();if(output==null||format==null)throw new NullPointerException("Bitmap output");if(quality<0||quality>100)throw new IllegalArgumentException("Bitmap quality");String codec=format==CompressFormat.PNG?"png":format==CompressFormat.JPEG?"jpeg":"webp";try{byte[] bytes=ImageCodec.encode(pixels,width,height,codec,quality);if(bytes==null||bytes.length==0)return false;output.write(bytes);return true;}catch(IOException failure){return false;}}
}
