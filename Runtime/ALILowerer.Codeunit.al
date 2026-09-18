// ALI Lowerer — annotated AST -> Module bytecode (§7.3, §16 M5).
//
// Scope (M5): everything M4 lowered (expressions, assignment incl. compound through the
// result-type matrix §6.4, if/while/for/repeat/case, exit/break, blocks, CONCAT_N fusion,
// Error(msg) -> ERROR_RAISE) PLUS procedures:
//   * one proc-table row per procedure (entry PC, per-class register counts, result
//     class/slot/type, param descriptors) — §7.3.
//   * CALL/RET/RET_VAL with windowed frames (§7.1 C + D-lite): all register operands are
//     FRAME-RELATIVE; the interpreter adds the per-class frame base.
//   * argument staging (§7.4 convention, documented in the interpreter header): argument
//     expressions are FIRST fully evaluated into caller registers, THEN copied into the
//     soon-to-be callee window by ARG_VAL / recorded as aliases by ARG_REF (var params,
//     §7.2 — indirection, never copy-in/out), then CALL. RESULT_FETCH copies the callee's
//     result slot back into a caller temp after return. exit(value) stores to the callee's
//     own result slot and returns via RET_VAL.
//   * module-level vars live in ABSOLUTE slots below every frame (GLOB_LOAD/GLOB_STORE);
//     var-param accesses go through LOAD_IND/STORE_IND.
//
// Register model (§7.1/§7.2): the binder allocated per-proc VARIABLE slots (params,
// result slot, locals, hidden for-loop limit slots — sizes via Symbol Table
// GetProcVarCount) and absolute global slots. The lowerer allocates expression
// TEMPORARIES above the var region with a reset-temp-counter-per-statement policy and
// derives the final per-class register counts (VarBase + MaxTemp watermark) per proc row.
//
// Statement boundaries (P1): no STMT instruction — every statement registers a debug-map
// row that the Module stamps onto each instruction it emits (InstrDbgRow), so runtime
// errors resolve from the failing PC. The runaway budget is charged at BACK-EDGES
// (ClassifyBackEdges rewrites backward jumps to charged twins), FOR_NEXT and CALL.
//
// For-loop fidelity (§5.3, pitfall 17): bounds evaluated ONCE; FOR_NEXT tests before
// incrementing. Non-short-circuit (§15 pitfall 2): and/or/xor lower BOTH operands.
codeunit 51032 "ALI Lowerer"
{
    Access = Public;
    SingleInstance = false;

    var
        TypeRules: Codeunit "ALI Type Rules";
        // M11: set while lowering a HARVESTED object unit. Module globals are opened once, in the
        // script's entry proc, and an object's own globals are opened there too — once per
        // instance (phase B2) — so an object unit emits no global initializers of its own.
        // Defaults false, i.e. every existing caller lowers a script unit exactly as before.
        IsObjectUnit: Boolean;
        CurProcId: Integer;
        // M11 phase B2: non-zero only while the SCRIPT's entry proc is emitting the one-time
        // initializers for instance N's block of a harvested object's globals. The EmitNew*Global
        // family is reused verbatim for that — GlobalSids is swapped to the object's globals and
        // StoreToSym reads this to address them ABSOLUTELY (base + offset) instead of emitting a
        // SELF_STORE, which would have no instance to resolve against out there.
        EmitInstIdx: Integer;
        MaxTemp: array[13] of Integer;      // watermark -> final reg counts
        RegClassCnt: Integer;               // TypeRules.RegClassCount() cached (hot: per-statement ResetTemps)
        ResultClass: Integer;
        ResultSlot: Integer;
        ResultTypeOrd: Integer;             // CURRENT proc result
        TempCount: array[13] of Integer;    // temps in flight within the current statement
        TempFloor: array[13] of Integer;    // temps PINNED across nested statements (case selector, §7.2)
        VarBase: array[13] of Integer;      // binder var-region size for the CURRENT proc
        // M11 phase A: ProcDecl nodes whose bind failed under per-procedure isolation, and the
        // message each one should raise if it is ever reached. Their bodies are NOT lowered —
        // the annotations are poisoned — but their proc rows must still be filled in, because a
        // sibling that DID compile may hold a CALL to one of them.
        BlockedProcNodeList: List of [Integer];
        BreakMarks: List of [Integer];      // BreakPCs.Count() snapshots per open loop
        BreakPCs: List of [Integer];        // JMP instrs awaiting their loop-exit target
        CurProcLocalSids: List of [Integer];// LocalVar sids of the CURRENT proc (EmitNew*ForProc)
        CurProcParamSids: List of [Integer];// Param sids of the CURRENT proc (byval-record prologue)
        // Symbol buckets built ONCE (not re-scanned per emit family) — the prologue emitters
        // below used to each walk all Symbols.Count() rows (20 scans/proc). GlobalSids is built
        // once per module; CurProcLocalSids/CurProcParamSids are rebuilt per proc in BeginProc.
        // All three preserve ascending-Sid order, so emitted bytecode is byte-identical.
        GlobalSids: List of [Integer];      // module-scope GlobalVar sids (iterated by EmitNew*Global)
        // M11 reachability: ProcDecl nodes with a signature but no bound body. Skipped entirely.
        UnboundProcNodeList: List of [Integer];
        BlockedProcMsgList: List of [Text];

    // ===== Public API (§13) =====

    // Lower the bound compilation unit rooted at Root into a FRESH Module. Only call after a
    // clean bind (no error diagnostics) — poisoned annotations are not lowered.
    procedure Lower(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; Root: Integer): Boolean
    begin
        Module.SetEntryProcId(LowerUnit(Tokens, Ast, Symbols, Diags, Module, Root));
        exit(FinalizeModule(Module, Diags));
    end;

    // Mark the NEXT LowerUnit call as lowering a harvested object rather than the script (see
    // IsObjectUnit). Only "ALI Object Registry" sets this.
    procedure SetObjectUnit(Value: Boolean)
    begin
        IsObjectUnit := Value;
    end;

    // Procedures the binder could not compile (see BlockedProcNodeList). Call BEFORE LowerUnit;
    // the two lists are parallel. Only "ALI Object Registry" sets this.
    procedure SetBlockedProcs(Nodes: List of [Integer]; Msgs: List of [Text])
    begin
        BlockedProcNodeList := Nodes;
        BlockedProcMsgList := Msgs;
    end;

    // Procedures the binder's reachability worklist never reached: signature declared, body not
    // bound. Emit NOTHING for these — not even a raising stub, because the proc row is meant to
    // stay empty until a later compile of the same object binds that body for real. Call BEFORE
    // LowerUnit; only "ALI Object Registry" sets this.
    procedure SetUnboundProcs(Nodes: List of [Integer])
    begin
        UnboundProcNodeList := Nodes;
    end;

    // M11 phase 0: lower ONE compilation unit, APPENDING to whatever the Module already holds
    // (instructions, const/operand pools and debug map are append-only, and jump targets are
    // absolute PCs patched within this unit — so units may be emitted interleaved without any
    // relocation pass). Returns the unit's entry proc id.
    //
    // The caller owns Module.Reset() / SetEntryProcId / FinalizeModule. Proc-table ROWS were
    // already reserved by "ALI Binder".Bind (it must reserve them before binding bodies, since
    // a body can harvest another object that lowers into this Module first); the ids come back
    // through each ProcDecl's proc symbol.
    procedure LowerUnit(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; Root: Integer): Integer
    var
        Child: Integer;
        Cls: Integer;
        EntryProc: Integer;
        i: Integer;
        K: Integer;
        PId: Integer;
        ProcNodes: List of [Integer];
        Stmts: List of [Integer];
    begin
        Clear(BreakPCs);
        Clear(BreakMarks);
        RegClassCnt := TypeRules.RegClassCount();
        BuildGlobalSids(Symbols, 0);

        // Module-level (global) var slots — absolute, below every frame window. The binder
        // allocates them cumulatively over the SHARED symbol table, so the counts only ever grow
        // and the last unit's write is the right one (existing slots keep their indices; frames
        // simply start higher).
        for Cls := 1 to RegClassCnt do
            Module.SetGlobalCount(Cls, Symbols.GetGlobalCount(Cls));

        // Locate proc decls / bare statements (same classification as the binder).
        for i := 0 to Ast.GetChildCount(Root) - 1 do begin
            Child := Ast.GetChild(Root, i);
            K := Ast.GetKind(Child);
            case true of
                (K = "ALI NodeKind"::VarSection):
                    // M11 phase B/B2: a harvested OBJECT may declare variables. The binder slots
                    // them into the SHARED symbol table as OFFSETS inside that object's block,
                    // and one block per declared variable of the object's type is carved out
                    // above the script's own globals. Nothing to emit here: the handle-kind ones
                    // are opened per instance by the SCRIPT unit's entry proc
                    // (EmitNewObjectGlobals), which is lowered after every harvest, and
                    // re-emitting them per object would open them twice.
                    ;
                (K = "ALI NodeKind"::ProcDecl):
                    ProcNodes.Add(Child);
                (K = "ALI NodeKind"::MissingNode):
                    ;   // sentinel — skip
                else
                    Stmts.Add(Child);
            end;
        end;

        EntryProc := Ast.GetSymbolId(Root);     // binder contract: entry proc id on the root
        if EntryProc <= 0 then
            EntryProc := 1;

        if ProcNodes.Count() = 0 then begin
            // form 0: one synthetic proc over the bare statement list; result info on Root.
            PId := EntryProc;                          // the row the binder reserved for it
            BeginProc(Symbols, PId, Ast.GetTypeOrd(Root), Ast.GetSlotIndex(Root));
            Module.SetProcEntryPC(PId, Module.NextPC());
            if not IsObjectUnit then begin            // globals belong to the SCRIPT unit only

                EmitNewRecordsGlobal(Symbols, Module);      // Handle Lifecycle Unification: module-scope records, once
                EmitNewStreamsGlobal(Symbols, Module);      // module-scope streams, once
                EmitNewTBGlobal(Symbols, Module);           // module-scope TextBuilders, once
                EmitNewBigTextGlobal(Symbols, Module);   // module-scope BigTexts, once
                EmitNewDialogGlobal(Symbols, Module);       // module-scope Dialogs, once
                EmitNewCollectionsGlobal(Symbols, Module);  // ListDictionaryPlan.md §5.1: module-scope List/Dict, once
                EmitNewArraysGlobal(Symbols, Module);       // §20.6: module-scope arrays, once
                EmitNewHttpGlobal(Symbols, Module);         // M10: module-scope Http*, once
                EmitNewJsonGlobal(Symbols, Module);         // Feature 2: module-scope Json*, once
                EmitNewXmlGlobal(Symbols, Module);          // Feature 3: module-scope Xml*, once
                EmitNewNativeCUGlobal(Symbols, Module);     // module-scope native codeunit instances, once
                EmitNewObjectGlobals(Symbols, Module);      // M11 phase B2: one block per instance of a harvested object
            end;
            EmitNewRecordsForProc(Symbols, Module, PId);  // this proc's own record locals, fresh every call
            EmitNewStreamsForProc(Symbols, Module, PId);  // this proc's own stream locals, fresh every call
            EmitNewTBForProc(Symbols, Module, PId);       // this proc's own TextBuilder locals, fresh every call
            EmitNewBigTextForProc(Symbols, Module, PId);  // this proc's own BigText locals, fresh every call
            EmitNewDialogForProc(Symbols, Module, PId);   // this proc's own Dialog locals, fresh every call
            EmitNewCollectionsForProc(Symbols, Module, PId);  // this proc's own List/Dict locals, fresh every call
            EmitNewArraysForProc(Symbols, Module, PId);   // this proc's own array locals, fresh every call
            EmitNewHttpForProc(Symbols, Module, PId);     // this proc's own Http* locals, fresh every call
            EmitNewJsonForProc(Symbols, Module, PId);     // this proc's own Json* locals, fresh every call
            EmitNewXmlForProc(Symbols, Module, PId);      // this proc's own Xml* locals, fresh every call
            EmitNewNativeCUForProc(Symbols, Module, PId); // this proc's own native codeunit locals, fresh every call
            EmitZeroScalarLocalsForProc(Symbols, Module, PId);  // this proc's own scalar locals, reset every call
            EmitZeroRecordRefLocalsForProc(Symbols, Module, PId);  // P1: RecordRef locals start UNOPENED (handle 0), every call
            foreach Child in Stmts do
                LowerStatement(Tokens, Ast, Symbols, Module, Child);
            Module.AddInstr("ALI Opcode"::RET, 0, 0, 0);
            EndProc(Symbols, Diags, Module, PId);
        end else
            for i := 1 to ProcNodes.Count() do begin
                Child := ProcNodes.Get(i);
                PId := ProcIdOfNode(Ast, Symbols, Child, i);
                // Reachability: a signature-only procedure (body never bound) is skipped whole —
                // its proc row stays empty until a later compile of the same object fills it.
                if not UnboundProcNodeList.Contains(Child) then
                    if BlockedProcNodeList.Contains(Child) then
                        EmitBlockedProcStub(Ast, Symbols, Diags, Module, Child, PId)
                    else begin
                        BeginProc(Symbols, PId, Ast.GetTypeOrd(Child), Ast.GetSlotIndex(Child));
                        Module.SetProcEntryPC(PId, Module.NextPC());
                        // Module globals are opened ONCE, in the SCRIPT unit's entry proc — a harvested
                        // object must not re-open them (see the ALI947 note above).
                        if (PId = EntryProc) and not IsObjectUnit then begin
                            EmitNewRecordsGlobal(Symbols, Module);  // Handle Lifecycle Unification: records are module-scoped; new in the entry proc
                            EmitNewStreamsGlobal(Symbols, Module);
                            EmitNewTBGlobal(Symbols, Module);
                            EmitNewBigTextGlobal(Symbols, Module);   // module-scope BigTexts, once
                            EmitNewDialogGlobal(Symbols, Module);
                            EmitNewCollectionsGlobal(Symbols, Module);  // ListDictionaryPlan.md §5.1: module-scope, once
                            EmitNewArraysGlobal(Symbols, Module);       // §20.6: module-scope arrays, once
                            EmitNewHttpGlobal(Symbols, Module);         // M10: module-scope Http*, once
                            EmitNewJsonGlobal(Symbols, Module);         // Feature 2: module-scope Json*, once
                            EmitNewXmlGlobal(Symbols, Module);          // Feature 3: module-scope Xml*, once
                            EmitNewNativeCUGlobal(Symbols, Module);     // module-scope native codeunit instances, once
                            EmitNewObjectGlobals(Symbols, Module);      // M11 phase B2: one block per instance of a harvested object
                        end;
                        EmitNewRecordsForProc(Symbols, Module, PId);      // this proc's OWN record locals, fresh every call
                        EmitCopyByvalRecordParams(Symbols, Module, PId);  // byval Record params: fresh handle + copy (value semantics)
                        EmitNewStreamsForProc(Symbols, Module, PId);      // this proc's OWN stream locals, fresh every call
                        EmitNewTBForProc(Symbols, Module, PId);           // this proc's OWN TextBuilder locals, fresh every call
                        EmitNewBigTextForProc(Symbols, Module, PId);  // this proc's own BigText locals, fresh every call
                        EmitNewDialogForProc(Symbols, Module, PId);       // this proc's OWN Dialog locals, fresh every call
                        EmitNewCollectionsForProc(Symbols, Module, PId);  // this proc's OWN List/Dict locals, fresh every call
                        EmitNewArraysForProc(Symbols, Module, PId);       // this proc's OWN array locals, fresh every call
                        EmitNewHttpForProc(Symbols, Module, PId);         // this proc's OWN Http* locals, fresh every call
                        EmitNewJsonForProc(Symbols, Module, PId);         // this proc's OWN Json* locals, fresh every call
                        EmitNewXmlForProc(Symbols, Module, PId);          // this proc's OWN Xml* locals, fresh every call
                        EmitNewNativeCUForProc(Symbols, Module, PId);     // this proc's OWN native codeunit locals, fresh every call
                        EmitZeroScalarLocalsForProc(Symbols, Module, PId); // this proc's OWN scalar locals, reset every call
                        EmitZeroRecordRefLocalsForProc(Symbols, Module, PId); // P1: RecordRef locals start UNOPENED (handle 0), every call
                        LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Child, 3));
                        Module.AddInstr("ALI Opcode"::RET, 0, 0, 0);
                        EndProc(Symbols, Diags, Module, PId);
                    end;
            end;

        exit(EntryProc);
    end;

    // M11 phase A: body of a procedure that did not compile. Its proc row is real (signature,
    // parameter descriptors, register counts) so a sibling's CALL stages arguments correctly and
    // the frame is well formed — it just raises instead of running. That keeps a fat table with
    // one unsupported helper usable, and turns "unset entry PC" (which would jump to PC 0) into
    // a named error the moment the procedure is actually reached.
    local procedure EmitBlockedProcStub(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; ProcNode: Integer; PId: Integer)
    var
        Idx: Integer;
        TxtReg: Integer;
        Msg: Text;
    begin
        Msg := 'This procedure could not be compiled by the AL interpreter.';
        Idx := BlockedProcNodeList.IndexOf(ProcNode);
        if (Idx >= 1) and (Idx <= BlockedProcMsgList.Count()) then
            Msg := BlockedProcMsgList.Get(Idx);

        BeginProc(Symbols, PId, Ast.GetTypeOrd(ProcNode), Ast.GetSlotIndex(ProcNode));
        Module.SetProcEntryPC(PId, Module.NextPC());
        TxtReg := AllocTemp("ALI Register Class"::"Text");
        Module.AddInstr("ALI Opcode"::LOAD_CONST_T, TxtReg, Module.AddConstText(Msg), 0);
        Module.AddInstr("ALI Opcode"::ERROR_RAISE, TxtReg, 0, 0);
        Module.AddInstr("ALI Opcode"::RET, 0, 0, 0);
        EndProc(Symbols, Diags, Module, PId);
    end;

    // Proc id of a ProcDecl node: the binder stamped its proc SYMBOL on the node in pass 1, and
    // the symbol carries the id. Falls back to the declaration-order id when the symbol is
    // missing — only reachable for a duplicate-name proc, which already errored the bind.
    local procedure ProcIdOfNode(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; ProcNode: Integer; Fallback: Integer): Integer
    var
        Sid: Integer;
    begin
        Sid := Ast.GetSymbolId(ProcNode);
        if Sid <= 0 then
            exit(Fallback);
        exit(Symbols.GetProcId(Sid));
    end;

    // Whole-module finish, once, after the LAST unit is lowered: back-edge classification is a
    // linear pass over every instruction and the overflow flag is module-wide, so neither
    // belongs in LowerUnit.
    procedure FinalizeModule(var Module: Codeunit "ALI Module"; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Limits: Codeunit "ALI Limits";
    begin
        // P1: all jump targets are final here — rewrite backward jumps/branches to their
        // charged twins so every loop iteration pays the runaway budget exactly once.
        Module.ClassifyBackEdges();

        if Module.Overflowed() then
            Diags.AddError('ALI940', StrSubstNo('Program too large: more than %1 instructions', Limits.MaxInstructions()), 0, 0);

        exit(not Diags.HasErrors());
    end;

    // ===== Per-proc bookkeeping =====

    local procedure BeginProc(var Symbols: Codeunit "ALI Symbol Table"; PId: Integer; ResT: Integer; ResSlot: Integer)
    var
        Cls: Integer;
    begin
        CurProcId := PId;
        Clear(TempCount);
        Clear(TempFloor);
        Clear(MaxTemp);
        for Cls := 1 to RegClassCnt do
            VarBase[Cls] := Symbols.GetProcVarCount(PId, Cls);
        ResultTypeOrd := ResT;
        ResultSlot := ResSlot;
        ResultClass := TypeRules.RegClassFor(ResT);
        BuildProcSids(Symbols, PId);
    end;

    // Collect module-scope GlobalVar symbol ids once (ascending) — the EmitNew*Global family
    // iterates this instead of re-scanning the whole symbol table per handle-kind.
    // ObjKey selects whose globals to collect: 0 = the SCRIPT's own (the ordinary case, absolute
    // slots), a harvested object's key = that object's, which the entry proc then initialises
    // once per instance (M11 phase B2).
    local procedure BuildGlobalSids(var Symbols: Codeunit "ALI Symbol Table"; ObjKey: Integer)
    var
        Sid: Integer;
    begin
        Clear(GlobalSids);
        // Symbols.GlobalSids() instead of a full-table scan — once per unit, over a table shared
        // with every harvested object.
        foreach Sid in Symbols.GlobalSids() do
            if Symbols.GetKind(Sid) = "ALI Symbol Kind"::GlobalVar then
                if Symbols.GetOwnerObjKey(Sid) = ObjKey then
                    GlobalSids.Add(Sid);
    end;

    // M11 phase B2: one block of object globals per INSTANCE, initialised once in the script's
    // entry proc. Reuses the whole EmitNew*Global family per instance — EmitInstIdx makes
    // StoreToSym address that instance's block absolutely, so nothing else has to change. An
    // instance whose object was never harvested contributes no globals and emits nothing.
    local procedure EmitNewObjectGlobals(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Inst: Integer;
    begin
        for Inst := 1 to Symbols.InstanceCount() do begin
            BuildGlobalSids(Symbols, Symbols.InstanceOwner(Inst));
            if GlobalSids.Count() > 0 then begin
                EmitInstIdx := Inst;
                EmitNewRecordsGlobal(Symbols, Module);
                EmitNewStreamsGlobal(Symbols, Module);
                EmitNewTBGlobal(Symbols, Module);
                EmitNewBigTextGlobal(Symbols, Module);
                EmitNewDialogGlobal(Symbols, Module);
                EmitNewCollectionsGlobal(Symbols, Module);
                EmitNewArraysGlobal(Symbols, Module);
                EmitNewHttpGlobal(Symbols, Module);
                EmitNewJsonGlobal(Symbols, Module);
                EmitNewXmlGlobal(Symbols, Module);
                EmitNewNativeCUGlobal(Symbols, Module);
                EmitInstIdx := 0;
            end;
        end;
        BuildGlobalSids(Symbols, 0);            // restore the script's own bucket
    end;

    // Collect the CURRENT proc's LocalVar and Param symbol ids once (ascending). The prologue
    // emitters (EmitNew*ForProc, EmitCopyByvalRecordParams, EmitZeroScalarLocalsForProc) walk
    // these buckets rather than filtering all Symbols.Count() rows each — same order, so the
    // emitted prologue is unchanged.
    local procedure BuildProcSids(var Symbols: Codeunit "ALI Symbol Table"; PId: Integer)
    var
        K: Integer;
        Sid: Integer;
    begin
        Clear(CurProcLocalSids);
        Clear(CurProcParamSids);
        // Symbols.ProcSymbols(PId) instead of a full-table scan: this runs once per PROCEDURE,
        // and under M11 whole-object harvesting the shared symbol table holds every harvested
        // object's symbols, not just the script's.
        foreach Sid in Symbols.ProcSymbols(PId) do begin
            K := Symbols.GetKind(Sid);
            if K = "ALI Symbol Kind"::LocalVar then
                CurProcLocalSids.Add(Sid)
            else
                if K = "ALI Symbol Kind"::Param then
                    CurProcParamSids.Add(Sid);
        end;
    end;

    local procedure EndProc(var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Cls: Integer;
        k: Integer;
        N: Integer;
        Row: Integer;
    begin
        for Cls := 1 to RegClassCnt do begin
            N := VarBase[Cls] + MaxTemp[Cls];
            Module.SetProcRegCount(PId, Cls, N);
            // Static sanity check: at least one frame of this proc must fit above globals.
            if Module.GetGlobalCount(Cls) + N > MaxRegistersOfClass(Cls) then
                Diags.AddError('ALI941', StrSubstNo('Program too large: register class %1 needs %2 slots (max %3)', Cls, Module.GetGlobalCount(Cls) + N, MaxRegistersOfClass(Cls)), 0, 0);
        end;
        Module.SetProcResult(PId, ResultClass, ResultSlot, ResultTypeOrd);
        // M11 phase B2: where SELF_LOAD/SELF_STORE find this frame's instance index (0 = this
        // procedure has no object globals to address).
        if Symbols.GetProcSelfRow(PId) > 0 then
            Module.SetProcSelfSlot(PId, Symbols.ParamRowSlot(Symbols.ProcParamRow(PId, Symbols.GetProcSelfRow(PId))));
        for k := 1 to Symbols.ProcParamCount(PId) do begin
            Row := Symbols.ProcParamRow(PId, k);
            Module.AddProcParamDesc(PId, TypeRules.RegClassFor(Symbols.ParamRowType(Row)), Symbols.ParamRowSlot(Row), Symbols.ParamRowIsVar(Row));
        end;
    end;

    // ===== Handle Lifecycle Unification Phase 3: Record/Stream/TextBuilder/Dialog dynamic
    // handle banks — mirrors EmitNewCollectionsForProc/Global exactly (§HandleLifecycle). A
    // LOCAL gets a fresh handle every proc entry (frame-windowed Int register, tracked for
    // frame-pop reclaim — fixes the recursion-sharing bug and, for the first time, makes
    // Record/Stream/TextBuilder usable as proc locals at all, see "ALI Binder" header notes);
    // a GLOBAL gets one handle for the whole run, allocated once in the entry proc. =====

    local procedure EmitNewRecordsForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TempFlag: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Record then begin
                TempFlag := 0;
                if Symbols.HasFlag(Sid, Symbols.FlagTemporary()) then
                    TempFlag := 1;
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::REC_OPEN, TmpReg, Symbols.GetTypeArg(Sid), TempFlag * 2 + 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    // Byval Record params (§7.5 value semantics): at proc entry the param slot holds the
    // CALLER's handle (ARG_VAL copied the Int). Open a FRESH local handle (tracked → freed at
    // frame pop), copy the caller's record into it (fields + filters, no table sharing — the
    // native byval contract; a `temporary` param opens its own empty temp dataset, mirroring
    // the native byval-temp gotcha), then rebind the param slot to the fresh handle. The
    // caller's record is never aliased. MUST run in the prologue, before any body statement.
    local procedure EmitCopyByvalRecordParams(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TempFlag: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcParamSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Record then begin
                TempFlag := 0;
                if Symbols.HasFlag(Sid, Symbols.FlagTemporary()) then
                    TempFlag := 1;
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::REC_OPEN, TmpReg, Symbols.GetTypeArg(Sid), TempFlag * 2 + 0);   // IsGlobal=0 (tracked)
                // dest = fresh handle (TmpReg), src = caller handle still in the param slot
                Module.AddInstr("ALI Opcode"::REC_COPY_REC, TmpReg, Symbols.GetSlot(Sid), 0);
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewRecordsGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        TempFlag: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Record then begin
                TempFlag := 0;
                if Symbols.HasFlag(Sid, Symbols.FlagTemporary()) then
                    TempFlag := 1;
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::REC_OPEN, TmpReg, Symbols.GetTypeArg(Sid), TempFlag * 2 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure IsStreamType(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::InStream) or (T = "ALI TypeKind"::OutStream));
    end;

    local procedure EmitNewStreamsForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        IsOut: Integer;
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if IsStreamType(Symbols.GetType(Sid)) then begin
                IsOut := 0;
                if Symbols.GetType(Sid) = "ALI TypeKind"::OutStream then
                    IsOut := 1;
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::STRM_OPEN, TmpReg, IsOut * 2 + 0, 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewStreamsGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        IsOut: Integer;
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if IsStreamType(Symbols.GetType(Sid)) then begin
                IsOut := 0;
                if Symbols.GetType(Sid) = "ALI TypeKind"::OutStream then
                    IsOut := 1;
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::STRM_OPEN, TmpReg, IsOut * 2 + 1, 0);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewTBForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::TextBuilder then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::TB_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + 0 * 100 + 0);   // MethodId=0 (New), IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewTBGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::TextBuilder then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::TB_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + 0 * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    // Native stateful codeunit variables (TypeKind NativeCodeunit, Data Compression): a fresh
    // platform instance per proc entry for a local, one for the whole run for a global.
    local procedure EmitNewNativeCUForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::NativeCodeunit then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::NCU_NEW, TmpReg, Symbols.GetTypeArg(Sid), 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewNativeCUGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::NativeCodeunit then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::NCU_NEW, TmpReg, Symbols.GetTypeArg(Sid), 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewBigTextForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::BigText then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::BIGTEXT_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + 0 * 100 + 0);   // MethodId=0 (New), IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewBigTextGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::BigText then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::BIGTEXT_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + 0 * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewDialogForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Dialog then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::DLG_METHOD, TmpReg, 0, 0 * 100 + 0);   // MethodId=0 (New), IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    local procedure EmitNewDialogGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Dialog then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::DLG_METHOD, TmpReg, 0, 0 * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    // ===== List/Dictionary RefShim collections (ListDictionaryPlan.md §5.1) =====
    //
    // A List/Dict value is an Int-class register — a LOCAL one occupies a distinct physical
    // slot per recursion depth (frame windowing), so it must get a FRESH handle every time its
    // owning proc is entered, not once at program start. Module-level (global) List/Dict vars
    // are the opposite: one shared absolute slot for the whole run, so they are newed exactly
    // once, in the entry proc, alongside EmitNewRecordsGlobal/EmitNewStreamsGlobal/etc. — every
    // handle-kind type (Array/List/Dictionary/Record/Stream/TextBuilder/Dialog/Http*) now
    // follows this same local/global shape (Handle Lifecycle Unification Phase 3).

    // Emit LIST_NEW/DICT_NEW for every List/Dict LOCAL scoped to proc PId, storing the fresh
    // handle through the normal StoreToSym path (handles the local/var-param/global storage
    // shapes uniformly — a local is the common case here and stores directly).
    local procedure EmitNewCollectionsForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do begin
            T := Symbols.GetType(Sid);
            if T = "ALI TypeKind"::List then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::LIST_NEW, TmpReg, Symbols.GetTypeArg(Sid), 0);   // IsGlobal=0 (Handle Lifecycle Unification)
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end else
                if T = "ALI TypeKind"::Dictionary then begin
                    TmpReg := AllocTemp("ALI Register Class"::Int);
                    Module.AddInstr("ALI Opcode"::DICT_NEW, TmpReg, Symbols.GetTypeArg(Sid), 0);   // IsGlobal=0
                    StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
                end;
        end;
    end;

    // Emit LIST_NEW/DICT_NEW for every List/Dict GLOBAL (module-scope) var — called once,
    // in the entry proc, before any statement runs.
    local procedure EmitNewCollectionsGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do begin
            T := Symbols.GetType(Sid);
            if T = "ALI TypeKind"::List then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::LIST_NEW, TmpReg, Symbols.GetTypeArg(Sid), 1);   // IsGlobal=1 (Handle Lifecycle Unification)
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end else
                if T = "ALI TypeKind"::Dictionary then begin
                    TmpReg := AllocTemp("ALI Register Class"::Int);
                    Module.AddInstr("ALI Opcode"::DICT_NEW, TmpReg, Symbols.GetTypeArg(Sid), 1);   // IsGlobal=1
                    StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
                end;
        end;
    end;

    // ===== §20 array RefShim allocation (mirrors EmitNewCollectionsForProc/Global above) =====
    //
    // An array is now an Int handle occupying a distinct physical slot per recursion depth
    // (frame windowing) — like List/Dict, it needs a FRESH block every time its owning proc
    // is entered (§20.6/20.9(4)). Module-level (global) array vars get ONE block for the
    // whole run, allocated once in the entry proc.

    // Emit ARR_NEW for every array LOCAL scoped to proc PId (fresh block every call).
    local procedure EmitNewArraysForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        ElemCls: Integer;
        Sid: Integer;
        TmpReg: Integer;
        TotalN: Integer;
    begin
        foreach Sid in CurProcLocalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Array then begin
                ElemCls := TypeRules.RegClassFor(ArrayElemType(Symbols.GetTypeArg(Sid)));
                TotalN := ArrayLen(Symbols.GetTypeArg(Sid));
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::ARR_NEW, TmpReg, ElemCls, TotalN * 2 + 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    // Emit CLEAR_TARGET for every plain-scalar LOCAL var of proc PId. A local occupies the
    // SAME physical register slot on every call at a given call site (frame windowing, M5),
    // and the register file is only ever zeroed once at interpreter start — so without this,
    // a local read before its first assignment silently sees the PREVIOUS call's leftover
    // value instead of its AL default (e.g. an accumulator that never resets across repeated
    // calls). Array/List/Dictionary locals are excluded — EmitNewArraysForProc/
    // EmitNewCollectionsForProc already give those a fresh handle every call; same for
    // Record/stream/TextBuilder/Http*/Json* (per-call fresh handles). Enum (Int-backed) and
    // Variant ARE zeroed — both have CLEAR_TARGET runtime arms.
    local procedure EmitZeroScalarLocalsForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        T: Integer;
    begin
        foreach Sid in CurProcLocalSids do begin
            T := Symbols.GetType(Sid);
            case T of
                "ALI TypeKind"::Integer, "ALI TypeKind"::BigInteger, "ALI TypeKind"::Decimal, "ALI TypeKind"::Char,
                "ALI TypeKind"::Byte, "ALI TypeKind"::Boolean, "ALI TypeKind"::Text, "ALI TypeKind"::Code,
                "ALI TypeKind"::Label, "ALI TypeKind"::SecretText, "ALI TypeKind"::Option, "ALI TypeKind"::Enum, "ALI TypeKind"::Variant,
                "ALI TypeKind"::Date, "ALI TypeKind"::Time,
                "ALI TypeKind"::DateTime, "ALI TypeKind"::Duration, "ALI TypeKind"::DateFormula, "ALI TypeKind"::Guid,
                "ALI TypeKind"::RecordID:
                    Module.AddInstr("ALI Opcode"::CLEAR_TARGET, Symbols.GetSlot(Sid), T, 0);
            end;
        end;
    end;

    // Zero every RecordRef LOCAL at proc entry (P1). A RecordRef deliberately gets NO handle
    // from the prologue — Open() is what allocates one — so the slot must start at 0, the
    // truthful "not open" state. Without this the frame-windowed register would still hold the
    // PREVIOUS call's handle, and the second call of a proc would silently operate on a bank
    // slot that Close() may already have recycled to somebody else.
    // Deliberately NOT folded into EmitZeroScalarLocalsForProc's CLEAR_TARGET list: the
    // RecordRef arm of CLEAR_TARGET implements native Clear(RecordRef), which CLOSES the
    // referenced slot — running that over a stale leftover handle would close a live ref
    // belonging to another variable. A plain constant store is the whole requirement here.
    local procedure EmitZeroRecordRefLocalsForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
    begin
        // P2/P3: FieldRef and KeyRef locals ride along for exactly the same reason — an unbound
        // packed pair IS 0, they never get a handle at proc entry (Field()/KeyIndex() binds
        // them), and a leftover value from a previous frame would decode to a live record
        // handle and a plausible-looking field number. Silently wrong, not an error: worth
        // three words of code to make impossible.
        foreach Sid in CurProcLocalSids do
            if (Symbols.GetType(Sid) = "ALI TypeKind"::RecordRef) or
               (Symbols.GetType(Sid) = "ALI TypeKind"::FieldRef) or
               (Symbols.GetType(Sid) = "ALI TypeKind"::KeyRef)
            then
                Module.AddInstr("ALI Opcode"::LOAD_CONST_I, Symbols.GetSlot(Sid), Module.AddConstInt(0), 0);
    end;

    // Emit ARR_NEW for every array GLOBAL (module-scope) var — called once, in the entry proc.
    local procedure EmitNewArraysGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        ElemCls: Integer;
        Sid: Integer;
        TmpReg: Integer;
        TotalN: Integer;
    begin
        foreach Sid in GlobalSids do
            if Symbols.GetType(Sid) = "ALI TypeKind"::Array then begin
                ElemCls := TypeRules.RegClassFor(ArrayElemType(Symbols.GetTypeArg(Sid)));
                TotalN := ArrayLen(Symbols.GetTypeArg(Sid));
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::ARR_NEW, TmpReg, ElemCls, TotalN * 2 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
    end;

    // ===== M10 Http* RefShim allocation (mirrors EmitNewCollectionsForProc/Global above) =====
    //
    // A Http* value is an Int handle (List/Dict scheme, "ALI Type Rules".RegClassFor) — a
    // LOCAL needs a fresh bank slot every call (frame windowing) AND gets tracked on the
    // frame-scoped alloc stack for reclaim on pop (mirrors ARR_NEW/§20.5); a GLOBAL gets one
    // for the whole run, freed only at Reset(). Emitted as a HTTP_METHOD "New" call: A/B
    // unused, C = OutReg*100000 + OutCls*10000 + MethodId*100 + IsGlobal(0/1) — New ids never
    // take real args, so the low ArgCount slot is repurposed for the IsGlobal flag (mirrors
    // ARR_NEW's TotalN*2+IsGlobal packing), OutCls = "ALI Register Class"::"Int".

    local procedure HttpNewMethodId(T: Integer): Integer
    begin
        case T of
            "ALI TypeKind"::HttpClient:
                exit(1);
            "ALI TypeKind"::HttpRequestMessage:
                exit(20);
            "ALI TypeKind"::HttpResponseMessage:
                exit(40);
            "ALI TypeKind"::HttpContent:
                exit(60);
            "ALI TypeKind"::HttpHeaders:
                exit(80);
        end;
    end;

    local procedure IsHttpType(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::HttpClient) or (T = "ALI TypeKind"::HttpRequestMessage) or (T = "ALI TypeKind"::HttpResponseMessage) or
             (T = "ALI TypeKind"::HttpContent) or (T = "ALI TypeKind"::HttpHeaders));
    end;

    local procedure IsJsonType(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::JsonObject) or (T = "ALI TypeKind"::JsonArray) or
             (T = "ALI TypeKind"::JsonToken) or (T = "ALI TypeKind"::JsonValue));
    end;

    // Per-kind "New" method id (the compiler-internal allocator emitted at declaration —
    // mirrors HttpNewMethodId). 1/26/51/76 head their JSON_METHOD id ranges.
    local procedure JsonNewMethodId(T: Integer): Integer
    begin
        case T of
            "ALI TypeKind"::JsonObject:
                exit(1);
            "ALI TypeKind"::JsonArray:
                exit(26);
            "ALI TypeKind"::JsonToken:
                exit(51);
            "ALI TypeKind"::JsonValue:
                exit(76);
        end;
    end;

    // Feature 3: the 16 Xml* kinds (XML_DESIGN.md §1) — contiguous ordinals 102-117.
    local procedure IsXmlType(T: Integer): Boolean
    begin
        exit((T >= "ALI TypeKind"::XmlDocument.AsInteger()) and (T <= "ALI TypeKind"::XmlNameTable.AsInteger()));
    end;

    // Per-kind "New" method id (compiler-internal allocator emitted at declaration —
    // mirrors JsonNewMethodId). XML_DESIGN.md §3: id = TypeKind ordinal − 101 (1-16).
    local procedure XmlNewMethodId(T: Integer): Integer
    begin
        exit(T - "ALI TypeKind"::XmlDocument.AsInteger() + 1);
    end;

    // Handle Lifecycle Unification: the TypeKinds whose value can be STORED as a bare handle
    // through a var-param alias or into a global, so StoreToSym has to emit a HANDLE_ESCAPE
    // ahead of the store and hand ownership out of the current frame.
    // Record/InStream/OutStream/TextBuilder/Dialog are tracked on the alloc stack too, but AL
    // has no handle-store shape for them (`:=` on a Record is a VALUE copy, and the rest cannot
    // be assigned at all), so they never reach here. RecordRef DOES have one: Open/Close/
    // GetTable rebind the variable, and LowerRecordRefMethod stores the new handle back through
    // exactly this path when the receiver is a global or a var-param.
    local procedure IsHandleKindType(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::Array) or (T = "ALI TypeKind"::List) or (T = "ALI TypeKind"::Dictionary) or (T = "ALI TypeKind"::RecordRef) or IsHttpType(T) or IsJsonType(T) or IsXmlType(T));
    end;

    local procedure EmitNewHttpForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do begin
            T := Symbols.GetType(Sid);
            if IsHttpType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::HTTP_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + HttpNewMethodId(T) * 100 + 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    local procedure EmitNewHttpGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do begin
            T := Symbols.GetType(Sid);
            if IsHttpType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::HTTP_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + HttpNewMethodId(T) * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    // Feature 2: Json* declaration-time "New" — mirrors EmitNewHttpForProc/Global. New ids
    // 1/26/51/76; IsGlobal packed into the ArgCount nibble (JSON_METHOD New ids take no real
    // args, same as HTTP_METHOD New).
    local procedure EmitNewJsonForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do begin
            T := Symbols.GetType(Sid);
            if IsJsonType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::JSON_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + JsonNewMethodId(T) * 100 + 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    local procedure EmitNewJsonGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do begin
            T := Symbols.GetType(Sid);
            if IsJsonType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::JSON_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + JsonNewMethodId(T) * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    // Feature 3: Xml* declaration-time "New" — mirrors EmitNewJsonForProc/Global. New ids
    // 1-16 (TypeKind ordinal − 101, XML_DESIGN.md §3); IsGlobal packed into the ArgCount
    // nibble (XML_METHOD New ids take no real args, same as JSON_METHOD New).
    local procedure EmitNewXmlForProc(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; PId: Integer)
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in CurProcLocalSids do begin
            T := Symbols.GetType(Sid);
            if IsXmlType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::XML_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + XmlNewMethodId(T) * 100 + 0);   // IsGlobal=0
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    local procedure EmitNewXmlGlobal(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Sid: Integer;
        T: Integer;
        TmpReg: Integer;
    begin
        foreach Sid in GlobalSids do begin
            T := Symbols.GetType(Sid);
            if IsXmlType(T) then begin
                TmpReg := AllocTemp("ALI Register Class"::Int);
                Module.AddInstr("ALI Opcode"::XML_METHOD, 0, 0, TmpReg * 100000 + "ALI Register Class"::Int * 10000 + XmlNewMethodId(T) * 100 + 1);   // IsGlobal=1
                StoreToSym(Module, Symbols, Sid, "ALI Register Class"::Int, TmpReg);
            end;
        end;
    end;

    // ===== Statements =====

    local procedure LowerStatement(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        i: Integer;
        K: Integer;
    begin
        ResetTemps();
        K := Ast.GetKind(Node);
        case true of
            (K = "ALI NodeKind"::Block):
                for i := 0 to Ast.GetChildCount(Node) - 1 do
                    LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, i));
            (K = "ALI NodeKind"::AssignmentStatement):
                LowerAssignment(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::ExpressionStatement):
                LowerExpressionStatement(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::IfStatement):
                LowerIf(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::WhileStatement):
                LowerWhile(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::RepeatStatement):
                LowerRepeat(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::ForStatement):
                LowerFor(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::ForEachStatement):
                LowerForEach(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::CaseStatement):
                LowerCase(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::ExitStatement):
                LowerExit(Tokens, Ast, Symbols, Module, Node);
            (K = "ALI NodeKind"::BreakStatement):
                begin
                    EmitStmtMarker(Tokens, Ast, Module, Node);
                    BreakPCs.Add(Module.AddInstr("ALI Opcode"::JMP, 0, 0, 0));
                end;
            else
                ;   // Empty/Error/Skipped/Missing/OrphanedElse — nothing executable
        end;
    end;

    local procedure LowerAssignment(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        Group: Integer;
        IdCalleeNode: Integer;
        OpT: Integer;
        OpTok: Integer;
        ResCls: Integer;
        ResReg: Integer;
        Sid: Integer;
        SourceNode: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
        TargetNode: Integer;
        TgtCls: Integer;
        TgtReg: Integer;
    begin
        EmitStmtMarker(Tokens, Ast, Module, Node);
        TargetNode := Ast.GetChild(Node, 0);
        SourceNode := Ast.GetChild(Node, 1);
        OpTok := Ast.GetExtra(Node);

        // M6: field / array-element / record-copy targets (plain := only; compound assignment
        // to fields/elements is out of M6 scope — the binder never annotates them for it).
        if OpTok = 40 then
            case Ast.GetKind(TargetNode) of
                "ALI NodeKind"::MemberAccessExpr:
                    begin
                        // `HttpReq.Method := 'GET'` — binder re-marked the target with an Http
                        // setter method id (see "ALI Binder".TryBindHttpPropertySet); emit the
                        // setter call, not a record field store.
                        // `F.Value := x` — FieldRefMethodMark(-16000) is MORE negative than every
                        // other property-set mark, so it must be tested before them or the Http
                        // arm would swallow it.
                        if Ast.GetSymbolId(TargetNode) <= FieldRefMethodMark() then
                            LowerFieldRefPropertyStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode)
                        else
                        if Ast.GetSymbolId(TargetNode) <= HttpMethodMark() then
                            LowerHttpPropertyStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode)
                        else
                            // `inStr.Position := n` — StreamMethodMark(-2000) range, checked
                            // AFTER Http (whose marks are more negative and would match too).
                            if Ast.GetSymbolId(TargetNode) <= StreamMethodMark() then
                                LowerStreamPropertyStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode)
                            else
                                LowerFieldStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode);
                        exit;
                    end;
                "ALI NodeKind"::IndexExpr:
                    begin
                        if Symbols.GetType(Ast.GetSymbolId(Ast.GetChild(TargetNode, 0))) = "ALI TypeKind"::Array then
                            LowerArrayStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode)
                        else
                            LowerTextIndexStore(Tokens, Ast, Symbols, Module, TargetNode, SourceNode);
                        exit;
                    end;
            end;

        Sid := Ast.GetSymbolId(TargetNode);
        if Sid <= 0 then
            exit;   // poisoned target — bind already errored

        // 'RecVar := idExpr.GetRecord();' (§ RecordID): SourceNode carries the GetRecord
        // marker set by "ALI Binder".BindGetRecordAssignment. Recompute its receiver
        // structurally (mirrors "ALI Binder".IsGetRecordCall) and emit REC_GET_BY_ID against
        // the target's handle — Conditional always false (throw on miss/wrong table, same as
        // native GetRecord()); the dest bool register is allocated but its value discarded.
        if (OpTok = 40) and (Ast.GetSymbolId(SourceNode) = RecordIdMethodMark() - 1) then begin
            if Ast.GetKind(SourceNode) = "ALI NodeKind"::InvocationExpr then
                IdCalleeNode := Ast.GetChild(SourceNode, 0)
            else
                IdCalleeNode := SourceNode;
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(IdCalleeNode, 0), SrcCls, SrcReg);
            ResCls := "ALI Register Class"::"Boolean";
            ResReg := AllocTemp(ResCls);
            // Handle Lifecycle Unification: REC_GET_BY_ID overwrites the TARGET's existing
            // record content in place (like REC_COPY) — resolve its CURRENT handle generically
            // rather than assuming a literal local slot.
            LoadSymValue(Module, Symbols, Sid, TgtCls, TgtReg);
            Module.AddInstr("ALI Opcode"::REC_GET_BY_ID, TgtReg, SrcReg, ResReg * 2);
            exit;
        end;

        // Variant box/unbox for Record + aggregates (§19.2 reference semantics). Routed here
        // because the AST node's ALI type is known — the generic scalar CONV_BOX path cannot
        // TAG a handle box, and `rec := v` must not fall into REC_COPY below.
        if OpTok = 40 then
            if LowerVariantRefAssign(Tokens, Ast, Symbols, Module, Sid, SourceNode) then
                exit;

        // Record := Record (value semantics, §7.5) -> REC_COPY of handles. REC_COPY mutates
        // the TARGET's existing record content in place (it never rebinds the handle
        // register), so both sides are resolved as ordinary READS (LoadSymValue/LowerExpr —
        // Handle Lifecycle Unification: same generic local/global/var-param resolution every
        // other handle-kind receiver uses), never stored back via StoreToSym.
        if (OpTok = 40) and (Symbols.GetType(Sid) = "ALI TypeKind"::Record) then begin
            LoadSymValue(Module, Symbols, Sid, TgtCls, TgtReg);
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            Module.AddInstr("ALI Opcode"::REC_COPY, TgtReg, SrcReg, 0);
            exit;
        end;

        // Handle Lifecycle Unification (Phase 5): `arrayVar := ProcCall()` -> ARR_REBIND, NOT
        // a plain register MOV — the target already owns an ARR_NEW-allocated block from this
        // proc's entry that must be freed, not silently overwritten (the binder guarantees Sid
        // is a LOCAL array var, so its slot is frame-relative and its old handle is always
        // frame-tracked).
        if (OpTok = 40) and (Symbols.GetType(Sid) = "ALI TypeKind"::Array) then begin
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            Module.AddInstr("ALI Opcode"::ARR_REBIND, Symbols.GetSlot(Sid), SrcReg, 0);
            exit;
        end;

        if OpTok = 40 then begin    // :=
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            StoreToSym(Module, Symbols, Sid, SrcCls, SrcReg);
            exit;
        end;

        // Compound: target := target <op> source through the SAME matrix path (§6.4).
        Group := CompoundOpGroup(OpTok);
        OpT := TypeRules.ResultType(Group, Symbols.GetType(Sid), Ast.GetTypeOrd(SourceNode));
        LoadSymValue(Module, Symbols, Sid, TgtCls, TgtReg);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        EmitBinaryFromParts(Module, Group, OpT,
            Symbols.GetType(Sid), TgtCls, TgtReg,
            Ast.GetTypeOrd(SourceNode), SrcCls, SrcReg,
            ResCls, ResReg);
        StoreToSym(Module, Symbols, Sid, ResCls, ResReg);
    end;

    // Executable expression-statements: bound Error(msg) (SymbolId = -1 -> ERROR_RAISE)
    // and user procedure calls (SymbolId = proc symbol -> CALL, result discarded).
    local procedure LowerExpressionStatement(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        ArgNode: Integer;
        Cls: Integer;
        InvNode: Integer;
        Reg: Integer;
        Sym: Integer;
        TxtReg: Integer;
    begin
        InvNode := Ast.GetChild(Node, 0);
        // Bare member/record method as a statement (`Tb.AppendLine;` / `Rec.FindSet;` /
        // `id.TableNo;` — no parens): the child is a MemberAccessExpr marked with a method
        // SymbolId. Result discarded. Full mark cascade, MOST-negative mark first (Json -10000
        // placeholder -> Http -9000 -> Dialog -8000 -> RecordId -7000 -> Dict -6000 ->
        // List -5000 -> TB -4000 -> Builtin -3000 -> Stream -2000 -> Rec -1000): a less-negative
        // `<= X` check would wrongly catch a more-negative mark first.
        if Ast.GetKind(InvNode) = "ALI NodeKind"::MemberAccessExpr then begin
            Sym := Ast.GetSymbolId(InvNode);
            // M11 object-procedure call (-500). A SENTINEL, not a range: it is LESS negative
            // than every family mark below, so no `Sym <= X` arm can swallow it — but for the
            // same reason it must be tested explicitly, by equality.
            if Sym = ObjectCallMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerObjectCall(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
                exit;
            end;
            // M11 phase C3: paren-less `MyCU.Run;` as a statement. Result discarded, so a failed
            // run raises — the native contract.
            if Sym = CodeunitRunMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerCodeunitRun(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
                exit;
            end;
            // M11 phase C2: paren-less codeunit-procedure call as a statement (`MyCU.Refresh;`).
            // A POSITIVE SymbolId on a member access can only be this — every other member family
            // marks itself with a negative sentinel — and it lowers as an ordinary call, because a
            // codeunit procedure takes no receiver.
            if Sym > 0 then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerCall(Tokens, Ast, Symbols, Module, InvNode, false, 0, 0, Cls, Reg);
                exit;
            end;
            // FieldRef/KeyRef (-16000) then RecordRef (-15000) then Media (-14000) then
            // BigText/SecretText (-13000) then Xml (-12000): most negative mark wins.
            if Sym <= FieldRefMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerFieldRefMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= RecordRefMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerRecordRefMethod(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
            end else if Sym <= MediaMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerMediaMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= BigTextMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerBigTextMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= XmlMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerXmlMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= BlobMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerBlobMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= JsonMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerJsonMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= HttpMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerHttpMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= DialogMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerDialogMethod(Tokens, Ast, Symbols, Module, InvNode);
            end else if Sym <= RecordIdMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerRecordIdMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= DictMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerDictMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= ListMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerListMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= TextBuilderMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerTextBuilderMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= BuiltinCallMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerBuiltinCall(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= StreamMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerStreamMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else if Sym <= RecMethodMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerRecordMethod(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
            end;
            exit;
        end;
        // Bare NameExpr as a statement: a 0-arg builtin (`SelectLatestVersion;` -> BuiltinCallMark)
        // or a 0-arg user proc (`MyProc;` -> positive proc SymbolId -> CALL). Result discarded.
        // Without this branch the InvocationExpr guard below silently drops it (a NameExpr is
        // neither MemberAccessExpr nor InvocationExpr). Guard `> 0` before Symbols.GetKind.
        if Ast.GetKind(InvNode) = "ALI NodeKind"::NameExpr then begin
            Sym := Ast.GetSymbolId(InvNode);
            if Sym <= BuiltinCallMark() then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerBuiltinCall(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            end else
                if Sym > 0 then
                    if Symbols.GetKind(Sym) = "ALI Symbol Kind"::Proc then begin
                        EmitStmtMarker(Tokens, Ast, Module, Node);
                        LowerCall(Tokens, Ast, Symbols, Module, InvNode, false, 0, 0, Cls, Reg);
                    end;
            exit;
        end;
        if Ast.GetKind(InvNode) <> "ALI NodeKind"::InvocationExpr then
            exit;
        Sym := Ast.GetSymbolId(InvNode);
        if Sym = -1 then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            ArgNode := Ast.GetChild(InvNode, 1);
            LowerExpr(Tokens, Ast, Symbols, Module, ArgNode, Cls, Reg);
            TxtReg := ToTextRegT(Module, Ast.GetTypeOrd(ArgNode), Cls, Reg);
            Module.AddInstr("ALI Opcode"::ERROR_RAISE, TxtReg, 0, 0);
            exit;
        end;
        if Sym > 0 then
            if Symbols.GetKind(Sym) = "ALI Symbol Kind"::Proc then begin
                EmitStmtMarker(Tokens, Ast, Module, Node);
                LowerCall(Tokens, Ast, Symbols, Module, InvNode, false, 0, 0, Cls, Reg);
                exit;
            end;
        // M11 object-procedure call as a statement — sentinel mark, tested by equality.
        if Sym = ObjectCallMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerObjectCall(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
            exit;
        end;
        // M11 phase C3: `Codeunit.Run(...);` / `MyCU.Run(...);` as a statement.
        if Sym = CodeunitRunMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerCodeunitRun(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
            exit;
        end;
        // FieldRef/KeyRef method as a statement (`F.SetRange(1, 9);`, `F.CalcField;`).
        // FieldRefMethodMark(-16000) is the MOST negative mark of all — checked FIRST.
        if Sym <= FieldRefMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerFieldRefMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // RecordRef-only method as a statement (`RRef.Open(18);`, `RRef.Close;`).
        if Sym <= RecordRefMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerRecordRefMethod(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
            exit;
        end;
        // Media field method as a statement (`Rec.Picture.ExportStream(os);`).
        if Sym <= MediaMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerMediaMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // BigText/SecretText method as a statement (AddText/Read/Write; result discarded).
        if Sym <= BigTextMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerBigTextMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // Xml* method as a statement (Feature 3, result discarded). XmlMethodMark(-12000) is
        // the MOST negative mark after Media/BigText — checked next.
        if Sym <= XmlMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerXmlMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // Blob field method as a statement (`Rec.MyBlob.CreateOutStream(os);`).
        // BlobMethodMark(-11000) is the MOST negative mark after Xml — checked next.
        if Sym <= BlobMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerBlobMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // Json* method as a statement (Feature 2). JsonMethodMark(-10000) is the MOST negative
        // mark of all — checked before Http and everything else.
        if Sym <= JsonMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerJsonMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // M10: Http* method as a statement (Get/Post/Clear/etc; result discarded). MUST be
        // checked before every other IMPLEMENTED mark except Json — HttpMethodMark(-9000).
        if Sym <= HttpMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerHttpMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // Dialog method as a statement (Open/Update/Close — always void). MUST be checked
        // before every other mark — DialogMethodMark(-8000) is the MOST negative of all.
        if Sym <= DialogMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerDialogMethod(Tokens, Ast, Symbols, Module, InvNode);
            exit;
        end;
        // RecordID method as a statement (`IdVar.TableNo();` — result discarded, but the
        // native call still runs so a blank-RecordID error still fires). MUST be checked
        // before every other mark — RecordIdMethodMark(-7000) is the MOST negative except Dialog.
        if Sym <= RecordIdMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerRecordIdMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // List/Dictionary method as a statement (Add/Set/Remove/etc; result discarded).
        // MUST be checked before every other mark — DictMethodMark(-6000) and
        // ListMethodMark(-5000) are MORE negative than TextBuilderMethodMark(-4000)
        // (ListDictionaryPlan.md §5.2: DictMethodMark < ListMethodMark < TextBuilderMethodMark).
        if Sym <= DictMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerDictMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        if Sym <= ListMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerListMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // M9: TextBuilder method as a statement (Append/Clear/etc; result discarded). MUST be
        // checked before Builtin/Stream/Rec marks — TextBuilderMethodMark(-4000) is the MOST
        // negative mark, so a less-negative `Sym <= X` check would wrongly catch it first.
        if Sym <= TextBuilderMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerTextBuilderMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // M7: builtin call as a statement (Message/Error/Sleep/etc; result discarded).
        // MUST be checked before Stream/Rec marks — BuiltinCallMark(-3000) is MORE negative
        // than StreamMethodMark(-2000), so `Sym <= StreamMethodMark()` would wrongly catch it.
        if Sym <= BuiltinCallMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerBuiltinCall(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // M6: stream method as a statement (WriteText/WriteLine/Link; result discarded).
        if Sym <= StreamMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerStreamMethod(Tokens, Ast, Symbols, Module, InvNode, Cls, Reg);
            exit;
        end;
        // M6: record method as a statement (result discarded).
        if Sym <= RecMethodMark() then begin
            EmitStmtMarker(Tokens, Ast, Module, Node);
            LowerRecordMethod(Tokens, Ast, Symbols, Module, InvNode, false, Cls, Reg);
        end;
    end;

    local procedure LowerIf(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        CondCls: Integer;
        CondReg: Integer;
        ElseNode: Integer;
        JumpEndPC: Integer;
        JumpFalsePC: Integer;
    begin
        EmitStmtMarker(Tokens, Ast, Module, Node);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), CondCls, CondReg);
        JumpFalsePC := EmitCondBranch(Module, false, CondReg);
        LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1));
        ElseNode := Ast.GetChild(Node, 2);
        if Ast.IsMissing(ElseNode) then
            Module.PatchA(JumpFalsePC, Module.NextPC())
        else begin
            JumpEndPC := Module.AddInstr("ALI Opcode"::JMP, 0, 0, 0);
            Module.PatchA(JumpFalsePC, Module.NextPC());
            LowerStatement(Tokens, Ast, Symbols, Module, ElseNode);
            Module.PatchA(JumpEndPC, Module.NextPC());
        end;
    end;

    local procedure LowerWhile(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        CondCls: Integer;
        CondReg: Integer;
        JumpFalsePC: Integer;
        LoopStart: Integer;
    begin
        LoopStart := Module.NextPC();
        // Loop-head marker: iterations are budget-charged by the backward jump (P1).
        EmitStmtMarker(Tokens, Ast, Module, Node);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), CondCls, CondReg);
        JumpFalsePC := EmitCondBranch(Module, false, CondReg);
        PushLoop();
        LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1));
        Module.AddInstr("ALI Opcode"::JMP, LoopStart, 0, 0);
        Module.PatchA(JumpFalsePC, Module.NextPC());
        PopLoop(Module, Module.NextPC());
    end;

    // Repeat children: stmt* then untilCond LAST; ExtraInt = body count (§5.5).
    local procedure LowerRepeat(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        BodyCount: Integer;
        CondCls: Integer;
        CondReg: Integer;
        i: Integer;
        LoopStart: Integer;
    begin
        BodyCount := Ast.GetExtra(Node);
        LoopStart := Module.NextPC();
        EmitStmtMarker(Tokens, Ast, Module, Node);      // per-iteration count (§7.4)
        PushLoop();
        for i := 0 to BodyCount - 1 do
            LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, i));
        ResetTemps();                                   // until-cond is its own temp scope
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, BodyCount), CondCls, CondReg);
        Module.PatchA(EmitCondBranch(Module, false, CondReg), LoopStart);   // until FALSE -> loop again
        PopLoop(Module, Module.NextPC());
    end;

    // For children: [0]=loopVar, [1]=init, [2]=end, [3]=body; ExtraInt bit0 = downto;
    // node SlotIndex = hidden limit slot (binder). Bounds evaluated ONCE (§5.3). The
    // binder guarantees the control var is frame-local (no var-param/global control vars).
    local procedure LowerFor(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        IsDownTo: Boolean;
        BodyStart: Integer;
        Cls: Integer;
        InitPC: Integer;
        LimitSlot: Integer;
        LoopEnd: Integer;
        Reg: Integer;
        Sid: Integer;
        VarSlot: Integer;
        VarT: Integer;
    begin
        Sid := Ast.GetSymbolId(Ast.GetChild(Node, 0));
        if Sid <= 0 then
            exit;
        VarT := Symbols.GetType(Sid);
        VarSlot := Symbols.GetSlot(Sid);
        LimitSlot := Ast.GetSlotIndex(Node);
        IsDownTo := (Ast.GetExtra(Node) mod 2) = 1;

        EmitStmtMarker(Tokens, Ast, Module, Node);
        // init -> loop var
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
        Reg := ConvertToType(Module, Cls, Reg, VarT);
        Module.AddInstr("ALI Opcode"::MOV_I, VarSlot, Reg, 0);
        // end bound -> dedicated limit slot, ONCE (§5.3, pitfall 17)
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
        Reg := ConvertToType(Module, Cls, Reg, VarT);
        Module.AddInstr("ALI Opcode"::MOV_I, LimitSlot, Reg, 0);

        if IsDownTo then
            InitPC := Module.AddInstr("ALI Opcode"::FOR_INIT_DOWN, VarSlot, LimitSlot, 0)
        else
            InitPC := Module.AddInstr("ALI Opcode"::FOR_INIT_UP, VarSlot, LimitSlot, 0);

        BodyStart := Module.NextPC();
        PushLoop();
        LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 3));
        if IsDownTo then
            Module.AddInstr("ALI Opcode"::FOR_NEXT_DOWN, VarSlot, LimitSlot, BodyStart)
        else
            Module.AddInstr("ALI Opcode"::FOR_NEXT_UP, VarSlot, LimitSlot, BodyStart);
        LoopEnd := Module.NextPC();
        Module.PatchC(InitPC, LoopEnd);
        PopLoop(Module, LoopEnd);
    end;

    // ForEach children: [0]=loopVar, [1]=collection, [2]=body; ExtraInt = collection
    // TypeKind ordinal (binder); node SlotIndex = base of 3 hidden Int slots
    // (index / limit / handle). No dedicated opcodes: desugars onto the FOR_INIT_UP/
    // FOR_NEXT_UP machinery — the collection expression is evaluated ONCE into the hidden
    // handle slot (§5.3-analog), then each iteration fetches the current element into the
    // loop var (LIST_GET for List, 1-based; JSON_METHOD ArrGet for JsonArray, 0-based —
    // ArrGet rebinds the loop var's EXISTING token handle, so the var's register is stable).
    local procedure LowerForEach(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        BodyStart: Integer;
        BoolReg: Integer;
        Cls: Integer;
        CntReg: Integer;
        CollT: Integer;
        HandleSlot: Integer;
        IdxSlot: Integer;
        InitPC: Integer;
        LimitSlot: Integer;
        LoopEnd: Integer;
        OperStart: Integer;
        OutCls: Integer;
        OutReg: Integer;
        Reg: Integer;
        VarSid: Integer;
    begin
        VarSid := Ast.GetSymbolId(Ast.GetChild(Node, 0));
        if VarSid <= 0 then
            exit;
        CollT := Ast.GetExtra(Node);
        if not (CollT in ["ALI TypeKind"::List.AsInteger(), "ALI TypeKind"::JsonArray.AsInteger(),
                          "ALI TypeKind"::XmlNodeList.AsInteger(), "ALI TypeKind"::XmlAttributeCollection.AsInteger()]) then
            exit;   // poisoned collection — bind already errored
        IdxSlot := Ast.GetSlotIndex(Node);
        LimitSlot := IdxSlot + 1;
        HandleSlot := IdxSlot + 2;

        EmitStmtMarker(Tokens, Ast, Module, Node);
        // collection handle -> hidden slot, ONCE
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
        Module.AddInstr("ALI Opcode"::MOV_I, HandleSlot, Reg, 0);

        CntReg := AllocTemp("ALI Register Class"::Int);
        case CollT of
            "ALI TypeKind"::JsonArray.AsInteger():
                begin
                    OperStart := Module.OperandCount() + 1;
                    Module.AddInstr("ALI Opcode"::JSON_METHOD, HandleSlot, OperStart, CntReg * 100000 + "ALI Register Class"::Int * 10000 + 38 * 100 + 0);   // Count()
                    Module.AddInstr("ALI Opcode"::SUB_I_IMM, LimitSlot, CntReg, 1);       // 0-based: 0..Count-1
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, IdxSlot, Module.AddConstInt(0), 0);
                end;
            "ALI TypeKind"::XmlNodeList.AsInteger(), "ALI TypeKind"::XmlAttributeCollection.AsInteger():
                begin
                    // XML_DESIGN.md §9: List-arm SHAPE, NATIVE 1-BASED. Count via XML_METHOD2
                    // packed 23 (NodeList, actual 123) / 27 (AttrCol, actual 127), 0 args.
                    if CollT = "ALI TypeKind"::XmlNodeList.AsInteger() then
                        Cls := 23
                    else
                        Cls := 27;      // reuse Cls as the packed method id (no operand class needed here)
                    OperStart := Module.OperandCount() + 1;
                    Module.AddInstr("ALI Opcode"::XML_METHOD2, HandleSlot, OperStart, CntReg * 100000 + "ALI Register Class"::Int * 10000 + Cls * 100 + 0);   // Count()
                    Module.AddInstr("ALI Opcode"::MOV_I, LimitSlot, CntReg, 0);           // 1-based: 1..Count
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, IdxSlot, Module.AddConstInt(1), 0);
                end;
            else begin
                OperStart := Module.OperandCount() + 1;
                Module.AddInstr("ALI Opcode"::LIST_COUNT, HandleSlot, OperStart, CntReg * 100 + 0);
                Module.AddInstr("ALI Opcode"::MOV_I, LimitSlot, CntReg, 0);           // 1-based: 1..Count
                Module.AddInstr("ALI Opcode"::LOAD_CONST_I, IdxSlot, Module.AddConstInt(1), 0);
            end;
        end;

        InitPC := Module.AddInstr("ALI Opcode"::FOR_INIT_UP, IdxSlot, LimitSlot, 0);
        BodyStart := Module.NextPC();
        PushLoop();
        // per-iteration element fetch -> loop var (own temp scope, reset each iteration)
        ResetTemps();
        if CollT = "ALI TypeKind"::JsonArray.AsInteger() then begin
            OperStart := Module.OperandCount() + 1;
            Module.AddOperand(IdxSlot * 16 + "ALI Register Class"::Int);
            Module.AddOperand(Symbols.GetSlot(VarSid) * 16 + "ALI Register Class"::Int);
            BoolReg := AllocTemp("ALI Register Class"::"Boolean");
            Module.AddInstr("ALI Opcode"::JSON_METHOD, HandleSlot, OperStart, BoolReg * 100000 + "ALI Register Class"::"Boolean" * 10000 + 34 * 100 + 2);   // Get(idx, var tok); bool discarded
        end else if CollT in ["ALI TypeKind"::XmlNodeList.AsInteger(), "ALI TypeKind"::XmlAttributeCollection.AsInteger()] then begin
            // Get via XML_METHOD2 packed 24 (NodeList.Get, actual 124) / 28 (AttrCol.Get,
            // actual 128) — REBINDS the loop var's existing bank handle (§9, ArrGet convention).
            if CollT = "ALI TypeKind"::XmlNodeList.AsInteger() then
                Cls := 24
            else
                Cls := 28;
            OperStart := Module.OperandCount() + 1;
            Module.AddOperand(IdxSlot * 16 + "ALI Register Class"::Int);
            Module.AddOperand(Symbols.GetSlot(VarSid) * 16 + "ALI Register Class"::Int);
            BoolReg := AllocTemp("ALI Register Class"::"Boolean");
            Module.AddInstr("ALI Opcode"::XML_METHOD2, HandleSlot, OperStart, BoolReg * 100000 + "ALI Register Class"::"Boolean" * 10000 + Cls * 100 + 2);   // Get(idx, var node/attr); bool discarded
        end else begin
            OutCls := TypeRules.RegClassFor(Symbols.GetType(VarSid));
            OperStart := Module.OperandCount() + 1;
            Module.AddOperand(IdxSlot * 16 + "ALI Register Class"::Int);
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::LIST_GET, HandleSlot, OperStart, OutReg * 100 + 1);
            StoreToSym(Module, Symbols, VarSid, OutCls, OutReg);
        end;
        LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2));
        Module.AddInstr("ALI Opcode"::FOR_NEXT_UP, IdxSlot, LimitSlot, BodyStart);
        LoopEnd := Module.NextPC();
        Module.PatchC(InitPC, LoopEnd);
        PopLoop(Module, LoopEnd);
    end;

    // Case children: [0]=selector, caseLine*, caseElse|Missing LAST; lowered to
    // compare-chains (§7.3 — no table jump in AL). Layout per line:
    //   tests -> JMP_IF_TRUE body / JMP next-line ; body ; JMP end ; next-line: ...
    local procedure LowerCase(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        BoolReg: Integer;
        ElseNode: Integer;
        i: Integer;
        j: Integer;
        LabelCount: Integer;
        LineCount: Integer;
        LineNode: Integer;
        PatchPC: Integer;
        SavedFloor: Integer;
        SelCls: Integer;
        SelReg: Integer;
        SelT: Integer;
        SkipPC: Integer;
        EndPCs: List of [Integer];
        HitPCs: List of [Integer];
    begin
        EmitStmtMarker(Tokens, Ast, Module, Node);
        SelT := Ast.GetTypeOrd(Ast.GetChild(Node, 0));
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), SelCls, SelReg);
        LineCount := Ast.GetExtra(Node);

        // Pin the selector register across the case (§7.2 selector caching) — see M4 note.
        SavedFloor := 0;
        if (SelCls > 0) and (SelCls <= TypeRules.RegClassCount()) then begin
            SavedFloor := TempFloor[SelCls];
            if TempCount[SelCls] > TempFloor[SelCls] then
                TempFloor[SelCls] := TempCount[SelCls];
        end;

        for i := 1 to LineCount do begin
            LineNode := Ast.GetChild(Node, i);
            LabelCount := Ast.GetExtra(LineNode);
            Clear(HitPCs);
            for j := 0 to LabelCount - 1 do begin
                BoolReg := EmitCaseTest(Tokens, Ast, Symbols, Module, Ast.GetChild(LineNode, j), SelT, SelCls, SelReg);
                HitPCs.Add(EmitCondBranch(Module, true, BoolReg));
            end;
            SkipPC := Module.AddInstr("ALI Opcode"::JMP, 0, 0, 0);        // no label matched -> next line
            foreach PatchPC in HitPCs do
                Module.PatchA(PatchPC, Module.NextPC());
            LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(LineNode, LabelCount));
            EndPCs.Add(Module.AddInstr("ALI Opcode"::JMP, 0, 0, 0));
            Module.PatchA(SkipPC, Module.NextPC());
        end;

        ElseNode := Ast.GetChild(Node, LineCount + 1);
        if not Ast.IsMissing(ElseNode) then
            for j := 0 to Ast.GetChildCount(ElseNode) - 1 do
                LowerStatement(Tokens, Ast, Symbols, Module, Ast.GetChild(ElseNode, j));

        foreach PatchPC in EndPCs do
            Module.PatchA(PatchPC, Module.NextPC());

        // Unpin the selector — subsequent statements get the full temp file again.
        if (SelCls > 0) and (SelCls <= TypeRules.RegClassCount()) then
            TempFloor[SelCls] := SavedFloor;
    end;

    // One case-label test -> Bool register. Plain label: sel = label. Range label:
    // (sel >= lo) and (sel <= hi) — both compares emitted, AND_B fused.
    local procedure EmitCaseTest(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; LabelNode: Integer; SelT: Integer; SelCls: Integer; SelReg: Integer): Integer
    var
        BoolReg1: Integer;
        BoolReg2: Integer;
        CmpCls: Integer;
        CmpT: Integer;
        HiCls: Integer;
        HiReg: Integer;
        LoCls: Integer;
        LoReg: Integer;
        OutReg: Integer;
        SelConv: Integer;
    begin
        if Ast.GetKind(LabelNode) = "ALI NodeKind"::RangeExpr then begin
            CmpT := CommonCompareType(SelT, Ast.GetTypeOrd(Ast.GetChild(LabelNode, 0)));
            CmpCls := TypeRules.RegClassFor(CmpT);
            SelConv := ConvertToType(Module, SelCls, SelReg, CmpT);
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(LabelNode, 0), LoCls, LoReg);
            LoReg := ConvertToType(Module, LoCls, LoReg, CmpT);
            BoolReg1 := AllocTemp("ALI Register Class"::"Boolean");
            if CmpCls = "ALI Register Class"::Int then
                EmitCmpIntFused(Module, "ALI Op Group"::Ge, BoolReg1, SelConv, LoReg, false)
            else
                Module.AddInstr(CmpOpcode(CmpCls, "ALI Op Group"::Ge), BoolReg1, SelConv, LoReg);
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(LabelNode, 1), HiCls, HiReg);
            HiReg := ConvertToType(Module, HiCls, HiReg, CmpT);
            BoolReg2 := AllocTemp("ALI Register Class"::"Boolean");
            if CmpCls = "ALI Register Class"::Int then
                EmitCmpIntFused(Module, "ALI Op Group"::Le, BoolReg2, SelConv, HiReg, false)
            else
                Module.AddInstr(CmpOpcode(CmpCls, "ALI Op Group"::Le), BoolReg2, SelConv, HiReg);
            OutReg := AllocTemp("ALI Register Class"::"Boolean");
            Module.AddInstr("ALI Opcode"::AND_B, OutReg, BoolReg1, BoolReg2);
            exit(OutReg);
        end;
        CmpT := CommonCompareType(SelT, Ast.GetTypeOrd(LabelNode));
        CmpCls := TypeRules.RegClassFor(CmpT);
        SelConv := ConvertToType(Module, SelCls, SelReg, CmpT);
        LowerExpr(Tokens, Ast, Symbols, Module, LabelNode, LoCls, LoReg);
        LoReg := ConvertToType(Module, LoCls, LoReg, CmpT);
        OutReg := AllocTemp("ALI Register Class"::"Boolean");
        if CmpCls = "ALI Register Class"::Int then
            EmitCmpIntFused(Module, "ALI Op Group"::Eq, OutReg, SelConv, LoReg, false)
        else
            Module.AddInstr(CmpOpcode(CmpCls, "ALI Op Group"::Eq), OutReg, SelConv, LoReg);
        exit(OutReg);
    end;

    // `Expr in [item, lo..hi, ...]` -> OR-chain of per-item tests, each item reusing the
    // case-label test emitter (EmitCaseTest: value -> eq, range -> fused >=/<= AND_B). The
    // tested expression lowers ONCE and its register is reused across all items — safe
    // without TempFloor pinning because temps are never recycled inside a single statement
    // (ResetTemps only runs at statement boundaries, and an in-list holds no statements).
    // AL `in` has no short-circuit natively; every item is evaluated, matching eager AL.
    local procedure LowerInList(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        AccReg: Integer;
        BoolReg: Integer;
        i: Integer;
        ItemCount: Integer;
        SelCls: Integer;
        SelReg: Integer;
        SelT: Integer;
    begin
        SelT := Ast.GetTypeOrd(Ast.GetChild(Node, 0));
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), SelCls, SelReg);
        ItemCount := Ast.GetExtra(Node);
        AccReg := 0;
        for i := 1 to ItemCount do begin
            BoolReg := EmitCaseTest(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, i), SelT, SelCls, SelReg);
            if AccReg = 0 then
                AccReg := BoolReg
            else
                Module.AddInstr("ALI Opcode"::OR_B, AccReg, AccReg, BoolReg);
        end;
        OutCls := "ALI Register Class"::"Boolean";
        OutReg := AccReg;
    end;

    // exit / exit(value): the value goes to the CURRENT proc's result slot (frame-local),
    // then RET_VAL (with value) / RET (bare) pops the frame — entry frame halts (§7.4).
    local procedure LowerExit(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        Cls: Integer;
        Reg: Integer;
        ValueNode: Integer;
    begin
        EmitStmtMarker(Tokens, Ast, Module, Node);
        ValueNode := Ast.GetChild(Node, 0);
        if (not Ast.IsMissing(ValueNode)) and (ResultSlot > 0) then begin
            // §19.2: exit(rec/list/dict/array) from a Variant-returning proc boxes by reference
            // (tagged); every other result goes through the generic scalar CONV path.
            if (ResultTypeOrd = "ALI TypeKind"::Variant) and IsRefBoxType(Ast.GetTypeOrd(ValueNode)) then
                Reg := BoxRefIntoVariantTemp(Tokens, Ast, Symbols, Module, ValueNode, Ast.GetTypeOrd(ValueNode))
            else begin
                LowerExpr(Tokens, Ast, Symbols, Module, ValueNode, Cls, Reg);
                Reg := ConvertToType(Module, Cls, Reg, ResultTypeOrd);
            end;
            Module.AddInstr(MovOpcode(ResultClass), ResultSlot, Reg, 0);
            Module.AddInstr("ALI Opcode"::RET_VAL, 0, 0, 0);
        end else
            Module.AddInstr("ALI Opcode"::RET, 0, 0, 0);
    end;

    // ===== Expressions =====

    // Lower an expression; returns its register class and register index. NameExpr of a
    // frame-local returns the variable slot DIRECTLY (no copy); var params and globals
    // load through LOAD_IND / GLOB_LOAD into fresh temps.
    local procedure LowerExpr(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        K: Integer;
        Sid: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        K := Ast.GetKind(Node);
        Sid := Ast.GetSymbolId(Node);   // dispatch marker or symbol id — read once (mark cascade below re-checks it up to 11x)
        case true of
            (K = "ALI NodeKind"::LiteralExpr):
                LowerLiteral(Tokens, Ast, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::NameExpr):
                // A bare 0-arg builtin call (e.g. `Today` without parens) is marked with a
                // builtin-call SymbolId by the binder; a bare 0-arg user proc (`x := MyFunc`) is
                // marked with the positive proc SymbolId -> CALL; otherwise it's a plain variable
                // read. Guard `> 0` before Symbols.GetKind — marks are negative (eager eval would
                // misread a mark as a symbol id).
                if Sid <= BuiltinCallMark() then
                    LowerBuiltinCall(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                else
                    // M11 phase B2: a paren-less SIBLING call inside a harvested CODEUNIT that
                    // declares globals (`x := Bonus`). It keeps its NameExpr shape — there is no
                    // receiver to attach, only the hidden instance index LowerObjectCall
                    // forwards — so the mark has to be caught here as well as on the member and
                    // invocation arms. Sentinel, tested by equality.
                    if Sid = ObjectCallMark() then
                        LowerObjectCall(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                    else
                        if Sid > 0 then begin
                            if Symbols.GetKind(Sid) = "ALI Symbol Kind"::Proc then
                                LowerCall(Tokens, Ast, Symbols, Module, Node, true, 0, 0, OutCls, OutReg)
                            else
                                LoadSymValue(Module, Symbols, Sid, OutCls, OutReg);
                        end else
                            LoadSymValue(Module, Symbols, Sid, OutCls, OutReg);
            (K = "ALI NodeKind"::UnaryExpr):
                LowerUnary(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::BinaryExpr):
                LowerBinary(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::InListExpr):
                LowerInList(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::InvocationExpr):
                if Sid > 0 then
                    LowerCall(Tokens, Ast, Symbols, Module, Node, true, 0, 0, OutCls, OutReg)
                else
                    if Sid = ObjectCallMark() then
                        // M11 object-procedure call — sentinel mark, tested by equality; the
                        // `Sid <= X` family cascade below could never match -500 anyway.
                        LowerObjectCall(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                    else
                    if Sid = CodeunitRunMark() then      // M11 phase C3 — `ok := Codeunit.Run(...)`
                        LowerCodeunitRun(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                    else
                        // FieldRef/KeyRef(-16000) checked FIRST — most negative mark — then
                        // RecordRef(-15000), Media (-14000), BigText/Secret(-13000),
                        // Xml(-12000), Blob(-11000), Json(-10000), HttpMethodMark(-9000),
                        // RecordIdMethodMark(-7000), DictMethodMark(-6000),
                        // ListMethodMark(-5000), TextBuilderMethodMark(-4000).
                        if Sid <= FieldRefMethodMark() then
                            LowerFieldRefMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                        else
                        if Sid <= RecordRefMethodMark() then
                            LowerRecordRefMethod(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                        else
                        if Sid <= MediaMethodMark() then
                            LowerMediaMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                        else
                            if Sid <= BigTextMethodMark() then
                                LowerBigTextMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                            else
                                if Sid <= XmlMethodMark() then
                                    LowerXmlMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                else
                                    if Sid <= BlobMethodMark() then
                                        LowerBlobMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                    else
                                        if Sid <= JsonMethodMark() then
                                            LowerJsonMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                        else
                                            if Sid <= HttpMethodMark() then
                                                LowerHttpMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                            else
                                                if Sid <= RecordIdMethodMark() then
                                                    LowerRecordIdMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                else
                                                    if Sid <= DictMethodMark() then
                                                        LowerDictMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                    else
                                                        if Sid <= ListMethodMark() then
                                                            LowerListMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                        else
                                                            if Sid <= TextBuilderMethodMark() then
                                                                LowerTextBuilderMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                            else
                                                                // BuiltinCallMark(-3000) checked next — more negative than Stream(-2000).
                                                                if Sid <= BuiltinCallMark() then
                                                                    LowerBuiltinCall(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                                else
                                                                    if Sid <= StreamMethodMark() then
                                                                        LowerStreamMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                                    else
                                                                        if Sid <= RecMethodMark() then
                                                                            LowerRecordMethod(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg);
            (K = "ALI NodeKind"::MemberAccessExpr):
                // A bare member method without parens (`x := Tb.Length`, `n := L.Count`,
                // `x := Resp.HttpStatusCode`, `Rec.FindSet`, `id.TableNo`) is marked with the
                // matching method SymbolId; full mark cascade MOST-negative first (Xml -12000 ->
                // Blob -11000 -> Json -10000 -> Http -> RecordId -> Dict -> List -> TB -> Builtin
                // -> Stream -> Rec), same ordering as the InvocationExpr branch above; else a
                // plain field read.
                if Sid = ObjectCallMark() then       // M11 paren-less object-procedure call
                    LowerObjectCall(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                else
                if Sid = CodeunitRunMark() then      // M11 phase C3 — `ok := MyCU.Run`
                    LowerCodeunitRun(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                else
                    // M11 phase C2: paren-less codeunit-procedure call as a VALUE (`x := MyCU.Total`).
                    // A positive SymbolId on a member access is only ever this — the other families
                    // all mark themselves negative — and it is an ordinary receiver-less call.
                    if Sid > 0 then
                        LowerCall(Tokens, Ast, Symbols, Module, Node, true, 0, 0, OutCls, OutReg)
                    else
                        // FieldRef/KeyRef(-16000) is the most negative mark — checked first here
                        // too, then RecordRef(-15000).
                        if Sid <= FieldRefMethodMark() then
                            LowerFieldRefMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                        else
                        if Sid <= RecordRefMethodMark() then
                            LowerRecordRefMethod(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                        else
                        if Sid <= MediaMethodMark() then
                            LowerMediaMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                        else
                            if Sid <= BigTextMethodMark() then
                                LowerBigTextMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                            else
                                if Sid <= XmlMethodMark() then
                                    LowerXmlMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                else
                                    if Sid <= BlobMethodMark() then
                                        LowerBlobMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                    else
                                        if Sid <= JsonMethodMark() then
                                            LowerJsonMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                        else
                                            if Sid <= HttpMethodMark() then
                                                LowerHttpMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                            else
                                                if Sid <= RecordIdMethodMark() then
                                                    LowerRecordIdMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                else
                                                    if Sid <= DictMethodMark() then
                                                        LowerDictMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                    else
                                                        if Sid <= ListMethodMark() then
                                                            LowerListMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                        else
                                                            if Sid <= TextBuilderMethodMark() then
                                                                LowerTextBuilderMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                            else
                                                                if Sid <= BuiltinCallMark() then
                                                                    LowerBuiltinCall(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                                else
                                                                    if Sid <= StreamMethodMark() then
                                                                        LowerStreamMethod(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                                                                    else
                                                                        if Sid <= RecMethodMark() then
                                                                            LowerRecordMethod(Tokens, Ast, Symbols, Module, Node, true, OutCls, OutReg)
                                                                        else
                                                                            LowerFieldLoad(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::IndexExpr):
                // The receiver's TypeOrd (bind-time annotation) tells array vs Text/Code apart
                // — NOT Symbols.GetType(GetSymbolId(child0)), which only resolves for a plain
                // NameExpr receiver; Text/Code indexing now also allows a general expression
                // receiver (e.g. `Format(1+2)[1]`, §19.4), whose child0 SymbolId is a lowerer
                // dispatch marker, not a Symbol Table id.
                if Ast.GetTypeOrd(Ast.GetChild(Node, 0)) = "ALI TypeKind"::Array then
                    LowerArrayLoad(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg)
                else
                    LowerTextIndexLoad(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            (K = "ALI NodeKind"::OptionAccessExpr):
                begin
                    // §19.6: `::` object-id — folded to a compile-time Int constant at bind
                    // time (Ast.SlotIndex = resolved object id).
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OutReg, Module.AddConstInt(Ast.GetSlotIndex(Node)), 0);
                end;
            else
                ;   // poisoned/unsupported — bind already errored; emit nothing
        end;
    end;

    local procedure LowerLiteral(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        Ch: Char;
        CharCode: Integer;
        PoolIdx: Integer;
        TokKind: Integer;
        LitText: Text;
    begin
        TokKind := Tokens.GetKind(Ast.GetMainToken(Node));
        PoolIdx := Ast.GetExtra(Node);      // token-table pool index (parser stored it)
        case TokKind of
            10: // Int32
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OutReg, Module.AddConstInt(Tokens.GetInt(PoolIdx)), 0);
                end;
            11: // Int64 / BigInteger
                begin
                    OutCls := "ALI Register Class"::BigInt;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_BIG, OutReg, Module.AddConstBig(Tokens.GetBigInt(PoolIdx)), 0);
                end;
            12: // Decimal
                begin
                    OutCls := "ALI Register Class"::"Decimal";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_D, OutReg, Module.AddConstDec(Tokens.GetDec(PoolIdx)), 0);
                end;
            13: // Date
                begin
                    OutCls := "ALI Register Class"::"Date";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_DATE, OutReg, Module.AddConstDate(Tokens.GetDate(PoolIdx)), 0);
                end;
            14: // Time
                begin
                    OutCls := "ALI Register Class"::"Time";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_TIME, OutReg, Module.AddConstTime(Tokens.GetTime(PoolIdx)), 0);
                end;
            15: // DateTime
                begin
                    OutCls := "ALI Register Class"::"DateTime";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_DT, OutReg, Module.AddConstDT(Tokens.GetDateTime(PoolIdx)), 0);
                end;
            16: // String
                if Ast.GetTypeOrd(Node) = "ALI TypeKind"::Char then begin
                    // 1-char literal retyped Char by the binder (`Txt[i] - 'a'`): fold to its code.
                    LitText := Tokens.GetText(PoolIdx);
                    Ch := LitText[1];
                    CharCode := Ch;     // assign, don't pass Ch as Integer arg: runtime can't cast Char->Int32 there
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OutReg, Module.AddConstInt(CharCode), 0);
                end else begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_T, OutReg, Module.AddConstText(Tokens.GetText(PoolIdx)), 0);
                end;
            21: // true
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_B, OutReg, 1, 0);
                end;
            22: // false
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_B, OutReg, 0, 0);
                end;
        end;
    end;

    local procedure LowerUnary(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        Cls: Integer;
        OpTok: Integer;
        R: Integer;
        Reg: Integer;
    begin
        OpTok := Ast.GetExtra(Node);
        R := Ast.GetTypeOrd(Node);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), Cls, Reg);
        case OpTok of
            63: // not
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::NOT_B, OutReg, Reg, 0);
                end;
            31: // unary -
                begin
                    Reg := ConvertToType(Module, Cls, Reg, R);
                    OutCls := TypeRules.RegClassFor(R);
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr(NegOpcode(OutCls), OutReg, Reg, 0);
                end;
            30: // unary +
                begin
                    OutReg := ConvertToType(Module, Cls, Reg, R);
                    OutCls := TypeRules.RegClassFor(R);
                end;
        end;
    end;

    local procedure LowerBinary(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        CmpT: Integer;
        Group: Integer;
        LCls: Integer;
        LeftNode: Integer;
        LReg: Integer;
        LT: Integer;
        R: Integer;
        RCls: Integer;
        RightNode: Integer;
        RReg: Integer;
        RT: Integer;
    begin
        Group := TypeRules.OpGroupFromToken(Ast.GetExtra(Node));
        R := Ast.GetTypeOrd(Node);
        LeftNode := Ast.GetChild(Node, 0);
        RightNode := Ast.GetChild(Node, 1);
        LT := Ast.GetTypeOrd(LeftNode);
        RT := Ast.GetTypeOrd(RightNode);

        // Text-concat chain fusion (§7.3 pitfall 9) — one CONCAT_N per `a + b + c + ...`.
        if (Group = "ALI Op Group"::"Add") and (R = "ALI TypeKind"::Text) then begin
            LowerConcatChain(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg);
            exit;
        end;

        // Comparisons -> Bool register.
        if (Group >= "ALI Op Group"::Eq) and (Group <= "ALI Op Group"::Ge) then begin
            CmpT := CommonCompareType(LT, RT);
            LowerExpr(Tokens, Ast, Symbols, Module, LeftNode, LCls, LReg);
            LowerExpr(Tokens, Ast, Symbols, Module, RightNode, RCls, RReg);
            // Text-common comparisons route through ToTextRegT (not the plain numeric
            // ConvertToType) so a Char operand (e.g. `Text[i] <> 'A'`) widens to its
            // PRINTABLE character rather than being read as a mismatched register class.
            if CmpT = "ALI TypeKind"::Text then begin
                LReg := ToTextRegT(Module, LT, LCls, LReg);
                RReg := ToTextRegT(Module, RT, RCls, RReg);
            end else begin
                LReg := ConvertToType(Module, LCls, LReg, CmpT);
                RReg := ConvertToType(Module, RCls, RReg, CmpT);
            end;
            OutCls := "ALI Register Class"::"Boolean";
            OutReg := AllocTemp(OutCls);
            if TypeRules.RegClassFor(CmpT) = "ALI Register Class"::Int then
                EmitCmpIntFused(Module, Group, OutReg, LReg, RReg, true)
            else
                Module.AddInstr(CmpOpcode(TypeRules.RegClassFor(CmpT), Group), OutReg, LReg, RReg);
            exit;
        end;

        // Logical — BOTH operands lowered unconditionally (§15 pitfall 2: no short-circuit).
        if (Group = "ALI Op Group"::"And") or (Group = "ALI Op Group"::"Or") or (Group = "ALI Op Group"::"Xor") then begin
            LowerExpr(Tokens, Ast, Symbols, Module, LeftNode, LCls, LReg);
            LowerExpr(Tokens, Ast, Symbols, Module, RightNode, RCls, RReg);
            OutCls := "ALI Register Class"::"Boolean";
            OutReg := AllocTemp(OutCls);
            case true of
                (Group = "ALI Op Group"::"And"):
                    Module.AddInstr("ALI Opcode"::AND_B, OutReg, LReg, RReg);
                (Group = "ALI Op Group"::"Or"):
                    Module.AddInstr("ALI Opcode"::OR_B, OutReg, LReg, RReg);
                else
                    Module.AddInstr("ALI Opcode"::XOR_B, OutReg, LReg, RReg);
            end;
            exit;
        end;

        // Arithmetic (incl. date/time forms).
        LowerExpr(Tokens, Ast, Symbols, Module, LeftNode, LCls, LReg);
        LowerExpr(Tokens, Ast, Symbols, Module, RightNode, RCls, RReg);
        EmitBinaryFromParts(Module, Group, R, LT, LCls, LReg, RT, RCls, RReg, OutCls, OutReg);
    end;

    // Arithmetic/concat emission shared by binary expressions and compound assignment.
    local procedure EmitBinaryFromParts(var Module: Codeunit "ALI Module"; Group: Integer; R: Integer; LT: Integer; LCls: Integer; LReg: Integer; RT: Integer; RCls: Integer; RReg: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        IsAdd: Boolean;
    begin
        OutCls := 0;
        OutReg := 0;
        IsAdd := Group = "ALI Op Group"::"Add";

        // Text concat (binary form; chains are fused earlier). Also reached by the compound
        // `+=` path (§6.4) — ToTextRegT (not the plain ToTextReg) so a Char operand (e.g.
        // `Txt += Txt[1]`) concatenates its PRINTABLE character, not its numeric ordinal.
        if (R = "ALI TypeKind"::Text) and IsAdd then begin
            LReg := ToTextRegT(Module, LT, LCls, LReg);
            RReg := ToTextRegT(Module, RT, RCls, RReg);
            OutCls := "ALI Register Class"::"Text";
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::CAT_T, OutReg, LReg, RReg);
            exit;
        end;

        // Temporal special forms (operand classes stay asymmetric).
        if (LT = "ALI TypeKind"::Date) and (RT = "ALI TypeKind"::Date) and (Group = "ALI Op Group"::Sub) then begin
            OutCls := "ALI Register Class"::Int;
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::SUB_DATE_DATE, OutReg, LReg, RReg);
            exit;
        end;
        if (LT = "ALI TypeKind"::Time) and (RT = "ALI TypeKind"::Time) and (Group = "ALI Op Group"::Sub) then begin
            OutCls := "ALI Register Class"::Int;
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::SUB_TIME_TIME, OutReg, LReg, RReg);
            exit;
        end;
        if (LT = "ALI TypeKind"::DateTime) and (RT = "ALI TypeKind"::DateTime) and (Group = "ALI Op Group"::Sub) then begin
            OutCls := "ALI Register Class"::"Duration";
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::SUB_DT_DT, OutReg, LReg, RReg);
            exit;
        end;
        if LT = "ALI TypeKind"::Date then begin
            OutCls := "ALI Register Class"::"Date";
            OutReg := AllocTemp(OutCls);
            if RT = "ALI TypeKind"::Duration then begin
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_DATE_DUR, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_DATE_DUR, OutReg, LReg, RReg);
            end else begin
                RReg := ConvertToType(Module, RCls, RReg, "ALI TypeKind"::Integer);
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_DATE_I, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_DATE_I, OutReg, LReg, RReg);
            end;
            exit;
        end;
        if LT = "ALI TypeKind"::Time then begin
            OutCls := "ALI Register Class"::"Time";
            OutReg := AllocTemp(OutCls);
            if RT = "ALI TypeKind"::Duration then begin
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_TIME_DUR, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_TIME_DUR, OutReg, LReg, RReg);
            end else begin
                RReg := ConvertToType(Module, RCls, RReg, "ALI TypeKind"::Integer);
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_TIME_I, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_TIME_I, OutReg, LReg, RReg);
            end;
            exit;
        end;
        if LT = "ALI TypeKind"::DateTime then begin
            OutCls := "ALI Register Class"::"DateTime";
            OutReg := AllocTemp(OutCls);
            if RT = "ALI TypeKind"::Duration then begin
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_DT_DUR, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_DT_DUR, OutReg, LReg, RReg);
            end else begin
                RReg := ConvertToType(Module, RCls, RReg, "ALI TypeKind"::Integer);
                if IsAdd then
                    Module.AddInstr("ALI Opcode"::ADD_DT_I, OutReg, LReg, RReg)
                else
                    Module.AddInstr("ALI Opcode"::SUB_DT_I, OutReg, LReg, RReg);
            end;
            exit;
        end;

        // Plain numeric: convert both operands to the result class, emit the family op.
        LReg := ConvertToType(Module, LCls, LReg, R);
        RReg := ConvertToType(Module, RCls, RReg, R);
        OutCls := TypeRules.RegClassFor(R);
        OutReg := AllocTemp(OutCls);
        // P3: int + / - with a just-loaded literal operand folds into ADD_I_IMM/SUB_I_IMM
        // (one dispatch instead of two; the immediate value lives in C, no pool read).
        if (OutCls = "ALI Register Class"::Int) and ((Group = "ALI Op Group"::"Add") or (Group = "ALI Op Group"::Sub)) then
            if TryEmitArithIntImm(Module, Group, OutReg, LReg, RReg) then
                exit;
        Module.AddInstr(ArithOpcode(OutCls, Group), OutReg, LReg, RReg);
    end;

    // Fold `LOAD_CONST_I t ; ADD_I/SUB_I d, l, t` into one immediate-form instruction.
    // Right-literal always folds; left-literal folds for + only (commutes — the temp was
    // emitted solely for this operand). Returns false when no fold applies.
    local procedure TryEmitArithIntImm(var Module: Codeunit "ALI Module"; Group: Integer; OutReg: Integer; LReg: Integer; RReg: Integer): Boolean
    var
        ImmOp: Integer;
        ImmVal: Integer;
        LastPC: Integer;
    begin
        LastPC := Module.InstrCount();
        if LastPC < 1 then
            exit(false);
        if Module.GetOp(LastPC) <> 43 then                      // LOAD_CONST_I
            exit(false);
        ImmOp := 427;                                           // ADD_I_IMM
        if Group = "ALI Op Group"::Sub then
            ImmOp := 428;                                       // SUB_I_IMM
        if Module.GetA(LastPC) = RReg then begin
            ImmVal := Module.GetConstInt(Module.GetB(LastPC));
            Module.RemoveLastInstr();
            Module.AddInstr(ImmOp, OutReg, LReg, ImmVal);
            exit(true);
        end;
        if (Group = "ALI Op Group"::"Add") and (Module.GetA(LastPC) = LReg) then begin
            ImmVal := Module.GetConstInt(Module.GetB(LastPC));
            Module.RemoveLastInstr();
            Module.AddInstr(ImmOp, OutReg, RReg, ImmVal);
            exit(true);
        end;
        exit(false);
    end;

    // Flatten `a + b + c` (all Text-typed `+` nodes) and emit ONE CONCAT_N (2 operands
    // degrade to CAT_T). Non-text operands are formatted via TO_TEXT.
    local procedure LowerConcatChain(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        First: Boolean;
        Cls: Integer;
        OperandNode: Integer;
        PoolIdx: Integer;
        Reg: Integer;
        RegIdx: Integer;
        StartIdx: Integer;
        Operands: List of [Integer];
        TextRegs: List of [Integer];
    begin
        CollectConcatOperands(Ast, Node, Operands);
        foreach OperandNode in Operands do begin
            LowerExpr(Tokens, Ast, Symbols, Module, OperandNode, Cls, Reg);
            // ToTextRegT (not ToTextReg): a Char operand in the chain (e.g. `a + Txt[i] + b`)
            // must format as its printable character, not its numeric ordinal (§6.4).
            TextRegs.Add(ToTextRegT(Module, Ast.GetTypeOrd(OperandNode), Cls, Reg));
        end;

        OutCls := "ALI Register Class"::"Text";
        OutReg := AllocTemp(OutCls);
        if TextRegs.Count() = 2 then begin
            Module.AddInstr("ALI Opcode"::CAT_T, OutReg, TextRegs.Get(1), TextRegs.Get(2));
            exit;
        end;
        First := true;
        StartIdx := 0;
        foreach RegIdx in TextRegs do begin
            PoolIdx := Module.AddOperand(RegIdx);
            if First then begin
                StartIdx := PoolIdx;
                First := false;
            end;
        end;
        Module.AddInstr("ALI Opcode"::CONCAT_N, OutReg, StartIdx, TextRegs.Count());
    end;

    // A node joins the chain when it is itself a Text-typed `+` BinaryExpr.
    local procedure CollectConcatOperands(var Ast: Codeunit "ALI Ast Store"; Node: Integer; var Operands: List of [Integer])
    begin
        if (Ast.GetKind(Node) = "ALI NodeKind"::BinaryExpr) and (Ast.GetExtra(Node) = 30) and (Ast.GetTypeOrd(Node) = "ALI TypeKind"::Text) then begin
            CollectConcatOperands(Ast, Ast.GetChild(Node, 0), Operands);
            CollectConcatOperands(Ast, Ast.GetChild(Node, 1), Operands);
            exit;
        end;
        Operands.Add(Node);
    end;

    // ===== Procedure calls (M5, §7.4 convention) =====

    // Lower a bound user-proc invocation. Two phases so nested calls in argument
    // expressions cannot clobber the staging window:
    //   1. every by-value argument expression is fully evaluated into caller registers
    //      (converted to the param type, store-side checks applied);
    //   2. ARG_VAL / ARG_REF stage them into the callee window, then CALL, then (when the
    //      result is wanted) RESULT_FETCH into a fresh caller temp.
    // M11 `Cust.CalcBalance(a)`: a normal interpreted CALL whose FIRST argument is the receiver,
    // staged as a var-param alias (ARG_REF) into descriptor row 1 — so the callee's implicit
    // `Rec` refers to the caller's record itself, and a Modify inside the procedure is visible
    // to the caller, exactly as in native AL. The remaining arguments are staged by LowerCall
    // with RowShift = 1.
    //
    // The receiver is recovered structurally, not from an annotation: on a parenthesised call
    // the node's child 0 is the MemberAccessExpr callee, whose own child 0 is the receiver; on
    // a paren-less call the node IS that MemberAccessExpr.
    local procedure LowerObjectCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; var OutCls: Integer; var OutReg: Integer)
    var
        CalleeNode: Integer;
        Mode: Integer;
        PId: Integer;
        ProcSym: Integer;
        RecvNode: Integer;
        RecvRow: Integer;
        RecvSid: Integer;
        RecvSlot: Integer;
        RecvSrc: Integer;
        Row: Integer;
        SelfInst: Integer;
        SelfRow: Integer;
        SelfSlot: Integer;
        SelfSrc: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        ProcSym := Ast.GetSlotIndex(Node);       // binder contract: callee symbol rides in SlotIndex
        if ProcSym <= 0 then
            exit;
        PId := Symbols.GetProcId(ProcSym);

        SelfRow := Symbols.GetProcSelfRow(PId);
        RecvRow := Symbols.GetProcRecvRow(PId);

        CalleeNode := Node;
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0);
        // A CODEUNIT sibling call (`Helper(x)` inside a harvested codeunit) has no receiver node
        // at all — the callee node is the bare NameExpr. Everything else is `X.Member`, whose
        // child 0 names the receiver variable.
        if Ast.GetKind(CalleeNode) = "ALI NodeKind"::MemberAccessExpr then begin
            RecvNode := Ast.GetChild(CalleeNode, 0);
            RecvSid := Ast.GetSymbolId(RecvNode);
            if RecvSid <= 0 then
                exit;                            // poisoned receiver — bind already errored
            Mode := AliasModeOf(Symbols, RecvSid);
        end;

        // M11 phase B2: which instance's globals the callee runs on. A receiver variable carries
        // its own instance index, known at compile time. Instance 0 means the receiver is the
        // implicit `Rec` of the frame we are lowering — a sibling call — so the caller's own
        // instance is forwarded instead, which is what makes recursion and call chains work.
        if SelfRow > 0 then begin
            SelfSlot := Symbols.ParamRowSlot(Symbols.ProcParamRow(PId, SelfRow));
            if RecvSid > 0 then
                SelfInst := Symbols.GetInstIdx(RecvSid);
            if SelfInst = 0 then
                SelfSrc := CurSelfSlot(Symbols);     // forward this frame's own instance
        end;

        // The receiver is handed to LowerCall rather than staged here. Staging it up front looked
        // harmless but was not: LowerCall evaluates argument EXPRESSIONS before staging anything,
        // precisely so a nested call inside an argument cannot clobber the staging window — and a
        // receiver staged ahead of that evaluation sits in exactly the window the nested call
        // reuses. `a.Foo(b.Bar())` would have called Foo on whatever Bar left behind.
        if RecvRow > 0 then begin
            Row := Symbols.ProcParamRow(PId, RecvRow);
            RecvSlot := Symbols.ParamRowSlot(Row);
            RecvSrc := Symbols.GetSlot(RecvSid);
        end;
        LowerCall(Tokens, Ast, Symbols, Module, Node, WantResult, ProcSym, SelfRowCount(SelfRow) + SelfRowCount(RecvRow), OutCls, OutReg,
            RecvSlot, RecvSrc, "ALI Register Class"::Int * 4 + Mode, SelfSlot, SelfInst, SelfSrc);
    end;

    // 1 when a hidden descriptor row exists, 0 when it does not — the two of them add up to the
    // callee's RowShift.
    local procedure SelfRowCount(Row: Integer): Integer
    begin
        if Row > 0 then
            exit(1);
        exit(0);
    end;

    // Frame-relative Int slot holding the instance index of the procedure BEING LOWERED. Only
    // ever read while lowering a harvested object's procedure, where the binder guaranteed the
    // hidden row exists.
    local procedure CurSelfSlot(var Symbols: Codeunit "ALI Symbol Table"): Integer
    var
        SelfRow: Integer;
    begin
        SelfRow := Symbols.GetProcSelfRow(CurProcId);
        if SelfRow = 0 then
            exit(0);
        exit(Symbols.ParamRowSlot(Symbols.ProcParamRow(CurProcId, SelfRow)));
    end;

    local procedure LowerCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; ProcSymIn: Integer; RowShift: Integer; var OutCls: Integer; var OutReg: Integer)
    begin
        LowerCall(Tokens, Ast, Symbols, Module, Node, WantResult, ProcSymIn, RowShift, OutCls, OutReg, 0, 0, 0, 0, 0, 0);
    end;

    // RecvSlot/RecvSrc/RecvMode (M11): an implicit receiver to stage as a hidden descriptor row,
    // or 0 to stage none. SelfSlot/SelfInst/SelfSrc (M11 phase B2): the hidden instance index —
    // SelfInst is the receiver variable's own index, or 0 to FORWARD the caller's, which then
    // sits in the caller frame's Int slot SelfSrc. Both hidden rows are materialised in PHASE 2,
    // after every argument expression has been evaluated: a register computed before that could
    // be reused by a nested call inside one of the arguments — see the receiver note below.
    local procedure LowerCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; ProcSymIn: Integer; RowShift: Integer; var OutCls: Integer; var OutReg: Integer; RecvSlot: Integer; RecvSrc: Integer; RecvMode: Integer; SelfSlot: Integer; SelfInst: Integer; SelfSrc: Integer)
    var
        ArgCount: Integer;
        ArgNode: Integer;
        ArgSid: Integer;
        Cls: Integer;
        CodeFlag: Integer;
        k: Integer;
        Mode: Integer;
        PArg: Integer;
        PCls: Integer;
        PId: Integer;
        ProcSym: Integer;
        PSlot: Integer;
        PT: Integer;
        RCls: Integer;
        Reg: Integer;
        RetT: Integer;
        Row: Integer;
        SelfReg: Integer;
        TmpReg: Integer;
        StageA: List of [Integer];
        StageB: List of [Integer];
        StageC: List of [Integer];
        StageKind: List of [Integer];   // 0 = ARG_VAL, 1 = ARG_REF
        ReStoreSids: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        // ProcSymIn (M11): 0 = ordinary call, the proc symbol is on the node. Non-zero = an
        // object-procedure call, whose node carries the ObjectCallMark sentinel instead, so the
        // caller passes the symbol in. RowShift is the count of hidden leading parameters the
        // CALLER stages (1 for the implicit receiver), so written argument k is descriptor row
        // k + RowShift — mirrors "ALI Binder".BindUserProcCall's RowShift exactly.
        if ProcSymIn <> 0 then
            ProcSym := ProcSymIn
        else
            ProcSym := Ast.GetSymbolId(Node);
        if ProcSym <= 0 then
            exit;
        PId := Symbols.GetProcId(ProcSym);
        // Paren-less zero-arg call (`MyProc;` / `x := MyFunc`): Node is a NameExpr whose ExtraInt
        // is the NameId, not an arg count — read 0. Parenthesized call: Node is InvocationExpr.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;

        // --- phase 1: evaluate/classify arguments ---
        for k := 1 to ArgCount do begin
            ArgNode := Ast.GetChild(Node, k);
            Row := Symbols.ProcParamRow(PId, k + RowShift);
            PT := Symbols.ParamRowType(Row);
            PArg := Symbols.ParamRowTypeArg(Row);
            PCls := TypeRules.RegClassFor(PT);
            PSlot := Symbols.ParamRowSlot(Row);
            if Symbols.ParamRowIsVar(Row) then begin
                // var param: record the alias (§7.2 — indirection, no copy). Mode says how
                // the interpreter resolves the source to an absolute register index.
                ArgSid := Ast.GetSymbolId(ArgNode);
                Mode := AliasModeOf(Symbols, ArgSid);
                if NeedsVarTextReStore(Symbols, ArgSid, PT, PArg) then
                    ReStoreSids.Add(ArgSid);
                StageKind.Add(1);
                StageA.Add(PSlot);
                StageB.Add(Symbols.GetSlot(ArgSid));
                StageC.Add(PCls * 4 + Mode);
            end else if (PT = "ALI TypeKind"::Variant) and IsRefBoxType(Ast.GetTypeOrd(ArgNode)) then begin
                // §19.2: Record / aggregate passed by value into a Variant param — box (tagged)
                // by reference, bypassing the scalar CONV path which cannot tag a handle.
                Reg := BoxRefIntoVariantTemp(Tokens, Ast, Symbols, Module, ArgNode, Ast.GetTypeOrd(ArgNode));
                StageKind.Add(0);
                StageA.Add(PSlot);
                StageB.Add(Reg);
                StageC.Add(PCls);
            end else begin
                LowerExpr(Tokens, Ast, Symbols, Module, ArgNode, Cls, Reg);
                Reg := ConvertToType(Module, Cls, Reg, PT);
                // store-side checks on the by-value copy (§7.2): Char/Byte range,
                // Text[n] length + Code uppercasing.
                case true of
                    (PT = "ALI TypeKind"::Char):
                        begin
                            TmpReg := AllocTemp("ALI Register Class"::Int);
                            Module.AddInstr("ALI Opcode"::CONV_I_CHAR, TmpReg, Reg, 0);
                            Reg := TmpReg;
                        end;
                    (PT = "ALI TypeKind"::Byte):
                        begin
                            TmpReg := AllocTemp("ALI Register Class"::Int);
                            Module.AddInstr("ALI Opcode"::CONV_I_BYTE, TmpReg, Reg, 0);
                            Reg := TmpReg;
                        end;
                    (PCls = "ALI Register Class"::"Text") and ((PArg > 0) or (PT = "ALI TypeKind"::Code)):
                        begin
                            CodeFlag := 0;
                            if PT = "ALI TypeKind"::Code then
                                CodeFlag := 1;
                            TmpReg := AllocTemp("ALI Register Class"::"Text");
                            Module.AddInstr("ALI Opcode"::STORE_TEXT_CHK, TmpReg, Reg, PArg * 2 + CodeFlag);
                            Reg := TmpReg;
                        end;
                end;
                StageKind.Add(0);
                StageA.Add(PSlot);
                StageB.Add(Reg);
                StageC.Add(PCls);
            end;
        end;

        // --- phase 2: stage + call ---
        // The implicit receiver goes first, but only NOW — after every argument expression has
        // been evaluated into caller registers, so a nested call inside one of them can no longer
        // overwrite it.
        // M11 phase B2: the instance index precedes the receiver, matching its descriptor row.
        if SelfSlot > 0 then begin
            SelfReg := AllocTemp("ALI Register Class"::Int);
            if SelfInst > 0 then
                Module.AddInstr("ALI Opcode"::LOAD_CONST_I, SelfReg, Module.AddConstInt(SelfInst), 0)
            else
                Module.AddInstr("ALI Opcode"::MOV_I, SelfReg, SelfSrc, 0);
            Module.AddInstr("ALI Opcode"::ARG_VAL, SelfSlot, SelfReg, "ALI Register Class"::Int);
        end;
        if RecvSlot > 0 then
            Module.AddInstr("ALI Opcode"::ARG_REF, RecvSlot, RecvSrc, RecvMode);
        for k := 1 to StageKind.Count() do
            if StageKind.Get(k) = 1 then
                Module.AddInstr("ALI Opcode"::ARG_REF, StageA.Get(k), StageB.Get(k), StageC.Get(k))
            else
                Module.AddInstr("ALI Opcode"::ARG_VAL, StageA.Get(k), StageB.Get(k), StageC.Get(k));

        // [TryFunction] whose outcome is consumed: TRY_CALL writes the Boolean straight into a
        // caller temp (the callee has no result slot, so there is nothing to RESULT_FETCH). An
        // unconsumed try call falls through to a plain CALL — native AL lets its error propagate.
        if WantResult and Symbols.IsTryProc(PId) then begin
            OutCls := "ALI Register Class"::"Boolean";
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::TRY_CALL, PId, OutReg, 0);
        end else begin
            Module.AddInstr("ALI Opcode"::CALL, PId, 0, 0);

            if WantResult then begin
                RetT := Symbols.GetType(ProcSym);
                RCls := TypeRules.RegClassFor(RetT);
                if RCls > 0 then begin
                    OutCls := RCls;
                    OutReg := AllocTemp(RCls);
                    Module.AddInstr("ALI Opcode"::RESULT_FETCH, OutReg, Symbols.GetProcResultSlot(PId), RCls);
                end;
            end;
        end;

        // --- phase 3: re-store Text/Code var args whose caller type is stricter than the param
        // (Code var -> var Text, Text[n] -> var Text / longer Text[m]): the callee wrote through
        // the alias with ITS checks, so re-apply the caller's length check + Code uppercasing.
        foreach ArgSid in ReStoreSids do begin
            LoadSymValue(Module, Symbols, ArgSid, Cls, Reg);
            StoreToSym(Module, Symbols, ArgSid, Cls, Reg);
        end;
    end;

    // True when a var Text/Code arg must be re-stored after the call (see LowerCall phase 3).
    local procedure NeedsVarTextReStore(var Symbols: Codeunit "ALI Symbol Table"; ArgSid: Integer; PT: Integer; PArg: Integer): Boolean
    var
        ArgLen: Integer;
        ArgT: Integer;
    begin
        ArgT := Symbols.GetType(ArgSid);
        if not (TypeRules.IsTextOrCode(PT) and TypeRules.IsTextOrCode(ArgT)) then
            exit(false);
        if (ArgT = "ALI TypeKind"::Code) and (PT <> "ALI TypeKind"::Code) then
            exit(true);
        ArgLen := Symbols.GetTypeArg(ArgSid);
        exit((ArgLen > 0) and ((PArg = 0) or (PArg > ArgLen)));
    end;

    // CLEAR_TARGET's C operand: 0 = frame-local slot, 1 = absolute global slot, 3 + Inst*4 = an object global of an explicit instance (EmitClearInstance), 2 = an object
    // global (offset in the current instance's block — M11 phase B2).
    local procedure ClearModeOf(var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer): Integer
    begin
        if Symbols.GetKind(Sid) <> "ALI Symbol Kind"::GlobalVar then
            exit(0);
        if Symbols.GetOwnerObjKey(Sid) <> 0 then
            exit(2);
        exit(1);
    end;

    // How ARG_REF must resolve a symbol to an absolute register index (the low two bits of its
    // C operand): 0 = caller frame-local, 1 = the caller's own var param (dereference), 2 = an
    // absolute global slot, 3 = an object global (the slot is an offset in the block of the
    // instance the CALLER is running on — M11 phase B2).
    local procedure AliasModeOf(var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer): Integer
    var
        SKind: Integer;
    begin
        SKind := Symbols.GetKind(Sid);
        if SKind = "ALI Symbol Kind"::VarParam then
            exit(1);
        if SKind = "ALI Symbol Kind"::GlobalVar then begin
            if Symbols.GetOwnerObjKey(Sid) <> 0 then
                exit(3);
            exit(2);
        end;
        exit(0);
    end;

    // ===== Variable load/store (storage kinds: local/param direct, var-param indirect,
    // module-level global absolute — M5 §7.2) =====

    // Load a variable symbol's VALUE into (OutCls, OutReg). Frame-locals return their slot
    // directly (no copy); var params / globals load into fresh temps.
    local procedure LoadSymValue(var Module: Codeunit "ALI Module"; var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        SKind: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        if Sid <= 0 then
            exit;
        OutCls := TypeRules.RegClassFor(Symbols.GetType(Sid));
        if OutCls = 0 then
            exit;
        // A Label is a compile-time text constant (§19.2): fold every read to a LOAD_CONST_T of
        // its text — the symbol has no live register slot. Must precede the storage-kind switch.
        if Symbols.GetType(Sid) = "ALI TypeKind"::Label then begin
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::LOAD_CONST_T, OutReg, Module.AddConstText(Symbols.GetLabelText(Sid)), 0);
            exit;
        end;
        SKind := Symbols.GetKind(Sid);
        case true of
            (SKind = "ALI Symbol Kind"::VarParam):
                begin
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_IND, OutReg, Symbols.GetSlot(Sid), OutCls);
                end;
            // M11 phase B2: a HARVESTED OBJECT's global. Its slot is an offset inside the
            // object's block; the absolute slot is resolved at runtime against the instance this
            // frame is running on. Checked ahead of the plain-global arm — it IS a GlobalVar.
            (SKind = "ALI Symbol Kind"::GlobalVar) and (Symbols.GetOwnerObjKey(Sid) <> 0):
                begin
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::SELF_LOAD, OutReg, Symbols.GetSlot(Sid), OutCls);
                end;
            (SKind = "ALI Symbol Kind"::GlobalVar):
                begin
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::GLOB_LOAD, OutReg, Symbols.GetSlot(Sid), OutCls);
                end;
            else
                OutReg := Symbols.GetSlot(Sid);
        end;
    end;

    // §19.2 Variant box/unbox for Record + aggregate reference types (List/Dict/Array), which the
    // generic scalar StoreToSym path cannot TAG. Returns true when it fully handled the `:=`:
    //   * v := rec ....................... BOX_REC (box the record handle, tag = Record)
    //   * v := list/dict/array ........... tagged CONV_BOX of the Int handle (tag = the ALI type)
    //   * rec := v ....................... UNBOX_REC (REC_COPY out of the boxed handle)
    // Scalar box/unbox, list/dict/array := v (Int-handle unbox), and v := v all fall through
    // (return false) to the generic StoreToSym / CONV path.
    local procedure LowerVariantRefAssign(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Sid: Integer; SourceNode: Integer): Boolean
    var
        SourceTy: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
        TargetTy: Integer;
        TgtCls: Integer;
        TgtReg: Integer;
        TmpVar: Integer;
    begin
        TargetTy := Symbols.GetType(Sid);
        SourceTy := Ast.GetTypeOrd(SourceNode);

        // rec := v — unbox a boxed record straight into the target record handle. UNBOX_REC
        // overwrites the target's EXISTING record content (REC_COPY semantics) rather than
        // rebinding the handle, so it's resolved as a read (Handle Lifecycle Unification: same
        // generic local/global/var-param resolution as REC_COPY above).
        if (TargetTy = "ALI TypeKind"::Record) and (SourceTy = "ALI TypeKind"::Variant) then begin
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            LoadSymValue(Module, Symbols, Sid, TgtCls, TgtReg);
            Module.AddInstr("ALI Opcode"::UNBOX_REC, TgtReg, SrcReg, 0);
            exit(true);
        end;

        // v := rec/list/dict/array — box (reference, tagged) then store into the target.
        if (TargetTy = "ALI TypeKind"::Variant) and IsRefBoxType(SourceTy) then begin
            TmpVar := BoxRefIntoVariantTemp(Tokens, Ast, Symbols, Module, SourceNode, SourceTy);
            StoreToSym(Module, Symbols, Sid, "ALI Register Class"::"Variant", TmpVar);
            exit(true);
        end;

        exit(false);
    end;

    // Record + the Int-handle aggregates box into a Variant by REFERENCE with a type tag (§19.2).
    local procedure IsRefBoxType(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::Record) or (T = "ALI TypeKind"::List) or (T = "ALI TypeKind"::Dictionary) or (T = "ALI TypeKind"::Array));
    end;

    // Box a Record / List / Dictionary / Array source into a fresh Variant temp, tagging it so
    // the runtime can identify the handle later (IsRecord/IsList/...). Returns the temp reg.
    local procedure BoxRefIntoVariantTemp(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; SourceNode: Integer; SourceTy: Integer): Integer
    var
        SrcCls: Integer;
        SrcReg: Integer;
        TmpVar: Integer;
    begin
        TmpVar := AllocTemp("ALI Register Class"::"Variant");
        if SourceTy = "ALI TypeKind"::Record then begin
            // Handle Lifecycle Unification: a record's "value" is its handle, now an ordinary
            // Int register (resolved generically, same as the CONV_BOX branch below) rather
            // than a literal slot in a separate handle space.
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            Module.AddInstr("ALI Opcode"::BOX_REC, TmpVar, SrcReg, 0);
        end else begin
            // List/Dict/Array: box the Int handle, tag = the ALI type (C = tag*16 + Int class).
            LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
            Module.AddInstr("ALI Opcode"::CONV_BOX, TmpVar, SrcReg, SourceTy * 16 + "ALI Register Class"::Int);
        end;
        exit(TmpVar);
    end;

    // Store (SrcCls, SrcReg) into the variable symbol with store-side checks (§7.2):
    // Text[n] length + Code uppercase, Char/Byte native range checks; then routed to the
    // right storage kind (direct MOV / STORE_IND / GLOB_STORE).
    local procedure StoreToSym(var Module: Codeunit "ALI Module"; var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer; SrcCls: Integer; SrcReg: Integer)
    var
        Direct: Boolean;
        IsObjGlobal: Boolean;
        CodeFlag: Integer;
        SKind: Integer;
        TargetArg: Integer;
        TargetCls: Integer;
        TargetSlot: Integer;
        TargetT: Integer;
        TmpReg: Integer;
    begin
        TargetT := Symbols.GetType(Sid);
        TargetArg := Symbols.GetTypeArg(Sid);
        TargetSlot := Symbols.GetSlot(Sid);
        TargetCls := TypeRules.RegClassFor(TargetT);
        SKind := Symbols.GetKind(Sid);
        Direct := (SKind <> "ALI Symbol Kind"::VarParam) and (SKind <> "ALI Symbol Kind"::GlobalVar);
        // M11 phase B2: an object global normally stores through SELF_STORE (offset + the
        // frame's instance). EmitInstIdx is the one exception: the SCRIPT's entry proc
        // initialises each instance's handle-kind globals before any object frame exists, so it
        // addresses them absolutely, through the layout the binder published.
        IsObjGlobal := (SKind = "ALI Symbol Kind"::GlobalVar) and (Symbols.GetOwnerObjKey(Sid) <> 0);
        if IsObjGlobal and (EmitInstIdx > 0) then begin
            IsObjGlobal := false;
            TargetSlot := Symbols.GetInstBase(EmitInstIdx, TargetCls) + TargetSlot;
        end;

        SrcReg := ConvertToType(Module, SrcCls, SrcReg, TargetT);

        // Checked conversions/stores land in the destination for direct storage, or in a
        // temp that is then routed through STORE_IND / GLOB_STORE.
        case true of
            (TargetT = "ALI TypeKind"::Char):
                if Direct then begin
                    Module.AddInstr("ALI Opcode"::CONV_I_CHAR, TargetSlot, SrcReg, 0);
                    exit;
                end else begin
                    TmpReg := AllocTemp("ALI Register Class"::Int);
                    Module.AddInstr("ALI Opcode"::CONV_I_CHAR, TmpReg, SrcReg, 0);
                    SrcReg := TmpReg;
                end;
            (TargetT = "ALI TypeKind"::Byte):
                if Direct then begin
                    Module.AddInstr("ALI Opcode"::CONV_I_BYTE, TargetSlot, SrcReg, 0);
                    exit;
                end else begin
                    TmpReg := AllocTemp("ALI Register Class"::Int);
                    Module.AddInstr("ALI Opcode"::CONV_I_BYTE, TmpReg, SrcReg, 0);
                    SrcReg := TmpReg;
                end;
            (TargetCls = "ALI Register Class"::"Text") and ((TargetArg > 0) or (TargetT = "ALI TypeKind"::Code)):
                begin
                    CodeFlag := 0;
                    if TargetT = "ALI TypeKind"::Code then
                        CodeFlag := 1;
                    if Direct then begin
                        Module.AddInstr("ALI Opcode"::STORE_TEXT_CHK, TargetSlot, SrcReg, TargetArg * 2 + CodeFlag);
                        exit;
                    end;
                    TmpReg := AllocTemp("ALI Register Class"::"Text");
                    Module.AddInstr("ALI Opcode"::STORE_TEXT_CHK, TmpReg, SrcReg, TargetArg * 2 + CodeFlag);
                    SrcReg := TmpReg;
                end;
        end;

        // Handle Lifecycle Unification: a handle-kind value about to be written through a
        // var-param alias or into a global must stop being owned by the CURRENT frame — see
        // "ALI Interpreter".ExecHandleEscape header for the full reasoning. Emitted for BOTH
        // escape shapes, right before the store it guards; a local-to-local store (the `else`
        // branch below) never needs it — same frame, same owner.
        if IsHandleKindType(TargetT) and ((SKind = "ALI Symbol Kind"::VarParam) or (SKind = "ALI Symbol Kind"::GlobalVar)) then
            Module.AddInstr("ALI Opcode"::HANDLE_ESCAPE, SrcReg, TargetT, 0);

        case true of
            (SKind = "ALI Symbol Kind"::VarParam):
                Module.AddInstr("ALI Opcode"::STORE_IND, TargetSlot, SrcReg, TargetCls);
            IsObjGlobal:
                Module.AddInstr("ALI Opcode"::SELF_STORE, TargetSlot, SrcReg, TargetCls);
            (SKind = "ALI Symbol Kind"::GlobalVar):
                Module.AddInstr("ALI Opcode"::GLOB_STORE, TargetSlot, SrcReg, TargetCls);
            else
                Module.AddInstr(MovOpcode(TargetCls), TargetSlot, SrcReg, 0);
        end;
    end;

    // ===== Conversion / store helpers =====

    // Convert a value to the register class of TargetT (operand context — the checked
    // Char/Byte narrowings apply only on variable STORES, §7.2). Returns the register.
    local procedure ConvertToType(var Module: Codeunit "ALI Module"; CurCls: Integer; CurReg: Integer; TargetT: Integer): Integer
    var
        NewReg: Integer;
        TargetCls: Integer;
    begin
        TargetCls := TypeRules.RegClassFor(TargetT);
        if (TargetCls = 0) or (TargetCls = CurCls) then
            exit(CurReg);
        NewReg := AllocTemp(TargetCls);
        case true of
            (CurCls = "ALI Register Class"::Int) and (TargetCls = "ALI Register Class"::"Decimal"):
                Module.AddInstr("ALI Opcode"::CONV_I_D, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::BigInt) and (TargetCls = "ALI Register Class"::"Decimal"):
                Module.AddInstr("ALI Opcode"::CONV_BIG_D, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::"Decimal") and (TargetCls = "ALI Register Class"::Int):
                Module.AddInstr("ALI Opcode"::CONV_D_I, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::"Decimal") and (TargetCls = "ALI Register Class"::BigInt):
                Module.AddInstr("ALI Opcode"::CONV_D_BIG, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::Int) and (TargetCls = "ALI Register Class"::BigInt):
                Module.AddInstr("ALI Opcode"::CONV_I_BIG, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::BigInt) and (TargetCls = "ALI Register Class"::Int):
                Module.AddInstr("ALI Opcode"::CONV_BIG_I, NewReg, CurReg, 0);
            (CurCls = "ALI Register Class"::"Text") and (TargetCls = "ALI Register Class"::"DateFormula"):
                Module.AddInstr("ALI Opcode"::CONV_TEXT_DF, NewReg, CurReg, 0);
            // Char -> Text/Code (ConvCharToText). Post-bind, an Int-class value reaching a
            // Text-class target can ONLY be a Char (the binder rejects Integer/Option/Enum
            // -> Text), so the class pair alone identifies the conversion.
            (CurCls = "ALI Register Class"::Int) and (TargetCls = "ALI Register Class"::"Text"):
                Module.AddInstr("ALI Opcode"::CHAR_TO_TEXT, NewReg, CurReg, 0);
            // Variant boxing / unboxing (§7.1): C carries the SOURCE class on box (what to read
            // as a Variant) and the TARGET class on unbox (what to write the Variant back into).
            (TargetCls = "ALI Register Class"::"Variant"):
                Module.AddInstr("ALI Opcode"::CONV_BOX, NewReg, CurReg, CurCls);
            (CurCls = "ALI Register Class"::"Variant"):
                Module.AddInstr("ALI Opcode"::CONV_UNBOX, NewReg, CurReg, TargetCls);
            else
                exit(CurReg);   // no cross-class path (post-bind this cannot happen)
        end;
        exit(NewReg);
    end;

    // Text register holding the (possibly formatted) value — TO_TEXT for non-text classes.
    local procedure ToTextReg(var Module: Codeunit "ALI Module"; Cls: Integer; Reg: Integer): Integer
    var
        NewReg: Integer;
    begin
        if Cls = "ALI Register Class"::"Text" then
            exit(Reg);
        NewReg := AllocTemp("ALI Register Class"::"Text");
        Module.AddInstr("ALI Opcode"::TO_TEXT, NewReg, Reg, Cls);
        exit(NewReg);
    end;

    // TypeKind-aware sibling of ToTextReg (§6.4): a Char's register class is RegClassInt —
    // indistinguishable from a genuine Integer at the Cls level — but a Char must format as
    // its printable character (CHAR_TO_TEXT), never as the decimal ordinal TO_TEXT would give
    // it. Every OTHER source type falls through to the plain Cls-based ToTextReg unchanged.
    // Used wherever a Char can legitimately reach a Text-typed slot: concatenation (+/+=,
    // §19.4 `Text[i]`) and Text-vs-Char comparison.
    local procedure ToTextRegT(var Module: Codeunit "ALI Module"; SrcT: Integer; Cls: Integer; Reg: Integer): Integer
    var
        NewReg: Integer;
    begin
        if Cls = "ALI Register Class"::"Text" then
            exit(Reg);
        if SrcT = "ALI TypeKind"::Char then begin
            NewReg := AllocTemp("ALI Register Class"::"Text");
            Module.AddInstr("ALI Opcode"::CHAR_TO_TEXT, NewReg, Reg, 0);
            exit(NewReg);
        end;
        exit(ToTextReg(Module, Cls, Reg));
    end;

    // Common comparison type for two operand types: text/text -> Text, same temporal ->
    // that type, Bool/Guid -> themselves, numeric -> Dec > Big > Int promotion.
    local procedure CommonCompareType(LT: Integer; RT: Integer): Integer
    begin
        if TypeRules.IsTextFamily(LT) and TypeRules.IsTextFamily(RT) then
            exit("ALI TypeKind"::Text);
        // Char paired with a Text/Code operand (e.g. `Text[i] <> 'A'`): widen the Char to its
        // printable 1-char Text rather than falling through to numeric comparison — native AL
        // compares a Char against a Text/Code literal or value as characters (§6.4).
        if (LT = "ALI TypeKind"::Char) and TypeRules.IsTextFamily(RT) then
            exit("ALI TypeKind"::Text);
        if TypeRules.IsTextFamily(LT) and (RT = "ALI TypeKind"::Char) then
            exit("ALI TypeKind"::Text);
        if (LT = "ALI TypeKind"::Boolean) and (RT = "ALI TypeKind"::Boolean) then
            exit("ALI TypeKind"::Boolean);
        if (LT = "ALI TypeKind"::Guid) and (RT = "ALI TypeKind"::Guid) then
            exit("ALI TypeKind"::Guid);
        if (LT = "ALI TypeKind"::RecordID) and (RT = "ALI TypeKind"::RecordID) then
            exit("ALI TypeKind"::RecordID);     // equality only — binder excludes ordering (RecordID)
        if (LT = "ALI TypeKind"::Date) and (RT = "ALI TypeKind"::Date) then
            exit("ALI TypeKind"::Date);
        if (LT = "ALI TypeKind"::Time) and (RT = "ALI TypeKind"::Time) then
            exit("ALI TypeKind"::Time);
        if (LT = "ALI TypeKind"::DateTime) and (RT = "ALI TypeKind"::DateTime) then
            exit("ALI TypeKind"::DateTime);
        if (LT = "ALI TypeKind"::Duration) and (RT = "ALI TypeKind"::Duration) then
            exit("ALI TypeKind"::Duration);
        if (LT = "ALI TypeKind"::DateFormula) and (RT = "ALI TypeKind"::DateFormula) then
            exit("ALI TypeKind"::DateFormula);     // equality only — binder's EqualityComparable already excludes mixed operands
        if (LT = "ALI TypeKind"::Decimal) or (RT = "ALI TypeKind"::Decimal) then
            exit("ALI TypeKind"::Decimal);
        if (LT = "ALI TypeKind"::BigInteger) or (RT = "ALI TypeKind"::BigInteger) then
            exit("ALI TypeKind"::BigInteger);
        exit("ALI TypeKind"::Integer);
    end;

    // ===== M6 record field access / array element access / record methods =====

    // Rec.Field read -> REC_FLD_LOAD into a fresh temp of the field's class. Node SlotIndex
    // holds the bind-resolved field number; child 0 is the record var (handle = its slot).
    local procedure LowerFieldLoad(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        FieldNo: Integer;
        FieldT: Integer;
        Handle: Integer;
        HandleCls: Integer;
    begin
        // Handle Lifecycle Unification: resolve the record receiver generically (LowerExpr),
        // same as any other handle-kind receiver.
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), HandleCls, Handle);
        FieldNo := Ast.GetSlotIndex(Node);
        FieldT := Ast.GetTypeOrd(Node);
        OutCls := TypeRules.RegClassFor(FieldT);
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::REC_FLD_LOAD, OutReg, Handle, FieldNo * 16 + OutCls);
    end;

    // Rec.Field := source -> lower source, convert to field type, REC_FLD_STORE.
    local procedure LowerFieldStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        Cls: Integer;
        FCls: Integer;
        FieldNo: Integer;
        FieldT: Integer;
        Handle: Integer;
        HandleCls: Integer;
        Reg: Integer;
    begin
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(TargetNode, 0), HandleCls, Handle);
        FieldNo := Ast.GetSlotIndex(TargetNode);
        FieldT := Ast.GetTypeOrd(TargetNode);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, Cls, Reg);
        Reg := ConvertToType(Module, Cls, Reg, FieldT);
        FCls := TypeRules.RegClassFor(FieldT);
        Module.AddInstr("ALI Opcode"::REC_FLD_STORE, Handle, Reg, FieldNo * 16 + FCls);
    end;

    // §20.7 row-major flat index: flat = 1 + Σ (i_k - 1) * stride_k, stride_k = product of
    // dims[k+1..rank] (compile-time constants, GetArrayDims). Emits one ARR_DIM_CHECK per
    // dimension BEFORE folding (native-exact bounds — option (b): a wrong i_k always raises,
    // even when the folded flat index would still land in 1..TotalN). IndexNode = the
    // IndexExpr node itself: children [1..Rank] are the index expressions.
    local procedure LowerArrayFlatIndex(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; IndexNode: Integer; ArrSid: Integer): Integer
    var
        FlatReg: Integer;
        IdxCls: Integer;
        IdxReg: Integer;
        IntCls: Integer;
        j: Integer;
        k: Integer;
        NextFlatReg: Integer;
        OneReg: Integer;
        Rank: Integer;
        Stride: Integer;
        StrideReg: Integer;
        TermReg: Integer;
        Dims: List of [Integer];
    begin
        Dims := Symbols.GetArrayDims(ArrSid);
        Rank := Dims.Count();
        IntCls := "ALI Register Class"::Int;
        FlatReg := AllocTemp(IntCls);
        Module.AddInstr("ALI Opcode"::LOAD_CONST_I, FlatReg, Module.AddConstInt(1), 0);
        for k := 1 to Rank do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(IndexNode, k), IdxCls, IdxReg);
            IdxReg := ConvertToType(Module, IdxCls, IdxReg, "ALI TypeKind"::Integer);
            Module.AddInstr("ALI Opcode"::ARR_DIM_CHECK, IdxReg, Dims.Get(k), k);
            OneReg := AllocTemp(IntCls);
            Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OneReg, Module.AddConstInt(1), 0);
            TermReg := AllocTemp(IntCls);
            Module.AddInstr("ALI Opcode"::SUB_I, TermReg, IdxReg, OneReg);
            Stride := 1;
            for j := k + 1 to Rank do
                Stride := Stride * Dims.Get(j);
            if Stride <> 1 then begin
                StrideReg := AllocTemp(IntCls);
                Module.AddInstr("ALI Opcode"::LOAD_CONST_I, StrideReg, Module.AddConstInt(Stride), 0);
                NextFlatReg := AllocTemp(IntCls);
                Module.AddInstr("ALI Opcode"::MUL_I, NextFlatReg, TermReg, StrideReg);
                TermReg := NextFlatReg;
            end;
            NextFlatReg := AllocTemp(IntCls);
            Module.AddInstr("ALI Opcode"::ADD_I, NextFlatReg, FlatReg, TermReg);
            FlatReg := NextFlatReg;
        end;
        exit(FlatReg);
    end;

    // arr[i,j,...] read -> ARR_LOAD off the array's HANDLE (§20.2). child 0 = array var,
    // children 1..rank = index expressions.
    local procedure LowerArrayLoad(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArrSid: Integer;
        ElemT: Integer;
        FlatReg: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
    begin
        ArrSid := Ast.GetSymbolId(Ast.GetChild(Node, 0));
        LoadSymValue(Module, Symbols, ArrSid, HandleCls, HandleReg);
        FlatReg := LowerArrayFlatIndex(Tokens, Ast, Symbols, Module, Node, ArrSid);
        ElemT := ArrayElemType(Symbols.GetTypeArg(ArrSid));
        OutCls := TypeRules.RegClassFor(ElemT);
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::ARR_LOAD, OutReg, HandleReg, FlatReg * 16 + OutCls);
    end;

    // arr[i,j,...] := source -> flat index first (matches native evaluation order), then
    // source, then ARR_STORE off the array's HANDLE.
    local procedure LowerArrayStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        ArrSid: Integer;
        Chk: Integer;
        ECls: Integer;
        ElemT: Integer;
        FlatReg: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
        TmpReg: Integer;
    begin
        ArrSid := Ast.GetSymbolId(Ast.GetChild(TargetNode, 0));
        LoadSymValue(Module, Symbols, ArrSid, HandleCls, HandleReg);
        FlatReg := LowerArrayFlatIndex(Tokens, Ast, Symbols, Module, TargetNode, ArrSid);
        ElemT := ArrayElemType(Symbols.GetTypeArg(ArrSid));
        ECls := TypeRules.RegClassFor(ElemT);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        SrcReg := ConvertToType(Module, SrcCls, SrcReg, ElemT);
        // Enforce a fixed Text[n]/Code[n] element width (length-check + Code upper-case), same as
        // scalar Text[n] stores — the width rides in ElemChk since array TArg keeps only elem type.
        if ECls = "ALI Register Class"::"Text" then begin
            Chk := Symbols.GetElemChk(ArrSid);
            if Chk > 0 then begin
                TmpReg := AllocTemp("ALI Register Class"::"Text");
                Module.AddInstr("ALI Opcode"::STORE_TEXT_CHK, TmpReg, SrcReg, Chk);
                SrcReg := TmpReg;
            end;
        end;
        Module.AddInstr("ALI Opcode"::ARR_STORE, HandleReg, SrcReg, FlatReg * 16 + ECls);
    end;

    // text[i] read -> TXT_CHAR_GET. child 0 = ANY Text/Code-typed expression (a plain
    // variable OR a general expression, e.g. `Format(1+2)[1]`, §19.4), child 1 = index.
    // Result class Char (RegClassInt, same file as Int — native AL text indexing yields a
    // Char). Uses the general LowerExpr (not LoadSymValue) so a non-variable receiver just
    // evaluates like any other expression — LowerExpr(NameExpr) already delegates to
    // LoadSymValue internally, so plain-variable receivers behave exactly as before.
    local procedure LowerTextIndexLoad(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        IdxCls: Integer;
        IdxReg: Integer;
        TxtCls: Integer;
        TxtReg: Integer;
    begin
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 0), TxtCls, TxtReg);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), IdxCls, IdxReg);
        IdxReg := ConvertToType(Module, IdxCls, IdxReg, "ALI TypeKind"::Integer);
        OutCls := TypeRules.RegClassFor("ALI TypeKind"::Char);
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::TXT_CHAR_GET, OutReg, TxtReg, IdxReg);
    end;

    // text[i] := source -> TXT_CHAR_SET (numeric/Char source, ASCII code) or TXT_CHAR_SET_TEXT
    // (single-character Text/Code source, §19.4 "native AL allows a literal/derived 1-char
    // Text on a Char position" — kept out of the general ConvKind lattice, see BindAssignment).
    // Mutates a loaded copy of the text then routes it back through StoreToSym so Text[n]
    // length-padding and Code upper-casing still apply (§7.2).
    local procedure LowerTextIndexStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        ChReg: Integer;
        IdxAndMax: Integer;
        IdxCls: Integer;
        IdxReg: Integer;
        Sid: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
        TxtCls: Integer;
        TxtReg: Integer;
    begin
        Sid := Ast.GetSymbolId(Ast.GetChild(TargetNode, 0));
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(TargetNode, 1), IdxCls, IdxReg);
        IdxReg := ConvertToType(Module, IdxCls, IdxReg, "ALI TypeKind"::Integer);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        LoadSymValue(Module, Symbols, Sid, TxtCls, TxtReg);
        // C packs the index register with the target's declared length (MaxLen, 0 = unbounded),
        // so the interpreter can space-extend a bounded Text[n]/Code[n] up to that ceiling.
        IdxAndMax := IdxReg * 4096 + Symbols.GetTypeArg(Sid);
        if SrcCls = "ALI Register Class"::"Text" then
            Module.AddInstr("ALI Opcode"::TXT_CHAR_SET_TEXT, TxtReg, SrcReg, IdxAndMax)
        else begin
            // Checked narrowing to Char's 0..65535 range — mirrors StoreToSym's own TChar branch.
            ChReg := AllocTemp("ALI Register Class"::Int);
            Module.AddInstr("ALI Opcode"::CONV_I_CHAR, ChReg, SrcReg, 0);
            Module.AddInstr("ALI Opcode"::TXT_CHAR_SET, TxtReg, ChReg, IdxAndMax);
        end;
        StoreToSym(Module, Symbols, Sid, TxtCls, TxtReg);
    end;

    // Record method invocation. Node SymbolId = RecMethodMark() - methodId; child 0 of the
    // callee is the record var (handle = its slot); node SlotIndex holds a field no for
    // SetRange/Validate. Emits the matching REC_* opcode; results land in a fresh temp.
    local procedure LowerRecordMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Cond: Integer;
        FCls: Integer;
        FieldNo: Integer;
        FieldT: Integer;
        Handle: Integer;
        HandleCls: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        Reg: Integer;
        Reg2: Integer;
        ToFieldArg: Integer;
        ToHandle: Integer;
        Trigg: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := RecMethodMark() - Ast.GetSymbolId(Node);
        // Invocation: child 0 is the MemberAccessExpr callee. Bare method call (`Rec.FindSet`
        // without parens): the node IS the MemberAccessExpr — its own child 0 is the record var.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0)
        else
            CalleeNode := Node;
        // Handle Lifecycle Unification (Phase 3): the receiver is now an ordinary Int-handle
        // register — resolve it generically (local: its own slot; global: GLOB_LOAD into a
        // temp; var-param: LOAD_IND) exactly like a List/Http method receiver (LowerListMethod
        // uses the same LowerExpr call on its receiver NameExpr).
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), HandleCls, Handle);
        // P1 routing: this same procedure serves a RecordRef receiver — the receiver register
        // holds the very same "ALI Rec Runtime" handle, so every REC_* opcode below works
        // unchanged. The ONE thing a Record receiver cannot be and a RecordRef can, is NOT OPEN:
        // a RecordRef holds handle 0 until Open() gives it one. Emit the assert-open guard
        // (REF_METHOD id 99) ahead of the opcode so that case fails with the truthful ALI937
        // instead of indexing RecRefs[0]. Costs one dispatch here and nothing on the Record path.
        if Ast.GetTypeOrd(Ast.GetChild(CalleeNode, 0)) = "ALI TypeKind"::RecordRef then
            Module.AddInstr("ALI Opcode"::REF_METHOD, Handle, 0, 99 * 100 + 0);

        case MethodId of
            1:  // Init
                Module.AddInstr("ALI Opcode"::REC_INIT, Handle, 0, 0);
            2:  // Reset
                Module.AddInstr("ALI Opcode"::REC_RESET, Handle, 0, 0);
            3, 4, 5, 6: // Insert / Modify / Delete / DeleteAll -> Bool. B bit0 = trigger flag
                        // (const-folded); B bit1 = conditional (result consumed) — the runtime then
                        // consumes the native Boolean so failure returns false instead of throwing.
                        // Result in C.
                begin
                    Trigg := 0;
                    // Bare `Rec.Insert` (no parens) has no trigger arg; only an invocation with
                    // one arg carries the trigger flag (ExtraInt = arg count there).
                    if (Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr) and (Ast.GetExtra(Node) = 1) then
                        Trigg := TriggerFlagFromArg(Tokens, Ast, Node);
                    if WantResult then
                        Trigg := Trigg + 2;
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    case MethodId of
                        3:
                            Module.AddInstr("ALI Opcode"::REC_INSERT, Handle, Trigg, OutReg);
                        4:
                            Module.AddInstr("ALI Opcode"::REC_MODIFY, Handle, Trigg, OutReg);
                        5:
                            Module.AddInstr("ALI Opcode"::REC_DELETE, Handle, Trigg, OutReg);
                        6:
                            Module.AddInstr("ALI Opcode"::REC_DELETEALL, Handle, Trigg, OutReg);
                    end;
                end;
            7:  // Get(keyValue [, ...up to 16]) -> Bool. Each key arg is lowered into a live
                // register and pushed into the operand pool as (reg*16 + class) — read live
                // at REC_GET time (no eager Variant boxing at lower time, §7.5/CONCAT_N
                // convention). C = destBoolReg*64 + conditional*32 + ArgCount (ArgCount 5 bits,
                // <=16; conditional bit5). Conditional = result consumed → runtime consumes the
                // native Boolean (miss returns false); a bare statement Get throws on no match.
                begin
                    // Parenless `Rec.Get` (0-arg default form) is a bare MemberAccessExpr whose
                    // ExtraInt is the member NameId, NOT an arg count — read 0 there (mirror the
                    // binder). Reading NameId as a count would loop over phantom children and
                    // recurse LowerExpr↔LowerRecordMethod until stack overflow.
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    // Get(RecordID): a distinct 1-arg overload (§7.5-analog) — bypasses the
                    // per-field-key operand pool entirely and goes through REC_GET_BY_ID.
                    if (ArgCount = 1) and (Ast.GetTypeOrd(Ast.GetChild(Node, 1)) = "ALI TypeKind"::RecordID) then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Cond := 0;
                        if WantResult then
                            Cond := 1;
                        OutCls := "ALI Register Class"::"Boolean";
                        OutReg := AllocTemp(OutCls);
                        Module.AddInstr("ALI Opcode"::REC_GET_BY_ID, Handle, Reg, OutReg * 2 + Cond);
                        exit;
                    end;
                    // Lower every arg BEFORE touching the pool: an arg can itself be a nested
                    // pool-based construct (e.g. a builtin call or a 3+-term CONCAT_N), whose
                    // own operand-pool pushes would otherwise land between OperStart and this
                    // call's own entries and desync the read-back at REC_GET time.
                    Clear(ArgClsList);
                    Clear(ArgRegList);
                    for k := 1 to ArgCount do begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                        ArgClsList.Add(Cls);
                        ArgRegList.Add(Reg);
                    end;
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
                    Cond := 0;
                    if WantResult then
                        Cond := 1;
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GET, Handle, OperStart, OutReg * 64 + Cond * 32 + ArgCount);
                end;
            8, 9, 10: // FindSet([ForUpdate]) / FindFirst / FindLast -> Bool.
                      // B = Which*4 + ForUpdate*2 + conditional (bit0). Statement form (result
                      // unconsumed) throws on no match; conditional returns false. ForUpdate is
                      // only meaningful for FindSet (Which=0); const-folded like the Insert/Modify
                      // trigger flag (§7.5 BoolFlagFromArg convention) — only a literal `true` sets it.
                begin
                    Cond := 0;
                    if WantResult then
                        Cond := 1;
                    Trigg := 0;
                    if (MethodId = 8) and (Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr) and (Ast.GetExtra(Node) = 1) then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 1);
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIND, Handle, (MethodId - 8) * 4 + Trigg * 2 + Cond, OutReg);
                end;
            11: // Next([Step]) -> Integer. Step defaults to a const 1 when omitted (matches
                // AL's Next() semantics); a live Step arg is lowered like any other expression
                // since it's commonly a variable (paging, batch skip), unlike the const-folded
                // Boolean flags above.
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    if (Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr) and (Ast.GetExtra(Node) = 1) then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                    end else begin
                        Reg := AllocTemp("ALI Register Class"::Int);
                        Module.AddInstr("ALI Opcode"::LOAD_CONST_I, Reg, Module.AddConstInt(1), 0);
                    end;
                    Module.AddInstr("ALI Opcode"::REC_NEXT, Handle, OutReg, Reg);
                end;
            12: // Count -> Integer
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_COUNT, Handle, OutReg, 0);
                end;
            13: // IsEmpty -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_ISEMPTY, Handle, OutReg, 0);
                end;
            14: // SetRange(field [, value [, toValue]]) — 1 arg clears, 2 args equality, 3 args range
                begin
                    FieldNo := Ast.GetSlotIndex(Node);
                    FieldT := Ast.GetTypeOrd(Ast.GetChild(Node, 1));
                    FCls := TypeRules.RegClassFor(FieldT);
                    ArgCount := Ast.GetExtra(Node);
                    case ArgCount of
                        1:
                            Module.AddInstr("ALI Opcode"::REC_SETRANGE_CLR, Handle, FieldNo, 0);
                        2:
                            begin
                                LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                                Reg := ConvertToType(Module, Cls, Reg, FieldT);
                                Module.AddInstr("ALI Opcode"::REC_SETRANGE, Handle, FieldNo, Reg * 16 + FCls);
                            end;
                        3:
                            begin
                                Clear(ArgClsList);
                                Clear(ArgRegList);
                                for k := 2 to 3 do begin
                                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                                    ArgClsList.Add(FCls);
                                    ArgRegList.Add(ConvertToType(Module, Cls, Reg, FieldT));
                                end;
                                OperStart := Module.OperandCount() + 1;
                                for k := 1 to 2 do
                                    Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
                                Module.AddInstr("ALI Opcode"::REC_SETRANGE_2, Handle, OperStart, FieldNo);
                            end;
                    end;
                end;
            15: // Validate(field, value)
                begin
                    FieldNo := Ast.GetSlotIndex(Node);
                    FieldT := Ast.GetTypeOrd(Ast.GetChild(Node, 1));
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, FieldT);
                    FCls := TypeRules.RegClassFor(FieldT);
                    Module.AddInstr("ALI Opcode"::REC_VALIDATE, Handle, Reg, FieldNo * 16 + FCls);
                end;
            16: // Rename(keyValue [, ...up to 16]) — identical operand-pool shape to Get (§7.5)
                begin
                    ArgCount := Ast.GetExtra(Node);
                    Clear(ArgClsList);
                    Clear(ArgRegList);
                    for k := 1 to ArgCount do begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                        ArgClsList.Add(Cls);
                        ArgRegList.Add(Reg);
                    end;
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
                    Module.AddInstr("ALI Opcode"::REC_RENAME, Handle, OperStart, ArgCount);
                end;
            17: // Copy(Record [, Boolean]) — src handle resolved generically (Handle Lifecycle
                // Unification: same as the receiver — LowerExpr, not a literal slot)
                begin
                    Trigg := 0;
                    if Ast.GetExtra(Node) = 2 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 2);
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_COPY_REC, Handle, Reg, Trigg);
                end;
            18: // TransferFields(var Record [, Boolean [, Boolean]])
                begin
                    Trigg := 0;
                    if Ast.GetExtra(Node) >= 2 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 2);
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_TRANSFERFIELDS, Handle, Reg, Trigg);
                end;
            19: // CopyFilters(var Record)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_COPYFILTERS, Handle, Reg, 0);
                end;
            20: // SetRecFilter()
                Module.AddInstr("ALI Opcode"::REC_SETRECFILTER, Handle, 0, 0);
            21: // Truncate([Boolean])
                begin
                    Trigg := 0;
                    if Ast.GetExtra(Node) = 1 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 1);
                    Module.AddInstr("ALI Opcode"::REC_TRUNCATE, Handle, Trigg, 0);
                end;
            /*
            22: // Consistent([Boolean]) — 0 args = getter, 1 arg = setter
                if Ast.GetExtra(Node) = 1 then begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_CONSISTENT_SET, Handle, Reg, 0);
                end else begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_CONSISTENT_GET, Handle, OutReg, 0);
                end;*/
            23: // IsTemporary() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_ISTEMPORARY, Handle, OutReg, 0);
                end;
            24: // CountApprox() -> Integer
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_COUNTAPPROX, Handle, OutReg, 0);
                end;
            25: // ReadPermission() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_READPERMISSION, Handle, OutReg, 0);
                end;
            26: // WritePermission() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_WRITEPERMISSION, Handle, OutReg, 0);
                end;
            27: // SetFilter(field, filterText [, value, ...])
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Text);
                    ArgCount := Ast.GetExtra(Node);
                    if ArgCount <= 2 then
                        Module.AddInstr("ALI Opcode"::REC_SETFILTER, Handle, FieldNo, Reg)
                    else begin
                        // %1-substitution form: lower every value arg FIRST, only then push to the
                        // operand pool — a nested pool-based construct in an arg would otherwise
                        // interleave its own operands with ours (same rule as CALL_BUILTIN_LIVE).
                        Clear(ArgClsList);
                        Clear(ArgRegList);
                        for k := 3 to ArgCount do begin
                            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg2);
                            ArgClsList.Add(Cls);
                            ArgRegList.Add(Reg2);
                        end;
                        OperStart := Module.OperandCount() + 1;
                        Module.AddOperand(FieldNo);
                        Module.AddOperand(Reg * 16 + "ALI Register Class"::"Text");
                        for k := 1 to ArgRegList.Count() do
                            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
                        Module.AddInstr("ALI Opcode"::REC_SETFILTER_ARGS, Handle, OperStart, ArgCount - 2);
                    end;
                end;
            28: // GetFilter(field) -> Text
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETFILTER, OutReg, Handle, FieldNo);
                end;
            29: // CopyFilter(fromField, toField) — the target may be `Other.Field`, in which case
                // the filter lands on ANOTHER record's handle. The binder bound only that
                // record variable (never the field read), so the target node's shape is what
                // says which record is meant: a MemberAccessExpr carries its own receiver,
                // a bare NameExpr means the receiver of the call itself.
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    ToFieldArg := Ast.GetChild(Node, 2);
                    ToHandle := Handle;
                    if Ast.GetKind(ToFieldArg) = "ALI NodeKind"::MemberAccessExpr then
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(ToFieldArg, 0), Cls, ToHandle);
                    OperStart := Module.OperandCount() + 1;
                    Module.AddOperand(FieldNo);
                    Module.AddOperand(Ast.GetSlotIndex(ToFieldArg));
                    Module.AddInstr("ALI Opcode"::REC_COPYFILTER, Handle, ToHandle, OperStart);
                end;
            30: // GetRangeMin(field) -> field's own type
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    FCls := TypeRules.RegClassFor(Ast.GetTypeOrd(Ast.GetChild(Node, 1)));
                    OutCls := FCls;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETRANGEMIN, OutReg, Handle, FieldNo * 16 + FCls);
                end;
            31: // GetRangeMax(field) -> field's own type
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    FCls := TypeRules.RegClassFor(Ast.GetTypeOrd(Ast.GetChild(Node, 1)));
                    OutCls := FCls;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETRANGEMAX, OutReg, Handle, FieldNo * 16 + FCls);
                end;
            32: // ModifyAll(field, value, [Boolean]) -> Bool. B = fieldNo*16 + srcClass.
                // C packs srcReg (high) | destBoolReg*4 | trigger*2 | conditional(low bit).
                // Conditional = result consumed → runtime consumes each row-Modify's Boolean
                // (failure returns false); statement re-raises. (srcReg<=8192, destReg<=4096 fit
                // a 32-bit operand: 8192*16384 = 134M.)
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    FieldT := Ast.GetTypeOrd(Ast.GetChild(Node, 1));
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, FieldT);
                    FCls := TypeRules.RegClassFor(FieldT);
                    Trigg := 0;
                    if Ast.GetExtra(Node) = 3 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 3);
                    Cond := 0;
                    if WantResult then
                        Cond := 1;
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_MODIFYALL, Handle, FieldNo * 16 + FCls, Reg * 16384 + OutReg * 4 + Trigg * 2 + Cond);
                end;
            33: // CalcFields(field,...) — field numbers pushed into the operand pool (§7.5)
                begin
                    ArgCount := Ast.GetExtra(Node);
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(Ast.GetSlotIndex(Ast.GetChild(Node, k)));
                    Module.AddInstr("ALI Opcode"::REC_CALCFIELDS, Handle, OperStart, ArgCount);
                end;
            34: // CalcSums(field,...) — same operand-pool shape as CalcFields
                begin
                    ArgCount := Ast.GetExtra(Node);
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(Ast.GetSlotIndex(Ast.GetChild(Node, k)));
                    Module.AddInstr("ALI Opcode"::REC_CALCSUMS, Handle, OperStart, ArgCount);
                end;
            35: // TestField(field [, value])
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    if Ast.GetExtra(Node) = 2 then begin
                        FieldT := Ast.GetTypeOrd(Ast.GetChild(Node, 1));
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, FieldT);
                        FCls := TypeRules.RegClassFor(FieldT);
                        Module.AddInstr("ALI Opcode"::REC_TESTFIELD_VAL, Handle, Reg * 16 + FCls, FieldNo * 16);
                    end else
                        Module.AddInstr("ALI Opcode"::REC_TESTFIELD, Handle, FieldNo, 0);
                end;
            36: // FieldError(field [, Text])
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    Reg := 0;
                    if Ast.GetExtra(Node) = 2 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                        Reg := ToTextReg(Module, Cls, Reg);
                    end;
                    Module.AddInstr("ALI Opcode"::REC_FIELDERROR, Handle, FieldNo, Reg);
                end;
            37: // FieldName(field) -> Text
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIELDNAME, OutReg, Handle, FieldNo);
                end;
            38: // FieldCaption(field) -> Text
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIELDCAPTION, OutReg, Handle, FieldNo);
                end;
            39: // TableName() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_TABLENAME, OutReg, Handle, 0);
                end;
            40: // TableCaption() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_TABLECAPTION, OutReg, Handle, 0);
                end;
            41: // FullyQualifiedName() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FQNAME, OutReg, Handle, 0);
                end;
            42: // SetCurrentKey(field,...) — field numbers pushed into the operand pool (§7.5)
                begin
                    ArgCount := Ast.GetExtra(Node);
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(Ast.GetSlotIndex(Ast.GetChild(Node, k)));
                    Module.AddInstr("ALI Opcode"::REC_SETCURRENTKEY, Handle, OperStart, ArgCount);
                end;
            43: // Ascending([Boolean]) — 0 args = getter, 1 arg = setter
                if Ast.GetExtra(Node) = 1 then begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_ASCENDING_SET, Handle, Reg, 0);
                end else begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_ASCENDING_GET, Handle, OutReg, 0);
                end;
            44: // SetAscending(field, Boolean)
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_SETASCENDING, Handle, FieldNo, Reg);
                end;
            45: // GetAscending(field) -> Bool
                begin
                    FieldNo := Ast.GetSlotIndex(Ast.GetChild(Node, 1));
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETASCENDING, Handle, FieldNo, OutReg);
                end;
            46: // CurrentKey() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_CURRENTKEY, OutReg, Handle, 0);
                end;
            47: // Mark([Boolean]) — 0 args = getter, 1 arg = setter
                if Ast.GetExtra(Node) = 1 then begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_MARK_SET, Handle, Reg, 0);
                end else begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_MARK_GET, Handle, OutReg, 0);
                end;
            48: // ClearMarks()
                Module.AddInstr("ALI Opcode"::REC_CLEARMARKS, Handle, 0, 0);
            49: // MarkedOnly([Boolean]) — 0 args = getter, 1 arg = setter
                if Ast.GetExtra(Node) = 1 then begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_MARKEDONLY_SET, Handle, Reg, 0);
                end else begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_MARKEDONLY_GET, Handle, OutReg, 0);
                end;
            50: // GetPosition([Boolean]) -> Text
                begin
                    Trigg := 0;
                    if Ast.GetExtra(Node) = 1 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 1);
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETPOSITION, OutReg, Handle, Trigg);
                end;
            51: // SetPosition(Text)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ToTextReg(Module, Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_SETPOSITION, Handle, Reg, 0);
                end;
            52: // GetView([Boolean]) -> Text
                begin
                    Trigg := 0;
                    if Ast.GetExtra(Node) = 1 then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 1);
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETVIEW, OutReg, Handle, Trigg);
                end;
            53: // SetView(Text)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ToTextReg(Module, Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_SETVIEW, Handle, Reg, 0);
                end;
            54: // ChangeCompany([Text])
                begin
                    Reg := 0;
                    if Ast.GetExtra(Node) = 1 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ToTextReg(Module, Cls, Reg);
                    end;
                    Module.AddInstr("ALI Opcode"::REC_CHANGECOMPANY, Handle, Reg, 0);
                end;
            55: // CurrentCompany() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_CURRENTCOMPANY, OutReg, Handle, 0);
                end;
            56: // GetFilters() -> Text
                begin
                    OutCls := "ALI Register Class"::"Text";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETFILTERS, OutReg, Handle, 0);
                end;
            57: // HasFilter() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_HASFILTER, Handle, OutReg, 0);
                end;
            58, 59, 60, 61, 62:
                // SetAutoCalcFields / SetLoadFields / AddLoadFields / LoadFields /
                // AreFieldsLoaded(field,...) -> Bool. Field numbers pushed into the operand pool
                // (like CalcFields); C = destBoolReg*32 + count so the result is also carried.
                begin
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    OperStart := Module.OperandCount() + 1;
                    for k := 1 to ArgCount do
                        Module.AddOperand(Ast.GetSlotIndex(Ast.GetChild(Node, k)));
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    case MethodId of
                        58:
                            Module.AddInstr("ALI Opcode"::REC_SETAUTOCALCFIELDS, Handle, OperStart, OutReg * 32 + ArgCount);
                        59:
                            Module.AddInstr("ALI Opcode"::REC_SETLOADFIELDS, Handle, OperStart, OutReg * 32 + ArgCount);
                        60:
                            Module.AddInstr("ALI Opcode"::REC_ADDLOADFIELDS, Handle, OperStart, OutReg * 32 + ArgCount);
                        61:
                            Module.AddInstr("ALI Opcode"::REC_LOADFIELDS, Handle, OperStart, OutReg * 32 + ArgCount);
                        62:
                            Module.AddInstr("ALI Opcode"::REC_AREFIELDSLOADED, Handle, OperStart, OutReg * 32 + ArgCount);
                    end;
                end;
            63: // LockTable([Boolean [, Boolean]]) — first arg is the (const-folded) wait flag
                begin
                    Trigg := 0;
                    if (Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr) and (Ast.GetExtra(Node) >= 1) then
                        Trigg := BoolFlagFromArg(Tokens, Ast, Node, 1);
                    Module.AddInstr("ALI Opcode"::REC_LOCKTABLE, Handle, Trigg, 0);
                end;
            64: // ReadConsistency() -> Bool (getter only)
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_READCONSISTENCY_GET, Handle, OutReg, 0);
                end;
            65: // FieldCount() -> Integer
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIELDCOUNT, Handle, OutReg, 0);
                end;
            66: // FieldExist(fieldNo) -> Bool — field number is a live int register
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIELDEXIST, OutReg, Handle, Reg);
                end;
            67: // KeyCount() -> Integer
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_KEYCOUNT, Handle, OutReg, 0);
                end;
            68: // CurrentKeyIndex([Integer]) — 0 args = getter, 1 arg = setter
                begin
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    if ArgCount = 1 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                        Module.AddInstr("ALI Opcode"::REC_CURRENTKEYINDEX_SET, Handle, Reg, 0);
                    end else begin
                        OutCls := "ALI Register Class"::Int;
                        OutReg := AllocTemp(OutCls);
                        Module.AddInstr("ALI Opcode"::REC_CURRENTKEYINDEX_GET, Handle, OutReg, 0);
                    end;
                end;
            69: // RecordId() -> RecordID
                begin
                    OutCls := "ALI Register Class"::"RecordId";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_RECORDID_GET, OutReg, Handle, 0);
                end;
            70: // FilterGroup([Integer]) — 0 args = getter, 1 arg = setter; both yield an Int result
                begin
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    if ArgCount = 1 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                        Module.AddInstr("ALI Opcode"::REC_FILTERGROUP_SET, Handle, Reg, OutReg);
                    end else
                        Module.AddInstr("ALI Opcode"::REC_FILTERGROUP_GET, Handle, OutReg, 0);
                end;
            71: // Find([Text]) -> Bool. The Which selector ('-','+','=','<','>','<=','>=') is
                // optional and defaults to '=' like native AL. Conditional (result consumed)
                // suppresses no-match; statement form throws (addDataError).
                begin
                    if (Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr) and (Ast.GetExtra(Node) >= 1) then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ToTextReg(Module, Cls, Reg);
                    end else begin
                        Reg := AllocTemp("ALI Register Class"::"Text");
                        Module.AddInstr("ALI Opcode"::LOAD_CONST_T, Reg, Module.AddConstText('='), 0);
                    end;
                    Cond := 0;
                    if WantResult then
                        Cond := 1;
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_FIND_TEXT, Handle, Reg, OutReg * 2 + Cond);
                end;
            72: // GetBySystemId(Guid) -> Bool — same optional-return semantics as Get.
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Guid);
                    Cond := 0;
                    if WantResult then
                        Cond := 1;
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_GETBYSYSTEMID, Handle, Reg, OutReg * 2 + Cond);
                end;
            73: // AddLink(url [, description]) -> Int. C packs descReg (high) | destIntReg;
                // descReg 0 = the no-description overload.
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ToTextReg(Module, Cls, Reg);
                    Reg2 := 0;
                    if Ast.GetExtra(Node) = 2 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg2);
                        Reg2 := ToTextReg(Module, Cls, Reg2);
                    end;
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_ADDLINK, Handle, Reg, Reg2 * 8192 + OutReg);
                end;
            74: // DeleteLink(Integer)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                    Module.AddInstr("ALI Opcode"::REC_DELETELINK, Handle, Reg, 0);
                end;
            75: // DeleteLinks()
                Module.AddInstr("ALI Opcode"::REC_DELETELINKS, Handle, 0, 0);
            76: // CopyLinks(var Record) — src handle resolved generically (like TransferFields)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::REC_COPYLINKS, Handle, Reg, 0);
                end;
            77: // HasLinks() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_HASLINKS, Handle, OutReg, 0);
                end;
            78: // ReadIsolation([Integer]) — 0 args = getter (-> Int ordinal), 1 arg = setter.
                // ArgCount computed with the InvocationExpr guard so a parenless property read
                // (`Rec.ReadIsolation`) is a getter, not a mis-parsed setter (its ExtraInt is the
                // member NameId, not an arg count).
                begin
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    if ArgCount = 1 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                        Module.AddInstr("ALI Opcode"::REC_READISOLATION_SET, Handle, Reg, 0);
                    end else begin
                        OutCls := "ALI Register Class"::Int;
                        OutReg := AllocTemp(OutCls);
                        Module.AddInstr("ALI Opcode"::REC_READISOLATION_GET, Handle, OutReg, 0);
                    end;
                end;
            79: // SetPermissionFilter()
                Module.AddInstr("ALI Opcode"::REC_SETPERMISSIONFILTER, Handle, 0, 0);
            80: // SecurityFiltering([Integer]) — 0 args = getter (-> Int ordinal), 1 arg = setter
                begin
                    if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
                        ArgCount := Ast.GetExtra(Node)
                    else
                        ArgCount := 0;
                    if ArgCount = 1 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer);
                        Module.AddInstr("ALI Opcode"::REC_SECURITYFILTERING_SET, Handle, Reg, 0);
                    end else begin
                        OutCls := "ALI Register Class"::Int;
                        OutReg := AllocTemp(OutCls);
                        Module.AddInstr("ALI Opcode"::REC_SECURITYFILTERING_GET, Handle, OutReg, 0);
                    end;
                end;
            81: // RecordLevelLocking() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_RECORDLEVELLOCKING, Handle, OutReg, 0);
                end;
        end;
    end;

    // RecordID method invocation (GetRecord/TableNo). Node SymbolId = RecordIdMethodMark() -
    // methodId. Only TableNo() (id 2) ever reaches here — GetRecord() (id 1) is bound and
    // lowered exclusively via the dedicated 'RecVar := idExpr.GetRecord();' assignment path
    // (BindAssignment / LowerAssignment); the binder rejects any other use of GetRecord(),
    // so this dispatch never sees it.
    local procedure LowerRecordIdMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        CalleeNode: Integer;
        Cls: Integer;
        MethodId: Integer;
        RecvNode: Integer;
        Reg: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := RecordIdMethodMark() - Ast.GetSymbolId(Node);
        // Parenless call (`id.TableNo` — no parens): Node IS the MemberAccessExpr itself, so
        // its own child 0 is the receiver (mirror LowerRecordMethod's same distinction).
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0)
        else
            CalleeNode := Node;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, Cls, Reg);
        if MethodId = 2 then begin
            OutCls := "ALI Register Class"::Int;
            OutReg := AllocTemp(OutCls);
            Module.AddInstr("ALI Opcode"::RECID_TABLENO, OutReg, Reg, 0);
        end;
    end;

    // Stream method invocation (§19.7). Node SymbolId = StreamMethodMark() - methodId; the
    // receiver's slot (callee child 0) is the stream handle. Method ids: 1 WriteText
    // 2 WriteLine 3 ReadText 4 EOS 5 Length 6 Link.
    local procedure LowerStreamMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        LenReg: Integer;
        MethodId: Integer;
        OtherHandle: Integer;
        Packed: Integer;
        Reg: Integer;
        TargetSid: Integer;
        ValueT: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := StreamMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`Ostr.EOS`, `Ostr.Length` — 0-arg only): Node IS the MemberAccessExpr.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0)
        else
            CalleeNode := Node;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        case MethodId of
            1:  // WriteText([text[, length]]) — C = length reg, 0 = absent, -1 = zero-arg form
                begin
                    ArgCount := StreamArgCount(Ast, Node);
                    if ArgCount = 0 then
                        Module.AddInstr("ALI Opcode"::STRM_WRITETEXT, Handle, 0, -1)
                    else begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                        Reg := ToTextReg(Module, Cls, Reg);
                        LenReg := 0;
                        if ArgCount = 2 then begin
                            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, LenReg);
                            LenReg := ConvertToType(Module, Cls, LenReg, "ALI TypeKind"::Integer);
                        end;
                        Module.AddInstr("ALI Opcode"::STRM_WRITETEXT, Handle, Reg, LenReg);
                    end;
                end;
            2:  // WriteLine(text)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Reg := ToTextReg(Module, Cls, Reg);
                    Module.AddInstr("ALI Opcode"::STRM_WRITELINE, Handle, Reg, 0);
                end;
            3:  // ReadText(var text[, length]) -> Integer (chars read). The text lands in a temp
                // routed through StoreToSym, same contract as Read (8).
                begin
                    TargetSid := Ast.GetSymbolId(Ast.GetChild(Node, 1));
                    if TargetSid <= 0 then
                        exit;
                    LenReg := LowerStreamReadLength(Tokens, Ast, Symbols, Module, Node);
                    Reg := AllocTemp("ALI Register Class"::"Text");
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::STRM_READTEXT, Reg, Handle, OutReg * 100000 + LenReg);
                    StoreToSym(Module, Symbols, TargetSid, "ALI Register Class"::"Text", Reg);
                end;
            4:  // EOS() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::STRM_EOS, OutReg, Handle, 0);
                end;
            5:  // Length() -> Int
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::STRM_LENGTH, OutReg, Handle, 0);
                end;
            6:  // Link(outStream) — pair handles (share backing)
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, OtherHandle);
                    Module.AddInstr("ALI Opcode"::STRM_LINK, Handle, OtherHandle, 0);
                end;
            7:  // Write(value) -> Integer (bytes) — native typed binary write
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    ValueT := Ast.GetTypeOrd(Ast.GetChild(Node, 1));
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::STRM_WRITEVAL, Handle, Reg, OutReg * 100000 + ValueT * 16 + Cls);
                end;
            8:  // Read(var target[, length]) -> Integer (bytes) — native typed binary read.
                // The value lands in a temp of the target's own class and is then routed
                // through StoreToSym, which owns the local/var-param/global storage shapes
                // (and the Text[n]/Code length check) — same contract as DICT_TRYGET.
                begin
                    TargetSid := Ast.GetSymbolId(Ast.GetChild(Node, 1));
                    if TargetSid <= 0 then
                        exit;
                    LenReg := LowerStreamReadLength(Tokens, Ast, Symbols, Module, Node);
                    ValueT := Symbols.GetType(TargetSid);
                    Cls := TypeRules.RegClassFor(ValueT);
                    Reg := AllocTemp(Cls);
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Packed := OutReg * 100000 + ValueT * 16 + Cls;
                    // C has no room left for a Length reg: spill both to the operand pool, C = -poolIdx.
                    if LenReg > 0 then begin
                        Packed := -Module.AddOperand(Packed);
                        Module.AddOperand(LenReg);
                    end;
                    Module.AddInstr("ALI Opcode"::STRM_READVAL, Reg, Handle, Packed);
                    StoreToSym(Module, Symbols, TargetSid, Cls, Reg);
                end;
            9:  // Position -> Integer (0 args) / Position(newPos) (1 arg)


                if StreamArgCount(Ast, Node) = 1 then begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), Cls, Reg);
                    Module.AddInstr("ALI Opcode"::STRM_POSSET, Handle, ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer), 0);
                end else begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::STRM_POSGET, OutReg, Handle, 0);
                end;
            10: // ResetPosition()
                Module.AddInstr("ALI Opcode"::STRM_RESETPOS, Handle, 0, 0);
        end;
    end;

    // Argument count of a stream method call. A paren-less method (`i.EOS`, `i.Position`) IS
    // the MemberAccessExpr, whose ExtraInt is the member NameId, not a count — mirrors the
    // binder's own dual-shape read in BindStreamMethod.
    local procedure StreamArgCount(var Ast: Codeunit "ALI Ast Store"; Node: Integer): Integer
    begin
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            exit(Ast.GetExtra(Node));
        exit(0);
    end;

    // Optional Length (2nd arg) of Read/ReadText as an Int register; 0 = absent.
    local procedure LowerStreamReadLength(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer): Integer
    var
        Cls: Integer;
        Reg: Integer;
    begin
        if StreamArgCount(Ast, Node) < 2 then
            exit(0);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 2), Cls, Reg);
        exit(ConvertToType(Module, Cls, Reg, "ALI TypeKind"::Integer));
    end;

    // `inStream.Position := n` — the binder re-marked the target with stream method id 11
    // (see "ALI Binder".TryBindStreamPropertySet); emit the setter, not a record field store.
    local procedure LowerStreamPropertyStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        Handle: Integer;
        HandleCls: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
    begin
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(TargetNode, 0), HandleCls, Handle);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        Module.AddInstr("ALI Opcode"::STRM_POSSET, Handle, ConvertToType(Module, SrcCls, SrcReg, "ALI TypeKind"::Integer), 0);
    end;

    // TextBuilder method invocation (M9). Node SymbolId = TextBuilderMethodMark() - methodId;
    // the receiver's slot (callee child 0) is the TextBuilder handle. Every method's args are
    // plain values, so this reuses the CALL_BUILTIN_LIVE-style operand-pool convention
    // uniformly (unlike stream methods, which have one arg shape each). Method ids: see
    // "ALI Binder".TextBuilderMethodId.
    local procedure LowerTextBuilderMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        Reg: Integer;
        ResultT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := TextBuilderMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`x := Tb.Length`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        // Two-pass: lower every arg before pushing any of them to the pool (an arg can itself
        // be a nested pool-based construct, e.g. a builtin call or 3+-term CONCAT_N).
        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr("ALI Opcode"::TB_METHOD, Handle, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);
    end;

    // BigText (ids 1-49) and SecretText (ids 50-59) method invocation — one mark, one helper,
    // two opcodes. The receiver lowers to a plain register: an Int HANDLE for BigText, the Text
    // value itself for SecretText (which has no handle space at all). Args ride the operand pool
    // with the CALL_BUILTIN_LIVE convention. Method ids: see "ALI Binder".BigTextMethodId.
    local procedure LowerBigTextMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        IsTextOut: Boolean;
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        Reg: Integer;
        ResultT: Integer;
        TextOutSid: Integer;
        TextOutTmp: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := BigTextMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`n := bt.Length`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        // GetSubText(var Text, ...) (ids 5/6): arg 1 is a scalar var-out — pass a fresh temp Text
        // register in its operand slot and StoreToSym it back afterwards (the HttpContent.ReadAs
        // mechanism, which handles local / global / var-param targets uniformly).
        IsTextOut := (MethodId = 5) or (MethodId = 6);
        if IsTextOut then begin
            TextOutSid := Ast.GetSymbolId(Ast.GetChild(Node, 1));
            TextOutTmp := AllocTemp("ALI Register Class"::"Text");
            ArgClsList.Add("ALI Register Class"::"Text");
            ArgRegList.Add(TextOutTmp);
        end;
        // Two-pass: lower every remaining arg before pushing any to the pool (an arg can itself
        // be a nested pool-based construct, e.g. a builtin call or 3+-term CONCAT_N).
        for k := 1 to ArgCount do
            if not (IsTextOut and (k = 1)) then begin
                LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                ArgClsList.Add(Cls);
                ArgRegList.Add(Reg);
            end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgClsList.Count() do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        if MethodId >= 50 then
            Module.AddInstr("ALI Opcode"::SECRET_METHOD, Handle, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount)
        else
            Module.AddInstr("ALI Opcode"::BIGTEXT_METHOD, Handle, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);

        if IsTextOut then
            StoreToSym(Module, Symbols, TextOutSid, "ALI Register Class"::"Text", TextOutTmp);
    end;

    // Media / MediaSet field method (`Rec.Picture.MediaId()`). The receiver is the `Rec.Picture`
    // field node: its own child 0 lowers to the record handle and its bind-time SlotIndex is the
    // field number (same shape as LowerBlobMethod). C only carries the method id — the field
    // number, the out register and the single optional argument all ride the operand pool, since
    // there are four values to pass and C has room for two. See "ALI Opcode"::MEDIA_METHOD.
    local procedure LowerMediaMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCls: Integer;
        ArgReg: Integer;
        CalleeNode: Integer;
        FieldNo: Integer;
        FieldNode: Integer;
        Handle: Integer;
        HandleCls: Integer;
        MethodId: Integer;
        OperStart: Integer;
        ResultT: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := MediaMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`Rec.Picture.HasValue`): Node IS the MemberAccessExpr.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0)
        else
            CalleeNode := Node;
        FieldNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(FieldNode, 0), HandleCls, Handle);
        FieldNo := Ast.GetSlotIndex(FieldNode);

        // ExportStream(OutStream) and Item(Integer) are the only arg-taking ids.
        if (MethodId = 1) or (MethodId = 21) then
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), ArgCls, ArgReg);

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;

        OperStart := Module.OperandCount() + 1;
        Module.AddOperand(FieldNo);
        Module.AddOperand(OutReg * 16 + OutCls);
        Module.AddOperand(ArgReg * 16 + ArgCls);
        Module.AddInstr("ALI Opcode"::MEDIA_METHOD, Handle, OperStart, MethodId);
    end;

    // ===== M7 builtin calls (§1.1/§8/§19.4) =====
    //
    // Node SymbolId = BuiltinCallMark() - BId. Two invocation shapes reach here:
    //   * free function `Fn(a,b,c)`     — callee child 0 = NameExpr, args = children 1..N
    //   * method `recv.Fn(a,b)` (§19.4) — callee child 0 = MemberAccessExpr; that node's own
    //     child 0 is the RECEIVER, which must be pushed as the FIRST operand-pool argument
    //     (registry rows count the receiver as param 1, mirroring the free-function twin).
    // Evaluate/Clear are special-cased separately (EVALUATE_TARGET/CLEAR_TARGET) because
    // their first argument is a var TARGET, not a value.
    local procedure LowerBuiltinCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        Registry: Codeunit "ALI Builtin Registry";
        IsMethodForm: Boolean;
        IsNative: Boolean;
        ArgCount: Integer;
        BId: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        k: Integer;
        OperStart: Integer;
        Reg: Integer;
        ResultT: Integer;
        TargetSid: Integer;
        TargetT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
        BName: Text;
    begin
        OutCls := 0;
        OutReg := 0;
        BId := BuiltinCallMark() - Ast.GetSymbolId(Node);
        // A native catalogue row is named after its codeunit METHOD (Type Helper's `Evaluate`),
        // which must not fall into the special cases below that key on the builtin's name.
        Registry.EnsureBuilt();
        IsNative := Registry.GetDomain(BId) = "ALI Builtin Domain"::Native;
        if not IsNative then
            BName := UpperCase(BuiltinNameOf(BId));

        if (BName = 'EVALUATE') or (BName = 'CLEAR') then begin
            LowerTargetingBuiltin(Tokens, Ast, Symbols, Module, Node, BName, OutCls, OutReg);
            exit;
        end;

        if (BName = 'ARRAYLEN') or (BName = 'COMPRESSARRAY') or (BName = 'COPYARRAY') then begin
            LowerArrayBuiltin(Tokens, Ast, Symbols, Module, Node, BName, OutCls, OutReg);
            exit;
        end;

        if BName = 'MAXSTRLEN' then begin
            LowerMaxStrLen(Ast, Module, Node, OutCls, OutReg);
            exit;
        end;

        // ClearAll: expanded at COMPILE time into one typed CLEAR_TARGET per MODULE-level
        // variable (locals stay untouched — documented scope). Replaces the interpreter-side
        // register-bank sweep, which zeroed the Int registers HOLDING handles (Record/List/
        // Dict/Array/TextBuilder/Http*/Json*) — detaching every global handle from its
        // variable instead of clearing its content. CLEAR_TARGET's typed arms clear handle
        // content in place. Labels are compile-time constants — skipped.
        if BName = 'CLEARALL' then begin
            for TargetSid := 1 to Symbols.Count() do
                if Symbols.GetKind(TargetSid) = "ALI Symbol Kind"::GlobalVar then begin
                    TargetT := Symbols.GetType(TargetSid);
                    if (TargetT <> "ALI TypeKind"::Label) and (TargetT <> "ALI TypeKind"::ErrorType) then
                        Module.AddInstr("ALI Opcode"::CLEAR_TARGET, Symbols.GetSlot(TargetSid), TargetT, ClearModeOf(Symbols, TargetSid));
                end;
            exit;
        end;

        // Bare form `Fn` (no parens, no arg list): Node is the leaf NameExpr itself, not an
        // InvocationExpr — no callee child to read, and always 0 args (binder only marks
        // this shape when MinArity = 0).
        if Ast.GetKind(Node) = "ALI NodeKind"::NameExpr then begin
            IsMethodForm := false;
            ArgCount := 0;
        end else if Ast.GetKind(Node) = "ALI NodeKind"::MemberAccessExpr then begin
            // Paren-less member builtin (`v.IsInteger`, `t.Split` w/o parens — 0-arg only): Node
            // IS the MemberAccessExpr; its own child 0 is the receiver (pushed as operand 1).
            CalleeNode := Node;
            IsMethodForm := true;
            ArgCount := 0;
        end else begin
            CalleeNode := Ast.GetChild(Node, 0);
            IsMethodForm := Ast.GetKind(CalleeNode) = "ALI NodeKind"::MemberAccessExpr;
            ArgCount := Ast.GetExtra(Node);
        end;
        // `TypeHelper.UrlEncode(s)`: the receiver names a stateless native codeunit and holds no
        // value (CodeunitRef has no register class) — it is not an operand. A NativeCodeunit
        // receiver (Data Compression) stays the method form: its handle is operand 1.
        if IsMethodForm and IsNative then
            if Ast.GetTypeOrd(Ast.GetChild(CalleeNode, 0)) = "ALI TypeKind"::CodeunitRef then
                IsMethodForm := false;

        // §D4: Format(x) arity-1 with x statically Option/Enum -> OPT_TO_TEXT (caption lookup
        // in "ALI Option Meta"), bypassing the generic CALL_BUILTIN_LIVE/TO_TEXT path (which
        // would just format the raw ordinal). Format(x, len)/Format(x, len, fmt) keep the
        // generic integer path (documented v1 scope — no per-value register tag exists).
        if (BName = 'FORMAT') and (not IsMethodForm) and (ArgCount = 1) then
            if LowerOptionFormat(Tokens, Ast, Symbols, Module, Node, OutCls, OutReg) then
                exit;

        // Two-pass: lower the receiver + every arg FIRST, only THEN push to the operand pool.
        // A receiver/arg can itself be a nested pool-based construct (a builtin call — e.g.
        // Message('x' + Format(y)) — or a 3+-term CONCAT_N); if we pushed while lowering,
        // that nested construct's own AddOperand calls would land between OperStart and this
        // call's entries and desync the read-back at CALL_BUILTIN_LIVE time (ALI990).
        if IsMethodForm then begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            // %1-substitution builtins (Message/Error/Confirm/StrSubstNo) format each arg
            // generically at runtime — an Option/Enum arg would show its raw ordinal there
            // (no per-value register tag exists, §D4 v1 scope note). Widen it to its CAPTION
            // text HERE instead, matching native AL (StrSubstNo/Message auto-format Option/Enum
            // via Format() semantics) and what Format(x) itself already does for this arg.
            if IsSubstArgBuiltin(BName) then
                WidenOptionArgToText(Ast, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;

        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgClsList.Count() do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr("ALI Opcode"::CALL_BUILTIN_LIVE, BId, OperStart, OutReg * 512 + OutCls * 32 + (ArgCount + BoolToInt(IsMethodForm)));

        // `var` parameters of a native row: the interpreter wrote the new value back into the
        // argument's own register; store it into the variable (a copy for a global / var-param,
        // the variable's own slot for a local — StoreToSym handles all three, plus Code/Text[n]).
        if IsNative and (Registry.GetVarMask(BId) <> 0) then
            for k := 1 to ArgCount do
                if Registry.IsVarParam(BId, k + BoolToInt(IsMethodForm)) then
                    StoreToSym(Module, Symbols, Ast.GetSymbolId(Ast.GetChild(Node, k)), ArgClsList.Get(k + BoolToInt(IsMethodForm)), ArgRegList.Get(k + BoolToInt(IsMethodForm)));
    end;

    // Message/Error/Confirm/StrSubstNo — the ONLY builtins whose args are generically
    // %1-substituted (matches "ALI Builtin Registry"'s Variadic() arity marker exactly;
    // every other builtin has fixed, position-typed args that must stay raw).
    local procedure IsSubstArgBuiltin(BName: Text): Boolean
    begin
        exit((BName = 'MESSAGE') or (BName = 'ERROR') or (BName = 'CONFIRM') or (BName = 'STRSUBSTNO'));
    end;

    // If ArgNode is statically Option/Enum with a known set id, replace (Cls, Reg) with a
    // fresh Text register holding its CAPTION (OPT_TO_TEXT) — otherwise leaves them untouched.
    local procedure WidenOptionArgToText(var Ast: Codeunit "ALI Ast Store"; var Module: Codeunit "ALI Module"; ArgNode: Integer; var Cls: Integer; var Reg: Integer)
    var
        ArgT: Integer;
        NewReg: Integer;
        SetId: Integer;
    begin
        ArgT := Ast.GetTypeOrd(ArgNode);
        if (ArgT <> "ALI TypeKind"::Option) and (ArgT <> "ALI TypeKind"::Enum) then
            exit;
        SetId := Ast.GetTypeArg(ArgNode);
        if SetId <= 0 then
            exit;
        NewReg := AllocTemp("ALI Register Class"::"Text");
        Module.AddInstr("ALI Opcode"::OPT_TO_TEXT, NewReg, Reg, SetId);
        Cls := "ALI Register Class"::"Text";
        Reg := NewReg;
    end;

    // §D4: Format(x) where x is statically TOption/TEnum with a known set id -> OPT_TO_TEXT.
    // Returns false (no instruction emitted, caller falls back to the generic path) when the
    // sole argument isn't Option/Enum-typed or carries no set id (TypeArg = 0 — should not
    // happen once the binder is fully wired, but the fallback keeps this defensive).
    local procedure LowerOptionFormat(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer): Boolean
    var
        ArgNode: Integer;
        ArgT: Integer;
        Cls: Integer;
        Reg: Integer;
        SetId: Integer;
    begin
        ArgNode := Ast.GetChild(Node, 1);
        ArgT := Ast.GetTypeOrd(ArgNode);
        if (ArgT <> "ALI TypeKind"::Option) and (ArgT <> "ALI TypeKind"::Enum) then
            exit(false);
        SetId := Ast.GetTypeArg(ArgNode);
        if SetId <= 0 then
            exit(false);
        LowerExpr(Tokens, Ast, Symbols, Module, ArgNode, Cls, Reg);
        OutCls := "ALI Register Class"::"Text";
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::OPT_TO_TEXT, OutReg, Reg, SetId);
        exit(true);
    end;

    // Evaluate(var target, text[, fmt]) / Clear(var target). Node SlotIndex = target's
    // TypeOrd (binder contract, §19.8 targeting builtins). Target must be a plain
    // assignable variable — its slot/class are read directly from the symbol (no register
    // eval needed for the target itself, matching the SetRange/Validate field-arg pattern).
    local procedure LowerTargetingBuiltin(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; BName: Text; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        Cls: Integer;
        IsGlobal: Integer;
        k: Integer;
        OperStart: Integer;
        Reg: Integer;
        TargetCls: Integer;
        TargetNode: Integer;
        TargetSid: Integer;
        TargetSlot: Integer;
        TargetT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
        VisitedInstances: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        TargetNode := Ast.GetChild(Node, 1);
        TargetSid := Ast.GetSymbolId(TargetNode);
        TargetT := Ast.GetSlotIndex(Node);
        TargetCls := TypeRules.RegClassFor(TargetT);
        TargetSlot := Symbols.GetSlot(TargetSid);
        IsGlobal := ClearModeOf(Symbols, TargetSid);

        if BName = 'CLEAR' then begin
            if TargetT = "ALI TypeKind"::CodeunitRef then begin
                EmitClearInstance(Symbols, Module, Symbols.GetInstIdx(TargetSid), VisitedInstances);
                exit;
            end;
            Module.AddInstr("ALI Opcode"::CLEAR_TARGET, TargetSlot, TargetT, IsGlobal);
            exit;
        end;

        // Evaluate: push text (+ optional format) args into the operand pool, then the
        // runtime resolves the typed native Evaluate overload from TargetT (C-packed).
        ArgCount := Ast.GetExtra(Node);
        for k := 2 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgClsList.Count() do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
        // Evaluate is valid in expression context too (§19.8: `exit(Evaluate(...))`), unlike
        // Clear — allocate a Bool result reg so ExecEvaluateTarget has somewhere to write the
        // success flag. C packing: TargetT can reach ~90 and OutReg can reach MaxBoolRegisters
        // (4096), so the fields are separated by decimal magnitude (OutReg's headroom is far
        // below Int32's range) rather than bit-packed, to keep each field unambiguous.
        OutCls := "ALI Register Class"::"Boolean";
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::EVALUATE_TARGET, TargetSlot, OperStart, OutReg * 100000 + TargetT * 1000 + IsGlobal * 100 + ArgCount);
    end;

    // Clear(MyCU) on an interpreted codeunit variable = native "fresh instance": every global of
    // that variable's phase-B2 block back to its default, handles cleared in place (the typed
    // CLEAR_TARGET arms). The instance is known at compile time, so it rides in C (mode 3,
    // `3 + Inst*4`) and the offsets are the globals' own slots. A codeunit-typed global is its
    // own instance and is reset the same way; Visited stops a cycle between codeunits. An
    // instance of an object that declares no globals (or was never harvested) emits nothing.
    local procedure EmitClearInstance(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Inst: Integer; var Visited: List of [Integer])
    var
        ObjKey: Integer;
        Sid: Integer;
        T: Integer;
    begin
        if Inst <= 0 then
            exit;
        if Visited.Contains(Inst) then
            exit;
        Visited.Add(Inst);
        ObjKey := Symbols.InstanceOwner(Inst);
        foreach Sid in Symbols.GlobalSids() do
            if Symbols.GetKind(Sid) = "ALI Symbol Kind"::GlobalVar then
                if Symbols.GetOwnerObjKey(Sid) = ObjKey then begin
                    T := Symbols.GetType(Sid);
                    if T = "ALI TypeKind"::CodeunitRef then
                        EmitClearInstance(Symbols, Module, Symbols.GetInstIdx(Sid), Visited)
                    else
                        if (T <> "ALI TypeKind"::Label) and (T <> "ALI TypeKind"::ErrorType) then
                            if (T = "ALI TypeKind"::Array) or (TypeRules.RegClassFor(T) > 0) then
                                Module.AddInstr("ALI Opcode"::CLEAR_TARGET, Symbols.GetSlot(Sid), T, 3 + Inst * 4);
                end;
    end;

    local procedure BoolToInt(B: Boolean): Integer
    begin
        if B then
            exit(1);
        exit(0);
    end;

    // ArrayLen/CompressArray/CopyArray — array operands are now HANDLES (§20.2), loaded the
    // same way any Int-class variable value is (LoadSymValue), so all three fit the same
    // shape as List/Dict method lowering. ArrayLen folds to an integer constant (per-dimension
    // via GetArrayDims, §20.9(5)); CompressArray/CopyArray get dedicated handle-based opcodes.
    local procedure LowerArrayBuiltin(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; BName: Text; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        ArrSid1: Integer;
        ArrSid2: Integer;
        DimVal: Integer;
        HandleCls1: Integer;
        HandleCls2: Integer;
        HandleReg1: Integer;
        HandleReg2: Integer;
        HasLen: Integer;
        LenReg: Integer;
        N: Integer;
        OperStart: Integer;
        PosCls: Integer;
        PosReg: Integer;
        Dims: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        ArgCount := Ast.GetExtra(Node);

        case BName of
            'ARRAYLEN':
                begin
                    ArrSid1 := Ast.GetSymbolId(Ast.GetChild(Node, 1));
                    DimVal := Ast.GetSlotIndex(Node);
                    if DimVal = 0 then
                        DimVal := 1;
                    Dims := Symbols.GetArrayDims(ArrSid1);
                    N := Dims.Get(DimVal);
                    OutCls := TypeRules.RegClassFor("ALI TypeKind"::Integer);
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OutReg, Module.AddConstInt(N), 0);
                end;
            'COMPRESSARRAY':
                begin
                    ArrSid1 := Ast.GetSymbolId(Ast.GetChild(Node, 1));
                    LoadSymValue(Module, Symbols, ArrSid1, HandleCls1, HandleReg1);
                    OutCls := TypeRules.RegClassFor("ALI TypeKind"::Integer);
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::ARR_COMPRESS, HandleReg1, OutReg, 0);
                end;
            'COPYARRAY':
                begin
                    ArrSid1 := Ast.GetSymbolId(Ast.GetChild(Node, 1));
                    ArrSid2 := Ast.GetSymbolId(Ast.GetChild(Node, 2));
                    LoadSymValue(Module, Symbols, ArrSid1, HandleCls1, HandleReg1);
                    LoadSymValue(Module, Symbols, ArrSid2, HandleCls2, HandleReg2);
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 3), PosCls, PosReg);
                    PosReg := ConvertToType(Module, PosCls, PosReg, "ALI TypeKind"::Integer);
                    HasLen := 0;
                    LenReg := 0;
                    if ArgCount = 4 then begin
                        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 4), PosCls, LenReg);
                        LenReg := ConvertToType(Module, PosCls, LenReg, "ALI TypeKind"::Integer);
                        HasLen := 1;
                    end;
                    // [destHandleReg, srcHandleReg, posReg, lenReg] — too many fields for A/B/C.
                    OperStart := Module.OperandCount() + 1;
                    Module.AddOperand(HandleReg1);
                    Module.AddOperand(HandleReg2);
                    Module.AddOperand(PosReg);
                    Module.AddOperand(LenReg);
                    Module.AddInstr("ALI Opcode"::ARR_COPY, OperStart, TypeRules.RegClassFor(ArrayElemType(Symbols.GetTypeArg(ArrSid1))), HasLen);
                end;
        end;
    end;

    // MaxStrLen(x) is a COMPILE-TIME constant — the declared max length of the argument's
    // Text/Code type (Ast TypeArg, set on the arg node by the binder's BindName). Unbounded
    // Text (TypeArg = 0) yields 2147483647, matching native AL. Emitted as a plain int
    // constant like ArrayLen — no runtime CALL_BUILTIN_LIVE.
    // ponytail: only var/param args carry a declared length; a Text literal arg (MaxStrLen('ab'))
    // folds to MaxInt, not 2 — add a NodeStrLiteral length case if that ever matters.
    local procedure LowerMaxStrLen(var Ast: Codeunit "ALI Ast Store"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        Len: Integer;
    begin
        Len := Ast.GetTypeArg(Ast.GetChild(Node, 1));
        if Len <= 0 then
            Len := 2147483647;      // unbounded Text -> native AL MaxInt
        OutCls := TypeRules.RegClassFor("ALI TypeKind"::Integer);
        OutReg := AllocTemp(OutCls);
        Module.AddInstr("ALI Opcode"::LOAD_CONST_I, OutReg, Module.AddConstInt(Len), 0);
    end;

    // Resolve a BuiltinId back to its uppercase name for the two special-cased builtins
    // (Evaluate/Clear) — small local table mirroring the registry's own names to avoid a
    // hard dependency from the Lowerer onto "ALI Builtin Registry" (the Lowerer otherwise
    // has none; keeping it AST/Module-only matches its existing dependency shape, §13).
    local procedure BuiltinNameOf(BId: Integer): Text
    var
        Registry: Codeunit "ALI Builtin Registry";
    begin
        Registry.EnsureBuilt();
        exit(Registry.GetName(BId));
    end;

    // The run-trigger boolean for Insert/Modify/Delete: only a literal true/false is honored
    // in M6 (const-folded to 0/1); a non-literal trigger arg defaults to false.
    local procedure TriggerFlagFromArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Integer
    begin
        exit(BoolFlagFromArg(Tokens, Ast, Node, 1));
    end;

    // Const-folded Boolean flag from an arbitrary arg index (§7.5 Insert/Modify/Copy/
    // TransferFields/Truncate flags): only a literal `true` sets the flag; a variable
    // bool argument is NOT read live here (matches the existing trigger-flag convention).
    local procedure BoolFlagFromArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; ArgIdx: Integer): Integer
    var
        ArgNode: Integer;
    begin
        ArgNode := Ast.GetChild(Node, ArgIdx);
        if (Ast.GetKind(ArgNode) = "ALI NodeKind"::LiteralExpr) and (Tokens.GetKind(Ast.GetMainToken(ArgNode)) = 21) then
            exit(1);        // true
        exit(0);
    end;

    local procedure ArrayElemType(TArg: Integer): Integer
    begin
        exit(TArg div 1000000);
    end;

    local procedure ArrayLen(TArg: Integer): Integer
    begin
        exit(TArg mod 1000000);
    end;

    // Mirror "ALI Binder".RecMethodMark() — the record-method SymbolId marker base.
    local procedure RecMethodMark(): Integer
    begin
        exit(-1000);
    end;

    // Mirror "ALI Binder".BuiltinCallMark() — the builtin-call SymbolId marker base (M7).
    local procedure BuiltinCallMark(): Integer
    begin
        exit(-3000);
    end;

    // Mirror "ALI Binder".StreamMethodMark() — the stream-method SymbolId marker base.
    local procedure StreamMethodMark(): Integer
    begin
        exit(-2000);
    end;

    // Mirror "ALI Binder".TextBuilderMethodMark() — the TextBuilder-method SymbolId marker
    // base (M9). Most negative of the four marks — checked first in both dispatch sites.
    local procedure TextBuilderMethodMark(): Integer
    begin
        exit(-4000);
    end;

    local procedure DialogMethodMark(): Integer
    begin
        exit(-8000);
    end;

    // Dialog method invocation (§8): void statement only. Node SymbolId = DialogMethodMark() -
    // methodId; receiver slot (callee child 0) = the Dialog handle. Args use the same
    // operand-pool live-read convention as TB_METHOD. C = MethodId*100 + ArgCount.
    local procedure LowerDialogMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        Reg: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        MethodId := DialogMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (0-arg only): Node IS the MemberAccessExpr.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        // Two-pass: lower every arg before pushing any to the pool (an arg may itself be a
        // nested pool-based construct).
        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        Module.AddInstr("ALI Opcode"::DLG_METHOD, Handle, OperStart, MethodId * 100 + ArgCount);
    end;

    // ===== Temp allocation (§7.2 reset-per-statement policy) =====

    local procedure ResetTemps()
    var
        Cls: Integer;
    begin
        for Cls := 1 to RegClassCnt do
            TempCount[Cls] := TempFloor[Cls];
    end;

    local procedure AllocTemp(Cls: Integer): Integer
    begin
        TempCount[Cls] += 1;
        if TempCount[Cls] > MaxTemp[Cls] then
            MaxTemp[Cls] := TempCount[Cls];
        exit(VarBase[Cls] + TempCount[Cls]);
    end;

    // ===== Loop / break bookkeeping =====

    local procedure PushLoop()
    begin
        BreakMarks.Add(BreakPCs.Count());
    end;

    local procedure PopLoop(var Module: Codeunit "ALI Module"; TargetPC: Integer)
    var
        Mark: Integer;
    begin
        Mark := BreakMarks.Get(BreakMarks.Count());
        BreakMarks.RemoveAt(BreakMarks.Count());
        while BreakPCs.Count() > Mark do begin
            Module.PatchA(BreakPCs.Get(BreakPCs.Count()), TargetPC);
            BreakPCs.RemoveAt(BreakPCs.Count());
        end;
    end;

    // ===== Statement marker (§7.4 debug map; P1: no STMT instruction) =====
    // Registers the statement's source position and stamps it onto every instruction the
    // statement emits (Module.InstrDbgRow). The runaway budget formerly charged by STMT is
    // now charged at BACK-EDGES (ClassifyBackEdges) + CALLs (interpreter PushFrame) only.

    local procedure EmitStmtMarker(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Module: Codeunit "ALI Module"; Node: Integer)
    var
        Col: Integer;
        Ln: Integer;
        Tok: Integer;
    begin
        // Was 5 cross-codeunit calls per statement (Count + GetLine + GetColumn + AddDebugRow +
        // SetDebugRow); GetLineCol folds the first three and AddAndSetDebugRow the last two.
        // GetLineCol leaves Ln/Col at 0 when the token index is out of range, which is exactly
        // the old else-branch, so the result is unchanged.
        Tok := Ast.GetMainToken(Node);
        Tokens.GetLineCol(Tok, Ln, Col);
        Module.AddAndSetDebugRow(Ln, Col);
    end;

    // ===== Dispatch-count fusion (P3) + back-edge classification (P1) =====

    // Emit a conditional branch on CondReg (target = A, patched later by the caller when 0).
    // When the immediately preceding instruction is the int compare that PRODUCED CondReg
    // (always a single-use lowerer temp there), the pair fuses into one branch-compare
    // opcode: the compare instruction is rewritten IN PLACE (same PC — a label pointing at
    // the compare still evaluates it), its A becomes the branch target, B/C stay the
    // compare operands. Returns the branch's PC for PatchA.
    local procedure EmitCondBranch(var Module: Codeunit "ALI Module"; BranchIfTrue: Boolean; CondReg: Integer): Integer
    var
        LastPC: Integer;
    begin
        // Peephole moved into "ALI Module" (one call instead of up to 5 across the boundary).
        LastPC := Module.TryFuseCondBranch(BranchIfTrue, CondReg);
        if LastPC > 0 then
            exit(LastPC);
        if BranchIfTrue then
            exit(Module.AddInstr("ALI Opcode"::JMP_IF_TRUE, 0, CondReg, 0));
        exit(Module.AddInstr("ALI Opcode"::JMP_IF_FALSE, 0, CondReg, 0));
    end;

    // Emit an int compare, folding an immediately preceding LOAD_CONST_I of one operand
    // into the CMP_xx_I_IMM form (the const load is removed — it was emitted solely for
    // that operand and is still the LAST instruction, so no label can point past it).
    // Left-literal folds by swapping the operand order and MIRRORING the comparison
    // (10 < i  <=>  i > 10). AllowLeftFold MUST be false when LReg is re-read after this
    // compare (case selector — removing its load would leave later reads unwritten).
    local procedure EmitCmpIntFused(var Module: Codeunit "ALI Module"; Group: Integer; OutReg: Integer; LReg: Integer; RReg: Integer; AllowLeftFold: Boolean)
    var
        ImmVal: Integer;
    begin
        // TryTakeLastConstInt folds the InstrCount/GetOp/GetA/GetB/GetConstInt/RemoveLastInstr
        // sequence into one call. Right operand first, then the mirrored left fold — same order,
        // and it only consumes the LOAD_CONST_I when the fold actually applies.
        if Module.TryTakeLastConstInt(RReg, ImmVal) then begin
            Module.AddInstr(429 + CmpGroupOffset(Group), OutReg, LReg, ImmVal);
            exit;
        end;
        if AllowLeftFold then
            if Module.TryTakeLastConstInt(LReg, ImmVal) then begin
                Module.AddInstr(429 + CmpGroupOffset(MirrorCmpGroup(Group)), OutReg, RReg, ImmVal);
                exit;
            end;
        Module.AddInstr(CmpOpcode("ALI Register Class"::Int, Group), OutReg, LReg, RReg);
    end;

    // EQ,NE,LT,LE,GT,GE -> 0..5 (operator groups OpEq..OpGe are dense, matching the order
    // of both the CMP_xx_I and CMP_xx_I_IMM opcode blocks).
    local procedure CmpGroupOffset(Group: Integer): Integer
    begin
        exit(Group - "ALI Op Group"::Eq);
    end;

    // Comparison mirrored across swapped operands: a < b <=> b > a (EQ/NE unchanged).
    local procedure MirrorCmpGroup(Group: Integer): Integer
    begin
        case true of
            (Group = "ALI Op Group"::Lt):
                exit("ALI Op Group"::Gt);
            (Group = "ALI Op Group"::Le):
                exit("ALI Op Group"::Ge);
            (Group = "ALI Op Group"::Gt):
                exit("ALI Op Group"::Lt);
            (Group = "ALI Op Group"::Ge):
                exit("ALI Op Group"::Le);
            else
                exit(Group);
        end;
    end;

    // P1: rewrite every jump/branch whose RESOLVED target is at or before its own PC to its
    // charged _BACK twin — any loop must cross one per iteration, so the runaway budget
    // stays enforced without a per-statement STMT charge. Runs once, after all lowering and
    // target patching completes. Fixed offsets: JMP(2)/JMP_IF_FALSE(3)/JMP_IF_TRUE(4) +374;
    // fused branches 379-402 +24.
    // Moved into "ALI Module".ClassifyBackEdges — it is a whole-module linear pass over columns
    // the Module owns, and running it from here cost up to 3 cross-codeunit calls per instruction.

    // Register-file capacity per class ("ALI Limits" — arrays hardcode the same numbers).
    local procedure MaxRegistersOfClass(Cls: Integer): Integer
    var
        Limits: Codeunit "ALI Limits";
    begin
        case Cls of
            "ALI Register Class"::Int:
                exit(Limits.MaxIntRegisters());
            "ALI Register Class"::Decimal:
                exit(Limits.MaxDecimalRegisters());
            "ALI Register Class"::Boolean:
                exit(Limits.MaxBoolRegisters());
            "ALI Register Class"::Text:
                exit(Limits.MaxTextRegisters());
            "ALI Register Class"::Variant:
                exit(Limits.MaxVariantRegisters());
            else
                exit(Limits.MaxScalarRegisters());
        end;
    end;

    // ===== Opcode selection =====

    // MOV_* : 32 + (class - 1) — classes 1..11 map to ordinals 32..42 in enum order.
    // RecordID (class 12) breaks the arithmetic (that ordinal range is taken by
    // LOAD_CONST_*) — MOV_RECID(350) is a separate appended opcode instead.
    local procedure MovOpcode(Cls: Integer): Integer
    begin
        if Cls = "ALI Register Class"::"RecordId" then
            exit("ALI Opcode"::MOV_RECID);
        if Cls = "ALI Register Class"::"DateFormula" then
            exit("ALI Opcode"::MOV_DF);
        exit(31 + Cls);
    end;

    // Comparison opcode: per-class base + (Group - OpEq) where order is EQ NE LT LE GT GE.
    // RecordID only ever reaches here with Group = OpEq/OpNeq (the binder's IsOrdered()
    // excludes RecordID, so LT/LE/GT/GE can never be lowered for it) — base 351 therefore
    // only ever yields 351 (EQ) or 352 (NE), never colliding with 353+ (REC_GET_BY_ID etc).
    local procedure CmpOpcode(Cls: Integer; Group: Integer): Integer
    var
        BaseOrd: Integer;
    begin
        case true of
            (Cls = "ALI Register Class"::Int):
                BaseOrd := 96;
            (Cls = "ALI Register Class"::"Decimal"):
                BaseOrd := 102;
            (Cls = "ALI Register Class"::"Text"):
                BaseOrd := 108;
            (Cls = "ALI Register Class"::"Boolean"):
                BaseOrd := 128;
            (Cls = "ALI Register Class"::BigInt):
                BaseOrd := 134;
            (Cls = "ALI Register Class"::"Date"):
                BaseOrd := 140;
            (Cls = "ALI Register Class"::"Time"):
                BaseOrd := 146;
            (Cls = "ALI Register Class"::"DateTime"):
                BaseOrd := 152;
            (Cls = "ALI Register Class"::"Duration"):
                BaseOrd := 160;
            (Cls = "ALI Register Class"::"RecordId"):
                BaseOrd := 351;
            (Cls = "ALI Register Class"::"DateFormula"):
                BaseOrd := 357;     // CMP_EQ_DF(357)/CMP_NE_DF(358) — equality only, mirrors RecordID
            else
                BaseOrd := 166;     // Guid
        end;
        exit(BaseOrd + (Group - "ALI Op Group"::Eq));
    end;

    // Arithmetic opcode per result class and operator group.
    local procedure ArithOpcode(Cls: Integer; Group: Integer): Integer
    begin
        case true of
            (Cls = "ALI Register Class"::Int):
                case true of
                    (Group = "ALI Op Group"::"Add"):
                        exit(64);   // ADD_I
                    (Group = "ALI Op Group"::Sub):
                        exit(65);
                    (Group = "ALI Op Group"::Mul):
                        exit(66);
                    (Group = "ALI Op Group"::IDiv):
                        exit(67);
                    else
                        exit(68);   // MOD_I
                end;
            (Cls = "ALI Register Class"::BigInt):
                case true of
                    (Group = "ALI Op Group"::"Add"):
                        exit(70);   // ADD_BIG
                    (Group = "ALI Op Group"::Sub):
                        exit(71);
                    (Group = "ALI Op Group"::Mul):
                        exit(72);
                    (Group = "ALI Op Group"::IDiv):
                        exit(73);
                    else
                        exit(74);   // MOD_BIG
                end;
            else
                case true of
                    (Group = "ALI Op Group"::"Add"):
                        exit(76);   // ADD_D
                    (Group = "ALI Op Group"::Sub):
                        exit(77);
                    (Group = "ALI Op Group"::Mul):
                        exit(78);
                    else
                        exit(79);   // DIV_D ('/')
                end;
        end;
    end;

    local procedure NegOpcode(Cls: Integer): Integer
    begin
        case true of
            (Cls = "ALI Register Class"::Int):
                exit(69);   // NEG_I
            (Cls = "ALI Register Class"::BigInt):
                exit(75);   // NEG_BIG
            else
                exit(80);   // NEG_D
        end;
    end;

    local procedure CompoundOpGroup(OpTok: Integer): Integer
    begin
        case OpTok of
            41:
                exit("ALI Op Group"::"Add");
            42:
                exit("ALI Op Group"::Sub);
            43:
                exit("ALI Op Group"::Mul);
            else
                exit("ALI Op Group"::RDiv);   // 44 /=
        end;
    end;


    // Mirror "ALI Binder".RecordIdMethodMark().
    local procedure RecordIdMethodMark(): Integer
    begin
        exit(-7000);
    end;

    // Mirror "ALI Binder".ListMethodMark()/DictMethodMark().
    local procedure ListMethodMark(): Integer
    begin
        exit(-5000);
    end;

    local procedure DictMethodMark(): Integer
    begin
        exit(-6000);
    end;

    local procedure ListOpcodeFor(MethodId: Integer): Integer
    begin
        case MethodId of
            1:
                exit("ALI Opcode"::LIST_ADD);
            2:
                exit("ALI Opcode"::LIST_ADDRANGE);
            3:
                exit("ALI Opcode"::LIST_CONTAINS);
            4:
                exit("ALI Opcode"::LIST_COUNT);
            5:
                exit("ALI Opcode"::LIST_GET);
            6:
                exit("ALI Opcode"::LIST_GETRANGE);
            7:
                exit("ALI Opcode"::LIST_INDEXOF);
            8:
                exit("ALI Opcode"::LIST_INSERT);
            9:
                exit("ALI Opcode"::LIST_REMOVE);
            10:
                exit("ALI Opcode"::LIST_REMOVEAT);
            11:
                exit("ALI Opcode"::LIST_REMOVERANGE);
            12:
                exit("ALI Opcode"::LIST_REVERSE);
            13:
                exit("ALI Opcode"::LIST_SET);
        end;
    end;

    local procedure DictOpcodeFor(MethodId: Integer): Integer
    begin
        case MethodId of
            1:
                exit("ALI Opcode"::DICT_ADD);
            2:
                exit("ALI Opcode"::DICT_CONTAINSKEY);
            3:
                exit("ALI Opcode"::DICT_COUNT);
            4:
                exit("ALI Opcode"::DICT_GET);
            5:
                exit("ALI Opcode"::DICT_KEYS);
            6:
                exit("ALI Opcode"::DICT_VALUES);
            7:
                exit("ALI Opcode"::DICT_REMOVE);
            8:
                exit("ALI Opcode"::DICT_SET);
            9:
                exit("ALI Opcode"::DICT_TRYGET);
        end;
    end;

    // List method invocation (ListDictionaryPlan.md §5.2). Node SymbolId = ListMethodMark() -
    // methodId. Shared operand convention (§3.3): A = handle reg (the receiver, LOWERED live
    // — NOT read via Symbols.GetSlot, since a List/Dict var can be local/global/var-param and
    // only LowerExpr resolves all three shapes), B = operand-pool start for the method's value
    // args (regIdx*16+class per entry, CALL_BUILTIN_LIVE-style), C = OutReg*100 + ArgCount.
    local procedure LowerListMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        Reg: Integer;
        ResultT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := ListMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`n := L.Count`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);

        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        // Length-check/upper-case a Text/Code value entering a `List of [Text[n]]`/`[Code[n]]`
        // (Add / Insert / Set) — the element's declared width, lost in TArg, rides in ElemChk.
        if (MethodId = 1) or (MethodId = 8) or (MethodId = 13) then
            ApplyCollectionElemChk(Ast, Symbols, Module, RecvNode, ArgCount, ArgClsList, ArgRegList);
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr(ListOpcodeFor(MethodId), HandleReg, OperStart, OutReg * 100 + ArgCount);
    end;

    // Wrap the last arg (the value, for List Add/Insert/Set and Dict Add/Set) through
    // STORE_TEXT_CHK when the receiver collection declares a fixed Text[n]/Code[n] element/value
    // width (ElemChk = Length*2 + IsCode, 0 = none). A transient receiver (no SymbolId) or a
    // non-Text value yields ElemChk 0 -> no-op, so this never perturbs existing collections.
    local procedure ApplyCollectionElemChk(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; RecvNode: Integer; ArgCount: Integer; var ArgClsList: List of [Integer]; var ArgRegList: List of [Integer])
    var
        Chk: Integer;
        TmpReg: Integer;
    begin
        if ArgCount < 1 then
            exit;
        if ArgClsList.Get(ArgCount) <> "ALI Register Class"::"Text" then
            exit;
        Chk := Symbols.GetElemChk(Ast.GetSymbolId(RecvNode));
        if Chk = 0 then
            exit;
        TmpReg := AllocTemp("ALI Register Class"::"Text");
        Module.AddInstr("ALI Opcode"::STORE_TEXT_CHK, TmpReg, ArgRegList.Get(ArgCount), Chk);
        ArgRegList.Set(ArgCount, TmpReg);
    end;

    // Dictionary method invocation — same shape as LowerListMethod.
    local procedure LowerDictMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        Reg: Integer;
        ResultT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := DictMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`n := D.Count`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);

        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        // Length-check/upper-case the VALUE (last arg) entering a `Dictionary of [K, Text[n]]`
        // on Add(key, value) / Set(key, value). Keys are not enforced (see ResolveDictType note).
        if (MethodId = 1) or (MethodId = 8) then
            ApplyCollectionElemChk(Ast, Symbols, Module, RecvNode, ArgCount, ArgClsList, ArgRegList);
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr(DictOpcodeFor(MethodId), HandleReg, OperStart, OutReg * 100 + ArgCount);

        // Get(key, var value) (id 9): arg 2 was lowered like a normal value arg, so its register
        // arrives holding the variable's CURRENT value; the interpreter overwrites it only on a
        // hit, and this write-back then persists it — a miss stores the value back unchanged.
        // The StoreToSym is what makes a global / var-param target work (mirrors Http ReadAs).
        if MethodId = 9 then
            StoreToSym(Module, Symbols, Ast.GetSymbolId(Ast.GetChild(Node, 2)), ArgClsList.Get(2), ArgRegList.Get(2));
    end;

    // Mirror "ALI Binder".HttpMethodMark() — the Http*-method SymbolId marker base. MOST
    // negative of every mark (-9000), so it is checked FIRST in every dispatch cascade.
    local procedure HttpMethodMark(): Integer
    begin
        exit(-9000);
    end;

    // Http* method invocation (M10). Node SymbolId = HttpMethodMark() - methodId. Same shared
    // convention as LowerListMethod (§3.3 comment there): A = receiver handle reg, LOWERED
    // live (not read via Symbols.GetSlot — Http* vars are a plain Int-class register, same
    // scheme as List/Dict), B = operand-pool start (regIdx*16+class per arg, CALL_BUILTIN_
    // LIVE-style), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount (TB_METHOD-style
    // packing, since a single opcode covers every method id across all 5 kinds).
    local procedure LowerHttpMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        IsTextOut: Boolean;
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        Reg: Integer;
        ResultT: Integer;
        TextOutSid: Integer;
        TextOutTmp: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := HttpMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`x := Resp.HttpStatusCode`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);

        // ReadAs(var Text) (id 65) is a scalar var-out — same mechanism as Json WriteTo (see
        // LowerJsonMethod): pass a fresh temp Text reg as the operand, StoreToSym it back into
        // the caller's variable after the instruction (works for local/global/var-param).
        IsTextOut := MethodId = 65;
        if IsTextOut then begin
            TextOutSid := Ast.GetSymbolId(Ast.GetChild(Node, 1));
            TextOutTmp := AllocTemp("ALI Register Class"::"Text");
            OperStart := Module.OperandCount() + 1;
            Module.AddOperand(TextOutTmp * 16 + "ALI Register Class"::"Text");
        end else begin
            for k := 1 to ArgCount do begin
                LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                ArgClsList.Add(Cls);
                ArgRegList.Add(Reg);
            end;
            OperStart := Module.OperandCount() + 1;
            for k := 1 to ArgCount do
                Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
        end;

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr("ALI Opcode"::HTTP_METHOD, HandleReg, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);

        if IsTextOut then
            StoreToSym(Module, Symbols, TextOutSid, "ALI Register Class"::"Text", TextOutTmp);
    end;

    // `HttpReq.Method := value` — property SET lowered as a 1-arg HTTP_METHOD setter call. The
    // arg is the assignment SOURCE (a sibling node), not a child of the target member access, so
    // this cannot route through LowerHttpMethod (which reads args from the call node's children).
    local procedure LowerHttpPropertyStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        HandleCls: Integer;
        HandleReg: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
    begin
        MethodId := HttpMethodMark() - Ast.GetSymbolId(TargetNode);
        RecvNode := Ast.GetChild(TargetNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        OperStart := Module.OperandCount() + 1;
        Module.AddOperand(SrcReg * 16 + SrcCls);
        // OutReg/OutCls = 0 (void setter), ArgCount = 1.
        Module.AddInstr("ALI Opcode"::HTTP_METHOD, HandleReg, OperStart, MethodId * 100 + 1);
    end;

    // Mirror "ALI Binder".JsonMethodMark() — the Json*-method SymbolId marker base. MOST
    // negative of every mark (-10000), so it is checked FIRST in every dispatch cascade.
    local procedure JsonMethodMark(): Integer
    begin
        exit(-10000);
    end;

    // Mirrors "ALI Binder".MediaMethodMark.
    local procedure MediaMethodMark(): Integer
    begin
        exit(-14000);
    end;

    // Mirrors "ALI Binder".RecordRefMethodMark — MOST negative mark of all, so it is checked
    // FIRST in every descending `Sid <= X` dispatch ladder in this codeunit.
    local procedure RecordRefMethodMark(): Integer
    begin
        exit(-15000);
    end;

    // RecordRef-ONLY method invocation (P1). Node SymbolId = RecordRefMethodMark() - methodId.
    // Same shape as LowerTextBuilderMethod: receiver handle in a register, args in the operand
    // pool, result in a fresh temp. Everything else a RecordRef can do is lowered by
    // LowerRecordMethod to a REC_* opcode — see "ALI Binder".RecordRefRoutesToRecordMethod.
    local procedure LowerRecordRefMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        Flags: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvSid: Integer;
        Reg: Integer;
        ResultT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := RecordRefMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`n := RRef.Number`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        // Two-pass (the TB_METHOD rule): lower every arg before pushing any of them, so a nested
        // pool-based argument cannot interleave its own operands with this call's.
        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        // P4 (ids 18-39): the one-digit OutCls field cannot carry a Variant (register class 11
        // would overflow straight into OutReg — the exact reason FLD_METHOD transmits no OutCls at
        // all), and GetRangeMin/GetRangeMax on a RecordRef DO return a Variant. So for the P4
        // block that digit is repurposed as a FLAGS field and the interpreter derives the result
        // class from the method id instead (RecordRefDynOutClass, the FieldRefOutClass rule).
        //   Flags bit0 = "result is consumed" — the optional-return contract ModifyAll needs, and
        //   the one thing that cannot ride in the operand pool because it is a property of the
        //   CALL SITE, not an argument. Ids 1-17 are emitted byte-for-byte as before.
        if MethodId >= 18 then begin
            Flags := 0;
            if WantResult then
                Flags := 1;
            Module.AddInstr("ALI Opcode"::REF_METHOD, Handle, OperStart, OutReg * 100000 + Flags * 10000 + MethodId * 100 + ArgCount);
        end else
            Module.AddInstr("ALI Opcode"::REF_METHOD, Handle, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);

        // Open(), Close() and GetTable() REBIND the variable's handle (Open allocates a bank slot
        // on the first call, Close hands it back and leaves 0 behind, GetTable opens or re-points
        // the ref on the record's table), so unlike every other method in this family they have
        // to store back into the receiver symbol. The runtime writes the new handle into the
        // receiver's REGISTER; that is already the right place for a local, but a global or a
        // var-param alias reached that register through a GLOB_LOAD/LOAD_IND into a TEMP, and
        // without this store the freshly opened handle would be dropped on the floor.
        if (MethodId = 1) or (MethodId = 2) or (MethodId = 6) then begin
            RecvSid := Ast.GetSymbolId(Ast.GetChild(CalleeNode, 0));
            if RecvSid > 0 then
                if Symbols.IsVariableKind(RecvSid) then
                    if Symbols.GetKind(RecvSid) <> "ALI Symbol Kind"::LocalVar then
                        StoreToSym(Module, Symbols, RecvSid, "ALI Register Class"::Int, Handle);
        end;
    end;

    // Mirrors "ALI Binder".FieldRefMethodMark — FieldRef (ids 1-31) and KeyRef (40-43) share
    // ONE mark and ONE opcode. MOST negative mark of all, so it is checked FIRST in every
    // descending `Sid <= X` ladder in this codeunit (there are five of them; miss one and the
    // RecordRef arm silently swallows a FieldRef call).
    local procedure FieldRefMethodMark(): Integer
    begin
        exit(-16000);
    end;

    // FieldRef / KeyRef method invocation (P2/P3). Node SymbolId = FieldRefMethodMark() -
    // methodId. Structurally identical to LowerRecordRefMethod, minus the store-back: NOTHING in
    // this family rebinds its receiver. A FieldRef handle is a pure function of (record handle,
    // field number), so no operation can change what the receiver names — the constructors that
    // MAKE one (Field/FieldIndex/KeyIndex) live on the RecordRef side and return a value like
    // any other method.
    local procedure LowerFieldRefMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        Handle: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        Reg: Integer;
        ResultT: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := FieldRefMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`n := F.Number`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(CalleeNode, 0), Cls, Handle);

        // Two-pass (the TB_METHOD rule): lower every arg before pushing any of them, so a nested
        // pool-based argument cannot interleave its own operands with this call's.
        for k := 1 to ArgCount do begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
            ArgClsList.Add(Cls);
            ArgRegList.Add(Reg);
        end;
        OperStart := Module.OperandCount() + 1;
        for k := 1 to ArgCount do
            Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        // NB the packing here is NOT TB_METHOD's: no OutCls field (see "ALI Opcode"::FLD_METHOD).
        // OutCls is still computed above — AllocTemp needs it to pick the register file — it is
        // simply not transmitted, because the interpreter derives it from the method id.
        Module.AddInstr("ALI Opcode"::FLD_METHOD, Handle, OperStart, OutReg * 10000 + MethodId * 100 + ArgCount);
    end;

    // `F.Value := x` — property SET lowered as the 1-arg FLD_METHOD id 2, exactly the
    // instruction `F.Value(x)` produces. The arg is the assignment SOURCE (a sibling node), not
    // a child of the target member access, so this cannot route through LowerFieldRefMethod
    // (which reads args from the call node's children) — same reason LowerHttpPropertyStore
    // exists next to LowerHttpMethod.
    local procedure LowerFieldRefPropertyStore(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; TargetNode: Integer; SourceNode: Integer)
    var
        HandleCls: Integer;
        HandleReg: Integer;
        MethodId: Integer;
        OperStart: Integer;
        SrcCls: Integer;
        SrcReg: Integer;
    begin
        MethodId := FieldRefMethodMark() - Ast.GetSymbolId(TargetNode);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(TargetNode, 0), HandleCls, HandleReg);
        LowerExpr(Tokens, Ast, Symbols, Module, SourceNode, SrcCls, SrcReg);
        OperStart := Module.OperandCount() + 1;
        Module.AddOperand(SrcReg * 16 + SrcCls);
        // OutReg = 0 (void setter), ArgCount = 1.
        Module.AddInstr("ALI Opcode"::FLD_METHOD, HandleReg, OperStart, MethodId * 100 + 1);
    end;

    // Mirrors "ALI Binder".BigTextMethodMark — BigText (ids 1-49) and SecretText (50-59).
    local procedure BigTextMethodMark(): Integer
    begin
        exit(-13000);
    end;

    // Mirrors "ALI Binder".BlobMethodMark.
    local procedure BlobMethodMark(): Integer
    begin
        exit(-11000);
    end;

    // Blob field method (`Rec.MyBlob.CreateInStream(s)`). Node SymbolId = BlobMethodMark() -
    // methodId (1 CreateInStream, 2 CreateOutStream, 3 HasValue, 4 Length). The receiver is the
    // `Rec.MyBlob` field node: its own child 0 lowers to the record handle, and its bind-time
    // SlotIndex is the field number (a BLOB is never loaded as a value, so no REC_FLD_LOAD).
    local procedure LowerBlobMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCls: Integer;
        ArgReg: Integer;
        CalleeNode: Integer;
        Enc: Integer;
        FieldNo: Integer;
        FieldNode: Integer;
        Handle: Integer;
        HandleCls: Integer;
        MethodId: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := BlobMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`Rec.MyBlob.HasValue`): Node IS the MemberAccessExpr.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := Ast.GetChild(Node, 0)
        else
            CalleeNode := Node;
        FieldNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(FieldNode, 0), HandleCls, Handle);
        FieldNo := Ast.GetSlotIndex(FieldNode);

        case MethodId of
            1:  // CreateInStream(inStr [, TextEncoding])
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), ArgCls, ArgReg);
                    Enc := BlobEncoding(Tokens, Ast, Symbols, Module, Node);   // may emit REC_BLOB_ENC first
                    Module.AddInstr("ALI Opcode"::REC_BLOB_INSTREAM, Handle, ArgReg, FieldNo * 5 + Enc);
                end;
            2:  // CreateOutStream(outStr [, TextEncoding])
                begin
                    LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, 1), ArgCls, ArgReg);
                    Enc := BlobEncoding(Tokens, Ast, Symbols, Module, Node);
                    Module.AddInstr("ALI Opcode"::REC_BLOB_OUTSTREAM, Handle, ArgReg, FieldNo * 5 + Enc);
                end;
            3:  // HasValue() -> Bool
                begin
                    OutCls := "ALI Register Class"::"Boolean";
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_BLOB_HASVALUE, OutReg, Handle, FieldNo);
                end;
            4:  // Length() -> Int
                begin
                    OutCls := "ALI Register Class"::Int;
                    OutReg := AllocTemp(OutCls);
                    Module.AddInstr("ALI Opcode"::REC_BLOB_LENGTH, OutReg, Handle, FieldNo);
                end;
        end;
    end;

    // Optional 2nd blob-stream argument: TextEncoding ordinal (0 MSDos/absent, 1 UTF8, 2 UTF16,
    // 3 Windows), packed into operand C as FieldNo*5+Enc — field ids stay far below the 2^31/5
    // ceiling. A `TextEncoding::X` literal is bind-time folded onto the arg node's SlotIndex; any
    // other TextEncoding expression lowers to a register and rides REC_BLOB_ENC, with Enc = 4.
    local procedure BlobEncoding(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer): Integer
    var
        ArgNode: Integer;
        EncCls: Integer;
        EncReg: Integer;
    begin
        if Ast.GetExtra(Node) < 2 then
            exit(0);
        ArgNode := Ast.GetChild(Node, 2);
        if Ast.GetKind(ArgNode) = "ALI NodeKind"::OptionAccessExpr then
            exit(Ast.GetSlotIndex(ArgNode));
        LowerExpr(Tokens, Ast, Symbols, Module, ArgNode, EncCls, EncReg);
        Module.AddInstr("ALI Opcode"::REC_BLOB_ENC, EncReg, 0, 0);
        exit(4);
    end;

    // Json* method invocation (Feature 2). Node SymbolId = JsonMethodMark() - methodId. Same
    // JSON_METHOD packing as HTTP_METHOD (C = OutReg*100000 + OutCls*10000 + MethodId*100 +
    // ArgCount). The one wrinkle vs LowerHttpMethod: WriteTo(var Text) (ids 13/40/53) is a
    // scalar var-out — arg 1 is a plain assignable Text variable (binder enforced, ALI995). We
    // pass a fresh temp Text reg as the single operand and StoreToSym it back into the variable
    // after the instruction (uniform across local/global/var-param storage — deviation from
    // the plan's "frame-local uses its own register" note, but simpler and correct everywhere).
    local procedure LowerJsonMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        IsWriteTo: Boolean;
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        Reg: Integer;
        ResultT: Integer;
        WriteToSid: Integer;
        WriteToTmp: Integer;
        ArgClsList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := JsonMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`x := Tok.IsObject`): Node IS the MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);

        IsWriteTo := (MethodId = 13) or (MethodId = 40) or (MethodId = 53);
        if IsWriteTo then begin
            WriteToSid := Ast.GetSymbolId(Ast.GetChild(Node, 1));
            WriteToTmp := AllocTemp("ALI Register Class"::"Text");
            OperStart := Module.OperandCount() + 1;
            Module.AddOperand(WriteToTmp * 16 + "ALI Register Class"::"Text");
        end else begin
            for k := 1 to ArgCount do begin
                LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                ArgClsList.Add(Cls);
                ArgRegList.Add(Reg);
            end;
            OperStart := Module.OperandCount() + 1;
            for k := 1 to ArgCount do
                Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
        end;

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        // Ids above 100 (typed GetX getters) overflow JSON_METHOD's 99-id C-pack — they ride
        // JSON_METHOD2 with the id rebased by -100 (see "ALI Opcode" JSON_METHOD2 header).
        if MethodId > 100 then
            Module.AddInstr("ALI Opcode"::JSON_METHOD2, HandleReg, OperStart, OutReg * 100000 + OutCls * 10000 + (MethodId - 100) * 100 + ArgCount)
        else
            Module.AddInstr("ALI Opcode"::JSON_METHOD, HandleReg, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);

        if IsWriteTo then
            StoreToSym(Module, Symbols, WriteToSid, "ALI Register Class"::"Text", WriteToTmp);
    end;

    // Mirror "ALI Binder".XmlMethodMark() — the Xml*-method SymbolId marker base (Feature 3).
    // MOST negative of every mark (-12000), so it is checked FIRST in every dispatch cascade.
    // Mirror "ALI Binder".ObjectCallMark() — the object-procedure-call sentinel (M11).
    local procedure ObjectCallMark(): Integer
    begin
        exit(-500);
    end;

    local procedure CodeunitRunMark(): Integer
    begin
        exit(-501);
    end;

    // M11 phase C3 — `Codeunit.Run(id[, Rec])` / `MyCU.Run([Rec])` to a single CU_RUN.
    //
    // Binder contract: SlotIndex holds the compile-time codeunit id for the INSTANCE form and 0
    // for the static form, whose id is argument 1 and may be any Integer expression. Arguments
    // start at child 1 (child 0 is the callee); a paren-less `MyCU.Run;` is the MemberAccessExpr
    // itself and has no children to read.
    //
    // A record argument is a record VARIABLE (the binder enforced it) and a record rides an Int
    // register holding its handle, so LowerExpr yields exactly what the opcode wants — the
    // callee mutates the caller's record because both name the same handle.
    local procedure LowerCodeunitRun(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; WantResult: Boolean; var OutCls: Integer; var OutReg: Integer)
    var
        ArgBase: Integer;
        ArgCount: Integer;
        Cls: Integer;
        CodeunitId: Integer;
        IdReg: Integer;
        RecReg: Integer;
    begin
        OutCls := 0;
        OutReg := 0;
        CodeunitId := Ast.GetSlotIndex(Node);
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node);

        ArgBase := 1;                                   // child index of the first argument
        if CodeunitId > 0 then begin
            IdReg := AllocTemp("ALI Register Class"::Int);   // instance form — id known at compile time
            Module.AddInstr("ALI Opcode"::LOAD_CONST_I, IdReg, Module.AddConstInt(CodeunitId), 0);
        end else begin
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, ArgBase), Cls, IdReg);
            ArgBase += 1;
        end;

        if ArgCount >= ArgBase then
            LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, ArgBase), Cls, RecReg);

        if WantResult then begin
            OutCls := "ALI Register Class"::"Boolean";
            OutReg := AllocTemp(OutCls);
        end;
        Module.AddInstr("ALI Opcode"::CU_RUN, OutReg, IdReg, RecReg);
    end;

    local procedure XmlMethodMark(): Integer
    begin
        exit(-12000);
    end;

    // XML_DESIGN.md §3 static-id sets: New allocators 1-16 (lowerer-emitted) + user-bindable
    // statics (XmlDocument 60-65, XmlElement.Create 101-104, XmlAttribute 116-118, simple-node
    // Create 140-148). The receiver is a TYPE NAME, never lowered — A stays 0.
    local procedure IsXmlStaticId(MethodId: Integer): Boolean
    begin
        exit(MethodId in [1 .. 16, 60 .. 65, 101 .. 104, 116 .. 118, 140 .. 148]);
    end;

    // XML_DESIGN.md §6 variadic content ids: args past the fixed prefix ride PAIR pool entries.
    local procedure IsXmlVariadicId(MethodId: Integer): Boolean
    begin
        exit(MethodId in [20, 21, 26, 40, 41, 51, 61, 103, 104]);
    end;

    // Fixed (non-content) argument prefix of a variadic id (103 Create(Text,Text,Any...),
    // 104 Create(Text,Any...)); every other variadic id is all-content.
    local procedure XmlFixedArgCount(MethodId: Integer): Integer
    begin
        case MethodId of
            103:
                exit(2);
            104:
                exit(1);
        end;
        exit(0);
    end;

    // XML_DESIGN.md §7.1 scalar `var Text` out-arg position per id (0 = none): WriteTo 31 and
    // DocType getters 158-161 at arg 1; WriteTo-with-options 32, GetNamespaceOfPrefix 106,
    // GetPrefixOfNamespace 107 and NsMgr Lookup* 173/174 at arg 2.
    local procedure XmlTextOutArgPos(MethodId: Integer): Integer
    begin
        case MethodId of
            31, 158, 159, 160, 161:
                exit(1);
            32, 106, 107, 173, 174:
                exit(2);
        end;
        exit(0);
    end;

    // Xml* method invocation (Feature 3). Node SymbolId = XmlMethodMark() - methodId. Same
    // C-packing as JSON_METHOD (OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount);
    // ids > 100 ride XML_METHOD2 rebased by -100. Differences vs LowerJsonMethod:
    // * static ids (IsXmlStaticId) never lower the receiver — it is a type name (§4), A = 0;
    // * variadic content ids emit fixed args as single pool entries then (reg*16+cls, TypeOrd)
    //   PAIRs per content arg (§6) so the interpreter can route Text -> ContentAddText vs
    //   node handle -> ContentAddNode;
    // * scalar `var Text` outs occur at position 1 OR 2 (XmlTextOutArgPos) — the temp-Text +
    //   StoreToSym mechanism is the same, but other args still lower normally around it.
    // Handle var-outs (GetParent/SelectNodes/ReadFrom/...) need nothing special here: the arg
    // register carries the out variable's existing handle and the runtime rebinds the bank
    // slot in place (§7.2).
    local procedure LowerXmlMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; Node: Integer; var OutCls: Integer; var OutReg: Integer)
    var
        ArgCount: Integer;
        CalleeNode: Integer;
        Cls: Integer;
        FixedN: Integer;
        HandleCls: Integer;
        HandleReg: Integer;
        k: Integer;
        MethodId: Integer;
        OperStart: Integer;
        RecvNode: Integer;
        Reg: Integer;
        ResultT: Integer;
        TextOutPos: Integer;
        TextOutSid: Integer;
        TextOutTmp: Integer;
        ArgClsList: List of [Integer];
        ArgOrdList: List of [Integer];
        ArgRegList: List of [Integer];
    begin
        OutCls := 0;
        OutReg := 0;
        MethodId := XmlMethodMark() - Ast.GetSymbolId(Node);
        // Paren-less method (`t := Elem.InnerText`, `Doc := XmlDocument.Create`): Node IS the
        // MemberAccessExpr, 0 args.
        if Ast.GetKind(Node) = "ALI NodeKind"::InvocationExpr then begin
            CalleeNode := Ast.GetChild(Node, 0);
            ArgCount := Ast.GetExtra(Node);
        end else begin
            CalleeNode := Node;
            ArgCount := 0;
        end;
        RecvNode := Ast.GetChild(CalleeNode, 0);
        HandleReg := 0;
        if not IsXmlStaticId(MethodId) then
            LowerExpr(Tokens, Ast, Symbols, Module, RecvNode, HandleCls, HandleReg);

        // Lower every arg first (temp-Text placeholder at the text-out position), THEN build
        // the pool — arg lowering may itself append operands (nested calls).
        TextOutPos := XmlTextOutArgPos(MethodId);
        for k := 1 to ArgCount do
            if k = TextOutPos then begin
                TextOutSid := Ast.GetSymbolId(Ast.GetChild(Node, k));
                TextOutTmp := AllocTemp("ALI Register Class"::"Text");
                ArgClsList.Add("ALI Register Class"::"Text");
                ArgRegList.Add(TextOutTmp);
                ArgOrdList.Add(0);
            end else begin
                LowerExpr(Tokens, Ast, Symbols, Module, Ast.GetChild(Node, k), Cls, Reg);
                ArgClsList.Add(Cls);
                ArgRegList.Add(Reg);
                ArgOrdList.Add(Ast.GetTypeOrd(Ast.GetChild(Node, k)));
            end;
        OperStart := Module.OperandCount() + 1;
        if IsXmlVariadicId(MethodId) then begin
            FixedN := XmlFixedArgCount(MethodId);
            for k := 1 to FixedN do
                Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
            for k := FixedN + 1 to ArgCount do begin
                Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));
                Module.AddOperand(ArgOrdList.Get(k));       // §6 PAIR: bound TypeOrd
            end;
        end else
            for k := 1 to ArgCount do
                Module.AddOperand(ArgRegList.Get(k) * 16 + ArgClsList.Get(k));

        ResultT := Ast.GetTypeOrd(Node);
        if ResultT = "ALI TypeKind"::ErrorType then
            ResultT := "ALI TypeKind"::None;
        if ResultT <> "ALI TypeKind"::None then begin
            OutCls := TypeRules.RegClassFor(ResultT);
            OutReg := AllocTemp(OutCls);
        end;
        if MethodId > 100 then
            Module.AddInstr("ALI Opcode"::XML_METHOD2, HandleReg, OperStart, OutReg * 100000 + OutCls * 10000 + (MethodId - 100) * 100 + ArgCount)
        else
            Module.AddInstr("ALI Opcode"::XML_METHOD, HandleReg, OperStart, OutReg * 100000 + OutCls * 10000 + MethodId * 100 + ArgCount);

        if TextOutPos > 0 then
            StoreToSym(Module, Symbols, TextOutSid, "ALI Register Class"::"Text", TextOutTmp);
    end;
}
