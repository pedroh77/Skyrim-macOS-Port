// Applies precomputed functions.tsv, jumptables.tsv, and extra_entries.json
// without running Ghidra auto-analysis, then dumps raw P-code JSONL.
//
// Args: <symbols_dir> <out.jsonl>
//@category BYOG

import java.io.*;
import java.nio.file.*;
import java.util.*;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.Register;
import ghidra.program.model.listing.*;
import ghidra.program.model.pcode.*;
import ghidra.program.model.symbol.*;

public class ApplyMetadataAndDump extends GhidraScript {

    private String vn(Varnode v) {
        if (v == null) return "null";
        String sp = v.getAddress().getAddressSpace().getName();
        if (v.isConstant()) sp = "const";
        return "[\"" + sp + "\"," + Long.toUnsignedString(v.getOffset()) + "," + v.getSize() + "]";
    }

    private List<Instruction> flowBody(Function f) {
        Listing listing = currentProgram.getListing();
        FunctionManager fm = currentProgram.getFunctionManager();
        TreeMap<Long, Instruction> seen = new TreeMap<>();
        ArrayDeque<Address> work = new ArrayDeque<>();
        work.add(f.getEntryPoint());
        while (!work.isEmpty() && seen.size() < 200000) {
            Address a = work.poll();
            if (seen.containsKey(a.getOffset())) continue;
            Instruction in = listing.getInstructionAt(a);
            if (in == null) continue;
            seen.put(a.getOffset(), in);
            FlowType ft = in.getFlowType();
            Address next = in.getMaxAddress().next();
            if (ft.isCall()) {
                if (next != null) work.add(next);
                continue;
            }
            if (ft.isJump()) {
                for (Address t : in.getFlows())
                    if (!t.equals(f.getEntryPoint()) && fm.getFunctionAt(t) != null) { /* tail call */ }
                    else work.add(t);
                if (ft.isComputed())
                    for (Reference r : in.getReferencesFrom())
                        if (r.getReferenceType().isFlow()) work.add(r.getToAddress());
                if (ft.isConditional() && next != null) work.add(next);
                continue;
            }
            if (ft.isTerminal()) continue;
            if (next != null) work.add(next);
        }
        return new ArrayList<>(seen.values());
    }

