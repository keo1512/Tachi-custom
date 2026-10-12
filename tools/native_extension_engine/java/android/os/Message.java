package android.os;

/** Portable message payload; Binder/Parcel transport is deliberately unavailable on iOS. */
public final class Message implements Parcelable {
    public int what,arg1,arg2,sendingUid=-1;
    public Object obj;
    public Messenger replyTo;
    long when;
    boolean queued;
    private Handler target;
    private Runnable callback;
    private Bundle data;
    private boolean asynchronous;
    public Message(){}
    public static Message obtain(){return new Message();}
    public static Message obtain(Message source){Message value=new Message();value.copyFrom(source);value.target=source.target;value.callback=source.callback;return value;}
    public static Message obtain(Handler handler){Message value=new Message();value.target=handler;return value;}
    public static Message obtain(Handler handler,Runnable runnable){if(runnable==null)throw new NullPointerException("Runnable is required");Message value=obtain(handler);value.callback=runnable;return value;}
    public static Message obtain(Handler handler,int what){Message value=obtain(handler);value.what=what;return value;}
    public static Message obtain(Handler handler,int what,Object object){Message value=obtain(handler,what);value.obj=object;return value;}
    public static Message obtain(Handler handler,int what,int arg1,int arg2){return obtain(handler,what,arg1,arg2,null);}
    public static Message obtain(Handler handler,int what,int arg1,int arg2,Object object){Message value=obtain(handler,what,object);value.arg1=arg1;value.arg2=arg2;return value;}
    public void recycle(){if(queued)throw new IllegalStateException("Cannot recycle a queued Message");target=null;callback=null;obj=null;data=null;}
    public void copyFrom(Message source){what=source.what;arg1=source.arg1;arg2=source.arg2;obj=source.obj;replyTo=source.replyTo;sendingUid=source.sendingUid;asynchronous=source.asynchronous;data=source.data;}
    public long getWhen(){return when;}
    public void setTarget(Handler target){if(queued)throw new IllegalStateException("Message is already queued");this.target=target;}
    public Handler getTarget(){return target;}
    public Runnable getCallback(){return callback;}
    public Bundle getData(){if(data==null)data=new Bundle();return data;}
    public Bundle peekData(){return data;}
    public void setData(Bundle data){this.data=data;}
    public void sendToTarget(){if(target==null)throw new IllegalStateException("Message has no target");target.sendMessage(this);}
    public boolean isAsynchronous(){return asynchronous;}
    public void setAsynchronous(boolean value){asynchronous=value;}
    public int describeContents(){return 0;}
    public void writeToParcel(Parcel parcel,int flags){throw new UnsupportedOperationException("Android Parcel transport is unavailable");}
    public static final Parcelable.Creator<Message> CREATOR=new Parcelable.Creator<Message>(){
        public Message createFromParcel(Parcel parcel){throw new UnsupportedOperationException("Android Parcel transport is unavailable");}
        public Message[] newArray(int size){return new Message[size];}
    };
    public String toString(){return "Message(what="+what+")";}
}
