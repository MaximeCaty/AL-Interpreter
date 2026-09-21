// ALI Symbol Table — struct-of-arrays symbol store + parent-pointer scopes (§6.1).
//
// Symbol columns (parallel, 1-based SymbolId):
//   KindOrd    "ALI Symbol Kind" ordinal (GlobalVar/LocalVar/Param/VarParam/Proc/...)
//   NameId     interned identifier pool index (integer compare, never string, §4.1)
//   TypeOrd    "ALI TypeKind" ordinal
//   TypeArg    length (Text[n]/Code[n]) | table id (record) | option-set id | array elem type
//   SlotIndex  register assignment (§7.2) — filled by the binder
//   ScopeId    the scope this symbol was declared in
//   ProcId     owning procedure (0 = module scope)
//   Flags      bit0 = temporary, bit1 = var-param (redundant w/ Kind, kept for fast check),
//              bit2 = array
//
// Scopes: a simple parent-pointer list (1-based ScopeId). Each scope keeps a
// Dictionary of [Integer, Integer] mapping NameId -> SymbolId. Because AL cannot hold a
// Dictionary inside a List element, the per-scope maps live in a fixed bank of member
// Dictionaries addressed by ScopeId. Lookup walks: current scope -> ... -> module -> (the
// binder then falls back to builtins itself). ScopeId 1 is always the module scope.
//
// Lookups key on the interned NameId (integer). Resolution is O(scope-depth) dictionary
// probes; identifiers are compared by id, never by string (§6.1).
codeunit 51122 "ALI Symbol Table"
{
    Access = Public;
    SingleInstance = false;

    var

        // --- Collection element length side-table, keyed by List/Dictionary SymbolId. TArg
        // collapses a Text[n]/Code[n] element to its register CLASS (width is lost there), so
        // the declared length can't ride in TArg. Stores the STORE_TEXT_CHK operand for the
        // element (List) or value (Dictionary): Length*2 + IsCode, 0 = no length check. Lets
        // the lowerer length-check/upper-case values entering a `List of [Text[n]]` etc. ---
        ElemChk: Dictionary of [Integer, Integer];
        GlobalCounts: Dictionary of [Integer, Integer];     // RegClass -> module-level (global) slot count
        InstBaseMap: Dictionary of [Integer, Integer];      // inst*16 + regClass -> absolute base
        InstIdxBySid: Dictionary of [Integer, Integer];

        // --- M11 phase B2: per-VARIABLE object globals ---------------------------------------
        //
        // A harvested object's globals used to be one shared block per object (SingleInstance
        // semantics, announced as ALI923). They are now one block per declared VARIABLE of that
        // object's type — an INSTANCE. Three side tables carry it:
        //
        //   OwnerObjKeyBySid  a GlobalVar sid -> the object that declared it (0 = the script's
        //                     own global, which keeps its ordinary absolute slot). For an object
        //                     global SlotIndex holds an OFFSET WITHIN ITS OBJECT'S BLOCK, not an
        //                     absolute slot — the lowerer emits SELF_LOAD/SELF_STORE for those.
        //   InstIdxBySid      a Record/CodeunitRef variable sid -> its 1-based instance index.
        //                     0 means "no instance of its own": the implicit `Rec` of a harvested
        //                     procedure, which FORWARDS the caller's instance instead.
        //   InstOwnerList     instance index -> the ObjKey whose block that instance holds.
        //
        // InstBaseMap is the layout the binder computes once every declaration is in (see
        // "ALI Binder".AllocateGlobalSlots): absolute base of instance i's block for register
        // class c, so an object global's absolute slot = base + its offset. The interpreter is
        // handed the same table and resolves SELF_* against the frame's current instance.
        OwnerObjKeyBySid: Dictionary of [Integer, Integer];
        ParamCountByProc: Dictionary of [Integer, Integer]; // PId -> param count
        // Per-proc param span into the columns above. Params are registered contiguously per
        // ProcId (pass-1 declares all of a proc's params before the next proc), so a first-row
        // + count index makes ProcParamCount/ProcParamRow O(1) instead of scanning every row.
        ParamFirstRow: Dictionary of [Integer, Integer];    // PId -> 1-based first param row
        ProcRecvRowMap: Dictionary of [Integer, Integer];   // PId -> descriptor row of the implicit Rec
        ProcResultSlots: Dictionary of [Integer, Integer];  // PId -> frame-relative result slot (0 = none)

        // --- Hidden parameter rows of a harvested object's procedure (M11 phase B2). Descriptor
        // row 1 is the instance index when the object declares globals; the implicit `Rec`
        // receiver follows it. Both are 0 for an ordinary script procedure, which is what makes
        // every call site read its RowShift from here instead of assuming one. ---
        ProcSelfRowMap: Dictionary of [Integer, Integer];   // PId -> descriptor row of the instance index

        // --- [TryFunction] procedures, keyed by PId (presence = try). Keyed by proc id, not by
        // symbol, because the lowerer's LowerCall decides CALL vs TRY_CALL from the PId. ---
        TryProcSet: Dictionary of [Integer, Boolean];

        // --- M5 per-proc / module register bookkeeping (binder -> lowerer contract) ---
        ProcVarCounts: Dictionary of [Integer, Integer];    // key = PId*16 + RegClass -> binder var-region size

        // --- Per-scope NameId -> SymbolId maps, keyed by ScopeId ---
        // AL cannot nest a Dictionary in a List, so we hold ONE flat map keyed on a packed
        // (ScopeId, NameId) integer. Packing: ScopeId * ScopeStride + NameId. ScopeStride is
        // larger than any NameId we expect (interned pool indices) — see ScopeStride().
        ScopeNameMap: Dictionary of [Integer, Integer];

        // --- §20.4 multidim array dimension side-table, keyed by array SymbolId. TArg keeps
        // ElemTypeOrd*ArrayStride+TotalN (unchanged); per-dimension sizes live here since a
        // single Integer TArg cannot hold up to 10 dimension sizes. ---
        ArrayDims: Dictionary of [Integer, List of [Integer]];

        // --- Procedure overload chains (AL0198 relaxation): packed (Scope,Name) key ->
        // every proc SymbolId sharing that name, in declaration order. ScopeNameMap keeps
        // only the FIRST overload (generic Lookup still works); call sites consult this
        // list to pick the overload matching the argument list. ---
        ProcOverloadMap: Dictionary of [Integer, List of [Integer]];

        // --- Per-owner symbol indexes. Both are maintained by Declare, so both are in ASCENDING
        // SymbolId order — i.e. declaration order, which the slot allocators depend on (a proc's
        // params must be numbered in the order they were declared).
        //
        // Why they exist: AllocateProcSlots (binder, twice) and BuildProcSids (lowerer) used to
        // find a procedure's own symbols by scanning the WHOLE table, once per procedure. That is
        // fine for a script with 20 symbols and invisible in every test. Under M11 whole-object
        // harvesting the shared table reaches several thousand symbols across hundreds of
        // harvested procedures, and procs x symbols turned a one-call script into a 25-second
        // compile. Same output, without the quadratic. ---
        SidsByProc: Dictionary of [Integer, List of [Integer]];  // PId -> its Param/VarParam/LocalVar sids

        // --- Label constant text side-table, keyed by Label SymbolId. A Label is a compile-
        // time text constant (§19.2): the lowerer folds every read to a LOAD_CONST_T of this
        // text — no register slot is ever read/written at runtime. ---
        LabelText: Dictionary of [Integer, Text];

        // --- M11 cross-unit procedure lookup, keyed "<scope>|<UPPERNAME>" -> first SymbolId.
        // Identifiers are interned PER "ALI Token Table" (§4.1), so a NameId from one
        // compilation unit is meaningless in another: a script asking for a harvested object's
        // procedure has no way to spell it as a NameId that unit would recognise. This index is
        // the bridge, and it is only ever consulted for cross-unit resolution — in-unit lookup
        // stays on the integer ScopeNameMap path. Overloads: this holds the FIRST symbol, same
        // as ScopeNameMap; take its GetNameId() and go through ProcOverloads for the chain. ---
        ProcNameIndex: Dictionary of [Text, Integer];
        CurScope: Integer;                  // currently open scope
        Flags: List of [Integer];
        GlobalSidList: List of [Integer];                        // every GlobalVar sid
        InstOwnerList: List of [Integer];
        // --- Symbol columns (1-based) ---
        KindOrd: List of [Integer];
        NameId: List of [Integer];
        ParamIsVar: List of [Integer];      // 1 = var-param (exact type, no implicit conv)

        // --- Proc parameter descriptors (parallel, keyed by ProcId), see below ---
        ParamProcId: List of [Integer];
        ParamSlot: List of [Integer];       // callee frame-relative register slot (M5, §7.2)
        ParamType: List of [Integer];
        ParamTypeArg: List of [Integer];
        ProcId: List of [Integer];
        ScopeId: List of [Integer];

        // --- Scope tree (parent-pointer) ---
        ScopeParent: List of [Integer];     // ScopeParent[s] = parent ScopeId (0 = root/module)
        SlotIndex: List of [Integer];
        TypeArg: List of [Integer];
        TypeOrd: List of [Integer];

    // Flag bit constants (§3.3 — AL has no constants).
    procedure FlagTemporary(): Integer
    begin
        exit(1);
    end;

    procedure FlagVarParam(): Integer
    begin
        exit(2);
    end;

    procedure FlagArray(): Integer
    begin
        exit(4);
    end;

    // Packing stride for the (scope,name) map key. Must exceed the max interned NameId.
    // The intern pool is bounded by source size; 1,000,000 is comfortably large for v1
    // scripts and keeps keys inside Int32.
    local procedure ScopeStride(): Integer
    begin
        exit(1000000);
    end;

    // ===== Symbol Kind ordinals (mirror "ALI Symbol Kind") =====
    procedure KindGlobalVar(): Integer
    begin
        exit(1);
    end;

    procedure KindLocalVar(): Integer
    begin
        exit(2);
    end;

    procedure KindParam(): Integer
    begin
        exit(3);
    end;

    procedure KindVarParam(): Integer
    begin
        exit(4);
    end;

    procedure KindProc(): Integer
    begin
        exit(5);
    end;

    procedure KindRecordVar(): Integer
    begin
        exit(6);
    end;

    procedure KindOptionMember(): Integer
    begin
        exit(7);
    end;

    procedure KindBuiltinProc(): Integer
    begin
        exit(8);
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        ClearAll();
        // Open the always-present module scope (ScopeId 1, parent 0).
        PushScope(0);
    end;

    // ===== Scope management =====

    // Open a new child scope of `Parent` (0 = root). Returns the new ScopeId and makes it
    // current. The module scope is opened by Reset(); procedure scopes push over it.
    procedure PushScope(Parent: Integer): Integer
    begin
        ScopeParent.Add(Parent);
        CurScope := ScopeParent.Count();
        exit(CurScope);
    end;

    // Open a child of the CURRENT scope (the common case: proc scope over module scope).
    procedure PushChildScope(): Integer
    begin
        exit(PushScope(CurScope));
    end;

    // Pop back to the parent of the current scope. Symbols already declared remain in the
    // columns (never removed — SymbolIds are stable handles) but become unreachable via
    // Lookup once their scope is closed.
    procedure PopScope()
    begin
        if CurScope > 0 then
            CurScope := ScopeParent.Get(CurScope);
    end;

    procedure CurrentScope(): Integer
    begin
        exit(CurScope);
    end;

    // Make an existing scope current. Used when binding a HARVESTED object unit (M11): its
    // declarations belong to that object's own scope, whose parent is the root (0), not the
    // script's module scope — the two must not see each other's names.
    procedure SetCurrentScope(S: Integer)
    begin
        CurScope := S;
    end;

    procedure ModuleScope(): Integer
    begin
        exit(1);        // opened first by Reset()
    end;

    // ===== Declaration =====

    // Declare a symbol in the CURRENT scope. Returns the new SymbolId, or 0 if a symbol of
    // the same NameId already exists in THIS scope (duplicate — caller emits the diagnostic;
    // we do not overwrite so the first declaration wins, matching native).
    procedure Declare(Kind: Integer; Name: Integer; TypeK: Integer; TArg: Integer; PId: Integer; SymFlags: Integer): Integer
    var
        KeyI: Integer;
        Sid: Integer;
    begin
        KeyI := CurScope * ScopeStride() + Name;
        if ScopeNameMap.ContainsKey(KeyI) then
            exit(0);                    // duplicate in same scope

        KindOrd.Add(Kind);
        NameId.Add(Name);
        TypeOrd.Add(TypeK);
        TypeArg.Add(TArg);
        SlotIndex.Add(0);
        ScopeId.Add(CurScope);
        ProcId.Add(PId);
        Flags.Add(SymFlags);
        Sid := KindOrd.Count();

        ScopeNameMap.Set(KeyI, Sid);
        IndexSymbol(Sid, Kind, PId);
        exit(Sid);
    end;

    // Maintain the per-owner indexes (see SidsByProc / GlobalSidList). Proc symbols are not
    // indexed — nothing iterates them by owner.
    local procedure IndexSymbol(Sid: Integer; Kind: Integer; PId: Integer)
    var
        Sids: List of [Integer];
    begin
        if Kind = "ALI Symbol Kind"::GlobalVar then begin
            GlobalSidList.Add(Sid);
            exit;
        end;
        if PId = 0 then
            exit;
        if (Kind <> "ALI Symbol Kind"::LocalVar) and (Kind <> "ALI Symbol Kind"::Param) and (Kind <> "ALI Symbol Kind"::VarParam) then
            exit;
        if not SidsByProc.Get(PId, Sids) then
            Clear(Sids);
        Sids.Add(Sid);
        SidsByProc.Set(PId, Sids);
    end;

    // Every Param/VarParam/LocalVar symbol owned by PId, in declaration order. Empty when the
    // proc declared none.
    procedure ProcSymbols(PId: Integer) Sids: List of [Integer]
    begin
        if SidsByProc.Get(PId, Sids) then
            exit(Sids);
        Clear(Sids);
    end;

    // Every module-scope GlobalVar symbol, in declaration order.
    procedure GlobalSids(): List of [Integer]
    begin
        exit(GlobalSidList);
    end;

    // Declare in an EXPLICIT scope (used for two-pass: proc signatures declared in the
    // module scope during pass 1 while other scopes may be current). Restores CurScope.
    procedure DeclareInScope(Scope: Integer; Kind: Integer; Name: Integer; TypeK: Integer; TArg: Integer; PId: Integer; SymFlags: Integer): Integer
    var
        Saved: Integer;
        Sid: Integer;
    begin
        Saved := CurScope;
        CurScope := Scope;
        Sid := Declare(Kind, Name, TypeK, TArg, PId, SymFlags);
        CurScope := Saved;
        exit(Sid);
    end;

    // Declare a PROC symbol in an explicit scope, allowing overloads: if the name is
    // already bound to another proc, a fresh symbol row is appended WITHOUT touching
    // ScopeNameMap (the first overload stays the generic Lookup result) and chained into
    // ProcOverloadMap. Returns 0 only when the name clashes with a NON-proc symbol.
    // Duplicate-SIGNATURE detection is the binder's job (it owns the param descriptors).
    procedure DeclareProcInScope(Scope: Integer; Name: Integer; TypeK: Integer; TArg: Integer; PId: Integer): Integer
    var
        ExistingSid: Integer;
        KeyI: Integer;
        Sid: Integer;
        Chain: List of [Integer];
    begin
        KeyI := Scope * ScopeStride() + Name;
        if ScopeNameMap.Get(KeyI, ExistingSid) then begin
            if KindOrd.Get(ExistingSid) <> KindProc() then
                exit(0);            // name taken by a variable/etc. — genuine duplicate
            // Overload: append a symbol row outside the name map.
            KindOrd.Add(KindProc());
            NameId.Add(Name);
            TypeOrd.Add(TypeK);
            TypeArg.Add(TArg);
            SlotIndex.Add(0);
            ScopeId.Add(Scope);
            ProcId.Add(PId);
            Flags.Add(0);
            Sid := KindOrd.Count();
        end else
            Sid := DeclareInScope(Scope, KindProc(), Name, TypeK, TArg, PId, 0);

        if not ProcOverloadMap.Get(KeyI, Chain) then
            Clear(Chain);
        Chain.Add(Sid);
        ProcOverloadMap.Set(KeyI, Chain);
        exit(Sid);
    end;

    // Every proc SymbolId declared under this (Scope, Name), declaration order.
    // Empty list when the name is unknown or not a proc.
    // Record a procedure symbol under its NAME TEXT so another compilation unit can find it
    // (see ProcNameIndex). Called once per declared procedure, right after DeclareProcInScope.
    procedure RegisterProcName(Scope: Integer; NameText: Text; Sid: Integer)
    var
        KeyT: Text;
    begin
        KeyT := ProcNameKey(Scope, NameText);
        if not ProcNameIndex.ContainsKey(KeyT) then
            ProcNameIndex.Set(KeyT, Sid);
    end;

    // First procedure symbol named NameText in Scope (exact scope, no parent walk), 0 if none.
    procedure LookupProcByName(Scope: Integer; NameText: Text): Integer
    var
        Sid: Integer;
    begin
        if ProcNameIndex.Get(ProcNameKey(Scope, NameText), Sid) then
            exit(Sid);
        exit(0);
    end;

    local procedure ProcNameKey(Scope: Integer; NameText: Text): Text
    begin
        exit(Format(Scope) + '|' + UpperCase(NameText));
    end;

    procedure ProcOverloads(Scope: Integer; Name: Integer): List of [Integer]
    var
        Chain: List of [Integer];
    begin
        if ProcOverloadMap.Get(Scope * ScopeStride() + Name, Chain) then
            exit(Chain);
        exit(Chain);    // empty
    end;

    // ===== Lookup =====

    // Resolve NameId starting from the CURRENT scope and walking parent pointers to the
    // module scope. Returns the SymbolId, or 0 if not found in any enclosing scope. The
    // binder then falls back to the builtin registry itself (§6.1). Shadowing falls out:
    // the innermost matching scope wins.
    procedure Lookup(Name: Integer): Integer
    begin
        exit(LookupFrom(CurScope, Name));
    end;

    // Resolve NameId starting from an explicit scope (walks parents).
    procedure LookupFrom(Scope: Integer; Name: Integer): Integer
    var
        KeyI: Integer;
        S: Integer;
        Sid: Integer;
    begin
        S := Scope;
        while S > 0 do begin
            KeyI := S * ScopeStride() + Name;
            if ScopeNameMap.Get(KeyI, Sid) then
                exit(Sid);
            S := ScopeParent.Get(S);
        end;
        exit(0);
    end;

    // Resolve NameId in a SINGLE scope only (no parent walk) — used for duplicate checks
    // and for member resolution inside a specific scope.
    procedure LookupInScope(Scope: Integer; Name: Integer): Integer
    var
        KeyI: Integer;
        Sid: Integer;
    begin
        KeyI := Scope * ScopeStride() + Name;
        if ScopeNameMap.Get(KeyI, Sid) then
            exit(Sid);
        exit(0);
    end;

    // ===== Symbol getters (1-based SymbolId) =====

    procedure Count(): Integer
    begin
        exit(KindOrd.Count());
    end;

    procedure GetKind(Sid: Integer): Integer
    begin
        exit(KindOrd.Get(Sid));
    end;

    procedure GetNameId(Sid: Integer): Integer
    begin
        exit(NameId.Get(Sid));
    end;

    procedure GetType(Sid: Integer): Integer
    begin
        exit(TypeOrd.Get(Sid));
    end;

    procedure GetTypeArg(Sid: Integer): Integer
    begin
        exit(TypeArg.Get(Sid));
    end;

    procedure GetSlot(Sid: Integer): Integer
    begin
        exit(SlotIndex.Get(Sid));
    end;

    procedure SetSlot(Sid: Integer; Slot: Integer)
    begin
        SlotIndex.Set(Sid, Slot);
    end;

    procedure GetScope(Sid: Integer): Integer
    begin
        exit(ScopeId.Get(Sid));
    end;

    procedure GetProcId(Sid: Integer): Integer
    begin
        exit(ProcId.Get(Sid));
    end;

    procedure GetFlags(Sid: Integer): Integer
    begin
        exit(Flags.Get(Sid));
    end;

    procedure HasFlag(Sid: Integer; Bit: Integer): Boolean
    begin
        // Bit must be a power of two; AL has no bitwise integer ops.
        exit((Flags.Get(Sid) div Bit) mod 2 = 1);
    end;

    // A symbol is an lvalue (assignable / var-param-passable) when it is a variable/param.
    // Procedures and option-members are not lvalues.
    procedure IsVariableKind(Sid: Integer): Boolean
    var
        K: Integer;
    begin
        // AL 'or' does not short-circuit: callers cannot pre-guard Sid in a compound
        // condition, so an out-of-range Sid (e.g. 0 for a literal argument) lands here.
        if (Sid <= 0) or (Sid > KindOrd.Count()) then
            exit(false);
        K := KindOrd.Get(Sid);
        exit((K = KindGlobalVar()) or (K = KindLocalVar()) or (K = KindParam()) or
             (K = KindVarParam()) or (K = KindRecordVar()));
    end;

    // ===== Proc metadata (return type + param descriptors) =====
    //
    // Procedures live in the symbol columns (KindProc). Their return type is stored in
    // TypeOrd/TypeArg of the proc symbol. Parameter descriptors are a separate parallel
    // store keyed by ProcId so the binder can validate call sites without re-walking the
    // AST: each param row is (ProcId, TypeOrd, TypeArg, IsVar). Columns are declared in the
    // single global var block above (AL codeunits permit only one var section).

    // Register a parameter descriptor for a proc (pass-1). Order = declaration order.
    procedure AddProcParam(PId: Integer; PType: Integer; PTypeArg: Integer; IsVar: Boolean)
    var
        Cnt: Integer;
    begin
        // Dictionary.Get(Key, var) THROWS on an absent key — it must be consumed as a Boolean
        // (matches GetProcVarCount's `if ...Get(...) then`). A false result = this proc's FIRST
        // param, so record its 1-based first row (the next column index) here. Relies on
        // contiguous per-proc registration (see ParamFirstRow declaration).
        if not ParamCountByProc.Get(PId, Cnt) then begin
            ParamFirstRow.Set(PId, ParamProcId.Count() + 1);
            Cnt := 0;
        end;
        ParamProcId.Add(PId);
        ParamType.Add(PType);
        ParamTypeArg.Add(PTypeArg);
        if IsVar then
            ParamIsVar.Add(1)
        else
            ParamIsVar.Add(0);
        ParamSlot.Add(0);       // filled by the binder during slot allocation (pass 2)
        ParamCountByProc.Set(PId, Cnt + 1);
    end;

    // Number of parameters registered for a proc.
    procedure ProcParamCount(PId: Integer): Integer
    var
        N: Integer;
    begin
        if ParamCountByProc.Get(PId, N) then
            exit(N);
        exit(0);
    end;

    // The i-th (1-based) parameter descriptor row index for a proc, or 0 if out of range.
    procedure ProcParamRow(PId: Integer; Idx: Integer): Integer
    var
        First: Integer;
    begin
        if (Idx < 1) or (Idx > ProcParamCount(PId)) then
            exit(0);
        // Consume the Boolean (Get throws on absent key); a proc with Idx in range always has a
        // ParamFirstRow entry, so the else is defensive only.
        if ParamFirstRow.Get(PId, First) then
            exit(First + Idx - 1);
        exit(0);
    end;

    procedure ParamRowType(Row: Integer): Integer
    begin
        exit(ParamType.Get(Row));
    end;

    procedure ParamRowTypeArg(Row: Integer): Integer
    begin
        exit(ParamTypeArg.Get(Row));
    end;

    procedure ParamRowIsVar(Row: Integer): Boolean
    begin
        exit(ParamIsVar.Get(Row) = 1);
    end;

    procedure SetParamRowSlot(Row: Integer; Slot: Integer)
    begin
        ParamSlot.Set(Row, Slot);
    end;

    procedure ParamRowSlot(Row: Integer): Integer
    begin
        exit(ParamSlot.Get(Row));
    end;

    // ===== M5 register bookkeeping (binder writes, lowerer reads §7.2) =====
    // Per-proc VAR-region size per register class (params + result + locals + hidden
    // for-limit slots — everything the binder allocated; temps sit above, lowerer-owned).

    procedure SetProcVarCount(PId: Integer; RegClass: Integer; N: Integer)
    begin
        ProcVarCounts.Set(PId * 16 + RegClass, N);
    end;

    procedure GetProcVarCount(PId: Integer; RegClass: Integer): Integer
    var
        N: Integer;
    begin
        if ProcVarCounts.Get(PId * 16 + RegClass, N) then
            exit(N);
        exit(0);
    end;

    procedure SetProcResultSlot(PId: Integer; Slot: Integer)
    begin
        ProcResultSlots.Set(PId, Slot);
    end;

    procedure GetProcResultSlot(PId: Integer): Integer
    var
        S: Integer;
    begin
        if ProcResultSlots.Get(PId, S) then
            exit(S);
        exit(0);
    end;

    // Module-level (global) variables live in ABSOLUTE slots 1..GlobalCount below every
    // frame window; the entry frame's per-class base = GlobalCount (M5, §7.1).

    procedure SetGlobalCount(RegClass: Integer; N: Integer)
    begin
        GlobalCounts.Set(RegClass, N);
    end;

    procedure GetGlobalCount(RegClass: Integer): Integer
    var
        N: Integer;
    begin
        if GlobalCounts.Get(RegClass, N) then
            exit(N);
        exit(0);
    end;

    // ===== M11 phase B2: object ownership, instances, block layout =====

    // Tag a GlobalVar as belonging to a harvested object (ObjKey = "ALI Object Registry"'s
    // KeyOfObject). Only the binder calls this, while binding that object's unit.
    procedure SetOwnerObjKey(Sid: Integer; ObjKey: Integer)
    begin
        OwnerObjKeyBySid.Set(Sid, ObjKey);
    end;

    // 0 = a script global (ordinary absolute slot); non-zero = an object global whose SlotIndex
    // is an offset inside that object's per-instance block.
    procedure GetOwnerObjKey(Sid: Integer): Integer
    var
        K: Integer;
    begin
        if OwnerObjKeyBySid.Get(Sid, K) then
            exit(K);
        exit(0);
    end;

    // Reserve a globals block for one declared variable of the object ObjKey. Returns the
    // 1-based instance index; indices are handed out in declaration order over the SHARED table,
    // so they stay stable while later harvests append more.
    procedure NewInstance(ObjKey: Integer): Integer
    begin
        InstOwnerList.Add(ObjKey);
        exit(InstOwnerList.Count());
    end;

    procedure InstanceCount(): Integer
    begin
        exit(InstOwnerList.Count());
    end;

    procedure InstanceOwner(Inst: Integer): Integer
    begin
        if (Inst < 1) or (Inst > InstOwnerList.Count()) then
            exit(0);
        exit(InstOwnerList.Get(Inst));
    end;

    procedure SetInstIdx(Sid: Integer; Inst: Integer)
    begin
        InstIdxBySid.Set(Sid, Inst);
    end;

    // The instance a Record/CodeunitRef variable owns. 0 = the implicit `Rec` of a harvested
    // procedure, which carries no instance of its own and forwards its caller's.
    procedure GetInstIdx(Sid: Integer): Integer
    var
        I: Integer;
    begin
        if InstIdxBySid.Get(Sid, I) then
            exit(I);
        exit(0);
    end;

    procedure SetInstBase(Inst: Integer; RegClass: Integer; Base: Integer)
    begin
        InstBaseMap.Set(Inst * 16 + RegClass, Base);
    end;

    procedure GetInstBase(Inst: Integer; RegClass: Integer): Integer
    var
        B: Integer;
    begin
        if InstBaseMap.Get(Inst * 16 + RegClass, B) then
            exit(B);
        exit(0);
    end;

    // Hidden descriptor rows of a harvested object's procedure (0 = the procedure has none).
    procedure SetProcHiddenRows(PId: Integer; SelfRow: Integer; RecvRow: Integer)
    begin
        ProcSelfRowMap.Set(PId, SelfRow);
        ProcRecvRowMap.Set(PId, RecvRow);
    end;

    procedure GetProcSelfRow(PId: Integer): Integer
    var
        R: Integer;
    begin
        if ProcSelfRowMap.Get(PId, R) then
            exit(R);
        exit(0);
    end;

    procedure GetProcRecvRow(PId: Integer): Integer
    var
        R: Integer;
    begin
        if ProcRecvRowMap.Get(PId, R) then
            exit(R);
        exit(0);
    end;

    // [TryFunction] marker. A try proc declares no return type; a call to it used as a VALUE is
    // Boolean (binder) and lowers to TRY_CALL, a call used as a statement stays a plain CALL.
    procedure SetProcIsTry(PId: Integer)
    begin
        TryProcSet.Set(PId, true);
    end;

    procedure IsTryProc(PId: Integer): Boolean
    begin
        exit(TryProcSet.ContainsKey(PId));
    end;

    // Count of hidden leading parameter rows — the RowShift every call site into PId must use.
    procedure GetProcHiddenCount(PId: Integer): Integer
    var
        N: Integer;
    begin
        if GetProcSelfRow(PId) > 0 then
            N += 1;
        if GetProcRecvRow(PId) > 0 then
            N += 1;
        exit(N);
    end;

    // ===== §20.4 array dimension side-table =====

    procedure SetArrayDims(Sid: Integer; Dims: List of [Integer])
    begin
        ArrayDims.Set(Sid, Dims);
    end;

    procedure GetArrayDims(Sid: Integer): List of [Integer]
    var
        Dims: List of [Integer];
    begin
        if ArrayDims.Get(Sid, Dims) then
            exit(Dims);
        exit(Dims);     // empty
    end;

    procedure GetArrayRank(Sid: Integer): Integer
    var
        Dims: List of [Integer];
    begin
        if ArrayDims.Get(Sid, Dims) then
            exit(Dims.Count());
        exit(0);
    end;

    // ===== Collection element length side-table (STORE_TEXT_CHK operand: Length*2 + IsCode) =====

    procedure SetElemChk(Sid: Integer; Chk: Integer)
    begin
        if Chk <> 0 then
            ElemChk.Set(Sid, Chk);
    end;

    procedure GetElemChk(Sid: Integer): Integer
    var
        Chk: Integer;
    begin
        if ElemChk.Get(Sid, Chk) then
            exit(Chk);
        exit(0);
    end;

    // ===== Label constant text side-table (§19.2) =====

    procedure SetLabelText(Sid: Integer; Txt: Text)
    begin
        LabelText.Set(Sid, Txt);
    end;

    procedure GetLabelText(Sid: Integer): Text
    var
        Txt: Text;
    begin
        if LabelText.Get(Sid, Txt) then
            exit(Txt);
        exit('');
    end;
}
