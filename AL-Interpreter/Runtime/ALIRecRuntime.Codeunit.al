// ALI Rec Runtime — RecordRef/FieldRef execution semantics (§7.5, M6; Handle Lifecycle
// Unification Phase 3).
//
// The interpreter delegates every record opcode here. A record handle is a 1-based index
// into RecRefs[] — the array itself stays fixed-size. List of [RecordRef] was tried and
// reverted: it compiles, but a RecordRef's bound/open state does not survive a generic
// List.Get()/.Set() round-trip the way it survives a direct variable-to-variable `:=`
// (confirmed by an actual "record is not open" runtime failure on every access, global AND
// local) — RecordRef's aliasing is a compiler-level special case for `:=` between declared
// RecordRef variables, not a property that generalizes through generic container storage
// (unlike List<T> itself, whose element type IS designed as a shared-backing-store handle,
// which is why nested "List of [List of [T]]" banks in "ALI List Runtime" work that way).
// So this mirrors "ALI Dialog Runtime"'s bigger-array-plus-free-list shape instead — the
// HANDLE now lives in an ordinary windowed Int register (RegClassFor routes Record here)
// instead of a compile-time-sealed absolute slot: NewRec()/FreeRec() allocate/recycle a slot
// on demand, with a fresh handle at every proc entry for a LOCAL record var (mirrors
// LIST_NEW) — fixing the recursive-proc-shares-one-handle bug and making Record usable as a
// proc local at all for the first time (previously silently non-functional, see "ALI
// Binder" notes).
//
// Field access (§7.5 pitfall 7): REC_FLD_LOAD reads FieldRef.Value into a Variant ONCE and
// the interpreter converts to the statically known register class immediately — one boxing
// per field access, never per operation. Field numbers are bind-time-resolved (carried in
// the opcode), so the runtime does zero name lookups.
//
// SingleInstance so the RecordRef array survives across the dispatch loop; Reset() by the
// interpreter's Reset (pitfall 19). Capacity = ArrayLen(RecRefs) = 1024, cross-checked against
// "ALI Limits".MaxRecordSlots by AssertBankCapacity() on every Reset.
codeunit 51115 "ALI Rec Runtime"
{
    Access = Public;

    // force permission on protected tables to write into
    Permissions = tabledata "Approval Entry" = rimd,
     tabledata "Bank Account Ledger Entry" = rimd,
     tabledata "Bank Account Statement Line" = rimd,
tabledata "Batch Processing Parameter" = rimd,
tabledata "Cancelled Document" = rmid,
     tabledata "Capacity Ledger Entry" = rimd,
tabledata "Change Log Entry" = rimd,
tabledata "Check Ledger Entry" = rimd,
tabledata "Cust. Ledger Entry" = rimd,
tabledata "Detailed Cust. Ledg. Entry" = rimd,
tabledata "Detailed Employee Ledger Entry" = rimd,
tabledata "Detailed Vendor Ledg. Entry" = rimd,
tabledata "Dimension Set Entry" = rimd,
tabledata "Dimension Set Tree Node" = rmid,
tabledata "Employee Ledger Entry" = rimd,
tabledata "FA Ledger Entry" = rimd,
tabledata "FA Register" = rimd,
tabledata "G/L Entry" = rimd,
     tabledata "G/L Entry - VAT Entry Link" = rimd,
tabledata "G/L Register" = rimd,
tabledata "Ins. Coverage Ledger Entry" = rimd,
     tabledata "Invt. Receipt Header" = rimd,
tabledata "Invt. Receipt Line" = rimd,
tabledata "Invt. Shipment Header" = rimd,
tabledata "Invt. Shipment Line" = rimd,
tabledata "Issued Fin. Charge Memo Header" = rimd,
tabledata "Issued Reminder Header" = rimd,
tabledata "Issued Reminder Line" = rimd,
tabledata "Item Application Entry" = rimd,
tabledata "Item Application Entry History" = rimd,
tabledata "Item Ledger Entry" = rimd,
tabledata "Item Register" = rimd,
tabledata "Job Ledger Entry" = rimd,
     tabledata "Job Register" = rimd,
tabledata "Maintenance Ledger Entry" = rimd,
     tabledata "Payable Employee Ledger Entry" = rimd,
tabledata "Payable Vendor Ledger Entry" = rimd,
tabledata "Phys. Inventory Ledger Entry" = rimd,
tabledata "Posted Approval Comment Line" = rmid,
tabledata "Posted Approval Entry" = rimd,
tabledata "Post Value Entry to G/L" = rimd,
tabledata "Pstd. Phys. Invt. Order Hdr" = rimd,
tabledata "Pstd. Phys. Invt. Order Line" = rimd,
     tabledata "Pstd. Phys. Invt. Record Hdr" = rimd,
tabledata "Pstd. Phys. Invt. Record Line" = rimd,
tabledata "Purch. Comment Line Archive" = rimd,
tabledata "Purch. Cr. Memo Hdr." = rimd,
tabledata "Purch. Cr. Memo Line" = rimd,
     tabledata "Purch. Inv. Header" = rimd,
tabledata "Purch. Inv. Line" = rimd,
tabledata "Purch. Rcpt. Header" = rimd,
tabledata "Purch. Rcpt. Line" = rimd,
     tabledata "Purchase Header Archive" = rimd,
tabledata "Purchase Line Archive" = rimd,
tabledata "Reminder/Fin. Charge Entry" = rmid,
     tabledata "Res. Ledger Entry" = rimd,
tabledata "Return Receipt Header" = rimd,
tabledata "Return Receipt Line" = rimd,
     tabledata "Return Shipment Header" = rimd,
tabledata "Return Shipment Line" = rimd,
     tabledata "Sales Comment Line Archive" = rimd,
     tabledata "Sales Cr.Memo Header" = rimd,
tabledata "Sales Cr.Memo Line" = rimd,
tabledata "Sales Header Archive" = rimd,
     tabledata "Sales Invoice Header" = rimd,
tabledata "Sales Invoice Line" = rimd,
tabledata "Sales Line Archive" = rimd,
tabledata "Sales Shipment Header" = rimd,
tabledata "Sales Shipment Line" = rimd,
tabledata "Service Cr.Memo Header" = rimd,
     tabledata "Service Invoice Header" = rimd,
tabledata "Service Ledger Entry" = rimd,
     tabledata "Value Entry" = rimd,
tabledata "VAT Entry" = rimd,
tabledata "Vendor Ledger Entry" = rimd,
tabledata "Warehouse Entry" = rimd,
tabledata "Warranty Ledger Entry" = rimd,
tabledata "Workflow Record Change Archive" = rimd,
tabledata "Workflow Step Argument Archive" = rimd,
     tabledata "Workflow Step Instance Archive" = rimd;
    SingleInstance = true;


    var
        RecRefs: array[256] of RecordRef;
        RecOpen: array[256] of Boolean;
        // Which ALLOCATION SITE opened each live slot: 1 = proc local / byval param (frame-scoped,
        // reclaimed at RET), 2 = module or object-instance global (opened once per run, reclaimed
        // only by Reset), 3 = RecordRef Open/GetTable/Duplicate (reclaimed at Close or at frame
        // pop). Kept purely for the ALI954 census — the three have completely different lifetimes,
        // and "the bank is full" is unactionable without knowing which of them filled it.
        RecOrigin: array[256] of Integer;
        // Table ids covered by the Permissions property above — built once per session, read on
        // every write op to decide whether the run may actually use that granted permission.
        ProtectedTables: Dictionary of [Integer, Boolean];
        DeleteOps: Dictionary of [Integer, Integer];
        // Per-table write-operation counters (keyed by table id), reported by the playground /
        // simulation runs. Insert/Modify/Delete count actual successful ops; ModifyAll/DeleteAll
        // count the affected-row count taken BEFORE the bulk op (§8).
        InsertOps: Dictionary of [Integer, Integer];
        ModifyOps: Dictionary of [Integer, Integer];
        HandleCount: Integer;
        // P2 FieldRef pair packing: the distinct field numbers this run has mentioned, interned
        // so a (recHandle, fieldNo) pair fits in ONE 32-bit Integer register (a raw field number
        // does not — SystemId is 2000000000). Slot = 1-based index into FieldNoPool; the
        // Dictionary is only the reverse lookup that keeps interning idempotent, which is what
        // makes `R.Field(1)` inside a loop allocation-free. Never shrinks during a run; reset
        // with the bank.
        FieldNoPool: List of [Integer];
        FieldNoIndex: Dictionary of [Integer, Integer];
        PendingBlobField: array[16] of Integer;
        // Blob writes in flight, indexed by STREAM handle (16 of them, "ALI Stream Runtime".
        // StreamCapacity): which record handle + field the stream opened by
        // Rec.MyBlob.CreateOutStream belongs to, so Insert/Modify can push the content in.
        PendingBlobRec: array[16] of Integer;
        FreeIdx: List of [Integer];
        // Record security ("ALI Run Options".ApplyRecordSecurity): per-run cache of the filter-group-2
        // filters "TOO Record Security Filters" raises per table (only tables that got filters), plus
        // a per-handle flag so an unsecured handle pays one Boolean lookup per read.
        Secured: array[256] of Boolean;
        SecChecked: Dictionary of [Integer, Boolean];
        SecFieldNos: Dictionary of [Integer, List of [Integer]];
        SecFilters: Dictionary of [Integer, List of [Text]];
        SecNotes: Dictionary of [Integer, Text];    // LLM-facing note per restricted table
        SecOpenedTables: List of [Integer];         // restricted tables the script actually opened this run

    // ===== Protected-table write gate =====
    //
    // The Permissions property is static: it grants write on every protected table for ALL runs.
    // The gate below is the dynamic half — "ALI Run Options".AllowProtectedWrite is off by
    // default, so a script writing a posted/ledger table fails with ALI983 unless the host opted
    // in. One dictionary lookup per write op (no SQL, no interpreter branch).
    local procedure CheckWriteAllowed(H: Integer)
    var
        RunOptions: Codeunit "ALI Run Options";
    begin
        if RunOptions.AllowProtectedWrite() then
            exit;
        if RecRefs[H].IsTemporary() then    // temp rows never reach the database
            exit;
        // Simulation writes are undone by the enclosing Codeunit.Run rollback and its COMMIT is
        // no-op'd (CommitBehavior::Ignore), so a dry run over posted/ledger tables can't persist.
        if RunOptions.IsSimulation() then
            exit;
        if ProtectedTables.Count() = 0 then
            BuildProtectedTables();
        if ProtectedTables.ContainsKey(RecRefs[H].Number()) then
            Error('ALI983: writing protected table %1 is not permitted in this execution context', RecRefs[H].Name());
    end;

    // Keep in sync BY HAND with the Permissions property at the top of this codeunit.
    local procedure BuildProtectedTables()
    var
        Id: Integer;
        Ids: List of [Integer];
    begin
        Ids.AddRange(52, Database::"Vendor Ledger Entry", Database::"FA Ledger Entry", Database::"Job Ledger Entry", Database::"Item Ledger Entry",
            Database::"Res. Ledger Entry", Database::"Check Ledger Entry", Database::"Cust. Ledger Entry", Database::"Service Ledger Entry",
            Database::"Capacity Ledger Entry", Database::"Employee Ledger Entry", Database::"Warranty Ledger Entry", Database::"Maintenance Ledger Entry",
            Database::"Bank Account Ledger Entry", Database::"Ins. Coverage Ledger Entry", Database::"Payable Vendor Ledger Entry", Database::"Phys. Inventory Ledger Entry",
            Database::"Payable Employee Ledger Entry", Database::"Detailed Employee Ledger Entry", Database::"Detailed Cust. Ledg. Entry", Database::"Detailed Vendor Ledg. Entry",
            Database::"Sales Invoice Header", Database::"Sales Invoice Line", Database::"Sales Shipment Header", Database::"Sales Shipment Line",
            Database::"Sales Cr.Memo Header", Database::"Sales Cr.Memo Line", Database::"Purch. Cr. Memo Hdr.", Database::"Purch. Cr. Memo Line",
            Database::"Purch. Inv. Header", Database::"Purch. Inv. Line", Database::"Purch. Rcpt. Header", Database::"Purch. Rcpt. Line",
            Database::"Purchase Header Archive", Database::"Sales Line Archive", Database::"Sales Header Archive", Database::"Purchase Line Archive",
            Database::"Sales Comment Line Archive", Database::"Purch. Comment Line Archive", Database::"Workflow Step Argument Archive", Database::"Workflow Record Change Archive",
            Database::"Workflow Step Instance Archive", Database::"G/L Entry", Database::"Approval Entry", Database::"Warehouse Entry",
            Database::"Value Entry", Database::"Item Register", Database::"G/L Register", Database::"VAT Entry", Database::"Dimension Set Entry",
            Database::"Service Invoice Header", Database::"Service Cr.Memo Header", Database::"Issued Reminder Header", Database::"Issued Reminder Line", Database::"Issued Fin. Charge Memo Header",
            Database::"G/L Entry - VAT Entry Link", Database::"Item Application Entry", Database::"Item Application Entry History",
            Database::"Return Shipment Header", Database::"Return Shipment Line", Database::"Return Receipt Header", Database::"Return Receipt Line",
            Database::"Invt. Receipt Header", Database::"Invt. Receipt Line", Database::"Invt. Shipment Header", Database::"Invt. Shipment Line",
            Database::"Pstd. Phys. Invt. Record Hdr", Database::"Pstd. Phys. Invt. Record Line", Database::"Pstd. Phys. Invt. Order Hdr", Database::"Pstd. Phys. Invt. Order Line",
            Database::"Bank Account Statement Line", Database::"Change Log Entry", Database::"Posted Approval Entry", Database::"FA Register", Database::"Post Value Entry to G/L",
            Database::"Job Register", Database::"Reminder/Fin. Charge Entry", Database::"Posted Approval Comment Line", Database::"Dimension Set Tree Node", Database::"Cancelled Document");
        foreach Id in Ids do
            if not ProtectedTables.ContainsKey(Id) then
                ProtectedTables.Add(Id, true);
    end;

    // ===== Record security filters =====
    //
    // Opt-in per run. The filters are captured once per table (probe RecordRef + event), then put
    // back into filter group 2 before every read, so Reset/SetView/CopyFilters/FilterGroup(2) in a
    // script cannot drop them. Get ignores filters natively, so a found row is re-checked.

    // Called at the end of every open path.
    local procedure MarkSecured(H: Integer)
    var
        RunOptions: Codeunit "ALI Run Options";
        TableId: Integer;
    begin
        Secured[H] := false;
        if not RunOptions.ApplyRecordSecurity() then
            exit;
        if RecRefs[H].IsTemporary() then
            exit;
        TableId := RecRefs[H].Number();
        if not SecChecked.ContainsKey(TableId) then
            LoadSecurity(TableId);
        Secured[H] := SecFieldNos.ContainsKey(TableId);
        if not Secured[H] then
            exit;
        ApplySecurity(RecRefs[H]);
        if not SecOpenedTables.Contains(TableId) then
            SecOpenedTables.Add(TableId);
    end;

    // One note per restricted table opened this run ('' if none) — scope and filters only, never
    // a count of hidden rows. Hosts append it to the run output.
    procedure SecurityNotesText(): Text
    var
        TableId: Integer;
        Sb: TextBuilder;
    begin
        foreach TableId in SecOpenedTables do
            Sb.AppendLine(SecNotes.Get(TableId));
        exit(Sb.ToText().TrimEnd());
    end;

    local procedure LoadSecurity(TableId: Integer)
    var
        SecurityFilters: Codeunit "ALI Record Security Filters";
        Probe: RecordRef;
        FRef: FieldRef;
        FieldNos: List of [Integer];
        Filters: List of [Text];
        i: Integer;
        Note: Text;
    begin
        SecChecked.Set(TableId, true);
        Probe.Open(TableId);
        Note := SecurityFilters.ApplyFilters(Probe);
        Probe.FilterGroup(2);
        for i := 1 to Probe.FieldCount() do begin
            FRef := Probe.FieldIndex(i);
            if FRef.GetFilter() <> '' then begin
                FieldNos.Add(FRef.Number());
                Filters.Add(FRef.GetFilter());
            end;
        end;
        Probe.Close();
        if FieldNos.Count() = 0 then
            exit;
        SecFieldNos.Set(TableId, FieldNos);
        SecFilters.Set(TableId, Filters);
        SecNotes.Set(TableId, Note);
    end;

    // Compare-then-set: an unchanged filter is not re-set, so a Next() loop keeps its cursor.
    local procedure ApplySecurity(var RecRef: RecordRef)
    var
        FRef: FieldRef;
        FieldNos: List of [Integer];
        Filters: List of [Text];
        i: Integer;
        PrevGroup: Integer;
    begin
        FieldNos := SecFieldNos.Get(RecRef.Number());
        Filters := SecFilters.Get(RecRef.Number());
        PrevGroup := RecRef.FilterGroup();
        RecRef.FilterGroup(2);
        for i := 1 to FieldNos.Count() do begin
            FRef := RecRef.Field(FieldNos.Get(i));
            if FRef.GetFilter() <> Filters.Get(i) then
                FRef.SetFilter(Filters.Get(i));
        end;
        RecRef.FilterGroup(PrevGroup);
    end;

    // After a successful Get on a secured handle: is the row inside the security filters? If not,
    // behave exactly like a miss (the script cannot tell the row exists).
    local procedure SecuredGetResult(H: Integer; Conditional: Boolean): Boolean
    var
        Probe: RecordRef;
        KRef: KeyRef;
        i: Integer;
        Ident: Text;
    begin
        Probe.Open(RecRefs[H].Number(), false, RecRefs[H].CurrentCompany());
        Probe.SetPosition(RecRefs[H].GetPosition(false));
        ApplySecurity(Probe);
        Probe.SetRecFilter();
        if not Probe.IsEmpty() then
            exit(true);
        KRef := RecRefs[H].KeyIndex(1);
        for i := 1 to KRef.FieldCount() do begin
            if i > 1 then
                Ident += ',';
            Ident += KRef.FieldIndex(i).Caption() + '=''' + Format(KRef.FieldIndex(i).Value()) + '''';
        end;
        RecRefs[H].Init();
        if Conditional then
            exit(false);
        Error('The %1 does not exist. Identification fields and values: %2', RecRefs[H].Caption(), Ident);
    end;

    // ===== Lifecycle =====
    procedure ClearRec(H: Integer)
    var
        Temp: Boolean;
        TableId: Integer;
    begin
        TableId := RecRefs[H].Number();
        Temp := RecRefs[H].IsTemporary();
        Clear(RecRefs[H]);
        // Reopen preserving the declared temp-ness — reopening non-temp records as temporary
        // silently rerouted their writes to a temp dataset (fixed).
        if Temp then
            RecRefs[H].Open(TableId, true)
        else
            RecRefs[H].Open(TableId);
        MarkSecured(H);
    end;

    procedure Reset()
    var
        i: Integer;
    begin
        AssertBankCapacity();
        // A failed allocation used to leave HandleCount one slot PAST the bank (it was bumped
        // before the ceiling check, and SingleInstance state survives the error), and this loop
        // then indexed RecOpen[1025] — an "index out of bounds" raised from inside Reset itself,
        // which BRICKED the session: LoadModule calls Reset first, so every later compile died
        // there instead of running. The allocators now check before they increment; this clamp is
        // the belt to that braces, so no stale count can ever take the session down again.
        if HandleCount > ArrayLen(RecOpen) then
            HandleCount := ArrayLen(RecOpen);
        for i := 1 to HandleCount do
            if RecOpen[i] then begin
                RecRefs[i].Close();
                RecOpen[i] := false;
            end;
        Clear(RecRefs);
        Clear(RecOrigin);
        HandleCount := 0;
        Clear(FreeIdx);
        Clear(InsertOps);
        Clear(ModifyOps);
        Clear(DeleteOps);
        Clear(PendingBlobRec);
        Clear(PendingBlobField);
        // P2: the field-number pool is per-run. Keeping it would be harmless for correctness
        // (slots are just names for numbers) but would let a long-lived session grow it without
        // bound, and stale slots would decode against recycled record handles.
        Clear(FieldNoPool);
        Clear(FieldNoIndex);
        Clear(Secured);
        Clear(SecChecked);
        Clear(SecFieldNos);
        Clear(SecFilters);
        Clear(SecNotes);
        Clear(SecOpenedTables);
    end;

    // What is actually holding the bank when it runs out. ALI954 used to report the ceiling and
    // nothing else, which says nothing about WHICH allocation site ran away — and the sites have
    // very different lifetimes (proc locals are frame-reclaimed at RET, module/object globals
    // live for the whole run, RecordRef slots live until Close). Naming the top tables turns the
    // next occurrence into a diagnosis instead of a guess.
    local procedure OpenSlotCensus(): Text
    var
        PerTable: Dictionary of [Integer, Integer];
        Sb: TextBuilder;
        Best: Integer;
        BestId: Integer;
        Cnt: Integer;
        i: Integer;
        n: Integer;
        NGlobal: Integer;
        NLocal: Integer;
        NRef: Integer;
        TableId: Integer;
    begin
        for i := 1 to HandleCount do
            if RecOpen[i] then begin
                TableId := RecRefs[i].Number();
                if PerTable.ContainsKey(TableId) then
                    PerTable.Set(TableId, PerTable.Get(TableId) + 1)
                else
                    PerTable.Add(TableId, 1);
                case RecOrigin[i] of
                    1:
                        NLocal += 1;
                    2:
                        NGlobal += 1;
                    3:
                        NRef += 1;
                end;
            end;
        Sb.Append(StrSubstNo(' — by site: %1 proc local, %2 global, %3 RecordRef', NLocal, NGlobal, NRef));
        Sb.Append(' — by table:');
        // Top 5 by selection, not by sorting: the dictionary is at most a few hundred entries and
        // this runs exactly once, on the way to an error.
        for n := 1 to 5 do begin
            Best := 0;
            BestId := 0;
            foreach TableId in PerTable.Keys() do begin
                Cnt := PerTable.Get(TableId);
                if Cnt > Best then begin
                    Best := Cnt;
                    BestId := TableId;
                end;
            end;
            if BestId = 0 then
                exit(Sb.ToText());
            Sb.Append(StrSubstNo(' %1 x%2', BestId, Best));
            PerTable.Remove(BestId);
        end;
        exit(Sb.ToText());
    end;

    // The bank's capacity. DERIVED from the array itself, never restated: AL array dimensions
    // must be integer literals, so `array[1024] of RecordRef` above is the only place the size
    // can be authored, and every bounds check reads it back from there with ArrayLen. The old
    // shape restated the number in three places (here, GuardHandle's `H > 4096`, and
    // "ALI Limits".MaxRecordSlots) and two of the three had silently drifted to 4096 — a guard
    // that admits handle 2000 into an array of 1024 is not a guard. AssertBankCapacity() below
    // keeps the remaining published copy honest.
    local procedure MaxRecordHandles(): Integer
    begin
        exit(ArrayLen(RecOpen));
    end;

    // The three facts that must agree about the bank's size, checked once per run (Reset) so a
    // future edit to any one of them fails LOUDLY on the first script instead of corrupting a
    // neighbouring handle or throwing "index out of bounds" from an unrelated call site:
    //   * RecRefs[] and RecOpen[] are index-parallel, so they must be the same length;
    //   * "ALI Limits" publishes the same capacity for documentation/diagnostics — it is not
    //     the source of truth (the array literal is), it is the copy most likely to rot;
    //   * FieldRefStride() is the FieldRef packing multiplier: a FieldRef handle is
    //     Slot * Stride + RecHandle, so RecHandle must stay strictly below the stride or the
    //     two halves of the pair alias each other. Raising the bank means raising the stride.
    local procedure AssertBankCapacity()
    var
        Limits: Codeunit "ALI Limits";
    begin
        if ArrayLen(RecRefs) <> ArrayLen(RecOpen) then
            Error('ALI955: record bank inconsistency — RecRefs holds %1 slots but RecOpen holds %2', ArrayLen(RecRefs), ArrayLen(RecOpen));
        if Limits.MaxRecordSlots() <> ArrayLen(RecOpen) then
            Error('ALI955: record bank inconsistency — "ALI Limits".MaxRecordSlots() says %1 but the bank holds %2 slots', Limits.MaxRecordSlots(), ArrayLen(RecOpen));
        if ArrayLen(RecOpen) >= FieldRefStride() then
            Error('ALI955: record bank of %1 slots does not fit under the FieldRef packing stride %2', ArrayLen(RecOpen), FieldRefStride());
    end;

    // Handle Lifecycle Unification: allocate (or reuse) a fresh record handle and open it on
    // TableId — mirrors "ALI List Runtime".NewList/"ALI Array Runtime".NewBlock. Replaces the
    // old binder-sealed Allocate(N); a record var now gets a fresh handle at whichever proc
    // entry declares it (global or local — see Phase 3, fixes the recursion-sharing bug).
    procedure NewRec(TableId: Integer; IsTemp: Boolean; Origin: Integer): Integer
    var
        H: Integer;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
        end else begin
            // Checked BEFORE the bump: incrementing first left the bank permanently one slot over
            // its own capacity once the error fired, and Reset then indexed past RecOpen[] — see
            // the note in Reset().
            if HandleCount >= MaxRecordHandles() then
                Error('ALI954: too many concurrently open record variables (max %1)%2', MaxRecordHandles(), OpenSlotCensus());
            HandleCount += 1;
            H := HandleCount;
        end;
        OpenRec(H, TableId, IsTemp);
        RecOrigin[H] := Origin;
        exit(H);
    end;

    // Reclaim a record handle — closes it if still open and recycles the slot.
    procedure FreeRec(H: Integer)
    var
        i: Integer;
    begin
        if (H < 1) or (H > HandleCount) then
            exit;
        // Already reclaimed. Freeing twice would put ONE slot on the free list twice, and the two
        // allocations after that would hand the same RecordRef to two unrelated variables.
        if not RecOpen[H] then
            exit;
        // Pending blob writes die with the record handle (nothing left to flush them into).
        for i := 1 to ArrayLen(PendingBlobRec) do
            if PendingBlobRec[i] = H then
                ClearPendingBlobStream(i);
        if RecOpen[H] then begin
            RecRefs[H].Close();
            RecOpen[H] := false;
        end;
        Secured[H] := false;
        FreeIdx.Add(H);
    end;

    // ===== Write-operation counting (§8) =====

    local procedure BumpOp(var OpDict: Dictionary of [Integer, Integer]; TableId: Integer; N: Integer)
    var
        Cur: Integer;
    begin
        if N <= 0 then
            exit;
        if OpDict.ContainsKey(TableId) then
            Cur := OpDict.Get(TableId);
        OpDict.Set(TableId, Cur + N);
    end;

    local procedure GetOp(var OpDict: Dictionary of [Integer, Integer]; TableId: Integer): Integer
    begin
        if OpDict.ContainsKey(TableId) then
            exit(OpDict.Get(TableId));
        exit(0);
    end;

    procedure RecordOpTotal(): Integer
    var
        Tid: Integer;
        Total: Integer;
        TableIds: List of [Integer];
    begin
        CollectOpTableIds(TableIds);
        foreach Tid in TableIds do
            Total += GetOp(InsertOps, Tid) + GetOp(ModifyOps, Tid) + GetOp(DeleteOps, Tid);
        exit(Total);
    end;

    // Human summary of write ops per table, one line each (playground / simulation report).
    procedure OpLogText(): Text
    var
        Tid: Integer;
        TableIds: List of [Integer];
        Nm: Text;
        Sb: TextBuilder;
    begin
        CollectOpTableIds(TableIds);
        if TableIds.Count() = 0 then
            exit('(no record write operations)');
        foreach Tid in TableIds do begin
            Nm := '';
            if not TryTableName(Tid, Nm) then
                Nm := '?';
            Sb.AppendLine(StrSubstNo('  [%1] %2: insert=%3 modify=%4 delete=%5',
                Tid, Nm, GetOp(InsertOps, Tid), GetOp(ModifyOps, Tid), GetOp(DeleteOps, Tid)));
        end;
        exit(Sb.ToText());
    end;

    local procedure CollectOpTableIds(var Ids: List of [Integer])
    var
        K: Integer;
    begin
        foreach K in InsertOps.Keys() do
            if not Ids.Contains(K) then
                Ids.Add(K);
        foreach K in ModifyOps.Keys() do
            if not Ids.Contains(K) then
                Ids.Add(K);
        foreach K in DeleteOps.Keys() do
            if not Ids.Contains(K) then
                Ids.Add(K);
    end;

    [TryFunction]
    local procedure TryTableName(TableId: Integer; var Name: Text)
    var
        RRef: RecordRef;
    begin
        RRef.Open(TableId);
        Name := RRef.Name();
        RRef.Close();
    end;

    // ===== Open / Reset / Init =====

    // Open handle H on TableId (Temp = temporary record). Idempotent-safe: re-opening closes
    // the prior ref first (matches native re-scoping). Called by NewRec() at allocation time;
    // no longer called directly at the opcode level (see ExecRecNew / REC_NEW).
    local procedure OpenRec(H: Integer; TableId: Integer; Temp: Boolean)
    begin
        GuardHandle(H);
        if RecOpen[H] then
            RecRefs[H].Close();
        if Temp then
            RecRefs[H].Open(TableId, true)
        else
            RecRefs[H].Open(TableId);
        RecOpen[H] := true;
        MarkSecured(H);
    end;

    procedure InitRec(H: Integer)
    begin
        RecRefs[H].Init();
    end;

    procedure ResetRec(H: Integer)
    begin
        RecRefs[H].Reset();
    end;

    // ===== CRUD =====

    // Insert/Modify/Delete return Boolean in AL. RecordRef's own methods carry the same optional
    // Boolean: CONSUMING the return suppresses the runtime error (returns false); DISCARDING it
    // re-raises. So Conditional (return consumed by the caller) picks which native form to emit —
    // no TryFunction needed. exit(RecRefs[H].X()) consumes; the bare call discards.
    procedure InsertRec(H: Integer; RunTrigger: Boolean; Conditional: Boolean): Boolean
    var
        Ok: Boolean;
    begin
        CheckWriteAllowed(H);
        FlushPendingBlobs(H);
        if Conditional then
            Ok := RecRefs[H].Insert(RunTrigger)
        else begin
            RecRefs[H].Insert(RunTrigger);
            Ok := true;
        end;
        if Ok then
            BumpOp(InsertOps, RecRefs[H].Number(), 1);
        exit(Ok);
    end;

    procedure ModifyRec(H: Integer; RunTrigger: Boolean; Conditional: Boolean): Boolean
    var
        Ok: Boolean;
    begin
        CheckWriteAllowed(H);
        FlushPendingBlobs(H);
        if Conditional then
            Ok := RecRefs[H].Modify(RunTrigger)
        else begin
            RecRefs[H].Modify(RunTrigger);
            Ok := true;
        end;
        if Ok then
            BumpOp(ModifyOps, RecRefs[H].Number(), 1);
        exit(Ok);
    end;

    procedure DeleteRec(H: Integer; RunTrigger: Boolean; Conditional: Boolean): Boolean
    var
        Ok: Boolean;
    begin
        CheckWriteAllowed(H);
        if Conditional then
            Ok := RecRefs[H].Delete(RunTrigger)
        else begin
            RecRefs[H].Delete(RunTrigger);
            Ok := true;
        end;
        if Ok then
            BumpOp(DeleteOps, RecRefs[H].Number(), 1);
        exit(Ok);
    end;

    procedure DeleteAllRec(H: Integer; RunTrigger: Boolean; Conditional: Boolean): Boolean
    var
        IntRecRef: RecordRef;
    begin
        CheckWriteAllowed(H);
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        // Count the affected rows BEFORE the bulk op (§8: "count before deleteall").
        BumpOp(DeleteOps, RecRefs[H].Number(), RecRefs[H].Count());
        // Fast path: RecordRef.DeleteAll is a bulk void op — throws on failure (statement form).
        if not Conditional then begin
            RecRefs[H].DeleteAll(RunTrigger);
            exit(true);
        end;
        // Conditional form: RecordRef.DeleteAll has no consumable Boolean (unlike the record-level
        // method), so iterate and consume each row-Delete — a failing delete returns false.
        // Same temp-ness as the source, then CopyIntoRef decides shareTable: a private cursor
        // opened non-temporary over a TEMPORARY record would have iterated (and deleted from)
        // the real database table instead of the temp dataset.
        IntRecRef.Open(RecRefs[H].Number, RecRefs[H].IsTemporary());
        CopyIntoRef(IntRecRef, H);
        if IntRecRef.FindSet() then
            repeat
                if not IntRecRef.Delete(RunTrigger) then
                    exit(false);
            until IntRecRef.Next() = 0;
        exit(true);
    end;

    // Get by primary key held in a single value staged into a Variant. For the test table
    // the PK is a single Code[20] field; the interpreter passes the key as Text. Multi-field
    // PK Get is a future concern — M6 supports single-field-PK Get.
    //
    // RecordRef.Get() expects a RecordId, not a bare field value, so a single scalar key
    // (e.g. Code[20]) cannot be passed to it directly (NavIndirectValue -> NavRecordId
    // conversion error). Filter the primary key's first field to the value instead and
    // FindFirst — equivalent for a single-field PK.
    // Get() with no key args: the documented default form — match on the primary key values
    // currently held in the record (RecordId reflects them).
    procedure GetRec(H: Integer; Conditional: Boolean): Boolean
    begin
        exit(FinishGet(H, RecRefs[H].RecordId(), Conditional));
    end;

    // Get(RecordID) — the RecordID-typed overload of Get(), and the runtime engine behind
    // `RecVar := idExpr.GetRecord();` (§ RecordID). A RecordId naturally carries its own
    // table number: if it doesn't match this handle's table, native Get() raises its own
    // "wrong table" error — no extra check needed here.
    procedure GetRecById(H: Integer; Conditional: Boolean; ById: RecordId): Boolean
    begin
        exit(FinishGet(H, ById, Conditional));
    end;

    // Record.RecordId() — the current record's identity as a RecordID value.
    procedure GetRecordId(H: Integer): RecordId
    begin
        exit(RecRefs[H].RecordId());
    end;

    // Get by RecordId, honoring AL's optional-return error semantics: Conditional (return
    // consumed) suppresses a miss and returns false; otherwise the unconsumed Get throws.
    local procedure FinishGet(H: Integer; RecId: RecordId; Conditional: Boolean): Boolean
    begin
        if Conditional then begin
            if not RecRefs[H].Get(RecId) then
                exit(false);
        end else
            RecRefs[H].Get(RecId);
        if Secured[H] then
            exit(SecuredGetResult(H, Conditional));
        exit(true);
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant; KeyValue15: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        TempRecRf.KeyIndex(1).FieldIndex(15).Value := KeyValue15;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    procedure GetRec(H: Integer; Conditional: Boolean; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant; KeyValue15: Variant; KeyValue16: Variant): Boolean
    var
        TempRecRf: RecordRef;
    begin
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        TempRecRf.KeyIndex(1).FieldIndex(15).Value := KeyValue15;
        TempRecRf.KeyIndex(1).FieldIndex(16).Value := KeyValue16;
        exit(FinishGet(H, TempRecRf.RecordId(), Conditional));
    end;

    // ===== Find / iterate =====
    // Which: 0 = FindSet, 1 = FindFirst, 2 = FindLast. Returns found. ForUpdate only applies
    // to FindSet (Which=0); FindFirst/FindLast have no ForUpdate overload in AL.
    // Conditional (return consumed) consumes the native Boolean (false on no match); otherwise
    // the unconsumed call throws, matching AL's Find* statement semantics (addDataError).
    procedure FindRec(H: Integer; Which: Integer; ForUpdate: Boolean; Conditional: Boolean): Boolean
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        if Conditional then
            case Which of
                0:
                    exit(RecRefs[H].FindSet(ForUpdate));
                1:
                    exit(RecRefs[H].FindFirst());
                2:
                    exit(RecRefs[H].FindLast());
                else
                    exit(false);
            end;
        case Which of
            0:
                RecRefs[H].FindSet(ForUpdate);
            1:
                RecRefs[H].FindFirst();
            2:
                RecRefs[H].FindLast();
        end;
        exit(true);
    end;

    // No ApplySecurity here: security filters (filter group 2) are set when the handle is opened
    // (MarkSecured) and re-checked by every Find*, and user SetRange/SetFilter work in group 0 —
    // Next only continues a cursor those already filtered. Hot in record loops.
    procedure NextRec(H: Integer; Step: Integer): Integer
    begin
        exit(RecRefs[H].Next(Step));
    end;

    procedure CountRec(H: Integer): Integer
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        exit(RecRefs[H].Count());
    end;

    procedure IsEmptyRec(H: Integer): Boolean
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        exit(RecRefs[H].IsEmpty());
    end;

    // ===== Filters =====
    // SetRange with one bound value (equality filter). Multi-value SetRange and SetFilter
    // land alongside once the front end passes their arguments; M6 covers the common case.
    procedure SetRangeEq(H: Integer; FieldNo: Integer; Value: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.SetRange(Value);
    end;

    procedure SetRangeBetween(H: Integer; FieldNo: Integer; LoVal: Variant; HiVal: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.SetRange(LoVal, HiVal);
    end;

    procedure ClearFieldRange(H: Integer; FieldNo: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.SetRange();
    end;

    // ===== Typed field access (§7.5) =====
    // Load reads FieldRef.Value ONCE into a Variant; the interpreter converts to the static
    // class. Store writes the boxed value back.

    procedure GetFieldValue(H: Integer; FieldNo: Integer): Variant
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Value());
    end;

    // Typed field load/store for the four register classes that cover almost all real scripts.
    // Same one FieldRef.Value() boxing at the platform boundary as GetFieldValue — the point is
    // that the interpreter can call these DIRECTLY from its REC_FLD_LOAD/REC_FLD_STORE arms and
    // skip both the ExecRecordOp dispatch hop and WriteRegisterFromVariant/ReadRegisterAsVariant.
    // That is 3 AL procedure calls down to 1 on the hottest opcode in record-loop scripts, and a
    // call costs ~450ns. Other classes still route through the generic Variant pair.

    procedure GetFieldInt(H: Integer; FieldNo: Integer): Integer
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Value());
    end;

    procedure GetFieldDec(H: Integer; FieldNo: Integer): Decimal
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Value());
    end;

    procedure GetFieldBool(H: Integer; FieldNo: Integer): Boolean
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Value());
    end;

    procedure GetFieldText(H: Integer; FieldNo: Integer): Text
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Value());
    end;

    procedure SetFieldInt(H: Integer; FieldNo: Integer; Value: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Value(Value);
    end;

    procedure SetFieldDec(H: Integer; FieldNo: Integer; Value: Decimal)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Value(Value);
    end;

    procedure SetFieldBool(H: Integer; FieldNo: Integer; Value: Boolean)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Value(Value);
    end;

    procedure SetFieldText(H: Integer; FieldNo: Integer; Value: Text)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Value(Value);
    end;

    // PERF TEST — binds a FieldRef the interpreter caches per REC_FLD_LOAD/STORE site and reuses
    // across rows ("ALI Interpreter" Fc* block). Remove together with that block.
    procedure BindFieldRef(H: Integer; FieldNo: Integer; var FRef: FieldRef)
    begin
        FRef := RecRefs[H].Field(FieldNo);
    end;

    procedure SetFieldValue(H: Integer; FieldNo: Integer; Value: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Value(Value);
    end;

    procedure ValidateField(H: Integer; FieldNo: Integer; Value: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.Validate(Value);
    end;

    // SetFilter(field, filterText): the general filter-expression form (as opposed to
    // SetRangeEq's single-value equality shortcut). FilterText is used as-is.
    procedure SetFilterField(H: Integer; FieldNo: Integer; FilterText: Text)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.SetFilter(FilterText);
    end;

    // SetFilter(field, filterText, v1, ...): the %1-substitution form. Arity is spelled out
    // because AL has no way to splat a Variant array into SetFilter's variadic tail; the
    // values stay Variants so the platform applies its own filter-safe formatting (invariant
    // decimals/dates, Option ordinals) instead of a locale-dependent StrSubstNo.
    procedure SetFilterFieldArgs(H: Integer; FieldNo: Integer; FilterText: Text; A: array[14] of Variant; N: Integer)
    begin
        case N of
            0:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText);
            1:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1]);
            2:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2]);
            3:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3]);
            4:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4]);
            5:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5]);
            6:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6]);
            7:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7]);
            8:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8]);
            9:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9]);
            10:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10]);
            11:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11]);
            12:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12]);
            13:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12], A[13]);
            14:
                RecRefs[H].Field(FieldNo).SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12], A[13], A[14]);
            else
                Error('ALI: SetFilter supports at most 14 substitution values (got %1)', N);
        end;
    end;

    procedure GetFilterField(H: Integer; FieldNo: Integer): Text
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.GetFilter());
    end;

    // The two records may differ — native AL's `Rec.CopyFilter(A, Other.B)` pushes one record's
    // filter onto another's field, which is how the method is nearly always used. ToH = H is the
    // same-record case.
    procedure CopyFilterField(H: Integer; FromFieldNo: Integer; ToH: Integer; ToFieldNo: Integer)
    var
        FromRef: FieldRef;
        ToRef: FieldRef;
    begin
        FromRef := RecRefs[H].Field(FromFieldNo);
        ToRef := RecRefs[ToH].Field(ToFieldNo);
        ToRef.SetFilter(FromRef.GetFilter());
    end;

    procedure GetRangeMinField(H: Integer; FieldNo: Integer): Variant
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.GetRangeMin());
    end;

    procedure GetRangeMaxField(H: Integer; FieldNo: Integer): Variant
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.GetRangeMax());
    end;

    // RecRef has no ModifyAll — iterate the filtered set. Conditional (return consumed) consumes
    // each row-Modify's Boolean so a failing modify returns false; otherwise the bare Modify throws.
    procedure ModifyAllField(H: Integer; FieldNo: Integer; Value: Variant; RunTrigger: Boolean; Conditional: Boolean): Boolean
    var
        IntRecRef: RecordRef;
        FRef: FieldRef;
    begin
        CheckWriteAllowed(H);
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        // Count the affected rows BEFORE the bulk op (§8: "count before modifyall").
        BumpOp(ModifyOps, RecRefs[H].Number(), RecRefs[H].Count());
        // Copy recref view then limit. Temp-ness must follow the source (see DeleteAllRec) —
        // otherwise ModifyAll on a temporary record wrote to the database table.
        IntRecRef.Open(RecRefs[H].Number, RecRefs[H].IsTemporary());
        CopyIntoRef(IntRecRef, H);
        IntRecRef.SetLoadFields(FieldNo);
        FRef := IntRecRef.Field(FieldNo);
        if IntRecRef.FindSet() then
            repeat
                FRef.Value := Value;
                if Conditional then begin
                    if not IntRecRef.Modify(RunTrigger) then
                        exit(false);
                end else
                    IntRecRef.Modify(RunTrigger);
            until IntRecRef.Next() = 0;
        exit(true);
    end;

    procedure CalcFieldsField(H: Integer; FieldNo: Integer)
    begin
        RecRefs[H].Field(FieldNo).CalcField();
    end;

    procedure CalcSumsField(H: Integer; FieldNo: Integer)
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        RecRefs[H].Field(FieldNo).CalcSum();
    end;

    // ===== BLOB fields (Rec.MyBlob.CreateInStream / CreateOutStream / HasValue / Length) =====
    //
    // Reads go through a Temp Blob taken from the RecordRef. Writes cannot reach the database
    // before the record itself is written, so CreateOutStream only parks the stream handle here
    // and Insert/Modify flushes it into the blob field — same observable order as native AL,
    // where the blob written in memory hits SQL on the record write.

    // Rec.MyBlob.CreateInStream(inStr): open StreamH over this record's blob content. A blob
    // still being written through CreateOutStream in the same run is read back from the
    // outstream's own backing (it is not in the record yet), which is what native AL does.
    procedure BlobCreateInStream(H: Integer; FieldNo: Integer; StreamH: Integer; Enc: Integer)
    var
        StrmRt: Codeunit "ALI Stream Runtime";
        TempBlob: Codeunit "Temp Blob";
        PendingH: Integer;
    begin
        GuardOpen(H);
        PendingH := PendingBlobStream(H, FieldNo);
        if PendingH <> 0 then begin
            StrmRt.LinkInToOut(StreamH, PendingH, Enc);
            exit;
        end;
        LoadBlob(H, FieldNo, TempBlob);      // CalcFields the blob if it is not loaded yet
        StrmRt.AttachInFromRecordRef(StreamH, RecRefs[H], FieldNo, Enc);
    end;

    // Rec.MyBlob.CreateOutStream(outStr): fresh empty blob, flushed into the field on write.
    procedure BlobCreateOutStream(H: Integer; FieldNo: Integer; StreamH: Integer; Enc: Integer)
    var
        StrmRt: Codeunit "ALI Stream Runtime";
    begin
        GuardOpen(H);
        if (StreamH < 1) or (StreamH > ArrayLen(PendingBlobRec)) then
            Error('ALI964: stream handle %1 out of range', StreamH);
        // Re-pointing a stream that is still holding a pending write for ANOTHER blob would
        // silently drop it; flush that one first (same reasoning as FlushPendingBlobStream).
        FlushPendingBlobStream(StreamH);
        StrmRt.ReopenOutEmpty(StreamH, Enc);
        PendingBlobRec[StreamH] := H;
        PendingBlobField[StreamH] := FieldNo;
    end;

    procedure BlobHasValue(H: Integer; FieldNo: Integer): Boolean
    begin
        exit(BlobLength(H, FieldNo) > 0);
    end;

    procedure BlobLength(H: Integer; FieldNo: Integer): Integer
    var
        StrmRt: Codeunit "ALI Stream Runtime";
        TempBlob: Codeunit "Temp Blob";
        PendingH: Integer;
    begin
        GuardOpen(H);
        PendingH := PendingBlobStream(H, FieldNo);
        if PendingH <> 0 then
            exit(StrmRt.StreamLength(PendingH));
        LoadBlob(H, FieldNo, TempBlob);
        exit(TempBlob.Length());
    end;

    // TempBlob.FromRecord / FromRecordRef / FromFieldRef ("ALI Native Runtime"): the record's blob
    // as Rec.Blob.CreateInStream would read it — a still-pending CreateOutStream write included
    // (pushed into the in-memory record first; the association stays, Insert/Modify pushes again).
    procedure BlobToTempBlob(H: Integer; FieldNo: Integer; var TempBlob: Codeunit "Temp Blob")
    var
        StrmRt: Codeunit "ALI Stream Runtime";
        PendingH: Integer;
    begin
        GuardOpen(H);
        PendingH := PendingBlobStream(H, FieldNo);
        if PendingH <> 0 then
            StrmRt.BlobToRecordRef(PendingH, RecRefs[H], FieldNo);
        LoadBlob(H, FieldNo, TempBlob);
    end;

    // TempBlob.ToRecordRef / ToFieldRef: into the in-memory record, which reaches the database on
    // Insert/Modify like any other field value. It replaces the field's blob, so a pending
    // CreateOutStream write on that field is dropped (Insert/Modify must not push it back over).
    procedure TempBlobToBlob(H: Integer; FieldNo: Integer; var TempBlob: Codeunit "Temp Blob")
    begin
        GuardOpen(H);
        ClearPendingBlobStream(PendingBlobStream(H, FieldNo));
        TempBlob.ToRecordRef(RecRefs[H], FieldNo);
    end;

    // Native catalogue record argument (Regex Matches/Groups/Captures/Options, Language's Windows
    // Language buffer — all temporary): Dest shares handle H's temp dataset, so the native
    // procedure's DeleteAll/Insert land in the script's record with no row copy.
    procedure ShareTempRef(H: Integer; var Dest: RecordRef)
    begin
        GuardOpen(H);
        if not RecRefs[H].IsTemporary() then
            Error('ALI980: a native catalogue record argument must be a temporary record (table %1)', RecRefs[H].Number());
        Dest.Open(RecRefs[H].Number(), true);
        Dest.Copy(RecRefs[H], true);
    end;

    // After the native call: current row + filters back into handle H (dataset still shared).
    procedure AdoptTempRef(H: Integer; var Src: RecordRef)
    begin
        RecRefs[H].Copy(Src, true);
    end;

    // ===== Media / MediaSet fields (Rec.Picture.MediaId / HasValue / Count / Item) =====
    //
    // ALI reaches every record field through a FieldRef, and a FieldRef cannot produce a native
    // Media/MediaSet object — only its VALUE, which for these two field types is the media (or
    // media-set) GUID. Everything derivable from that GUID is implemented here against the
    // Tenant Media / Tenant Media Set system tables, which is where the platform itself stores
    // the payload. Importing (Media.ImportStream / MediaSet.Insert / Remove) has no GUID-only
    // equivalent — it needs the strongly-typed field — so the BINDER rejects those methods
    // outright (ALI976) rather than this layer faking them by writing to system tables.

    procedure MediaId(H: Integer; FieldNo: Integer): Guid
    var
        Res: Guid;
    begin
        GuardOpen(H);
        Res := RecRefs[H].Field(FieldNo).Value();
        exit(Res);
    end;

    // Native HasValue() is "the field is set AND the media row exists" — both halves are
    // checkable from the GUID, so this matches rather than approximates.
    procedure MediaHasValue(H: Integer; FieldNo: Integer): Boolean
    var
        TenantMedia: Record "Tenant Media";
        Id: Guid;
    begin
        Id := MediaId(H, FieldNo);
        if IsNullGuid(Id) then
            exit(false);
        exit(TenantMedia.Get(Id));
    end;

    procedure MediaSetCount(H: Integer; FieldNo: Integer): Integer
    var
        TenantMediaSet: Record "Tenant Media Set";
        Id: Guid;
    begin
        Id := MediaId(H, FieldNo);
        if IsNullGuid(Id) then
            exit(0);
        TenantMediaSet.SetRange(ID, Id);
        exit(TenantMediaSet.Count());
    end;

    // MediaSet.Item(Index) — 1-based, native returns a blank GUID for an out-of-range index.
    procedure MediaSetItem(H: Integer; FieldNo: Integer; Index: Integer): Guid
    var
        TenantMediaSet: Record "Tenant Media Set";
        Blank: Guid;
        Id: Guid;
    begin
        Id := MediaId(H, FieldNo);
        if IsNullGuid(Id) then
            exit(Blank);
        if Index < 1 then
            exit(Blank);
        TenantMediaSet.SetRange(ID, Id);
        if not TenantMediaSet.FindSet() then
            exit(Blank);
        if Index > 1 then
            if TenantMediaSet.Next(Index - 1) = 0 then
                exit(Blank);
        exit(TenantMediaSet."Media ID".MediaId());
    end;

    local procedure LoadBlob(H: Integer; FieldNo: Integer; var TempBlob: Codeunit "Temp Blob")
    begin
        TempBlob.FromRecordRef(RecRefs[H], FieldNo);
        if TempBlob.HasValue() then
            exit;
        // An empty blob may just mean "not calculated yet" (FlowField blob, or a row whose blob
        // was not fetched). CalcField is the fix, and it is allowed to fail — a normal blob on
        // an in-memory record has nothing to calculate and genuinely is empty.
        if TryCalcBlobField(H, FieldNo) then
            TempBlob.FromRecordRef(RecRefs[H], FieldNo);
    end;

    [TryFunction]
    local procedure TryCalcBlobField(H: Integer; FieldNo: Integer)
    begin
        RecRefs[H].Field(FieldNo).CalcField();
    end;

    // Drop a pending blob write without keeping it. Only right when the RECORD is going away
    // (FreeRec) — there is nothing left to flush into.
    procedure ClearPendingBlobStream(StreamH: Integer)
    begin
        if (StreamH < 1) or (StreamH > ArrayLen(PendingBlobRec)) then
            exit;
        PendingBlobRec[StreamH] := 0;
        PendingBlobField[StreamH] := 0;
    end;

    // Push a pending blob write into its record, then drop the association. Called by
    // "ALI Stream Runtime".FreeStream when the OUTSTREAM dies — which, for a stream declared as
    // a procedure local, is at frame pop.
    //
    // Native AL semantics: `Rec.MyBlob.CreateOutStream(os)` writes THROUGH to the record's blob
    // field, so the bytes belong to the record and the stream is only a writer. ALI defers the
    // copy (see BlobCreateOutStream), which means the stream dying used to discard the write
    // entirely — a procedure whose OutStream was a local could not populate a blob at all, and
    // a following Modify() persisted the OLD value. Flushing here restores the native outcome:
    // whatever was written is in the record for any later read, Modify or CalcFields.
    procedure FlushPendingBlobStream(StreamH: Integer)
    var
        StrmRt: Codeunit "ALI Stream Runtime";
        RecUsable: Boolean;
        H: Integer;
    begin
        if (StreamH < 1) or (StreamH > ArrayLen(PendingBlobRec)) then
            exit;
        H := PendingBlobRec[StreamH];
        // Resolved in STAGES, never as one `and` chain: AL evaluates every operand of `and`
        // (§15 pitfall 2), so `(H >= 1) and RecOpen[H]` indexes RecOpen[0] whenever there is no
        // pending write — an out-of-range runtime error on every ordinary stream free.
        RecUsable := false;
        if (H >= 1) and (H <= HandleCount) then
            RecUsable := RecOpen[H];

        if RecUsable then
            StrmRt.BlobToRecordRef(StreamH, RecRefs[H], PendingBlobField[StreamH]);
        PendingBlobRec[StreamH] := 0;
        PendingBlobField[StreamH] := 0;
    end;

    // Stream handle currently writing (H, FieldNo), or 0. At most 16 stream handles exist.
    local procedure PendingBlobStream(H: Integer; FieldNo: Integer): Integer
    var
        i: Integer;
    begin
        for i := 1 to ArrayLen(PendingBlobRec) do
            if (PendingBlobRec[i] = H) and (PendingBlobField[i] = FieldNo) then
                exit(i);
        exit(0);
    end;

    // Push every blob written through Rec.MyBlob.CreateOutStream into the record, right before
    // it is written to the database.
    local procedure FlushPendingBlobs(H: Integer)
    var
        StrmRt: Codeunit "ALI Stream Runtime";
        i: Integer;
    begin
        for i := 1 to ArrayLen(PendingBlobRec) do
            if PendingBlobRec[i] = H then
                StrmRt.BlobToRecordRef(i, RecRefs[H], PendingBlobField[i]);
    end;

    // TestField(field) — non-zero/non-blank check, no explicit value to compare against.
    procedure TestFieldEmpty(H: Integer; FieldNo: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.TestField();
    end;

    // TestField(field, value) — value-match check (ErrorInfo overload not modeled, per scope).
    procedure TestFieldValue(H: Integer; FieldNo: Integer; Value: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.TestField(Value);
    end;

    procedure FieldErrorDefault(H: Integer; FieldNo: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.FieldError();
    end;

    procedure FieldErrorText(H: Integer; FieldNo: Integer; Msg: Text)
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        FRef.FieldError(Msg);
    end;

    procedure FieldNameOf(H: Integer; FieldNo: Integer): Text
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Name());
    end;

    procedure FieldCaptionOf(H: Integer; FieldNo: Integer): Text
    var
        FRef: FieldRef;
    begin
        FRef := RecRefs[H].Field(FieldNo);
        exit(FRef.Caption());
    end;

    procedure TableNameOf(H: Integer): Text
    begin
        exit(RecRefs[H].Name);
    end;

    procedure TableCaptionOf(H: Integer): Text
    begin
        exit(RecRefs[H].Caption);
    end;

    procedure FullyQualifiedNameOf(H: Integer): Text
    begin

#if BC28Plus
        exit(RecRefs[H].FullyQualifiedName());
#else
        Error('Runtime error : Record.FullyQualifiedName method is only supported in Business Central AL runtime 17.0+ (v28+).');
#endif
    end;

    // SetCurrentKey(field,...): selects the declared key whose field sequence starts with
    // the given field numbers, in order (RecordRef has no free-form multi-field SetCurrentKey
    // — only a fixed set of declared KeyRefs, so this picks the best-matching one, same as
    // native behavior when no exact key matches the requested field list).
    procedure SetCurrentKeyList(H: Integer; FieldNos: List of [Integer])
    var
        BestKeyIdx: Integer;
        BestMatchLen: Integer;
        i: Integer;
        MatchLen: Integer;
        KRef: KeyRef;
    begin
        BestKeyIdx := 1;
        BestMatchLen := 0;
        for i := 1 to RecRefs[H].KeyCount() do begin
            KRef := RecRefs[H].KeyIndex(i);
            MatchLen := 0;
            while (MatchLen < FieldNos.Count()) and (MatchLen < KRef.FieldCount()) do begin
                if KRef.FieldIndex(MatchLen + 1).Number() <> FieldNos.Get(MatchLen + 1) then
                    break;
                MatchLen += 1;
            end;
            if MatchLen > BestMatchLen then begin
                BestMatchLen := MatchLen;
                BestKeyIdx := i;
            end;
        end;
        RecRefs[H].CurrentKeyIndex(BestKeyIdx);
    end;

    procedure GetAscendingRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].Ascending());
    end;

    procedure SetAscendingRec(H: Integer; Value: Boolean)
    begin
        RecRefs[H].Ascending(Value);
    end;

    // Native SetAscending(FieldNo, Bool) is a typed-Record-only method — there is no
    // FieldRef.SetAscending. A RecordRef's sort direction is per-KEY, not per-field
    // (RecordRef.Ascending is the only direction knob it exposes), so the FieldNo is used
    // ONLY as a guard: setting the direction "for a field" means setting the current key's
    // direction, and that is meaningful only while the field actually takes part in the
    // current sorting. If it does not, this is a no-op.
    //
    // Direction is NOT round-tripped through the view text: SetView does not reliably carry
    // an Order(...) clause back out of GetView, so a text-rewrite emulation reads back as
    // ascending no matter what was written.
    procedure SetAscendingField(H: Integer; FieldNo: Integer; Value: Boolean)
    begin
        if not ViewSortingHasField(RecRefs[H].GetView(false), FieldNo) then
            exit;
        RecRefs[H].Ascending(Value);
    end;

    // See SetAscendingField: the direction is the current key's, and it only answers for a
    // field that is part of the current sorting — false when the field is not.
    procedure GetAscendingField(H: Integer; FieldNo: Integer): Boolean
    begin
        if not ViewSortingHasField(RecRefs[H].GetView(false), FieldNo) then
            exit(false);
        exit(RecRefs[H].Ascending());
    end;

    local procedure ViewSortingHasField(ViewTxt: Text; FieldNo: Integer): Boolean
    var
        P: Integer;
        Q: Integer;
        Parts: List of [Text];
        Part: Text;
        SortBody: Text;
        Target: Text;
    begin
        P := StrPos(UpperCase(ViewTxt), 'SORTING(');
        if P = 0 then
            exit(false);
        P += StrLen('SORTING(');
        Q := StrPos(CopyStr(ViewTxt, P), ')'); // field list has no nested parens
        if Q = 0 then
            exit(false);
        SortBody := CopyStr(ViewTxt, P, Q - 1);
        Target := 'FIELD' + Format(FieldNo);
        Parts := SortBody.Split(',');
        foreach Part in Parts do
            if UpperCase(DelChr(Part, '<>', ' ')) = Target then
                exit(true);
        exit(false);
    end;

    procedure CurrentKeyOf(H: Integer): Text
    begin
        exit(RecRefs[H].CurrentKey());
    end;

    procedure SetMark(H: Integer; Value: Boolean)
    begin
        RecRefs[H].Mark(Value);
    end;

    procedure GetMark(H: Integer): Boolean
    begin
        exit(RecRefs[H].Mark());
    end;

    procedure ClearMarksRec(H: Integer)
    begin
        RecRefs[H].ClearMarks();
    end;

    procedure SetMarkedOnly(H: Integer; Value: Boolean)
    begin
        RecRefs[H].MarkedOnly(Value);
    end;

    procedure GetMarkedOnly(H: Integer): Boolean
    begin
        exit(RecRefs[H].MarkedOnly());
    end;

    procedure GetPositionOf(H: Integer; IncludeSortOrder: Boolean): Text
    begin
        exit(RecRefs[H].GetPosition(IncludeSortOrder));
    end;

    procedure SetPositionOf(H: Integer; Position: Text)
    begin
        RecRefs[H].SetPosition(Position);
    end;

    procedure GetViewOf(H: Integer; IncludeSortOrder: Boolean): Text
    begin
        exit(RecRefs[H].GetView(IncludeSortOrder));
    end;

    procedure SetViewOf(H: Integer; ViewText: Text)
    begin
        RecRefs[H].SetView(ViewText);
    end;

    // ChangeCompany('') mirrors ChangeCompany() with no argument (current company).
    procedure ChangeCompanyRec(H: Integer; CompanyName: Text)
    begin
        RecRefs[H].ChangeCompany(CompanyName);
        MarkSecured(H);
    end;

    procedure CurrentCompanyOf(H: Integer): Text
    begin
        exit(RecRefs[H].CurrentCompany());
    end;

    procedure GetFiltersOf(H: Integer): Text
    begin
        exit(RecRefs[H].GetFilters());
    end;

    procedure HasFilterRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].HasFilter());
    end;

    // FilterGroup([Group]) — getter returns the currently active filter group; setter activates
    // Group and returns the group that was active BEFORE (native RecordRef.FilterGroup semantics).
    // Group range is -1..7.
    procedure FilterGroupGet(H: Integer): Integer
    begin
        exit(RecRefs[H].FilterGroup());
    end;

    procedure FilterGroupSet(H: Integer; NewGroup: Integer): Integer
    begin
        exit(RecRefs[H].FilterGroup(NewGroup));
    end;

    // Value-semantics record copy (§7.5): TargetRec := SourceRec copies field values by
    // value (a later mutation of the source must not affect the copy). Both handles must be
    // open on the same table. Implemented field-by-field via FieldRef so it does not depend
    // on RecordRef.Copy availability and cannot alias.
    procedure CopyRec(DestH: Integer; SrcH: Integer)
    var
        DestField: FieldRef;
        SrcField: FieldRef;
        i: Integer;
    begin
        for i := 1 to RecRefs[SrcH].FieldCount() do begin
            SrcField := RecRefs[SrcH].FieldIndex(i);
            DestField := RecRefs[DestH].Field(SrcField.Number());
            DestField.Value(SrcField.Value());
        end;
    end;

    // Native .Copy(Record [, ShareTable]) — distinct from CopyRec (value-semantics `:=`
    // assignment, §7.5). Copy ALWAYS carries the row, the filters, the view and the marks; the
    // optional Boolean is native AL's shareTable, NOT an "include filters" switch (the platform
    // rejects shareTable = true unless BOTH records are temporary — "The COPY function can only
    // be used with the shareTable argument set to true if both records are temporary"). Passed
    // straight through so a script sees exactly the native behaviour, error included.
    procedure CopyRec2(DestH: Integer; SrcH: Integer; ShareTable: Boolean)
    begin
        RecRefs[DestH].Copy(RecRefs[SrcH], ShareTable);
    end;

    // The internal copy every RecordRef-level operation uses (GetTable / SetTable / Duplicate,
    // and the two bulk ops that clone a filtered view into a private cursor).
    //
    // shareTable is decided HERE rather than by the caller, because the caller never has a
    // meaningful opinion about it and getting it wrong fails both ways round:
    //   * shareTable = true on non-temporary records is a hard platform error (that is what
    //     Duplicate()/GetTable() used to raise — they passed a literal `true` meaning "include
    //     filters", a parameter that does not exist on Copy);
    //   * shareTable = false between two TEMPORARY records gives the destination its own EMPTY
    //     temp dataset, so a "copy" of a temp record would see none of its rows — silently.
    // Both temporary => share, otherwise plain Copy. Filters travel either way.
    local procedure CopyIntoRef(var Dest: RecordRef; SrcH: Integer)
    begin
        if Dest.IsTemporary() and RecRefs[SrcH].IsTemporary() then
            Dest.Copy(RecRefs[SrcH], true)
        else
            Dest.Copy(RecRefs[SrcH]);
    end;

    procedure CopyFiltersRec(DestH: Integer; SrcH: Integer)
    begin
        RecRefs[DestH].SetView(RecRefs[SrcH].GetView());
    end;

    procedure SetRecFilterRec(H: Integer)
    begin
        RecRefs[H].SetRecFilter();
    end;

    procedure TruncateRec(H: Integer; RunTrigger: Boolean)
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        RecRefs[H].Truncate(RunTrigger);
    end;

    procedure IsTemporaryRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].IsTemporary());
    end;

    procedure CountApproxRec(H: Integer): Integer
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        exit(RecRefs[H].CountApprox());
    end;

    procedure ReadPermissionRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].ReadPermission());
    end;

    procedure WritePermissionRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].WritePermission());
    end;

    // TransferFields: copies every matching field (by field NUMBER present on BOTH records)
    // from src into this record's in-memory buffer — unconditional overwrite, same as native
    // (the Boolean overloads control trigger/system-field nuances this interpreter does not
    // model yet). Implemented field-by-field via FieldRef since RecordRef has no built-in
    // TransferFields.
    procedure TransferFieldsRec(DestH: Integer; SrcH: Integer; Unused: Boolean)
    var
        SrcField: FieldRef;
        i: Integer;
    begin
        for i := 1 to RecRefs[SrcH].FieldCount() do begin
            SrcField := RecRefs[SrcH].FieldIndex(i);
            if RecRefs[DestH].FieldExist(SrcField.Number()) then
                RecRefs[DestH].Field(SrcField.Number()).Value(SrcField.Value());
        end;
    end;

    // Get/Rename share the same primary-key-value shape (§7.5) — one Variant per PK field,
    // 1..16 fields. Rename builds a scratch RecordRef the same way GetRec does, but calls
    // Rename() (which both changes the key AND repositions the current record).
    procedure RenameRec(H: Integer; KeyValue1: Variant)
    begin
        CheckWriteAllowed(H);
        RecRefs[H].Rename(KeyValue1);
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant; KeyValue15: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        TempRecRf.KeyIndex(1).FieldIndex(15).Value := KeyValue15;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    procedure RenameRec(H: Integer; KeyValue1: Variant; KeyValue2: Variant; KeyValue3: Variant; KeyValue4: Variant; KeyValue5: Variant; KeyValue6: Variant; KeyValue7: Variant; KeyValue8: Variant; KeyValue9: Variant; KeyValue10: Variant; KeyValue11: Variant; KeyValue12: Variant; KeyValue13: Variant; KeyValue14: Variant; KeyValue15: Variant; KeyValue16: Variant)
    var
        TempRecRf: RecordRef;
    begin
        CheckWriteAllowed(H);
        TempRecRf.Open(RecRefs[H].Number);
        TempRecRf.KeyIndex(1).FieldIndex(1).Value := KeyValue1;
        TempRecRf.KeyIndex(1).FieldIndex(2).Value := KeyValue2;
        TempRecRf.KeyIndex(1).FieldIndex(3).Value := KeyValue3;
        TempRecRf.KeyIndex(1).FieldIndex(4).Value := KeyValue4;
        TempRecRf.KeyIndex(1).FieldIndex(5).Value := KeyValue5;
        TempRecRf.KeyIndex(1).FieldIndex(6).Value := KeyValue6;
        TempRecRf.KeyIndex(1).FieldIndex(7).Value := KeyValue7;
        TempRecRf.KeyIndex(1).FieldIndex(8).Value := KeyValue8;
        TempRecRf.KeyIndex(1).FieldIndex(9).Value := KeyValue9;
        TempRecRf.KeyIndex(1).FieldIndex(10).Value := KeyValue10;
        TempRecRf.KeyIndex(1).FieldIndex(11).Value := KeyValue11;
        TempRecRf.KeyIndex(1).FieldIndex(12).Value := KeyValue12;
        TempRecRf.KeyIndex(1).FieldIndex(13).Value := KeyValue13;
        TempRecRf.KeyIndex(1).FieldIndex(14).Value := KeyValue14;
        TempRecRf.KeyIndex(1).FieldIndex(15).Value := KeyValue15;
        TempRecRf.KeyIndex(1).FieldIndex(16).Value := KeyValue16;
        RecRefs[H].Rename(TempRecRf.RecordId());
    end;

    // ===== Field load set / auto-calc (§7.5) =====
    // RecordRef.SetLoadFields/AddLoadFields/LoadFields/AreFieldsLoaded are variadic (no List
    // overload), but the load set is ADDITIVE so a field list can be replayed incrementally.
    // SetAutoCalcFields is variadic REPLACE, so it needs the arity overloads below instead.

    procedure SetLoadFieldsRec(H: Integer; FieldNos: List of [Integer]): Boolean
    var
        First: Boolean;
        Res: Boolean;
        FieldNo: Integer;
    begin
        // Empty list = native SetLoadFields() reset (reload all fields).
        if FieldNos.Count() = 0 then
            exit(RecRefs[H].SetLoadFields());
        // "Set to exactly these": seed the set with the first field (SetLoadFields replaces),
        // then extend with AddLoadFields for the rest.
        First := true;
        Res := true;
        foreach FieldNo in FieldNos do
            if First then begin
                Res := RecRefs[H].SetLoadFields(FieldNo);
                First := false;
            end else
                Res := RecRefs[H].AddLoadFields(FieldNo);
        exit(Res);
    end;

    procedure AddLoadFieldsRec(H: Integer; FieldNos: List of [Integer]): Boolean
    var
        Res: Boolean;
        FieldNo: Integer;
    begin
        Res := true;
        foreach FieldNo in FieldNos do
            Res := RecRefs[H].AddLoadFields(FieldNo);
        exit(Res);
    end;

    procedure LoadFieldsRec(H: Integer; FieldNos: List of [Integer]): Boolean
    var
        Res: Boolean;
        FieldNo: Integer;
    begin
        Res := true;
        foreach FieldNo in FieldNos do
            if not RecRefs[H].LoadFields(FieldNo) then
                Res := false;
        exit(Res);
    end;

    procedure AreFieldsLoadedRec(H: Integer; FieldNos: List of [Integer]): Boolean
    var
        FieldNo: Integer;
    begin
        foreach FieldNo in FieldNos do
            if not RecRefs[H].AreFieldsLoaded(FieldNo) then
                exit(false);
        exit(true);
    end;

    // SetAutoCalcFields(field,...) — variadic overloads 0..16 (no List spread; each call
    // replaces the auto-calc set, so it cannot be built incrementally like the load set).
    procedure SetAutoCalcFieldsRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields());
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer; F12: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer; F12: Integer; F13: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer; F12: Integer; F13: Integer; F14: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer; F12: Integer; F13: Integer; F14: Integer; F15: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15));
    end;

    procedure SetAutoCalcFieldsRec(H: Integer; F1: Integer; F2: Integer; F3: Integer; F4: Integer; F5: Integer; F6: Integer; F7: Integer; F8: Integer; F9: Integer; F10: Integer; F11: Integer; F12: Integer; F13: Integer; F14: Integer; F15: Integer; F16: Integer): Boolean
    begin
        exit(RecRefs[H].SetAutoCalcFields(F1, F2, F3, F4, F5, F6, F7, F8, F9, F10, F11, F12, F13, F14, F15, F16));
    end;

    // ===== Locking / consistency / metadata counts (§7.5) =====

    // LockTable([Wait]): the KeepDataCache overload arg is not modeled — Wait covers the
    // blocking-vs-non-blocking choice scripts need.
    procedure LockTableRec(H: Integer; Wait: Boolean)
    begin
        RecRefs[H].LockTable(Wait);
    end;

    procedure GetReadConsistencyRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].ReadConsistency());
    end;

    procedure FieldCountRec(H: Integer): Integer
    begin
        exit(RecRefs[H].FieldCount());
    end;

    procedure FieldExistRec(H: Integer; FieldNo: Integer): Boolean
    begin
        exit(RecRefs[H].FieldExist(FieldNo));
    end;

    procedure KeyCountRec(H: Integer): Integer
    begin
        exit(RecRefs[H].KeyCount());
    end;

    procedure GetCurrentKeyIndexRec(H: Integer): Integer
    begin
        exit(RecRefs[H].CurrentKeyIndex());
    end;

    procedure SetCurrentKeyIndexRec(H: Integer; NewKeyIndex: Integer)
    begin
        RecRefs[H].CurrentKeyIndex(NewKeyIndex);
    end;

    // ===== Find(Text) / GetBySystemId (§7.5) =====
    // Find(Which) — the direction/relation selector overload ('-','+','=','<','>','<=','>=').
    // addDataError like Get/FindFirst: consuming the return (Conditional) suppresses the
    // no-match runtime error and returns false; a bare statement Find re-raises.
    procedure FindTextRec(H: Integer; Which: Text; Conditional: Boolean): Boolean
    begin
        if Secured[H] then
            ApplySecurity(RecRefs[H]);
        if Conditional then
            exit(RecRefs[H].Find(Which));
        RecRefs[H].Find(Which);
        exit(true);
    end;

    // GetBySystemId(Guid) — locate by the SystemId field. Same optional-return error
    // semantics as Get: Conditional consumes the native Boolean (miss returns false); a bare
    // statement throws on no match.
    procedure GetBySystemIdRec(H: Integer; Conditional: Boolean; Id: Guid): Boolean
    begin
        if Conditional then begin
            if not RecRefs[H].GetBySystemId(Id) then
                exit(false);
        end else
            RecRefs[H].GetBySystemId(Id);
        if Secured[H] then
            exit(SecuredGetResult(H, Conditional));
        exit(true);
    end;

    // ===== Record links (URLs/notes attached to a record) =====

    procedure AddLinkRec(H: Integer; Url: Text; Description: Text; HasDesc: Boolean): Integer
    begin
        if HasDesc then
            exit(RecRefs[H].AddLink(Url, Description));
        exit(RecRefs[H].AddLink(Url));
    end;

    procedure DeleteLinkRec(H: Integer; LinkId: Integer)
    begin
        RecRefs[H].DeleteLink(LinkId);
    end;

    procedure DeleteLinksRec(H: Integer)
    begin
        RecRefs[H].DeleteLinks();
    end;

    // CopyLinks(FromRecord): copy the source record's links onto this one. Reuses the
    // same-table BindRecArg check at bind time; native CopyLinks itself is table-agnostic,
    // but the interpreter only stages same-table record args (scope decision).
    procedure CopyLinksRec(DestH: Integer; SrcH: Integer)
    begin
        RecRefs[DestH].CopyLinks(RecRefs[SrcH]);
    end;

    procedure HasLinksRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].HasLinks());
    end;

    // ===== Isolation / permission / security (property getters+setters) =====
    // ReadIsolation is the native IsolationLevel option; exposed to scripts as its ordinal
    // Integer (Default 0, ReadUncommitted 1, ReadCommitted 2, RepeatableRead 3, UpdLock 4).
    // Mapped by case both ways so it doesn't rely on AsInteger()/FromInteger() on the
    // built-in system option.
    procedure GetReadIsolationRec(H: Integer): Integer
    var
        Iso: IsolationLevel;
    begin
        Iso := RecRefs[H].ReadIsolation();
        case Iso of
            IsolationLevel::Default:
                exit(0);
            IsolationLevel::ReadUncommitted:
                exit(1);
            IsolationLevel::ReadCommitted:
                exit(2);
            IsolationLevel::RepeatableRead:
                exit(3);
            IsolationLevel::UpdLock:
                exit(4);
        end;
        exit(0);
    end;

    procedure SetReadIsolationRec(H: Integer; Level: Integer)
    var
        Iso: IsolationLevel;
    begin
        case Level of
            0:
                Iso := IsolationLevel::Default;
            1:
                Iso := IsolationLevel::ReadUncommitted;
            2:
                Iso := IsolationLevel::ReadCommitted;
            3:
                Iso := IsolationLevel::RepeatableRead;
            4:
                Iso := IsolationLevel::UpdLock;
            else
                Error('ALI957: invalid ReadIsolation ordinal %1 (expected 0..4)', Level);
        end;
        RecRefs[H].ReadIsolation(Iso);
    end;

    procedure SetPermissionFilterRec(H: Integer)
    begin
        RecRefs[H].SetPermissionFilter();
    end;

    // SecurityFiltering: native SecurityFilter option as its ordinal Integer
    // (Validated 0, Filtered 1, Ignored 2, Disallowed 3). Same case-map approach as
    // ReadIsolation.
    procedure GetSecurityFilteringRec(H: Integer): Integer
    var
        SF: SecurityFilter;
    begin
        SF := RecRefs[H].SecurityFiltering();
        case SF of
            SecurityFilter::Validated:
                exit(0);
            SecurityFilter::Filtered:
                exit(1);
            SecurityFilter::Ignored:
                exit(2);
            SecurityFilter::Disallowed:
                exit(3);
        end;
        exit(0);
    end;

    procedure SetSecurityFilteringRec(H: Integer; Value: Integer)
    var
        SF: SecurityFilter;
    begin
        case Value of
            0:
                SF := SecurityFilter::Validated;
            1:
                SF := SecurityFilter::Filtered;
            2:
                SF := SecurityFilter::Ignored;
            3:
                SF := SecurityFilter::Disallowed;
            else
                Error('ALI958: invalid SecurityFiltering ordinal %1 (expected 0..3)', Value);
        end;
        RecRefs[H].SecurityFiltering(SF);
    end;

    procedure RecordLevelLockingRec(H: Integer): Boolean
    begin
        exit(RecRefs[H].RecordLevelLocking());
    end;

    // M11 phase C3 — the record a handle stands for, as a Variant, so it can be handed to the
    // platform's `Codeunit.Run(id, var Record)`.
    //
    // Native AL will not take a RecordRef there (AL0133: "cannot convert from 'RecordRef' to
    // 'var Table'"), and a Variant is the only shape that call accepts generically. The Variant
    // is built from the RecordRef itself, so whether the platform hands the callee an ALIAS or a
    // COPY of the row is the platform's decision, not something ALI can choose — the
    // Codeunit.Run record round-trip test is what pins it.
    procedure RecordAsVariant(H: Integer; var V: Variant)
    begin
        GuardOpen(H);
        if Secured[H] then
            ApplySecurity(RecRefs[H]); // native callee (Page/Report.Run, codeunit) gets the filters
        V := RecRefs[H];
    end;

    // ===== User-declared RecordRef (P1) =====
    //
    // A RecordRef VARIABLE reuses this bank verbatim — the handle it carries is the same kind
    // of 1-based RecRefs[] index a Record variable carries, which is precisely why ~106 REC_*
    // opcodes are reachable from a RecordRef receiver without one line of new execution code
    // (see "ALI Opcode"::REF_METHOD). The one genuine difference is LIFECYCLE: a Record local
    // gets its handle from the proc prologue, a RecordRef gets it from Open() and gives it back
    // at Close(), so before Open() the variable holds handle 0 and EVERY operation on it must
    // fail truthfully (AssertRefOpen / ALI937) instead of indexing RecRefs[0].

    // The truthful use-before-Open diagnostic. Handle 0 is the "declared but never opened"
    // state (a RecordRef local is NOT given a handle at proc entry, unlike a Record local), and
    // any other unopened slot means the variable was Close()d and then used again.
    procedure AssertRefOpen(H: Integer)
    begin
        if H = 0 then
            Error('ALI937: this RecordRef is not open — call Open(<table id or name>) before using it');
        if (H < 1) or (H > MaxRecordHandles()) then
            Error('ALI955: record handle %1 out of range', H);
        if not RecOpen[H] then
            Error('ALI937: this RecordRef is not open — it was closed, or never opened');
    end;

    // RecordRef.Open(TableId [, Temporary] [, CompanyName]). Returns the handle to store back
    // into the variable: 0 in (never opened) allocates a fresh slot, otherwise the SAME slot is
    // re-opened, so `RRef.Open(a); RRef.Open(b);` reuses one slot and every alias of the
    // variable follows it — native re-scoping semantics.
    procedure OpenRefById(H: Integer; TableId: Integer; Temp: Boolean; CompanyName: Text): Integer
    begin
        if H = 0 then begin
            if FreeIdx.Count() > 0 then begin
                H := FreeIdx.Get(FreeIdx.Count());
                FreeIdx.RemoveAt(FreeIdx.Count());
            end else begin
                if HandleCount >= MaxRecordHandles() then
                    Error('ALI954: too many concurrently open record variables (max %1)%2', MaxRecordHandles(), OpenSlotCensus());
                HandleCount += 1;
                H := HandleCount;
            end;
        end;
        GuardHandle(H);
        if RecOpen[H] then
            RecRefs[H].Close();
        // Native has one overload per combination; there is no "absent argument" value to pass
        // through, so the combinations are spelled out.
        case true of
            (CompanyName <> ''):
                RecRefs[H].Open(TableId, Temp, CompanyName);
            Temp:
                RecRefs[H].Open(TableId, true);
            else
                RecRefs[H].Open(TableId);
        end;
        RecOpen[H] := true;
        RecOrigin[H] := 3;
        MarkSecured(H);
        exit(H);
    end;

    // RecordRef.Open by table NAME. Native AL has no such overload — a script that only knows
    // the table by name would otherwise have to hard-code an id, which is exactly the thing a
    // RecordRef exists to avoid. Resolved against deployed object metadata, so an unknown name
    // is a truthful error rather than a wrong table.
    procedure OpenRefByName(H: Integer; TableName: Text; Temp: Boolean; CompanyName: Text): Integer
    var
        TableId: Integer;
    begin
        if not TryResolveTableId(TableName, TableId) then
            Error('ALI937: no table named ''%1'' is deployed — RecordRef.Open cannot resolve it', TableName);
        exit(OpenRefById(H, TableId, Temp, CompanyName));
    end;

    local procedure TryResolveTableId(TableName: Text; var TableId: Integer): Boolean
    var
        AllObj: Record AllObjWithCaption;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
        AllObj.SetRange("Object Name", CopyStr(TableName, 1, MaxStrLen(AllObj."Object Name")));
        if not AllObj.FindFirst() then
            exit(false);
        TableId := AllObj."Object ID";
        exit(true);
    end;

    // RecordRef.Close(). The slot goes back on the free list, so a long loop of Open/Close pairs
    // cannot exhaust the bank. The caller (the interpreter) writes 0 back into the variable's
    // register, which puts it back in the truthful "not open" state.
    procedure CloseRef(H: Integer)
    begin
        if H = 0 then
            exit;                       // Close() on a never-opened RecordRef is a native no-op
        AssertRefOpen(H);
        FreeRec(H);
    end;

    procedure NumberOfRef(H: Integer): Integer
    begin
        AssertRefOpen(H);
        exit(RecRefs[H].Number());
    end;

    // RecordRef.Duplicate() — a SECOND handle on the same table carrying the same content and
    // filters. ponytail: the fresh handle is not tracked on the interpreter's frame-scoped alloc
    // stack (a RecordRef's lifetime is Open/Close, not frame scope, and an alias may outlive the
    // frame), so it is reclaimed at Close() or at the end of the run by Reset(). Ceiling: a
    // Duplicate() inside a hot loop with no Close() burns handles up to MaxRecordHandles.
    // Upgrade path: refcount the bank slots, or track RecordRef handles per frame once
    // escape analysis covers them.
    procedure DuplicateRef(H: Integer): Integer
    var
        NewH: Integer;
    begin
        AssertRefOpen(H);
        // Open the second slot on the same table and same temp-ness, then copy — see
        // CopyIntoRef for why the shareTable decision belongs there and not here. (Native has a
        // one-call RecordRef.Duplicate, but it wants a target RecordRef VARIABLE; the target
        // here is a bank slot, and Open+Copy reaches the identical state.)
        NewH := NewRec(RecRefs[H].Number(), RecRefs[H].IsTemporary(), 3);
        CopyIntoRef(RecRefs[NewH], H);
        exit(NewH);
    end;

    // RecordRef.GetTable(Record) — take the record's content. Both sides are already native
    // RecordRefs in this one bank, so it is a handle-to-handle copy. A ref pointing at another
    // table (or at nothing yet) is re-opened on the record's table first, matching native, where
    // GetTable re-points the reference.
    procedure GetTableRef(RefH: Integer; RecH: Integer; var NewRefH: Integer)
    var
        MustOpen: Boolean;
    begin
        GuardOpen(RecH);
        NewRefH := RefH;
        // Resolved in STAGES, never as one `or` chain: AL evaluates EVERY operand of `or`
        // (§15 pitfall 2), so `(RefH = 0) or (not RecOpen[RefH])` indexes RecOpen[0] on the very
        // case it is there to catch — the never-opened ref, i.e. the documented FIRST use of a
        // RecordRef (`r.GetTable(c)`). That is an "index out of bounds" from inside the runtime
        // instead of the adoption this method exists to perform. Same staged shape as
        // FlushPendingBlobStream above.
        MustOpen := RefH = 0;
        if not MustOpen then
            MustOpen := not RecOpen[RefH];
        if not MustOpen then
            MustOpen := RecRefs[RefH].Number() <> RecRefs[RecH].Number();
        // Temp-ness is part of "which table this ref points at": a ref left open on the real
        // table cannot hold a temporary record's rows (it would copy from a temp dataset it does
        // not share and come back empty), so a disagreement re-points the ref exactly as a table
        // id disagreement does. Native GetTable re-binds the reference wholesale.
        if not MustOpen then
            MustOpen := RecRefs[RefH].IsTemporary() <> RecRefs[RecH].IsTemporary();
        if MustOpen then
            NewRefH := OpenRefById(RefH, RecRefs[RecH].Number(), RecRefs[RecH].IsTemporary(), '');
        CopyIntoRef(RecRefs[NewRefH], RecH);
    end;

    // RecordRef.SetTable(Record [, IncludeFilters]) — push the ref's content back into a record
    // VARIABLE, whose table is fixed at compile time. The table ids therefore have to agree, and
    // the check has to happen at run time because the ref's table is not known before then.
    // ponytail: the IncludeFilters argument is accepted and ignored — a native Copy carries the
    // filters unconditionally and there is no "content only" primitive to build the false case
    // on. Ceiling: `RRef.SetTable(Rec, false)` leaves Rec filtered by the ref's view instead of
    // unfiltered; the default (no argument) case, which is every use in practice and every use
    // in the tests, is exactly native. Upgrade path: stash Rec.GetView() before the copy and
    // restore it after, once a test pins what native actually does with the second argument.
    procedure SetTableRef(RefH: Integer; RecH: Integer; IncludeFilters: Boolean)
    begin
        AssertRefOpen(RefH);
        GuardOpen(RecH);
        if RecRefs[RefH].Number() <> RecRefs[RecH].Number() then
            Error('ALI937: SetTable expects a record of table %1, but the target variable is table %2',
                RecRefs[RefH].Number(), RecRefs[RecH].Number());
        CopyIntoRef(RecRefs[RecH], RefH);
    end;

    // RecordRef.FieldExist by NAME — the by-NUMBER form routes to the existing REC_FIELDEXIST
    // opcode instead (nothing to add there). Names are compared case-insensitively, as AL does.
    procedure FieldExistByName(H: Integer; FieldName: Text): Boolean
    var
        FRef: FieldRef;
        i: Integer;
    begin
        AssertRefOpen(H);
        for i := 1 to RecRefs[H].FieldCount() do begin
            FRef := RecRefs[H].FieldIndex(i);
            if UpperCase(FRef.Name()) = UpperCase(FieldName) then
                exit(true);
        end;
        exit(false);
    end;

    // The five system-field NUMBER getters (SystemId / SystemCreatedAt / SystemCreatedBy /
    // SystemModifiedAt / SystemModifiedBy). One entry point keyed by the method id keeps five
    // near-identical one-liners out of the interpreter's dispatch.
    procedure SystemFieldNoRef(H: Integer; Which: Integer): Integer
    begin
        AssertRefOpen(H);
        case Which of
            10:
                exit(RecRefs[H].SystemIdNo());
            11:
                exit(RecRefs[H].SystemCreatedAtNo());
            12:
                exit(RecRefs[H].SystemCreatedByNo());
            13:
                exit(RecRefs[H].SystemModifiedAtNo());
            14:
                exit(RecRefs[H].SystemModifiedByNo());
        end;
    end;

    // ===== FieldRef / KeyRef (P2/P3) =====
    //
    // A FieldRef VALUE in this interpreter is an Integer packing (record handle, field number);
    // a KeyRef packs (record handle, key index). Nothing native is stored — every operation
    // below re-materializes `RecRefs[rh].Field(fno)` / `.KeyIndex(ki)` and drops it again. See
    // "ALI Opcode"::FLD_METHOD for the full rationale; the two load-bearing points are:
    //
    //   1. write-through is NOT a new assumption. `FRef := RecRefs[H].Field(n); FRef.Value(x)`
    //      is literally what SetFieldText/SetFieldInt/ValidateField above have been doing since
    //      M6 — the native FieldRef returned by RecordRef.Field() writes into the row the
    //      RecordRef holds, it is not a detached copy. So materializing on demand loses nothing.
    //   2. there is therefore no bank, no free list and no lifecycle. `Field(n)` is a PURE
    //      function of (h, n): calling it a million times in a loop yields the same integer a
    //      million times and allocates nothing. That is the property an `array[N] of FieldRef`
    //      bank could not have (`:=` gives the lowerer no hook to release the overwritten
    //      handle, so every loop turn would burn a slot).
    //
    // Packing: Handle = Slot * FieldRefStride + RecHandle, RecHandle in 1..1024. For a FieldRef,
    // Slot is a 1-based index into FieldNoPool — AL field numbers run to 2000000000 (SystemId),
    // which does not fit alongside a handle in a 32-bit Integer, but the count of DISTINCT field
    // numbers one script mentions trivially does. For a KeyRef, Slot IS the 1-based key index.
    // Handle 0 = unbound (a local starts there), and every entry point asserts that first.

    local procedure FieldRefStride(): Integer
    begin
        exit(2048);     // > MaxRecordHandles() = 1024, so the two halves never collide
    end;

    // Intern a field number, returning its 1-based pool slot. Idempotent — this is what makes a
    // FieldRef handle a pure function of (recHandle, fieldNo) and so leak-free.
    local procedure InternFieldNo(FieldNo: Integer): Integer
    var
        Slot: Integer;
    begin
        if FieldNoIndex.Get(FieldNo, Slot) then
            exit(Slot);
        FieldNoPool.Add(FieldNo);
        Slot := FieldNoPool.Count();
        if Slot > 1048575 then      // Slot * 2048 must stay inside a 32-bit Integer
            Error('ALI954: too many distinct field numbers in one run (max %1)', 1048575);
        FieldNoIndex.Add(FieldNo, Slot);
        exit(Slot);
    end;

    procedure FieldRefRecHandle(FH: Integer): Integer
    begin
        exit(FH mod FieldRefStride());
    end;

    procedure FieldRefFieldNo(FH: Integer): Integer
    begin
        AssertFieldRefBound(FH);
        exit(FieldNoPool.Get(FH div FieldRefStride()));
    end;

    // The KeyRef half: Slot is the key index itself, no pool.
    procedure KeyRefIndex(KH: Integer): Integer
    begin
        AssertKeyRefBound(KH);
        exit(KH div FieldRefStride());
    end;

    // ALI937 is deliberately REUSED from "this RecordRef is not open" rather than given a new
    // code: the ALI9xx space is fully allocated (901-999), and this is literally the same
    // condition one level down — a reference variable used before anything bound it. The message
    // names which of the two it was, which is what a reader actually needs.
    procedure AssertFieldRefBound(FH: Integer)
    begin
        if FH = 0 then
            Error('ALI937: this FieldRef is not bound — obtain it from RecordRef.Field(...)/FieldIndex(...) or KeyRef.FieldIndex(...) first');
        AssertRefOpen(FH mod FieldRefStride());
    end;

    procedure AssertKeyRefBound(KH: Integer)
    begin
        if KH = 0 then
            Error('ALI937: this KeyRef is not bound — obtain it from RecordRef.KeyIndex(...) first');
        AssertRefOpen(KH mod FieldRefStride());
    end;

    // The one materializer. EVERY FieldRef operation goes through it, so the "never store a
    // native FieldRef" rule has exactly one place to be broken and is easy to keep.
    local procedure FRefOf(FH: Integer): FieldRef
    begin
        AssertFieldRefBound(FH);
        exit(RecRefs[FH mod FieldRefStride()].Field(FieldNoPool.Get(FH div FieldRefStride())));
    end;

    local procedure KRefOf(KH: Integer): KeyRef
    begin
        AssertKeyRefBound(KH);
        exit(RecRefs[KH mod FieldRefStride()].KeyIndex(KH div FieldRefStride()));
    end;

    // ----- constructors (REF_METHOD ids 15/16/17 and FLD_METHOD id 42) -----

    procedure MakeFieldRef(H: Integer; FieldNo: Integer): Integer
    begin
        AssertRefOpen(H);
        if not RecRefs[H].FieldExist(FieldNo) then
            Error('ALI939: table %1 has no field %2', RecRefs[H].Name(), FieldNo);
        exit(InternFieldNo(FieldNo) * FieldRefStride() + H);
    end;

    // Field(Text) is an ALI EXTENSION (native RecordRef.Field takes a number only), the same
    // convenience Open(Text) already adds: resolve the name against the live table metadata.
    procedure MakeFieldRefByName(H: Integer; FieldName: Text): Integer
    var
        FRef: FieldRef;
        i: Integer;
    begin
        AssertRefOpen(H);
        for i := 1 to RecRefs[H].FieldCount() do begin
            FRef := RecRefs[H].FieldIndex(i);
            if UpperCase(FRef.Name()) = UpperCase(FieldName) then
                exit(InternFieldNo(FRef.Number()) * FieldRefStride() + H);
        end;
        Error('ALI939: table %1 has no field named ''%2''', RecRefs[H].Name(), FieldName);
    end;

    // FieldIndex(i) — the i-th field in field-number order, NOT the field numbered i.
    procedure MakeFieldRefByIndex(H: Integer; Idx: Integer): Integer
    begin
        AssertRefOpen(H);
        if (Idx < 1) or (Idx > RecRefs[H].FieldCount()) then
            Error('ALI939: field index %1 is out of range (table %2 has %3 fields)', Idx, RecRefs[H].Name(), RecRefs[H].FieldCount());
        exit(InternFieldNo(RecRefs[H].FieldIndex(Idx).Number()) * FieldRefStride() + H);
    end;

    procedure MakeKeyRef(H: Integer; KeyIdx: Integer): Integer
    begin
        AssertRefOpen(H);
        if (KeyIdx < 1) or (KeyIdx > RecRefs[H].KeyCount()) then
            Error('ALI939: key index %1 is out of range (table %2 has %3 keys)', KeyIdx, RecRefs[H].Name(), RecRefs[H].KeyCount());
        exit(KeyIdx * FieldRefStride() + H);
    end;

    // The i-th field OF A KEY -> a FieldRef on the same record handle.
    procedure KeyRefFieldRef(KH: Integer; Idx: Integer): Integer
    var
        KRef: KeyRef;
    begin
        KRef := KRefOf(KH);
        if (Idx < 1) or (Idx > KRef.FieldCount()) then
            Error('ALI939: key field index %1 is out of range (the key has %2 fields)', Idx, KRef.FieldCount());
        exit(InternFieldNo(KRef.FieldIndex(Idx).Number()) * FieldRefStride() + (KH mod FieldRefStride()));
    end;

    procedure KeyRefActive(KH: Integer): Boolean
    begin
        exit(KRefOf(KH).Active());
    end;

    procedure KeyRefFieldCount(KH: Integer): Integer
    begin
        exit(KRefOf(KH).FieldCount());
    end;

    // ----- value get/set -----
    //
    // Blob/Media/MediaSet through a FieldRef: refused, with the SAME ALI997 reasoning the media
    // write side already carries in the binder — a FieldRef yields the raw blob/media id, never
    // a usable Blob or writable Media object, so letting Value through would hand the script
    // something that silently is not what it looks like. The check is at RUN time (unlike the
    // binder's) for the obvious reason: a FieldRef's field number is only known then.

    local procedure GuardValueType(var FRef: FieldRef)
    var
        TypeNm: Text;
    begin
        TypeNm := UpperCase(Format(FRef.Type()));
        if (TypeNm = 'BLOB') or (TypeNm = 'MEDIA') or (TypeNm = 'MEDIASET') then
            Error('ALI997: FieldRef.Value is not supported on the %1 field ''%2'': the interpreter reaches table fields through a FieldRef, which yields the raw id but never a usable Blob/Media object. Use Rec.<field>.CreateInStream / .MediaId through a Record variable', Format(FRef.Type()), FRef.Name());
    end;

    procedure FieldRefGetValue(FH: Integer): Variant
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        GuardValueType(FRef);
        exit(FRef.Value());
    end;

    procedure FieldRefSetValue(FH: Integer; Value: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        GuardValueType(FRef);
        FRef.Value(Value);
    end;

    procedure FieldRefValidate(FH: Integer; Value: Variant; HasValue: Boolean)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        GuardValueType(FRef);
        if HasValue then
            FRef.Validate(Value)
        else
            FRef.Validate();
    end;

    // ----- filters -----

    procedure FieldRefSetRange(FH: Integer; ArgCount: Integer; LoVal: Variant; HiVal: Variant)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        case ArgCount of
            0:
                FRef.SetRange();
            1:
                FRef.SetRange(LoVal);
            else
                FRef.SetRange(LoVal, HiVal);
        end;
    end;

    // SetFilter(Text [, up to 14 substitution args]) — the same 0..14 ladder SetFilterField
    // above uses, for the same reason (AL has no way to splat a variadic arg list).
    procedure FieldRefSetFilter(FH: Integer; FilterText: Text; ArgCount: Integer; A: array[14] of Variant)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        case ArgCount of
            0:
                FRef.SetFilter(FilterText);
            1:
                FRef.SetFilter(FilterText, A[1]);
            2:
                FRef.SetFilter(FilterText, A[1], A[2]);
            3:
                FRef.SetFilter(FilterText, A[1], A[2], A[3]);
            4:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4]);
            5:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5]);
            6:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6]);
            7:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7]);
            8:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8]);
            9:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9]);
            10:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10]);
            11:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11]);
            12:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12]);
            13:
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12], A[13]);
            else
                FRef.SetFilter(FilterText, A[1], A[2], A[3], A[4], A[5], A[6], A[7], A[8], A[9], A[10], A[11], A[12], A[13], A[14]);
        end;
    end;

    procedure FieldRefGetFilter(FH: Integer): Text
    begin
        exit(FRefOf(FH).GetFilter());
    end;

    procedure FieldRefGetRangeMin(FH: Integer): Variant
    begin
        exit(FRefOf(FH).GetRangeMin());
    end;

    procedure FieldRefGetRangeMax(FH: Integer): Variant
    begin
        exit(FRefOf(FH).GetRangeMax());
    end;

    procedure FieldRefCalcField(FH: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        FRef.CalcField();
    end;

    procedure FieldRefCalcSum(FH: Integer)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        if Secured[FH mod FieldRefStride()] then
            ApplySecurity(RecRefs[FH mod FieldRefStride()]);
        FRef.CalcSum();
    end;

    // TestField() / TestField(value) — ONE Variant-argument entry point rather than the ~30
    // typed overloads native AL declares. The register file the argument came from is gone by
    // the time we are here anyway (the operand pool boxes it), so a typed ladder would buy
    // nothing but 30 near-identical bodies.
    procedure FieldRefTestField(FH: Integer; Value: Variant; HasValue: Boolean)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        if HasValue then
            FRef.TestField(Value)
        else
            FRef.TestField();
    end;

    procedure FieldRefFieldError(FH: Integer; Msg: Text; HasMsg: Boolean)
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        if HasMsg then
            FRef.FieldError(Msg)
        else
            FRef.FieldError();
    end;

    // ----- metadata -----
    //
    // One entry point per RESULT CLASS instead of one per method: the interpreter's dispatch
    // already carries the method id, and three small case blocks here keep ~18 one-line
    // procedures out of both files.

    procedure FieldRefTextInfo(FH: Integer; Which: Integer; Arg: Integer): Text
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        case Which of
            13:
                exit(FRef.Name());
            15:
                exit(FRef.Caption());
            21:
                exit(FRef.OptionCaption());
            22:
                exit(FRef.OptionMembers());
            25:
                exit(FRef.GetEnumValueName(Arg));
            26:
                exit(FRef.GetEnumValueCaption(Arg));
            28:
                exit(FRef.GetEnumValueNameFromOrdinalValue(Arg));
            29:
                exit(FRef.GetEnumValueCaptionFromOrdinalValue(Arg));
        end;
    end;

    procedure FieldRefIntInfo(FH: Integer; Which: Integer; Arg: Integer): Integer
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        case Which of
            14:
                exit(FRef.Number());
            16:
                exit(FRef.Length());
            17:
                // Class()/Type() return native option types whose ORDINALS ALI cannot reuse:
                // FieldType's are non-contiguous platform numbers (Text = 31488, RecordID =
                // 4988…), and ALI's option sets are index-ordered name lists. So both are mapped
                // by NAME into ALI's own FieldClass/FieldType sets — self-consistent inside the
                // interpreter (`F.Type() = FieldType::Text` works), and never leaking a platform
                // ordinal a script could not have written down anyway.
                exit(FieldClassOrdinal(Format(FRef.Class())));
            18:
                exit(FieldTypeOrdinal(Format(FRef.Type())));
            20:
                exit(FRef.Relation());
            24:
                exit(FRef.EnumValueCount());
            27:
                exit(FRef.GetEnumValueOrdinal(Arg));
        end;
    end;

    procedure FieldRefBoolInfo(FH: Integer; Which: Integer): Boolean
    var
        FRef: FieldRef;
    begin
        FRef := FRefOf(FH);
        case Which of
            19:
                exit(FRef.Active());
            23:
                exit(FRef.IsEnum());
            30:
                exit(FRef.IsOptimizedForTextSearch());
        end;
    end;

    // Name -> ALI ordinal for the two built-in system option sets Class()/Type() live in. The
    // name lists are the single source of truth and are shared with "ALI Binder".
    // TrySystemOptionSet through "ALI Option Meta" — keep the three in step.
    local procedure FieldClassOrdinal(Nm: Text): Integer
    var
        OptMeta: Codeunit "ALI Option Meta";
    begin
        exit(NameOrdinal(OptMeta.FieldClassNames(), Nm));
    end;

    local procedure FieldTypeOrdinal(Nm: Text): Integer
    var
        OptMeta: Codeunit "ALI Option Meta";
    begin
        exit(NameOrdinal(OptMeta.FieldTypeNames(), Nm));
    end;

    local procedure NameOrdinal(Names: List of [Text]; Nm: Text): Integer
    var
        i: Integer;
    begin
        for i := 1 to Names.Count() do
            if UpperCase(Names.Get(i)) = UpperCase(Nm) then
                exit(i - 1);
        exit(-1);       // a platform member ALI's list does not know — truthfully "no ordinal"
    end;

    // ===== Guards =====

    local procedure GuardHandle(H: Integer)
    begin
        if (H < 1) or (H > MaxRecordHandles()) then
            Error('ALI955: record handle %1 out of range', H);
    end;

    local procedure GuardOpen(H: Integer)
    begin
        GuardHandle(H);
        if not RecOpen[H] then
            Error('ALI956: record variable used before it was opened (handle %1)', H);
    end;
}
