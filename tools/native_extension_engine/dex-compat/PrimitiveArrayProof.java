import com.googlecode.d2j.*;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.node.*;
import com.googlecode.d2j.reader.*;
import com.googlecode.d2j.visitors.DexFileVisitor;
import dev.tachibooks.engine.DexCompatibility;
import java.net.URLClassLoader;
import java.nio.file.*;
import java.util.*;

/** Execute original primitive fill-array payloads large enough to require Hex templates. */
public final class PrimitiveArrayProof {
    private static BaseDexFileReader reader(final DexFileNode file) {
        return new BaseDexFileReader() {
            public int getDexVersion() { return 35; }
            public List<String> getClassNames() { return Collections.singletonList("Lfixture/PrimitiveArrays;"); }
            public void accept(DexFileVisitor visitor) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int config) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int index, int config) { file.clzs.get(index).accept(visitor); }
        };
    }
    public static void main(String[] args)throws Exception {
        if(!System.getProperty("java.specification.version").equals("1.8"))throw new AssertionError("Java8 verifier required");
        int size=256;byte[] bytes=new byte[size];short[] shorts=new short[size];int[] ints=new int[size];long[] longs=new long[size];
        for(int i=0;i<size;i++){bytes[i]=(byte)(i-128);shorts[i]=(short)(i*257-32768);ints[i]=i*0x1020304^Integer.MIN_VALUE;longs[i]=Long.MIN_VALUE+0x1020304050607L*i;}
        DexFileNode file=new DexFileNode();file.visitDexFileVersion(35);
        DexClassNode type=(DexClassNode)file.visit(0x11,"Lfixture/PrimitiveArrays;","Ljava/lang/Object;",new String[0]);
        Object[] payloads={bytes,shorts,ints,longs};String[] descriptors={"[B","[S","[I","[J"};
        for(int i=0;i<payloads.length;i++){
            DexCodeNode code=(DexCodeNode)type.visitMethod(0x9,new Method(type.className,"array"+i,new String[0],descriptors[i])).visitCode();
            code.visitRegister(2);code.visitConstStmt(Op.CONST,0,size);code.visitTypeStmt(Op.NEW_ARRAY,0,0,descriptors[i]);code.visitFillArrayDataStmt(Op.FILL_ARRAY_DATA,0,payloads[i]);code.visitStmt1R(Op.RETURN_OBJECT,0);
        }
        Path output=Paths.get(args[0]);Dex2jar.from(DexCompatibility.prepare(reader(file))).dontSanitizeNames(true).computeFrames(true).to(output);
        try(URLClassLoader loader=new URLClassLoader(new java.net.URL[]{output.toUri().toURL()},PrimitiveArrayProof.class.getClassLoader())){
            Class<?> converted=loader.loadClass("fixture.PrimitiveArrays");
            Object[] actual=new Object[4];for(int i=0;i<4;i++)actual[i]=converted.getMethod("array"+i).invoke(null);
            if(!Arrays.equals(bytes,(byte[])actual[0])||!Arrays.equals(shorts,(short[])actual[1])||!Arrays.equals(ints,(int[])actual[2])||!Arrays.equals(longs,(long[])actual[3]))throw new AssertionError("DEX payload bytes changed");
        }
        System.out.println("JAVA8_PRIMITIVE_ARRAY_PROOF_OK four256entryarrays signedbyte/short/int/long exactvalues");
    }
}
