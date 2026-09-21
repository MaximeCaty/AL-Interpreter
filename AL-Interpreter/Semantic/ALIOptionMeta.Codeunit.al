// ALI Option Meta — memoized Option/Enum set registry (§D3). SingleInstance so bind-time
// interning is visible at runtime with zero plumbing (the binder interns a set id; the
// lowerer/interpreter read it back through OPT_TO_TEXT / CaptionOf without any extra wiring).
//
// A "set" is one option/enum value space: an inline option string (`Option A,B,C`), a table
// field (Option or Enum typed — same FieldRef-driven source since both report identically
// through the virtual Field table, §D1), or a real Enum object. Each gets an integer SetId;
// integer<->name/caption maps for a set are built EXACTLY ONCE (EnsureBuilt), then every
// subsequent lookup is a dictionary probe — the whole point of memoizing (§ plan perf note).
codeunit 51137 "ALI Option Meta"
{
    Access = Public;
    SingleInstance = true;

    var
        LastResolveFailed: Boolean;  // last enum-source EnsureBuilt found no source at all
        FieldKeyMap: Dictionary of [BigInteger, Integer];   // tableId*FieldStride+fieldNo -> SetId
        OrdToCaption: Dictionary of [BigInteger, Text]; // setId*OrdStride+(ordinal+1) -> caption
        EnumKeyMap: Dictionary of [Integer, Integer];       // enum object id -> SetId
        // --- Interning maps: content/source key -> SetId ---
        InlineKeyMap: Dictionary of [Text, Integer];        // 'A|B|C c' (content) -> SetId
        InlineKeyOf: Dictionary of [Integer, Text];         // reverse of InlineKeyMap (DescribeSet)

        // --- Member maps, keyed by SetId (built once per set by EnsureBuilt) ---
        NameToOrd: Dictionary of [Text, Integer];   // Format(SetId)+'|'+UPPERCASE(name) -> ordinal

        BuildCounter: Integer;   // # of EnsureBuilt actual builds this session (test 8 hook)
        SetBuilt: List of [Boolean];

        // --- Per-set bookkeeping (parallel, 1-based SetId) ---
        SetKind: List of [Integer];         // 1=Inline 2=Field 3=Enum
        SetSourceA: List of [Integer];      // Inline: unused / Field: table id / Enum: enum object id
        SetSourceB: List of [Integer];      // Field: field no / Inline,Enum: unused

    // ===== Kind ordinals =====
    local procedure FieldStride(): BigInteger
    begin
        exit(1000000);
    end;

    local procedure OrdStride(): BigInteger
    begin
        exit(1000000);
    end;

    // ===== Interning =====

    // Inline option string (`Option A,B,"C c"`) — content-interned so two identical
    // declarations share one SetId. Names in DECLARATION order; empty entries (gapped slots,
    // e.g. `Option ,One,Two`) are '' and get ordinal = their position. Built eagerly (names
    // are already in hand — no metadata fetch needed).
    procedure InternInlineSet(Names: List of [Text]): Integer
    var
        i: Integer;
        SetId: Integer;
        KeyN: Text;
        Name: Text;
    begin
        KeyN := '';
        foreach Name in Names do begin
            if KeyN <> '' then
                KeyN += '|';
            KeyN += Name;
        end;
        if InlineKeyMap.Get(KeyN, SetId) then
            exit(SetId);

        SetId := NewSet(1/*KindInline()*/, 0, 0);
        for i := 1 to Names.Count() do
            RegisterMember(SetId, i - 1, Names.Get(i), Names.Get(i));
        MarkBuilt(SetId);
        InlineKeyMap.Set(KeyN, SetId);
        InlineKeyOf.Set(SetId, KeyN);
        exit(SetId);
    end;

    // Table field of type Option or Enum (both map to TOption per §D1 — enum-ness only
    // matters here, for member enumeration via FieldRef). Lazy: SetId is handed out
    // immediately, members enumerated on first lookup via EnsureBuilt.
    procedure FieldSetId(TableId: Integer; FieldNo: Integer): Integer
    var
        KeyI: BigInteger;
        SetId: Integer;
    begin
        KeyI := TableId * FieldStride() + FieldNo;
        if FieldKeyMap.Get(KeyI, SetId) then
            exit(SetId);
        SetId := NewSet(2/*KindField()*/, TableId, FieldNo);
        FieldKeyMap.Set(KeyI, SetId);
        exit(SetId);
    end;

    // Real Enum object (`Enum "X"` variable, or bare `"X"::Value`). Lazy — same shape as
    // FieldSetId; the enum's AL source is only fetched/tokenized on first member lookup.
    procedure InternEnum(EnumId: Integer): Integer
    var
        SetId: Integer;
    begin
        if EnumKeyMap.Get(EnumId, SetId) then
            exit(SetId);
        SetId := NewSet(3/*KindEnum()*/, EnumId, 0);
        EnumKeyMap.Set(EnumId, SetId);
        exit(SetId);
    end;

    local procedure NewSet(Kind: Integer; SrcA: Integer; SrcB: Integer): Integer
    begin
        SetKind.Add(Kind);
        SetSourceA.Add(SrcA);
        SetSourceB.Add(SrcB);
        SetBuilt.Add(false);
        exit(SetKind.Count());
    end;

    // ===== Lookup (dictionary probes ONLY once EnsureBuilt has run) =====

    // Resolve a member NAME (identifier, not caption) to its ordinal within a set.
    procedure TryOrdinalByName(SetId: Integer; MemberName: Text; var Ord: Integer): Boolean
    begin
        if SetId <= 0 then
            exit(false);
        EnsureBuilt(SetId);
        exit(NameToOrd.Get(Format(SetId) + '|' + UpperCase(MemberName), Ord));
    end;

    // Caption for an ordinal (Format(x) result). Unknown ordinal -> Format(Ord) fallback,
    // matching native AL's own behavior for an out-of-range/undeclared option value.
    procedure CaptionOf(SetId: Integer; Ord: Integer): Text
    var
        Cap: Text;
    begin
        if SetId <= 0 then
            exit(Format(Ord));
        EnsureBuilt(SetId);
        if OrdToCaption.Get(SetId * OrdStride() + (Ord + 1), Cap) then
            exit(Cap);
        exit(Format(Ord));
    end;

    local procedure RegisterMember(SetId: Integer; Ord: Integer; Name: Text; Caption: Text)
    begin
        // Blank names (gapped inline slots) are never a valid `::Member` target — only the
        // caption map gets an entry so Format() still returns '' for that ordinal.
        if Name <> '' then
            NameToOrd.Set(Format(SetId) + '|' + UpperCase(Name), Ord);
        OrdToCaption.Set(SetId * OrdStride() + (Ord + 1), Caption);
    end;

    // ===== Build (once per set; §D3 perf requirement) =====

    local procedure MarkBuilt(SetId: Integer)
    begin
        SetBuilt.Set(SetId, true);
    end;

    local procedure EnsureBuilt(SetId: Integer)
    begin
        if SetBuilt.Get(SetId) then
            exit;
        case SetKind.Get(SetId) of
            2/*KindField()*/:
                BuildFromField(SetId, SetSourceA.Get(SetId), SetSourceB.Get(SetId));
            3/*KindEnum()*/:
#if CLOUD
                // CLOUD: an Enum OBJECT's member names and captions live only in its stored AL
                // source, and "Application Object Metadata" (OnPrem-scoped) is the only way to
                // reach it — see "ALI Object Registry".TryGetObjectSource. Nothing can be built,
                // which is exactly the state an enum whose source would not read produces on
                // premise: plain integer enum semantics keep working, and only a `::Member`
                // lookup or Format() reports the §D5-3 ALI987 gate.
                LastResolveFailed := true;
#else
                BuildFromEnumSource(SetId, SetSourceA.Get(SetId));
#endif
        // KindInline() is always built eagerly at InternInlineSet time.
        end;
        MarkBuilt(SetId);
        BuildCounter += 1;
    end;

    // Field-backed set (§D5-1): FieldRef enum APIs are 1-based, gap-safe, and cover BOTH
    // option and enum fields identically — including enumextension values and the SESSION
    // LANGUAGE caption (translated), unlike the Enum-object source-parse path below.
    local procedure BuildFromField(SetId: Integer; TableId: Integer; FieldNo: Integer)
    var
        RRef: RecordRef;
        FRef: FieldRef;
        Cnt: Integer;
        i: Integer;
    begin
        RRef.Open(TableId, true);
        FRef := RRef.Field(FieldNo);
        Cnt := FRef.EnumValueCount();
        for i := 1 to Cnt do
            RegisterMember(SetId, FRef.GetEnumValueOrdinal(i), FRef.GetEnumValueName(i), FRef.GetEnumValueCaption(i));
        RRef.Close();
    end;

    // Enum-object set (§D5-3): no runtime API exposes an enum OBJECT's members (unlike a field,
    // which FieldRef covers above — and no metadata table maps an enum id to its values either),
    // so the enum's AL source is retrieved via page 51017's GetUserALCodeInStream (works without
    // opening the page — only its table permission is needed) and tokenized with the existing
    // lexer (comment/string safe), walking `value ( <int> ; <name> ) { [Caption = '<txt>';] }`.
    // Values added by EnumExtension objects are merged in. Caption falls back to the name (source
    // captions are source-language, not fr-CH translated — documented v1 scope).
    //
    // Both metadata reads go through AllObjWithCaption first, which is the cheap side: it hands
    // over the runtime package id (the LEADING primary-key field of "Application Object Metadata",
    // so the read is a seek instead of a scan, and cannot pick a row from another package), and
    // for an EXTENSION object its "Object Subtype" is the base object id — which is what finds the
    // enumextensions without opening every one of them to look for `extends <name>`.
    // Everything from here to KindSemicolon() exists only to parse an enum object's stored AL
    // source, which no cloud build can read — excluded there in one piece rather than left as
    // unreachable code (see EnsureBuilt for what happens instead).
#if not CLOUD
    local procedure BuildFromEnumSource(SetId: Integer; EnumId: Integer)
    var
        AllObj: Record AllObjWithCaption;
        AppObjMeta: Record "Application Object Metadata";
        ExtAllObj: Record AllObjWithCaption;
        Found: Boolean;
        Source: Text;
    begin
        if AllObj.Get(AllObj."Object Type"::Enum, EnumId) then begin
            AppObjMeta.SetRange("Object Type", AppObjMeta."Object Type"::Enum);
            if TryGetObjectSource(AppObjMeta, AllObj."App Runtime Package ID", EnumId, Source) then begin
                RegisterEnumValues(SetId, Source);
                Found := true;
            end;
        end;

        // Merge EnumExtension objects extending this enum.
        ExtAllObj.SetRange("Object Type", ExtAllObj."Object Type"::EnumExtension);
        ExtAllObj.SetRange("Object Subtype", Format(EnumId));
        if ExtAllObj.FindSet() then begin
            AppObjMeta.Reset();
            // Object Type ordinals differ between AllObj and "Application Object Metadata" — only
            // ids and package GUIDs are carried over from AllObj, never the option value itself.
            AppObjMeta.SetRange("Object Type", AppObjMeta."Object Type"::EnumExtension);
            repeat
                if TryGetObjectSource(AppObjMeta, ExtAllObj."App Runtime Package ID", ExtAllObj."Object ID", Source) then begin
                    RegisterEnumValues(SetId, Source);
                    Found := true;
                end;
            until ExtAllObj.Next() = 0;
        end;

        if not Found then
            LastResolveFailed := true;
    end;

    // Source of one metadata row, addressed by (runtime package, object type, object id) — the
    // caller owns the "Object Type" filter, which keeps the option value out of this signature
    // (AL has no way to pass an unnamed Option). Those three are the leading columns of the
    // table's clustered key, so the read is a seek; the fourth ("Emit Version") is unknown here,
    // which is why this filters rather than Get()s. NOTHING is read from the database on this
    // side: only the filters are handed to the page, which does the seek and the blob read in
    // ONE round trip (see GetUserALCodeFromFilters).
    local procedure TryGetObjectSource(var AppObjMeta: Record "Application Object Metadata"; PackageId: Guid; ObjectId: Integer; var Source: Text): Boolean
    var
        MetaPage: Page "ALI App. Obj. Metadata";
    begin
        AppObjMeta.SetRange("Runtime Package ID", PackageId);
        AppObjMeta.SetRange("Object ID", ObjectId);
        Source := MetaPage.GetUserALCodeFromFilters(AppObjMeta);
        exit(Source <> '');
    end;

    local procedure RegisterEnumValues(SetId: Integer; Source: Text)
    var
        i: Integer;
        Ordinals: List of [Integer];
        Captions: List of [Text];
        Names: List of [Text];
    begin
        ParseEnumValueDecls(Source, Names, Ordinals, Captions);
        for i := 1 to Names.Count() do
            RegisterMember(SetId, Ordinals.Get(i), Names.Get(i), Captions.Get(i));
    end;

    // Tokenizes Source with the existing lexer and walks `value ( Int ; Name ) { ... }`
    // declarations, picking up an optional `Caption = '...'` property from the value's body.
    // Best-effort: a source the lexer can't tokenize cleanly yields whatever was matched
    // before the trouble spot (never raises) — the caller's ALI987 gate covers total failure.
    local procedure ParseEnumValueDecls(Source: Text; var Names: List of [Text]; var Ordinals: List of [Integer]; var Captions: List of [Text])
    var
        ScratchDiags: Codeunit "ALI Diag Bag";
        Lex: Codeunit "ALI Lexer";
        Toks: Codeunit "ALI Token Table";
        Depth: Integer;
        i: Integer;
        j: Integer;
        n: Integer;
        Ord: Integer;
        CapTxt: Text;
        NameTxt: Text;
    begin
        Clear(Names);
        Clear(Ordinals);
        Clear(Captions);
        Toks.Reset();
        ScratchDiags.Reset();
        Lex.Tokenize(Source, Toks, ScratchDiags);
        n := Toks.Count();
        i := 1;
        while i <= n do
            if IsValueDecl(Toks, i, n) then begin
                Ord := Toks.GetInt(Toks.GetValueIndex(i + 2));
                NameTxt := Toks.GetIdentText(i + 4);
                // Find the closing ')' of `value(...)`.
                j := i + 5;
                while (j <= n) and (Toks.GetKind(j) <> KindCloseParen()) do
                    j += 1;
                CapTxt := NameTxt;
                j += 1;
                if (j <= n) and (Toks.GetKind(j) = KindOpenBrace()) then begin
                    Depth := 1;
                    j += 1;
                    while (j <= n) and (Depth > 0) do begin
                        if Toks.GetKind(j) = KindOpenBrace() then
                            Depth += 1
                        else
                            if Toks.GetKind(j) = KindCloseBrace() then
                                Depth -= 1
                            else
                                // AL is EAGER — never fold GetIdentText(j) into the same
                                // condition as the GetKind(j) = Identifier check (§ CLAUDE.md).
                                if (Depth = 1) and (Toks.GetKind(j) = KindIdentifier()) then
                                    if UpperCase(Toks.GetIdentText(j)) = 'CAPTION' then
                                        if (j + 2 <= n) and (Toks.GetKind(j + 1) = KindEquals()) and (Toks.GetKind(j + 2) = KindStringLiteral()) then
                                            CapTxt := Toks.GetIdentText(j + 2);
                        j += 1;
                    end;
                end;
                Names.Add(NameTxt);
                Ordinals.Add(Ord);
                Captions.Add(CapTxt);
                i := j;
            end else
                i += 1;
    end;

    // `value ( Int32Literal ; (Identifier|StringLiteral) )` starting at token i.
    local procedure IsValueDecl(var Toks: Codeunit "ALI Token Table"; i: Integer; n: Integer): Boolean
    begin
        if i + 4 > n then
            exit(false);
        // AL is EAGER (no short-circuit): GetIdentText(i) must not run before we know token i
        // is actually an identifier — calling it on e.g. a StringLiteral/Int32Literal token
        // reads the wrong value pool and throws "invalid argument ... List" (§ CLAUDE.md).
        if Toks.GetKind(i) <> KindIdentifier() then
            exit(false);
        if UpperCase(Toks.GetIdentText(i)) <> 'VALUE' then
            exit(false);
        if Toks.GetKind(i + 1) <> KindOpenParen() then
            exit(false);
        if Toks.GetKind(i + 2) <> KindInt32Literal() then
            exit(false);
        if Toks.GetKind(i + 3) <> KindSemicolon() then
            exit(false);
        exit((Toks.GetKind(i + 4) = KindIdentifier()) or (Toks.GetKind(i + 4) = KindStringLiteral()));
    end;

    // ===== Raw token-kind ordinals (mirror "ALI TokenKind"; see that enum for the full list) =====
    local procedure KindInt32Literal(): Integer
    begin
        exit(10);
    end;

    local procedure KindStringLiteral(): Integer
    begin
        exit(16);
    end;

    local procedure KindIdentifier(): Integer
    begin
        exit(20);
    end;

    local procedure KindEquals(): Integer
    begin
        exit(50);
    end;

    local procedure KindOpenParen(): Integer
    begin
        exit(70);
    end;

    local procedure KindCloseParen(): Integer
    begin
        exit(71);
    end;

    local procedure KindOpenBrace(): Integer
    begin
        exit(74);
    end;

    local procedure KindCloseBrace(): Integer
    begin
        exit(75);
    end;

    local procedure KindSemicolon(): Integer
    begin
        exit(81);
    end;
#endif

    // Whether the last EnsureBuilt() for an Enum-object set found no source at all (§D5-3
    // ALI987 gate: names/captions unavailable — plain integer semantics still work, so the
    // binder only reports this when a `::Member` lookup or Format() actually needs it).
    procedure LastEnumSourceUnresolved(): Boolean
    begin
        exit(LastResolveFailed);
    end;

    // ===== FieldClass / FieldType member lists (P2) =====
    //
    // `FieldRef.Class()` and `FieldRef.Type()` return native platform option types. Neither can
    // be modelled by reusing the platform ORDINALS: ALI's option sets are index-ordered name
    // lists (member i has ordinal i), while the platform's FieldType numbers are the virtual
    // Field table's non-contiguous ones (RecordID = 4988, Text = 31488, …). So ALI declares its
    // OWN ordinals over the SAME member names and maps between the two BY NAME at run time
    // ("ALI Rec Runtime".FieldTypeOrdinal formats the native value and looks the name up here).
    //
    // That is closed and self-consistent: a script can write `F.Type() = FieldType::Text` and
    // `Format(F.Type())`, and both sides of the comparison are ALI ordinals. The one thing it
    // deliberately does NOT do is let a platform ordinal leak into a script — which is right,
    // because a script could not have written that number down in the first place (there is no
    // AL syntax for a FieldType literal other than `FieldType::Member`).
    //
    // These two lists are the single source of truth, read by BOTH "ALI Binder".
    // TrySystemOptionSet (bind time, for `::` member access and variable declarations) and
    // "ALI Rec Runtime" (run time, for the name -> ordinal map). Member ORDER is therefore free
    // to be whatever the platform's OptionString says, and only membership matters for
    // correctness — an unknown name maps to -1 rather than silently to member 0.

    procedure FieldClassNames(): List of [Text]
    var
        Names: List of [Text];
    begin
        Names.Add('Normal');
        Names.Add('FlowField');
        Names.Add('FlowFilter');
        exit(Names);
    end;

    procedure FieldTypeNames(): List of [Text]
    var
        Names: List of [Text];
    begin
        // Order = the virtual Field table's OptionString, so a reader can diff it against the
        // platform. The values are NOT the platform ordinals (see the header above).
        Names.Add('TableFilter');
        Names.Add('RecordID');
        Names.Add('OemText');
        Names.Add('Date');
        Names.Add('Time');
        Names.Add('DateFormula');
        Names.Add('Decimal');
        Names.Add('Media');
        Names.Add('MediaSet');
        Names.Add('Text');
        Names.Add('Code');
        Names.Add('Binary');
        Names.Add('BLOB');
        Names.Add('Boolean');
        Names.Add('Integer');
        Names.Add('OemCode');
        Names.Add('Option');
        Names.Add('BigInteger');
        Names.Add('Duration');
        Names.Add('GUID');
        Names.Add('DateTime');
        exit(Names);
    end;

    // ===== Session-independent set spelling (stored bytecode) =====
    //
    // SetIds are handed out per session in interning order, so a module compiled in one session
    // and run in another would point OPT_TO_TEXT at somebody else's set. "ALI Module".Serialize
    // stores this spelling instead, and Deserialize re-interns it into this session's id.
    // 'I<names joined by |>' inline, 'F<table>,<field>' field-backed, 'E<enum id>' enum object.

    procedure DescribeSet(SetId: Integer): Text
    begin
        if (SetId < 1) or (SetId > SetKind.Count()) then
            exit('');
        case SetKind.Get(SetId) of
            1:
                exit('I' + InlineKeyOf.Get(SetId));
            2:
                exit('F' + Format(SetSourceA.Get(SetId), 0, 9) + ',' + Format(SetSourceB.Get(SetId), 0, 9));
            3:
                exit('E' + Format(SetSourceA.Get(SetId), 0, 9));
        end;
        exit('');
    end;

    // 0 = unreadable spelling (the caller then treats the stored module as stale).
    procedure InternDescribed(Desc: Text): Integer
    var
        Parts: List of [Text];
        A: Integer;
        B: Integer;
    begin
        if Desc = '' then
            exit(0);
        case CopyStr(Desc, 1, 1) of
            'I':
                exit(InternInlineSet(CopyStr(Desc, 2).Split('|')));
            'F':
                begin
                    Parts := CopyStr(Desc, 2).Split(',');
                    if Parts.Count() <> 2 then
                        exit(0);
                    if not Evaluate(A, Parts.Get(1), 9) then
                        exit(0);
                    if not Evaluate(B, Parts.Get(2), 9) then
                        exit(0);
                    exit(FieldSetId(A, B));
                end;
            'E':
                begin
                    if not Evaluate(A, CopyStr(Desc, 2), 9) then
                        exit(0);
                    exit(InternEnum(A));
                end;
        end;
        exit(0);
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        Clear(InlineKeyMap);
        Clear(InlineKeyOf);
        Clear(FieldKeyMap);
        Clear(EnumKeyMap);
        Clear(SetKind);
        Clear(SetSourceA);
        Clear(SetSourceB);
        Clear(SetBuilt);
        Clear(NameToOrd);
        Clear(OrdToCaption);
        BuildCounter := 0;
        LastResolveFailed := false;
    end;

    // Number of EnsureBuilt builds this session (test 8: memoization proof — two scripts
    // referencing the SAME set must trigger exactly one build).
    procedure BuildCount(): Integer
    begin
        exit(BuildCounter);
    end;
}
