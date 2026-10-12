package dev.tachibooks.engine;

import com.googlecode.d2j.Method;
import com.googlecode.d2j.DexLabel;
import com.googlecode.d2j.node.*;
import com.googlecode.d2j.node.insn.*;
import com.googlecode.d2j.reader.*;
import com.googlecode.d2j.visitors.DexFileVisitor;
import java.util.*;

/** Preserve R8's constructor-elided concrete allocations when converting to JVM. */
public final class DexCompatibility {
    private DexCompatibility() {}

    public static BaseDexFileReader prepare(BaseDexFileReader input) {
        final DexFileNode file = new DexFileNode();
        // Read failures must propagate; a partially read package is not executable.
        input.accept(file, DexFileReader.SKIP_DEBUG);
        final Map<String, DexClassNode> types = new HashMap<>();
        final Set<Method> forwarders = new HashSet<>();
        for (DexClassNode type : file.clzs) {
            types.put(type.className, type);
        }
        for (DexClassNode type : file.clzs) {
            if (type.methods == null) continue;
            // Adding forwarding constructors may extend another class's list.
            for (DexMethodNode method : new ArrayList<>(type.methods)) {
                normalize(method, types, forwarders);
            }
        }
        return new BaseDexFileReader() {
            public int getDexVersion() { return file.dexVersion; }
            public List<String> getClassNames() {
                List<String> names = new ArrayList<>();
                for (DexClassNode type : file.clzs) names.add(type.className);
                return names;
            }
            public void accept(DexFileVisitor visitor) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int config) { file.accept(visitor); }
            public void accept(DexFileVisitor visitor, int index, int config) {
                visitor.visitDexFileVersion(file.dexVersion);
                file.clzs.get(index).accept(visitor);
                visitor.visitEnd();
            }
        };
    }

    private static final class Allocation {
        final String type;
        final boolean constructorReceiver;
        Allocation(String type) { this(type, false); }
        Allocation(String type, boolean receiver) { this.type = type; constructorReceiver = receiver; }
    }
    // An untracked/initialized value on one incoming path must not be mistaken
    // for the allocation arriving on another path.
    private static final Allocation UNKNOWN = new Allocation(null);

    private static Map<Integer, Set<Allocation>> copy(Map<Integer, Set<Allocation>> state) {
        Map<Integer, Set<Allocation>> result = new HashMap<>();
        for (Map.Entry<Integer, Set<Allocation>> entry : state.entrySet()) {
            result.put(entry.getKey(), new HashSet<>(entry.getValue()));
        }
        return result;
    }

    private static boolean merge(Map<Integer, Set<Allocation>> target, Map<Integer, Set<Allocation>> source) {
        boolean changed = false;
        Set<Integer> registers = new HashSet<>(target.keySet());
        registers.addAll(source.keySet());
        for (Integer register : registers) {
            Set<Allocation> old = target.get(register);
            Set<Allocation> incoming = source.get(register);
            Set<Allocation> joined = old == null ? new HashSet<Allocation>() : new HashSet<>(old);
            if (old == null || incoming == null) joined.add(UNKNOWN);
            if (incoming != null) joined.addAll(incoming);
            if (!joined.equals(old)) { target.put(register, joined); changed = true; }
        }
        return changed;
    }

    private static int label(Map<DexLabel, Integer> labels, DexLabel value, DexMethodNode context) {
        Integer index = labels.get(value);
        if (index == null) throw unsupported(context, "missing control-flow label");
        return index;
    }

    private static void normalize(DexMethodNode method, Map<String, DexClassNode> types,
                                  Set<Method> forwarders) {
        if (method.codeNode == null || method.codeNode.stmts.isEmpty()) return;
        List<DexStmtNode> statements = method.codeNode.stmts;
        int count = statements.size();
        Map<DexLabel, Integer> labels = new IdentityHashMap<>();
        Map<Integer, Allocation> definitions = new HashMap<>();
        for (int index = 0; index < count; index++) {
            DexStmtNode statement = statements.get(index);
            if (statement instanceof DexLabelStmtNode) labels.put(((DexLabelStmtNode) statement).label, index);
            if (statement instanceof TypeStmtNode && statement.op == Op.NEW_INSTANCE) {
                definitions.put(index, new Allocation(((TypeStmtNode) statement).type));
            }
        }
        List<List<Integer>> edges = new ArrayList<>(), exceptional = new ArrayList<>();
        for (int index = 0; index < count; index++) {
            DexStmtNode statement = statements.get(index);
            List<Integer> successors = new ArrayList<>();
            String opcode = statement.op == null ? "" : statement.op.name();
            boolean fallthrough = !opcode.startsWith("RETURN") && !opcode.equals("THROW");
            if (statement instanceof JumpStmtNode) {
                successors.add(label(labels, ((JumpStmtNode) statement).label, method));
                if (opcode.startsWith("GOTO")) fallthrough = false;
            } else if (statement instanceof BaseSwitchStmtNode) {
                for (DexLabel target : ((BaseSwitchStmtNode) statement).labels) successors.add(label(labels, target, method));
            }
            if (fallthrough && index + 1 < count) successors.add(index + 1);
            edges.add(successors);
            exceptional.add(new ArrayList<Integer>());
        }
        if (method.codeNode.tryStmts != null) for (TryCatchNode range : method.codeNode.tryStmts) {
            int start = label(labels, range.start, method), end = label(labels, range.end, method);
            for (int index = start; index < end; index++) {
                // Exception paths observe the register state before the throwing
                // instruction. Labels cannot throw and need no exceptional edge.
                if (statements.get(index).op == null) continue;
                for (DexLabel handler : range.handler) exceptional.get(index).add(label(labels, handler, method));
            }
        }
        List<Map<Integer, Set<Allocation>>> states = new ArrayList<>();
        for (int index = 0; index < count; index++) states.add(null);
        Map<Integer, Set<Allocation>> entry = new HashMap<>();
        if (method.method.getName().equals("<init>")) {
            int parameters = 1;
            for (String parameter : method.method.getParameterTypes()) {
                parameters += parameter.equals("J") || parameter.equals("D") ? 2 : 1;
            }
            int receiverRegister = method.codeNode.totalRegister - parameters;
            if (receiverRegister < 0) throw unsupported(method, "invalid constructor parameter registers");
            entry.put(receiverRegister, new HashSet<>(Collections.singleton(new Allocation(method.method.getOwner(), true))));
        }
        states.set(0, entry);
        Deque<Integer> work = new ArrayDeque<>();
        boolean[] queued = new boolean[count];
        work.add(0); queued[0] = true;
        while (!work.isEmpty()) {
            int index = work.removeFirst(); queued[index] = false;
            Map<Integer, Set<Allocation>> before = states.get(index);
            Map<Integer, Set<Allocation>> after = copy(before);
            transfer(statements.get(index), definitions.get(index), after);
            propagate(after, edges.get(index), states, work, queued);
            propagate(before, exceptional.get(index), states, work, queued);
        }
        for (int index = 0; index < statements.size(); index++) {
            DexStmtNode statement = statements.get(index);
            Map<Integer, Set<Allocation>> allocations = states.get(index);
            if (allocations == null) continue; // unreachable instructions
            if (statement instanceof MethodStmtNode) {
                MethodStmtNode call = (MethodStmtNode) statement;
                if (call.method.getName().equals("<init>") && call.args.length > 0) {
                    Set<Allocation> candidates = allocations.get(call.args[0]);
                    if (candidates != null) {
                        if (candidates.size() != 1 || candidates.contains(UNKNOWN)) {
                            for (Allocation value : candidates) if (value != UNKNOWN && !call.method.getOwner().equals(value.type)) {
                                throw unsupported(method, "constructor receiver has ambiguous control-flow allocations");
                            }
                            continue;
                        }
                        Allocation allocation = candidates.iterator().next();
                        if (!call.method.getOwner().equals(allocation.type)) {
                            if (call.op != Op.INVOKE_DIRECT && call.op != Op.INVOKE_DIRECT_RANGE) {
                                throw unsupported(method, "constructor opcode is not direct");
                            }
                            DexClassNode allocated = types.get(allocation.type);
                            if (allocated == null || !allocation.constructorReceiver && (allocated.access & 0x400) != 0) {
                                throw unsupported(method, "allocation is unknown or abstract");
                            }
                            String first = allocation.constructorReceiver ? allocated.superClass : allocation.type;
                            // A normal this/super constructor call already has
                            // legal JVM semantics; only ancestor elision needs
                            // pure forwarders in the skipped classes.
                            if (first.equals(call.method.getOwner())) continue;
                            Method forwarded = forwardPath(first, call.method, types, method, forwarders);
                            statements.set(index, new MethodStmtNode(call.op, call.args.clone(), forwarded));
                        }
                    }
                }
            }
        }
    }

    private static Method forwardPath(String first, Method ancestor, Map<String, DexClassNode> types,
                                      DexMethodNode context, Set<Method> forwarders) {
        List<DexClassNode> chain = new ArrayList<>();
        Set<String> seen = new HashSet<>();
        String cursor = first;
        while (!ancestor.getOwner().equals(cursor)) {
            DexClassNode type = types.get(cursor);
            if (type == null || (type.access & 0x200) != 0 || !seen.add(cursor)) {
                throw unsupported(context, "constructor owner is not a proven ancestor");
            }
            chain.add(type); cursor = type.superClass;
        }
        Method parent = ancestor;
        for (int index = chain.size() - 1; index >= 0; index--) {
            DexClassNode type = chain.get(index);
            Method forwarded = new Method(type.className, "<init>", ancestor.getParameterTypes(), "V");
            addForwarder(type, forwarded, parent, context, forwarders);
            parent = forwarded;
        }
        return parent;
    }

    private static void propagate(Map<Integer, Set<Allocation>> value, List<Integer> successors,
                                  List<Map<Integer, Set<Allocation>>> states, Deque<Integer> work, boolean[] queued) {
        for (Integer target : successors) {
            boolean changed;
            if (states.get(target) == null) { states.set(target, copy(value)); changed = true; }
            else changed = merge(states.get(target), value);
            if (changed && !queued[target]) { work.addLast(target); queued[target] = true; }
        }
    }

    private static void addForwarder(DexClassNode type, Method forwarded, Method parent,
                                     DexMethodNode context, Set<Method> forwarders) {
        if (type.methods == null) type.methods = new ArrayList<>();
        for (DexMethodNode existing : type.methods) {
            if (existing.method.equals(forwarded)) {
                if (forwarders.contains(forwarded)) return;
                // Calling an existing subclass constructor could add side effects
                // that the original DEX's explicit superclass call did not have.
                throw unsupported(context, "the concrete class already declares this constructor");
            }
        }
        DexMethodNode wrapper = new DexMethodNode(0x10001, forwarded); // public constructor
        DexCodeNode code = new DexCodeNode();
        int width = 1;
        for (String parameter : parent.getParameterTypes()) {
            width += parameter.equals("J") || parameter.equals("D") ? 2 : 1;
        }
        int[] registers = new int[width];
        for (int index = 0; index < width; index++) registers[index] = index;
        code.visitRegister(width);
        code.visitMethodStmt(Op.INVOKE_DIRECT_RANGE, registers, parent);
        code.visitStmt0R(Op.RETURN_VOID);
        wrapper.codeNode = code;
        type.methods.add(wrapper);
        forwarders.add(forwarded);
    }

    private static void written(int register, String opcode, Map<Integer, Set<Allocation>> allocations) {
        allocations.remove(register);
        // CMP_LONG/CMPL_DOUBLE/CMPG_DOUBLE produce a single int, despite the
        // operand type in their name. Do not erase an adjacent object register.
        if (opcode.contains("WIDE") || opcode.endsWith("_TO_LONG") || opcode.endsWith("_TO_DOUBLE") ||
                (!opcode.startsWith("CMP") && !opcode.contains("_TO_") &&
                        (opcode.contains("_LONG") || opcode.contains("_DOUBLE")))) {
            allocations.remove(register + 1);
        }
    }

    private static void transfer(DexStmtNode statement, Allocation definition, Map<Integer, Set<Allocation>> allocations) {
        String opcode = statement.op == null ? "" : statement.op.name();
        if (statement instanceof MethodStmtNode) {
            MethodStmtNode call = (MethodStmtNode) statement;
            if (call.method.getName().equals("<init>") && call.args.length > 0) {
                Set<Allocation> receiver = allocations.get(call.args[0]);
                if (receiver != null && receiver.size() == 1 && !receiver.contains(UNKNOWN)) {
                    Allocation initialized = receiver.iterator().next();
                    for (Iterator<Map.Entry<Integer, Set<Allocation>>> entries = allocations.entrySet().iterator(); entries.hasNext();) {
                        Set<Allocation> values = entries.next().getValue();
                        if (values.remove(initialized)) {
                            if (values.isEmpty()) entries.remove();
                            else values.add(UNKNOWN);
                        }
                    }
                }
            }
        } else if (statement instanceof TypeStmtNode) {
            TypeStmtNode type = (TypeStmtNode) statement;
            if (type.op == Op.NEW_INSTANCE) allocations.put(type.a, new HashSet<>(Collections.singleton(definition)));
            else if (type.op != Op.CHECK_CAST) written(type.a, opcode, allocations);
        } else if (statement instanceof Stmt2RNode) {
            Stmt2RNode move = (Stmt2RNode) statement;
            if (opcode.startsWith("MOVE_OBJECT")) {
                Set<Allocation> value = allocations.get(move.b);
                if (value == null) allocations.remove(move.a);
                else allocations.put(move.a, new HashSet<>(value));
            } else written(move.a, opcode, allocations);
        } else if (statement instanceof ConstStmtNode) {
            written(((ConstStmtNode) statement).a, opcode, allocations);
        } else if (statement instanceof Stmt1RNode) {
            if (opcode.startsWith("MOVE_RESULT") || opcode.equals("MOVE_EXCEPTION"))
                written(((Stmt1RNode) statement).a, opcode, allocations);
        } else if (statement instanceof Stmt2R1NNode) {
            written(((Stmt2R1NNode) statement).distReg, opcode, allocations);
        } else if (statement instanceof Stmt3RNode) {
            if (!opcode.startsWith("APUT")) written(((Stmt3RNode) statement).a, opcode, allocations);
        } else if (statement instanceof FieldStmtNode) {
            if (opcode.startsWith("IGET") || opcode.startsWith("SGET"))
                written(((FieldStmtNode) statement).a, opcode, allocations);
        }
    }

    private static IllegalArgumentException unsupported(DexMethodNode method, String reason) {
        return new IllegalArgumentException("Unsupported DEX constructor pattern in " + method.method + ": " + reason);
    }
}
