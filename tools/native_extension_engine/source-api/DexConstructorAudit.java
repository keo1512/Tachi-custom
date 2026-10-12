import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.node.*;
import com.googlecode.d2j.node.insn.*;
import com.googlecode.d2j.reader.DexFileReader;
import java.io.File;
import java.util.Arrays;

/** Read-only diagnostic: retain DEX NEW_INSTANCE and constructor owner identity. */
public final class DexConstructorAudit {
    public static void main(String[] args) throws Exception {
        DexFileNode file = new DexFileNode();
        Dex2jar.from(new File(args[0])).getReader().accept(file, DexFileReader.SKIP_DEBUG);
        for (DexClassNode type : file.clzs) {
            if (type.superClass != null && type.superClass.contains("Filter$")) {
                System.out.println("CLASS " + type.className + " SUPER " + type.superClass);
                if (type.methods != null) for (DexMethodNode method : type.methods) System.out.println("  METHOD " + method.method);
            }
            if (!type.className.equals(args.length > 1 ? args[1] : "Lkeiyoushi/source/Generated;")) continue;
            System.out.println("SELECTED CLASS " + type.className + " SUPER " + type.superClass);
            for (DexMethodNode method : type.methods) {
                if (!method.method.getName().equals(args.length > 2 ? args[2] : "getFilterList")) continue;
                System.out.println("METHOD " + method.method);
                int index = 0;
                for (DexStmtNode stmt : method.codeNode.stmts) {
                    if (stmt instanceof TypeStmtNode) {
                        TypeStmtNode value = (TypeStmtNode) stmt;
                        System.out.println(index + " " + value.op + " v" + value.a + " " + value.type);
                    }
                    if (stmt instanceof MethodStmtNode) {
                        MethodStmtNode value = (MethodStmtNode) stmt;
                        if (value.method.getName().equals("<init>")) {
                            System.out.println(index + " " + value.op + " " + Arrays.toString(value.args) + " " + value.method);
                        }
                    }
                    index++;
                }
            }
        }
    }
}
