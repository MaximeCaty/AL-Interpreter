// ALI Parse Ctx — shared cursor + nesting depth for the two parser codeunits (§5.2).
// Split-parser state lives here so "ALI Parser" (stmts/decls) and "ALI Parser Expr"
// (Pratt expressions) share one cursor and one depth guard.
//
// The token/AST/diag STORES are passed by `var` into the navigation helpers rather than
// stored as codeunit members — AL codeunit assignment copies, so holding them as members
// would desync from the caller's instances. Cursor + depth ARE members (scalar state).
//
// Cursor is a 1-based token index. The lexer always appends an EndOfFileToken, so the
// cursor never runs off the end: Peek past EOF returns EOF repeatedly.
codeunit 51021 "ALI Parse Ctx"
{
    Access = Public;
    SingleInstance = false;

    var
        DepthTripped: Boolean;  // set once when the guard fires (single diagnostic)
        Cursor: Integer;    // 1-based index of the NEXT token to consume
        Depth: Integer;     // current expression+statement recursion depth (§5.2 guard)
        MaxDepth: Integer;  // from ALI Limits
        TokCount: Integer;
        // Perf: private copy of the token KIND column, taken once in Init. Lexing is complete
        // before the parser runs and kinds never change, so this is safe to snapshot. It used to
        // be read live: CurKind -> PeekKind -> Tokens.Count + Tokens.GetKind, so consuming one
        // token cost ~7 AL procedure calls at ~450ns each. Navigation is now straight-line over
        // these two members. The token/AST/diag STORES still come in by `var` everywhere they
        // are actually needed (Expect/EnterDepth, for diagnostic positions).
        Kinds: List of [Integer];

    // Token-kind ordinals the ctx needs to reason about (mirror "ALI TokenKind").
    procedure KindEOF(): Integer
    begin
        exit(1);        // EndOfFileToken
    end;

    // ===== Lifecycle =====

    procedure Init(var Tokens: Codeunit "ALI Token Table")
    var
        Limits: Codeunit "ALI Limits";
    begin
        Cursor := 1;
        Depth := 0;
        MaxDepth := Limits.MaxNestingDepth();
        DepthTripped := false;
        Clear(Kinds);
        Tokens.CopyKindColumn(Kinds);
        TokCount := Kinds.Count();
    end;

    // ===== Cursor navigation (over the Init-snapshotted kind column, §5.2) =====
    // Each of these is straight-line on purpose — they do NOT delegate to one another. The old
    // CurKind -> PeekKind and Advance -> CurIndex + CurKind chains multiplied the call count on
    // the hottest path in the compiler for no benefit.

    // Kind of the token at Cursor+Offset (clamped to the trailing EOF token).
    procedure PeekKind(Offset: Integer): Integer
    var
        I: Integer;
    begin
        I := Cursor + Offset;
        if I > TokCount then
            exit(KindEOF());
        exit(Kinds.Get(I));
    end;

    // Kind of the current token.
    procedure CurKind(): Integer
    begin
        if Cursor > TokCount then
            exit(KindEOF());
        exit(Kinds.Get(Cursor));
    end;

    // Token index of the current token (clamped to the last real token = EOF).
    procedure CurIndex(): Integer
    begin
        if Cursor > TokCount then
            exit(TokCount);
        exit(Cursor);
    end;

    procedure AtEof(): Boolean
    begin
        if Cursor > TokCount then
            exit(true);
        exit(Kinds.Get(Cursor) = KindEOF());
    end;

    // Consume the current token and return its index; does not advance past EOF.
    procedure Advance(): Integer
    begin
        if Cursor > TokCount then
            exit(TokCount);
        if Kinds.Get(Cursor) <> KindEOF() then begin
            Cursor += 1;
            exit(Cursor - 1);
        end;
        exit(Cursor);
    end;

    // If the current token is Kind, consume it and return true; else false (no advance).
    procedure Accept(Kind: Integer): Boolean
    begin
        // Past the end reads as EOF (as PeekKind/CurKind do); "consuming" it is a no-op, which
        // is what the old CurKind+Advance pair did. Unreachable while the lexer appends a
        // trailing EOF token, but kept faithful so the two forms cannot diverge.
        if Cursor > TokCount then
            exit(Kind = KindEOF());
        if Kinds.Get(Cursor) <> Kind then
            exit(false);
        if Kind <> KindEOF() then
            Cursor += 1;
        exit(true);
    end;

    // Expect a required token: consume it if present. If absent, report the MS-style
    // "expected" diagnostic at the current position and return the current index WITHOUT
    // advancing (missing-token insertion is modelled positionally — no synthetic token is
    // added to the table; the AST anchors to the current index). Returns the token index
    // to anchor to (consumed token, or current position for the missing case).
    procedure Expect(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"; Kind: Integer; ExpectedText: Text): Integer
    var
        Idx: Integer;
    begin
        if CurKind() = Kind then
            exit(Advance());
        // Missing required token (§5.2 missing-token insertion).
        Idx := CurIndex();
        Diags.AddError('AL0132', StrSubstNo('%1 expected', ExpectedText), Tokens.GetStartPos(Idx), 0);
        exit(Idx);
    end;

    // ===== Depth guard (§5.2 / §5.4 — mandatory: AL stack overflow is uncatchable) =====

    // Enter a recursion level; returns false and emits a single diagnostic once the guard
    // trips, so callers unwind by synthesizing an error node instead of recursing.
    procedure EnterDepth(var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Idx: Integer;
    begin
        Depth += 1;
        if Depth > MaxDepth then begin
            // Failed enter has NO matching LeaveDepth in callers — undo the increment here,
            // or Depth leaks +1 per trip and the guard stays tripped after full unwind
            // (zero-consume error nodes then starve progress-less caller loops).
            Depth -= 1;
            if not DepthTripped then begin
                DepthTripped := true;
                Idx := CurIndex();
                Diags.AddError('ALI901', 'Expression or statement is too complex (nesting too deep)', Tokens.GetStartPos(Idx), 0);
            end;
            exit(false);
        end;
        exit(true);
    end;

    procedure LeaveDepth()
    begin
        if Depth > 0 then
            Depth -= 1;
    end;

    procedure DepthExceeded(): Boolean
    begin
        // EnterDepth self-balances on failure, so Depth never passes MaxDepth; "at the
        // limit" is the failing condition now.
        exit(Depth >= MaxDepth);
    end;
}