    @Override
    public void run() throws Exception {
        String[] args = getScriptArgs();
        if (args.length < 2) {
            throw new IllegalArgumentException("Expected <symbols_dir> <out.jsonl>");
        }
        File symDir = new File(args[0]);
        File out = new File(args[1]);

        List<Long> entries = new ArrayList<>();
        Map<Long, String> names = new HashMap<>();
        AddressSet seeds = new AddressSet();

        try (BufferedReader br = Files.newBufferedReader(new File(symDir, "functions.tsv").toPath())) {
            String line = br.readLine(); // header
            while ((line = br.readLine()) != null) {
                if (line.isEmpty()) continue;
                String[] parts = line.split("\t", 2);
                long addr = Long.parseUnsignedLong(parts[0], 16);
                String name = parts.length > 1 ? parts[1] : String.format("FUN_%08x", addr);
                entries.add(addr);
                names.put(addr, name);
                seeds.add(toAddr(addr));
            }
        }

        List<long[]> jtables = new ArrayList<>();
        File jtFile = new File(symDir, "jumptables.tsv");
        if (jtFile.isFile()) {
            try (BufferedReader br = Files.newBufferedReader(jtFile.toPath())) {
                String line = br.readLine(); // header
                while ((line = br.readLine()) != null) {
                    if (line.isEmpty()) continue;
                    String[] parts = line.split("\t", 2);
                    if (parts.length < 2 || parts[1].isEmpty()) continue;
                    long jmp = Long.parseUnsignedLong(parts[0], 16);
                    String[] tstrs = parts[1].split(",");
                    long[] row = new long[1 + tstrs.length];
                    row[0] = jmp;
                    for (int i = 0; i < tstrs.length; i++) {
                        long t = Long.parseUnsignedLong(tstrs[i], 16);
                        row[1 + i] = t;
                        seeds.add(toAddr(t));
                    }
                    jtables.add(row);
                }
            }
        }

        // Disassemble all precomputed roots in a single batch (follow flow = true)
        DisassembleCommand disasm = new DisassembleCommand(seeds, null, true);
        disasm.applyTo(currentProgram, monitor);

        FunctionManager fm = currentProgram.getFunctionManager();
        for (long addr : entries) {
            Address a = toAddr(addr);
            if (fm.getFunctionAt(a) == null) {
                try {
                    fm.createFunction(names.get(addr), a, new AddressSet(a), SourceType.USER_DEFINED);
                } catch (Exception ignored) {}
            }
        }

        ReferenceManager rm = currentProgram.getReferenceManager();
        for (long[] row : jtables) {
            Address jmp = toAddr(row[0]);
            for (int i = 1; i < row.length; i++) {
                rm.addMemoryReference(jmp, toAddr(row[i]), RefType.COMPUTED_JUMP, SourceType.USER_DEFINED, 0);
            }
        }

        int written = 0, scanned = 0;
        try (PrintWriter w = new PrintWriter(new BufferedWriter(new OutputStreamWriter(
                new FileOutputStream(out), "UTF-8")))) {
            for (Function f : fm.getFunctions(true)) {
                if (monitor.isCancelled()) break;
                if (f.isExternal()) continue;
                scanned++;
                StringBuilder sb = new StringBuilder();
                boolean leaf = true;
                TreeSet<Long> callees = new TreeSet<>();
                sb.append("{\"entry\":").append(f.getEntryPoint().getOffset())
                  .append(",\"name\":\"").append(f.getName().replace("\"", "")).append("\",\"insns\":[");
                boolean first = true;
                for (Instruction in : flowBody(f)) {
                    FlowType ft = in.getFlowType();
                    if (ft.isCall()) {
                        leaf = false;
                        for (Address a : in.getFlows()) callees.add(a.getOffset());
                    }
                    if (ft.isJump() && ft.isComputed()) {
                        boolean resolved = false;
                        for (Reference r : in.getReferencesFrom())
                            if (r.getReferenceType().isFlow()) resolved = true;
                        if (!resolved) leaf = false;
                    }
                    if (!first) sb.append(',');
                    first = false;
                    sb.append("{\"a\":").append(in.getAddress().getOffset())
                      .append(",\"len\":").append(in.getLength())
                      .append(",\"m\":\"").append(in.toString().replace("\\", "\\\\").replace("\"", "'"))
                      .append("\"");
                    if (ft.isJump() && ft.isComputed()) {
                        sb.append(",\"targets\":[");
                        boolean f2 = true;
                        for (Reference r : in.getReferencesFrom()) {
                            if (!r.getReferenceType().isFlow()) continue;
                            if (!f2) sb.append(',');
                            f2 = false;
                            sb.append(r.getToAddress().getOffset());
                        }
                        sb.append("]");
                    }
                    sb.append(",\"ops\":[");
                    PcodeOp[] ops = in.getPcode();
                    for (int i = 0; i < ops.length; i++) {
                        PcodeOp op = ops[i];
                        if (i > 0) sb.append(',');
                        sb.append("[\"").append(op.getMnemonic()).append("\",").append(vn(op.getOutput())).append(",[");
                        for (int j = 0; j < op.getNumInputs(); j++) {
                            if (j > 0) sb.append(',');
                            sb.append(vn(op.getInput(j)));
                        }
                        sb.append("]]");
                    }
                    sb.append("]}");
                }
                sb.append("],\"callees\":").append(callees.toString().replace(" ", ""))
                  .append(",\"leaf\":").append(leaf).append('}');
                w.println(sb);
                written++;
            }
        }

        try (PrintWriter w = new PrintWriter(new File(out.getPath() + ".regs.json"), "UTF-8")) {
            w.print("{");
            boolean first = true;
            for (Register r : currentProgram.getLanguage().getRegisters()) {
                if (r.isProcessorContext()) continue;
                if (!first) w.print(',');
                first = false;
                w.print("\"" + r.getName() + "\":[" + r.getOffset() + "," + r.getMinimumByteSize() + "]");
            }
            w.print("}");
        }
        try (PrintWriter w = new PrintWriter(new File(out.getPath() + ".userops.json"), "UTF-8")) {
            ghidra.program.model.lang.Language lang = currentProgram.getLanguage();
            w.print("[");
            for (int i = 0; i < lang.getNumberOfUserDefinedOpNames(); i++) {
                if (i > 0) w.print(',');
                w.print("\"" + lang.getUserDefinedOpName(i) + "\"");
            }
            w.print("]");
        }
        println(String.format("ApplyMetadataAndDump: scanned %d functions, wrote %d -> %s", scanned, written, out));
    }
}
