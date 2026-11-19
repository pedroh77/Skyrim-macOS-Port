// Resolves switch jump tables that auto-analysis left as unresolved computed jumps:
//   JMP dword ptr [reg*4 + TABLE]
// Table entries are read while they point into the code block near the jump; each entry becomes a
// COMPUTED_JUMP flow reference from the JMP (so flow-based bodies include every case) and is
// disassembled. Run WITHOUT -readOnly; follow with FixEntries/DumpPcode.
//@category BYOG

import java.util.*;

import ghidra.app.cmd.disassemble.DisassembleCommand;
import ghidra.app.script.GhidraScript;
import ghidra.program.model.address.*;
import ghidra.program.model.lang.OperandType;
import ghidra.program.model.listing.*;
import ghidra.program.model.mem.*;
import ghidra.program.model.scalar.Scalar;
import ghidra.program.model.symbol.*;

public class ResolveJumpTables extends GhidraScript {
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
        Listing listing = currentProgram.getListing();
        Memory mem = currentProgram.getMemory();
        ReferenceManager rm = currentProgram.getReferenceManager();
        MemoryBlock text = mem.getBlock(".text");
        Set<Long> relocLocs = loadPeRelocLocs(mem, currentProgram.getImageBase());
        int jumps = 0, resolved = 0, targets = 0;
        List<Instruction> todo = new ArrayList<>();
        // every computed jump, including ones analysis resolved only partially (e.g. 1 of 23 cases)
        for (Instruction in : listing.getInstructions(true)) {
            FlowType ft = in.getFlowType();
            if (ft.isJump() && ft.isComputed() && !ft.isCall()) todo.add(in);
        }
        for (Instruction in : todo) {
            jumps++;
            if (!in.getMnemonicString().equalsIgnoreCase("JMP")) continue;
            int t = in.getOperandType(0);
            if ((t & OperandType.DYNAMIC) == 0) continue;           // need a memory operand
            long disp = -1; int scale = 0;
            for (Object o : in.getOpObjects(0)) {
                if (o instanceof Scalar) {
                    long v = ((Scalar) o).getUnsignedValue();
                    if (v == 4) scale = 4; else if (v > 0x400000) disp = v;
                }
            }
            if (disp < 0 || scale != 4) continue;
            Address table = toAddr(disp);
            if (!mem.contains(table)) continue;
            // table size from the bounds check: CMP idx, N ; JA default  ->  N + 1 entries
            int bound = -1;
            Instruction p = in.getPrevious();
            for (int k = 0; k < 4 && p != null && bound < 0; k++, p = p.getPrevious()) {
                if (p.getMnemonicString().equalsIgnoreCase("CMP") && p.getNumOperands() == 2)
                    for (Object o : p.getOpObjects(1)) if (o instanceof Scalar) bound = (int) ((Scalar) o).getUnsignedValue() + 1;
            }
            Set<Address> found = new LinkedHashSet<>();
            Set<Address> have = new HashSet<>();
            for (Reference r : in.getReferencesFrom()) if (r.getReferenceType().isFlow()) have.add(r.getToAddress());
            int limit = bound > 0 && bound <= 4096 ? bound : 1024;
            long jmpOff = in.getAddress().getOffset();
            int startIdx = 0;
            if (!relocLocs.isEmpty() && !relocLocs.contains(table.getOffset()) && relocLocs.contains(table.add(4).getOffset())) {
                startIdx = 1; // 1-based jump table (e.g. MSVC CRT aligned-tail switch)
            }
            for (int i = startIdx; i < limit; i++) {
                Address e = table.add(4L * i);
                if (!mem.contains(e)) break;
                if (!relocLocs.isEmpty() && !relocLocs.contains(e.getOffset())) break;
                long v = mem.getInt(e) & 0xffffffffL;
                Address a = toAddr(v);
                if (!text.contains(a)) break;
                if (bound < 0 && Math.abs(v - jmpOff) > 0x40000) break;   // unbounded: cases live near their switch
                if (relocLocs.isEmpty() && bound < 0 && listing.getDefinedDataContaining(a) != null) break;
                found.add(a);
            }
            if (!relocLocs.isEmpty()) {
                // Negative-indexed jump tables (e.g. MSVC CRT memmove [ecx*4 + table] with ecx in -7..-1)
                for (int i = -1; i >= -64; i--) {
                    Address e = table.add(4L * i);
                    if (!mem.contains(e) || !relocLocs.contains(e.getOffset())) break;
                    long v = mem.getInt(e) & 0xffffffffL;
                    Address a = toAddr(v);
                    if (!text.contains(a)) break;
                    if (Math.abs(v - jmpOff) > 0x40000) break;
                    found.add(a);
                }
            }
            if (found.isEmpty()) continue;
            found.removeAll(have);
            if (found.isEmpty()) continue;
            for (Address a : found) {
                Data d = listing.getDefinedDataContaining(a);
                if (d != null) listing.clearCodeUnits(d.getMinAddress(), d.getMaxAddress(), false);
                if (listing.getInstructionAt(a) == null) new DisassembleCommand(a, null, true).applyTo(currentProgram, monitor);
                if (listing.getInstructionAt(a) == null) continue;
                rm.addMemoryReference(in.getAddress(), a, RefType.COMPUTED_JUMP, SourceType.ANALYSIS, 0);
                targets++;
            }
            resolved++;
        }
        println(String.format("ResolveJumpTables: %d unresolved computed jumps, resolved %d tables, %d case targets", jumps, resolved, targets));
    }
}
