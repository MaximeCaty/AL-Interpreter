// ALI Builtin Registry — builtin signatures only (M3 deliverable §16.3 / §6.2 / §12).
//
// Data assembled ONCE (lazy, on first Resolve/EnsureBuilt). No handlers this milestone —
// only name->id, arity range, param types, result type, and a Pure flag (§12 wants Pure
// from day one for the short-circuit optimizer). Overload resolution is by arity then
// operand types; v1 builtins are mostly non-overloaded, so a name maps to one row and the
// binder checks arity + convertibility against the row.
//
// Struct-of-arrays (parallel, 1-based BuiltinId):
//   NameId      interned identifier pool index (set once the Token Table has interned the
//               name — we intern lazily via an internal Dictionary keyed on UPPERCASE name,
//               because builtin names are known as text here, not as token ids)
//   NameText    original spelling (diagnostics)
//   MinArity/MaxArity   inclusive argument-count range (MaxArity = 99 => variadic)
//   ResultType  "ALI TypeKind" ordinal of the return value (None = procedure/void)
//   Domain      dispatch domain ord (Str/Math/DateTime/System/Record) — for M7 handlers
//   Flags       bit0 = Pure, bit1 = Unimplemented (recognized-but-not-implemented tier §19.8)
//
// Param types are stored in a separate parallel store keyed by BuiltinId (ParamOf*). For
// v1 we keep param typing coarse: many builtins accept "any" (TypeKind None used as a
// wildcard in the param slot) because full overload precision isn't needed until handlers
// land (M7). The binder treats a None param type as "accept any convertible".
//
// Names are matched case-insensitively via the uppercase intern map — mirroring AL
// identifier semantics (§4.1). The binder passes the call's NameId; the registry maps that
// NameId back through the Token Table spelling only when needed. To stay decoupled from a
// specific Token Table instance, ResolveByName(UpperName) is the primary entry and the
// binder upper-cases the callee spelling before calling.
codeunit 51039 "ALI Builtin Registry"
{
    Access = Public;
    // Signature table is immutable once built and shared by binder, lowerer, interpreter and
    // the API catalog — SingleInstance so Populate() runs ONCE per session (EnsureBuilt is
    // idempotent) instead of rebuilding ~200 rows on every Compile. Nothing ever mutates it
    // after build; no code calls Reset() on this codeunit.
    SingleInstance = true;

    var

        Built: Boolean;

        // --- Name -> BuiltinId (uppercase) ---
        NameMap: Dictionary of [Text, Integer];
        BDomain: List of [Enum "ALI Builtin Domain"];
        // Interpreter dispatch kind, resolved ONCE at build time (see ClassifyKinds). The
        // interpreter used to recover this per call by upper-casing the name and running a
        // 20-term string-comparison chain (IsVariantTestName) plus a 'SPLIT' compare, on EVERY
        // builtin call including plain Abs()/StrLen(). Now it is one List.Get of an Integer.
        BKind: List of [Enum "ALI Builtin Kind"];
        BFlags: List of [Integer];
        // Why an Unimplemented row is unimplemented, when there is something better to say than
        // "not implemented". A Dictionary rather than a column: only a handful of rows carry one,
        // and it is read once, by a diagnostic — no parallel-array contract to keep.
        BUnimplWhy: Dictionary of [Integer, Text];
        BMaxArity: List of [Integer];
        BMinArity: List of [Integer];
        BResultType: List of [Integer];
        PCountByBId: List of [Integer];
        // Per-builtin param span into PParamType (1-based first index + count), keyed by
        // BuiltinId — turns ParamType() from an O(total-params) scan into O(1).
        PFirstByBId: List of [Integer];

        // --- Param types (parallel, keyed by BuiltinId) ---
        PParamBId: List of [Integer];
        PParamType: List of [Integer];
        BNameText: List of [Text];
        // --- Builtin columns (1-based BuiltinId) ---
        BNameUpper: List of [Text];

        // --- Native codeunit catalogue (see PopulateNative). Parallel columns, 0 on every
        // non-native row. A native row is reached ONLY through NativeFirst (keyed by codeunit id +
        // method), never through NameMap, so a bare `ToBase64(x)` stays an unknown name. ---
        BVarMask: List of [Integer];            // bit (i-1) set = parameter i is `var`
        BNextOverload: List of [Integer];       // next row of the same (codeunit, method), 0 = end
        NativeFirst: Dictionary of [Text, Integer];
        StatefulNative: List of [Integer];      // codeunit ids whose variables are NativeCodeunit handles

    // ===== Flag bits / arity sentinel =====
    // Domains, dispatch kinds and TypeKind ordinals are enums now ("ALI Builtin Domain",
    // "ALI Builtin Kind", "ALI TypeKind") — the ordinal is a compile-time constant, so no
    // accessor call and no second copy of the numbering to drift.
    procedure FlagPure(): Integer
    begin
        exit(1);
    end;

    procedure FlagUnimplemented(): Integer
    begin
        exit(2);
    end;

    procedure Variadic(): Integer
    begin
        exit(99);
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        Clear(BNameUpper);
        Clear(BNameText);
        Clear(BMinArity);
        Clear(BMaxArity);
        Clear(BResultType);
        Clear(BDomain);
        Clear(BFlags);
        Clear(BKind);
        Clear(PParamBId);
        Clear(PParamType);
        Clear(PFirstByBId);
        Clear(PCountByBId);
        Clear(NameMap);
        Clear(BVarMask);
        Clear(BNextOverload);
        Clear(NativeFirst);
        Clear(StatefulNative);
        Built := false;
    end;

    // Ensure the signature table is populated (idempotent; safe to call before every bind).
    procedure EnsureBuilt()
    begin
        if Built then
            exit;
        Populate();
        Built := true;
    end;

    // ===== Resolution =====

    // Resolve a builtin by its UPPERCASE name. Returns BuiltinId or 0 if not a builtin.
    procedure ResolveByName(UpperName: Text): Integer
    var
        Id: Integer;
    begin
        EnsureBuilt();
        if NameMap.Get(UpperName, Id) then
            exit(Id);
        exit(0);
    end;

    // Is the arity within this builtin's declared range?
    procedure ArityOk(BId: Integer; ArgCount: Integer): Boolean
    begin
        exit((ArgCount >= BMinArity.Get(BId)) and (ArgCount <= BMaxArity.Get(BId)));
    end;

    // ===== Getters =====

    procedure Count(): Integer
    begin
        exit(BNameUpper.Count());
    end;

    procedure GetName(BId: Integer): Text
    begin
        exit(BNameText.Get(BId));
    end;

    // The UPPERCASE spelling, already computed at build time. The interpreter must use this
    // rather than UpperCase(GetName(BId)) — that allocated a fresh string on every builtin call.
    procedure GetNameUpper(BId: Integer): Text
    begin
        exit(BNameUpper.Get(BId));
    end;

    // Interpreter dispatch kind (Ordinary / Split / VariantTest).
    procedure GetKind(BId: Integer): Enum "ALI Builtin Kind"
    begin
        exit(BKind.Get(BId));
    end;

    procedure GetMinArity(BId: Integer): Integer
    begin
        exit(BMinArity.Get(BId));
    end;

    procedure GetMaxArity(BId: Integer): Integer
    begin
        exit(BMaxArity.Get(BId));
    end;

    procedure GetResultType(BId: Integer): Integer
    begin
        exit(BResultType.Get(BId));
    end;

    procedure GetDomain(BId: Integer): Enum "ALI Builtin Domain"
    begin
        exit(BDomain.Get(BId));
    end;

    procedure IsPure(BId: Integer): Boolean
    begin
        exit((BFlags.Get(BId) div FlagPure()) mod 2 = 1);
    end;

    procedure IsUnimplemented(BId: Integer): Boolean
    begin
        exit((BFlags.Get(BId) div FlagUnimplemented()) mod 2 = 1);
    end;

    /// <summary>
    /// Why this builtin is unimplemented ('the platform method it calls is only available in an
    /// on-premises installation'), or '' when the plain "not implemented" answer is the whole
    /// story. Only meaningful for a row IsUnimplemented() reports true for.
    /// </summary>
    procedure UnimplementedReason(BId: Integer) Why: Text
    begin
        if BUnimplWhy.Get(BId, Why) then
            exit(Why);
        exit('');
    end;

    // The declared type of parameter Idx (1-based) for a builtin, or TypeKind::None (wildcard/any)
    // if the builtin declares no explicit type for that position.
    procedure ParamType(BId: Integer; Idx: Integer): Integer
    begin
        if (Idx < 1) or (Idx > PCountByBId.Get(BId)) then
            exit("ALI TypeKind"::None.AsInteger());
        exit(PParamType.Get(PFirstByBId.Get(BId) + Idx - 1));
    end;

    // ===== Native codeunit catalogue =====

    // First catalogued overload of CodeunitId.UpperMethod, or 0 when the method is not on the
    // catalogue (the call then goes through the harvester exactly as before).
    procedure ResolveNative(CodeunitId: Integer; UpperMethod: Text): Integer
    var
        BId: Integer;
    begin
        EnsureBuilt();
        if NativeFirst.Get(NativeKey(CodeunitId, UpperMethod), BId) then
            exit(BId);
        exit(0);
    end;

    // Pseudo codeunit ids of the STATIC receivers `File.` / `Page.` / `Report.`. Their members
    // are platform methods, not procedures of a codeunit, but they bind and run exactly like the
    // stateless catalogue (a receiver with no value, one row per overload), so they live in the
    // same NativeFirst map under an id no real codeunit can have.
    procedure FileNativeId(): Integer
    begin
        exit(-1);
    end;

    procedure PageNativeId(): Integer
    begin
        exit(-2);
    end;

    procedure ReportNativeId(): Integer
    begin
        exit(-3);
    end;

    procedure IsNativeMethod(CodeunitId: Integer; UpperMethod: Text): Boolean
    begin
        exit(ResolveNative(CodeunitId, UpperMethod) <> 0);
    end;

    // Every catalogued method of one native codeunit, as first-overload BuiltinIds — the
    // enumeration counterpart of ResolveNative, for the editor's completion list. Reading the
    // NativeFirst keys is what keeps the dropdown and the binder in step: both see the same map,
    // so a method the list offers is exactly a method a call resolves to. Later overloads hang
    // off NextOverload(), as everywhere else.
    procedure NativeMethodsOf(CodeunitId: Integer) BIds: List of [Integer]
    var
        BId: Integer;
        NKey: Text;
        Prefix: Text;
    begin
        EnsureBuilt();
        Prefix := Format(CodeunitId) + '.';
        foreach NKey in NativeFirst.Keys() do
            // The '.' is part of Prefix and a method name can never contain one, so codeunit 4
            // can never answer for 42 — the match is exact by construction.
            if NKey.StartsWith(Prefix) then begin
                NativeFirst.Get(NKey, BId);
                BIds.Add(BId);
            end;
    end;

    procedure NextOverload(BId: Integer): Integer
    begin
        exit(BNextOverload.Get(BId));
    end;

    procedure GetVarMask(BId: Integer): Integer
    begin
        exit(BVarMask.Get(BId));
    end;

    procedure IsVarParam(BId: Integer; Idx: Integer): Boolean
    var
        Bit: Integer;
        k: Integer;
    begin
        Bit := 1;
        for k := 2 to Idx do
            Bit := Bit * 2;
        exit((BVarMask.Get(BId) div Bit) mod 2 = 1);
    end;

    // A codeunit whose variables carry a live platform instance (TypeKind NativeCodeunit).
    procedure IsStatefulNative(CodeunitId: Integer): Boolean
    begin
        EnsureBuilt();
        exit(StatefulNative.Contains(CodeunitId));
    end;

    local procedure NativeKey(CodeunitId: Integer; UpperMethod: Text): Text
    begin
        exit(Format(CodeunitId) + '.' + UpperMethod);
    end;

    // ===== Population =====

    // Add a builtin row. Params is a caller-built list of param TypeKind ordinals (may be
    // empty; TypeKind::None entries mean "any"). Returns the new BuiltinId.
    local procedure Add(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; Params: List of [Enum "ALI TypeKind"]): Integer
    var
        BId: Integer;
        F: Integer;
    begin
        F := 0;
        if Pure then
            F += FlagPure();
        BId := AddRow(UpperCase(Name), Name, MinA, MaxA, ResType, Domain, F, 0, Params);
        NameMap.Set(UpperCase(Name), BId);
        exit(BId);
    end;

    // One row in every column. UpperKey is the interpreter's dispatch key (the builtin's name,
    // or a per-overload key for a native row); NameText is the spelling diagnostics show.
    local procedure AddRow(UpperKey: Text; NameText: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Flags: Integer; VarMask: Integer; Params: List of [Enum "ALI TypeKind"]): Integer
    var
        PType: Enum "ALI TypeKind";
        BId: Integer;
    begin
        BNameUpper.Add(UpperKey);
        BNameText.Add(NameText);
        BMinArity.Add(MinA);
        BMaxArity.Add(MaxA);
        BResultType.Add(ResType.AsInteger());
        BDomain.Add(Domain);
        BFlags.Add(Flags);
        BVarMask.Add(VarMask);
        BNextOverload.Add(0);
        BId := BNameUpper.Count();
        // Record this builtin's param span (params are appended contiguously below) so
        // ParamType(BId, Idx) is a direct index, not a scan.
        PFirstByBId.Add(PParamType.Count() + 1);
        PCountByBId.Add(Params.Count());
        foreach PType in Params do begin
            PParamBId.Add(BId);
            PParamType.Add(PType.AsInteger());
        end;
        exit(BId);
    end;

    // Convenience overloads with fixed param lists (AL has no varargs at call site).
    local procedure Add0(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add1(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add2(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"; P2: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        P.Add(P2);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add3(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"; P2: Enum "ALI TypeKind"; P3: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        P.Add(P2);
        P.Add(P3);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add4(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"; P2: Enum "ALI TypeKind"; P3: Enum "ALI TypeKind"; P4: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        P.Add(P2);
        P.Add(P3);
        P.Add(P4);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add5(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"; P2: Enum "ALI TypeKind"; P3: Enum "ALI TypeKind"; P4: Enum "ALI TypeKind"; P5: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        P.Add(P2);
        P.Add(P3);
        P.Add(P4);
        P.Add(P5);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    local procedure Add6(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Pure: Boolean; P1: Enum "ALI TypeKind"; P2: Enum "ALI TypeKind"; P3: Enum "ALI TypeKind"; P4: Enum "ALI TypeKind"; P5: Enum "ALI TypeKind"; P6: Enum "ALI TypeKind"): Integer
    var
        P: List of [Enum "ALI TypeKind"];
    begin
        P.Add(P1);
        P.Add(P2);
        P.Add(P3);
        P.Add(P4);
        P.Add(P5);
        P.Add(P6);
        exit(Add(Name, MinA, MaxA, ResType, Domain, Pure, P));
    end;

    // The v1 builtin signature catalog (§1.1). Purity: string/math/date-formatting fns are
    // pure; Message/Error/Confirm/Random/Today/CurrentDateTime and record ops are NOT.
    local procedure Populate()
    begin
        PopulateString();
        PopulateMath();
        PopulateDateTime();
        PopulateSystem();
        PopulateTextMethods();
        PopulateVariantMethods();
        PopulateArray();
        PopulateUnimplemented();
        // LAST, always: every row above keeps the BuiltinId it had before the native catalogue
        // existed, so bytecode stored by SaveCompiled (CALL_BUILTIN_LIVE carries the raw BId)
        // stays valid. New native rows go at the END of PopulateNative for the same reason.
        PopulateNative();
        ClassifyKinds();
    end;

    // Resolve each builtin's interpreter dispatch kind once, by name. Deliberately a post-pass
    // over BNameUpper rather than a flag threaded through the Add* helpers: it reuses the exact
    // same name predicate ExecCallBuiltinLive used to evaluate per call, so behaviour is
    // identical by construction. Runs once per session (Populate is EnsureBuilt-guarded).
    local procedure ClassifyKinds()
    var
        i: Integer;
        U: Text;
    begin
        Clear(BKind);
        for i := 1 to BNameUpper.Count() do begin
            U := BNameUpper.Get(i);
            case true of
                U = 'SPLIT':
                    BKind.Add("ALI Builtin Kind"::Split);
                (U = 'ISINTEGER') or (U = 'ISBIGINTEGER') or (U = 'ISDECIMAL') or
                (U = 'ISBOOLEAN') or (U = 'ISTEXT') or (U = 'ISCODE') or
                (U = 'ISCHAR') or (U = 'ISBYTE') or (U = 'ISDATE') or
                (U = 'ISTIME') or (U = 'ISDATETIME') or (U = 'ISDURATION') or
                (U = 'ISGUID') or (U = 'ISOPTION') or (U = 'ISDATEFORMULA') or
                (U = 'ISRECORDID') or (U = 'ISRECORD') or (U = 'ISLIST') or
                (U = 'ISDICTIONARY') or (U = 'ISARRAY'):
                    BKind.Add("ALI Builtin Kind"::VariantTest);
                else
                    BKind.Add("ALI Builtin Kind"::Ordinary);
            end;
        end;
    end;

    // --- §19.2 Variant type-detection methods. Registered arity 1 (the receiver counts as
    // param 1, mirroring the Text-method rows); the method form is therefore arity 0. Domain 0
    // (other) — the interpreter special-cases these by name in ExecCallBuiltinLive (like Split),
    // calling the native AL Variant .IsInteger/.IsText/... predicates. Pure (no side effects). ---
    local procedure PopulateVariantMethods()
    begin
        Add1('IsInteger', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsBigInteger', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDecimal', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsBoolean', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsText', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsCode', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsChar', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsByte', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDate', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsTime', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDateTime', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDuration', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsGuid', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsOption', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDateFormula', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsRecordId', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsRecord', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsList', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsDictionary', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
        Add1('IsArray', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None, true, "ALI TypeKind"::None);
    end;

    // --- Array intrinsics (§19.x). Take array-VARIABLE operands, not values — a native AL
    // array cannot be boxed into a Variant, so these bypass the generic Variant-boundary
    // builtin path and are bound/lowered specially (like Evaluate/Clear). Param-type lists are
    // therefore left empty: the binder validates the array operands itself (BindArrayBuiltin).
    // ArrayLen is pure (compile-time constant fold); CopyArray/CompressArray mutate. ---
    local procedure PopulateArray()
    begin
        Add0('ArrayLen', 1, 2, "ALI TypeKind"::Integer, "ALI Builtin Domain"::None, true);          // Length := ArrayLen(Array [,Dimension]);
        Add0('CompressArray', 1, 1, "ALI TypeKind"::Integer, "ALI Builtin Domain"::None, false);    // Count := CompressArray(StringArray);
        Add0('CopyArray', 3, 4, "ALI TypeKind"::None, "ALI Builtin Domain"::None, false);       // CopyArray(NewArray, Array, Position [, Length]);
    end;

    // --- §19.4 Text member-accessor spellings. Same BuiltinId space; a method call binds
    // to these rows by name (binder routes `s.Trim()` -> ResolveByName('TRIM') etc. after
    // confirming the receiver is Text-family). Aliases (ToLower/ToUpper/Substring) point at
    // dedicated rows here rather than reusing LowerCase/UpperCase/CopyStr's row so the
    // registry can tell a free-function call from a method call if ever needed; the builtin
    // HANDLER for the pair is shared (§19.4: "one implementation") by having the interpreter's inlined
    // Str arm (CALL_BUILTIN_LIVE) route both names to the same case branch.
    local procedure PopulateTextMethods()
    begin
        Add1('Trim', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add2('TrimStart', 1, 2, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);  // (s[, chars])
        Add2('TrimEnd', 1, 2, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);    // (s[, chars])
        Add3('Replace', 3, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add2('Contains', 2, 2, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add3('IndexOf', 2, 3, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);       // (s, value[, startIndex])
        Add3('LastIndexOf', 2, 3, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);   // (s, value[, startIndex])
        Add3('IndexOfAny', 2, 3, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);    // (s, values[, startIndex])
        Add2('StartsWith', 2, 2, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add2('EndsWith', 2, 2, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add1('ToLower', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add1('ToUpper', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add3('Substring', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);
        Add2('PadLeft', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);               // (s, count[, char])
        Add2('PadRight', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);              // (s, count[, char])
        Add3('Remove', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);        // (s, startIndex[, count])
        Add3('Split', 2, 3, "ALI TypeKind"::List, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
    end;

    // --- §19.8 recognized-but-unimplemented tier: every OTHER documented AL system
    // function gets a row so it is bound, never "unknown identifier". Arity is set as
    // generously as the common native signature allows (min..max cover the usual overloads);
    // precision here only matters for a truthful arg-count in the diagnostic, not execution.
    // Domain 0 (none of Str/Math/DateTime/System/Record) marks "other" for these rows.
    local procedure PopulateUnimplemented()
    begin
        // --- Environment / diagnostics ---
        AddUnimpl('CurrReport', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('CurrPage', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('CurrFieldNo', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::None);
        AddUnimpl('DebuggerBreak', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('HyperLink', 1, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('LogMessage', 2, 6, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('FeatureTelemetry', 2, 5, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('IsUnimplemented', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
        // --- File / device (out of v1's InStream/OutStream helper scope) ---
        AddUnimpl('File', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('Download', 1, 5, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
        AddUnimpl('Upload', 1, 5, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
        AddUnimpl('DownloadFromStream', 1, 5, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
        AddUnimpl('FileExists', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
        AddUnimpl('ErrorInfo', 0, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        AddUnimpl('RegisterServiceConnection', 1, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::None);
        // --- Bare `Run(...)` (§19.6). `Codeunit.Run(...)` and `MyCU.Run(...)` do NOT come through
        // here: both are member calls, resolved by "ALI Binder".BindRunCall into a CU_RUN. This
        // row only keeps an UNQUALIFIED `Run(...)` recognized instead of "name does not exist".
        AddUnimpl('Run', 0, 2, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::None);
    end;

    local procedure AddUnimpl(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"): Integer
    var
        BId: Integer;
        F: Integer;
    begin
        BNameUpper.Add(UpperCase(Name));
        BNameText.Add(Name);
        BMinArity.Add(MinA);
        BMaxArity.Add(MaxA);
        BResultType.Add(ResType.AsInteger());
        BDomain.Add(Domain);
        F := FlagUnimplemented();
        BFlags.Add(F);
        BVarMask.Add(0);
        BNextOverload.Add(0);
        BId := BNameUpper.Count();
        NameMap.Set(UpperCase(Name), BId);
        // Unimplemented builtins take no typed params, but the param-span columns MUST stay
        // parallel to the builtin columns (ParamType indexes PCountByBId by BId directly, so a
        // missing row here reads past the list end).
        PFirstByBId.Add(PParamType.Count() + 1);
        PCountByBId.Add(0);
        exit(BId);
    end;

    // AddUnimpl with a reason the diagnostic can show. Used where the builtin is not missing work
    // but unavailable BY BUILD — a platform method whose scope is OnPrem cannot even be compiled
    // into a Cloud build, so the row is registered in place (BuiltinIds stay identical across
    // both builds, which stored bytecode depends on) and refused at bind time instead.
    local procedure AddUnimplBecause(Name: Text; MinA: Integer; MaxA: Integer; ResType: Enum "ALI TypeKind"; Domain: Enum "ALI Builtin Domain"; Why: Text): Integer
    var
        BId: Integer;
    begin
        BId := AddUnimpl(Name, MinA, MaxA, ResType, Domain);
        BUnimplWhy.Set(BId, Why);
        exit(BId);
    end;

    // --- String group (§1.1) — all pure ---
    local procedure PopulateString()
    begin
        Add3('CopyStr', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);  // (s, start[, len])
        Add1('StrLen', 1, 1, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add1('MaxStrLen', 1, 1, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);  // compile-time: declared Text/Code length (lowerer-folded, like ArrayLen)
        Add2('StrPos', 2, 2, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add0('StrSubstNo', 1, Variadic(), "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true);               // format + args
        // SecretStrSubstNo(format, args...) -> SecretText. Identical formatting to StrSubstNo —
        // the only difference is the RESULT TYPE, which is what stops the formatted value from
        // flowing back into a plain Text without an explicit Unwrap(). Native AL additionally
        // requires every substitution arg to be SecretText; ALI accepts Text there too
        // (a superset — it never makes a script that native accepts fail here).
        Add0('SecretStrSubstNo', 1, Variadic(), "ALI TypeKind"::SecretText, "ALI Builtin Domain"::Str, true);
        Add0('Format', 1, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true);                            // (val[,len][,fmt])
        Add1('LowerCase', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add1('UpperCase', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text);
        Add3('DelChr', 1, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Text); // (s[,where][,chars])
        Add3('ConvertStr', 3, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Text);
        Add2('PadStr', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);           // (s, len[, fillChar])
        Add2('IncStr', 1, 1, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::None);
        Add2('SelectStr', 2, 2, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Integer, "ALI TypeKind"::Text);
        Add3('DelStr', 2, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);       // (s, pos[, len])
        Add3('InsStr', 3, 3, "ALI TypeKind"::Text, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);       // (s, sub, pos)
        Add3('StrCheckSum', 1, 3, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Str, true, "ALI TypeKind"::Text, "ALI TypeKind"::Text, "ALI TypeKind"::Integer);   // (s[, weight][, modulus])
    end;

    // --- Math group (§1.1). Random/Randomize are NOT pure. ---
    local procedure PopulateMath()
    begin
        Add1('Abs', 1, 1, "ALI TypeKind"::Decimal, "ALI Builtin Domain"::Math, true, "ALI TypeKind"::Decimal);
        Add3('Round', 1, 3, "ALI TypeKind"::Decimal, "ALI Builtin Domain"::Math, true, "ALI TypeKind"::Decimal, "ALI TypeKind"::Decimal, "ALI TypeKind"::Text);
        Add2('Power', 2, 2, "ALI TypeKind"::Decimal, "ALI Builtin Domain"::Math, true, "ALI TypeKind"::Decimal, "ALI TypeKind"::Decimal);
        Add1('Random', 1, 1, "ALI TypeKind"::Integer, "ALI Builtin Domain"::Math, false, "ALI TypeKind"::Integer);
        Add1('Randomize', 0, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::Math, false, "ALI TypeKind"::Integer);
    end;

    // --- Date/time group (§1.1). Today/Time/CurrentDateTime/WorkDate are NOT pure. ---
    local procedure PopulateDateTime()
    begin
        Add0('Today', 0, 0, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, false);
        Add0('Time', 0, 0, "ALI TypeKind"::Time, "ALI Builtin Domain"::DateTime, false);
        Add0('CurrentDateTime', 0, 0, "ALI TypeKind"::DateTime, "ALI Builtin Domain"::DateTime, false);
        Add0('WorkDate', 0, 1, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, false);
        Add2('CalcDate', 1, 2, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::DateFormula, "ALI TypeKind"::Date);  // P1 accepts a real DateFormula var OR a Text literal (implicit Text->DateFormula conversion, §6.4)
        Add2('Date2DMY', 2, 2, "ALI TypeKind"::Integer, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date, "ALI TypeKind"::Integer);
        Add2('Date2DWY', 2, 2, "ALI TypeKind"::Integer, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date, "ALI TypeKind"::Integer);
        Add3('DMY2Date', 1, 3, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);
        Add3('DWY2Date', 1, 3, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer);
        Add2('CreateDateTime', 2, 2, "ALI TypeKind"::DateTime, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date, "ALI TypeKind"::Time);
        Add1('DT2Date', 1, 1, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::DateTime);
        Add1('DT2Time', 1, 1, "ALI TypeKind"::Time, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::DateTime);
        Add1('ClosingDate', 1, 1, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date);
        Add1('NormalDate', 1, 1, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date);
        Add2('RoundDateTime', 1, 2, "ALI TypeKind"::DateTime, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::DateTime, "ALI TypeKind"::BigInteger);  // (dt[, precisionMs])
        Add2('DaTi2Variant', 2, 2, "ALI TypeKind"::Variant, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::Date, "ALI TypeKind"::Time);
        Add1('Variant2Date', 1, 1, "ALI TypeKind"::Date, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::None);   // any convertible operand (Variant wildcard)
        Add1('Variant2Time', 1, 1, "ALI TypeKind"::Time, "ALI Builtin Domain"::DateTime, true, "ALI TypeKind"::None);
    end;

    // --- System group (§1.1). UI/side-effecting -> NOT pure. ---
    local procedure PopulateSystem()
    begin
        Add0('Commit', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);   // no-op under the interpreter's TryFunction scope (CommitBehavior::Ignore); Simulation rolls everything back regardless
        Add0('Message', 1, Variadic(), "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);
        Add0('Error', 1, Variadic(), "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);
        Add0('Confirm', 1, Variadic(), "ALI TypeKind"::Boolean, "ALI Builtin Domain"::System, false);
        Add0('StrMenu', 1, 3, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        Add1('Sleep', 1, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false, "ALI TypeKind"::Integer);
        Add0('GuiAllowed', 0, 0, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::System, false);
        Add0('CompanyName', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
        Add0('UserId', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
        Add0('UserSecurityId', 0, 0, "ALI TypeKind"::Guid, "ALI Builtin Domain"::System, false);
        Add0('CreateGuid', 0, 0, "ALI TypeKind"::Guid, "ALI Builtin Domain"::System, false);
        Add1('IsNullGuid', 1, 1, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::System, true, "ALI TypeKind"::Guid);
        Add0('Evaluate', 2, 3, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::System, false);   // (var target, text[, number])
        Add0('GetLastErrorText', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
        Add0('GETLASTERRORCALLSTACK', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
#if CLOUD
        // GetLastErrorObject() is OnPrem-scoped platform surface — it does not exist to be called
        // in a cloud build. Registered IN PLACE (not removed) so every BuiltinId after it keeps
        // the value it has on premise, which serialized modules carry raw.
        AddUnimplBecause('GETLASTERROROBJECT', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::None, 'it is only available in an on-premises installation');
#else
        Add0('GETLASTERROROBJECT', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
#endif
        Add0('GETLASTERRORCODE', 0, 0, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false);
        // Void: the System runtime never sets ResultV for it, so a non-None result type made the
        // interpreter copy an UNSET Variant into the out register (NavIndirectValue -> NavText).
        Add1('SelectLatestVersion', 0, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false, "ALI TypeKind"::Integer);
        Add0('ClearLastError', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);
        Add0('Clear', 1, 1, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);      // (var anything)
        Add0('ClearAll', 0, 0, "ALI TypeKind"::None, "ALI Builtin Domain"::System, false);
        Add0('WindowsLanguage', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        // Session-environment options. Result type is Integer, not Option: the ordinal is the
        // whole payload (`CurrentClientType() = ClientType::Web` needs the ClientType option SET
        // to exist, which is a system option ALI has no metadata source for). ponytail: ordinal
        // only, add the named set if a script ever needs Format()/`::` on one of these.
        Add0('ClientType', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        Add0('CurrentClientType', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        Add0('CurrentExecutionMode', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        Add1('GlobalLanguage', 0, 1, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false, "ALI TypeKind"::Integer);
        Add0('SessionID', 0, 0, "ALI TypeKind"::Integer, "ALI Builtin Domain"::System, false);
        Add6('GetUrl', 1, 6, "ALI TypeKind"::Text, "ALI Builtin Domain"::System, false, "ALI TypeKind"::Integer, "ALI TypeKind"::Text, "ALI TypeKind"::Integer, "ALI TypeKind"::Integer, "ALI TypeKind"::Text, "ALI TypeKind"::Boolean);
        // CopyStream(OutStream, InStream[, ByteToRead]). The two stream params are wildcards
        // here: stream handles ride the generic Int-register path, and the binder checks their
        // OutStream/InStream direction itself (ALI968), like the stream methods do.
        Add3('CopyStream', 2, 3, "ALI TypeKind"::Boolean, "ALI Builtin Domain"::System, false, "ALI TypeKind"::None, "ALI TypeKind"::None, "ALI TypeKind"::Integer);
    end;

    // ===== Native codeunit catalogue =====
    //
    // A fixed list of procedures of real codeunits that ALI calls NATIVELY instead of harvesting
    // their source — the ones whose body needs DotNet (which the harvester can never compile)
    // plus the handful of helpers scripts use all the time. `TypeHelper.UrlEncode(s)` binds to
    // one of these rows and runs as `TypeHelper.UrlEncode(s)` inside "ALI Native Runtime". A
    // method NOT listed here still goes through the harvester, exactly as before.
    //
    // One row per OVERLOAD (AL procedures have no optional parameters, so arity is exact);
    // "ALI Binder".BindNativeCall walks the BNextOverload chain and takes the first row whose
    // parameters accept the argument types. Spec = comma-separated parameter codes (see
    // NativeParamType), `&` prefix = `var`. The row's dispatch key is
    // UPPER(Tag.Method(Spec)) — the `case` label in "ALI Native Runtime".Invoke.
    //
    // Left out on purpose: SecretText overloads (Cryptography Management keys excepted: they take Text), and every overload taking a Codeunit "Temp Blob"
    // as an ARGUMENT of another native (a native call takes values, not instance handles). Rows are only ever APPENDED:
    // a BuiltinId must never move (see Populate).
    local procedure PopulateNative()
    begin
        // --- codeunit 10 "Type Helper" (Base Application) ---
        Nat(10, 'TH', 'UrlEncode', "ALI TypeKind"::Text, '&Txt');
        Nat(10, 'TH', 'UrlDecode', "ALI TypeKind"::Text, '&Txt');
        Nat(10, 'TH', 'HtmlEncode', "ALI TypeKind"::Text, '&Txt');
        Nat(10, 'TH', 'HtmlDecode', "ALI TypeKind"::Text, '&Txt');
        Nat(10, 'TH', 'UriEscapeDataString', "ALI TypeKind"::Text, 'Txt');
        Nat(10, 'TH', 'JavaScriptStringEncode', "ALI TypeKind"::Text, 'Txt');
        Nat(10, 'TH', 'JavaScriptStringEncode', "ALI TypeKind"::Text, 'Txt,Bool');
        Nat(10, 'TH', 'CRLFSeparator', "ALI TypeKind"::Text, '');
        Nat(10, 'TH', 'LFSeparator', "ALI TypeKind"::Text, '');
        Nat(10, 'TH', 'NewLine', "ALI TypeKind"::Text, '');
        Nat(10, 'TH', 'ReadAsTextWithSeparator', "ALI TypeKind"::Text, 'InS,Txt');
        Nat(10, 'TH', 'FormatDate', "ALI TypeKind"::Text, 'Date,Int');
        Nat(10, 'TH', 'FormatDate', "ALI TypeKind"::Text, 'Date,Txt,Txt');
        Nat(10, 'TH', 'FormatDateWithCurrentCulture', "ALI TypeKind"::Text, 'Date');
        Nat(10, 'TH', 'FormatDateTime', "ALI TypeKind"::Text, 'DT,Txt,Txt');
        Nat(10, 'TH', 'FormatUtcDateTime', "ALI TypeKind"::Text, 'DT,Txt,Txt');
        Nat(10, 'TH', 'FormatDecimal', "ALI TypeKind"::Text, 'Dec,Txt,Txt');
        Nat(10, 'TH', 'Evaluate', "ALI TypeKind"::Boolean, '&Var,Txt,Txt,Txt');
        Nat(10, 'TH', 'GetCurrUTCDateTime', "ALI TypeKind"::DateTime, '');
        Nat(10, 'TH', 'GetCurrUTCDateTimeISO8601', "ALI TypeKind"::Text, '');
        Nat(10, 'TH', 'EvaluateUTCDateTime', "ALI TypeKind"::DateTime, 'Txt');
        Nat(10, 'TH', 'EvaluateUnixTimestamp', "ALI TypeKind"::DateTime, 'BigInt');
        Nat(10, 'TH', 'GetCurrentDateTimeInUserTimeZone', "ALI TypeKind"::DateTime, '');
        Nat(10, 'TH', 'ConvertDateTimeFromUTCToTimeZone', "ALI TypeKind"::DateTime, 'DT,Txt');
        Nat(10, 'TH', 'GetUserTimezoneOffset', "ALI TypeKind"::Boolean, '&Dur');
        Nat(10, 'TH', 'IsNumeric', "ALI TypeKind"::Boolean, 'Txt');
        Nat(10, 'TH', 'TextDistance', "ALI TypeKind"::Integer, 'Txt,Txt');
        Nat(10, 'TH', 'IntToHex', "ALI TypeKind"::Text, 'Int');
        Nat(10, 'TH', 'BitwiseAnd', "ALI TypeKind"::Integer, 'Int,Int');
        Nat(10, 'TH', 'BitwiseOr', "ALI TypeKind"::Integer, 'Int,Int');
        Nat(10, 'TH', 'BitwiseXor', "ALI TypeKind"::Integer, 'Int,Int');
        Nat(10, 'TH', 'Maximum', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(10, 'TH', 'Minimum', "ALI TypeKind"::Decimal, 'Dec,Dec');

        // --- codeunit 4110 "Base64 Convert" (System Application) ---
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'Txt');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'Txt,Bool');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'Txt,Enc');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'Txt,Enc,Int');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'Txt,Bool,Enc,Int');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'InS');
        Nat(4110, 'B64', 'ToBase64', "ALI TypeKind"::Text, 'InS,Bool');
        Nat(4110, 'B64', 'ToBase64Url', "ALI TypeKind"::Text, 'Txt');
        Nat(4110, 'B64', 'ToBase64Url', "ALI TypeKind"::Text, 'Txt,Enc');
        Nat(4110, 'B64', 'ToBase64Url', "ALI TypeKind"::Text, 'Txt,Enc,Int');
        Nat(4110, 'B64', 'ToBase64Url', "ALI TypeKind"::Text, 'InS');
        Nat(4110, 'B64', 'FromBase64', "ALI TypeKind"::Text, 'Txt');
        Nat(4110, 'B64', 'FromBase64', "ALI TypeKind"::Text, 'Txt,Enc');
        Nat(4110, 'B64', 'FromBase64', "ALI TypeKind"::Text, 'Txt,Enc,Int');
        Nat(4110, 'B64', 'FromBase64', "ALI TypeKind"::None, 'Txt,OutS');

        // --- codeunit 710 Math (System Application) ---
        Nat(710, 'MATH', 'Pi', "ALI TypeKind"::Decimal, '');
        Nat(710, 'MATH', 'E', "ALI TypeKind"::Decimal, '');
        Nat(710, 'MATH', 'Abs', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Acos', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Asin', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Atan', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Atan2', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'BigMul', "ALI TypeKind"::BigInteger, 'Int,Int');
        Nat(710, 'MATH', 'Ceiling', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Cos', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Cosh', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Exp', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Floor', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'IEEERemainder', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'Log', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Log', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'Log10', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Max', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'Min', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'Pow', "ALI TypeKind"::Decimal, 'Dec,Dec');
        Nat(710, 'MATH', 'Sign', "ALI TypeKind"::Integer, 'Dec');
        Nat(710, 'MATH', 'Sinh', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Sin', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Sqrt', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Tan', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Tanh', "ALI TypeKind"::Decimal, 'Dec');
        Nat(710, 'MATH', 'Truncate', "ALI TypeKind"::Decimal, 'Dec');

        // --- codeunit 1486 Encoding (System Application) ---
        Nat(1486, 'ENC', 'Convert', "ALI TypeKind"::Text, 'Int,Int,Txt');

        // --- codeunit 425 "Data Compression" (System Application) — STATEFUL: the zip archive
        // lives inside the instance, so its variables are NativeCodeunit handles and every row
        // takes the receiver as parameter 1 ('Self'). ---
        StatefulNative.Add(425);
        Nat(425, 'DC', 'CreateZipArchive', "ALI TypeKind"::None, 'Self');
        Nat(425, 'DC', 'OpenZipArchive', "ALI TypeKind"::None, 'Self,InS,Bool');
        Nat(425, 'DC', 'OpenZipArchive', "ALI TypeKind"::None, 'Self,InS,Bool,Int');
        Nat(425, 'DC', 'SaveZipArchive', "ALI TypeKind"::None, 'Self,OutS');
        Nat(425, 'DC', 'CloseZipArchive', "ALI TypeKind"::None, 'Self');
        Nat(425, 'DC', 'GetEntryList', "ALI TypeKind"::None, 'Self,List');
        Nat(425, 'DC', 'ExtractEntry', "ALI TypeKind"::Integer, 'Self,Txt,OutS');
        Nat(425, 'DC', 'ExtractEntry', "ALI TypeKind"::None, 'Self,Txt,OutS,&Int');
        Nat(425, 'DC', 'AddEntry', "ALI TypeKind"::None, 'Self,InS,Txt');
        Nat(425, 'DC', 'RemoveEntry', "ALI TypeKind"::None, 'Self,Txt');
        Nat(425, 'DC', 'IsGZip', "ALI TypeKind"::Boolean, 'Self,InS');
        Nat(425, 'DC', 'IsZip', "ALI TypeKind"::Boolean, 'Self,InS');
        Nat(425, 'DC', 'GZipCompress', "ALI TypeKind"::None, 'Self,InS,OutS');
        Nat(425, 'DC', 'GZipDecompress', "ALI TypeKind"::None, 'Self,InS,OutS');

        // --- codeunit 4100 "Temp Blob" (System Application) — STATEFUL: the blob lives inside
        // the instance, so several streams (and several Temp Blobs) can meet on it. The
        // stream-RETURNING overloads (`InS := TB.CreateInStream()`) are left out: a stream is a
        // handle allocated at proc entry, there is nothing for a call to return into. ---
        StatefulNative.Add(4100);
        Nat(4100, 'TB', 'CreateInStream', "ALI TypeKind"::None, 'Self,InS');
        Nat(4100, 'TB', 'CreateInStream', "ALI TypeKind"::None, 'Self,InS,Enc');
        Nat(4100, 'TB', 'CreateOutStream', "ALI TypeKind"::None, 'Self,OutS');
        Nat(4100, 'TB', 'CreateOutStream', "ALI TypeKind"::None, 'Self,OutS,Enc');
        Nat(4100, 'TB', 'HasValue', "ALI TypeKind"::Boolean, 'Self');
        Nat(4100, 'TB', 'Length', "ALI TypeKind"::Integer, 'Self');
        Nat(4100, 'TB', 'FromRecord', "ALI TypeKind"::None, 'Self,Rec,Int');
        Nat(4100, 'TB', 'FromRecord', "ALI TypeKind"::None, 'Self,RRef,Int');
        Nat(4100, 'TB', 'FromRecordRef', "ALI TypeKind"::None, 'Self,RRef,Int');
        Nat(4100, 'TB', 'ToRecordRef', "ALI TypeKind"::None, 'Self,RRef,Int');
        Nat(4100, 'TB', 'FromFieldRef', "ALI TypeKind"::None, 'Self,FRef');
        Nat(4100, 'TB', 'ToFieldRef', "ALI TypeKind"::None, 'Self,FRef');

        // --- codeunit 457 "Environment Information" (System Application) ---
        Nat(457, 'ENV', 'IsProduction', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'IsSandbox', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'IsSaaS', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'IsOnPrem', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'IsFinancials', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'IsSaaSInfrastructure', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'CanStartSession', "ALI TypeKind"::Boolean, '');
        Nat(457, 'ENV', 'GetEnvironmentName', "ALI TypeKind"::Text, '');
        Nat(457, 'ENV', 'GetApplicationFamily', "ALI TypeKind"::Text, '');
        Nat(457, 'ENV', 'GetLinkedPowerPlatformEnvironmentId', "ALI TypeKind"::Text, '');
#if CLOUD
        // Environment Information.GetEnvironmentSetting reads server configuration and is
        // OnPrem-scoped: not callable from a cloud build. Row kept in place so every native
        // BuiltinId after it is unchanged — see NatUnavailable.
        NatUnavailable(457, 'ENV', 'GetEnvironmentSetting', "ALI TypeKind"::Text, 'Txt', 'it is only available in an on-premises installation');
#else
        Nat(457, 'ENV', 'GetEnvironmentSetting', "ALI TypeKind"::Text, 'Txt');
#endif
        Nat(457, 'ENV', 'VersionInstalled', "ALI TypeKind"::Integer, 'Guid');

        // --- codeunit 43 Language (System Application). Code[10] parameters take Text, as a
        // native call does (overlong input errors at the call). Lookup* (pages) and
        // SetPreferredLanguageID (writes User Personalization) left out. Int overload of
        // GetWindowsLanguageName first: a Text argument never converts to Integer. ---
        Nat(43, 'LANG', 'GetUserLanguageCode', "ALI TypeKind"::Text, '');
        Nat(43, 'LANG', 'GetUserLanguageTag', "ALI TypeKind"::Text, '');
        Nat(43, 'LANG', 'GetDefaultApplicationLanguageId', "ALI TypeKind"::Integer, '');
        Nat(43, 'LANG', 'GetCurrentCultureName', "ALI TypeKind"::Text, '');
        Nat(43, 'LANG', 'GetLanguageIdOrDefault', "ALI TypeKind"::Integer, 'Txt');
        Nat(43, 'LANG', 'GetLanguageId', "ALI TypeKind"::Integer, 'Txt');
        Nat(43, 'LANG', 'GetFormatRegionOrDefault', "ALI TypeKind"::Text, 'Txt');
        Nat(43, 'LANG', 'GetLanguageCode', "ALI TypeKind"::Text, 'Int');
        Nat(43, 'LANG', 'GetWindowsLanguageName', "ALI TypeKind"::Text, 'Int');
        Nat(43, 'LANG', 'GetWindowsLanguageName', "ALI TypeKind"::Text, 'Txt');
        Nat(43, 'LANG', 'GetParentLanguageId', "ALI TypeKind"::Integer, 'Int');
        Nat(43, 'LANG', 'GetTwoLetterISOLanguageName', "ALI TypeKind"::Text, 'Int');
        Nat(43, 'LANG', 'GetLanguageIdFromCultureName', "ALI TypeKind"::Integer, 'Txt');
        Nat(43, 'LANG', 'GetCultureName', "ALI TypeKind"::Text, 'Int');
        Nat(43, 'LANG', 'ValidateApplicationLanguageId', "ALI TypeKind"::None, 'Int');
        Nat(43, 'LANG', 'ValidateWindowsLanguageId', "ALI TypeKind"::None, 'Int');
        Nat(43, 'LANG', 'ToDefaultLanguage', "ALI TypeKind"::Text, 'Var');
        Nat(43, 'LANG', 'SetOverrideLanguageId', "ALI TypeKind"::None, 'Int');
        Nat(43, 'LANG', 'SetOverrideLanguageId', "ALI TypeKind"::None, 'Int,Bool');
        Nat(43, 'LANG', 'SetOverrideFormatRegion', "ALI TypeKind"::None, 'Txt');
        Nat(43, 'LANG', 'SetOverrideFormatRegion', "ALI TypeKind"::None, 'Txt,Bool');
        Nat(43, 'LANG', 'GetApplicationLanguages', "ALI TypeKind"::None, 'Rec');     // temporary Record "Windows Language"

        // --- codeunit 1266 "Cryptography Management" (System Application). HashAlgorithmType
        // (Option) and Enum "Hash Algorithm" / "RSA Signature Padding" ride as Int (Option/Enum
        // convert implicitly); a SecretText key takes Text. Tenant encryption (EncryptText,
        // Decrypt, Enable/DisableEncryption…) and Signature Key overloads left out on purpose. ---
        Nat(1266, 'CRY', 'GenerateHash', "ALI TypeKind"::Text, 'Txt,Int');
        Nat(1266, 'CRY', 'GenerateHash', "ALI TypeKind"::Text, 'InS,Int');
        Nat(1266, 'CRY', 'GenerateHash', "ALI TypeKind"::Text, 'Txt,Txt,Int');
        Nat(1266, 'CRY', 'GenerateHashAsBase64String', "ALI TypeKind"::Text, 'Txt,Int');
        Nat(1266, 'CRY', 'GenerateHashAsBase64String', "ALI TypeKind"::Text, 'Txt,Txt,Int');
        Nat(1266, 'CRY', 'GenerateBase64KeyedHashAsBase64String', "ALI TypeKind"::Text, 'Txt,Txt,Int');
        Nat(1266, 'CRY', 'GenerateBase64KeyedHash', "ALI TypeKind"::Text, 'Txt,Txt,Int');
        Nat(1266, 'CRY', 'SignData', "ALI TypeKind"::None, 'Txt,Txt,Int,OutS');
        Nat(1266, 'CRY', 'SignData', "ALI TypeKind"::None, 'InS,Txt,Int,OutS');
        Nat(1266, 'CRY', 'SignData', "ALI TypeKind"::None, 'Txt,Txt,Int,Int,OutS');
        Nat(1266, 'CRY', 'VerifyData', "ALI TypeKind"::Boolean, 'Txt,Txt,Int,InS');
        Nat(1266, 'CRY', 'VerifyData', "ALI TypeKind"::Boolean, 'InS,Txt,Int,InS');

        // --- codeunit 3960 Regex (System Application) — STATEFUL: `R.Regex(Pattern)` keeps the
        // pattern for the instance forms (`R.IsMatch(Input)`). Record arguments (Matches, Groups,
        // Captures, Regex Options — all TableType Temporary) share the script record's dataset;
        // List arguments are List of [Text]. GetGroupNumbers (List of [Integer]) left out. ---
        StatefulNative.Add(3960);
        Nat(3960, 'RGX', 'Regex', "ALI TypeKind"::None, 'Self,Txt');
        Nat(3960, 'RGX', 'Regex', "ALI TypeKind"::None, 'Self,Txt,Rec');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt,Txt');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt,Int');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt,Txt,Int');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt,Txt,Rec');
        Nat(3960, 'RGX', 'IsMatch', "ALI TypeKind"::Boolean, 'Self,Txt,Txt,Int,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Int,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Int,Int,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Rec,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Int,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Rec,Rec');
        Nat(3960, 'RGX', 'Match', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Int,Rec,Rec');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Int');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt,Int');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Int,Int');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt,Rec');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt,Int,Int');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt,Int,Rec');
        Nat(3960, 'RGX', 'Replace', "ALI TypeKind"::Text, 'Self,Txt,Txt,Txt,Int,Int,Rec');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Int,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Int,Int,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,Rec,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Int,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Rec,List');
        Nat(3960, 'RGX', 'Split', "ALI TypeKind"::None, 'Self,Txt,Txt,Int,Int,Rec,List');
        Nat(3960, 'RGX', 'Escape', "ALI TypeKind"::Text, 'Self,Txt');
        Nat(3960, 'RGX', 'Unescape', "ALI TypeKind"::Text, 'Self,Txt');
        Nat(3960, 'RGX', 'GroupNameFromNumber', "ALI TypeKind"::Text, 'Self,Int');
        Nat(3960, 'RGX', 'GroupNumberFromName', "ALI TypeKind"::Integer, 'Self,Txt');
        Nat(3960, 'RGX', 'GetGroupNames', "ALI TypeKind"::None, 'Self,List');
        Nat(3960, 'RGX', 'GetCacheSize', "ALI TypeKind"::Integer, 'Self');
        Nat(3960, 'RGX', 'SetCacheSize', "ALI TypeKind"::None, 'Self,Int');
        Nat(3960, 'RGX', 'GetHashCode', "ALI TypeKind"::Integer, 'Self');
        Nat(3960, 'RGX', 'Groups', "ALI TypeKind"::None, 'Self,Rec,Rec');
        Nat(3960, 'RGX', 'Captures', "ALI TypeKind"::None, 'Self,Rec,Rec');
        Nat(3960, 'RGX', 'MatchResult', "ALI TypeKind"::Text, 'Self,Rec,Txt');

        // --- Static platform receivers `Page.` / `Report.` / `File.` (pseudo codeunit ids, see
        // FileNativeId). The record argument rides as its Rec Runtime handle and reaches the
        // platform as a Variant (RecordAsVariant, the Codeunit.Run bridge). Object ids take
        // `Page::"X"` too: ObjectId converts to Integer. The old 'File' / 'DownloadFromStream'
        // unimplemented rows stay where they are — their BuiltinIds must not move. ---
        Nat(PageNativeId(), 'PAGE', 'Run', "ALI TypeKind"::None, 'Int');
        Nat(PageNativeId(), 'PAGE', 'Run', "ALI TypeKind"::None, 'Int,Rec');
        Nat(PageNativeId(), 'PAGE', 'Run', "ALI TypeKind"::None, 'Int,Rec,Int');
        Nat(ReportNativeId(), 'REPORT', 'Run', "ALI TypeKind"::None, 'Int');
        Nat(ReportNativeId(), 'REPORT', 'Run', "ALI TypeKind"::None, 'Int,Bool');
        Nat(ReportNativeId(), 'REPORT', 'Run', "ALI TypeKind"::None, 'Int,Bool,Bool');
        Nat(ReportNativeId(), 'REPORT', 'Run', "ALI TypeKind"::None, 'Int,Bool,Bool,Rec');
        // InStream of UploadIntoStream without `&`, as TB.CreateInStream: the handle is re-pointed
        // in place (AttachIn), nothing is written back. Classic 5-argument Upload form kept: it is
        // what existing code uses.
        Nat(FileNativeId(), 'FILE', 'DownloadFromStream', "ALI TypeKind"::Boolean, 'InS,Txt,Txt,Txt,&Txt');
        Nat(FileNativeId(), 'FILE', 'UploadIntoStream', "ALI TypeKind"::Boolean, 'Txt,InS');
        Nat(FileNativeId(), 'FILE', 'UploadIntoStream', "ALI TypeKind"::Boolean, 'Txt,Txt,Txt,&Txt,InS');
    end;

    // A native overload the catalogue KNOWS but this build cannot call: the underlying method's
    // scope is OnPrem, so it is not compilable into a Cloud build. Same row, same BuiltinId
    // ordering, just flagged Unimplemented so BindNativeCall refuses it with a reason instead of
    // the call reaching a dispatch arm that is not there.
    local procedure NatUnavailable(CodeunitId: Integer; Tag: Text; Method: Text; ResType: Enum "ALI TypeKind"; Spec: Text; Why: Text)
    var
        BId: Integer;
    begin
        BId := Nat(CodeunitId, Tag, Method, ResType, Spec);
        BFlags.Set(BId, BFlags.Get(BId) + FlagUnimplemented());
        BUnimplWhy.Set(BId, Why);
    end;

    // One native overload row, chained behind the previous overloads of the same method.
    local procedure Nat(CodeunitId: Integer; Tag: Text; Method: Text; ResType: Enum "ALI TypeKind"; Spec: Text) BId: Integer
    var
        Params: List of [Enum "ALI TypeKind"];
        Codes: List of [Text];
        Bit: Integer;
        Last: Integer;
        VarMask: Integer;
        NKey: Text;
        ParamCode: Text;
        TypeCode: Text;
    begin
        Bit := 1;
        if Spec <> '' then
            Codes := Spec.Split(',');
        foreach ParamCode in Codes do begin
            TypeCode := ParamCode;
            if TypeCode.StartsWith('&') then begin
                VarMask += Bit;
                TypeCode := TypeCode.Substring(2);
            end;
            Params.Add(NativeParamType(TypeCode));
            Bit := Bit * 2;
        end;

        BId := AddRow(UpperCase(Tag + '.' + Method + '(' + Spec + ')'), Method, Params.Count(), Params.Count(), ResType, "ALI Builtin Domain"::Native, 0, VarMask, Params);

        NKey := NativeKey(CodeunitId, UpperCase(Method));
        if not NativeFirst.Get(NKey, Last) then
            NativeFirst.Add(NKey, BId)
        else begin
            while BNextOverload.Get(Last) <> 0 do
                Last := BNextOverload.Get(Last);
            BNextOverload.Set(Last, BId);
        end;
        exit(BId);
    end;

    local procedure NativeParamType(TypeCode: Text): Enum "ALI TypeKind"
    begin
        case TypeCode of
            'Txt':
                exit("ALI TypeKind"::Text);
            'Bool':
                exit("ALI TypeKind"::Boolean);
            'Int':
                exit("ALI TypeKind"::Integer);
            'BigInt':
                exit("ALI TypeKind"::BigInteger);
            'Dec':
                exit("ALI TypeKind"::Decimal);
            'Date':
                exit("ALI TypeKind"::Date);
            'DT':
                exit("ALI TypeKind"::DateTime);
            'Dur':
                exit("ALI TypeKind"::Duration);
            'Var':
                exit("ALI TypeKind"::Variant);
            'Guid':
                exit("ALI TypeKind"::Guid);
            'Enc':
                exit("ALI TypeKind"::Option);           // TextEncoding — the binder checks the set
            'InS':
                exit("ALI TypeKind"::InStream);
            'OutS':
                exit("ALI TypeKind"::OutStream);
            'List':
                exit("ALI TypeKind"::List);             // List of [Text] — the binder checks the element
            'Rec':
                exit("ALI TypeKind"::Record);           // any table — rides as its Rec Runtime handle
            'RRef':
                exit("ALI TypeKind"::RecordRef);
            'FRef':
                exit("ALI TypeKind"::FieldRef);
            'Self':
                exit("ALI TypeKind"::NativeCodeunit);
        end;
        Error('ALI980: unknown native parameter code ''%1''', TypeCode);
    end;
}
