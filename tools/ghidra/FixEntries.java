// Finds code entry points that auto-analysis missed, so the recompiler's dispatch table is complete.
//
//  1. Every aligned dword in the initialised non-executable blocks (vtables, callback tables,
//     jump tables) and every CALL target that points into an executable block is a candidate.
//  2. A candidate with no instruction is disassembled; one in no function gets a new function.
//  3. A candidate that lands *inside* an existing function (hand-written CRT code has secondary
//     entry points) is recorded as an extra entry of that function.
//
// Writes <out>/extra_entries.json: {"<func entry>": [extra entry, ...]} and prints counts.
// Run WITHOUT -readOnly so new functions are saved.
//@category BYOG

import java.io.*;
import java.util.*;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.cmd.function.CreateFunctionCmd;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.symbol.*;

public class FixEntries extends GhidraScript {

    private String codeBlock = ".text";   // 2nd script arg overrides; packer stubs (.bind) are excluded

    private boolean inExec(Address a) {
        MemoryBlock b = currentProgram.getMemory().getBlock(a);
        return b != null && b.isExecute() && b.isInitialized() && b.getName().equals(codeBlock);
    }

    private static Set<Long> loadPeRelocLocs(Memory mem, Address base) {
        Set<Long> locs = new HashSet<>();
        try {
            int peOff = mem.getInt(base.add(0x3c));
            Address pe = base.add(peOff);
            if (mem.getInt(pe) != 0x00004550) return locs;
            int optOff = peOff + 24;
            if ((mem.getShort(base.add(optOff)) & 0xffff) != 0x010b) return locs;
            if ((mem.getInt(base.add(optOff + 92)) & 0xffffffffL) <= 5) return locs;
            long relocRva = mem.getInt(base.add(optOff + 96 + 8 * 5)) & 0xffffffffL;
            long relocSize = mem.getInt(base.add(optOff + 96 + 8 * 5 + 4)) & 0xffffffffL;
            if (relocRva == 0 || relocSize == 0) return locs;
            Address cur = base.add(relocRva), end = cur.add(relocSize);
            long imageBase = base.getOffset();
            while (cur.compareTo(end) < 0 && mem.contains(cur.add(7))) {
                long pageRva = mem.getInt(cur) & 0xffffffffL;
                long blkSize = mem.getInt(cur.add(4)) & 0xffffffffL;
                if (blkSize < 8) break;
                int count = (int) ((blkSize - 8) / 2);
                for (int i = 0; i < count; i++) {
                    int entry = mem.getShort(cur.add(8 + 2L * i)) & 0xffff;
                    if ((entry >>> 12) == 3) locs.add(imageBase + pageRva + (entry & 0xfff));
                }
                cur = cur.add(blkSize);
            }
        } catch (Exception ignored) {}
        return locs;
    }

