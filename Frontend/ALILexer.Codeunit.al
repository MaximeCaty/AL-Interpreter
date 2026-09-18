// ALI Lexer — hand-written single-pass scanner over the source Text (§5.1).
//
// M1 SPIKE — Text `Source[i]` O(1) indexing (§5.1, §17):
//   AL `Text[i]` indexing on runtime 12 is a direct char fetch (Char = index into the
//   underlying string), NOT a CopyStr slice — it is O(1). Confirmed by design: the
//   platform exposes Text as an indexable Char sequence; `Source[i]` compiles to a single
//   character read with bounds check, no allocation. We therefore scan by direct index
//   `GetCh(i)` and NEVER build per-char substrings (§5.1 pitfall). The only substrings
//   built are: literal values (once per literal) and the identifier buffer (once per word).
//   If a future runtime regresses this to O(n), stage Source into `List of [Char]` in
//   Tokenize() up front — the rest of the scanner is index-based and unaffected.
//
// Contextual keywords (§5.1): every word lexes as a keyword-kind when it matches the
// table, else IdentifierToken. The PARSER decides where a keyword token may still act as
// an identifier (`IsIdentifierLike`). The lexer does no context resolution.
//
// No state survives between Tokenize() calls; the keyword map is built lazily once.
codeunit 51020 "ALI Lexer"
{
    Access = Public;
    SingleInstance = false;

    var
        Emitting: Boolean;          // cached top-of-stack "bit 1", tested per directive
        KeywordsBuilt: Boolean;
        Symbols: Dictionary of [Text, Boolean];

        Keywords: Dictionary of [Text, Integer];  // UPPERCASE spelling -> TokenKind ordinal
        Len: Integer;               // char count of Src
        // Pending trivia flags for the NEXT token (leading-comment / precedes-newline).
        PendingTrivia: Integer;
        Pos: Integer;               // 1-based cursor: next char to read
        // One entry per open #if, innermost last. Bit 1 = this branch emits, bit 2 = some branch
        // of this #if already emitted, bit 4 = the enclosing level emits.
        CondStack: List of [Integer];
        LineStarts: List of [Integer];  // 1-based offset where each line begins
        // Conditional compilation (§5.1). BaseSymbols = the project-level set handed in by the
        // caller and never mutated; Symbols = that set plus this file's #define/#undef.
        BaseSymbols: List of [Text];
        // Source scanning state (all reset per Tokenize call).
        Src: Text;

    // ===== Public entry (§5.1) =====

    // Scan Source into Tokens; append diagnostics to Diags; hand line map to Diags.
    procedure Tokenize(Source: Text; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        More: Boolean;
        Ch: Integer;
        Nx: Integer;
    begin
        // InitScan(Source);
        Src := Source;
        Len := StrLen(Src);
        Pos := 1;
        PendingTrivia := 0;
        Clear(LineStarts);
        LineStarts.Add(1); // line 1 starts at offset 1
        ResetConditionals();

        if not KeywordsBuilt then
            BuildKeywords();

        while Pos <= Len do begin
            // ===== Trivia: whitespace, newlines, comments, preprocessor (§5.1) =====
            // Inlined
            // SkipTrivia(Diags);
            More := true;
            while More do begin
                More := false;
                if Pos > Len then                        // trivia ran to EOF (e.g. a trailing directive line)
                    break;
                Ch := Src[Pos]; // PeekCh(0);
                case Ch of
                    13, 10:  // CR / LF
                        begin
                            HandleNewline(Ch);
                            PendingTrivia := SetBit(PendingTrivia, 2/*TriviaBit_PrecedesNewline()*/);
                            More := true;
                        end;
                    32, 9:  // space / tab
                        begin
                            Pos += 1;
                            More := true;
                        end;
                    35:               // '#' preprocessor directive (§5.1)
                        begin
                            ScanPreprocessor(Diags);
                            More := true;
                        end;
                    47:               // '/' — maybe a comment
                        begin
                            Nx := PeekCh(1);
                            case Nx of
                                47:          // '//'  line comment
                                    begin
                                        ScanLineComment();
                                        PendingTrivia := SetBit(PendingTrivia, 1/*TriviaBit_LeadingComment()*/);
                                        More := true;
                                    end;
                                42:          // '/*'  block comment
                                    begin
                                        ScanBlockComment(Diags);
                                        PendingTrivia := SetBit(PendingTrivia, 1/*TriviaBit_LeadingComment()*/);
                                        More := true;
                                    end;
                                else
                                    More := false;  // real '/' operator — stop trivia
                            end;
                        end;
                    else
                        More := false;
                end;
            end;

            if Pos > Len then
                break;

            Ch := Src[Pos]; // PeekCh(0);

            case Ch of
                // letter or underscore (AL identifiers; quoted handled separately). Letter test spelled
                // out rather than delegating to IsLetter: these run per source character, and one AL
                // call costs ~450ns against the handful of integer compares it wraps.
                65 .. 90,
                97 .. 122,
                127 .. 1114111, // > 127, up to utf8 max char
                95:
                    ScanWord(Tokens);

                34: // '"'  quoted identifier
                    ScanQuotedIdent(Tokens, Diags);

                48 .. 57: // '0'..'9'
                    ScanNumericOrDate(Tokens, Diags);

                39:  // '\''  string literal
                    ScanString(Tokens, Diags);

                else
                    ScanOperatorOrBad(Tokens, Diags);
            end;
        end;

        if CondStack.Count() > 0 then
            Diags.AddError(Code_UnterminatedDirective(), StrSubstNo('%1 unterminated #if directive(s) — #endif missing', CondStack.Count()), Len, 0);

        // Terminal EOF token so the parser always has a stopping anchor.
        AddTok(Tokens, "ALI TokenKind"::EndOfFileToken, Pos, 0, 0);

        // Line map -> diag bag (§4.3): only the lexer tracks lines.
        Diags.SetLineStarts(LineStarts);
    end;

    // Line-start offsets for whoever else needs them (§5.1 GetLineStarts).
    procedure GetLineStarts(): List of [Integer]
    begin
        exit(LineStarts);
    end;
    // ===== Scan lifecycle =====


    // ===== Char access (all O(1) direct indexing, §5.1 spike) =====

    // Char code at 1-based Pos+Offset, or 0 past end. 0 is never a legal source char here.
    local procedure PeekCh(Offset: Integer): Integer
    var
        I: Integer;
    begin
        I := Pos + Offset;
        if (I < 1) or (I > Len) then
            exit(0);
        exit(Src[I]);
    end;

    // Advance() was `Pos += 1` behind a procedure call, invoked once per source character —
    // ~450ns of AL call overhead to perform an increment. Spelled inline at all 32 sites.

    // Record a newline; handle CRLF as one line break. Advances past the terminator(s).
    local procedure HandleNewline(Ch: Integer)
    begin
        if Ch = 13 then begin
            Pos += 1;
            if PeekCh(0) = 10 then      // CRLF
                Pos += 1;
        end else
            Pos += 1;                  // bare LF
        LineStarts.Add(Pos);            // next line starts here
    end;

    local procedure ScanLineComment()
    begin
        // consume until newline (not inclusive — HandleNewline records the line)
        while (Pos <= Len) and (PeekCh(0) <> 13) and (PeekCh(0) <> 10) do
            Pos += 1;
    end;

    // Non-nested block comment (§5.1). Unterminated -> diagnostic.
    local procedure ScanBlockComment(var Diags: Codeunit "ALI Diag Bag")
    var
        StartPos: Integer;
    begin
        StartPos := Pos;
        Pos += 1;  // '/'
        Pos += 1;  // '*'
        while Pos <= Len do begin
            if (Src[Pos] = 42) and (PeekCh(1) = 47) then begin  // '*/'
                Pos += 1;
                Pos += 1;
                exit;
            end;
            if (Src[Pos] = 13) or (Src[Pos] = 10) then
                HandleNewline(Src[Pos])
            else
                Pos += 1;
        end;
        Diags.AddError(Code_UnterminatedComment(), 'Unterminated block comment', StartPos, Pos - StartPos);
    end;

    // ===== Preprocessor / conditional compilation (§5.1) =====

    // Project-level symbols (app.json `preprocessorSymbols`) for the extension this source comes
    // from. Set once before Tokenize; #define / #undef inside the file are applied on top and do
    // not leak into the next Tokenize call.
    procedure SetDefinedSymbols(DefinedSymbols: List of [Text])
    begin
        BaseSymbols := DefinedSymbols;
    end;

    local procedure ResetConditionals()
    var
        Sym: Text;
    begin
        Clear(CondStack);
        Clear(Symbols);
        foreach Sym in BaseSymbols do
            Symbols.Set(UpperCase(Sym.Trim()), true);
        Emitting := true;
    end;

    // One directive line. Pos is on '#'; on return Pos is at the line terminator (or EOF), and
    // when the branch we just entered is inactive the source up to the next directive line has
    // been consumed as trivia.
    local procedure ScanPreprocessor(var Diags: Codeunit "ALI Diag Bag")
    var
        Active: Boolean;
        ParentActive: Boolean;
        Taken: Boolean;
        Level: Integer;
        StartPos: Integer;
        Argument: Text;
        Directive: Text;
    begin
        StartPos := Pos;
        Pos += 1;                                        // '#'
        while (Pos <= Len) and (Src[Pos] = 32) do        // '# if' is legal
            Pos += 1;
        Directive := UpperCase(ReadWord());
        Argument := ReadRestOfLine();

        case Directive of
            'IF':
                begin
                    ParentActive := Emitting;
                    Active := false;
                    // Guarded, not `ParentActive and Eval(...)`: AL evaluates both operands, and a
                    // condition inside an excluded branch must not report diagnostics.
                    if ParentActive then
                        Active := EvalCondition(Argument, Diags, StartPos);
                    CondStack.Add(EncodeLevel(Active, Active, ParentActive));
                end;
            'ELIF', 'ELSEIF':
                begin
                    if not ReopenBranch(Level, Diags, StartPos, Directive) then
                        exit;
                    DecodeLevel(Level, Active, Taken, ParentActive);
                    if Taken or not ParentActive then
                        Active := false
                    else begin
                        Active := EvalCondition(Argument, Diags, StartPos);
                        Taken := Active;
                    end;
                    CondStack.Set(CondStack.Count(), EncodeLevel(Active, Taken, ParentActive));
                end;
            'ELSE':
                begin
                    if not ReopenBranch(Level, Diags, StartPos, Directive) then
                        exit;
                    DecodeLevel(Level, Active, Taken, ParentActive);
                    Active := ParentActive and not Taken;
                    CondStack.Set(CondStack.Count(), EncodeLevel(Active, true, ParentActive));
                end;
            'ENDIF':
                if CondStack.Count() = 0 then
                    Diags.AddError(Code_UnterminatedDirective(), '#endif without #if', StartPos, Pos - StartPos)
                else
                    CondStack.RemoveAt(CondStack.Count());
            'DEFINE':
                if Emitting and (Argument <> '') then
                    Symbols.Set(UpperCase(Argument), true);
            'UNDEF':
                if Emitting and (Argument <> '') then
                    if Symbols.ContainsKey(UpperCase(Argument)) then
                        Symbols.Remove(UpperCase(Argument));
            'PRAGMA', 'REGION', 'ENDREGION':
                ;                                        // no effect on the token stream
            else
                Diags.AddWarning(Code_PreprocessorSkipped(), StrSubstNo('Unknown preprocessor directive ''#%1'' ignored', LowerCase(Directive)), StartPos, Pos - StartPos);
        end;

        RefreshEmitting();
        if not Emitting then
            SkipInactiveLines();
    end;

    // Load the innermost open #if for #elif / #else. False (with a diagnostic) when there is none.
    local procedure ReopenBranch(var Level: Integer; var Diags: Codeunit "ALI Diag Bag"; StartPos: Integer; Directive: Text): Boolean
    begin
        if CondStack.Count() = 0 then begin
            Diags.AddError(Code_UnterminatedDirective(), StrSubstNo('#%1 without #if', LowerCase(Directive)), StartPos, Pos - StartPos);
            exit(false);
        end;
        Level := CondStack.Get(CondStack.Count());
        exit(true);
    end;

    local procedure RefreshEmitting()
    begin
        if CondStack.Count() = 0 then
            Emitting := true
        else
            Emitting := (CondStack.Get(CondStack.Count()) mod 2) = 1;
    end;

    // Consume the excluded branch. Lines are swallowed whole — the disabled text is never lexed,
    // so it may hold anything — up to the next line whose first non-blank character is '#', which
    // the trivia loop then hands back to ScanPreprocessor.
    local procedure SkipInactiveLines()
    var
        Probe: Integer;
    begin
        while Pos <= Len do begin
            while (Pos <= Len) and (Src[Pos] <> 13) and (Src[Pos] <> 10) do
                Pos += 1;
            if Pos > Len then
                exit;
            HandleNewline(Src[Pos]);
            Probe := Pos;
            while (Probe <= Len) and ((Src[Probe] = 32) or (Src[Probe] = 9)) do
                Probe += 1;
            if Probe <= Len then
                if Src[Probe] = 35 then begin            // '#'
                    Pos := Probe;
                    exit;
                end;
        end;
    end;

    // ===== Directive condition: SYMBOL, not, and, or, parentheses ('not' > 'and' > 'or') =====

    local procedure EvalCondition(Argument: Text; var Diags: Codeunit "ALI Diag Bag"; StartPos: Integer): Boolean
    var
        Result: Boolean;
        Idx: Integer;
        Toks: List of [Text];
    begin
        SplitCondition(Argument, Toks);
        if Toks.Count() = 0 then begin
            Diags.AddError(Code_BadDirectiveCondition(), 'Missing condition after #if', StartPos, Pos - StartPos);
            exit(false);
        end;
        Idx := 1;
        Result := EvalOr(Toks, Idx);
        if Idx <= Toks.Count() then
            Diags.AddError(Code_BadDirectiveCondition(), StrSubstNo('Unexpected ''%1'' in preprocessor condition', Toks.Get(Idx)), StartPos, Pos - StartPos);
        exit(Result);
    end;

    // Identifiers, parentheses; everything else is separated on whitespace.
    local procedure SplitCondition(Argument: Text; var Toks: List of [Text])
    var
        Ch: Integer;
        I: Integer;
        Word: Text;
    begin
        for I := 1 to StrLen(Argument) do begin
            Ch := Argument[I];
            case Ch of
                32, 9:
                    begin
                        if Word <> '' then
                            Toks.Add(Word);
                        Word := '';
                    end;
                40, 41:  // '(' ')'
                    begin
                        if Word <> '' then
                            Toks.Add(Word);
                        Word := '';
                        Toks.Add(Format(Argument[I]));
                    end;
                else
                    Word += Format(Argument[I]);
            end;
        end;
        if Word <> '' then
            Toks.Add(Word);
    end;

    // Bounds-safe lookahead into the condition token list.
    //
    // AL evaluates BOTH operands of `and` — there is no short circuit — so the natural spelling
    //     while (Idx <= Toks.Count()) and (UpperCase(Toks.Get(Idx)) = 'AND') do
    // still calls Get() one past the end and raises "Un argument non valide a été transmis à une
    // méthode de type de données « List »" instead of ending the loop. That fires on EVERY well
    // formed `#if SYMBOL`, because the operand loop always probes once past the last token.
    local procedure PeekCondTok(var Toks: List of [Text]; Idx: Integer): Text
    begin
        if (Idx < 1) or (Idx > Toks.Count()) then
            exit('');
        exit(Toks.Get(Idx));
    end;

    local procedure EvalOr(var Toks: List of [Text]; var Idx: Integer): Boolean
    var
        Result: Boolean;
    begin
        Result := EvalAnd(Toks, Idx);
        while UpperCase(PeekCondTok(Toks, Idx)) = 'OR' do begin
            Idx += 1;
            // No short circuit: the right side must be consumed even when the answer is settled.
            Result := EvalAnd(Toks, Idx) or Result;
        end;
        exit(Result);
    end;

    local procedure EvalAnd(var Toks: List of [Text]; var Idx: Integer): Boolean
    var
        Result: Boolean;
    begin
        Result := EvalUnary(Toks, Idx);
        while UpperCase(PeekCondTok(Toks, Idx)) = 'AND' do begin
            Idx += 1;
            Result := EvalUnary(Toks, Idx) and Result;
        end;
        exit(Result);
    end;

    local procedure EvalUnary(var Toks: List of [Text]; var Idx: Integer): Boolean
    var
        Result: Boolean;
        Tok: Text;
    begin
        if Idx > Toks.Count() then
            exit(false);
        Tok := Toks.Get(Idx);
        case UpperCase(Tok) of
            'NOT':
                begin
                    Idx += 1;
                    exit(not EvalUnary(Toks, Idx));
                end;
            '(':
                begin
                    Idx += 1;
                    Result := EvalOr(Toks, Idx);
                    if PeekCondTok(Toks, Idx) = ')' then     // same eager-`and` trap
                        Idx += 1;
                    exit(Result);
                end;
            'TRUE':
                begin
                    Idx += 1;
                    exit(true);
                end;
            'FALSE':
                begin
                    Idx += 1;
                    exit(false);
                end;
        end;
        Idx += 1;
        exit(Symbols.ContainsKey(UpperCase(Tok)));
    end;

    // ===== Directive line reading =====

    local procedure ReadWord(): Text
    var
        Ch: Integer;
        Start: Integer;
    begin
        Start := Pos;
        while Pos <= Len do begin
            Ch := Src[Pos];
            if ((Ch >= 65) and (Ch <= 90)) or ((Ch >= 97) and (Ch <= 122)) or (Ch = 95) then
                Pos += 1
            else
                break;
        end;
        exit(CopyStr(Src, Start, Pos - Start));
    end;

    // Rest of the directive line, trimmed, '//' comment tail dropped. Pos lands on the terminator.
    local procedure ReadRestOfLine() Rest: Text
    var
        CommentAt: Integer;
        Start: Integer;
    begin
        Start := Pos;
        while (Pos <= Len) and (Src[Pos] <> 13) and (Src[Pos] <> 10) do
            Pos += 1;
        Rest := CopyStr(Src, Start, Pos - Start);
        CommentAt := StrPos(Rest, '//');
        if CommentAt > 0 then
            Rest := CopyStr(Rest, 1, CommentAt - 1);
        exit(Rest.Trim());
    end;

    // Level layout: bit 1 = this branch emits, bit 2 = a branch of this #if already emitted,
    // bit 4 = the enclosing level emits (what #elif / #else fall back to).
    local procedure EncodeLevel(Active: Boolean; Taken: Boolean; ParentActive: Boolean): Integer
    var
        Level: Integer;
    begin
        if Active then
            Level += 1;
        if Taken then
            Level += 2;
        if ParentActive then
            Level += 4;
        exit(Level);
    end;

    local procedure DecodeLevel(Level: Integer; var Active: Boolean; var Taken: Boolean; var ParentActive: Boolean)
    begin
        Active := (Level mod 2) = 1;
        Taken := ((Level div 2) mod 2) = 1;
        ParentActive := (Level div 4) = 1;
    end;

    // ===== Identifiers & keywords (§5.1) =====

    // A word: identifier or keyword. Uppercase once for the intern/keyword lookup.
    local procedure ScanWord(var Tokens: Codeunit "ALI Token Table")
    var
        Ch: Integer;
        Col: Integer;
        Hi: Integer;
        IdIdx: Integer;
        Kind: Integer;
        Ln: Integer;
        Lo: Integer;
        Mid: Integer;
        StartPos: Integer;
        Spelling: Text;
    begin
        StartPos := Pos;
        // Is Ident Part At inlined. It was one call per identifier CHARACTER — the single hottest
        // call in the lexer once M11 started feeding it whole harvested objects rather than
        // 20-line scripts. The bounds test stays a separate statement because AL evaluates `and`
        // EAGERLY: `(Pos <= Len) and (Src[Pos] ...)` still indexes Src when Pos > Len.
        while Pos <= Len do begin
            Ch := Src[Pos];
            if ((Ch >= 65) and (Ch <= 90)) or ((Ch >= 97) and (Ch <= 122)) or (Ch > 127) or
               ((Ch >= 48) and (Ch <= 57)) or (Ch = 95) then
                Pos += 1
            else
                break;
        end;
        Spelling := CopyStr(Src, StartPos, Pos - StartPos);

        if Keywords.Get(UpperCase(Spelling), Kind) then begin
            // Inline of :
            //AddTok(Tokens, Kind, StartPos, Pos - StartPos, 0);
            //// LineColOf(StartPos, Ln, Col);
            Lo := 1;
            Hi := LineStarts.Count();
            while Lo < Hi do begin
                Mid := (Lo + Hi + 1) div 2;
                if LineStarts.Get(Mid) <= StartPos then
                    Lo := Mid
                else
                    Hi := Mid - 1;
            end;
            Ln := Lo;
            Col := (StartPos - LineStarts.Get(Lo)) + 1;
            Tokens.AddToken(Kind, StartPos, Pos - StartPos, Lo, Col, 0, PendingTrivia);
            PendingTrivia := 0;
        end else begin
            IdIdx := Tokens.InternIdentifier(Spelling);
            // Inline of :
            //AddTok(Tokens, "ALI TokenKind"::IdentifierToken, StartPos, Pos - StartPos, IdIdx);
            //// LineColOf(StartPos, Ln, Col);
            Lo := 1;
            Hi := LineStarts.Count();
            while Lo < Hi do begin
                Mid := (Lo + Hi + 1) div 2;
                if LineStarts.Get(Mid) <= StartPos then
                    Lo := Mid
                else
                    Hi := Mid - 1;
            end;
            Ln := Lo;
            Col := (StartPos - LineStarts.Get(Lo)) + 1;
            Tokens.AddToken("ALI TokenKind"::IdentifierToken, StartPos, Pos - StartPos, Ln, Col, IdIdx, PendingTrivia);
            PendingTrivia := 0;
        end;
    end;

    // Quoted identifier "Some ""Name""" with doubled-quote escape (§5.1). Always an
    // IdentifierToken (never a keyword). Unterminated -> diagnostic.
    // SPAN-then-slice, not append-per-character. The body used to run CharToText + TextBuilder
    // .Append for every character of every quoted name — and AL object source is dense with them
    // (`Record "BAS Document Grouping Header"`). Scanning to the closing quote first lets the
    // common case finish in ONE CopyStr; only a literal that actually contains a doubled quote
    // pays anything extra, and it pays one Replace rather than N appends.
    local procedure ScanQuotedIdent(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        HasEscape: Boolean;
        NextIsQuote: Boolean;
        Ch: Integer;
        ContentStart: Integer;
        IdIdx: Integer;
        StartPos: Integer;
        Spelling: Text;
    begin
        StartPos := Pos;
        Pos += 1;  // opening '"'
        ContentStart := Pos;
        while Pos <= Len do begin
            Ch := Src[Pos];
            if Ch = 34 then begin               // '"'
                // Nested, not `and`: AL evaluates both operands, so Src[Pos + 1] would be
                // indexed past the end when Pos = Len.
                NextIsQuote := false;
                if Pos < Len then
                    NextIsQuote := Src[Pos + 1] = 34;
                if NextIsQuote then begin       // doubled -> literal quote
                    HasEscape := true;
                    Pos += 2;
                end else begin
                    Spelling := SliceLiteral(ContentStart, Pos - ContentStart, HasEscape, '"');
                    Pos += 1;                  // closing quote
                    IdIdx := Tokens.InternIdentifier(Spelling);
                    AddTok(Tokens, "ALI TokenKind"::IdentifierToken, StartPos, Pos - StartPos, IdIdx);
                    exit;
                end;
            end else begin
                if (Ch = 13) or (Ch = 10) then
                    break;                         // no multiline quoted identifiers
                Pos += 1;
            end;
        end;
        Diags.AddError(Code_UnterminatedQuotedIdent(), 'Unterminated quoted identifier', StartPos, Pos - StartPos);
        // still emit an identifier token so downstream stages have an anchor
        IdIdx := Tokens.InternIdentifier(SliceLiteral(ContentStart, Pos - ContentStart, HasEscape, '"'));
        AddTok(Tokens, "ALI TokenKind"::IdentifierToken, StartPos, Pos - StartPos, IdIdx);
    end;

    // The text between the quotes, with doubled delimiters collapsed. One CopyStr when the
    // literal held no escape (the overwhelming majority), one extra Replace when it did.
    local procedure SliceLiteral(ContentStart: Integer; Span: Integer; HasEscape: Boolean; Delim: Text): Text
    var
        Raw: Text;
    begin
        if Span <= 0 then
            exit('');
        Raw := CopyStr(Src, ContentStart, Span);
        if not HasEscape then
            exit(Raw);
        exit(Raw.Replace(Delim + Delim, Delim));
    end;

    // ===== String literals (§5.1) — single quotes, '' escape =====

    // Span-then-slice, same as ScanQuotedIdent — see its note.
    local procedure ScanString(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        HasEscape: Boolean;
        NextIsQuote: Boolean;
        Ch: Integer;
        Col, Hi, Lo, Mid : Integer;
        ContentStart: Integer;
        StartPos: Integer;
        ValIdx: Integer;
    begin
        StartPos := Pos;
        Pos += 1;  // opening '\''
        ContentStart := Pos;
        while Pos <= Len do begin
            Ch := Src[Pos];
            if Ch = 39 then begin               // '\''
                NextIsQuote := false;
                if Pos < Len then
                    NextIsQuote := Src[Pos + 1] = 39;
                if NextIsQuote then begin       // '' -> literal quote
                    HasEscape := true;
                    Pos += 2;
                end else begin
                    ValIdx := Tokens.AddStringLiteral(SliceLiteral(ContentStart, Pos - ContentStart, HasEscape, ''''));
                    Pos += 1;                  // closing quote
                    AddTok(Tokens, "ALI TokenKind"::StringLiteralToken, StartPos, Pos - StartPos, ValIdx);
                    exit;
                end;
            end else begin
                if (Ch = 13) or (Ch = 10) then
                    break;                         // unterminated at line end (§5.1)
                Pos += 1;
            end;
        end;
        Diags.AddError(Code_UnterminatedString(), 'Unterminated string literal', StartPos, Pos - StartPos);
        ValIdx := Tokens.AddStringLiteral(SliceLiteral(ContentStart, Pos - ContentStart, HasEscape, ''''));
        // Inline of Add Tok
        //AddTok(Tokens, "ALI TokenKind"::StringLiteralToken, StartPos, Pos - StartPos, ValIdx);
        Lo := 1;
        Hi := LineStarts.Count();
        while Lo < Hi do begin
            Mid := (Lo + Hi + 1) div 2;
            if LineStarts.Get(Mid) <= StartPos then
                Lo := Mid
            else
                Hi := Mid - 1;
        end;
        Col := (StartPos - LineStarts.Get(Lo)) + 1;
        Tokens.AddToken("ALI TokenKind"::StringLiteralToken, StartPos, Pos - StartPos, Lo, Col, ValIdx, PendingTrivia);
        PendingTrivia := 0;
    end;

    // ===== Numeric / date / time / datetime literals (§5.1) =====
    //
    // A run of digits may be: integer, bigint, decimal (contains '.'), or a date/time/
    // datetime literal if terminated by D / T / DT. The decimal-vs-range ambiguity
    // (`1.5` vs `1..2`): after digits, a '.' is a decimal point ONLY if the next char is
    // NOT another '.' — `1..2` keeps the number as integer `1` and lets `..` lex next.
    local procedure ScanNumericOrDate(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        HasDot: Boolean;
        DigitEnd: Integer;
        StartPos: Integer;
        Suffix: Integer;    // 0 none, 1 D, 2 T, 3 DT
        Raw: Text;
    begin
        StartPos := Pos;
        // integer part
        while IsDigitAt(Pos) do
            Pos += 1;

        // fractional part: '.' NOT followed by '.' (range guard), and a digit after it
        HasDot := false;
        if (PeekCh(0) = 46) and (PeekCh(1) <> 46) and IsDigit(PeekCh(1)) then begin
            HasDot := true;
            Pos += 1;  // '.'
            while IsDigitAt(Pos) do
                Pos += 1;
        end;

        DigitEnd := Pos;

        // date/time suffix: D, T, or DT immediately after the digits (case-insensitive),
        // only when NOT already a decimal (dates/times are integer-shaped digit runs).
        Suffix := 0;
        if not HasDot then
            Suffix := ScanDateTimeSuffix();

        Raw := CopyStr(Src, StartPos, DigitEnd - StartPos);

        case Suffix of
            1:  // 'D' date literal (§5.1 — validate calendar validity)
                EmitDateLiteral(Tokens, Diags, Raw, StartPos);
            2:  // 'T' time literal
                EmitTimeLiteral(Tokens, Diags, Raw, StartPos);
            3:  // 'DT' datetime literal
                EmitDateTimeLiteral(Tokens, Diags, Raw, StartPos);
            else
                EmitNumericLiteral(Tokens, Diags, Raw, HasDot, StartPos);
        end;
    end;

    // Look for a D / T / DT suffix right after the digit run; consume it if present.
    // Returns 0/1/2/3 and advances Pos past the suffix on a match. `0D`/`0DT` handled
    // because the digit run may be a single '0'.
    local procedure ScanDateTimeSuffix(): Integer
    var
        C0: Integer;
    begin
        C0 := PeekCh(0);
        // 'DT' (D then T) — check before bare 'D'
        if IsLetterD(C0) and IsLetterT(PeekCh(1)) and (not IsIdentPart(PeekCh(2))) then begin
            Pos += 1;
            Pos += 1;
            exit(3);
        end;
        if IsLetterD(C0) and (not IsIdentPart(PeekCh(1))) then begin
            Pos += 1;
            exit(1);
        end;
        if IsLetterT(C0) and (not IsIdentPart(PeekCh(1))) then begin
            Pos += 1;
            exit(2);
        end;
        exit(0);
    end;

    local procedure EmitNumericLiteral(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Raw: Text; HasDot: Boolean; StartPos: Integer)
    var
        BigV: BigInteger;
        DecV: Decimal;
        IntV: Integer;
        Span: Integer;
        ValIdx: Integer;
    begin
        Span := Pos - StartPos;
        if HasDot then begin
            if Evaluate(DecV, Raw, 9) then begin
                ValIdx := Tokens.AddDecLiteral(DecV);
                AddTok(Tokens, "ALI TokenKind"::DecimalLiteralToken, StartPos, Span, ValIdx);
            end else
                EmitBadNumber(Tokens, Diags, Raw, StartPos, Span);
            exit;
        end;

        // integer-shaped: fit in Int32? else BigInteger.
        if Evaluate(IntV, Raw) then begin
            ValIdx := Tokens.AddIntLiteral(IntV);
            AddTok(Tokens, "ALI TokenKind"::Int32LiteralToken, StartPos, Span, ValIdx);
        end else if Evaluate(BigV, Raw) then begin
            ValIdx := Tokens.AddBigIntLiteral(BigV);
            AddTok(Tokens, "ALI TokenKind"::Int64LiteralToken, StartPos, Span, ValIdx);
        end else
            EmitBadNumber(Tokens, Diags, Raw, StartPos, Span);
    end;

    local procedure EmitBadNumber(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Raw: Text; StartPos: Integer; Span: Integer)
    begin
        Diags.AddError(Code_InvalidNumber(), StrSubstNo('Invalid numeric literal ''%1''', Raw), StartPos, Span);
        AddTok(Tokens, "ALI TokenKind"::BadToken, StartPos, Span, 0);
    end;

    // Date literal `ddMMyyD` or `0D` (§5.1). Validate calendar validity here.
    local procedure EmitDateLiteral(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Raw: Text; StartPos: Integer)
    var
        DateV: Date;
        Span: Integer;
        ValIdx: Integer;
    begin
        Span := Pos - StartPos;
        if Raw = '0' then begin  // 0D = the undefined/zero date
            ValIdx := Tokens.AddDateLiteral(0D);
            AddTok(Tokens, "ALI TokenKind"::DateLiteralToken, StartPos, Span, ValIdx);
            exit;
        end;
        if TryParseDate(Raw, DateV) then begin
            ValIdx := Tokens.AddDateLiteral(DateV);
            AddTok(Tokens, "ALI TokenKind"::DateLiteralToken, StartPos, Span, ValIdx);
        end else begin
            Diags.AddError(Code_InvalidDate(), StrSubstNo('Invalid date literal ''%1D''', Raw), StartPos, Span);
            AddTok(Tokens, "ALI TokenKind"::BadToken, StartPos, Span, 0);
        end;
    end;

    // Time literal `hhmmss[.fff]T` or `0T` — but time never carries a '.' in our digit run,
    // so fractional milliseconds are out of v1 scope; validate hhmmss.
    local procedure EmitTimeLiteral(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Raw: Text; StartPos: Integer)
    var
        Span: Integer;
        ValIdx: Integer;
        TimeV: Time;
    begin
        Span := Pos - StartPos;
        if Raw = '0' then begin
            ValIdx := Tokens.AddTimeLiteral(0T);
            AddTok(Tokens, "ALI TokenKind"::TimeLiteralToken, StartPos, Span, ValIdx);
            exit;
        end;
        if TryParseTime(Raw, TimeV) then begin
            ValIdx := Tokens.AddTimeLiteral(TimeV);
            AddTok(Tokens, "ALI TokenKind"::TimeLiteralToken, StartPos, Span, ValIdx);
        end else begin
            Diags.AddError(Code_InvalidTime(), StrSubstNo('Invalid time literal ''%1T''', Raw), StartPos, Span);
            AddTok(Tokens, "ALI TokenKind"::BadToken, StartPos, Span, 0);
        end;
    end;

    // DateTime literal — only the `0DT` (undefined datetime) form is representable as a
    // bare digit run in v1; any non-zero digit run + DT is validated as a date, at midnight.
    local procedure EmitDateTimeLiteral(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Raw: Text; StartPos: Integer)
    var
        DateV: Date;
        DateTimeV: DateTime;
        Span: Integer;
        ValIdx: Integer;
    begin
        Span := Pos - StartPos;
        if Raw = '0' then begin
            ValIdx := Tokens.AddDateTimeLiteral(0DT);
            AddTok(Tokens, "ALI TokenKind"::DateTimeLiteralToken, StartPos, Span, ValIdx);
            exit;
        end;
        if TryParseDate(Raw, DateV) then begin
            DateTimeV := CreateDateTime(DateV, 0T);
            ValIdx := Tokens.AddDateTimeLiteral(DateTimeV);
            AddTok(Tokens, "ALI TokenKind"::DateTimeLiteralToken, StartPos, Span, ValIdx);
        end else begin
            Diags.AddError(Code_InvalidDateTime(), StrSubstNo('Invalid datetime literal ''%1DT''', Raw), StartPos, Span);
            AddTok(Tokens, "ALI TokenKind"::BadToken, StartPos, Span, 0);
        end;
    end;

    // Parse yyyyMMdd into a Date with calendar validation (§5.1: reject 20251302D).
    // Native format confirmed from decompiled alc (DateTimeUtilities.TryParseDate): the
    // digit run is exactly 8 digits, YYYYMMDD — NOT ddMMyy(yy).
    [TryFunction]
    local procedure TryParseDate(Raw: Text; var Result: Date)
    var
        Dd: Integer;
        Mm: Integer;
        Yy: Integer;
    begin
        if StrLen(Raw) <> 8 then
            Error('bad length');
        Evaluate(Yy, CopyStr(Raw, 1, 4));
        Evaluate(Mm, CopyStr(Raw, 5, 2));
        Evaluate(Dd, CopyStr(Raw, 7, 2));
        Result := DMY2Date(Dd, Mm, Yy);  // DMY2Date errors on an invalid calendar date
    end;

    // Parse hhmmss into a Time.
    [TryFunction]
    local procedure TryParseTime(Raw: Text; var Result: Time)
    var
        Hh: Integer;
        Mm: Integer;
        Ss: Integer;
    begin
        if StrLen(Raw) <> 6 then
            Error('bad length');
        Evaluate(Hh, CopyStr(Raw, 1, 2));
        Evaluate(Mm, CopyStr(Raw, 3, 2));
        Evaluate(Ss, CopyStr(Raw, 5, 2));
        if (Hh > 23) or (Mm > 59) or (Ss > 59) then
            Error('out of range');
        // Build the Time from a midnight base by adding the components as Durations.
        // NB: literal 0T is the UNDEFINED time sentinel, not 00:00:00 — arithmetic on it
        // yields garbage. 000000T is real midnight; use it as the base.
        Result := 000000T;
        Result := Result
            + (Hh * 3600000)   // ms per hour
            + (Mm * 60000)     // ms per minute
            + (Ss * 1000);     // ms per second
    end;

    // ===== Operators & punctuation (§5.1) =====
    //
    // Longest-match: multi-char operators (`:=` `+=` `<>` `<=` `>=` `..` `::`) checked
    // before their single-char prefixes. `<>=` lexes as `<>` then `=` (§14 test 1).
    local procedure ScanOperatorOrBad(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        C0: Integer;
        C1: Integer;
        StartPos: Integer;
    begin
        StartPos := Pos;
        C0 := PeekCh(0);
        C1 := PeekCh(1);

        case C0 of
            43:  // '+'
                EmitOp(Tokens, StartPos, PickAssign(C1, "ALI TokenKind"::AssignPlusToken, "ALI TokenKind"::PlusToken), OpLen(C1, 61));
            45:  // '-'
                EmitOp(Tokens, StartPos, PickAssign(C1, "ALI TokenKind"::AssignMinusToken, "ALI TokenKind"::MinusToken), OpLen(C1, 61));
            42:  // '*'
                EmitOp(Tokens, StartPos, PickAssign(C1, "ALI TokenKind"::AssignMultiplyToken, "ALI TokenKind"::MultiplyToken), OpLen(C1, 61));
            47:  // '/'
                EmitOp(Tokens, StartPos, PickAssign(C1, "ALI TokenKind"::AssignRDivToken, "ALI TokenKind"::RDivToken), OpLen(C1, 61));
            61:  // '='
                EmitOp(Tokens, StartPos, "ALI TokenKind"::EqualsToken, 1);
            60:  // '<'  -> '<>', '<=', or '<'


                case C1 of
                    62:  // '>'
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::NotEqualsToken, 2);
                    61:  // '='
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::LessThanEqualsToken, 2);
                    else
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::LessThanToken, 1);
                end;
            62:  // '>'  -> '>=' or '>'
                EmitOp(Tokens, StartPos, PickCmp(C1, 61, "ALI TokenKind"::GreaterThanEqualsToken, "ALI TokenKind"::GreaterThanToken), OpLen(C1, 61));
            58:  // ':'  -> ':=', '::', or ':'


                case C1 of
                    61:  // '='
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::AssignToken, 2);
                    58:  // ':'
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::ColonColonToken, 2);
                    else
                        EmitOp(Tokens, StartPos, "ALI TokenKind"::ColonToken, 1);
                end;
            46:  // '.'  -> '..' or '.'


                if C1 = 46 then
                    EmitOp(Tokens, StartPos, "ALI TokenKind"::DotDotToken, 2)
                else
                    EmitOp(Tokens, StartPos, "ALI TokenKind"::DotToken, 1);
            40:  // '('
                EmitOp(Tokens, StartPos, "ALI TokenKind"::OpenParenToken, 1);
            41:  // ')'
                EmitOp(Tokens, StartPos, "ALI TokenKind"::CloseParenToken, 1);
            91:  // '['
                EmitOp(Tokens, StartPos, "ALI TokenKind"::OpenBracketToken, 1);
            93:  // ']'
                EmitOp(Tokens, StartPos, "ALI TokenKind"::CloseBracketToken, 1);
            123: // '{'
                EmitOp(Tokens, StartPos, "ALI TokenKind"::OpenBraceToken, 1);
            125: // '}'
                EmitOp(Tokens, StartPos, "ALI TokenKind"::CloseBraceToken, 1);
            44:  // ','
                EmitOp(Tokens, StartPos, "ALI TokenKind"::CommaToken, 1);
            59:  // ';'
                EmitOp(Tokens, StartPos, "ALI TokenKind"::SemicolonToken, 1);
            else begin
                Diags.AddError(Code_UnexpectedChar(), StrSubstNo('Unexpected character ''%1''', CharToText(C0)), StartPos, 1);
                Pos += 1;
                AddTok(Tokens, "ALI TokenKind"::BadToken, StartPos, 1, 0);
            end;
        end;
    end;

    // Emit an operator token spanning Span chars and advance the cursor over them.
    local procedure EmitOp(var Tokens: Codeunit "ALI Token Table"; StartPos: Integer; Kind: Integer; Span: Integer)
    var
        I: Integer;
    begin
        for I := 1 to Span do
            Pos += 1;
        AddTok(Tokens, Kind, StartPos, Span, 0);
    end;

    // '+=' family: if next char is '=' pick the compound kind (len 2), else the plain (len 1).
    local procedure PickAssign(C1: Integer; CompoundKind: Integer; PlainKind: Integer): Integer
    begin
        if C1 = 61 then
            exit(CompoundKind);
        exit(PlainKind);
    end;

    local procedure PickCmp(C1: Integer; WantChar: Integer; TwoKind: Integer; OneKind: Integer): Integer
    begin
        if C1 = WantChar then
            exit(TwoKind);
        exit(OneKind);
    end;

    local procedure OpLen(C1: Integer; WantChar: Integer): Integer
    begin
        if C1 = WantChar then
            exit(2);
        exit(1);
    end;

    // ===== Token emit helper: attach + clear pending trivia (§5.1) =====

    local procedure AddTok(var Tokens: Codeunit "ALI Token Table"; Kind: Integer; StartPos: Integer; Span: Integer; ValIdx: Integer)
    var
        Col: Integer;
        Ln: Integer;
    begin
        LineColOf(StartPos, Ln, Col);
        Tokens.AddToken(Kind, StartPos, Span, Ln, Col, ValIdx, PendingTrivia);
        PendingTrivia := 0;
    end;

    // Resolve a source offset to (line, col) using LineStarts (same search as the diag bag).
    local procedure LineColOf(P: Integer; var Ln: Integer; var Col: Integer)
    var
        Hi: Integer;
        Lo: Integer;
        Mid: Integer;
    begin
        Lo := 1;
        Hi := LineStarts.Count();
        while Lo < Hi do begin
            Mid := (Lo + Hi + 1) div 2;
            if LineStarts.Get(Mid) <= P then
                Lo := Mid
            else
                Hi := Mid - 1;
        end;
        Ln := Lo;
        Col := (P - LineStarts.Get(Lo)) + 1;
    end;

    // ===== Character classification =====

    local procedure IsDigit(Ch: Integer): Boolean
    begin
        exit((Ch >= 48) and (Ch <= 57));  // '0'..'9'
    end;

    local procedure IsIdentPart(Ch: Integer): Boolean
    begin
        exit(((Ch >= 65) and (Ch <= 90)) or ((Ch >= 97) and (Ch <= 122)) or (Ch > 127) or
             ((Ch >= 48) and (Ch <= 57)) or (Ch = 95));
    end;

    local procedure IsDigitAt(I: Integer): Boolean
    begin
        if (I < 1) or (I > Len) then
            exit(false);
        exit((Src[I] >= 48) and (Src[I] <= 57)); // '0' .. '9'
    end;

    local procedure IsLetter(Ch: Integer): Boolean
    begin
        // ASCII letters, plus any char above 127: native AL accepts Unicode letters in
        // unquoted identifiers (e.g. 'RabaisSpéciaux', 'Prénom' — verified against alc).
        // ponytail: >127 also admits non-letter symbols (e.g. '€') that alc rejects;
        // tighten to Unicode letter categories if that overacceptance ever bites.
        exit(((Ch >= 65) and (Ch <= 90)) or ((Ch >= 97) and (Ch <= 122)) or (Ch > 127));
    end;

    local procedure IsLetterD(Ch: Integer): Boolean
    begin
        exit((Ch = 68) or (Ch = 100));  // 'D' / 'd'
    end;

    local procedure IsLetterT(Ch: Integer): Boolean
    begin
        exit((Ch = 84) or (Ch = 116));  // 'T' / 't'
    end;

    local procedure CharToText(Ch: Integer): Text
    var
        C: Char;
    begin
        C := Ch;
        exit(Format(C));
    end;

    // ===== Bit helpers (TriviaFlags packing) =====

    local procedure SetBit(Flags: Integer; Bit: Integer): Integer
    begin
        if (Flags mod (Bit * 2)) >= Bit then
            exit(Flags);  // already set
        exit(Flags + Bit);
    end;

    // ===== Keyword table (built once; UPPERCASE spelling -> TokenKind ordinal) =====

    local procedure BuildKeywords()
    begin
        Keywords.Set('DIV', "ALI TokenKind"::IDivKeyword);
        Keywords.Set('MOD', "ALI TokenKind"::ModuloKeyword);
        Keywords.Set('AND', "ALI TokenKind"::AndKeyword);
        Keywords.Set('OR', "ALI TokenKind"::OrKeyword);
        Keywords.Set('XOR', "ALI TokenKind"::XorKeyword);
        Keywords.Set('NOT', "ALI TokenKind"::NotKeyword);
        Keywords.Set('TRUE', "ALI TokenKind"::TrueKeyword);
        Keywords.Set('FALSE', "ALI TokenKind"::FalseKeyword);

        Keywords.Set('IF', "ALI TokenKind"::IfKeyword);
        Keywords.Set('THEN', "ALI TokenKind"::ThenKeyword);
        Keywords.Set('ELSE', "ALI TokenKind"::ElseKeyword);
        Keywords.Set('CASE', "ALI TokenKind"::CaseKeyword);
        Keywords.Set('OF', "ALI TokenKind"::OfKeyword);
        Keywords.Set('FOR', "ALI TokenKind"::ForKeyword);
        Keywords.Set('TO', "ALI TokenKind"::ToKeyword);
        Keywords.Set('DOWNTO', "ALI TokenKind"::DownToKeyword);
        Keywords.Set('DO', "ALI TokenKind"::DoKeyword);
        Keywords.Set('WHILE', "ALI TokenKind"::WhileKeyword);
        Keywords.Set('REPEAT', "ALI TokenKind"::RepeatKeyword);
        Keywords.Set('UNTIL', "ALI TokenKind"::UntilKeyword);
        Keywords.Set('FOREACH', "ALI TokenKind"::ForEachKeyword);
        Keywords.Set('IN', "ALI TokenKind"::InKeyword);
        Keywords.Set('BEGIN', "ALI TokenKind"::BeginKeyword);
        Keywords.Set('END', "ALI TokenKind"::EndKeyword);
        Keywords.Set('EXIT', "ALI TokenKind"::ExitKeyword);
        Keywords.Set('BREAK', "ALI TokenKind"::BreakKeyword);
        Keywords.Set('WITH', "ALI TokenKind"::WithKeyword);

        Keywords.Set('PROCEDURE', "ALI TokenKind"::ProcedureKeyword);
        Keywords.Set('LOCAL', "ALI TokenKind"::LocalKeyword);
        Keywords.Set('INTERNAL', "ALI TokenKind"::InternalKeyword);
        Keywords.Set('PROTECTED', "ALI TokenKind"::ProtectedKeyword);
        Keywords.Set('VAR', "ALI TokenKind"::VarKeyword);
        Keywords.Set('ARRAY', "ALI TokenKind"::ArrayKeyword);
        Keywords.Set('TEMPORARY', "ALI TokenKind"::TemporaryKeyword);
        Keywords.Set('TRIGGER', "ALI TokenKind"::TriggerKeyword);
        Keywords.Set('CODEUNIT', "ALI TokenKind"::CodeunitKeyword);
        Keywords.Set('TABLE', "ALI TokenKind"::TableKeyword);
        Keywords.Set('PAGE', "ALI TokenKind"::PageKeyword);
        Keywords.Set('REPORT', "ALI TokenKind"::ReportKeyword);
        Keywords.Set('QUERY', "ALI TokenKind"::QueryKeyword);
        Keywords.Set('XMLPORT', "ALI TokenKind"::XmlPortKeyword);
        Keywords.Set('DOTNET', "ALI TokenKind"::DotNetKeyword);
        Keywords.Set('EVENT', "ALI TokenKind"::EventKeyword);

        KeywordsBuilt := true;
    end;

    // TokenKind ordinals used to be 80 `EnumKind_X(): Integer` accessors returning a hardcoded
    // literal — one AL call per token emitted, and a second copy of the frozen ordinals to keep
    // in step with "ALI TokenKind". Both are gone: `"ALI TokenKind"::X` is a compile-time
    // constant, so the call disappears and the enum is the single source of the number.
    // (It also caught a real one: a hand-inlined AddToken on the unterminated-string path passed
    // literal 20 under a `/* StringLiteralToken */` comment — 20 is IdentifierToken.)

    // ===== Diagnostic codes (ALI9xx reserved range, §4.3) =====

    local procedure Code_UnterminatedComment(): Text
    begin
        exit('ALI901');
    end;

    local procedure Code_UnterminatedString(): Text
    begin
        exit('ALI902');
    end;

    local procedure Code_UnterminatedQuotedIdent(): Text
    begin
        exit('ALI903');
    end;

    local procedure Code_InvalidNumber(): Text
    begin
        exit('ALI904');
    end;

    local procedure Code_InvalidDate(): Text
    begin
        exit('ALI905');
    end;

    local procedure Code_InvalidTime(): Text
    begin
        exit('ALI906');
    end;

    local procedure Code_InvalidDateTime(): Text
    begin
        exit('ALI907');
    end;

    local procedure Code_UnexpectedChar(): Text
    begin
        exit('ALI908');
    end;

    local procedure Code_PreprocessorSkipped(): Text
    begin
        exit('ALI909');
    end;

    local procedure Code_UnterminatedDirective(): Text
    begin
        exit('ALI910');
    end;

    local procedure Code_BadDirectiveCondition(): Text
    begin
        exit('ALI912');
    end;
}
