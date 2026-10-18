package android.graphics;

/** Rectangle copy/scaling used by original source image interceptors. */
public final class Canvas {
    private Bitmap target;
    public Canvas(){}
    public Canvas(Bitmap bitmap){setBitmap(bitmap);}
    public void setBitmap(Bitmap bitmap){if(bitmap!=null)bitmap.require();target=bitmap;}
    public int getWidth(){return target==null?0:target.getWidth();}
    public int getHeight(){return target==null?0:target.getHeight();}
    public void drawColor(int color){if(target==null)throw new IllegalStateException("Canvas has no bitmap");target.eraseColor(color);}
    public void drawBitmap(Bitmap source,float left,float top,Paint paint){drawBitmap(source,null,new Rect(Math.round(left),Math.round(top),Math.round(left)+source.getWidth(),Math.round(top)+source.getHeight()),paint);}
    public void drawBitmap(Bitmap source,Rect src,Rect dst,Paint paint){
        if(target==null)throw new IllegalStateException("Canvas has no bitmap");source.require();target.require();
        if(src==null)src=new Rect(0,0,source.width,source.height);
        if(src.isEmpty()||dst.isEmpty())return;
        if(src.left<0||src.top<0||src.right>source.width||src.bottom>source.height)throw new IllegalArgumentException("Source rectangle exceeds bitmap");
        int[] pixels=source==target?source.pixels.clone():source.pixels;
        for(int y=Math.max(0,dst.top);y<Math.min(target.height,dst.bottom);y++){
            int sy=src.top+(int)(((long)y-dst.top)*src.height()/dst.height());
            for(int x=Math.max(0,dst.left);x<Math.min(target.width,dst.right);x++){
                int sx=src.left+(int)(((long)x-dst.left)*src.width()/dst.width());
                target.pixels[y*target.width+x]=pixels[sy*source.width+sx];
            }
        }
    }
}
