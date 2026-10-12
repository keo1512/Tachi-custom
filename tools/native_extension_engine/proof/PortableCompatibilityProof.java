package dev.tachibooks.engine;

import android.os.*;
import androidx.preference.*;
import com.squareup.zstd.okio.OkioZstd;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.*;
import okio.*;

/** Executable Java8 proof of portable scheduling, persisted preferences and real Zstd bytes. */
public final class PortableCompatibilityProof {
    private static void require(boolean value,String message){if(!value)throw new AssertionError(message);}
    public static void main(String[] args)throws Exception{
        require("1.8".equals(System.getProperty("java.specification.version")),"Use the Java8 verifier/interpreter");
        require(java.lang.management.ManagementFactory.getRuntimeMXBean().getInputArguments().contains("-Xint"),"Interpreter proof requires -Xint");
        scheduling();preferences(Paths.get(args[0]));compression();
        System.out.println("JAVA8_PORTABLE_COMPATIBILITY_PROOF_OK serial-handler cancellation typed-preferences zstd-frames-flush-close");
    }
    private static void scheduling()throws Exception{
        Looper main=Looper.getMainLooper();
        require(main.getThread()!=Thread.currentThread(),"Extension scheduler is separate from the caller");
        CountDownLatch started=new CountDownLatch(1),release=new CountDownLatch(1),done=new CountDownLatch(3);
        List<Integer> order=Collections.synchronizedList(new ArrayList<Integer>());
        Handler handler=new Handler(main,message->{require(main.isCurrentThread(),"Message thread identity");order.add(message.what);done.countDown();return true;});
        require(handler.post(()->{started.countDown();try{require(release.await(5,TimeUnit.SECONDS),"Release scheduler");}catch(InterruptedException failure){throw new AssertionError(failure);}}),"Initial post");
        require(started.await(5,TimeUnit.SECONDS),"Scheduler starts");
        handler.post(()->{order.add(1);done.countDown();});
        handler.postAtFrontOfQueue(()->{order.add(2);done.countDown();});
        Runnable cancelled=()->{throw new AssertionError("Cancelled runnable executed");};
        handler.postDelayed(cancelled,100);require(handler.hasCallbacks(cancelled),"Pending callback visible");handler.removeCallbacks(cancelled);require(!handler.hasCallbacks(cancelled),"Callback removed");
        handler.sendEmptyMessage(5);require(handler.hasMessages(5),"Pending message visible");
        release.countDown();require(done.await(5,TimeUnit.SECONDS),"Ordered messages complete");
        require(order.equals(Arrays.asList(2,1,5)),"Front queue and serial message ordering");
        CountDownLatch prepared=new CountDownLatch(1);
        Thread worker=new Thread(()->{Looper.prepare();Handler local=new Handler();local.post(()->{require(Looper.myLooper().isCurrentThread(),"Prepared loop runs on owning thread");prepared.countDown();Looper.myLooper().quit();});Looper.loop();},"PreparedExtensionProof");
        worker.start();require(prepared.await(5,TimeUnit.SECONDS),"Prepared Looper delivery");worker.join(5000);require(!worker.isAlive(),"Prepared Looper quits");
    }
    private static void preferences(Path directory)throws Exception{
        Files.createDirectories(directory);EngineApplication app=new EngineApplication(directory);
        Preference number=new Preference(app);number.setKey("number");number.setDefaultValue(7);number.setSharedPreferences(app.getSharedPreferences("proof",0));
        number.setEnabled(false);number.setVisible(false);require(!number.isEnabled()&&!number.getVisible(),"Enabled and visibility retained");number.saveNewValue(19);
        EngineApplication reopened=new EngineApplication(directory);number.setSharedPreferences(reopened.getSharedPreferences("proof",0));require(number.getCurrentValue().equals(19),"Typed value persists across new application");
        MultiSelectListPreference multiple=new MultiSelectListPreference(reopened);multiple.setKey("selected");multiple.setEntryValues(new String[]{"a","b","c"});multiple.setSharedPreferences(reopened.getSharedPreferences("proof",0));multiple.setValues(new LinkedHashSet<>(Arrays.asList("a","c")));
        require(multiple.getValues().equals(new HashSet<>(Arrays.asList("a","c"))),"Selected values retained");require(multiple.findIndexOfValue("c")==2&&multiple.findIndexOfValue("missing")==-1,"Entry index lookup");
        Set<String> external=multiple.getValues();external.clear();require(multiple.getValues().size()==2,"Selected values copied");
    }
    private static void compression()throws Exception{
        byte[] input=new byte[1024*1024+733];new Random(8391).nextBytes(input);
        Buffer compressed=new Buffer();Sink encoder=OkioZstd.zstdCompress(compressed);
        Buffer first=new Buffer().write(input,0,100731);encoder.write(first,first.size());encoder.flush();
        byte[] flushed=decode(compressed.clone());require(Arrays.equals(flushed,Arrays.copyOfRange(input,0,100731)),"Flush exposes complete standard frames");
        Buffer remaining=new Buffer().write(input,100731,input.length-100731);encoder.write(remaining,remaining.size());encoder.close();
        require(Arrays.equals(input,decode(compressed.clone())),"Concatenated Zstandard frames recover exact bytes");
        Buffer empty=new Buffer();OkioZstd.zstdCompress(empty).close();require(decode(empty).length==0,"Empty compressed stream is valid");
        boolean rejected=false;byte[] truncated=compressed.readByteArray();
        try{decode(new Buffer().write(truncated,0,truncated.length-1));}catch(Exception expected){rejected=true;}
        require(rejected,"Truncated compressed stream is rejected");
        try{encoder.flush();throw new AssertionError("Closed sink accepted flush");}catch(java.io.IOException expected){}
    }
    private static byte[] decode(Buffer input)throws Exception{
        Buffer output=new Buffer();try(Source decoder=OkioZstd.zstdDecompress(input)){while(decoder.read(output,8192)!=-1){require(output.size()<2*1024*1024,"Bounded fixture decode");}}return output.readByteArray();
    }
}
