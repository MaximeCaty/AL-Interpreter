// ALI Binder — resolution, typing, conversions, slot allocation
//
// M5 adds full PROCEDURE support (§16 item 5):
//   * two-pass binding: pass 1 declares every procedure SIGNATURE (name, param types,
//     return type) in the module scope so forward and mutually-recursive calls bind
//     (§6.2); pass 2 binds bodies with per-proc scopes.
//   * per-proc slot allocation (§7.2): params first (declaration order), then the result
//     slot, then locals, then hidden for-loop limit slots. Expression temporaries are
//     allocated ABOVE these by the Lowerer. Module-level vars get ABSOLUTE slots 1..G per
//     class (they live below every frame window; entry frame base = G).
//   * var params (§7.2): callee slot is an indirection at runtime; the binder enforces
//     that var-param arguments are assignable lvalues of the EXACT type (no implicit
//     conversion — mirrors the native diagnostic; Text/Code excepted, any length, shorter
//     param warns). Non-var params copy by value with
//     normal assignment-conversion rules.
//   * §19.1 early type-verification pass: every typeRef is classified against the §19.2
//     matrix as it is resolved — Supported / RefShim / Rejected-known / Unknown. Bad
//     types AddError with a precise position and CONTINUE (symbol typed ErrorType,
//     poisoning §6.2) so ALL bad-type diagnostics land in one compile.
//
// ALI9xx codes owned by this stage (semantic; codes may overlap other stages' blocks):
//   ALI907 for-loop control variable rules      ALI908 assignment lvalue
//   ALI909 exit(value) outside value proc
//
//   ALI913 only calls usable as statements      ALI914 break outside loop
//   ALI915 Error() returns no value             ALI916 argument count mismatch
//   ALI917 var-param argument rules             ALI918 too many procedures
//   ALI920 arrays until M6                      ALI921 (retired) was "Option until
//                                                front-end pass"; Option now fully supported
//   ALI924 rejected-known type (v1)             ALI925 unknown type
//   ALI926 Error() arity until M7               ALI927 RefShim type not yet supported
//   ALI928 procedure used as a value            ALI929 void proc used in expression
//   ALI930 operator/operand mismatch            ALI931 condition must be Boolean
//   ALI932 cannot implicitly convert            ALI933 case label type mismatch
//   ALI934 member access until M6+              ALI935 initializers not AL
//   ALI936 statements mixed with procedures     ALI938 called name is not a procedure
//   ALI939 Label requires a text constant        ALI940 Label is read-only (no assign)
//   ALI941 unsupported Variant method            (§19.2 Label/Variant)
//   ALI942 'in' set element type mismatch
//   ALI986 unknown Option/Enum member (::)       ALI987 Enum source unresolvable (names/
//                                                 captions needed but unavailable)
//   ALI989 RecordRef member recognized but not implemented yet (field-number operand pools /
//          FieldRef-KeyRef results) — the 🔶 contract, never a bare "unknown identifier"
//   ALI1001 [TryFunction] procedure declares a return value
//   ALI1004 (warning) FlowField read but never calculated in this procedure
//
// Annotations written onto the AST :
//   every expression node ..... TypeOrd
//   NameExpr .................. SymbolId
//   assignment source / exit value / for bounds / args ... ConvOrd (toward target)
//   ForStatement node ......... SlotIndex = hidden loop-limit slot (frame-relative)
//   Invocation of Error() ..... SymbolId = -1 (lowerer contract: ERROR_RAISE)
//   Invocation of user proc ... SymbolId = proc symbol id (lowerer contract: CALL)
//   ProcDecl node ............. TypeOrd = return type, SlotIndex = result slot,
//                               SymbolId = proc symbol id
//   Param node ................ SymbolId = param symbol id
//   CompilationUnit root ...... TypeOrd = entry result type, SlotIndex = entry result
//                               slot (frame-relative), SymbolId = ENTRY PROC ID
codeunit 51038 "ALI Binder"
{
    Access = Public;
    SingleInstance = false;

    var
        Builtins: Codeunit "ALI Builtin Registry";
        SuggestCatalog: Codeunit "ALI Api Catalog";    // name lists for "did you mean" (error path only)
        OptionMeta: Codeunit "ALI Option Meta";
        RecMeta: Codeunit "ALI Rec Meta";
        TypeRules: Codeunit "ALI Type Rules";
        // M11 phase 0: bind this unit INTO an already-populated Symbol Table (no Reset), so a
        // later unit resolves the procedures an earlier one declared. Pair with SetProcIdBase.
        AppendMode: Boolean;
        InferResult: Boolean;           // form 0: infer result type from exit(expr)
        // M11 phase A: bind each procedure of this unit in its OWN diagnostic sandbox. A
        // harvested object is one unit now (that is what makes sibling calls resolve), so
        // without isolation a single procedure using an unsupported feature would take the
        // whole table down with it. Only "ALI Object Registry" turns this on.
        IsolateProcErrors: Boolean;
        // M11: this object's signatures were already declared by an earlier compile — pass 1
        // looks them up instead of declaring them again. Set when the registry comes back for a
        // procedure whose body the first compile did not reach.
        ReuseSignatures: Boolean;
        // Live-check mode: declare this unit's signatures, bind NO body. Call sites still type-
        // check (the signature is what they need), but no body means no HarvestObjectRefs, so the
        // callee's own dependency graph is never pulled in. Only "ALI Object Registry" sets it.
        SignaturesOnly: Boolean;
        // Strict script entry: `trigger OnRun()` is required and is the only entry point (no
        // first-procedure fallback, no bare statement block). Script units only; set by the host
        // through "ALI Engine".SetRequireOnRun.
        RequireOnRun: Boolean;
        // True when this unit's object declares at least one global the interpreter can store.
        // ONLY such a unit's procedures carry the hidden instance-index parameter: an object
        // without globals has no per-instance state, so its call shape stays exactly as before.
        UnitHasObjGlobals: Boolean;
        // M11 phase B2: ObjType*1000000 + ObjId of the harvested object this unit IS (0 = a
        // script). Unlike ObjectTableId it covers codeunits too, because a codeunit's globals are
        // per-instance in exactly the same way — it is what tags this unit's globals as belonging
        // to that object, and what the per-variable instance layout keys on.
        CurObjKey: Integer;
        CurProcId: Integer;             // proc being bound (pass 2)
        EntryProcIdx: Integer;          // entry proc id (OnRun if present, else first proc)
        EntryResArg: Integer;
        EntryResSlot: Integer;
        EntryResT: Integer;
        ImplicitRecSid: Integer;        // the `Rec` symbol of the proc currently being bound
        LastElemChk: Integer;           // List/Dict element (value) STORE_TEXT_CHK operand; set by ResolveList/DictType, consumed by DeclareVar
        LoopNesting: Integer;           // break legality (§5.3)
        // M11: table id when this unit is a harvested TABLE object (0 = ordinary script). Every
        // procedure of such a unit gets an implicit `Rec` VAR parameter of that table, declared
        // ahead of its own parameters — that is what makes `Rec.Field`, bare field names and
        // `Rec.Modify` work inside harvested code, and what the call site binds the receiver to.
        ObjectTableId: Integer;
        ResTypeArg: Integer;            // Text[n]/Code[n] length of the result (0 = none)
        ResTypeOrd: Integer;            // CURRENT proc result type ("ALI TypeKind" ordinal)
        ResultSlot: Integer;            // frame-relative result slot of the CURRENT proc
        ResultVarSid: Integer;          // symbol of the CURRENT proc's NAMED return value (0 = unnamed)
        // M11: the scope this unit's top-level declarations (procs + module vars) go into.
        // 1 (the Symbol Table's module scope) for a script; a HARVESTED object unit gets its
        // own scope parented to the ROOT, so object and script never see each other's names.
        UnitScopeVal: Integer;
        BlockedProcNodeList: List of [Integer];  // M11 phase A: ProcDecl nodes whose bind failed under isolation
        ForEachNodes: List of [Integer];    // ForEachStatement nodes needing 3 hidden Int slots (index/limit/handle)
        ForNodes: List of [Integer];    // ForStatement nodes of the CURRENT proc needing a limit slot
        LastArrayDims: List of [Integer];    // §20.4: set by ResolveArrayType, consumed by DeclareVar
        // AST structural columns, shared (by reference) from "ALI Ast Store" at Bind() entry —
        // see GetStructureColumns there. The binder reads these several times per node; going
        // through Ast.GetKind/GetMainToken/GetChild/GetChildCount cost a ~450ns cross-codeunit
        // call each, ~740 sites in this codeunit. Structure is immutable during binding, so
        // reading it locally is safe; ANNOTATION writes (SetTypeOrd/SetSymbolId/SetConvOrd/
        // SetSlotIndex/SetTypeArg) and ExtraInt access still go through Ast.
        NChildCnt: List of [Integer];
        NEdges: List of [Integer];
        NFirstChild: List of [Integer];
        NKind: List of [Integer];
        NMainTok: List of [Integer];
        PopulatedTables: List of [Integer];     // M6: table ids whose fields are memoized
        UnboundProcNodeList: List of [Integer];  // M11: ProcDecl nodes the reachability worklist never reached
        // M11: procedures of this object whose bodies an EARLIER compile already bound and
        // lowered. The worklist must not bind them a second time — that would declare a second
        // set of symbols against the same proc id and emit the body twice.
        AlreadyBoundNameList: List of [Text];
        BlockedProcNameList: List of [Text];     // ... their names (registry cache key)
        BlockedProcReasonList: List of [Text];   // ... and the first error each one produced
        BoundProcNameList: List of [Text];       // ... and the names of the ones it did
        // M11 reachability: bind the BODIES of these procedures and of whatever they transitively
        // call, and nothing else. Empty = bind every body (the script path, unchanged).
        EntryProcNameList: List of [Text];
        LastLabelText: Text;                 // §19.2: Label constant text; set by ResolveTypeRef LABEL branch, consumed by DeclareVar
        // M11 DotNet gate: the declaration ResolveTypeRef is currently resolving a type FOR, so a
        // rejected type can name it ("the variable 'Compressor'") instead of reporting a bare
        // "DotNet is not supported" with nothing to search for. Set around every ResolveTypeRef
        // call that has a name to give; empty everywhere else.
        DeclNameHint: Text;
        // M11 phase C3: codeunit-variable symbol ids the harvest pre-scan saw used for a real
        // PROCEDURE call. `MyCU.Run` on one of them splits state between ALI's instance block and
        // the platform instance, so it is refused (ALI928). Filled by TryHarvestReceiverObject.
        CodeunitVarProcUse: List of [Integer];
        // ALI1004, per procedure body of the SCRIPT: FlowFields read as a value (key 'table:field'
        // -> first source position / name) and FlowFields named by CalcFields/SetAutoCalcFields/
        // CalcSums on any record of that table. A read never calculated = a value of 0 / ''.
        FlowFieldReadPos: Dictionary of [Text, Integer];
        FlowFieldReadName: Dictionary of [Text, Text];
        FlowFieldCalced: Dictionary of [Text, Boolean];

    // ===== Public API (§6.2) =====

    // Bind into the symbols an earlier unit already declared instead of starting from a clean
    // table (see AppendMode). Call BEFORE Bind.
    procedure SetAppendMode(Value: Boolean)
    begin
        AppendMode := Value;
    end;

    // Scope for this unit's top-level declarations (see UnitScopeVal). Call BEFORE Bind; 0 or
    // an unset value means the Symbol Table's module scope. Only a harvested object unit needs
    // this — the "ALI Object Registry" opens a root-parented scope and passes it here.
    procedure SetUnitScope(S: Integer)
    begin
        UnitScopeVal := S;
    end;

    local procedure UnitScope(var Symbols: Codeunit "ALI Symbol Table"): Integer
    begin
        if UnitScopeVal > 0 then
            exit(UnitScopeVal);
        exit(Symbols.ModuleScope());
    end;

    // Bind this unit as the body of a harvested OBJECT. Call BEFORE Bind; only "ALI Object
    // Registry" does. ObjType is an "ALI Object Type" ordinal; ObjType::None restores ordinary
    // script binding.
    //
    // Only a TABLE contributes an implicit receiver: its procedures address fields, so they need
    // `Rec`. A CODEUNIT has no fields, so its procedures bind almost like a script's — the one
    // thing both kinds share is the phase-B2 hidden instance index, and only when the object
    // declares globals worth keeping per variable.
    procedure SetObjectContext(ObjType: Integer; ObjId: Integer)
    begin
        ObjectTableId := 0;
        if ObjType = "ALI Object Type"::Table.AsInteger() then
            ObjectTableId := ObjId;
        CurObjKey := 0;
        if ObjType <> "ALI Object Type"::None.AsInteger() then
            CurObjKey := ObjKeyOf(ObjType, ObjId);
    end;

    // Object identity as one integer, same packing as "ALI Object Registry".KeyOfObject — the
    // two tables are keyed alike so a key means the same thing on both sides.
    local procedure ObjKeyOf(ObjType: Integer; ObjId: Integer): Integer
    begin
        exit(ObjType * 1000000 + ObjId);
    end;

    // The object a variable of this type is an INSTANCE of, or 0 for a type that carries no
    // object globals. A record variable instantiates its table, a codeunit variable its codeunit.
    local procedure ObjKeyOfVarType(T: Integer; TArg: Integer): Integer
    begin
        if T = "ALI TypeKind"::Record then
            exit(ObjKeyOf("ALI Object Type"::Table.AsInteger(), TArg));
        if T = "ALI TypeKind"::CodeunitRef then
            exit(ObjKeyOf("ALI Object Type"::Codeunit.AsInteger(), TArg));
        exit(0);
    end;

    // M11 phase B2: give a freshly declared Record/Codeunit variable its own block of that
    // object's globals. Called for globals, locals and parameters alike — every DECLARED
    // variable is one instance, which is precisely native AL's model. The implicit `Rec` of a
    // harvested procedure is the one exception (it forwards its caller's instance) and simply
    // never reaches here.
    local procedure AssignInstance(var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer; T: Integer; TArg: Integer)
    var
        ObjKey: Integer;
    begin
        if Sid <= 0 then
            exit;
        ObjKey := ObjKeyOfVarType(T, TArg);
        if ObjKey = 0 then
            exit;
        Symbols.SetInstIdx(Sid, Symbols.NewInstance(ObjKey));
    end;

    // M11 phase A: sandbox each procedure's diagnostics (see IsolateProcErrors). Call BEFORE
    // Bind. After Bind, BlockedProc* report which procedures were dropped and why.
    procedure SetIsolateProcErrors(Value: Boolean)
    begin
        IsolateProcErrors := Value;
    end;

    // M11 reachability: bind only these procedures' bodies and whatever they transitively call.
    // Call BEFORE Bind; an empty list binds everything. Only "ALI Object Registry" sets this —
    // a script has no entry set and is bound whole.
    procedure SetEntryProcNames(Names: List of [Text])
    begin
        EntryProcNameList := Names;
    end;

    // Strict script entry (see RequireOnRun). Call BEFORE Bind.
    procedure SetRequireOnRun(Value: Boolean)
    begin
        RequireOnRun := Value;
    end;

    // Signatures without bodies for this unit (see SignaturesOnly). Call BEFORE Bind.
    procedure SetSignaturesOnly(Value: Boolean)
    begin
        SignaturesOnly := Value;
    end;

    // M11: this unit's signatures are already in the scope from an earlier compile of the same
    // object; pass 1 must look them up, not re-declare them. Call BEFORE Bind.
    procedure SetReuseSignatures(Value: Boolean)
    begin
        ReuseSignatures := Value;
    end;

    // Procedures of this object an earlier compile already bound and lowered (see
    // AlreadyBoundNameList). Call BEFORE Bind.
    procedure SetAlreadyBoundProcNames(Names: List of [Text])
    begin
        AlreadyBoundNameList := Names;
    end;

    // ProcDecl nodes the reachability worklist never reached: signatures exist, bodies do not.
    // The lowerer must emit NOTHING for these (not even a stub) — the proc row stays empty until
    // a later compile of the same object binds it.
    procedure UnboundProcNodes(): List of [Integer]
    begin
        exit(UnboundProcNodeList);
    end;

    // Names of the procedures whose bodies WERE bound in this pass.
    procedure BoundProcNames(): List of [Text]
    begin
        exit(BoundProcNameList);
    end;

    // ProcDecl nodes that did not compile — the lowerer must not lower these bodies.
    procedure BlockedProcNodes(): List of [Integer]
    begin
        exit(BlockedProcNodeList);
    end;

    // Names of the blocked procedures (parallel to BlockedProcNodes).
    procedure BlockedProcNames(): List of [Text]
    begin
        exit(BlockedProcNameList);
    end;

    // First error each blocked procedure produced (parallel to BlockedProcNodes).
    procedure BlockedProcReasons(): List of [Text]
    begin
        exit(BlockedProcReasonList);
    end;

    // Strict entry (RequireOnRun): the `trigger OnRun` among the unit's procedures — a trigger is
    // parsed as a ProcDecl, so it is told apart by the keyword token right before its name. A
    // missing one is ALI1000; the first procedure is still returned so binding carries on and
    // reports everything else in the same pass.
    local procedure StrictEntryProc(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; var ProcNodes: List of [Integer]; var ProcIds: List of [Integer]; Root: Integer): Integer
    var
        i: Integer;
        NameTok: Integer;
        ProcOnRunTok: Integer;
    begin
        for i := 1 to ProcNodes.Count() do begin
            NameTok := NMainTok.Get(ProcNodes.Get(i));
            if UpperCase(Tokens.GetIdentText(NameTok)) = 'ONRUN' then
                if NameTok > 1 then
                    if Tokens.GetKind(NameTok - 1) = "ALI TokenKind"::TriggerKeyword.AsInteger() then
                        exit(ProcIds.Get(i))
                    else
                        if ProcOnRunTok = 0 then
                            ProcOnRunTok := NameTok;
        end;
        if ProcOnRunTok <> 0 then
            Diags.AddError('ALI1000', 'OnRun must be declared as a trigger: write ''trigger OnRun()'' instead of ''procedure OnRun()''', TokPos(Tokens, ProcOnRunTok), Tokens.GetLength(ProcOnRunTok))
        else
            Diags.AddError('ALI1000', 'The script has no entry point: declare ''trigger OnRun() begin ... end;'' — it is the only procedure executed, the others run when called', TokPos(Tokens, NMainTok.Get(Root)), 0);
        exit(ProcIds.Get(1));
    end;

    // One procedure's diagnostic sandbox: roll the bag back to Mark and record the procedure as
    // blocked when binding it produced errors. A no-op unless isolation is on, so the script
    // path is byte-identical. Warnings raised by a blocked procedure go too — they describe code
    // that will never run.
    local procedure SealProcDiags(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; ProcNode: Integer; Mark: Integer; ErrMark: Integer)
    var
        i: Integer;
        Reason: Text;
    begin
        if not IsolateProcErrors then
            exit;
        if Diags.ErrorCount() <= ErrMark then
            exit;
        if BlockedProcNodeList.Contains(ProcNode) then begin  // already blocked in pass 1
            Diags.TruncateTo(Mark);
            exit;
        end;
        for i := Mark + 1 to Diags.Count() do
            if (Reason = '') and (Diags.GetSeverity(i) = "ALI Severity"::Error) then
                Reason := StrSubstNo('%1 %2', Diags.GetCode(i), Diags.GetMessage(i));
        Diags.TruncateTo(Mark);
        BlockedProcNodeList.Add(ProcNode);
        BlockedProcNameList.Add(Tokens.GetIdentText(NMainTok.Get(ProcNode)));
        BlockedProcReasonList.Add(Reason);
    end;

    // Number of hidden parameters prepended to every procedure of this unit: 1 (`Rec`) inside a
    // table object, 0 in a script. Declared parameter k therefore occupies descriptor row
    // k + HiddenParamCount.
    local procedure HiddenParamCount(): Integer
    var
        N: Integer;
    begin
        if UnitHasObjGlobals then
            N += 1;
        if ObjectTableId <> 0 then
            N += 1;
        exit(N);
    end;

    // Descriptor row of the hidden instance index (0 = this unit's procedures have none).
    local procedure SelfParamRow(): Integer
    begin
        if UnitHasObjGlobals then
            exit(1);
        exit(0);
    end;

    // Descriptor row of the implicit `Rec` receiver (0 = not a table unit). It follows the
    // instance index when there is one.
    local procedure RecvParamRow(): Integer
    begin
        if ObjectTableId = 0 then
            exit(0);
        exit(SelfParamRow() + 1);
    end;

    // Bind the compilation unit rooted at Root. Returns true when the bag holds no errors
    // afterwards. All annotations + symbol slots are written even on partial failure
    // (poisoned nodes carry ErrorType) — callers must gate lowering on the return value.
    // M11: the Module is threaded through the bind because binding is what ALLOCATES proc-table
    // rows (pass 1 below) — and because resolving `Rec.SomeUserProc()` can harvest another
    // object mid-bind, whose procedures must be lowered into this same Module before this bind
    // finishes. Callers that only want diagnostics pass a scratch Module.
    procedure Bind(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; Root: Integer): Boolean
    var
        Limits: Codeunit "ALI Limits";
        // Pass 1/2 are written out in full rather than split into helpers: they are the hot path
        // for M11 harvesting (once per procedure of every harvested object), and each helper was
        // single-use. Distinct prefixes keep the merged locals apart — Sig* for the signature
        // pass, Row* for the proc-row reservation, Walk*/Ref* for the reachability walk.
        DupFound: Boolean;
        RowMatched: Boolean;
        SigAllSame: Boolean;
        SigIsVar: Boolean;
        SigStop: Boolean;
        SkipBody: Boolean;
        ProcIndexBySid: Dictionary of [Integer, Integer];
        Child: Integer;
        DiagMark: Integer;
        ErrMark: Integer;
        i: Integer;
        K: Integer;
        OtherPId: Integer;
        OtherRow: Integer;
        OtherSid: Integer;
        ParamListNode: Integer;
        ParamNode: Integer;
        PArg: Integer;
        pk: Integer;
        ProcNode: Integer;
        PT: Integer;
        RefIdx: Integer;
        RefSid: Integer;
        RetArg: Integer;
        RetNode: Integer;
        RetT: Integer;
        RowCandSid: Integer;
        RowPId: Integer;
        RowSid: Integer;
        RowWant: Integer;
        SigN: Integer;
        SigNameId: Integer;
        SigPId: Integer;
        SigRow: Integer;
        SigSid: Integer;
        sk: Integer;
        WalkNode: Integer;
        wk: Integer;
        BodyStmts: List of [Integer];
        Done: List of [Integer];
        Pending: List of [Integer];
        ProcIds: List of [Integer];
        ProcNodes: List of [Integer];
        WalkStack: List of [Integer];
        Wanted: Text;
    begin
        // Share the AST structural columns for the whole bind (see the N* member declarations).
        // Must happen before any Bind*/Resolve* work, which all read through them.
        Ast.GetStructureColumns(NKind, NMainTok, NFirstChild, NChildCnt, NEdges);

        if not AppendMode then
            Symbols.Reset();
        Symbols.SetCurrentScope(UnitScope(Symbols));
        Builtins.EnsureBuilt();
        RecMeta.Reset();
        Clear(PopulatedTables);
        LoopNesting := 0;
        InferResult := false;
        ResTypeOrd := "ALI TypeKind"::None;
        ResTypeArg := 0;
        ResultSlot := 0;
        ResultVarSid := 0;
        Clear(ForNodes);
        Clear(ForEachNodes);
        Clear(BlockedProcNodeList);
        Clear(BlockedProcNameList);
        Clear(BlockedProcReasonList);
        CurProcId := 0;
        EntryProcIdx := 0;
        EntryResT := "ALI TypeKind"::None;
        EntryResArg := 0;
        EntryResSlot := 0;

        Clear(UnboundProcNodeList);
        Clear(BoundProcNameList);

        // Classify root children: var sections (module scope), proc decls, bare statements.
        for i := 0 to NChildCnt.Get(Root) - 1 do begin
            Child := NEdges.Get(NFirstChild.Get(Root) + i);
            K := NKind.Get(Child);
            case true of
                (K = "ALI NodeKind"::VarSection):
                    // In ReuseSignatures mode this unit's declarations are already in the scope
                    // from the earlier compile — re-declaring them is an AL0198 duplicate.
                    if not ReuseSignatures then
                        DeclareVarSection(Tokens, Ast, Symbols, Diags, Child, 0);
                (K = "ALI NodeKind"::ProcDecl):
                    ProcNodes.Add(Child);
                (K = "ALI NodeKind"::MissingNode):
                    ;   // sentinel — skip
                else
                    BodyStmts.Add(Child);   // form 0: bare statement
            end;
        end;

        // M11 phase B2: decided BEFORE pass 1, because it changes every signature this unit
        // registers. Recomputed from the symbol table rather than remembered from the
        // declaration loop above, so a ReuseSignatures recompile (which re-declares nothing)
        // still sees the globals the FIRST compile of this object put there.
        UnitHasObjGlobals := UnitDeclaresStorableGlobals(Symbols);

        AllocateGlobalSlots(Symbols);

        // Proc-table rows are allocated HERE, not in the lowerer: a `Rec.UserProc()` call
        // resolved during pass 2 harvests another object and lowers ITS procedures into this
        // same Module immediately, so this unit's rows must already be reserved by then or the
        // two units would claim the same ids.
        if ProcNodes.Count() = 0 then begin
            if RequireOnRun and (CurObjKey = 0) then
                Diags.AddError('ALI1000', 'The script has no entry point: declare ''trigger OnRun() begin ... end;'' and put the code to run in it', TokPos(Tokens, 1), 0);
            // Synthetic OnRun over the bare statement list (form 0) = this unit's only proc.
            InferResult := true;
            CurProcId := Module.AddProc();
            EntryProcIdx := CurProcId;
            Clear(ForNodes);
            Clear(ForEachNodes);
            ClearFlowFieldUse();
            foreach Child in BodyStmts do
                HarvestObjectRefs(Tokens, Ast, Symbols, Diags, Module, Child);
            foreach Child in BodyStmts do
                BindStatement(Tokens, Ast, Symbols, Diags, Child);
            ReportUncalcedFlowFields(Diags);
            AllocateProcSlots(Ast, Symbols, CurProcId);
            EntryResT := ResTypeOrd;
            EntryResArg := ResTypeArg;
            EntryResSlot := ResultSlot;
        end else begin
            if BodyStmts.Count() > 0 then
                Diags.AddError('ALI936', 'Top-level statements cannot be mixed with procedure declarations', TokPos(Tokens, Ast.GetMainToken(BodyStmts.Get(1))), 0);
            // ReuseSignatures adds no rows — they were reserved by the earlier compile.
            if not ReuseSignatures then
                if Module.ProcCount() + ProcNodes.Count() > Limits.MaxProcsPerModule() then begin
                    Diags.AddError('ALI918', StrSubstNo('Too many procedures: %1 (max %2)', Module.ProcCount() + ProcNodes.Count(), Limits.MaxProcsPerModule()), TokPos(Tokens, NMainTok.Get(Root)), 0);
                    exit(false);
                end;

            // ---- Pass 1: signatures (forward/mutual references bind, §6.2) ----
            // ALWAYS for every procedure, even when pass 2 will bind only a few: a reachable
            // procedure must be able to call any sibling, and a signature costs no harvest.
            //
            // ReserveProcRow inlined. Normally a fresh proc-table row; in ReuseSignatures mode
            // the row this object's EARLIER compile already reserved, found by NAME (identifiers
            // are interned per token table, so the previous unit's NameId means nothing here —
            // LookupProcByName is the only bridge). Overloads resolve to the first declaration,
            // matching every other cross-unit lookup in M11. Proc id 0 = no signature under that
            // name, so pass 2 must leave the procedure alone: adding a row here would give it an
            // id with NO parameter descriptors (ReuseSignatures skips the declaration below) and
            // the body would bind against an empty signature.
            for i := 1 to ProcNodes.Count() do begin
                ProcNode := ProcNodes.Get(i);
                RowPId := 0;
                if ReuseSignatures then begin
                    RowSid := Symbols.LookupProcByName(UnitScope(Symbols), Tokens.GetIdentText(NMainTok.Get(ProcNode)));
                    // OVERLOADS: LookupProcByName answers with the FIRST declaration of that
                    // spelling. Handing its proc id to a DIFFERENT overload gave that body a
                    // signature with the wrong number of descriptor rows, so ProcParamRow
                    // returned 0 and BindProcBody indexed the descriptor lists with it — a raw
                    // "invalid argument ... List" out of the interpreter, no diagnostic. Pick the
                    // overload whose PARAMETER COUNT matches this declaration; the overload chain
                    // is keyed by the NameId of the compile that declared it, which is what
                    // GetNameId(RowSid) carries (ours is from a different token table, §4.1).
                    if RowSid > 0 then begin
                        RowWant := NChildCnt.Get(NEdges.Get(NFirstChild.Get(ProcNode) + 0)) + HiddenParamCount();
                        if Symbols.ProcParamCount(Symbols.GetProcId(RowSid)) <> RowWant then begin
                            RowMatched := false;
                            foreach RowCandSid in Symbols.ProcOverloads(UnitScope(Symbols), Symbols.GetNameId(RowSid)) do
                                if not RowMatched then
                                    if Symbols.ProcParamCount(Symbols.GetProcId(RowCandSid)) = RowWant then begin
                                        RowSid := RowCandSid;
                                        RowMatched := true;
                                    end;
                            // ponytail: arity only — two overloads with the same count but
                            // different types still pick the first. Compare descriptor types here
                            // if that ever bites; the crash it replaced needed only the count.
                            if not RowMatched then
                                RowSid := 0;             // no reusable row: pass 2 skips the body
                        end;
                    end;
                    if RowSid > 0 then begin
                        Ast.SetSymbolId(ProcNode, RowSid);      // lowerer contract: ProcIdOfNode reads this
                        RowPId := Symbols.GetProcId(RowSid);
                    end;
                end else
                    RowPId := Module.AddProc();
                ProcIds.Add(RowPId);
            end;

            // DeclareProcSignature inlined (ProcDecl children §5.5: [0]=ParamList,
            // [1]=returnTypeRef|Missing, [2]=localVarSection|Missing, [3]=body Block; ExtraInt =
            // NameId. Param node: child [0]=typeRef, ExtraInt = NameId*2 + var-bit).
            if not ReuseSignatures then
                for i := 1 to ProcNodes.Count() do begin
                    DiagMark := Diags.Count();
                    ErrMark := Diags.ErrorCount();
                    ProcNode := ProcNodes.Get(i);
                    SigPId := ProcIds.Get(i);
                    SigNameId := Ast.GetExtra(ProcNode);
                    ParamListNode := NEdges.Get(NFirstChild.Get(ProcNode) + 0);
                    RetNode := NEdges.Get(NFirstChild.Get(ProcNode) + 1);

                    RetT := "ALI TypeKind"::None;
                    RetArg := 0;
                    if not Ast.IsMissing(RetNode) then
                        // Handle Lifecycle Unification: array-return is supported — a returned
                        // array handle survives its frame's reclaim via the same return-escape
                        // mechanism as List/Dictionary/Http*. The ONLY legal sink for the result
                        // is `localArrayVar := Call()` (see BindAssignment's Array block +
                        // "ALI Lowerer".ARR_REBIND) — arrays still have no general whole-array
                        // assignment or var-param passing (ALI991).
                        RetT := ResolveTypeRef(Tokens, Ast, Diags, RetNode, RetArg);
                    // M11 phase C1: no register class, so no result slot to return one through.
                    if (RetT = "ALI TypeKind"::CodeunitRef) or (RetT = "ALI TypeKind"::NativeCodeunit) then begin
                        Diags.AddError('ALI927', 'A procedure cannot return a codeunit', TokPos(Tokens, Ast.GetMainToken(RetNode)), 0);
                        RetT := "ALI TypeKind"::ErrorType;
                    end;
                    // [TryFunction]: the Boolean a call yields is the try outcome, so the procedure
                    // itself may not declare a value (native AL rejects it the same way). The flag
                    // is keyed by proc id — BindUserProcCall types the call, LowerCall picks TRY_CALL.
                    if Ast.GetTryFunction(ProcNode) then begin
                        Symbols.SetProcIsTry(SigPId);
                        if not Ast.IsMissing(RetNode) then begin
                            Diags.AddError('ALI1001', StrSubstNo('The TryFunction ''%1'' cannot declare a return value — a call to it returns the Boolean try outcome', Tokens.GetIdentText(NMainTok.Get(ProcNode))), TokPos(Tokens, Ast.GetMainToken(RetNode)), 0);
                            RetT := "ALI TypeKind"::ErrorType;
                        end;
                    end;

                    // Overloading (native AL): same proc name is legal when the parameter lists
                    // differ in count or type — DeclareProcInScope chains overloads; only a clash
                    // with a NON-proc symbol returns 0. Identical signatures are caught after the
                    // param descriptors are registered.
                    SigSid := Symbols.DeclareProcInScope(UnitScope(Symbols), SigNameId, RetT, RetArg, SigPId);
                    if SigSid = 0 then
                        Diags.AddError('AL0198', StrSubstNo('A procedure named ''%1'' is already defined in this scope', Tokens.GetIdentText(NMainTok.Get(ProcNode))), TokPos(Tokens, NMainTok.Get(ProcNode)), 0)
                    else begin
                        Ast.SetSymbolId(ProcNode, SigSid);
                        // Cross-unit handle (M11): NameIds are per-token-table, so another unit
                        // can only ask for this procedure by its spelling. One dictionary write.
                        Symbols.RegisterProcName(UnitScope(Symbols), Tokens.GetIdentText(NMainTok.Get(ProcNode)), SigSid);
                    end;

                    // M11: the implicit receiver goes in as descriptor row 1, ahead of the
                    // declared parameters, so a call site stages it exactly like any other var
                    // parameter (ARG_REF — an alias, no copy, so the callee mutates the caller's
                    // record as native AL does).
                    //
                    // M11 phase B2: the INSTANCE INDEX goes in first, ahead of the receiver, when
                    // the object declares globals — it says which variable's block of them this
                    // call runs on. Objects without globals get neither hidden row and keep the
                    // call shape they had. Every call site reads the count back through
                    // "ALI Symbol Table".GetProcHiddenCount rather than assuming one.
                    if UnitHasObjGlobals then
                        Symbols.AddProcParam(SigPId, "ALI TypeKind"::Integer, 0, false);
                    if ObjectTableId <> 0 then
                        Symbols.AddProcParam(SigPId, "ALI TypeKind"::Record, ObjectTableId, true);
                    Symbols.SetProcHiddenRows(SigPId, SelfParamRow(), RecvParamRow());

                    // Param descriptor rows (type verification §19.1 runs here, once per param).
                    for pk := 0 to NChildCnt.Get(ParamListNode) - 1 do begin
                        ParamNode := NEdges.Get(NFirstChild.Get(ParamListNode) + pk);
                        SigIsVar := (Ast.GetExtra(ParamNode) mod 2) = 1;
                        DeclNameHint := Tokens.GetIdentText(NMainTok.Get(ParamNode));
                        PT := ResolveTypeRef(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(ParamNode) + 0), PArg);
                        DeclNameHint := '';
                        // §20.5 escape guard: neither a var-param (upward alias out of the frame)
                        // nor a byval array param (would require a whole-array copy, unsupported
                        // §20.1(1)) may exist — both close off escape vectors so reclamation-at-
                        // frame-pop stays sound.
                        if PT = "ALI TypeKind"::Array then begin
                            if SigIsVar then
                                Diags.AddError('ALI991', 'An array cannot be passed by reference (var) in this milestone', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(ParamNode) + 0))), 0)
                            else
                                Diags.AddError('ALI991', 'An array cannot be passed by value as a parameter in this milestone', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(ParamNode) + 0))), 0);
                            PT := "ALI TypeKind"::ErrorType;
                        end;
                        // M11 phase C1: a codeunit variable has no register class, so there is
                        // nothing for ARG_VAL/ARG_REF to stage. Declare one as a local or an
                        // object global and call its procedures directly.
                        // NativeCodeunit BY VALUE too: it has a handle, but whether native AL shares or
                        // copies a codeunit passed by value is not something to guess. By `var` it is
                        // an ordinary Int-handle alias (like a var Record) — `var TempBlob: Codeunit
                        // "Temp Blob"` is how helper procedures take one; the callee never frees it
                        // (only NCU_NEW locals are tracked) and cannot re-assign it (ALI927).
                        if (PT = "ALI TypeKind"::CodeunitRef) or ((PT = "ALI TypeKind"::NativeCodeunit) and not SigIsVar) then begin
                            Diags.AddError('ALI927', 'A codeunit cannot be a procedure parameter — declare it as a variable where it is used', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(ParamNode) + 0))), 0);
                            PT := "ALI TypeKind"::ErrorType;
                        end;
                        // Handle Lifecycle Unification (Phase 3): a Record var-param is an
                        // ordinary alias (LOAD_IND/STORE_IND work generically for any Int-handle
                        // type). A BYVAL Record param copies only the Int HANDLE at the call
                        // (ARG_VAL); native value semantics (independent record + filters, §7.5)
                        // are restored by the callee prologue, which opens a FRESH handle, copies
                        // the caller's record into it and rebinds the param slot — see
                        // "ALI Lowerer".EmitCopyByvalRecordParams.
                        Symbols.AddProcParam(SigPId, PT, PArg, SigIsVar);
                    end;

                    // Duplicate-SIGNATURE check (native AL0198), SameSignatureExists inlined: an
                    // overload is only legal when the parameter list differs in count or type from
                    // every EARLIER one. Runs after AddProcParam so this proc's descriptors are
                    // comparable. Types compare on TypeOrd; Record params additionally on table id
                    // (`Record A` vs `Record B` overload legally). Var-ness does not
                    // differentiate, matching native.
                    if SigSid <> 0 then begin
                        DupFound := false;
                        SigStop := false;
                        SigN := Symbols.ProcParamCount(SigPId);
                        // AL has no loop `break` out of a foreach here without restructuring, so
                        // the scan carries a stop flag. It must stop AT OURSELVES: only EARLIER
                        // overloads count, and the chain is in declaration order.
                        foreach OtherSid in Symbols.ProcOverloads(UnitScope(Symbols), SigNameId) do
                            if not SigStop then
                                if OtherSid = SigSid then
                                    SigStop := true     // reached ourselves — every earlier overload differed
                                else begin
                                    OtherPId := Symbols.GetProcId(OtherSid);
                                    if Symbols.ProcParamCount(OtherPId) = SigN then begin
                                        SigAllSame := true;
                                        for sk := 1 to SigN do begin
                                            SigRow := Symbols.ProcParamRow(SigPId, sk);
                                            OtherRow := Symbols.ProcParamRow(OtherPId, sk);
                                            if Symbols.ParamRowType(SigRow) <> Symbols.ParamRowType(OtherRow) then
                                                SigAllSame := false
                                            else
                                                if (Symbols.ParamRowType(SigRow) = "ALI TypeKind"::Record) and (Symbols.ParamRowTypeArg(SigRow) <> Symbols.ParamRowTypeArg(OtherRow)) then
                                                    SigAllSame := false;
                                        end;
                                        if SigAllSame then begin
                                            DupFound := true;
                                            SigStop := true;
                                        end;
                                    end;
                                end;
                        if DupFound then
                            Diags.AddError('AL0198', StrSubstNo('A procedure named ''%1'' with the same parameter types is already defined in this scope', Tokens.GetIdentText(NMainTok.Get(ProcNode))), TokPos(Tokens, NMainTok.Get(ProcNode)), 0);
                    end;

                    SealProcDiags(Tokens, Diags, ProcNode, DiagMark, ErrMark);
                end;

            // Entry proc: first proc named OnRun (codeunit-shell trigger), else the first proc.
            // Strict mode (script units): only `trigger OnRun` qualifies, and there is no fallback.
            if RequireOnRun and (CurObjKey = 0) then
                EntryProcIdx := StrictEntryProc(Tokens, Diags, ProcNodes, ProcIds, Root)
            else begin
                EntryProcIdx := ProcIds.Get(1);
                for i := 1 to ProcNodes.Count() do begin
                    ProcNode := ProcNodes.Get(i);
                    if UpperCase(Tokens.GetIdentText(NMainTok.Get(ProcNode))) = 'ONRUN' then begin
                        EntryProcIdx := ProcIds.Get(i);
                        break;
                    end;
                end;
            end;

            // ---- Pass 2: bodies, REACHABLE ONES ONLY ----
            //
            // Binding a body is what costs: it runs HarvestObjectRefs, which compiles every
            // object that body touches, whose own bodies harvest further. Binding all ~50
            // procedures of a helper codeunit to serve one call therefore pulled in a whole
            // dependency graph — thousands of symbols and tens of seconds for a call that
            // executes a few hundred statements. A script asks for ONE procedure; only that
            // procedure and what it actually calls need bodies.
            //
            // A worklist, not a pre-computed graph: the call edges only exist once a body is
            // bound, so each newly bound body is scanned for sibling references and those are
            // queued. An empty entry set (every script) means "everything", so the script path
            // is unchanged.
            // SeedReachable inlined: the procedures named in the entry set, or ALL of them when
            // no entry set was given (every script). Every overload of a wanted name is seeded —
            // the caller asked by name and which overload it meant is not known here.
            // Signatures-only: seed nothing, so the worklist below binds no body at all.
            if SignaturesOnly then
                Clear(Pending)
            else
                if EntryProcNameList.Count() = 0 then
                    for i := 1 to ProcNodes.Count() do
                        Pending.Add(i)
                else
                    foreach Wanted in EntryProcNameList do
                        for i := 1 to ProcNodes.Count() do
                            if UpperCase(Tokens.GetIdentText(NMainTok.Get(ProcNodes.Get(i)))) = UpperCase(Wanted) then
                                Pending.Add(i);

            // BuildProcNodeIndex inlined: proc SymbolId -> index into ProcNodes, so a call found
            // in a bound body maps back to the declaration whose body has to be bound next.
            Clear(ProcIndexBySid);
            for i := 1 to ProcNodes.Count() do begin
                RowSid := Ast.GetSymbolId(ProcNodes.Get(i));
                if RowSid > 0 then
                    ProcIndexBySid.Set(RowSid, i);
            end;

            while Pending.Count() > 0 do begin
                i := Pending.Get(1);
                Pending.RemoveAt(1);
                if not Done.Contains(i) then begin
                    Done.Add(i);
                    ProcNode := ProcNodes.Get(i);
                    // AlreadyBound inlined. Already lowered by an earlier compile of this object,
                    // or with no usable signature (proc id 0, see pass 1): leave the row alone.
                    // Still counts as Done so the worklist does not chase it again, and goes to
                    // UnboundProcNodes so this pass's lowerer emits nothing for it.
                    SkipBody := ProcIds.Get(i) <= 0;
                    if not SkipBody then
                        if AlreadyBoundNameList.Count() > 0 then
                            SkipBody := AlreadyBoundNameList.Contains(UpperCase(Tokens.GetIdentText(NMainTok.Get(ProcNode))));
                    if SkipBody then
                        UnboundProcNodeList.Add(ProcNode)
                    else begin
                        DiagMark := Diags.Count();
                        ErrMark := Diags.ErrorCount();
                        BindProcBody(Tokens, Ast, Symbols, Diags, Module, ProcNode, ProcIds.Get(i));
                        SealProcDiags(Tokens, Diags, ProcNode, DiagMark, ErrMark);
                        BoundProcNameList.Add(Tokens.GetIdentText(NMainTok.Get(ProcNode)));

                        // QueueSiblingRefs inlined: walk the just-bound body and queue every
                        // SIBLING it calls. Two shapes carry a callee — an ordinary user call puts
                        // the proc symbol in SymbolId, an object call (a table's `Rec.Sibling()`,
                        // including the bare form phase A rewrites) puts the sentinel in SymbolId
                        // and the symbol in SlotIndex. A symbol belonging to ANOTHER object is not
                        // in the index and is ignored — that object is harvested on its own.
                        // Iterative: an AST nests to "ALI Limits".MaxNestingDepth and AL's own
                        // stack is the one thing the interpreter cannot catch.
                        if NChildCnt.Get(ProcNode) >= 4 then begin
                            Clear(WalkStack);
                            WalkStack.Add(NEdges.Get(NFirstChild.Get(ProcNode) + 3));    // body Block
                            while WalkStack.Count() > 0 do begin
                                WalkNode := WalkStack.Get(WalkStack.Count());
                                WalkStack.RemoveAt(WalkStack.Count());

                                RefSid := Ast.GetSymbolId(WalkNode);
                                if RefSid = ObjectCallMark() then
                                    RefSid := Ast.GetSlotIndex(WalkNode);
                                if RefSid > 0 then
                                    if ProcIndexBySid.Get(RefSid, RefIdx) then
                                        if not Done.Contains(RefIdx) then
                                            if not Pending.Contains(RefIdx) then
                                                Pending.Add(RefIdx);

                                for wk := 0 to NChildCnt.Get(WalkNode) - 1 do
                                    WalkStack.Add(NEdges.Get(NFirstChild.Get(WalkNode) + wk));
                            end;
                        end;

                        if ProcIds.Get(i) = EntryProcIdx then begin
                            EntryResT := ResTypeOrd;
                            EntryResArg := ResTypeArg;
                            EntryResSlot := ResultSlot;
                        end;
                    end;
                end;
            end;

            // Whatever the worklist never reached has a reserved proc row but no body. The
            // lowerer must emit nothing for those — a later request for one of them recompiles
            // the object in ReuseSignatures mode and fills the row in then.
            for i := 1 to ProcNodes.Count() do
                if not Done.Contains(i) then
                    UnboundProcNodeList.Add(ProcNodes.Get(i));
        end;

        // Handle Lifecycle Unification (Phase 3): Record/Stream/TextBuilder/Dialog local AND
        // global handle slots are now allocated generically by AllocateGlobalSlots/
        // AllocateProcSlots (RegClassFor routes them to RegClassInt, same as List/Dictionary/
        // Array/Http*) — the special-cased Allocate*Handles passes are gone. This also fixes
        // the prior "top-level only" restriction: Record/Stream/TextBuilder can now be proc
        // locals too, exactly like Dialog already could.

        // Lowerer contract: entry result type + slot + entry proc id on the CU root.
        Ast.SetTypeOrd(Root, EntryResT);
        Ast.SetSlotIndex(Root, EntryResSlot);
        Ast.SetSymbolId(Root, EntryProcIdx);

        // M11 phase B2: this is the SCRIPT unit (an object unit has a CurObjKey), so every
        // harvest it could trigger has happened and the instance layout is final. Re-run it once
        // more and publish it — the lowerer reads the bases to initialise each instance's
        // handle-kind globals, the interpreter to resolve SELF_LOAD/SELF_STORE.
        if CurObjKey = 0 then begin
            AllocateGlobalSlots(Symbols);
            PublishInstanceLayout(Symbols, Module);
        end;
        exit(not Diags.HasErrors());
    end;

    // ===== Pass 2: procedure bodies =====

    local procedure BindProcBody(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; ProcNode: Integer; PId: Integer)
    var
        IsVar: Boolean;
        k: Integer;
        LocalsNode: Integer;
        ParamListNode: Integer;
        ParamNameId: Integer;
        ParamNode: Integer;
        ProcSym: Integer;
        RetVarNode: Integer;
        Row: Integer;
        RowArg: Integer;
        RowT: Integer;
        Sid: Integer;
        SymFlags: Integer;
        SymKind: Integer;
    begin
        CurProcId := PId;
        LoopNesting := 0;
        InferResult := false;
        Clear(ForNodes);
        Clear(ForEachNodes);

        ProcSym := Ast.GetSymbolId(ProcNode);
        if ProcSym > 0 then begin
            ResTypeOrd := Symbols.GetType(ProcSym);
            ResTypeArg := Symbols.GetTypeArg(ProcSym);
        end else begin
            // duplicate proc name — still bind the body for diagnostics
            ResTypeOrd := "ALI TypeKind"::None;
            ResTypeArg := 0;
        end;
        ResultSlot := 0;

        ParamListNode := NEdges.Get(NFirstChild.Get(ProcNode) + 0);
        LocalsNode := NEdges.Get(NFirstChild.Get(ProcNode) + 2);

        Symbols.PushChildScope();

        // M11: the implicit `Rec` receiver is declared BEFORE the proc's own parameters, so
        // symbol order still matches descriptor-row order and AllocateProcSlots gives it slot 1.
        // The name is interned in THIS unit's token table — ids are per-table (§4.1).
        //
        // M11 phase B2: the instance index is declared ahead of both. Its name cannot collide
        // with anything the source can spell — no AL identifier starts with '$' — so it is
        // invisible to the harvested body and exists only to carry the caller's instance.
        if UnitHasObjGlobals then
            Sid := Symbols.Declare(Symbols.KindParam(), Tokens.InternIdentifier('$inst'),
                "ALI TypeKind"::Integer, 0, PId, 0);
        ImplicitRecSid := 0;
        if ObjectTableId <> 0 then begin
            EnsureTablePopulated(Tokens, ObjectTableId);
            ImplicitRecSid := Symbols.Declare(Symbols.KindVarParam(), Tokens.InternIdentifier('Rec'),
                "ALI TypeKind"::Record, ObjectTableId, PId, Symbols.FlagVarParam());
        end;

        // Params become symbols in the proc scope (declaration order = descriptor order).
        for k := 0 to NChildCnt.Get(ParamListNode) - 1 do begin
            ParamNode := NEdges.Get(NFirstChild.Get(ParamListNode) + k);
            ParamNameId := Ast.GetExtra(ParamNode) div 2;
            IsVar := (Ast.GetExtra(ParamNode) mod 2) = 1;
            Row := Symbols.ProcParamRow(PId, k + 1 + HiddenParamCount());
            // Row 0 = this body is being bound against a signature that does not describe it
            // (proc id from another overload, or a signature that never registered descriptors).
            // Reading the descriptor lists at 0 raises a raw AL "invalid argument was passed to a
            // method of data type List" from inside ParamRowType, killing the whole compile with
            // no diagnostic and no source position. Fail this ONE procedure instead: the
            // per-procedure sandbox marks it Blocked and only a call to it reports ALI922.
            if Row > 0 then begin
                RowT := Symbols.ParamRowType(Row);
                RowArg := Symbols.ParamRowTypeArg(Row);
            end else begin
                RowT := "ALI TypeKind"::ErrorType;
                RowArg := 0;
                Diags.AddError('ALI919', StrSubstNo('The signature of this procedure does not match its declaration (no descriptor for parameter ''%1'')', Tokens.GetIdentText(NMainTok.Get(ParamNode))), TokPos(Tokens, NMainTok.Get(ParamNode)), 0);
            end;
            if IsVar then begin
                SymKind := Symbols.KindVarParam();
                SymFlags := Symbols.FlagVarParam();
            end else begin
                SymKind := Symbols.KindParam();
                SymFlags := 0;
                // Byval `Rec: Record X temporary` param: carry the temporary flag onto the
                // symbol so the prologue's fresh handle opens a temp table (own empty
                // dataset — mirrors the native byval-temp gotcha; pass by var to share).
                if (RowT = "ALI TypeKind"::Record) and (Ast.GetExtra(NEdges.Get(NFirstChild.Get(ParamNode) + 0)) = 1) then
                    SymFlags := Symbols.FlagTemporary();
            end;
            Sid := Symbols.Declare(SymKind, ParamNameId, RowT, RowArg, PId, SymFlags);
            if Sid = 0 then
                Diags.AddError('AL0198', StrSubstNo('A parameter named ''%1'' is already defined in this scope', Tokens.GetIdentText(NMainTok.Get(ParamNode))), TokPos(Tokens, NMainTok.Get(ParamNode)), 0)
            else begin
                Ast.SetSymbolId(ParamNode, Sid);
                // A record PARAMETER is a declared variable too, so it owns an instance. For a
                // byval one that is exactly right (it is a copy). For `var` it is the documented
                // phase-B2 ceiling: the alias shares the caller's FIELDS but not the caller's
                // block of object globals — see the "ALI Object Registry" header.
                AssignInstance(Symbols, Sid, RowT, RowArg);
            end;
        end;

        // Named return value (child [4], §5.5): a local-var symbol of the proc's return
        // type. AllocateProcSlots aliases it onto the RESULT SLOT, so assignments to the
        // name write the return value directly and bare `exit`/fall-through return it.
        ResultVarSid := 0;
        if NChildCnt.Get(ProcNode) > 4 then begin
            RetVarNode := NEdges.Get(NFirstChild.Get(ProcNode) + 4);
            if not Ast.IsMissing(RetVarNode) then begin
                Sid := Symbols.Declare(Symbols.KindLocalVar(), Ast.GetExtra(RetVarNode), ResTypeOrd, ResTypeArg, PId, 0);
                if Sid = 0 then
                    Diags.AddError('AL0198', StrSubstNo('A variable named ''%1'' is already defined in this scope', Tokens.GetIdentText(NMainTok.Get(RetVarNode))), TokPos(Tokens, NMainTok.Get(RetVarNode)), 0)
                else begin
                    Ast.SetSymbolId(RetVarNode, Sid);
                    ResultVarSid := Sid;
                end;
            end;
        end;

        if not Ast.IsMissing(LocalsNode) then
            DeclareVarSection(Tokens, Ast, Symbols, Diags, LocalsNode, 1);

        // M11: every name this body can see is declared by now, so cross-object calls can be
        // resolved BEFORE the body binds — see HarvestObjectRefs for why that ordering matters.
        HarvestObjectRefs(Tokens, Ast, Symbols, Diags, Module, NEdges.Get(NFirstChild.Get(ProcNode) + 3));

        ClearFlowFieldUse();
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(ProcNode) + 3));
        ReportUncalcedFlowFields(Diags);
        Symbols.PopScope();

        AllocateProcSlots(Ast, Symbols, PId);

        Ast.SetTypeOrd(ProcNode, ResTypeOrd);
        Ast.SetSlotIndex(ProcNode, ResultSlot);
        if ProcSym > 0 then
            Symbols.SetSlot(ProcSym, ResultSlot);
    end;

    // ===== M11 cross-object pre-scan =====
    //
    // Walks a body BEFORE it is bound and harvests every object whose procedure it calls, so
    // that by the time BindRecordMethod reaches `Cust.CalcBalance(...)` the callee's signature
    // is already in the Symbol Table and resolution is a pure lookup.
    //
    // The ordering exists for one reason: harvesting COMPILES foreign source into the shared
    // Module, and the Module only reaches as far as Bind()/BindProcBody — threading it through
    // all of BindExpr would touch a couple of hundred signatures for a value 99% of them never
    // read. Running the harvest here keeps the expression binder untouched, because the
    // registry's cache-hit path needs no Module at all.
    //
    // ponytail: the receiver must be a plain VARIABLE (`Cust.Foo()`), which is also how the
    // ROADMAP scopes M11. An expression receiver (`GetCust().Foo()`, `Lines[i].Foo()`) has no
    // resolvable type before binding, so it is skipped here and still fails with ALI961 at bind
    // time. Upgrade path if that ever matters: thread `var Module` through the BindExpr chain
    // and resolve at the call site instead — this pre-scan then simply becomes dead code.
    local procedure HarvestObjectRefs(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; BodyNode: Integer)
    var
        Registry: Codeunit "ALI Object Registry";
        CalleeNode: Integer;
        i: Integer;
        Kind: Integer;
        Node: Integer;
        Pending: List of [Integer];
    begin
        if BodyNode <= 0 then
            exit;

        // Iterative walk (never recursive: an AST can nest to "ALI Limits".MaxNestingDepth and
        // AL's own stack is the one thing the interpreter cannot catch).
        Pending.Add(BodyNode);
        while Pending.Count() > 0 do begin
            Node := Pending.Get(Pending.Count());
            Pending.RemoveAt(Pending.Count());

            Kind := NKind.Get(Node);
            if (Kind = "ALI NodeKind"::InvocationExpr) or (Kind = "ALI NodeKind"::MemberAccessExpr) then begin
                // Parenthesised call: child 0 is the MemberAccessExpr callee. Paren-less call:
                // the MemberAccessExpr IS the node. Same shape both ways.
                CalleeNode := Node;
                if Kind = "ALI NodeKind"::InvocationExpr then
                    if NChildCnt.Get(Node) > 0 then
                        CalleeNode := NEdges.Get(NFirstChild.Get(Node) + 0);
                if NKind.Get(CalleeNode) = "ALI NodeKind"::MemberAccessExpr then
                    TryHarvestReceiverObject(Tokens, Ast, Symbols, Diags, Module, Registry, CalleeNode);
            end;

            for i := 0 to NChildCnt.Get(Node) - 1 do
                Pending.Add(NEdges.Get(NFirstChild.Get(Node) + i));
        end;
    end;

    // One `X.Member` callee: harvest table X's procedure `Member` when X is a record variable and
    // Member is neither a built-in record method nor one of the table's fields. Every miss is a
    // silent skip — this pass only warms the registry, it never decides anything. Diagnostics
    // belong to BindRecordMethod, which runs later and knows the call's real shape.
    local procedure TryHarvestReceiverObject(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; var Module: Codeunit "ALI Module"; var Registry: Codeunit "ALI Object Registry"; CalleeNode: Integer)
    var
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        MemberNameId: Integer;
        ProcSid: Integer;
        RecvNode: Integer;
        RecvSid: Integer;
        TableId: Integer;
        MemberName: Text;
    begin
        if NChildCnt.Get(CalleeNode) = 0 then
            exit;
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit;                                       // expression receiver — see the ceiling note
        RecvSid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if RecvSid = 0 then
            exit;

        MemberName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));

        // M11 phase C2: `MyCU.Proc(...)` — a codeunit variable. No fields and no built-in method
        // set to rule out first, so the member is always a procedure of that codeunit.
        if Symbols.GetType(RecvSid) = "ALI TypeKind"::CodeunitRef then begin
            // M11 phase C3: `MyCU.Run` is executed by the platform, so there is nothing to
            // harvest — this early exit IS the "do not parse OnRun" optimization on the instance
            // form. Every OTHER member is a real procedure call, which is what makes mixing the
            // two on one variable a state split (ALI928 in BindCodeunitProcCall).
            //
            // ponytail: the use set is filled by the pre-scan of the body being bound, so a
            // variable used for Run in one procedure and for calls in ANOTHER is not caught and
            // runs natively. Whole-unit detection would need the scan hoisted above the bind;
            // add it if a real script ever splits state that way.
            if UpperCase(MemberName) = 'RUN' then
                exit;
            // Native catalogue (`TypeHelper.UrlEncode`): called natively, never harvested — this is
            // what keeps a DotNet-backed codeunit from being parsed at all.
            if Builtins.IsNativeMethod(Symbols.GetTypeArg(RecvSid), UpperCase(MemberName)) then
                exit;
            if not CodeunitVarProcUse.Contains(RecvSid) then
                CodeunitVarProcUse.Add(RecvSid);
            Registry.TryBindObjectProc("ALI Object Type"::Codeunit.AsInteger(), Symbols.GetTypeArg(RecvSid), MemberName, Symbols, Module, Diags, ProcSid);
            exit;
        end;

        if Symbols.GetType(RecvSid) <> "ALI TypeKind"::Record then
            exit;

        if RecMethodId(UpperCase(MemberName)) <> 0 then
            exit;                                       // a built-in record method, not user code

        TableId := Symbols.GetTypeArg(RecvSid);
        MemberNameId := Ast.GetExtra(CalleeNode);
        EnsureTablePopulated(Tokens, TableId);
        if RecMeta.TryFieldInfo(TableId, MemberNameId, FNo, FType, FLen, FClass) then
            exit;                                       // a field of the table, not a call

        Registry.TryBindObjectProc("ALI Object Type"::Table.AsInteger(), TableId, MemberName, Symbols, Module, Diags, ProcSid);
    end;

    // ===== Declarations =====

    local procedure DeclareVarSection(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; SectionNode: Integer; ScopeKind: Integer)
    var
        DeclNode: Integer;
        i: Integer;
    begin
        for i := 0 to NChildCnt.Get(SectionNode) - 1 do begin
            DeclNode := NEdges.Get(NFirstChild.Get(SectionNode) + i);
            if NKind.Get(DeclNode) = "ALI NodeKind"::VarDecl then
                DeclareVar(Tokens, Ast, Symbols, Diags, DeclNode, ScopeKind);
        end;
    end;

    // VarDecl children (§5.5): [0]=typeRef, [1]=initExpr|Missing. ExtraInt = NameId.
    local procedure DeclareVar(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; DeclNode: Integer; ScopeKind: Integer)
    var
        DiagMark: Integer;
        InitNode: Integer;
        NameId: Integer;
        Sid: Integer;
        SymFlags: Integer;
        SymKind: Integer;
        T: Integer;
        TArg: Integer;
        TypeNode: Integer;
    begin
        TypeNode := NEdges.Get(NFirstChild.Get(DeclNode) + 0);
        InitNode := NEdges.Get(NFirstChild.Get(DeclNode) + 1);
        NameId := Ast.GetExtra(DeclNode);
        DiagMark := Diags.Count();
        DeclNameHint := Tokens.GetIdentText(NMainTok.Get(DeclNode));
        T := ResolveTypeRef(Tokens, Ast, Diags, TypeNode, TArg);
        DeclNameHint := '';

        // M11 phase B: a harvested OBJECT's var block is real table source, so it routinely
        // declares types the interpreter has no representation for (Codeunit, Report, DotNet…).
        // Object declarations are unit-level, i.e. OUTSIDE any procedure's diagnostic sandbox —
        // one of them would otherwise sink the whole object. Drop the declaration instead: every
        // procedure that touches the name then fails with AL0118 and blocks only ITSELF, and the
        // procedures that never mention it compile as usual.
        if IsolateProcErrors and (ScopeKind = 0) and (T = "ALI TypeKind"::ErrorType) then begin
            Diags.TruncateTo(DiagMark);
            exit;
        end;

        if not Ast.IsMissing(InitNode) then
            Diags.AddError('ALI935', 'Variable initializers are not part of the AL language', TokPos(Tokens, NMainTok.Get(DeclNode)), 0);

        if ScopeKind = 0 then
            SymKind := Symbols.KindGlobalVar()
        else
            SymKind := Symbols.KindLocalVar();

        SymFlags := 0;
        if (T = "ALI TypeKind"::Record) and (Ast.GetExtra(TypeNode) = 1) then
            SymFlags := Symbols.FlagTemporary();

        Sid := Symbols.Declare(SymKind, NameId, T, TArg, CurProcId, SymFlags);
        if Sid = 0 then
            Diags.AddError('AL0198', StrSubstNo('A variable named ''%1'' is already defined in this scope', Tokens.GetIdentText(NMainTok.Get(DeclNode))), TokPos(Tokens, NMainTok.Get(DeclNode)), 0)
        else begin
            Ast.SetSymbolId(DeclNode, Sid);
            // M11 phase B2: a global of a HARVESTED object is stored per instance of that object,
            // not once per run — tag its owner here, and its SlotIndex becomes an offset inside
            // the object's block (AllocateGlobalSlots).
            if (ScopeKind = 0) and (CurObjKey <> 0) then
                Symbols.SetOwnerObjKey(Sid, CurObjKey);
            AssignInstance(Symbols, Sid, T, TArg);
            if T = "ALI TypeKind"::Array then
                Symbols.SetArrayDims(Sid, LastArrayDims);
            if (T = "ALI TypeKind"::Array) or (T = "ALI TypeKind"::List) or (T = "ALI TypeKind"::Dictionary) then
                Symbols.SetElemChk(Sid, LastElemChk);
            if T = "ALI TypeKind"::Label then
                Symbols.SetLabelText(Sid, LastLabelText);
        end;
    end;

    // ===== §19.1 early type verification =====
    // Resolve a TypeRef node to ("ALI TypeKind" ordinal, TypeArg length), classifying it
    // against the §19.2 matrix. Rejected-known / Unknown / not-yet-supported RefShim types
    // AddError with a precise position and CONTINUE with ErrorType (collect-all rule).
    local procedure ResolveTypeRef(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; TypeNode: Integer; var TArg: Integer): Integer
    var
        Anchor: Integer;
        K: Integer;
        T: Integer;
        UpperName: Text;
    begin
        TArg := 0;
        LastElemChk := 0;
        Anchor := NMainTok.Get(TypeNode);
        if Anchor = 0 then begin
            Ast.SetTypeOrd(TypeNode, "ALI TypeKind"::ErrorType);
            exit("ALI TypeKind"::ErrorType);
        end;
        K := Tokens.GetKind(Anchor);

        case true of
            (K = 135):  // ArrayKeyword — array[N] of ElemType (1-D, §1.1)
                T := ResolveArrayType(Tokens, Ast, Diags, TypeNode, Anchor, TArg);
            (K = 144):  // DotNetKeyword (§18.3 rejected-known)
                begin
                    Diags.AddError('ALI924', DotNetGateText(), TokPos(Tokens, Anchor), 0);
                    T := "ALI TypeKind"::ErrorType;
                end;
            (K = 138):  // Codeunit "X" as a variable type (M11 phase C1)
                T := ResolveCodeunitType(Tokens, Diags, Anchor, TArg);
            (K = 139) or (K = 140):  // Table / Page keyword as type
                begin
                    Diags.AddError('ALI927', 'Object-reference variables are not yet supported', TokPos(Tokens, Anchor), 0);
                    T := "ALI TypeKind"::ErrorType;
                end;
            (K = 20):   // IdentifierToken — the normal path
                begin
                    UpperName := UpperCase(Tokens.GetIdentText(Anchor));
                    T := TypeFromName(UpperName);
                    case true of
                        (T <> "ALI TypeKind"::None):

                            // Text[n]/Code[n] length (0 = unbounded Text; Code requires one).
                            if (T = "ALI TypeKind"::Text) or (T = "ALI TypeKind"::Code) then
                                TArg := ReadLengthSuffix(Tokens, Diags, Anchor, T = "ALI TypeKind"::Code);
                        (UpperName = 'RECORD'):
                            T := ResolveRecordType(Tokens, Diags, Anchor, TArg);
                        (UpperName = 'ENUM'):
                            T := ResolveEnumType(Tokens, Diags, Anchor, TArg);
                        (UpperName = 'OPTION'):
                            begin
                                TArg := OptionMeta.InternInlineSet(CollectOptionMembers(Tokens, Anchor));
                                T := "ALI TypeKind"::Option;
                            end;
                        (UpperName = 'LABEL'):
                            T := ResolveLabelType(Tokens, Diags, Anchor);
                        (UpperName = 'VARIANT'):
                            T := "ALI TypeKind"::Variant;
                        (UpperName = 'DIALOG'):
                            T := "ALI TypeKind"::Dialog;
                        (UpperName = 'INSTREAM'):
                            T := "ALI TypeKind"::InStream;      // M6 §19.7 (real, temp-Blob backed)
                        (UpperName = 'OUTSTREAM'):
                            T := "ALI TypeKind"::OutStream;
                        (UpperName = 'TEXTBUILDER'):
                            T := "ALI TypeKind"::TextBuilder;   // M9: own handle space, §19.7-style
                        (UpperName = 'BIGTEXT'):
                            T := "ALI TypeKind"::BigText;       // own handle space, TextBuilder scheme
                        (UpperName = 'SECRETTEXT'):
                            T := "ALI TypeKind"::SecretText;    // Text register file; secrecy is bind-time only
                        (UpperName = 'RECORDREF'):
                            // P0: the SAME Int handle a Record variable carries, into the SAME
                            // "ALI Rec Runtime" bank — only the table id (TypeArg) is unknown at
                            // bind time, which is why there is no static field access on one and
                            // why a LOCAL RecordRef gets NO handle at proc entry (Open() gives it
                            // one; before that every use raises ALI937).
                            T := "ALI TypeKind"::RecordRef;
                        (UpperName = 'FIELDREF'):
                            // P2: an Int register holding the PACKED PAIR (recHandle, fieldNo) —
                            // no native FieldRef is ever stored (see "ALI Opcode"::FLD_METHOD).
                            // Like a RecordRef it starts UNBOUND (handle 0); Field()/FieldIndex()
                            // on an open RecordRef binds it, and any use before that is ALI938.
                            T := "ALI TypeKind"::FieldRef;
                        (UpperName = 'KEYREF'):
                            // P3: the same packing with a key index instead of a field number.
                            T := "ALI TypeKind"::KeyRef;
                        (UpperName = 'LIST'):
                            T := ResolveListType(Tokens, Diags, Anchor, TArg);
                        (UpperName = 'DICTIONARY'):
                            T := ResolveDictType(Tokens, Diags, Anchor, TArg);
                        (UpperName = 'HTTPCLIENT'):
                            T := "ALI TypeKind"::HttpClient;        // M10: Int-handle RefShim (List/Dict scheme)
                        (UpperName = 'HTTPREQUESTMESSAGE'):
                            T := "ALI TypeKind"::HttpRequestMessage;
                        (UpperName = 'HTTPRESPONSEMESSAGE'):
                            T := "ALI TypeKind"::HttpResponseMessage;
                        (UpperName = 'HTTPCONTENT'):
                            T := "ALI TypeKind"::HttpContent;
                        (UpperName = 'HTTPHEADERS'):
                            T := "ALI TypeKind"::HttpHeaders;
                        (UpperName = 'JSONOBJECT'):
                            T := "ALI TypeKind"::JsonObject;        // Feature 2: Int-handle RefShim, unified bank
                        (UpperName = 'JSONARRAY'):
                            T := "ALI TypeKind"::JsonArray;
                        (UpperName = 'JSONTOKEN'):
                            T := "ALI TypeKind"::JsonToken;
                        (UpperName = 'JSONVALUE'):
                            T := "ALI TypeKind"::JsonValue;
                        (UpperName = 'XMLDOCUMENT'):
                            T := "ALI TypeKind"::XmlDocument;       // Feature 3: Int-handle RefShim, unified node bank (XML_DESIGN.md §1)
                        (UpperName = 'XMLNODE'):
                            T := "ALI TypeKind"::XmlNode;
                        (UpperName = 'XMLELEMENT'):
                            T := "ALI TypeKind"::XmlElement;
                        (UpperName = 'XMLATTRIBUTE'):
                            T := "ALI TypeKind"::XmlAttribute;
                        (UpperName = 'XMLNODELIST'):
                            T := "ALI TypeKind"::XmlNodeList;
                        (UpperName = 'XMLATTRIBUTECOLLECTION'):
                            T := "ALI TypeKind"::XmlAttributeCollection;
                        (UpperName = 'XMLCOMMENT'):
                            T := "ALI TypeKind"::XmlComment;
                        (UpperName = 'XMLCDATA'):
                            T := "ALI TypeKind"::XmlCData;
                        (UpperName = 'XMLDECLARATION'):
                            T := "ALI TypeKind"::XmlDeclaration;
                        (UpperName = 'XMLDOCUMENTTYPE'):
                            T := "ALI TypeKind"::XmlDocumentType;
                        (UpperName = 'XMLTEXT'):
                            T := "ALI TypeKind"::XmlText;
                        (UpperName = 'XMLPROCESSINGINSTRUCTION'):
                            T := "ALI TypeKind"::XmlProcessingInstruction;
                        (UpperName = 'XMLNAMESPACEMANAGER'):
                            T := "ALI TypeKind"::XmlNamespaceManager;
                        (UpperName = 'XMLREADOPTIONS'):
                            T := "ALI TypeKind"::XmlReadOptions;
                        (UpperName = 'XMLWRITEOPTIONS'):
                            T := "ALI TypeKind"::XmlWriteOptions;
                        (UpperName = 'XMLNAMETABLE'):
                            T := "ALI TypeKind"::XmlNameTable;
                        // Built-in system option types (TextEncoding, IsolationLevel, ...) as a
                        // variable type — same inline set `::` access already interns, so
                        // `E: TextEncoding; E := TextEncoding::UTF8` shares one SetId.
                        TrySystemOptionSet(UpperName, TArg):
                            T := "ALI TypeKind"::Option;
                        IsRejectedKnownType(UpperName):
                            begin
                                Diags.AddError('ALI924', StrSubstNo('The type ''%1'' is not supported by the interpreter (v1)', Tokens.GetIdentText(Anchor)), TokPos(Tokens, Anchor), 0);
                                T := "ALI TypeKind"::ErrorType;
                            end;
                        else begin
                            Diags.AddError('ALI925', StrSubstNo('Unknown type ''%1''', Tokens.GetIdentText(Anchor)), TokPos(Tokens, Anchor), 0);
                            T := "ALI TypeKind"::ErrorType;
                        end;
                    end;
                end;
            else begin
                Diags.AddError('ALI925', 'Type name expected', TokPos(Tokens, Anchor), 0);
                T := "ALI TypeKind"::ErrorType;
            end;
        end;

        Ast.SetTypeOrd(TypeNode, T);
        exit(T);
    end;

    // M11 DotNet gate. A DotNet variable is reference-unrepresentable, so the DECLARATION is
    // what fails — and inside a harvested object that failure is swallowed (DeclareVar drops the
    // declaration, the procedures that mention the name block on their own AL0118). Naming the
    // declaration is therefore the only thing that makes the cause findable: the reader sees
    // which variable to remove or replace, not just that "something" used DotNet.
    local procedure DotNetGateText(): Text
    begin
        if DeclNameHint = '' then
            exit('DotNet is not supported by the interpreter (reference-unrepresentable)');
        exit(StrSubstNo('''%1'' is declared as DotNet, which the interpreter cannot represent (reference-unrepresentable)', DeclNameHint));
    end;

    // Label 'text' [, Comment = '...', Locked = true, MaxLength = n] (§19.2). A Label is a
    // compile-time text constant: the mandatory string literal follows the `Label` keyword
    // (Anchor). Stash its text in LastLabelText for DeclareVar to attach to the SymbolId; the
    // lowerer folds every read to a LOAD_CONST_T (no runtime slot). Missing string -> error.
    local procedure ResolveLabelType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer): Integer
    begin
        LastLabelText := '';
        if Tokens.GetKind(Anchor + 1) <> 16 then begin      // StringLiteralToken
            Diags.AddError('ALI939', 'A Label declaration requires a text constant', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        LastLabelText := Tokens.GetText(Tokens.GetValueIndex(Anchor + 1));
        exit("ALI TypeKind"::Label);
    end;

    // ===== M6 aggregate type resolution =====

    // array[N1, N2, ..., Nk] of ElemType. Anchor = 'array'. Token layout: array [ N1 , N2 , ... ]
    // of ElemName. Returns TArray with TArg packed as ElemTypeOrd * ArrayStride + TotalN
    // (TotalN = product of all dimension sizes, §20.4; ElemType must be a register-class
    // primitive; nested arrays / RefShim elements are rejected §19.1). Per-dimension sizes are
    // stashed in LastArrayDims for the caller (DeclareVar) to attach to the array's SymbolId
    // via Symbols.SetArrayDims — a single Integer TArg cannot hold up to 10 dimension sizes.
    local procedure ResolveArrayType(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; TypeNode: Integer; Anchor: Integer; var TArg: Integer): Integer
    var
        Dn: Integer;
        ElemArg: Integer;
        ElemT: Integer;
        ElemTok: Integer;
        i: Integer;
        TotalN: Integer;
        ElemName: Text;
    begin
        TArg := 0;
        Clear(LastArrayDims);
        // dimension sizes: every Int32 literal between the anchor and the matching ']'
        // (commas are simply skipped — no separate arity token needed, §20.8).
        for i := Anchor + 1 to Tokens.Count() do begin
            if Tokens.GetKind(i) = 73 then               // CloseBracketToken
                break;
            if Tokens.GetKind(i) = 104 then               // OfKeyword reached without ']'
                break;
            if Tokens.GetKind(i) = 10 then begin          // Int32LiteralToken
                Dn := Tokens.GetInt(Tokens.GetValueIndex(i));
                if (Dn < 1) or (Dn > 1000000) then begin
                    Diags.AddError('ALI958', StrSubstNo('Array dimension size must be between 1 and 1000000 (got %1)', Dn), TokPos(Tokens, Anchor), 0);
                    exit("ALI TypeKind"::ErrorType);
                end;
                LastArrayDims.Add(Dn);
            end;
        end;
        if (LastArrayDims.Count() < 1) or (LastArrayDims.Count() > 10) then begin
            Diags.AddError('ALI958', StrSubstNo('Array rank must be between 1 and 10 (got %1)', LastArrayDims.Count()), TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TotalN := 1;
        foreach Dn in LastArrayDims do
            TotalN := TotalN * Dn;
        if (TotalN < 1) or (TotalN > 1000000) then begin
            Diags.AddError('ALI958', StrSubstNo('Total array element count must be between 1 and 1000000 (got %1)', TotalN), TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        // element type name: first identifier AFTER the 'of' keyword.
        ElemTok := 0;
        for i := Anchor + 1 to Tokens.Count() do
            if Tokens.GetKind(i) = 104 then begin        // OfKeyword
                if i + 1 <= Tokens.Count() then
                    if Tokens.GetKind(i + 1) = 20 then
                        ElemTok := i + 1;
                break;
            end;
        if ElemTok = 0 then begin
            Diags.AddError('ALI958', 'Array element type expected after ''of''', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        ElemName := UpperCase(Tokens.GetIdentText(ElemTok));
        ElemT := TypeFromName(ElemName);
        if ElemT = "ALI TypeKind"::None then begin
            Diags.AddError('ALI958', StrSubstNo('Array element type ''%1'' is not a supported primitive', Tokens.GetIdentText(ElemTok)), TokPos(Tokens, ElemTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        if TypeRules.RegClassFor(ElemT) = 0 then begin
            Diags.AddError('ALI958', 'Array elements must be a register-class primitive type', TokPos(Tokens, ElemTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        // Text[n]/Code[n] element length is not modelled per-element in M6 — store unbounded.
        ElemArg := 0;
        if (ElemT = "ALI TypeKind"::Text) or (ElemT = "ALI TypeKind"::Code) then begin
            ElemArg := ReadLengthSuffix(Tokens, Diags, ElemTok, ElemT = "ALI TypeKind"::Code);
            // Element width rides in ElemChk (Length*2 + IsCode), enforced at ARR_STORE.
            if ElemT = "ALI TypeKind"::Code then
                LastElemChk := ElemArg * 2 + 1
            else
                LastElemChk := ElemArg * 2;
        end;

        // Pack (elemType, TotalN); the element WIDTH is carried in ElemChk (side-table), not TArg.
        TArg := ElemT * ArrayStride() + TotalN;
        exit("ALI TypeKind"::Array);
    end;

    // List of [ElemType] (ListDictionaryPlan.md §3.1/§4.1). Anchor = 'List' identifier;
    // no parser/AST change needed — re-scan tokens after Anchor for the identifier inside
    // 'of [ ... ]'. NOTE: unlike array[N] of ElemType (brackets wrap the SIZE, BEFORE 'of'),
    // native List/Dictionary syntax wraps the TYPE ARGUMENT(S) in brackets AFTER 'of' — the
    // element identifier is the token AFTER '[', not directly after 'of'. TArg = elemClass,
    // where elemClass IS the "ALI Type Rules" RegClass* ordinal (1..10) — no separate
    // class-numbering scheme. Unsupported elements (Variant/Record/List/Dictionary/RefShim/
    // unknown) all fall out of TypeFromName() as TNone() and get ONE precise ALI984.
    local procedure ResolveListType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; var TArg: Integer): Integer
    var
        ElemCls: Integer;
        ElemLen: Integer;
        ElemT: Integer;
        ElemTok: Integer;
        i: Integer;
    begin
        TArg := 0;
        ElemTok := 0;
        for i := Anchor + 1 to Tokens.Count() do
            if Tokens.GetKind(i) = 104 then begin        // OfKeyword
                if i + 1 <= Tokens.Count() then
                    if Tokens.GetKind(i + 1) = 72 then    // OpenBracketToken '['
                        if i + 2 <= Tokens.Count() then
                            if Tokens.GetKind(i + 2) = 20 then  // IdentifierToken
                                ElemTok := i + 2;
                break;
            end;
        if ElemTok = 0 then begin
            Diags.AddError('ALI984', 'List element type expected after ''of [''', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        ElemT := TypeFromName(UpperCase(Tokens.GetIdentText(ElemTok)));
        // RecordID (§ RecordID) has its own RegClass but is NOT a supported List element:
        // ExecListOp boxes elements through ReadRegisterAsVariant/WriteRegisterFromVariant,
        // which have no RecordID case — silently dropping the value. Reject explicitly rather
        // than let it fall through as "supported".
        if (ElemT = "ALI TypeKind"::None) or (ElemT = "ALI TypeKind"::RecordID) then begin
            Diags.AddError('ALI984', StrSubstNo('List element type ''%1'' is not supported (Integer, BigInteger, Decimal, Boolean, Text, Date, Time, DateTime, Duration, Guid only)', Tokens.GetIdentText(ElemTok)), TokPos(Tokens, ElemTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        ElemCls := TypeRules.RegClassFor(ElemT);
        if ElemCls = 0 then begin
            Diags.AddError('ALI984', 'List element type is not a register-class primitive', TokPos(Tokens, ElemTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        // Validate + capture the Text[n]/Code[n] element length (rejects Text[0]/negative/>2048,
        // Code without a length) and stash its STORE_TEXT_CHK operand for runtime enforcement of
        // values entering the list (LowerListMethod). ElemCls alone loses the width and Code-ness.
        if (ElemT = "ALI TypeKind"::Text) or (ElemT = "ALI TypeKind"::Code) then begin
            ElemLen := ReadLengthSuffix(Tokens, Diags, ElemTok, ElemT = "ALI TypeKind"::Code);
            if ElemT = "ALI TypeKind"::Code then
                LastElemChk := ElemLen * 2 + 1
            else
                LastElemChk := ElemLen * 2;
        end;
        TArg := ElemCls;
        exit("ALI TypeKind"::List);
    end;

    // Dictionary of [KeyType, ValueType]. Anchor = 'Dictionary' identifier; scan for the two
    // identifiers inside 'of [ K, V ]' — the bracket wraps the (K,V) pair AFTER 'of' (same
    // native-syntax note as ResolveListType: NOT the array[N]-style bracket-before-'of'
    // shape). Keys restricted to Integer class / Text class (ALI984); values allow the full
    // List/Dictionary register-class set. TArg = keyClass*16 + valueClass (both RegClass*
    // ordinals, max 10 -> no collision at *16).
    local procedure ResolveDictType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; var TArg: Integer): Integer
    var
        i: Integer;
        KeyCls: Integer;
        KeyLen: Integer;
        KeyT: Integer;
        KeyTok: Integer;
        OfTok: Integer;
        ValCls: Integer;
        ValLen: Integer;
        ValT: Integer;
        ValTok: Integer;
    begin
        TArg := 0;
        OfTok := 0;
        for i := Anchor + 1 to Tokens.Count() do
            if Tokens.GetKind(i) = 104 then begin        // OfKeyword
                OfTok := i;
                break;
            end;
        if OfTok = 0 then begin
            Diags.AddError('ALI984', 'Dictionary key/value types expected after ''of''', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        KeyTok := 0;
        if OfTok + 1 <= Tokens.Count() then
            if Tokens.GetKind(OfTok + 1) = 72 then       // OpenBracketToken '['
                if OfTok + 2 <= Tokens.Count() then
                    if Tokens.GetKind(OfTok + 2) = 20 then    // IdentifierToken
                        KeyTok := OfTok + 2;
        if KeyTok = 0 then begin
            Diags.AddError('ALI984', 'Dictionary key type expected after ''of [''', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        ValTok := 0;
        for i := KeyTok + 1 to Tokens.Count() do
            if Tokens.GetKind(i) = 76 then begin         // CommaToken
                if i + 1 <= Tokens.Count() then
                    if Tokens.GetKind(i + 1) = 20 then    // IdentifierToken
                        ValTok := i + 1;
                break;
            end;
        if ValTok = 0 then begin
            Diags.AddError('ALI984', 'Dictionary value type expected after '',''', TokPos(Tokens, KeyTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        KeyT := TypeFromName(UpperCase(Tokens.GetIdentText(KeyTok)));
        KeyCls := TypeRules.RegClassFor(KeyT);
        if (KeyCls <> "ALI Register Class"::Int) and (KeyCls <> "ALI Register Class"::"Text") then begin
            Diags.AddError('ALI984', StrSubstNo('Dictionary key type ''%1'' is not supported (Integer or Text class only)', Tokens.GetIdentText(KeyTok)), TokPos(Tokens, KeyTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        // Validate the key's Text[n]/Code[n] length (rejects Text[0]/negative/>2048, Code without
        // a length). ponytail: key length is not runtime-enforced (silently truncating/upper-casing
        // a key would change lookup identity) — validation only; add key STORE_TEXT_CHK if needed.
        if (KeyT = "ALI TypeKind"::Text) or (KeyT = "ALI TypeKind"::Code) then
            KeyLen := ReadLengthSuffix(Tokens, Diags, KeyTok, KeyT = "ALI TypeKind"::Code);

        ValT := TypeFromName(UpperCase(Tokens.GetIdentText(ValTok)));
        // RecordID excluded for the same reason as List elements (see ResolveListType).
        if (ValT = "ALI TypeKind"::None) or (ValT = "ALI TypeKind"::RecordID) then begin
            Diags.AddError('ALI984', StrSubstNo('Dictionary value type ''%1'' is not supported (Integer, BigInteger, Decimal, Boolean, Text, Date, Time, DateTime, Duration, Guid only)', Tokens.GetIdentText(ValTok)), TokPos(Tokens, ValTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        ValCls := TypeRules.RegClassFor(ValT);
        if ValCls = 0 then begin
            Diags.AddError('ALI984', 'Dictionary value type is not a register-class primitive', TokPos(Tokens, ValTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        // Validate + capture the value's Text[n]/Code[n] length for runtime enforcement of values
        // entering the dictionary (LowerDictMethod, Add/Set), same as List elements above.
        if (ValT = "ALI TypeKind"::Text) or (ValT = "ALI TypeKind"::Code) then begin
            ValLen := ReadLengthSuffix(Tokens, Diags, ValTok, ValT = "ALI TypeKind"::Code);
            if ValT = "ALI TypeKind"::Code then
                LastElemChk := ValLen * 2 + 1
            else
                LastElemChk := ValLen * 2;
        end;

        TArg := KeyCls * 16 + ValCls;
        exit("ALI TypeKind"::Dictionary);
    end;

    // Record "Table" / Record Table. Anchor = 'Record' identifier; subtype at Anchor+1
    // (identifier or quoted string literal). Resolves the table id via RecMeta and memoizes
    // its fields. TArg = table id. Unknown table -> §19.1 error, ErrorType.
    local procedure ResolveRecordType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; var TArg: Integer): Integer
    var
        SubKind: Integer;
        SubTok: Integer;
        TableId: Integer;
        TableName: Text;
    begin
        TArg := 0;
        SubTok := Anchor + 1;
        if SubTok > Tokens.Count() then begin
            Diags.AddError('ALI959', 'A record subtype (table name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        SubKind := Tokens.GetKind(SubTok);
        if (SubKind <> 20) and (SubKind <> 16) then begin   // identifier or string literal
            Diags.AddError('ALI959', 'A record subtype (table name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TableName := Tokens.GetIdentText(SubTok);

        if not RecMeta.ResolveTableIdByName(TableName, TableId) then begin
            Diags.AddError('ALI959', StrSubstNo('Table ''%1'' does not exist', TableName) + SuggestFrom(TableName, SuggestCatalog.TableNames()), TokPos(Tokens, SubTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        EnsureTablePopulated(Tokens, TableId);
        TArg := TableId;
        exit("ALI TypeKind"::Record);
    end;

    // M11 phase C1: `Codeunit "X"` (variable / parameter / object global). Anchor = the reserved
    // `codeunit` keyword, subtype at Anchor+1 (identifier or quoted string). TArg = object id.
    //
    // A codeunit variable carries NO runtime state and therefore NO register: RegClassFor returns
    // 0 for CodeunitRef, and every slot allocator skips class 0. Phase B2's per-instance globals
    // did not change that: the instance a variable owns is decided at COMPILE time (AssignInstance
    // gives every declared Record/Codeunit variable an index) and travels as a hidden argument, so
    // the variable itself still costs nothing at runtime.
    local procedure ResolveCodeunitType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; var TArg: Integer): Integer
    var
        CodeunitId: Integer;
        SubKind: Integer;
        SubTok: Integer;
        CodeunitName: Text;
    begin
        TArg := 0;
        SubTok := Anchor + 1;
        if SubTok > Tokens.Count() then begin
            Diags.AddError('ALI959', 'A codeunit subtype (codeunit name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        SubKind := Tokens.GetKind(SubTok);
        if (SubKind <> 20) and (SubKind <> 16) then begin   // identifier or string literal
            Diags.AddError('ALI959', 'A codeunit subtype (codeunit name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        CodeunitName := Tokens.GetIdentText(SubTok);

        if not TryResolveObjectId('Codeunit', CodeunitName, CodeunitId) then begin
            Diags.AddError('ALI959', StrSubstNo('Codeunit ''%1'' does not exist', CodeunitName) + SuggestFrom(CodeunitName, SuggestCatalog.CodeunitNames()), TokPos(Tokens, SubTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TArg := CodeunitId;
        // A codeunit whose state must live between calls (Data Compression's open archive) is a
        // handle to a real platform instance in "ALI Native Runtime" — see TypeKind NativeCodeunit.
        if Builtins.IsStatefulNative(CodeunitId) then
            exit("ALI TypeKind"::NativeCodeunit);
        exit("ALI TypeKind"::CodeunitRef);
    end;

    // Inline option string (Option A,B,"C c") — structure-only parse (§ v1 philosophy): the
    // parser only re-synced the token stream past the comma-separated member list; the
    // ACTUAL member names are re-derived here from the raw token span starting right after
    // the 'Option' anchor. A quoted member lexes as a single StringLiteralToken; an empty
    // slot between two commas (`Option ,One,Two`) yields ''. Always at least one entry
    // (native AL requires an option to declare at least one member).
    local procedure CollectOptionMembers(var Tokens: Codeunit "ALI Token Table"; Anchor: Integer) Names: List of [Text]
    var
        Done: Boolean;
        i: Integer;
    begin
        i := Anchor + 1;
        repeat
            if (Tokens.GetKind(i) = 20) or (Tokens.GetKind(i) = 16) or ((Tokens.GetKind(i) >= 130) and (Tokens.GetKind(i) <= 145)) then begin  // Identifier / StringLiteral / keyword member (`Option Table,Page`)
                Names.Add(MemberName(Tokens, i));
                i += 1;
            end else
                Names.Add('');
            if Tokens.GetKind(i) = 76 then  // CommaToken
                i += 1
            else
                Done := true;
        until Done;
    end;

    // Enum "X" (local variable / parameter). Anchor = 'ENUM' identifier; subtype at Anchor+1
    // (identifier or quoted string). Resolves the object id via AllObjWithCaption (same
    // resolver §19.6 object-id access uses) and interns the set. Unknown enum -> ALI984
    // (reusing the existing "object does not exist" code, §19.6 precedent).
    local procedure ResolveEnumType(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; var TArg: Integer): Integer
    var
        EnumId: Integer;
        SubKind: Integer;
        SubTok: Integer;
        EnumName: Text;
    begin
        TArg := 0;
        SubTok := Anchor + 1;
        if SubTok > Tokens.Count() then begin
            Diags.AddError('ALI959', 'An enum subtype (enum name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        SubKind := Tokens.GetKind(SubTok);
        if (SubKind <> 20) and (SubKind <> 16) then begin
            Diags.AddError('ALI959', 'An enum subtype (enum name) is required', TokPos(Tokens, Anchor), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        EnumName := Tokens.GetIdentText(SubTok);
        if not TryResolveObjectId('Enum', EnumName, EnumId) then begin
            Diags.AddError('ALI984', StrSubstNo('Enum ''%1'' does not exist', EnumName), TokPos(Tokens, SubTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TArg := OptionMeta.InternEnum(EnumId);
        exit("ALI TypeKind"::Enum);
    end;

    // Enumerate a table's fields once and memorize (RecMeta) keyed on the INTERNED field-name
    // pool index (so a Rec.Field member-access NameId matches by integer, §4.1). Field type
    // is mapped native -> "ALI TypeKind"; unsupported field types are stored as ErrorType
    // (a read of that field then errors precisely at the access site, not here).
    local procedure EnsureTablePopulated(var Tokens: Codeunit "ALI Token Table"; TableId: Integer)
    var
        Cnt: Integer;
        i: Integer;
        NameId: Integer;
        TKind: Integer;
        FldClasses: List of [Integer];
        FldLens: List of [Integer];
        FldNativeTypes: List of [Integer];
        FldNos: List of [Integer];
        FldNames: List of [Text];
    begin
        if PopulatedTables.Contains(TableId) then
            exit;
        PopulatedTables.Add(TableId);
        RecMeta.RegisterTable(UpperCase(TableIdName(TableId)), TableId);
        Cnt := RecMeta.EnumerateFields(TableId, FldNos, FldNames, FldNativeTypes, FldLens, FldClasses);
        for i := 1 to Cnt do begin
            NameId := Tokens.InternIdentifier(FldNames.Get(i));
            TKind := TypeRules.FieldTypeToTypeKind(FldNativeTypes.Get(i));
            if TKind = "ALI TypeKind"::None then
                TKind := "ALI TypeKind"::ErrorType;
            RecMeta.RegisterField(TableId, NameId, FldNos.Get(i), TKind, FldLens.Get(i), FldClasses.Get(i));
        end;
    end;

    // A table's object name (for the RecMeta name map — informational). We already resolved
    // by name; reuse a lightweight AllObj lookup only when needed. Cheap enough at bind time.
    local procedure TableIdName(TableId: Integer): Text
    var
        AllObj: Record AllObjWithCaption;
    begin
        if AllObj.Get(AllObj."Object Type"::Table, TableId) then
            exit(AllObj."Object Name");
        exit(Format(TableId));
    end;

    // Packing stride for array (elemType, N): elemType < ~90, N <= 65535. Stride 1e6 keeps
    // the packed value inside Int32 and cleanly separable.
    local procedure ArrayStride(): Integer
    begin
        exit(1000000);
    end;

    local procedure TypeFromName(UpperName: Text): Integer
    begin
        case UpperName of
            'INTEGER':
                exit("ALI TypeKind"::Integer);
            'BIGINTEGER':
                exit("ALI TypeKind"::BigInteger);
            'DECIMAL':
                exit("ALI TypeKind"::Decimal);
            'CHAR':
                exit("ALI TypeKind"::Char);
            'BYTE':
                exit("ALI TypeKind"::Byte);
            'BOOLEAN':
                exit("ALI TypeKind"::Boolean);
            'TEXT':
                exit("ALI TypeKind"::Text);
            'CODE':
                exit("ALI TypeKind"::Code);
            'DATE':
                exit("ALI TypeKind"::Date);
            'TIME':
                exit("ALI TypeKind"::Time);
            'DATETIME':
                exit("ALI TypeKind"::DateTime);
            'DURATION':
                exit("ALI TypeKind"::Duration);
            'DATEFORMULA':
                exit("ALI TypeKind"::DateFormula);
            'GUID':
                exit("ALI TypeKind"::Guid);
            'RECORDID':
                exit("ALI TypeKind"::RecordID);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // Recognized-but-v1-rejected type names (§19.2) — precise message instead of "unknown".
    // (The old IsRefShimType gate died with the P2 pass: it held nothing but FieldRef/KeyRef,
    // and both now resolve as real packed-pair Int-handle types in the TypeFromName cascade
    // above — RecordRef had already left it in P0. InStream/OutStream are real RefShim types
    // handled earlier, §19.7.)
    local procedure IsRejectedKnownType(UpperName: Text): Boolean
    begin
        // Xml* names left this list in Feature 3 (XML_DESIGN.md) — they resolve as real
        // Int-handle RefShim types in the TypeFromName fallback case above.
        // BigText left this list once it got a real handle bank. Media/MediaSet stay: native alc
        // itself rejects them as variable types (AL0157) — they only exist as table field types.
        exit((UpperName = 'MEDIA') or (UpperName = 'NOTIFICATION') or
             (UpperName = 'MEDIASET') or (UpperName = 'BLOB') or (UpperName = 'INTERFACE') or
             (UpperName = 'DOTNET') or
             (UpperName = 'TESTPAGE') or (UpperName = 'REPORT') or (UpperName = 'XMLPORT') or
             (UpperName = 'QUERY'));
    end;

    // Text[30]: anchor is the type-name token; tokens anchor+1..anchor+3 are '[' 30 ']'.
    // Enforces native AL string-length rules: fixed length is an integer literal 1..2048;
    // Code MUST carry a length (only Text may be unbounded). Returns the length (0 = the
    // legal unbounded Text). Invalid declarations AddError and CONTINUE (collect-all rule).
    local procedure ReadLengthSuffix(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Anchor: Integer; IsCode: Boolean): Integer
    var
        Len: Integer;
    begin
        // No '[' suffix: Text is unbounded (legal); Code has no unbounded form (native AL).
        if (Anchor + 1 > Tokens.Count()) or (Tokens.GetKind(Anchor + 1) <> 72) then begin   // OpenBracketToken
            if IsCode then
                Diags.AddError('ALI948', 'The Code data type must specify a length, e.g. Code[20] (1..2048)', TokPos(Tokens, Anchor), 0);
            exit(0);
        end;
        // '[' present but the length is not a positive integer literal (negative sign, an
        // identifier, or empty brackets) — native AL only accepts an integer literal 1..2048.
        if (Anchor + 2 > Tokens.Count()) or (Tokens.GetKind(Anchor + 2) <> 10) then begin    // Int32LiteralToken
            Diags.AddError('ALI947', 'The string length must be an integer literal between 1 and 2048', TokPos(Tokens, Anchor), 0);
            exit(0);
        end;
        Len := Tokens.GetInt(Tokens.GetValueIndex(Anchor + 2));
        if (Len < 1) or (Len > 2048) then
            Diags.AddError('ALI947', StrSubstNo('The string length %1 is out of range (must be between 1 and 2048)', Len), TokPos(Tokens, Anchor), 0);
        exit(Len);
    end;

    // ===== Statements =====

    procedure BindStatement(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        i: Integer;
        K: Integer;
    begin
        K := NKind.Get(Node);
        case true of
            (K = "ALI NodeKind"::Block):
                for i := 0 to NChildCnt.Get(Node) - 1 do
                    BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + i));
            (K = "ALI NodeKind"::IfStatement):
                BindIf(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::WhileStatement):
                BindWhile(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::RepeatStatement):
                BindRepeat(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::ForStatement):
                BindFor(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::ForEachStatement):
                BindForEach(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::CaseStatement):
                BindCase(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::AssignmentStatement):
                BindAssignment(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::ExpressionStatement):
                BindExpressionStatement(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::ExitStatement):
                BindExit(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::BreakStatement):
                if LoopNesting = 0 then
                    Diags.AddError('ALI914', 'break is only allowed inside a loop', TokPos(Tokens, NMainTok.Get(Node)), 0);
            (K = "ALI NodeKind"::EmptyStatement) or (K = "ALI NodeKind"::ErrorStatement) or (K = "ALI NodeKind"::SkippedTokens) or (K = "ALI NodeKind"::MissingNode):
                ;   // nothing to bind
            (K = "ALI NodeKind"::OrphanedElseStatement):
                // parse already errored; bind the inner statement for more diagnostics
                BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
            else
                ;   // declaration kinds never appear at statement position
        end;
    end;

    local procedure BindIf(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        ElseNode: Integer;
    begin
        RequireBool(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 1));
        ElseNode := NEdges.Get(NFirstChild.Get(Node) + 2);
        if not Ast.IsMissing(ElseNode) then
            BindStatement(Tokens, Ast, Symbols, Diags, ElseNode);
    end;

    local procedure BindWhile(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    begin
        RequireBool(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
        LoopNesting += 1;
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 1));
        LoopNesting -= 1;
    end;

    // Repeat children (§5.5): stmt* then untilCond as LAST child; ExtraInt = body count.
    local procedure BindRepeat(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        BodyCount: Integer;
        i: Integer;
    begin
        BodyCount := Ast.GetExtra(Node);
        LoopNesting += 1;
        for i := 0 to BodyCount - 1 do
            BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + i));
        LoopNesting -= 1;
        RequireBool(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + BodyCount));
    end;

    // For children (§5.5): [0]=loopVar expr, [1]=init, [2]=end, [3]=body. ExtraInt bit0=downto.
    local procedure BindFor(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        EndT: Integer;
        InitT: Integer;
        Sid: Integer;
        SKind: Integer;
        VarNode: Integer;
        VarT: Integer;
    begin
        VarNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        VarT := BindExpr(Tokens, Ast, Symbols, Diags, VarNode);
        if VarT <> "ALI TypeKind"::ErrorType then begin
            Sid := Ast.GetSymbolId(VarNode);
            if (NKind.Get(VarNode) <> "ALI NodeKind"::NameExpr) or (Sid = 0) or (not Symbols.IsVariableKind(Sid)) then begin
                Diags.AddError('ALI907', 'The for-loop control variable must be a declared variable', TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                VarT := "ALI TypeKind"::ErrorType;
            end else begin
                // FOR_INIT/FOR_NEXT address the loop var by direct frame-relative slot, so
                // indirect (var-param) and absolute (module-level) storage is out for M5.
                SKind := Symbols.GetKind(Sid);
                if (SKind = Symbols.KindVarParam()) or (SKind = Symbols.KindGlobalVar()) then begin
                    Diags.AddError('ALI907', 'The for-loop control variable must be a local variable or by-value parameter', TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                    VarT := "ALI TypeKind"::ErrorType;
                end else
                    if not ((VarT = "ALI TypeKind"::Integer) or (VarT = "ALI TypeKind"::Char) or (VarT = "ALI TypeKind"::Byte)) then begin
                        Diags.AddError('ALI907', StrSubstNo('The for-loop control variable must be of an integer type (got %1)', TypeRules.TypeName(VarT)), TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                        VarT := "ALI TypeKind"::ErrorType;
                    end;
            end;
        end;

        InitT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 1));
        EndT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 2));
        if VarT <> "ALI TypeKind"::ErrorType then begin
            CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + 1), VarT, InitT);
            CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + 2), VarT, EndT);
        end;

        // Reserve the hidden limit slot (§5.3: end bound evaluated once) — assigned in
        // AllocateProcSlots, written into this node's SlotIndex annotation.
        ForNodes.Add(Node);

        LoopNesting += 1;
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 3));
        LoopNesting -= 1;
    end;

    // ForEach children (§5.5): [0]=loopVar expr, [1]=collection expr, [2]=body.
    // Node SlotIndex = base of 3 hidden Int slots (index / limit / collection handle) —
    // assigned in AllocateProcSlots. Supported collections mirror native AL foreach:
    // List of [T] (loop var register class must equal the element class), JsonArray
    // (loop var must be JsonToken), XmlNodeList (loop var XmlNode) and XmlAttributeCollection
    // (loop var XmlAttribute — XML_DESIGN.md §9, lowered on the 1-based List-arm shape).
    // Dictionary iterates via foreach k in d.Keys().
    local procedure BindForEach(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        CollNode: Integer;
        CollT: Integer;
        ElemCls: Integer;
        Sid: Integer;
        SKind: Integer;
        VarNode: Integer;
        VarT: Integer;
    begin
        VarNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        VarT := BindExpr(Tokens, Ast, Symbols, Diags, VarNode);
        if VarT <> "ALI TypeKind"::ErrorType then begin
            Sid := Ast.GetSymbolId(VarNode);
            if (NKind.Get(VarNode) <> "ALI NodeKind"::NameExpr) or (Sid = 0) or (not Symbols.IsVariableKind(Sid)) then begin
                Diags.AddError('ALI907', 'The foreach loop variable must be a declared variable', TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                VarT := "ALI TypeKind"::ErrorType;
            end else begin
                // The loop var is written by direct frame-relative slot each iteration —
                // same storage restriction as the for-loop control variable.
                SKind := Symbols.GetKind(Sid);
                if (SKind = Symbols.KindVarParam()) or (SKind = Symbols.KindGlobalVar()) then begin
                    Diags.AddError('ALI907', 'The foreach loop variable must be a local variable or by-value parameter', TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                    VarT := "ALI TypeKind"::ErrorType;
                end;
            end;
        end;

        CollNode := NEdges.Get(NFirstChild.Get(Node) + 1);
        CollT := BindExpr(Tokens, Ast, Symbols, Diags, CollNode);
        if (VarT <> "ALI TypeKind"::ErrorType) and (CollT <> "ALI TypeKind"::ErrorType) then
            case true of
                (CollT = "ALI TypeKind"::List):
                    begin
                        ElemCls := ListDictTArgOf(Ast, Symbols, CollNode);
                        if TypeRules.RegClassFor(VarT) <> ElemCls then
                            Diags.AddError('ALI907', StrSubstNo('The foreach loop variable type %1 does not match the List element type', TypeRules.TypeName(VarT)), TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                    end;
                (CollT = "ALI TypeKind"::JsonArray):
                    if VarT <> "ALI TypeKind"::JsonToken then
                        Diags.AddError('ALI907', StrSubstNo('The foreach loop variable must be a JsonToken when iterating a JsonArray (got %1)', TypeRules.TypeName(VarT)), TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                (CollT = "ALI TypeKind"::XmlNodeList):
                    if VarT <> "ALI TypeKind"::XmlNode then
                        Diags.AddError('ALI907', StrSubstNo('The foreach loop variable must be an XmlNode when iterating an XmlNodeList (got %1)', TypeRules.TypeName(VarT)), TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                (CollT = "ALI TypeKind"::XmlAttributeCollection):
                    if VarT <> "ALI TypeKind"::XmlAttribute then
                        Diags.AddError('ALI907', StrSubstNo('The foreach loop variable must be an XmlAttribute when iterating an XmlAttributeCollection (got %1)', TypeRules.TypeName(VarT)), TokPos(Tokens, NMainTok.Get(VarNode)), 0);
                else
                    Diags.AddError('ALI907', StrSubstNo('foreach requires a List, JsonArray, XmlNodeList or XmlAttributeCollection collection (got %1); iterate a Dictionary via its Keys() list', TypeRules.TypeName(CollT)), TokPos(Tokens, NMainTok.Get(CollNode)), 0);
            end;
        // Lowerer contract: ExtraInt = collection TypeKind ordinal (List vs JsonArray dispatch).
        Ast.SetExtra(Node, CollT);

        // Reserve the 3 hidden Int slots (index / limit / handle) — assigned in
        // AllocateProcSlots, base written into this node's SlotIndex annotation.
        ForEachNodes.Add(Node);

        LoopNesting += 1;
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 2));
        LoopNesting -= 1;
    end;

    // Case children (§5.5): [0]=selector, caseLine*, caseElse|Missing as LAST child.
    local procedure BindCase(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        ElseNode: Integer;
        i: Integer;
        j: Integer;
        LineCount: Integer;
        LineNode: Integer;
        SelT: Integer;
    begin
        SelT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
        LineCount := Ast.GetExtra(Node);
        for i := 1 to LineCount do begin
            LineNode := NEdges.Get(NFirstChild.Get(Node) + i);
            BindCaseLine(Tokens, Ast, Symbols, Diags, LineNode, SelT);
        end;
        ElseNode := Ast.GetChild(Node, LineCount + 1);
        if not Ast.IsMissing(ElseNode) then
            for j := 0 to NChildCnt.Get(ElseNode) - 1 do
                BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(ElseNode) + j));
    end;

    // CaseLine children (§5.5): label+ then body as LAST child; ExtraInt = label count.
    local procedure BindCaseLine(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; LineNode: Integer; SelT: Integer)
    var
        HiT: Integer;
        i: Integer;
        LabelCount: Integer;
        LabelNode: Integer;
        LabT: Integer;
        LoT: Integer;
    begin
        LabelCount := Ast.GetExtra(LineNode);
        for i := 0 to LabelCount - 1 do begin
            LabelNode := NEdges.Get(NFirstChild.Get(LineNode) + i);
            if NKind.Get(LabelNode) = "ALI NodeKind"::RangeExpr then begin
                LoT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(LabelNode) + 0));
                HiT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(LabelNode) + 1));
                Ast.SetTypeOrd(LabelNode, LoT);
                CheckCaseLabel(Tokens, Ast, Diags, LabelNode, SelT, LoT, true);
                CheckCaseLabel(Tokens, Ast, Diags, LabelNode, SelT, HiT, true);
            end else begin
                LabT := BindExpr(Tokens, Ast, Symbols, Diags, LabelNode);
                CheckCaseLabel(Tokens, Ast, Diags, LabelNode, SelT, LabT, false);
            end;
        end;
        BindStatement(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(LineNode) + LabelCount));
    end;

    local procedure CheckCaseLabel(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; LabelNode: Integer; SelT: Integer; LabT: Integer; IsRange: Boolean)
    var
        Group: Integer;
    begin
        if (SelT = "ALI TypeKind"::ErrorType) or (LabT = "ALI TypeKind"::ErrorType) then
            exit;
        if IsRange then
            Group := "ALI Op Group"::Le       // ranges need ordering
        else
            Group := "ALI Op Group"::Eq;
        if TypeRules.ResultType(Group, SelT, LabT) <> "ALI TypeKind"::Boolean then
            Diags.AddError('ALI933', StrSubstNo('Case label type %1 is not compatible with selector type %2', TypeRules.TypeName(LabT), TypeRules.TypeName(SelT)), TokPos(Tokens, NMainTok.Get(LabelNode)), 0);
    end;

    // Assignment children (§5.5): [0]=target, [1]=source. ExtraInt = assign-op TokenKind
    // (40 := / 41 += / 42 -= / 43 *= / 44 /=). Compound type-checks as
    // `target := target <op> source` through the SAME matrix (§6.4 — do not shortcut).
    local procedure BindAssignment(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        Group: Integer;
        OpT: Integer;
        OpTok: Integer;
        Sid: Integer;
        SourceNode: Integer;
        SourceT: Integer;
        TargetNode: Integer;
        TargetT: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        SourceNode := NEdges.Get(NFirstChild.Get(Node) + 1);
        OpTok := Ast.GetExtra(Node);

        TargetT := BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);

        // `HttpReq.Method := 'GET'` (§ Http property) — a getter-typed member access on the LHS
        // of a plain `:=` is a property SET, not the (illegal) assignment to a method result the
        // generic lvalue check below would reject. Re-marks TargetNode with the setter method id.
        if (OpTok = 40) and TryBindHttpPropertySet(Tokens, Ast, Symbols, Diags, TargetNode, SourceNode) then
            exit;

        // `strm.Position := n` (§19.7) — same property-SET shape as the Http properties above.
        if (OpTok = 40) and TryBindStreamPropertySet(Tokens, Ast, Symbols, Diags, TargetNode, SourceNode) then
            exit;

        // `F.Value := x` (P2) — the idiomatic FieldRef write. Same property-SET shape again.
        if (OpTok = 40) and TryBindFieldRefPropertySet(Tokens, Ast, Symbols, Diags, TargetNode, SourceNode) then
            exit;

        // 'RecVar := idExpr.GetRecord();' (§ RecordID) is recognized STRUCTURALLY, before the
        // generic BindExpr walk reaches the GetRecord() call — the generic dispatch
        // (BindRecordIdMethod) always rejects GetRecord() with a diagnostic, since only this
        // exact assignment shape can give it a statically-known target table. Detecting it
        // here, ahead of the generic bind, is what makes that one shape legal.
        if (OpTok = 40) and IsGetRecordCall(Tokens, Ast, SourceNode) then begin
            BindGetRecordAssignment(Tokens, Ast, Symbols, Diags, TargetNode, TargetT, SourceNode);
            exit;
        end;

        SourceT := BindExpr(Tokens, Ast, Symbols, Diags, SourceNode);

        // lvalue check (M6): plain variables, record fields (MemberAccess), array elements
        // (Index). A record variable itself is a valid target only via REC_COPY (value
        // semantics) — handled below.
        if TargetT <> "ALI TypeKind"::ErrorType then
            case NKind.Get(TargetNode) of
                "ALI NodeKind"::NameExpr:
                    begin
                        Sid := Ast.GetSymbolId(TargetNode);
                        if (Sid = 0) or (not Symbols.IsVariableKind(Sid)) then begin
                            Diags.AddError('ALI908', 'The left-hand side of an assignment must be a variable', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                            exit;
                        end;
                        // A Label is a read-only compile-time constant (§19.2) — assigning to it
                        // is a native AL error even though it is a genuine variable kind.
                        if Symbols.GetType(Sid) = "ALI TypeKind"::Label then begin
                            Diags.AddError('ALI940', 'A Label is read-only and cannot be assigned', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                            exit;
                        end;
                    end;
                "ALI NodeKind"::MemberAccessExpr, "ALI NodeKind"::IndexExpr:
                    begin
                        // field / array-element write — bound above, lowered specially. A bare
                        // record method (`Rec.FindSet`) resolves to a MemberAccessExpr too but is
                        // not assignable.
                        // M11: a paren-less object-procedure call (`Cust.DisplayName`) carries the
                        // ObjectCallMark sentinel, which is LESS negative than RecMethodMark and so
                        // needs its own equality test — it is no more assignable than the rest.
                        if (NKind.Get(TargetNode) = "ALI NodeKind"::MemberAccessExpr) and ((Ast.GetSymbolId(TargetNode) <= RecMethodMark()) or (Ast.GetSymbolId(TargetNode) = ObjectCallMark())) then begin
                            Diags.AddError('ALI908', 'The left-hand side of an assignment must be a variable, record field, or array element', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                            exit;
                        end;
                        // text[i] := ... needs an addressable Text/Code VARIABLE on the left —
                        // BindIndexAccess allows any expression as a READ receiver (§19.4), but
                        // writing into the result of e.g. `Format(x)[1] := ...` has no slot to
                        // store back into and is illegal in native AL too.
                        if (NKind.Get(TargetNode) = "ALI NodeKind"::IndexExpr) and (Ast.GetTypeOrd(TargetNode) = "ALI TypeKind"::Char) then begin
                            Sid := Ast.GetSymbolId(NEdges.Get(NFirstChild.Get(TargetNode) + 0));
                            if (Ast.GetKind(NEdges.Get(NFirstChild.Get(TargetNode) + 0)) <> "ALI NodeKind"::NameExpr) or (Sid <= 0) then begin
                                Diags.AddError('ALI908', 'The left-hand side of an assignment must be a variable, record field, or array element', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                                exit;
                            end;
                            // A Label is read-only — Label[i] := ... is illegal (it has no slot).
                            if Symbols.GetType(Sid) = "ALI TypeKind"::Label then begin
                                Diags.AddError('ALI940', 'A Label is read-only and cannot be assigned', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                                exit;
                            end;
                        end;
                    end;
                else begin
                    Diags.AddError('ALI908', 'The left-hand side of an assignment must be a variable, record field, or array element', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                    exit;
                end;
            end;
        if (TargetT = "ALI TypeKind"::ErrorType) or (SourceT = "ALI TypeKind"::ErrorType) then
            exit;

        if OpTok = 40 then begin    // plain :=
            // Variant box/unbox (§19.2): `v := <anything boxable>` or `<typed> := v`. Handled
            // ahead of the Record/List/Dict same-type branches below because those reject a
            // Variant counterpart. AssignmentCompatible routes through ConvKind's box/unbox.
            if (TargetT = "ALI TypeKind"::Variant) or (SourceT = "ALI TypeKind"::Variant) then begin
                if TypeRules.AssignmentCompatible(TargetT, SourceT) then
                    exit    // lowerer emits CONV_BOX / CONV_UNBOX / BOX_REC / UNBOX_REC / MOV_V
                else
                    Diags.AddError('ALI932', StrSubstNo('Cannot implicitly convert %1 to %2', TypeRules.TypeName(SourceT), TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
            // Record := Record (value semantics, §7.5): same table, both record vars. Nested
            // ifs (AL 'and' does not short-circuit — GetTypeArg on a non-record source Sid
            // would be out of range).
            if (TargetT = "ALI TypeKind"::Record) or (SourceT = "ALI TypeKind"::Record) then begin
                if (TargetT = "ALI TypeKind"::Record) and (SourceT = "ALI TypeKind"::Record) then begin
                    if Symbols.GetTypeArg(Ast.GetSymbolId(TargetNode)) = Symbols.GetTypeArg(Ast.GetSymbolId(SourceNode)) then
                        exit    // lowerer emits REC_COPY
                    else
                        Diags.AddError('ALI932', 'Record assignment requires both records to be of the same table', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end else
                    Diags.AddError('ALI932', 'Record assignment requires both sides to be records', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
            // List := List / Dictionary := Dictionary (ListDictionaryPlan.md §5.3): reference
            // assignment lowers through the normal Int-class MOV_I path (TargetT=SourceT=TList()
            // both being an identity conversion is not enough — TargetT/SourceT alone can't tell
            // `List of [Integer]` from `List of [Text]` apart, so the element/key/value class
            // packed in TypeArg must match too).
            if (TargetT = "ALI TypeKind"::List) or (SourceT = "ALI TypeKind"::List) then begin
                if (TargetT = "ALI TypeKind"::List) and (SourceT = "ALI TypeKind"::List) then begin
                    if ListDictTArgOf(Ast, Symbols, TargetNode) = ListDictTArgOf(Ast, Symbols, SourceNode) then
                        exit    // lowerer emits the normal Int MOV_I/GLOB_STORE/STORE_IND path
                    else
                        Diags.AddError('ALI984', 'List assignment requires both sides to have the same element type', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end else
                    Diags.AddError('ALI984', 'List assignment requires both sides to be List', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
            if (TargetT = "ALI TypeKind"::Dictionary) or (SourceT = "ALI TypeKind"::Dictionary) then begin
                if (TargetT = "ALI TypeKind"::Dictionary) and (SourceT = "ALI TypeKind"::Dictionary) then begin
                    if ListDictTArgOf(Ast, Symbols, TargetNode) = ListDictTArgOf(Ast, Symbols, SourceNode) then
                        exit
                    else
                        Diags.AddError('ALI984', 'Dictionary assignment requires both sides to have the same key/value types', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end else
                    Diags.AddError('ALI984', 'Dictionary assignment requires both sides to be Dictionary', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
            // Handle Lifecycle Unification (Phase 5): `arrayVar := ProcCall()` — the ONLY legal
            // array assignment shape (v1). No whole-array-variable copy (`arr1 := arr2`) exists;
            // the source must be a call to a proc returning an array of the SAME element type
            // and length, and the target must be a LOCAL array variable — the lowerer's
            // ARR_REBIND frees the target's OLD block (frame-scoped, so it must be a local) and
            // rebinds the register to the freshly-returned block (already escape-tracked into
            // this frame by PopFrame when the call returned).
            if (TargetT = "ALI TypeKind"::Array) or (SourceT = "ALI TypeKind"::Array) then begin
                if (TargetT = "ALI TypeKind"::Array) and (SourceT = "ALI TypeKind"::Array) and
                   (NKind.Get(TargetNode) = "ALI NodeKind"::NameExpr) and (NKind.Get(SourceNode) = "ALI NodeKind"::InvocationExpr)
                then begin
                    Sid := Ast.GetSymbolId(TargetNode);
                    if Symbols.GetKind(Sid) <> Symbols.KindLocalVar() then begin
                        Diags.AddError('ALI990', 'An array can only be reassigned from a procedure call when it is a local variable (v1)', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                        exit;
                    end;
                    if ListDictTArgOf(Ast, Symbols, TargetNode) = ListDictTArgOf(Ast, Symbols, SourceNode) then
                        exit    // lowerer emits ARR_REBIND
                    else
                        Diags.AddError('ALI990', 'Array assignment requires the same element type and length', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end else
                    Diags.AddError('ALI990', 'An array can only be assigned from a procedure call returning the same array type (v1)', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
            // text[i] := <Text/Code> (§19.4-analog): single-character store off a Text/Code
            // source, runtime length-checked by the lowerer/interpreter (ALI973) — NOT a
            // general Text->Char conversion (deliberately kept out of the ConvKind lattice;
            // plain `MyChar := SomeText;` stays illegal, same as native AL for non-literals).
            if (NKind.Get(TargetNode) = "ALI NodeKind"::IndexExpr) and (TargetT = "ALI TypeKind"::Char) and TypeRules.IsTextFamily(SourceT) then
                exit;
            CheckAssignable(Tokens, Ast, Diags, SourceNode, TargetT, SourceT);
            exit;
        end;

        Group := CompoundOpGroup(OpTok);
        OpT := TypeRules.ResultType(Group, TargetT, SourceT);
        if OpT = "ALI TypeKind"::None then
            if TryCharLiteral(Tokens, Ast, SourceNode, TargetT) then begin
                SourceT := "ALI TypeKind"::Char;
                OpT := TypeRules.ResultType(Group, TargetT, SourceT);
            end;
        if OpT = "ALI TypeKind"::None then begin
            Diags.AddError('ALI930', StrSubstNo('Operator cannot be applied to operands of type %1 and %2', TypeRules.TypeName(TargetT), TypeRules.TypeName(SourceT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit;
        end;
        // The operation result must narrow back into the target (e.g. `/=` on Integer:
        // Decimal division then Decimal->Integer assignment conversion, §6.4).
        if not TypeRules.AssignmentCompatible(TargetT, OpT) then begin
            Diags.AddError('ALI932', StrSubstNo('Cannot implicitly convert %1 to %2', TypeRules.TypeName(OpT), TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit;
        end;
        // Annotate: source's conversion toward the OPERATION type; the node's own ConvOrd
        // records the narrowing back to the target.
        Ast.SetConvOrd(SourceNode, TypeRules.ConvKind(SourceT, OpT));
        Ast.SetConvOrd(Node, TypeRules.ConvKind(OpT, TargetT));
    end;

    // Structural (type-free) detection of 'idExpr.GetRecord()' or the parenless 'idExpr.
    // GetRecord' — checked BEFORE any binding happens, so BindAssignment can special-case it
    // ahead of the generic BindExpr walk (§ RecordID).
    local procedure IsGetRecordCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    var
        CalleeNode: Integer;
    begin
        case NKind.Get(Node) of
            "ALI NodeKind"::InvocationExpr:
                begin
                    if Ast.GetExtra(Node) <> 0 then
                        exit(false);
                    CalleeNode := NEdges.Get(NFirstChild.Get(Node) + 0);
                end;
            "ALI NodeKind"::MemberAccessExpr:
                CalleeNode := Node;
            else
                exit(false);
        end;
        if NKind.Get(CalleeNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit(false);
        exit(UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode))) = 'GETRECORD');
    end;

    // Binds 'RecVar := idExpr.GetRecord();': TargetNode must already be a plain Record
    // variable (its table is what the runtime opens the RecordID against — REC_GET_BY_ID,
    // §7.5-analog); idExpr must be RecordID-typed. Marks SourceNode with the RecordID
    // GetRecord marker so LowerAssignment recognizes the shape instead of falling into the
    // generic REC_COPY (Record:=Record) path.
    local procedure BindGetRecordAssignment(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; TargetNode: Integer; TargetT: Integer; SourceNode: Integer)
    var
        CalleeNode: Integer;
        RecvNode: Integer;
        RecvT: Integer;
    begin
        if NKind.Get(SourceNode) = "ALI NodeKind"::InvocationExpr then
            CalleeNode := NEdges.Get(NFirstChild.Get(SourceNode) + 0)
        else
            CalleeNode := SourceNode;
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        RecvT := BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);

        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (Ast.GetSymbolId(TargetNode) <= 0) or (TargetT <> "ALI TypeKind"::Record) then begin
            Diags.AddError('ALI908', 'The left-hand side of ''idExpr.GetRecord()'' must be a Record variable', TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit;
        end;
        if RecvT = "ALI TypeKind"::ErrorType then
            exit;
        if RecvT <> "ALI TypeKind"::RecordID then begin
            Diags.AddError('ALI934', StrSubstNo('GetRecord() requires a RecordID variable (got %1)', TypeRules.TypeName(RecvT)), TokPos(Tokens, NMainTok.Get(SourceNode)), 0);
            exit;
        end;

        Ast.SetTypeOrd(SourceNode, "ALI TypeKind"::Record);
        Ast.SetSymbolId(SourceNode, RecordIdMethodMark() - 1);   // lowerer contract: GetRecord marker
    end;

    local procedure CompoundOpGroup(OpTok: Integer): Integer
    begin
        case OpTok of
            41: // +=
                exit("ALI Op Group"::"Add");
            42: // -=
                exit("ALI Op Group"::Sub);
            43: // *=
                exit("ALI Op Group"::Mul);
            44: // /=
                exit("ALI Op Group"::RDiv);
            else
                exit(0);
        end;
    end;

    local procedure BindExpressionStatement(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        ArgsBound: Boolean;
        IsParenlessMember: Boolean;
        BareBId: Integer;
        ExprNode: Integer;
        MemberResultT: Integer;
        Sid: Integer;
        BareName: Text;
    begin
        ExprNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        // The `Target.Method();` (parens) form routes through BindInvocation.
        if NKind.Get(ExprNode) = "ALI NodeKind"::InvocationExpr then begin
            BindInvocation(Tokens, Ast, Symbols, Diags, ExprNode, true);
            exit;
        end;
        // Parenless member/record method as a statement (`Tb.AppendLine;`, `Rec.Reset;`): the
        // parser built a plain MemberAccessExpr. Bind in STATEMENT context so void methods don't
        // trip the ALI929 void-in-expression check. Two steps, not one `and`: TryDispatch /
        // IsRecMethodMember must not run on a non-MemberAccess node (AL evaluates both operands).
        IsParenlessMember := NKind.Get(ExprNode) = "ALI NodeKind"::MemberAccessExpr;
        if IsParenlessMember then
            if TryDispatchMemberMethod(Tokens, Ast, Symbols, Diags, ExprNode, ExprNode, true, MemberResultT) then begin
                Ast.SetTypeOrd(ExprNode, MemberResultT);
                exit;
            end;
        // M11: same for a paren-less call to a procedure declared on the table (`Cust.Refresh;`).
        // BindRecordMethod routes it to TryBindObjectProcCall; STATEMENT context matters here for
        // the same reason as above — a void procedure would otherwise trip ALI929.
        if IsParenlessMember then
            if IsRecMethodMember(Tokens, Ast, ExprNode) or IsObjectProcMember(Tokens, Ast, Symbols, ExprNode) then begin
                Ast.SetTypeOrd(ExprNode, BindRecordMethod(Tokens, Ast, Symbols, Diags, ExprNode, ExprNode, true));
                exit;
            end;
        // M11: paren-less record method with no receiver, as a statement (`Modify;`, `Init;`)
        // inside a harvested table procedure. STATEMENT context matters — a void method like
        // Init would otherwise trip ALI929 "does not return a value".
        if NKind.Get(ExprNode) = "ALI NodeKind"::NameExpr then
            if Symbols.Lookup(Ast.GetExtra(ExprNode)) = 0 then
                if TryBindImplicitRecMethod(Tokens, Ast, Symbols, Diags, ExprNode, ExprNode, true, MemberResultT) then begin
                    Ast.SetTypeOrd(ExprNode, MemberResultT);
                    exit;
                end;
        // Bare user procedure as a statement (`MyProc;`): resolve the NameExpr to a Proc symbol
        // and bind as a zero-arg call in STATEMENT context — void procs skip ALI929, and the
        // positive proc SymbolId never reaches the ALI913 check below. Nested ifs (eager eval:
        // Symbols.GetKind(Sid) must not run when Sid = 0).
        if NKind.Get(ExprNode) = "ALI NodeKind"::NameExpr then begin
            Sid := Symbols.Lookup(Ast.GetExtra(ExprNode));
            if Sid <> 0 then
                if Symbols.GetKind(Sid) = Symbols.KindProc() then begin
                    // M11 phase A: paren-less SIBLING call as a statement (`Recalculate;`).
                    if TryBindSiblingProcCall(Tokens, Ast, Symbols, Diags, ExprNode, ExprNode, Sid, 0, true, MemberResultT) then begin
                        Ast.SetTypeOrd(ExprNode, MemberResultT);
                        exit;
                    end;
                    // Paren-less call: pick the zero-arg overload if one exists.
                    Sid := ResolveOverload(Tokens, Ast, Symbols, Diags, ExprNode, Ast.GetExtra(ExprNode), Sid, 0, ArgsBound);
                    BindUserProcCall(Tokens, Ast, Symbols, Diags, ExprNode, Sid, Tokens.GetIdentText(NMainTok.Get(ExprNode)), true, 0, ArgsBound, 0);
                    exit;
                end;
        end;
        // Bare 0-arg builtin as a statement (`SelectLatestVersion;`, `Commit;`, `ClearAll;`):
        // bind in STATEMENT context, else a void builtin trips ALI929 — BindNameExpr only knows
        // expression context (IsStatement=false). User symbols shadow (handled above). Nested
        // ifs: eager evaluation.
        if NKind.Get(ExprNode) = "ALI NodeKind"::NameExpr then
            if Symbols.Lookup(Ast.GetExtra(ExprNode)) = 0 then begin
                BareName := Tokens.GetIdentText(NMainTok.Get(ExprNode));
                BareBId := Builtins.ResolveByName(UpperCase(BareName));
                if BareBId <> 0 then begin
                    Ast.SetTypeOrd(ExprNode, BindBuiltinCall(Tokens, Ast, Symbols, Diags, ExprNode, BareBId, BareName, UpperCase(BareName), 0, true));
                    exit;
                end;
            end;
        BindExpr(Tokens, Ast, Symbols, Diags, ExprNode);
        // A bare record method (`Rec.FindSet;`) binds to a MemberAccessExpr marked with a
        // record-method SymbolId (<= RecMethodMark()); that is a valid statement. A bare 0-arg
        // builtin (`SelectLatestVersion;`) binds with a BuiltinCallMark SymbolId (also negative).
        // Anything else that isn't a call — e.g. a plain field read as a statement — is not.
        if (Ast.GetTypeOrd(ExprNode) <> "ALI TypeKind"::ErrorType) and (Ast.GetSymbolId(ExprNode) > RecMethodMark()) then
            Diags.AddError('ALI913', 'Only a procedure call can be used as a statement', TokPos(Tokens, NMainTok.Get(Node)), 0);
    end;

    // Argument k of an invocation node, or a MissingNode when the node has no such child.
    //
    // Load-bearing, not belt-and-braces. Every record-method arm below reads its arguments at
    // FIXED positions, and it does so even after CheckRecArgCount has already reported the arity
    // as wrong — `Rec.Find` with no argument still reaches the `Find(Text)` arm's read of child 1.
    // An unguarded NEdges.Get(FirstChild + 1) does NOT fail there: the edge list is one flat array
    // shared by every node, so the read silently returns SOME OTHER NODE's edge. When that node
    // happens to be an ancestor, binding it re-enters the same arm and the binder recurses until
    // AL aborts the session with "insufficient memory … may be caused by recursive functions" —
    // no diagnostic, no position. Whole-object harvesting made this reachable by binding far more
    // real record code than a hand-written script ever contained.
    //
    // BindExpr answers MissingNode with ErrorType and no side effects, so an over-read now
    // degrades into the arity diagnostic that was already queued.
    local procedure ArgOrMissing(var Ast: Codeunit "ALI Ast Store"; Node: Integer; k: Integer): Integer
    begin
        if (k < 0) or (k >= NChildCnt.Get(Node)) then
            exit(Ast.MissingNode());
        exit(NEdges.Get(NFirstChild.Get(Node) + k));
    end;

    // True when a MemberAccessExpr's member name is a known record method (`Rec.Reset`), so a
    // bare-statement form can be bound as a zero-arg call rather than a field read.
    local procedure IsRecMethodMember(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    begin
        exit(RecMethodId(UpperCase(Tokens.GetIdentText(NMainTok.Get(Node)))) <> 0);
    end;

    // M11: true when a paren-less MemberAccessExpr over a record VARIABLE names a procedure
    // declared on that table rather than a field (`Cust.Refresh;`). Statement context has to know
    // BEFORE anything binds, so this is a non-binding peek, the same shape as the Is*Receiver
    // predicates. A blocked procedure counts as a match — BindRecordMethod then reports ALI922
    // rather than letting the statement fall through to a field-read diagnostic.
    local procedure IsObjectProcMember(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Node: Integer): Boolean
    var
        Registry: Codeunit "ALI Object Registry";
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        ProcSid: Integer;
        RecvNode: Integer;
        RecvSid: Integer;
        TableId: Integer;
        BlockedReason: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        RecvSid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if RecvSid = 0 then
            exit(false);
        if Symbols.GetType(RecvSid) <> "ALI TypeKind"::Record then
            exit(false);
        TableId := Symbols.GetTypeArg(RecvSid);
        EnsureTablePopulated(Tokens, TableId);
        if RecMeta.TryFieldInfo(TableId, Ast.GetExtra(Node), FNo, FType, FLen, FClass) then
            exit(false);                                // a field wins over a same-named procedure
        if Registry.TryLookupObjectProc("ALI Object Type"::Table.AsInteger(), TableId, Tokens.GetIdentText(NMainTok.Get(Node)), Symbols, ProcSid, BlockedReason) then
            exit(true);
        exit(BlockedReason <> '');
    end;

    // Exit children (§5.5): [0]=value|Missing. ExtraInt bit0 = has-value.
    local procedure BindExit(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer)
    var
        ValueNode: Integer;
        VT: Integer;
    begin
        ValueNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        if Ast.IsMissing(ValueNode) then
            exit;
        VT := BindExpr(Tokens, Ast, Symbols, Diags, ValueNode);
        if VT = "ALI TypeKind"::ErrorType then
            exit;
        if ResTypeOrd = "ALI TypeKind"::None then
            if InferResult then begin
                // form 0 (bare statement block): first exit(expr) fixes the result type.
                ResTypeOrd := VT;
                ResTypeArg := 0;
            end else begin
                Diags.AddError('ALI909', 'exit(value) is only allowed in a procedure with a return type', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit;
            end;
        CheckAssignable(Tokens, Ast, Diags, ValueNode, ResTypeOrd, VT);
    end;

    // ===== Expressions =====

    // Bind an expression node; writes TypeOrd (+ SymbolId for names) and returns the type.
    procedure BindExpr(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        K: Integer;
        T: Integer;
    begin
        K := NKind.Get(Node);
        case true of
            (K = "ALI NodeKind"::LiteralExpr):
                T := BindLiteral(Tokens, Ast, Node);
            (K = "ALI NodeKind"::NameExpr):
                T := BindName(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::UnaryExpr):
                T := BindUnary(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::BinaryExpr):
                T := BindBinary(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::InvocationExpr):
                T := BindInvocation(Tokens, Ast, Symbols, Diags, Node, false);
            (K = "ALI NodeKind"::MemberAccessExpr):
                T := BindFieldAccess(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::OptionAccessExpr):
                T := BindOptionAccess(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::IndexExpr):
                T := BindIndexAccess(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::InListExpr):
                T := BindInList(Tokens, Ast, Symbols, Diags, Node);
            (K = "ALI NodeKind"::ErrorExpr) or (K = "ALI NodeKind"::MissingNode):
                T := "ALI TypeKind"::ErrorType;
            else
                T := "ALI TypeKind"::ErrorType;
        end;
        Ast.SetTypeOrd(Node, T);
        exit(T);
    end;

    // ===== §19.6 object-id `::` access =====
    //
    // `Database::"Customer"`, `Codeunit::"Sales Post"`, `Page::X`, `Report::X`, `Query::X`,
    // `XmlPort::X`, `Enum::X` fold to a compile-time Integer constant (the object id).
    // Distinguishing object-kind LEFT TOKEN from an option/enum-typed variable: the parser
    // widened IsNameLike (§ ALI Parser Expr) so Codeunit/Table/Page/Report/Query/XmlPort
    // keyword tokens parse as a NameExpr leaf too — check the RAW TOKEN KIND first (never
    // call BindName/symbol-lookup on a keyword token, it has no interned NameId). Database
    // and Enum are not reserved keywords at all, so they arrive as plain IdentifierToken;
    // for those we match the SPELLING against the recognized object-kind words before
    // falling back to Option/Enum member access (§C/§D/§E).
    local procedure BindOptionAccess(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        LeftKind: Integer;
        LeftNode: Integer;
        LeftTok: Integer;
        MemberTok: Integer;
        ObjId: Integer;
        MemberText: Text;
        ObjKindWord: Text;
    begin
        LeftNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        LeftTok := NMainTok.Get(LeftNode);
        LeftKind := Tokens.GetKind(LeftTok);
        ObjKindWord := '';

        case LeftKind of
            138:
                ObjKindWord := 'Codeunit';
            139:
                ObjKindWord := 'Table';
            140:
                ObjKindWord := 'Page';
            141:
                ObjKindWord := 'Report';
            142:
                ObjKindWord := 'Query';
            143:
                ObjKindWord := 'XmlPort';
            20:  // plain identifier — only Database/Enum are recognized object-kind words,
                 // and ONLY when no local symbol of that exact name shadows them (AL-consistent
                 // — a variable literally named "Enum" would win the symbol lookup below).

                // and ONLY when no local symbol of that exact name shadows them (AL-consistent
                // — a variable literally named "Enum" would win the symbol lookup below).

                if UpperCase(Tokens.GetIdentText(LeftTok)) = 'DATABASE' then
                    ObjKindWord := 'Table'    // Database::X and Table::X are the same id space natively
                else
                    if (UpperCase(Tokens.GetIdentText(LeftTok)) = 'ENUM') and (NKind.Get(LeftNode) = "ALI NodeKind"::NameExpr) and (Symbols.Lookup(Ast.GetExtra(LeftNode)) = 0) then
                        ObjKindWord := 'Enum';
        end;

        if ObjKindWord <> '' then begin
            MemberTok := NMainTok.Get(Node);
            MemberText := MemberName(Tokens, MemberTok);
            if not TryResolveObjectId(ObjKindWord, MemberText, ObjId) then begin
                Diags.AddError('ALI984', StrSubstNo('%1 ''%2'' does not exist', ObjKindWord, MemberText), TokPos(Tokens, MemberTok), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            Ast.SetSlotIndex(Node, ObjId);      // lowerer contract: folded object id
            exit("ALI TypeKind"::ObjectId);
        end;

        exit(BindOptionOrEnumMember(Tokens, Ast, Symbols, Diags, Node, LeftNode));
    end;

    // Option/Enum `::Member` member access — everything that ISN'T a recognized object-kind
    // word (§C local Option, §D table-field Option/Enum, §E Enum literal/chained access).
    // Member lookup matches the value NAME (identifier); the ordinal is what folds onto the
    // node (SlotIndex, lowerer contract already shared with the object-id branch above — both
    // are compile-time Int constants, so no lowerer change is needed for `::`).
    local procedure BindOptionOrEnumMember(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; LeftNode: Integer): Integer
    var
        LeftT: Integer;
        MemberTok: Integer;
        ObjId: Integer;
        SetId: Integer;
        Sid: Integer;
        EnumName: Text;
        MemberText: Text;
    begin
        MemberTok := NMainTok.Get(Node);
        MemberText := MemberName(Tokens, MemberTok);

        // (a) chained Enum::"X"::Value — left is itself an OptionAccessExpr that folded to an
        // object id (the inner `Enum::"X"` access).
        if NKind.Get(LeftNode) = "ALI NodeKind"::OptionAccessExpr then begin
            LeftT := BindExpr(Tokens, Ast, Symbols, Diags, LeftNode);
            if LeftT = "ALI TypeKind"::ErrorType then
                exit("ALI TypeKind"::ErrorType);   // poisoned upstream — LeftNode already reported (§6.2)
            if LeftT = "ALI TypeKind"::ObjectId then begin
                ObjId := Ast.GetSlotIndex(LeftNode);
                SetId := OptionMeta.InternEnum(ObjId);
                exit(FoldMember(Ast, Diags, Tokens, Node, MemberTok, MemberText, SetId, "ALI TypeKind"::Enum, EnumDisplayName(ObjId)));
            end;
            Diags.AddError('ALI934', StrSubstNo('''::%1'' cannot be applied here — only an Enum::"Name"::Member chain is valid', MemberText), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        // (b) local/global variable or parameter of type Option/Enum: `O::B`, `E::Open`.
        if NKind.Get(LeftNode) = "ALI NodeKind"::NameExpr then begin
            Sid := Symbols.Lookup(Ast.GetExtra(LeftNode));
            if Sid <> 0 then begin
                LeftT := BindExpr(Tokens, Ast, Symbols, Diags, LeftNode);
                if LeftT = "ALI TypeKind"::ErrorType then
                    exit("ALI TypeKind"::ErrorType);   // poisoned upstream — LeftNode already reported (§6.2)
                if (LeftT = "ALI TypeKind"::Option) or (LeftT = "ALI TypeKind"::Enum) then begin
                    SetId := Symbols.GetTypeArg(Sid);
                    exit(FoldMember(Ast, Diags, Tokens, Node, MemberTok, MemberText, SetId, LeftT, Tokens.GetIdentText(NMainTok.Get(LeftNode))));
                end;
                Diags.AddError('ALI934', StrSubstNo('''%1'' is not an Option or Enum variable (got %2), so ''::%3'' does not apply', Tokens.GetIdentText(NMainTok.Get(LeftNode)), TypeRules.TypeName(LeftT), MemberText), TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            // (c) no symbol of that name — bare Enum-object literal: `"ALI Test Enum"::Open`.
            EnumName := Tokens.GetIdentText(NMainTok.Get(LeftNode));
            if TryResolveObjectId('Enum', EnumName, ObjId) then begin
                SetId := OptionMeta.InternEnum(ObjId);
                exit(FoldMember(Ast, Diags, Tokens, Node, MemberTok, MemberText, SetId, "ALI TypeKind"::Enum, EnumName));
            end;
            // (c') built-in system option types used as method args (RecordRef.ReadIsolation /
            // SecurityFiltering): `IsolationLevel::UpdLock`, `SecurityFilter::Ignored`. Not real
            // Enum objects, so intern a fixed inline set (0-based ordinals match the runtime map).
            if TrySystemOptionSet(EnumName, SetId) then
                exit(FoldMember(Ast, Diags, Tokens, Node, MemberTok, MemberText, SetId, "ALI TypeKind"::Option, EnumName));
            // Neither a name in scope nor an Enum object. The usual real cause is a module var
            // section whose declarations never made it into the unit — say that, instead of
            // blaming `::`, which is what sent readers looking for a missing language feature.
            Diags.AddError('ALI984', StrSubstNo('''%1'' is not a declared Option/Enum variable, and no Enum of that name exists', EnumName), TokPos(Tokens, NMainTok.Get(LeftNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        // (d) record field of type Option/Enum: `Rec.Status::Open`.
        if NKind.Get(LeftNode) = "ALI NodeKind"::MemberAccessExpr then begin
            LeftT := BindExpr(Tokens, Ast, Symbols, Diags, LeftNode);
            if LeftT = "ALI TypeKind"::ErrorType then
                exit("ALI TypeKind"::ErrorType);   // poisoned upstream — LeftNode already reported (§6.2)
            if (LeftT = "ALI TypeKind"::Option) or (LeftT = "ALI TypeKind"::Enum) then begin
                SetId := Ast.GetTypeArg(LeftNode);
                exit(FoldMember(Ast, Diags, Tokens, Node, MemberTok, MemberText, SetId, LeftT, Tokens.GetIdentText(NMainTok.Get(LeftNode))));
            end;
        end;

        Diags.AddError('ALI934', StrSubstNo('The left of ''::%1'' must be an Option/Enum variable, an Option/Enum field, or an Enum name', MemberText), TokPos(Tokens, NMainTok.Get(Node)), 0);
        exit("ALI TypeKind"::ErrorType);
    end;

    // Built-in RecordRef system option types exposed to `::` so scripts can write
    // `IsolationLevel::UpdLock` / `SecurityFilter::Ignored` instead of a bare ordinal. Member
    // order = native ordinal (Int-backed, folds to the same value the runtime case-maps back).
    local procedure TrySystemOptionSet(TypeName: Text; var SetId: Integer): Boolean
    var
        Names: List of [Text];
    begin
        case UpperCase(TypeName) of
            // P2: the two option types FieldRef.Class()/Type() return. UNLIKE every other set
            // here, their member ORDER is NOT the native ordinal — FieldType's platform numbers
            // are the virtual Field table's non-contiguous ones (Text = 31488), which an
            // index-ordered ALI option set cannot reproduce. ALI therefore declares its own
            // ordinals over the same names and maps native <-> ALI BY NAME at run time
            // ("ALI Rec Runtime".FieldTypeOrdinal). Self-consistent inside a script — that is
            // all `F.Type() = FieldType::Text` and `Format(F.Type())` need — and no platform
            // ordinal is ever exposed. Single source of truth: "ALI Option Meta".
            'FIELDCLASS':
                Names := OptionMeta.FieldClassNames();
            'FIELDTYPE':
                Names := OptionMeta.FieldTypeNames();
            'ISOLATIONLEVEL':
                begin
                    Names.Add('Default');           // 0
                    Names.Add('ReadUncommitted');   // 1
                    Names.Add('ReadCommitted');     // 2
                    Names.Add('RepeatableRead');    // 3
                    Names.Add('UpdLock');           // 4
                end;
            'SECURITYFILTER':
                begin
                    Names.Add('Validated');         // 0
                    Names.Add('Filtered');          // 1
                    Names.Add('Ignored');           // 2
                    Names.Add('Disallowed');        // 3
                end;
            'CLIENTTYPE':
                begin
                    Names.Add('Background');        // 0
                    Names.Add('ChildSession');      // 1
                    Names.Add('Desktop');           // 2
                    Names.Add('Management');        // 3
                    Names.Add('NAS');               // 4
                    Names.Add('OData');             // 5
                    Names.Add('Phone');             // 6
                    Names.Add('SOAP');              // 7
                    Names.Add('Tablet');            // 8
                    Names.Add('Web');               // 9
                    Names.Add('Windows');           // 10
                    Names.Add('Current');           // 11
                    Names.Add('Default');           // 12
                    Names.Add('ODataV4');           // 13
                    Names.Add('Api');               // 14
                    Names.Add('Teams');             // 15
                end;
            'TRANSACTIONTYPE':
                begin
                    Names.Add('UpdateNoLocks');     // 0
                    Names.Add('Update');            // 1
                    Names.Add('Snapshot');          // 2
                    Names.Add('Browse');            // 3
                    Names.Add('Report');            // 4
                end;
            'DATACLASSIFICATION':
                begin
                    Names.Add('CustomerContent');                       // 0
                    Names.Add('ToBeClassified');                        // 1
                    Names.Add('EndUserIdentifiableInformation');        // 2
                    Names.Add('AccountData');                           // 3
                    Names.Add('EndUserPseudonymousIdentifiers');        // 4
                    Names.Add('OrganizationIdentifiableInformation');   // 5
                    Names.Add('SystemMetadata');                        // 6
                end;
            'ERRORTYPE':
                begin
                    Names.Add('Client');            // 0
                    Names.Add('Internal');          // 1
                end;
            'PAGESTYLE':
                begin
                    Names.Add('None');              // 0
                    Names.Add('Standard');          // 1
                    Names.Add('StandardAccent');    // 2
                    Names.Add('Strong');            // 3
                    Names.Add('StrongAccent');      // 4
                    Names.Add('Attention');         // 5
                    Names.Add('AttentionAccent');   // 6
                    Names.Add('Favorable');         // 7
                    Names.Add('Unfavorable');       // 8
                    Names.Add('Ambiguous');         // 9
                    Names.Add('Subordinate');       // 10
                end;
            'VERBOSITY':
                begin
                    Names.Add('Critical');          // 0
                    Names.Add('Error');             // 1
                    Names.Add('Warning');           // 2
                    Names.Add('Normal');            // 3
                    Names.Add('Verbose');           // 4
                end;
            'TEXTENCODING':
                begin
                    Names.Add('MSDos');             // 0 (native default)
                    Names.Add('UTF8');              // 1
                    Names.Add('UTF16');             // 2
                    Names.Add('Windows');           // 3
                end;
            else
                exit(false);
        end;
        SetId := OptionMeta.InternInlineSet(Names);
        exit(true);
    end;

    // True when a bound expression is Option-typed over the built-in TextEncoding set.
    local procedure IsTextEncodingSet(ArgT: Integer; SetId: Integer): Boolean
    var
        EncSetId: Integer;
    begin
        if ArgT <> "ALI TypeKind"::Option then
            exit(false);
        exit(TrySystemOptionSet('TEXTENCODING', EncSetId) and (SetId = EncSetId));
    end;

    // Resolve MemberText's ordinal within SetId and fold it onto Node, or report ALI986.
    local procedure FoldMember(var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Tokens: Codeunit "ALI Token Table"; Node: Integer; MemberTok: Integer; MemberText: Text; SetId: Integer; ResultT: Integer; SetDisplayName: Text): Integer
    var
        Ord: Integer;
    begin
        if not OptionMeta.TryOrdinalByName(SetId, MemberText, Ord) then begin
            Diags.AddError('ALI986', StrSubstNo('''%1'' is not a member of ''%2''', MemberText, SetDisplayName), TokPos(Tokens, MemberTok), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        Ast.SetSlotIndex(Node, Ord);
        Ast.SetTypeOrd(Node, ResultT);
        Ast.SetTypeArg(Node, SetId);
        exit(ResultT);
    end;

    // `::` member spelling. Keyword tokens carry no pooled text, so an unquoted `::Page` would
    // read as ''; recover it from the TokenKind value name (PageKeyword -> Page). Member lookup
    // is case-insensitive, so the enum's casing is fine.
    local procedure MemberName(var Tokens: Codeunit "ALI Token Table"; MemberTok: Integer): Text
    var
        Kind: Integer;
        KindName: Text;
    begin
        Kind := Tokens.GetKind(MemberTok);
        if (Kind < 130) or (Kind > 145) then    // ProcedureKeyword..EventKeyword (parser § IsDeclarationKeyword)
            exit(Tokens.GetIdentText(MemberTok));
        KindName := "ALI TokenKind".Names().Get("ALI TokenKind".Ordinals().IndexOf(Kind));
        exit(CopyStr(KindName, 1, StrLen(KindName) - StrLen('Keyword')));
    end;

    // Best-effort enum object name for diagnostics (falls back to the numeric id).
    local procedure EnumDisplayName(EnumId: Integer): Text
    var
        AllObj: Record AllObjWithCaption;
    begin
        if AllObj.Get(AllObj."Object Type"::Enum, EnumId) then
            exit(AllObj."Object Name");
        exit(Format(EnumId));
    end;

    // Resolve an object-kind word + name to its numeric object id via AllObjWithCaption.
    local procedure TryResolveObjectId(ObjKindWord: Text; ObjName: Text; var ObjId: Integer): Boolean
    var
        AllObj: Record AllObjWithCaption;
    begin
        case ObjKindWord of
            'Table':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
            'Codeunit':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Codeunit);
            'Page':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Page);
            'Report':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Report);
            'Query':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Query);
            'XmlPort':
                AllObj.SetRange("Object Type", AllObj."Object Type"::XMLport);
            'Enum':
                AllObj.SetRange("Object Type", AllObj."Object Type"::Enum);
            else
                exit(false);
        end;
        // "Object Name" is Text[30] but platform objects may be longer (enum 11512 "Swiss QR-Bill
        // Payment Reference Type" = 36): the row carries the name truncated to 30, so match on
        // that prefix (same as ALIRecRuntime.TryResolveTableId).
        // ponytail: two objects sharing a 30-char prefix resolve to the first; disambiguate via
        // the object source header if that ever happens.
        AllObj.SetRange("Object Name", CopyStr(ObjName, 1, MaxStrLen(AllObj."Object Name")));
        if AllObj.FindFirst() then begin
            ObjId := AllObj."Object ID";
            exit(true);
        end;
        exit(false);
    end;

    local procedure BindLiteral(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Integer
    var
        TokKind: Integer;
    begin
        TokKind := Tokens.GetKind(NMainTok.Get(Node));
        case TokKind of
            10: // Int32LiteralToken
                exit("ALI TypeKind"::Integer);
            11: // Int64LiteralToken
                exit("ALI TypeKind"::BigInteger);
            12: // DecimalLiteralToken
                exit("ALI TypeKind"::Decimal);
            13: // DateLiteralToken
                exit("ALI TypeKind"::Date);
            14: // TimeLiteralToken
                exit("ALI TypeKind"::Time);
            15: // DateTimeLiteralToken
                exit("ALI TypeKind"::DateTime);
            16: // StringLiteralToken
                exit("ALI TypeKind"::Text);
            21, 22: // TrueKeyword / FalseKeyword
                exit("ALI TypeKind"::Boolean);
            else
                exit("ALI TypeKind"::ErrorType);
        end;
    end;

    local procedure BindName(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        ArgsBound: Boolean;
        BId: Integer;
        ImplicitResultT: Integer;
        NameId: Integer;
        Sid: Integer;
        NameText: Text;
        UpperName: Text;
    begin
        NameId := Ast.GetExtra(Node);
        // `System.`-qualified: the builtin is named explicitly — skip variables/procs/fields.
        if Ast.GetForceBuiltin(Node) then
            Sid := 0
        else
            Sid := Symbols.Lookup(NameId);
        if Sid <> 0 then begin
            Ast.SetSymbolId(Node, Sid);
            if Symbols.GetKind(Sid) = Symbols.KindProc() then begin
                // M11 phase A: paren-less SIBLING call inside a harvested object (`x := Helper`).
                if TryBindSiblingProcCall(Tokens, Ast, Symbols, Diags, Node, Node, Sid, 0, false, ImplicitResultT) then
                    exit(ImplicitResultT);
                // Paren-less zero-arg call as a value (`x := MyFunc`): AL allows dropping `()`.
                // A proc that requires parameters errors ALI916 (arity) inside BindUserProcCall;
                // a void proc used in expression context errors ALI929 — both native-equivalent.
                Sid := ResolveOverload(Tokens, Ast, Symbols, Diags, Node, NameId, Sid, 0, ArgsBound);
                Ast.SetSymbolId(Node, Sid);
                exit(BindUserProcCall(Tokens, Ast, Symbols, Diags, Node, Sid, Tokens.GetIdentText(NMainTok.Get(Node)), false, 0, ArgsBound, 0));
            end;
            // §D2: a bare Option/Enum-typed variable read needs its set id on the NODE too
            // (not just the symbol) — Format(o) reads Ast.GetTypeArg(argNode), which BindName
            // never wrote before this fix (only BindOptionAccess/BindFieldAccess did).
            Ast.SetTypeArg(Node, Symbols.GetTypeArg(Sid));
            exit(Symbols.GetType(Sid));
        end;
        // M11: inside a harvested TABLE procedure an unqualified name may be one of the table's
        // own FIELDS (`"No." := 'X'` — the dominant spelling in real table code), or a paren-less
        // record METHOD used as a value (`if Insert then`). Tried after variables and before
        // builtins, matching native AL resolution order.
        if (ImplicitRecSid > 0) and (not Ast.GetForceBuiltin(Node)) then begin
            if TryBindImplicitField(Tokens, Ast, Symbols, Node, NameId) then
                exit(Ast.GetTypeOrd(Node));
            if TryBindImplicitRecMethod(Tokens, Ast, Symbols, Diags, Node, Node, false, ImplicitResultT) then
                exit(ImplicitResultT);
        end;

        NameText := Tokens.GetIdentText(NMainTok.Get(Node));
        UpperName := UpperCase(NameText);
        BId := Builtins.ResolveByName(UpperName);
        if BId <> 0 then
            // Native AL lets a 0-arg builtin be invoked without (); reuse the normal
            // builtin-call binder with ArgCount=0 on this same NameExpr node — BindArgs/the
            // arity check are both ArgCount-driven and no-op/error correctly with 0 args, and
            // the resulting BuiltinCallMark() SymbolId is what LowerExpr's NodeNameExpr case
            // dispatches on (§ AL0912 fix).
            exit(BindBuiltinCall(Tokens, Ast, Symbols, Diags, Node, BId, NameText, UpperName, 0, false));
        Diags.AddError('AL0118', StrSubstNo('The name ''%1'' does not exist in the current context', NameText) + SuggestFrom(NameText, SuggestCatalog.BuiltinNames()), TokPos(Tokens, NMainTok.Get(Node)), 0);
        exit("ALI TypeKind"::ErrorType);
    end;

    // M11: rewrite a bare field name into the `Rec.<field>` shape the rest of the pipeline
    // already understands, rather than teaching the lowerer a second field-access form. A
    // NameExpr and a MemberAccessExpr differ only in children — and the NameExpr's ExtraInt is
    // ALREADY the member NameId that MemberAccessExpr wants — so the node is re-kinded in place
    // and given one synthetic child: a NameExpr bound to the implicit `Rec` symbol. From here on
    // it is indistinguishable from source that said `Rec."No."`, including as an assignment
    // target (LowerFieldStore) and including var-param receivers (LowerExpr -> LOAD_IND).
    // Returns false when the name is not a field of the table, leaving the node untouched.
    // M11: the METHOD counterpart of TryBindImplicitField. Inside a harvested table procedure,
    // `CalcFields(x)`, `Modify()`, `Delete` and friends are written WITHOUT a receiver, and mean
    // the record the procedure was called on. Same technique: give the callee NameExpr a
    // synthetic `Rec` child and re-kind it to MemberAccessExpr, which is exactly the shape
    // BindRecordMethod already consumes — so all 15+ record methods work with no new dispatch.
    //
    // Member-first, matching native AL: a name that is a record method resolves to the record's
    // method even if a global builtin shares the spelling.
    local procedure TryBindImplicitRecMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean; var ResultT: Integer): Boolean
    begin
        if ImplicitRecSid <= 0 then
            exit(false);
        if NKind.Get(CalleeNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        if RecMethodId(UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)))) = 0 then
            exit(false);

        AttachImplicitReceiver(Ast, Symbols, CalleeNode);
        ResultT := BindRecordMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
        exit(true);
    end;

    // Re-kind a bare NameExpr into `Rec.<name>`: one synthetic child bound to the implicit
    // receiver. The NameExpr's ExtraInt is already the member NameId that MemberAccessExpr
    // wants, and its MainTok already points at the identifier, so nothing else moves.
    local procedure AttachImplicitReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Node: Integer)
    var
        RecNode: Integer;
        Kids: List of [Integer];
    begin
        RecNode := Ast.AddLeaf("ALI NodeKind"::NameExpr, NMainTok.Get(Node), Symbols.GetNameId(ImplicitRecSid));
        Ast.SetSymbolId(RecNode, ImplicitRecSid);
        Ast.SetTypeOrd(RecNode, "ALI TypeKind"::Record);
        Ast.SetTypeArg(RecNode, ObjectTableId);

        Kids.Add(RecNode);
        Ast.SetKind(Node, "ALI NodeKind"::MemberAccessExpr);
        Ast.SetChildren(Node, Kids);
        // The structural columns were snapshotted at Bind() entry and are read all over this
        // codeunit; re-take them so the node's new kind and child are visible.
        Ast.GetStructureColumns(NKind, NMainTok, NFirstChild, NChildCnt, NEdges);
    end;

    local procedure TryBindImplicitField(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Node: Integer; MemberNameId: Integer): Boolean
    var
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
    begin
        if not RecMeta.TryFieldInfo(ObjectTableId, MemberNameId, FNo, FType, FLen, FClass) then
            exit(false);
        if FType = "ALI TypeKind"::ErrorType then
            exit(false);            // unsupported field type — fall through to the AL0118 path

        AttachImplicitReceiver(Ast, Symbols, Node);   // ExtraInt already holds the member NameId
        Ast.SetSlotIndex(Node, FNo);            // lowerer contract: field number
        Ast.SetTypeOrd(Node, FType);
        if FType = "ALI TypeKind"::Option then
            Ast.SetTypeArg(Node, OptionMeta.FieldSetId(ObjectTableId, FNo));
        exit(true);
    end;

    // Rec.Field (MemberAccessExpr): child 0 = target (record var), ExtraInt = member NameId.
    // Resolves the field via RecMeta and annotates the node: TypeOrd = field type, SlotIndex
    // = field number (lowerer contract). The record handle is the target symbol's slot.
    local procedure BindFieldAccess(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        MemberNameId: Integer;
        MemberResultT: Integer;
        Sid: Integer;
        TableId: Integer;
        TargetNode: Integer;
        TargetT: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        // Paren-less Xml STATIC call (`Doc := XmlDocument.Create` — type-name receiver,
        // XML_DESIGN.md §4): routed BEFORE binding the target — the type name is not a
        // symbol, so BindExpr would emit AL0118 and poison the node.
        if XmlStaticReceiverKind(Tokens, Ast, Symbols, TargetNode) <> "ALI TypeKind"::None then
            exit(BindXmlMethod(Tokens, Ast, Symbols, Diags, Node, Node, false));
        TargetT := BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        if TargetT = "ALI TypeKind"::ErrorType then
            exit("ALI TypeKind"::ErrorType);
        // Parenless RecordID method (`id.TableNo` — no parens): AL allows dropping `()` on a
        // no-arg method call here too, same as record methods below.
        if TargetT = "ALI TypeKind"::RecordID then
            exit(BindRecordIdMethod(Tokens, Ast, Symbols, Diags, Node, Node, false));
        // Paren-less member method on a non-record receiver (`x := Tb.Length`, `n := L.Count`,
        // `x := Resp.HttpStatusCode`): Node IS the MemberAccessExpr (its own child 0 = receiver).
        // Route through the shared dispatcher before the record-only guard below.
        if TryDispatchMemberMethod(Tokens, Ast, Symbols, Diags, Node, Node, false, MemberResultT) then
            exit(MemberResultT);
        if TargetT <> "ALI TypeKind"::Record then begin
            Diags.AddError('ALI934', StrSubstNo('Member access requires a record variable (got %1)', TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        Sid := Ast.GetSymbolId(TargetNode);
        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (Sid <= 0) then begin
            Diags.AddError('ALI934', 'The left of a field access must be a record variable', TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TableId := Symbols.GetTypeArg(Sid);
        MemberNameId := Ast.GetExtra(Node);
        // Member resolution order mirrors native AL: a FIELD of the table wins over a
        // same-named record method in the paren-less form (e.g. the virtual Field table's
        // own "FieldName"/"TableName" columns — `F.FieldName` reads the field; the method
        // spelling needs an explicit argument list and routes through BindInvocation).
        // Only when no field matches is a bare no-arg record method (`Rec.FindSet`,
        // `Rec.Next`) resolved — AL allows dropping `()` on a no-arg method call.
        if not RecMeta.TryFieldInfo(TableId, MemberNameId, FNo, FType, FLen, FClass) then begin
            if RecMethodId(UpperCase(Tokens.GetIdentText(NMainTok.Get(Node)))) <> 0 then
                exit(BindRecordMethod(Tokens, Ast, Symbols, Diags, Node, Node, false));
            // M11: a procedure declared on the TABLE, called WITHOUT parentheses
            // (`x := Cust.DisplayName`). AL allows dropping `()` on a no-arg call here exactly
            // as it does for the built-in record methods above; Node IS the callee, so 0 args.
            if TryBindObjectProcCall(Tokens, Ast, Symbols, Diags, Node, Node, TableId, Tokens.GetIdentText(NMainTok.Get(Node)), 0, false, MemberResultT) then
                exit(MemberResultT);
            Diags.AddError('AL0132', StrSubstNo('''%1'' is not a field of the record', Tokens.GetIdentText(NMainTok.Get(Node))) + SuggestField(TableId, Tokens.GetIdentText(NMainTok.Get(Node))), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        if FType = "ALI TypeKind"::ErrorType then begin
            Diags.AddError('ALI960', StrSubstNo('Field ''%1'' has a type the interpreter does not support', Tokens.GetIdentText(NMainTok.Get(Node))), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        NoteFlowFieldRead(Tokens, Node, TableId, FNo, FClass);
        Ast.SetSlotIndex(Node, FNo);            // lowerer contract: field number
        // Option/Enum field (§D5-1, §D under Table-field Option/Enum): the set id comes from
        // FieldRef enumeration (works identically for a genuine Option field and a genuine
        // Enum field — both map to TOption() here per §D1) so `Rec.Status::Open` /
        // Format(Rec.Status) resolve without a separate per-field metadata pass.
        if FType = "ALI TypeKind"::Option then
            Ast.SetTypeArg(Node, OptionMeta.FieldSetId(TableId, FNo));
        exit(FType);
    end;

    // arr[i] (IndexExpr): child 0 = array variable OR any Text/Code-typed expression, child 1
    // = index expr. Node TypeOrd = element type; for arrays the element base slot is the
    // target symbol's slot (lowerer reads it directly). Text/Code targets (§19.4-analog
    // "native AL text array access") index single characters and type as Char — the lowerer
    // routes them to TXT_CHAR_GET/SET instead of ARR_LOAD/STORE, telling the two apart via the
    // receiver's bound TypeOrd (NOT Symbols.GetType(Sid) — the receiver need not be a variable
    // for the Text/Code case, see BindIndexAccess below).
    // §20.9(2): IndexExpr children are [0]=target, [1..IndexCount]=index expressions
    // (ExtraInt=IndexCount, §20.8). Array targets require IndexCount = the array's declared
    // rank exactly (compile error otherwise, so the interpreter never sees a wrong arity);
    // Text/Code targets keep the single-index §19.4 char-access shape.
    local procedure BindIndexAccess(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        HasIndexError: Boolean;
        i: Integer;
        IdxT: Integer;
        IndexCount: Integer;
        IndexNode: Integer;
        Rank: Integer;
        Sid: Integer;
        TargetNode: Integer;
        TargetT: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        IndexCount := Ast.GetExtra(Node);
        TargetT := BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        if TargetT = "ALI TypeKind"::ErrorType then
            exit("ALI TypeKind"::ErrorType);
        // Label indexes like Text (it folds to its text constant, §19.2) — read-only, so a
        // WRITE into Label[i] is rejected in BindAssignment, not here.
        if (TargetT <> "ALI TypeKind"::Array) and (not TypeRules.IsTextFamily(TargetT)) then begin
            Diags.AddError('ALI920', StrSubstNo('Indexing requires an array or Text/Code value (got %1)', TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        Sid := Ast.GetSymbolId(TargetNode);
        // Arrays must be indexed off a plain array VARIABLE — there is no array-valued
        // rvalue expression in this subset. Text/Code MAY be indexed off ANY expression (e.g.
        // `Format(1+2)[1]`) — reading a char only needs the evaluated VALUE, not an
        // addressable slot (§19.4); writing INTO text[i] still requires a variable and is
        // enforced separately in BindAssignment.
        if TargetT = "ALI TypeKind"::Array then begin
            if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (Sid <= 0) then begin
                Diags.AddError('ALI920', 'The target of an array index must be an array variable', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            Rank := Symbols.GetArrayRank(Sid);
            if IndexCount <> Rank then begin
                Diags.AddError('ALI920', StrSubstNo('Array has rank %1; expected %1 index expression(s), got %2', Rank, IndexCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
        end else
            if IndexCount <> 1 then begin
                Diags.AddError('ALI920', 'Text/Code indexing takes exactly one index', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;

        HasIndexError := false;
        for i := 1 to IndexCount do begin
            IndexNode := NEdges.Get(NFirstChild.Get(Node) + i);
            IdxT := BindExpr(Tokens, Ast, Symbols, Diags, IndexNode);
            if (IdxT <> "ALI TypeKind"::ErrorType) and (not TypeRules.IsIntegerFamily(IdxT)) then begin
                Diags.AddError('ALI920', StrSubstNo('Index must be an integer (got %1)', TypeRules.TypeName(IdxT)), TokPos(Tokens, NMainTok.Get(IndexNode)), 0);
                HasIndexError := true;
            end;
        end;
        if HasIndexError then
            exit("ALI TypeKind"::ErrorType);
        if TargetT = "ALI TypeKind"::Array then
            exit(ArrayElemType(Symbols.GetTypeArg(Sid)));
        exit("ALI TypeKind"::Char);
    end;

    local procedure BindUnary(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        OperandT: Integer;
        OpTok: Integer;
    begin
        OpTok := Ast.GetExtra(Node);        // operator TokenKind: 63 not / 31 - / 30 +
        OperandT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
        if OperandT = "ALI TypeKind"::ErrorType then
            exit("ALI TypeKind"::ErrorType);
        if OpTok = 63 then begin            // not
            if OperandT <> "ALI TypeKind"::Boolean then begin
                Diags.AddError('ALI930', StrSubstNo('Operator ''not'' requires a Boolean operand (got %1)', TypeRules.TypeName(OperandT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            exit("ALI TypeKind"::Boolean);
        end;
        // unary - / + : numeric only; Char/Byte/Option promote to Integer.
        if not TypeRules.IsNumeric(OperandT) then begin
            Diags.AddError('ALI930', StrSubstNo('Unary operator requires a numeric operand (got %1)', TypeRules.TypeName(OperandT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        if OperandT = "ALI TypeKind"::Decimal then
            exit("ALI TypeKind"::Decimal);
        if OperandT = "ALI TypeKind"::BigInteger then
            exit("ALI TypeKind"::BigInteger);
        exit("ALI TypeKind"::Integer);
    end;

    // `Expr in [item, lo..hi, ...]` — child 0 = tested expr, children 1..ExtraInt = items
    // (plain value or RangeExpr). Every item must compare with the tested expression through
    // the SAME matrix as case labels: OpEq for plain values, OpLe for range bounds (ordering
    // required). Result type is Boolean regardless of item errors (poison stays local).
    local procedure BindInList(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        HiT: Integer;
        i: Integer;
        ItemCount: Integer;
        ItemNode: Integer;
        ItemT: Integer;
        LhsT: Integer;
        LoT: Integer;
    begin
        LhsT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 0));
        ItemCount := Ast.GetExtra(Node);
        for i := 1 to ItemCount do begin
            ItemNode := NEdges.Get(NFirstChild.Get(Node) + i);
            if NKind.Get(ItemNode) = "ALI NodeKind"::RangeExpr then begin
                LoT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(ItemNode) + 0));
                HiT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(ItemNode) + 1));
                Ast.SetTypeOrd(ItemNode, LoT);      // lowerer contract shared with case labels
                CheckInItem(Tokens, Ast, Diags, ItemNode, LhsT, LoT, true);
                CheckInItem(Tokens, Ast, Diags, ItemNode, LhsT, HiT, true);
            end else begin
                ItemT := BindExpr(Tokens, Ast, Symbols, Diags, ItemNode);
                CheckInItem(Tokens, Ast, Diags, ItemNode, LhsT, ItemT, false);
            end;
        end;
        exit("ALI TypeKind"::Boolean);
    end;

    local procedure CheckInItem(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; ItemNode: Integer; LhsT: Integer; ItemT: Integer; IsRange: Boolean)
    var
        Group: Integer;
    begin
        if (LhsT = "ALI TypeKind"::ErrorType) or (ItemT = "ALI TypeKind"::ErrorType) then
            exit;
        if IsRange then
            Group := "ALI Op Group"::Le       // ranges need ordering
        else
            Group := "ALI Op Group"::Eq;
        if TypeRules.ResultType(Group, LhsT, ItemT) <> "ALI TypeKind"::Boolean then
            Diags.AddError('ALI942', StrSubstNo('''in'' set element type %1 is not compatible with the tested expression type %2', TypeRules.TypeName(ItemT), TypeRules.TypeName(LhsT)), TokPos(Tokens, NMainTok.Get(ItemNode)), 0);
    end;

    local procedure BindBinary(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer): Integer
    var
        Group: Integer;
        LeftNode: Integer;
        LT: Integer;
        R: Integer;
        RightNode: Integer;
        RT: Integer;
    begin
        LeftNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        RightNode := NEdges.Get(NFirstChild.Get(Node) + 1);
        Group := TypeRules.OpGroupFromToken(Ast.GetExtra(Node));
        LT := BindExpr(Tokens, Ast, Symbols, Diags, LeftNode);
        RT := BindExpr(Tokens, Ast, Symbols, Diags, RightNode);
        if Group = 0 then
            exit("ALI TypeKind"::ErrorType);
        R := TypeRules.ResultType(Group, LT, RT);
        if R = "ALI TypeKind"::ErrorType then
            exit(R);                        // poison — no cascade (§6.2)
        // Native AL: a 1-char string literal converts implicitly to Char (then to Integer),
        // e.g. `10 + Txt[i] - 'a'`. Only tried when the op is otherwise illegal, so the
        // existing Text readings (`Ch = 'a'`, `Ch + 'a'` concat) keep priority.
        if R = "ALI TypeKind"::None then
            if TryCharLiteral(Tokens, Ast, RightNode, LT) then begin
                RT := "ALI TypeKind"::Char;
                R := TypeRules.ResultType(Group, LT, RT);
            end else
                if TryCharLiteral(Tokens, Ast, LeftNode, RT) then begin
                    LT := "ALI TypeKind"::Char;
                    R := TypeRules.ResultType(Group, LT, RT);
                end;
        if R = "ALI TypeKind"::None then begin
            Diags.AddError('ALI930', StrSubstNo('Operator cannot be applied to operands of type %1 and %2', TypeRules.TypeName(LT), TypeRules.TypeName(RT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        // Informative operand conversion annotations (the lowerer re-derives register
        // classes from TypeOrd; ConvToText marks concat's formatted operands).
        if (Group = "ALI Op Group"::"Add") and (R = "ALI TypeKind"::Text) then begin
            if not TypeRules.IsTextFamily(LT) then
                Ast.SetConvOrd(LeftNode, "ALI Conv Kind"::ToText);
            if not TypeRules.IsTextFamily(RT) then
                Ast.SetConvOrd(RightNode, "ALI Conv Kind"::ToText);
        end else begin
            if TypeRules.CanConvert(LT, R) then
                Ast.SetConvOrd(LeftNode, TypeRules.ConvKind(LT, R));
            if TypeRules.CanConvert(RT, R) then
                Ast.SetConvOrd(RightNode, TypeRules.ConvKind(RT, R));
        end;
        exit(R);
    end;

    // Retype a 1-char string literal operand as Char when the other operand is numeric
    // (Char included). The lowerer folds such a literal to its Int character code.
    local procedure TryCharLiteral(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; OtherT: Integer): Boolean
    begin
        if not TypeRules.IsNumeric(OtherT) then
            exit(false);
        if NKind.Get(Node) <> "ALI NodeKind"::LiteralExpr then
            exit(false);
        if Tokens.GetKind(NMainTok.Get(Node)) <> 16 then       // StringLiteralToken
            exit(false);
        if StrLen(Tokens.GetText(Ast.GetExtra(Node))) <> 1 then
            exit(false);
        Ast.SetTypeOrd(Node, "ALI TypeKind"::Char);
        exit(true);
    end;

    // Shared member-method dispatcher: peek the receiver kind of a MemberAccessExpr callee and
    // route to the matching *Method binder. Returns false (leaving ResultT untouched) when no
    // non-record receiver kind matches — the caller then falls back (record method / field
    // access). Used by BindInvocation (parenthesized: CalleeNode = the invocation's callee) AND
    // by the paren-less callers BindFieldAccess / BindExpressionStatement (CalleeNode = Node).
    // Receiver checks are non-binding Symbols.Lookup peeks — no double-bind hazard.
    local procedure TryDispatchMemberMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean; var ResultT: Integer): Boolean
    var
        MediaKind: Integer;
        RecvNode: Integer;
        RefKind: Integer;
        StaticNativeId: Integer;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        // M11 phase C3: `Codeunit.Run(...)`. FIRST, because the receiver is the CodeunitKeyword
        // TOKEN and every predicate below peeks at it through Symbols.Lookup(NameId) — a keyword
        // token has no interned NameId to look up.
        if IsCodeunitKeywordReceiver(Tokens, RecvNode) then begin
            ResultT := BindCodeunitStaticRun(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // `Page.Run(...)` / `Report.Run(...)` / `File.DownloadFromStream(...)`: static platform
        // receivers, bound to native catalogue rows under a pseudo codeunit id. Here, for the
        // same reason as the arm above: Page and Report are keyword tokens with no NameId.
        StaticNativeId := StaticNativeReceiverId(Tokens, Ast, Symbols, RecvNode, CalleeNode);
        if StaticNativeId <> 0 then begin
            ResultT := BindStaticNativeCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, RecvNode, StaticNativeId, IsStatement);
            exit(true);
        end;
        // M11: inside a harvested table procedure the RECEIVER itself may be a bare field name —
        // `"Issued Rem. Header Filter".HasValue()`, a BLOB field with no `Rec.` prefix. Every
        // Is*Receiver predicate below inspects the receiver STRUCTURALLY, and on the invocation
        // path they run before anything binds it, so an unrewritten NameExpr matches none of them
        // and the call falls through to BindRecordMethod's "requires a record variable" error.
        // Rewriting here, once, fixes every receiver family at the same time (Blob, but equally a
        // Text field's .Contains, a RecordId field's .TableNo, ...). The paren-less path
        // (BindFieldAccess) binds its target first and so already arrives normalized.
        if ImplicitRecSid > 0 then
            if NKind.Get(RecvNode) = "ALI NodeKind"::NameExpr then
                if Symbols.Lookup(Ast.GetExtra(RecvNode)) = 0 then      // a real variable wins
                    TryBindImplicitField(Tokens, Ast, Symbols, RecvNode, Ast.GetExtra(RecvNode));
        // User-declared FieldRef / KeyRef receiver (P2/P3, mark -16000, MOST negative of all).
        // Ahead of RecordRef for the same reason RecordRef is ahead of the rest: a FieldRef
        // variable is a plain NameExpr, and no other predicate below would claim it.
        if IsFieldRefReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindFieldRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, false, IsStatement);
            exit(true);
        end;
        if IsKeyRefReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindFieldRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, true, IsStatement);
            exit(true);
        end;
        // User-declared RecordRef receiver (P1, mark -15000, MOST negative). Checked ahead of
        // every other family: a RecordRef variable is a plain NameExpr like a List or a Dialog
        // variable, and the routed half of its surface deliberately ends up in BindRecordMethod,
        // which no other predicate here would reach for it.
        if IsRecordRefReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindRecordRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // Media/MediaSet field receiver (`Rec.Picture.MediaId()`, mark -14000):
        MediaKind := MediaKindOfFieldReceiver(Ast, Symbols, RecvNode);
        if MediaKind <> "ALI TypeKind"::None then begin
            ResultT := BindMediaMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, MediaKind, IsStatement);
            exit(true);
        end;
        // BigText / SecretText (mark -13000):
        if IsBigTextReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindBigTextMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, false, IsStatement);
            exit(true);
        end;
        if IsSecretTextReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindBigTextMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, true, IsStatement);
            exit(true);
        end;
        // ===== Chained member access on a ref-typed CALL RESULT (`RRef.Field(3).Value`) =====
        //
        // The three predicates above are STRUCTURAL: NameExpr + Symbols.Lookup, i.e. they see a
        // ref-typed VARIABLE and nothing else. `RRef.Field(3).Value`, `K.FieldIndex(1).Name()`,
        // `F.Record().Number()` and `GetFieldRef().Value` have an InvocationExpr (or a paren-less
        // MemberAccessExpr) as their receiver, which no symbol table can answer for — the type is
        // only known by BINDING the receiver. That is what this arm does, and it is the idiomatic
        // spelling of the whole RecordRef API, so it is not an edge case.
        //
        // WHY IT SITS HERE and not next to its three siblings at the top of the ladder: peeking a
        // non-name receiver means speculatively binding it (ExprTypePeek's rule). The MEDIA arm
        // just above is matched structurally on an UNBOUND `Rec.<field>` member access, and
        // pre-binding that would annotate it behind its back. The Xml arm immediately below
        // ALREADY peeks through ExprTypePeek, as does every arm after it (Blob included), so
        // placing this one right here adds exactly ZERO speculative binds that did not happen
        // before — while still being ahead of every family a ref could be confused with (none: a
        // FieldRef is neither Xml, Json, Http nor Text).
        //
        // Nothing else is needed to make chaining work: a RecordRef handle is an Int register and
        // a FieldRef/KeyRef handle is a packed Int with no bank and no lifecycle, so an
        // intermediate link is a plain temp register — no allocation, no freeing, no leak. The
        // lowerer already resolves every receiver with a generic LowerExpr on `child 0`.
        RefKind := RefKindOfChainedReceiver(Tokens, Ast, Symbols, RecvNode);
        if RefKind = "ALI TypeKind"::FieldRef then begin
            ResultT := BindFieldRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, false, IsStatement);
            exit(true);
        end;
        if RefKind = "ALI TypeKind"::KeyRef then begin
            ResultT := BindFieldRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, true, IsStatement);
            exit(true);
        end;
        if RefKind = "ALI TypeKind"::RecordRef then begin
            ResultT := BindRecordRefMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // Xml (Feature 3, mark -12000, MOST negative of every mark — checked FIRST; also
        // recognizes the STATIC type-name receiver `XmlDocument.ReadFrom(...)`, XML_DESIGN.md §4):
        if XmlKindOfReceiver(Tokens, Ast, Symbols, RecvNode) <> "ALI TypeKind"::None then begin
            ResultT := BindXmlMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // BLOB field receiver (`Rec.MyBlob.CreateInStream(s)`, mark -11000):
        if IsBlobFieldReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindBlobMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // Json (Feature 2, mark -10000):
        if JsonKindOfReceiver(Tokens, Ast, Symbols, RecvNode) <> "ALI TypeKind"::None then begin
            ResultT := BindJsonMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsStreamReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindStreamMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsTextBuilderReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindTextBuilderMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsDialogReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindDialogMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsListReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindListMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsDictReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindDictMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsVariantReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindVariantMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsTextReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindTextMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if IsRecordIdReceiver(Tokens, Ast, Symbols, RecvNode) then begin
            ResultT := BindRecordIdMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        if HttpKindOfReceiver(Tokens, Ast, Symbols, RecvNode) <> "ALI TypeKind"::None then begin
            ResultT := BindHttpMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement);
            exit(true);
        end;
        // M11 phase C2: `MyCU.Proc(args)` / `MyCU.Proc` — a codeunit variable receiver. Last,
        // because it is the only family with no built-in method set of its own: every member of a
        // codeunit is user code, so reaching here means nothing else claimed it.
        if IsCodeunitReceiver(Ast, Symbols, RecvNode) then begin
            ResultT := BindCodeunitProcCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, RecvNode, IsStatement);
            exit(true);
        end;
        exit(false);
    end;

    // A plain variable of type `Codeunit "X"`. Structural, like every other Is*Receiver: the
    // receiver has not been bound yet on the invocation path, so this reads the symbol table
    // directly from the NameExpr's NameId.
    local procedure IsCodeunitReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit((Symbols.GetType(Sid) = "ALI TypeKind"::CodeunitRef) or (Symbols.GetType(Sid) = "ALI TypeKind"::NativeCodeunit));
    end;

    // M11 phase C2: a call to a procedure declared on a CODEUNIT. Unlike the table case there is
    // no receiver to pass — a codeunit has no fields, and object globals are stored per object
    // (phase B), so nothing about the call is instance-specific. It is therefore an ORDINARY user
    // proc call: RowShift 0, SymbolId = the proc symbol, and the lowerer emits a plain CALL with
    // no new machinery. The receiver node is annotated but never loaded (CodeunitRef has no
    // register class), which is what makes `MyCU` cost nothing at runtime.
    local procedure BindCodeunitProcCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; RecvNode: Integer; IsStatement: Boolean): Integer
    var
        Registry: Codeunit "ALI Object Registry";
        IsNativeInstance: Boolean;
        ArgCount: Integer;
        CodeunitId: Integer;
        NativeBId: Integer;
        ProcSid: Integer;
        RecvSid: Integer;
        ResultT: Integer;
        BlockedReason: Text;
        MethodName: Text;
    begin
        RecvSid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        CodeunitId := Symbols.GetTypeArg(RecvSid);
        IsNativeInstance := Symbols.GetType(RecvSid) = "ALI TypeKind"::NativeCodeunit;
        Ast.SetSymbolId(RecvNode, RecvSid);
        Ast.SetTypeOrd(RecvNode, Symbols.GetType(RecvSid));
        Ast.SetTypeArg(RecvNode, CodeunitId);

        // A paren-less call (`MyCU.Refresh;`) has no InvocationExpr, so Node IS the member access
        // and its ExtraInt is the member NameId, not an argument count.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;

        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));

        // M11 phase C3: `MyCU.Run([Rec])` — never a harvested procedure. It runs the codeunit
        // NATIVELY, on a fresh platform instance, so it must not be mixed with interpreted
        // procedure calls through the same variable (see the BindRunCall header).
        if UpperCase(MethodName) = 'RUN' then begin
            if CodeunitVarProcUse.Contains(RecvSid) then begin
                Diags.AddError('ALI928', StrSubstNo('''%1'' is used both for Run and for procedure calls. Run executes the codeunit natively on a fresh instance, which cannot see the state your procedure calls build up — declare a second variable for the Run, or use Codeunit.Run(Codeunit::"...").', Tokens.GetIdentText(NMainTok.Get(RecvNode))), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            exit(BindRunCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, CodeunitId, false, ArgCount, IsStatement));
        end;

        // Native codeunit catalogue: the real codeunit is called natively, nothing is harvested.
        NativeBId := Builtins.ResolveNative(CodeunitId, UpperCase(MethodName));
        if NativeBId <> 0 then
            exit(BindNativeCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, NativeBId, ArgCount, IsNativeInstance, IsStatement));
        // A stateful native variable has no harvested procedures to fall back on: its value is a
        // handle into "ALI Native Runtime", not an instance block of interpreted globals.
        if IsNativeInstance then begin
            Diags.AddError('ALI961', StrSubstNo('''%1'' is not in the native catalogue of codeunit %2 (SecretText overloads, overloads taking a Temp Blob and stream-returning overloads are not supported — use the Text / stream-parameter overload)', MethodName, CodeunitId), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        if not Registry.TryLookupObjectProc("ALI Object Type"::Codeunit.AsInteger(), CodeunitId, MethodName, Symbols, ProcSid, BlockedReason) then begin
            if BlockedReason <> '' then
                Diags.AddError('ALI922', StrSubstNo('Procedure ''%1'' of codeunit %2 could not be compiled: %3', MethodName, CodeunitId, BlockedReason), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0)
            else
                Diags.AddError('ALI961', UnknownCodeunitMethodText(MethodName, CodeunitId), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ProcSid := PickArityOverload(Symbols, ProcSid, ArgCount);
        ResultT := BindUserProcCall(Tokens, Ast, Symbols, Diags, Node, ProcSid, MethodName, IsStatement, ArgCount, false, Symbols.GetProcHiddenCount(Symbols.GetProcId(ProcSid)));
        // M11 phase B2: a codeunit that declares globals takes a hidden instance index, so the
        // call is no longer a plain CALL — mark it like a table object call and let
        // LowerObjectCall stage the index. A codeunit WITHOUT globals keeps the phase-C2 shape
        // (proc symbol on the node, ordinary CALL, nothing staged).
        if ResultT <> "ALI TypeKind"::ErrorType then
            if Symbols.GetProcHiddenCount(Symbols.GetProcId(ProcSid)) > 0 then begin
                Ast.SetSlotIndex(Node, ProcSid);
                Ast.SetSymbolId(Node, ObjectCallMark());
            end;
        exit(ResultT);
    end;

    // ALI982 text. A row registered as unimplemented either has no v1 implementation, or is a
    // real AL method this BUILD cannot call at all (OnPrem-scoped surface in a cloud build) —
    // two very different answers for the reader, so the registry's reason is shown when it has
    // one. See "ALI Builtin Registry".UnimplementedReason.
    local procedure UnimplementedBuiltinText(NameText: Text; BId: Integer): Text
    var
        Why: Text;
    begin
        Why := Builtins.UnimplementedReason(BId);
        if Why <> '' then
            exit(StrSubstNo('Built-in ''%1'' is recognized but not available in this build: %2', NameText, Why));
        exit(StrSubstNo('Built-in ''%1'' is recognized but not implemented in v1', NameText));
    end;

    // ALI961 text for a codeunit member. Same three causes as the table variant, minus the
    // expression-receiver one (a codeunit variable is always a plain name).
    local procedure UnknownCodeunitMethodText(MethodName: Text; CodeunitId: Integer): Text
    var
        Registry: Codeunit "ALI Object Registry";
    begin
        exit(StrSubstNo('Codeunit %2 has no procedure ''%1'' with readable source. Triggers (including OnRun) and decorated procedures (other than TryFunction) are not harvested.', MethodName, CodeunitId) + Registry.NoSourceReason());
    end;

    // ===== Native codeunit catalogue ("ALI Builtin Registry".PopulateNative) =====
    //
    // `TypeHelper.UrlEncode(s)`, `Base64.ToBase64(InS)`, `DataComp.AddEntry(InS, 'a.txt')`: the
    // call binds to a builtin row of Domain Native, so it lowers through the ordinary
    // CALL_BUILTIN_LIVE path (SymbolId = BuiltinCallMark() - BId) and runs in "ALI Native Runtime"
    // on a real instance of the codeunit. Nothing is harvested: no `Allow Object Calls`, no DotNet
    // gate. Overloads are picked here, on the arguments' STATIC types — the runtime key is
    // per-overload, so it never has to guess from a Variant.
    //
    // HasReceiver: a stateful receiver (NativeCodeunit, Data Compression) is parameter 1 of every
    // row and the lowerer pushes its handle as operand 1 (method form). A CodeunitRef receiver
    // (the stateless catalogue) carries no value and is not an operand at all.
    local procedure BindNativeCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; FirstBId: Integer; ArgCount: Integer; HasReceiver: Boolean; IsStatement: Boolean): Integer
    var
        Found: Boolean;
        ArgNode: Integer;
        ArgSid: Integer;
        BId: Integer;
        k: Integer;
        Offset: Integer;
        ParamT: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        if HasReceiver then begin
            BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));
            Offset := 1;
        end;
        BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
        for k := 1 to ArgCount do
            if Ast.GetTypeOrd(NativeArgNode(Node, k)) = "ALI TypeKind"::ErrorType then
                exit("ALI TypeKind"::ErrorType);          // the argument already reported why

        // First overload whose parameters accept every argument. Two separate tests, not one
        // `and`: AL evaluates both operands, and NativeRowAccepts(0) would read past the rows.
        BId := FirstBId;
        while (BId <> 0) and (not Found) do
            if NativeRowAccepts(Ast, Node, BId, ArgCount, Offset) then
                Found := true
            else
                BId := Builtins.NextOverload(BId);
        if not Found then begin
            Diags.AddError('ALI916', StrSubstNo('No overload of ''%1'' accepts the arguments (%2)', MethodName, NativeArgTypesText(Ast, Node, ArgCount)), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        // A catalogued row this BUILD cannot call (see "ALI Builtin Registry".NatUnavailable).
        // Caught after overload selection, so the message names the overload the user picked.
        if Builtins.IsUnimplemented(BId) then begin
            Diags.AddError('ALI982', UnimplementedBuiltinText(MethodName, BId), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;

        for k := 1 to ArgCount do begin
            ArgNode := NativeArgNode(Node, k);
            ParamT := Builtins.ParamType(BId, k + Offset);
            if Builtins.IsVarParam(BId, k + Offset) then begin
                // The runtime writes the new value back into this argument's register and the
                // lowerer stores it into the variable — so it has to BE a variable.
                ArgSid := Ast.GetSymbolId(ArgNode);
                if (NKind.Get(ArgNode) <> "ALI NodeKind"::NameExpr) or (ArgSid <= 0) or (not Symbols.IsVariableKind(ArgSid)) then begin
                    Diags.AddError('ALI917', StrSubstNo('Argument %1 of ''%2'' is passed by var and must be an assignable variable', k, MethodName), TokPos(Tokens, Ast.GetMainToken(ArgNode)), 0);
                    exit("ALI TypeKind"::ErrorType);
                end;
            end;
        end;

        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);
        ResultT := Builtins.GetResultType(BId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // Does catalogue row BId take exactly these (already bound) arguments? Offset = 1 skips the
    // row's receiver parameter.
    local procedure NativeRowAccepts(var Ast: Codeunit "ALI Ast Store"; Node: Integer; BId: Integer; ArgCount: Integer; Offset: Integer): Boolean
    var
        ArgNode: Integer;
        ArgT: Integer;
        k: Integer;
        ParamT: Integer;
    begin
        if Builtins.GetMinArity(BId) <> ArgCount + Offset then
            exit(false);
        for k := 1 to ArgCount do begin
            ArgNode := NativeArgNode(Node, k);
            ArgT := Ast.GetTypeOrd(ArgNode);
            ParamT := Builtins.ParamType(BId, k + Offset);
            case ParamT of
                "ALI TypeKind"::Variant:
                    ;                                   // Type Helper's `var Variable: Variant` takes any variable
                "ALI TypeKind"::InStream, "ALI TypeKind"::OutStream:
                    if ArgT <> ParamT then
                        exit(false);
                "ALI TypeKind"::Option:                 // the catalogue's only Option parameter is TextEncoding
                    if not IsTextEncodingSet(ArgT, Ast.GetTypeArg(ArgNode)) then
                        exit(false);
                "ALI TypeKind"::List:                   // List of [Text]
                    if (ArgT <> "ALI TypeKind"::List) or (Ast.GetTypeArg(ArgNode) <> "ALI Register Class"::"Text".AsInteger()) then
                        exit(false);
                else
                    if Builtins.IsVarParam(BId, k + Offset) then begin
                        // by var: the written-back value must fit the variable, both ways
                        if not (TypeRules.AssignmentCompatible(ParamT, ArgT) and TypeRules.AssignmentCompatible(ArgT, ParamT)) then
                            exit(false);
                    end else
                        if not TypeRules.AssignmentCompatible(ParamT, ArgT) then
                            exit(false);
            end;
        end;
        exit(true);
    end;

    local procedure NativeArgNode(Node: Integer; k: Integer): Integer
    begin
        exit(NEdges.Get(NFirstChild.Get(Node) + k));
    end;

    // "Text, Integer" — the argument types of a call that matched no overload (ALI916).
    local procedure NativeArgTypesText(var Ast: Codeunit "ALI Ast Store"; Node: Integer; ArgCount: Integer): Text
    var
        k: Integer;
        Result: Text;
    begin
        for k := 1 to ArgCount do begin
            if k > 1 then
                Result += ', ';
            Result += TypeRules.TypeName(Ast.GetTypeOrd(NativeArgNode(Node, k)));
        end;
        exit(Result);
    end;

    // ===== M11 phase C3 — Codeunit.Run =====
    //
    // Run is the one cross-object call that does NOT go through the harvester. The codeunit is
    // executed by the PLATFORM (native `Codeunit.Run`), so its OnRun — and every procedure OnRun
    // reaches — is never lexed, parsed, bound or lowered. That is what makes it both fast (no
    // compile of a foreign dependency graph) and total (no ALI feature gap can block it: DotNet,
    // reports, pages, whatever the codeunit uses is the platform's problem, not the interpreter's).
    //
    // The error contract falls out of native AL for free: `Codeunit.Run` returns a Boolean and
    // swallows the error when the result is consumed, and raises when it is discarded. No
    // interpreted error trap is needed — which is exactly the piece the ROADMAP called the hard
    // part of this phase, and which native execution sidesteps entirely.
    //
    //   *** Divergence from native AL, deliberate: `MyCU.Run` runs a FRESH platform instance. ***
    //
    // An interpreted `MyCU.Proc()` mutates the phase-B2 instance block ALI keeps in its own
    // register bank; the platform instance behind `MyCU.Run` cannot see that block and vice versa.
    // Mixing the two on one variable would silently split the state, so it is refused (ALI928)
    // whenever the pre-scan saw the same variable used for a procedure call — see MarkCodeunitVarProcUse.

    // `Codeunit` as the receiver of a member call: the STATIC form. The receiver is a keyword
    // TOKEN, not a variable, so this has to be tested before anything calls Symbols.Lookup on it
    // (a keyword token carries no interned NameId — see BindOptionAccess for the same rule).
    local procedure IsCodeunitKeywordReceiver(var Tokens: Codeunit "ALI Token Table"; RecvNode: Integer): Boolean
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        exit(Tokens.GetKind(NMainTok.Get(RecvNode)) = 138);      // CodeunitKeyword
    end;

    // `Codeunit.Run(id[, Rec])`. Run is the only member the Codeunit keyword has.
    local procedure BindCodeunitStaticRun(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        MethodName: Text;
    begin
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        if UpperCase(MethodName) <> 'RUN' then begin
            Diags.AddError('ALI961', StrSubstNo('''Codeunit.%1'' is not a recognized method — the only static member of Codeunit is Run(id [, Rec])', MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node);
        exit(BindRunCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, 0, true, ArgCount, IsStatement));
    end;

    // Shared body of both Run shapes.
    //   static   — IdFromArg, argument 1 is the object id, argument 2 the optional record.
    //   instance — CodeunitId is already known, argument 1 is the optional record.
    // Lowerer contract: SymbolId = CodeunitRunMark(), SlotIndex = the compile-time codeunit id
    // (0 for the static form, whose id is an ordinary expression the lowerer evaluates).
    local procedure BindRunCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; CodeunitId: Integer; IdFromArg: Boolean; ArgCount: Integer; IsStatement: Boolean): Integer
    var
        Registry: Codeunit "ALI Object Registry";
        IdT: Integer;
        MaxArgs: Integer;
        MinArgs: Integer;
        RecArgNode: Integer;
        RecArgPos: Integer;
        RecSid: Integer;
        RecT: Integer;
    begin
        MinArgs := 0;
        if IdFromArg then
            MinArgs := 1;
        MaxArgs := MinArgs + 1;
        if (ArgCount < MinArgs) or (ArgCount > MaxArgs) then begin
            Diags.AddError('ALI926', StrSubstNo('Run expects %1 or %2 arguments, got %3', MinArgs, MaxArgs, ArgCount), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        RecArgPos := MinArgs + 1;                   // child index of the record argument, if given
        if IdFromArg then begin
            IdT := BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 1));
            if IdT = "ALI TypeKind"::ErrorType then
                exit("ALI TypeKind"::ErrorType);    // poisoned upstream (§6.2)
            // ObjectId (`Codeunit::"X"`) and Integer are the same Int register; nothing else is
            // an object number.
            if (IdT <> "ALI TypeKind"::ObjectId) and (IdT <> "ALI TypeKind"::Integer) then begin
                Diags.AddError('ALI931', StrSubstNo('The first argument of Codeunit.Run must be a codeunit id (Codeunit::"X" or an Integer), not %1', TypeRules.TypeName(IdT)), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
        end;

        if ArgCount = MaxArgs then begin
            RecArgNode := NEdges.Get(NFirstChild.Get(Node) + RecArgPos);
            RecT := BindExpr(Tokens, Ast, Symbols, Diags, RecArgNode);
            if RecT = "ALI TypeKind"::ErrorType then
                exit("ALI TypeKind"::ErrorType);
            RecSid := Ast.GetSymbolId(RecArgNode);
            // Native AL takes the record BY REFERENCE, so the argument has to be a record
            // VARIABLE — there is nothing to alias in `Codeunit.Run(id, GetCust())`.
            if (RecT <> "ALI TypeKind"::Record) or (NKind.Get(RecArgNode) <> "ALI NodeKind"::NameExpr) or (RecSid <= 0) then begin
                Diags.AddError('ALI931', 'The record argument of Run must be a record VARIABLE (it is passed by reference)', TokPos(Tokens, NMainTok.Get(RecArgNode)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
        end;

        Ast.SetSymbolId(Node, CodeunitRunMark());
        Ast.SetSlotIndex(Node, CodeunitId);
        exit("ALI TypeKind"::Boolean);
    end;

    // ===== Static Page.Run / Report.Run / File.* — native catalogue under a pseudo id =====
    //
    // Unlike Codeunit.Run these need no opcode of their own: nothing about them is interpreted
    // (no Boolean/raise contract to reproduce, no implicit commit), so they are plain native
    // catalogue rows ("ALI Builtin Registry".FileNativeId) and ride CALL_BUILTIN_LIVE like
    // `TypeHelper.UrlEncode`. The receiver is annotated CodeunitRef, i.e. "no value, not an
    // operand" — the lowerer's test for the stateless catalogue.

    // Pseudo codeunit id of a static receiver, 0 when RecvNode is not one. `Page` / `Report`
    // are keyword tokens and nothing else can mean them. `File` is an ordinary identifier: a
    // variable of that name wins, and so does any member the catalogue does not list (the call
    // then fails exactly as it did before this arm existed).
    local procedure StaticNativeReceiverId(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer; CalleeNode: Integer): Integer
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(0);
        case Tokens.GetKind(NMainTok.Get(RecvNode)) of
            140:                                            // PageKeyword
                exit(Builtins.PageNativeId());
            141:                                            // ReportKeyword
                exit(Builtins.ReportNativeId());
            20:                                             // IdentifierToken
                if UpperCase(Tokens.GetIdentText(NMainTok.Get(RecvNode))) = 'FILE' then
                    if Symbols.Lookup(Ast.GetExtra(RecvNode)) = 0 then
                        if Builtins.IsNativeMethod(Builtins.FileNativeId(), UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)))) then
                            exit(Builtins.FileNativeId());
        end;
        exit(0);
    end;

    local procedure BindStaticNativeCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; RecvNode: Integer; PseudoId: Integer; IsStatement: Boolean): Integer
    var
        Registry: Codeunit "ALI Object Registry";
        ArgCount: Integer;
        BId: Integer;
        MethodName: Text;
        ReceiverName: Text;
    begin
        // A paren-less call has no InvocationExpr: Node IS the member access, 0 arguments.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node);
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        ReceiverName := 'File';
        if PseudoId = Builtins.PageNativeId() then
            ReceiverName := 'Page';
        if PseudoId = Builtins.ReportNativeId() then
            ReceiverName := 'Report';

        BId := Builtins.ResolveNative(PseudoId, UpperCase(MethodName));
        if BId = 0 then begin
            Diags.AddError('ALI961', StrSubstNo('''%1.%2'' is not supported — the static members ALI runs are Page.Run(id [, Rec [, FieldNo]]) and Report.Run(id [, RequestWindow [, SystemPrinter [, Rec]]])', ReceiverName, MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        Ast.SetTypeOrd(RecvNode, "ALI TypeKind"::CodeunitRef);
        exit(BindNativeCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, BId, ArgCount, false, IsStatement));
    end;

    // Invocation (M5): user procedures (CALL) + the builtin Error(msg) statement.
    // Other builtins are diagnosed forward-compatibly (M7).
    // Lowerer contracts: Error() invocation -> SymbolId = -1; user proc -> SymbolId = proc
    // symbol id (positive).
    local procedure BindInvocation(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; IsStatement: Boolean): Integer
    var
        ArgsBound: Boolean;
        ArgCount: Integer;
        BId: Integer;
        CalleeNode: Integer;
        MemberResultT: Integer;
        Sid: Integer;
        NameText: Text;
        UpperName: Text;
    begin
        CalleeNode := NEdges.Get(NFirstChild.Get(Node) + 0);
        ArgCount := Ast.GetExtra(Node);

        // Method call `Target.Method(args)` — callee is a MemberAccessExpr (M6: record +
        // stream methods; M7 §19.4: Text/Code member-accessors). Peek the receiver type.
        if NKind.Get(CalleeNode) = "ALI NodeKind"::MemberAccessExpr then begin
            if TryDispatchMemberMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement, MemberResultT) then
                exit(MemberResultT);
            exit(BindRecordMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement));
        end;

        if NKind.Get(CalleeNode) <> "ALI NodeKind"::NameExpr then begin
            Diags.AddError('ALI934', 'Method calls are not supported yet (M6+/M11)', TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        NameText := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        UpperName := UpperCase(NameText);

        // `System.Evaluate(...)`: the qualifier names the SYSTEM builtin explicitly, so neither a
        // same-named procedure in scope nor an implicit record method may claim the call.
        if Ast.GetForceBuiltin(CalleeNode) then
            Sid := 0
        else
            Sid := Symbols.Lookup(Ast.GetExtra(CalleeNode));
        if Sid <> 0 then begin
            if Symbols.GetKind(Sid) <> Symbols.KindProc() then begin
                Diags.AddError('ALI938', StrSubstNo('''%1'' is not a procedure', NameText), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
                BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
                exit("ALI TypeKind"::ErrorType);
            end;
            // M11 phase A: inside a harvested object, a bare call names a SIBLING procedure,
            // which takes the implicit receiver — not an ordinary script-local call.
            if TryBindSiblingProcCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, Sid, ArgCount, IsStatement, MemberResultT) then
                exit(MemberResultT);
            Sid := ResolveOverload(Tokens, Ast, Symbols, Diags, Node, Ast.GetExtra(CalleeNode), Sid, ArgCount, ArgsBound);
            exit(BindUserProcCall(Tokens, Ast, Symbols, Diags, Node, Sid, NameText, IsStatement, Ast.GetExtra(Node), ArgsBound, 0));
        end;

        // M11: `CalcFields(x)` / `SetRange(f, v)` with no receiver, inside a harvested table
        // procedure — the record's own method. Member-first, so this precedes builtin lookup.
        if not Ast.GetForceBuiltin(CalleeNode) then
            if TryBindImplicitRecMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement, MemberResultT) then
                exit(MemberResultT);

        // Legacy unqualified `DownloadFromStream(...)` / `UploadIntoStream(...)`: the same
        // platform methods as `File.X`, so the same catalogue rows. Ahead of ResolveByName, which
        // would find the old DownloadFromStream unimplemented row (kept for its BuiltinId).
        if (UpperName = 'DOWNLOADFROMSTREAM') or (UpperName = 'UPLOADINTOSTREAM') then
            exit(BindNativeCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, Builtins.ResolveNative(Builtins.FileNativeId(), UpperName), ArgCount, false, IsStatement));

        BId := Builtins.ResolveByName(UpperName);
        if BId = 0 then begin
            Diags.AddError('AL0118', StrSubstNo('The name ''%1'' does not exist in the current context', NameText) + SuggestFrom(NameText, SuggestCatalog.BuiltinNames()), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        if (UpperName = 'ERROR') and (ArgCount = 1) and IsStatement then begin
            // M5-era single-arg fast path kept byte-for-byte (ERROR_RAISE contract; tests
            // depend on SymbolId=-1). Multi-arg / expression-context Error(...) falls through
            // to the general builtin path below (CALL_BUILTIN, §1.1 variadic Error).
            BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 1));
            Ast.SetSymbolId(Node, -1);      // lowerer contract: ERROR_RAISE
            exit("ALI TypeKind"::None);
        end;

        exit(BindBuiltinCall(Tokens, Ast, Symbols, Diags, Node, BId, NameText, UpperName, ArgCount, IsStatement));
    end;

    // ===== M7 builtin calls (§1.1/§8/§19.8) =====
    //
    // Lowerer contract: node SymbolId = BuiltinCallMark() - BId (a THIRD distinct negative
    // range, clear of RecMethodMark(-1000)/StreamMethodMark(-2000)/Error(-1)/user-proc(>0)).
    // Arg nodes are bound normally and left as children 1..ArgCount; the lowerer evaluates
    // each into a live register and pushes it into the CONCAT_N-style operand pool exactly
    // like REC_GET (§7.5) — no eager Variant boxing at bind/lower time.
    procedure BuiltinCallMark(): Integer
    begin
        exit(-3000);
    end;

    local procedure BindBuiltinCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; BId: Integer; NameText: Text; UpperName: Text; ArgCount: Integer; IsStatement: Boolean): Integer
    var
        MaxA: Integer;
        MinA: Integer;
        ResultT: Integer;
    begin
        if Builtins.IsUnimplemented(BId) then begin
            Diags.AddError('ALI982', UnimplementedBuiltinText(NameText, BId), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        MinA := Builtins.GetMinArity(BId);
        MaxA := Builtins.GetMaxArity(BId);
        if (ArgCount < MinA) or (ArgCount > MaxA) then begin
            Diags.AddError('ALI916', StrSubstNo('The built-in function ''%1'' expects between %2 and %3 argument(s), but %4 were provided', NameText, MinA, MaxA, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        // Evaluate/Clear need a var-param-like target (§ builtin System) — handled specially:
        // arg 1 must be an assignable simple variable; it is bound but NOT type-converted
        // (the runtime writes into it directly via its own slot, native Evaluate semantics).
        if (UpperName = 'EVALUATE') or (UpperName = 'CLEAR') then
            exit(BindTargetingBuiltin(Tokens, Ast, Symbols, Diags, Node, BId, NameText, UpperName, ArgCount, IsStatement));

        // Array intrinsics take array-VARIABLE operands (not boxable into a Variant) — bound
        // specially, mirroring Evaluate/Clear's target handling (§ array intrinsics).
        if (UpperName = 'ARRAYLEN') or (UpperName = 'COMPRESSARRAY') or (UpperName = 'COPYARRAY') then
            exit(BindArrayBuiltin(Tokens, Ast, Symbols, Diags, Node, BId, NameText, UpperName, ArgCount, IsStatement));

        BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);

        // CopyStream's two stream operands travel the generic value path (a stream is an Int
        // handle register), so only their DIRECTION needs checking — same ALI968 contract as
        // the stream methods.
        if UpperName = 'COPYSTREAM' then begin
            CheckStreamArg(Tokens, Ast, Diags, Node, 1, "ALI TypeKind"::OutStream, 'CopyStream requires an OutStream as its first argument');
            CheckStreamArg(Tokens, Ast, Diags, Node, 2, "ALI TypeKind"::InStream, 'CopyStream requires an InStream as its second argument');
        end;

        // Format(Value, Length, FormatStr): argument 2 is the LENGTH. A format string there
        // (`Format(Amt, '<0,###,##0.00>')`, the .NET/Excel habit) binds against the untyped
        // registry row and only fails at run time as a Variant -> Integer conversion error.
        if (UpperName = 'FORMAT') and (ArgCount >= 2) then
            if TypeRules.IsTextFamily(Ast.GetTypeOrd(NEdges.Get(NFirstChild.Get(Node) + 2))) then
                Diags.AddError('ALI932', 'Format argument 2 is the Length (Integer), not a format string: Format(Value, Length, FormatString)', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(Node) + 2))), 0);

        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);
        ResultT := Builtins.GetResultType(BId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The built-in function ''%1'' does not return a value', NameText), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // Argument Idx (1-based) of an already-bound call must be of stream type WantT. Silent on
    // ErrorType — the arg's own diagnostic was already reported (mirrors RequireBool).
    local procedure CheckStreamArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; Idx: Integer; WantT: Integer; Msg: Text)
    var
        ArgNode: Integer;
        T: Integer;
    begin
        ArgNode := NEdges.Get(NFirstChild.Get(Node) + Idx);
        T := Ast.GetTypeOrd(ArgNode);
        if (T <> WantT) and (T <> "ALI TypeKind"::ErrorType) then
            Diags.AddError('ALI968', Msg, TokPos(Tokens, Ast.GetMainToken(ArgNode)), 0);
    end;

    // Evaluate(var target, text[, format]) / Clear(var target): arg 1 must be a plain
    // assignable local/global/param variable (no var-param passthrough, no field/array
    // element — v1 scope decision, mirrors the SetRange/Validate field-arg restriction
    // style already used for record methods). SlotIndex carries the target's own TypeOrd so
    // the lowerer/interpreter can emit the correctly-typed native Evaluate/default-reset.
    local procedure BindTargetingBuiltin(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; BId: Integer; NameText: Text; UpperName: Text; ArgCount: Integer; IsStatement: Boolean): Integer
    var
        k: Integer;
        TargetNode: Integer;
        TargetSid: Integer;
        TargetT: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + 1);
        BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        TargetSid := Ast.GetSymbolId(TargetNode);
        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (TargetSid <= 0) or (not Symbols.IsVariableKind(TargetSid)) then begin
            Diags.AddError('ALI917', StrSubstNo('The first argument of %1 must be an assignable variable', NameText), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TargetT := Symbols.GetType(TargetSid);
        if UpperName = 'EVALUATE' then begin
            if not (TypeRules.IsTextFamily(TargetT) or TypeRules.IsNumeric(TargetT) or (TargetT = "ALI TypeKind"::Boolean) or
                    (TargetT = "ALI TypeKind"::Date) or (TargetT = "ALI TypeKind"::Time) or (TargetT = "ALI TypeKind"::DateTime) or
                    (TargetT = "ALI TypeKind"::RecordID) or (TargetT = "ALI TypeKind"::DateFormula))
            then begin
                Diags.AddError('ALI917', StrSubstNo('Evaluate does not support target type %1', TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            for k := 2 to ArgCount do
                CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + k), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + k)));
        end;
        Ast.SetSlotIndex(Node, TargetT);        // lowerer contract: target's own TypeOrd
        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);

        if UpperName = 'CLEAR' then begin
            if not IsStatement then begin
                Diags.AddError('ALI929', 'Clear(...) does not return a value', TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            exit("ALI TypeKind"::None);
        end;

        exit("ALI TypeKind"::Boolean);   // Evaluate -> Bool (success)
    end;

    // ArrayLen/CompressArray/CopyArray. Array operands must be plain array VARIABLES (native
    // AL forbids a bare array as a value / Variant, so the generic value-arg path can't carry
    // them); scalar operands (Position/Length/Dimension) bind normally as Integer. Each array
    // arg NameExpr is annotated with its own array Sid + TArray TypeOrd so the lowerer can
    // recover base slot / element class / length (mirrors LowerArrayLoad's array-var read).
    local procedure BindArrayBuiltin(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; BId: Integer; NameText: Text; UpperName: Text; ArgCount: Integer; IsStatement: Boolean): Integer
    var
        DimVal: Integer;
        ElemT: Integer;
        Rank: Integer;
        Sid1: Integer;
        Sid2: Integer;
    begin
        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);

        case UpperName of
            'ARRAYLEN':
                begin
                    Sid1 := BindArrayVarArg(Tokens, Ast, Symbols, Diags, Node, 1, NameText);
                    if Sid1 = 0 then
                        exit("ALI TypeKind"::ErrorType);
                    Rank := Symbols.GetArrayRank(Sid1);
                    // §20.9(5): ArrayLen(a) (no dim) = N1 (native returns the FIRST dimension
                    // size, not the total — a change from the 1-D-only behaviour where the two
                    // coincided). ArrayLen(a, dim) requires a literal dim so it stays a
                    // compile-time constant fold (v1: non-literal dim is rejected).
                    if ArgCount = 2 then begin
                        if not TryLiteralIntValue(Tokens, Ast, NEdges.Get(NFirstChild.Get(Node) + 2), DimVal) then begin
                            Diags.AddError('ALI986', 'ArrayLen dimension must be a literal integer constant', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(Node) + 2))), 0);
                            exit("ALI TypeKind"::ErrorType);
                        end;
                        if (DimVal < 1) or (DimVal > Rank) then begin
                            Diags.AddError('ALI986', StrSubstNo('ArrayLen dimension must be between 1 and %1 (got %2)', Rank, DimVal), TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(Node) + 2))), 0);
                            exit("ALI TypeKind"::ErrorType);
                        end;
                        Ast.SetSlotIndex(Node, DimVal);
                    end else
                        Ast.SetSlotIndex(Node, 1);
                    exit("ALI TypeKind"::Integer);
                end;
            'COMPRESSARRAY':
                begin
                    Sid1 := BindArrayVarArg(Tokens, Ast, Symbols, Diags, Node, 1, NameText);
                    if Sid1 = 0 then
                        exit("ALI TypeKind"::ErrorType);
                    ElemT := ArrayElemType(Symbols.GetTypeArg(Sid1));
                    if not TypeRules.IsTextFamily(ElemT) then begin
                        Diags.AddError('ALI986', 'CompressArray requires a Text/Code array', TokPos(Tokens, Ast.GetMainToken(NEdges.Get(NFirstChild.Get(Node) + 1))), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    exit("ALI TypeKind"::Integer);
                end;
            'COPYARRAY':
                begin
                    if not IsStatement then begin
                        Diags.AddError('ALI929', 'CopyArray(...) does not return a value', TokPos(Tokens, NMainTok.Get(Node)), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    Sid1 := BindArrayVarArg(Tokens, Ast, Symbols, Diags, Node, 1, NameText);
                    Sid2 := BindArrayVarArg(Tokens, Ast, Symbols, Diags, Node, 2, NameText);
                    if (Sid1 = 0) or (Sid2 = 0) then
                        exit("ALI TypeKind"::ErrorType);
                    if ArrayElemType(Symbols.GetTypeArg(Sid1)) <> ArrayElemType(Symbols.GetTypeArg(Sid2)) then begin
                        Diags.AddError('ALI986', 'CopyArray requires both arrays to have the same element type', TokPos(Tokens, NMainTok.Get(Node)), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    // Position (arg 3) and optional Length (arg 4): integer-convertible values.
                    CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + 3), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 3)));
                    if ArgCount = 4 then
                        CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + 4), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + 4)));
                    exit("ALI TypeKind"::None);
                end;
        end;
        exit("ALI TypeKind"::ErrorType);
    end;

    // Resolve arg #Idx as an array variable; annotate its NameExpr with the array Sid + TArray
    // TypeOrd (lowerer contract). Returns the array Sid, or 0 (with a diagnostic) if the arg is
    // not a plain array variable.
    local procedure BindArrayVarArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; Idx: Integer; NameText: Text): Integer
    var
        ArgNode: Integer;
        Sid: Integer;
    begin
        ArgNode := NEdges.Get(NFirstChild.Get(Node) + Idx);
        if NKind.Get(ArgNode) = "ALI NodeKind"::NameExpr then
            Sid := Symbols.Lookup(Ast.GetExtra(ArgNode))
        else
            Sid := 0;
        if (Sid <= 0) or (Symbols.GetType(Sid) <> "ALI TypeKind"::Array) then begin
            Diags.AddError('ALI986', StrSubstNo('Argument %1 of %2 must be an array variable', Idx, NameText), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
            exit(0);
        end;
        Ast.SetSymbolId(ArgNode, Sid);
        Ast.SetTypeOrd(ArgNode, "ALI TypeKind"::Array);
        exit(Sid);
    end;

    // A literal Int32 constant expression node -> its value (§20.9(5): ArrayLen(a, dim)
    // requires dim to be such a literal so the result stays a compile-time constant fold).
    local procedure TryLiteralIntValue(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; var Value: Integer): Boolean
    begin
        if NKind.Get(Node) <> "ALI NodeKind"::LiteralExpr then
            exit(false);
        if Tokens.GetKind(NMainTok.Get(Node)) <> 10 then       // 10 = Int32 literal
            exit(false);
        Value := Tokens.GetInt(Ast.GetExtra(Node));                // GetExtra = token-pool index (parser-stored)
        exit(true);
    end;

    // ===== §19.4 Text/Code member-accessors =====

    // Is a receiver expression Text-family (Text/Code/Label)? Same shape as IsStreamReceiver.
    local procedure IsTextReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        T: Integer;
    begin
        T := ExprTypePeek(Tokens, Ast, Symbols, RecvNode);
        exit(TypeRules.IsTextFamily(T));
    end;

    // ===== §19.2 Variant type-detection methods (`v.IsInteger()`, `v.IsText()`, ...) =====

    local procedure IsVariantReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    begin
        exit(ExprTypePeek(Tokens, Ast, Symbols, RecvNode) = "ALI TypeKind"::Variant);
    end;

    // The Variant type-detection methods return Boolean and take no arguments. They resolve to
    // the SAME builtin rows as the free-function spelling (registered arity 1 counting the
    // receiver, so the method form is arity 0) and lower through CALL_BUILTIN_LIVE with the
    // receiver pushed as operand 1 — no dedicated opcode. Non-Is* methods on a Variant error.
    local procedure IsVariantMethodName(UpperName: Text): Boolean
    begin
        exit((UpperName = 'ISINTEGER') or (UpperName = 'ISBIGINTEGER') or (UpperName = 'ISDECIMAL') or
             (UpperName = 'ISBOOLEAN') or (UpperName = 'ISTEXT') or (UpperName = 'ISCODE') or
             (UpperName = 'ISCHAR') or (UpperName = 'ISBYTE') or (UpperName = 'ISDATE') or
             (UpperName = 'ISTIME') or (UpperName = 'ISDATETIME') or (UpperName = 'ISDURATION') or
             (UpperName = 'ISGUID') or (UpperName = 'ISOPTION') or (UpperName = 'ISDATEFORMULA') or
             (UpperName = 'ISRECORDID') or (UpperName = 'ISRECORD') or (UpperName = 'ISLIST') or
             (UpperName = 'ISDICTIONARY') or (UpperName = 'ISARRAY'));
    end;

    local procedure BindVariantMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        BId: Integer;
        MethodName: Text;
        UpperName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));      // receiver
        // Paren-less method (`v.IsInteger`): Node is the MemberAccessExpr, its ExtraInt is the
        // member NameId, not an arg count — read 0. Dual-shape mirrors BindRecordMethod:2530.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        UpperName := UpperCase(MethodName);

        if not IsVariantMethodName(UpperName) then begin
            Diags.AddError('ALI941', StrSubstNo('Variant method ''%1'' is not supported', MethodName) + SuggestMethod('Variant', MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        if ArgCount <> 0 then begin
            Diags.AddError('ALI916', StrSubstNo('The method ''%1'' expects 0 argument(s), but %2 were provided', MethodName, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        BId := Builtins.ResolveByName(UpperName);
        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);
        exit("ALI TypeKind"::Boolean);
    end;

    // Peek an expression's type without re-binding side effects where possible; falls back
    // to a full bind for non-trivial receivers (e.g. `Format(1+2).Trim()`, `Foo().Trim()`)
    // against a THROWAWAY diag bag — safe because BindExpr is idempotent per node (AST
    // annotations are simply overwritten identically) and the real dispatch target
    // (BindTextMethod/BindRecordMethod) re-binds the same node against the REAL Diags right
    // after, so any diagnostics are still reported exactly once.
    local procedure ExprTypePeek(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Node: Integer): Integer
    var
        ScratchDiags: Codeunit "ALI Diag Bag";
        Sid: Integer;
    begin
        if NKind.Get(Node) = "ALI NodeKind"::NameExpr then begin
            Sid := Symbols.Lookup(Ast.GetExtra(Node));
            if Sid <> 0 then
                exit(Symbols.GetType(Sid));
            exit("ALI TypeKind"::None);
        end;
        exit(BindExpr(Tokens, Ast, Symbols, ScratchDiags, Node));
    end;

    // `s.Method(args)` where s is Text/Code-typed. Method name resolves through the SAME
    // registry rows as the free-function twin (§19.4 "one implementation"); Split is
    // special-cased below — it returns a List of [Text] (runtime allocates the handle).
    local procedure BindTextMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        BId: Integer;
        MaxA: Integer;
        MinA: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        MethodName: Text;
        UpperName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        UpperName := UpperCase(MethodName);

        // Split(sep1[, sep2]) -> List of [Text]. Bound as a builtin (SymbolId = builtin mark)
        // whose runtime allocates the List handle; the element class (Text) is stashed on
        // SlotIndex so ListDictTArgOf recovers it for List-assignment type checks — mirroring
        // the GetRange/Keys/Values shape in BindListMethod.
        if UpperName = 'SPLIT' then begin
            if (ArgCount < 1) or (ArgCount > 2) then begin
                Diags.AddError('ALI916', StrSubstNo('The method ''%1'' expects between %2 and %3 argument(s), but %4 were provided', MethodName, 1, 2, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
                BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
                exit("ALI TypeKind"::ErrorType);
            end;
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            Ast.SetSymbolId(Node, BuiltinCallMark() - Builtins.ResolveByName('SPLIT'));
            Ast.SetSlotIndex(Node, "ALI Register Class"::"Text");
            exit("ALI TypeKind"::List);
        end;

        BId := Builtins.ResolveByName(UpperName);
        if BId = 0 then begin
            Diags.AddError('ALI968', StrSubstNo('Text method ''%1'' is not supported', MethodName) + SuggestMethod('Text', MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        // Method-form arg count excludes the receiver (registry rows count the receiver as
        // param 1 to share shape with the free-function twin, e.g. CopyStr/Substring —
        // Substring(start[,len]) i.e. arity 1..2 as a METHOD vs 2..3 as a free function).
        MinA := Builtins.GetMinArity(BId) - 1;
        MaxA := Builtins.GetMaxArity(BId) - 1;
        if (ArgCount < MinA) or (ArgCount > MaxA) then begin
            Diags.AddError('ALI916', StrSubstNo('The method ''%1'' expects between %2 and %3 argument(s), but %4 were provided', MethodName, MinA, MaxA, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
        // Lowerer contract: same BuiltinCallMark() space; child 0 (the callee's own child 0,
        // i.e. the receiver) is READ BY THE LOWERER as the first operand-pool argument — the
        // method-call invocation node's children are [0]=MemberAccessExpr callee, [1..N]=args,
        // so the lowerer special-cases method dispatch to also push the receiver (from
        // CalleeNode child 0) as argument slot 1 ahead of the bound args (§ LowerBuiltinCall).
        Ast.SetSymbolId(Node, BuiltinCallMark() - BId);
        ResultT := Builtins.GetResultType(BId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // M11: `Cust.CalcBalance(a, b)` where CalcBalance is a procedure declared on table Cust.
    // Argument checking is the ORDINARY user-call path with RowShift = 1, because the callee's
    // descriptor row 1 is the implicit receiver — so arity, var-param lvalue rules, record-arg
    // rules and implicit conversions all behave exactly as they do for a script-local call.
    //
    // Lowerer contract: SymbolId = ObjectCallMark() (a sentinel, NOT a range — it is LESS
    // negative than every family mark, so the `Sym <= X` cascades cannot swallow it and each
    // dispatch site tests it explicitly), and SlotIndex carries the callee's proc SymbolId. The
    // receiver is not annotated anywhere: the lowerer recovers it structurally from the callee
    // node, the same way LowerHttpPropertyStore and friends already do.
    local procedure TryBindObjectProcCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; TableId: Integer; MethodName: Text; ArgCount: Integer; IsStatement: Boolean; var ResultT: Integer): Boolean
    var
        Registry: Codeunit "ALI Object Registry";
        ProcSid: Integer;
        BlockedReason: Text;
    begin
        if not Registry.TryLookupObjectProc("ALI Object Type"::Table.AsInteger(), TableId, MethodName, Symbols, ProcSid, BlockedReason) then begin
            // M11 phase A: the procedure EXISTS but did not compile (its object's other
            // procedures did). Say so here rather than let it fall through to ALI961's "no
            // procedure of that name", which would send the reader looking for a typo.
            if BlockedReason <> '' then begin
                // "or one of its extensions": the lookup that found it searched both, and the
                // registry does not report back which unit answered. Naming only the table sends
                // the reader to the wrong source file.
                Diags.AddError('ALI922', StrSubstNo('Procedure ''%1'' of table %2 (or one of its extensions) could not be compiled: %3', MethodName, TableId, BlockedReason), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
                BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
                ResultT := "ALI TypeKind"::ErrorType;
                exit(true);
            end;
            exit(false);
        end;

        ProcSid := PickArityOverload(Symbols, ProcSid, ArgCount);
        ResultT := BindUserProcCall(Tokens, Ast, Symbols, Diags, Node, ProcSid, MethodName, IsStatement, ArgCount, false, Symbols.GetProcHiddenCount(Symbols.GetProcId(ProcSid)));
        if ResultT = "ALI TypeKind"::ErrorType then
            exit(true);                     // resolved, but the call itself is in error

        // BindUserProcCall stamped the proc symbol on the node; replace it with the object-call
        // marker and keep the symbol where the lowerer expects to find it.
        Ast.SetSlotIndex(Node, ProcSid);
        Ast.SetSymbolId(Node, ObjectCallMark());
        exit(true);
    end;

    // M11 phase A: `Helper(x)` / `Helper` inside a harvested object procedure — a SIBLING
    // procedure of the same object, written WITHOUT a receiver exactly as native AL writes it.
    // Every procedure of a harvested unit carries the implicit `Rec` as descriptor row 1, so
    // this cannot ride the ordinary user-call path: its arity would be off by one and the
    // callee's receiver would be unbound. Same rewrite as a bare field name — attach the
    // CURRENT procedure's own `Rec` as receiver, then bind as an object call with RowShift = 1.
    // The receiver is a var-param alias, so caller and callee share one record, as in native AL.
    //
    // Any procedure symbol visible here is a sibling: a harvested unit's scope chain is proc
    // scope -> object scope -> root, and the script's module scope is not on it.
    //
    // ponytail: overload resolution is arity-only (PickArityOverload) — same-arity overloads of
    // an object procedure still resolve to the first declaration.
    // Upgrade path if that bites: give ResolveOverload a RowShift and use it here.
    local procedure TryBindSiblingProcCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; ProcSid: Integer; ArgCount: Integer; IsStatement: Boolean; var ResultT: Integer): Boolean
    begin
        // Any procedure of a harvested unit carries hidden rows; one with none is an ordinary
        // in-unit call and must NOT come through here (it would shift its arguments).
        if Symbols.GetProcHiddenCount(Symbols.GetProcId(ProcSid)) = 0 then
            exit(false);

        // A CODEUNIT sibling has no receiver to attach — only the instance index, which
        // LowerObjectCall forwards from this frame. A TABLE sibling gets both.
        if ImplicitRecSid > 0 then
            AttachImplicitReceiver(Ast, Symbols, CalleeNode);
        ProcSid := PickArityOverload(Symbols, ProcSid, ArgCount);
        ResultT := BindUserProcCall(Tokens, Ast, Symbols, Diags, Node, ProcSid, Tokens.GetIdentText(NMainTok.Get(CalleeNode)), IsStatement, ArgCount, false, Symbols.GetProcHiddenCount(Symbols.GetProcId(ProcSid)));
        if ResultT <> "ALI TypeKind"::ErrorType then begin
            Ast.SetSlotIndex(Node, ProcSid);
            Ast.SetSymbolId(Node, ObjectCallMark());
        end;
        exit(true);
    end;

    // ALI961 text. The three ways to land here are indistinguishable to the user but have very
    // different fixes, so the message names which one it is: the feature is off, the feature is
    // on but neither the table nor any of its tableextensions has such a procedure (or readable
    // source), or the receiver was an expression rather than a variable and the pre-scan never
    // looked (see HarvestObjectRefs).
    local procedure UnknownRecordMethodText(var Tokens: Codeunit "ALI Token Table"; TableId: Integer; MemberTok: Integer): Text
    var
        Registry: Codeunit "ALI Object Registry";
        MethodName: Text;
        Suggestion: Text;
    begin
        MethodName := Tokens.GetIdentText(MemberTok);
        // A close built-in name is by far the likelier cause (`SetAutoCalcField`): say only that.
        Suggestion := SuggestMethod('Record', MethodName);
        if Suggestion <> '' then
            exit(StrSubstNo('''%1'' is not a record method.%2', MethodName, Suggestion));
        exit(StrSubstNo('''%1'' is not a built-in record method, and neither table %2 nor any of its tableextensions has a procedure of that name with readable source. Note that the receiver of such a call must be a record VARIABLE.', MethodName, TableId) + Registry.NoSourceReason());
    end;

    // Marker SymbolId for a call to a procedure declared on a table (M11). Deliberately the
    // LEAST negative marker (-500, above RecMethodMark's -1000): every other family is matched
    // by a `Sym <= mark` cascade, and a more negative value would be captured by the first arm
    // of every one of them. Tested only by exact equality.
    procedure ObjectCallMark(): Integer
    begin
        exit(-500);
    end;

    // Marker SymbolId for `Codeunit.Run(id[, Rec])` / `MyCU.Run([Rec])` (M11 phase C3). Same
    // sentinel family as ObjectCallMark — tested by exact equality, never by a `<=` cascade.
    // SlotIndex carries the compile-time codeunit id for the INSTANCE form, and 0 for the
    // static form (whose id is argument 1 and may be any Integer expression).
    procedure CodeunitRunMark(): Integer
    begin
        exit(-501);
    end;

    // ===== M6 record methods (§7.5) =====
    //
    // `Rec.Method(args)` where the callee is a MemberAccessExpr over a record variable.
    // Lowerer contract: the invocation node's SymbolId is set to RecMethodMark() - methodId
    // (a distinct negative range from Error()=-1 and user procs>0); SlotIndex carries the
    // field number for SetRange/Validate. Argument nodes are bound normally EXCEPT the
    // leading field argument of SetRange/Validate, which is resolved as a field reference.
    //
    // Method ids: 1 Init 2 Reset 3 Insert 4 Modify 5 Delete 6 DeleteAll 7 Get 8 FindSet
    // 9 FindFirst 10 FindLast 11 Next 12 Count 13 IsEmpty 14 SetRange 15 Validate.
    local procedure BindRecordMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        k: Integer;
        MethodId: Integer;
        MethodNameId: Integer;
        RecNode: Integer;
        RecSid: Integer;
        RecT: Integer;
        ResultT: Integer;
        TableId: Integer;
        MethodName: Text;
    begin
        RecNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        RecT := BindExpr(Tokens, Ast, Symbols, Diags, RecNode);
        // Invocation nodes carry the arg count in ExtraInt; a bare MemberAccessExpr method
        // call (no parentheses, Node = CalleeNode) has no args, and its ExtraInt is the member
        // NameId, not a count — so read 0 there.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        if RecT = "ALI TypeKind"::ErrorType then begin
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        if (RecT <> "ALI TypeKind"::Record) and (RecT <> "ALI TypeKind"::RecordRef) then begin
            // M11: the receiver is now BOUND, and binding it may have changed its shape — a bare
            // field name inside a harvested table procedure is rewritten to `Rec.<field>` by
            // TryBindImplicitField during the BindExpr above. The Is*Receiver predicates in
            // TryDispatchMemberMethod are structural and ran BEFORE that, on the invocation path,
            // so a receiver family they could not recognise then may be recognisable now
            // (`"Some Blob".HasValue()`, `"Some RecordId".TableNo()`, ...). Retry the dispatch
            // once, against the settled tree, before declaring the call invalid.
            if TryDispatchMemberMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement, ResultT) then
                exit(ResultT);
            Diags.AddError('ALI934', StrSubstNo('Method calls require a record variable (got %1)', TypeRules.TypeName(RecT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        RecSid := Ast.GetSymbolId(RecNode);
        // P1 routing: a RecordRef receiver reaches this procedure through BindRecordRefMethod,
        // which has already checked that the method needs NO bind-time table id. TableId 0 is
        // the "table unknown until run time" marker every field-resolving helper below would
        // choke on — the allow-list in RecordRefRoutesToRecordMethod is what guarantees none of
        // them runs. It is also read by BindRecArg, where it means "check the record argument's
        // table at run time instead" (there is nothing to compare against here).
        if RecT = "ALI TypeKind"::RecordRef then
            TableId := 0
        else
            TableId := Symbols.GetTypeArg(RecSid);

        MethodNameId := Ast.GetExtra(CalleeNode);
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := RecMethodId(MethodName);
        if MethodId = 0 then begin
            // M11: not a built-in record method — it may be a procedure declared on the TABLE
            // itself. HarvestObjectRefs already compiled it (this is a cache lookup, no Module
            // needed here); anything it could not resolve falls through to ALI961 below.
            if TryBindObjectProcCall(Tokens, Ast, Symbols, Diags, Node, CalleeNode, TableId, Tokens.GetIdentText(NMainTok.Get(CalleeNode)), ArgCount, IsStatement, ResultT) then
                exit(ResultT);
            Diags.AddError('ALI961', UnknownRecordMethodText(Tokens, TableId, NMainTok.Get(CalleeNode)), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1, 2:       // Init / Reset — no args
                CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
            3, 4, 5, 6: // Insert / Modify / Delete / DeleteAll -> Bool — 0 or 1 (bool trigger). Each
                        // carries AL's optional Boolean return: consuming it (`if Rec.Insert() then`)
                        // suppresses the runtime error and returns false; a bare statement throws.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            7:          // Get([keyValue, ...up to 16]) -> Bool — one arg per PK field. 0 args is the
                        // documented default form (Get with the record's current field values).
                        // Get(RecordID) is a distinct 1-arg overload: a single RecordID-typed
                        // argument bypasses the per-field-key shape entirely (lowerer picks the
                        // opcode by peeking the bound arg's TypeOrd, §7.5 REC_GET_BY_ID).
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 16);
                    for k := 1 to ArgCount do
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            8:      // FindSet([ForUpdate]) — ForUpdate is const-folded (§7.5 BoolFlagFromArg
                    // convention), same as Insert/Modify's trigger flag; still type-checked here.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            9, 10:   // FindFirst / FindLast -> Bool (no ForUpdate overload)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            11:         // Next([Step]) -> Integer
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            12:         // Count -> Integer
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            13:         // IsEmpty -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            14:         // SetRange(field [, value [, toValue]]) — native arity 1..3: 1 arg clears the
                        // field's filter, 2 args = equality, 3 args = from..to range. Value args are
                        // bound + assignment-checked to the field type; field arg is a field ref.
                BindRecFieldFirst(Tokens, Ast, Symbols, Diags, Node, TableId, MethodName, ArgCount, 1, 3);
            15:         // Validate(field, value)
                BindRecFieldFirst(Tokens, Ast, Symbols, Diags, Node, TableId, MethodName, ArgCount, 2, 2);
            16:         // Rename(keyValue [, ...up to 16]) — one arg per PK field, same shape as Get
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 16);
                    for k := 1 to ArgCount do
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k));
                end;
            17:         // Copy(Record [, Boolean])
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 2);
                    if ArgCount >= 1 then
                        BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            18:         // TransferFields(var Record [, Boolean [, Boolean]])
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 3);
                    if ArgCount >= 1 then
                        BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    for k := 2 to ArgCount do
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, k), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k)));
                end;
            19:         // CopyFilters(var Record)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    if ArgCount = 1 then
                        BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                end;
            20:         // SetRecFilter() — no args
                CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
            21:         // Truncate([Boolean])
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            23:         // IsTemporary() -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            24:         // CountApprox() -> Integer
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            25, 26:     // ReadPermission() / WritePermission() -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            27:         // SetFilter(field, filterText [, value, ...]) — args 3..16 are the values
                        // substituted into the filter expression's %1..%14 placeholders. They stay
                        // raw (no option->caption widening): native SetFilter substitutes an
                        // Option/Enum as its ordinal, which is what a filter expects.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 2, 16);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    for k := 3 to ArgCount do
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k));
                end;
            28:         // GetFilter(field) -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    ResultT := "ALI TypeKind"::Text;
                end;
            29:         // CopyFilter(fromField, toField) — both field args resolved to field nos,
                        // each stashed on its own arg node's SlotIndex. The TARGET may be a field
                        // of ANOTHER record (`Rec.CopyFilter(A, Other.B)`), which is the shape
                        // most real AL uses; see BindCopyFilterTargetArg.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 2, 2);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    BindCopyFilterTargetArg(Tokens, Ast, Symbols, Diags, Node, TableId, MethodName);
                end;
            30, 31:     // GetRangeMin(field) / GetRangeMax(field) -> field's own type
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    ResultT := BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    if ResultT = 0 then
                        ResultT := "ALI TypeKind"::ErrorType;
                end;
            32:         // ModifyAll(field, value, [Boolean]) -> Bool (optional return; consuming it
                        // suppresses a failing row-Modify and returns false, same as Modify)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 2, 3);
                    BindRecFieldFirst(Tokens, Ast, Symbols, Diags, Node, TableId, MethodName, 2, 2, 2);
                    if ArgCount = 3 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            33, 34:     // CalcFields(field,...) / CalcSums(field,...) — every arg is a field name
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 16);
                    for k := 1 to ArgCount do
                        BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, k, TableId, MethodName);
                end;
            35:         // TestField(field [, value]) — 1 arg = non-zero/non-blank check; 2 args =
                        // value-match check (ErrorInfo overloads not modeled, per scope decision)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 2);
                    if ArgCount = 1 then
                        BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName)
                    else
                        BindRecFieldFirst(Tokens, Ast, Symbols, Diags, Node, TableId, MethodName, ArgCount, 2, 2);
                end;
            36:         // FieldError(field [, Text]) — ErrorInfo overload not modeled
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 2);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            37, 38:     // FieldName(field) / FieldCaption(field) -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    ResultT := "ALI TypeKind"::Text;
                end;
            39, 40, 41: // TableName() / TableCaption() / FullyQualifiedName() -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Text;
                end;
            42:         // SetCurrentKey(field,...) — every arg is a field name
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 16);
                    for k := 1 to ArgCount do
                        BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, k, TableId, MethodName);
                end;
            43:         // Ascending([Boolean]) — 0 args = getter (-> Bool), 1 arg = setter (void)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Boolean;
                end;
            44:         // SetAscending(field, Boolean)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 2, 2);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            45:         // GetAscending(field) -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            46:         // CurrentKey() -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Text;
                end;
            47:         // Mark([Boolean]) — 0 args = getter (-> Bool), 1 arg = setter (void)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Boolean;
                end;
            48:         // ClearMarks() — no args
                CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
            49:         // MarkedOnly([Boolean]) — 0 args = getter (-> Bool), 1 arg = setter (void)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Boolean;
                end;
            50:         // GetPosition([Boolean]) -> Text — the optional bool tweaks output detail
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Text;
                end;
            51:         // SetPosition(Text)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            52:         // GetView([Boolean]) -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Text;
                end;
            53:         // SetView(Text)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            54:         // ChangeCompany([Text])
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            55:         // CurrentCompany() -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Text;
                end;
            56:         // GetFilters() -> Text
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Text;
                end;
            57:         // HasFilter() -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            58, 59, 60, 61, 62:
                // SetAutoCalcFields / SetLoadFields / AddLoadFields / LoadFields /
                // AreFieldsLoaded(field,...) -> Bool. Every arg is a field name; 0 args is
                // the documented "reset" form (SetLoadFields() reloads all fields).
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 16);
                    for k := 1 to ArgCount do
                        BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, k, TableId, MethodName);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            63:         // LockTable([Boolean [, Boolean]]) — args are the wait/keep-cache flags
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 2);
                    for k := 1 to ArgCount do
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, k), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k)));
                end;
            64:         // ReadConsistency() -> Bool — getter only (this compiler exposes it like
                        // ReadPermission: an isProperty getter with no setter parameter)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            65, 67:     // FieldCount() / KeyCount() -> Integer
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            66:         // FieldExist(fieldNo) -> Bool — the arg is an Integer field NUMBER (a value
                        // expression), not a field-name identifier like CalcFields/GetFilter take.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            68:         // CurrentKeyIndex([Integer]) — 0 args = getter (-> Int), 1 arg = setter (void)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Integer;
                end;
            69:         // RecordId() -> RecordID
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::RecordID;
                end;
            70:         // FilterGroup([Integer]) -> Int — getter reads current group, setter activates
                        // the arg's group; both forms return an Integer (setter returns the prior group)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            71:         // Find([Text]) -> Bool — the Which selector is optional and defaults to '='
                        // (native AL semantics). Optional-return: consuming suppresses no-match.
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            72:         // GetBySystemId(Guid) -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Guid, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            73:         // AddLink(Text [, Text]) -> Integer (link id)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 2);
                    for k := 1 to ArgCount do
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, k), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            74:         // DeleteLink(Integer)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            75:         // DeleteLinks() — no args
                CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
            76:         // CopyLinks(var Record) — same-table record arg (see BindRecArg note)
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 1, 1);
                    BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, TableId, MethodName);
                end;
            77:         // HasLinks() -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            78:         // ReadIsolation([Integer]) — 0 args = getter (-> Int ordinal), 1 arg = setter.
                        // IsolationLevel exposed as its ordinal (Default 0..UpdLock 4).
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Integer;
                end;
            79:         // SetPermissionFilter() — no args
                CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
            80:         // SecurityFiltering([Integer]) — 0 args = getter (-> Int ordinal), 1 arg = setter.
                        // SecurityFilter exposed as its ordinal (Validated 0..Disallowed 3).
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 1);
                    if ArgCount = 1 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        ResultT := "ALI TypeKind"::Integer;
                end;
            81:         // RecordLevelLocking() -> Bool
                begin
                    CheckRecArgCount(Tokens, Ast, Diags, Node, MethodName, ArgCount, 0, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
        end;

        Ast.SetSymbolId(Node, RecMethodMark() - MethodId);      // lowerer contract
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The record method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // A single field-name argument at ArgIdx (GetFilter/CopyFilter/GetRangeMin/Max/CalcFields/
    // CalcSums/SetFilter's leading arg): a bare NameExpr naming a field of the record, NOT a
    // value. Resolves it and stashes the field number on the ARG NODE ITSELF (SlotIndex) so
    // multi-field-arg methods (CalcFields, CopyFilter) can read each one independently — the
    // single-slot-on-Node convention BindRecFieldFirst uses only fits ONE field arg per call.
    // Returns the field's own TypeKind (0 on failure, already diagnosed).
    local procedure BindRecFieldArgAt(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgIdx: Integer; TableId: Integer; MethodName: Text): Integer
    var
        FClass: Integer;
        FieldArg: Integer;
        FieldNameId: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
    begin
        FieldArg := NEdges.Get(NFirstChild.Get(Node) + ArgIdx);
        if NKind.Get(FieldArg) <> "ALI NodeKind"::NameExpr then begin
            Diags.AddError('ALI962', StrSubstNo('Argument %1 of %2 must be a field name', ArgIdx, MethodName), TokPos(Tokens, NMainTok.Get(FieldArg)), 0);
            exit(0);
        end;
        FieldNameId := Ast.GetExtra(FieldArg);
        if not RecMeta.TryFieldInfo(TableId, FieldNameId, FNo, FType, FLen, FClass) then begin
            Diags.AddError('AL0132', StrSubstNo('''%1'' is not a field of the record', Tokens.GetIdentText(NMainTok.Get(FieldArg))) + SuggestField(TableId, Tokens.GetIdentText(NMainTok.Get(FieldArg))), TokPos(Tokens, NMainTok.Get(FieldArg)), 0);
            exit(0);
        end;
        NoteFlowFieldCalc(TableId, FNo, MethodName);
        Ast.SetTypeOrd(FieldArg, FType);
        Ast.SetSlotIndex(FieldArg, FNo);
        exit(FType);
    end;

    // The TARGET argument of CopyFilter, which native AL lets name a field of a DIFFERENT record:
    // `Cust.CopyFilter("Date Filter", CustLedgEntry."Posting Date")` is the ordinary spelling, and
    // real table code (a tableextension pushing its filters onto a ledger record before drilling
    // down) is written almost entirely that way. Two shapes are accepted:
    //
    //   Field            a bare field of the RECEIVER's own table, exactly as before
    //   Other.Field      a field of another record variable's table
    //
    // The second is NOT bound as an expression — binding it would compile a field READ, and the
    // value of the target field is precisely what this call does not want. Only the receiver
    // variable of the member access is bound; the field is resolved against ITS table and the
    // number stashed on the arg node's SlotIndex, same convention as BindRecFieldArgAt. The
    // lowerer recovers the target record structurally from the arg node's shape (a NameExpr means
    // "the receiver itself"), the way it already recovers an object call's receiver.
    local procedure BindCopyFilterTargetArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; TableId: Integer; MethodName: Text)
    var
        ArgNode: Integer;
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        OtherSid: Integer;
        OtherTableId: Integer;
        RecvNode: Integer;
    begin
        ArgNode := NEdges.Get(NFirstChild.Get(Node) + 2);
        if NKind.Get(ArgNode) <> "ALI NodeKind"::MemberAccessExpr then begin
            BindRecFieldArgAt(Tokens, Ast, Symbols, Diags, Node, 2, TableId, MethodName);
            exit;
        end;

        RecvNode := NEdges.Get(NFirstChild.Get(ArgNode) + 0);
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then begin
            Diags.AddError('ALI962', StrSubstNo('The target of %1 must be a field name, optionally qualified by a record VARIABLE', MethodName), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
            exit;
        end;
        if BindExpr(Tokens, Ast, Symbols, Diags, RecvNode) <> "ALI TypeKind"::Record then begin
            Diags.AddError('ALI934', StrSubstNo('The target of %1 must be qualified by a record variable', MethodName), TokPos(Tokens, NMainTok.Get(RecvNode)), 0);
            exit;
        end;
        OtherSid := Ast.GetSymbolId(RecvNode);
        if OtherSid <= 0 then
            exit;                                       // poisoned receiver — bind already errored

        OtherTableId := Symbols.GetTypeArg(OtherSid);
        EnsureTablePopulated(Tokens, OtherTableId);
        if not RecMeta.TryFieldInfo(OtherTableId, Ast.GetExtra(ArgNode), FNo, FType, FLen, FClass) then begin
            Diags.AddError('AL0132', StrSubstNo('''%1'' is not a field of table %2', Tokens.GetIdentText(NMainTok.Get(ArgNode)), OtherTableId) + SuggestField(OtherTableId, Tokens.GetIdentText(NMainTok.Get(ArgNode))), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
            exit;
        end;
        Ast.SetTypeOrd(ArgNode, FType);
        Ast.SetSlotIndex(ArgNode, FNo);
    end;

    // A record-typed argument (Copy/TransferFields/CopyFilters): must be a NameExpr bound to
    // a record variable OF THE SAME TABLE. The lowerer reads the arg node's own SymbolId to
    // get its handle — no extra AST annotation needed beyond the normal BindExpr result.
    local procedure BindRecArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgIdx: Integer; TableId: Integer; MethodName: Text)
    var
        ArgNode: Integer;
        ArgSid: Integer;
        ArgT: Integer;
    begin
        ArgNode := NEdges.Get(NFirstChild.Get(Node) + ArgIdx);
        ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
        if ArgT = "ALI TypeKind"::ErrorType then
            exit;
        if ArgT <> "ALI TypeKind"::Record then begin
            Diags.AddError('ALI934', StrSubstNo('The argument for %1 must be a record variable (got %2)', MethodName, TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
            exit;
        end;
        ArgSid := Ast.GetSymbolId(ArgNode);
        if (NKind.Get(ArgNode) <> "ALI NodeKind"::NameExpr) or (ArgSid <= 0) then begin
            Diags.AddError('ALI934', StrSubstNo('The argument for %1 must be a record variable', MethodName), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
            exit;
        end;
        // TableId 0 = the receiver is a RecordRef, whose table is only known at run time (P1).
        // There is nothing to compare the argument against here; the runtime raises when the
        // two tables actually disagree (see "ALI Rec Runtime".SetTableRef and the native
        // RecordRef.Copy contract).
        if TableId = 0 then
            exit;
        if Symbols.GetTypeArg(ArgSid) <> TableId then
            Diags.AddError('ALI934', StrSubstNo('The argument for %1 must be a record of the same table', MethodName), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
    end;

    // SetRange/Validate: the FIRST argument is a field of the record (a bare NameExpr whose
    // name is a field), not a value. Resolve it to a field number, stash it on the node's
    // SlotIndex, and bind the remaining value arg(s) normally.
    local procedure BindRecFieldFirst(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; TableId: Integer; MethodName: Text; ArgCount: Integer; MinArgs: Integer; MaxArgs: Integer)
    var
        FClass: Integer;
        FieldArg: Integer;
        FieldNameId: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        i: Integer;
    begin
        if (ArgCount < MinArgs) or (ArgCount > MaxArgs) then begin
            if MinArgs = MaxArgs then
                Diags.AddError('ALI916', StrSubstNo('%1 expects %2 argument(s), got %3', MethodName, MinArgs, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
            else
                Diags.AddError('ALI916', StrSubstNo('%1 expects between %2 and %3 argument(s), got %4', MethodName, MinArgs, MaxArgs, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            for i := 1 to ArgCount do
                BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + i));
            exit;
        end;
        FieldArg := NEdges.Get(NFirstChild.Get(Node) + 1);
        if NKind.Get(FieldArg) <> "ALI NodeKind"::NameExpr then begin
            Diags.AddError('ALI962', StrSubstNo('The first argument of %1 must be a field name', MethodName), TokPos(Tokens, NMainTok.Get(FieldArg)), 0);
            exit;
        end;
        FieldNameId := Ast.GetExtra(FieldArg);
        if not RecMeta.TryFieldInfo(TableId, FieldNameId, FNo, FType, FLen, FClass) then begin
            Diags.AddError('AL0132', StrSubstNo('''%1'' is not a field of the record', Tokens.GetIdentText(NMainTok.Get(FieldArg))) + SuggestField(TableId, Tokens.GetIdentText(NMainTok.Get(FieldArg))), TokPos(Tokens, NMainTok.Get(FieldArg)), 0);
            exit;
        end;
        // Mark the field arg so the lowerer skips value-lowering it; store the field type on
        // it (for the value operand's target type) and the field no on the invocation node.
        Ast.SetTypeOrd(FieldArg, FType);
        Ast.SetSlotIndex(FieldArg, FNo);
        Ast.SetSlotIndex(Node, FNo);
        // remaining value argument(s): bound + assignment-checked to the field type
        for i := 2 to ArgCount do
            CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + i), FType, BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + i)));
    end;

    local procedure CheckRecArgCount(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; MethodName: Text; ArgCount: Integer; MinArgs: Integer; MaxArgs: Integer)
    begin
        if (ArgCount < MinArgs) or (ArgCount > MaxArgs) then
            Diags.AddError('ALI916', StrSubstNo('%1 expects between %2 and %3 argument(s), got %4', MethodName, MinArgs, MaxArgs, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
    end;

    local procedure RecMethodId(UpperName: Text): Integer
    begin
        case UpperName of
            'INIT':
                exit(1);
            'RESET':
                exit(2);
            'INSERT':
                exit(3);
            'MODIFY':
                exit(4);
            'DELETE':
                exit(5);
            'DELETEALL':
                exit(6);
            'GET':
                exit(7);
            'FINDSET':
                exit(8);
            'FINDFIRST':
                exit(9);
            'FINDLAST':
                exit(10);
            'NEXT':
                exit(11);
            'COUNT':
                exit(12);
            'ISEMPTY':
                exit(13);
            'SETRANGE':
                exit(14);
            'VALIDATE':
                exit(15);
            'RENAME':
                exit(16);
            'COPY':
                exit(17);
            'TRANSFERFIELDS':
                exit(18);
            'COPYFILTERS':
                exit(19);
            'SETRECFILTER':
                exit(20);
            'TRUNCATE':
                exit(21);
            'ISTEMPORARY':
                exit(23);
            'COUNTAPPROX':
                exit(24);
            'READPERMISSION':
                exit(25);
            'WRITEPERMISSION':
                exit(26);
            'SETFILTER':
                exit(27);
            'GETFILTER':
                exit(28);
            'COPYFILTER':
                exit(29);
            'GETRANGEMIN':
                exit(30);
            'GETRANGEMAX':
                exit(31);
            'MODIFYALL':
                exit(32);
            'CALCFIELDS':
                exit(33);
            'CALCSUMS':
                exit(34);
            'TESTFIELD':
                exit(35);
            'FIELDERROR':
                exit(36);
            'FIELDNAME':
                exit(37);
            'FIELDCAPTION':
                exit(38);
            'TABLENAME':
                exit(39);
            'TABLECAPTION':
                exit(40);
            'FULLYQUALIFIEDNAME':
                exit(41);
            'SETCURRENTKEY':
                exit(42);
            'ASCENDING':
                exit(43);
            'SETASCENDING':
                exit(44);
            'GETASCENDING':
                exit(45);
            'CURRENTKEY':
                exit(46);
            'MARK':
                exit(47);
            'CLEARMARKS':
                exit(48);
            'MARKEDONLY':
                exit(49);
            'GETPOSITION':
                exit(50);
            'SETPOSITION':
                exit(51);
            'GETVIEW':
                exit(52);
            'SETVIEW':
                exit(53);
            'CHANGECOMPANY':
                exit(54);
            'CURRENTCOMPANY':
                exit(55);
            'GETFILTERS':
                exit(56);
            'HASFILTER':
                exit(57);
            'SETAUTOCALCFIELDS':
                exit(58);
            'SETLOADFIELDS':
                exit(59);
            'ADDLOADFIELDS':
                exit(60);
            'LOADFIELDS':
                exit(61);
            'AREFIELDSLOADED':
                exit(62);
            'LOCKTABLE':
                exit(63);
            'READCONSISTENCY':
                exit(64);
            'FIELDCOUNT':
                exit(65);
            'FIELDEXIST':
                exit(66);
            'KEYCOUNT':
                exit(67);
            'CURRENTKEYINDEX':
                exit(68);
            'RECORDID':
                exit(69);
            'FILTERGROUP':
                exit(70);
            'FIND':
                exit(71);
            'GETBYSYSTEMID':
                exit(72);
            'ADDLINK':
                exit(73);
            'DELETELINK':
                exit(74);
            'DELETELINKS':
                exit(75);
            'COPYLINKS':
                exit(76);
            'HASLINKS':
                exit(77);
            'READISOLATION':
                exit(78);
            'SETPERMISSIONFILTER':
                exit(79);
            'SECURITYFILTERING':
                exit(80);
            'RECORDLEVELLOCKING':
                exit(81);
            else
                exit(0);
        end;
    end;

    // Marker base for record-method invocations on the AST SymbolId column: node SymbolId =
    // RecMethodMark() - methodId, keeping it clear of Error()=-1 and user-proc ids (>0).
    procedure RecMethodMark(): Integer
    begin
        exit(-1000);
    end;

    // ===== User-declared RecordRef methods (P1) =====
    //
    // The whole point of this family is how LITTLE of it there is. A RecordRef receiver holds
    // the same Int handle a Record receiver holds, into the same "ALI Rec Runtime" bank, so
    // every method that does not need a bind-time FIELD NUMBER is bound by the EXISTING
    // BindRecordMethod and lowered to the EXISTING REC_* opcode — no second implementation of
    // Find/FindSet/Count/Insert/SetView/Mark/... exists anywhere. Only three groups are handled
    // here:
    //   (a) the RecordRef-only surface (Open/Close/Number/Name/Caption/GetTable/SetTable/
    //       Duplicate/FieldExist-by-name/System*No) -> REF_METHOD, mark -15000;
    //   (b) the routed set -> straight into BindRecordMethod (mark -1000, REC_* opcodes);
    //   (c) the field-NUMBER surface (P4, ids 18-39) -> also REF_METHOD, because the numbers
    //       arrive as run-time Integers and this opcode's operand pool is already read live;
    //   (d) everything else -> AddMethodDiag (unknown name, or right name / wrong arity).
    //
    // Method ids, mirrored by "ALI Lowerer".LowerRecordRefMethod and "ALI Interpreter".
    // ExecRecordRefOp: 1 Open, 2 Close, 3 Number, 4 Name, 5 Caption, 6 GetTable, 7 SetTable,
    // 8 Duplicate, 9 FieldExist, 10 SystemIdNo, 11 SystemCreatedAtNo, 12 SystemCreatedByNo,
    // 13 SystemModifiedAtNo, 14 SystemModifiedByNo, 15 Field, 16 FieldIndex, 17 KeyIndex;
    // P4 field-number block: 18 SetRange, 19 SetFilter, 20 GetFilter, 21 CopyFilter,
    // 22 GetRangeMin, 23 GetRangeMax, 24 Validate, 25 ModifyAll, 26 CalcFields, 27 CalcSums,
    // 28 TestField, 29 FieldError, 30 FieldName, 31 FieldCaption, 32 SetAscending,
    // 33 GetAscending, 34 SetCurrentKey, 35 SetAutoCalcFields, 36 SetLoadFields,
    // 37 AddLoadFields, 38 LoadFields, 39 AreFieldsLoaded. (99 is the lowerer's internal
    // assert-open guard and is never bound from user text.)

    // Structural receiver peek, exactly like IsListReceiver/IsDialogReceiver: the receiver has
    // not been bound yet on the invocation path, so read the symbol table directly.
    local procedure IsRecordRefReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::RecordRef);
    end;

    local procedure BindRecordRefMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgT: Integer;
        k: Integer;
        MethodId: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        // Paren-less method (`n := RRef.Number`): Node IS the MemberAccessExpr, ExtraInt = the
        // member NameId rather than an argument count — read 0 there (the BindRecordMethod rule).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := RecordRefMethodId(MethodName, ArgCount);

        // Routed to the Record path: bind NOTHING here first — BindRecordMethod binds the
        // receiver itself, and binding it twice is the double-bind hazard the whole Is*Receiver
        // convention exists to avoid.
        if MethodId = 0 then
            if RecordRefRoutesToRecordMethod(RecMethodId(MethodName)) then
                exit(BindRecordMethod(Tokens, Ast, Symbols, Diags, Node, CalleeNode, IsStatement));

        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));    // receiver

        if MethodId = 0 then begin
            AddRecordRefUnsupportedDiag(Tokens, Ast, Diags, CalleeNode, MethodName, ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:  // Open(Integer|Text [, Temporary: Boolean] [, CompanyName: Text]). The two
                // overloads share one method id and are told apart by the FIRST argument's
                // register class at run time — picking the id here would mean binding the
                // argument before the method is resolved, which the dispatch order forbids.
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if not (TypeRules.CanConvert(ArgT, "ALI TypeKind"::Integer) or TypeRules.CanConvert(ArgT, "ALI TypeKind"::Text)) then
                        Diags.AddError('ALI932', StrSubstNo('RecordRef.Open expects a table id (Integer) or a table name (Text), got %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount >= 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    if ArgCount = 3 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                end;
            2:  // Close()
                ;
            3:  // Number() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            4, 5:   // Name() / Caption() -> Text
                ResultT := "ALI TypeKind"::Text;
            6:  // GetTable(Record) — a record VARIABLE of any table (its table is what the ref
                // takes on); BindRecArg with TableId 0 accepts any table and defers to run time.
                BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, 0, MethodName);
            7:  // SetTable(Record [, IncludeFilters: Boolean])
                begin
                    BindRecArg(Tokens, Ast, Symbols, Diags, Node, 1, 0, MethodName);
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            8:  // Duplicate() -> RecordRef (a second handle on the same bank)
                ResultT := "ALI TypeKind"::RecordRef;
            9:  // FieldExist(Integer|Text) -> Boolean — one id, run-time class branch (see Open)
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if not (TypeRules.CanConvert(ArgT, "ALI TypeKind"::Integer) or TypeRules.CanConvert(ArgT, "ALI TypeKind"::Text)) then
                        Diags.AddError('ALI932', StrSubstNo('RecordRef.FieldExist expects a field number (Integer) or a field name (Text), got %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            10, 11, 12, 13, 14:     // System*No() -> Integer (field numbers of the system fields)
                ResultT := "ALI TypeKind"::Integer;
            15: // Field(Integer|Text) -> FieldRef. One id, run-time class branch (the Open rule):
                // Field(Text) is an ALI EXTENSION (native takes a number only), the same
                // convenience Open(Text) adds.
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if not (TypeRules.CanConvert(ArgT, "ALI TypeKind"::Integer) or TypeRules.CanConvert(ArgT, "ALI TypeKind"::Text)) then
                        Diags.AddError('ALI932', StrSubstNo('RecordRef.Field expects a field number (Integer) or a field name (Text), got %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(Node)), 0);
                    ResultT := "ALI TypeKind"::FieldRef;
                end;
            16: // FieldIndex(Integer) -> FieldRef (the i-th field in field-number order)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::FieldRef;
                end;
            17: // KeyIndex(Integer) -> KeyRef
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::KeyRef;
                end;
            // ===== P4 (ids 18-39): field numbers arrive as run-time Integers =====
            // Only the FIELD-NUMBER arguments and the typed tail arguments (Text/Boolean) are
            // checked here. Every VALUE argument is deliberately left to the generic bind loop
            // below and reaches the runtime as a Variant through the operand pool: there is no
            // bind-time field type to check it against, which is exactly the difference from the
            // Record path (and exactly what §3c's FieldRef surface already does).
            18: // SetRange(fieldNo [, value [, toValue]]) — 1/2/3 args = clear / eq / from..to
                BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
            19: // SetFilter(fieldNo, filterText [, %1-substitution values ...])
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            20: // GetFilter(fieldNo) -> Text
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    ResultT := "ALI TypeKind"::Text;
                end;
            21: // CopyFilter(fromFieldNo, toFieldNo) — TWO field numbers, both live
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 2);
                end;
            22, 23: // GetRangeMin(fieldNo) / GetRangeMax(fieldNo) -> Variant.
                    // NOT the field's own type as on a Record: the field is only known at run
                    // time, so Variant is the honest static type — the same call the FieldRef
                    // surface makes (§3c). Ordinary Variant unboxing carries it into a typed target.
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    ResultT := "ALI TypeKind"::Variant;
                end;
            24: // Validate(fieldNo, value)
                BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
            25: // ModifyAll(fieldNo, value [, RunTrigger]) -> Bool (optional return: consuming it
                // suppresses a failing row-Modify, exactly as on the Record path)
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    if ArgCount = 3 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            26, 27: // CalcFields(fieldNo, ...) / CalcSums(fieldNo, ...) — every arg is a field no
                for k := 1 to ArgCount do
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, k);
            28: // TestField(fieldNo [, value])
                BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
            29: // FieldError(fieldNo [, Text])
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            30, 31: // FieldName(fieldNo) / FieldCaption(fieldNo) -> Text
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    ResultT := "ALI TypeKind"::Text;
                end;
            32: // SetAscending(fieldNo, Boolean)
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            33: // GetAscending(fieldNo) -> Bool
                begin
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, 1);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            34: // SetCurrentKey(fieldNo, ...) — void, matching the Record path's arity 42 (native
                // returns a Boolean this compiler has never exposed; parity beats novelty here)
                for k := 1 to ArgCount do
                    BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, k);
            35, 36, 37, 38, 39:
                // SetAutoCalcFields / SetLoadFields / AddLoadFields / LoadFields /
                // AreFieldsLoaded(fieldNo, ...) -> Bool
                begin
                    for k := 1 to ArgCount do
                        BindRefFieldNoArg(Tokens, Ast, Symbols, Diags, Node, k);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
        end;
        // Anything the arms above did not bind explicitly still has to be bound: an unbound
        // argument node keeps TypeOrd 0 and the lowerer would emit a register read for it.
        for k := 1 to ArgCount do
            if Ast.GetTypeOrd(ArgOrMissing(Ast, Node, k)) = "ALI TypeKind"::None then
                BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k));

        Ast.SetSymbolId(Node, RecordRefMethodMark() - MethodId);     // lowerer contract
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The RecordRef method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // The RecordRef-ONLY surface. Returns 0 for everything else — including every name that is
    // routed to the Record path, which must NOT be claimed here.
    local procedure RecordRefMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'OPEN':
                if (ArgCount >= 1) and (ArgCount <= 3) then
                    exit(1);
            'CLOSE':
                if ArgCount = 0 then
                    exit(2);
            'NUMBER':
                if ArgCount = 0 then
                    exit(3);
            'NAME':
                if ArgCount = 0 then
                    exit(4);
            'CAPTION':
                if ArgCount = 0 then
                    exit(5);
            'GETTABLE':
                if ArgCount = 1 then
                    exit(6);
            'SETTABLE':
                if (ArgCount = 1) or (ArgCount = 2) then
                    exit(7);
            'DUPLICATE':
                if ArgCount = 0 then
                    exit(8);
            'FIELDEXIST':
                if ArgCount = 1 then
                    exit(9);
            'SYSTEMIDNO':
                if ArgCount = 0 then
                    exit(10);
            'SYSTEMCREATEDATNO':
                if ArgCount = 0 then
                    exit(11);
            'SYSTEMCREATEDBYNO':
                if ArgCount = 0 then
                    exit(12);
            'SYSTEMMODIFIEDATNO':
                if ArgCount = 0 then
                    exit(13);
            'SYSTEMMODIFIEDBYNO':
                if ArgCount = 0 then
                    exit(14);
            // P2/P3: the three constructors of the packed-pair handles. They belong on THIS
            // opcode (not FLD_METHOD) because their RECEIVER is a RecordRef — only the RESULT
            // is a FieldRef/KeyRef, and the result is just an Integer like every other handle.
            'FIELD':
                if ArgCount = 1 then
                    exit(15);
            'FIELDINDEX':
                if ArgCount = 1 then
                    exit(16);
            'KEYINDEX':
                if ArgCount = 1 then
                    exit(17);
            // ===== P4: the field-number-argument surface (ids 18-39) =====
            //
            // These are the 22 methods that used to answer ALI989 on a RecordRef receiver. They
            // are NOT new behaviour and NOT new runtime code — every one of them already exists
            // in "ALI Rec Runtime" taking its field number as a plain Integer parameter (
            // SetRangeEq, CopyFilterField, ModifyAllField, SetLoadFieldsRec, ...). What used to
            // block them was purely the ENCODING on the Record path: there, the field number is
            // resolved from a field NAME at bind time and burned into the instruction (B, or a
            // pool of raw ints); a RecordRef supplies it as a run-time Integer, which that
            // encoding has nowhere to put.
            //
            // The vehicle is therefore the operand pool THIS opcode already uses: REF_METHOD's
            // pool is the CALL_BUILTIN_LIVE/TB_METHOD convention — every entry is regIdx*16+class,
            // read LIVE by the interpreter. A field number is just another live Integer operand.
            // So the field-number methods land here, on the family that already reads live
            // operands, instead of a parallel REC_*_DYN opcode per operation, and the reserved
            // REC_FLD_LOAD_DYN/REC_FLD_STORE_DYN ordinals stay unused: they encode a single
            // field LOAD/STORE, not 22 operations, and would have needed 22 siblings.
            //
            // *** The Record fast path is untouched. *** Not one REC_* opcode, lowering arm or
            // runtime procedure changes: a Record receiver still resolves its field name at bind
            // time and still emits the constant. A RecordRef receiver never reaches
            // LowerRecordMethod for these names (RecordRefMethodId claims them before
            // RecordRefRoutesToRecordMethod is consulted), so the two encodings never meet.
            //
            // Arg convention, uniform: the field number(s) come FIRST, exactly where the field
            // NAME sits on the Record path, and value arguments follow and are boxed through the
            // pool as Variants (there is no bind-time field type to convert them to — the same
            // reason a FieldRef takes Variant values in §3c).
            'SETRANGE':
                if (ArgCount >= 1) and (ArgCount <= 3) then
                    exit(18);
            'SETFILTER':
                if (ArgCount >= 2) and (ArgCount <= 16) then      // fieldNo + text + up to 14 subs
                    exit(19);
            'GETFILTER':
                if ArgCount = 1 then
                    exit(20);
            'COPYFILTER':
                if ArgCount = 2 then
                    exit(21);
            'GETRANGEMIN':
                if ArgCount = 1 then
                    exit(22);
            'GETRANGEMAX':
                if ArgCount = 1 then
                    exit(23);
            'VALIDATE':
                if ArgCount = 2 then
                    exit(24);
            'MODIFYALL':
                if (ArgCount >= 2) and (ArgCount <= 3) then
                    exit(25);
            'CALCFIELDS':
                if (ArgCount >= 1) and (ArgCount <= 16) then
                    exit(26);
            'CALCSUMS':
                if (ArgCount >= 1) and (ArgCount <= 16) then
                    exit(27);
            'TESTFIELD':
                if (ArgCount >= 1) and (ArgCount <= 2) then
                    exit(28);
            'FIELDERROR':
                if (ArgCount >= 1) and (ArgCount <= 2) then
                    exit(29);
            'FIELDNAME':
                if ArgCount = 1 then
                    exit(30);
            'FIELDCAPTION':
                if ArgCount = 1 then
                    exit(31);
            'SETASCENDING':
                if ArgCount = 2 then
                    exit(32);
            'GETASCENDING':
                if ArgCount = 1 then
                    exit(33);
            'SETCURRENTKEY':
                if (ArgCount >= 1) and (ArgCount <= 16) then
                    exit(34);
            // The five field-number-LIST methods. Their COUNT is bind-time-known even when the
            // values are not, so it stays in the instruction (ArgCount) and only the values are
            // live — no run-time-variadic machinery anywhere. 0 args is the documented reset form.
            'SETAUTOCALCFIELDS':
                if ArgCount <= 16 then
                    exit(35);
            'SETLOADFIELDS':
                if ArgCount <= 16 then
                    exit(36);
            'ADDLOADFIELDS':
                if ArgCount <= 16 then
                    exit(37);
            'LOADFIELDS':
                if ArgCount <= 16 then
                    exit(38);
            'AREFIELDSLOADED':
                if ArgCount <= 16 then
                    exit(39);
        end;
        exit(0);
    end;

    // Arity sweep for the ALI961 wording. Up to 16 because P4's SetFilter/CalcFields/
    // SetCurrentKey/SetLoadFields take that many.
    local procedure RecordRefMethodNameKnown(MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 16 do
            if RecordRefMethodId(MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    // A field-NUMBER argument (P4 ids 18-39). The Record path resolves a field NAME here; a
    // RecordRef has no table id to resolve one against, so this is an ordinary Integer-valued
    // expression — a variable, a computed expression, a FieldExist-guarded lookup, or a literal.
    local procedure BindRefFieldNoArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgIdx: Integer)
    begin
        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, ArgIdx), "ALI TypeKind"::Integer,
            BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, ArgIdx)));
    end;

    // The routed set: every native Record/RecordRef method whose binding needs NO table id and
    // no bind-time field number, so the existing BindRecordMethod + REC_* opcode serve a
    // RecordRef receiver unchanged. Deliberately an ALLOW-list and not a deny-list: a Record
    // method added later must be opted in consciously, because the failure mode of routing one
    // that DOES resolve a field name is a wrong field number, not a diagnostic.
    local procedure RecordRefRoutesToRecordMethod(RecId: Integer): Boolean
    begin
        case RecId of
            1, 2, 3, 4, 5, 6, 7,                    // Init Reset Insert Modify Delete DeleteAll Get
            8, 9, 10, 11, 12, 13,                   // FindSet FindFirst FindLast Next Count IsEmpty
            16, 17,                                 // Rename Copy
            20, 21, 23, 24, 25, 26,                 // SetRecFilter Truncate IsTemporary CountApprox Read/WritePermission
            41,                                     // FullyQualifiedName
            43, 46, 47, 48, 49,                     // Ascending CurrentKey Mark ClearMarks MarkedOnly
            50, 51, 52, 53, 54, 55, 56, 57,         // Get/SetPosition Get/SetView ChangeCompany CurrentCompany GetFilters HasFilter
            63, 64, 65, 67, 68, 69, 70,             // LockTable ReadConsistency FieldCount KeyCount CurrentKeyIndex RecordId FilterGroup
            71, 72,                                 // Find(Text) GetBySystemId
            73, 74, 75, 76, 77,                     // AddLink DeleteLink DeleteLinks CopyLinks HasLinks
            78, 79, 80, 81:                         // ReadIsolation SetPermissionFilter SecurityFiltering RecordLevelLocking
                exit(true);
        end;
        exit(false);
    end;

    // Truthful "recognized but not implemented" (the 🔶 contract): never report a native
    // RecordRef method as an unknown identifier, and always name the actual obstacle.
    local procedure AddRecordRefUnsupportedDiag(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; CalleeNode: Integer; MethodName: Text; ArgCount: Integer)
    begin
        // P4 emptied this procedure's 🔶 arm: the 22 field-number methods that used to answer
        // ALI989 here are real ids 18-39 now (see RecordRefMethodId's P4 header). Nothing on the
        // documented RecordRef surface is deferred any more, so reaching this point means the name
        // is genuinely unknown, or it is the right name at an arity no overload has — both of
        // which AddMethodDiag already words correctly. Kept as a named procedure rather than
        // inlined because it is the one place a future deferral would go back.
        AddMethodDiag(Tokens, Ast, Diags, CalleeNode, 'RecordRef', RecordRefMethodNameKnown(MethodName) or (RecMethodId(MethodName) <> 0), ArgCount);
    end;

    // Marker base for RecordRef-method invocations. MORE negative than MediaMethodMark(-14000),
    // which was the most negative mark before this pass — every dispatch cascade in the lowerer
    // is a descending `Sym <= X` ladder, so a new family must sit at the TOP of the ladder to be
    // matched at all. Keep this the most negative mark, or move the whole ladder.
    procedure RecordRefMethodMark(): Integer
    begin
        exit(-15000);
    end;

    // ===== User-declared FieldRef / KeyRef methods (P2 / P3) =====
    //
    // ONE family, ONE mark, ONE opcode for both types — a KeyRef is four methods and a third
    // dispatch family would have cost more ladder edits than it saved. They are separated by
    // METHOD ID RANGE (FieldRef 1-31, KeyRef 40-43); the receiver's static type picks the id
    // table, so the two can never be confused.
    //
    // Why this family needs NONE of the compile-time field-number operand pools that still block
    // SetRange/Validate/CalcFields/... on a RecordRef receiver (ALI989, P4): a FieldRef CARRIES
    // its field number inside its own handle. There is nothing for the binder to resolve and
    // nothing to pool — `F.SetRange(1, 9)` lowers to "call SetRange on whatever field F names",
    // with the field number arriving at run time in the receiver register. Same operations,
    // completely different code path.
    //
    // Method ids are mirrored by "ALI Lowerer".LowerFieldRefMethod, "ALI Interpreter".
    // ExecFieldRefOp and the "ALI Opcode"::FLD_METHOD header — keep the four in step.

    local procedure IsFieldRefReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    begin
        exit(RefKindOfReceiver(Ast, Symbols, RecvNode) = "ALI TypeKind"::FieldRef);
    end;

    local procedure IsKeyRefReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    begin
        exit(RefKindOfReceiver(Ast, Symbols, RecvNode) = "ALI TypeKind"::KeyRef);
    end;

    // Structural receiver peek (the IsRecordRefReceiver shape): the receiver has not been bound
    // yet on the invocation path, so read the symbol table directly.
    local procedure RefKindOfReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit("ALI TypeKind"::None);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit("ALI TypeKind"::None);
        exit(Symbols.GetType(Sid));
    end;

    // Chained receiver peek — the ONE thing the three structural predicates above cannot do.
    // Returns RecordRef / FieldRef / KeyRef when the receiver is an EXPRESSION of that type
    // (`RRef.Field(3)`, `K.FieldIndex(1)`, `F.Record()`, `GetFieldRef()`), None otherwise.
    //
    // NameExpr is deliberately refused here: a ref VARIABLE is already claimed structurally
    // higher up the ladder, and answering it twice would only pay Symbols.Lookup twice.
    //
    // The TypeOrd fast path is not an optimization detail, it is what keeps chaining LINEAR: a
    // depth-n chain reaches this peek once per link, and on the paren-less path (BindFieldAccess
    // binds its target BEFORE dispatching) the receiver is always already bound, so re-binding it
    // would double the work at every level — 2^n binds for an n-link chain. The bind is only
    // needed on the PARENTHESIZED path, where TryDispatchMemberMethod runs before anything binds
    // the receiver. Throwaway diag bag, same contract as ExprTypePeek: BindExpr is idempotent per
    // node, and the real Bind*RefMethod re-binds the receiver against the REAL Diags right after,
    // so a diagnostic inside the receiver is still reported exactly once.
    local procedure RefKindOfChainedReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    var
        ScratchDiags: Codeunit "ALI Diag Bag";
        T: Integer;
    begin
        if NKind.Get(RecvNode) = "ALI NodeKind"::NameExpr then
            exit("ALI TypeKind"::None);
        T := Ast.GetTypeOrd(RecvNode);
        if (T = "ALI TypeKind"::None) or (T = "ALI TypeKind"::ErrorType) then
            T := BindExpr(Tokens, Ast, Symbols, ScratchDiags, RecvNode);
        if T = "ALI TypeKind"::RecordRef then
            exit(T);
        if T = "ALI TypeKind"::FieldRef then
            exit(T);
        if T = "ALI TypeKind"::KeyRef then
            exit(T);
        exit("ALI TypeKind"::None);
    end;

    // Is this receiver node FieldRef-VALUED — as a variable (structural) or as the result of a
    // call (already bound by the caller)? Used by the `F.Value := x` property-set recognizer,
    // which runs AFTER BindAssignment has bound the whole target expression and so can trust the
    // annotation. Deliberately does NOT bind: an lvalue receiver is bound by then, always.
    local procedure IsFieldRefValuedReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    begin
        if RefKindOfReceiver(Ast, Symbols, RecvNode) = "ALI TypeKind"::FieldRef then
            exit(true);
        exit(Ast.GetTypeOrd(RecvNode) = "ALI TypeKind"::FieldRef);
    end;

    local procedure BindFieldRefMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsKey: Boolean; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        k: Integer;
        MethodId: Integer;
        ResultT: Integer;
        SetId: Integer;
        MethodName: Text;
    begin
        // Paren-less method (`n := F.Number`): Node IS the MemberAccessExpr, ExtraInt = the
        // member NameId rather than an argument count — read 0 there (the BindRecordMethod rule).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));

        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));    // receiver

        if IsKey then
            MethodId := KeyRefMethodId(MethodName, ArgCount)
        else
            MethodId := FieldRefMethodId(MethodName, ArgCount);
        if MethodId = 0 then begin
            AddFieldRefUnsupportedDiag(Tokens, Ast, Diags, CalleeNode, MethodName, ArgCount, IsKey);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:  // Value() -> Variant. The static type IS Variant (a FieldRef's field type is only
                // known at run time), so the existing Variant register file + the REC_FLD_LOAD
                // Variant->register converter carry it with no new machinery.
                ResultT := "ALI TypeKind"::Variant;
            2, 3:   // Value(v) / Validate([v]) — one Variant-shaped argument, any type
                ;
            4:  // SetRange() / SetRange(v) / SetRange(lo, hi) — all three arities, one id
                ;
            5:  // SetFilter(Text [, args...]) — arg 1 must be Text, the rest are substitutions
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            6:  // GetFilter() -> Text
                ResultT := "ALI TypeKind"::Text;
            7, 8:   // GetRangeMin() / GetRangeMax() -> Variant (same reasoning as Value())
                ResultT := "ALI TypeKind"::Variant;
            9, 10:  // CalcField() / CalcSum() — void
                ;
            11: // TestField() / TestField(value) — ONE Variant-argument form, not native AL's ~30
                // typed overloads: the operand pool boxes the argument either way, so a typed
                // ladder would buy 30 identical bodies and nothing else.
                ;
            12: // FieldError() / FieldError(Text)
                if ArgCount = 1 then
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            13, 15, 21, 22:     // Name / Caption / OptionCaption / OptionMembers -> Text
                ResultT := "ALI TypeKind"::Text;
            14, 16, 20, 24:     // Number / Length / Relation / EnumValueCount -> Integer
                ResultT := "ALI TypeKind"::Integer;
            17: // Class() -> FieldClass (a built-in system option set, see TrySystemOptionSet)
                begin
                    TrySystemOptionSet('FIELDCLASS', SetId);
                    Ast.SetTypeArg(Node, SetId);
                    ResultT := "ALI TypeKind"::Option;
                end;
            18: // Type() -> FieldType (ditto — ALI ordinals over the platform's member NAMES)
                begin
                    TrySystemOptionSet('FIELDTYPE', SetId);
                    Ast.SetTypeArg(Node, SetId);
                    ResultT := "ALI TypeKind"::Option;
                end;
            19, 23, 30:         // Active / IsEnum / IsOptimizedForTextSearch -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            25, 26, 28, 29:     // GetEnumValue{Name,Caption}[FromOrdinalValue](Integer) -> Text
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Text;
                end;
            27: // GetEnumValueOrdinal(Integer) -> Integer
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            31, 43:             // Record() -> RecordRef — free under the pair design: the owning
                                // record handle is literally the low half of the FieldRef handle
                ResultT := "ALI TypeKind"::RecordRef;
            40:                 // KeyRef.Active() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            41:                 // KeyRef.FieldCount() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            42:                 // KeyRef.FieldIndex(Integer) -> FieldRef
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::FieldRef;
                end;
        end;
        // Anything the arms above did not bind explicitly still has to be bound: an unbound
        // argument node keeps TypeOrd 0 and the lowerer would emit a register read for it.
        for k := 1 to ArgCount do
            if Ast.GetTypeOrd(ArgOrMissing(Ast, Node, k)) = "ALI TypeKind"::None then
                BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, k));

        Ast.SetSymbolId(Node, FieldRefMethodMark() - MethodId);     // lowerer contract
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The FieldRef method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    local procedure FieldRefMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'VALUE':
                case ArgCount of
                    0:
                        exit(1);
                    1:
                        exit(2);
                end;
            'VALIDATE':
                if ArgCount <= 1 then
                    exit(3);
            'SETRANGE':
                if ArgCount <= 2 then
                    exit(4);
            'SETFILTER':
                if (ArgCount >= 1) and (ArgCount <= 15) then    // filter text + up to 14 args
                    exit(5);
            'GETFILTER':
                if ArgCount = 0 then
                    exit(6);
            'GETRANGEMIN':
                if ArgCount = 0 then
                    exit(7);
            'GETRANGEMAX':
                if ArgCount = 0 then
                    exit(8);
            'CALCFIELD':
                if ArgCount = 0 then
                    exit(9);
            'CALCSUM':
                if ArgCount = 0 then
                    exit(10);
            'TESTFIELD':
                if ArgCount <= 1 then
                    exit(11);
            'FIELDERROR':
                if ArgCount <= 1 then
                    exit(12);
            'NAME':
                if ArgCount = 0 then
                    exit(13);
            'NUMBER':
                if ArgCount = 0 then
                    exit(14);
            'CAPTION':
                if ArgCount = 0 then
                    exit(15);
            'LENGTH':
                if ArgCount = 0 then
                    exit(16);
            'CLASS':
                if ArgCount = 0 then
                    exit(17);
            'TYPE':
                if ArgCount = 0 then
                    exit(18);
            'ACTIVE':
                if ArgCount = 0 then
                    exit(19);
            'RELATION':
                if ArgCount = 0 then
                    exit(20);
            'OPTIONCAPTION':
                if ArgCount = 0 then
                    exit(21);
            'OPTIONMEMBERS':
                if ArgCount = 0 then
                    exit(22);
            'ISENUM':
                if ArgCount = 0 then
                    exit(23);
            'ENUMVALUECOUNT':
                if ArgCount = 0 then
                    exit(24);
            'GETENUMVALUENAME':
                if ArgCount = 1 then
                    exit(25);
            'GETENUMVALUECAPTION':
                if ArgCount = 1 then
                    exit(26);
            'GETENUMVALUEORDINAL':
                if ArgCount = 1 then
                    exit(27);
            'GETENUMVALUENAMEFROMORDINALVALUE':
                if ArgCount = 1 then
                    exit(28);
            'GETENUMVALUECAPTIONFROMORDINALVALUE':
                if ArgCount = 1 then
                    exit(29);
            'ISOPTIMIZEDFORTEXTSEARCH':
                if ArgCount = 0 then
                    exit(30);
            'RECORD':
                if ArgCount = 0 then
                    exit(31);
        end;
        exit(0);
    end;

    local procedure KeyRefMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'ACTIVE':
                if ArgCount = 0 then
                    exit(40);
            'FIELDCOUNT':
                if ArgCount = 0 then
                    exit(41);
            'FIELDINDEX':
                if ArgCount = 1 then
                    exit(42);
            'RECORD':
                if ArgCount = 0 then
                    exit(43);
        end;
        exit(0);
    end;

    local procedure FieldRefMethodNameKnown(MethodName: Text; IsKey: Boolean): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 15 do
            if IsKey then begin
                if KeyRefMethodId(MethodName, A) <> 0 then
                    exit(true);
            end else
                if FieldRefMethodId(MethodName, A) <> 0 then
                    exit(true);
        exit(false);
    end;

    local procedure AddFieldRefUnsupportedDiag(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; CalleeNode: Integer; MethodName: Text; ArgCount: Integer; IsKey: Boolean)
    var
        Kind: Text;
    begin
        Kind := 'FieldRef';
        if IsKey then
            Kind := 'KeyRef';
        // The whole documented surface of both types is implemented, so there is no 🔶 deferral
        // arm here — an unrecognized name really is unknown (or the right name at the wrong
        // arity), which AddMethodDiag already words correctly for both cases.
        AddMethodDiag(Tokens, Ast, Diags, CalleeNode, Kind, FieldRefMethodNameKnown(MethodName, IsKey), ArgCount);
    end;

    // `F.Value := x` / `RRef.Field(3).Value := x` — the property-SET shape, recognized
    // structurally by BindAssignment before the generic lvalue check would reject "assignment to
    // a method result". Re-marks the target with the Value-setter id (2), which is the same id
    // `F.Value(x)` binds to.
    //
    // The CHAINED form is the commoner of the two in real RecordRef code, and it is the reason the
    // receiver test is IsFieldRefValuedReceiver and not the structural IsFieldRefReceiver: the
    // left of the `:=` is `<call>.Value`, whose receiver is an expression. Nothing else about the
    // write path changes — the lowerer's LowerFieldRefPropertyStore already resolves the receiver
    // with a generic LowerExpr, so the intermediate FieldRef lives in a temp register and costs
    // nothing (packed Int, no bank, no lifecycle).
    local procedure TryBindFieldRefPropertySet(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; TargetNode: Integer; SourceNode: Integer): Boolean
    var
        RecvNode: Integer;
    begin
        if NKind.Get(TargetNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit(false);
        RecvNode := NEdges.Get(NFirstChild.Get(TargetNode) + 0);
        if not IsFieldRefValuedReceiver(Ast, Symbols, RecvNode) then
            exit(false);
        if UpperCase(Tokens.GetIdentText(NMainTok.Get(TargetNode))) <> 'VALUE' then
            exit(false);
        // The receiver is ALREADY bound: BindAssignment binds the whole target expression before
        // calling here (the Http/Stream property-set precedent). Re-binding it would be the
        // double-bind hazard the Is*Receiver convention exists to avoid.
        BindExpr(Tokens, Ast, Symbols, Diags, SourceNode);      // any type — boxed into a Variant
        Ast.SetSymbolId(TargetNode, FieldRefMethodMark() - 2);
        exit(true);
    end;

    // Marker base for FieldRef/KeyRef-method invocations. MORE negative than
    // RecordRefMethodMark(-15000), which was the most negative mark before this pass — every
    // dispatch cascade in the lowerer is a descending `Sym <= X` ladder, so a new family must
    // sit at the TOP of the ladder to be matched at all. Keep this the most negative mark, or
    // move the whole ladder.
    procedure FieldRefMethodMark(): Integer
    begin
        exit(-16000);
    end;

    // ===== RecordID methods =====
    //
    // Is a receiver expression RecordID-typed? Same shape as IsStreamReceiver/IsTextReceiver.
    local procedure IsRecordIdReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    begin
        exit(ExprTypePeek(Tokens, Ast, Symbols, RecvNode) = "ALI TypeKind"::RecordID);
    end;

    // `id.Method()` where id is RecordID-typed. Method ids: 1 GetRecord (see note below)
    // 2 TableNo. TableNo() -> Integer, no args (native: errors if the RecordID is blank —
    // the runtime lets RecordId.TableNo() raise its own native error for that case).
    //
    // GetRecord() is deliberately NOT resolved here: its native return type is RecordRef,
    // which this interpreter's Record model cannot represent as a free-standing value (a
    // Record variable's table is fixed at declaration, §7.5, but GetRecord()'s table is only
    // known at runtime from the RecordID's payload). The ONE shape this interpreter can and
    // does support — 'RecVar := idExpr.GetRecord();' — is recognized and bound directly by
    // BindAssignment (its own pre-check, before the generic BindExpr walk reaches here),
    // and lowers straight to REC_GET_BY_ID against RecVar's handle (table mismatch becomes
    // a runtime error there, exactly like a native Get(RecordId) on the wrong table). Any
    // OTHER appearance of '.GetRecord()' (chained, passed as an argument, compared, ...)
    // reaches this generic dispatch instead, and is rejected with a precise diagnostic.
    local procedure BindRecordIdMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        RecvNode: Integer;
        MethodName: Text;
        UpperName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        // Parenless call (`id.TableNo` — no parens): Node IS the MemberAccessExpr, whose own
        // ExtraInt is the member NameId, NOT an arg count (mirror BindRecordMethod/
        // BindStreamMethod — reading NameId as a count would walk phantom children).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        UpperName := UpperCase(MethodName);

        if UpperName = 'GETRECORD' then begin
            Diags.AddError('ALI971', 'GetRecord() is only supported in the form ''RecVar := idExpr.GetRecord();'' (the target record variable''s table must be known statically)', TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        if UpperName <> 'TABLENO' then begin
            Diags.AddError('ALI968', StrSubstNo('RecordID method ''%1'' is not supported', MethodName), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        if ArgCount <> 0 then begin
            Diags.AddError('ALI916', StrSubstNo('TableNo expects 0 argument(s), but %1 were provided', ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;
        Ast.SetSymbolId(Node, RecordIdMethodMark() - 2);
        exit("ALI TypeKind"::Integer);
    end;

    // Marker base for RecordID-method invocations (GetRecord/TableNo). Most negative of the
    // negative marker ranges (< DictMethodMark(-6000)) so the Lowerer's descending `Sym <= X`
    // cascade (Dict/List/TextBuilder/Builtin/Stream/Rec) can check it first without ambiguity.
    procedure RecordIdMethodMark(): Integer
    begin
        exit(-7000);
    end;

    // ===== BLOB table fields =====
    //
    // A BLOB field has no register class, so it is never loaded as a value; the only legal
    // uses are the four native blob methods on the field access itself:
    //   Rec.MyBlob.CreateInStream(inStr) / CreateOutStream(outStr) / HasValue() / Length()
    // Anything else (`x := Rec.MyBlob`) fails the normal assignability check with type `Blob`.

    // Is a receiver expression a `Rec.MyBlob` field access? Probed WITHOUT binding (so no
    // diagnostic is emitted twice), unlike the NameExpr-shaped Is*Receiver helpers.
    local procedure IsBlobFieldReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        Sid: Integer;
        TargetNode: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit(false);
        TargetNode := NEdges.Get(NFirstChild.Get(RecvNode) + 0);
        if NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(TargetNode));
        if Sid = 0 then
            exit(false);
        if Symbols.GetType(Sid) <> "ALI TypeKind"::Record then
            exit(false);
        if not RecMeta.TryFieldInfo(Symbols.GetTypeArg(Sid), Ast.GetExtra(RecvNode), FNo, FType, FLen, FClass) then
            exit(false);
        exit(FType = "ALI TypeKind"::Blob);
    end;

    // `Rec.MyBlob.Method(args)`. Method ids: 1 CreateInStream 2 CreateOutStream 3 HasValue
    // 4 Length. Node SymbolId = BlobMethodMark() - methodId; binding the receiver annotates
    // the field node with the field number the lowerer needs (SlotIndex).
    local procedure BindBlobMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgNode: Integer;
        ArgT: Integer;
        MethodId: Integer;
        ResultT: Integer;
        WantT: Integer;
        MethodName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));
        // Paren-less method (`Rec.MyBlob.HasValue`): Node IS the MemberAccessExpr.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := BlobMethodId(MethodName);
        if MethodId = 0 then begin
            Diags.AddError('ALI969', StrSubstNo('Blob method ''%1'' is not supported (CreateInStream/CreateOutStream/HasValue/Length)', Tokens.GetIdentText(NMainTok.Get(CalleeNode))), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1, 2:   // CreateInStream(inStr [, TextEncoding::X]) / CreateOutStream(outStr [, TextEncoding::X])
                begin
                    if MethodId = 1 then
                        WantT := "ALI TypeKind"::InStream
                    else
                        WantT := "ALI TypeKind"::OutStream;
                    if (ArgCount < 1) or (ArgCount > 2) then
                        Diags.AddError('ALI916', StrSubstNo('%1 expects 1 or 2 arguments, got %2', MethodName, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else begin
                        ArgNode := ArgOrMissing(Ast, Node, 1);
                        ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
                        if ArgT <> WantT then
                            Diags.AddError('ALI969', StrSubstNo('%1 requires a %2 variable', MethodName, TypeRules.TypeName(WantT)), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                        if ArgCount = 2 then begin
                            // Any TextEncoding-typed expression: a `TextEncoding::X` literal folds
                            // into the instruction, anything else is read from a register at run time.
                            ArgNode := ArgOrMissing(Ast, Node, 2);
                            ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
                            if not IsTextEncodingSet(ArgT, Ast.GetTypeArg(ArgNode)) then
                                Diags.AddError('ALI969', StrSubstNo('%1 encoding argument must be a TextEncoding value (e.g. TextEncoding::UTF8)', MethodName), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                        end;
                    end;
                end;
            3:      // HasValue() -> Bool
                begin
                    CheckStreamArgCount(Tokens, Ast, Diags, Node, 'HasValue', ArgCount, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            4:      // Length() -> Int
                begin
                    CheckStreamArgCount(Tokens, Ast, Diags, Node, 'Length', ArgCount, 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
        end;

        Ast.SetSymbolId(Node, BlobMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The blob method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    local procedure BlobMethodId(UpperName: Text): Integer
    begin
        case UpperName of
            'CREATEINSTREAM':
                exit(1);
            'CREATEOUTSTREAM':
                exit(2);
            'HASVALUE':
                exit(3);
            'LENGTH':
                exit(4);
            else
                exit(0);
        end;
    end;

    // Marker base for blob-method invocations. MORE negative than JsonMethodMark(-10000) so it
    // wins the lowerer's descending `Sym <= X` cascade.
    procedure BlobMethodMark(): Integer
    begin
        exit(-11000);
    end;

    // ===== Media / MediaSet table fields =====
    //
    // Same shape as BLOB: no register class, never loaded as a value, reachable only through
    // the media methods on the field access itself. ALI reads fields through a FieldRef, whose
    // Value for these two field types is the media (or media-set) GUID — so the QUERY half of
    // the surface is fully implementable and the IMPORT half is not (it needs the strongly-typed
    // field object). ImportStream / Insert / Remove therefore get a precise ALI997 refusal here
    // instead of silently doing nothing at runtime.

    local procedure MediaKindOfFieldReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    var
        FClass: Integer;
        FLen: Integer;
        FNo: Integer;
        FType: Integer;
        Sid: Integer;
        TargetNode: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit("ALI TypeKind"::None);
        TargetNode := NEdges.Get(NFirstChild.Get(RecvNode) + 0);
        if NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr then
            exit("ALI TypeKind"::None);
        Sid := Symbols.Lookup(Ast.GetExtra(TargetNode));
        if Sid = 0 then
            exit("ALI TypeKind"::None);
        if Symbols.GetType(Sid) <> "ALI TypeKind"::Record then
            exit("ALI TypeKind"::None);
        if not RecMeta.TryFieldInfo(Symbols.GetTypeArg(Sid), Ast.GetExtra(RecvNode), FNo, FType, FLen, FClass) then
            exit("ALI TypeKind"::None);
        if (FType = "ALI TypeKind"::Media) or (FType = "ALI TypeKind"::MediaSet) then
            exit(FType);
        exit("ALI TypeKind"::None);
    end;

    // `Rec.MyPicture.Method(args)`. Ids: Media 1 ExportStream(OutStream) 2 HasValue()->Boolean
    // 3 MediaId()->Guid; MediaSet 20 Count()->Integer 21 Item(Integer)->Guid 22 MediaId()->Guid.
    // Node SymbolId = MediaMethodMark() - methodId; binding the receiver annotates the field node
    // with the field number the lowerer needs (SlotIndex), exactly as for BLOB.
    local procedure BindMediaMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; Kind: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgNode: Integer;
        ArgT: Integer;
        MethodId: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));
        // Paren-less method (`Rec.MyPicture.HasValue`): Node IS the MemberAccessExpr.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));

        if MediaMethodIsWriteSide(MethodName) then begin
            Diags.AddError('ALI997', StrSubstNo('%1.%2 is not supported: the interpreter reaches table fields through a FieldRef, which yields the media id but never a writable Media object', TypeRules.TypeName(Kind), Tokens.GetIdentText(NMainTok.Get(CalleeNode))), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        MethodId := MediaMethodId(Kind, MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, TypeRules.TypeName(Kind), MediaMethodNameKnown(Kind, MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // ExportStream(OutStream)
                begin
                    ArgNode := ArgOrMissing(Ast, Node, 1);
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
                    if ArgT <> "ALI TypeKind"::OutStream then
                        Diags.AddError('ALI969', 'ExportStream requires an OutStream variable', TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                end;
            2:      // HasValue() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            3, 22:  // MediaId() -> Guid
                ResultT := "ALI TypeKind"::Guid;
            20:     // Count() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            21:     // Item(Integer) -> Guid
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Guid;
                end;
        end;

        Ast.SetSymbolId(Node, MediaMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The %1 method ''%2'' does not return a value', TypeRules.TypeName(Kind), MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // The methods that exist natively but cannot be expressed on top of a FieldRef.
    local procedure MediaMethodIsWriteSide(UpperName: Text): Boolean
    begin
        exit((UpperName = 'IMPORTSTREAM') or (UpperName = 'IMPORTFILE') or
             (UpperName = 'INSERT') or (UpperName = 'REMOVE'));
    end;

    local procedure MediaMethodId(Kind: Integer; UpperName: Text; ArgCount: Integer): Integer
    begin
        if Kind = "ALI TypeKind"::Media then
            case UpperName of
                'EXPORTSTREAM':
                    if ArgCount = 1 then
                        exit(1);
                'HASVALUE':
                    if ArgCount = 0 then
                        exit(2);
                'MEDIAID':
                    if ArgCount = 0 then
                        exit(3);
            end
        else
            case UpperName of
                'COUNT':
                    if ArgCount = 0 then
                        exit(20);
                'ITEM':
                    if ArgCount = 1 then
                        exit(21);
                'MEDIAID':
                    if ArgCount = 0 then
                        exit(22);
            end;
        exit(0);
    end;

    local procedure MediaMethodNameKnown(Kind: Integer; MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 2 do
            if MediaMethodId(Kind, MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    // Marker base for media-field methods. MORE negative than BlobMethodMark(-11000) and
    // BigTextMethodMark(-13000) so it wins every descending `Sym <= X` cascade.
    procedure MediaMethodMark(): Integer
    begin
        exit(-14000);
    end;

    // ===== BigText / SecretText methods (one mark, two id ranges) =====
    //
    // Both families share MethodMark -13000 because both lower through the same helper: the
    // receiver is a plain register (an Int handle for BigText, the Text value itself for
    // SecretText) and the args ride the operand pool. Ids 1-49 = BigText, 50-59 = SecretText.

    local procedure IsBigTextReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::BigText);
    end;

    local procedure IsSecretTextReceiver(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::SecretText);
    end;

    // `bt.Method(args)` / `st.Method()`. Ids: 1 AddText(Text) 2 AddText(Text,Int)
    // 3 AddText(BigText) 4 AddText(BigText,Int) 5 GetSubText(var Text,Int)
    // 6 GetSubText(var Text,Int,Int) 7 GetSubText(var BigText,Int) 8 GetSubText(var BigText,Int,Int)
    // 9 Length()->Int 10 Read(InStream) 11 TextPos(Text)->Int 12 Write(OutStream)
    // 50 IsEmpty()->Boolean 51 Unwrap()->Text.
    local procedure BindBigTextMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsSecret: Boolean; IsStatement: Boolean): Integer
    var
        FirstArgIsBig: Boolean;
        ArgCount: Integer;
        ArgNode: Integer;
        ArgT: Integer;
        MethodId: Integer;
        ResultT: Integer;
        MethodName: Text;
        RecvTypeName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));    // receiver
        // Paren-less method (`n := bt.Length`): Node is the MemberAccessExpr.
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));

        if IsSecret then begin
            RecvTypeName := 'SecretText';
            MethodId := SecretTextMethodId(MethodName, ArgCount);
        end else begin
            RecvTypeName := 'BigText';
            // AddText/GetSubText overload on the FIRST argument's TYPE, not on arity alone.
            // A BigText value can only ever be a variable (nothing in the surface produces one
            // as an expression result), so this is a symbol peek — deliberately NOT
            // ExprTypePeek, which would bind the node a second time for the Text overloads.
            FirstArgIsBig := ArgCount >= 1;
            if FirstArgIsBig then
                FirstArgIsBig := IsBigTextReceiver(Ast, Symbols, ArgOrMissing(Ast, Node, 1));
            MethodId := BigTextMethodId(MethodName, ArgCount, FirstArgIsBig);
        end;
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, RecvTypeName, BigTextMethodNameKnown(MethodName, IsSecret), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // AddText(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            2:      // AddText(Text, Integer)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            3:      // AddText(BigText)
                BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
            4:      // AddText(BigText, Integer)
                begin
                    BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            5, 6:   // GetSubText(var Text, Int [, Int]) — arg 1 is an out-target, not a value
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'GetSubText') then
                        exit("ALI TypeKind"::ErrorType);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    if MethodId = 6 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                end;
            7, 8:   // GetSubText(var BigText, Int [, Int]) — the destination is a bank slot, so
                    // the handle itself is the out-target and needs no store-back
                begin
                    BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    if MethodId = 8 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                end;
            9:      // Length() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            10, 12: // Read(InStream) / Write(OutStream)
                begin
                    ArgNode := ArgOrMissing(Ast, Node, 1);
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
                    if MethodId = 10 then begin
                        if ArgT <> "ALI TypeKind"::InStream then
                            Diags.AddError('ALI968', 'BigText.Read requires an InStream variable', TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                    end else
                        if ArgT <> "ALI TypeKind"::OutStream then
                            Diags.AddError('ALI968', 'BigText.Write requires an OutStream variable', TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                end;
            11:     // TextPos(Text) -> Integer
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            50:     // IsEmpty() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            51:     // Unwrap() -> Text
                ResultT := "ALI TypeKind"::Text;
        end;

        Ast.SetSymbolId(Node, BigTextMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The %1 method ''%2'' does not return a value', RecvTypeName, MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    local procedure BigTextMethodId(UpperName: Text; ArgCount: Integer; FirstArgIsBig: Boolean): Integer
    begin
        case UpperName of
            'ADDTEXT':
                case ArgCount of
                    1:
                        if FirstArgIsBig then
                            exit(3)
                        else
                            exit(1);
                    2:
                        if FirstArgIsBig then
                            exit(4)
                        else
                            exit(2);
                end;
            'GETSUBTEXT':
                case ArgCount of
                    2:
                        if FirstArgIsBig then
                            exit(7)
                        else
                            exit(5);
                    3:
                        if FirstArgIsBig then
                            exit(8)
                        else
                            exit(6);
                end;
            'LENGTH':
                if ArgCount = 0 then
                    exit(9);
            'READ':
                if ArgCount = 1 then
                    exit(10);
            'TEXTPOS':
                if ArgCount = 1 then
                    exit(11);
            'WRITE':
                if ArgCount = 1 then
                    exit(12);
        end;
        exit(0);
    end;

    local procedure SecretTextMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'ISEMPTY':
                if ArgCount = 0 then
                    exit(50);
            'UNWRAP':
                if ArgCount = 0 then
                    exit(51);
        end;
        exit(0);
    end;

    local procedure BigTextMethodNameKnown(MethodName: Text; IsSecret: Boolean): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 3 do
            if IsSecret then begin
                if SecretTextMethodId(MethodName, A) <> 0 then
                    exit(true);
            end else
                if (BigTextMethodId(MethodName, A, false) <> 0) or (BigTextMethodId(MethodName, A, true) <> 0) then
                    exit(true);
        exit(false);
    end;

    // Marker base for BigText/SecretText methods. MORE negative than XmlMethodMark(-12000).
    procedure BigTextMethodMark(): Integer
    begin
        exit(-13000);
    end;

    // ===== M6 stream methods (§19.7) =====

    // Is a receiver expression a stream variable? (NameExpr whose symbol is In/OutStream.)
    local procedure IsStreamReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
        T: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        T := Symbols.GetType(Sid);
        exit((T = "ALI TypeKind"::InStream) or (T = "ALI TypeKind"::OutStream));
    end;

    // `strm.Method(args)`. Method ids: 1 WriteText 2 WriteLine 3 ReadText 4 EOS 5 Length
    // 6 Link 7 Write 8 Read 9 Position (get/set) 10 ResetPosition — plus 11, the Position
    // SETTER reached only through `strm.Position := n` (TryBindStreamPropertySet). Node
    // SymbolId = StreamMethodMark() - methodId; the receiver's slot is the stream handle
    // (lowerer reads it from the callee's child-0 symbol).
    local procedure BindStreamMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgSid: Integer;
        ArgT: Integer;
        MethodId: Integer;
        RecvNode: Integer;
        RecvT: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        RecvT := BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := StreamMethodId(MethodName);
        if MethodId = 0 then begin
            Diags.AddError('ALI968', StrSubstNo('Stream method ''%1'' is not supported (M6)', Tokens.GetIdentText(NMainTok.Get(CalleeNode))), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // WriteText([text[, length]]) — OutStream only. Native arities: 0 args
                    // writes the line terminator, 1 the text, 2 the text truncated to length.
                begin
                    if RecvT <> "ALI TypeKind"::OutStream then
                        Diags.AddError('ALI968', StrSubstNo('%1 is only valid on an OutStream', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount > 2 then
                        Diags.AddError('ALI916', StrSubstNo('WriteText expects between 0 and 2 arguments, got %1', ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else begin
                        if ArgCount >= 1 then
                            CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                        if ArgCount = 2 then
                            CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    end;
                end;
            2:      // WriteLine(text) — OutStream only
                begin
                    if RecvT <> "ALI TypeKind"::OutStream then
                        Diags.AddError('ALI968', StrSubstNo('%1 is only valid on an OutStream', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount <> 1 then
                        Diags.AddError('ALI916', StrSubstNo('%1 expects 1 argument, got %2', MethodName, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                end;
            3:      // ReadText(var text[, length]) -> Integer (chars read) — InStream only
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'ReadText is only valid on an InStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    ArgT := BindStreamReadArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount, 'ReadText');
                    if ArgT <> "ALI TypeKind"::ErrorType then
                        if (not TypeRules.IsTextFamily(ArgT)) or (ArgT = "ALI TypeKind"::Label) then
                            Diags.AddError('ALI968', StrSubstNo('ReadText does not support target type %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgOrMissing(Ast, Node, 1))), 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            4:      // EOS() -> Bool — InStream
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'EOS is only valid on an InStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    CheckStreamArgCount(Tokens, Ast, Diags, Node, 'EOS', ArgCount, 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            5:      // Length() -> Int
                begin
                    CheckStreamArgCount(Tokens, Ast, Diags, Node, 'Length', ArgCount, 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            7:      // Write(value) -> Integer (bytes) — OutStream only, native typed binary write
                begin
                    if RecvT <> "ALI TypeKind"::OutStream then
                        Diags.AddError('ALI968', 'Write is only valid on an OutStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount <> 1 then
                        Diags.AddError('ALI916', StrSubstNo('Write expects 1 argument, got %1', ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else begin
                        ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                        if (ArgT <> "ALI TypeKind"::ErrorType) and (not IsStreamValueType(ArgT)) then
                            Diags.AddError('ALI968', StrSubstNo('Write does not support value type %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 1))), 0);
                    end;
                    ResultT := "ALI TypeKind"::Integer;
                end;
            8:      // Read(var target[, length]) -> Integer (bytes) — InStream only
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'Read is only valid on an InStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    ArgT := BindStreamReadArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount, 'Read');
                    // Variant is writable but NOT readable: native Read(var Any) cannot
                    // pick an overload from a Variant target (AL0196) — same in native AL.
                    if ArgT <> "ALI TypeKind"::ErrorType then
                        if (not IsStreamValueType(ArgT)) or (ArgT = "ALI TypeKind"::Variant) or (ArgT = "ALI TypeKind"::Label) then
                            Diags.AddError('ALI968', StrSubstNo('Read does not support target type %1', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgOrMissing(Ast, Node, 1))), 0);
                    ResultT := "ALI TypeKind"::Integer;
                end;
            9:      // Position -> Integer (get) / Position(newPos) (set). The `strm.Position := n`
                    // spelling is bound by TryBindStreamPropertySet, not here. InStream only —
                    // native OutStream has no Position.
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'Position is only valid on an InStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount > 1 then
                        Diags.AddError('ALI916', StrSubstNo('Position expects between 0 and 1 argument(s), got %1', ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else
                        if ArgCount = 1 then
                            CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if ArgCount = 0 then
                        ResultT := "ALI TypeKind"::Integer;
                end;
            10:     // ResetPosition() — rewind to the start of the backing (InStream only)
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'ResetPosition is only valid on an InStream', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    CheckStreamArgCount(Tokens, Ast, Diags, Node, 'ResetPosition', ArgCount, 0);
                end;
            6:      // Link(otherStream) — pair an InStream to an OutStream's backing
                begin
                    if RecvT <> "ALI TypeKind"::InStream then
                        Diags.AddError('ALI968', 'Link is only valid on an InStream (Link(outStream))', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    if ArgCount <> 1 then
                        Diags.AddError('ALI916', StrSubstNo('Link expects 1 argument, got %1', ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0)
                    else begin
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                        ArgSid := Ast.GetSymbolId(ArgOrMissing(Ast, Node, 1));
                        if ArgSid <= 0 then
                            Diags.AddError('ALI968', 'Link requires an OutStream argument', TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 1))), 0)
                        else
                            if Symbols.GetType(ArgSid) <> "ALI TypeKind"::OutStream then
                                Diags.AddError('ALI968', 'Link requires an OutStream argument', TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 1))), 0);
                    end;
                end;
        end;

        Ast.SetSymbolId(Node, StreamMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The stream method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // `strm.Position := n` — a Position member access on the LHS of a plain `:=` is a property
    // SET, not the (illegal) assignment to a method result. The receiver and the member access
    // were already bound by BindAssignment's TargetT bind (which resolved Position to the
    // GETTER, id 9); re-marking the node with the setter id 11 is what routes the lowerer to
    // STRM_POSSET instead of a record field store. Mirrors TryBindHttpPropertySet.
    local procedure TryBindStreamPropertySet(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; TargetNode: Integer; SourceNode: Integer): Boolean
    var
        RecvNode: Integer;
    begin
        if NKind.Get(TargetNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit(false);
        RecvNode := NEdges.Get(NFirstChild.Get(TargetNode) + 0);
        if ExprTypePeek(Tokens, Ast, Symbols, RecvNode) <> "ALI TypeKind"::InStream then
            exit(false);
        if UpperCase(Tokens.GetIdentText(NMainTok.Get(TargetNode))) <> 'POSITION' then
            exit(false);
        CheckAssignable(Tokens, Ast, Diags, SourceNode, "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, SourceNode));
        Ast.SetSymbolId(TargetNode, StreamMethodMark() - 11);
        exit(true);
    end;

    // Args of Read/ReadText(var target[, length]). The target is a WRITE target (native var
    // param), so it must be a plain assignable variable — same contract as Evaluate's first
    // argument. Returns the target's type, ErrorType once a diagnostic was raised.
    local procedure BindStreamReadArgs(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgCount: Integer; MethodName: Text): Integer
    var
        ArgSid: Integer;
        TargetNode: Integer;
    begin
        if (ArgCount < 1) or (ArgCount > 2) then begin
            Diags.AddError('ALI916', StrSubstNo('%1 expects between 1 and 2 arguments, got %2', MethodName, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        TargetNode := ArgOrMissing(Ast, Node, 1);
        BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        if ArgCount = 2 then
            CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
        ArgSid := Ast.GetSymbolId(TargetNode);
        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (ArgSid <= 0) or (not Symbols.IsVariableKind(ArgSid)) then begin
            Diags.AddError('ALI917', StrSubstNo('The argument of %1 must be an assignable variable', MethodName), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(Symbols.GetType(ArgSid));
    end;

    local procedure CheckStreamArgCount(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; MethodName: Text; ArgCount: Integer; Expected: Integer)
    begin
        if ArgCount <> Expected then
            Diags.AddError('ALI916', StrSubstNo('%1 expects %2 argument(s), got %3', MethodName, Expected, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
    end;

    local procedure StreamMethodId(UpperName: Text): Integer
    begin
        case UpperName of
            'WRITETEXT':
                exit(1);
            'WRITELINE':
                exit(2);
            'READTEXT':
                exit(3);
            'EOS':
                exit(4);
            'LENGTH':
                exit(5);
            'LINK':
                exit(6);
            'WRITE':
                exit(7);
            'READ':
                exit(8);
            'POSITION':
                exit(9);
            'RESETPOSITION':
                exit(10);
            else
                exit(0);
        end;
    end;

    // Types native Read/Write can carry over a stream (the runtime resolves the native typed
    // overload from the TypeKind ordinal — see "ALI Stream Runtime".WriteValue). Char/Byte are
    // NOT here: their register class is Int, so the interpreter cannot hand the native call a
    // 1-byte local and the on-stream width would silently differ from native AL.
    local procedure IsStreamValueType(T: Integer): Boolean
    begin
        exit(TypeRules.IsTextFamily(T) or
             (T = "ALI TypeKind"::Integer) or (T = "ALI TypeKind"::BigInteger) or (T = "ALI TypeKind"::Decimal) or
             (T = "ALI TypeKind"::Boolean) or (T = "ALI TypeKind"::Option) or (T = "ALI TypeKind"::Enum) or
             (T = "ALI TypeKind"::Date) or (T = "ALI TypeKind"::Time) or (T = "ALI TypeKind"::DateTime) or
             (T = "ALI TypeKind"::Duration) or (T = "ALI TypeKind"::Guid) or (T = "ALI TypeKind"::Variant));
    end;

    procedure StreamMethodMark(): Integer
    begin
        exit(-2000);
    end;

    // ===== M9 TextBuilder methods =====

    // Is a receiver expression a TextBuilder variable? Same shape as IsStreamReceiver.
    local procedure IsTextBuilderReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::TextBuilder);
    end;

    // `tb.Method(args)`. Method ids (arity distinguishes overloads — mirrors the record
    // method table's Add1/Add2/Add3 style): 1 Append(Text) 2 AppendLine() 3 AppendLine(Text)
    // 4 Capacity()->Int 5 Capacity(Int) 6 Clear() 7 EnsureCapacity(Int) 8 Insert(Int,Text)
    // 9 Length()->Int 10 Length(Int) 11 MaxCapacity()->Int 12 Remove(Int,Int)
    // 13 Replace(Text,Text) 14 Replace(Text,Text,Int,Int) 15 ToText()->Text
    // 16 ToText(Int,Int)->Text. Node SymbolId = TextBuilderMethodMark() - methodId; the
    // receiver's slot is the TextBuilder handle (lowerer reads it from the callee's child-0
    // symbol, same contract as streams).
    local procedure BindTextBuilderMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        MethodId: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));    // receiver
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := TextBuilderMethodId(MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, 'TextBuilder', TextBuilderMethodNameKnown(MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // Append(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            2:      // AppendLine()
                ;
            3:      // AppendLine(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            4:      // Capacity() -> Int
                ResultT := "ALI TypeKind"::Integer;
            5:      // Capacity(Int)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            6:      // Clear()
                ;
            7:      // EnsureCapacity(Int)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            8:      // Insert(Int, Text)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            9:      // Length() -> Int
                ResultT := "ALI TypeKind"::Integer;
            10:     // Length(Int)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            11:     // MaxCapacity() -> Int
                ResultT := "ALI TypeKind"::Integer;
            12:     // Remove(Int, Int)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            13:     // Replace(Text, Text)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            14:     // Replace(Text, Text, Int, Int)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 4), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 4)));
                end;
            15:     // ToText() -> Text
                ResultT := "ALI TypeKind"::Text;
            16:     // ToText(Int, Int) -> Text
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Text;
                end;
        end;

        Ast.SetSymbolId(Node, TextBuilderMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The TextBuilder method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // Method id keyed by (UpperName, ArgCount) — resolves the overloaded pairs (AppendLine,
    // Capacity, Length, Replace, ToText) by arity, same style as record's arity-keyed table.
    local procedure TextBuilderMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'APPEND':
                if ArgCount = 1 then
                    exit(1);
            'APPENDLINE':
                case ArgCount of
                    0:
                        exit(2);
                    1:
                        exit(3);
                end;
            'CAPACITY':
                case ArgCount of
                    0:
                        exit(4);
                    1:
                        exit(5);
                end;
            'CLEAR':
                if ArgCount = 0 then
                    exit(6);
            'ENSURECAPACITY':
                if ArgCount = 1 then
                    exit(7);
            'INSERT':
                if ArgCount = 2 then
                    exit(8);
            'LENGTH':
                case ArgCount of
                    0:
                        exit(9);
                    1:
                        exit(10);
                end;
            'MAXCAPACITY':
                if ArgCount = 0 then
                    exit(11);
            'REMOVE':
                if ArgCount = 2 then
                    exit(12);
            'REPLACE':
                case ArgCount of
                    2:
                        exit(13);
                    4:
                        exit(14);
                end;
            'TOTEXT':
                case ArgCount of
                    0:
                        exit(15);
                    2:
                        exit(16);
                end;
        end;
        exit(0);
    end;

    procedure TextBuilderMethodMark(): Integer
    begin
        exit(-4000);
    end;

    // ===== Dialog (progress window) methods (§8) =====
    // Void methods only: 1 Open(Text) 2 Update() 3 Update(Integer) 4 Update(Integer, value)
    // 5 Close(). Node SymbolId = DialogMethodMark() - methodId; receiver slot = the Dialog handle.

    local procedure IsDialogReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::Dialog);
    end;

    local procedure BindDialogMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        MethodId: Integer;
        MethodName: Text;
    begin
        BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(CalleeNode) + 0));    // receiver
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := DialogMethodId(MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, 'Dialog', DialogMethodNameKnown(MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        case MethodId of
            1: // Open(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            2: // Update()
                ;
            3: // Update(Integer)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            4: // Update(Integer, value) — value is any type, formatted to text at runtime
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2));
                end;
            5: // Close()
                ;
        end;

        Ast.SetSymbolId(Node, DialogMethodMark() - MethodId);
        if not IsStatement then begin
            Diags.AddError('ALI929', StrSubstNo('The Dialog method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit("ALI TypeKind"::None);
    end;

    local procedure DialogMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'OPEN':
                if ArgCount = 1 then
                    exit(1);
            'UPDATE':
                case ArgCount of
                    0:
                        exit(2);
                    1:
                        exit(3);
                    2:
                        exit(4);
                end;
            'CLOSE':
                if ArgCount = 0 then
                    exit(5);
        end;
        exit(0);
    end;

    // Most-negative mark (checked FIRST in the lowerer's statement dispatch, ahead of
    // RecordIdMethodMark -7000) so a Dialog method node is never mis-routed.
    procedure DialogMethodMark(): Integer
    begin
        exit(-8000);
    end;

    // ===== List/Dictionary RefShim methods (see ListDictionaryPlan.md §4/§6) =====

    // Is a receiver expression a List variable? Same shape as IsTextBuilderReceiver.
    local procedure IsListReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::List);
    end;

    local procedure IsDictReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Boolean
    var
        Sid: Integer;
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit(false);
        Sid := Symbols.Lookup(Ast.GetExtra(RecvNode));
        if Sid = 0 then
            exit(false);
        exit(Symbols.GetType(Sid) = "ALI TypeKind"::Dictionary);
    end;

    // Recover the packed element/key-value TypeArg of a List/Dictionary-typed EXPRESSION —
    // needed because TargetT=SourceT=TList() alone (identity) does not distinguish
    // `List of [Integer]` from `List of [Text]`. Three shapes reach here: a plain variable
    // (read its symbol's TypeArg), a user procedure call (SymbolId = proc id > 0 — read the
    // PROC symbol's TypeArg, since a proc's return TArg is stored the same way), or a
    // List/Dictionary method call that synthesizes a NEW collection (Keys/Values/GetRange —
    // SymbolId is the negative method mark; the element/key/value class was stashed onto
    // Ast.SlotIndex at bind time, mirroring how array result element types are threaded).
    local procedure ListDictTArgOf(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Node: Integer): Integer
    var
        Sid: Integer;
    begin
        if NKind.Get(Node) = "ALI NodeKind"::NameExpr then begin
            Sid := Ast.GetSymbolId(Node);
            if Sid > 0 then
                exit(Symbols.GetTypeArg(Sid));
            exit(-1);
        end;
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then begin
            Sid := Ast.GetSymbolId(Node);
            if Sid > 0 then
                exit(Symbols.GetTypeArg(Sid));
            exit(Ast.GetSlotIndex(Node));
        end;
        exit(-1);
    end;

    // `L.Method(args)`. Method ids (arity distinguishes the two Get/Set arities that DO ship
    // in v1 — the `var value`/`var old` overloads are deferred, ListDictionaryPlan.md §6):
    // 1 Add(T) 2 AddRange(List) 3 Contains(T)->Bool 4 Count()->Int 5 Get(Int)->T
    // 6 GetRange(Int,Int)->List 7 IndexOf(T)->Int 8 Insert(Int,T) 9 Remove(T)->Bool
    // 10 RemoveAt(Int) 11 RemoveRange(Int,Int) 12 Reverse() 13 Set(Int,T)->T(old)
    // 14 ToArray() — bound but rejected (ALI985, array-threading deferred).
    local procedure BindListMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgT: Integer;
        ElemCls: Integer;
        ElemT: Integer;
        MethodId: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        ElemCls := Symbols.GetTypeArg(Ast.GetSymbolId(RecvNode));
        ElemT := TypeRules.TypeKindForRegClass(ElemCls);
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := ListMethodId(MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, 'List', ListMethodNameKnown(MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // Add(T)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            2:      // AddRange(List)
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if ArgT <> "ALI TypeKind"::ErrorType then
                        if (ArgT <> "ALI TypeKind"::List) or (ListDictTArgOf(Ast, Symbols, ArgOrMissing(Ast, Node, 1)) <> ElemCls) then
                            Diags.AddError('ALI984', 'AddRange requires a List of the same element type', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end;
            3:      // Contains(T) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            4:      // Count() -> Int
                ResultT := "ALI TypeKind"::Integer;
            5:      // Get(Int) -> T
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := ElemT;
                end;
            6:      // GetRange(Int, Int) -> List of [T]
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    Ast.SetSlotIndex(Node, ElemCls);
                    ResultT := "ALI TypeKind"::List;
                end;
            7:      // IndexOf(T) -> Int
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            8:      // Insert(Int, T)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            9:      // Remove(T) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            10:     // RemoveAt(Int)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            11:     // RemoveRange(Int, Int)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            12:     // Reverse()
                ;
            13:     // Set(Int, T) -> T (old)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), ElemT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := ElemT;
                end;
            14:     // ToArray() — deferred, ListDictionaryPlan.md §6
                begin
                    Diags.AddError('ALI985', 'List.ToArray is not supported in this milestone', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    exit("ALI TypeKind"::ErrorType);
                end;
        end;

        Ast.SetSymbolId(Node, ListMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The List method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    local procedure ListMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'ADD':
                if ArgCount = 1 then
                    exit(1);
            'ADDRANGE':
                if ArgCount = 1 then
                    exit(2);
            'CONTAINS':
                if ArgCount = 1 then
                    exit(3);
            'COUNT':
                if ArgCount = 0 then
                    exit(4);
            'GET':
                if ArgCount = 1 then
                    exit(5);
            'GETRANGE':
                if ArgCount = 2 then
                    exit(6);
            'INDEXOF':
                if ArgCount = 1 then
                    exit(7);
            'INSERT':
                if ArgCount = 2 then
                    exit(8);
            'REMOVE':
                if ArgCount = 1 then
                    exit(9);
            'REMOVEAT':
                if ArgCount = 1 then
                    exit(10);
            'REMOVERANGE':
                if ArgCount = 2 then
                    exit(11);
            'REVERSE':
                if ArgCount = 0 then
                    exit(12);
            'SET':
                if ArgCount = 2 then
                    exit(13);
            'TOARRAY':
                if ArgCount = 0 then
                    exit(14);
        end;
        exit(0);
    end;

    procedure ListMethodMark(): Integer
    begin
        exit(-5000);
    end;

    // `D.Method(args)`. Method ids: 1 Add(K,V) 2 ContainsKey(K)->Bool 3 Count()->Int
    // 4 Get(K)->V 5 Keys()->List of [K] 6 Values()->List of [V] 7 Remove(K)->Bool
    // 8 Set(K,V) (add-or-update) 9 Get(K, var V)->Bool (native TryGetValue-style overload).
    local procedure BindDictMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        KeyCls: Integer;
        KeyT: Integer;
        MethodId: Integer;
        PackedArg: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        ValCls: Integer;
        ValT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        PackedArg := Symbols.GetTypeArg(Ast.GetSymbolId(RecvNode));
        KeyCls := PackedArg div 16;
        ValCls := PackedArg mod 16;
        KeyT := TypeRules.TypeKindForRegClass(KeyCls);
        ValT := TypeRules.TypeKindForRegClass(ValCls);
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := DictMethodId(MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, 'Dictionary', DictMethodNameKnown(MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            1:      // Add(K, V)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), ValT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            2:      // ContainsKey(K) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            3:      // Count() -> Int
                ResultT := "ALI TypeKind"::Integer;
            4:      // Get(K) -> V
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := ValT;
                end;
            5:      // Keys() -> List of [K]
                begin
                    Ast.SetSlotIndex(Node, KeyCls);
                    ResultT := "ALI TypeKind"::List;
                end;
            6:      // Values() -> List of [V]
                begin
                    Ast.SetSlotIndex(Node, ValCls);
                    ResultT := "ALI TypeKind"::List;
                end;
            7:      // Remove(K) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            8:      // Set(K, V) — add-or-update
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), ValT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            9:      // Get(K, var V) -> Bool — scalar var-out, arg 2 is written only on a hit
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), KeyT, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if not BindValueOutArgAt(Tokens, Ast, Symbols, Diags, Node, 2, ValT, 'Get') then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
        end;

        Ast.SetSymbolId(Node, DictMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The Dictionary method ''%1'' does not return a value', MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    local procedure DictMethodId(UpperName: Text; ArgCount: Integer): Integer
    begin
        case UpperName of
            'ADD':
                if ArgCount = 2 then
                    exit(1);
            'CONTAINSKEY':
                if ArgCount = 1 then
                    exit(2);
            'COUNT':
                if ArgCount = 0 then
                    exit(3);
            'GET':
                begin
                    if ArgCount = 1 then
                        exit(4);
                    if ArgCount = 2 then
                        exit(9);
                end;
            'KEYS':
                if ArgCount = 0 then
                    exit(5);
            'VALUES':
                if ArgCount = 0 then
                    exit(6);
            'REMOVE':
                if ArgCount = 1 then
                    exit(7);
            'SET':
                if ArgCount = 2 then
                    exit(8);
        end;
        exit(0);
    end;

    procedure DictMethodMark(): Integer
    begin
        exit(-6000);
    end;

    // ===== M10 Http* RefShim methods =====
    //
    // Http* variables are Int-handle RefShim (List/Dict scheme, "ALI Type Rules".RegClassFor)
    // — NOT their own handle space. Method ids are packed by RECEIVER KIND range: 1-19
    // HttpClient, 20-39 HttpRequestMessage, 40-59 HttpResponseMessage, 60-79 HttpContent,
    // 80-99 HttpHeaders; each range's first id (1/20/40/60/80) is the compiler-internal "New"
    // allocator emitted by the lowerer at declaration (mirrors LIST_NEW/DICT_NEW) and never
    // resolves from user text. := between same-kind Http vars and handle-returning methods
    // (e.g. `Content := Response.Content()`) need NO special binder mechanic: TargetT=SourceT
    // identity already makes AssignmentCompatible true (§ALITypeRules.AssignmentCompatible),
    // and a handle-returning method's ResultT is just the Http TypeKind like any other method.

    // Is a receiver expression Http*-typed? Returns the specific TypeKind (92-96) or None.
    // Detects from the receiver's BOUND type (ExprTypePeek) — NOT a NameExpr-only symbol
    // lookup — so a chained receiver that is itself a call result
    // (`Client.DefaultRequestHeaders().TryAddWithoutValidation(...)`, `Resp.Content().ReadAs()`)
    // dispatches here instead of falling through to the record path. Mirrors
    // JsonKindOfReceiver, which peeks the same way.
    local procedure HttpKindOfReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    begin
        exit(HttpKindFromTypeOrd(ExprTypePeek(Tokens, Ast, Symbols, RecvNode)));
    end;

    // Narrow an arbitrary bound TypeOrd to one of the 5 Http kinds, or None.
    local procedure HttpKindFromTypeOrd(T: Integer): Integer
    begin
        case T of
            "ALI TypeKind"::HttpClient, "ALI TypeKind"::HttpRequestMessage, "ALI TypeKind"::HttpResponseMessage,
            "ALI TypeKind"::HttpContent, "ALI TypeKind"::HttpHeaders:
                exit(T);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // ===== Method-not-found diagnostics (unknown name vs wrong arity) =====
    //
    // The per-type method-id tables key on (name, argcount), so a miss alone cannot tell
    // "no such method" from "right method, wrong argument count". The *MethodNameKnown
    // probes re-ask the same table for ANY arity (0..12 covers every table); the split
    // mirrors Microsoft: AL0132 "does not contain a definition" vs ALI916 arity error.

    local procedure AddMethodDiag(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; CalleeNode: Integer; TypeNameTxt: Text; NameKnown: Boolean; ArgCount: Integer)
    var
        Ident: Text;
    begin
        Ident := Tokens.GetIdentText(NMainTok.Get(CalleeNode));
        if NameKnown then
            Diags.AddError('ALI916', StrSubstNo('The method ''%1'' exists on %2 but cannot be called with %3 argument(s)', Ident, TypeNameTxt, ArgCount), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0)
        else
            Diags.AddError('AL0132', StrSubstNo('''%1'' does not contain a definition for ''%2''', TypeNameTxt, Ident) + SuggestMethod(TypeNameTxt, Ident), TokPos(Tokens, NMainTok.Get(CalleeNode)), 0);
    end;

    local procedure HttpMethodNameKnown(Kind: Integer; MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if HttpMethodId(Kind, MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    local procedure JsonMethodNameKnown(Kind: Integer; MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if JsonMethodId(Kind, MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    local procedure ListMethodNameKnown(MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if ListMethodId(MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    local procedure DictMethodNameKnown(MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if DictMethodId(MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    local procedure TextBuilderMethodNameKnown(MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if TextBuilderMethodId(MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    local procedure DialogMethodNameKnown(MethodName: Text): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if DialogMethodId(MethodName, A) <> 0 then
                exit(true);
        exit(false);
    end;

    // `h.Method(args)`. Method id table (arity distinguishes overloads, mirrors TextBuilder's
    // style): see HttpMethodId for the full name/arity -> id map per receiver kind.
    local procedure BindHttpMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgT: Integer;
        Kind: Integer;
        MethodId: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        // Bind the receiver ONCE (any expression, including a chained call result like
        // `Client.DefaultRequestHeaders()`), then read its bound TypeOrd — never re-peek
        // (which would bind a chained receiver a second time). Mirrors BindJsonMethod.
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        Kind := HttpKindFromTypeOrd(Ast.GetTypeOrd(RecvNode));
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := HttpMethodId(Kind, MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, TypeRules.TypeName(Kind), HttpMethodNameKnown(Kind, MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            // ----- HttpClient -----
            2, 3, 4, 5, 6:      // Get/Post/Put/Delete(Text[, Content], var Response) / Send(Request, var Response) -> Boolean
                begin
                    if MethodId = 6 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::HttpRequestMessage, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)))
                    else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if (MethodId = 3) or (MethodId = 4) then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::HttpContent, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, NEdges.Get(NFirstChild.Get(Node) + ArgCount), "ALI TypeKind"::HttpResponseMessage, BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + ArgCount)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            7:      // SetBaseAddress(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            8:      // Timeout() -> Duration
                ResultT := "ALI TypeKind"::Duration;
            9:      // Timeout(Duration or Integer — native accepts an Integer ms count directly)
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if (ArgT <> "ALI TypeKind"::ErrorType) and (ArgT <> "ALI TypeKind"::Duration) and (ArgT <> "ALI TypeKind"::Integer) then
                        Diags.AddError('ALI983', 'Timeout expects a Duration or Integer argument', TokPos(Tokens, NMainTok.Get(Node)), 0);
                end;
            10:     // DefaultRequestHeaders() -> HttpHeaders (handle-returning)
                ResultT := "ALI TypeKind"::HttpHeaders;
            11:     // Clear()
                ;
            // ----- HttpRequestMessage -----
            21:     // Method() -> Text
                ResultT := "ALI TypeKind"::Text;
            22:     // Method(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            23:     // SetRequestUri(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            24:     // GetRequestUri() -> Text
                ResultT := "ALI TypeKind"::Text;
            25:     // Content() -> HttpContent (handle-returning getter)
                ResultT := "ALI TypeKind"::HttpContent;
            26:     // Content(HttpContent) (setter)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::HttpContent, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            27:     // GetHeaders() -> HttpHeaders (handle-returning)
                ResultT := "ALI TypeKind"::HttpHeaders;
            28:     // GetHeaders(var HttpHeaders) — native shape, fills caller's handle in place
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::HttpHeaders, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            // ----- HttpResponseMessage -----
            41:     // HttpStatusCode() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            42:     // IsSuccessStatusCode() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            43:     // ReasonPhrase() -> Text
                ResultT := "ALI TypeKind"::Text;
            44:     // IsBlockedByEnvironment() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            45:     // Content() -> HttpContent (handle-returning)
                ResultT := "ALI TypeKind"::HttpContent;
            46:     // Headers() -> HttpHeaders (handle-returning)
                ResultT := "ALI TypeKind"::HttpHeaders;
            // ----- HttpContent -----
            61:     // WriteFrom(Text)
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            62:     // ReadAs() -> Text (simplified v1 shape vs native var-param form)
                ResultT := "ALI TypeKind"::Text;
            63:     // GetHeaders() -> HttpHeaders (handle-returning)
                ResultT := "ALI TypeKind"::HttpHeaders;
            64:     // Clear()
                ;
            65:     // ReadAs(var Text) -> Boolean — native shape, writes body back into the arg
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'ReadAs') then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            66:     // GetHeaders(var HttpHeaders) -> Boolean — fills caller's handle in place
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::HttpHeaders, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            // ----- HttpHeaders -----
            81:     // Add(Text, Text)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                end;
            82:     // TryAddWithoutValidation(Text, Text) -> Boolean
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            83:     // Contains(Text) -> Boolean
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            84:     // Remove(Text) -> Boolean
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            85:     // Clear()
                ;
            86:     // GetValues(Text, var List of [Text]) -> Boolean — 2nd arg reuses the List RefShim
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2));
                    if ArgT <> "ALI TypeKind"::ErrorType then
                        if (ArgT <> "ALI TypeKind"::List) or (ListDictTArgOf(Ast, Symbols, ArgOrMissing(Ast, Node, 2)) <> "ALI Register Class"::"Text") then
                            Diags.AddError('ALI983', 'GetValues requires a List of [Text]', TokPos(Tokens, NMainTok.Get(Node)), 0);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
        end;

        Ast.SetSymbolId(Node, HttpMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The %1 method ''%2'' does not return a value', TypeRules.TypeName(Kind), MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // Method id keyed by (receiver Kind, UpperName, ArgCount). Ranges: 1-19 HttpClient,
    // 20-39 HttpRequestMessage, 40-59 HttpResponseMessage, 60-79 HttpContent, 80-99
    // HttpHeaders (see "ALI Opcode" HTTP_METHOD header). Ids 1/20/40/60/80 ("New") are
    // compiler-internal only and never returned here.
    local procedure HttpMethodId(Kind: Integer; UpperName: Text; ArgCount: Integer): Integer
    begin
        case Kind of
            "ALI TypeKind"::HttpClient:
                case UpperName of
                    'GET':
                        if ArgCount = 2 then
                            exit(2);
                    'POST':
                        if ArgCount = 3 then
                            exit(3);
                    'PUT':
                        if ArgCount = 3 then
                            exit(4);
                    'DELETE':
                        if ArgCount = 2 then
                            exit(5);
                    'SEND':
                        if ArgCount = 2 then
                            exit(6);
                    'SETBASEADDRESS':
                        if ArgCount = 1 then
                            exit(7);
                    'TIMEOUT':
                        case ArgCount of
                            0:
                                exit(8);
                            1:
                                exit(9);
                        end;
                    'DEFAULTREQUESTHEADERS':
                        if ArgCount = 0 then
                            exit(10);
                    'CLEAR':
                        if ArgCount = 0 then
                            exit(11);
                end;
            "ALI TypeKind"::HttpRequestMessage:
                case UpperName of
                    'METHOD':
                        case ArgCount of
                            0:
                                exit(21);
                            1:
                                exit(22);
                        end;
                    'SETREQUESTURI':
                        if ArgCount = 1 then
                            exit(23);
                    'GETREQUESTURI':
                        if ArgCount = 0 then
                            exit(24);
                    'CONTENT':
                        case ArgCount of
                            0:
                                exit(25);
                            1:
                                exit(26);
                        end;
                    'GETHEADERS':
                        case ArgCount of
                            0:
                                exit(27);
                            1:      // native-shape GetHeaders(var Headers) — fills the arg in place
                                exit(28);
                        end;
                end;
            "ALI TypeKind"::HttpResponseMessage:
                case UpperName of
                    'HTTPSTATUSCODE':
                        if ArgCount = 0 then
                            exit(41);
                    'ISSUCCESSSTATUSCODE':
                        if ArgCount = 0 then
                            exit(42);
                    'REASONPHRASE':
                        if ArgCount = 0 then
                            exit(43);
                    'ISBLOCKEDBYENVIRONMENT':
                        if ArgCount = 0 then
                            exit(44);
                    'CONTENT':
                        if ArgCount = 0 then
                            exit(45);
                    'HEADERS':
                        if ArgCount = 0 then
                            exit(46);
                end;
            "ALI TypeKind"::HttpContent:
                case UpperName of
                    'WRITEFROM':
                        if ArgCount = 1 then
                            exit(61);
                    'READAS':
                        case ArgCount of
                            0:
                                exit(62);
                            1:      // native-shape ReadAs(var Text) -> Boolean
                                exit(65);
                        end;
                    'GETHEADERS':
                        case ArgCount of
                            0:
                                exit(63);
                            1:      // native-shape GetHeaders(var Headers) -> Boolean
                                exit(66);
                        end;
                    'CLEAR':
                        if ArgCount = 0 then
                            exit(64);
                end;
            "ALI TypeKind"::HttpHeaders:
                case UpperName of
                    'ADD':
                        if ArgCount = 2 then
                            exit(81);
                    'TRYADDWITHOUTVALIDATION':
                        if ArgCount = 2 then
                            exit(82);
                    'CONTAINS':
                        if ArgCount = 1 then
                            exit(83);
                    'REMOVE':
                        if ArgCount = 1 then
                            exit(84);
                    'CLEAR':
                        if ArgCount = 0 then
                            exit(85);
                    'GETVALUES':
                        if ArgCount = 2 then
                            exit(86);
                end;
        end;
        exit(0);
    end;

    procedure HttpMethodMark(): Integer
    begin
        exit(-9000);
    end;

    // Http* property SET via `recv.Prop := value`. TargetNode was already bound as the property
    // GETTER (parenless member access) by the caller; here we recognize the settable ones,
    // type-check the source, and re-mark TargetNode with the SETTER method id so
    // "ALI Lowerer".LowerAssignment emits an HTTP_METHOD setter call instead of a field store.
    // Returns false (leaving TargetNode as-is) for any non-Http or read-only member.
    local procedure TryBindHttpPropertySet(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; TargetNode: Integer; SourceNode: Integer): Boolean
    var
        Kind: Integer;
        PropT: Integer;
        RecvNode: Integer;
        SetterId: Integer;
    begin
        if NKind.Get(TargetNode) <> "ALI NodeKind"::MemberAccessExpr then
            exit(false);
        RecvNode := NEdges.Get(NFirstChild.Get(TargetNode) + 0);
        Kind := HttpKindOfReceiver(Tokens, Ast, Symbols, RecvNode);
        if Kind = "ALI TypeKind"::None then
            exit(false);
        SetterId := HttpPropertySetterId(Kind, UpperCase(Tokens.GetIdentText(NMainTok.Get(TargetNode))), PropT);
        if SetterId = 0 then
            exit(false);
        CheckAssignable(Tokens, Ast, Diags, SourceNode, PropT, BindExpr(Tokens, Ast, Symbols, Diags, SourceNode));
        Ast.SetSymbolId(TargetNode, HttpMethodMark() - SetterId);
        exit(true);
    end;

    // Settable Http* properties: getter member name -> (setter method id, property TypeKind).
    // Only members that native AL exposes as an assignable property belong here.
    local procedure HttpPropertySetterId(Kind: Integer; UpperName: Text; var PropT: Integer): Integer
    begin
        if Kind <> "ALI TypeKind"::HttpRequestMessage then
            exit(0);
        case UpperName of
            'METHOD':
                begin
                    PropT := "ALI TypeKind"::Text;
                    exit(22);
                end;
            'CONTENT':
                begin
                    PropT := "ALI TypeKind"::HttpContent;
                    exit(26);
                end;
        end;
        exit(0);
    end;

    // ===== Feature 2: Json* method binding (JsonObject/JsonArray/JsonToken/JsonValue) =====
    //
    // Same Int-handle RefShim scheme as Http* (BindHttpMethod above); mark -10000 (MOST
    // negative of every mark, checked FIRST in every dispatch cascade). := between same-kind
    // Json vars is a plain Int MOV (reference semantics, matches native); cross-kind assign is
    // rejected by AssignmentCompatible (TargetT<>SourceT). Var-out HANDLE args (Get/SelectToken
    // `var JsonToken`) use the Http var-out mechanism (the arg register carries the out handle
    // live; the runtime rebinds that handle's bank slot). The scalar var-out WriteTo(var Text)
    // is the one new mechanism (see BindTextOutArg / "ALI Lowerer".LowerJsonMethod).

    // Is a receiver expression Json*-typed? Returns the specific TypeKind (97-100) or None.
    // Detects from the receiver's BOUND type (ExprTypePeek) — NOT a NameExpr symbol lookup —
    // so a chained receiver that is itself a call result (`Tok.AsValue().AsInteger()`,
    // `t.AsObject().Count()`) dispatches here instead of falling through to the record path
    // (ALI934). Mirrors IsTextReceiver/IsVariantReceiver, which peek the same way.
    local procedure JsonKindOfReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    begin
        exit(JsonKindFromTypeOrd(ExprTypePeek(Tokens, Ast, Symbols, RecvNode)));
    end;

    // Narrow an arbitrary bound TypeOrd to one of the 4 Json kinds, or None.
    local procedure JsonKindFromTypeOrd(T: Integer): Integer
    begin
        case T of
            "ALI TypeKind"::JsonObject, "ALI TypeKind"::JsonArray, "ALI TypeKind"::JsonToken, "ALI TypeKind"::JsonValue:
                exit(T);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    local procedure BindJsonMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        ArgCount: Integer;
        ArgT: Integer;
        Kind: Integer;
        MethodId: Integer;
        Off: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        // Bind the receiver ONCE (any expression, including a chained call result), then read
        // its bound TypeOrd — never re-peek (which would bind a chained receiver a second time).
        BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
        Kind := JsonKindFromTypeOrd(Ast.GetTypeOrd(RecvNode));
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        MethodId := JsonMethodId(Kind, MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, TypeRules.TypeName(Kind), JsonMethodNameKnown(Kind, MethodName), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            // ----- JsonObject.Add(name, value): ids 2-8, value TypeOrd-discriminated -----
            2:
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2));
                    Off := JsonAddValueOffset(ArgT);
                    if Off < 0 then begin
                        Diags.AddError('ALI994', StrSubstNo('JsonObject.Add value must be Text, Integer, BigInteger, Decimal, Boolean, Option, Date, Time, DateTime, JsonToken, JsonObject or JsonArray (got %1)', TypeRules.TypeName(ArgT)), TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 2))), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    MethodId := JsonAddMethodId(2, Off);
                end;
            9:      // Contains(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            10:     // Get(Text, var JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            11:     // Remove(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            12:     // Replace(Text, JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            13:     // WriteTo(var Text) -> Bool
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'WriteTo') then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            14:     // ReadFrom(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            15:     // Keys() -> List of [Text]
                begin
                    Ast.SetSlotIndex(Node, "ALI Register Class"::"Text");
                    ResultT := "ALI TypeKind"::List;
                end;
            16:     // Count() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            17:     // AsToken() -> JsonToken
                ResultT := "ALI TypeKind"::JsonToken;
            18:     // Clone() -> JsonObject
                ResultT := "ALI TypeKind"::JsonObject;

            // ----- JsonArray.Add(value): ids 27-33, value TypeOrd-discriminated -----
            27:
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    Off := JsonAddValueOffset(ArgT);
                    if Off < 0 then begin
                        Diags.AddError('ALI994', StrSubstNo('JsonArray.Add value must be Text, Integer, BigInteger, Decimal, Boolean, Option, Date, Time, DateTime, JsonToken, JsonObject or JsonArray (got %1)', TypeRules.TypeName(ArgT)), TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 1))), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    MethodId := JsonAddMethodId(27, Off);
                end;
            34:     // Get(Integer, var JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            35:     // Set(Integer, JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            36:     // Insert(Integer, JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            37:     // RemoveAt(Integer) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            38:     // Count() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            39:     // IndexOf(JsonToken) -> Integer
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Integer;
                end;
            40:     // WriteTo(var Text) -> Bool
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'WriteTo') then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            41:     // ReadFrom(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            42:     // AsToken() -> JsonToken
                ResultT := "ALI TypeKind"::JsonToken;
            43:     // Clone() -> JsonArray
                ResultT := "ALI TypeKind"::JsonArray;

            // ----- JsonToken -----
            52:     // ReadFrom(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            53:     // WriteTo(var Text) -> Bool
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'WriteTo') then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            54:     // IsObject() -> Bool
                ResultT := "ALI TypeKind"::Boolean;
            55:     // IsArray() -> Bool
                ResultT := "ALI TypeKind"::Boolean;
            56:     // IsValue() -> Bool
                ResultT := "ALI TypeKind"::Boolean;
            57:     // AsObject() -> JsonObject
                ResultT := "ALI TypeKind"::JsonObject;
            58:     // AsArray() -> JsonArray
                ResultT := "ALI TypeKind"::JsonArray;
            59:     // AsValue() -> JsonValue
                ResultT := "ALI TypeKind"::JsonValue;
            60:     // Clone() -> JsonToken
                ResultT := "ALI TypeKind"::JsonToken;
            61:     // SelectToken(Text, var JsonToken) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::JsonToken, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;

            // ----- JsonValue.SetValue(value): ids 77-83, value TypeOrd-discriminated -----
            77:
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    Off := JsonSetValueOffset(ArgT);
                    if Off < 0 then begin
                        Diags.AddError('ALI994', StrSubstNo('JsonValue.SetValue value must be Text, Integer, BigInteger, Decimal, Boolean, Option, Date, Time or DateTime (got %1)', TypeRules.TypeName(ArgT)), TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 1))), 0);
                        exit("ALI TypeKind"::ErrorType);
                    end;
                    MethodId := 77 + Off;
                end;
            // ----- Typed getters GetX(Key/Idx [, DefaultIfNotFound]) — JSON_METHOD2 ids -----
            // 101-116 JsonObject (arg1 Text), 131-146 JsonArray (arg1 Integer). Optional arg2
            // Boolean. Result type = the getter's own type (JsonGetterResultT by offset).
            101 .. 116:
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := JsonGetterResultT(MethodId - 101);
                end;
            131 .. 146:
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if ArgCount = 2 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := JsonGetterResultT(MethodId - 131);
                end;

            84:     // AsText() -> Text
                ResultT := "ALI TypeKind"::Text;
            85:     // AsCode() -> Code
                ResultT := "ALI TypeKind"::Code;
            86:     // AsInteger() -> Integer
                ResultT := "ALI TypeKind"::Integer;
            87:     // AsDecimal() -> Decimal
                ResultT := "ALI TypeKind"::Decimal;
            88:     // AsBoolean() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            89:     // AsDate() -> Date
                ResultT := "ALI TypeKind"::Date;
            90:     // AsTime() -> Time
                ResultT := "ALI TypeKind"::Time;
            91:     // AsDateTime() -> DateTime
                ResultT := "ALI TypeKind"::DateTime;
            92:     // IsNull() -> Boolean
                ResultT := "ALI TypeKind"::Boolean;
            93:     // AsToken() -> JsonToken
                ResultT := "ALI TypeKind"::JsonToken;
            94:     // AsByte() -> Byte
                ResultT := "ALI TypeKind"::Byte;
            95:     // AsChar() -> Char
                ResultT := "ALI TypeKind"::Char;
            96:     // AsOption() -> Option
                ResultT := "ALI TypeKind"::Option;
        end;

        Ast.SetSymbolId(Node, JsonMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The %1 method ''%2'' does not return a value', TypeRules.TypeName(Kind), MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // Add/Insert/IndexOf value overload offset (Text/Integer/Decimal/Boolean/JsonToken/
    // JsonObject/JsonArray -> 0..6); -1 if the value type is unsupported.
    // Value-type discriminator for JsonObject.Add / JsonArray.Add. Offsets 0-6 map onto the
    // original contiguous id blocks (2-8 / 27-33); offsets 7-10 (Date/Time/DateTime/
    // BigInteger — all native Add overloads) land on the id-range tail (19-22 / 44-47)
    // because ids 9+/34+ were already taken — JsonAddMethodId does that rebasing.
    // Char/Byte/Option/Enum ride the Integer offset: they live in the Int register class, so
    // the runtime's ArgAsInt reads them unchanged (an Option adds as its ordinal, native).
    local procedure JsonAddValueOffset(T: Integer): Integer
    begin
        case true of
            TypeRules.IsTextFamily(T):
                exit(0);
            (T = "ALI TypeKind"::BigInteger):
                exit(10);
            TypeRules.IsIntegerFamily(T):
                exit(1);
            (T = "ALI TypeKind"::Decimal):
                exit(2);
            (T = "ALI TypeKind"::Boolean):
                exit(3);
            (T = "ALI TypeKind"::JsonToken):
                exit(4);
            (T = "ALI TypeKind"::JsonObject):
                exit(5);
            (T = "ALI TypeKind"::JsonArray):
                exit(6);
            (T = "ALI TypeKind"::Date):
                exit(7);
            (T = "ALI TypeKind"::Time):
                exit(8);
            (T = "ALI TypeKind"::DateTime):
                exit(9);
        end;
        exit(-1);
    end;

    // Rebase an Add value-offset onto the actual method id: Base = 2 (JsonObject.Add) or 27
    // (JsonArray.Add); tail offsets 7-10 continue at id Base+17 (19-22 / 44-47).
    local procedure JsonAddMethodId(BaseId: Integer; Off: Integer): Integer
    begin
        if Off <= 6 then
            exit(BaseId + Off);
        exit(BaseId + 17 + (Off - 7));
    end;

    // Typed-getter result type by offset within a GetX id range (101-116 / 131-146):
    // 0 GetText, 1 GetInteger, 2 GetBigInteger, 3 GetDecimal, 4 GetBoolean, 5 GetDate,
    // 6 GetTime, 7 GetDateTime, 8 GetDuration, 9 GetGuid, 10 GetObject, 11 GetArray,
    // 12 GetValue, 13 GetByte, 14 GetChar, 15 GetOption. Shared by JsonObject and JsonArray
    // (same order in both ranges).
    local procedure JsonGetterResultT(Off: Integer): Integer
    begin
        case Off of
            0:
                exit("ALI TypeKind"::Text);
            1:
                exit("ALI TypeKind"::Integer);
            2:
                exit("ALI TypeKind"::BigInteger);
            3:
                exit("ALI TypeKind"::Decimal);
            4:
                exit("ALI TypeKind"::Boolean);
            5:
                exit("ALI TypeKind"::Date);
            6:
                exit("ALI TypeKind"::Time);
            7:
                exit("ALI TypeKind"::DateTime);
            8:
                exit("ALI TypeKind"::Duration);
            9:
                exit("ALI TypeKind"::Guid);
            10:
                exit("ALI TypeKind"::JsonObject);
            11:
                exit("ALI TypeKind"::JsonArray);
            12:
                exit("ALI TypeKind"::JsonValue);
            13:
                exit("ALI TypeKind"::Byte);
            14:
                exit("ALI TypeKind"::Char);
            15:
                exit("ALI TypeKind"::Option);
        end;
        exit("ALI TypeKind"::ErrorType);
    end;

    // Map a GetX getter name to its offset (see JsonGetterResultT); -1 if not a getter name.
    local procedure JsonGetterOffset(UpperName: Text): Integer
    begin
        case UpperName of
            'GETTEXT':
                exit(0);
            'GETINTEGER':
                exit(1);
            'GETBIGINTEGER':
                exit(2);
            'GETDECIMAL':
                exit(3);
            'GETBOOLEAN':
                exit(4);
            'GETDATE':
                exit(5);
            'GETTIME':
                exit(6);
            'GETDATETIME':
                exit(7);
            'GETDURATION':
                exit(8);
            'GETGUID':
                exit(9);
            'GETOBJECT':
                exit(10);
            'GETARRAY':
                exit(11);
            'GETVALUE':
                exit(12);
            'GETBYTE':
                exit(13);
            'GETCHAR':
                exit(14);
            'GETOPTION':
                exit(15);
        end;
        exit(-1);
    end;

    // JsonValue.SetValue overload offset (Text/Integer/Decimal/Boolean/Date/Time/DateTime ->
    // 0..6); -1 if unsupported.
    local procedure JsonSetValueOffset(T: Integer): Integer
    begin
        case true of
            TypeRules.IsTextFamily(T):
                exit(0);
            (T = "ALI TypeKind"::BigInteger):
                exit(2);        // exact in Decimal (96-bit mantissa covers any Int64)
            TypeRules.IsIntegerFamily(T):
                exit(1);        // Char/Byte/Option/Enum are Int-class registers
            (T = "ALI TypeKind"::Decimal):
                exit(2);
            (T = "ALI TypeKind"::Boolean):
                exit(3);
            (T = "ALI TypeKind"::Date):
                exit(4);
            (T = "ALI TypeKind"::Time):
                exit(5);
            (T = "ALI TypeKind"::DateTime):
                exit(6);
        end;
        exit(-1);
    end;

    // Scalar var-out Text arg (JSON WriteTo, Http ReadAs): arg 1 must be a plain assignable
    // Text/Code variable (mirrors BindTargetingBuiltin's ALI917 restriction — the runtime writes
    // the result back into the variable's own slot; a field/expression target has no lowerable
    // write-back). MethodName only shapes the diagnostic.
    local procedure BindTextOutArg(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; MethodName: Text): Boolean
    begin
        exit(BindTextOutArgAt(Tokens, Ast, Symbols, Diags, Node, 1, MethodName));
    end;

    // Position-aware twin: several Xml methods carry the `var Text` past arg 1 (WriteTo(Opt,
    // var Text), GetNamespaceOfPrefix/GetPrefixOfNamespace, NsMgr Lookup* — XML_DESIGN.md §7.1).
    local procedure BindTextOutArgAt(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgIdx: Integer; MethodName: Text): Boolean
    var
        TargetNode: Integer;
        TargetSid: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + ArgIdx);
        BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        TargetSid := Ast.GetSymbolId(TargetNode);
        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (TargetSid <= 0) or (not Symbols.IsVariableKind(TargetSid)) then begin
            Diags.AddError('ALI995', StrSubstNo('The argument of %1 must be an assignable text variable', MethodName), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit(false);
        end;
        if not TypeRules.IsTextFamily(Symbols.GetType(TargetSid)) then begin
            Diags.AddError('ALI995', StrSubstNo('The argument of %1 must be a Text variable', MethodName), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit(false);
        end;
        exit(true);
    end;

    // Scalar var-out arg of an arbitrary value type (Dictionary.Get(K, var V)) — same
    // restriction as BindTextOutArgAt, since the write-back lowers to a StoreToSym on the
    // variable's own symbol and a field/expression target has none. The type test is by
    // REGISTER CLASS, not TypeKind identity: a `Text[30]` variable legally receives a
    // `Dictionary of [K, Text]` value (StoreToSym applies the length check), while a target
    // whose register file differs from the value's is rejected.
    local procedure BindValueOutArgAt(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgIdx: Integer; ExpectT: Integer; MethodName: Text): Boolean
    var
        TargetNode: Integer;
        TargetSid: Integer;
    begin
        TargetNode := NEdges.Get(NFirstChild.Get(Node) + ArgIdx);
        BindExpr(Tokens, Ast, Symbols, Diags, TargetNode);
        TargetSid := Ast.GetSymbolId(TargetNode);
        if (NKind.Get(TargetNode) <> "ALI NodeKind"::NameExpr) or (TargetSid <= 0) or (not Symbols.IsVariableKind(TargetSid)) then begin
            Diags.AddError('ALI995', StrSubstNo('The value argument of %1 must be an assignable variable', MethodName), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit(false);
        end;
        if TypeRules.RegClassFor(Symbols.GetType(TargetSid)) <> TypeRules.RegClassFor(ExpectT) then begin
            Diags.AddError('ALI995', StrSubstNo('The value argument of %1 must be a %2 variable', MethodName, TypeRules.TypeName(ExpectT)), TokPos(Tokens, NMainTok.Get(TargetNode)), 0);
            exit(false);
        end;
        exit(true);
    end;

    // Method id keyed by (receiver Kind, UpperName, ArgCount). Ranges: 1-25 JsonObject,
    // 26-50 JsonArray, 51-75 JsonToken, 76-99 JsonValue (see "ALI Opcode" JSON_METHOD header).
    // Ids 1/26/51/76 ("New") are compiler-internal only and never returned here. DEVIATION
    // from the pure name+arity key used by HttpMethodId: the Add (2 / 27) and SetValue (77)
    // ids returned here are the BASE of an overload family; BindJsonMethod refines them by the
    // bound value-arg TypeOrd (JsonAddValueOffset / JsonSetValueOffset) — a value type cannot
    // be discriminated by arity alone.
    local procedure JsonMethodId(Kind: Integer; UpperName: Text; ArgCount: Integer): Integer
    var
        GetterOff: Integer;
    begin
        // Typed getters GetX(Key/Idx [, DefaultIfNotFound]) — JSON_METHOD2 id space (101+/131+).
        if Kind in ["ALI TypeKind"::JsonObject, "ALI TypeKind"::JsonArray] then
            if ArgCount in [1, 2] then begin
                GetterOff := JsonGetterOffset(UpperName);
                if GetterOff >= 0 then
                    if Kind = "ALI TypeKind"::JsonObject then
                        exit(101 + GetterOff)
                    else
                        // native JsonArray.GetByte/GetChar/GetOption have no DefaultIfNotFound overload
                        if (GetterOff < 13) or (ArgCount = 1) then
                            exit(131 + GetterOff);
            end;
        case Kind of
            "ALI TypeKind"::JsonObject:
                case UpperName of
                    'ADD':
                        if ArgCount = 2 then
                            exit(2);
                    'CONTAINS':
                        if ArgCount = 1 then
                            exit(9);
                    'GET':
                        if ArgCount = 2 then
                            exit(10);
                    'REMOVE':
                        if ArgCount = 1 then
                            exit(11);
                    'REPLACE':
                        if ArgCount = 2 then
                            exit(12);
                    'WRITETO':
                        if ArgCount = 1 then
                            exit(13);
                    'READFROM':
                        if ArgCount = 1 then
                            exit(14);
                    'KEYS':
                        if ArgCount = 0 then
                            exit(15);
                    'COUNT':
                        if ArgCount = 0 then
                            exit(16);
                    'ASTOKEN':
                        if ArgCount = 0 then
                            exit(17);
                    'CLONE':
                        if ArgCount = 0 then
                            exit(18);
                end;
            "ALI TypeKind"::JsonArray:
                case UpperName of
                    'ADD':
                        if ArgCount = 1 then
                            exit(27);
                    'GET':
                        if ArgCount = 2 then
                            exit(34);
                    'SET':
                        if ArgCount = 2 then
                            exit(35);
                    'INSERT':
                        if ArgCount = 2 then
                            exit(36);
                    'REMOVEAT':
                        if ArgCount = 1 then
                            exit(37);
                    'COUNT':
                        if ArgCount = 0 then
                            exit(38);
                    'INDEXOF':
                        if ArgCount = 1 then
                            exit(39);
                    'WRITETO':
                        if ArgCount = 1 then
                            exit(40);
                    'READFROM':
                        if ArgCount = 1 then
                            exit(41);
                    'ASTOKEN':
                        if ArgCount = 0 then
                            exit(42);
                    'CLONE':
                        if ArgCount = 0 then
                            exit(43);
                end;
            "ALI TypeKind"::JsonToken:
                case UpperName of
                    'READFROM':
                        if ArgCount = 1 then
                            exit(52);
                    'WRITETO':
                        if ArgCount = 1 then
                            exit(53);
                    'ISOBJECT':
                        if ArgCount = 0 then
                            exit(54);
                    'ISARRAY':
                        if ArgCount = 0 then
                            exit(55);
                    'ISVALUE':
                        if ArgCount = 0 then
                            exit(56);
                    'ASOBJECT':
                        if ArgCount = 0 then
                            exit(57);
                    'ASARRAY':
                        if ArgCount = 0 then
                            exit(58);
                    'ASVALUE':
                        if ArgCount = 0 then
                            exit(59);
                    'CLONE':
                        if ArgCount = 0 then
                            exit(60);
                    'SELECTTOKEN':
                        if ArgCount = 2 then
                            exit(61);
                end;
            "ALI TypeKind"::JsonValue:
                case UpperName of
                    'SETVALUE':
                        if ArgCount = 1 then
                            exit(77);
                    'ASTEXT':
                        if ArgCount = 0 then
                            exit(84);
                    'ASCODE':
                        if ArgCount = 0 then
                            exit(85);
                    'ASINTEGER':
                        if ArgCount = 0 then
                            exit(86);
                    'ASDECIMAL':
                        if ArgCount = 0 then
                            exit(87);
                    'ASBOOLEAN':
                        if ArgCount = 0 then
                            exit(88);
                    'ASDATE':
                        if ArgCount = 0 then
                            exit(89);
                    'ASTIME':
                        if ArgCount = 0 then
                            exit(90);
                    'ASDATETIME':
                        if ArgCount = 0 then
                            exit(91);
                    'ISNULL':
                        if ArgCount = 0 then
                            exit(92);
                    'ASTOKEN':
                        if ArgCount = 0 then
                            exit(93);
                    'ASBYTE':
                        if ArgCount = 0 then
                            exit(94);
                    'ASCHAR':
                        if ArgCount = 0 then
                            exit(95);
                    'ASOPTION':
                        if ArgCount = 0 then
                            exit(96);
                end;
        end;
        exit(0);
    end;

    procedure JsonMethodMark(): Integer
    begin
        exit(-10000);
    end;

    // ===== Feature 3: Xml* method binding (XML_DESIGN.md) =====
    //
    // Same Int-handle RefShim scheme as Json* (BindJsonMethod above); mark -12000 (MOST
    // negative of every mark, checked FIRST in every dispatch cascade). The 10 node kinds
    // share ONE unified NodeBank at runtime, so method ids are NOT partitioned per receiver
    // kind (§2 DEVIATION) — the binder is the sole gate on which (kind, name) pairs are
    // legal. NEW vs Json: STATIC calls with a TYPE NAME receiver (`XmlDocument.ReadFrom`,
    // `XmlElement.Create` — §4) and variadic `Any,...` content args (§6, PAIR pool encoding
    // in the lowerer). Actual ids 101+ are XML_METHOD2 (packed = actual − 100), like Json.

    // The 10 unified-NodeBank ordinals (§1); XmlNodeList/XmlAttributeCollection/
    // XmlNamespaceManager/Xml{Read,Write}Options/XmlNameTable live in their own banks.
    local procedure IsXmlNodeKind(T: Integer): Boolean
    begin
        case T of
            "ALI TypeKind"::XmlDocument, "ALI TypeKind"::XmlNode, "ALI TypeKind"::XmlElement,
            "ALI TypeKind"::XmlAttribute, "ALI TypeKind"::XmlComment, "ALI TypeKind"::XmlCData,
            "ALI TypeKind"::XmlDeclaration, "ALI TypeKind"::XmlDocumentType, "ALI TypeKind"::XmlText,
            "ALI TypeKind"::XmlProcessingInstruction:
                exit(true);
            else
                exit(false);
        end;
    end;

    // Is a receiver expression Xml*-typed? Returns the specific TypeKind (102-117) or None.
    // Two shapes (§4): (a) STATIC type-name receiver (`XmlDocument.ReadFrom(...)`) probed by
    // XmlStaticReceiverKind; (b) instance receiver whose BOUND type is an Xml kind, detected
    // via ExprTypePeek so a chained receiver (`n.AsXmlElement().InnerText()`) dispatches
    // here — mirrors JsonKindOfReceiver.
    local procedure XmlKindOfReceiver(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    var
        Kind: Integer;
    begin
        Kind := XmlStaticReceiverKind(Tokens, Ast, Symbols, RecvNode);
        if Kind <> "ALI TypeKind"::None then
            exit(Kind);
        exit(XmlKindFromTypeOrd(ExprTypePeek(Tokens, Ast, Symbols, RecvNode)));
    end;

    // Narrow an arbitrary bound TypeOrd to one of the 16 Xml kinds, or None.
    local procedure XmlKindFromTypeOrd(T: Integer): Integer
    begin
        if IsXmlNodeKind(T) then
            exit(T);
        case T of
            "ALI TypeKind"::XmlNodeList, "ALI TypeKind"::XmlAttributeCollection,
            "ALI TypeKind"::XmlNamespaceManager, "ALI TypeKind"::XmlReadOptions,
            "ALI TypeKind"::XmlWriteOptions, "ALI TypeKind"::XmlNameTable:
                exit(T);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // STATIC type-name receiver probe (§4): a NameExpr that resolves to NO user symbol (a
    // same-named variable/procedure SHADOWS the type — mirrors native) and whose identifier
    // is one of the 9 static-bearing Xml type names. Non-binding (Symbols.Lookup peek only).
    local procedure XmlStaticReceiverKind(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; RecvNode: Integer): Integer
    begin
        if NKind.Get(RecvNode) <> "ALI NodeKind"::NameExpr then
            exit("ALI TypeKind"::None);
        // The receiver must be a real IDENTIFIER token. A NameExpr synthesised by parser error
        // recovery carries MainToken 0, and a harvested object whose source did not fully parse
        // now reaches the binder (M11: a parse error no longer discards the whole object), so
        // this is a shape that genuinely arrives here.
        if Tokens.GetKind(NMainTok.Get(RecvNode)) <> 20 then      // IdentifierToken
            exit("ALI TypeKind"::None);
        if Symbols.Lookup(Ast.GetExtra(RecvNode)) <> 0 then
            exit("ALI TypeKind"::None);
        case UpperCase(Tokens.GetIdentText(NMainTok.Get(RecvNode))) of
            'XMLDOCUMENT':
                exit("ALI TypeKind"::XmlDocument);
            'XMLELEMENT':
                exit("ALI TypeKind"::XmlElement);
            'XMLATTRIBUTE':
                exit("ALI TypeKind"::XmlAttribute);
            'XMLCOMMENT':
                exit("ALI TypeKind"::XmlComment);
            'XMLCDATA':
                exit("ALI TypeKind"::XmlCData);
            'XMLDECLARATION':
                exit("ALI TypeKind"::XmlDeclaration);
            'XMLDOCUMENTTYPE':
                exit("ALI TypeKind"::XmlDocumentType);
            'XMLTEXT':
                exit("ALI TypeKind"::XmlText);
            'XMLPROCESSINGINSTRUCTION':
                exit("ALI TypeKind"::XmlProcessingInstruction);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // May a value of type T appear as an `Any,...` content arg (§6)? Text-family becomes an
    // XmlText at runtime; any node kind is inserted as-is (illegal placements — e.g. an
    // attribute where only nodes fit — error at RUNTIME via the native engine, mirrors native).
    local procedure XmlContentTypeOk(T: Integer): Boolean
    begin
        if TypeRules.IsTextFamily(T) then
            exit(true);
        exit(IsXmlNodeKind(T));
    end;

    // Bind + validate the variadic content args [FirstArg..ArgCount] of Node (§6). Each arg's
    // bound TypeOrd annotation is what the lowerer's PAIR pool encoding reads. ContentCount =
    // TOTAL content args of the call (can exceed the bound range by the already-bound arg 2
    // of XmlElement.Create(Text, Any,...)); capped at 20 so C's packed ArgCount never
    // overflows (§2).
    local procedure BindXmlContentArgs(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; FirstArg: Integer; ArgCount: Integer; ContentCount: Integer): Boolean
    var
        Ok: Boolean;
        ArgNode: Integer;
        ArgT: Integer;
        k: Integer;
    begin
        Ok := true;
        if ContentCount > 20 then begin
            Diags.AddError('ALI996', StrSubstNo('Too many Xml content arguments (max 20, got %1)', ContentCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            Ok := false;
        end;
        for k := FirstArg to ArgCount do begin
            ArgNode := NEdges.Get(NFirstChild.Get(Node) + k);
            ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
            if ArgT <> "ALI TypeKind"::ErrorType then
                if not XmlContentTypeOk(ArgT) then begin
                    Diags.AddError('ALI996', StrSubstNo('Xml content must be Text or an Xml node (got %1)', TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                    Ok := false;
                end;
        end;
        exit(Ok);
    end;

    local procedure XmlMethodNameKnown(Kind: Integer; MethodName: Text; IsStatic: Boolean): Boolean
    var
        A: Integer;
    begin
        for A := 0 to 12 do
            if IsStatic then begin
                if XmlStaticMethodId(Kind, MethodName, A) <> 0 then
                    exit(true);
            end else
                if XmlMethodId(Kind, MethodName, A) <> 0 then
                    exit(true);
        exit(false);
    end;

    // `recv.Method(args)` / `XmlType.Static(args)`. Full §3 id table; overloads discriminated
    // by ArgCount first (XmlMethodId / XmlStaticMethodId), then by bound arg TypeOrd where an
    // arity is shared (WriteTo 31/33 + 32/34, ReadFrom 62/64 + 63/65, XmlElement.Create
    // 102/103/104, RemoveAttribute 109/111, AttrCol Get 128/129 and Remove 131/132 — the
    // tables return the family's BASE id, refined below; the Json Add base-id convention).
    local procedure BindXmlMethod(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; CalleeNode: Integer; IsStatement: Boolean): Integer
    var
        IsStatic: Boolean;
        ArgCount: Integer;
        ArgT: Integer;
        Kind: Integer;
        MethodId: Integer;
        RecvNode: Integer;
        ResultT: Integer;
        MethodName: Text;
    begin
        RecvNode := NEdges.Get(NFirstChild.Get(CalleeNode) + 0);
        Kind := XmlStaticReceiverKind(Tokens, Ast, Symbols, RecvNode);
        IsStatic := Kind <> "ALI TypeKind"::None;
        if IsStatic then
            // §4 static path: the receiver is a TYPE NAME, not an expression — never BindExpr
            // it. TypeOrd annotation only (SymbolId stays 0); the lowerer skips the receiver
            // for static ids and emits A = 0.
            Ast.SetTypeOrd(RecvNode, Kind)
        else begin
            // Bind the receiver ONCE (any expression, including a chained call result), then
            // read its bound TypeOrd — never re-peek (mirrors BindJsonMethod).
            BindExpr(Tokens, Ast, Symbols, Diags, RecvNode);
            Kind := XmlKindFromTypeOrd(Ast.GetTypeOrd(RecvNode));
        end;
        // Paren-less method: Node is the MemberAccessExpr, ExtraInt = member NameId (read 0).
        if NKind.Get(Node) = "ALI NodeKind"::InvocationExpr then
            ArgCount := Ast.GetExtra(Node)
        else
            ArgCount := 0;
        MethodName := UpperCase(Tokens.GetIdentText(NMainTok.Get(CalleeNode)));
        if IsStatic then
            MethodId := XmlStaticMethodId(Kind, MethodName, ArgCount)
        else
            MethodId := XmlMethodId(Kind, MethodName, ArgCount);
        if MethodId = 0 then begin
            AddMethodDiag(Tokens, Ast, Diags, CalleeNode, TypeRules.TypeName(Kind), XmlMethodNameKnown(Kind, MethodName, IsStatic), ArgCount);
            BindArgsSilently(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        ResultT := "ALI TypeKind"::None;
        case MethodId of
            // ----- variadic Any,... content methods (§6): AddAfterSelf 20 / AddBeforeSelf 21 /
            // ReplaceWith 26 / Add 40 / AddFirst 41 / ReplaceNodes 51 -> void -----
            20, 21, 26, 40, 41, 51:
                if not BindXmlContentArgs(Tokens, Ast, Symbols, Diags, Node, 1, ArgCount, ArgCount) then
                    exit("ALI TypeKind"::ErrorType);
            22:     // AsXmlNode() -> XmlNode (fresh handle)
                ResultT := "ALI TypeKind"::XmlNode;
            23:     // GetDocument(var XmlDocument) -> Bool (§7.2 handle var-out: exact kind)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlDocument, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            24:     // GetParent(var XmlElement) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlElement, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            25, 50, 108, 134, 178:
                // Remove / RemoveNodes / RemoveAllAttributes / AttrCol.RemoveAll / PushScope
                // -> void, 0 args
                ;
            27, 29:     // SelectNodes(Text, var XmlNodeList) 27 / SelectSingleNode(Text, var XmlNode) 29 -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if MethodId = 27 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlNodeList, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)))
                    else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlNode, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            28, 30:     // ns-manager overloads: SelectNodes 28 / SelectSingleNode 30 -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlNamespaceManager, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    if MethodId = 28 then
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::XmlNodeList, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)))
                    else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::XmlNode, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            31:     // WriteTo(var Text) 31 / WriteTo(OutStream) 33 — by arg 1's type (peeked;
                    // the winning path then binds exactly once against the real Diags)
                begin
                    if ExprTypePeek(Tokens, Ast, Symbols, ArgOrMissing(Ast, Node, 1)) = "ALI TypeKind"::OutStream then begin
                        MethodId := 33;
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    end else
                        if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, 'WriteTo') then
                            exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            32:     // WriteTo(XmlWriteOptions, var Text) 32 / WriteTo(XmlWriteOptions, OutStream) 34
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlWriteOptions, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if ExprTypePeek(Tokens, Ast, Symbols, ArgOrMissing(Ast, Node, 2)) = "ALI TypeKind"::OutStream then begin
                        MethodId := 34;
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2));
                    end else
                        if not BindTextOutArgAt(Tokens, Ast, Symbols, Diags, Node, 2, 'WriteTo') then
                            exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            35, 90, 91, 92, 93, 94, 120, 150, 152, 154, 168:
                // Value / LocalName / Name / NamespaceUri / InnerText / InnerXml /
                // NamespacePrefix / Encoding / Standalone / Version / Target getters -> Text
                ResultT := "ALI TypeKind"::Text;
            36, 151, 153, 155, 162, 163, 164, 165:
                // Value / Encoding / Standalone / Version setters + DocType Set* -> void, 1 Text arg
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            42, 45, 46, 49:     // GetChildElements/GetChildNodes/GetDescendantElements/GetDescendantNodes() -> XmlNodeList
                ResultT := "ALI TypeKind"::XmlNodeList;
            43, 47:     // GetChildElements(Text) / GetDescendantElements(Text) -> XmlNodeList
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::XmlNodeList;
                end;
            44, 48:     // GetChildElements(Text, Text) / GetDescendantElements(Text, Text) -> XmlNodeList
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::XmlNodeList;
                end;
            55:     // GetDeclaration(var XmlDeclaration) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlDeclaration, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            56:     // GetDocumentType(var XmlDocumentType) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlDocumentType, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            57:     // GetRoot(var XmlElement) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlElement, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            58, 175:    // NameTable() -> XmlNameTable (fresh handle)
                ResultT := "ALI TypeKind"::XmlNameTable;
            59:     // SetDeclaration(XmlDeclaration) -> void
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlDeclaration, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            60:     // XmlDocument.Create() STATIC -> XmlDocument
                ResultT := "ALI TypeKind"::XmlDocument;
            61:     // XmlDocument.Create(Any,...) STATIC -> XmlDocument
                begin
                    if not BindXmlContentArgs(Tokens, Ast, Symbols, Diags, Node, 1, ArgCount, ArgCount) then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::XmlDocument;
                end;
            62:     // ReadFrom(Text, var XmlDocument) 62 / ReadFrom(InStream, var XmlDocument) 64 STATIC -> Bool
                begin
                    if ExprTypePeek(Tokens, Ast, Symbols, ArgOrMissing(Ast, Node, 1)) = "ALI TypeKind"::InStream then begin
                        MethodId := 64;
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    end else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlDocument, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            63:     // ReadFrom(Text, XmlReadOptions, var XmlDocument) 63 / ReadFrom(InStream, ...) 65 STATIC -> Bool
                begin
                    if ExprTypePeek(Tokens, Ast, Symbols, ArgOrMissing(Ast, Node, 1)) = "ALI TypeKind"::InStream then begin
                        MethodId := 65;
                        BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    end else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlReadOptions, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::XmlDocument, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            // ----- XmlNode As* (fresh handle; native error on kind mismatch) -----
            68:
                ResultT := "ALI TypeKind"::XmlAttribute;
            69:
                ResultT := "ALI TypeKind"::XmlCData;
            70:
                ResultT := "ALI TypeKind"::XmlComment;
            71:
                ResultT := "ALI TypeKind"::XmlDeclaration;
            72:
                ResultT := "ALI TypeKind"::XmlDocument;
            73:
                ResultT := "ALI TypeKind"::XmlDocumentType;
            74:
                ResultT := "ALI TypeKind"::XmlElement;
            75:
                ResultT := "ALI TypeKind"::XmlProcessingInstruction;
            76:
                ResultT := "ALI TypeKind"::XmlText;
            77 .. 85, 95, 96, 97, 119, 177, 182, 184:
                // Is* (77-85) / HasAttributes / HasElements / IsEmpty / IsNamespaceDeclaration /
                // PopScope / PreserveWhitespace getters -> Bool, 0 args
                ResultT := "ALI TypeKind"::Boolean;
            98:     // Attributes() -> XmlAttributeCollection (fresh handle)
                ResultT := "ALI TypeKind"::XmlAttributeCollection;
            // ----- XML_METHOD2 ids (actual 101+; SymbolId carries the ACTUAL id — the
            // lowerer rebases to packed id − 100) -----
            101:    // XmlElement.Create(Text) STATIC -> XmlElement
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::XmlElement;
                end;
            102:    // XmlElement.Create ≥2 args STATIC: ns form 102/103 when arg 2 is
                    // Text-family, else content form 104 (mirrors native overload resolution)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2));
                    if TypeRules.IsTextFamily(ArgT) then begin
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, ArgT);
                        if ArgCount = 2 then
                            MethodId := 102
                        else begin
                            MethodId := 103;
                            if not BindXmlContentArgs(Tokens, Ast, Symbols, Diags, Node, 3, ArgCount, ArgCount - 2) then
                                exit("ALI TypeKind"::ErrorType);
                        end;
                    end else begin
                        MethodId := 104;
                        // arg 2 is the FIRST content arg — already bound above; validate only.
                        if (ArgT <> "ALI TypeKind"::ErrorType) and (not XmlContentTypeOk(ArgT)) then begin
                            Diags.AddError('ALI996', StrSubstNo('Xml content must be Text or an Xml node (got %1)', TypeRules.TypeName(ArgT)), TokPos(Tokens, Ast.GetMainToken(ArgOrMissing(Ast, Node, 2))), 0);
                            exit("ALI TypeKind"::ErrorType);
                        end;
                        if not BindXmlContentArgs(Tokens, Ast, Symbols, Diags, Node, 3, ArgCount, ArgCount - 1) then
                            exit("ALI TypeKind"::ErrorType);
                    end;
                    ResultT := "ALI TypeKind"::XmlElement;
                end;
            106, 107:   // GetNamespaceOfPrefix / GetPrefixOfNamespace (Text, var Text) -> Bool (§7.1, pos 2)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if not BindTextOutArgAt(Tokens, Ast, Symbols, Diags, Node, 2, MethodName) then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            109:    // RemoveAttribute(Text) 109 / RemoveAttribute(XmlAttribute) 111 -> void
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if ArgT = "ALI TypeKind"::XmlAttribute then
                        MethodId := 111
                    else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, ArgT);
                end;
            110, 112, 133, 135, 171, 179:
                // RemoveAttribute(Text, Text) / SetAttribute(Text, Text) / AttrCol.Remove(Text,
                // Text) / AttrCol.Set(Text, Text) / AddNamespace / RemoveNamespace(-> Bool)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    if MethodId = 179 then
                        ResultT := "ALI TypeKind"::Boolean;
                end;
            113, 136:   // SetAttribute(Text, Text, Text) / AttrCol.Set(Text, Text, Text) -> void
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                end;
            116, 118:   // XmlAttribute.Create(Text, Text) / CreateNamespaceDeclaration(Text, Text) STATIC -> XmlAttribute
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::XmlAttribute;
                end;
            117:    // XmlAttribute.Create(Text, Text, Text) STATIC -> XmlAttribute
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::XmlAttribute;
                end;
            123, 127:   // Count() -> Integer (NodeList / AttrCol)
                ResultT := "ALI TypeKind"::Integer;
            124:    // XmlNodeList.Get(Integer, var XmlNode) -> Bool (NATIVE 1-BASED)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlNode, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            128:    // AttrCol.Get(Integer, var XmlAttribute) 128 / Get(Text, var XmlAttribute) 129 -> Bool
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if TypeRules.IsTextFamily(ArgT) then begin
                        MethodId := 129;
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, ArgT);
                    end else
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Integer, ArgT);
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::XmlAttribute, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            130:    // AttrCol.Get(Text, Text, var XmlAttribute) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::XmlAttribute, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            131:    // AttrCol.Remove(XmlAttribute) 131 / Remove(Text) 132 -> void
                begin
                    ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1));
                    if ArgT <> "ALI TypeKind"::XmlAttribute then begin
                        MethodId := 132;
                        CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, ArgT);
                    end;
                end;
            140, 141, 142, 145:     // XmlComment/XmlCData/XmlText/XmlDocumentType .Create(Text) STATIC
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    case MethodId of
                        140:
                            ResultT := "ALI TypeKind"::XmlComment;
                        141:
                            ResultT := "ALI TypeKind"::XmlCData;
                        142:
                            ResultT := "ALI TypeKind"::XmlText;
                        145:
                            ResultT := "ALI TypeKind"::XmlDocumentType;
                    end;
                end;
            143:    // XmlProcessingInstruction.Create(Text, Text) STATIC — (target, data)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::XmlProcessingInstruction;
                end;
            144, 147:   // XmlDeclaration.Create(Text×3) 144 / XmlDocumentType.Create(Text×3) 147 STATIC
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    if MethodId = 144 then
                        ResultT := "ALI TypeKind"::XmlDeclaration
                    else
                        ResultT := "ALI TypeKind"::XmlDocumentType;
                end;
            146:    // XmlDocumentType.Create(Text, Text) STATIC
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    ResultT := "ALI TypeKind"::XmlDocumentType;
                end;
            148:    // XmlDocumentType.Create(Text×4) STATIC — (name, publicId, systemId, internalSubset)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 2), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 2)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 3), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 3)));
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 4), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 4)));
                    ResultT := "ALI TypeKind"::XmlDocumentType;
                end;
            158 .. 161:     // DocType GetInternalSubset/GetName/GetPublicId/GetSystemId(var Text) -> Bool (§7.1)
                begin
                    if not BindTextOutArg(Tokens, Ast, Symbols, Diags, Node, MethodName) then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            172:    // HasNamespace(Text) -> Bool
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            173, 174:   // LookupNamespace / LookupPrefix (Text, var Text) -> Bool (§7.1, pos 2)
                begin
                    CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Text, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
                    if not BindTextOutArgAt(Tokens, Ast, Symbols, Diags, Node, 2, MethodName) then
                        exit("ALI TypeKind"::ErrorType);
                    ResultT := "ALI TypeKind"::Boolean;
                end;
            176:    // NameTable(XmlNameTable) setter -> void
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::XmlNameTable, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
            183, 185:   // PreserveWhitespace(Boolean) setters -> void
                CheckAssignable(Tokens, Ast, Diags, ArgOrMissing(Ast, Node, 1), "ALI TypeKind"::Boolean, BindExpr(Tokens, Ast, Symbols, Diags, ArgOrMissing(Ast, Node, 1)));
        end;

        Ast.SetSymbolId(Node, XmlMethodMark() - MethodId);
        if (ResultT = "ALI TypeKind"::None) and (not IsStatement) then begin
            Diags.AddError('ALI929', StrSubstNo('The %1 method ''%2'' does not return a value', TypeRules.TypeName(Kind), MethodName), TokPos(Tokens, NMainTok.Get(Node)), 0);
            exit("ALI TypeKind"::ErrorType);
        end;
        exit(ResultT);
    end;

    // INSTANCE method id keyed by (receiver Kind, UpperName, ArgCount) — §3. Ids are shared
    // across node kinds (unified NodeBank, §2 DEVIATION); this table is the sole receiver-kind
    // gate. Ids 31/62/63/102/109/128/131 are BASES of arity-sharing overload families,
    // refined by bound arg TypeOrd in BindXmlMethod. New ids 1-16 are compiler-internal only
    // (emitted by the lowerer at declaration) and never returned here.
    local procedure XmlMethodId(Kind: Integer; UpperName: Text; ArgCount: Integer): Integer
    begin
        // Shared node methods (ids 20-36) — any node kind; per-kind gates inline.
        if IsXmlNodeKind(Kind) then begin
            case UpperName of
                'ADDAFTERSELF':
                    if ArgCount >= 1 then
                        exit(20);
                'ADDBEFORESELF':
                    if ArgCount >= 1 then
                        exit(21);
                'ASXMLNODE':
                    // every node kind EXCEPT XmlNode itself (mirrors native)
                    if (ArgCount = 0) and (Kind <> "ALI TypeKind"::XmlNode) then
                        exit(22);
                'GETDOCUMENT':
                    if ArgCount = 1 then
                        exit(23);
                'GETPARENT':
                    if ArgCount = 1 then
                        exit(24);
                'REMOVE':
                    if ArgCount = 0 then
                        exit(25);
                'REPLACEWITH':
                    if ArgCount >= 1 then
                        exit(26);
                'SELECTNODES':
                    case ArgCount of
                        2:
                            exit(27);
                        3:
                            exit(28);
                    end;
                'SELECTSINGLENODE':
                    case ArgCount of
                        2:
                            exit(29);
                        3:
                            exit(30);
                    end;
                'WRITETO':
                    case ArgCount of
                        1:      // base: var Text 31 / OutStream 33
                            exit(31);
                        2:      // base: (Opt, var Text) 32 / (Opt, OutStream) 34
                            exit(32);
                    end;
                'VALUE':
                    if Kind in ["ALI TypeKind"::XmlAttribute, "ALI TypeKind"::XmlComment, "ALI TypeKind"::XmlCData, "ALI TypeKind"::XmlText, "ALI TypeKind"::XmlProcessingInstruction] then
                        case ArgCount of
                            0:
                                exit(35);
                            1:
                                exit(36);
                        end;
            end;
            // Container methods (ids 40-51) — XmlDocument / XmlElement only.
            if Kind in ["ALI TypeKind"::XmlDocument, "ALI TypeKind"::XmlElement] then
                case UpperName of
                    'ADD':
                        if ArgCount >= 1 then
                            exit(40);
                    'ADDFIRST':
                        if ArgCount >= 1 then
                            exit(41);
                    'GETCHILDELEMENTS':
                        case ArgCount of
                            0:
                                exit(42);
                            1:
                                exit(43);
                            2:
                                exit(44);
                        end;
                    'GETCHILDNODES':
                        if ArgCount = 0 then
                            exit(45);
                    'GETDESCENDANTELEMENTS':
                        case ArgCount of
                            0:
                                exit(46);
                            1:
                                exit(47);
                            2:
                                exit(48);
                        end;
                    'GETDESCENDANTNODES':
                        if ArgCount = 0 then
                            exit(49);
                    'REMOVENODES':
                        if ArgCount = 0 then
                            exit(50);
                    'REPLACENODES':
                        if ArgCount >= 1 then
                            exit(51);
                end;
            // LocalName/Name/NamespaceUri (90-92) — XmlElement AND XmlAttribute (runtime
            // dispatches on the actual node kind).
            if Kind in ["ALI TypeKind"::XmlElement, "ALI TypeKind"::XmlAttribute] then
                case UpperName of
                    'LOCALNAME':
                        if ArgCount = 0 then
                            exit(90);
                    'NAME':
                        if ArgCount = 0 then
                            exit(91);
                    'NAMESPACEURI':
                        if ArgCount = 0 then
                            exit(92);
                end;
        end;
        case Kind of
            "ALI TypeKind"::XmlDocument:
                case UpperName of
                    'GETDECLARATION':
                        if ArgCount = 1 then
                            exit(55);
                    'GETDOCUMENTTYPE':
                        if ArgCount = 1 then
                            exit(56);
                    'GETROOT':
                        if ArgCount = 1 then
                            exit(57);
                    'NAMETABLE':
                        if ArgCount = 0 then
                            exit(58);
                    'SETDECLARATION':
                        if ArgCount = 1 then
                            exit(59);
                end;
            "ALI TypeKind"::XmlNode:
                if ArgCount = 0 then
                    case UpperName of
                        'ASXMLATTRIBUTE':
                            exit(68);
                        'ASXMLCDATA':
                            exit(69);
                        'ASXMLCOMMENT':
                            exit(70);
                        'ASXMLDECLARATION':
                            exit(71);
                        'ASXMLDOCUMENT':
                            exit(72);
                        'ASXMLDOCUMENTTYPE':
                            exit(73);
                        'ASXMLELEMENT':
                            exit(74);
                        'ASXMLPROCESSINGINSTRUCTION':
                            exit(75);
                        'ASXMLTEXT':
                            exit(76);
                        'ISXMLATTRIBUTE':
                            exit(77);
                        'ISXMLCDATA':
                            exit(78);
                        'ISXMLCOMMENT':
                            exit(79);
                        'ISXMLDECLARATION':
                            exit(80);
                        'ISXMLDOCUMENT':
                            exit(81);
                        'ISXMLDOCUMENTTYPE':
                            exit(82);
                        'ISXMLELEMENT':
                            exit(83);
                        'ISXMLPROCESSINGINSTRUCTION':
                            exit(84);
                        'ISXMLTEXT':
                            exit(85);
                    end;
            "ALI TypeKind"::XmlElement:
                case UpperName of
                    'INNERTEXT':
                        if ArgCount = 0 then
                            exit(93);
                    'INNERXML':
                        if ArgCount = 0 then
                            exit(94);
                    'HASATTRIBUTES':
                        if ArgCount = 0 then
                            exit(95);
                    'HASELEMENTS':
                        if ArgCount = 0 then
                            exit(96);
                    'ISEMPTY':
                        if ArgCount = 0 then
                            exit(97);
                    'ATTRIBUTES':
                        if ArgCount = 0 then
                            exit(98);
                    'GETNAMESPACEOFPREFIX':
                        if ArgCount = 2 then
                            exit(106);
                    'GETPREFIXOFNAMESPACE':
                        if ArgCount = 2 then
                            exit(107);
                    'REMOVEALLATTRIBUTES':
                        if ArgCount = 0 then
                            exit(108);
                    'REMOVEATTRIBUTE':
                        case ArgCount of
                            1:      // base: Text 109 / XmlAttribute 111
                                exit(109);
                            2:
                                exit(110);
                        end;
                    'SETATTRIBUTE':
                        case ArgCount of
                            2:
                                exit(112);
                            3:
                                exit(113);
                        end;
                end;
            "ALI TypeKind"::XmlAttribute:
                case UpperName of
                    'ISNAMESPACEDECLARATION':
                        if ArgCount = 0 then
                            exit(119);
                    'NAMESPACEPREFIX':
                        if ArgCount = 0 then
                            exit(120);
                end;
            "ALI TypeKind"::XmlNodeList:
                case UpperName of
                    'COUNT':
                        if ArgCount = 0 then
                            exit(123);
                    'GET':
                        if ArgCount = 2 then
                            exit(124);
                end;
            "ALI TypeKind"::XmlAttributeCollection:
                case UpperName of
                    'COUNT':
                        if ArgCount = 0 then
                            exit(127);
                    'GET':
                        case ArgCount of
                            2:      // base: Integer 128 / Text 129
                                exit(128);
                            3:
                                exit(130);
                        end;
                    'REMOVE':
                        case ArgCount of
                            1:      // base: XmlAttribute 131 / Text 132
                                exit(131);
                            2:
                                exit(133);
                        end;
                    'REMOVEALL':
                        if ArgCount = 0 then
                            exit(134);
                    'SET':
                        case ArgCount of
                            2:
                                exit(135);
                            3:
                                exit(136);
                        end;
                end;
            "ALI TypeKind"::XmlDeclaration:
                case UpperName of
                    'ENCODING':
                        case ArgCount of
                            0:
                                exit(150);
                            1:
                                exit(151);
                        end;
                    'STANDALONE':
                        case ArgCount of
                            0:
                                exit(152);
                            1:
                                exit(153);
                        end;
                    'VERSION':
                        case ArgCount of
                            0:
                                exit(154);
                            1:
                                exit(155);
                        end;
                end;
            "ALI TypeKind"::XmlDocumentType:
                case UpperName of
                    'GETINTERNALSUBSET':
                        if ArgCount = 1 then
                            exit(158);
                    'GETNAME':
                        if ArgCount = 1 then
                            exit(159);
                    'GETPUBLICID':
                        if ArgCount = 1 then
                            exit(160);
                    'GETSYSTEMID':
                        if ArgCount = 1 then
                            exit(161);
                    'SETINTERNALSUBSET':
                        if ArgCount = 1 then
                            exit(162);
                    'SETNAME':
                        if ArgCount = 1 then
                            exit(163);
                    'SETPUBLICID':
                        if ArgCount = 1 then
                            exit(164);
                    'SETSYSTEMID':
                        if ArgCount = 1 then
                            exit(165);
                end;
            "ALI TypeKind"::XmlProcessingInstruction:
                case UpperName of
                    'TARGET':
                        if ArgCount = 0 then
                            exit(168);
                end;
            "ALI TypeKind"::XmlNamespaceManager:
                case UpperName of
                    'ADDNAMESPACE':
                        if ArgCount = 2 then
                            exit(171);
                    'HASNAMESPACE':
                        if ArgCount = 1 then
                            exit(172);
                    'LOOKUPNAMESPACE':
                        if ArgCount = 2 then
                            exit(173);
                    'LOOKUPPREFIX':
                        if ArgCount = 2 then
                            exit(174);
                    'NAMETABLE':
                        case ArgCount of
                            0:
                                exit(175);
                            1:
                                exit(176);
                        end;
                    'POPSCOPE':
                        if ArgCount = 0 then
                            exit(177);
                    'PUSHSCOPE':
                        if ArgCount = 0 then
                            exit(178);
                    'REMOVENAMESPACE':
                        if ArgCount = 2 then
                            exit(179);
                end;
            "ALI TypeKind"::XmlReadOptions:
                case UpperName of
                    'PRESERVEWHITESPACE':
                        case ArgCount of
                            0:
                                exit(182);
                            1:
                                exit(183);
                        end;
                end;
            "ALI TypeKind"::XmlWriteOptions:
                case UpperName of
                    'PRESERVEWHITESPACE':
                        case ArgCount of
                            0:
                                exit(184);
                            1:
                                exit(185);
                        end;
                end;
        end;
        exit(0);
    end;

    // STATIC method id keyed by (type Kind, UpperName, ArgCount) — §3/§4 (the 9 static-
    // bearing type names; A = 0 at runtime). Ids 62/63/102 are BASES refined by bound arg
    // TypeOrd in BindXmlMethod.
    local procedure XmlStaticMethodId(Kind: Integer; UpperName: Text; ArgCount: Integer): Integer
    begin
        case Kind of
            "ALI TypeKind"::XmlDocument:
                case UpperName of
                    'CREATE':
                        if ArgCount = 0 then
                            exit(60)
                        else
                            exit(61);       // variadic content (§6)
                    'READFROM':
                        case ArgCount of
                            2:      // base: Text 62 / InStream 64
                                exit(62);
                            3:      // base: Text 63 / InStream 65
                                exit(63);
                        end;
                end;
            "ALI TypeKind"::XmlElement:
                case UpperName of
                    'CREATE':
                        if ArgCount = 1 then
                            exit(101)
                        else
                            if ArgCount >= 2 then
                                exit(102);      // base: ns 102 / ns+content 103 / content 104
                end;
            "ALI TypeKind"::XmlAttribute:
                case UpperName of
                    'CREATE':
                        case ArgCount of
                            2:
                                exit(116);
                            3:
                                exit(117);
                        end;
                    'CREATENAMESPACEDECLARATION':
                        if ArgCount = 2 then
                            exit(118);
                end;
            "ALI TypeKind"::XmlComment:
                if (UpperName = 'CREATE') and (ArgCount = 1) then
                    exit(140);
            "ALI TypeKind"::XmlCData:
                if (UpperName = 'CREATE') and (ArgCount = 1) then
                    exit(141);
            "ALI TypeKind"::XmlText:
                if (UpperName = 'CREATE') and (ArgCount = 1) then
                    exit(142);
            "ALI TypeKind"::XmlProcessingInstruction:
                if (UpperName = 'CREATE') and (ArgCount = 2) then
                    exit(143);
            "ALI TypeKind"::XmlDeclaration:
                if (UpperName = 'CREATE') and (ArgCount = 3) then
                    exit(144);
            "ALI TypeKind"::XmlDocumentType:
                if UpperName = 'CREATE' then
                    case ArgCount of
                        1:
                            exit(145);
                        2:
                            exit(146);
                        3:
                            exit(147);
                        4:
                            exit(148);
                    end;
        end;
        exit(0);
    end;

    // Marker base for Xml*-method invocations (Feature 3, XML_DESIGN.md §5). MORE negative
    // than BlobMethodMark(-11000) so it wins the lowerer's descending `Sym <= X` cascades.
    procedure XmlMethodMark(): Integer
    begin
        exit(-12000);
    end;

    // Overload resolution: pick the proc SymbolId under NameId whose signature matches the
    // call's argument list. Single overload (the common case) short-circuits to FirstSid.
    // Otherwise: filter on arity; a single survivor wins outright (its arg-type errors then
    // surface normally in BindUserProcCall). Several same-arity survivors need the ARG TYPES,
    // so the args are bound HERE (once — ArgsBound tells BindUserProcCall to reuse the node
    // annotations instead of re-binding, which would duplicate diagnostics): an exact
    // type-match on every param beats an implicit-convertible match; first-declared wins a
    // convertible tie (identical signatures are already AL0198 at declaration).
    local procedure ResolveOverload(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; NameId: Integer; FirstSid: Integer; ArgCount: Integer; var ArgsBound: Boolean): Integer
    var
        ArgT: Integer;
        Best: Integer;
        BestSid: Integer;
        CandPId: Integer;
        CandSid: Integer;
        k: Integer;
        PT: Integer;
        Row: Integer;
        Score: Integer;
        ArityMatch: List of [Integer];
        Overloads: List of [Integer];
    begin
        ArgsBound := false;
        Overloads := Symbols.ProcOverloads(UnitScope(Symbols), NameId);
        if Overloads.Count() <= 1 then
            exit(FirstSid);

        foreach CandSid in Overloads do
            if Symbols.ProcParamCount(Symbols.GetProcId(CandSid)) = ArgCount then
                ArityMatch.Add(CandSid);
        if ArityMatch.Count() = 0 then
            exit(FirstSid);         // no arity fits — ALI916 against the first overload
        if ArityMatch.Count() = 1 then
            exit(ArityMatch.Get(1));

        // Several overloads take this many args: bind the args once, then score.
        for k := 1 to ArgCount do
            BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + k));
        ArgsBound := true;

        Best := 0;
        BestSid := 0;
        foreach CandSid in ArityMatch do begin
            CandPId := Symbols.GetProcId(CandSid);
            Score := 2;             // 2 = exact on every param, 1 = convertible, 0 = no fit
            for k := 1 to ArgCount do begin
                Row := Symbols.ProcParamRow(CandPId, k);
                PT := Symbols.ParamRowType(Row);
                ArgT := Ast.GetTypeOrd(NEdges.Get(NFirstChild.Get(Node) + k));
                if ArgT <> PT then begin
                    if Score = 2 then
                        Score := 1;
                    // var params allow no implicit conversion — exact type or no fit
                    // (Text <-> Code excepted, mirrors BindUserProcCall).
                    if Symbols.ParamRowIsVar(Row) then begin
                        if not (TypeRules.IsTextOrCode(PT) and TypeRules.IsTextOrCode(ArgT)) then
                            Score := 0;
                    end else
                        if not TypeRules.AssignmentCompatible(PT, ArgT) then
                            Score := 0;
                end;
            end;
            if Score > Best then begin
                Best := Score;
                BestSid := CandSid;
            end;
        end;
        if BestSid = 0 then
            exit(ArityMatch.Get(1));    // nothing fits — conversion errors against the first
        exit(BestSid);
    end;

    // Object-procedure overloads (Temp Blob's CreateInStream/CreateOutStream with and without the
    // TextEncoding argument, ...) share one name in the object's scope, and LookupProcByName
    // answers with the first declaration. Pick the one whose VISIBLE arity — declared params
    // minus the hidden receiver/instance rows — matches the call; on no match keep the first, so
    // the arity error still reports against it.
    local procedure PickArityOverload(var Symbols: Codeunit "ALI Symbol Table"; ProcSid: Integer; ArgCount: Integer): Integer
    var
        CandSid: Integer;
        PId: Integer;
    begin
        PId := Symbols.GetProcId(ProcSid);
        if Symbols.ProcParamCount(PId) - Symbols.GetProcHiddenCount(PId) = ArgCount then
            exit(ProcSid);
        foreach CandSid in Symbols.ProcOverloads(Symbols.GetScope(ProcSid), Symbols.GetNameId(ProcSid)) do begin
            PId := Symbols.GetProcId(CandSid);
            if Symbols.ProcParamCount(PId) - Symbols.GetProcHiddenCount(PId) = ArgCount then
                exit(CandSid);
        end;
        exit(ProcSid);
    end;

    // User procedure call (M5). Arity, per-arg typing, var-param enforcement (§7.2:
    // assignable lvalue of the EXACT type — no implicit conversion, mirror native).
    // ArgsBound = true when ResolveOverload already bound the args (reuse node annotations —
    // re-binding would duplicate any diagnostics they carry).
    local procedure BindUserProcCall(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ProcSym: Integer; NameText: Text; IsStatement: Boolean; ArgCount: Integer; ArgsBound: Boolean; RowShift: Integer): Integer
    var
        ArgOk: Boolean;
        ArgLen: Integer;
        ArgNode: Integer;
        ArgSid: Integer;
        ArgT: Integer;
        Expected: Integer;
        k: Integer;
        PArg: Integer;
        PId: Integer;
        PT: Integer;
        RetT: Integer;
        Row: Integer;
    begin
        PId := Symbols.GetProcId(ProcSym);
        // ArgCount is a parameter now: BindInvocation passes GetExtra(Node) (parenthesized call);
        // paren-less callers (BindName, BindExpressionStatement) pass 0.
        // RowShift (M11) is the count of HIDDEN leading parameters the caller supplies rather
        // than the source: 1 for `Rec.ObjProc(a)`, whose descriptor row 1 is the implicit
        // receiver, so written argument k is row k+1. 0 for every ordinary call.
        Expected := Symbols.ProcParamCount(PId) - RowShift;
        if ArgCount <> Expected then begin
            Diags.AddError('ALI916', StrSubstNo('The procedure ''%1'' expects %2 argument(s), but %3 were provided', NameText, Expected, ArgCount), TokPos(Tokens, NMainTok.Get(Node)), 0);
            if not ArgsBound then
                BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
            exit("ALI TypeKind"::ErrorType);
        end;

        for k := 1 to ArgCount do begin
            ArgNode := NEdges.Get(NFirstChild.Get(Node) + k);
            Row := Symbols.ProcParamRow(PId, k + RowShift);
            PT := Symbols.ParamRowType(Row);
            PArg := Symbols.ParamRowTypeArg(Row);
            if ArgsBound then
                ArgT := Ast.GetTypeOrd(ArgNode)
            else
                ArgT := BindExpr(Tokens, Ast, Symbols, Diags, ArgNode);
            if (ArgT <> "ALI TypeKind"::ErrorType) and (PT <> "ALI TypeKind"::ErrorType) then
                if Symbols.ParamRowIsVar(Row) then begin
                    // var param: assignable lvalue of the EXACT type — except Text/Code, which
                    // accept each other at any length (native; a shorter param only warns). The
                    // lowerer re-stores the caller's variable after the call, so its own
                    // length check / Code uppercasing still apply (LowerCall phase 3).
                    ArgOk := true;
                    ArgSid := Ast.GetSymbolId(ArgNode);
                    if (NKind.Get(ArgNode) <> "ALI NodeKind"::NameExpr) or (ArgSid <= 0) or (not Symbols.IsVariableKind(ArgSid)) then begin
                        Diags.AddError('ALI917', StrSubstNo('The argument for var parameter %1 of ''%2'' must be an assignable variable', k, NameText), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                        ArgOk := false;
                    end;
                    // Nested if, not one 'and' chain: AL evaluates both operands, and
                    // GetTypeArg(ArgSid) is only valid when ArgOk guaranteed ArgSid > 0.
                    if ArgOk then
                        if TypeRules.IsTextOrCode(PT) and TypeRules.IsTextOrCode(ArgT) then begin
                            ArgLen := Symbols.GetTypeArg(ArgSid);
                            if (PArg > 0) and ((ArgLen = 0) or (ArgLen > PArg)) then
                                Diags.AddWarning('ALI917', StrSubstNo('Possible overflow: argument for var parameter %1 of ''%2'' is longer than %3[%4]', k, NameText, TypeRules.TypeName(PT), PArg), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                        end else
                            if (ArgT <> PT) or
                               (((PT = "ALI TypeKind"::List) or (PT = "ALI TypeKind"::Dictionary) or (PT = "ALI TypeKind"::Record) or (PT = "ALI TypeKind"::NativeCodeunit)) and (Symbols.GetTypeArg(ArgSid) <> PArg)) then
                                Diags.AddError('ALI917', StrSubstNo('The argument for var parameter %1 of ''%2'' must be of the exact type %3 (got %4) — var parameters allow no implicit conversion', k, NameText, TypeRules.TypeName(PT), TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                end else
                    if PT = "ALI TypeKind"::Record then begin
                        // by-value Record param: the argument must be a record VARIABLE of the
                        // same table (no record-valued rvalue exists in this subset); the callee
                        // prologue copies it into a fresh handle (value semantics, §7.5).
                        ArgSid := Ast.GetSymbolId(ArgNode);
                        if (ArgT <> "ALI TypeKind"::Record) or (NKind.Get(ArgNode) <> "ALI NodeKind"::NameExpr) or (ArgSid <= 0) then
                            Diags.AddError('ALI932', StrSubstNo('The argument for record parameter %1 of ''%2'' must be a record variable (got %3)', k, NameText, TypeRules.TypeName(ArgT)), TokPos(Tokens, NMainTok.Get(ArgNode)), 0)
                        else
                            if Symbols.GetTypeArg(ArgSid) <> PArg then
                                Diags.AddError('ALI932', StrSubstNo('The argument for record parameter %1 of ''%2'' must be a record of the same table', k, NameText), TokPos(Tokens, NMainTok.Get(ArgNode)), 0);
                    end else
                        // by-value param: normal assignment-conversion rules; ConvOrd annotated.
                        CheckAssignable(Tokens, Ast, Diags, ArgNode, PT, ArgT);
        end;

        Ast.SetSymbolId(Node, ProcSym);  // lowerer contract: CALL
        RetT := Symbols.GetType(ProcSym);
        Ast.SetTypeArg(Node, Symbols.GetTypeArg(ProcSym)); // §D2: Option/Enum set id on a proc-call result
        if RetT = "ALI TypeKind"::None then begin
            // [TryFunction] consumed as a value: the call yields the try outcome (lowerer: TRY_CALL,
            // the callee's error is caught). As a statement it stays void, and the error propagates.
            if (not IsStatement) and Symbols.IsTryProc(PId) then
                exit("ALI TypeKind"::Boolean);
            if not IsStatement then begin
                Diags.AddError('ALI929', StrSubstNo('The procedure ''%1'' does not return a value', NameText), TokPos(Tokens, NMainTok.Get(Node)), 0);
                exit("ALI TypeKind"::ErrorType);
            end;
            exit("ALI TypeKind"::None);
        end;
        exit(RetT);                          // statement context discards the value (native)
    end;

    local procedure BindArgs(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgCount: Integer)
    var
        i: Integer;
    begin
        for i := 1 to ArgCount do
            BindExpr(Tokens, Ast, Symbols, Diags, NEdges.Get(NFirstChild.Get(Node) + i));
    end;

    // Error recovery for a call whose CALLEE could not be resolved: the args are still bound (every
    // node keeps its annotations) but what they report is dropped. Without a callee there is no
    // signature, so `Rec.SetOrder("Vendor No.")` would otherwise add "'Vendor No.' does not exist"
    // to the real error — noise that sends a reader (or an LLM) fixing the wrong thing.
    local procedure BindArgsSilently(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Node: Integer; ArgCount: Integer)
    var
        Snapshot: Integer;
    begin
        Snapshot := Diags.Count();
        BindArgs(Tokens, Ast, Symbols, Diags, Node, ArgCount);
        Diags.TruncateTo(Snapshot);
    end;

    // ===== "Did you mean" suffixes for unknown-name diagnostics (error path only) =====

    local procedure SuggestFrom(Name: Text; Candidates: List of [Text]): Text
    var
        Matcher: Codeunit "ALI Diag Bag";
    begin
        exit(Matcher.DidYouMean(Name, Candidates));
    end;

    local procedure SuggestField(TableId: Integer; Name: Text): Text
    begin
        if TableId = 0 then
            exit('');
        exit(SuggestFrom(Name, SuggestCatalog.FieldNames(TableId)));
    end;

    local procedure SuggestMethod(TypeNameTxt: Text; Name: Text): Text
    begin
        exit(SuggestFrom(Name, SuggestCatalog.MethodNames(TypeNameTxt)));
    end;

    // ===== ALI1004 FlowField never calculated (warning) =====
    //
    // Static and order-insensitive on purpose: any CalcFields/SetAutoCalcFields/CalcSums naming the
    // field ANYWHERE in the same body (on any record of that table) silences it. Script bodies only
    // (CurObjKey = 0) — harvested table/codeunit code is not the reader's to fix.
    // ponytail: a record calculated by the CALLER and passed in still warns; track per record
    // handle at run time if that false positive ever matters.

    local procedure ClearFlowFieldUse()
    begin
        Clear(FlowFieldReadPos);
        Clear(FlowFieldReadName);
        Clear(FlowFieldCalced);
    end;

    local procedure NoteFlowFieldRead(var Tokens: Codeunit "ALI Token Table"; Node: Integer; TableId: Integer; FNo: Integer; FClass: Integer)
    var
        FieldKey: Text;
    begin
        if (CurObjKey <> 0) or (FClass <> 1) then     // "ALI Rec Meta" FieldClass: 1 = FlowField
            exit;
        FieldKey := StrSubstNo('%1:%2', TableId, FNo);
        if FlowFieldReadPos.ContainsKey(FieldKey) then
            exit;
        FlowFieldReadPos.Add(FieldKey, TokPos(Tokens, NMainTok.Get(Node)));
        FlowFieldReadName.Add(FieldKey, Tokens.GetIdentText(NMainTok.Get(Node)));
    end;

    local procedure NoteFlowFieldCalc(TableId: Integer; FNo: Integer; MethodName: Text)
    begin
        case UpperCase(MethodName) of
            'CALCFIELDS', 'SETAUTOCALCFIELDS', 'CALCSUMS':
                FlowFieldCalced.Set(StrSubstNo('%1:%2', TableId, FNo), true);
        end;
    end;

    local procedure ReportUncalcedFlowFields(var Diags: Codeunit "ALI Diag Bag")
    var
        FieldKey: Text;
        FieldName: Text;
    begin
        foreach FieldKey in FlowFieldReadPos.Keys() do
            if not FlowFieldCalced.ContainsKey(FieldKey) then begin
                FieldName := FlowFieldReadName.Get(FieldKey);
                Diags.AddWarning('ALI1004', StrSubstNo('FlowField ''%1'' is read but never calculated in this procedure: its value will be 0/empty', FieldName), FlowFieldReadPos.Get(FieldKey), 0);
            end;
        ClearFlowFieldUse();
    end;

    // ===== Shared checks =====
    local procedure RequireBool(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; CondNode: Integer)
    var
        T: Integer;
    begin
        T := BindExpr(Tokens, Ast, Symbols, Diags, CondNode);
        if (T <> "ALI TypeKind"::Boolean) and (T <> "ALI TypeKind"::ErrorType) then
            Diags.AddError('ALI931', StrSubstNo('The condition must be a Boolean expression (got %1)', TypeRules.TypeName(T)), TokPos(Tokens, NMainTok.Get(CondNode)), 0);
    end;

    // target := source compatibility; annotates the source node's ConvOrd on success.
    local procedure CheckAssignable(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; SourceNode: Integer; TargetT: Integer; SourceT: Integer)
    begin
        if (TargetT = "ALI TypeKind"::ErrorType) or (SourceT = "ALI TypeKind"::ErrorType) then
            exit;
        // M11 phase C1: a codeunit variable is a compile-time NAME for an object, not a value —
        // it has no register class, so a MOV would silently move nothing. AssignmentCompatible
        // says yes (the types are identical), which is exactly why the guard belongs here.
        if (TargetT = "ALI TypeKind"::CodeunitRef) or (TargetT = "ALI TypeKind"::NativeCodeunit) then begin
            Diags.AddError('ALI927', 'A codeunit variable cannot be assigned — it only names the object whose procedures you call', TokPos(Tokens, NMainTok.Get(SourceNode)), 0);
            exit;
        end;
        if not TypeRules.AssignmentCompatible(TargetT, SourceT) then begin
            Diags.AddError('ALI932', StrSubstNo('Cannot implicitly convert %1 to %2', TypeRules.TypeName(SourceT), TypeRules.TypeName(TargetT)), TokPos(Tokens, NMainTok.Get(SourceNode)), 0);
            exit;
        end;
        Ast.SetConvOrd(SourceNode, TypeRules.ConvKind(SourceT, TargetT));
    end;

    // ===== Slot allocation (§7.2) =====

    // The register class a GlobalVar occupies, or 0 for a symbol with no runtime storage.
    // §20.2/20.9(4): an array VALUE is a single Int handle (element data lives in "ALI Array
    // Runtime"), so it reserves exactly 1 Int slot regardless of element class or length.
    local procedure GlobalRegClass(var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer): Integer
    begin
        if Symbols.GetType(Sid) = "ALI TypeKind"::Array then
            exit("ALI Register Class"::Int);
        exit(TypeRules.RegClassFor(Symbols.GetType(Sid)));
    end;

    // M11 phase B2: does the object this unit belongs to declare a global with real storage?
    // Only then do its procedures need the hidden instance index. False for a script.
    local procedure UnitDeclaresStorableGlobals(var Symbols: Codeunit "ALI Symbol Table"): Boolean
    var
        Sid: Integer;
    begin
        if CurObjKey = 0 then
            exit(false);
        foreach Sid in Symbols.GlobalSids() do
            if Symbols.GetOwnerObjKey(Sid) = CurObjKey then
                if Symbols.GetKind(Sid) = Symbols.KindGlobalVar() then
                    if GlobalRegClass(Symbols, Sid) > 0 then
                        exit(true);
        exit(false);
    end;

    // Module-level vars: ABSOLUTE slots 1..G per register class. They live below every
    // frame window; the entry frame's base per class = the global count.
    //
    // M11 phase B2 splits the bank in two. The SCRIPT's own globals keep absolute slots, packed
    // from 1 as before. A HARVESTED OBJECT's globals are numbered per object as OFFSETS inside a
    // block, and the bank then carries one copy of that block per INSTANCE — per declared
    // variable of the object's type — stacked above the script's globals:
    //
    //   [ script globals ][ instance 1's block ][ instance 2's block ] ...
    //
    // so `a.Bump()` and `b.Bump()` on two variables of the same table write different storage,
    // which is what native AL does. An object global's absolute slot is its instance's base plus
    // its offset; SELF_LOAD/SELF_STORE do that addition at runtime against the frame's instance.
    //
    // Re-run on every unit's bind over the SHARED symbol table, and idempotent: sids are visited
    // in declaration order, so every slot, offset and base keeps the value an earlier run gave
    // it and later harvests only ever append.
    local procedure AllocateGlobalSlots(var Symbols: Codeunit "ALI Symbol Table")
    var
        BlockSize: Dictionary of [BigInteger, Integer];    // ObjKey*16 + class -> globals in that block
        ClassCounter: array[13] of Integer;
        Cls: Integer;
        Inst: Integer;
        N: Integer;
        ObjKey: Integer;
        Running: array[13] of Integer;
        Sid: Integer;
    begin
        // Symbols.GlobalSids() instead of a full-table scan: the table is SHARED across every
        // harvested object, and this runs once per object bind.
        foreach Sid in Symbols.GlobalSids() do
            if Symbols.GetKind(Sid) = Symbols.KindGlobalVar() then begin
                Cls := GlobalRegClass(Symbols, Sid);
                if Cls > 0 then begin
                    ObjKey := Symbols.GetOwnerObjKey(Sid);
                    if ObjKey = 0 then begin
                        ClassCounter[Cls] += 1;
                        Symbols.SetSlot(Sid, ClassCounter[Cls]);         // absolute
                    end else begin
                        N := 0;
                        if BlockSize.ContainsKey(ObjKey * 16L + Cls) then
                            N := BlockSize.Get(ObjKey * 16L + Cls);
                        N += 1;
                        BlockSize.Set(ObjKey * 16L + Cls, N);
                        Symbols.SetSlot(Sid, N);                         // offset within the block
                    end;
                end;
            end;

        for Cls := 1 to TypeRules.RegClassCount() do
            Running[Cls] := ClassCounter[Cls];

        // One block per instance, in instance order. An instance whose object declares nothing
        // in a class simply consumes no space there.
        for Inst := 1 to Symbols.InstanceCount() do begin
            ObjKey := Symbols.InstanceOwner(Inst);
            for Cls := 1 to TypeRules.RegClassCount() do begin
                Symbols.SetInstBase(Inst, Cls, Running[Cls]);
                if BlockSize.ContainsKey(ObjKey * 16L + Cls) then
                    Running[Cls] += BlockSize.Get(ObjKey * 16L + Cls);
            end;
        end;

        for Cls := 1 to TypeRules.RegClassCount() do
            Symbols.SetGlobalCount(Cls, Running[Cls]);
    end;

    // Copy the finished instance layout into the Module, which is what the interpreter is
    // loaded from. Rebuilt wholesale rather than patched: a compile can run twice over the same
    // Module (diagnostics pass, then the real one) and a half-updated table would be worse than
    // none.
    local procedure PublishInstanceLayout(var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module")
    var
        Cls: Integer;
        Inst: Integer;
        Bases: List of [Integer];
    begin
        Module.ClearInstBases();
        for Inst := 1 to Symbols.InstanceCount() do begin
            Clear(Bases);
            for Cls := 1 to 13 do
                Bases.Add(Symbols.GetInstBase(Inst, Cls));
            Module.AddInstBases(Bases);
        end;
    end;

    // Unpack array TArg (elemType * ArrayStride + N).
    local procedure ArrayElemType(TArg: Integer): Integer
    begin
        exit(TArg div ArrayStride());
    end;

    // Handle Lifecycle Unification (Phase 3): Record/InStream/OutStream/TextBuilder/Dialog no
    // longer get a separate compilation-wide handle-space allocation pass — RegClassFor routes
    // them to RegClassInt, so AllocateGlobalSlots/AllocateProcSlots already give every symbol
    // of these types an ordinary windowed Int slot (global or per-proc-local), exactly like
    // List/Dictionary/Array/Http*. The four Allocate*Handles passes formerly here (and their
    // *HandleCount() getters, and the Module Set/GetXHandleCount plumbing that fed the
    // interpreter's now-removed Rt.Allocate(N) calls) are gone.

    // Per-proc frame-relative slots: params first (declaration order), then the result
    // slot, then locals (declaration order), then hidden for-loop limit slots (§7.2).
    // Expression temporaries are allocated ABOVE these by the Lowerer.
    local procedure AllocateProcSlots(var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; PId: Integer)
    var
        ClassCounter: array[13] of Integer;
        Cls: Integer;
        ForNode: Integer;
        ParamOrdinal: Integer;
        Row: Integer;
        Sid: Integer;
        SKind: Integer;
    begin
        // 1. params (symbol order = declaration order = descriptor row order)
        // Symbols.ProcSymbols(PId) instead of a full-table scan — same set, same order, but this
        // runs once per PROCEDURE over a table shared by every harvested object (see the index's
        // note in "ALI Symbol Table").
        ParamOrdinal := 0;
        foreach Sid in Symbols.ProcSymbols(PId) do begin
            SKind := Symbols.GetKind(Sid);
            if (SKind = Symbols.KindParam()) or (SKind = Symbols.KindVarParam()) then begin
                ParamOrdinal += 1;
                Cls := TypeRules.RegClassFor(Symbols.GetType(Sid));
                if Cls > 0 then begin
                    ClassCounter[Cls] += 1;
                    Symbols.SetSlot(Sid, ClassCounter[Cls]);
                    Row := Symbols.ProcParamRow(PId, ParamOrdinal);
                    if Row > 0 then
                        Symbols.SetParamRowSlot(Row, ClassCounter[Cls]);
                end;
            end;
        end;

        // 2. result slot
        ResultSlot := 0;
        if (ResTypeOrd <> "ALI TypeKind"::None) and (ResTypeOrd <> "ALI TypeKind"::ErrorType) then begin
            Cls := TypeRules.RegClassFor(ResTypeOrd);
            if Cls > 0 then begin
                ClassCounter[Cls] += 1;
                ResultSlot := ClassCounter[Cls];
            end;
        end;
        Symbols.SetProcResultSlot(PId, ResultSlot);
        // Named return value: its symbol ALIASES the result slot (no own local slot) —
        // stores through the name land directly in the return value.
        if ResultVarSid > 0 then
            Symbols.SetSlot(ResultVarSid, ResultSlot);

        // 3. locals (§20.2/20.9(4): an array is a single Int handle slot, like List/Dict)
        foreach Sid in Symbols.ProcSymbols(PId) do
            if (Symbols.GetKind(Sid) = Symbols.KindLocalVar()) and (Sid <> ResultVarSid) then
                if Symbols.GetType(Sid) = "ALI TypeKind"::Array then begin
                    Cls := "ALI Register Class"::Int;
                    ClassCounter[Cls] += 1;
                    Symbols.SetSlot(Sid, ClassCounter[Cls]);
                end else begin
                    Cls := TypeRules.RegClassFor(Symbols.GetType(Sid));
                    if Cls > 0 then begin
                        ClassCounter[Cls] += 1;
                        Symbols.SetSlot(Sid, ClassCounter[Cls]);
                    end;
                end;

        // 4. hidden for-loop limit slots (Integer class)
        foreach ForNode in ForNodes do begin
            ClassCounter["ALI Register Class"::Int] += 1;
            Ast.SetSlotIndex(ForNode, ClassCounter["ALI Register Class"::Int]);
        end;

        // 4b. hidden foreach slots: 3 consecutive Int slots per node (index / limit / handle);
        // SlotIndex = base (the index slot).
        foreach ForNode in ForEachNodes do begin
            ClassCounter["ALI Register Class"::Int] += 1;
            Ast.SetSlotIndex(ForNode, ClassCounter["ALI Register Class"::Int]);
            ClassCounter["ALI Register Class"::Int] += 2;
        end;

        // binder -> lowerer: the proc's var-region size per class (temps go above)
        for Cls := 1 to TypeRules.RegClassCount() do
            Symbols.SetProcVarCount(PId, Cls, ClassCounter[Cls]);
    end;

    // ===== Helpers =====
    local procedure TokPos(var Tokens: Codeunit "ALI Token Table"; TokenIdx: Integer): Integer
    begin
        if (TokenIdx <= 0) or (TokenIdx > Tokens.Count()) then
            exit(0);
        exit(Tokens.GetStartPos(TokenIdx));
    end;
}