    @Override
    public void run() throws Exception {
        File outDir = new File(getScriptArgs().length > 0 ? getScriptArgs()[0] : ".");
        if (getScriptArgs().length > 1) codeBlock = getScriptArgs()[1];
        Memory mem = currentProgram.getMemory();
        Listing listing = currentProgram.getListing();
        FunctionManager fm = currentProgram.getFunctionManager();
        AddressSpace space = currentProgram.getAddressFactory().getDefaultAddressSpace();
        Set<Long> relocLocs = loadPeRelocLocs(mem, currentProgram.getImageBase());

        TreeSet<Address> cands = new TreeSet<>();
        for (MemoryBlock b : mem.getBlocks()) {
            if (b.isExecute() || !b.isInitialized()) continue;
            byte[] buf = new byte[(int) b.getSize()];
            b.getBytes(b.getStart(), buf);
            long blkStart = b.getStart().getOffset();
            for (int i = 0; i + 4 <= buf.length; i += 4) {
                if (!relocLocs.isEmpty() && !relocLocs.contains(blkStart + i)) continue;
                long v = (buf[i] & 0xffL) | (buf[i + 1] & 0xffL) << 8 | (buf[i + 2] & 0xffL) << 16 | (buf[i + 3] & 0xffL) << 24;
                Address a = space.getAddress(v, true);
                if (a != null && inExec(a) && !relocLocs.contains(v)) cands.add(a);
            }
        }
        int dataPtrs = cands.size();
        // addresses the runtime had to interpret (fnvhost's fallback_entries.txt) are entries by proof
        int learned = 0;
        if (getScriptArgs().length > 2) {
            for (String line : java.nio.file.Files.readAllLines(new File(getScriptArgs()[2]).toPath())) {
                line = line.trim();
                if (line.isEmpty()) continue;
                Address a = space.getAddress(Long.decode(line), true);
                if (a != null && inExec(a) && cands.add(a)) learned++;
            }
            println("FixEntries: " + learned + " learned entries from " + getScriptArgs()[2]);
        }
        int imm = 0;
        for (Instruction in : listing.getInstructions(true)) {
            if (in.getFlowType().isCall())
                for (Address a : in.getFlows()) if (inExec(a)) cands.add(a);
            if (!relocLocs.isEmpty()) {
                if (in.getFlowType().isJump() && in.getFlowType().isComputed()) continue; // jump table base is data, cases handled by ResolveJumpTables
                long lo = in.getMinAddress().getOffset(), hi = in.getMaxAddress().getOffset();
                for (long r = lo; r + 3 <= hi; r++) {
                    if (!relocLocs.contains(r)) continue;
                    long v = mem.getInt(space.getAddress(r, true)) & 0xffffffffL;
                    if (relocLocs.contains(v)) continue;
                    Address a = space.getAddress(v, true);
                    if (a != null && inExec(a) && cands.add(a)) imm++;
                }
            } else {
                // fallback for binaries without .reloc: scan scalar immediates
                for (int op = 0; op < in.getNumOperands(); op++) {
                    for (Object o : in.getOpObjects(op)) {
                        if (!(o instanceof ghidra.program.model.scalar.Scalar)) continue;
                        long v = ((ghidra.program.model.scalar.Scalar) o).getUnsignedValue();
                        Address a = space.getAddress(v, true);
                        if (a != null && inExec(a) && cands.add(a)) imm++;
                    }
                }
            }
        }
        println("FixEntries: " + imm + " immediate code-address candidates");
        println("FixEntries: " + dataPtrs + " data-pointer candidates, " + cands.size() + " total");

        int disasm = 0, created = 0, extra = 0, skipped = 0;
        TreeMap<Long, TreeSet<Long>> extras = new TreeMap<>();
        for (Address a : cands) {
            if (monitor.isCancelled()) break;
            if (fm.getFunctionAt(a) != null) continue;
            Data d = listing.getDefinedDataContaining(a);
            if (d != null) { skipped++; continue; }           // pointer into data that lives in .text
            if (listing.getInstructionAt(a) == null) {
                if (listing.getInstructionContaining(a) != null) { skipped++; continue; }  // mid-instruction
                DisassembleCommand cmd = new DisassembleCommand(a, null, true);
                if (!cmd.applyTo(currentProgram, monitor) || listing.getInstructionAt(a) == null) { skipped++; continue; }
                disasm++;
            }
            Function owner = fm.getFunctionContaining(a);
            if (owner == null) {
                CreateFunctionCmd cf = new CreateFunctionCmd(a);
                if (cf.applyTo(currentProgram, monitor)) created++; else skipped++;
            } else {
                extras.computeIfAbsent(owner.getEntryPoint().getOffset(), k -> new TreeSet<>()).add(a.getOffset());
                extra++;
            }
        }
        try (PrintWriter w = new PrintWriter(new File(outDir, "extra_entries.json"), "UTF-8")) {
            w.print("{");
            boolean first = true;
            for (Map.Entry<Long, TreeSet<Long>> e : extras.entrySet()) {
                if (!first) w.print(',');
                first = false;
                w.print("\"" + e.getKey() + "\":" + e.getValue().toString().replace(" ", ""));
            }
            w.print("}");
        }
        println(String.format("FixEntries: disassembled %d, created %d functions, %d extra entries in %d functions, skipped %d",
            disasm, created, extra, extras.size(), skipped));
    }
}
