import com.googlecode.d2j.*;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.node.*;
import com.googlecode.d2j.reader.*;
import com.googlecode.d2j.visitors.DexFileVisitor;
import dev.tachibooks.engine.DexCompatibility;
import java.net.URLClassLoader;
import java.nio.file.*;
import java.util.*;

/** Executable JVM8 regression for constructor identity, aliases and wide arguments. */
public final class DexCompatibilityProof {
    public abstract static class Base {
        public final String label;
        public final long value;
        public Base(String label, long value) { this.label = label; this.value = value; }
    }
    private static final String BASE = "LDexCompatibilityProof$Base;";
    private static final String CHILD = "Lfixture/ConstructorChild;";
    private static final String INTERMEDIATE = "Lfixture/ConstructorIntermediate;";
    private static final String EXPLICIT = "Lfixture/ConstructorExplicit;";
    private static final String FACTORY = "Lfixture/ConstructorFactory;";
    private static final Method PARENT = new Method(BASE, "<init>", new String[]{"Ljava/lang/String;", "J"}, "V");
    private static void require(boolean result, String reason) {
        if (!result) throw new AssertionError(reason);
    }
    private static BaseDexFileReader reader(final DexFileNode file) {
        return new BaseDexFileReader() {
            public int getDexVersion() { return 35; }
            public List<String> getClassNames() {
                List<String> names = new ArrayList<>();
                for (DexClassNode type : file.clzs) names.add(type.className);
                return names;
            }
            public void accept(DexFileVisitor visitor) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int config) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int index, int config) { file.clzs.get(index).accept(visitor); }
        };
    }
    private static DexFileNode fixture(boolean existingConstructor, int branch) {
        DexFileNode file = new DexFileNode(); file.visitDexFileVersion(35);
        file.visit(0x401, INTERMEDIATE, BASE, new String[0]); // abstract, constructor elided by R8
        DexClassNode child = (DexClassNode) file.visit(0x11, CHILD, INTERMEDIATE, new String[0]);
        if (existingConstructor) child.visitMethod(0x10001,
                new Method(CHILD, "<init>", PARENT.getParameterTypes(), "V"));
        DexClassNode explicit = (DexClassNode) file.visit(0x11, EXPLICIT, INTERMEDIATE, new String[0]);
        Method explicitConstructor = new Method(EXPLICIT, "<init>", PARENT.getParameterTypes(), "V");
        DexCodeNode explicitCode = (DexCodeNode) explicit.visitMethod(0x10001, explicitConstructor).visitCode();
        explicitCode.visitRegister(4);
        // A constructor's uninitialized this may directly invoke an ancestor
        // after R8 removes the intermediate constructor.
        explicitCode.visitMethodStmt(Op.INVOKE_DIRECT, new int[]{0, 1, 2, 3}, PARENT);
        explicitCode.visitStmt0R(Op.RETURN_VOID);
        DexClassNode factory = (DexClassNode) file.visit(0x11, FACTORY, "Ljava/lang/Object;", new String[0]);
        for (String name : new String[]{"first", "second", "explicit"}) {
            DexMethodNode method = (DexMethodNode) factory.visitMethod(0x9, new Method(FACTORY, name, new String[0], BASE));
            DexCodeNode code = (DexCodeNode) method.visitCode();
            code.visitRegister(6);
            code.visitTypeStmt(Op.NEW_INSTANCE, 0, 0, name.equals("explicit") ? EXPLICIT : CHILD);
            if (branch == 3) {
                DexLabel alternative = new DexLabel(), join = new DexLabel();
                code.visitConstStmt(Op.CONST, 4, 0);
                code.visitPackedSwitchStmt(Op.PACKED_SWITCH, 4, 0, new DexLabel[]{alternative});
                code.visitConstStmt(Op.CONST_STRING, 1, "unselected switch");
                code.visitJumpStmt(Op.GOTO, 0, 0, join);
                code.visitLabel(alternative);
                code.visitConstStmt(Op.CONST_STRING, 1, name);
                code.visitLabel(join);
            } else if (branch != 0) {
                DexLabel alternative = new DexLabel(), join = new DexLabel();
                code.visitConstStmt(Op.CONST, 4, 0);
                code.visitJumpStmt(Op.IF_EQZ, 4, 0, alternative);
                code.visitConstStmt(Op.CONST_STRING, 1, "unselected branch");
                if (branch == 2) code.visitTypeStmt(Op.NEW_INSTANCE, 0, 0, CHILD);
                code.visitJumpStmt(Op.GOTO, 0, 0, join);
                code.visitLabel(alternative);
                code.visitConstStmt(Op.CONST_STRING, 1, name);
                code.visitLabel(join);
            }
            code.visitStmt2R(Op.MOVE_OBJECT, 5, 0);
            // Overwriting the original register must leave its alias intact.
            code.visitConstStmt(Op.CONST, 0, 0);
            if (branch == 0) code.visitConstStmt(Op.CONST_STRING, 1, name);
            code.visitConstStmt(Op.CONST_WIDE, 2, 1234567890123L);
            // Long comparison writes one int, preserving adjacent v5's object.
            code.visitStmt3R(Op.CMP_LONG, 4, 2, 2);
            code.visitMethodStmt(Op.INVOKE_DIRECT, new int[]{5, 1, 2, 3}, name.equals("explicit") ? explicitConstructor : PARENT);
            code.visitStmt1R(Op.RETURN_OBJECT, 5);
        }
        return file;
    }
    public static void main(String[] args) throws Exception {
        require(System.getProperty("java.specification.version").equals("1.8"), "Execute with Java8 verifier");
        Path output = Paths.get(args[0]);
        for (int branch : new int[]{0, 1, 3}) {
            Path jar = branch == 0 ? output : Paths.get(output.toString().replace(".jar", "-branch" + branch + ".jar"));
            BaseDexFileReader prepared = DexCompatibility.prepare(reader(fixture(false, branch)));
            Dex2jar.from(prepared).computeFrames(true).dontSanitizeNames(true).to(jar);
            try (URLClassLoader loader = new URLClassLoader(new java.net.URL[]{jar.toUri().toURL()}, DexCompatibilityProof.class.getClassLoader())) {
                Class<?> factory = loader.loadClass("fixture.ConstructorFactory");
                for (String name : new String[]{"first", "second", "explicit"}) {
                    Base result = (Base) factory.getMethod(name).invoke(null);
                    require(result.getClass().getName().equals(name.equals("explicit") ? "fixture.ConstructorExplicit" : "fixture.ConstructorChild"), "Allocation class preserved");
                    require(result.label.equals(name) && result.value == 1234567890123L, "Forwarded wide arguments/aliases");
                    require(result.getClass().getDeclaredConstructors().length == 1, "Forwarder reused once");
                }
            }
        }
        try { DexCompatibility.prepare(reader(fixture(true, 0))); throw new AssertionError("Existing side-effect constructor accepted"); }
        catch (IllegalArgumentException expected) { require(expected.getMessage().contains("already declares"), "Existing constructor rejection reason"); }
        try { DexCompatibility.prepare(reader(fixture(false, 2))); throw new AssertionError("Unproven branch receiver accepted"); }
        catch (IllegalArgumentException expected) { require(expected.getMessage().contains("control-flow"), "Ambiguous branch rejection reason"); }
        System.out.println("JAVA8_DEX_COMPAT_PROOF_OK concrete identity/alias/wide/reuse/conditional and switch joins/ancestor chain/constructor this/CMP destination/existing ctor/ambiguous branch rejection");
    }
}
