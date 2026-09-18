// ALI Diag Bag — diagnostics collection shared by every pipeline stage (§4.3).
// Struct-of-arrays: one parallel List column per field. Every stage receives the
// SAME bag by var and appends; nothing stops at first error (§5.2 hard requirement).
// Position -> line/column is computed from the lexer's line-start offset array
// (binary search) so only the lexer tracks lines (§4.3).
// Mirror Microsoft codes/messages where a counterpart exists (AL0118, AL0132, ...);
// engine-specific conditions use the reserved ALI9xx range (§4.3).
codeunit 51008 "ALI Diag Bag"
{
    Access = Public;
    SingleInstance = false;   // constructed per-pipeline so tests stay isolated (§3.5)

    var
        HasLineMap: Boolean;
        HasSource: Boolean;
        HideCodes: Boolean;             // GetText/ToText omit the 'ALI984: ' prefix (LLM hosts: the code is noise)
        Verbose: Boolean;               // ToText additionally quotes the source line + caret + hint
        ColumnNo: List of [Integer];
        Length: List of [Integer];
        LineNo: List of [Integer];
        LineStarts: List of [Integer];  // 1-based source offset of each line start
        SeverityOrd: List of [Integer]; // "ALI Severity" ordinal
        StageOrd: List of [Integer];    // which pipeline stage produced it (free-form)
        StartPos: List of [Integer];    // 1-based char offset into source
        CodeText: List of [Text];       // e.g. 'AL0118' / 'ALI901'
        Message: List of [Text];
        SourceLines: List of [Text];    // installed via SetSource when verbose rendering is wanted

    // ===== Line map (installed once by the lexer) =====

    // Hand the lexer's line-start offsets to the bag so Pos -> (line,col) works.
    // LineStarts[i] = 1-based char offset where line i begins (i is 1-based).
    procedure SetLineStarts(NewLineStarts: List of [Integer])
    begin
        LineStarts := NewLineStarts;
        HasLineMap := true;
    end;

    // ===== Verbose rendering (source line + caret + hint under each diagnostic) =====
    // Aimed at small-LLM consumers: quoting the offending instruction next to the error
    // makes the diagnostic self-contained — no need to count lines in the original source.

    procedure SetVerbose(Value: Boolean)
    begin
        Verbose := Value;
    end;

    procedure IsVerbose(): Boolean
    begin
        exit(Verbose);
    end;

    // Drop the diagnostic code from the rendered text. The code stays in the bag (GetCode, ToJson)
    // so the script editor keeps it; an LLM host turns it off because it only costs tokens.
    procedure SetHideCodes(Value: Boolean)
    begin
        HideCodes := Value;
    end;

    procedure SetSource(Source: Text)
    begin
        SplitLines(Source, SourceLines);
        HasSource := true;
    end;

    procedure GetSourceLine(Ln: Integer): Text
    begin
        if (Ln < 1) or (Ln > SourceLines.Count()) then
            exit('');
        exit(SourceLines.Get(Ln));
    end;

    local procedure SplitLines(Source: Text; var Lines: List of [Text])
    var
        CR: Text[1];
        LF: Text[1];
    begin
        CR := ' ';
        CR[1] := 13;
        LF := ' ';
        LF[1] := 10;
        Lines := Source.Replace(CR + LF, LF).Replace(CR, LF).Split(LF);
    end;

    // ===== Adders =====
    // The *AtPos overloads take a raw source position; the plain overloads take a
    // pre-resolved line/column (used when the caller already knows it, e.g. token idx
    // resolved by the Token Table). Length may be 0 for a point diagnostic.

    procedure AddError(Code: Text; Msg: Text; Pos: Integer; Len: Integer)
    begin
        AddAtPos(Code, 2, Msg, Pos, Len, 0);
    end;

    procedure AddWarning(Code: Text; Msg: Text; Pos: Integer; Len: Integer)
    begin
        AddAtPos(Code, 1, Msg, Pos, Len, 0);
    end;

    procedure AddInfo(Code: Text; Msg: Text; Pos: Integer; Len: Integer)
    begin
        AddAtPos(Code, 0, Msg, Pos, Len, 0);
    end;

    // Stage-tagged variant.
    procedure AddAtPos(Code: Text; Sev: Integer; Msg: Text; Pos: Integer; Len: Integer; Stage: Integer)
    var
        Col: Integer;
        Ln: Integer;
    begin
        ResolvePos(Pos, Ln, Col);
        AddResolved(Code, Sev, Msg, Ln, Col, Pos, Len, Stage);
    end;

    // Fully-resolved variant (caller supplies line/column directly).
    procedure AddResolved(Code: Text; Sev: Integer; Msg: Text; Ln: Integer; Col: Integer; Pos: Integer; Len: Integer; Stage: Integer)
    begin
        CodeText.Add(Code);
        SeverityOrd.Add(Sev);
        Message.Add(Msg);
        LineNo.Add(Ln);
        ColumnNo.Add(Col);
        StartPos.Add(Pos);
        Length.Add(Len);
        StageOrd.Add(Stage);
    end;

    // ===== Position resolution (§4.3 binary search over LineStarts) =====

    // Given a 1-based source offset, resolve (1-based line, 1-based column).
    // Falls back to (0,0) when no line map is installed (e.g. unit-tested in isolation).
    procedure ResolvePos(Pos: Integer; var Ln: Integer; var Col: Integer)
    var
        Hi: Integer;
        Lo: Integer;
        Mid: Integer;
        Start: Integer;
    begin
        if (not HasLineMap) or (LineStarts.Count() = 0) or (Pos <= 0) then begin
            Ln := 0;
            Col := 0;
            exit;
        end;

        // largest index i where LineStarts[i] <= Pos
        Lo := 1;
        Hi := LineStarts.Count();
        while Lo < Hi do begin
            Mid := (Lo + Hi + 1) div 2;
            if LineStarts.Get(Mid) <= Pos then
                Lo := Mid
            else
                Hi := Mid - 1;
        end;

        Start := LineStarts.Get(Lo);
        Ln := Lo;
        Col := (Pos - Start) + 1;   // 1-based column
    end;

    // Drop every diagnostic after index N. M11 phase A per-PROCEDURE error isolation: a
    // harvested object is compiled as ONE unit, so without this one unsupported procedure would
    // poison every sibling of the same object. The binder snapshots Count(), binds one body,
    // and rolls the bag back when that body did not compile — the procedure is marked Blocked
    // instead, and only a call to IT reports the failure.
    procedure TruncateTo(N: Integer)
    var
        Idx: Integer;
    begin
        if N < 0 then
            N := 0;
        Idx := CodeText.Count();
        while Idx > N do begin
            CodeText.RemoveAt(Idx);
            SeverityOrd.RemoveAt(Idx);
            Message.RemoveAt(Idx);
            LineNo.RemoveAt(Idx);
            ColumnNo.RemoveAt(Idx);
            StartPos.RemoveAt(Idx);
            Length.RemoveAt(Idx);
            StageOrd.RemoveAt(Idx);
            Idx -= 1;
        end;
    end;

    // Turn every Error in the bag into a Warning. M11: a PARSE error inside a harvested object is
    // not fatal to the script — the parser resyncs at top level, so the declarations that did
    // parse are all in the tree and worth binding. Demoting lets the harvest continue while the
    // reader still sees which object had unreadable source.
    procedure DemoteErrorsToWarnings()
    var
        i: Integer;
    begin
        for i := 1 to SeverityOrd.Count() do
            if SeverityOrd.Get(i) = "ALI Severity"::Error.AsInteger() then
                SeverityOrd.Set(i, "ALI Severity"::Warning.AsInteger());
    end;

    // ===== Queries =====

    procedure Count(): Integer
    begin
        exit(CodeText.Count());
    end;

    procedure ErrorCount(): Integer
    var
        i: Integer;
        n: Integer;
    begin
        for i := 1 to SeverityOrd.Count() do
            if SeverityOrd.Get(i) = 2 then
                n += 1;
        exit(n);
    end;

    procedure WarningCount(): Integer
    var
        i: Integer;
        n: Integer;
    begin
        for i := 1 to SeverityOrd.Count() do
            if SeverityOrd.Get(i) = 1 then
                n += 1;
        exit(n);
    end;

    procedure HasErrors(): Boolean
    begin
        exit(ErrorCount() > 0);
    end;

    // ===== Enumeration (1-based index; typed getters, struct-of-arrays style) =====
    //
    // OUT OF RANGE RETURNS EMPTY, it never raises. AL evaluates arguments EAGERLY, so the
    // universal shape of a caller here is
    //
    //     Assert.IsTrue(Compile(...), StrSubstNo('should be clean: %1', Diags.GetMessage(1)));
    //
    // where the message argument is built BEFORE the condition is known — i.e. exactly when the
    // bag is empty because nothing went wrong. A raising Get() turns every such clean run into
    // "Un argument non valide a été transmis à une méthode de type de données « List »", which
    // reports as a failure of whatever was being asserted and hides the real (passing) result.
    local procedure InRange(Idx: Integer): Boolean
    begin
        exit((Idx >= 1) and (Idx <= CodeText.Count()));
    end;

    procedure GetCode(Idx: Integer): Text
    begin
        if not InRange(Idx) then
            exit('');
        exit(CodeText.Get(Idx));
    end;

    procedure GetSeverity(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(SeverityOrd.Get(Idx));
    end;

    procedure GetMessage(Idx: Integer): Text
    begin
        if not InRange(Idx) then
            exit('');
        exit(Message.Get(Idx));
    end;

    procedure GetLine(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(LineNo.Get(Idx));
    end;

    procedure GetColumn(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(ColumnNo.Get(Idx));
    end;

    procedure GetStartPos(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(StartPos.Get(Idx));
    end;

    procedure GetLength(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(Length.Get(Idx));
    end;

    procedure GetStage(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(StageOrd.Get(Idx));
    end;

    // ===== Rendering (§4.3 / §14 golden-text tests) =====

    // One line per diagnostic: "SEV(line,col) CODE: message" — stable golden shape.
    //
    // Verbose (LLM consumers) adds two context savers: a hint already printed for an earlier
    // diagnostic is not repeated, and only the first MaxVerboseErrors() errors are rendered —
    // past that point errors are mostly consequences of the first ones.
    procedure ToText(): Text
    var
        Shown: Boolean;
        ErrorsShown: Integer;
        Hidden: Integer;
        i: Integer;
        SeenHints: Dictionary of [Text, Boolean];
        Sb: TextBuilder;
    begin
        for i := 1 to Count() do begin
            Shown := true;
            if Verbose and (SeverityOrd.Get(i) = "ALI Severity"::Error.AsInteger()) then begin
                Shown := ErrorsShown < MaxVerboseErrors();
                if Shown then
                    ErrorsShown += 1
                else
                    Hidden += 1;
            end;
            if Shown then begin
                if Sb.Length() > 0 then
                    Sb.AppendLine();
                Sb.Append(RenderOne(i, SeenHints));
            end;
        end;
        if Hidden > 0 then begin
            Sb.AppendLine();
            Sb.Append(StrSubstNo('(+%1 more error(s) not shown: fix the ones above first, later errors are often consequences of them)', Hidden));
        end;
        exit(Sb.ToText());
    end;

    local procedure MaxVerboseErrors(): Integer
    begin
        exit(10);
    end;

    // One diagnostic as ToText renders it (verbose detail included), for callers that style or
    // route each diagnostic on its own (the ALI Script Editor Result pane).
    procedure GetText(Idx: Integer): Text
    var
        NoDedupe: Dictionary of [Text, Boolean];
    begin
        if not InRange(Idx) then
            exit('');
        exit(RenderOne(Idx, NoDedupe));
    end;

    local procedure RenderOne(Idx: Integer; var SeenHints: Dictionary of [Text, Boolean]): Text
    var
        Sb: TextBuilder;
    begin
        Sb.Append(SeverityLabel(SeverityOrd.Get(Idx)));
        Sb.Append('(');
        Sb.Append(Format(LineNo.Get(Idx)));
        Sb.Append(',');
        Sb.Append(Format(ColumnNo.Get(Idx)));
        Sb.Append(') ');
        if not HideCodes then begin
            Sb.Append(CodeText.Get(Idx));
            Sb.Append(': ');
        end;
        Sb.Append(Message.Get(Idx));
        if Verbose then
            AppendVerbose(Sb, Idx, SeenHints);
        exit(Sb.ToText());
    end;

    // Serializes the bag for the code editor add-in: [{line, col, len, sev, msg}, ...].
    procedure ToJson(): Text
    var
        i: Integer;
        Arr: JsonArray;
        Obj: JsonObject;
        JsonText: Text;
    begin
        for i := 1 to Count() do begin
            Clear(Obj);
            Obj.Add('line', GetLine(i));
            Obj.Add('col', GetColumn(i));
            Obj.Add('len', GetLength(i));
            Obj.Add('sev', GetSeverity(i));
            Obj.Add('msg', StrSubstNo('%1: %2', GetCode(i), GetMessage(i)));
            Arr.Add(Obj);
        end;
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // Under the diagnostic line, quote the source line, point at the column with a caret,
    // and add a plain-language hint for the error-code family when we have one.
    // SeenHints: a hint already printed by this rendering pass is not repeated (the same mistake
    // made five times costs one explanation, not five).
    local procedure AppendVerbose(var Sb: TextBuilder; i: Integer; var SeenHints: Dictionary of [Text, Boolean])
    var
        Col: Integer;
        Ln: Integer;
        Hint: Text;
        SrcLine: Text;
    begin
        Ln := LineNo.Get(i);
        Col := ColumnNo.Get(i);
        if HasSource and (Ln >= 1) and (Ln <= SourceLines.Count()) then begin
            SrcLine := SourceLines.Get(Ln);
            Sb.AppendLine();
            Sb.Append('   | ');
            Sb.Append(SrcLine);
            if Col >= 1 then begin
                Sb.AppendLine();
                Sb.Append('   | ');
                Sb.Append(CaretPad(SrcLine, Col));
                Sb.Append('^');
            end;
        end;
        Hint := SourceHintFor(CodeText.Get(i), Message.Get(i), Ln, SrcLine, Col);
        if (Hint <> '') and not SeenHints.ContainsKey(Hint) then begin
            SeenHints.Add(Hint, true);
            Sb.AppendLine();
            Sb.Append('   hint: ');
            Sb.Append(Hint);
        end;
    end;

    // Mirror the source line's whitespace up to Col-1 (tabs stay tabs) so the caret lands
    // under the offending column regardless of the reader's tab width.
    local procedure CaretPad(SrcLine: Text; Col: Integer): Text
    var
        i: Integer;
        TabTxt: Text[1];
        Sb: TextBuilder;
    begin
        TabTxt := ' ';
        TabTxt[1] := 9;
        for i := 1 to Col - 1 do
            if (i <= StrLen(SrcLine)) and (SrcLine[i] = 9) then
                Sb.Append(TabTxt)
            else
                Sb.Append(' ');
        exit(Sb.ToText());
    end;

    // Hints that need the offending source line: syntax borrowed from C#/JS/Python, the most
    // common slips of models that know little AL. Falls back to the message-based HintFor.
    local procedure SourceHintFor(Code: Text; Msg: Text; Ln: Integer; SrcLine: Text; Col: Integer): Text
    var
        PrevLine: Text;
        UpperLine: Text;
    begin
        if (SrcLine <> '') and ((Code = 'AL0132') or (Code = 'AL0118')) then begin
            if (Col >= 1) and (Col <= StrLen(SrcLine)) then
                if SrcLine[Col] = 34 then   // '"'
                    exit('Double quotes delimit identifiers (field/variable names such as Rec."No."). Text literals use single quotes: ''abc''.');
            if SrcLine.Contains('==') or SrcLine.Contains('!=') or SrcLine.Contains('&&') or SrcLine.Contains('||') then
                exit('AL operators are: = (compare), := (assign), <> (not equal), and, or, not.');
            UpperLine := UpperCase(SrcLine.Trim());
            PrevLine := GetSourceLine(Ln - 1).Trim();
            if UpperLine.Contains('; ELSE') or (UpperLine.StartsWith('ELSE') and PrevLine.EndsWith(';')) then
                exit(ElseSemicolonHintTxt());
        end;
        exit(HintFor(Code, Msg));
    end;

    // One-line explainer for a diagnostic. Keyed on code AND message: ALI codes are shared by
    // unrelated conditions (ALI984 = collection declaration syntax, unknown enum, mismatched
    // assignment...), so a code alone would give the wrong advice. Code '' = a RUNTIME error
    // text (the engine passes the whole message), matched on its fragments only.
    procedure HintFor(Code: Text; Msg: Text): Text
    begin
        if Code = '' then
            exit(RuntimeHintFor(Msg));
        // The binder appended close names: a typo, whatever the code says (even "not supported").
        if Msg.Contains(' Did you mean ') then
            exit('The name is misspelled: use one of the suggested names exactly.');
        case Code of
            'ALI932':
                if Msg.StartsWith('Format argument 2') then
                    exit('AL format strings are not .NET/Excel patterns (no #, 0.00). Pass 0 as Length: Format(Amt, 0, ''<Precision,2:2><Standard Format,0>'') -> 2 decimals + thousands separator (user locale) ; Format(Amt, 0, ''<Precision,2:2><Integer><Decimals>'') -> 1234.50 ; Format(D, 0, ''<Day,2>.<Month,2>.<Year4>'') -> 05.03.2026 ; Format(X, 0, 9) -> XML/invariant format.');
            'ALI903':   // shared with the lexer's unterminated quoted identifier
                if Msg.Contains('else') then
                    exit(ElseSemicolonHintTxt());
            'ALI984':
                begin
                    if Msg.StartsWith('List') or Msg.StartsWith('AddRange') then
                        exit(ListHintTxt());
                    if Msg.StartsWith('Dictionary') then
                        exit(DictHintTxt());
                    if Msg.Contains('Enum') or Msg.Contains('does not exist') then
                        exit('Use the exact enum name and value: Enum::"Sales Document Type"::Order, or Rec.Field::Value for an option/enum field.');
                end;
            'ALI958':
                exit('Declare as: MyArr: array[10] of Integer; indexes run from 1 to 10 (MyArr[1]).');
            'ALI907':
                exit('foreach syntax: foreach Item in MyList do ... ; for a Dictionary: foreach K in MyDict.Keys do ... (loop variable of the element/key type).');
            'ALI920':
                exit('Only arrays and Text can be indexed with []. Use MyList.Get(i) for a List (1-based) and MyDict.Get(K) for a Dictionary.');
            'ALI925':
                exit('AL type names: String -> Text, int/long -> Integer/BigInteger, bool -> Boolean, double/float/decimal -> Decimal, var/object -> Variant, DateTime/Date/Time as is.');
            'ALI959':
                exit('Use the object name exactly as declared, in double quotes when it contains spaces or dots: Rec: Record "Sales Header";');
            'ALI924':
                exit('This type is valid AL but the interpreter cannot represent it. Use only supported variable types (Integer, BigInteger, Decimal, Boolean, Text, Code, Label, Date, Time, DateTime, Duration, Guid, Record, List, Dictionary, array, Json*, TextBuilder).');
            'ALI916':
                exit('The method exists and is supported, but not with this number of arguments. Check the AL signature and pass the right argument count.');
            'ALI961':
                if not IsUnsupportedMsg(Msg) then
                    exit('Check the exact method name (spelling, plural "s"). A procedure of a table or codeunit is only callable when its source is available to the interpreter.');
            'ALI1004':
                exit('FlowFields are not loaded with the record: call Rec.SetAutoCalcFields("Field") before Get/FindSet, or Rec.CalcFields("Field") after it.');
            'AL0118':
                exit('This name is not declared here: declare the variable in a var section or fix the spelling. If it is an AL system function, the interpreter does not implement it — use a supported function instead.');
            'AL0132':
                begin
                    if Msg.EndsWith(' expected') then
                        exit('A required token is missing at this position. Check for a missing '';'', ''then'', ''do'', ''begin''/''end'' or closing parenthesis on this or the previous line.');
                    if Msg.Contains('does not contain a definition') then
                        exit('This type has no method with that name in the interpreter. Either the spelling is wrong, or the method is not supported — use a supported method.');
                    if Msg.Contains('is not a field') then
                        exit('Use the exact field name as declared in the table (case-insensitive, double quotes when it contains spaces or dots: Rec."No."). Do not guess: look the field up in the table metadata.');
                end;
            'ALI901':
                exit('Nesting is too deep for the interpreter. Split the expression/statement into smaller ones using intermediate variables.');
        end;
        if IsUnsupportedMsg(Msg) then
            exit('This construct is valid AL but NOT implemented by the interpreter. Rewrite this instruction with supported functions/methods, or compute the value another way.');
        exit('');
    end;

    local procedure RuntimeHintFor(Msg: Text): Text
    var
        LowerMsg: Text;
    begin
        LowerMsg := LowerCase(Msg);
        if LowerMsg.Contains('jsonarray') and LowerMsg.Contains('out of range') then
            exit('JsonArray is the only 0-based collection: valid indexes are 0 .. Count() - 1.');
        if LowerMsg.Contains('array index') or LowerMsg.Contains('list index') or LowerMsg.Contains('text index') then
            exit('AL arrays, Lists and Text are 1-based: first element is MyArr[1] / MyList.Get(1) / MyText[1]. Only JsonArray is 0-based.');
        if LowerMsg.Contains('dictionary') and (LowerMsg.Contains('key') or LowerMsg.Contains('clé')) then
            exit('Test the key first: if MyDict.ContainsKey(K) then ... , or use if MyDict.Get(K, Value) then ... which returns false instead of failing.');
        exit('');
    end;

    local procedure IsUnsupportedMsg(Msg: Text): Boolean
    begin
        exit(Msg.Contains('not supported') or Msg.Contains('not implemented') or Msg.Contains('in this milestone'));
    end;

    // One text for both routes (ALI903 and the '; else' source pattern) so the dedupe merges them.
    local procedure ElseSemicolonHintTxt(): Text
    begin
        exit('The statement before else must NOT end with '';'' (the '';'' closes the if, leaving else orphaned). Write: if <condition> then <statement> else <statement>; — with begin/end blocks: if <condition> then begin ... end else begin ... end;');
    end;

    local procedure ListHintTxt(): Text
    begin
        exit('Declare as: MyList: List of [Text]; use MyList.Add(X), MyList.Get(1) (1-based), MyList.Count(), foreach Item in MyList do.');
    end;

    local procedure DictHintTxt(): Text
    begin
        exit('Declare as: MyDict: Dictionary of [Text, Integer]; use MyDict.Add(K, V), MyDict.Set(K, V), MyDict.ContainsKey(K), MyDict.Get(K), foreach K in MyDict.Keys do.');
    end;

    // ===== "Did you mean" (error path only) =====

    // ' Did you mean ''A'' or ''B''?' for the closest Candidates to Name, or '' when none is close.
    // Leading space included so callers can append it straight to a message. Match order: equal
    // once case, spaces, dots and quotes are ignored; then one name containing the other (the
    // "SetAutoCalcField" / "Account No." slips); then a small edit distance.
    // ponytail: O(candidates * len^2) Levenshtein, fine on the error path for a few thousand names.
    procedure DidYouMean(Name: Text; Candidates: List of [Text]): Text
    var
        Best: array[3] of Text;
        BestScore: array[3] of Integer;
        Cand: Text;
        NormCand: Text;
        NormName: Text;
        Dist: Integer;
        Found: Integer;
        i: Integer;
        Limit: Integer;
        Score: Integer;
        Sb: TextBuilder;
    begin
        NormName := NormalizeName(Name);
        if NormName = '' then
            exit('');
        Limit := StrLen(NormName) div 3;
        if Limit < 1 then
            Limit := 1;
        if Limit > 3 then
            Limit := 3;
        foreach Cand in Candidates do begin
            NormCand := NormalizeName(Cand);
            Score := -1;
            if NormCand = NormName then
                Score := 0
            else
                if (StrLen(NormName) >= 3) and (StrLen(NormCand) >= 3) and (NormCand.Contains(NormName) or NormName.Contains(NormCand)) then
                    Score := 1 + Abs(StrLen(NormCand) - StrLen(NormName)) div 4
                else
                    if Abs(StrLen(NormCand) - StrLen(NormName)) <= Limit then begin
                        Dist := Levenshtein(NormName, NormCand);
                        if Dist <= Limit then
                            Score := 1 + Dist;
                    end;
            if Score >= 0 then
                InsertBest(Best, BestScore, Cand, Score);
        end;
        for i := 1 to 3 do
            if Best[i] <> '' then begin
                Found += 1;
                if Found = 1 then
                    Sb.Append(' Did you mean ')
                else
                    Sb.Append(' or ');
                Sb.Append('''' + Best[i] + '''');
            end;
        if Found = 0 then
            exit('');
        Sb.Append('?');
        exit(Sb.ToText());
    end;

    // Keep the 3 lowest scores, ties in candidate order, no duplicate names.
    local procedure InsertBest(var Best: array[3] of Text; var BestScore: array[3] of Integer; Cand: Text; Score: Integer)
    var
        i: Integer;
        Slot: Integer;
    begin
        for i := 1 to 3 do
            if Best[i] = Cand then
                exit;
        i := 1;
        while (Slot = 0) and (i <= 3) do begin
            if (Best[i] = '') or (Score < BestScore[i]) then
                Slot := i;
            i += 1;
        end;
        if Slot = 0 then
            exit;
        for i := 3 downto Slot + 1 do begin
            Best[i] := Best[i - 1];
            BestScore[i] := BestScore[i - 1];
        end;
        Best[Slot] := Cand;
        BestScore[Slot] := Score;
    end;

    local procedure NormalizeName(Name: Text): Text
    begin
        exit(DelChr(UpperCase(Name), '=', ' ."_'));
    end;

    local procedure Levenshtein(A: Text; B: Text): Integer
    var
        Cur: array[251] of Integer;
        Prev: array[251] of Integer;
        Cost: Integer;
        i: Integer;
        j: Integer;
        LenA: Integer;
        LenB: Integer;
    begin
        LenA := StrLen(A);
        LenB := StrLen(B);
        if LenA > 250 then
            LenA := 250;
        if LenB > 250 then
            LenB := 250;
        // Prev[j + 1] = distance between A[1..i-1] and B[1..j] (AL arrays are 1-based).
        for j := 0 to LenB do
            Prev[j + 1] := j;
        for i := 1 to LenA do begin
            Cur[1] := i;
            for j := 1 to LenB do begin
                Cost := 1;
                if A[i] = B[j] then
                    Cost := 0;
                Cur[j + 1] := Min3(Prev[j + 1] + 1, Cur[j] + 1, Prev[j] + Cost);
            end;
            CopyArray(Prev, Cur, 1);
        end;
        exit(Prev[LenB + 1]);
    end;

    local procedure Min3(A: Integer; B: Integer; C: Integer): Integer
    begin
        if B < A then
            A := B;
        if C < A then
            A := C;
        exit(A);
    end;

    local procedure SeverityLabel(Sev: Integer): Text
    begin
        case Sev of
            2:
                exit('error');
            1:
                exit('warning');
            0:
                exit('info');
            else
                exit('?');
        end;
    end;

    // ===== Lifecycle (§15 pitfall 19 — every store needs Reset) =====

    procedure Reset()
    begin
        ClearAll();
    end;
}
