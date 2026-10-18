package android.graphics;

public final class Rect {
    public int left,top,right,bottom;
    public Rect(){}
    public Rect(int left,int top,int right,int bottom){set(left,top,right,bottom);}
    public Rect(Rect other){this(other.left,other.top,other.right,other.bottom);}
    public void set(int left,int top,int right,int bottom){this.left=left;this.top=top;this.right=right;this.bottom=bottom;}
    public int width(){return right-left;}
    public int height(){return bottom-top;}
    public int getWidth(){return width();}
    public int getHeight(){return height();}
    public boolean isEmpty(){return left>=right||top>=bottom;}
    public boolean contains(int x,int y){return x>=left&&x<right&&y>=top&&y<bottom;}
    public int centerX(){return (left+right)/2;}
    public int centerY(){return (top+bottom)/2;}
    public void offset(int x,int y){left+=x;right+=x;top+=y;bottom+=y;}
    public String toString(){return "Rect("+left+","+top+","+right+","+bottom+")";}
}
