package android.os;

import android.util.Printer;

/** Android Handler scheduling contract backed by the host's serial JVM Looper. */
public class Handler {
    public interface Callback{boolean handleMessage(Message message);}
    private final Looper looper;
    private final Callback callback;
    public Handler(){this(current(),null);}
    public Handler(Callback callback){this(current(),callback);}
    public Handler(Looper looper){this(looper,null);}
    public Handler(Looper looper,Callback callback){if(looper==null)throw new NullPointerException("Looper is required");this.looper=looper;this.callback=callback;}
    private static Looper current(){Looper value=Looper.myLooper();if(value==null)throw new IllegalStateException("Thread has no Looper");return value;}
    public static Handler createAsync(Looper looper){return new Handler(looper);}
    public static Handler createAsync(Looper looper,Callback callback){return new Handler(looper,callback);}
    public void handleMessage(Message message){}
    public void dispatchMessage(Message message){message.queued=false;if(message.getCallback()!=null)message.getCallback().run();else if(callback==null||!callback.handleMessage(message))handleMessage(message);}
    public String getMessageName(Message message){return message.getCallback()!=null?message.getCallback().getClass().getName():Integer.toHexString(message.what);}
    public final Message obtainMessage(){return Message.obtain(this);}
    public final Message obtainMessage(int what){return Message.obtain(this,what);}
    public final Message obtainMessage(int what,Object object){return Message.obtain(this,what,object);}
    public final Message obtainMessage(int what,int arg1,int arg2){return Message.obtain(this,what,arg1,arg2);}
    public final Message obtainMessage(int what,int arg1,int arg2,Object object){return Message.obtain(this,what,arg1,arg2,object);}
    public final boolean post(Runnable runnable){return postDelayed(runnable,0);}
    public final boolean postAtTime(Runnable runnable,long uptime){return postAtTime(runnable,null,uptime);}
    public final boolean postAtTime(Runnable runnable,Object token,long uptime){Message message=Message.obtain(this,runnable);message.obj=token;return sendMessageAtTime(message,uptime);}
    public final boolean postDelayed(Runnable runnable,long delay){return postDelayed(runnable,null,delay);}
    public final boolean postDelayed(Runnable runnable,Object token,long delay){return postAtTime(runnable,token,SystemClock.uptimeMillis()+Math.max(0,delay));}
    public final boolean postAtFrontOfQueue(Runnable runnable){return sendMessageAtFrontOfQueue(Message.obtain(this,runnable));}
    public final void removeCallbacks(Runnable runnable){removeCallbacks(runnable,null);}
    public final void removeCallbacks(Runnable runnable,Object token){looper.remove(this,runnable,null,token,false);}
    public final boolean sendMessage(Message message){return sendMessageDelayed(message,0);}
    public final boolean sendEmptyMessage(int what){return sendMessage(obtainMessage(what));}
    public final boolean sendEmptyMessageDelayed(int what,long delay){return sendMessageDelayed(obtainMessage(what),delay);}
    public final boolean sendEmptyMessageAtTime(int what,long uptime){return sendMessageAtTime(obtainMessage(what),uptime);}
    public final boolean sendMessageDelayed(Message message,long delay){return sendMessageAtTime(message,SystemClock.uptimeMillis()+Math.max(0,delay));}
    public boolean sendMessageAtTime(Message message,long uptime){message.setTarget(this);return looper.enqueue(message,uptime,false);}
    public final boolean sendMessageAtFrontOfQueue(Message message){message.setTarget(this);return looper.enqueue(message,0,true);}
    public final void removeMessages(int what){removeMessages(what,null);}
    public final void removeMessages(int what,Object token){looper.remove(this,null,what,token,false);}
    public final void removeCallbacksAndMessages(Object token){looper.remove(this,null,null,token,true);}
    public final boolean hasMessages(int what){return hasMessages(what,null);}
    public final boolean hasMessages(int what,Object token){return looper.contains(this,null,what,token);}
    public final boolean hasCallbacks(Runnable runnable){return looper.contains(this,runnable,null,null);}
    public final Looper getLooper(){return looper;}
    public final void dump(Printer printer,String prefix){looper.dump(printer,prefix);}
    public String toString(){return "Handler("+looper+")";}
}
