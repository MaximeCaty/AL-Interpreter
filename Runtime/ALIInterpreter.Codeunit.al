/*
    == ALI Interpreter — the dispatch loop. Single-instance ==

    Owns: sealed instruction stream + proc table (the Module's List columns are copied ONCE
    at LoadModule, §3.2 "sealing"), per-type const pools, typed register files
    WINDOWED FRAME STACK, PC, statement counter + budget, debug map.

    ===== CALLING CONVENTION (frozen; the Lowerer emits exactly this) =====

    Register operands in instructions are FRAME-RELATIVE; the loop adds the per-class
    frame base (CurBase*). Module-level (global) vars live in ABSOLUTE slots 1..G per
    class BELOW every frame; the entry frame's base per class = G (GLOB_LOAD/GLOB_STORE
    use absolute slots).

    A call site lowers to:
    1. by-value argument expressions fully evaluated into caller registers;
    2. ARG_VAL  (A=callee param slot, B=caller src reg, C=class): copies the value into
        the CALLEE WINDOW at [CurBase + CurProcRegCount + A] — callee param slots are the
        FIRST slots of the new frame, so the window is staged before the frame exists;
        ARG_REF  (A=callee param slot, B=caller src slot, C=class*4+mode): records a
        var-param ALIAS in the per-class Ref*
        tables: Ref[calleeParamAbs] := absolute index of the aliased storage. Mode:
        0 = caller frame-local (abs = CurBase+B), 1 = caller's own var param (abs =
        Ref[CurBase+B] — nested var passing dereferences), 2 = global (abs = B).
    3. CALL (A=proc id): pushes a frame — saves return PC / proc id / all 11 bases,
        advances each base by the CALLER's per-class register count (from the proc
        table), checks callee window capacity, jumps to the callee entry PC. Interpreted
        recursion NEVER uses AL recursion — depth is bounded only by MaxFrames/registers
        with clean ALI952/ALI953 runtime errors.
    4. callee body: var-param accesses use LOAD_IND/STORE_IND (per-class Ref* tables);
        exit(v) stores to the callee's own result slot then RET_VAL; bare exit / end of
        body -> RET. RET/RET_VAL pop the frame (entry frame -> halt).
    5. RESULT_FETCH (A=caller dest reg, B=callee result slot, C=class): after the pop,
        reads the (still intact) callee window at [CurBase + CurProcRegCount + B].
    6. TRY_CALL (A=proc id, B=caller Bool reg) replaces steps 3+5 for a [TryFunction] call
        whose outcome is consumed: same frame push but return PC = InstrTotal, then RunLoopFlat
        is re-entered under a native [TryFunction]; the callee's RET ends that nested loop. On
        a caught error the frames above the call are unwound (handles reclaimed) and B := false.
        See ExecTryCall.

    ALL arithmetic executes on NATIVE AL types (§15 pitfall 20). Runtime errors raise
    native AL errors inside the loop; Run() catches them at the conditional Codeunit.Run
    boundary (OnRun), which also gives the run a real transaction/rollback scope.

    DISPATCH: RunLoopFlat — one flat `case Op of` (AL emits it as a C# switch/jump table,
    so arm order is cosmetic). P1/P2/P3 dispatch-count optimizations: no STMT opcode (budget
    charged at back-edges + calls; per-instruction DbgRowOfPC resolves error positions),
    single pre-incremented PC (jump arms assign target-1), fused branch-compares and
    int-immediate ALU forms (opcodes 376+).

    FIXED ARRAY CAPACITIES are hardcoded (AL array bounds must be literals) and MUST match
    "ALI Limits": instructions 65536, const pools 2048, operand pool 4096,
    registers: Int 8192, Dec/Bool 4096, Text 2048, scalar files 2048, Variant 256;
    frames 1024, procs 1024, object instances 1024 (x13 classes = 13312 InstBaseArr entries).
    AssertArrayCapacities() checks every one of those pairs on each LoadModule — the two copies
    are not kept in step by hand any more. The debug map is no longer in this list: it is three
    Lists aliased to the module's own columns (see their declaration).
*/
codeunit 51031 "ALI Interpreter"
{
    Access = Public;
    SingleInstance = true;

    var

        // --- array RefShim runtime ---
        ArrayRt: Codeunit "ALI Array Runtime";
        BigRt: Codeunit "ALI BigText Runtime";
        BuiltinRegistry: Codeunit "ALI Builtin Registry";

        // --- builtin dispatch
        BSystem: Codeunit "ALI Builtin System";
        DlgRt: Codeunit "ALI Dialog Runtime";
        DictRt: Codeunit "ALI Dict Runtime";

        // --- Http* RefShim runtime (M10, Int-handle scheme — no separate handle count) ---
        HttpRt: Codeunit "ALI Http Runtime";

        // --- Json* RefShim runtime (Feature 2, unified Int-handle bank) ---
        JsonRt: Codeunit "ALI Json Runtime";

        // --- List/Dictionary RefShim runtime ---
        ListRt: Codeunit "ALI List Runtime";

        // --- Option/Enum registry
        OptionMeta: Codeunit "ALI Option Meta";

        // --- record/stream/TextBuilder/Dialog runtimes (Handle Lifecycle Unification Phase
        // 3: dynamic handle banks, allocated via *_NEW opcodes like every other handle-kind
        // type — no more binder-sealed handle counts) ---
        NativeRt: Codeunit "ALI Native Runtime";
        RecRt: Codeunit "ALI Rec Runtime";
        RunOptions: Codeunit "ALI Run Options";
        StrmRt: Codeunit "ALI Stream Runtime";
        TbRt: Codeunit "ALI TextBuilder Runtime";

        // --- Xml* RefShim runtime (Feature 3, unified NodeBank + side banks) ---
        XmlRt: Codeunit "ALI Xml Runtime";
        RegDateFormula: array[2048] of DateFormula;
        RegRecordId: array[2048] of RecordId;
        CPoolBig: array[2048] of BigInteger;
        RegBig: array[2048] of BigInteger;
        // PopFrame
        Escaped: Boolean;

        Loaded: Boolean;
        // Perf: PopFrame's "does this proc return a handle-kind value?" test, resolved ONCE per
        // proc at LoadModule instead of calling IsAllocStackHandleKind on every single return
        // (it is a ~10-term ordinal-range predicate, and AL evaluates it eagerly regardless of
        // the PTResClass/PTResSlot guards next to it).
        PTResIsHandle: array[1024] of Boolean;
        RegBool: array[4096] of Boolean;
        ResultIsHandle: Boolean;
        CPoolDate: array[2048] of Date;
        RegDate: array[2048] of Date;
        CPoolDT: array[2048] of DateTime;
        RegDT: array[2048] of DateTime;
        CPoolDec: array[2048] of Decimal;
        RegDec: array[4096] of Decimal;
        RegDur: array[2048] of Duration;
        RegGuid: array[2048] of Guid;
        AArr: array[65536] of Integer;
        BArr: array[65536] of Integer;
        // PushFrame
        CalleeRow: Integer;
        CallerRow: Integer;
        CArr: array[65536] of Integer;

        // --- Const pools (ALI Limits.MaxConstPoolEntries) ---
        CPoolInt: array[2048] of Integer;
        CurBaseBig: Integer;
        CurBaseBool: Integer;
        CurBaseDate: Integer;
        CurBaseDateFormula: Integer;
        CurBaseDec: Integer;
        CurBaseDT: Integer;
        CurBaseDur: Integer;
        CurBaseGuid: Integer;
        // --- Current frame bases (per class) + entry-frame bases (= global counts) ---
        CurBaseInt: Integer;
        CurBaseRecordId: Integer;
        CurBaseText: Integer;
        CurBaseTime: Integer;
        CurBaseVar: Integer;
        // Cached (instance-1)*13 for the frame currently executing — recomputed exactly where
        // CurWin* is, i.e. whenever the frame or proc changes, so SELF_* stays two array reads.
        CurInstRow: Integer;
        CurProcIdVal: Integer;
        CurWinBig: Integer;
        CurWinBool: Integer;
        CurWinDate: Integer;
        CurWinDateFormula: Integer;
        CurWinDec: Integer;
        CurWinDT: Integer;
        CurWinDur: Integer;
        CurWinGuid: Integer;
        // Perf: cached callee-window base per class (= CurBase* + PTRegCnt[row + cls] for the
        // CURRENT proc) — the ARG_VAL/ARG_REF/RESULT_FETCH arms each recomputed this from scratch
        // on EVERY operand; refreshed instead ONLY where CurProcIdVal/CurBase* actually change
        // (Run() init via RecomputeCurWin, end of PushFrame, end of PopFrame — the latter two
        // inline that body rather than call it, and those 3 sites are the only valid ones).
        CurWinInt: Integer;
        CurWinRecordId: Integer;
        CurWinText: Integer;
        CurWinTime: Integer;
        CurWinVar: Integer;
        // --- Debug map (ALI Limits.MaxDebugEntries) ---
        // Lists, not fixed arrays, and ALIASED to the module's own columns rather than copied:
        // these three are written once at LoadModule and read ONLY when a run fails, so they
        // carry no hot-path cost — while as arrays they were 262144 Integer slots (~1MB) that
        // every fresh interpreter instance had to allocate, a large share of the cold-start cost
        // of the session's first run. Aliases stay valid for the run: the module outlives it.
        DbgCol: List of [Integer];
        DbgLine: List of [Integer];
        // Per-instruction debug row (P1: replaces the STMT opcode) — DbgRowOfPC[PC] is the
        // debug-map row of the statement that instruction belongs to (0 = none). On a runtime
        // error, PC still holds the failing instruction (single-counter loop, P2).
        DbgRowOfPC: List of [Integer];
        DbgTotal: Integer;
        EBBig: Integer;
        EBBool: Integer;
        EBDate: Integer;
        EBDateFormula: Integer;
        EBDec: Integer;
        EBDT: Integer;
        EBDur: Integer;
        EBGuid: Integer;
        EBInt: Integer;
        EBRecordId: Integer;
        EBText: Integer;
        EBTime: Integer;
        EBVar: Integer;
        EntryPCVal: Integer;
        EntryProcIdVal: Integer;
        EscHandle: Integer;
        EscKind: Integer;
        EvalInt: Integer;
        FrAllocBase: array[1024] of Integer;
        FrameSP: Integer;
        FrBBig: array[1024] of Integer;
        FrBBool: array[1024] of Integer;
        FrBDate: array[1024] of Integer;
        FrBDateFormula: array[1024] of Integer;
        FrBDec: array[1024] of Integer;
        FrBDT: array[1024] of Integer;
        FrBDur: array[1024] of Integer;
        FrBGuid: array[1024] of Integer;
        FrBInt: array[1024] of Integer;
        FrBRecordId: array[1024] of Integer;
        FrBText: array[1024] of Integer;
        FrBTime: array[1024] of Integer;
        FrBVar: array[1024] of Integer;
        FrProcId: array[1024] of Integer;

        // --- Frame stack (ALI Limits.MaxFrames; parallel arrays, §7.4) ---
        FrRetPC: array[1024] of Integer;
        H, Row : Integer;
        // ExecHandleEscape
        i: Integer;
        // Absolute base of instance i's globals block per register class, (i-1)*13 + class.
        // 13312 = "ALI Limits".MaxObjectInstances (1024) * 13.
        InstBaseArr: array[13312] of Integer;
        InstrTotal: Integer;
        InstTotal: Integer;
        // --- Sealed instruction stream (capacities = ALI Limits.MaxInstructions) ---
        OpArr: array[65536] of Integer;

        // --- CONCAT_N operand pool (ALI Limits.MaxConcatOperands) ---
        OperArr: array[4096] of Integer;

        // --- Run state ---
        PC: Integer;
        // TextEncoding parked by REC_BLOB_ENC for the immediately following blob stream op.
        PendingBlobEnc: Integer;
        ProcTotal: Integer;

        // --- Sealed proc table (ALI Limits.MaxProcsPerModule) ---
        PTEntry: array[1024] of Integer;
        PTRegCnt: array[13312] of Integer;  // (ProcId-1)*13 + RegClass (13 = RegClassCount, incl. DateFormula)
        PTResClass: array[1024] of Integer;
        PTResSlot: array[1024] of Integer;
        // Handle Lifecycle Unification: the "ALI TypeKind" ordinal of the proc's result, when
        // it is a handle-kind type (Array/List/Dictionary/Http*) — 0 otherwise. Lets PopFrame
        // recognize "this proc's return value IS a handle it allocated" without re-deriving it
        // from PTResClass (which is only the REGISTER class, always Int for every handle kind).
        PTResTypeOrd: array[1024] of Integer;
        // M11 phase B2: frame-relative Int slot holding the running instance index of a harvested
        // object's procedure (0 = ordinary procedure, no object globals). SELF_LOAD/SELF_STORE
        // read it to pick which instance's block of globals to address.
        PTSelfSlot: array[1024] of Integer;
        RefBig: array[2048] of Integer;
        RefBool: array[4096] of Integer;
        RefDate: array[2048] of Integer;
        RefDateFormula: array[2048] of Integer;
        RefDec: array[4096] of Integer;
        RefDT: array[2048] of Integer;
        RefDur: array[2048] of Integer;
        RefGuid: array[2048] of Integer;

        // --- Var-param alias tables (M5, §7.2): Ref*[abs param slot] = abs aliased idx ---
        RefInt: array[8192] of Integer;
        RefRecordId: array[2048] of Integer;
        RefText: array[2048] of Integer;
        RefTime: array[2048] of Integer;
        RefVar: array[256] of Integer;

        // --- Typed register files (§7.1; capacities = ALI Limits.Max*Registers) ---
        RegInt: array[8192] of Integer;
        // Parallel type-tag shadowing RegVariant (same absolute indexing, §19.2). Holds the
        // "ALI TypeKind" of the boxed value ONLY for handle/reference types the native Variant
        // cannot self-identify: Record/List/Dictionary/Array (their boxed value is a bare Int
        // handle). 0 = a native scalar (native Variant.IsXxx() answers those). Propagated
        // alongside RegVariant at every move site (MOV_V, ARG_VAL/REF, RESULT_FETCH, IND, GLOB).
        RegVarTag: array[256] of Integer;

        Idx: Integer;

        // --- Result descriptor (entry proc; slot is ABSOLUTE after LoadModule) ---
        ResultClassVal: Integer;
        ResultSlotVal: Integer;
        ResultTypeOrdVal: Integer;
        //InstrCounter: Integer;
        StmtBudget: Integer;
        StmtCounter: Integer;
        SimRollbackTok: Label 'ALI_SIM_ROLLBACK_SENTINEL', Locked = true;  // Simulation end-of-run rollback marker (§8)
        AllocHandleStack: List of [Integer];

        // --- Handle Lifecycle Unification: ONE frame-scoped tagged alloc stack for every
        // reference-typed runtime object whose value is a plain Int handle — Array, List,
        // Dictionary, Http* (Record/InStream/OutStream/TextBuilder/Dialog stay on their own
        // separate module-scoped handle spaces for now, unconverted). Two PARALLEL lists
        // (Kind, Handle), not one packed integer — List/Dict handles already pack
        // classIndex*1000000+bankIndex, so packing a TypeKind ordinal on top would collide/
        // overflow. FrAllocBase[FrameSP] snapshots AllocKindStack.Count() at PushFrame so
        // PopFrame can reclaim exactly what the popped frame allocated (skipping a value that
        // escapes via a bare-value `exit` — see PopFrame; HANDLE_ESCAPE/ExecHandleEscape
        // handles the var-param/global escape case at the store site). ---
        AllocKindStack: List of [Integer];
        // REC_NEW PC -> the bank slot that instruction's GLOBAL record already owns for this run.
        // Makes a re-entered global prologue idempotent instead of leaking a slot per pass (see
        // ExecRecNew). Per-run: cleared by Reset alongside every other runtime bank.
        GlobalRecByPC: Dictionary of [Integer, Integer];
        GlobalRecReopens: Integer;      // how often that dedupe actually fired — reported by CopyPendingToResult
        PendingMessages: List of [Text];    // Message(...) interception, collected in call order (§8/§9)
        PendingWarnings: List of [Text];    // ALI9xx runtime warnings (unscripted Confirm/StrMenu, §8)
        CPoolText: array[2048] of Text;
        RegText: array[2048] of Text;
        CPoolTime: array[2048] of Time;
        RegTime: array[2048] of Time;
        RegVariant: array[256] of Variant;

    // ===== Lifecycle / config =====

    // Every fixed array above is sized from a constant that "ALI Limits" also publishes, and AL
    // array dimensions must be literals — so the two copies can only be kept together by hand.
    // They already rotted once in the record bank ("ALI Rec Runtime".AssertBankCapacity, ALI955:
    // Limits said 4096 while the array held 1024, turning an in-range check into an out-of-bounds
    // index). Same guard here, same shape: one ArrayLen compare per limit, once per LoadModule.
    // A limit LOWER than its array only wastes slots; a limit HIGHER lets the bounds checks in
    // LoadModule pass and then indexes past the end mid-run, so both directions fail loudly.
    local procedure AssertArrayCapacities()
    var
        Limits: Codeunit "ALI Limits";
    begin
        if (Limits.MaxInstructions() <> ArrayLen(OpArr)) or (Limits.MaxInstructions() <> ArrayLen(AArr)) or
           (Limits.MaxInstructions() <> ArrayLen(BArr)) or (Limits.MaxInstructions() <> ArrayLen(CArr)) then
            Error('ALI958: "ALI Limits".MaxInstructions() says %1 but the sealed stream holds %2/%3/%4/%5 (Op/A/B/C)',
                Limits.MaxInstructions(), ArrayLen(OpArr), ArrayLen(AArr), ArrayLen(BArr), ArrayLen(CArr));
        if (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolInt)) or (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolBig)) or
           (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolDec)) or (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolText)) or
           (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolDate)) or (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolTime)) or
           (Limits.MaxConstPoolEntries() <> ArrayLen(CPoolDT)) then
            Error('ALI958: "ALI Limits".MaxConstPoolEntries() says %1 but a const pool holds a different count (Int %2, Big %3, Dec %4, Text %5, Date %6, Time %7, DateTime %8)',
                Limits.MaxConstPoolEntries(), ArrayLen(CPoolInt), ArrayLen(CPoolBig), ArrayLen(CPoolDec),
                ArrayLen(CPoolText), ArrayLen(CPoolDate), ArrayLen(CPoolTime), ArrayLen(CPoolDT));
        if Limits.MaxObjectInstances() * 13 <> ArrayLen(InstBaseArr) then
            Error('ALI958: "ALI Limits".MaxObjectInstances() says %1 (x13 classes = %2) but InstBaseArr holds %3',
                Limits.MaxObjectInstances(), Limits.MaxObjectInstances() * 13, ArrayLen(InstBaseArr));
        if Limits.MaxConcatOperands() <> ArrayLen(OperArr) then
            Error('ALI958: "ALI Limits".MaxConcatOperands() says %1 but the operand pool holds %2', Limits.MaxConcatOperands(), ArrayLen(OperArr));
        if Limits.MaxProcsPerModule() <> ArrayLen(PTEntry) then
            Error('ALI958: "ALI Limits".MaxProcsPerModule() says %1 but the proc table holds %2', Limits.MaxProcsPerModule(), ArrayLen(PTEntry));
        if Limits.MaxFrames() <> ArrayLen(FrRetPC) then
            Error('ALI958: "ALI Limits".MaxFrames() says %1 but the frame stack holds %2', Limits.MaxFrames(), ArrayLen(FrRetPC));
        if (Limits.MaxIntRegisters() <> ArrayLen(RegInt)) or (Limits.MaxDecimalRegisters() <> ArrayLen(RegDec)) or
           (Limits.MaxBoolRegisters() <> ArrayLen(RegBool)) or (Limits.MaxTextRegisters() <> ArrayLen(RegText)) or
           (Limits.MaxScalarRegisters() <> ArrayLen(RegDate)) or (Limits.MaxVariantRegisters() <> ArrayLen(RegVariant)) then
            Error('ALI958: register file / "ALI Limits" mismatch (Int %1/%2, Dec %3/%4, Bool %5/%6, Text %7/%8, Scalar %9/%10, Variant %11/%12)',
                Limits.MaxIntRegisters(), ArrayLen(RegInt), Limits.MaxDecimalRegisters(), ArrayLen(RegDec),
                Limits.MaxBoolRegisters(), ArrayLen(RegBool), Limits.MaxTextRegisters(), ArrayLen(RegText),
                Limits.MaxScalarRegisters(), ArrayLen(RegDate), Limits.MaxVariantRegisters(), ArrayLen(RegVariant));
    end;

    procedure Reset()
    var
        Limits: Codeunit "ALI Limits";
    begin
        InstrTotal := 0;
        EntryPCVal := 1;
        DbgTotal := 0;
        Loaded := false;
        StmtBudget := Limits.DefaultStatementBudget();
        ProcTotal := 0;
        EntryProcIdVal := 1;
        FrameSP := 0;
        ResultClassVal := 0;
        ResultSlotVal := 0;
        ResultTypeOrdVal := 0;
        RecRt.Reset();
        FcGen += 1;    // PERF TEST — bank reset renumbers handles
        StrmRt.Reset();
        NativeRt.Reset();
        TbRt.Reset();
        BigRt.Reset();
        DlgRt.Reset();
        ListRt.Reset();
        DictRt.Reset();
        HttpRt.Reset();
        JsonRt.Reset();
        XmlRt.Reset();
        ArrayRt.Reset();
        Clear(GlobalRecByPC);
        GlobalRecReopens := 0;
        Clear(AllocKindStack);
        Clear(AllocHandleStack);
        Clear(FrAllocBase);
        Clear(PendingMessages);
        Clear(PendingWarnings);
        // The three debug lists are deliberately NOT cleared here: they alias the module's own
        // columns, and Reset() runs from LoadModule BEFORE the aliases are re-taken — clearing
        // them could empty the module's columns through the alias and silently lose every error
        // position. InstrTotal/DbgTotal (zeroed above) are what guard the error path.
        ClearRegisters();
    end;

    procedure SetBudget(MaxStatements: Integer)
    begin
        StmtBudget := MaxStatements;
    end;

    // ===== LoadModule — seal List-built columns into fixed arrays (§3.2) =====
    procedure LoadModule(var Module: Codeunit "ALI Module")
    var
        Limits: Codeunit "ALI Limits";
        Cls: Integer;
        i: Integer;
        p: Integer;
        SealA: List of [Integer];
        SealB: List of [Integer];
        SealC: List of [Integer];
        SealOp: List of [Integer];
    begin
        Reset();
        AssertArrayCapacities();
        if Module.InstrCount() > Limits.MaxInstructions() then
            Error('ALI940: program too large (%1 instructions, max %2)', Module.InstrCount(), Limits.MaxInstructions());
        if (Module.ConstIntCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstBigCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstDecCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstTextCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstDateCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstTimeCount() > Limits.MaxConstPoolEntries()) or
           (Module.ConstDTCount() > Limits.MaxConstPoolEntries())
        then
            Error('ALI942: const pool too large');
        if Module.OperandCount() > Limits.MaxConcatOperands() then
            Error('ALI943: operand pool too large');
        if Module.DebugCount() > Limits.MaxDebugEntries() then
            Error('ALI944: debug map too large');
        if Module.ProcCount() > Limits.MaxProcsPerModule() then
            Error('ALI946: too many procedures (%1, max %2)', Module.ProcCount(), Limits.MaxProcsPerModule());

        // Builtin signature table: built once per session. Guarded here rather than inside
        // the CALL_BUILTIN_LIVE arm, which used to re-check the flag on every builtin call. The
        // binder/lowerer normally build it during Compile; this covers a module that is loaded
        // and run without a compile in the same session.
        BuiltinRegistry.EnsureBuilt();
        Clear(BMemoOk);     // registry rows are session-stable, but a Reset() would renumber them

        InstrTotal := Module.InstrCount();
        // Take the five instruction columns by reference in ONE call, then iterate them locally.
        // The per-instruction getter form cost 5 cross-codeunit calls per instruction before a
        // run could start; this is 1 call plus plain List reads.
        // The debug column is taken as the alias itself (error-path only — see its declaration),
        // so it costs nothing per instruction; the four hot columns are still copied into arrays.
        Module.GetInstrColumns(SealOp, SealA, SealB, SealC, DbgRowOfPC);
        for i := 1 to InstrTotal do begin
            OpArr[i] := SealOp.Get(i);
            AArr[i] := SealA.Get(i);
            BArr[i] := SealB.Get(i);
            CArr[i] := SealC.Get(i);
        end;
        // PERF TEST — number the REC_FLD_LOAD/STORE sites; sites past the cache share the scratch slot.
        FcGen += 1;
        p := 0;
        for i := 1 to InstrTotal do
            if (OpArr[i] = 247) or (OpArr[i] = 248) then begin
                if p < ArrayLen(FcHandle) then
                    p += 1;
                FcSiteOfPC[i] := p;
            end;
        // end PERF TEST

        for i := 1 to Module.ConstIntCount() do
            CPoolInt[i] := Module.GetConstInt(i);
        for i := 1 to Module.ConstBigCount() do
            CPoolBig[i] := Module.GetConstBig(i);
        for i := 1 to Module.ConstDecCount() do
            CPoolDec[i] := Module.GetConstDec(i);
        for i := 1 to Module.ConstTextCount() do
            CPoolText[i] := Module.GetConstText(i);
        for i := 1 to Module.ConstDateCount() do
            CPoolDate[i] := Module.GetConstDate(i);
        for i := 1 to Module.ConstTimeCount() do
            CPoolTime[i] := Module.GetConstTime(i);
        for i := 1 to Module.ConstDTCount() do
            CPoolDT[i] := Module.GetConstDT(i);

        for i := 1 to Module.OperandCount() do
            OperArr[i] := Module.GetOperand(i);

        DbgTotal := Module.DebugCount();
        Module.GetDebugColumns(DbgLine, DbgCol);

        // Proc table (§7.3).
        ProcTotal := Module.ProcCount();
        for p := 1 to ProcTotal do begin
            PTEntry[p] := Module.GetProcEntryPC(p);
            PTResClass[p] := Module.GetProcResultClass(p);
            PTResSlot[p] := Module.GetProcResultSlot(p);
            PTResTypeOrd[p] := Module.GetProcResultTypeOrd(p);
            PTResIsHandle[p] := (PTResClass[p] = 1) and (PTResSlot[p] > 0) and
                                IsAllocStackHandleKind(PTResTypeOrd[p]);
            PTSelfSlot[p] := Module.GetProcSelfSlot(p);
            for Cls := 1 to 13 do
                PTRegCnt[(p - 1) * 13 + Cls] := Module.GetProcRegCount(p, Cls);
        end;

        // M11 phase B2: the per-instance globals layout the binder computed.
        InstTotal := Module.InstanceCount();
        if InstTotal > Limits.MaxObjectInstances() then
            Error('ALI954: too many object variables (%1, max %2)', InstTotal, Limits.MaxObjectInstances());
        for p := 1 to InstTotal do
            for Cls := 1 to 13 do
                InstBaseArr[(p - 1) * 13 + Cls] := Module.GetInstBase(p, Cls);

        // Entry-frame bases = module global counts (globals sit in absolute 1..G).
        EBInt := Module.GetGlobalCount(1);
        EBBig := Module.GetGlobalCount(2);
        EBDec := Module.GetGlobalCount(3);
        EBBool := Module.GetGlobalCount(4);
        EBText := Module.GetGlobalCount(5);
        EBDate := Module.GetGlobalCount(6);
        EBTime := Module.GetGlobalCount(7);
        EBDT := Module.GetGlobalCount(8);
        EBDur := Module.GetGlobalCount(9);
        EBGuid := Module.GetGlobalCount(10);
        EBVar := Module.GetGlobalCount(11);
        EBRecordId := Module.GetGlobalCount(12);
        EBDateFormula := Module.GetGlobalCount(13);

        EntryProcIdVal := Module.EntryProcId();
        EntryPCVal := Module.EntryPC();
        ResultClassVal := Module.ResultClass();
        ResultTypeOrdVal := Module.ResultTypeOrd();
        // Entry result slot is frame-relative in the module; the entry frame base is
        // fixed, so seal it as an ABSOLUTE index.
        ResultSlotVal := Module.ResultSlot();
        if (ResultClassVal > 0) and (ResultSlotVal > 0) then
            ResultSlotVal += EntryBaseOf(ResultClassVal);
        Loaded := true;
    end;

    // ===== Run (§7.4) =====

    procedure Run(var ExecResult: Codeunit "ALI Exec Result")
    var
        Ok: Boolean;
        ErrDbgRow: Integer;
    begin
        ExecResult.Reset();
        if not Loaded then begin
            ExecResult.SetStart(CurrentDateTime());
            ExecResult.SetEnd(CurrentDateTime());
            ExecResult.SetSucceeded(false);
            ExecResult.SetError('ALI945: no module loaded', 0, 0);
            exit;
        end;

        ClearRegisters();
        RecRt.Reset();
        FcGen += 1;    // PERF TEST — bank reset renumbers handles
        StrmRt.Reset();
        NativeRt.Reset();
        TbRt.Reset();
        BigRt.Reset();
        DlgRt.Reset();
        ListRt.Reset();
        DictRt.Reset();
        HttpRt.Reset();
        JsonRt.Reset();
        XmlRt.Reset();
        ArrayRt.Reset();
        Clear(GlobalRecByPC);
        GlobalRecReopens := 0;
        Clear(AllocKindStack);
        Clear(AllocHandleStack);
        Clear(FrAllocBase);
        Clear(PendingMessages);
        Clear(PendingWarnings);
        PC := EntryPCVal - 1;   // single-counter loop pre-increments (P2)
        CurProcIdVal := EntryProcIdVal;
        FrameSP := 0;
        TryDepth := 0;
        BSystem.SetLastErrorText('');   // a caught TryFunction error must not leak into the next run
        CurBaseInt := EBInt;
        CurBaseBig := EBBig;
        CurBaseDec := EBDec;
        CurBaseBool := EBBool;
        CurBaseText := EBText;
        CurBaseDate := EBDate;
        CurBaseTime := EBTime;
        CurBaseDT := EBDT;
        CurBaseDur := EBDur;
        CurBaseGuid := EBGuid;
        CurBaseVar := EBVar;
        CurBaseRecordId := EBRecordId;
        CurBaseDateFormula := EBDateFormula;
        RecomputeCurWin();
        StmtCounter := 0;

        ExecResult.SetStart(CurrentDateTime());
        // Conditional Codeunit.Run — the ONLY AL construct that gives the run its own rollback
        // scope. A [TryFunction] catches the error but does NOT undo the writes made inside it
        // ("changes to the database that are made with a try method aren't rolled back"), which
        // is why Simulation used to leave its Insert/Modify/Delete behind. Single-instance, so
        // this reuses THIS instance: module, registers, PC and pending logs stay intact (memory
        // is untouched by the rollback) and the error position below still resolves.
        // Note: Codeunit.Run implicitly commits the HOST's pending writes before starting.
        Commit();
        Ok := Codeunit.Run(Codeunit::"ALI Interpreter");
        ExecResult.SetEnd(CurrentDateTime());
        ExecResult.SetCounts(StmtCounter, 0);
        CopyPendingToResult(ExecResult);

        if Ok then
            FinishSuccess(ExecResult)
        // Simulation: a clean run ends with the sentinel error (thrown to force the Codeunit.Run
        // rollback) — treat it as success, never surface it. A real error has a different text.
        else if RunOptions.IsSimulation() and (GetLastErrorText() = SimRollbackTok) then begin
            ClearLastError();
            FinishSuccess(ExecResult);
        end else begin
            ExecResult.SetSucceeded(false);
            ErrDbgRow := 0;
            if (PC >= 1) and (PC <= InstrTotal) and (PC <= DbgRowOfPC.Count()) then
                ErrDbgRow := DbgRowOfPC.Get(PC);    // PC = the failing instruction (P2)
            if (ErrDbgRow >= 1) and (ErrDbgRow <= DbgTotal) and (ErrDbgRow <= DbgLine.Count()) then
                ExecResult.SetError(GetLastErrorText(), DbgLine.Get(ErrDbgRow), DbgCol.Get(ErrDbgRow))
            else
                ExecResult.SetError(GetLastErrorText(), 0, 0);
            ClearLastError();
        end;
    end;

    local procedure FinishSuccess(var ExecResult: Codeunit "ALI Exec Result")
    begin
        ExecResult.SetSucceeded(true);
        if (ResultClassVal > 0) and (ResultSlotVal > 0) then
            ExecResult.SetResultValue(FormatAbsRegister(ResultClassVal, ResultSlotVal), ResultTypeOrdVal);
    end;

    // ===== Run scopes: two entries into the SAME dispatch loop (§8) =====
    //
    // Normal     — no CommitBehavior attribute: a script COMMIT is a REAL commit, and so is any
    //              commit done by an external procedure/codeunit the script calls. A runtime
    //              error fails this Codeunit.Run and rolls the run back to its start (up to the
    //              last COMMIT the script itself asked for).
    // Simulation — RunLoopSimulation() below carries CommitBehavior::Ignore, which applies to
    //              its whole call stack: neither the script's COMMIT nor any future external
    //              call can pin writes past the sentinel rollback.
    trigger OnRun()
    begin
        if RunOptions.IsSimulation() then
            RunLoopIgnoreCommit()
        else
            RunLoopFlat();
    end;

    [CommitBehavior(CommitBehavior::Ignore)]
    // Ignore covers every explicit Commit() below this frame (script COMMIT, and later external
    // procedure/codeunit calls) — silently dropped, no "commit not allowed" error. Caveat: the
    // attribute does NOT cover the IMPLICIT commit a nested Codeunit.Run performs, so external
    // *codeunit* invocation must stay blocked in Simulation until that is handled explicitly.
    local procedure RunLoopIgnoreCommit()
    begin
        RunLoopFlat();
        // Simulation (§8): after a clean run, raise a sentinel error so the enclosing
        // Codeunit.Run rolls back every DB write the run made. Run() maps the sentinel back
        // to success; any other error text is a genuine script failure.
        Error(SimRollbackTok);
    end;

    // ===== FLAT dispatch: one case for all operation =====
    var
        ByScratch: Byte;
        ChScratch: Char;
        k: Integer;
        MaxLen: Integer;
        RIdx: Integer;
        TxtVal: Text;
        Sb: TextBuilder;
        VScratch: Variant;      // generic-class fallback in the hoisted REC_FLD_* arms
        // ===== PERF TEST — FieldRef inline cache (REC_FLD_LOAD/REC_FLD_STORE). To revert: delete
        // every "PERF TEST" block (Fc* names) and uncomment the "PERF TEST original" arms. =====
        // One cached FieldRef per 247/248 instruction site (sites numbered in LoadModule). A hit
        // needs the same handle AND the same FcHEpoch[handle] + FcGen as at bind time: a reopened /
        // freed / rebound RecordRef invalidates its FieldRefs, so every such event bumps the
        // handle's epoch (FcBumpHandle) or FcGen (bank reset, native calls). Both counters only
        // grow, so their sum changes on any bump. Last site slot = scratch, never marked bound.
        FcSiteOfPC: array[65536] of Integer;
        FcRef: array[1024] of FieldRef;
        FcHandle: array[1024] of Integer;
        FcStamp: array[1024] of Integer;
        FcHEpoch: array[256] of Integer;    // = "ALI Rec Runtime" bank capacity (RecRefs)
        FcGen: Integer;
        FcSite: Integer;
        FcMiss: Boolean;
        // ===== end PERF TEST =====
        // CALL_BUILTIN_LIVE arm state (inlined — was ExecCallBuiltinLive, one AL call per builtin).
        // Codeunit members, not locals: no per-call prologue for 16 Variants + 3 Texts.
        BArgs: array[16] of Variant;
        BResultV: Variant;
        BHasMessage: Boolean;
        BWarned: Boolean;
        BArgCount: Integer;
        BId: Integer;
        BIdx: Integer;
        BOperStart: Integer;
        BCollectedMsg: Text;
        BWarningText: Text;
        // Per-run memo of the registry's name/domain/kind columns by BuiltinId: 3-4 cross-codeunit
        // getter calls per builtin call become array reads. Cleared in LoadModule. Last slot (2049)
        // is scratch for BIds past it: never marked Ok, reloaded from the registry getters every call.
        BMemoOk: array[2049] of Boolean;
        BMemoName: array[2049] of Text;
        BMemoDomain: array[2049] of Enum "ALI Builtin Domain";
        BMemoKind: array[2049] of Enum "ALI Builtin Kind";
        BSlot: Integer;
        // Inlined Str builtin (307 arm) scratch.
        BStrFmt: array[9] of Text;
        BStrText: Text;
        BStrInt: Integer;
        BStrLen: Integer;
        BNumDec: Decimal;       // inlined Math builtin scratch
        BNumPrec: Decimal;
        BDtDate: Date;          // inlined DateTime builtin scratch
        BDtTime: Time;
        BDtDT: DateTime;
        BDtBig: BigInteger;
        // Inlined Dictionary (342-345, 347, 460) and List (327-332) arms scratch.
        DHandle: Integer;
        DPacked: Integer;
        DOutReg: Integer;
        DKeyV: Variant;
        DValV: Variant;

    local procedure RunLoopFlat()
    begin
        // PC IS the current instruction (incremented at the
        // loop top), so every jump arm assigns target-1. FrRetPC stores the CALL's own PC
        // (return resumes at the next increment); Run() starts at EntryPC-1; halting sets
        // PC := InstrTotal so the while-condition exits.
        // P1: no STMT dispatch — the runaway budget is charged only at back-edges (charged
        // _BACK jump twins + FOR_NEXT) and CALLs; source positions for errors come from the
        // per-instruction DbgRowOfPC map.
        while PC < InstrTotal do begin
            PC += 1;
            StmtCounter += 1;
            if StmtCounter > StmtBudget then
                Error('ALI950: statement budget exhausted after %1 statements', StmtBudget);

            case OpArr[PC] of
                // --- hottest: loop kernel / jumps ---
                7:  // FOR_NEXT_UP (charged: one budget tick per iteration — empty bodies stay budgeted)
                    begin
                        RIdx := CurBaseInt + AArr[PC];
                        if RegInt[RIdx] < RegInt[CurBaseInt + BArr[PC]] then begin
                            RegInt[RIdx] += 1;
                            PC := CArr[PC] - 1;
                        end;
                    end;
                8:  // FOR_NEXT_DOWN
                    begin
                        RIdx := CurBaseInt + AArr[PC];
                        if RegInt[RIdx] > RegInt[CurBaseInt + BArr[PC]] then begin
                            RegInt[RIdx] -= 1;
                            PC := CArr[PC] - 1;
                        end;
                    end;
                2:  // JMP (forward — back-edges were rewritten to JMP_BACK)
                    PC := AArr[PC] - 1;
                3:  // JMP_IF_FALSE
                    if not RegBool[CurBaseBool + BArr[PC]] then
                        PC := AArr[PC] - 1;
                4:  // JMP_IF_TRUE
                    if RegBool[CurBaseBool + BArr[PC]] then
                        PC := AArr[PC] - 1;
                376: // JMP_BACK (charged)


                    PC := AArr[PC] - 1;
                377: // JMP_IF_FALSE_BACK (charged)


                    if not RegBool[CurBaseBool + BArr[PC]] then
                        PC := AArr[PC] - 1;
                378: // JMP_IF_TRUE_BACK (charged)


                    if RegBool[CurBaseBool + BArr[PC]] then
                        PC := AArr[PC] - 1;
                // --- fused branch-compares (P3): A = target, B = left int reg, C = right
                // int reg (_IMM: C = the immediate value). BF_* jumps when the comparison is
                // FALSE, BT_* when TRUE. _BACK twins additionally charge the budget. ---
                379: // BF_EQ_I
                    if RegInt[CurBaseInt + BArr[PC]] <> RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                380: // BF_NE_I
                    if RegInt[CurBaseInt + BArr[PC]] = RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                381: // BF_LT_I
                    if RegInt[CurBaseInt + BArr[PC]] >= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                382: // BF_LE_I
                    if RegInt[CurBaseInt + BArr[PC]] > RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                383: // BF_GT_I
                    if RegInt[CurBaseInt + BArr[PC]] <= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                384: // BF_GE_I
                    if RegInt[CurBaseInt + BArr[PC]] < RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                385: // BT_EQ_I
                    if RegInt[CurBaseInt + BArr[PC]] = RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                386: // BT_NE_I
                    if RegInt[CurBaseInt + BArr[PC]] <> RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                387: // BT_LT_I
                    if RegInt[CurBaseInt + BArr[PC]] < RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                388: // BT_LE_I
                    if RegInt[CurBaseInt + BArr[PC]] <= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                389: // BT_GT_I
                    if RegInt[CurBaseInt + BArr[PC]] > RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                390: // BT_GE_I
                    if RegInt[CurBaseInt + BArr[PC]] >= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                391: // BF_EQ_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] <> CArr[PC] then
                        PC := AArr[PC] - 1;
                392: // BF_NE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] = CArr[PC] then
                        PC := AArr[PC] - 1;
                393: // BF_LT_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] >= CArr[PC] then
                        PC := AArr[PC] - 1;
                394: // BF_LE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] > CArr[PC] then
                        PC := AArr[PC] - 1;
                395: // BF_GT_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] <= CArr[PC] then
                        PC := AArr[PC] - 1;
                396: // BF_GE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] < CArr[PC] then
                        PC := AArr[PC] - 1;
                397: // BT_EQ_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] = CArr[PC] then
                        PC := AArr[PC] - 1;
                398: // BT_NE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] <> CArr[PC] then
                        PC := AArr[PC] - 1;
                399: // BT_LT_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] < CArr[PC] then
                        PC := AArr[PC] - 1;
                400: // BT_LE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] <= CArr[PC] then
                        PC := AArr[PC] - 1;
                401: // BT_GT_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] > CArr[PC] then
                        PC := AArr[PC] - 1;
                402: // BT_GE_I_IMM
                    if RegInt[CurBaseInt + BArr[PC]] >= CArr[PC] then
                        PC := AArr[PC] - 1;
                403: // BF_EQ_I_BACK (charged — loop back-edges land here, keep inline)


                    if RegInt[CurBaseInt + BArr[PC]] <> RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                404: // BF_NE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] = RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                405: // BF_LT_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] >= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                406: // BF_LE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] > RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                407: // BF_GT_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                408: // BF_GE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] < RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                409: // BT_EQ_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] = RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                410: // BT_NE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <> RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                411: // BT_LT_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] < RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                412: // BT_LE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                413: // BT_GT_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] > RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                414: // BT_GE_I_BACK


                    if RegInt[CurBaseInt + BArr[PC]] >= RegInt[CurBaseInt + CArr[PC]] then
                        PC := AArr[PC] - 1;
                415: // BF_EQ_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <> CArr[PC] then
                        PC := AArr[PC] - 1;
                416: // BF_NE_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] = CArr[PC] then
                        PC := AArr[PC] - 1;
                417: // BF_LT_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] >= CArr[PC] then
                        PC := AArr[PC] - 1;
                418: // BF_LE_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] > CArr[PC] then
                        PC := AArr[PC] - 1;
                419: // BF_GT_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <= CArr[PC] then
                        PC := AArr[PC] - 1;
                420: // BF_GE_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] < CArr[PC] then
                        PC := AArr[PC] - 1;
                421: // BT_EQ_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] = CArr[PC] then
                        PC := AArr[PC] - 1;
                422: // BT_NE_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] <> CArr[PC] then
                        PC := AArr[PC] - 1;
                423: // BT_LT_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] < CArr[PC] then
                        PC := AArr[PC] - 1;
                424: // BT_LE_I_IMM_BACK



                    if RegInt[CurBaseInt + BArr[PC]] <= CArr[PC] then
                        PC := AArr[PC] - 1;
                425: // BT_GT_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] > CArr[PC] then
                        PC := AArr[PC] - 1;
                426: // BT_GE_I_IMM_BACK


                    if RegInt[CurBaseInt + BArr[PC]] >= CArr[PC] then
                        PC := AArr[PC] - 1;
                32: // MOV_I
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                43: // LOAD_CONST_I
                    RegInt[CurBaseInt + AArr[PC]] := CPoolInt[BArr[PC]];
                64: // ADD_I (native overflow)
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] + RegInt[CurBaseInt + CArr[PC]];
                65: // SUB_I
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] - RegInt[CurBaseInt + CArr[PC]];
                66: // MUL_I
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] * RegInt[CurBaseInt + CArr[PC]];
                67: // DIV_I (native div; div-by-zero raises)
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] div RegInt[CurBaseInt + CArr[PC]];
                68: // MOD_I
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] mod RegInt[CurBaseInt + CArr[PC]];
                427: // ADD_I_IMM (C = immediate value; native overflow)
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] + CArr[PC];
                428: // SUB_I_IMM
                    RegInt[CurBaseInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] - CArr[PC];
                96: // CMP_EQ_I
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] = RegInt[CurBaseInt + CArr[PC]];
                97:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] <> RegInt[CurBaseInt + CArr[PC]];
                98:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] < RegInt[CurBaseInt + CArr[PC]];
                99:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] <= RegInt[CurBaseInt + CArr[PC]];
                100:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] > RegInt[CurBaseInt + CArr[PC]];
                101:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] >= RegInt[CurBaseInt + CArr[PC]];
                429: // CMP_EQ_I_IMM (C = immediate value)
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] = CArr[PC];
                430:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] <> CArr[PC];
                431:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] < CArr[PC];
                432:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] <= CArr[PC];
                433:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] > CArr[PC];
                434:
                    RegBool[CurBaseBool + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]] >= CArr[PC];
                5:  // FOR_INIT_UP: skip loop when init already beyond limit (§5.3)
                    if RegInt[CurBaseInt + AArr[PC]] > RegInt[CurBaseInt + BArr[PC]] then
                        PC := CArr[PC] - 1;
                6:  // FOR_INIT_DOWN
                    if RegInt[CurBaseInt + AArr[PC]] < RegInt[CurBaseInt + BArr[PC]] then
                        PC := CArr[PC] - 1;
                114: // AND_B (both operands were evaluated — no short-circuit, §15.2)
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] and RegBool[CurBaseBool + CArr[PC]];
                115: // OR_B
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] or RegBool[CurBaseBool + CArr[PC]];
                116: // XOR_B
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] xor RegBool[CurBaseBool + CArr[PC]];
                117: // NOT_B
                    RegBool[CurBaseBool + AArr[PC]] := not RegBool[CurBaseBool + BArr[PC]];
                1:  // STMT (legacy — no longer emitted; kept as a plain budget tick)
                    ;

                // --- calls (M5) ---
                192: // CALL (charged: recursion is the only STMT-free loop shape left)
                    // Push a frame for Callee: save state, advance every base by the CALLER's counts,
                    // check the callee window fits every register file, jump to the callee entry PC.
                    // inline PushFrame(x)
                    //CalleeRow: Integer;
                    //CallerRow: Integer;
                    //Callee: AArr[PC]
                    begin
                        // P1: calls are budget-charged (with back-edges, they cover every loop shape —
                        // unbounded recursion alone must still exhaust the runaway budget).
                        StmtCounter += 1;
                        if StmtCounter > StmtBudget then
                            Error('ALI950: statement budget exhausted after %1 statements', StmtBudget);
                        if FrameSP >= 1024 then
                            Error('ALI952: call stack exhausted (max %1 interpreted frames)', 1024);
                        FrameSP += 1;
                        FrRetPC[FrameSP] := PC;     // the CALL's own PC — the loop-top increment resumes AFTER it (P2)
                        FrProcId[FrameSP] := CurProcIdVal;
                        FrBInt[FrameSP] := CurBaseInt;
                        FrBBig[FrameSP] := CurBaseBig;
                        FrBDec[FrameSP] := CurBaseDec;
                        FrBBool[FrameSP] := CurBaseBool;
                        FrBText[FrameSP] := CurBaseText;
                        FrBDate[FrameSP] := CurBaseDate;
                        FrBTime[FrameSP] := CurBaseTime;
                        FrBDT[FrameSP] := CurBaseDT;
                        FrBDur[FrameSP] := CurBaseDur;
                        FrBGuid[FrameSP] := CurBaseGuid;
                        FrBVar[FrameSP] := CurBaseVar;
                        FrBRecordId[FrameSP] := CurBaseRecordId;
                        FrBDateFormula[FrameSP] := CurBaseDateFormula;
                        FrAllocBase[FrameSP] := AllocKindStack.Count(); // Handle Lifecycle Unification: snapshot BEFORE the callee allocates its own handles

                        // Advance every base past the CALLER's own window (CurProcIdVal is still the caller).
                        CallerRow := (CurProcIdVal - 1) * 13;
                        CurBaseInt += PTRegCnt[CallerRow + 1];
                        CurBaseBig += PTRegCnt[CallerRow + 2];
                        CurBaseDec += PTRegCnt[CallerRow + 3];
                        CurBaseBool += PTRegCnt[CallerRow + 4];
                        CurBaseText += PTRegCnt[CallerRow + 5];
                        CurBaseDate += PTRegCnt[CallerRow + 6];
                        CurBaseTime += PTRegCnt[CallerRow + 7];
                        CurBaseDT += PTRegCnt[CallerRow + 8];
                        CurBaseDur += PTRegCnt[CallerRow + 9];
                        CurBaseGuid += PTRegCnt[CallerRow + 10];
                        CurBaseVar += PTRegCnt[CallerRow + 11];
                        CurBaseRecordId += PTRegCnt[CallerRow + 12];
                        CurBaseDateFormula += PTRegCnt[CallerRow + 13];

                        // A reserved proc row whose body was never lowered (a signatures-only
                        // harvest, a procedure the reachability worklist never reached). Its entry
                        // pc is 0, which is not a pc — jumping there used to land on the module's
                        // FIRST instruction and silently run somebody else's code.
                        if PTEntry[AArr[PC]] <= 0 then
                            Error('ALI964: procedure #%1 was called but its body was never compiled into this module (signatures-only harvest, or it was not reachable from the entry procedure)', AArr[PC]);

                        CalleeRow := (AArr[PC] - 1) * 13;
                        if (CurBaseInt + PTRegCnt[CalleeRow + 1] > 8192) or
                           (CurBaseBig + PTRegCnt[CalleeRow + 2] > 2048) or
                           (CurBaseDec + PTRegCnt[CalleeRow + 3] > 4096) or
                           (CurBaseBool + PTRegCnt[CalleeRow + 4] > 4096) or
                           (CurBaseText + PTRegCnt[CalleeRow + 5] > 2048) or
                           (CurBaseDate + PTRegCnt[CalleeRow + 6] > 2048) or
                           (CurBaseTime + PTRegCnt[CalleeRow + 7] > 2048) or
                           (CurBaseDT + PTRegCnt[CalleeRow + 8] > 2048) or
                           (CurBaseDur + PTRegCnt[CalleeRow + 9] > 2048) or
                           (CurBaseGuid + PTRegCnt[CalleeRow + 10] > 2048) or
                           (CurBaseVar + PTRegCnt[CalleeRow + 11] > 256) or
                           (CurBaseRecordId + PTRegCnt[CalleeRow + 12] > 2048) or
                           (CurBaseDateFormula + PTRegCnt[CalleeRow + 13] > 2048)
                        then
                            Error('ALI953: register file exhausted at interpreted call depth %1', FrameSP);

                        CurProcIdVal := AArr[PC];
                        PC := PTEntry[AArr[PC]] - 1;  // pre-increment convention (P2)

                        // CurWin* cache = the (new) bases + the CALLEE's counts. Inlined RecomputeCurWin:
                        // CalleeRow is already resolved for the bounds check above, so this is 13 array reads
                        // with zero call overhead on the per-interpreted-CALL path.
                        CurWinInt := CurBaseInt + PTRegCnt[CalleeRow + 1];
                        CurWinBig := CurBaseBig + PTRegCnt[CalleeRow + 2];
                        CurWinDec := CurBaseDec + PTRegCnt[CalleeRow + 3];
                        CurWinBool := CurBaseBool + PTRegCnt[CalleeRow + 4];
                        CurWinText := CurBaseText + PTRegCnt[CalleeRow + 5];
                        CurWinDate := CurBaseDate + PTRegCnt[CalleeRow + 6];
                        CurWinTime := CurBaseTime + PTRegCnt[CalleeRow + 7];
                        CurWinDT := CurBaseDT + PTRegCnt[CalleeRow + 8];
                        CurWinDur := CurBaseDur + PTRegCnt[CalleeRow + 9];
                        CurWinGuid := CurBaseGuid + PTRegCnt[CalleeRow + 10];
                        CurWinVar := CurBaseVar + PTRegCnt[CalleeRow + 11];
                        CurWinRecordId := CurBaseRecordId + PTRegCnt[CalleeRow + 12];
                        CurWinDateFormula := CurBaseDateFormula + PTRegCnt[CalleeRow + 13];

                        // M11 phase B2: which instance's object globals this frame addresses. The
                        // hidden index was staged as an ordinary Int argument, so it already sits
                        // in the (now current) frame at its param slot.
                        CurInstRow := 0;
                        if PTSelfSlot[CurProcIdVal] > 0 then
                            CurInstRow := (RegInt[CurBaseInt + PTSelfSlot[CurProcIdVal]] - 1) * 13;
                    end;
                9, 197: // RET / RET_VAL: pop frame; entry frame halts
                    if FrameSP = 0 then
                        PC := InstrTotal
                    else begin
                        //PopFrame();
                        // Phase "return escape": if the popping proc's result is itself a handle-kind value,
                        // that value must survive this frame's reclaim below — it is the thing being handed
                        // to the caller (exit(h) / RESULT_FETCH reads it right after this pop). Read it now,
                        // BEFORE CurBaseInt is restored, while it still points at the callee's own window.
                        // Precomputed at LoadModule (see PTResIsHandle) — this used to run a call plus a ~10-term
                        // ordinal-range predicate on every single interpreted return.
                        ResultIsHandle := PTResIsHandle[CurProcIdVal];
                        Escaped := false;
                        if ResultIsHandle then begin
                            EscKind := PTResTypeOrd[CurProcIdVal];
                            EscHandle := RegInt[CurBaseInt + PTResSlot[CurProcIdVal]];
                        end;

                        // Handle Lifecycle Unification: reclaim every LOCAL handle-kind value (Array/List/
                        // Dictionary/Http*) this frame allocated, before restoring the caller's bases — except
                        // the one this frame is returning by value (skipped once; re-tracked in the caller's
                        // segment below, ownership transfers). A handle that escaped via a var-param/global
                        // store was already untracked at the store site (HANDLE_ESCAPE/ExecHandleEscape), so
                        // it is simply absent from this segment and neither freed nor re-tracked here.
                        while AllocKindStack.Count() > FrAllocBase[FrameSP] do begin
                            k := AllocKindStack.Get(AllocKindStack.Count());
                            H := AllocHandleStack.Get(AllocHandleStack.Count());
                            AllocKindStack.RemoveAt(AllocKindStack.Count());
                            AllocHandleStack.RemoveAt(AllocHandleStack.Count());
                            if ResultIsHandle and (not Escaped) and (k = EscKind) and (H = EscHandle) then
                                Escaped := true     // first match only — ownership transfers, do not free
                            else
                                FreeHandleByKind(k, H);
                        end;

                        CurBaseInt := FrBInt[FrameSP];
                        CurBaseBig := FrBBig[FrameSP];
                        CurBaseDec := FrBDec[FrameSP];
                        CurBaseBool := FrBBool[FrameSP];
                        CurBaseText := FrBText[FrameSP];
                        CurBaseDate := FrBDate[FrameSP];
                        CurBaseTime := FrBTime[FrameSP];
                        CurBaseDT := FrBDT[FrameSP];
                        CurBaseDur := FrBDur[FrameSP];
                        CurBaseGuid := FrBGuid[FrameSP];
                        CurBaseVar := FrBVar[FrameSP];
                        CurBaseRecordId := FrBRecordId[FrameSP];
                        CurBaseDateFormula := FrBDateFormula[FrameSP];
                        CurProcIdVal := FrProcId[FrameSP];
                        PC := FrRetPC[FrameSP];
                        FrameSP -= 1;

                        // Inlined RecomputeCurWin (see PushFrame) — the restored proc's own counts off one row.
                        Row := (CurProcIdVal - 1) * 13;
                        CurWinInt := CurBaseInt + PTRegCnt[Row + 1];
                        CurWinBig := CurBaseBig + PTRegCnt[Row + 2];
                        CurWinDec := CurBaseDec + PTRegCnt[Row + 3];
                        CurWinBool := CurBaseBool + PTRegCnt[Row + 4];
                        CurWinText := CurBaseText + PTRegCnt[Row + 5];
                        CurWinDate := CurBaseDate + PTRegCnt[Row + 6];
                        CurWinTime := CurBaseTime + PTRegCnt[Row + 7];
                        CurWinDT := CurBaseDT + PTRegCnt[Row + 8];
                        CurWinDur := CurBaseDur + PTRegCnt[Row + 9];
                        CurWinGuid := CurBaseGuid + PTRegCnt[Row + 10];
                        CurWinVar := CurBaseVar + PTRegCnt[Row + 11];
                        CurWinRecordId := CurBaseRecordId + PTRegCnt[Row + 12];
                        CurWinDateFormula := CurBaseDateFormula + PTRegCnt[Row + 13];

                        // M11 phase B2: restore the CALLER's instance alongside its window cache.
                        CurInstRow := 0;
                        if PTSelfSlot[CurProcIdVal] > 0 then
                            CurInstRow := (RegInt[CurBaseInt + PTSelfSlot[CurProcIdVal]] - 1) * 13;

                        // Ownership transfer: the returned handle is now the CALLER's responsibility — re-track
                        // it in the caller's (now current) alloc-stack segment so a later pop/Reset reclaims it.
                        // Only if it was actually found above: a proc that returns a value it did NOT itself
                        // allocate this call (e.g. `exit(SomeGlobal)` or a passed-through by-value param) never
                        // matches, so Escaped stays false and nothing is re-tracked — correct, ownership never
                        // left wherever it already was.
                        if Escaped then
                            TrackLocalHandle(EscKind, EscHandle);
                    end;
                // ARG_VAL / RESULT_FETCH / GLOB_* / *_IND were one-call-site `local procedure`s
                // whose whole body was a 13-arm class switch. An AL procedure call costs ~450ns —
                // ~10x the couple of array reads it wrapped — and each of these fires on every
                // argument passed, every result taken and every module-level variable touched, so
                // the bodies are inlined here. Single call site each, so nothing is duplicated:
                // the procedures were deleted, not copied. ARG_REF still calls StageArgRef — its
                // body is ~150 lines (3-way alias mode per class) and var-params are far rarer.
                198: // ARG_VAL — A = callee param slot, B = caller src reg, C = class
                    case CArr[PC] of
                        1:
                            RegInt[CurWinInt + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                        2:
                            RegBig[CurWinBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                        3:
                            RegDec[CurWinDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                        4:
                            RegBool[CurWinBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]];
                        5:
                            RegText[CurWinText + AArr[PC]] := RegText[CurBaseText + BArr[PC]];
                        6:
                            RegDate[CurWinDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]];
                        7:
                            RegTime[CurWinTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]];
                        8:
                            RegDT[CurWinDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]];
                        9:
                            RegDur[CurWinDur + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]];
                        10:
                            RegGuid[CurWinGuid + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]];
                        11:
                            begin
                                RegVariant[CurWinVar + AArr[PC]] := RegVariant[CurBaseVar + BArr[PC]];
                                RegVarTag[CurWinVar + AArr[PC]] := RegVarTag[CurBaseVar + BArr[PC]];
                            end;
                        12:
                            RegRecordId[CurWinRecordId + AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]];
                        13:
                            RegDateFormula[CurWinDateFormula + AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]];
                    end;
                199: // ARG_REF
                    StageArgRef(AArr[PC], BArr[PC], CArr[PC]);
                200: // RESULT_FETCH — A = caller dest reg, B = callee result slot, C = class
                    case CArr[PC] of
                        1:
                            RegInt[CurBaseInt + AArr[PC]] := RegInt[CurWinInt + BArr[PC]];
                        2:
                            RegBig[CurBaseBig + AArr[PC]] := RegBig[CurWinBig + BArr[PC]];
                        3:
                            RegDec[CurBaseDec + AArr[PC]] := RegDec[CurWinDec + BArr[PC]];
                        4:
                            RegBool[CurBaseBool + AArr[PC]] := RegBool[CurWinBool + BArr[PC]];
                        5:
                            RegText[CurBaseText + AArr[PC]] := RegText[CurWinText + BArr[PC]];
                        6:
                            RegDate[CurBaseDate + AArr[PC]] := RegDate[CurWinDate + BArr[PC]];
                        7:
                            RegTime[CurBaseTime + AArr[PC]] := RegTime[CurWinTime + BArr[PC]];
                        8:
                            RegDT[CurBaseDT + AArr[PC]] := RegDT[CurWinDT + BArr[PC]];
                        9:
                            RegDur[CurBaseDur + AArr[PC]] := RegDur[CurWinDur + BArr[PC]];
                        10:
                            RegGuid[CurBaseGuid + AArr[PC]] := RegGuid[CurWinGuid + BArr[PC]];
                        11:
                            begin
                                RegVariant[CurBaseVar + AArr[PC]] := RegVariant[CurWinVar + BArr[PC]];
                                RegVarTag[CurBaseVar + AArr[PC]] := RegVarTag[CurWinVar + BArr[PC]];
                            end;
                        12:
                            RegRecordId[CurBaseRecordId + AArr[PC]] := RegRecordId[CurWinRecordId + BArr[PC]];
                        13:
                            RegDateFormula[CurBaseDateFormula + AArr[PC]] := RegDateFormula[CurWinDateFormula + BArr[PC]];
                    end;
                201: // GLOB_LOAD — A = dest reg rel, B = ABSOLUTE slot, C = class
                    case CArr[PC] of
                        1:
                            RegInt[CurBaseInt + AArr[PC]] := RegInt[BArr[PC]];
                        2:
                            RegBig[CurBaseBig + AArr[PC]] := RegBig[BArr[PC]];
                        3:
                            RegDec[CurBaseDec + AArr[PC]] := RegDec[BArr[PC]];
                        4:
                            RegBool[CurBaseBool + AArr[PC]] := RegBool[BArr[PC]];
                        5:
                            RegText[CurBaseText + AArr[PC]] := RegText[BArr[PC]];
                        6:
                            RegDate[CurBaseDate + AArr[PC]] := RegDate[BArr[PC]];
                        7:
                            RegTime[CurBaseTime + AArr[PC]] := RegTime[BArr[PC]];
                        8:
                            RegDT[CurBaseDT + AArr[PC]] := RegDT[BArr[PC]];
                        9:
                            RegDur[CurBaseDur + AArr[PC]] := RegDur[BArr[PC]];
                        10:
                            RegGuid[CurBaseGuid + AArr[PC]] := RegGuid[BArr[PC]];
                        11:
                            begin
                                RegVariant[CurBaseVar + AArr[PC]] := RegVariant[BArr[PC]];
                                RegVarTag[CurBaseVar + AArr[PC]] := RegVarTag[BArr[PC]];
                            end;
                        12:
                            RegRecordId[CurBaseRecordId + AArr[PC]] := RegRecordId[BArr[PC]];
                        13:
                            RegDateFormula[CurBaseDateFormula + AArr[PC]] := RegDateFormula[BArr[PC]];
                    end;
                202: // GLOB_STORE — A = ABSOLUTE slot, B = src reg rel, C = class
                    case CArr[PC] of
                        1:
                            RegInt[AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                        2:
                            RegBig[AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                        3:
                            RegDec[AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                        4:
                            RegBool[AArr[PC]] := RegBool[CurBaseBool + BArr[PC]];
                        5:
                            RegText[AArr[PC]] := RegText[CurBaseText + BArr[PC]];
                        6:
                            RegDate[AArr[PC]] := RegDate[CurBaseDate + BArr[PC]];
                        7:
                            RegTime[AArr[PC]] := RegTime[CurBaseTime + BArr[PC]];
                        8:
                            RegDT[AArr[PC]] := RegDT[CurBaseDT + BArr[PC]];
                        9:
                            RegDur[AArr[PC]] := RegDur[CurBaseDur + BArr[PC]];
                        10:
                            RegGuid[AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]];
                        11:
                            begin
                                RegVariant[AArr[PC]] := RegVariant[CurBaseVar + BArr[PC]];
                                RegVarTag[AArr[PC]] := RegVarTag[CurBaseVar + BArr[PC]];
                            end;
                        12:
                            RegRecordId[AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]];
                        13:
                            RegDateFormula[AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]];
                    end;
                203: // SELF_LOAD — A = dest reg rel, B = offset in this instance's block, C = class
                    case CArr[PC] of
                        1:
                            RegInt[CurBaseInt + AArr[PC]] := RegInt[InstBaseArr[CurInstRow + 1] + BArr[PC]];
                        2:
                            RegBig[CurBaseBig + AArr[PC]] := RegBig[InstBaseArr[CurInstRow + 2] + BArr[PC]];
                        3:
                            RegDec[CurBaseDec + AArr[PC]] := RegDec[InstBaseArr[CurInstRow + 3] + BArr[PC]];
                        4:
                            RegBool[CurBaseBool + AArr[PC]] := RegBool[InstBaseArr[CurInstRow + 4] + BArr[PC]];
                        5:
                            RegText[CurBaseText + AArr[PC]] := RegText[InstBaseArr[CurInstRow + 5] + BArr[PC]];
                        6:
                            RegDate[CurBaseDate + AArr[PC]] := RegDate[InstBaseArr[CurInstRow + 6] + BArr[PC]];
                        7:
                            RegTime[CurBaseTime + AArr[PC]] := RegTime[InstBaseArr[CurInstRow + 7] + BArr[PC]];
                        8:
                            RegDT[CurBaseDT + AArr[PC]] := RegDT[InstBaseArr[CurInstRow + 8] + BArr[PC]];
                        9:
                            RegDur[CurBaseDur + AArr[PC]] := RegDur[InstBaseArr[CurInstRow + 9] + BArr[PC]];
                        10:
                            RegGuid[CurBaseGuid + AArr[PC]] := RegGuid[InstBaseArr[CurInstRow + 10] + BArr[PC]];
                        11:
                            begin
                                RegVariant[CurBaseVar + AArr[PC]] := RegVariant[InstBaseArr[CurInstRow + 11] + BArr[PC]];
                                RegVarTag[CurBaseVar + AArr[PC]] := RegVarTag[InstBaseArr[CurInstRow + 11] + BArr[PC]];
                            end;
                        12:
                            RegRecordId[CurBaseRecordId + AArr[PC]] := RegRecordId[InstBaseArr[CurInstRow + 12] + BArr[PC]];
                        13:
                            RegDateFormula[CurBaseDateFormula + AArr[PC]] := RegDateFormula[InstBaseArr[CurInstRow + 13] + BArr[PC]];
                    end;
                204: // SELF_STORE — A = offset in this instance's block, B = src reg rel, C = class
                    case CArr[PC] of
                        1:
                            RegInt[InstBaseArr[CurInstRow + 1] + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                        2:
                            RegBig[InstBaseArr[CurInstRow + 2] + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                        3:
                            RegDec[InstBaseArr[CurInstRow + 3] + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                        4:
                            RegBool[InstBaseArr[CurInstRow + 4] + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]];
                        5:
                            RegText[InstBaseArr[CurInstRow + 5] + AArr[PC]] := RegText[CurBaseText + BArr[PC]];
                        6:
                            RegDate[InstBaseArr[CurInstRow + 6] + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]];
                        7:
                            RegTime[InstBaseArr[CurInstRow + 7] + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]];
                        8:
                            RegDT[InstBaseArr[CurInstRow + 8] + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]];
                        9:
                            RegDur[InstBaseArr[CurInstRow + 9] + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]];
                        10:
                            RegGuid[InstBaseArr[CurInstRow + 10] + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]];
                        11:
                            begin
                                RegVariant[InstBaseArr[CurInstRow + 11] + AArr[PC]] := RegVariant[CurBaseVar + BArr[PC]];
                                RegVarTag[InstBaseArr[CurInstRow + 11] + AArr[PC]] := RegVarTag[CurBaseVar + BArr[PC]];
                            end;
                        12:
                            RegRecordId[InstBaseArr[CurInstRow + 12] + AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]];
                        13:
                            RegDateFormula[InstBaseArr[CurInstRow + 13] + AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]];
                    end;
                52: // LOAD_IND (var param read) — A = dest reg, B = param slot, C = class
                    case CArr[PC] of
                        1:
                            RegInt[CurBaseInt + AArr[PC]] := RegInt[RefInt[CurBaseInt + BArr[PC]]];
                        2:
                            RegBig[CurBaseBig + AArr[PC]] := RegBig[RefBig[CurBaseBig + BArr[PC]]];
                        3:
                            RegDec[CurBaseDec + AArr[PC]] := RegDec[RefDec[CurBaseDec + BArr[PC]]];
                        4:
                            RegBool[CurBaseBool + AArr[PC]] := RegBool[RefBool[CurBaseBool + BArr[PC]]];
                        5:
                            RegText[CurBaseText + AArr[PC]] := RegText[RefText[CurBaseText + BArr[PC]]];
                        6:
                            RegDate[CurBaseDate + AArr[PC]] := RegDate[RefDate[CurBaseDate + BArr[PC]]];
                        7:
                            RegTime[CurBaseTime + AArr[PC]] := RegTime[RefTime[CurBaseTime + BArr[PC]]];
                        8:
                            RegDT[CurBaseDT + AArr[PC]] := RegDT[RefDT[CurBaseDT + BArr[PC]]];
                        9:
                            RegDur[CurBaseDur + AArr[PC]] := RegDur[RefDur[CurBaseDur + BArr[PC]]];
                        10:
                            RegGuid[CurBaseGuid + AArr[PC]] := RegGuid[RefGuid[CurBaseGuid + BArr[PC]]];
                        11:
                            begin
                                RegVariant[CurBaseVar + AArr[PC]] := RegVariant[RefVar[CurBaseVar + BArr[PC]]];
                                RegVarTag[CurBaseVar + AArr[PC]] := RegVarTag[RefVar[CurBaseVar + BArr[PC]]];
                            end;
                        12:
                            RegRecordId[CurBaseRecordId + AArr[PC]] := RegRecordId[RefRecordId[CurBaseRecordId + BArr[PC]]];
                        13:
                            RegDateFormula[CurBaseDateFormula + AArr[PC]] := RegDateFormula[RefDateFormula[CurBaseDateFormula + BArr[PC]]];
                    end;
                53: // STORE_IND (var param write) — A = param slot, B = src reg, C = class
                    case CArr[PC] of
                        1:
                            RegInt[RefInt[CurBaseInt + AArr[PC]]] := RegInt[CurBaseInt + BArr[PC]];
                        2:
                            RegBig[RefBig[CurBaseBig + AArr[PC]]] := RegBig[CurBaseBig + BArr[PC]];
                        3:
                            RegDec[RefDec[CurBaseDec + AArr[PC]]] := RegDec[CurBaseDec + BArr[PC]];
                        4:
                            RegBool[RefBool[CurBaseBool + AArr[PC]]] := RegBool[CurBaseBool + BArr[PC]];
                        5:
                            RegText[RefText[CurBaseText + AArr[PC]]] := RegText[CurBaseText + BArr[PC]];
                        6:
                            RegDate[RefDate[CurBaseDate + AArr[PC]]] := RegDate[CurBaseDate + BArr[PC]];
                        7:
                            RegTime[RefTime[CurBaseTime + AArr[PC]]] := RegTime[CurBaseTime + BArr[PC]];
                        8:
                            RegDT[RefDT[CurBaseDT + AArr[PC]]] := RegDT[CurBaseDT + BArr[PC]];
                        9:
                            RegDur[RefDur[CurBaseDur + AArr[PC]]] := RegDur[CurBaseDur + BArr[PC]];
                        10:
                            RegGuid[RefGuid[CurBaseGuid + AArr[PC]]] := RegGuid[CurBaseGuid + BArr[PC]];
                        11:
                            begin
                                RegVariant[RefVar[CurBaseVar + AArr[PC]]] := RegVariant[CurBaseVar + BArr[PC]];
                                RegVarTag[RefVar[CurBaseVar + AArr[PC]]] := RegVarTag[CurBaseVar + BArr[PC]];
                            end;
                        12:
                            RegRecordId[RefRecordId[CurBaseRecordId + AArr[PC]]] := RegRecordId[CurBaseRecordId + BArr[PC]];
                        13:
                            RegDateFormula[RefDateFormula[CurBaseDateFormula + AArr[PC]]] := RegDateFormula[CurBaseDateFormula + BArr[PC]];
                    end;
                // --- moves / loads ---
                33:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                34:
                    RegDec[CurBaseDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                35:
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]];
                36:
                    RegText[CurBaseText + AArr[PC]] := RegText[CurBaseText + BArr[PC]];
                37:
                    RegDate[CurBaseDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]];
                38:
                    RegTime[CurBaseTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]];
                39:
                    RegDT[CurBaseDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]];
                40:
                    RegDur[CurBaseDur + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]];
                41:
                    RegGuid[CurBaseGuid + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]];
                42:
                    begin
                        RegVariant[CurBaseVar + AArr[PC]] := RegVariant[CurBaseVar + BArr[PC]];
                        RegVarTag[CurBaseVar + AArr[PC]] := RegVarTag[CurBaseVar + BArr[PC]];
                    end;
                350: // MOV_RECID
                    RegRecordId[CurBaseRecordId + AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]];
                351: // CMP_EQ_RECID
                    RegBool[CurBaseBool + AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]] = RegRecordId[CurBaseRecordId + CArr[PC]];
                352: // CMP_NE_RECID
                    RegBool[CurBaseBool + AArr[PC]] := RegRecordId[CurBaseRecordId + BArr[PC]] <> RegRecordId[CurBaseRecordId + CArr[PC]];
                356: // MOV_DF
                    RegDateFormula[CurBaseDateFormula + AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]];
                357: // CMP_EQ_DF
                    RegBool[CurBaseBool + AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]] = RegDateFormula[CurBaseDateFormula + CArr[PC]];
                358: // CMP_NE_DF
                    RegBool[CurBaseBool + AArr[PC]] := RegDateFormula[CurBaseDateFormula + BArr[PC]] <> RegDateFormula[CurBaseDateFormula + CArr[PC]];
                359: // CONV_TEXT_DF — native implicit Text->DateFormula conversion (runtime error on bad syntax)
                    Evaluate(RegDateFormula[CurBaseDateFormula + AArr[PC]], RegText[CurBaseText + BArr[PC]]);
                44:
                    RegBig[CurBaseBig + AArr[PC]] := CPoolBig[BArr[PC]];
                45:
                    RegDec[CurBaseDec + AArr[PC]] := CPoolDec[BArr[PC]];
                46: // LOAD_CONST_B — immediate
                    RegBool[CurBaseBool + AArr[PC]] := BArr[PC] = 1;
                47:
                    RegText[CurBaseText + AArr[PC]] := CPoolText[BArr[PC]];
                48:
                    RegDate[CurBaseDate + AArr[PC]] := CPoolDate[BArr[PC]];
                49:
                    RegTime[CurBaseTime + AArr[PC]] := CPoolTime[BArr[PC]];
                50:
                    RegDT[CurBaseDT + AArr[PC]] := CPoolDT[BArr[PC]];
                51: // STORE_TEXT_CHK: C = MaxLen*2 + IsCode (§7.2 store-side checks)
                    begin
                        TxtVal := RegText[CurBaseText + BArr[PC]];
                        if (CArr[PC] mod 2) = 1 then
                            TxtVal := UpperCase(TxtVal);
                        MaxLen := CArr[PC] div 2;
                        if (MaxLen > 0) and (StrLen(TxtVal) > MaxLen) then
                            Error('The length of the string is %1, but it must be less than or equal to %2 characters. Value: %3', StrLen(TxtVal), MaxLen, TxtVal);
                        RegText[CurBaseText + AArr[PC]] := TxtVal;
                    end;
                // --- remaining arithmetic ---
                69:
                    RegInt[CurBaseInt + AArr[PC]] := -RegInt[CurBaseInt + BArr[PC]];
                70:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] + RegBig[CurBaseBig + CArr[PC]];
                71:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] - RegBig[CurBaseBig + CArr[PC]];
                72:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] * RegBig[CurBaseBig + CArr[PC]];
                73:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] div RegBig[CurBaseBig + CArr[PC]];
                74:
                    RegBig[CurBaseBig + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] mod RegBig[CurBaseBig + CArr[PC]];
                75:
                    RegBig[CurBaseBig + AArr[PC]] := -RegBig[CurBaseBig + BArr[PC]];
                76:
                    RegDec[CurBaseDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] + RegDec[CurBaseDec + CArr[PC]];
                77:
                    RegDec[CurBaseDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] - RegDec[CurBaseDec + CArr[PC]];
                78:
                    RegDec[CurBaseDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] * RegDec[CurBaseDec + CArr[PC]];
                79: // DIV_D — `/` (native decimal division; div-by-zero raises)
                    RegDec[CurBaseDec + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] / RegDec[CurBaseDec + CArr[PC]];
                80:
                    RegDec[CurBaseDec + AArr[PC]] := -RegDec[CurBaseDec + BArr[PC]];
                81: // CAT_T
                    RegText[CurBaseText + AArr[PC]] := RegText[CurBaseText + BArr[PC]] + RegText[CurBaseText + CArr[PC]];
                82: // CONCAT_N — fused chain via TextBuilder (§15 pitfall 9)
                    begin
                        Clear(Sb);
                        for k := 0 to CArr[PC] - 1 do
                            Sb.Append(RegText[CurBaseText + OperArr[BArr[PC] + k]]);
                        RegText[CurBaseText + AArr[PC]] := Sb.ToText();
                    end;
                83: // ADD_DATE_I
                    RegDate[CurBaseDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] + RegInt[CurBaseInt + CArr[PC]];
                84:
                    RegDate[CurBaseDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] - RegInt[CurBaseInt + CArr[PC]];
                85: // SUB_DATE_DATE -> Integer days (BuiltInOperators.ReturnType)
                    RegInt[CurBaseInt + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] - RegDate[CurBaseDate + CArr[PC]];
                86:
                    RegDate[CurBaseDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] + RegDur[CurBaseDur + CArr[PC]];
                87:
                    RegDate[CurBaseDate + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] - RegDur[CurBaseDur + CArr[PC]];
                88:
                    RegTime[CurBaseTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] + RegDur[CurBaseDur + CArr[PC]];
                89:
                    RegTime[CurBaseTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] - RegDur[CurBaseDur + CArr[PC]];
                90: // SUB_TIME_TIME -> Integer ms
                    RegInt[CurBaseInt + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] - RegTime[CurBaseTime + CArr[PC]];
                91:
                    RegDT[CurBaseDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] + RegDur[CurBaseDur + CArr[PC]];
                92:
                    RegDT[CurBaseDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] - RegDur[CurBaseDur + CArr[PC]];
                93: // SUB_DT_DT -> Duration
                    RegDur[CurBaseDur + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] - RegDT[CurBaseDT + CArr[PC]];
                // --- remaining comparisons ---
                102:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] = RegDec[CurBaseDec + CArr[PC]];
                103:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] <> RegDec[CurBaseDec + CArr[PC]];
                104:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] < RegDec[CurBaseDec + CArr[PC]];
                105:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] <= RegDec[CurBaseDec + CArr[PC]];
                106:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] > RegDec[CurBaseDec + CArr[PC]];
                107:
                    RegBool[CurBaseBool + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]] >= RegDec[CurBaseDec + CArr[PC]];
                108:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] = RegText[CurBaseText + CArr[PC]];
                109:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] <> RegText[CurBaseText + CArr[PC]];
                110:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] < RegText[CurBaseText + CArr[PC]];
                111:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] <= RegText[CurBaseText + CArr[PC]];
                112:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] > RegText[CurBaseText + CArr[PC]];
                113:
                    RegBool[CurBaseBool + AArr[PC]] := RegText[CurBaseText + BArr[PC]] >= RegText[CurBaseText + CArr[PC]];
                128:
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] = RegBool[CurBaseBool + CArr[PC]];
                129:
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] <> RegBool[CurBaseBool + CArr[PC]];
                130: // false < true — expressed in pure Boolean logic
                    RegBool[CurBaseBool + AArr[PC]] := (not RegBool[CurBaseBool + BArr[PC]]) and RegBool[CurBaseBool + CArr[PC]];
                131:
                    RegBool[CurBaseBool + AArr[PC]] := (not RegBool[CurBaseBool + BArr[PC]]) or RegBool[CurBaseBool + CArr[PC]];
                132:
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] and (not RegBool[CurBaseBool + CArr[PC]]);
                133:
                    RegBool[CurBaseBool + AArr[PC]] := RegBool[CurBaseBool + BArr[PC]] or (not RegBool[CurBaseBool + CArr[PC]]);
                134:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] = RegBig[CurBaseBig + CArr[PC]];
                135:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] <> RegBig[CurBaseBig + CArr[PC]];
                136:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] < RegBig[CurBaseBig + CArr[PC]];
                137:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] <= RegBig[CurBaseBig + CArr[PC]];
                138:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] > RegBig[CurBaseBig + CArr[PC]];
                139:
                    RegBool[CurBaseBool + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]] >= RegBig[CurBaseBig + CArr[PC]];
                140:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] = RegDate[CurBaseDate + CArr[PC]];
                141:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] <> RegDate[CurBaseDate + CArr[PC]];
                142:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] < RegDate[CurBaseDate + CArr[PC]];
                143:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] <= RegDate[CurBaseDate + CArr[PC]];
                144:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] > RegDate[CurBaseDate + CArr[PC]];
                145:
                    RegBool[CurBaseBool + AArr[PC]] := RegDate[CurBaseDate + BArr[PC]] >= RegDate[CurBaseDate + CArr[PC]];
                146:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] = RegTime[CurBaseTime + CArr[PC]];
                147:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] <> RegTime[CurBaseTime + CArr[PC]];
                148:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] < RegTime[CurBaseTime + CArr[PC]];
                149:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] <= RegTime[CurBaseTime + CArr[PC]];
                150:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] > RegTime[CurBaseTime + CArr[PC]];
                151:
                    RegBool[CurBaseBool + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] >= RegTime[CurBaseTime + CArr[PC]];
                152:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] = RegDT[CurBaseDT + CArr[PC]];
                153:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] <> RegDT[CurBaseDT + CArr[PC]];
                154:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] < RegDT[CurBaseDT + CArr[PC]];
                155:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] <= RegDT[CurBaseDT + CArr[PC]];
                156:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] > RegDT[CurBaseDT + CArr[PC]];
                157:
                    RegBool[CurBaseBool + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] >= RegDT[CurBaseDT + CArr[PC]];
                160:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] = RegDur[CurBaseDur + CArr[PC]];
                161:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] <> RegDur[CurBaseDur + CArr[PC]];
                162:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] < RegDur[CurBaseDur + CArr[PC]];
                163:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] <= RegDur[CurBaseDur + CArr[PC]];
                164:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] > RegDur[CurBaseDur + CArr[PC]];
                165:
                    RegBool[CurBaseBool + AArr[PC]] := RegDur[CurBaseDur + BArr[PC]] >= RegDur[CurBaseDur + CArr[PC]];
                166:
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] = RegGuid[CurBaseGuid + CArr[PC]];
                167:
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] <> RegGuid[CurBaseGuid + CArr[PC]];
                168: // native Guid ordering (GuidLessThan 0x1833)
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] < RegGuid[CurBaseGuid + CArr[PC]];
                169:
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] <= RegGuid[CurBaseGuid + CArr[PC]];
                170:
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] > RegGuid[CurBaseGuid + CArr[PC]];
                171:
                    RegBool[CurBaseBool + AArr[PC]] := RegGuid[CurBaseGuid + BArr[PC]] >= RegGuid[CurBaseGuid + CArr[PC]];
                // --- conversions (native semantics) ---
                172: // CONV_I_D
                    RegDec[CurBaseDec + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                173: // CONV_BIG_D
                    RegDec[CurBaseDec + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                174: // CONV_D_I — native narrowing (rounds; §6.4 pitfall 24)
                    RegInt[CurBaseInt + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                175: // CONV_D_BIG
                    RegBig[CurBaseBig + AArr[PC]] := RegDec[CurBaseDec + BArr[PC]];
                176: // CONV_I_BIG
                    RegBig[CurBaseBig + AArr[PC]] := RegInt[CurBaseInt + BArr[PC]];
                177: // CONV_BIG_I — native overflow check
                    RegInt[CurBaseInt + AArr[PC]] := RegBig[CurBaseBig + BArr[PC]];
                178: // CONV_I_CHAR — native checked 0..65535
                    begin
                        ChScratch := RegInt[CurBaseInt + BArr[PC]];
                        RegInt[CurBaseInt + AArr[PC]] := ChScratch;
                    end;
                179: // CONV_I_BYTE — native checked 0..255
                    begin
                        ByScratch := RegInt[CurBaseInt + BArr[PC]];
                        RegInt[CurBaseInt + AArr[PC]] := ByScratch;
                    end;
                180: // CONV_T_CODE
                    RegText[CurBaseText + AArr[PC]] := UpperCase(RegText[CurBaseText + BArr[PC]]);
                181: // TO_TEXT: C = source register class
                    RegText[CurBaseText + AArr[PC]] := FormatRegister(CArr[PC], BArr[PC]);
                360: // OPT_TO_TEXT: A=out Text reg, B=src Int reg (ordinal), C=set id (§D4)
                    RegText[CurBaseText + AArr[PC]] := OptionMeta.CaptionOf(CArr[PC], RegInt[CurBaseInt + BArr[PC]]);
                361: // ADD_DT_I — DateTime + Int -> DateTime (native DateTimeAndIntegerAddition)
                    RegDT[CurBaseDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] + RegInt[CurBaseInt + CArr[PC]];
                362: // SUB_DT_I
                    RegDT[CurBaseDT + AArr[PC]] := RegDT[CurBaseDT + BArr[PC]] - RegInt[CurBaseInt + CArr[PC]];
                363: // ADD_TIME_I — Time + Int -> Time (native TimeAndIntegerAddition)
                    RegTime[CurBaseTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] + RegInt[CurBaseInt + CArr[PC]];
                364: // SUB_TIME_I
                    RegTime[CurBaseTime + AArr[PC]] := RegTime[CurBaseTime + BArr[PC]] - RegInt[CurBaseInt + CArr[PC]];
                372: // CONV_BOX: C = tag*16 + srcRegClass. RegVariant[A] := <reg B of class srcRegClass>
                     // boxed; RegVarTag[A] := tag (0 for scalars, aggregate ALI type for handle boxes).
                    begin
                        RegVariant[CurBaseVar + AArr[PC]] := ReadRegisterAsVariant(CArr[PC] mod 16, BArr[PC]);
                        RegVarTag[CurBaseVar + AArr[PC]] := CArr[PC] div 16;
                    end;
                373: // CONV_UNBOX: <reg A of class C> := RegVariant[B] (native runtime error on type mismatch)
                    WriteRegisterFromVariant(CArr[PC], AArr[PC], RegVariant[CurBaseVar + BArr[PC]]);
                374: // BOX_REC: A = dest variant reg, B = record handle (absolute). Box the handle int, tag = Record (§19.2 reference semantics).
                    begin
                        RegVariant[CurBaseVar + AArr[PC]] := BArr[PC];
                        RegVarTag[CurBaseVar + AArr[PC]] := "ALI TypeKind"::Record;
                    end;
                375: // UNBOX_REC: A = dest record handle (absolute), B = src variant reg. REC_COPY content from the boxed handle.
                    ExecUnboxRec(AArr[PC], BArr[PC]);
                // REC_NEXT — A = handle reg, B = dest int reg, C = step reg. Hoisted out of the
                // ExecRecordOp group like REC_FLD_*: it runs once per row of every record loop.
                228:
                    RegInt[CurBaseInt + BArr[PC]] := RecRt.NextRec(RegInt[CurBaseInt + AArr[PC]], RegInt[CurBaseInt + CArr[PC]]);
                // --- records (family 7) + native-Record-method sweep (family 9) ---
                224, 225, 226, 227, 229, 230, 231, 232, 233, 234, 235, 236, 237, 238, 239, 240,
                241, 242, 243, 244, 245, 246,
                265, 266, 267, 268, 269, 270, 271, 272, 273, 274, 275, 276, 277, 278, 279, 280, 281, 282, 283,
                284, 286, 287, 288, 289, 290, 291, 292, 293, 294, 295, 296, 297, 298, 299, 300, 301,
                302, 303, 304,
                309, 310, 311, 312, 313, 314, 315, 317, 318, 319, 320, 321,
                353, 354, 355, 369, 370,
                438, 439, 440, 441, 442, 443, 444, 445, 446, 447, 448, 449, 450,
                453, 454, 455, 456, 457:
                    ExecRecordOp(OpArr[PC], AArr[PC], BArr[PC], CArr[PC]);
                // REC_FLD_LOAD / REC_FLD_STORE are hoisted out of the ExecRecordOp group: field
                // access is the dominant opcode in record-loop scripts, and routing it through
                // the group handler cost 3 AL calls (ExecRecordOp + the Rec Runtime getter +
                // WriteRegisterFromVariant/ReadRegisterAsVariant) at ~450ns each. Int/Decimal/
                // Boolean/Text go straight to a typed "ALI Rec Runtime" accessor — 1 call. The
                // remaining 9 classes keep the generic Variant pair.
                // A = dest/src reg, B = handle reg, C = fieldNo*16 + class.
                // PERF TEST — cached-FieldRef arms. Hit = zero AL calls; miss = one BindFieldRef call.
                // A cache hit requires FcHandle = RIdx AND RIdx >= 1 (tested in a separate if before the epoch
                // read below never indexes FcHEpoch[0]); FcHandle only ever stores a handle that
                // just bound successfully, so FcHEpoch[RIdx] is in range. Variant/RecordId/
                // DateFormula registers keep the Variant path (tag/conversion semantics).
                247: // REC_FLD_LOAD
                    begin
                        RIdx := CurBaseInt + BArr[PC];
                        if (RIdx < 1) or (RIdx > 8192) then
                            RIdx := 0
                        else
                            RIdx := RegInt[RIdx];
                        FcSite := FcSiteOfPC[PC];
                        FcMiss := (FcHandle[FcSite] <> RIdx) or (RIdx < 1);
                        if not FcMiss then
                            FcMiss := FcStamp[FcSite] <> FcHEpoch[RIdx] + FcGen;
                        if FcMiss then begin
                            RecRt.BindFieldRef(RIdx, CArr[PC] div 16, FcRef[FcSite]);
                            if FcSite < ArrayLen(FcHandle) then begin
                                FcHandle[FcSite] := RIdx;
                                FcStamp[FcSite] := FcHEpoch[RIdx] + FcGen;
                            end;
                        end;
                        case CArr[PC] mod 16 of
                            1:
                                RegInt[CurBaseInt + AArr[PC]] := FcRef[FcSite].Value;
                            2:
                                RegBig[CurBaseBig + AArr[PC]] := FcRef[FcSite].Value;
                            3:
                                RegDec[CurBaseDec + AArr[PC]] := FcRef[FcSite].Value;
                            4:
                                RegBool[CurBaseBool + AArr[PC]] := FcRef[FcSite].Value;
                            5:
                                RegText[CurBaseText + AArr[PC]] := FcRef[FcSite].Value;
                            6:
                                RegDate[CurBaseDate + AArr[PC]] := FcRef[FcSite].Value;
                            7:
                                RegTime[CurBaseTime + AArr[PC]] := FcRef[FcSite].Value;
                            8:
                                RegDT[CurBaseDT + AArr[PC]] := FcRef[FcSite].Value;
                            9:
                                RegDur[CurBaseDur + AArr[PC]] := FcRef[FcSite].Value;
                            10:
                                RegGuid[CurBaseGuid + AArr[PC]] := FcRef[FcSite].Value;
                            else begin
                                VScratch := FcRef[FcSite].Value;
                                WriteRegisterFromVariant(CArr[PC] mod 16, AArr[PC], VScratch);
                            end;
                        end;
                    end;
                248: // REC_FLD_STORE
                    begin
                        RIdx := CurBaseInt + AArr[PC];
                        if (RIdx < 1) or (RIdx > 8192) then
                            RIdx := 0
                        else
                            RIdx := RegInt[RIdx];
                        FcSite := FcSiteOfPC[PC];
                        FcMiss := (FcHandle[FcSite] <> RIdx) or (RIdx < 1);
                        if not FcMiss then
                            FcMiss := FcStamp[FcSite] <> FcHEpoch[RIdx] + FcGen;
                        if FcMiss then begin
                            RecRt.BindFieldRef(RIdx, CArr[PC] div 16, FcRef[FcSite]);
                            if FcSite < ArrayLen(FcHandle) then begin
                                FcHandle[FcSite] := RIdx;
                                FcStamp[FcSite] := FcHEpoch[RIdx] + FcGen;
                            end;
                        end;
                        case CArr[PC] mod 16 of
                            1:
                                FcRef[FcSite].Value(RegInt[CurBaseInt + BArr[PC]]);
                            2:
                                FcRef[FcSite].Value(RegBig[CurBaseBig + BArr[PC]]);
                            3:
                                FcRef[FcSite].Value(RegDec[CurBaseDec + BArr[PC]]);
                            4:
                                FcRef[FcSite].Value(RegBool[CurBaseBool + BArr[PC]]);
                            5:
                                FcRef[FcSite].Value(RegText[CurBaseText + BArr[PC]]);
                            6:
                                FcRef[FcSite].Value(RegDate[CurBaseDate + BArr[PC]]);
                            7:
                                FcRef[FcSite].Value(RegTime[CurBaseTime + BArr[PC]]);
                            8:
                                FcRef[FcSite].Value(RegDT[CurBaseDT + BArr[PC]]);
                            9:
                                FcRef[FcSite].Value(RegDur[CurBaseDur + BArr[PC]]);
                            10:
                                FcRef[FcSite].Value(RegGuid[CurBaseGuid + BArr[PC]]);
                            else
                                FcRef[FcSite].Value(ReadRegisterAsVariant(CArr[PC] mod 16, BArr[PC]));
                        end;
                    end;
                // end PERF TEST
                // PERF TEST original (uncomment to revert, delete the cached arms above):
                // 247: // REC_FLD_LOAD
                //     begin
                //         RIdx := CurBaseInt + BArr[PC];
                //         if (RIdx < 1) or (RIdx > 8192) then
                //             RIdx := 0
                //         else
                //             RIdx := RegInt[RIdx];
                //         case CArr[PC] mod 16 of
                //             1:
                //                 RegInt[CurBaseInt + AArr[PC]] := RecRt.GetFieldInt(RIdx, CArr[PC] div 16);
                //             3:
                //                 RegDec[CurBaseDec + AArr[PC]] := RecRt.GetFieldDec(RIdx, CArr[PC] div 16);
                //             4:
                //                 RegBool[CurBaseBool + AArr[PC]] := RecRt.GetFieldBool(RIdx, CArr[PC] div 16);
                //             5:
                //                 RegText[CurBaseText + AArr[PC]] := RecRt.GetFieldText(RIdx, CArr[PC] div 16);
                //             else begin
                //                 VScratch := RecRt.GetFieldValue(RIdx, CArr[PC] div 16);
                //                 WriteRegisterFromVariant(CArr[PC] mod 16, AArr[PC], VScratch);
                //             end;
                //         end;
                //     end;
                // 248: // REC_FLD_STORE
                //     begin
                //         RIdx := CurBaseInt + AArr[PC];
                //         if (RIdx < 1) or (RIdx > 8192) then
                //             RIdx := 0
                //         else
                //             RIdx := RegInt[RIdx];
                //         case CArr[PC] mod 16 of
                //             1:
                //                 RecRt.SetFieldInt(RIdx, CArr[PC] div 16, RegInt[CurBaseInt + BArr[PC]]);
                //             3:
                //                 RecRt.SetFieldDec(RIdx, CArr[PC] div 16, RegDec[CurBaseDec + BArr[PC]]);
                //             4:
                //                 RecRt.SetFieldBool(RIdx, CArr[PC] div 16, RegBool[CurBaseBool + BArr[PC]]);
                //             5:
                //                 RecRt.SetFieldText(RIdx, CArr[PC] div 16, RegText[CurBaseText + BArr[PC]]);
                //             else
                //                 RecRt.SetFieldValue(RIdx, CArr[PC] div 16,
                //                     ReadRegisterAsVariant(CArr[PC] mod 16, BArr[PC]));
                //         end;
                //     end;
                // ARR_LOAD  A = dest reg, B = handle reg, C = flatIndexReg*16 + elemClass. The flat
                // index is bounds-checked in "ALI Array Runtime" (per-dimension check ran in
                // ARR_DIM_CHECK, §20.7).
                256:
                    case CArr[PC] mod 16 of
                        1:
                            RegInt[CurBaseInt + AArr[PC]] := ArrayRt.ReadCell(RegInt[CurBaseInt + BArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)]);
                        5:
                            RegText[CurBaseText + AArr[PC]] := ArrayRt.ReadCell(RegInt[CurBaseInt + BArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)]);
                        else
                            WriteRegisterFromVariant(CArr[PC] mod 16, AArr[PC], ArrayRt.ReadCell(RegInt[CurBaseInt + BArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)]));
                    end;
                // ARR_STORE  A = handle reg, B = src reg, C = flatIndexReg*16 + elemClass.
                257:
                    case CArr[PC] mod 16 of
                        1:
                            ArrayRt.WriteCell(RegInt[CurBaseInt + AArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)], RegInt[CurBaseInt + BArr[PC]]);
                        5:
                            ArrayRt.WriteCell(RegInt[CurBaseInt + AArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)], RegText[CurBaseText + BArr[PC]]);
                        else
                            ArrayRt.WriteCell(RegInt[CurBaseInt + AArr[PC]], RegInt[CurBaseInt + (CArr[PC] div 16)], ReadRegisterAsVariant(CArr[PC] mod 16, BArr[PC]));
                    end;
                365: // ARR_COMPRESS
                    ExecArrCompress(AArr[PC], BArr[PC], CArr[PC]);
                366: // ARR_COPY
                    ExecArrCopy(AArr[PC], BArr[PC], CArr[PC]);
                367: // ARR_NEW
                    ExecArrNew(AArr[PC], BArr[PC], CArr[PC]); // Native-exact per-dimension check before the flat-index fold (§20.7 option (b)).
                368:
                    if (RegInt[CurBaseInt + AArr[PC]] < 1) or (RegInt[CurBaseInt + AArr[PC]] > BArr[PC]) then
                        Error('ALI957: array index %1 out of bounds for dimension %2 (1..%3)', RegInt[CurBaseInt + AArr[PC]], CArr[PC], BArr[PC]);
                322: // TXT_CHAR_GET
                    begin
                        //inline of ExecTxtCharGet(AArr[PC], BArr[PC], CArr[PC]);
                        // TXT_CHAR_GET A=dest int reg (Char), B=src text reg, C=index int reg.
                        // ===== §19.4-analog text array access — shared by both dispatch shapes =====
                        // Implemented by delegating straight to native AL's own indexed-Text get/set (the exact
                        // feature being emulated for the interpreted language) rather than hand-rolling CopyStr/
                        // PadStr splicing.
                        TxtVal := RegText[CurBaseText + BArr[PC]];
                        Idx := RegInt[CurBaseInt + CArr[PC]];
                        if (Idx < 1) or (Idx > StrLen(TxtVal)) then
                            Error('ALI972: text index %1 out of bounds (1..%2)', Idx, StrLen(TxtVal));
                        RegInt[CurBaseInt + AArr[PC]] := TxtVal[Idx];
                    end;

                323: // TXT_CHAR_SET
                    ExecTxtCharSet(AArr[PC], BArr[PC], CArr[PC]);
                324: // TXT_CHAR_SET_TEXT
                    ExecTxtCharSetText(AArr[PC], BArr[PC], CArr[PC]);
                325: // CHAR_TO_TEXT
                    ExecCharToText(AArr[PC], BArr[PC]);
                258, 259, 260, 261, 262, 263, 264, 461, 462, 463, 464, 465: // stream RefShim ops (§19.7)
                    ExecStreamOp(OpArr[PC], AArr[PC], BArr[PC], CArr[PC]);
                305: // EVALUATE_TARGET (§1.1/§19.8 M7)
                    ExecEvaluateTarget(AArr[PC], BArr[PC], CArr[PC]);
                306: // CLEAR_TARGET
                    ExecClearTarget(AArr[PC], BArr[PC], CArr[PC]);
                // CALL_BUILTIN_LIVE (§1.1/§8/§19.4/§19.6 M7): A = BuiltinId, B = operand-pool start
                // (each entry regIdx*16+class, read LIVE — no eager boxing at lower time), C =
                // OutReg*512 + OutCls*32 + ArgCount. Unboxes each arg to a Variant, dispatches by
                // the builtin's Domain to the matching "ALI Builtin *" codeunit, writes the result
                // back into the destination register. Inlined: hot in record loops (StrLen/CopyStr/
                // Round/... per row), where the call frame was a measurable share of the builtin.
                // ClearAll never reaches here — the lowerer expands it into typed CLEAR_TARGETs.
                307:
                    begin
                        BId := AArr[PC];
                        BOperStart := BArr[PC];
                        BArgCount := CArr[PC] mod 32;
                        for BIdx := 1 to BArgCount do
                            if BIdx <= 16 then
                                BArgs[BIdx] := ReadRegisterAsVariant(OperArr[BOperStart + BIdx - 1] mod 16, OperArr[BOperStart + BIdx - 1] div 16);
                        // ponytail: BResultV is not cleared between calls — every arm with an out
                        // register assigns it; a builtin that returned nothing would reuse the last value.
                        // BIds past the memo share its last slot as scratch: never marked Ok, so the
                        // registry getters run again on every such call.
                        BSlot := BId;
                        if BSlot >= ArrayLen(BMemoOk) then
                            BSlot := ArrayLen(BMemoOk);
                        if not BMemoOk[BSlot] then begin
                            BMemoName[BSlot] := BuiltinRegistry.GetNameUpper(BId);
                            BMemoDomain[BSlot] := BuiltinRegistry.GetDomain(BId);
                            BMemoKind[BSlot] := BuiltinRegistry.GetKind(BId);
                            BMemoOk[BSlot] := BSlot < ArrayLen(BMemoOk);
                        end;
                        case BMemoKind[BSlot] of
                            // Split returns a List of [Text] handle (built here — needs List runtime
                            // access). Args[1] = receiver, Args[2..] = separators.
                            "ALI Builtin Kind"::Split:
                                BResultV := ExecTextSplit(BArgs, BArgCount);
                            // §19.2 Variant type tests — the receiver register's TAG tells boxed
                            // handles (Record/List/Dictionary/Array) apart from native scalars.
                            "ALI Builtin Kind"::VariantTest:
                                BResultV := ExecVariantTest(BMemoName[BSlot], BArgs[1], RegVarTag[CurBaseVar + (OperArr[BOperStart] div 16)]);
                            else
                                case BMemoDomain[BSlot] of
                                    // Str builtins + §19.4 Text-method aliases, inlined (a procedure call
                                    // costs more than most of these native string statements). Aliases
                                    // share one branch — "one implementation" per §19.4.
                                    "ALI Builtin Domain"::Str:
                                        case BMemoName[BSlot] of
                                            // native CopyStr silently returns '' when start > len(s)+1;
                                            // §1.1 requires a raised error, so the bound is checked here.
                                            'COPYSTR', 'SUBSTRING':
                                                begin
                                                    BStrText := Format(BArgs[1]);
                                                    BStrInt := BArgs[2];
                                                    if (BStrInt < 1) or (BStrInt > StrLen(BStrText) + 1) then
                                                        Error('ALI981: CopyStr start position %1 is out of range for a string of length %2', BStrInt, StrLen(BStrText));
                                                    if BArgCount >= 3 then begin
                                                        BStrLen := BArgs[3];
                                                        BResultV := CopyStr(BStrText, BStrInt, BStrLen);
                                                    end else
                                                        BResultV := CopyStr(BStrText, BStrInt);
                                                end;
                                            'STRLEN':
                                                BResultV := StrLen(Format(BArgs[1]));
                                            'STRPOS':
                                                BResultV := StrPos(Format(BArgs[1]), Format(BArgs[2]));
                                            // SecretStrSubstNo differs only in its declared RESULT TYPE (SecretText).
                                            // BStrFmt is global: unused slots must be reset to ''.
                                            'STRSUBSTNO', 'SECRETSTRSUBSTNO':
                                                begin
                                                    for BIdx := 1 to 9 do
                                                        if BIdx < BArgCount then
                                                            BStrFmt[BIdx] := Format(BArgs[BIdx + 1])
                                                        else
                                                            BStrFmt[BIdx] := '';
                                                    BResultV := StrSubstNo(Format(BArgs[1]), BStrFmt[1], BStrFmt[2], BStrFmt[3], BStrFmt[4], BStrFmt[5], BStrFmt[6], BStrFmt[7], BStrFmt[8], BStrFmt[9]);
                                                end;
                                            // Format(value[, len][, fmt]) — fmt is a standard-format number or a format string.
                                            'FORMAT':
                                                if BArgCount = 1 then
                                                    BResultV := Format(BArgs[1])
                                                else begin
                                                    BStrLen := BArgs[2];
                                                    if BArgCount = 2 then
                                                        BResultV := Format(BArgs[1], BStrLen)
                                                    else
                                                        if BArgs[3].IsInteger() or BArgs[3].IsOption() then begin
                                                            BStrInt := BArgs[3];
                                                            BResultV := Format(BArgs[1], BStrLen, BStrInt);
                                                        end else
                                                            BResultV := Format(BArgs[1], BStrLen, Format(BArgs[3]));
                                                end;
                                            'LOWERCASE', 'TOLOWER':
                                                BResultV := LowerCase(Format(BArgs[1]));
                                            'UPPERCASE', 'TOUPPER':
                                                BResultV := UpperCase(Format(BArgs[1]));
                                            // DelChr(s[, where][, chars]) — where: '<' leading, '>' trailing, '=' (default) all.
                                            'DELCHR':
                                                case BArgCount of
                                                    1:
                                                        BResultV := DelChr(Format(BArgs[1]), '=');
                                                    2:
                                                        BResultV := DelChr(Format(BArgs[1]), Format(BArgs[2]));
                                                    else
                                                        BResultV := DelChr(Format(BArgs[1]), Format(BArgs[2]), Format(BArgs[3]));
                                                end;
                                            'CONVERTSTR':
                                                BResultV := ConvertStr(Format(BArgs[1]), Format(BArgs[2]), Format(BArgs[3]));
                                            // PadStr(s, len[, fillChar]) — default fill is space.
                                            'PADSTR':
                                                begin
                                                    BStrLen := BArgs[2];
                                                    if BArgCount >= 3 then
                                                        BStrText := Format(BArgs[3])
                                                    else
                                                        BStrText := '';
                                                    if BStrText <> '' then
                                                        BResultV := PadStr(Format(BArgs[1]), BStrLen, BStrText[1])
                                                    else
                                                        BResultV := PadStr(Format(BArgs[1]), BStrLen);
                                                end;
                                            'INCSTR':
                                                BResultV := IncStr(Format(BArgs[1]));
                                            'SELECTSTR':
                                                BResultV := SelectStr(BArgs[1], Format(BArgs[2]));
                                            // DelStr(s, pos[, len]) — default deletes to end.
                                            'DELSTR':
                                                begin
                                                    BStrInt := BArgs[2];
                                                    if BArgCount >= 3 then begin
                                                        BStrLen := BArgs[3];
                                                        BResultV := DelStr(Format(BArgs[1]), BStrInt, BStrLen);
                                                    end else
                                                        BResultV := DelStr(Format(BArgs[1]), BStrInt);
                                                end;
                                            'INSSTR':
                                                begin
                                                    BStrInt := BArgs[3];
                                                    BResultV := InsStr(Format(BArgs[1]), Format(BArgs[2]), BStrInt);
                                                end;
                                            // StrCheckSum(s[, weight][, modulus])
                                            'STRCHECKSUM':
                                                case BArgCount of
                                                    1:
                                                        BResultV := StrCheckSum(Format(BArgs[1]));
                                                    2:
                                                        BResultV := StrCheckSum(Format(BArgs[1]), Format(BArgs[2]));
                                                    else begin
                                                        BStrInt := BArgs[3];
                                                        BResultV := StrCheckSum(Format(BArgs[1]), Format(BArgs[2]), BStrInt);
                                                    end;
                                                end;
                                            'TRIM':
                                                BResultV := Format(BArgs[1]).Trim();
                                            'TRIMSTART':
                                                if BArgCount >= 2 then
                                                    BResultV := Format(BArgs[1]).TrimStart(Format(BArgs[2]))
                                                else
                                                    BResultV := Format(BArgs[1]).TrimStart();
                                            'TRIMEND':
                                                if BArgCount >= 2 then
                                                    BResultV := Format(BArgs[1]).TrimEnd(Format(BArgs[2]))
                                                else
                                                    BResultV := Format(BArgs[1]).TrimEnd();
                                            'REPLACE':
                                                BResultV := Format(BArgs[1]).Replace(Format(BArgs[2]), Format(BArgs[3]));
                                            'CONTAINS':
                                                BResultV := Format(BArgs[1]).Contains(Format(BArgs[2]));
                                            // IndexOf(s, value[, startIndex]) — 2-arg keeps StrPos semantics.
                                            'INDEXOF':
                                                if BArgCount >= 3 then begin
                                                    BStrInt := BArgs[3];
                                                    BResultV := Format(BArgs[1]).IndexOf(Format(BArgs[2]), BStrInt);
                                                end else
                                                    BResultV := StrPos(Format(BArgs[1]), Format(BArgs[2]));
                                            'LASTINDEXOF':
                                                if BArgCount >= 3 then begin
                                                    BStrInt := BArgs[3];
                                                    BResultV := Format(BArgs[1]).LastIndexOf(Format(BArgs[2]), BStrInt);
                                                end else
                                                    BResultV := Format(BArgs[1]).LastIndexOf(Format(BArgs[2]));
                                            'INDEXOFANY':
                                                if BArgCount >= 3 then begin
                                                    BStrInt := BArgs[3];
                                                    BResultV := Format(BArgs[1]).IndexOfAny(Format(BArgs[2]), BStrInt);
                                                end else
                                                    BResultV := Format(BArgs[1]).IndexOfAny(Format(BArgs[2]));
                                            'STARTSWITH':
                                                BResultV := Format(BArgs[1]).StartsWith(Format(BArgs[2]));
                                            'ENDSWITH':
                                                BResultV := Format(BArgs[1]).EndsWith(Format(BArgs[2]));
                                            // PadLeft/PadRight(s, count[, char]) — default fill is space.
                                            'PADLEFT':
                                                begin
                                                    BStrLen := BArgs[2];
                                                    if BArgCount >= 3 then
                                                        BStrText := Format(BArgs[3])
                                                    else
                                                        BStrText := '';
                                                    if BStrText <> '' then
                                                        BResultV := Format(BArgs[1]).PadLeft(BStrLen, BStrText[1])
                                                    else
                                                        BResultV := Format(BArgs[1]).PadLeft(BStrLen);
                                                end;
                                            'PADRIGHT':
                                                begin
                                                    BStrLen := BArgs[2];
                                                    if BArgCount >= 3 then
                                                        BStrText := Format(BArgs[3])
                                                    else
                                                        BStrText := '';
                                                    if BStrText <> '' then
                                                        BResultV := Format(BArgs[1]).PadRight(BStrLen, BStrText[1])
                                                    else
                                                        BResultV := Format(BArgs[1]).PadRight(BStrLen);
                                                end;
                                            // Remove(s, startIndex[, count]) — default removes to end.
                                            'REMOVE':
                                                begin
                                                    BStrInt := BArgs[2];
                                                    if BArgCount >= 3 then begin
                                                        BStrLen := BArgs[3];
                                                        BResultV := Format(BArgs[1]).Remove(BStrInt, BStrLen);
                                                    end else
                                                        BResultV := Format(BArgs[1]).Remove(BStrInt);
                                                end;
                                            else
                                                Error('ALI980: ''%1'' is not a recognized string builtin', BMemoName[BSlot]);
                                        end;
                                    // Math builtins, inlined like Str (procedure call > statement cost).
                                    "ALI Builtin Domain"::Math:
                                        case BMemoName[BSlot] of
                                            'ABS':
                                                begin
                                                    BNumDec := BArgs[1];
                                                    BResultV := Abs(BNumDec);
                                                end;
                                            // Round(value[, precision][, mode]) — mode: '=' nearest (default), '<' down, '>' up.
                                            'ROUND':
                                                begin
                                                    BNumDec := BArgs[1];
                                                    if BArgCount >= 2 then
                                                        BNumPrec := BArgs[2]
                                                    else
                                                        BNumPrec := 1;
                                                    if BArgCount >= 3 then
                                                        BResultV := Round(BNumDec, BNumPrec, Format(BArgs[3]))
                                                    else
                                                        BResultV := Round(BNumDec, BNumPrec, '=');
                                                end;
                                            'POWER':
                                                begin
                                                    BNumDec := BArgs[1];
                                                    BNumPrec := BArgs[2];
                                                    BResultV := Power(BNumDec, BNumPrec);
                                                end;
                                            'RANDOM':
                                                begin
                                                    BStrInt := BArgs[1];
                                                    BResultV := Random(BStrInt);
                                                end;
                                            'RANDOMIZE':
                                                if BArgCount >= 1 then begin
                                                    BStrInt := BArgs[1];
                                                    Randomize(BStrInt);
                                                end else
                                                    Randomize();
                                            else
                                                Error('ALI980: ''%1'' is not a recognized math builtin', BMemoName[BSlot]);
                                        end;
                                    // Date/time builtins, inlined like Str/Math.
                                    "ALI Builtin Domain"::DateTime:
                                        case BMemoName[BSlot] of
                                            'TODAY':
                                                BResultV := Today();
                                            'TIME':
                                                BResultV := Time();
                                            'CURRENTDATETIME':
                                                BResultV := CurrentDateTime();
                                            'WORKDATE':
                                                BResultV := WorkDate();
                                            // CalcDate(expr[, refDate]) — refDate defaults to WorkDate() (native default).
                                            'CALCDATE':
                                                begin
                                                    if BArgCount >= 2 then
                                                        BDtDate := BArgs[2]
                                                    else
                                                        BDtDate := WorkDate();
                                                    BResultV := CalcDate(Format(BArgs[1]), BDtDate);
                                                end;
                                            'DATE2DMY':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BResultV := Date2DMY(BDtDate, BArgs[2]);
                                                end;
                                            'DATE2DWY':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BResultV := Date2DWY(BDtDate, BArgs[2]);
                                                end;
                                            'DMY2DATE':
                                                BResultV := DMY2Date(BArgs[1], BArgs[2], BArgs[3]);
                                            'DWY2DATE':
                                                BResultV := DWY2Date(BArgs[1], BArgs[2], BArgs[3]);
                                            'CREATEDATETIME':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BDtTime := BArgs[2];
                                                    BResultV := CreateDateTime(BDtDate, BDtTime);
                                                end;
                                            'DT2DATE':
                                                begin
                                                    BDtDT := BArgs[1];
                                                    BResultV := DT2Date(BDtDT);
                                                end;
                                            'DT2TIME':
                                                begin
                                                    BDtDT := BArgs[1];
                                                    BResultV := DT2Time(BDtDT);
                                                end;
                                            'CLOSINGDATE':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BResultV := ClosingDate(BDtDate);
                                                end;
                                            'NORMALDATE':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BResultV := NormalDate(BDtDate);
                                                end;
                                            // RoundDateTime(dt[, precision]) — precision in ms (BigInteger), native default 1000.
                                            'ROUNDDATETIME':
                                                begin
                                                    BDtDT := BArgs[1];
                                                    if BArgCount < 2 then
                                                        BResultV := RoundDateTime(BDtDT)
                                                    else begin
                                                        // Variant->BigInteger direct assignment fails when the boxed value is Integer — widen manually.
                                                        if BArgs[2].IsInteger() then begin
                                                            BStrInt := BArgs[2];
                                                            BDtBig := BStrInt;
                                                        end else
                                                            BDtBig := BArgs[2];
                                                        BResultV := RoundDateTime(BDtDT, BDtBig);
                                                    end;
                                                end;
                                            'DATI2VARIANT':
                                                begin
                                                    BDtDate := BArgs[1];
                                                    BDtTime := BArgs[2];
                                                    BResultV := DaTi2Variant(BDtDate, BDtTime);
                                                end;
                                            'VARIANT2DATE':
                                                BResultV := Variant2Date(BArgs[1]);
                                            'VARIANT2TIME':
                                                BResultV := Variant2Time(BArgs[1]);
                                            else
                                                Error('ALI980: ''%1'' is not a recognized date/time builtin', BMemoName[BSlot]);
                                        end;
                                    "ALI Builtin Domain"::System: // carries the §8 interception side channels
                                        begin
                                            BHasMessage := false;
                                            BWarned := false;
                                            BCollectedMsg := '';
                                            BWarningText := '';
                                            BSystem.Invoke(BMemoName[BSlot], BArgs, BArgCount, BResultV, BHasMessage, BCollectedMsg, BWarned, BWarningText);
                                            if BHasMessage then
                                                PendingMessages.Add(BCollectedMsg);
                                            if BWarned and (BWarningText <> '') then
                                                PendingWarnings.Add(BWarningText);
                                        end;
                                    "ALI Builtin Domain"::Native: // catalogued procedure of a real codeunit, called natively
                                        begin
                                            NativeRt.Invoke(BMemoName[BSlot], BArgs, BArgCount, BResultV);
                                            FcGen += 1;    // PERF TEST — AdoptTempRef re-Copies temp records after native calls
                                            // `var` parameters: put the new value back into the argument's register;
                                            // the lowerer stores it into the variable right after this instruction.
                                            if BuiltinRegistry.GetVarMask(BId) <> 0 then
                                                for BIdx := 1 to BArgCount do
                                                    if BuiltinRegistry.IsVarParam(BId, BIdx) then
                                                        WriteRegisterFromVariant(OperArr[BOperStart + BIdx - 1] mod 16, OperArr[BOperStart + BIdx - 1] div 16, BArgs[BIdx]);
                                        end;
                                    else
                                        Error('ALI951: builtin ''%1'' has no dispatch domain', BMemoName[BSlot]);
                                end;
                        end;
                        if CArr[PC] >= 512 then
                            if (CArr[PC] div 32) mod 16 > 0 then
                                WriteRegisterFromVariant((CArr[PC] div 32) mod 16, CArr[PC] div 512, BResultV);
                    end;
                308: // TB_METHOD (M9 TextBuilder RefShim)
                    ExecTextBuilderOp(AArr[PC], BArr[PC], CArr[PC]);
                466: // BIGTEXT_METHOD (BigText RefShim)
                    ExecBigTextOp(AArr[PC], BArr[PC], CArr[PC]);
                467: // SECRET_METHOD (SecretText members — receiver is a Text register, not a handle)
                    ExecSecretOp(AArr[PC], CArr[PC]);
                469: // REC_BLOB_ENC: A = int reg holding the TextEncoding for the next blob stream op
                    PendingBlobEnc := RegInt[CurBaseInt + AArr[PC]];
                468: // MEDIA_METHOD (Media/MediaSet field members)
                    ExecMediaOp(AArr[PC], BArr[PC], CArr[PC]);
                371: // DLG_METHOD (Dialog RefShim, §8)
                    ExecDialogOp(AArr[PC], BArr[PC], CArr[PC]);
                // List RefShim, hot methods inlined: A = handle reg, B = operand-pool start, C =
                // OutReg*100 + ArgCount. Element class is packed in the handle (handle div 1000000).
                327, 328, 329, 330, 331, 332:
                    begin
                        DHandle := RegInt[CurBaseInt + AArr[PC]];
                        DOutReg := CArr[PC] div 100;
                        // value operand: slot 0 for Add/Contains/IndexOf, slot 1 for Set(index, value)
                        if OpArr[PC] in [327, 329, 331, 332] then begin
                            if OpArr[PC] = 329 then
                                DPacked := OperArr[BArr[PC] + 1]
                            else
                                DPacked := OperArr[BArr[PC]];
                            case DPacked mod 16 of
                                1:
                                    DValV := RegInt[CurBaseInt + (DPacked div 16)];
                                5:
                                    DValV := RegText[CurBaseText + (DPacked div 16)];
                                else
                                    DValV := ReadRegisterAsVariant(DPacked mod 16, DPacked div 16);
                            end;
                        end;
                        // index operand (Get/Set): emitted as Int class in practice
                        if OpArr[PC] in [328, 329] then begin
                            DPacked := OperArr[BArr[PC]];
                            if DPacked mod 16 = 1 then
                                DKeyV := RegInt[CurBaseInt + (DPacked div 16)]
                            else
                                DKeyV := ReadRegisterAsVariant(DPacked mod 16, DPacked div 16);
                        end;
                        case OpArr[PC] of
                            327: // Add(value)
                                ListRt.Add(DHandle, DValV);
                            328: // Get(index) -> T; Int lists skip the Variant round-trip (GetInt)
                                if DOutReg > 0 then
                                    case DHandle div 1000000 of
                                        1:
                                            RegInt[CurBaseInt + DOutReg] := ListRt.GetInt(DHandle, DKeyV);
                                        5:
                                            RegText[CurBaseText + DOutReg] := ListRt.Get(DHandle, DKeyV);
                                        else
                                            WriteRegisterFromVariant(DHandle div 1000000, DOutReg, ListRt.Get(DHandle, DKeyV));
                                    end
                                else
                                    ListRt.Get(DHandle, DKeyV);
                            329: // Set(index, value) -> T (old)
                                if DOutReg > 0 then
                                    WriteRegisterFromVariant(DHandle div 1000000, DOutReg, ListRt.SetAt(DHandle, DKeyV, DValV))
                                else
                                    ListRt.SetAt(DHandle, DKeyV, DValV);
                            330: // Count() -> Integer
                                if DOutReg > 0 then
                                    RegInt[CurBaseInt + DOutReg] := ListRt.Count(DHandle);
                            331: // Contains(value) -> Boolean
                                if DOutReg > 0 then
                                    RegBool[CurBaseBool + DOutReg] := ListRt.Contains(DHandle, DValV)
                                else
                                    ListRt.Contains(DHandle, DValV);
                            332: // IndexOf(value) -> Integer
                                if DOutReg > 0 then
                                    RegInt[CurBaseInt + DOutReg] := ListRt.IndexOf(DHandle, DValV)
                                else
                                    ListRt.IndexOf(DHandle, DValV);
                        end;
                    end;
                326, 333, 334, 335, 336, 337, 338, 339, 340: // List New / Remove / RemoveAt / RemoveRange / Insert / AddRange / GetRange / Reverse
                    ExecListOp(OpArr[PC], AArr[PC], BArr[PC], CArr[PC]);
                // Dictionary RefShim, hot methods inlined: A = handle reg, B = operand-pool start
                // (key, then value), C = OutReg*100. Int/Text operands are read straight off their
                // register (ReadRegisterAsVariant call only for other classes).
                342, 343, 344, 345, 347, 460:
                    begin
                        DHandle := RegInt[CurBaseInt + AArr[PC]];
                        DOutReg := CArr[PC] div 100;
                        if OpArr[PC] <> 347 then begin
                            DPacked := OperArr[BArr[PC]];
                            case DPacked mod 16 of
                                1:
                                    DKeyV := RegInt[CurBaseInt + (DPacked div 16)];
                                5:
                                    DKeyV := RegText[CurBaseText + (DPacked div 16)];
                                else
                                    DKeyV := ReadRegisterAsVariant(DPacked mod 16, DPacked div 16);
                            end;
                        end;
                        if OpArr[PC] in [342, 343] then begin
                            DPacked := OperArr[BArr[PC] + 1];
                            case DPacked mod 16 of
                                1:
                                    DValV := RegInt[CurBaseInt + (DPacked div 16)];
                                5:
                                    DValV := RegText[CurBaseText + (DPacked div 16)];
                                else
                                    DValV := ReadRegisterAsVariant(DPacked mod 16, DPacked div 16);
                            end;
                        end;
                        case OpArr[PC] of
                            343: // Set(key, value) — add-or-update
                                DictRt.SetKV(DHandle, DKeyV, DValV);
                            460: // Get(key, var value) -> Boolean. Operand 1 = caller's value register,
                                 // written back ONLY on a hit (a miss keeps the incoming value).
                                begin
                                    if DictRt.TryGet(DHandle, DKeyV, DValV) then begin
                                        DPacked := OperArr[BArr[PC] + 1];
                                        if DPacked mod 16 = 1 then
                                            RegInt[CurBaseInt + (DPacked div 16)] := DValV
                                        else
                                            WriteRegisterFromVariant(DPacked mod 16, DPacked div 16, DValV);
                                        if DOutReg > 0 then
                                            RegBool[CurBaseBool + DOutReg] := true;
                                    end else
                                        if DOutReg > 0 then
                                            RegBool[CurBaseBool + DOutReg] := false;
                                end;
                            342: // Add(key, value)
                                DictRt.Add(DHandle, DKeyV, DValV);
                            344: // Get(key) -> V (value class packed in the handle)
                                if DOutReg > 0 then
                                    WriteRegisterFromVariant((DHandle div 1000000) mod 16, DOutReg, DictRt.Get(DHandle, DKeyV))
                                else
                                    DictRt.Get(DHandle, DKeyV);
                            345: // ContainsKey(key) -> Boolean
                                if DOutReg > 0 then
                                    RegBool[CurBaseBool + DOutReg] := DictRt.ContainsKey(DHandle, DKeyV)
                                else
                                    DictRt.ContainsKey(DHandle, DKeyV);
                            347: // Count() -> Integer
                                if DOutReg > 0 then
                                    RegInt[CurBaseInt + DOutReg] := DictRt.Count(DHandle);
                        end;
                    end;
                341, 346, 348, 349: // Dictionary New / Remove / Keys / Values
                    ExecDictOp(OpArr[PC], AArr[PC], BArr[PC], CArr[PC]);
                435: // HTTP_METHOD (M10 Http* RefShim)
                    ExecHttpOp(AArr[PC], BArr[PC], CArr[PC]);
                451: // JSON_METHOD (Feature 2 Json* RefShim)
                    ExecJsonOp(AArr[PC], BArr[PC], CArr[PC]);
                452: // JSON_METHOD2 (typed GetX getters, id space 101-199 rebased -100)
                    ExecJsonOp2(AArr[PC], BArr[PC], CArr[PC]);
                458: // XML_METHOD (Feature 3 Xml* RefShim, ids 1-99)
                    ExecXmlOp(AArr[PC], BArr[PC], CArr[PC]);
                459: // XML_METHOD2 (Feature 3 Xml* RefShim, id space 101-199 rebased -100)
                    ExecXmlOp2(AArr[PC], BArr[PC], CArr[PC]);
                436: // HANDLE_ESCAPE
                    begin
                        // A handle-kind value is about to be stored through a var-param alias or
                        // into a global (the ONLY two write shapes "ALI Lowerer".StoreToSym routes through STORE_
                        // IND/GLOB_STORE for a handle-kind target — see its header). It must stop being owned by
                        // the CURRENT frame: scan just this frame's own segment of the alloc stack (entries from
                        // FrAllocBase[FrameSP]+1 upward) for a matching (Kind, Handle) and remove it — a plain
                        // local-to-local `:=` never reaches here (StoreToSym takes the direct-MOV path for that
                        // case), so this only ever fires for the two escape shapes. A miss (the value being stored
                        // was never owned by this frame — e.g. it is itself a global's handle, or a byval param
                        // passed straight through) is a harmless no-op: nothing to un-own here. Accepted v1 limit:
                        // a handle boxed into a Variant (CONV_BOX) is NOT detected as escaping this way (the
                        // target's static type there is Variant, not the handle kind) — such a handle is freed
                        // normally at frame pop even if a Variant alias of it lives on; document alongside.
                        // The scan stops on the FIRST match by driving i to 0 — this arm is INLINE in
                        // RunLoopFlat, so an `exit` here would return from the whole interpreter loop
                        // and silently halt the script at the store (script appears to return the
                        // default value with every later statement dropped).
                        H := RegInt[CurBaseInt + AArr[PC]];
                        i := AllocKindStack.Count();
                        while i >= CurFrameAllocBase() + 1 do
                            if (AllocKindStack.Get(i) = BArr[PC]) and (AllocHandleStack.Get(i) = H) then begin
                                AllocKindStack.RemoveAt(i);
                                AllocHandleStack.RemoveAt(i);
                                i := 0;
                            end else
                                i -= 1;
                    end;
                437: // ARR_REBIND (Handle Lifecycle Unification Phase 5: array-return)
                    ExecArrRebind(AArr[PC], BArr[PC]);
                471: // REF_METHOD (user-declared RecordRef — the RecordRef-ONLY surface; every
                     // other RecordRef method is a REC_* opcode in the group above)
                    ExecRecordRefOp(AArr[PC], BArr[PC], CArr[PC]);
                472: // FLD_METHOD (user-declared FieldRef ids 1-31 / KeyRef ids 40-43)
                    ExecFieldRefOp(AArr[PC], BArr[PC], CArr[PC]);
                470: // CU_RUN (M11 phase C3 — native Codeunit.Run)
                    ExecCodeunitRun(AArr[PC], BArr[PC], CArr[PC]);
                474: // TRY_CALL ([TryFunction] call consumed as a value — cold, re-enters this loop)
                    ExecTryCall(AArr[PC], BArr[PC]);
                473: // NCU_NEW (native stateful codeunit instance — Data Compression)
                    begin
                        H := NativeRt.NewInstance(BArr[PC]);
                        if CArr[PC] = 0 then
                            TrackLocalHandle("ALI TypeKind"::NativeCodeunit.AsInteger(), H);
                        RegInt[CurBaseInt + AArr[PC]] := H;
                    end;
                // --- control tail ---
                10: // ERROR_RAISE
                    Error(RegText[CurBaseText + AArr[PC]]);
                0:  // NOP
                    ;
                else
                    Error('ALI951: invalid opcode %1 at PC %2', OpArr[PC], PC);
            end;
        end;
    end;

    // ===== M11 phase C3 — native Codeunit.Run =====
    //
    // CU_RUN: A = destination Boolean register (0 = result discarded), B = Int register holding
    // the codeunit id, C = Int register holding a record handle (0 = no record).
    //
    // The codeunit is executed by the PLATFORM. Nothing about it is harvested, so its OnRun and
    // everything OnRun reaches stay outside the interpreter entirely — that is the whole point of
    // this opcode, and it is also why no interpreted error trap is needed: native `Codeunit.Run`
    // already returns a Boolean and swallows the error. When the result is DISCARDED the failure
    // is re-raised, exactly as native AL does with an unconsumed Run result.
    local procedure ExecCodeunitRun(A: Integer; B: Integer; C: Integer)
    var
        Ok: Boolean;
        CodeunitId: Integer;
        RecHandle: Integer;
        V: Variant;
    begin
        CodeunitId := RegInt[CurBaseInt + B];
        if CodeunitId <= 0 then
            Error('ALI957: Codeunit.Run was given %1, which is not a codeunit id', CodeunitId);
        // This codeunit IS the running interpreter (SingleInstance): re-entering it would reset
        // PC, frames and registers underneath the loop that is executing this instruction.
        if CodeunitId = Codeunit::"ALI Interpreter" then
            Error('ALI959: Codeunit.Run cannot run the interpreter itself');

        // Simulation must stay a sandbox, and Codeunit.Run performs an IMPLICIT commit of the
        // host's pending writes before it starts — which CommitBehavior::Ignore does NOT cover
        // (see RunLoopIgnoreCommit). Pinning the run's writes past the sentinel rollback is
        // exactly what Simulation promises never to do, so refuse rather than break the promise.
        if RunOptions.IsSimulation() then
            Error('ALI958: Codeunit.Run is not available in Simulation mode — it commits the pending writes of the run before starting, which would defeat the rollback');

        if C = 0 then
            Ok := Codeunit.Run(CodeunitId)
        else begin
            RecHandle := RegInt[CurBaseInt + C];
            RecRt.RecordAsVariant(RecHandle, V);
            Ok := Codeunit.Run(CodeunitId, V);
            FcGen += 1;    // PERF TEST — native callee holds the record
        end;

        if A > 0 then
            RegBool[CurBaseBool + A] := Ok
        else
            if not Ok then
                Error(GetLastErrorText());
    end;

    // ===== [TryFunction] calls — TRY_CALL =====
    //
    // A = proc id, B = destination Boolean register (frame-relative, in the CALLER's frame).
    //
    // An interpreted error trap needs a native one: only an AL [TryFunction] can catch an error
    // raised by an arbitrary arm of the loop. So TRY_CALL does not jump into the callee in the
    // running loop; it pushes the callee frame and RE-ENTERS RunLoopFlat natively from inside
    // TryRunFrame. That is legal because every piece of interpreter state (PC, frame stack, bases,
    // registers, alloc stack, even the loop's scratch variables) is codeunit-global — the nested
    // loop simply continues on the same state.
    //
    // How the nested loop ends without touching RET or the loop head: the pushed frame's return
    // PC is InstrTotal instead of the TRY_CALL's own PC. The callee's RET pops the frame exactly as
    // usual and lands on PC = InstrTotal, which is the `while PC < InstrTotal` exit condition —
    // the same trick the entry frame uses to halt. Nested CALLs inside the callee keep their
    // ordinary return PCs, so only the try frame's own return leaves the nested loop.
    //
    // On failure the frames above the call (the try frame plus whatever it had called) are still
    // on the stack: UnwindFramesTo pops them, reclaiming their tracked handles, and the caller's
    // frame resumes after the TRY_CALL with B = false and the script-visible last error set.
    // Resource-exhaustion / internal errors (IsFatalRunError) are NOT catchable: they are
    // re-raised with the frames and PC left in place, so Run() still reports the failing position.
    var
        TryDepth: Integer;      // nesting depth of TRY_CALL re-entries (AL call-stack guard)

    local procedure ExecTryCall(Callee: Integer; DestReg: Integer)
    var
        SavedPC: Integer;
        SavedSP: Integer;
        SavedTryDepth: Integer;
        ErrText: Text;
    begin
        // Charged like CALL — a recursive try procedure must still exhaust the runaway budget.
        StmtCounter += 1;
        if StmtCounter > StmtBudget then
            Error('ALI950: statement budget exhausted after %1 statements', StmtBudget);

        // Each try level costs real AL stack frames (TryRunFrame -> RunLoopFlat -> ExecTryCall),
        // unlike an interpreted CALL, so it has its own much smaller cap.
        if TryDepth >= MaxTryDepth() then
            Error('ALI1002: TryFunction calls nested too deeply (max %1 levels)', MaxTryDepth());

        SavedSP := FrameSP;
        SavedPC := PC;
        SavedTryDepth := TryDepth;
        PushTryFrame(Callee);
        FrRetPC[FrameSP] := InstrTotal;     // callee RET ends the nested loop (see header above)

        TryDepth += 1;
        if TryRunFrame() then begin
            TryDepth := SavedTryDepth;
            PC := SavedPC;                  // loop-top increment resumes after the TRY_CALL
            RegBool[CurBaseBool + DestReg] := true;
            exit;
        end;
        TryDepth := SavedTryDepth;

        ErrText := GetLastErrorText();
        if IsFatalRunError(ErrText) then
            Error(ErrText);                 // no unwind: PC is still the failing instruction

        UnwindFramesTo(SavedSP);
        // GetLastErrorText() in the script reads the builtin's own copy, not the platform's —
        // hand it over, then clear the native one so it cannot leak into Run()'s own reporting.
        BSystem.SetLastErrorText(ErrText);
        ClearLastError();
        PC := SavedPC;
        RegBool[CurBaseBool + DestReg] := false;
    end;

    [TryFunction]
    local procedure TryRunFrame()
    begin
        RunLoopFlat();
    end;

    local procedure MaxTryDepth(): Integer
    begin
        exit(64);
    end;

    // Errors a TryFunction must not swallow: they mean the RUN itself cannot go on (budget,
    // frame/register exhaustion, try nesting cap, sealed-array limit mismatch, a call into a
    // procedure whose body was never compiled, corrupt bytecode). Catching ALI950 in particular
    // would turn a runaway `while not MyTry() do;` into an endless loop.
    local procedure IsFatalRunError(ErrText: Text): Boolean
    begin
        exit(ErrText.StartsWith('ALI950:') or ErrText.StartsWith('ALI951:') or ErrText.StartsWith('ALI952:') or
             ErrText.StartsWith('ALI953:') or ErrText.StartsWith('ALI958:') or ErrText.StartsWith('ALI964:') or
             ErrText.StartsWith('ALI1002:'));
    end;

    // Frame push for TRY_CALL — the CALL arm's body, minus its budget tick (ExecTryCall charges
    // it). Deliberately a COPY: the CALL arm stays inlined in RunLoopFlat, where a procedure call
    // would cost every interpreted call ~450ns; TRY_CALL is rare enough to pay for one.
    local procedure PushTryFrame(Callee: Integer)
    var
        CalleeRowT: Integer;
        CallerRowT: Integer;
    begin
        if FrameSP >= 1024 then
            Error('ALI952: call stack exhausted (max %1 interpreted frames)', 1024);
        FrameSP += 1;
        FrRetPC[FrameSP] := PC;
        FrProcId[FrameSP] := CurProcIdVal;
        FrBInt[FrameSP] := CurBaseInt;
        FrBBig[FrameSP] := CurBaseBig;
        FrBDec[FrameSP] := CurBaseDec;
        FrBBool[FrameSP] := CurBaseBool;
        FrBText[FrameSP] := CurBaseText;
        FrBDate[FrameSP] := CurBaseDate;
        FrBTime[FrameSP] := CurBaseTime;
        FrBDT[FrameSP] := CurBaseDT;
        FrBDur[FrameSP] := CurBaseDur;
        FrBGuid[FrameSP] := CurBaseGuid;
        FrBVar[FrameSP] := CurBaseVar;
        FrBRecordId[FrameSP] := CurBaseRecordId;
        FrBDateFormula[FrameSP] := CurBaseDateFormula;
        FrAllocBase[FrameSP] := AllocKindStack.Count();

        CallerRowT := (CurProcIdVal - 1) * 13;
        CurBaseInt += PTRegCnt[CallerRowT + 1];
        CurBaseBig += PTRegCnt[CallerRowT + 2];
        CurBaseDec += PTRegCnt[CallerRowT + 3];
        CurBaseBool += PTRegCnt[CallerRowT + 4];
        CurBaseText += PTRegCnt[CallerRowT + 5];
        CurBaseDate += PTRegCnt[CallerRowT + 6];
        CurBaseTime += PTRegCnt[CallerRowT + 7];
        CurBaseDT += PTRegCnt[CallerRowT + 8];
        CurBaseDur += PTRegCnt[CallerRowT + 9];
        CurBaseGuid += PTRegCnt[CallerRowT + 10];
        CurBaseVar += PTRegCnt[CallerRowT + 11];
        CurBaseRecordId += PTRegCnt[CallerRowT + 12];
        CurBaseDateFormula += PTRegCnt[CallerRowT + 13];

        if PTEntry[Callee] <= 0 then
            Error('ALI964: procedure #%1 was called but its body was never compiled into this module (signatures-only harvest, or it was not reachable from the entry procedure)', Callee);

        CalleeRowT := (Callee - 1) * 13;
        if (CurBaseInt + PTRegCnt[CalleeRowT + 1] > 8192) or
           (CurBaseBig + PTRegCnt[CalleeRowT + 2] > 2048) or
           (CurBaseDec + PTRegCnt[CalleeRowT + 3] > 4096) or
           (CurBaseBool + PTRegCnt[CalleeRowT + 4] > 4096) or
           (CurBaseText + PTRegCnt[CalleeRowT + 5] > 2048) or
           (CurBaseDate + PTRegCnt[CalleeRowT + 6] > 2048) or
           (CurBaseTime + PTRegCnt[CalleeRowT + 7] > 2048) or
           (CurBaseDT + PTRegCnt[CalleeRowT + 8] > 2048) or
           (CurBaseDur + PTRegCnt[CalleeRowT + 9] > 2048) or
           (CurBaseGuid + PTRegCnt[CalleeRowT + 10] > 2048) or
           (CurBaseVar + PTRegCnt[CalleeRowT + 11] > 256) or
           (CurBaseRecordId + PTRegCnt[CalleeRowT + 12] > 2048) or
           (CurBaseDateFormula + PTRegCnt[CalleeRowT + 13] > 2048)
        then
            Error('ALI953: register file exhausted at interpreted call depth %1', FrameSP);

        CurProcIdVal := Callee;
        PC := PTEntry[Callee] - 1;          // pre-increment convention (P2)
        RecomputeCurWin();                  // also settles CurInstRow from the staged instance index
    end;

    // Pop every frame above TargetSP after a caught error — RET's restore without its return-
    // escape logic (a try procedure returns no value, and nothing is being handed back). Each
    // popped frame's tracked handles are reclaimed, so a failed try call leaks no List/Record/...
    // it had allocated and tracked.
    local procedure UnwindFramesTo(TargetSP: Integer)
    var
        HKind: Integer;
        HVal: Integer;
    begin
        while FrameSP > TargetSP do begin
            while AllocKindStack.Count() > FrAllocBase[FrameSP] do begin
                HKind := AllocKindStack.Get(AllocKindStack.Count());
                HVal := AllocHandleStack.Get(AllocHandleStack.Count());
                AllocKindStack.RemoveAt(AllocKindStack.Count());
                AllocHandleStack.RemoveAt(AllocHandleStack.Count());
                FreeHandleByKind(HKind, HVal);
            end;
            CurBaseInt := FrBInt[FrameSP];
            CurBaseBig := FrBBig[FrameSP];
            CurBaseDec := FrBDec[FrameSP];
            CurBaseBool := FrBBool[FrameSP];
            CurBaseText := FrBText[FrameSP];
            CurBaseDate := FrBDate[FrameSP];
            CurBaseTime := FrBTime[FrameSP];
            CurBaseDT := FrBDT[FrameSP];
            CurBaseDur := FrBDur[FrameSP];
            CurBaseGuid := FrBGuid[FrameSP];
            CurBaseVar := FrBVar[FrameSP];
            CurBaseRecordId := FrBRecordId[FrameSP];
            CurBaseDateFormula := FrBDateFormula[FrameSP];
            CurProcIdVal := FrProcId[FrameSP];
            FrameSP -= 1;
        end;
        RecomputeCurWin();                  // window cache + CurInstRow of the restored caller
    end;

    // ===== Frame machinery (M5, §7.4) — shared by both dispatch shapes =====

    // Perf: refresh the CurWin* cache from the (just-changed) CurProcIdVal/CurBase*.
    // COLD PATH ONLY — Run() init. PushFrame/PopFrame inline this body instead of calling it:
    // an AL procedure call costs ~500ns, roughly 10x the 13 array reads it would wrap here, and
    // both are on the per-interpreted-CALL path. The proc-table row is resolved once; the old
    // per-class CurCnt() accessor is gone for the same reason (13 calls to wrap 13 array reads).
    local procedure RecomputeCurWin()
    var
        Row: Integer;
    begin
        // M11 phase B2: kept in step with the window cache — same trigger, same lifetime. The
        // entry proc has no hidden instance row, so this settles at 0 there.
        CurInstRow := 0;
        if PTSelfSlot[CurProcIdVal] > 0 then
            CurInstRow := (RegInt[CurBaseInt + PTSelfSlot[CurProcIdVal]] - 1) * 13;
        Row := (CurProcIdVal - 1) * 13;
        CurWinInt := CurBaseInt + PTRegCnt[Row + 1];
        CurWinBig := CurBaseBig + PTRegCnt[Row + 2];
        CurWinDec := CurBaseDec + PTRegCnt[Row + 3];
        CurWinBool := CurBaseBool + PTRegCnt[Row + 4];
        CurWinText := CurBaseText + PTRegCnt[Row + 5];
        CurWinDate := CurBaseDate + PTRegCnt[Row + 6];
        CurWinTime := CurBaseTime + PTRegCnt[Row + 7];
        CurWinDT := CurBaseDT + PTRegCnt[Row + 8];
        CurWinDur := CurBaseDur + PTRegCnt[Row + 9];
        CurWinGuid := CurBaseGuid + PTRegCnt[Row + 10];
        CurWinVar := CurBaseVar + PTRegCnt[Row + 11];
        CurWinRecordId := CurBaseRecordId + PTRegCnt[Row + 12];
        CurWinDateFormula := CurBaseDateFormula + PTRegCnt[Row + 13];
    end;

    // Handle Lifecycle Unification: true for every "ALI TypeKind" ordinal tracked on the
    // unified frame-scoped alloc stack — every reference-typed runtime object whose value is
    // a plain Int handle (Array/List/Dictionary/Record/InStream/OutStream/TextBuilder/Dialog/
    // Http*, Phase 3 folded Record/Stream/TextBuilder/Dialog in alongside the rest).
    local procedure IsAllocStackHandleKind(TypeOrd: Integer): Boolean
    begin
        exit((TypeOrd = "ALI TypeKind"::Array) or (TypeOrd = "ALI TypeKind"::List) or (TypeOrd = "ALI TypeKind"::Dictionary) or
             (TypeOrd = "ALI TypeKind"::Record) or (TypeOrd = "ALI TypeKind"::RecordRef) or
             (TypeOrd = "ALI TypeKind"::InStream) or (TypeOrd = "ALI TypeKind"::OutStream) or
             (TypeOrd = "ALI TypeKind"::TextBuilder) or (TypeOrd = "ALI TypeKind"::BigText) or (TypeOrd = "ALI TypeKind"::Dialog) or
             // Http* (92-96) and Json* (97-100) are contiguous — one range covers both.
             ((TypeOrd >= "ALI TypeKind"::HttpClient.AsInteger()) and (TypeOrd <= "ALI TypeKind"::JsonValue.AsInteger())) or
             // Feature 3: Xml* (102-117; 101 Blob is NOT a handle kind, so its own range).
             ((TypeOrd >= "ALI TypeKind"::XmlDocument.AsInteger()) and (TypeOrd <= "ALI TypeKind"::XmlNameTable.AsInteger())));
    end;

    // Alloc-stack base of the CURRENT frame's segment. FrAllocBase is a 1-based AL array, and
    // the entry frame runs at FrameSP = 0 — its segment starts at the stack bottom (base 0),
    // so FrAllocBase[0] must never be read (index-out-of-range at runtime).
    local procedure CurFrameAllocBase(): Integer
    begin
        if FrameSP = 0 then
            exit(0);
        exit(FrAllocBase[FrameSP]);
    end;

    // Push (Kind, Handle) onto the unified alloc stack — called for every LOCAL allocation of
    // a handle-kind runtime object (declaration-time New, or a handle-returning method result).
    local procedure TrackLocalHandle(Kind: Integer; H: Integer)
    begin
        AllocKindStack.Add(Kind);
        AllocHandleStack.Add(H);
    end;

    // Drop (Kind, Handle) from the alloc stack because the runtime just reclaimed it explicitly
    // (RecordRef Close / Clear). Scans the WHOLE stack, not just the current frame's segment as
    // HANDLE_ESCAPE does: a ref opened by the caller can be closed inside a callee through a
    // var-param, and leaving the caller's entry behind would have that frame free a slot the
    // bank has since handed to somebody else.
    local procedure UntrackLocalHandle(Kind: Integer; H: Integer)
    var
        i: Integer;
    begin
        if H = 0 then
            exit;
        for i := AllocKindStack.Count() downto 1 do
            if (AllocKindStack.Get(i) = Kind) and (AllocHandleStack.Get(i) = H) then begin
                AllocKindStack.RemoveAt(i);
                AllocHandleStack.RemoveAt(i);
                exit;
            end;
    end;

    // PERF TEST — invalidate every cached FieldRef bound to record handle H (reopen/free/rebind).
    local procedure FcBumpHandle(H: Integer)
    begin
        if (H >= 1) and (H <= ArrayLen(FcHEpoch)) then
            FcHEpoch[H] += 1;
    end;

    // Dispatch a reclaim to the owning runtime by TypeKind ordinal — the single funnel every
    // PopFrame reclaim (and Reset, indirectly via each runtime's own Reset) goes through.
    local procedure FreeHandleByKind(Kind: Integer; H: Integer)
    begin
        case Kind of
            "ALI TypeKind"::Array:
                ArrayRt.FreeBlock(H);
            "ALI TypeKind"::List:
                ListRt.FreeList(H);
            "ALI TypeKind"::Dictionary:
                DictRt.FreeDict(H);
            "ALI TypeKind"::Record, "ALI TypeKind"::RecordRef:
                begin
                    RecRt.FreeRec(H);       // one bank, one reclaim — a RecordRef slot IS a record slot
                    FcBumpHandle(H);        // PERF TEST
                end;
            "ALI TypeKind"::InStream, "ALI TypeKind"::OutStream:
                StrmRt.FreeStream(H);
            "ALI TypeKind"::TextBuilder:
                TbRt.FreeTb(H);
            "ALI TypeKind"::BigText:
                BigRt.FreeBt(H);
            "ALI TypeKind"::Dialog:
                DlgRt.FreeDialog(H);
            "ALI TypeKind"::NativeCodeunit:
                NativeRt.FreeInstance(H);
            "ALI TypeKind"::HttpClient, "ALI TypeKind"::HttpRequestMessage, "ALI TypeKind"::HttpResponseMessage,
            "ALI TypeKind"::HttpContent, "ALI TypeKind"::HttpHeaders:
                HttpRt.FreeByKind(Kind, H);
            "ALI TypeKind"::JsonObject, "ALI TypeKind"::JsonArray, "ALI TypeKind"::JsonToken, "ALI TypeKind"::JsonValue:
                JsonRt.Free(H);      // Feature 2: unified bank, one Free for all 4 kinds
            else
                // Feature 3: Xml* kinds (102-117, contiguous) — per-bank funnel in the runtime.
                if (Kind >= "ALI TypeKind"::XmlDocument.AsInteger()) and (Kind <= "ALI TypeKind"::XmlNameTable.AsInteger()) then
                    XmlRt.FreeByKind(Kind, H);
        end;
    end;



    // ===== BigText / SecretText / Media ops =====

    // BIGTEXT_METHOD: same packing as TB_METHOD — A = handle (Int register), B = operand-pool
    // start (each entry regIdx*16+class, read LIVE), C = OutReg*100000 + OutCls*10000 +
    // MethodId*100 + ArgCount. Method ids mirror "ALI Binder".BigTextMethodId. GetSubText's
    // Text out-target arrives as operand 0 holding a temp the lowerer stores back afterwards,
    // so from here it is an ordinary result register.
    local procedure ExecBigTextOp(A: Integer; B: Integer; C: Integer)
    var
        HA: Integer;
        IsGlobal: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultInt: Integer;
        ResultText: Text;
    begin
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;

        // MethodId 0 = "New" (mirrors TB_METHOD): A/B unused, IsGlobal packed into the low
        // ArgCount digit, fresh handle written into OutReg and tracked when local.
        if MethodId = 0 then begin
            IsGlobal := C mod 100 mod 2;
            ResultInt := BigRt.NewBt();
            if IsGlobal = 0 then
                TrackLocalHandle("ALI TypeKind"::BigText, ResultInt);
            if (OutCls > 0) and (OutReg > 0) then
                RegInt[CurBaseInt + OutReg] := ResultInt;
            exit;
        end;

        HA := RegInt[CurBaseInt + A];
        case MethodId of
            1: // AddText(Text)
                BigRt.AddText(HA, ArgAsText(B, 0));
            2: // AddText(Text, Integer)
                BigRt.AddTextAt(HA, ArgAsText(B, 0), ArgAsInt(B, 1));
            3: // AddText(BigText)
                BigRt.AddBig(HA, ArgAsInt(B, 0));
            4: // AddText(BigText, Integer)
                BigRt.AddBigAt(HA, ArgAsInt(B, 0), ArgAsInt(B, 1));
            5: // GetSubText(var Text, Integer)
                ResultText := BigRt.GetSubTextToText(HA, ArgAsInt(B, 1));
            6: // GetSubText(var Text, Integer, Integer)
                ResultText := BigRt.GetSubTextToTextLen(HA, ArgAsInt(B, 1), ArgAsInt(B, 2));
            7: // GetSubText(var BigText, Integer)
                BigRt.GetSubTextToBig(HA, ArgAsInt(B, 0), ArgAsInt(B, 1));
            8: // GetSubText(var BigText, Integer, Integer)
                BigRt.GetSubTextToBigLen(HA, ArgAsInt(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            9: // Length() -> Integer
                ResultInt := BigRt.GetLength(HA);
            10: // Read(InStream) — hosted by the stream runtime, which owns the native stream
                StrmRt.BigTextRead(ArgAsInt(B, 0), HA);
            11: // TextPos(Text) -> Integer
                ResultInt := BigRt.TextPos(HA, ArgAsText(B, 0));
            12: // Write(OutStream)
                StrmRt.BigTextWrite(ArgAsInt(B, 0), HA);
            else
                Error('ALI998: invalid BigText method id %1 at PC %2', MethodId, PC);
        end;

        // GetSubText(var Text) writes its result into the operand-0 temp, not into OutReg — the
        // lowerer allocated that temp and stores it back into the caller's variable.
        if (MethodId = 5) or (MethodId = 6) then begin
            RegText[CurBaseText + (OperArr[B] div 16)] := ResultText;
            exit;
        end;
        if (OutCls > 0) and (OutReg > 0) then
            case OutCls of
                1:
                    RegInt[CurBaseInt + OutReg] := ResultInt;
                5:
                    RegText[CurBaseText + OutReg] := ResultText;
            end;
    end;

    // SECRET_METHOD: A = receiver TEXT register (a SecretText IS its text — see
    // "ALI TypeKind"::SecretText), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount.
    local procedure ExecSecretOp(A: Integer; C: Integer)
    var
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        Value: Text;
    begin
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        Value := RegText[CurBaseText + A];
        case MethodId of
            50: // IsEmpty() -> Boolean
                if (OutCls > 0) and (OutReg > 0) then
                    RegBool[CurBaseBool + OutReg] := Value = '';
            51: // Unwrap() -> Text
                if (OutCls > 0) and (OutReg > 0) then
                    RegText[CurBaseText + OutReg] := Value;
            else
                Error('ALI998: invalid SecretText method id %1 at PC %2', MethodId, PC);
        end;
    end;

    // MEDIA_METHOD: A = record handle reg, C = MethodId, everything else in the operand pool
    // ([B+0] FieldNo, [B+1] OutReg*16+OutCls, [B+2] ArgReg*16+ArgCls). See "ALI Opcode".
    local procedure ExecMediaOp(A: Integer; B: Integer; C: Integer)
    var
        FieldNo: Integer;
        HA: Integer;
        OutCls: Integer;
        OutReg: Integer;
        PackedOut: Integer;
    begin
        HA := RegInt[CurBaseInt + A];
        FieldNo := OperArr[B];
        PackedOut := OperArr[B + 1];
        OutReg := PackedOut div 16;
        OutCls := PackedOut mod 16;
        // A value-returning media method used as a STATEMENT has no result register (the
        // binder allows that — only the reverse, a void method used as a value, is an error).
        // Run the call anyway so its side effects and errors still happen; drop the result.
        if OutCls = 0 then
            OutReg := 0;

        case C of
            1:  // Media.ExportStream(OutStream)
                StrmRt.MediaExport(ArgAsInt(B, 2), RecRt.MediaId(HA, FieldNo));
            2:  // Media.HasValue() -> Boolean
                if OutReg > 0 then
                    RegBool[CurBaseBool + OutReg] := RecRt.MediaHasValue(HA, FieldNo)
                else
                    RecRt.MediaHasValue(HA, FieldNo);
            3, 22:  // MediaId() -> Guid (Media and MediaSet alike)
                if OutReg > 0 then
                    RegGuid[CurBaseGuid + OutReg] := RecRt.MediaId(HA, FieldNo)
                else
                    RecRt.MediaId(HA, FieldNo);
            20: // MediaSet.Count() -> Integer
                if OutReg > 0 then
                    RegInt[CurBaseInt + OutReg] := RecRt.MediaSetCount(HA, FieldNo)
                else
                    RecRt.MediaSetCount(HA, FieldNo);
            21: // MediaSet.Item(Integer) -> Guid
                if OutReg > 0 then
                    RegGuid[CurBaseGuid + OutReg] := RecRt.MediaSetItem(HA, FieldNo, ArgAsInt(B, 2))
                else
                    RecRt.MediaSetItem(HA, FieldNo, ArgAsInt(B, 2));
            else
                Error('ALI999: invalid media method id %1 at PC %2', C, PC);
        end;
    end;

    // ARG_REF: record a var-param alias in the callee window (A = callee param slot,
    // B = caller src slot, C = class*4 + mode; mode 0 = caller local, 1 = caller's own
    // var param (deref), 2 = global absolute).
    local procedure StageArgRef(A: Integer; B: Integer; C: Integer)
    var
        Cls: Integer;
        Mode: Integer;
        SrcAbs: Integer;
    begin
        Cls := C div 4;
        Mode := C mod 4;
        // M11 phase B2, mode 3 — an object global: B is an offset inside the block of the
        // instance the CALLER is running on. Class-independent, so it is resolved once here and
        // the per-class arms below (which have no `3:` branch) leave SrcAbs alone.
        if Mode = 3 then
            SrcAbs := InstBaseArr[CurInstRow + Cls] + B;
        case Cls of
            1:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseInt + B;
                        1:
                            SrcAbs := RefInt[CurBaseInt + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefInt[CurWinInt + A] := SrcAbs;
                end;
            2:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseBig + B;
                        1:
                            SrcAbs := RefBig[CurBaseBig + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefBig[CurWinBig + A] := SrcAbs;
                end;
            3:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseDec + B;
                        1:
                            SrcAbs := RefDec[CurBaseDec + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefDec[CurWinDec + A] := SrcAbs;
                end;
            4:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseBool + B;
                        1:
                            SrcAbs := RefBool[CurBaseBool + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefBool[CurWinBool + A] := SrcAbs;
                end;
            5:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseText + B;
                        1:
                            SrcAbs := RefText[CurBaseText + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefText[CurWinText + A] := SrcAbs;
                end;
            6:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseDate + B;
                        1:
                            SrcAbs := RefDate[CurBaseDate + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefDate[CurWinDate + A] := SrcAbs;
                end;
            7:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseTime + B;
                        1:
                            SrcAbs := RefTime[CurBaseTime + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefTime[CurWinTime + A] := SrcAbs;
                end;
            8:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseDT + B;
                        1:
                            SrcAbs := RefDT[CurBaseDT + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefDT[CurWinDT + A] := SrcAbs;
                end;
            9:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseDur + B;
                        1:
                            SrcAbs := RefDur[CurBaseDur + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefDur[CurWinDur + A] := SrcAbs;
                end;
            10:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseGuid + B;
                        1:
                            SrcAbs := RefGuid[CurBaseGuid + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefGuid[CurWinGuid + A] := SrcAbs;
                end;
            11:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseVar + B;
                        1:
                            SrcAbs := RefVar[CurBaseVar + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefVar[CurWinVar + A] := SrcAbs;
                end;
            12:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseRecordId + B;
                        1:
                            SrcAbs := RefRecordId[CurBaseRecordId + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefRecordId[CurWinRecordId + A] := SrcAbs;
                end;
            13:
                begin
                    case Mode of
                        0:
                            SrcAbs := CurBaseDateFormula + B;
                        1:
                            SrcAbs := RefDateFormula[CurBaseDateFormula + B];
                        2:
                            SrcAbs := B;
                    end;
                    RefDateFormula[CurWinDateFormula + A] := SrcAbs;
                end;
        end;
    end;

    // ===== M6 record opcodes (family 7, §7.5) — shared by both dispatch shapes =====
    // Record handles are ABSOLUTE (a compilation-wide handle space, NOT a windowed register
    // class); scalar operands are FRAME-RELATIVE like every other opcode. Packing:
    //   REC_OPEN         A=handle,       B=tableId,          C=tempFlag
    //   REC_INIT/RESET   A=handle
    //   REC_INSERT/...   A=handle,       B=run-trigger flag
    //   REC_FIND         A=handle,       B=which*4+ForUpdate*2+cond, C=dest bool reg
    //   REC_NEXT         A=handle,       B=dest int reg,     C=step reg (Int class)
    //   REC_COUNT        A=handle,       B=dest int reg
    //   REC_ISEMPTY      A=handle,       B=dest bool reg
    //   REC_GET          A=handle,       B=key text reg,     C=dest bool reg
    //   REC_SETRANGE     A=handle,       B=field no,         C=valueReg*16 + class
    //   REC_FLD_LOAD     A=dest reg,     B=handle,           C=fieldNo*16 + destClass
    //   REC_FLD_STORE    A=handle,       B=src reg,          C=fieldNo*16 + srcClass
    //   REC_VALIDATE     A=handle,       B=src reg,          C=fieldNo*16 + srcClass
    //   REC_COPY         A=dest handle,  B=src handle
    // Handle Lifecycle Unification (Phase 3): a record handle operand is now an Int REGISTER
    // (frame-relative, like every other handle-kind type) instead of an absolute compile-time
    // slot number. HA/HB resolve whichever position(s) actually carry a handle for a given
    // opcode (per-arm comments below, otherwise unchanged from the pre-Phase-3 convention) —
    // computed unconditionally up front (two cheap array reads; harmless when an opcode
    // doesn't use one as a handle, e.g. REC_NEXT's B is a dest register, not a handle).
    // That speculative resolution is bounds-guarded: an out-of-[1,8192] index means the slot was
    // never really a handle for this opcode, so 0 is a harmless stand-in (only ever consumed by
    // an arm that doesn't touch it). The guard used to live in a SafeRegInt() helper; it is
    // inlined at both use sites now — it ran twice per record/stream opcode, and an AL call
    // costs ~450ns against the two comparisons it wrapped.

    local procedure ExecRecordOp(Op: Integer; A: Integer; B: Integer; C: Integer)
    var
        Cls: Integer;
        FieldNo: Integer;
        HA: Integer;
        HB: Integer;
        V: Variant;
    begin
        // A and B are handle-bearing registers for MOST record opcodes, but not all: several
        // pass a literal flag/field-no/table-id in B (229-232 trigger+conditional bits, 246's
        // table id, etc.), and a few text/name getters (282-284, 290, 296, 298, 301, 302, 303,
        // 277, 276, 280, 281, 318, 354) carry the real handle in B while A is a plain dest reg.
        // Resolving both unconditionally as RegInt[CurBaseInt+literal] can land on index 0
        // (1-based array) whenever CurBaseInt+literal = 0 — e.g. a bare Insert()/Modify()/
        // Init() with all-false flag bits — and crash before the opcode ever reads the literal
        // correctly. Bounds-guard both: an out-of-range read only ever feeds an opcode arm that
        // ignores it, so returning 0 there is safe.
        // SafeRegInt inlined: these two fire unconditionally on every opcode of this family,
        // and a call costs ~450ns against the two comparisons + array read it wrapped.
        HA := CurBaseInt + A;
        if (HA < 1) or (HA > 8192) then
            HA := 0
        else
            HA := RegInt[HA];
        HB := CurBaseInt + B;
        if (HB < 1) or (HB > 8192) then
            HB := 0
        else
            HB := RegInt[HB];
        case Op of
            246: // REC_NEW (repurposed from REC_OPEN, unreachable via the old scheme since
                 // AllocateRecordHandles is gone — v1 never serialized bytecode, safe to
                 // repurpose): A = dest int reg (fresh handle), B = tableId (literal),
                 // C = IsTemp*2 + IsGlobal(0/1)
                ExecRecNew(A, B, C);
            224: // REC_INIT
                RecRt.InitRec(HA);
            225: // REC_RESET
                RecRt.ResetRec(HA);
            226: // REC_GET
                ExecRecGet(HA, B, C);
            227: // REC_FIND — B = Which*4 + ForUpdate*2 + conditional; C = dest bool reg
                RegBool[CurBaseBool + C] := RecRt.FindRec(HA, B div 4, (B div 2) mod 2 = 1, (B mod 2) = 1);
            229: // REC_INSERT — B bit0=trigger, bit1=conditional; C=dest bool reg
                RegBool[CurBaseBool + C] := RecRt.InsertRec(HA, (B mod 2) = 1, (B div 2) = 1);
            230: // REC_MODIFY — B bit0=trigger, bit1=conditional; C=dest bool reg
                RegBool[CurBaseBool + C] := RecRt.ModifyRec(HA, (B mod 2) = 1, (B div 2) = 1);
            231: // REC_DELETE — B bit0=trigger, bit1=conditional; C=dest bool reg
                RegBool[CurBaseBool + C] := RecRt.DeleteRec(HA, (B mod 2) = 1, (B div 2) = 1);
            232: // REC_DELETEALL — B bit0=trigger, bit1=conditional; C=dest bool reg
                RegBool[CurBaseBool + C] := RecRt.DeleteAllRec(HA, (B mod 2) = 1, (B div 2) = 1);
            234: // REC_SETRANGE
                begin
                    Cls := C mod 16;
                    V := ReadRegisterAsVariant(Cls, C div 16);
                    RecRt.SetRangeEq(HA, B, V);
                end;
            270: // REC_SETRANGE_CLR — SetRange(field): clear the field's filter
                RecRt.ClearFieldRange(HA, B);
            271: // REC_SETRANGE_2 — SetRange(field, from, to): B = operand-pool start (2 entries), C = field no
                RecRt.SetRangeBetween(HA, C,
                    ReadRegisterAsVariant(OperArr[B] mod 16, OperArr[B] div 16),
                    ReadRegisterAsVariant(OperArr[B + 1] mod 16, OperArr[B + 1] div 16));
            237: // REC_COUNT
                RegInt[CurBaseInt + B] := RecRt.CountRec(HA);
            238: // REC_ISEMPTY
                RegBool[CurBaseBool + B] := RecRt.IsEmptyRec(HA);
            241: // REC_VALIDATE
                begin
                    FieldNo := C div 16;
                    Cls := C mod 16;
                    V := ReadRegisterAsVariant(Cls, B);
                    RecRt.ValidateField(HA, FieldNo, V);
                end;
            245: // REC_COPY: A=dest handle, B=src handle
                RecRt.CopyRec(HA, HB);
            // 247 REC_FLD_LOAD / 248 REC_FLD_STORE are handled directly in RunLoopFlat's case —
            // hoisted out of this group handler to save two calls per field access.
            265: // REC_RENAME
                ExecRecRename(HA, B, C);
            266: // REC_COPY_REC: A=dest handle, B=src handle, C=includeFilters(1/0)
                begin
                    RecRt.CopyRec2(HA, HB, C = 1);
                    FcBumpHandle(HA);    // PERF TEST — Copy(shareTable) may rebind the dataset
                end;
            267: // REC_COPYFILTERS: A=dest handle, B=src handle
                RecRt.CopyFiltersRec(HA, HB);
            268: // REC_SETRECFILTER
                RecRt.SetRecFilterRec(HA);
            269: // REC_TRUNCATE
                RecRt.TruncateRec(HA, B = 1);
            272: // REC_ISTEMPORARY
                RegBool[CurBaseBool + B] := RecRt.IsTemporaryRec(HA);
            273: // REC_COUNTAPPROX
                RegInt[CurBaseInt + B] := RecRt.CountApproxRec(HA);
            274: // REC_READPERMISSION
                RegBool[CurBaseBool + B] := RecRt.ReadPermissionRec(HA);
            275: // REC_WRITEPERMISSION
                RegBool[CurBaseBool + B] := RecRt.WritePermissionRec(HA);
            244: // REC_TRANSFERFIELDS: A=dest handle, B=src handle, C=replaceExisting(1/0)
                RecRt.TransferFieldsRec(HA, HB, C = 1);
            235: // REC_SETFILTER: A=handle, B=fieldNo, C=src text reg
                RecRt.SetFilterField(HA, B, RegText[CurBaseText + C]);
            457: // REC_SETFILTER_ARGS: A=handle, B=operand-pool start, C=substitution value count
                ExecRecSetFilterArgs(HA, B, C);
            276: // REC_GETFILTER: A=dest text reg, B=handle, C=fieldNo
                RegText[CurBaseText + A] := RecRt.GetFilterField(HB, C);
            279: // REC_COPYFILTER: A=source handle, B=target handle (= A same-record),
                 // C=operand-pool start: [fromFieldNo, toFieldNo]
                RecRt.CopyFilterField(HA, OperArr[C], HB, OperArr[C + 1]);
            280: // REC_GETRANGEMIN: A=dest reg, B=handle, C=fieldNo*16 + destClass
                begin
                    FieldNo := C div 16;
                    Cls := C mod 16;
                    V := RecRt.GetRangeMinField(HB, FieldNo);
                    WriteRegisterFromVariant(Cls, A, V);
                end;
            281: // REC_GETRANGEMAX: A=dest reg, B=handle, C=fieldNo*16 + destClass
                begin
                    FieldNo := C div 16;
                    Cls := C mod 16;
                    V := RecRt.GetRangeMaxField(HB, FieldNo);
                    WriteRegisterFromVariant(Cls, A, V);
                end;
            233: // REC_MODIFYALL: A=handle, B=fieldNo*16+srcClass,
                 // C = srcReg*16384 + destBoolReg*4 + trigger*2 + conditional
                begin
                    FieldNo := B div 16;
                    Cls := B mod 16;
                    V := ReadRegisterAsVariant(Cls, C div 16384);
                    RegBool[CurBaseBool + ((C div 4) mod 4096)] := RecRt.ModifyAllField(HA, FieldNo, V, ((C div 2) mod 2) = 1, (C mod 2) = 1);
                end;
            239: // REC_CALCFIELDS: A=handle, B=operand-pool start (field nos), C=count
                ExecRecFieldNoList(HA, B, C, false);
            240: // REC_CALCSUMS: A=handle, B=operand-pool start (field nos), C=count
                ExecRecFieldNoList(HA, B, C, true);
            242: // REC_TESTFIELD: A=handle, B=fieldNo (1-arg non-zero/non-blank check)
                RecRt.TestFieldEmpty(HA, B);
            304: // REC_TESTFIELD_VAL: A=handle, B=valueReg*16+valueClass, C=fieldNo*16
                begin
                    Cls := B mod 16;
                    V := ReadRegisterAsVariant(Cls, B div 16);
                    RecRt.TestFieldValue(HA, C div 16, V);
                end;
            243: // REC_FIELDERROR: A=handle, B=fieldNo, C=src text reg (0 = no custom message)
                if C = 0 then
                    RecRt.FieldErrorDefault(HA, B)
                else
                    RecRt.FieldErrorText(HA, B, RegText[CurBaseText + C]);
            302: // REC_FIELDNAME: A=dest text reg, B=handle, C=fieldNo
                RegText[CurBaseText + A] := RecRt.FieldNameOf(HB, C);
            303: // REC_FIELDCAPTION: A=dest text reg, B=handle, C=fieldNo
                RegText[CurBaseText + A] := RecRt.FieldCaptionOf(HB, C);
            282: // REC_TABLENAME: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.TableNameOf(HB);
            283: // REC_TABLECAPTION: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.TableCaptionOf(HB);
            284: // REC_FQNAME: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.FullyQualifiedNameOf(HB);
            236: // REC_SETCURRENTKEY: A=handle, B=operand-pool start (field nos), C=count
                ExecRecSetCurrentKey(HA, B, C);
            286: // REC_ASCENDING_GET: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.GetAscendingRec(HA);
            287: // REC_ASCENDING_SET: A=handle, B=src bool reg
                RecRt.SetAscendingRec(HA, RegBool[CurBaseBool + B]);
            288: // REC_SETASCENDING: A=handle, B=fieldNo, C=src bool reg
                RecRt.SetAscendingField(HA, B, RegBool[CurBaseBool + C]);
            289: // REC_GETASCENDING: A=handle, B=fieldNo, C=dest bool reg
                RegBool[CurBaseBool + C] := RecRt.GetAscendingField(HA, B);
            290: // REC_CURRENTKEY: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.CurrentKeyOf(HB);
            291: // REC_MARK_SET: A=handle, B=src bool reg
                RecRt.SetMark(HA, RegBool[CurBaseBool + B]);
            292: // REC_MARK_GET: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.GetMark(HA);
            293: // REC_CLEARMARKS: A=handle
                RecRt.ClearMarksRec(HA);
            294: // REC_MARKEDONLY_SET: A=handle, B=src bool reg
                RecRt.SetMarkedOnly(HA, RegBool[CurBaseBool + B]);
            295: // REC_MARKEDONLY_GET: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.GetMarkedOnly(HA);
            296: // REC_GETPOSITION: A=dest text reg, B=handle, C=includeSortOrder(1/0)
                RegText[CurBaseText + A] := RecRt.GetPositionOf(HB, C = 1);
            297: // REC_SETPOSITION: A=handle, B=src text reg
                RecRt.SetPositionOf(HA, RegText[CurBaseText + B]);
            298: // REC_GETVIEW: A=dest text reg, B=handle, C=includeSortOrder(1/0)
                RegText[CurBaseText + A] := RecRt.GetViewOf(HB, C = 1);
            299: // REC_SETVIEW: A=handle, B=src text reg
                RecRt.SetViewOf(HA, RegText[CurBaseText + B]);
            300: // REC_CHANGECOMPANY: A=handle, B=src text reg (0 = no arg -> current company)
                begin
                    if B = 0 then
                        RecRt.ChangeCompanyRec(HA, '')
                    else
                        RecRt.ChangeCompanyRec(HA, RegText[CurBaseText + B]);
                    FcBumpHandle(HA);    // PERF TEST
                end;
            301: // REC_CURRENTCOMPANY: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.CurrentCompanyOf(HB);
            277: // REC_GETFILTERS: A=dest text reg, B=handle
                RegText[CurBaseText + A] := RecRt.GetFiltersOf(HB);
            278: // REC_HASFILTER: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.HasFilterRec(HA);
            309: // REC_SETAUTOCALCFIELDS: A=handle, B=field-no pool start, C=destBoolReg*32+count
                ExecRecAutoCalc(HA, B, C);
            310: // REC_SETLOADFIELDS
                ExecRecLoadFieldList(HA, B, C, 1);
            311: // REC_ADDLOADFIELDS
                ExecRecLoadFieldList(HA, B, C, 2);
            312: // REC_LOADFIELDS
                ExecRecLoadFieldList(HA, B, C, 3);
            313: // REC_AREFIELDSLOADED
                ExecRecLoadFieldList(HA, B, C, 4);
            314: // REC_LOCKTABLE: A=handle, B=wait flag (const-folded)
                RecRt.LockTableRec(HA, B = 1);
            315: // REC_READCONSISTENCY_GET: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.GetReadConsistencyRec(HA);
            317: // REC_FIELDCOUNT: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.FieldCountRec(HA);
            318: // REC_FIELDEXIST: A=dest bool reg, B=handle, C=src int reg (field number)
                RegBool[CurBaseBool + A] := RecRt.FieldExistRec(HB, RegInt[CurBaseInt + C]);
            319: // REC_KEYCOUNT: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.KeyCountRec(HA);
            320: // REC_CURRENTKEYINDEX_GET: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.GetCurrentKeyIndexRec(HA);
            321: // REC_CURRENTKEYINDEX_SET: A=handle, B=src int reg
                RecRt.SetCurrentKeyIndexRec(HA, RegInt[CurBaseInt + B]);
            353: // REC_GET_BY_ID: A=handle, B=RecordID reg, C=destBoolReg*2+conditional
                ExecRecGetById(HA, B, C);
            354: // REC_RECORDID_GET: A=dest RecordID reg, B=handle
                RegRecordId[CurBaseRecordId + A] := RecRt.GetRecordId(HB);
            355: // RECID_TABLENO: A=dest int reg, B=src RecordID reg (native errors if blank) — no record handle involved
                RegInt[CurBaseInt + A] := RegRecordId[CurBaseRecordId + B].TableNo();
            369: // REC_FILTERGROUP_GET: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.FilterGroupGet(HA);
            370: // REC_FILTERGROUP_SET: A=handle, B=src int reg (new group), C=dest int reg (prior group)
                RegInt[CurBaseInt + C] := RecRt.FilterGroupSet(HA, RegInt[CurBaseInt + B]);
            438: // REC_FIND_TEXT: A=handle, B=which text reg, C=destBoolReg*2+conditional
                RegBool[CurBaseBool + (C div 2)] := RecRt.FindTextRec(HA, RegText[CurBaseText + B], (C mod 2) = 1);
            439: // REC_GETBYSYSTEMID: A=handle, B=guid reg, C=destBoolReg*2+conditional
                RegBool[CurBaseBool + (C div 2)] := RecRt.GetBySystemIdRec(HA, (C mod 2) = 1, RegGuid[CurBaseGuid + B]);
            440: // REC_ADDLINK: A=handle, B=url text reg, C=descTextReg*8192+destIntReg
                ExecRecAddLink(HA, B, C);
            441: // REC_DELETELINK: A=handle, B=src int reg (link id)
                RecRt.DeleteLinkRec(HA, RegInt[CurBaseInt + B]);
            442: // REC_DELETELINKS: A=handle
                RecRt.DeleteLinksRec(HA);
            443: // REC_COPYLINKS: A=dest handle, B=src handle
                RecRt.CopyLinksRec(HA, HB);
            444: // REC_HASLINKS: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.HasLinksRec(HA);
            445: // REC_READISOLATION_GET: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.GetReadIsolationRec(HA);
            446: // REC_READISOLATION_SET: A=handle, B=src int reg
                RecRt.SetReadIsolationRec(HA, RegInt[CurBaseInt + B]);
            447: // REC_SETPERMISSIONFILTER: A=handle
                RecRt.SetPermissionFilterRec(HA);
            448: // REC_SECURITYFILTERING_GET: A=handle, B=dest int reg
                RegInt[CurBaseInt + B] := RecRt.GetSecurityFilteringRec(HA);
            449: // REC_SECURITYFILTERING_SET: A=handle, B=src int reg
                RecRt.SetSecurityFilteringRec(HA, RegInt[CurBaseInt + B]);
            450: // REC_RECORDLEVELLOCKING: A=handle, B=dest bool reg
                RegBool[CurBaseBool + B] := RecRt.RecordLevelLockingRec(HA);
            453: // REC_BLOB_INSTREAM: A=rec handle, B=stream handle, C=fieldNo*5+textEncoding (4 = PendingBlobEnc)
                RecRt.BlobCreateInStream(HA, C div 5, HB, BlobEnc(C mod 5));
            454: // REC_BLOB_OUTSTREAM: A=rec handle, B=stream handle, C=fieldNo*5+textEncoding (4 = PendingBlobEnc)
                RecRt.BlobCreateOutStream(HA, C div 5, HB, BlobEnc(C mod 5));
            455: // REC_BLOB_HASVALUE: A=dest bool reg, B=rec handle, C=fieldNo
                RegBool[CurBaseBool + A] := RecRt.BlobHasValue(HB, C);
            456: // REC_BLOB_LENGTH: A=dest int reg, B=rec handle, C=fieldNo
                RegInt[CurBaseInt + A] := RecRt.BlobLength(HB, C);
            else
                Error('ALI951: invalid record opcode %1 at PC %2', Op, PC);
        end;
    end;

    // Packed blob encoding: 0-3 = the TextEncoding ordinal itself, 4 = the value REC_BLOB_ENC
    // just parked (a non-constant TextEncoding expression).
    local procedure BlobEnc(Packed: Integer): Integer
    begin
        if Packed = 4 then
            exit(PendingBlobEnc);
        exit(Packed);
    end;

    // REC_NEW (Handle Lifecycle Unification Phase 3): A = dest int reg (fresh handle),
    // B = tableId (literal), C = IsTemp*2 + IsGlobal(0/1) — mirrors LIST_NEW's shape.
    local procedure ExecRecNew(A: Integer; B: Integer; C: Integer)
    var
        Handle: Integer;
        IsGlobal: Integer;
        IsTemp: Integer;
    begin
        IsGlobal := C mod 2;
        IsTemp := (C div 2) mod 2;
        // A GLOBAL record is opened once per run — that is the whole contract of the IsGlobal
        // flag (the handle is deliberately NOT put on the frame alloc stack, so nothing but Reset
        // ever gives the slot back). This instruction belongs to exactly one (instance, global)
        // pair, so if it executes a second time the prologue that owns it was re-entered, and
        // allocating again silently orphaned the previous slot: the bank then filled up with
        // copies of the same global and ALI954 fired with every slot on one table. Hand back the
        // slot this PC already owns instead — which is also the AL semantics, since module
        // globals are not re-initialised when a procedure runs again.
        if IsGlobal = 1 then
            if GlobalRecByPC.Get(PC, Handle) then begin
                RegInt[CurBaseInt + A] := Handle;
                GlobalRecReopens += 1;
                exit;
            end;
        Handle := RecRt.NewRec(B, IsTemp = 1, IsGlobal + 1);   // origin tag: 1 = local, 2 = global
        FcBumpHandle(Handle);    // PERF TEST — slot may be a recycled handle
        RegInt[CurBaseInt + A] := Handle;
        if IsGlobal = 0 then
            TrackLocalHandle("ALI TypeKind"::Record, Handle)
        else
            GlobalRecByPC.Set(PC, Handle);
    end;

    // REC_GET_BY_ID: Get-by-RecordID, both for `Rec.Get(idExpr)` (Conditional per WantResult)
    // and the `RecVar := idExpr.GetRecord();` assignment form (Conditional always false there,
    // matching native throw-on-miss/wrong-table semantics; the dest register is unused but
    // always valid). C = destBoolReg*2 + conditional.
    local procedure ExecRecGetById(A: Integer; B: Integer; C: Integer)
    var
        Conditional: Boolean;
        DestReg: Integer;
    begin
        Conditional := (C mod 2) = 1;
        DestReg := C div 2;
        RegBool[CurBaseBool + DestReg] := RecRt.GetRecById(A, Conditional, RegRecordId[CurBaseRecordId + B]);
    end;

    // REC_ADDLINK: A=handle, B=url text reg, C=descTextReg*8192+destIntReg. descReg 0 means
    // the no-description overload; the returned link id lands in destIntReg (harmless when the
    // script discards it — it is still a valid temp).
    local procedure ExecRecAddLink(HA: Integer; B: Integer; C: Integer)
    var
        DescReg: Integer;
        Description: Text;
    begin
        DescReg := C div 8192;
        if DescReg <> 0 then
            Description := RegText[CurBaseText + DescReg];
        RegInt[CurBaseInt + (C mod 8192)] := RecRt.AddLinkRec(HA, RegText[CurBaseText + B], Description, DescReg <> 0);
    end;

    // REC_CALCFIELDS / REC_CALCSUMS share this shape: a run of field numbers in the operand
    // pool (no packed class — field numbers alone, unlike the key-value pools elsewhere).
    local procedure ExecRecFieldNoList(A: Integer; B: Integer; C: Integer; Sums: Boolean)
    var
        i: Integer;
    begin
        for i := 0 to C - 1 do
            if Sums then
                RecRt.CalcSumsField(A, OperArr[B + i])
            else
                RecRt.CalcFieldsField(A, OperArr[B + i]);
    end;

    // REC_SETCURRENTKEY: builds the field-number list from the operand pool, then hands it
    // to RecRt to pick the best-matching declared key (§7.5).
    local procedure ExecRecSetCurrentKey(A: Integer; B: Integer; C: Integer)
    var
        i: Integer;
        FieldNos: List of [Integer];
    begin
        for i := 0 to C - 1 do
            FieldNos.Add(OperArr[B + i]);
        RecRt.SetCurrentKeyList(A, FieldNos);
    end;

    // REC_SETLOADFIELDS / ADDLOADFIELDS / LOADFIELDS / AREFIELDSLOADED: field-no pool + a
    // returned Boolean. C = destBoolReg*32 + count. Which: 1..4 selects the runtime call.
    local procedure ExecRecLoadFieldList(A: Integer; B: Integer; C: Integer; Which: Integer)
    var
        Count: Integer;
        DestReg: Integer;
        i: Integer;
        FieldNos: List of [Integer];
    begin
        Count := C mod 32;
        DestReg := C div 32;
        for i := 0 to Count - 1 do
            FieldNos.Add(OperArr[B + i]);
        RegBool[CurBaseBool + DestReg] := ApplyLoadFieldList(A, FieldNos, Which);
    end;

    // The runtime call of the load-field family, split out from the field-number DECODING above so
    // the P4 RecordRef path (ExecRefDynFieldOp) can share it: there the numbers come from LIVE
    // registers instead of raw pool ints, but the four calls below are identical. Which: 1..4 =
    // SetLoadFields / AddLoadFields / LoadFields / AreFieldsLoaded.
    local procedure ApplyLoadFieldList(A: Integer; var FieldNos: List of [Integer]; Which: Integer): Boolean
    begin
        case Which of
            1:
                exit(RecRt.SetLoadFieldsRec(A, FieldNos));
            2:
                exit(RecRt.AddLoadFieldsRec(A, FieldNos));
            3:
                exit(RecRt.LoadFieldsRec(A, FieldNos));
            4:
                exit(RecRt.AreFieldsLoadedRec(A, FieldNos));
        end;
    end;

    // REC_SETAUTOCALCFIELDS: RecordRef.SetAutoCalcFields is variadic REPLACE (each call resets
    // the set), so — unlike the load-field family — it cannot be built incrementally. Dispatch
    // the arity 0..16 overloads exactly like ExecRecGet does for the PK. C = destBoolReg*32+count.
    local procedure ExecRecAutoCalc(A: Integer; B: Integer; C: Integer)
    var
        Count: Integer;
        DestReg: Integer;
        F: array[16] of Integer;
        i: Integer;
    begin
        Count := C mod 32;
        DestReg := C div 32;
        for i := 1 to Count do
            F[i] := OperArr[B + i - 1];
        RegBool[CurBaseBool + DestReg] := ApplyAutoCalcFields(A, Count, F);
    end;

    // The arity ladder itself, split out from the field-number DECODING above so the P4 RecordRef
    // path (ExecRefDynFieldOp) can share it — same reason ApplyLoadFieldList exists.
    local procedure ApplyAutoCalcFields(A: Integer; Count: Integer; F: array[16] of Integer): Boolean
    var
        Res: Boolean;
    begin
        case Count of
            0:
                Res := RecRt.SetAutoCalcFieldsRec(A);
            1:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1]);
            2:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2]);
            3:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3]);
            4:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4]);
            5:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5]);
            6:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6]);
            7:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7]);
            8:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8]);
            9:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9]);
            10:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10]);
            11:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11]);
            12:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12]);
            13:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12], F[13]);
            14:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12], F[13], F[14]);
            15:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12], F[13], F[14], F[15]);
            16:
                Res := RecRt.SetAutoCalcFieldsRec(A, F[1], F[2], F[3], F[4], F[5], F[6], F[7], F[8], F[9], F[10], F[11], F[12], F[13], F[14], F[15], F[16]);
        end;
        exit(Res);
    end;

    // REC_GET: A=handle, B=operand-pool start, C=destBoolReg*32 + ArgCount (1..16). Each
    // pool slot packs (reg*16 + class) for one PK key argument (§7.5, CONCAT_N convention —
    // key values are read live off their registers here, never boxed at lower time).
    local procedure ExecRecGet(A: Integer; B: Integer; C: Integer)
    var
        Conditional: Boolean;
        Found: Boolean;
        ArgCount: Integer;
        DestReg: Integer;
        K1, K2, K3, K4, K5, K6, K7, K8, K9, K10 : Variant;
        K11, K12, K13, K14, K15, K16 : Variant;
    begin
        // C = destBoolReg*64 + conditional*32 + ArgCount (ArgCount<=16 → 5 bits; conditional 1 bit)
        ArgCount := C mod 32;
        Conditional := ((C div 32) mod 2) = 1;
        DestReg := C div 64;
        if ArgCount >= 1 then
            K1 := ReadRegisterAsVariant(OperArr[B] mod 16, OperArr[B] div 16);
        if ArgCount >= 2 then
            K2 := ReadRegisterAsVariant(OperArr[B + 1] mod 16, OperArr[B + 1] div 16);
        if ArgCount >= 3 then
            K3 := ReadRegisterAsVariant(OperArr[B + 2] mod 16, OperArr[B + 2] div 16);
        if ArgCount >= 4 then
            K4 := ReadRegisterAsVariant(OperArr[B + 3] mod 16, OperArr[B + 3] div 16);
        if ArgCount >= 5 then
            K5 := ReadRegisterAsVariant(OperArr[B + 4] mod 16, OperArr[B + 4] div 16);
        if ArgCount >= 6 then
            K6 := ReadRegisterAsVariant(OperArr[B + 5] mod 16, OperArr[B + 5] div 16);
        if ArgCount >= 7 then
            K7 := ReadRegisterAsVariant(OperArr[B + 6] mod 16, OperArr[B + 6] div 16);
        if ArgCount >= 8 then
            K8 := ReadRegisterAsVariant(OperArr[B + 7] mod 16, OperArr[B + 7] div 16);
        if ArgCount >= 9 then
            K9 := ReadRegisterAsVariant(OperArr[B + 8] mod 16, OperArr[B + 8] div 16);
        if ArgCount >= 10 then
            K10 := ReadRegisterAsVariant(OperArr[B + 9] mod 16, OperArr[B + 9] div 16);
        if ArgCount >= 11 then
            K11 := ReadRegisterAsVariant(OperArr[B + 10] mod 16, OperArr[B + 10] div 16);
        if ArgCount >= 12 then
            K12 := ReadRegisterAsVariant(OperArr[B + 11] mod 16, OperArr[B + 11] div 16);
        if ArgCount >= 13 then
            K13 := ReadRegisterAsVariant(OperArr[B + 12] mod 16, OperArr[B + 12] div 16);
        if ArgCount >= 14 then
            K14 := ReadRegisterAsVariant(OperArr[B + 13] mod 16, OperArr[B + 13] div 16);
        if ArgCount >= 15 then
            K15 := ReadRegisterAsVariant(OperArr[B + 14] mod 16, OperArr[B + 14] div 16);
        if ArgCount >= 16 then
            K16 := ReadRegisterAsVariant(OperArr[B + 15] mod 16, OperArr[B + 15] div 16);

        case ArgCount of
            0:
                Found := RecRt.GetRec(A, Conditional);
            1:
                Found := RecRt.GetRec(A, Conditional, K1);
            2:
                Found := RecRt.GetRec(A, Conditional, K1, K2);
            3:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3);
            4:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4);
            5:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5);
            6:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6);
            7:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7);
            8:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8);
            9:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9);
            10:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10);
            11:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11);
            12:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12);
            13:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13);
            14:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14);
            15:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14, K15);
            16:
                Found := RecRt.GetRec(A, Conditional, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14, K15, K16);
        end;
        RegBool[CurBaseBool + DestReg] := Found;
    end;

    // REC_SETFILTER_ARGS: A=handle, B=operand-pool start (0=fieldNo, 1=filter-text reg packed,
    // 2.. = %1..%14 substitution value regs packed), C=substitution value count. The values are
    // handed to FieldRef.SetFilter as-is so native AL does the filter-safe formatting.
    local procedure ExecRecSetFilterArgs(A: Integer; B: Integer; C: Integer)
    var
        i: Integer;
        Args: array[14] of Variant;
    begin
        for i := 1 to C do
            Args[i] := ReadRegisterAsVariant(OperArr[B + 1 + i] mod 16, OperArr[B + 1 + i] div 16);
        RecRt.SetFilterFieldArgs(A, OperArr[B], RegText[CurBaseText + (OperArr[B + 1] div 16)], Args, C);
    end;

    // REC_RENAME: A=handle, B=operand-pool start, C=ArgCount (1..16). Same key-reading shape
    // as ExecRecGet, but Rename returns no result (RecordId-only key change, §7.5).
    local procedure ExecRecRename(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        K1, K2, K3, K4, K5, K6, K7, K8, K9, K10 : Variant;
        K11, K12, K13, K14, K15, K16 : Variant;
    begin
        ArgCount := C;
        if ArgCount >= 1 then
            K1 := ReadRegisterAsVariant(OperArr[B] mod 16, OperArr[B] div 16);
        if ArgCount >= 2 then
            K2 := ReadRegisterAsVariant(OperArr[B + 1] mod 16, OperArr[B + 1] div 16);
        if ArgCount >= 3 then
            K3 := ReadRegisterAsVariant(OperArr[B + 2] mod 16, OperArr[B + 2] div 16);
        if ArgCount >= 4 then
            K4 := ReadRegisterAsVariant(OperArr[B + 3] mod 16, OperArr[B + 3] div 16);
        if ArgCount >= 5 then
            K5 := ReadRegisterAsVariant(OperArr[B + 4] mod 16, OperArr[B + 4] div 16);
        if ArgCount >= 6 then
            K6 := ReadRegisterAsVariant(OperArr[B + 5] mod 16, OperArr[B + 5] div 16);
        if ArgCount >= 7 then
            K7 := ReadRegisterAsVariant(OperArr[B + 6] mod 16, OperArr[B + 6] div 16);
        if ArgCount >= 8 then
            K8 := ReadRegisterAsVariant(OperArr[B + 7] mod 16, OperArr[B + 7] div 16);
        if ArgCount >= 9 then
            K9 := ReadRegisterAsVariant(OperArr[B + 8] mod 16, OperArr[B + 8] div 16);
        if ArgCount >= 10 then
            K10 := ReadRegisterAsVariant(OperArr[B + 9] mod 16, OperArr[B + 9] div 16);
        if ArgCount >= 11 then
            K11 := ReadRegisterAsVariant(OperArr[B + 10] mod 16, OperArr[B + 10] div 16);
        if ArgCount >= 12 then
            K12 := ReadRegisterAsVariant(OperArr[B + 11] mod 16, OperArr[B + 11] div 16);
        if ArgCount >= 13 then
            K13 := ReadRegisterAsVariant(OperArr[B + 12] mod 16, OperArr[B + 12] div 16);
        if ArgCount >= 14 then
            K14 := ReadRegisterAsVariant(OperArr[B + 13] mod 16, OperArr[B + 13] div 16);
        if ArgCount >= 15 then
            K15 := ReadRegisterAsVariant(OperArr[B + 14] mod 16, OperArr[B + 14] div 16);
        if ArgCount >= 16 then
            K16 := ReadRegisterAsVariant(OperArr[B + 15] mod 16, OperArr[B + 15] div 16);

        case ArgCount of
            1:
                RecRt.RenameRec(A, K1);
            2:
                RecRt.RenameRec(A, K1, K2);
            3:
                RecRt.RenameRec(A, K1, K2, K3);
            4:
                RecRt.RenameRec(A, K1, K2, K3, K4);
            5:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5);
            6:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6);
            7:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7);
            8:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8);
            9:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9);
            10:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10);
            11:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11);
            12:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12);
            13:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13);
            14:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14);
            15:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14, K15);
            16:
                RecRt.RenameRec(A, K1, K2, K3, K4, K5, K6, K7, K8, K9, K10, K11, K12, K13, K14, K15, K16);
        end;
    end;

    // ARR_NEW  A = dest int reg (fresh handle), B = ElemClass, C = TotalN*2 + IsGlobal(0/1).
    // Mirrors LIST_NEW's shape (§20.6) — the fresh handle is stored back through the normal
    // StoreToSym path by the lowerer, so this Exec only needs to allocate and, for a LOCAL
    // array, track the handle on the frame-scoped AllocStack for reclamation (§20.5/20.11).
    local procedure ExecArrNew(A: Integer; B: Integer; C: Integer)
    var
        Handle: Integer;
        IsGlobal: Integer;
        TotalN: Integer;
    begin
        IsGlobal := C mod 2;
        TotalN := C div 2;
        Handle := ArrayRt.NewBlock(B, TotalN);
        RegInt[CurBaseInt + A] := Handle;
        if IsGlobal = 0 then
            TrackLocalHandle("ALI TypeKind"::Array, Handle);
    end;

    // ARR_REBIND (Handle Lifecycle Unification Phase 5): `arrayVar := ProcCall()`. The new
    // handle (B) was already escape-tracked into THIS frame's alloc-stack segment by PopFrame
    // when the call returned (Array is an ordinary IsAllocStackHandleKind member) — nothing to
    // track here. The OLD handle (A's current value) is always frame-local (the binder only
    // allows this shape for a local array var), so free it: scan this frame's own segment,
    // remove its entry, release the block, then rebind the register to the new handle.
    local procedure ExecArrRebind(A: Integer; B: Integer)
    var
        Freed: Boolean;
        i: Integer;
        NewHandle: Integer;
        OldHandle: Integer;
    begin
        OldHandle := RegInt[CurBaseInt + A];
        NewHandle := RegInt[CurBaseInt + B];
        Freed := false;
        for i := AllocKindStack.Count() downto CurFrameAllocBase() + 1 do
            if (not Freed) and (AllocKindStack.Get(i) = "ALI TypeKind"::Array) and (AllocHandleStack.Get(i) = OldHandle) then begin
                AllocKindStack.RemoveAt(i);
                AllocHandleStack.RemoveAt(i);
                Freed := true;
            end;
        if Freed then
            ArrayRt.FreeBlock(OldHandle);
        RegInt[CurBaseInt + A] := NewHandle;
    end;

    // ARR_COMPRESS  A = handle reg (frame-relative Int reg), B = dest count int reg, C = 0
    // (unused). Text arrays only (bind-time checked): compacts non-empty elements to the
    // front over TotalN (flat order, §20.14), blanks the trailing tail, writes the count.
    local procedure ExecArrCompress(A: Integer; B: Integer; C: Integer)
    var
    //Handle: Integer;
    begin
        // Whole compaction runs inside the block on its native Cells (§20.14) — one Blocks.Get
        // instead of a ReadCell/WriteCell (each a Blocks.Get) per element.
        //Handle := RegInt[CurBaseInt + A];
        RegInt[CurBaseInt + B] := ArrayRt.CompressBlock(RegInt[CurBaseInt + A]);
    end;

    // ARR_COPY  A = operand-pool start [destHandleReg, srcHandleReg, posReg, lenReg], B =
    // element reg class, C = hasLength (1/0). Copies Len elements from src[Pos..] into
    // dest[1..] (native CopyArray semantics, flat order over TotalN); when Length is omitted
    // it runs from Pos to the end of source. Bounds are native-style checked.
    local procedure ExecArrCopy(A: Integer; B: Integer; C: Integer)
    var
        DestHandle: Integer;
        DN: Integer;
        Len: Integer;
        Pos: Integer;
        SN: Integer;
        SrcHandle: Integer;
    begin
        DestHandle := RegInt[CurBaseInt + OperArr[A]];
        SrcHandle := RegInt[CurBaseInt + OperArr[A + 1]];
        DN := ArrayRt.TotalNOf(DestHandle);
        SN := ArrayRt.TotalNOf(SrcHandle);
        Pos := RegInt[CurBaseInt + OperArr[A + 2]];
        if C = 1 then
            Len := RegInt[CurBaseInt + OperArr[A + 3]]
        else
            Len := SN - Pos + 1;
        if (Pos < 1) or (Pos > SN) then
            Error('ALI987: CopyArray source position %1 out of bounds (1..%2)', Pos, SN);
        if Len < 0 then
            Error('ALI987: CopyArray length %1 is negative', Len);
        if Pos + Len - 1 > SN then
            Error('ALI987: CopyArray reads past end of source (position %1 + length %2 exceeds %3)', Pos, Len, SN);
        if Len > DN then
            Error('ALI987: CopyArray length %1 exceeds destination size %2', Len, DN);
        // Bounds validated above; the copy loop runs in the runtime with both blocks resolved
        // once (no per-cell Blocks.Get).
        ArrayRt.CopyBlock(DestHandle, SrcHandle, Pos, Len);
    end;

    // Common index-write bound check + space-extension. C packs (idxReg * 4096 + MaxLen), where
    // MaxLen is the target's declared length (0 = unbounded Text). Bounded Text[n]/Code[n]: a write
    // within the declared length space-extends the buffer (so `t[4] := x` works on a shorter value,
    // per §19.4 fixed-buffer semantics); past the declared length errors. Unbounded Text keeps
    // native AL semantics — the position must already exist. Returns the resolved 1-based index.
    local procedure TxtCharWritePrep(var TxtVal: Text; C: Integer): Integer
    var
        Idx: Integer;
        MaxLen: Integer;
    begin
        Idx := RegInt[CurBaseInt + (C div 4096)];
        MaxLen := C mod 4096;
        if Idx < 1 then
            Error('ALI972: text index %1 out of bounds (must be >= 1)', Idx);
        if MaxLen = 0 then begin
            if Idx > StrLen(TxtVal) then
                Error('ALI972: text index %1 out of bounds (1..%2)', Idx, StrLen(TxtVal));
        end else begin
            if Idx > MaxLen then
                Error('The length of the string is %1, but it must be less than or equal to %2 characters.', Idx, MaxLen);
            if Idx > StrLen(TxtVal) then
                TxtVal := PadStr(TxtVal, Idx, ' ');
        end;
        exit(Idx);
    end;

    // TXT_CHAR_SET A=text reg (in/out), B=char-code int reg (ASCII), C=idxReg*4096 + MaxLen.
    local procedure ExecTxtCharSet(A: Integer; B: Integer; C: Integer)
    var
        Idx: Integer;
        TxtVal: Text;
    begin
        TxtVal := RegText[CurBaseText + A];
        Idx := TxtCharWritePrep(TxtVal, C);
        TxtVal[Idx] := RegInt[CurBaseInt + B];
        RegText[CurBaseText + A] := TxtVal;
    end;

    // TXT_CHAR_SET_TEXT A=text reg (in/out), B=single-character src text reg, C=idxReg*4096 + MaxLen.
    local procedure ExecTxtCharSetText(A: Integer; B: Integer; C: Integer)
    var
        Idx: Integer;
        SrcVal: Text;
        TxtVal: Text;
    begin
        TxtVal := RegText[CurBaseText + A];
        SrcVal := RegText[CurBaseText + B];
        if StrLen(SrcVal) <> 1 then
            Error('ALI973: cannot assign a %1-character value to a single text position (expected length 1)', StrLen(SrcVal));
        Idx := TxtCharWritePrep(TxtVal, C);
        TxtVal[Idx] := SrcVal[1];
        RegText[CurBaseText + A] := TxtVal;
    end;

    // CHAR_TO_TEXT A=dest text reg, B=src int reg holding a Char code point (C unused).
    // Native AL formats a Char as the printable character it represents, NOT its decimal
    // ordinal (that's TO_TEXT/FormatRegister, used for genuine Integer/Decimal/etc. operands)
    // — going through an actual `Char` variable here (rather than Format() on the raw
    // Integer) is what gets that native character-formatting behavior (§6.4).
    local procedure ExecCharToText(A: Integer; B: Integer)
    var
        ChScratch: Char;
    begin
        ChScratch := RegInt[CurBaseInt + B];
        RegText[CurBaseText + A] := Format(ChScratch);
    end;

    // ===== M6 stream ops (§19.7) — shared by both dispatch shapes =====
    // Handle operands ABSOLUTE (stream handle space); text/bool/int regs frame-relative.
    // Handle Lifecycle Unification (Phase 3): stream handle operands are now Int registers.
    // HA/HB resolved unconditionally (cheap; unused where an opcode's operand isn't a handle).
    local procedure ExecStreamOp(Op: Integer; A: Integer; B: Integer; C: Integer)
    var
        Bytes: Integer;
        CntReg: Integer;
        HA: Integer;
        HB: Integer;
        LenReg: Integer;
        Packed: Integer;
        Txt: Text;
        V: Variant;
    begin
        // Same speculative-read hazard as ExecRecordOp's HA/HB (see its header): STRM_NEW's B
        // is IsOut*2+IsGlobal, a small literal, not a handle register — bounds-guard both.
        // SafeRegInt inlined: these two fire unconditionally on every opcode of this family,
        // and a call costs ~450ns against the two comparisons + array read it wrapped.
        HA := CurBaseInt + A;
        if (HA < 1) or (HA > 8192) then
            HA := 0
        else
            HA := RegInt[HA];
        HB := CurBaseInt + B;
        if (HB < 1) or (HB > 8192) then
            HB := 0
        else
            HB := RegInt[HB];
        case Op of
            258: // STRM_NEW (repurposed from STRM_OPEN, same rationale as REC_NEW/246): A = dest
                 // int reg (fresh handle), B = IsOut*2 + IsGlobal(0/1)
                ExecStrmNew(A, B);
            259: // STRM_LINK: A = in handle, B = out handle
                StrmRt.LinkInToOut(HA, HB, 0);
            260: // STRM_WRITETEXT: A = handle, B = src text reg, C = Length reg (0 none, -1 = WriteText())
                case true of
                    C = 0:
                        StrmRt.WriteText(HA, RegText[CurBaseText + B]);
                    C < 0:
                        StrmRt.WriteNewLine(HA);
                    else
                        StrmRt.WriteTextN(HA, RegText[CurBaseText + B], RegInt[CurBaseInt + C]);
                end;
            261: // STRM_WRITELINE
                StrmRt.WriteLine(HA, RegText[CurBaseText + B]);
            262: // STRM_READTEXT: A = dest text reg, B = handle, C = cntReg*100000 + Length reg (0 = none)
                begin
                    LenReg := C mod 100000;
                    if LenReg = 0 then
                        Bytes := StrmRt.ReadText(HB, Txt)
                    else
                        Bytes := StrmRt.ReadTextN(HB, RegInt[CurBaseInt + LenReg], Txt);
                    RegText[CurBaseText + A] := Txt;
                    CntReg := C div 100000;
                    if CntReg > 0 then
                        RegInt[CurBaseInt + CntReg] := Bytes;
                end;
            263: // STRM_EOS: A = dest bool reg, B = handle
                RegBool[CurBaseBool + A] := StrmRt.EndOfStream(HB);
            264: // STRM_LENGTH: A = dest int reg, B = handle
                RegInt[CurBaseInt + A] := StrmRt.StreamLength(HB);
            461: // STRM_WRITEVAL: A = handle, B = value reg, C = cntReg*100000 + typeOrd*16 + valueClass
                begin
                    Bytes := StrmRt.WriteValue(HA, (C mod 100000) div 16, ReadRegisterAsVariant(C mod 16, B));
                    CntReg := C div 100000;
                    if CntReg > 0 then
                        RegInt[CurBaseInt + CntReg] := Bytes;
                end;
            462: // STRM_READVAL: A = dest value reg, B = handle, C = cntReg*100000 + typeOrd*16 + targetClass,
                 // or -poolIdx with a Length: pool[idx] = that packing, pool[idx+1] = Length reg
                begin
                    Packed := C;
                    LenReg := 0;
                    if C < 0 then begin
                        Packed := OperArr[-C];
                        LenReg := OperArr[1 - C];
                    end;
                    if LenReg = 0 then
                        Bytes := StrmRt.ReadValue(HB, (Packed mod 100000) div 16, -1, V)
                    else
                        Bytes := StrmRt.ReadValue(HB, (Packed mod 100000) div 16, RegInt[CurBaseInt + LenReg], V);
                    WriteRegisterFromVariant(Packed mod 16, A, V);
                    CntReg := Packed div 100000;
                    if CntReg > 0 then
                        RegInt[CurBaseInt + CntReg] := Bytes;
                end;
            463: // STRM_POSGET: A = dest int reg, B = handle
                RegInt[CurBaseInt + A] := StrmRt.GetPosition(HB);
            464: // STRM_POSSET: A = handle, B = new-position int reg
                StrmRt.SetPosition(HA, RegInt[CurBaseInt + B]);
            465: // STRM_RESETPOS: A = handle
                StrmRt.ResetPos(HA);
            else
                Error('ALI951: invalid stream opcode %1 at PC %2', Op, PC);
        end;
    end;

    // STRM_NEW: A = dest int reg (fresh handle), B = IsOut*2 + IsGlobal(0/1).
    local procedure ExecStrmNew(A: Integer; B: Integer)
    var
        Handle: Integer;
        IsGlobal: Integer;
        IsOut: Integer;
        Kind: Integer;
    begin
        IsGlobal := B mod 2;
        IsOut := (B div 2) mod 2;
        Handle := StrmRt.NewStream(IsOut = 1);
        RegInt[CurBaseInt + A] := Handle;
        if IsOut = 1 then
            Kind := "ALI TypeKind"::OutStream
        else
            Kind := "ALI TypeKind"::InStream;
        if IsGlobal = 0 then
            TrackLocalHandle(Kind, Handle);
    end;

    // ===== M9 TextBuilder ops =====
    //
    // TB_METHOD: A = handle (ABSOLUTE, TextBuilder handle space), B = operand-pool start
    // (each entry regIdx*16+class, read LIVE — CALL_BUILTIN_LIVE convention), C = OutReg*
    // 100000 + OutCls*10000 + MethodId*100 + ArgCount. Method ids mirror
    // "ALI Binder".TextBuilderMethodId.
    local procedure ExecTextBuilderOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        HA: Integer;
        IsGlobal: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultInt: Integer;
        ResultText: Text;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;

        // Handle Lifecycle Unification (Phase 3): MethodId 0 = "New" (mirrors HTTP_METHOD's
        // scheme) — A/B are unused for this id; a fresh handle is allocated and written into
        // OutReg (packed exactly like every other TB_METHOD result), tracked when local
        // (IsGlobal packed into the low ArgCount digit, same trick as ARR_NEW/HTTP_METHOD New).
        if MethodId = 0 then begin
            IsGlobal := ArgCount mod 2;
            ResultInt := TbRt.NewTb();
            if IsGlobal = 0 then
                TrackLocalHandle("ALI TypeKind"::TextBuilder, ResultInt);
            if (OutCls > 0) and (OutReg > 0) then
                RegInt[CurBaseInt + OutReg] := ResultInt;
            exit;
        end;

        HA := RegInt[CurBaseInt + A];
        case MethodId of
            1: // Append(Text)
                TbRt.Append(HA, ArgAsText(B, 0));
            2: // AppendLine()
                TbRt.AppendLine(HA);
            3: // AppendLine(Text)
                TbRt.AppendLineText(HA, ArgAsText(B, 0));
            4: // Capacity() -> Int
                ResultInt := TbRt.GetCapacity(HA);
            5: // Capacity(Int)
                TbRt.SetCapacity(HA, ArgAsInt(B, 0));
            6: // Clear()
                TbRt.ClearI(HA);
            7: // EnsureCapacity(Int)
                TbRt.EnsureCapacity(HA, ArgAsInt(B, 0));
            8: // Insert(Int, Text)
                TbRt.Insert(HA, ArgAsInt(B, 0), ArgAsText(B, 1));
            9: // Length() -> Int
                ResultInt := TbRt.GetLength(HA);
            10: // Length(Int)
                TbRt.SetLength(HA, ArgAsInt(B, 0));
            11: // MaxCapacity() -> Int
                ResultInt := TbRt.MaxCapacity(HA);
            12: // Remove(Int, Int)
                TbRt.Remove(HA, ArgAsInt(B, 0), ArgAsInt(B, 1));
            13: // Replace(Text, Text)
                TbRt.Replace(HA, ArgAsText(B, 0), ArgAsText(B, 1));
            14: // Replace(Text, Text, Int, Int)
                TbRt.ReplaceRange(HA, ArgAsText(B, 0), ArgAsText(B, 1), ArgAsInt(B, 2), ArgAsInt(B, 3));
            15: // ToText() -> Text
                ResultText := TbRt.ToText(HA);
            16: // ToText(Int, Int) -> Text
                ResultText := TbRt.ToTextRange(HA, ArgAsInt(B, 0), ArgAsInt(B, 1));
            else
                Error('ALI951: invalid TextBuilder method id %1 at PC %2', MethodId, PC);
        end;

        if (OutCls > 0) and (OutReg > 0) then
            case OutCls of
                1: // Int register file
                    RegInt[CurBaseInt + OutReg] := ResultInt;
                5: // Text register file
                    RegText[CurBaseText + OutReg] := ResultText;
            end;
    end;

    // DLG_METHOD: A = handle (Dialog handle space), B = operand-pool start (regIdx*16+class,
    // read LIVE), C = MethodId*100 + ArgCount. All void; Hide/Show is decided inside
    // "ALI Dialog Runtime" from the Dialog run-option. Method ids: "ALI Binder".DialogMethodId.
    local procedure ExecDialogOp(A: Integer; B: Integer; C: Integer)
    var
        HA: Integer;
        Handle: Integer;
        IsGlobal: Integer;
    begin
        // Handle Lifecycle Unification (Phase 3): MethodId 0 = "New" — A = dest int reg for
        // the fresh handle, low ArgCount digit = IsGlobal (see "ALI Lowerer".EmitNewDialogForProc/
        // Global), tracked on the frame-scoped alloc stack when local, exactly like TB_METHOD 0.
        if (C div 100) = 0 then begin
            IsGlobal := C mod 100;
            Handle := DlgRt.NewDialog();
            RegInt[CurBaseInt + A] := Handle;
            if IsGlobal = 0 then
                TrackLocalHandle("ALI TypeKind"::Dialog, Handle);
            exit;
        end;

        HA := RegInt[CurBaseInt + A];
        case (C div 100) of
            1: // Open(Text)
                DlgRt.OpenDlg(HA, ArgAsText(B, 0));
            2: // Update()
                DlgRt.Update0(HA);
            3: // Update(Integer)
                DlgRt.UpdateId(HA, ArgAsInt(B, 0));
            4: // Update(Integer, value)
                DlgRt.UpdateVal(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1));
            5: // Close()
                DlgRt.CloseDlg(HA);
            else
                Error('ALI952: invalid Dialog method id %1 at PC %2', C div 100, PC);
        end;
    end;

    // REF_METHOD: the RecordRef-ONLY surface of a user-declared RecordRef variable. Packing is
    // the TB_METHOD one — A = receiver handle reg (Int, read LIVE; 0 = never opened), B =
    // operand-pool start, C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount.
    //
    // Everything NOT here (Find/FindSet/Count/Insert/SetView/Mark/links/isolation/...) executes
    // as its ordinary REC_* opcode with the very same handle — a RecordRef and a Record variable
    // are the same handle into the same "ALI Rec Runtime" bank, and reimplementing ~50 methods
    // for the second static type would have been pure duplication. Method ids: "ALI Binder".
    // RecordRefMethodId. Id 99 is the lowerer's assert-open guard emitted before a routed REC_*.
    local procedure ExecRecordRefOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        Cond: Integer;
        HA: Integer;
        MethodId: Integer;
        NewH: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultBool: Boolean;
        ResultInt: Integer;
        ResultText: Text;
        ResultV: Variant;
        CompanyNm: Text;
        // One Boolean local for the optional flag every arm that has one takes (Open's
        // Temporary, SetTable's IncludeFilters) — they are never both live.
        Flag: Boolean;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        // P4 (ids 18-39): that digit is a FLAGS field there, not OutCls — see the packing note in
        // "ALI Lowerer".LowerRecordRefMethod. bit0 = "result consumed" (ModifyAll's optional
        // return); the result class comes from the method id, because GetRangeMin/GetRangeMax
        // return a Variant and class 11 does not fit in one digit.
        if MethodId >= 18 then begin
            Cond := OutCls mod 2;
            OutCls := RecordRefDynOutClass(MethodId);
        end;

        // Same speculative-read hazard ExecRecordOp guards against: CurBaseInt + A can leave the
        // 1-based register file when A is 0 (the guard form passes no operands at all).
        HA := CurBaseInt + A;
        if (HA < 1) or (HA > 8192) then
            HA := 0
        else
            HA := RegInt[HA];

        case MethodId of
            99: // <compiler-internal> assert-open, emitted before a routed REC_* instruction
                begin
                    RecRt.AssertRefOpen(HA);
                    exit;
                end;
            1:  // Open(Integer|Text [, Temporary] [, CompanyName]) — the overload is chosen by
                // the FIRST operand's REGISTER CLASS, because the binder cannot know an argument
                // type before it has picked a method id (see "ALI Opcode"::REF_METHOD).
                begin
                    Flag := false;
                    CompanyNm := '';
                    if ArgCount >= 2 then
                        Flag := ArgAsBool(B, 1);
                    if ArgCount = 3 then
                        CompanyNm := ArgAsText(B, 2);
                    if OperArr[B] mod 16 = 1 then       // RegClassInt -> a table id
                        NewH := RecRt.OpenRefById(HA, ArgAsInt(B, 0), Flag, CompanyNm)
                    else
                        NewH := RecRt.OpenRefByName(HA, ArgAsText(B, 0), Flag, CompanyNm);
                    FcBumpHandle(HA);    // PERF TEST
                    FcBumpHandle(NewH);    // PERF TEST
                    // Rebind the variable: Open ALLOCATES the handle (a RecordRef local gets none
                    // at proc entry, unlike a Record local). The lowerer adds the global /
                    // var-param store-back after this instruction.
                    RegInt[CurBaseInt + A] := NewH;
                    // Handle Lifecycle Unification: a FRESH slot (the receiver held 0) is owned by
                    // this frame until it is closed or the frame pops. Re-opening an already-open
                    // ref keeps the same slot, so there is nothing new to own. Without this, a proc
                    // that opened a RecordRef and did not Close() burned one bank slot PER CALL —
                    // the only per-call unbounded consumer of the 256-slot bank (ALI954).
                    if HA = 0 then
                        TrackLocalHandle("ALI TypeKind"::RecordRef, NewH);
                    exit;
                end;
            2:  // Close() — hand the bank slot back and return the variable to the truthful
                // "not open" state, so a later use raises ALI937 rather than reading a slot that
                // has since been recycled by somebody else's Open().
                begin
                    UntrackLocalHandle("ALI TypeKind"::RecordRef, HA);   // reclaimed here, not at frame pop
                    RecRt.CloseRef(HA);
                    FcBumpHandle(HA);    // PERF TEST
                    RegInt[CurBaseInt + A] := 0;
                    exit;
                end;
            6:  // GetTable(Record) — operand 0 is the record variable's own handle register.
                //
                // Sits UP HERE with Open/Close, above the assert-open guard, because it is the
                // THIRD method of this family that OPENS a ref rather than requiring one: on a
                // never-opened receiver it adopts the record's table (GetTableRef allocates the
                // slot itself, exactly as Open does), which is what makes `r.GetTable(c)` usable
                // as the first thing a script ever does with a RecordRef — the documented P1
                // contract, and native AL's. Leaving it below the guard made that documented
                // first use fail with ALI937 "this RecordRef is not open", i.e. the ref could
                // only be adopted once it had already been opened some other way.
                begin
                    RecRt.GetTableRef(HA, ArgAsInt(B, 0), NewH);
                    FcBumpHandle(HA);    // PERF TEST
                    FcBumpHandle(NewH);    // PERF TEST
                    RegInt[CurBaseInt + A] := NewH;     // GetTable may re-point (and so re-open) the ref
                    if HA = 0 then
                        TrackLocalHandle("ALI TypeKind"::RecordRef, NewH);   // adoption allocated the slot — same rule as Open
                    exit;
                end;
        end;

        // Everything below needs an OPEN ref; one guard covers them all.
        RecRt.AssertRefOpen(HA);
        case MethodId of
            3:  // Number() -> Integer
                ResultInt := RecRt.NumberOfRef(HA);
            4:  // Name() -> Text (the table's object name — RecRt.TableNameOf is the same call
                // Record.TableName already uses)
                ResultText := RecRt.TableNameOf(HA);
            5:  // Caption() -> Text
                ResultText := RecRt.TableCaptionOf(HA);
            7:  // SetTable(Record [, IncludeFilters])
                begin
                    Flag := false;
                    if ArgCount = 2 then
                        Flag := ArgAsBool(B, 1);
                    RecRt.SetTableRef(HA, ArgAsInt(B, 0), Flag);
                    FcBumpHandle(ArgAsInt(B, 0));    // PERF TEST — record content replaced via Copy
                end;
            8:  // Duplicate() -> RecordRef (a fresh handle on the same bank)
                begin
                    ResultInt := RecRt.DuplicateRef(HA);
                    FcBumpHandle(ResultInt);    // PERF TEST
                    // Owned by this frame until closed or popped — a Duplicate() in a hot loop
                    // used to burn slots with nothing ever reclaiming them.
                    TrackLocalHandle("ALI TypeKind"::RecordRef, ResultInt);
                end;
            9:  // FieldExist(Integer|Text) -> Boolean — class-branched like Open. The by-NUMBER
                // form still goes through the Rec Runtime's own FieldExistRec, the exact call
                // REC_FIELDEXIST makes for a Record.
                if OperArr[B] mod 16 = 1 then
                    ResultBool := RecRt.FieldExistRec(HA, ArgAsInt(B, 0))
                else
                    ResultBool := RecRt.FieldExistByName(HA, ArgAsText(B, 0));
            10, 11, 12, 13, 14:     // System*No() -> Integer
                ResultInt := RecRt.SystemFieldNoRef(HA, MethodId);
            15: // Field(Integer|Text) -> FieldRef handle. Class-branched like Open/FieldExist;
                // the by-NAME form is an ALI extension (native takes a number only).
                if OperArr[B] mod 16 = 1 then
                    ResultInt := RecRt.MakeFieldRef(HA, ArgAsInt(B, 0))
                else
                    ResultInt := RecRt.MakeFieldRefByName(HA, ArgAsText(B, 0));
            16: // FieldIndex(Integer) -> FieldRef handle (i-th field, not field number i)
                ResultInt := RecRt.MakeFieldRefByIndex(HA, ArgAsInt(B, 0));
            17: // KeyIndex(Integer) -> KeyRef handle
                ResultInt := RecRt.MakeKeyRef(HA, ArgAsInt(B, 0));
            18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29,
            30, 31, 32, 33, 34, 35, 36, 37, 38, 39:
                // P4: the field-number surface. Its own procedure so the fat locals it needs (a
                // 14-Variant filter-arg block, a 16-Integer field-no block) stay OUT of this
                // dispatcher's frame — ids 1-17 are the hot path and must not pay for them.
                ExecRefDynFieldOp(HA, B, MethodId, ArgCount, Cond, ResultBool, ResultText, ResultV);
            else
                Error('ALI951: invalid RecordRef method id %1 at PC %2', MethodId, PC);
        end;

        if (OutCls > 0) and (OutReg > 0) then
            case OutCls of
                1: // Int register file (Integer results AND the Duplicate() handle)
                    RegInt[CurBaseInt + OutReg] := ResultInt;
                4: // Boolean register file
                    RegBool[CurBaseBool + OutReg] := ResultBool;
                5: // Text register file
                    RegText[CurBaseText + OutReg] := ResultText;
                11: // Variant register file — P4's GetRangeMin/GetRangeMax only. A RecordRef's
                    // field type is only known at run time, so Variant is the honest static type,
                    // exactly as for FieldRef.Value (see ExecFieldRefOp).
                    RegVariant[CurBaseVar + OutReg] := ResultV;
            end;
    end;

    // The result register class of each P4 REF_METHOD id (18-39) — the packing carries no OutCls
    // for that block (see ExecRecordRefOp's header). Mirrors the ResultT arms of "ALI Binder".
    // BindRecordRefMethod: if a method's return type changes there, it changes here. 0 = void.
    local procedure RecordRefDynOutClass(MethodId: Integer): Integer
    begin
        case MethodId of
            22, 23:                     // GetRangeMin / GetRangeMax
                exit("ALI Register Class"::"Variant");
            20, 30, 31:                 // GetFilter / FieldName / FieldCaption
                exit("ALI Register Class"::"Text");
            25, 33, 35, 36, 37, 38, 39: // ModifyAll / GetAscending / the load-field family
                exit("ALI Register Class"::"Boolean");
        end;
        // 18/19/21/24/26/27/28/29/32/34 are void (SetCurrentKey included — the Record path has
        // never exposed its native Boolean either, and parity beats novelty).
        exit(0);
    end;

    // ===== P4: RecordRef methods whose FIELD NUMBERS arrive at run time =====
    //
    // Every call below is the SAME "ALI Rec Runtime" procedure the Record path calls — they have
    // always taken the field number as a plain Integer parameter, so nothing about the record
    // engine is new here. The only thing P4 changes is where the number comes from: REF_METHOD's
    // operand pool, read LIVE off a register (ArgAsInt), instead of a constant burned into the
    // instruction at bind time. The Record path keeps its constants and is not touched.
    //
    // Operand layout, uniform: the field number(s) come FIRST (index 0, plus index 1 for
    // CopyFilter's second field), then the method's own arguments. Values are read as Variants
    // because there is no bind-time field type to convert them to — the platform's own FieldRef
    // assignment does the coercion, the same way it does for a FieldRef receiver (§3c).
    //
    // Cond is the CALL SITE's "result consumed" flag, which cannot ride in the pool because it is
    // not an argument; ModifyAll is the only id that reads it (optional-return contract).
    local procedure ExecRefDynFieldOp(HA: Integer; B: Integer; MethodId: Integer; ArgCount: Integer; Cond: Integer; var ResultBool: Boolean; var ResultText: Text; var ResultV: Variant)
    var
        Flag: Boolean;
        k: Integer;
        AutoF: array[16] of Integer;
        FieldNos: List of [Integer];
        FilterArgs: array[14] of Variant;
    begin
        case MethodId of
            18: // SetRange(fieldNo [, value [, toValue]]) — 1/2/3 args = clear / eq / from..to,
                // the same three runtime calls REC_SETRANGE_CLR / REC_SETRANGE / REC_SETRANGE_2 make
                case ArgCount of
                    1:
                        RecRt.ClearFieldRange(HA, ArgAsInt(B, 0));
                    2:
                        RecRt.SetRangeEq(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1));
                    else
                        RecRt.SetRangeBetween(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1), ArgAsVariant(B, 2));
                end;
            19: // SetFilter(fieldNo, filterText [, up to 14 %1-substitution values]). One call for
                // both shapes: SetFilterFieldArgs' N=0 arm IS the plain SetFilter.
                begin
                    Clear(FilterArgs);
                    for k := 1 to ArgCount - 2 do
                        FilterArgs[k] := ArgAsVariant(B, k + 1);
                    RecRt.SetFilterFieldArgs(HA, ArgAsInt(B, 0), ArgAsText(B, 1), FilterArgs, ArgCount - 2);
                end;
            20: // GetFilter(fieldNo) -> Text
                ResultText := RecRt.GetFilterField(HA, ArgAsInt(B, 0));
            21: // CopyFilter(fromFieldNo, toFieldNo) — both numbers live, both on THIS
                // RecordRef: the FieldRef surface names fields by number, so there is no second
                // record to name here (the Record path takes `Other.Field` instead).
                RecRt.CopyFilterField(HA, ArgAsInt(B, 0), HA, ArgAsInt(B, 1));
            22: // GetRangeMin(fieldNo) -> Variant
                ResultV := RecRt.GetRangeMinField(HA, ArgAsInt(B, 0));
            23: // GetRangeMax(fieldNo) -> Variant
                ResultV := RecRt.GetRangeMaxField(HA, ArgAsInt(B, 0));
            24: // Validate(fieldNo, value) — runs the field's OnValidate natively
                RecRt.ValidateField(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1));
            25: // ModifyAll(fieldNo, value [, RunTrigger]) -> Bool. The trigger flag is a LIVE
                // register here rather than the Record path's const-folded literal: a RecordRef
                // script is dynamic by nature, and the pool already carries it for free.
                begin
                    Flag := false;
                    if ArgCount = 3 then
                        Flag := ArgAsBool(B, 2);
                    ResultBool := RecRt.ModifyAllField(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1), Flag, Cond = 1);
                end;
            26: // CalcFields(fieldNo, ...) — one call per field, as ExecRecFieldNoList does
                for k := 0 to ArgCount - 1 do
                    RecRt.CalcFieldsField(HA, ArgAsInt(B, k));
            27: // CalcSums(fieldNo, ...)
                for k := 0 to ArgCount - 1 do
                    RecRt.CalcSumsField(HA, ArgAsInt(B, k));
            28: // TestField(fieldNo [, value])
                if ArgCount = 2 then
                    RecRt.TestFieldValue(HA, ArgAsInt(B, 0), ArgAsVariant(B, 1))
                else
                    RecRt.TestFieldEmpty(HA, ArgAsInt(B, 0));
            29: // FieldError(fieldNo [, Text])
                if ArgCount = 2 then
                    RecRt.FieldErrorText(HA, ArgAsInt(B, 0), ArgAsText(B, 1))
                else
                    RecRt.FieldErrorDefault(HA, ArgAsInt(B, 0));
            30: // FieldName(fieldNo) -> Text
                ResultText := RecRt.FieldNameOf(HA, ArgAsInt(B, 0));
            31: // FieldCaption(fieldNo) -> Text
                ResultText := RecRt.FieldCaptionOf(HA, ArgAsInt(B, 0));
            32: // SetAscending(fieldNo, Boolean)
                RecRt.SetAscendingField(HA, ArgAsInt(B, 0), ArgAsBool(B, 1));
            33: // GetAscending(fieldNo) -> Bool
                ResultBool := RecRt.GetAscendingField(HA, ArgAsInt(B, 0));
            34: // SetCurrentKey(fieldNo, ...) — the COUNT is bind-time-known (ArgCount), only the
                // values are live, so no run-time-variadic machinery is needed anywhere
                begin
                    for k := 0 to ArgCount - 1 do
                        FieldNos.Add(ArgAsInt(B, k));
                    RecRt.SetCurrentKeyList(HA, FieldNos);
                end;
            35: // SetAutoCalcFields(fieldNo, ...) -> Bool. REPLACE semantics, so it cannot be built
                // incrementally — shares the Record path's spelled-out arity ladder.
                begin
                    Clear(AutoF);
                    for k := 1 to ArgCount do
                        AutoF[k] := ArgAsInt(B, k - 1);
                    ResultBool := ApplyAutoCalcFields(HA, ArgCount, AutoF);
                end;
            36, 37, 38, 39:
                // SetLoadFields / AddLoadFields / LoadFields / AreFieldsLoaded(fieldNo, ...) ->
                // Bool. ApplyLoadFieldList's Which is 1..4, hence MethodId - 35.
                begin
                    for k := 0 to ArgCount - 1 do
                        FieldNos.Add(ArgAsInt(B, k));
                    ResultBool := ApplyLoadFieldList(HA, FieldNos, MethodId - 35);
                end;
        end;
    end;

    // FLD_METHOD: user-declared FieldRef (ids 1-31) and KeyRef (ids 40-43). Packing is the
    // TB_METHOD one — A = receiver handle reg (Int, read LIVE; 0 = unbound), B = operand-pool
    // start, C = OutReg*10000 + MethodId*100 + ArgCount — NOT TB_METHOD's packing: there is no
    // OutCls field, because Value/GetRangeMin/GetRangeMax return a Variant (register class 11)
    // and an 11 would overflow a one-digit OutCls straight into OutReg. Every method id here has
    // exactly one possible result class, so FieldRefOutClass derives it instead.
    //
    // The receiver register holds a PACKED PAIR, not a bank index: slot*2048 + recordHandle (see
    // "ALI Opcode"::FLD_METHOD). Nothing is decoded here — "ALI Rec Runtime" owns the packing
    // and every arm below hands it the raw handle, so there is exactly ONE place that knows the
    // layout. That is also why this opcode needs no assert-open guard of its own: the runtime's
    // AssertFieldRefBound checks BOTH halves (bound pair, and the record behind it still open).
    local procedure ExecFieldRefOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        FH: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultBool: Boolean;
        ResultInt: Integer;
        ResultText: Text;
        ResultV: Variant;
        FilterArgs: array[14] of Variant;
        k: Integer;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutReg := C div 10000;
        OutCls := FieldRefOutClass(MethodId);

        // Same speculative-read hazard ExecRecordOp/ExecRecordRefOp guard against.
        FH := CurBaseInt + A;
        if (FH < 1) or (FH > 8192) then
            FH := 0
        else
            FH := RegInt[FH];

        case MethodId of
            1:  // Value() -> Variant
                ResultV := RecRt.FieldRefGetValue(FH);
            2:  // Value(v) / `F.Value := v`
                RecRt.FieldRefSetValue(FH, ArgAsVariant(B, 0));
            3:  // Validate() / Validate(v)
                if ArgCount = 1 then
                    RecRt.FieldRefValidate(FH, ArgAsVariant(B, 0), true)
                else
                    RecRt.FieldRefValidate(FH, ResultV, false);
            4:  // SetRange() / SetRange(v) / SetRange(lo, hi) — one id, ArgCount branch
                case ArgCount of
                    0:
                        RecRt.FieldRefSetRange(FH, 0, ResultV, ResultV);
                    1:
                        RecRt.FieldRefSetRange(FH, 1, ArgAsVariant(B, 0), ResultV);
                    else
                        RecRt.FieldRefSetRange(FH, 2, ArgAsVariant(B, 0), ArgAsVariant(B, 1));
                end;
            5:  // SetFilter(Text [, up to 14 substitution args])
                begin
                    for k := 1 to ArgCount - 1 do
                        FilterArgs[k] := ArgAsVariant(B, k);
                    RecRt.FieldRefSetFilter(FH, ArgAsText(B, 0), ArgCount - 1, FilterArgs);
                end;
            6:  // GetFilter() -> Text
                ResultText := RecRt.FieldRefGetFilter(FH);
            7:  // GetRangeMin() -> Variant
                ResultV := RecRt.FieldRefGetRangeMin(FH);
            8:  // GetRangeMax() -> Variant
                ResultV := RecRt.FieldRefGetRangeMax(FH);
            9:  // CalcField()
                RecRt.FieldRefCalcField(FH);
            10: // CalcSum()
                RecRt.FieldRefCalcSum(FH);
            11: // TestField() / TestField(value) — one Variant form, not native's ~30 overloads
                if ArgCount = 1 then
                    RecRt.FieldRefTestField(FH, ArgAsVariant(B, 0), true)
                else
                    RecRt.FieldRefTestField(FH, ResultV, false);
            12: // FieldError() / FieldError(Text)
                if ArgCount = 1 then
                    RecRt.FieldRefFieldError(FH, ArgAsText(B, 0), true)
                else
                    RecRt.FieldRefFieldError(FH, '', false);
            13, 15, 21, 22:     // Name / Caption / OptionCaption / OptionMembers -> Text
                ResultText := RecRt.FieldRefTextInfo(FH, MethodId, 0);
            25, 26, 28, 29:     // GetEnumValue{Name,Caption}[FromOrdinalValue](i) -> Text
                ResultText := RecRt.FieldRefTextInfo(FH, MethodId, ArgAsInt(B, 0));
            14, 16, 17, 18, 20, 24:     // Number / Length / Class / Type / Relation / EnumValueCount
                ResultInt := RecRt.FieldRefIntInfo(FH, MethodId, 0);
            27: // GetEnumValueOrdinal(i) -> Integer
                ResultInt := RecRt.FieldRefIntInfo(FH, MethodId, ArgAsInt(B, 0));
            19, 23, 30:         // Active / IsEnum / IsOptimizedForTextSearch -> Boolean
                ResultBool := RecRt.FieldRefBoolInfo(FH, MethodId);
            31: // FieldRef.Record() -> RecordRef. Free under the pair design: the owning record
                // handle IS the low half of the FieldRef handle, so this is a decode, not a copy
                // — and the RecordRef it yields ALIASES the same bank slot, as in native AL.
                begin
                    RecRt.AssertFieldRefBound(FH);
                    ResultInt := RecRt.FieldRefRecHandle(FH);
                end;
            40: // KeyRef.Active() -> Boolean
                ResultBool := RecRt.KeyRefActive(FH);
            41: // KeyRef.FieldCount() -> Integer
                ResultInt := RecRt.KeyRefFieldCount(FH);
            42: // KeyRef.FieldIndex(i) -> FieldRef (same record handle, the key's i-th field)
                ResultInt := RecRt.KeyRefFieldRef(FH, ArgAsInt(B, 0));
            43: // KeyRef.Record() -> RecordRef (same decode as id 31)
                begin
                    RecRt.AssertKeyRefBound(FH);
                    ResultInt := RecRt.FieldRefRecHandle(FH);
                end;
            else
                Error('ALI951: invalid FieldRef/KeyRef method id %1 at PC %2', MethodId, PC);
        end;

        if (OutCls > 0) and (OutReg > 0) then
            case OutCls of
                1: // Int register file (Integer results, Option ordinals from Class()/Type(),
                   // AND the RecordRef/FieldRef handles ids 31/42/43 hand back)
                    RegInt[CurBaseInt + OutReg] := ResultInt;
                4: // Boolean register file
                    RegBool[CurBaseBool + OutReg] := ResultBool;
                5: // Text register file
                    RegText[CurBaseText + OutReg] := ResultText;
                11: // Variant register file — Value()/GetRangeMin()/GetRangeMax(). A FieldRef's
                    // field type is only known at run time, so Variant is the HONEST static type
                    // here; the ordinary Variant machinery (and Evaluate/Format on it) takes over
                    // from this point exactly as it does for a boxed field read.
                    RegVariant[CurBaseVar + OutReg] := ResultV;
            end;
    end;

    // The result register class of each FLD_METHOD id — the packing carries no OutCls field
    // (see ExecFieldRefOp's header). Mirrors the ResultT arms of "ALI Binder".BindFieldRefMethod:
    // if a method's return type changes there, it changes here. 0 = void.
    local procedure FieldRefOutClass(MethodId: Integer): Integer
    begin
        case MethodId of
            1, 7, 8:                                    // Value / GetRangeMin / GetRangeMax
                exit("ALI Register Class"::"Variant");
            6, 13, 15, 21, 22, 25, 26, 28, 29:          // the Text-returning metadata surface
                exit("ALI Register Class"::"Text");
            19, 23, 30, 40:                             // Active / IsEnum / IsOptimized / Key.Active
                exit("ALI Register Class"::"Boolean");
            14, 16, 17, 18, 20, 24, 27, 31, 41, 42, 43:
                // Integer, the Class()/Type() option ordinals, and the RecordRef/FieldRef handles
                // ids 31/42/43 return — every one of them an Int register (handles included:
                // that is the whole point of the packed-pair representation).
                exit("ALI Register Class"::Int);
        end;
        exit(0);    // 2/3/4/5/9/10/11/12 are void
    end;

    // ===== List/Dictionary RefShim ops (ListDictionaryPlan.md §3.3/§7.2) =====
    // Cold List arms only — Add/Get/Set/Count/Contains/IndexOf are inlined in RunLoopFlat.
    //
    // Shared operand convention for every method opcode (LIST_NEW/DICT_NEW are the two
    // exceptions, handled first below): A = handle reg (frame-relative Int reg holding the
    // LIVE handle value — decode classIndex/keyClass/valueClass straight off the handle
    // integer, since classIndex IS the RegClass* ordinal, ListDictionaryPlan.md §1), B =
    // operand-pool start for the method's value args (regIdx*16+class per entry, read live
    // exactly like CALL_BUILTIN_LIVE/TB_METHOD), C = OutReg*100 + ArgCount.
    local procedure ExecListOp(Op: Integer; A: Integer; B: Integer; C: Integer)
    var
        FreshH: Integer;
        Handle: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultV: Variant;
    begin
        OutReg := C div 100;
        OutCls := 0;

        if Op = 326 then begin     // LIST_NEW: A = dest reg, B = elemClass, C = IsGlobal(0/1)
            RegInt[CurBaseInt + A] := ListRt.NewList(B);
            if C = 0 then
                TrackLocalHandle("ALI TypeKind"::List, RegInt[CurBaseInt + A]);
            exit;
        end;

        Handle := RegInt[CurBaseInt + A];

        case Op of
            333:    // Remove(value) -> Boolean
                begin
                    ResultV := ListRt.Remove(Handle, ArgAsVariant(B, 0));
                    OutCls := 4;
                end;
            334:    // RemoveAt(index)
                ListRt.RemoveAt(Handle, ArgAsInt(B, 0));
            335:    // RemoveRange(index, count)
                ListRt.RemoveRange(Handle, ArgAsInt(B, 0), ArgAsInt(B, 1));
            336:    // Insert(index, value)
                ListRt.Insert(Handle, ArgAsInt(B, 0), ArgAsVariant(B, 1));
            337:    // AddRange(srcList) — sole pool entry is the SOURCE list's handle reg
                ListRt.AddRange(Handle, ArgAsInt(B, 0));
            338:    // GetRange(index, count) -> List of [T] (fresh handle, always tracked — a
                    // handle-returning method always allocates a new LOCAL, mirrors Http*'s
                    // handle-returning methods, e.g. Response.Content())
                begin
                    FreshH := ListRt.GetRange(Handle, ArgAsInt(B, 0), ArgAsInt(B, 1));
                    TrackLocalHandle("ALI TypeKind"::List, FreshH);
                    ResultV := FreshH;
                    OutCls := 1;
                end;
            339:    // Reverse()
                ListRt.Reverse(Handle);
            else
                Error('ALI951: invalid List opcode %1 at PC %2', Op, PC);
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // Cold Dictionary ops (New / Remove / Keys / Values). Add/Set/Get/ContainsKey/Count/TryGet are
    // inlined in RunLoopFlat.
    local procedure ExecDictOp(Op: Integer; A: Integer; B: Integer; C: Integer)
    var
        FreshH: Integer;
        Handle: Integer;
        OutReg: Integer;
        ResultV: Variant;
    begin
        OutReg := C div 100;

        if Op = 341 then begin     // DICT_NEW: A = dest reg, B = keyClass*16+valueClass, C = IsGlobal(0/1)
            RegInt[CurBaseInt + A] := DictRt.NewDict(B div 16, B mod 16);
            if C = 0 then
                TrackLocalHandle("ALI TypeKind"::Dictionary, RegInt[CurBaseInt + A]);
            exit;
        end;

        Handle := RegInt[CurBaseInt + A];
        case Op of
            346:    // Remove(key) -> Boolean
                begin
                    ResultV := DictRt.Remove(Handle, ArgAsVariant(B, 0));
                    if OutReg > 0 then
                        WriteRegisterFromVariant(4, OutReg, ResultV);
                end;
            348:    // Keys() -> List of [K] (fresh handle, always tracked — see LIST_GETRANGE)
                begin
                    FreshH := DictRt.Keys(Handle);
                    TrackLocalHandle("ALI TypeKind"::List, FreshH);
                    if OutReg > 0 then
                        RegInt[CurBaseInt + OutReg] := FreshH;
                end;
            349:    // Values() -> List of [V] (fresh handle, always tracked — see LIST_GETRANGE)
                begin
                    FreshH := DictRt.Values(Handle);
                    TrackLocalHandle("ALI TypeKind"::List, FreshH);
                    if OutReg > 0 then
                        RegInt[CurBaseInt + OutReg] := FreshH;
                end;
            else
                Error('ALI951: invalid Dictionary opcode %1 at PC %2', Op, PC);
        end;
    end;

    local procedure ArgAsVariant(B: Integer; Idx: Integer): Variant
    var
        Packed: Integer;
    begin
        Packed := OperArr[B + Idx];
        // Int is by far the commonest operand class; reading RegInt straight into the Variant
        // return saves the ReadRegisterAsVariant call (~450ns, ~10x the array read it wraps).
        if Packed mod 16 = 1 then
            exit(RegInt[CurBaseInt + (Packed div 16)]);
        exit(ReadRegisterAsVariant(Packed mod 16, Packed div 16));
    end;

    // Read operand-pool slot Idx (0-based offset from B) as Text/Int, live off its register.
    local procedure ArgAsText(B: Integer; Idx: Integer): Text
    var
        Packed: Integer;
    begin
        Packed := OperArr[B + Idx];
        exit(Format(ReadRegisterAsVariant(Packed mod 16, Packed div 16)));
    end;

    local procedure ArgAsInt(B: Integer; Idx: Integer): Integer
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        // Index/count args are emitted as class 1 in practice, so this is the path taken by
        // essentially every List/Dict/Array/Http/Json/Xml method call: it drops both the
        // ReadRegisterAsVariant call and the Variant boxing round-trip. The generic tail stays
        // for any class the lowerer might legitimately widen from (Byte/Char are Int-backed).
        if Packed mod 16 = 1 then
            exit(RegInt[CurBaseInt + (Packed div 16)]);
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsDuration(B: Integer; Idx: Integer): Duration
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsDec(B: Integer; Idx: Integer): Decimal
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsBool(B: Integer; Idx: Integer): Boolean
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsDate(B: Integer; Idx: Integer): Date
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsTime(B: Integer; Idx: Integer): Time
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsDateTime(B: Integer; Idx: Integer): DateTime
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    local procedure ArgAsBig(B: Integer; Idx: Integer): BigInteger
    var
        Packed: Integer;
        V: Variant;
    begin
        Packed := OperArr[B + Idx];
        V := ReadRegisterAsVariant(Packed mod 16, Packed div 16);
        exit(V);
    end;

    // Scalar var-out write-back (Json WriteTo(var Text)): operand slot Idx carries the target
    // register (regIdx*16+class) live; write Value straight back into it (frame-local reg — the
    // lowerer emits a StoreToSym after the instruction to persist a global/var-param target).
    local procedure WriteTextArg(B: Integer; Idx: Integer; Value: Text)
    var
        Packed: Integer;
    begin
        Packed := OperArr[B + Idx];
        WriteRegisterFromVariant(Packed mod 16, Packed div 16, Value);
    end;

    // Same write-back for a value of any register class (Dictionary Get(key, var value)).
    local procedure WriteVariantArg(B: Integer; Idx: Integer; Value: Variant)
    var
        Packed: Integer;
    begin
        Packed := OperArr[B + Idx];
        WriteRegisterFromVariant(Packed mod 16, Packed div 16, Value);
    end;

    // ===== M10 Http* RefShim ops =====
    //
    // HTTP_METHOD: A = receiver handle reg (frame-relative Int reg, LIVE; ignored for "New"
    // ids), B = operand-pool start (each entry regIdx*16+class, read LIVE — TB_METHOD/
    // CALL_BUILTIN_LIVE convention), C = OutReg*100000 + OutCls*10000 + MethodId*100 +
    // ArgCount — same packing as TB_METHOD. MethodId ranges pick the receiver kind (see "ALI
    // Opcode" HTTP_METHOD header); "ALI Binder".HttpMethodId is the name/arity table.
    local procedure ExecHttpOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        TmpText: Text;
        ResultV: Variant;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;

        case MethodId of
            // ----- HttpClient (1 = New, 2-11) -----
            1:
                ResultV := HttpRt.NewClient();
            2: // Get(Text, var HttpResponseMessage) -> Boolean
                ResultV := HttpRt.ClientGet(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsInt(B, 1));
            3: // Post(Text, HttpContent, var HttpResponseMessage) -> Boolean
                ResultV := HttpRt.ClientPost(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            4: // Put(Text, HttpContent, var HttpResponseMessage) -> Boolean
                ResultV := HttpRt.ClientPut(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            5: // Delete(Text, var HttpResponseMessage) -> Boolean
                ResultV := HttpRt.ClientDelete(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsInt(B, 1));
            6: // Send(HttpRequestMessage, var HttpResponseMessage) -> Boolean
                ResultV := HttpRt.ClientSend(RegInt[CurBaseInt + A], ArgAsInt(B, 0), ArgAsInt(B, 1));
            7: // SetBaseAddress(Text)
                HttpRt.ClientSetBaseAddress(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            8: // Timeout() -> Duration
                ResultV := HttpRt.ClientGetTimeout(RegInt[CurBaseInt + A]);
            9: // Timeout(Duration)
                HttpRt.ClientSetTimeout(RegInt[CurBaseInt + A], ArgAsDuration(B, 0));
            10: // DefaultRequestHeaders() -> HttpHeaders (handle-returning)
                ResultV := HttpRt.ClientDefaultRequestHeaders(RegInt[CurBaseInt + A]);
            11: // Clear()
                HttpRt.ClientClear(RegInt[CurBaseInt + A]);

            // ----- HttpRequestMessage (20 = New, 21-27) -----
            20:
                ResultV := HttpRt.NewRequest();
            21: // Method() -> Text
                ResultV := HttpRt.RequestGetMethod(RegInt[CurBaseInt + A]);
            22: // Method(Text)
                HttpRt.RequestSetMethod(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            23: // SetRequestUri(Text)
                HttpRt.RequestSetRequestUri(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            24: // GetRequestUri() -> Text
                ResultV := HttpRt.RequestGetRequestUri(RegInt[CurBaseInt + A]);
            25: // Content() -> HttpContent (handle-returning)
                ResultV := HttpRt.RequestGetContent(RegInt[CurBaseInt + A]);
            26: // Content(HttpContent)
                HttpRt.RequestSetContent(RegInt[CurBaseInt + A], ArgAsInt(B, 0));
            27: // GetHeaders() -> HttpHeaders (handle-returning)
                ResultV := HttpRt.RequestGetHeaders(RegInt[CurBaseInt + A]);
            28: // GetHeaders(var HttpHeaders) — native shape, fills the arg handle in place
                HttpRt.RequestGetHeadersInto(RegInt[CurBaseInt + A], ArgAsInt(B, 0));

            // ----- HttpResponseMessage (40 = New, 41-46) -----
            40:
                ResultV := HttpRt.NewResponse();
            41: // HttpStatusCode() -> Integer
                ResultV := HttpRt.ResponseHttpStatusCode(RegInt[CurBaseInt + A]);
            42: // IsSuccessStatusCode() -> Boolean
                ResultV := HttpRt.ResponseIsSuccessStatusCode(RegInt[CurBaseInt + A]);
            43: // ReasonPhrase() -> Text
                ResultV := HttpRt.ResponseReasonPhrase(RegInt[CurBaseInt + A]);
            44: // IsBlockedByEnvironment() -> Boolean
                ResultV := HttpRt.ResponseIsBlockedByEnvironment(RegInt[CurBaseInt + A]);
            45: // Content() -> HttpContent (handle-returning)
                ResultV := HttpRt.ResponseContent(RegInt[CurBaseInt + A]);
            46: // Headers() -> HttpHeaders (handle-returning)
                ResultV := HttpRt.ResponseHeaders(RegInt[CurBaseInt + A]);

            // ----- HttpContent (60 = New, 61-64) -----
            60:
                ResultV := HttpRt.NewContent();
            61: // WriteFrom(Text)
                HttpRt.ContentWriteFrom(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            62: // ReadAs() -> Text (simplified v1 shape, see "ALI Http Runtime".ContentReadAs)
                ResultV := HttpRt.ContentReadAs(RegInt[CurBaseInt + A]);
            63: // GetHeaders() -> HttpHeaders (handle-returning)
                ResultV := HttpRt.ContentGetHeaders(RegInt[CurBaseInt + A]);
            64: // Clear()
                HttpRt.ContentClear(RegInt[CurBaseInt + A]);
            65: // ReadAs(var Text) -> Boolean — scalar var-out, write body back into the arg
                begin
                    ResultV := HttpRt.ContentReadAsInto(RegInt[CurBaseInt + A], TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            66: // GetHeaders(var HttpHeaders) -> Boolean — native shape, fills the arg handle in place
                ResultV := HttpRt.ContentGetHeadersInto(RegInt[CurBaseInt + A], ArgAsInt(B, 0));

            // ----- HttpHeaders (80 = New, 81-86) -----
            80:
                ResultV := HttpRt.NewHeaders();
            81: // Add(Text, Text)
                HttpRt.HeadersAdd(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsText(B, 1));
            82: // TryAddWithoutValidation(Text, Text) -> Boolean
                ResultV := HttpRt.HeadersTryAddWithoutValidation(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsText(B, 1));
            83: // Contains(Text) -> Boolean
                ResultV := HttpRt.HeadersContains(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            84: // Remove(Text) -> Boolean
                ResultV := HttpRt.HeadersRemove(RegInt[CurBaseInt + A], ArgAsText(B, 0));
            85: // Clear()
                HttpRt.HeadersClear(RegInt[CurBaseInt + A]);
            86: // GetValues(Text, var List of [Text]) -> Boolean — 2nd arg is a List handle
                ResultV := HttpRt.HeadersGetValues(RegInt[CurBaseInt + A], ArgAsText(B, 0), ArgAsInt(B, 1));
            else
                Error('ALI981: invalid Http method id %1 at PC %2', MethodId, PC);
        end;

        // Handle Lifecycle Unification (mirrors ARR_NEW/LIST_NEW): a "New" id (1/20/40/60/80)
        // allocated a LOCAL's own slot when ArgCount here is really the IsGlobal flag = 0 (see
        // "ALI Lowerer".EmitNewHttpForProc/Global); a handle-returning method (10/25/27/45/46/
        // 63) always allocates a fresh slot, tracked unconditionally. GLOBAL "New" allocations
        // are never tracked — freed only at Reset().
        case MethodId of
            1:
                if ArgCount = 0 then begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpClient, EvalInt);
                end;
            20:
                if ArgCount = 0 then begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpRequestMessage, EvalInt);
                end;
            40:
                if ArgCount = 0 then begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpResponseMessage, EvalInt);
                end;
            60:
                if ArgCount = 0 then begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpContent, EvalInt);
                end;
            80:
                if ArgCount = 0 then begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpHeaders, EvalInt);
                end;
            10, 27, 46:     // handle-returning -> HttpHeaders
                begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpHeaders, EvalInt);
                end;
            25, 45, 63:     // handle-returning -> HttpContent
                begin
                    EvalInt := ResultV;
                    TrackLocalHandle("ALI TypeKind"::HttpContent, EvalInt);
                end;
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // ===== Feature 2 Json* RefShim ops =====
    //
    // JSON_METHOD: A = receiver handle reg (frame-relative Int reg, LIVE; ignored for "New"
    // ids), B = operand-pool start (regIdx*16+class per entry, read LIVE — HTTP_METHOD
    // convention), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount. MethodId ranges
    // pick the receiver kind (1-25 JsonObject, 26-50 JsonArray, 51-75 JsonToken, 76-99
    // JsonValue). Ids 1/26/51/76 ("New") pack IsGlobal into the low ArgCount slot. All 4 kinds
    // share ONE bank ("ALI Json Runtime"); handle-returning methods (As*/Clone/Keys) always
    // allocate a FRESH slot, tracked unconditionally. Var-out HANDLE args (Get/SelectToken)
    // rebind the caller's existing out-handle slot in place (no fresh allocation) — the Http
    // var-out mechanism. WriteTo(var Text) writes its serialized text back via WriteTextArg.
    local procedure ExecJsonOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        FreshH: Integer;
        HandleH: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        TmpText: Text;
        ResultV: Variant;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        // "New" ids (1/26/51/76) carry no receiver: A = 0 and CurBaseInt can be 0 too, so the
        // register read would index RegInt[0] (1-based) and throw. Read the handle only for
        // real method calls — mirrors ExecHttpOp, which reads the receiver inline per arm.
        if not (MethodId in [1, 26, 51, 76]) then
            HandleH := RegInt[CurBaseInt + A];

        case MethodId of
            // ----- JsonObject (1 = New, 2-18) -----
            1:
                ResultV := JsonRt.NewObject();
            2:  // Add(Text, Text)
                JsonRt.ObjAddText(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            3:  // Add(Text, Integer)
                JsonRt.ObjAddInt(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            4:  // Add(Text, Decimal)
                JsonRt.ObjAddDec(HandleH, ArgAsText(B, 0), ArgAsDec(B, 1));
            5:  // Add(Text, Boolean)
                JsonRt.ObjAddBool(HandleH, ArgAsText(B, 0), ArgAsBool(B, 1));
            6, 7, 8:  // Add(Text, JsonToken/JsonObject/JsonArray) — value is a Json handle
                JsonRt.ObjAddToken(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            9:  // Contains(Text) -> Bool
                ResultV := JsonRt.ObjContains(HandleH, ArgAsText(B, 0));
            10: // Get(Text, var JsonToken) -> Bool
                ResultV := JsonRt.ObjGet(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            11: // Remove(Text) -> Bool
                ResultV := JsonRt.ObjRemove(HandleH, ArgAsText(B, 0));
            12: // Replace(Text, JsonToken) -> Bool
                ResultV := JsonRt.ObjReplace(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            13: // WriteTo(var Text) -> Bool
                begin
                    ResultV := JsonRt.ObjWriteTo(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            14: // ReadFrom(Text) -> Bool
                ResultV := JsonRt.ObjReadFrom(HandleH, ArgAsText(B, 0));
            15: // Keys() -> List of [Text] (fresh List handle)
                ResultV := JsonRt.ObjKeys(HandleH);
            16: // Count() -> Integer
                ResultV := JsonRt.ObjCount(HandleH);
            17: // AsToken() -> JsonToken (fresh)
                ResultV := JsonRt.ObjAsToken(HandleH);
            18: // Clone() -> JsonObject (fresh)
                ResultV := JsonRt.ObjClone(HandleH);
            19: // Add(Text, Date)
                JsonRt.ObjAddDate(HandleH, ArgAsText(B, 0), ArgAsDate(B, 1));
            20: // Add(Text, Time)
                JsonRt.ObjAddTime(HandleH, ArgAsText(B, 0), ArgAsTime(B, 1));
            21: // Add(Text, DateTime)
                JsonRt.ObjAddDateTime(HandleH, ArgAsText(B, 0), ArgAsDateTime(B, 1));
            22: // Add(Text, BigInteger)
                JsonRt.ObjAddBig(HandleH, ArgAsText(B, 0), ArgAsBig(B, 1));

            // ----- JsonArray (26 = New, 27-43) — native 0-based indexes -----
            26:
                ResultV := JsonRt.NewArray();
            27: // Add(Text)
                JsonRt.ArrAddText(HandleH, ArgAsText(B, 0));
            28: // Add(Integer)
                JsonRt.ArrAddInt(HandleH, ArgAsInt(B, 0));
            29: // Add(Decimal)
                JsonRt.ArrAddDec(HandleH, ArgAsDec(B, 0));
            30: // Add(Boolean)
                JsonRt.ArrAddBool(HandleH, ArgAsBool(B, 0));
            31, 32, 33:  // Add(JsonToken/JsonObject/JsonArray)
                JsonRt.ArrAddToken(HandleH, ArgAsInt(B, 0));
            34: // Get(Integer, var JsonToken) -> Bool
                ResultV := JsonRt.ArrGet(HandleH, ArgAsInt(B, 0), ArgAsInt(B, 1));
            35: // Set(Integer, JsonToken) -> Bool
                ResultV := JsonRt.ArrSet(HandleH, ArgAsInt(B, 0), ArgAsInt(B, 1));
            36: // Insert(Integer, JsonToken) -> Bool
                ResultV := JsonRt.ArrInsert(HandleH, ArgAsInt(B, 0), ArgAsInt(B, 1));
            37: // RemoveAt(Integer) -> Bool
                ResultV := JsonRt.ArrRemoveAt(HandleH, ArgAsInt(B, 0));
            38: // Count() -> Integer
                ResultV := JsonRt.ArrCount(HandleH);
            39: // IndexOf(JsonToken) -> Integer
                ResultV := JsonRt.ArrIndexOf(HandleH, ArgAsInt(B, 0));
            40: // WriteTo(var Text) -> Bool
                begin
                    ResultV := JsonRt.ArrWriteTo(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            41: // ReadFrom(Text) -> Bool
                ResultV := JsonRt.ArrReadFrom(HandleH, ArgAsText(B, 0));
            42: // AsToken() -> JsonToken (fresh)
                ResultV := JsonRt.ArrAsToken(HandleH);
            43: // Clone() -> JsonArray (fresh)
                ResultV := JsonRt.ArrClone(HandleH);
            44: // Add(Date)
                JsonRt.ArrAddDate(HandleH, ArgAsDate(B, 0));
            45: // Add(Time)
                JsonRt.ArrAddTime(HandleH, ArgAsTime(B, 0));
            46: // Add(DateTime)
                JsonRt.ArrAddDateTime(HandleH, ArgAsDateTime(B, 0));
            47: // Add(BigInteger)
                JsonRt.ArrAddBig(HandleH, ArgAsBig(B, 0));

            // ----- JsonToken (51 = New, 52-61) -----
            51:
                ResultV := JsonRt.NewTokenH();
            52: // ReadFrom(Text) -> Bool
                ResultV := JsonRt.TokReadFrom(HandleH, ArgAsText(B, 0));
            53: // WriteTo(var Text) -> Bool
                begin
                    ResultV := JsonRt.TokWriteTo(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            54: // IsObject() -> Bool
                ResultV := JsonRt.TokIsObject(HandleH);
            55: // IsArray() -> Bool
                ResultV := JsonRt.TokIsArray(HandleH);
            56: // IsValue() -> Bool
                ResultV := JsonRt.TokIsValue(HandleH);
            57: // AsObject() -> JsonObject (fresh)
                ResultV := JsonRt.TokAsObject(HandleH);
            58: // AsArray() -> JsonArray (fresh)
                ResultV := JsonRt.TokAsArray(HandleH);
            59: // AsValue() -> JsonValue (fresh)
                ResultV := JsonRt.TokAsValue(HandleH);
            60: // Clone() -> JsonToken (fresh)
                ResultV := JsonRt.TokClone(HandleH);
            61: // SelectToken(Text, var JsonToken) -> Bool
                ResultV := JsonRt.TokSelectToken(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));

            // ----- JsonValue (76 = New, 77-96) -----
            76:
                ResultV := JsonRt.NewValue();
            77: // SetValue(Text)
                JsonRt.ValSetText(HandleH, ArgAsText(B, 0));
            78: // SetValue(Integer)
                JsonRt.ValSetInt(HandleH, ArgAsInt(B, 0));
            79: // SetValue(Decimal)
                JsonRt.ValSetDec(HandleH, ArgAsDec(B, 0));
            80: // SetValue(Boolean)
                JsonRt.ValSetBool(HandleH, ArgAsBool(B, 0));
            81: // SetValue(Date)
                JsonRt.ValSetDate(HandleH, ArgAsDate(B, 0));
            82: // SetValue(Time)
                JsonRt.ValSetTime(HandleH, ArgAsTime(B, 0));
            83: // SetValue(DateTime)
                JsonRt.ValSetDateTime(HandleH, ArgAsDateTime(B, 0));
            84: // AsText() -> Text
                ResultV := JsonRt.ValAsText(HandleH);
            85: // AsCode() -> Code (STORE_TEXT_CHK uppercases at the assignment site)
                ResultV := JsonRt.ValAsText(HandleH);
            86: // AsInteger() -> Integer
                ResultV := JsonRt.ValAsInteger(HandleH);
            87: // AsDecimal() -> Decimal
                ResultV := JsonRt.ValAsDecimal(HandleH);
            88: // AsBoolean() -> Boolean
                ResultV := JsonRt.ValAsBoolean(HandleH);
            89: // AsDate() -> Date
                ResultV := JsonRt.ValAsDate(HandleH);
            90: // AsTime() -> Time
                ResultV := JsonRt.ValAsTime(HandleH);
            91: // AsDateTime() -> DateTime
                ResultV := JsonRt.ValAsDateTime(HandleH);
            92: // IsNull() -> Boolean
                ResultV := JsonRt.ValIsNull(HandleH);
            93: // AsToken() -> JsonToken (fresh)
                ResultV := JsonRt.ValAsToken(HandleH);
            94: // AsByte() -> Byte (Int register)
                ResultV := JsonRt.ValAsByte(HandleH);
            95: // AsChar() -> Char (Int register)
                ResultV := JsonRt.ValAsChar(HandleH);
            96: // AsOption() -> Option ordinal (Int register)
                ResultV := JsonRt.ValAsOption(HandleH);
            else
                Error('ALI996: invalid Json method id %1 at PC %2', MethodId, PC);
        end;

        // Handle Lifecycle Unification: LOCAL "New" (IsGlobal flag = ArgCount = 0) and EVERY
        // fresh handle-returning result (As*/Clone/Keys) are tracked for frame-pop reclaim.
        // Var-out handle methods (Get/SelectToken) are absent here — they rebind an existing
        // handle, never allocate. GLOBAL "New" is never tracked (freed only at Reset()).
        case MethodId of
            1:
                if ArgCount = 0 then begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonObject, FreshH);
                end;
            26:
                if ArgCount = 0 then begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonArray, FreshH);
                end;
            51:
                if ArgCount = 0 then begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonToken, FreshH);
                end;
            76:
                if ArgCount = 0 then begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonValue, FreshH);
                end;
            18, 57:     // fresh -> JsonObject (Clone / Token.AsObject)
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonObject, FreshH);
                end;
            43, 58:     // fresh -> JsonArray (Clone / Token.AsArray)
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonArray, FreshH);
                end;
            17, 42, 60, 93:     // fresh -> JsonToken (AsToken x3 / Token.Clone)
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonToken, FreshH);
                end;
            59:         // fresh -> JsonValue (Token.AsValue)
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::JsonValue, FreshH);
                end;
            15:         // Keys() -> fresh List handle (tracked as List kind)
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::List, FreshH);
                end;
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // JSON_METHOD2: typed GetX getters (GetText/GetInteger/.../GetObject/GetArray/GetValue
    // [, DefaultIfNotFound]). Same A/B/C packing as JSON_METHOD; the C MethodId field holds
    // ACTUAL id - 100 (packed 1-16 = JsonObject 101-116, packed 31-46 = JsonArray 131-146).
    // Offset order within each range: 0 Text, 1 Integer, 2 BigInteger, 3 Decimal, 4 Boolean,
    // 5 Date, 6 Time, 7 DateTime, 8 Duration, 9 Guid, 10 Object, 11 Array, 12 Value,
    // 13 Byte, 14 Char, 15 Option (Byte/Char/Option results are Int-register ordinals).
    // Handle-kind getters (offsets 10-12) allocate FRESH handles — tracked like As*/Clone.
    local procedure ExecJsonOp2(A: Integer; B: Integer; C: Integer)
    var
        DefaultIfNotFound: Boolean;
        ArgCount: Integer;
        FreshH: Integer;
        HandleH: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        ResultV: Variant;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        HandleH := RegInt[CurBaseInt + A];
        if ArgCount = 2 then
            DefaultIfNotFound := ArgAsBool(B, 1);

        case MethodId of
            // ----- JsonObject.GetX(Name [, DefaultIfNotFound]) — packed 1-13 -----
            1:
                ResultV := JsonRt.ObjGetText(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            2:
                ResultV := JsonRt.ObjGetInteger(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            3:
                ResultV := JsonRt.ObjGetBigInteger(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            4:
                ResultV := JsonRt.ObjGetDecimal(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            5:
                ResultV := JsonRt.ObjGetBoolean(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            6:
                ResultV := JsonRt.ObjGetDate(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            7:
                ResultV := JsonRt.ObjGetTime(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            8:
                ResultV := JsonRt.ObjGetDateTime(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            9:
                ResultV := JsonRt.ObjGetDuration(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            10:
                ResultV := JsonRt.ObjGetGuid(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            11: // GetObject -> fresh JsonObject handle
                begin
                    FreshH := JsonRt.ObjGetObject(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonObject, FreshH);
                    ResultV := FreshH;
                end;
            12: // GetArray -> fresh JsonArray handle
                begin
                    FreshH := JsonRt.ObjGetArray(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonArray, FreshH);
                    ResultV := FreshH;
                end;
            13: // GetValue -> fresh JsonValue handle
                begin
                    FreshH := JsonRt.ObjGetValue(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonValue, FreshH);
                    ResultV := FreshH;
                end;
            14:
                ResultV := JsonRt.ObjGetByte(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            15:
                ResultV := JsonRt.ObjGetChar(HandleH, ArgAsText(B, 0), DefaultIfNotFound);
            16:
                ResultV := JsonRt.ObjGetOption(HandleH, ArgAsText(B, 0), DefaultIfNotFound);

            // ----- JsonArray.GetX(Index [, DefaultIfNotFound]) — packed 31-43 -----
            31:
                ResultV := JsonRt.ArrGetText(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            32:
                ResultV := JsonRt.ArrGetInteger(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            33:
                ResultV := JsonRt.ArrGetBigInteger(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            34:
                ResultV := JsonRt.ArrGetDecimal(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            35:
                ResultV := JsonRt.ArrGetBoolean(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            36:
                ResultV := JsonRt.ArrGetDate(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            37:
                ResultV := JsonRt.ArrGetTime(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            38:
                ResultV := JsonRt.ArrGetDateTime(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            39:
                ResultV := JsonRt.ArrGetDuration(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            40:
                ResultV := JsonRt.ArrGetGuid(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            41: // GetObject -> fresh JsonObject handle
                begin
                    FreshH := JsonRt.ArrGetObject(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonObject, FreshH);
                    ResultV := FreshH;
                end;
            42: // GetArray -> fresh JsonArray handle
                begin
                    FreshH := JsonRt.ArrGetArray(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonArray, FreshH);
                    ResultV := FreshH;
                end;
            43: // GetValue -> fresh JsonValue handle
                begin
                    FreshH := JsonRt.ArrGetValue(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
                    TrackLocalHandle("ALI TypeKind"::JsonValue, FreshH);
                    ResultV := FreshH;
                end;
            44:
                ResultV := JsonRt.ArrGetByte(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            45:
                ResultV := JsonRt.ArrGetChar(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            46:
                ResultV := JsonRt.ArrGetOption(HandleH, ArgAsInt(B, 0), DefaultIfNotFound);
            else
                Error('ALI996: invalid Json method2 id %1 at PC %2', MethodId, PC);
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // ===== Feature 3 Xml* RefShim ops =====
    //
    // XML_METHOD: A = receiver handle reg (frame-relative Int reg, LIVE; NOT read for New ids
    // 1-16 and static ids 60-65 — a static's receiver is a type name, XML_DESIGN.md §4), B =
    // operand-pool start (regIdx*16+class entries; variadic content ids carry (reg, TypeOrd)
    // PAIRs after the fixed prefix — §6), C = OutReg*100000 + OutCls*10000 + MethodId*100 +
    // ArgCount. Method ids are SHARED across receiver kinds (unified NodeBank — §2 deviation
    // from Json); "ALI Binder".XmlMethodId is the (kind, name, arity) gate. New ids 1-16 pack
    // IsGlobal into the ArgCount slot (Json New convention). Fresh-handle results are tracked
    // for frame-pop reclaim; var-out HANDLE args rebind the caller's existing bank slot in
    // place (§7.2) — never tracked. WriteTo(var Text) writes back via WriteTextArg (§7.1);
    // stream overloads route through "ALI Stream Runtime".XmlWriteNode/XmlReadDoc (§7.3 — the
    // discrete native stream slots live there, AttachInFromRecordRef precedent).
    local procedure ExecXmlOp(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        FreshH: Integer;
        HandleH: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        TmpText: Text;
        ResultV: Variant;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100;
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        if not (MethodId in [1 .. 16, 60 .. 65]) then
            HandleH := RegInt[CurBaseInt + A];

        case MethodId of
            // ----- New allocators (id = TypeKind ordinal - 101; lowerer-emitted §3) -----
            1, 2, 3, 4, 7, 8, 9, 10, 11, 12:
                ResultV := XmlRt.NewNode();
            5:
                ResultV := XmlRt.NewNodeList();
            6:
                ResultV := XmlRt.NewAttrCol();
            13:
                ResultV := XmlRt.NewNsMgr();
            14:
                ResultV := XmlRt.NewReadOpt();
            15:
                ResultV := XmlRt.NewWriteOpt();
            16:
                ResultV := XmlRt.NewNameTable();
            // ----- shared node methods (20-36) -----
            20: // AddAfterSelf(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.NodeAddAfterSelf(HandleH);
                end;
            21: // AddBeforeSelf(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.NodeAddBeforeSelf(HandleH);
                end;
            22: // AsXmlNode() -> fresh XmlNode
                ResultV := XmlRt.NodeAsXmlNode(HandleH);
            23: // GetDocument(var XmlDocument) -> Bool
                ResultV := XmlRt.NodeGetDocument(HandleH, ArgAsInt(B, 0));
            24: // GetParent(var XmlElement) -> Bool
                ResultV := XmlRt.NodeGetParent(HandleH, ArgAsInt(B, 0));
            25: // Remove()
                XmlRt.NodeRemove(HandleH);
            26: // ReplaceWith(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.NodeReplaceWith(HandleH);
                end;
            27: // SelectNodes(Text, var XmlNodeList) -> Bool
                ResultV := XmlRt.NodeSelectNodes(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            28: // SelectNodes(Text, XmlNamespaceManager, var XmlNodeList) -> Bool
                ResultV := XmlRt.NodeSelectNodesNs(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            29: // SelectSingleNode(Text, var XmlNode) -> Bool
                ResultV := XmlRt.NodeSelectSingle(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            30: // SelectSingleNode(Text, XmlNamespaceManager, var XmlNode) -> Bool
                ResultV := XmlRt.NodeSelectSingleNs(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            31: // WriteTo(var Text) -> Bool
                begin
                    ResultV := XmlRt.NodeWriteToText(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            32: // WriteTo(XmlWriteOptions, var Text) -> Bool
                begin
                    ResultV := XmlRt.NodeWriteToTextOpt(HandleH, ArgAsInt(B, 0), TmpText);
                    WriteTextArg(B, 1, TmpText);
                end;
            33: // WriteTo(OutStream) -> Bool (§7.3 stream bridge)
                ResultV := StrmRt.XmlWriteNode(ArgAsInt(B, 0), HandleH, 0, false);
            34: // WriteTo(XmlWriteOptions, OutStream) -> Bool
                ResultV := StrmRt.XmlWriteNode(ArgAsInt(B, 1), HandleH, ArgAsInt(B, 0), true);
            35: // Value() -> Text (runtime dispatches on actual node kind)
                ResultV := XmlRt.NodeValueGet(HandleH);
            36: // Value(Text)
                XmlRt.NodeValueSet(HandleH, ArgAsText(B, 0));
            // ----- container methods (40-51; XmlDocument/XmlElement receiver) -----
            40: // Add(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.ContAdd(HandleH);
                end;
            41: // AddFirst(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.ContAddFirst(HandleH);
                end;
            42:
                ResultV := XmlRt.ContChildElements(HandleH);
            43:
                ResultV := XmlRt.ContChildElementsName(HandleH, ArgAsText(B, 0));
            44: // GetChildElements(namespaceUri, localName)
                ResultV := XmlRt.ContChildElementsNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            45:
                ResultV := XmlRt.ContChildNodes(HandleH);
            46:
                ResultV := XmlRt.ContDescendantElements(HandleH);
            47:
                ResultV := XmlRt.ContDescendantElementsName(HandleH, ArgAsText(B, 0));
            48:
                ResultV := XmlRt.ContDescendantElementsNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            49:
                ResultV := XmlRt.ContDescendantNodes(HandleH);
            50: // RemoveNodes()
                XmlRt.ContRemoveNodes(HandleH);
            51: // ReplaceNodes(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    XmlRt.ContReplaceNodes(HandleH);
                end;
            // ----- XmlDocument instance (55-59) + statics (60-65, A not read) -----
            55:
                ResultV := XmlRt.DocGetDeclaration(HandleH, ArgAsInt(B, 0));
            56:
                ResultV := XmlRt.DocGetDocumentType(HandleH, ArgAsInt(B, 0));
            57:
                ResultV := XmlRt.DocGetRoot(HandleH, ArgAsInt(B, 0));
            58: // NameTable() -> fresh XmlNameTable
                ResultV := XmlRt.DocNameTable(HandleH);
            59:
                XmlRt.DocSetDeclaration(HandleH, ArgAsInt(B, 0));
            60: // XmlDocument.Create()
                ResultV := XmlRt.DocCreate();
            61: // XmlDocument.Create(Any,...)
                begin
                    XmlLoadContent(B, ArgCount, 0);
                    ResultV := XmlRt.DocCreateWithContent();
                end;
            62: // ReadFrom(Text, var XmlDocument) -> Bool
                ResultV := XmlRt.DocReadFromText(ArgAsText(B, 0), ArgAsInt(B, 1));
            63: // ReadFrom(Text, XmlReadOptions, var XmlDocument) -> Bool
                ResultV := XmlRt.DocReadFromTextOpt(ArgAsText(B, 0), ArgAsInt(B, 1), ArgAsInt(B, 2));
            64: // ReadFrom(InStream, var XmlDocument) -> Bool (§7.3 stream bridge)
                ResultV := StrmRt.XmlReadDoc(ArgAsInt(B, 0), 0, false, ArgAsInt(B, 1));
            65: // ReadFrom(InStream, XmlReadOptions, var XmlDocument) -> Bool
                ResultV := StrmRt.XmlReadDoc(ArgAsInt(B, 0), ArgAsInt(B, 1), true, ArgAsInt(B, 2));
            // ----- XmlNode As* (68-76, fresh handle) / Is* (77-85) -----
            68 .. 76:
                ResultV := XmlRt.NodeAsKind(HandleH, XmlAsTargetOrd(MethodId));
            77:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlAttribute.AsInteger());
            78:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlCData.AsInteger());
            79:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlComment.AsInteger());
            80:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlDeclaration.AsInteger());
            81:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlDocument.AsInteger());
            82:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlDocumentType.AsInteger());
            83:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlElement.AsInteger());
            84:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlProcessingInstruction.AsInteger());
            85:
                ResultV := XmlRt.NodeIsKind(HandleH, "ALI TypeKind"::XmlText.AsInteger());
            // ----- name/content getters (90-98; 90-92 element AND attribute) -----
            90:
                ResultV := XmlRt.NodeLocalName(HandleH);
            91:
                ResultV := XmlRt.NodeName(HandleH);
            92:
                ResultV := XmlRt.NodeNamespaceUri(HandleH);
            93:
                ResultV := XmlRt.ElemInnerText(HandleH);
            94:
                ResultV := XmlRt.ElemInnerXml(HandleH);
            95:
                ResultV := XmlRt.ElemHasAttributes(HandleH);
            96:
                ResultV := XmlRt.ElemHasElements(HandleH);
            97:
                ResultV := XmlRt.ElemIsEmpty(HandleH);
            98: // Attributes() -> fresh XmlAttributeCollection
                ResultV := XmlRt.ElemAttributes(HandleH);
            else
                Error('ALI996: invalid Xml method id %1 at PC %2', MethodId, PC);
        end;

        // Handle Lifecycle Unification: LOCAL New (IsGlobal flag = ArgCount slot = 0) and every
        // fresh handle-returning result is tracked for frame-pop reclaim. Var-out handle args
        // (GetParent/SelectNodes/ReadFrom/...) rebind existing slots — absent here. GLOBAL New
        // is never tracked (freed only at Reset()).
        case MethodId of
            1 .. 16:    // New — id + 101 = the allocated TypeKind ordinal (§3)
                if ArgCount = 0 then begin
                    FreshH := ResultV;
                    TrackLocalHandle(MethodId + 101, FreshH);
                end;
            22:         // AsXmlNode -> fresh XmlNode
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlNode.AsInteger(), FreshH);
                end;
            42, 43, 44, 45, 46, 47, 48, 49:     // child/descendant lists -> fresh XmlNodeList
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlNodeList.AsInteger(), FreshH);
                end;
            58:         // NameTable() -> fresh XmlNameTable
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlNameTable.AsInteger(), FreshH);
                end;
            60, 61:     // XmlDocument.Create -> fresh XmlDocument
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlDocument.AsInteger(), FreshH);
                end;
            68 .. 76:   // As* -> fresh handle of the target kind
                begin
                    FreshH := ResultV;
                    TrackLocalHandle(XmlAsTargetOrd(MethodId), FreshH);
                end;
            98:         // Attributes() -> fresh XmlAttributeCollection
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlAttributeCollection.AsInteger(), FreshH);
                end;
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // XML_METHOD2: Xml method ids 101-199 (C's MethodId field carries ACTUAL id - 100 — same
    // rebase as JSON_METHOD2). Same A/B/C packing and conventions as ExecXmlOp; static ids
    // (101-104, 116-118, 140-148) never read the receiver register.
    local procedure ExecXmlOp2(A: Integer; B: Integer; C: Integer)
    var
        ArgCount: Integer;
        FreshH: Integer;
        HandleH: Integer;
        MethodId: Integer;
        OutCls: Integer;
        OutReg: Integer;
        TmpText: Text;
        ResultV: Variant;
    begin
        ArgCount := C mod 100;
        MethodId := (C div 100) mod 100 + 100;      // ACTUAL id (packed + 100)
        OutCls := (C div 10000) mod 10;
        OutReg := C div 100000;
        if not (MethodId in [101 .. 104, 116 .. 118, 140 .. 148]) then
            HandleH := RegInt[CurBaseInt + A];

        case MethodId of
            // ----- XmlElement statics (101-104, A not read) -----
            101: // Create(Text)
                ResultV := XmlRt.ElemCreate(ArgAsText(B, 0));
            102: // Create(Text, Text) — (localName, namespaceUri)
                ResultV := XmlRt.ElemCreateNs(ArgAsText(B, 0), ArgAsText(B, 1));
            103: // Create(Text, Text, Any,...) — 2 fixed args + content (§6)
                begin
                    XmlLoadContent(B, ArgCount, 2);
                    ResultV := XmlRt.ElemCreateNs(ArgAsText(B, 0), ArgAsText(B, 1));
                end;
            104: // Create(Text, Any,...) — 1 fixed arg + content
                begin
                    XmlLoadContent(B, ArgCount, 1);
                    ResultV := XmlRt.ElemCreate(ArgAsText(B, 0));
                end;
            // ----- XmlElement instance (106-113) -----
            106: // GetNamespaceOfPrefix(Text, var Text) -> Bool
                begin
                    ResultV := XmlRt.ElemGetNsOfPrefix(HandleH, ArgAsText(B, 0), TmpText);
                    WriteTextArg(B, 1, TmpText);
                end;
            107: // GetPrefixOfNamespace(Text, var Text) -> Bool
                begin
                    ResultV := XmlRt.ElemGetPrefixOfNs(HandleH, ArgAsText(B, 0), TmpText);
                    WriteTextArg(B, 1, TmpText);
                end;
            108:
                XmlRt.ElemRemoveAllAttributes(HandleH);
            109:
                XmlRt.ElemRemoveAttribute(HandleH, ArgAsText(B, 0));
            110: // RemoveAttribute(localName, namespaceUri)
                XmlRt.ElemRemoveAttributeNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            111: // RemoveAttribute(XmlAttribute)
                XmlRt.ElemRemoveAttributeByAttr(HandleH, ArgAsInt(B, 0));
            112: // SetAttribute(name, value)
                XmlRt.ElemSetAttribute(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            113: // SetAttribute(name, namespaceUri, value)
                XmlRt.ElemSetAttributeNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2));
            // ----- XmlAttribute statics (116-118, A not read) + instance (119-120) -----
            116:
                ResultV := XmlRt.AttrCreate(ArgAsText(B, 0), ArgAsText(B, 1));
            117:
                ResultV := XmlRt.AttrCreateNs(ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2));
            118:
                ResultV := XmlRt.AttrCreateNsDecl(ArgAsText(B, 0), ArgAsText(B, 1));
            119:
                ResultV := XmlRt.AttrIsNsDeclaration(HandleH);
            120:
                ResultV := XmlRt.AttrNamespacePrefix(HandleH);
            // ----- XmlNodeList (123-124; native 1-BASED) -----
            123:
                ResultV := XmlRt.NodeListCount(HandleH);
            124: // Get(Integer, var XmlNode) -> Bool
                ResultV := XmlRt.NodeListGet(HandleH, ArgAsInt(B, 0), ArgAsInt(B, 1));
            // ----- XmlAttributeCollection (127-136; 1-based) -----
            127:
                ResultV := XmlRt.AttrColCount(HandleH);
            128:
                ResultV := XmlRt.AttrColGetIdx(HandleH, ArgAsInt(B, 0), ArgAsInt(B, 1));
            129:
                ResultV := XmlRt.AttrColGetName(HandleH, ArgAsText(B, 0), ArgAsInt(B, 1));
            130:
                ResultV := XmlRt.AttrColGetNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1), ArgAsInt(B, 2));
            131:
                XmlRt.AttrColRemoveAttr(HandleH, ArgAsInt(B, 0));
            132:
                XmlRt.AttrColRemoveName(HandleH, ArgAsText(B, 0));
            133:
                XmlRt.AttrColRemoveNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            134:
                XmlRt.AttrColRemoveAll(HandleH);
            135:
                XmlRt.AttrColSet(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            136:
                XmlRt.AttrColSetNs(HandleH, ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2));
            // ----- simple-node statics (140-148, A not read; fresh handles) -----
            140:
                ResultV := XmlRt.CommentCreate(ArgAsText(B, 0));
            141:
                ResultV := XmlRt.CDataCreate(ArgAsText(B, 0));
            142:
                ResultV := XmlRt.TextCreate(ArgAsText(B, 0));
            143: // XmlProcessingInstruction.Create(target, data)
                ResultV := XmlRt.PICreate(ArgAsText(B, 0), ArgAsText(B, 1));
            144: // XmlDeclaration.Create(version, encoding, standalone)
                ResultV := XmlRt.DeclCreate(ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2));
            145:
                ResultV := XmlRt.DocTypeCreate1(ArgAsText(B, 0));
            146:
                ResultV := XmlRt.DocTypeCreate2(ArgAsText(B, 0), ArgAsText(B, 1));
            147:
                ResultV := XmlRt.DocTypeCreate3(ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2));
            148:
                ResultV := XmlRt.DocTypeCreate4(ArgAsText(B, 0), ArgAsText(B, 1), ArgAsText(B, 2), ArgAsText(B, 3));
            // ----- XmlDeclaration properties (150-155) -----
            150:
                ResultV := XmlRt.DeclEncodingGet(HandleH);
            151:
                XmlRt.DeclEncodingSet(HandleH, ArgAsText(B, 0));
            152:
                ResultV := XmlRt.DeclStandaloneGet(HandleH);
            153:
                XmlRt.DeclStandaloneSet(HandleH, ArgAsText(B, 0));
            154:
                ResultV := XmlRt.DeclVersionGet(HandleH);
            155:
                XmlRt.DeclVersionSet(HandleH, ArgAsText(B, 0));
            // ----- XmlDocumentType getters (158-161, var Text §7.1) / setters (162-165) -----
            158:
                begin
                    ResultV := XmlRt.DocTypeGetInternalSubset(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            159:
                begin
                    ResultV := XmlRt.DocTypeGetName(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            160:
                begin
                    ResultV := XmlRt.DocTypeGetPublicId(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            161:
                begin
                    ResultV := XmlRt.DocTypeGetSystemId(HandleH, TmpText);
                    WriteTextArg(B, 0, TmpText);
                end;
            162:
                XmlRt.DocTypeSetInternalSubset(HandleH, ArgAsText(B, 0));
            163:
                XmlRt.DocTypeSetName(HandleH, ArgAsText(B, 0));
            164:
                XmlRt.DocTypeSetPublicId(HandleH, ArgAsText(B, 0));
            165:
                XmlRt.DocTypeSetSystemId(HandleH, ArgAsText(B, 0));
            // ----- XmlProcessingInstruction (168) -----
            168:
                ResultV := XmlRt.PITargetGet(HandleH);
            // ----- XmlNamespaceManager (171-179) -----
            171:
                XmlRt.NsMgrAddNamespace(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            172:
                ResultV := XmlRt.NsMgrHasNamespace(HandleH, ArgAsText(B, 0));
            173: // LookupNamespace(Text, var Text) -> Bool
                begin
                    ResultV := XmlRt.NsMgrLookupNamespace(HandleH, ArgAsText(B, 0), TmpText);
                    WriteTextArg(B, 1, TmpText);
                end;
            174: // LookupPrefix(Text, var Text) -> Bool
                begin
                    ResultV := XmlRt.NsMgrLookupPrefix(HandleH, ArgAsText(B, 0), TmpText);
                    WriteTextArg(B, 1, TmpText);
                end;
            175: // NameTable() -> fresh XmlNameTable
                ResultV := XmlRt.NsMgrNameTableGet(HandleH);
            176:
                XmlRt.NsMgrNameTableSet(HandleH, ArgAsInt(B, 0));
            177:
                ResultV := XmlRt.NsMgrPopScope(HandleH);
            178:
                XmlRt.NsMgrPushScope(HandleH);
            179:
                ResultV := XmlRt.NsMgrRemoveNamespace(HandleH, ArgAsText(B, 0), ArgAsText(B, 1));
            // ----- Xml{Read,Write}Options (182-185) -----
            182:
                ResultV := XmlRt.ReadOptPreserveWsGet(HandleH);
            183:
                XmlRt.ReadOptPreserveWsSet(HandleH, ArgAsBool(B, 0));
            184:
                ResultV := XmlRt.WriteOptPreserveWsGet(HandleH);
            185:
                XmlRt.WriteOptPreserveWsSet(HandleH, ArgAsBool(B, 0));
            else
                Error('ALI996: invalid Xml method2 id %1 at PC %2', MethodId, PC);
        end;

        // Fresh-handle tracking (same rules as ExecXmlOp).
        case MethodId of
            101 .. 104:     // XmlElement.Create
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlElement.AsInteger(), FreshH);
                end;
            116 .. 118:     // XmlAttribute.Create / CreateNamespaceDeclaration
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlAttribute.AsInteger(), FreshH);
                end;
            140:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlComment.AsInteger(), FreshH);
                end;
            141:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlCData.AsInteger(), FreshH);
                end;
            142:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlText.AsInteger(), FreshH);
                end;
            143:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlProcessingInstruction.AsInteger(), FreshH);
                end;
            144:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlDeclaration.AsInteger(), FreshH);
                end;
            145 .. 148:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlDocumentType.AsInteger(), FreshH);
                end;
            175:
                begin
                    FreshH := ResultV;
                    TrackLocalHandle("ALI TypeKind"::XmlNameTable.AsInteger(), FreshH);
                end;
        end;

        if OutReg > 0 then
            WriteRegisterFromVariant(OutCls, OutReg, ResultV);
    end;

    // Target TypeKind ordinal of an XmlNode As* conversion id (68-76, XML_DESIGN.md §3).
    local procedure XmlAsTargetOrd(MethodId: Integer): Integer
    begin
        case MethodId of
            68:
                exit("ALI TypeKind"::XmlAttribute.AsInteger());
            69:
                exit("ALI TypeKind"::XmlCData.AsInteger());
            70:
                exit("ALI TypeKind"::XmlComment.AsInteger());
            71:
                exit("ALI TypeKind"::XmlDeclaration.AsInteger());
            72:
                exit("ALI TypeKind"::XmlDocument.AsInteger());
            73:
                exit("ALI TypeKind"::XmlDocumentType.AsInteger());
            74:
                exit("ALI TypeKind"::XmlElement.AsInteger());
            75:
                exit("ALI TypeKind"::XmlProcessingInstruction.AsInteger());
            76:
                exit("ALI TypeKind"::XmlText.AsInteger());
        end;
    end;

    // Walk a variadic content tail (§6): the pool holds FixedN single entries then one
    // (regIdx*16+class, TypeOrd) PAIR per content arg. Text-family content wraps into an
    // XmlText (ContentAddText); every other legal TypeOrd is a node kind whose Int reg holds
    // a NodeBank handle (ContentAddNode). The consuming runtime call drains the buffer.
    local procedure XmlLoadContent(B: Integer; ArgCount: Integer; FixedN: Integer)
    var
        ContentOrd: Integer;
        i: Integer;
        Idx: Integer;
    begin
        XmlRt.ContentBegin();
        for i := 1 to ArgCount - FixedN do begin
            Idx := FixedN + 2 * (i - 1);
            ContentOrd := OperArr[B + Idx + 1];
            if (ContentOrd = "ALI TypeKind"::Text.AsInteger()) or (ContentOrd = "ALI TypeKind"::Code.AsInteger()) or
               (ContentOrd = "ALI TypeKind"::Label.AsInteger()) then
                XmlRt.ContentAddText(ArgAsText(B, Idx))
            else
                XmlRt.ContentAddNode(ArgAsInt(B, Idx));
        end;
    end;

    local procedure CopyPendingToResult(var ExecResult: Codeunit "ALI Exec Result")
    var
        i: Integer;
    begin
        for i := 1 to PendingMessages.Count() do
            ExecResult.AddCollectedMessage(PendingMessages.Get(i));
        for i := 1 to PendingWarnings.Count() do
            ExecResult.AddRuntimeWarning(PendingWarnings.Get(i));
        // A global record prologue should execute exactly once per run. Any re-entry is now
        // harmless for the record bank (ExecRecNew hands back the slot that PC already owns),
        // but it still means control reached module-global initialisation a second time, which
        // is a real question about the lowered code — so say so instead of hiding it.
        if GlobalRecReopens > 0 then
            ExecResult.AddRuntimeWarning(StrSubstNo('ALI956: module-global record initialisation ran again %1 time(s) after the first pass — the slots were reused, not re-allocated', GlobalRecReopens));
    end;

    // UNBOX_REC: copy the record whose handle is boxed in variant register VarReg into the
    // destination record handle DestHandle (reference-semantics unbox, §19.2). The boxed value
    // is a bare Int handle; the assignment auto-unboxes the Variant to Integer.
    local procedure ExecUnboxRec(DestHandle: Integer; VarReg: Integer)
    var
        SrcHandle: Integer;
    begin
        SrcHandle := RegVariant[CurBaseVar + VarReg];
        RecRt.CopyRec(DestHandle, SrcHandle);
    end;

    // §19.2 Variant type-detection method names are now classified once at registry build time
    // (see "ALI Builtin Registry".ClassifyKinds / BKind) — the per-call name chain is gone.

    // Answer a Variant type-detection predicate. Handle/reference types (Record/List/Dictionary/
    // Array) are boxed as a bare Int handle, so the native Variant reports them as Integer — the
    // TAG disambiguates. Aggregate tests check the tag; scalar tests require tag = 0 (a genuine
    // native scalar) AND the native predicate, so `boxedList.IsInteger()` is correctly false.
    local procedure ExecVariantTest(UpperName: Text; V: Variant; Tag: Integer): Boolean
    begin
        case UpperName of
            'ISRECORD':
                exit(Tag = "ALI TypeKind"::Record);
            'ISLIST':
                exit(Tag = "ALI TypeKind"::List);
            'ISDICTIONARY':
                exit(Tag = "ALI TypeKind"::Dictionary);
            'ISARRAY':
                exit(Tag = "ALI TypeKind"::Array);
        end;
        if Tag <> 0 then
            exit(false);        // a boxed handle/reference is never a scalar
        case UpperName of
            'ISINTEGER':
                exit(V.IsInteger());
            'ISBIGINTEGER':
                exit(V.IsBigInteger());
            'ISDECIMAL':
                exit(V.IsDecimal());
            'ISBOOLEAN':
                exit(V.IsBoolean());
            'ISTEXT':
                exit(V.IsText());
            'ISCODE':
                exit(V.IsCode());
            'ISCHAR':
                exit(V.IsChar());
            'ISBYTE':
                exit(V.IsByte());
            'ISDATE':
                exit(V.IsDate());
            'ISTIME':
                exit(V.IsTime());
            'ISDATETIME':
                exit(V.IsDateTime());
            'ISDURATION':
                exit(V.IsDuration());
            'ISGUID':
                exit(V.IsGuid());
            'ISOPTION':
                exit(V.IsOption());
            'ISDATEFORMULA':
                exit(V.IsDateFormula());
            'ISRECORDID':
                exit(V.IsRecordId());
        end;
    end;

    // Text.Split(sep1[, sep2]) — reuses the native AL Text.Split to do the actual splitting,
    // then copies the parts into a fresh List-runtime handle (Text element class). Returns the
    // Int handle, stored back into the caller's Int register (List values are Int handles).
    local procedure ExecTextSplit(var Args: array[16] of Variant; ArgCount: Integer): Integer
    var
        Handle: Integer;
        Parts: List of [Text];
        Part: Text;
        Recv: Text;
    begin
        Recv := Format(Args[1]);
        case ArgCount of
            2:
                Parts := Recv.Split(Format(Args[2]));
            3:
                Parts := Recv.Split(Format(Args[2]), Format(Args[3]));
            else
                Error('ALI951: Split expects 1 or 2 separators at PC %1', PC);
        end;
        Handle := ListRt.NewList(TypeRules_RegClassText());
        foreach Part in Parts do
            ListRt.Add(Handle, Part);
        exit(Handle);
    end;

    // EVALUATE_TARGET: A = target slot, B = operand-pool start (text[+fmt] args), C =
    // OutBoolReg*100000 + TargetTypeOrd*1000 + IsGlobal*100 + ArgCount. Writes directly into
    // the target's OWN typed register (native Evaluate semantics — success/failure only
    // affects the value on success, matching native "target left unchanged on failure").
    // OutBoolReg (0 = discard, e.g. Clear or a statement-context call that ignores the
    // result) also gets the success flag, so Evaluate can be used in expression context
    // (§19.8: `exit(Evaluate(...))`).
    local procedure ExecEvaluateTarget(A: Integer; B: Integer; C: Integer)
    var
        OkDF: DateFormula;
        OkRecId: RecordId;
        OkBig: BigInteger;
        OkBool: Boolean;
        Success: Boolean;
        OkDate: Date;
        OkDT: DateTime;
        OkDec: Decimal;
        ArgCount: Integer;
        IsGlobal: Integer;
        OkInt: Integer;
        OutBoolReg: Integer;
        TargetAbs: Integer;
        TargetT: Integer;
        SourceText: Text;
        OkTime: Time;
    begin
        // Mirrors LowerTargetingBuiltin's C := OutReg*100000 + TargetT*1000 + IsGlobal*100 + ArgCount.
        OutBoolReg := C div 100000;
        TargetT := (C mod 100000) div 1000;
        IsGlobal := (C mod 1000) div 100;
        ArgCount := C mod 100;
        if ArgCount >= 1 then
            SourceText := Format(ReadRegisterAsVariant(TypeRules_RegClassText(), RelOrAbsOperandReg(B, 0, IsGlobal)));

        if IsGlobal = 1 then
            TargetAbs := A
        else
            TargetAbs := CurBaseOf(RegClassForTypeOrd(TargetT)) + A;

        case TargetT of
            10: // Integer
                begin
                    Success := BSystem.TryEvaluateInt(SourceText, OkInt);
                    if Success then
                        RegInt[TargetAbs] := OkInt;
                end;
            11: // BigInteger
                begin
                    Success := BSystem.TryEvaluateBig(SourceText, OkBig);
                    if Success then
                        RegBig[TargetAbs] := OkBig;
                end;
            12: // Decimal
                begin
                    Success := BSystem.TryEvaluateDec(SourceText, OkDec);
                    if Success then
                        RegDec[TargetAbs] := OkDec;
                end;
            20: // Boolean
                begin
                    Success := BSystem.TryEvaluateBool(SourceText, OkBool);
                    if Success then
                        RegBool[TargetAbs] := OkBool;
                end;
            30, 31, 32: // Text/Code/Label — Evaluate on Text is just an assign
                begin
                    RegText[TargetAbs] := SourceText;
                    Success := true;
                end;
            50: // Date
                begin
                    Success := BSystem.TryEvaluateDate(SourceText, OkDate);
                    if Success then
                        RegDate[TargetAbs] := OkDate;
                end;
            51: // Time
                begin
                    Success := BSystem.TryEvaluateTime(SourceText, OkTime);
                    if Success then
                        RegTime[TargetAbs] := OkTime;
                end;
            52: // DateTime
                begin
                    Success := BSystem.TryEvaluateDateTime(SourceText, OkDT);
                    if Success then
                        RegDT[TargetAbs] := OkDT;
                end;
            91: // RecordID
                begin
                    Success := BSystem.TryEvaluateRecordId(SourceText, OkRecId);
                    if Success then
                        RegRecordId[TargetAbs] := OkRecId;
                end;
            54: // DateFormula
                begin
                    Success := BSystem.TryEvaluateDateFormula(SourceText, OkDF);
                    if Success then
                        RegDateFormula[TargetAbs] := OkDF;
                end;
        end;

        if OutBoolReg > 0 then
            RegBool[CurBaseBool + OutBoolReg] := Success;
    end;

    // CLEAR_TARGET: A = target slot, B = TargetTypeOrd, C = IsGlobal (C mod 4: 0 frame-local,
    // 1 absolute global, 2 object global of the running instance, 3 object global of instance
    // C div 4 — Clear(MyCU), see "ALI Lowerer".EmitClearInstance). Resets the target to
    // its type's default value (native Clear semantics). Handle-kind types (Record/List/
    // Dict/Array/TextBuilder/Http*/Json*) live in Int registers holding a HANDLE — the arm
    // dereferences RegInt[TargetAbs] and clears the handle's CONTENT in place (the handle
    // itself stays live and bound to the variable; zeroing the register would detach it).
    local procedure ExecClearTarget(A: Integer; B: Integer; C: Integer)
    var
        TargetAbs: Integer;
    begin
        case C mod 4 of
            1:
                TargetAbs := A;
            2:  // M11 phase B2: an object global — A is an offset in the current instance's block
                TargetAbs := InstBaseArr[CurInstRow + RegClassForTypeOrd(B)] + A;
            3:  // an object global of an explicit instance (C div 4), not the running one
                TargetAbs := InstBaseArr[(C div 4 - 1) * 13 + RegClassForTypeOrd(B)] + A;
            else
                TargetAbs := CurBaseOf(RegClassForTypeOrd(B)) + A;
        end;

        case B of
            "ALI TypeKind"::Integer,
            "ALI TypeKind"::Char,
            "ALI TypeKind"::Byte,
            "ALI TypeKind"::Option,
            "ALI TypeKind"::Enum:
                Clear(RegInt[TargetAbs]);         // Integer/Char/Byte/Option/Enum
            "ALI TypeKind"::BigInteger:
                Clear(RegBig[TargetAbs]);
            "ALI TypeKind"::Decimal:
                Clear(RegDec[TargetAbs]);
            "ALI TypeKind"::Boolean:
                Clear(RegBool[TargetAbs]);
            "ALI TypeKind"::Text,
            "ALI TypeKind"::Code,
            "ALI TypeKind"::Label,
            "ALI TypeKind"::SecretText:       // value lives in the Text register file
                Clear(RegText[TargetAbs]);
            "ALI TypeKind"::Date:
                Clear(RegDate[TargetAbs]);
            "ALI TypeKind"::Time:
                Clear(RegTime[TargetAbs]);
            "ALI TypeKind"::DateTime:
                Clear(RegDT[TargetAbs]);
            "ALI TypeKind"::Duration:
                Clear(RegDur[TargetAbs]);
            "ALI TypeKind"::Guid:
                Clear(RegGuid[TargetAbs]);
            "ALI TypeKind"::Variant:
                begin
                    Clear(RegVariant[TargetAbs]);
                    RegVarTag[TargetAbs] := 0;
                end;
            "ALI TypeKind"::DateFormula:
                Clear(RegDateFormula[TargetAbs]);
            "ALI TypeKind"::Array:
                ArrayRt.ClearArray(RegInt[TargetAbs]);
            "ALI TypeKind"::List:
                ListRt.ClearList(RegInt[TargetAbs]);
            "ALI TypeKind"::Dictionary:
                DictRt.ClearDict(RegInt[TargetAbs]);
            "ALI TypeKind"::RecordID:
                Clear(RegRecordId[TargetAbs]);
            "ALI TypeKind"::Record:
                // Handle Lifecycle Phase 3: the handle lives IN the Int register (the old
                // "A is the handle" contract is gone) — dereference like every other bank.
                begin
                    RecRt.ClearRec(RegInt[TargetAbs]);
                    FcBumpHandle(RegInt[TargetAbs]);    // PERF TEST — Clear + reopen
                end;
            "ALI TypeKind"::TextBuilder:
                TbRt.ClearI(RegInt[TargetAbs]);
            "ALI TypeKind"::BigText:
                BigRt.ClearBt(RegInt[TargetAbs]);
            "ALI TypeKind"::NativeCodeunit:
                NativeRt.ResetInstance(RegInt[TargetAbs]);     // a fresh platform instance, same handle
            "ALI TypeKind"::HttpClient, "ALI TypeKind"::HttpRequestMessage, "ALI TypeKind"::HttpResponseMessage,
            "ALI TypeKind"::HttpContent, "ALI TypeKind"::HttpHeaders:
                HttpRt.ClearByKind(B, RegInt[TargetAbs]);
            "ALI TypeKind"::JsonObject, "ALI TypeKind"::JsonArray, "ALI TypeKind"::JsonToken, "ALI TypeKind"::JsonValue:
                JsonRt.ClearJson(RegInt[TargetAbs], B);
            "ALI TypeKind"::RecordRef:
                // Native Clear(RecordRef) UNBINDS the reference (it is not "empty the record",
                // which is what Clear(Record) means) — so close the bank slot and put the
                // variable back in the handle-0 "not open" state, exactly as Close() leaves it.
                begin
                    UntrackLocalHandle("ALI TypeKind"::RecordRef, RegInt[TargetAbs]);
                    RecRt.CloseRef(RegInt[TargetAbs]);
                    FcBumpHandle(RegInt[TargetAbs]);    // PERF TEST
                    RegInt[TargetAbs] := 0;
                end;
            "ALI TypeKind"::FieldRef, "ALI TypeKind"::KeyRef:
                // Native Clear(FieldRef) UNBINDS the reference, same as Clear(RecordRef) — but
                // here there is nothing to close: the handle is a packed (recordHandle, index)
                // pair that OWNS no resource (see "ALI Opcode"::FLD_METHOD). Zeroing the register
                // IS the unbind, and it deliberately does NOT touch the underlying record.
                RegInt[TargetAbs] := 0;
            else
                // Feature 3: Xml* kinds (102-117) — blank-of-static-kind in place (XML_DESIGN.md §8).
                if (B >= "ALI TypeKind"::XmlDocument.AsInteger()) and (B <= "ALI TypeKind"::XmlNameTable.AsInteger()) then
                    XmlRt.ClearXml(RegInt[TargetAbs], B);
        // InStream/OutStream/Dialog: Clear is a no-op here (a stream's only state is its
        // shared backing buffer; Dialog has no clearable value) — documented scope.
        end;
    end;

    // Read one operand-pool slot as if it were index Idx within the pool starting at B
    // (helper kept tiny/obvious — EVALUATE_TARGET only ever reads its first text argument in
    // v1; multi-arg Evaluate(text,fmt) format numbers are recognized at bind time but the
    // v1 runtime only consumes the text operand).
    local procedure RelOrAbsOperandReg(B: Integer; Idx: Integer; IsGlobal: Integer): Integer
    var
        Packed: Integer;
    begin
        Packed := OperArr[B + Idx];
        exit(Packed div 16);
    end;

    local procedure TypeRules_RegClassText(): Integer
    begin
        exit(5);
    end;

    // Mirror "ALI Type Rules".RegClassFor for the small set of TypeOrds Evaluate/Clear can
    // target (kept local — the Interpreter has no TypeRules dependency elsewhere; §13 keeps
    // it Module/RecRuntime/Builtin*-only).
    //
    // A HAND-MAINTAINED MIRROR, and it had drifted: every Int-handle RefShim kind added since it
    // was written (RecordRef 81 / FieldRef 82 / KeyRef 83, and Xml* 102-117 before them) was
    // missing, so it fell through to the Variant fallback. That is silent, not loud —
    // ExecClearTarget computes TargetAbs from this class, so `Clear(someRecordRef)` indexed the
    // VARIANT register file's base, then wrote 0 into RegInt at that index: the ref was not
    // unbound and an unrelated Int register was corrupted instead. When adding a TypeKind whose
    // RegClassFor is Int, add it here as well — the fallback will not tell you.
    local procedure RegClassForTypeOrd(T: Integer): Integer
    begin
        case T of
            10, 13, 14, 40, 41:
                exit(1);               // Integer/Char/Byte/Option/Enum
            70, 89, 90:
                exit(1);               // Array/List/Dictionary — Int-handle reference (RegClassFor mirror)
            5, 80, 84, 85, 88, 92, 93, 94, 95, 96, 97, 98, 99, 100, 119, 122:
                exit(1);               // Dialog/Record/InStream/OutStream/TextBuilder/Http*/Json*/BigText/NativeCodeunit — Int-handle reference
            81, 82, 83:
                exit(1);               // RecordRef/FieldRef/KeyRef — Int-handle reference (P1/P2/P3)
            102, 103, 104, 105, 106, 107, 108, 109, 110,
            111, 112, 113, 114, 115, 116, 117:
                exit(1);               // Xml* — Int-handle reference
            118:
                exit(5);               // SecretText — Text register file
            11:
                exit(2);               // BigInteger
            12:
                exit(3);               // Decimal
            20:
                exit(4);               // Boolean
            30, 31, 32:
                exit(5);                    // Text/Code/Label
            50:
                exit(6);               // Date
            51:
                exit(7);               // Time
            52:
                exit(8);               // DateTime
            53:
                exit(9);               // Duration
            60:
                exit(10);              // Guid
            91:
                exit(12);              // RecordID
            54:
                exit(13);              // DateFormula
            else
                exit(11);             // Variant fallback
        end;
    end;

    // Read a FRAME-RELATIVE register of class Cls into a Variant (field/filter boundary).
    local procedure ReadRegisterAsVariant(Cls: Integer; Reg: Integer): Variant
    var
        V: Variant;
    begin
        case Cls of
            1:
                V := RegInt[CurBaseInt + Reg];
            2:
                V := RegBig[CurBaseBig + Reg];
            3:
                V := RegDec[CurBaseDec + Reg];
            4:
                V := RegBool[CurBaseBool + Reg];
            5:
                V := RegText[CurBaseText + Reg];
            6:
                V := RegDate[CurBaseDate + Reg];
            7:
                V := RegTime[CurBaseTime + Reg];
            8:
                V := RegDT[CurBaseDT + Reg];
            9:
                V := RegDur[CurBaseDur + Reg];
            10:
                V := RegGuid[CurBaseGuid + Reg];
            11:
                V := RegVariant[CurBaseVar + Reg];
            12:
                V := RegRecordId[CurBaseRecordId + Reg];
            13:
                V := RegDateFormula[CurBaseDateFormula + Reg];
        end;
        exit(V);
    end;

    // Write a Variant (from FieldRef.Value) into a FRAME-RELATIVE register, converting to the
    // statically-known class (§7.5: one boxing per field access, native conversion here).
    local procedure WriteRegisterFromVariant(Cls: Integer; Reg: Integer; V: Variant)
    begin
        case Cls of
            1:
                RegInt[CurBaseInt + Reg] := V;
            2:
                RegBig[CurBaseBig + Reg] := V;
            3:
                RegDec[CurBaseDec + Reg] := V;
            4:
                RegBool[CurBaseBool + Reg] := V;
            5:
                RegText[CurBaseText + Reg] := V;
            6:
                RegDate[CurBaseDate + Reg] := V;
            7:
                RegTime[CurBaseTime + Reg] := V;
            8:
                RegDT[CurBaseDT + Reg] := V;
            9:
                RegDur[CurBaseDur + Reg] := V;
            10:
                RegGuid[CurBaseGuid + Reg] := V;
            11:
                RegVariant[CurBaseVar + Reg] := V;
            12:
                RegRecordId[CurBaseRecordId + Reg] := V;
            13:
                RegDateFormula[CurBaseDateFormula + Reg] := V;
        end;
    end;

    // ===== TO_TEXT / result formatting =====

    // Format a FRAME-RELATIVE register of the given class (TO_TEXT operand).
    // One switch rather than CurBaseOf() + FormatAbsRegister(): TO_TEXT is on the string-building
    // path, and those two calls cost ~900ns against the single array read they resolved to.
    local procedure FormatRegister(Cls: Integer; Reg: Integer): Text
    begin
        case Cls of
            1:
                exit(Format(RegInt[CurBaseInt + Reg]));
            2:
                exit(Format(RegBig[CurBaseBig + Reg]));
            3:
                exit(Format(RegDec[CurBaseDec + Reg]));
            4:
                exit(Format(RegBool[CurBaseBool + Reg]));
            5:
                exit(RegText[CurBaseText + Reg]);
            6:
                exit(Format(RegDate[CurBaseDate + Reg]));
            7:
                exit(Format(RegTime[CurBaseTime + Reg]));
            8:
                exit(Format(RegDT[CurBaseDT + Reg]));
            9:
                exit(Format(RegDur[CurBaseDur + Reg]));
            10:
                exit(Format(RegGuid[CurBaseGuid + Reg]));
            11:
                exit(Format(RegVariant[CurBaseVar + Reg]));
            12:
                exit(Format(RegRecordId[CurBaseRecordId + Reg]));
            13:
                exit(Format(RegDateFormula[CurBaseDateFormula + Reg]));
            else
                exit('');
        end;
    end;

    // Format an ABSOLUTE register index of the given class.
    local procedure FormatAbsRegister(Cls: Integer; AbsIdx: Integer): Text
    begin
        case Cls of
            1:
                exit(Format(RegInt[AbsIdx]));
            2:
                exit(Format(RegBig[AbsIdx]));
            3:
                exit(Format(RegDec[AbsIdx]));
            4:
                exit(Format(RegBool[AbsIdx]));
            5:
                exit(RegText[AbsIdx]);
            6:
                exit(Format(RegDate[AbsIdx]));
            7:
                exit(Format(RegTime[AbsIdx]));
            8:
                exit(Format(RegDT[AbsIdx]));
            9:
                exit(Format(RegDur[AbsIdx]));
            10:
                exit(Format(RegGuid[AbsIdx]));
            11:
                exit(Format(RegVariant[AbsIdx]));
            12:
                exit(Format(RegRecordId[AbsIdx]));
            13:
                exit(Format(RegDateFormula[AbsIdx]));
            else
                exit('');
        end;
    end;

    local procedure CurBaseOf(Cls: Integer): Integer
    begin
        case Cls of
            1:
                exit(CurBaseInt);
            2:
                exit(CurBaseBig);
            3:
                exit(CurBaseDec);
            4:
                exit(CurBaseBool);
            5:
                exit(CurBaseText);
            6:
                exit(CurBaseDate);
            7:
                exit(CurBaseTime);
            8:
                exit(CurBaseDT);
            9:
                exit(CurBaseDur);
            10:
                exit(CurBaseGuid);
            11:
                exit(CurBaseVar);
            12:
                exit(CurBaseRecordId);
            13:
                exit(CurBaseDateFormula);
            else
                exit(0);
        end;
    end;

    local procedure EntryBaseOf(Cls: Integer): Integer
    begin
        case Cls of
            1:
                exit(EBInt);
            2:
                exit(EBBig);
            3:
                exit(EBDec);
            4:
                exit(EBBool);
            5:
                exit(EBText);
            6:
                exit(EBDate);
            7:
                exit(EBTime);
            8:
                exit(EBDT);
            9:
                exit(EBDur);
            10:
                exit(EBGuid);
            11:
                exit(EBVar);
            12:
                exit(EBRecordId);
            13:
                exit(EBDateFormula);
            else
                exit(0);
        end;
    end;

    // ===== Typed result getters (tests / hosts read the entry proc's result) =====
    // ResultSlotVal was sealed as an ABSOLUTE index at LoadModule.

    procedure GetResultInt(): Integer
    begin
        exit(RegInt[ResultSlotVal]);
    end;

    procedure GetResultBig(): BigInteger
    begin
        exit(RegBig[ResultSlotVal]);
    end;

    procedure GetResultDec(): Decimal
    begin
        exit(RegDec[ResultSlotVal]);
    end;

    procedure GetResultBool(): Boolean
    begin
        exit(RegBool[ResultSlotVal]);
    end;

    procedure GetResultText(): Text
    begin
        exit(RegText[ResultSlotVal]);
    end;

    procedure GetResultDate(): Date
    begin
        exit(RegDate[ResultSlotVal]);
    end;

    procedure GetResultTime(): Time
    begin
        exit(RegTime[ResultSlotVal]);
    end;

    procedure GetResultDT(): DateTime
    begin
        exit(RegDT[ResultSlotVal]);
    end;

    procedure GetResultDur(): Duration
    begin
        exit(RegDur[ResultSlotVal]);
    end;

    // Register peeks for white-box tests: Slot is ENTRY-FRAME-relative (binder numbering).
    procedure PeekInt(Slot: Integer): Integer
    begin
        exit(RegInt[EBInt + Slot]);
    end;

    procedure PeekText(Slot: Integer): Text
    begin
        exit(RegText[EBText + Slot]);
    end;

    // Module-level (global) var peeks: Slot is the ABSOLUTE global slot (binder order,
    // 1-based per class).
    procedure PeekGlobalInt(Slot: Integer): Integer
    begin
        exit(RegInt[Slot]);
    end;

    procedure PeekGlobalText(Slot: Integer): Text
    begin
        exit(RegText[Slot]);
    end;

    // ===== Internals =====
    local procedure ClearRegisters()
    begin
        Clear(RegInt);
        Clear(RegBig);
        Clear(RegDec);
        Clear(RegBool);
        Clear(RegText);
        Clear(RegDate);
        Clear(RegTime);
        Clear(RegDT);
        Clear(RegDur);
        Clear(RegGuid);
        Clear(RegVariant);
        Clear(RegRecordId);
        Clear(RegDateFormula);
        Clear(RefInt);
        Clear(RefBig);
        Clear(RefDec);
        Clear(RefBool);
        Clear(RefText);
        Clear(RefDate);
        Clear(RefTime);
        Clear(RefDT);
        Clear(RefDur);
        Clear(RefGuid);
        Clear(RefVar);
        Clear(RefRecordId);
        Clear(RefDateFormula);
    end;
}
