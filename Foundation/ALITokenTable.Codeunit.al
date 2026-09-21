// ALI Token Table — token columns + per-type literal pools + identifier interning (§4.1).
// Struct-of-arrays: parallel List columns indexed by 1-based token index.
// Parser/binder compare identifiers by POOL INDEX (integer compare), never by string
// (interning is load-bearing, §4.1). Identifiers case-insensitive -> intern keyed on
// UPPERCASE spelling; original spelling kept in the pool for diagnostics.
codeunit 51104 "ALI Token Table"
{
    Access = Public;
    SingleInstance = false;

    var

        // --- Identifier intern map: UPPERCASE spelling -> TextPool index ---
        InternMap: Dictionary of [Text, Integer];
        BigIntPool: List of [BigInteger];
        DatePool: List of [Date];
        DateTimePool: List of [DateTime];
        DecPool: List of [Decimal];
        ColumnNo: List of [Integer];

        // --- Literal pools (1-based; ValueIndex points here per token KindOrd) ---
        IntPool: List of [Integer];
        // --- Token columns (parallel, 1-based) ---
        KindOrd: List of [Integer];     // "ALI TokenKind" ordinal
        Length: List of [Integer];
        LineNo: List of [Integer];
        StartPos: List of [Integer];    // 1-based char offset into source
        TriviaFlags: List of [Integer]; // byte-packed: bit0 leading-comment, bit1 precedes-newline
        ValueIndex: List of [Integer];  // index into the per-type pool, or 0
        TextPool: List of [Text];       // string literals AND identifier spellings (deduped)
        TimePool: List of [Time];

    // ===== Add =====

    // Core adder. ValIdx = pool index already resolved by the lexer (0 if none).
    procedure AddToken(Kind: Integer; Pos: Integer; Len: Integer; Ln: Integer; Col: Integer; ValIdx: Integer; Trivia: Integer): Integer
    begin
        KindOrd.Add(Kind);
        StartPos.Add(Pos);
        Length.Add(Len);
        LineNo.Add(Ln);
        ColumnNo.Add(Col);
        ValueIndex.Add(ValIdx);
        TriviaFlags.Add(Trivia);
        exit(KindOrd.Count());
    end;

    // ===== Literal-pool interning helpers (return the pool index to stash in ValueIndex) =====

    procedure AddIntLiteral(V: Integer): Integer
    begin
        IntPool.Add(V);
        exit(IntPool.Count());
    end;

    procedure AddBigIntLiteral(V: BigInteger): Integer
    begin
        BigIntPool.Add(V);
        exit(BigIntPool.Count());
    end;

    procedure AddDecLiteral(V: Decimal): Integer
    begin
        DecPool.Add(V);
        exit(DecPool.Count());
    end;

    procedure AddDateLiteral(V: Date): Integer
    begin
        DatePool.Add(V);
        exit(DatePool.Count());
    end;

    procedure AddTimeLiteral(V: Time): Integer
    begin
        TimePool.Add(V);
        exit(TimePool.Count());
    end;

    procedure AddDateTimeLiteral(V: DateTime): Integer
    begin
        DateTimePool.Add(V);
        exit(DateTimePool.Count());
    end;

    // String literal — NOT interned (each occurrence is its own value).
    procedure AddStringLiteral(V: Text): Integer
    begin
        TextPool.Add(V);
        exit(TextPool.Count());
    end;

    // Identifier — INTERNED. Keyed on uppercase; original Spelling kept for diagnostics.
    // Returns the shared TextPool index so equal identifiers share one id (§4.1).
    procedure InternIdentifier(Spelling: Text): Integer
    var
        Idx: Integer;
        KeySpelling: Text;
    begin
        KeySpelling := UpperCase(Spelling);
        if InternMap.Get(KeySpelling, Idx) then
            exit(Idx);
        TextPool.Add(Spelling);
        Idx := TextPool.Count();
        InternMap.Set(KeySpelling, Idx);
        exit(Idx);
    end;

    // ===== Token getters (1-based token index) =====

    procedure Count(): Integer
    begin
        exit(KindOrd.Count());
    end;

    // The single-index getters below are TOTAL: an out-of-range token index yields a neutral
    // value instead of raising. That is not defensiveness for its own sake — the binder reaches
    // them through a node's MainToken, and a node produced by PARSER ERROR RECOVERY carries 0.
    // Since M11 stopped treating a parse error in a HARVESTED object as fatal (the parser resyncs
    // and the declarations that did parse are worth binding), such nodes reach the binder for
    // real. A compiler must answer that with a diagnostic, not with a raw AL "invalid argument
    // was passed to a List method" that takes the whole session down with no position and no
    // message the reader can act on.
    local procedure InRange(Idx: Integer): Boolean
    begin
        exit((Idx >= 1) and (Idx <= KindOrd.Count()));
    end;

    procedure GetKind(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(KindOrd.Get(Idx));
    end;

    // Bulk copy of the kind column, for "ALI Parse Ctx" to snapshot at Init. Kinds are immutable
    // once lexing finishes, so the parser can navigate its own copy instead of paying a
    // cross-codeunit GetKind/Count per peek. One call per parse instead of ~7 per token.
    procedure CopyKindColumn(var Dest: List of [Integer])
    var
        K: Integer;
    begin
        Clear(Dest);
        foreach K in KindOrd do
            Dest.Add(K);
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

    // Bounds-check + line + column in one call, for the lowerer's per-statement debug marker.
    // That path ran Count() + GetLine() + GetColumn() separately — 3 cross-codeunit calls per
    // statement. Returns false (and leaves Ln/Col at 0) when Idx is out of range.
    procedure GetLineCol(Idx: Integer; var Ln: Integer; var Col: Integer): Boolean
    begin
        Ln := 0;
        Col := 0;
        if (Idx < 1) or (Idx > KindOrd.Count()) then
            exit(false);
        Ln := LineNo.Get(Idx);
        Col := ColumnNo.Get(Idx);
        exit(true);
    end;

    procedure GetValueIndex(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(ValueIndex.Get(Idx));
    end;

    procedure GetTrivia(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(TriviaFlags.Get(Idx));
    end;

    procedure HasTrivia(Idx: Integer; Bit: Integer): Boolean
    begin
        if not InRange(Idx) then
            exit(false);
        exit((TriviaFlags.Get(Idx) mod (Bit * 2)) >= Bit);
    end;

    // Interned identifier id for a token (the shared TextPool index). 0 = out of range, or a
    // token that carries no interned value.
    procedure GetIdentId(Idx: Integer): Integer
    begin
        if not InRange(Idx) then
            exit(0);
        exit(ValueIndex.Get(Idx));
    end;

    // ===== Value getters by pool =====

    procedure GetInt(PoolIdx: Integer): Integer
    begin
        exit(IntPool.Get(PoolIdx));
    end;

    procedure GetBigInt(PoolIdx: Integer): BigInteger
    begin
        exit(BigIntPool.Get(PoolIdx));
    end;

    procedure GetDec(PoolIdx: Integer): Decimal
    begin
        exit(DecPool.Get(PoolIdx));
    end;

    procedure GetText(PoolIdx: Integer): Text
    begin
        exit(TextPool.Get(PoolIdx));
    end;

    procedure GetDate(PoolIdx: Integer): Date
    begin
        exit(DatePool.Get(PoolIdx));
    end;

    procedure GetTime(PoolIdx: Integer): Time
    begin
        exit(TimePool.Get(PoolIdx));
    end;

    procedure GetDateTime(PoolIdx: Integer): DateTime
    begin
        exit(DateTimePool.Get(PoolIdx));
    end;

    // Convenience: spelling of an identifier token (from the interned TextPool). '' when the
    // token index is out of range OR the token carries no pooled text (i.e. it is neither an
    // identifier nor a string literal) — the single most-called getter on a node's MainToken, and
    // the one an error-recovery node's 0 used to crash on. See the InRange note above.
    procedure GetIdentText(TokenIdx: Integer): Text
    var
        PoolIdx: Integer;
    begin
        if not InRange(TokenIdx) then
            exit('');
        PoolIdx := ValueIndex.Get(TokenIdx);
        if (PoolIdx < 1) or (PoolIdx > TextPool.Count()) then
            exit('');
        exit(TextPool.Get(PoolIdx));
    end;

    // Lazy source slice for messages (§4.1): the exact chars this token spans.
    procedure GetSourceText(TokenIdx: Integer; Source: Text): Text
    begin
        if not InRange(TokenIdx) then
            exit('');
        exit(CopyStr(Source, StartPos.Get(TokenIdx), Length.Get(TokenIdx)));
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        ClearAll();
    end;
}
