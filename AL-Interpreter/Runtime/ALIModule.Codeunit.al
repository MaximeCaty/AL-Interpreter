// ALI Module — the executable artifact (§7.3): typed register bytecode, per-type const
// pools (deduplicated), proc table, debug map.
//
// Built by the Lowerer via List columns (compile-time, growable, §3.2); the Interpreter
// SEALS these columns into its own fixed arrays at LoadModule (the List->array copy is
// the one-time "sealing" §3.2 describes — the hot loop never touches a List).
//
// Instruction format: four parallel int columns Op/A/B/C, 1-based PC. Jump operands are
// absolute 1-based instruction indices, patched by the Lowerer (PatchA). CONCAT_N reads
// its text-register operands from the OPERAND POOL (B = 1-based start, C = count).
// The DEBUG MAP holds (line, column) per statement boundary; every instruction carries its
// statement's row in InstrDbgRow (parallel column), so runtime errors resolve to source
// positions from the failing PC without the token table (§7.4/§9) — no STMT opcode needed.
//
// Proc table (M5, §7.3): one row per procedure — entry PC, per-register-class register
// counts (classes per "ALI Type Rules" RegClass*), result class/slot/type, param
// descriptors. Module-level vars occupy ABSOLUTE slots 1..GlobalCount(cls) below every
// frame window. Legacy single-proc getters delegate to the entry proc's row.
codeunit 51114 "ALI Module"
{
    Access = Public;
    SingleInstance = false;

    var
        Overflow: Boolean;
        BigMap: Dictionary of [BigInteger, Integer];
        DateMap: Dictionary of [Date, Integer];
        DTMap: Dictionary of [DateTime, Integer];
        DecMap: Dictionary of [Decimal, Integer];
        IntMap: Dictionary of [Integer, Integer];
        TextMap: Dictionary of [Text, Integer];
        TimeMap: Dictionary of [Time, Integer];
        CurDbgRowVal: Integer;
        EntryProcIdVal: Integer;                // which proc Run() starts in (default 1)
        GlobalCnt: array[13] of Integer;        // module-level var slots per class (absolute 1..N)
        MaxInstrCache: Integer;                 // "ALI Limits".MaxInstructions(), cached at Reset (hot: read per AddInstr)
        ConstBigPool: List of [BigInteger];
        ConstDatePool: List of [Date];
        ConstDTPool: List of [DateTime];
        ConstDecPool: List of [Decimal];
        ACol: List of [Integer];
        BCol: List of [Integer];
        CCol: List of [Integer];

        // --- Const pools (1-based, deduplicated) ---
        ConstIntPool: List of [Integer];
        DebugColCol: List of [Integer];

        // --- Debug map (1-based row; instructions point here via InstrDbgRow) ---
        DebugLineCol: List of [Integer];
        // M11 phase B2: absolute base of instance i's globals block per register class, packed
        // i*16 + class. An object global's absolute slot = this base + the offset carried by the
        // SELF_* instruction. Index 0 is unused (0 = "no instance").
        InstBaseList: List of [Integer];
        // Per-instruction debug row (parallel to Op/A/B/C): the debug-map row of the source
        // statement each instruction belongs to (0 = none). Replaces the former STMT opcode —
        // runtime errors resolve source positions from the FAILING PC directly (P1).
        InstrDbgRow: List of [Integer];
        // --- Instruction columns (1-based PC) ---
        OpCol: List of [Integer];

        // --- CONCAT_N operand pool (text register indices) ---
        OperandPool: List of [Integer];

        // --- Proc table (M5, §7.3): one row per procedure ---
        // Parallel lists, 1-based ProcId. Per-class register counts are flattened:
        // ProcRegCnt[(ProcId-1)*11 + RegClass]. Param descriptors (type class, slot,
        // var-flag) are kept for disassembly/serialization; the RUNTIME calling convention
        // encodes staging in ARG_VAL/ARG_REF instructions, so the interpreter only seals
        // entry PC + reg counts + result info.
        ProcEntryList: List of [Integer];
        ProcParamClass: List of [Integer];
        ProcParamOwner: List of [Integer];      // param descriptor rows (informational)
        ProcParamSlot: List of [Integer];
        ProcParamVar: List of [Integer];
        ProcRegCnt: List of [Integer];
        ProcResClassList: List of [Integer];    // 0 = no result
        ProcResSlotList: List of [Integer];     // frame-relative
        ProcResTypeList: List of [Integer];     // "ALI TypeKind" ordinal
        // M11 phase B2: frame-relative Int slot of a harvested procedure's hidden instance-index
        // parameter (0 = the procedure has none, i.e. it never touches object globals). SELF_LOAD
        // / SELF_STORE read it to find which instance's block of globals this frame is running on.
        ProcSelfSlotList: List of [Integer];
        ConstTextPool: List of [Text];
        ConstTimePool: List of [Time];

    // ===== Lifecycle =====

    procedure Reset()
    var
        Limits: Codeunit "ALI Limits";
    begin
        MaxInstrCache := Limits.MaxInstructions();
        Clear(OpCol);
        Clear(ACol);
        Clear(BCol);
        Clear(CCol);
        Overflow := false;
        Clear(ConstIntPool);
        Clear(ConstBigPool);
        Clear(ConstDecPool);
        Clear(ConstTextPool);
        Clear(ConstDatePool);
        Clear(ConstTimePool);
        Clear(ConstDTPool);
        Clear(IntMap);
        Clear(BigMap);
        Clear(DecMap);
        Clear(TextMap);
        Clear(DateMap);
        Clear(TimeMap);
        Clear(DTMap);
        Clear(OperandPool);
        Clear(DebugLineCol);
        Clear(DebugColCol);
        Clear(InstrDbgRow);
        CurDbgRowVal := 0;
        Clear(ProcEntryList);
        Clear(ProcRegCnt);
        Clear(ProcResClassList);
        Clear(ProcResSlotList);
        Clear(ProcResTypeList);
        Clear(ProcSelfSlotList);
        Clear(InstBaseList);
        Clear(ProcParamOwner);
        Clear(ProcParamClass);
        Clear(ProcParamSlot);
        Clear(ProcParamVar);
        EntryProcIdVal := 1;
        Clear(GlobalCnt);
    end;

    // ===== Instruction building =====

    // Append an instruction; returns its PC (0 when the module is full — the caller
    // reports one clean "program too large" diagnostic via Overflowed()).
    procedure AddInstr(Op: Integer; A: Integer; B: Integer; C: Integer): Integer
    begin
        if OpCol.Count() >= MaxInstrCache then begin
            Overflow := true;
            exit(0);
        end;
        OpCol.Add(Op);
        ACol.Add(A);
        BCol.Add(B);
        CCol.Add(C);
        InstrDbgRow.Add(CurDbgRowVal);
        exit(OpCol.Count());
    end;

    // Remove the just-emitted instruction (fusion only: the caller folds it into the next
    // emit — never call once any label could point past it).
    procedure RemoveLastInstr()
    begin
        if OpCol.Count() = 0 then
            exit;
        OpCol.RemoveAt(OpCol.Count());
        ACol.RemoveAt(ACol.Count());
        BCol.RemoveAt(BCol.Count());
        CCol.RemoveAt(CCol.Count());
        InstrDbgRow.RemoveAt(InstrDbgRow.Count());
    end;

    procedure Overflowed(): Boolean
    begin
        exit(Overflow);
    end;

    // Next PC to be emitted (= current count + 1) — used for jump-target bookkeeping.
    procedure NextPC(): Integer
    begin
        exit(OpCol.Count() + 1);
    end;

    procedure InstrCount(): Integer
    begin
        exit(OpCol.Count());
    end;

    // Patch a jump target (A operand) after the target PC becomes known.
    procedure PatchA(PC: Integer; Value: Integer)
    begin
        if (PC >= 1) and (PC <= ACol.Count()) then
            ACol.Set(PC, Value);
    end;

    // Patch the C operand (FOR_INIT loop-exit target).
    procedure PatchC(PC: Integer; Value: Integer)
    begin
        if (PC >= 1) and (PC <= CCol.Count()) then
            CCol.Set(PC, Value);
    end;

    // Rewrite an instruction's opcode in place (branch fusion + back-edge classification).
    procedure PatchOp(PC: Integer; Op: Integer)
    begin
        if (PC >= 1) and (PC <= OpCol.Count()) then
            OpCol.Set(PC, Op);
    end;

    // Bulk column access for "ALI Interpreter".LoadModule's sealing loop. `List of [T]` is a
    // reference type in AL, so these hand over the column itself — no copy — and the interpreter
    // iterates it locally into its fixed arrays. Read-only on the interpreter side.
    // Sealing used to call GetOp/GetA/GetB/GetC/GetInstrDebugRow per instruction: 5N
    // cross-codeunit calls at ~450ns, i.e. ~1ms per 450 instructions before a run even starts.
    procedure GetInstrColumns(var Op: List of [Integer]; var A: List of [Integer]; var B: List of [Integer]; var C: List of [Integer]; var DbgRow: List of [Integer])
    begin
        Op := OpCol;
        A := ACol;
        B := BCol;
        C := CCol;
        DbgRow := InstrDbgRow;
    end;

    // Peephole helpers used by the lowerer's emit path. Both used to be written there as a
    // sequence of InstrCount/GetOp/GetA/GetB/PatchOp/PatchA/GetConstInt/RemoveLastInstr calls —
    // 5 to 7 cross-codeunit calls per conditional branch or per integer comparison. Owning the
    // columns, each is one call.

    // Fuse a preceding CMP_*_I / CMP_*_I_IMM into a branch-compare, rewriting it in place.
    // Returns the rewritten PC, or 0 when the previous instruction is not a fusable compare on
    // CondReg (caller then emits a plain JMP_IF_TRUE/FALSE).
    procedure TryFuseCondBranch(BranchIfTrue: Boolean; CondReg: Integer): Integer
    var
        LastOp: Integer;
        LastPC: Integer;
        NewOp: Integer;
    begin
        LastPC := OpCol.Count();
        if LastPC < 1 then
            exit(0);
        LastOp := OpCol.Get(LastPC);
        NewOp := 0;
        if (LastOp >= 96) and (LastOp <= 101) then          // CMP_EQ_I..CMP_GE_I
            NewOp := 379 + (LastOp - 96);                    // BF_xx_I
        if (LastOp >= 429) and (LastOp <= 434) then         // CMP_xx_I_IMM
            NewOp := 391 + (LastOp - 429);                   // BF_xx_I_IMM
        if NewOp = 0 then
            exit(0);
        if ACol.Get(LastPC) <> CondReg then
            exit(0);
        if BranchIfTrue then
            NewOp += 6;                                      // BF block -> BT block
        OpCol.Set(LastPC, NewOp);
        ACol.Set(LastPC, 0);                                 // target placeholder
        exit(LastPC);
    end;

    // If the previous instruction is a LOAD_CONST_I into Reg, drop it and return its constant.
    // Returns false and leaves ImmVal untouched otherwise.
    procedure TryTakeLastConstInt(Reg: Integer; var ImmVal: Integer): Boolean
    var
        LastPC: Integer;
    begin
        LastPC := OpCol.Count();
        if LastPC < 1 then
            exit(false);
        if OpCol.Get(LastPC) <> 43 then                      // LOAD_CONST_I
            exit(false);
        if ACol.Get(LastPC) <> Reg then
            exit(false);
        ImmVal := ConstIntPool.Get(BCol.Get(LastPC));
        RemoveLastInstr();
        exit(true);
    end;

    // Rewrite every BACKWARD jump to its budget-charged twin (§7.4 / P1: the runaway statement
    // budget is charged at back-edges and CALLs only). Jump families: 2..4 (unconditional +
    // cond) map to +374, 379..402 (fused branch-compares) map to +24.
    //
    // Lives here rather than in the lowerer because it is a whole-module linear pass: as a
    // lowerer loop it cost GetOp + GetA + PatchOp — up to 3 cross-codeunit calls per
    // instruction, so 3N calls at ~450ns each on a program of N instructions. Owning the
    // columns, it is one call and plain List access.
    procedure ClassifyBackEdges()
    var
        i: Integer;
        N: Integer;
        Op: Integer;
        Target: Integer;
    begin
        N := OpCol.Count();
        for i := 1 to N do begin
            Op := OpCol.Get(i);
            if ((Op >= 2) and (Op <= 4)) or ((Op >= 379) and (Op <= 402)) then begin
                Target := ACol.Get(i);
                if (Target >= 1) and (Target <= i) then
                    if Op <= 4 then
                        OpCol.Set(i, Op + 374)
                    else
                        OpCol.Set(i, Op + 24);
            end;
        end;
    end;

    // ===== Instruction getters (sealing + disassembly) =====

    procedure GetOp(PC: Integer): Integer
    begin
        exit(OpCol.Get(PC));
    end;

    procedure GetA(PC: Integer): Integer
    begin
        exit(ACol.Get(PC));
    end;

    procedure GetB(PC: Integer): Integer
    begin
        exit(BCol.Get(PC));
    end;

    procedure GetC(PC: Integer): Integer
    begin
        exit(CCol.Get(PC));
    end;

    // ===== Const pools (deduplicated adders return the 1-based pool index) =====

    procedure AddConstInt(V: Integer): Integer
    var
        Idx: Integer;
    begin
        if IntMap.Get(V, Idx) then
            exit(Idx);
        ConstIntPool.Add(V);
        Idx := ConstIntPool.Count();
        IntMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstBig(V: BigInteger): Integer
    var
        Idx: Integer;
    begin
        if BigMap.Get(V, Idx) then
            exit(Idx);
        ConstBigPool.Add(V);
        Idx := ConstBigPool.Count();
        BigMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstDec(V: Decimal): Integer
    var
        Idx: Integer;
    begin
        if DecMap.Get(V, Idx) then
            exit(Idx);
        ConstDecPool.Add(V);
        Idx := ConstDecPool.Count();
        DecMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstText(V: Text): Integer
    var
        Idx: Integer;
    begin
        if TextMap.Get(V, Idx) then
            exit(Idx);
        ConstTextPool.Add(V);
        Idx := ConstTextPool.Count();
        TextMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstDate(V: Date): Integer
    var
        Idx: Integer;
    begin
        if DateMap.Get(V, Idx) then
            exit(Idx);
        ConstDatePool.Add(V);
        Idx := ConstDatePool.Count();
        DateMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstTime(V: Time): Integer
    var
        Idx: Integer;
    begin
        if TimeMap.Get(V, Idx) then
            exit(Idx);
        ConstTimePool.Add(V);
        Idx := ConstTimePool.Count();
        TimeMap.Set(V, Idx);
        exit(Idx);
    end;

    procedure AddConstDT(V: DateTime): Integer
    var
        Idx: Integer;
    begin
        if DTMap.Get(V, Idx) then
            exit(Idx);
        ConstDTPool.Add(V);
        Idx := ConstDTPool.Count();
        DTMap.Set(V, Idx);
        exit(Idx);
    end;

    // --- Const pool getters ---

    procedure ConstIntCount(): Integer
    begin
        exit(ConstIntPool.Count());
    end;

    procedure GetConstInt(Idx: Integer): Integer
    begin
        exit(ConstIntPool.Get(Idx));
    end;

    procedure ConstBigCount(): Integer
    begin
        exit(ConstBigPool.Count());
    end;

    procedure GetConstBig(Idx: Integer): BigInteger
    begin
        exit(ConstBigPool.Get(Idx));
    end;

    procedure ConstDecCount(): Integer
    begin
        exit(ConstDecPool.Count());
    end;

    procedure GetConstDec(Idx: Integer): Decimal
    begin
        exit(ConstDecPool.Get(Idx));
    end;

    procedure ConstTextCount(): Integer
    begin
        exit(ConstTextPool.Count());
    end;

    procedure GetConstText(Idx: Integer): Text
    begin
        exit(ConstTextPool.Get(Idx));
    end;

    procedure ConstDateCount(): Integer
    begin
        exit(ConstDatePool.Count());
    end;

    procedure GetConstDate(Idx: Integer): Date
    begin
        exit(ConstDatePool.Get(Idx));
    end;

    procedure ConstTimeCount(): Integer
    begin
        exit(ConstTimePool.Count());
    end;

    procedure GetConstTime(Idx: Integer): Time
    begin
        exit(ConstTimePool.Get(Idx));
    end;

    procedure ConstDTCount(): Integer
    begin
        exit(ConstDTPool.Count());
    end;

    procedure GetConstDT(Idx: Integer): DateTime
    begin
        exit(ConstDTPool.Get(Idx));
    end;

    // ===== CONCAT_N operand pool =====

    // Append one operand (a text register index); returns its 1-based pool position.
    procedure AddOperand(TextReg: Integer): Integer
    begin
        OperandPool.Add(TextReg);
        exit(OperandPool.Count());
    end;

    procedure OperandCount(): Integer
    begin
        exit(OperandPool.Count());
    end;

    procedure GetOperand(Idx: Integer): Integer
    begin
        exit(OperandPool.Get(Idx));
    end;

    // ===== Debug map (statement boundary -> source line/column, §7.3/§9) =====

    procedure AddDebugRow(LineNo: Integer; ColumnNo: Integer): Integer
    begin
        DebugLineCol.Add(LineNo);
        DebugColCol.Add(ColumnNo);
        exit(DebugLineCol.Count());
    end;

    // Set the debug row stamped onto every subsequently emitted instruction (P1: replaces
    // the former STMT boundary instruction — called by the lowerer's statement marker).
    procedure SetDebugRow(Row: Integer)
    begin
        CurDbgRowVal := Row;
    end;

    // Append a debug row and make it current — the only way the lowerer ever uses the pair, and
    // it does so once per statement. Saves one of the two cross-codeunit calls.
    procedure AddAndSetDebugRow(LineNo: Integer; ColumnNo: Integer)
    begin
        DebugLineCol.Add(LineNo);
        DebugColCol.Add(ColumnNo);
        CurDbgRowVal := DebugLineCol.Count();
    end;

    procedure GetInstrDebugRow(PC: Integer): Integer
    begin
        exit(InstrDbgRow.Get(PC));
    end;

    procedure DebugCount(): Integer
    begin
        exit(DebugLineCol.Count());
    end;

    procedure GetDebugLine(Row: Integer): Integer
    begin
        exit(DebugLineCol.Get(Row));
    end;

    procedure GetDebugColumn(Row: Integer): Integer
    begin
        exit(DebugColCol.Get(Row));
    end;

    // Both debug columns by reference in one call, mirroring GetInstrColumns. The interpreter
    // aliases them instead of copying every row into a fixed array — the map is read only when
    // a run fails, so it never needs the array's indexing speed.
    procedure GetDebugColumns(var Line: List of [Integer]; var Col: List of [Integer])
    begin
        Line := DebugLineCol;
        Col := DebugColCol;
    end;

    // ===== Proc table (M5, §7.3) =====

    // Append a proc-table row with defaults; returns the 1-based ProcId.
    procedure AddProc(): Integer
    var
        i: Integer;
    begin
        // 0 = "row reserved, body never lowered". It used to default to 1, which is a VALID pc —
        // so a call to a procedure whose body never got lowered (a signatures-only harvest, a
        // procedure the reachability worklist never reached) jumped to the module's first
        // instruction instead of failing, and ran whatever happened to be lowered there. The
        // interpreter's CALL now rejects 0; every real lowering overwrites it via SetProcEntryPC.
        ProcEntryList.Add(0);
        ProcResClassList.Add(0);
        ProcResSlotList.Add(0);
        ProcResTypeList.Add(0);
        ProcSelfSlotList.Add(0);
        for i := 1 to 13 do
            ProcRegCnt.Add(0);
        exit(ProcEntryList.Count());
    end;

    procedure ProcCount(): Integer
    begin
        exit(ProcEntryList.Count());
    end;

    procedure SetProcEntryPC(ProcId: Integer; PC: Integer)
    begin
        ProcEntryList.Set(ProcId, PC);
    end;

    procedure GetProcEntryPC(ProcId: Integer): Integer
    begin
        exit(ProcEntryList.Get(ProcId));
    end;

    // Per-class register count (Cls per "ALI Type Rules" RegClass*, 1..13) — the proc's
    // full frame window size (binder vars + lowerer temps watermark).
    procedure SetProcRegCount(ProcId: Integer; Cls: Integer; N: Integer)
    begin
        ProcRegCnt.Set((ProcId - 1) * 13 + Cls, N);
    end;

    procedure GetProcRegCount(ProcId: Integer; Cls: Integer): Integer
    begin
        exit(ProcRegCnt.Get((ProcId - 1) * 13 + Cls));
    end;

    procedure SetProcResult(ProcId: Integer; Cls: Integer; Slot: Integer; TypeOrd: Integer)
    begin
        ProcResClassList.Set(ProcId, Cls);
        ProcResSlotList.Set(ProcId, Slot);
        ProcResTypeList.Set(ProcId, TypeOrd);
    end;

    procedure GetProcResultClass(ProcId: Integer): Integer
    begin
        exit(ProcResClassList.Get(ProcId));
    end;

    procedure GetProcResultSlot(ProcId: Integer): Integer
    begin
        exit(ProcResSlotList.Get(ProcId));
    end;

    procedure GetProcResultTypeOrd(ProcId: Integer): Integer
    begin
        exit(ProcResTypeList.Get(ProcId));
    end;

    // Param descriptor rows (informational: disassembly + M8 serialization; the runtime
    // convention is carried by ARG_VAL/ARG_REF instructions).
    procedure AddProcParamDesc(ProcId: Integer; Cls: Integer; Slot: Integer; IsVar: Boolean)
    begin
        ProcParamOwner.Add(ProcId);
        ProcParamClass.Add(Cls);
        ProcParamSlot.Add(Slot);
        if IsVar then
            ProcParamVar.Add(1)
        else
            ProcParamVar.Add(0);
    end;

    procedure SetEntryProcId(ProcId: Integer)
    begin
        EntryProcIdVal := ProcId;
    end;

    procedure EntryProcId(): Integer
    begin
        exit(EntryProcIdVal);
    end;

    // Module-level (global) var slot counts per class — absolute slots 1..N; every frame
    // window sits above them (entry frame base = GlobalCount, §7.1 M5).
    procedure SetGlobalCount(Cls: Integer; N: Integer)
    begin
        GlobalCnt[Cls] := N;
    end;

    procedure GetGlobalCount(Cls: Integer): Integer
    begin
        exit(GlobalCnt[Cls]);
    end;

    // ===== M11 phase B2: per-instance object-globals layout =====

    procedure SetProcSelfSlot(ProcId: Integer; Slot: Integer)
    begin
        ProcSelfSlotList.Set(ProcId, Slot);
    end;

    procedure GetProcSelfSlot(ProcId: Integer): Integer
    begin
        exit(ProcSelfSlotList.Get(ProcId));
    end;

    // Instance count = the highest instance the layout knows about. Rows are appended densely by
    // SetInstBase below, 13 classes at a time.
    procedure InstanceCount(): Integer
    begin
        exit(InstBaseList.Count() div 13);
    end;

    // Record instance Inst's block base for every register class at once — the layout is built in
    // one pass by "ALI Binder".AllocateGlobalSlots, so a per-class setter would only invite a
    // half-filled table.
    procedure AddInstBases(Bases: List of [Integer])
    var
        Cls: Integer;
    begin
        for Cls := 1 to 13 do
            InstBaseList.Add(Bases.Get(Cls));
    end;

    procedure ClearInstBases()
    begin
        Clear(InstBaseList);
    end;

    procedure GetInstBase(Inst: Integer; Cls: Integer): Integer
    begin
        if (Inst < 1) or (Inst > InstanceCount()) then
            exit(0);
        exit(InstBaseList.Get((Inst - 1) * 13 + Cls));
    end;

    // Handle Lifecycle Unification (Phase 3): Record/InStream/OutStream/TextBuilder/Dialog no
    // longer have a separate compilation-wide handle count sealed here — RegClassFor routes
    // them to RegClassInt, so they're ordinary windowed Int slots (global or per-proc-local)
    // like every other handle-kind type. The Set/GetXHandleCount getters formerly here (and
    // the runtime Rt.Allocate(N) calls they fed) are gone.

    // ===== Legacy single-proc getters (delegate to the ENTRY proc row) =====

    procedure EntryPC(): Integer
    begin
        if ProcEntryList.Count() = 0 then
            exit(1);
        exit(ProcEntryList.Get(EntryProcIdVal));
    end;

    procedure ResultClass(): Integer
    begin
        if ProcResClassList.Count() = 0 then
            exit(0);
        exit(ProcResClassList.Get(EntryProcIdVal));
    end;

    procedure ResultSlot(): Integer
    begin
        if ProcResSlotList.Count() = 0 then
            exit(0);
        exit(ProcResSlotList.Get(EntryProcIdVal));
    end;

    procedure ResultTypeOrd(): Integer
    begin
        if ProcResTypeList.Count() = 0 then
            exit(0);
        exit(ProcResTypeList.Get(EntryProcIdVal));
    end;

    // ===== Serialization (stored bytecode — "ALI Stored Script"."Compiled Code") =====
    // Every column the interpreter seals at LoadModule, as one JSON object. Integer columns travel
    // as one comma-joined string each: a JsonArray of thousands of ints would cost an AL call per
    // element on both sides. Pools that can hold blanks or free text (Text, Decimal, Date...) go
    // as JsonArrays of Format(x, 0, 9). Compile-only state (dedupe maps, param descriptors) is not
    // stored — a loaded module is run, never lowered into again.
    //
    // OPT_TO_TEXT is the one instruction carrying a SESSION-scoped id (its C operand is an
    // "ALI Option Meta" set id), so the sets it points at are stored by spelling and re-interned
    // on load. Bump SerialVersion whenever the stored shape changes; the host also keys the
    // stored module on the app version, which covers opcode renumbering.

    local procedure SerialVersion(): Integer
    begin
        exit(1);
    end;

    procedure Serialize(): Text
    var
        OptMeta: Codeunit "ALI Option Meta";
        Root: JsonObject;
        Sets: JsonObject;
        Globals: List of [Integer];
        Cls: Integer;
        i: Integer;
        OptToText: Integer;
        SetKey: Text;
        Result: Text;
    begin
        for Cls := 1 to 13 do
            Globals.Add(GlobalCnt[Cls]);
        Root.Add('v', SerialVersion());
        Root.Add('entry', EntryProcIdVal);
        Root.Add('glob', JoinInts(Globals));
        Root.Add('op', JoinInts(OpCol));
        Root.Add('a', JoinInts(ACol));
        Root.Add('b', JoinInts(BCol));
        Root.Add('c', JoinInts(CCol));
        Root.Add('dbg', JoinInts(InstrDbgRow));
        Root.Add('dl', JoinInts(DebugLineCol));
        Root.Add('dc', JoinInts(DebugColCol));
        Root.Add('opnd', JoinInts(OperandPool));
        Root.Add('pe', JoinInts(ProcEntryList));
        Root.Add('prc', JoinInts(ProcRegCnt));
        Root.Add('prcl', JoinInts(ProcResClassList));
        Root.Add('prs', JoinInts(ProcResSlotList));
        Root.Add('prt', JoinInts(ProcResTypeList));
        Root.Add('pss', JoinInts(ProcSelfSlotList));
        Root.Add('inst', JoinInts(InstBaseList));
        Root.Add('ci', JoinInts(ConstIntPool));
        Root.Add('cb', BigPoolToJson());
        Root.Add('cd', DecPoolToJson());
        Root.Add('ct', TextPoolToJson());
        Root.Add('cda', DatePoolToJson());
        Root.Add('cti', TimePoolToJson());
        Root.Add('cdt', DTPoolToJson());

        OptToText := "ALI Opcode"::OPT_TO_TEXT.AsInteger();
        for i := 1 to OpCol.Count() do
            if OpCol.Get(i) = OptToText then
                if CCol.Get(i) > 0 then begin
                    SetKey := Format(CCol.Get(i), 0, 9);
                    if not Sets.Contains(SetKey) then
                        Sets.Add(SetKey, OptMeta.DescribeSet(CCol.Get(i)));
                end;
        Root.Add('sets', Sets);
        Root.WriteTo(Result);
        exit(Result);
    end;

    // False = not a module this build can run (other version, damaged text, an option set that
    // no longer resolves): the caller recompiles. The module is left Reset in that case.
    procedure Deserialize(Serialized: Text): Boolean
    var
        OptMeta: Codeunit "ALI Option Meta";
        Root: JsonObject;
        Sets: JsonObject;
        Tok: JsonToken;
        Globals: List of [Integer];
        SetMap: Dictionary of [Integer, Integer];
        Cls: Integer;
        i: Integer;
        NewId: Integer;
        OldId: Integer;
        OptToText: Integer;
        SetKey: Text;
    begin
        Reset();
        if Serialized = '' then
            exit(false);
        if not Root.ReadFrom(Serialized) then
            exit(false);
        if Root.GetInteger('v', true) <> SerialVersion() then
            exit(false);
        EntryProcIdVal := Root.GetInteger('entry', true);
        if not (SplitInts(Root, 'glob', Globals) and
                SplitInts(Root, 'op', OpCol) and SplitInts(Root, 'a', ACol) and
                SplitInts(Root, 'b', BCol) and SplitInts(Root, 'c', CCol) and
                SplitInts(Root, 'dbg', InstrDbgRow) and SplitInts(Root, 'dl', DebugLineCol) and
                SplitInts(Root, 'dc', DebugColCol) and SplitInts(Root, 'opnd', OperandPool) and
                SplitInts(Root, 'pe', ProcEntryList) and SplitInts(Root, 'prc', ProcRegCnt) and
                SplitInts(Root, 'prcl', ProcResClassList) and SplitInts(Root, 'prs', ProcResSlotList) and
                SplitInts(Root, 'prt', ProcResTypeList) and SplitInts(Root, 'pss', ProcSelfSlotList) and
                SplitInts(Root, 'inst', InstBaseList) and SplitInts(Root, 'ci', ConstIntPool)) then
            exit(Deserialized(false));
        if not (BigPoolFromJson(Root) and DecPoolFromJson(Root) and TextPoolFromJson(Root) and
                DatePoolFromJson(Root) and TimePoolFromJson(Root) and DTPoolFromJson(Root)) then
            exit(Deserialized(false));
        if (Globals.Count() <> 13) or (EntryProcIdVal < 1) or (EntryProcIdVal > ProcEntryList.Count()) then
            exit(Deserialized(false));
        if (ACol.Count() <> OpCol.Count()) or (BCol.Count() <> OpCol.Count()) or
           (CCol.Count() <> OpCol.Count()) or (InstrDbgRow.Count() <> OpCol.Count()) then
            exit(Deserialized(false));
        for Cls := 1 to 13 do
            GlobalCnt[Cls] := Globals.Get(Cls);

        // Re-intern the option sets under this session's ids, then repoint OPT_TO_TEXT at them.
        if Root.Get('sets', Tok) then begin
            Sets := Tok.AsObject();
            foreach SetKey in Sets.Keys() do begin
                Sets.Get(SetKey, Tok);
                if not Evaluate(OldId, SetKey) then
                    exit(Deserialized(false));
                NewId := OptMeta.InternDescribed(Tok.AsValue().AsText());
                if NewId = 0 then
                    exit(Deserialized(false));
                SetMap.Set(OldId, NewId);
            end;
            if SetMap.Count() > 0 then begin
                OptToText := "ALI Opcode"::OPT_TO_TEXT.AsInteger();
                for i := 1 to OpCol.Count() do
                    if OpCol.Get(i) = OptToText then
                        if SetMap.Get(CCol.Get(i), NewId) then
                            CCol.Set(i, NewId);
            end;
        end;
        exit(true);
    end;

    // Leaves a rejected module empty rather than half-loaded.
    local procedure Deserialized(Ok: Boolean): Boolean
    begin
        if not Ok then
            Reset();
        exit(Ok);
    end;

    local procedure JoinInts(Values: List of [Integer]): Text
    var
        V: Integer;
        First: Boolean;
        Sb: TextBuilder;
    begin
        First := true;
        foreach V in Values do begin
            if not First then
                Sb.Append(',');
            Sb.Append(Format(V, 0, 9));
            First := false;
        end;
        exit(Sb.ToText());
    end;

    // An integer never formats to '', so an empty string can only be an empty list.
    local procedure SplitInts(var Root: JsonObject; Name: Text; var Values: List of [Integer]): Boolean
    var
        Joined: Text;
        Part: Text;
        V: Integer;
    begin
        Clear(Values);
        if not Root.Contains(Name) then
            exit(false);
        Joined := Root.GetText(Name);
        if Joined = '' then
            exit(true);
        foreach Part in Joined.Split(',') do begin
            if not Evaluate(V, Part) then
                exit(false);
            Values.Add(V);
        end;
        exit(true);
    end;

    local procedure PoolArray(var Root: JsonObject; Name: Text; var Arr: JsonArray): Boolean
    var
        Tok: JsonToken;
    begin
        if not Root.Get(Name, Tok) then
            exit(false);
        if not Tok.IsArray() then
            exit(false);
        Arr := Tok.AsArray();
        exit(true);
    end;

    local procedure PoolItem(var Arr: JsonArray; Idx: Integer): Text
    var
        Tok: JsonToken;
    begin
        Arr.Get(Idx, Tok);
        exit(Tok.AsValue().AsText());
    end;

    local procedure BigPoolToJson() Arr: JsonArray
    var
        V: BigInteger;
    begin
        foreach V in ConstBigPool do
            Arr.Add(Format(V, 0, 9));
    end;

    local procedure DecPoolToJson() Arr: JsonArray
    var
        V: Decimal;
    begin
        foreach V in ConstDecPool do
            Arr.Add(Format(V, 0, 9));
    end;

    local procedure TextPoolToJson() Arr: JsonArray
    var
        V: Text;
    begin
        foreach V in ConstTextPool do
            Arr.Add(V);
    end;

    local procedure DatePoolToJson() Arr: JsonArray
    var
        V: Date;
    begin
        foreach V in ConstDatePool do
            Arr.Add(Format(V, 0, 9));
    end;

    local procedure TimePoolToJson() Arr: JsonArray
    var
        V: Time;
    begin
        foreach V in ConstTimePool do
            Arr.Add(Format(V, 0, 9));
    end;

    local procedure DTPoolToJson() Arr: JsonArray
    var
        V: DateTime;
    begin
        foreach V in ConstDTPool do
            Arr.Add(Format(V, 0, 9));
    end;

    local procedure BigPoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
        V: BigInteger;
    begin
        if not PoolArray(Root, 'cb', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do begin
            if not Evaluate(V, PoolItem(Arr, i), 9) then
                exit(false);
            ConstBigPool.Add(V);
        end;
        exit(true);
    end;

    local procedure DecPoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
        V: Decimal;
    begin
        if not PoolArray(Root, 'cd', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do begin
            if not Evaluate(V, PoolItem(Arr, i), 9) then
                exit(false);
            ConstDecPool.Add(V);
        end;
        exit(true);
    end;

    local procedure TextPoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
    begin
        if not PoolArray(Root, 'ct', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do
            ConstTextPool.Add(PoolItem(Arr, i));
        exit(true);
    end;

    local procedure DatePoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
        V: Date;
        Item: Text;
    begin
        if not PoolArray(Root, 'cda', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do begin
            Item := PoolItem(Arr, i);
            V := 0D;    // a blank date formats to '' and must come back blank
            if Item <> '' then
                if not Evaluate(V, Item, 9) then
                    exit(false);
            ConstDatePool.Add(V);
        end;
        exit(true);
    end;

    local procedure TimePoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
        V: Time;
        Item: Text;
    begin
        if not PoolArray(Root, 'cti', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do begin
            Item := PoolItem(Arr, i);
            V := 0T;
            if Item <> '' then
                if not Evaluate(V, Item, 9) then
                    exit(false);
            ConstTimePool.Add(V);
        end;
        exit(true);
    end;

    local procedure DTPoolFromJson(var Root: JsonObject): Boolean
    var
        Arr: JsonArray;
        i: Integer;
        V: DateTime;
        Item: Text;
    begin
        if not PoolArray(Root, 'cdt', Arr) then
            exit(false);
        for i := 0 to Arr.Count() - 1 do begin
            Item := PoolItem(Arr, i);
            V := 0DT;
            if Item <> '' then
                if not Evaluate(V, Item, 9) then
                    exit(false);
            ConstDTPool.Add(V);
        end;
        exit(true);
    end;

    // ===== Disassembly (§14 golden tests) =====
    // One instruction per line: "<PC>: <MNEMONIC> <A> <B> <C>". Line separator is
    // TextBuilder.AppendLine — golden tests build their expectation with the same call.

    procedure Disassemble(): Text
    var
        PC: Integer;
        Sb: TextBuilder;
    begin
        for PC := 1 to OpCol.Count() do begin
            Sb.Append(DisassembleInstr(PC));
            Sb.AppendLine();
        end;
        exit(Sb.ToText());
    end;

    procedure DisassembleInstr(PC: Integer): Text
    var
        Op: Enum "ALI Opcode";
    begin
        Op := Enum::"ALI Opcode".FromInteger(OpCol.Get(PC));
        exit(StrSubstNo('%1: %2 %3 %4 %5', PC, Format(Op), ACol.Get(PC), BCol.Get(PC), CCol.Get(PC)));
    end;
}
