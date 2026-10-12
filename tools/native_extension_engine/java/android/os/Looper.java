package android.os;

import android.util.Printer;
import java.util.concurrent.DelayQueue;
import java.util.concurrent.Delayed;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicLong;

/** Serial JVM message loop for extension scheduling; this is not the UIKit UI thread. */
public final class Looper {
    private static final ThreadLocal<Looper> CURRENT=new ThreadLocal<>();
    private static final AtomicLong ORDER=new AtomicLong();
    private final DelayQueue<Pending> queue=new DelayQueue<>();
    private Thread thread;
    private volatile boolean stopped;
    private Looper(Thread thread){this.thread=thread;}
    private static final class Main {
        static final Looper INSTANCE=start();
        private static Looper start(){
            final Looper value=new Looper(null);
            Thread worker=new Thread(()->{CURRENT.set(value);run(value);},"TachiExtensionLooper");
            worker.setDaemon(true);value.thread=worker;worker.start();return value;
        }
    }
    public static void prepare(){if(CURRENT.get()!=null)throw new IllegalStateException("Thread already has a Looper");CURRENT.set(new Looper(Thread.currentThread()));}
    public static void prepareMainLooper(){throw new UnsupportedOperationException("The extension main Looper is initialized by the host");}
    public static Looper getMainLooper(){return Main.INSTANCE;}
    public static Looper myLooper(){return CURRENT.get();}
    public static void loop(){Looper value=myLooper();if(value==null)throw new IllegalStateException("No Looper was prepared for this thread");run(value);}
    private static void run(Looper value){
        try{while(!value.stopped){Pending task=value.queue.take();if(!value.stopped)task.message.getTarget().dispatchMessage(task.message);}}
        catch(InterruptedException interrupted){Thread.currentThread().interrupt();}
        finally{value.stopped=true;value.queue.clear();}
    }
    synchronized boolean enqueue(Message message,long when,boolean front){
        if(stopped)return false;
        if(message.queued)throw new IllegalStateException("Message is already queued");
        message.queued=true;message.when=when;
        queue.add(new Pending(message,front?0:Math.max(0,when),front?-ORDER.incrementAndGet():ORDER.incrementAndGet()));return true;
    }
    synchronized void remove(Handler handler,Runnable runnable,Integer what,Object token,boolean all){
        queue.removeIf(task->{Message m=task.message;boolean match=m.getTarget()==handler&&(all||runnable!=null&&m.getCallback()==runnable||what!=null&&m.getCallback()==null&&m.what==what)&&(token==null||m.obj==token);if(match)m.queued=false;return match;});
    }
    synchronized boolean contains(Handler handler,Runnable runnable,Integer what,Object token){
        for(Pending task:queue){Message m=task.message;if(m.getTarget()==handler&&(runnable!=null?m.getCallback()==runnable:m.getCallback()==null&&what!=null&&m.what==what)&&(token==null||m.obj==token))return true;}return false;
    }
    public boolean isCurrentThread(){return Thread.currentThread()==thread;}
    public Thread getThread(){return thread;}
    public void quit(){stopped=true;queue.clear();thread.interrupt();}
    public void quitSafely(){synchronized(this){queue.removeIf(task->task.when>SystemClock.uptimeMillis());}Handler handler=new Handler(this);handler.post(this::quit);}
    public void setMessageLogging(Printer printer){if(printer!=null)throw new UnsupportedOperationException("Message tracing is not supported");}
    public void dump(Printer printer,String prefix){printer.println(prefix+"Extension Looper queued="+queue.size()+" stopped="+stopped);}
    public MessageQueue getQueue(){throw new UnsupportedOperationException("Android MessageQueue native hooks are unavailable");}
    public static MessageQueue myQueue(){Looper looper=myLooper();if(looper==null)throw new IllegalStateException("No current Looper");return looper.getQueue();}
    public String toString(){return "Looper("+thread.getName()+")";}
    private static final class Pending implements Delayed{
        final Message message;final long when,order;
        Pending(Message message,long when,long order){this.message=message;this.when=when;this.order=order;}
        public long getDelay(TimeUnit unit){return unit.convert(when-SystemClock.uptimeMillis(),TimeUnit.MILLISECONDS);}
        public int compareTo(Delayed other){Pending value=(Pending)other;int time=Long.compare(when,value.when);return time==0?Long.compare(order,value.order):time;}
    }
}
