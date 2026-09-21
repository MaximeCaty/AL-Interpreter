// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Front End Tests — lexer, parser, parser error recovery and the editor-facing API
// catalog, i.e. everything that runs BEFORE the binder hands a module to the interpreter.
// Merged from the former "ALI Lexer/Parser/Parser Recovery/Api Catalog Tests" codeunits;
// each section keeps its original documentation header below.
codeunit 51128 "ALI Front End Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        ApiCatalog: Codeunit "ALI Api Catalog";
        DiagEngine: Codeunit "ALI Engine";
        Pipeline: Codeunit "ALI Test Pipeline";
        Assert: Codeunit "Library Assert";

    // ================================================================================================
    // ALI Lexer Tests (§14.1) — all literal forms + edge cases:
    //   1..2 vs 1.5 vs 1., 0D/0DT/invalid 20259999D, quoted ident w/ doubled quotes,
    //   string '' escape + unterminated, /* unterminated, := vs : =, case-insensitive
    //   keywords, identifiers that look like keywords, empty / whitespace-only source,
    //   long identifier/string, operator adjacency (<>= -> <> =), line/col across CRLF vs LF.
    //
    // Golden-shape asserts use "ALI Test Pipeline".DumpKinds; value/position/diagnostic
    // asserts use the Token Table / Diag Bag getters directly. Each stage is testable in
    // isolation (§14) — these tests touch only Lexer + TokenTable + DiagBag.
    // ================================================================================================

    // ===== Helpers =====

    local procedure Lex(Source: Text; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        Lexer: Codeunit "ALI Lexer";
    begin
        Tokens.Reset();
        Diags.Reset();
        Lexer.Tokenize(Source, Tokens, Diags);
    end;

    // Assert the space-separated kind sequence (EOF appended by the lexer).
    local procedure AssertKinds(Source: Text; Expected: Text)
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex(Source, Tokens, Diags);
        Assert.AreEqual(Expected, Pipeline.DumpKinds(Tokens), StrSubstNo('kinds for <%1>', Source));
    end;

    // ===== Numeric / range / decimal boundary =====

    [Test]
    procedure T01_IntegerLiteral()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('42', Tokens, Diags);
        Assert.AreEqual(2, Tokens.Count(), 'int + EOF');  // 42, EOF
        Assert.AreEqual(10, Tokens.GetKind(1), 'Int32');
        Assert.AreEqual(42, Tokens.GetInt(Tokens.GetValueIndex(1)), 'value 42');
    end;

    [Test]
    procedure T02_DecimalVsRange()
    begin
        // 1.5 is ONE decimal; 1..2 is int '1', '..', int '2' (§5.1 range guard).
        AssertKinds('1.5', 'DecimalLiteralToken EndOfFileToken');
        AssertKinds('1..2', 'Int32LiteralToken DotDotToken Int32LiteralToken EndOfFileToken');
    end;

    [Test]
    procedure T03_TrailingDotIsNotFraction()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // '1.' -> integer '1' then a lone '.' (no digit after the dot => not a fraction).
        Lex('1.', Tokens, Diags);
        Assert.AreEqual(10, Tokens.GetKind(1), 'int 1');
        Assert.AreEqual(77, Tokens.GetKind(2), 'DotToken');
        Assert.AreEqual(1, Tokens.GetInt(Tokens.GetValueIndex(1)), 'value 1');
    end;

    [Test]
    procedure T04_BigIntegerWidening()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // Beyond Int32 range -> Int64LiteralToken (BigInteger pool).
        Lex('9999999999', Tokens, Diags);
        Assert.AreEqual(11, Tokens.GetKind(1), 'Int64');
        Assert.AreEqual(9999999999L, Tokens.GetBigInt(Tokens.GetValueIndex(1)), 'value');
    end;

    // ===== Date / time / datetime =====

    [Test]
    procedure T05_DateLiteral()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('20250101D', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
        Assert.AreEqual(13, Tokens.GetKind(1), 'DateLiteral');
        Assert.AreEqual(DMY2Date(1, 1, 2025), Tokens.GetDate(Tokens.GetValueIndex(1)), '01-01-2025');
    end;

    [Test]
    procedure T06_ZeroDateAndDateTime()
    begin
        AssertKinds('0D', 'DateLiteralToken EndOfFileToken');
        AssertKinds('0DT', 'DateTimeLiteralToken EndOfFileToken');
        AssertKinds('0T', 'TimeLiteralToken EndOfFileToken');
    end;

    [Test]
    procedure T07_InvalidDateReported()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // 20259999D -> month 99 invalid; must be reported (ALI905), not silently accepted.
        Lex('20259999D', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'one error');
        Assert.AreEqual('ALI905', Diags.GetCode(1), 'invalid-date code');
        Assert.AreEqual(2, Tokens.GetKind(1), 'emitted as BadToken');
    end;

    [Test]
    procedure T08_TimeLiteral()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('120000T', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
        Assert.AreEqual(14, Tokens.GetKind(1), 'TimeLiteral');
        Assert.AreEqual(120000T, Tokens.GetTime(Tokens.GetValueIndex(1)), '12:00:00');
    end;

    // ===== Strings =====

    [Test]
    procedure T09_StringWithDoubledQuoteEscape()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // 'it''s' -> value  it's
        Lex('''it''''s''', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
        Assert.AreEqual(16, Tokens.GetKind(1), 'StringLiteral');
        Assert.AreEqual('it''s', Tokens.GetText(Tokens.GetValueIndex(1)), 'unescaped value');
    end;

    [Test]
    procedure T10_UnterminatedString()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('''oops', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'one error');
        Assert.AreEqual('ALI902', Diags.GetCode(1), 'unterminated-string code');
        Assert.AreEqual(16, Tokens.GetKind(1), 'still emits a string token anchor');
    end;

    // ===== Quoted identifiers =====

    [Test]
    procedure T11_QuotedIdentifierDoubledQuotes()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // "Some ""Name"""  -> identifier spelling  Some "Name"
        Lex('"Some ""Name"""', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
        Assert.AreEqual(20, Tokens.GetKind(1), 'IdentifierToken');
        Assert.AreEqual('Some "Name"', Tokens.GetIdentText(1), 'unescaped spelling');
    end;

    // ===== Comments (unterminated block) =====

    [Test]
    procedure T12_UnterminatedBlockComment()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('/* never closed', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'one error');
        Assert.AreEqual('ALI901', Diags.GetCode(1), 'unterminated-comment code');
        // only EOF remains as a token
        Assert.AreEqual(1, Tokens.Count(), 'just EOF');
        Assert.AreEqual(1, Tokens.GetKind(1), 'EOF');
    end;

    [Test]
    procedure T13_LineCommentTriviaFlag()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // comment before an identifier -> leading-comment trivia bit set on that ident.
        Lex('// hi' + NewLine() + 'x', Tokens, Diags);
        Assert.AreEqual(20, Tokens.GetKind(1), 'ident after comment');
        Assert.IsTrue(Tokens.HasTrivia(1, 1), 'leading-comment bit');
        Assert.IsTrue(Tokens.HasTrivia(1, 2), 'precedes-newline bit (newline before it)');
    end;

    // ===== Operator adjacency & compound assign =====

    [Test]
    procedure T14_AssignVsColonEquals()
    begin
        // ':=' is one token; ': =' (with space) is colon then equals.
        AssertKinds('x:=1', 'IdentifierToken AssignToken Int32LiteralToken EndOfFileToken');
        AssertKinds('x: =1', 'IdentifierToken ColonToken EqualsToken Int32LiteralToken EndOfFileToken');
    end;

    [Test]
    procedure T15_NotEqualsAdjacency()
    begin
        // '<>=' lexes as '<>' then '=' (longest-match, §14 test 1).
        AssertKinds('<>=', 'NotEqualsToken EqualsToken EndOfFileToken');
    end;

    [Test]
    procedure T16_AllCompoundAssigns()
    begin
        AssertKinds('+= -= *= /=',
            'AssignPlusToken AssignMinusToken AssignMultiplyToken AssignRDivToken EndOfFileToken');
    end;

    [Test]
    procedure T17_ColonColonAndDotDot()
    begin
        AssertKinds('a::b', 'IdentifierToken ColonColonToken IdentifierToken EndOfFileToken');
        AssertKinds('.. .', 'DotDotToken DotToken EndOfFileToken');
    end;

    // ===== Keywords: case-insensitive + identifier-look-alike =====

    [Test]
    procedure T18_KeywordsCaseInsensitive()
    begin
        AssertKinds('IF if If iF',
            'IfKeyword IfKeyword IfKeyword IfKeyword EndOfFileToken');
        AssertKinds('BEGIN End',
            'BeginKeyword EndKeyword EndOfFileToken');
        AssertKinds('div MOD And oR xOr NoT',
            'IDivKeyword ModuloKeyword AndKeyword OrKeyword XorKeyword NotKeyword EndOfFileToken');
    end;

    [Test]
    procedure T19_IdentifierInterningCaseInsensitive()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // Foo and FOO intern to the SAME id (case-insensitive), but the first spelling is kept.
        Lex('Foo FOO', Tokens, Diags);
        Assert.AreEqual(20, Tokens.GetKind(1), 'ident 1');
        Assert.AreEqual(20, Tokens.GetKind(2), 'ident 2');
        Assert.AreEqual(Tokens.GetIdentId(1), Tokens.GetIdentId(2), 'same interned id');
        Assert.AreEqual('Foo', Tokens.GetIdentText(1), 'first spelling kept');
    end;

    [Test]
    procedure T20_IdentifierWithUnderscoreAndDigits()
    begin
        AssertKinds('_x1 a2b', 'IdentifierToken IdentifierToken EndOfFileToken');
    end;

    // ===== Empty / whitespace / long =====

    [Test]
    procedure T21_EmptySource()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('', Tokens, Diags);
        Assert.AreEqual(1, Tokens.Count(), 'only EOF');
        Assert.AreEqual(1, Tokens.GetKind(1), 'EOF');
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
    end;

    [Test]
    procedure T22_WhitespaceOnly()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lex('   ' + NewLine() + Tab() + '  ', Tokens, Diags);
        Assert.AreEqual(1, Tokens.Count(), 'only EOF');
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
    end;

    [Test]
    procedure T23_LongIdentifierAndString()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
        I: Integer;
        Long: Text;
    begin
        for I := 1 to 500 do
            Long += 'a';
        Lex(Long, Tokens, Diags);
        Assert.AreEqual(20, Tokens.GetKind(1), 'long ident');
        Assert.AreEqual(Long, Tokens.GetIdentText(1), 'full spelling preserved');
        Assert.AreEqual(500, Tokens.GetLength(1), 'length 500');
    end;

    // ===== Line/column across CRLF vs LF =====

    [Test]
    procedure T24_LineColumnLF()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // "a\nbb\nc" — token on each line, columns reset per line.
        Lex('a' + Lf() + 'bb' + Lf() + 'c', Tokens, Diags);
        AssertPos(Tokens, 1, 1, 1);   // a
        AssertPos(Tokens, 2, 2, 1);   // bb
        AssertPos(Tokens, 3, 3, 1);   // c
    end;

    [Test]
    procedure T25_LineColumnCRLF()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // CRLF counts as ONE line break; column of second-line token is 1.
        Lex('a' + CrLf() + 'b', Tokens, Diags);
        AssertPos(Tokens, 1, 1, 1);   // a
        AssertPos(Tokens, 2, 2, 1);   // b  (not offset by the CR)
    end;

    [Test]
    procedure T26_ColumnMidLine()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // "  x := 1" — x at col 3, := at col 5, 1 at col 8.
        Lex('  x := 1', Tokens, Diags);
        AssertPos(Tokens, 1, 1, 3);   // x
        AssertPos(Tokens, 2, 1, 5);   // :=
        AssertPos(Tokens, 3, 1, 8);   // 1
    end;

    // ===== Preprocessor =====

    // Lex with a project-level symbol set, semicolon-separated ('' = none).
    local procedure LexDef(Source: Text; DefinedSymbols: Text; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        Lexer: Codeunit "ALI Lexer";
        SymbolList: List of [Text];
    begin
        Tokens.Reset();
        Diags.Reset();
        if DefinedSymbols <> '' then
            SymbolList := DefinedSymbols.Split(';');
        Lexer.SetDefinedSymbols(SymbolList);
        Lexer.Tokenize(Source, Tokens, Diags);
    end;

    // Assert the identifiers surviving conditional compilation, in order.
    local procedure AssertIdents(Source: Text; DefinedSymbols: Text; Expected: Text)
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
        I: Integer;
        Actual: Text;
    begin
        LexDef(Source, DefinedSymbols, Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), StrSubstNo('no errors for <%1>', Source));
        for I := 1 to Tokens.Count() - 1 do begin      // -1: skip EOF
            if Actual <> '' then
                Actual += ' ';
            Actual += Tokens.GetIdentText(I);
        end;
        Assert.AreEqual(Expected, Actual, StrSubstNo('kept identifiers for <%1> with [%2]', Source, DefinedSymbols));
    end;

    [Test]
    procedure T27_PragmaIgnored()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // #pragma / #region carry no meaning for the interpreter and cost no diagnostic.
        Lex('#pragma warning disable' + NewLine() + 'x', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors');
        Assert.AreEqual(0, Diags.WarningCount(), 'no warnings');
        Assert.AreEqual(20, Tokens.GetKind(1), 'x after directive still lexes');
    end;

    [Test]
    procedure T27b_IfBranchTakenAndSkipped()
    begin
        AssertIdents('a' + NewLine() + '#if TAG' + NewLine() + 'b' + NewLine() + '#endif' + NewLine() + 'c', 'TAG', 'a b c');
        AssertIdents('a' + NewLine() + '#if TAG' + NewLine() + 'b' + NewLine() + '#endif' + NewLine() + 'c', '', 'a c');
    end;

    [Test]
    procedure T27c_ElseAndElif()
    var
        Source: Text;
    begin
        Source := '#if T1' + NewLine() + 'a' + NewLine() + '#elif T2' + NewLine() + 'b' + NewLine() + '#else' + NewLine() + 'c' + NewLine() + '#endif';
        AssertIdents(Source, 'T1', 'a');
        AssertIdents(Source, 'T2', 'b');
        AssertIdents(Source, 'T1;T2', 'a');            // first match wins, later branches dead
        AssertIdents(Source, '', 'c');
    end;

    [Test]
    procedure T27d_ConditionOperators()
    var
        Source: Text;
    begin
        Source := '#if %1' + NewLine() + 'a' + NewLine() + '#endif';
        AssertIdents(StrSubstNo(Source, 'T1 and T2'), 'T1;T2', 'a');
        AssertIdents(StrSubstNo(Source, 'T1 and T2'), 'T1', '');
        AssertIdents(StrSubstNo(Source, 'T1 or T2'), 'T2', 'a');
        AssertIdents(StrSubstNo(Source, 'not T1'), 'T2', 'a');
        AssertIdents(StrSubstNo(Source, 'not T1'), 'T1', '');
        AssertIdents(StrSubstNo(Source, 'not T1 and (T2 or T3)'), 'T3', 'a');
    end;

    [Test]
    procedure T27e_NestedAndDeadOuterBranch()
    var
        Source: Text;
    begin
        // The inner #if must not resurrect code inside an excluded outer branch.
        Source := '#if OUT' + NewLine() + '#if IN' + NewLine() + 'a' + NewLine() + '#else' + NewLine() + 'b' + NewLine() + '#endif' + NewLine() + '#endif' + NewLine() + 'z';
        AssertIdents(Source, 'OUT;IN', 'a z');
        AssertIdents(Source, 'OUT', 'b z');
        AssertIdents(Source, 'IN', 'z');
    end;

    [Test]
    procedure T27f_DefineAndUndef()
    begin
        AssertIdents('#define T1' + NewLine() + '#if T1' + NewLine() + 'a' + NewLine() + '#endif', '', 'a');
        AssertIdents('#undef T1' + NewLine() + '#if T1' + NewLine() + 'a' + NewLine() + '#endif', 'T1', '');
        // A #define inside an excluded branch has no effect.
        AssertIdents('#if T9' + NewLine() + '#define T1' + NewLine() + '#endif' + NewLine() + '#if T1' + NewLine() + 'a' + NewLine() + '#endif', '', '');
    end;

    [Test]
    procedure T27g_ExcludedTextIsNeverLexed()
    begin
        // Garbage that would not lex is fine as long as it sits in the dead branch.
        AssertIdents('#if T1' + NewLine() + 'this is @@ not ''AL' + NewLine() + '#endif' + NewLine() + 'ok', '', 'ok');
    end;

    [Test]
    procedure T27h_UnterminatedIfIsAnError()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        LexDef('#if T1' + NewLine() + 'a', 'T1', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'missing #endif');
        Assert.AreEqual('ALI910', Diags.GetCode(1), 'unterminated-directive code');
    end;

    [Test]
    procedure T27i_EndifWithoutIfIsAnError()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        LexDef('a' + NewLine() + '#endif', '', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'stray #endif');
        Assert.AreEqual('ALI910', Diags.GetCode(1), 'unterminated-directive code');
    end;

    // ===== Unexpected char recovery =====

    [Test]
    procedure T28_UnexpectedCharBecomesBadToken()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // '@' is not a legal AL token start -> ALI908 + BadToken, scanning continues.
        Lex('a @ b', Tokens, Diags);
        Assert.AreEqual(1, Diags.ErrorCount(), 'one error for @');
        Assert.AreEqual('ALI908', Diags.GetCode(1), 'unexpected-char code');
        // a, BadToken(@), b, EOF
        Assert.AreEqual(4, Tokens.Count(), 'a BadToken b EOF');
        Assert.AreEqual(2, Tokens.GetKind(2), 'BadToken for @');
    end;

    // ===== Unicode identifiers (native AL parity) =====

    [Test]
    procedure T29_AccentedIdentifiers()
    var
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // Native alc accepts Unicode letters unquoted and any char quoted:
        // RabaisSpéciaux := "%RabaisSpéciaux";
        Lex('RabaisSpéciaux := "%RabaisSpéciaux"', Tokens, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'no errors on accented identifiers');
        Assert.AreEqual(4, Tokens.Count(), 'ident := ident EOF');
        Assert.AreEqual('RabaisSpéciaux', Tokens.GetIdentText(1), 'unquoted accented spelling');
        Assert.AreEqual('%RabaisSpéciaux', Tokens.GetIdentText(3), 'quoted accented spelling');
    end;

    // ===== Position assert helper =====

    local procedure AssertPos(var Tokens: Codeunit "ALI Token Table"; Idx: Integer; ExpLine: Integer; ExpCol: Integer)
    begin
        Assert.AreEqual(ExpLine, Tokens.GetLine(Idx), StrSubstNo('line of token %1', Idx));
        Assert.AreEqual(ExpCol, Tokens.GetColumn(Idx), StrSubstNo('col of token %1', Idx));
    end;

    // ===== Newline helpers =====

    local procedure NewLine(): Text
    begin
        exit(CrLf());
    end;

    local procedure CrLf(): Text
    var
        Cr: Char;
        LfC: Char;
    begin
        Cr := 13;
        LfC := 10;
        exit(Format(Cr) + Format(LfC));
    end;

    local procedure Lf(): Text
    var
        LfC: Char;
    begin
        LfC := 10;
        exit(Format(LfC));
    end;

    local procedure Tab(): Text
    var
        T: Char;
    begin
        T := 9;
        exit(Format(T));
    end;

    // ================================================================================================
    // ALI Parser Tests (§14.2) — precedence goldens (esp. the Pascal quirk), statement forms,
    // nested case with ranges, dangling-else / HasSemicolon binding (§5.4), `..` positional
    // coverage (§5.2). S-expression goldens via "ALI Test Pipeline".
    //
    // Each test lexes then parses, asserting no unexpected diagnostics for well-formed input
    // and the exact S-expr shape. Stage isolation: touches Lexer + Parser + stores only.
    // ================================================================================================

    // ===== Helpers =====

    local procedure Pipe(Source: Text; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag")
    var
        Lexer: Codeunit "ALI Lexer";
    begin
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Lexer.Tokenize(Source, Tokens, Diags);
    end;

    // Parse an expression standalone -> S-expr.
    local procedure ExprSExpr(Source: Text): Text
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        Pipe(Source, Tokens, Ast, Diags);
        Root := Parser.ParseExpressionEntry(Tokens, Ast, Diags);
        exit(Pipeline.DumpAst(Ast, Tokens, Root));
    end;

    // Parse a statement block -> S-expr of the whole CompilationUnit.
    local procedure StmtSExpr(Source: Text): Text
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        Pipe(Source, Tokens, Ast, Diags);
        Root := Parser.ParseStatements(Tokens, Ast, Diags);
        exit(Pipeline.DumpAst(Ast, Tokens, Root));
    end;

    local procedure AssertExpr(Source: Text; Expected: Text)
    begin
        Assert.AreEqual(Expected, ExprSExpr(Source), StrSubstNo('expr <%1>', Source));
    end;

    local procedure AssertStmt(Source: Text; Expected: Text)
    begin
        Assert.AreEqual(Expected, StmtSExpr(Source), StrSubstNo('stmt <%1>', Source));
    end;

    // ===== Expression precedence =====

    [Test]
    procedure T01_TermFactor()
    begin
        // a + b * c  ->  + binds looser than *   =>  (a + (b*c))
        AssertExpr('a + b * c', '(Bin + (Name a) (Bin * (Name b) (Name c)))');
    end;

    [Test]
    procedure T02_LeftAssoc()
    begin
        // a - b - c  =>  ((a-b)-c)
        AssertExpr('a - b - c', '(Bin - (Bin - (Name a) (Name b)) (Name c))');
    end;

    [Test]
    procedure T03_PascalPrecedence_AndTighterThanComparison()
    begin
        // FIDELITY TRAP (§5.2): and(5) binds tighter than comparison(3).
        // x > 1 and y < 2  parses as  x > (1 and y) < 2, left-assoc over power 3:
        //   ((x > (1 and y)) < 2)
        AssertExpr('x > 1 and y < 2',
            '(Bin < (Bin > (Name x) (Bin and (Lit 1) (Name y))) (Lit 2))');
    end;

    [Test]
    procedure T04_XorSharesPowerWithOr()
    begin
        // xor(4) and or(4) same power, left-assoc:  a or b xor c => ((a or b) xor c)
        AssertExpr('a or b xor c', '(Bin xor (Bin or (Name a) (Name b)) (Name c))');
    end;

    [Test]
    procedure T05_AndTighterThanOr()
    begin
        // a or b and c  =>  a or (b and c)
        AssertExpr('a or b and c', '(Bin or (Name a) (Bin and (Name b) (Name c)))');
    end;

    [Test]
    procedure T06_UnaryChain()
    begin
        AssertExpr('not not a', '(Un not (Un not (Name a)))');
        AssertExpr('-a * b', '(Bin * (Un - (Name a)) (Name b))');
    end;

    [Test]
    procedure T07_Parens()
    begin
        AssertExpr('(a + b) * c', '(Bin * (Bin + (Name a) (Name b)) (Name c))');
    end;

    [Test]
    procedure T08_PostfixChain()
    begin
        // Rec.FindSet()  =>  Call(callee = Member(.FindSet Rec))
        AssertExpr('Rec.FindSet()', '(Call (Member .FindSet (Name Rec)))');
        AssertExpr('arr[i]', '(Index (Name arr) (Name i))');
        AssertExpr('Rec.Field', '(Member .Field (Name Rec))');
        AssertExpr('Status::Open', '(Option ::Open (Name Status))');
    end;

    [Test]
    procedure T09_CallArgs()
    begin
        AssertExpr('Foo(a, b + 1)',
            '(Call (Name Foo) (Name a) (Bin + (Name b) (Lit 1)))');
    end;

    // ===== Statements =====

    [Test]
    procedure T10_Assignment()
    begin
        AssertStmt('x := 1 + 2;',
            '(Unit (Assign := (Name x) (Bin + (Lit 1) (Lit 2))))');
    end;

    [Test]
    procedure T11_CompoundAssign()
    begin
        AssertStmt('x += 5;', '(Unit (Assign += (Name x) (Lit 5)))');
    end;

    [Test]
    procedure T12_WhileDo()
    begin
        AssertStmt('while a do x := 1;',
            '(Unit (While (Name a) (Assign := (Name x) (Lit 1))))');
    end;

    [Test]
    procedure T13_ForTo()
    begin
        AssertStmt('for i := 1 to 10 do x := i;',
            '(Unit (For (Name i) (Lit 1) (Lit 10) (Assign := (Name x) (Name i))))');
    end;

    [Test]
    procedure T14_RepeatUntil()
    begin
        // repeat body-stmts + until cond (cond = last child, §5.5)
        AssertStmt('repeat x := 1; until a;',
            '(Unit (Repeat (Assign := (Name x) (Lit 1)) (Name a)))');
    end;

    [Test]
    procedure T15_Block()
    begin
        AssertStmt('begin a(); b(); end;',
            '(Unit (Block (ExprStmt (Call (Name a))) (ExprStmt (Call (Name b)))))');
    end;

    [Test]
    procedure T16_ExitValue()
    begin
        AssertStmt('exit(42);', '(Unit (Exit (Lit 42)))');
        AssertStmt('exit;', '(Unit (Exit _))');
    end;

    // ===== case with ranges + else (`..` positional, §5.2) =====

    [Test]
    procedure T17_CaseRangesAndElse()
    begin
        // labels: value list + range 5..9 ; else body. `..` builds a Range node positionally.
        AssertStmt('case x of 1, 3: a(); 5..9: b(); else c(); end;',
            '(Unit (Case (Name x)' +
            ' (CaseLine (Lit 1) (Lit 3) (ExprStmt (Call (Name a))))' +
            ' (CaseLine (Range (Lit 5) (Lit 9)) (ExprStmt (Call (Name b))))' +
            ' (CaseElse (ExprStmt (Call (Name c))))))');
    end;

    // ===== if / else — HasSemicolon binding (§5.4) =====

    [Test]
    procedure T18_IfThenElse_NoSemicolonAttaches()
    begin
        // Foo() has no ';' before else  => else attaches (§5.4 table row 1).
        AssertStmt('if C then Foo() else Bar();',
            '(Unit (If (Name C) (ExprStmt (Call (Name Foo))) (ExprStmt (Call (Name Bar)))))');
    end;

    [Test]
    procedure T19_IfThen_SemicolonBlocksElse_Orphaned()
    begin
        // Foo(); HAS ';'  => else does NOT attach; the else is an orphaned-else error node.
        AssertStmt('if C then Foo(); else Bar();',
            '(Unit (If (Name C) (ExprStmt (Call (Name Foo))) _)' +
            ' (OrphanElse (ExprStmt (Call (Name Bar)))))');
    end;

    [Test]
    procedure T20_IfBeginEnd_NoSemicolon_ElseAttaches()
    begin
        // begin..end (no ';') => HasSemicolon false => else attaches (§5.4 table row 3).
        AssertStmt('if C then begin Foo() end else Bar();',
            '(Unit (If (Name C) (Block (ExprStmt (Call (Name Foo)))) (ExprStmt (Call (Name Bar)))))');
    end;

    [Test]
    procedure T21_DanglingElse_BindsToInnerIf()
    begin
        // inner if owns the else (§5.4 table last row) — falls out of the algorithm free.
        AssertStmt('if C then if D then A() else B();',
            '(Unit (If (Name C)' +
            ' (If (Name D) (ExprStmt (Call (Name A))) (ExprStmt (Call (Name B)))) _))');
    end;

    // ================================================================================================
    // ALI Parser Recovery Tests (§14.3) — error recovery is a HARD requirement (§5.2):
    // never stop at first error, always reach EOF, never runtime-error / hang.
    //
    // Covers: multiple seeded errors all reported; missing ';', missing 'then', unclosed
    // 'begin'; garbage between statements; the §5.4 depth guard on a deep nested-if chain
    // (200+) must produce a diagnostic, NOT crash the uncatchable AL stack.
    // ================================================================================================

    local procedure Parse(Source: Text; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Lexer: Codeunit "ALI Lexer";
        Parser: Codeunit "ALI Parser";
    begin
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Lexer.Tokenize(Source, Tokens, Diags);
        exit(Parser.ParseStatements(Tokens, Ast, Diags));
    end;

    // ===== Missing tokens =====

    [Test]
    procedure T01_MissingThen()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Parse('if a b();', Tokens, Ast, Diags);  // no 'then'
        Assert.IsTrue(Diags.HasErrors(), 'missing then reported');
        Assert.IsTrue(HasCode(Diags, 'AL0132'), 'AL0132 expected-token');
    end;

    [Test]
    procedure T02_MissingSemicolonSeparator()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // begin A() B() end — one missing ';' on B (§5.4 rule 4: separates, last optional).
        Parse('begin a() b() end;', Tokens, Ast, Diags);
        Assert.IsTrue(Diags.HasErrors(), 'missing separator reported');
    end;

    [Test]
    procedure T03_MissingSemicolon_LastOptional()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // begin A(); B() end — final ';' omitted is LEGAL (§5.4 rule 4).
        Parse('begin a(); b() end;', Tokens, Ast, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'trailing ; is optional -> no error');
    end;

    [Test]
    procedure T04_UnclosedBegin()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Parse('begin a();', Tokens, Ast, Diags);  // no 'end'
        Assert.IsTrue(Diags.HasErrors(), 'unclosed begin reported');
    end;

    // ===== Multiple errors + reaches EOF =====

    [Test]
    procedure T05_MultipleErrorsAllReported()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // three seeded problems: missing then, missing ')', orphaned else.
        Parse('if a b(; x := 1; else y();', Tokens, Ast, Diags);
        Assert.IsTrue(Diags.ErrorCount() >= 2, 'multiple errors reported, not just first');
    end;

    [Test]
    procedure T06_GarbageBetweenStatements_ReachesEof()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        // Garbage tokens between valid statements; parser must sync and reach EOF.
        Parse('x := 1; @ @ @ ; y := 2;', Tokens, Ast, Diags);
        Assert.IsTrue(Ast.Count() > 0, 'produced a tree');
        // A well-behaved parser reaches EOF without hanging — reaching here IS the assertion.
        Assert.IsTrue(true, 'terminated');
    end;

    [Test]
    procedure T07_OrphanedElse()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
    begin
        Parse('else x();', Tokens, Ast, Diags);
        Assert.IsTrue(HasCode(Diags, 'ALI903'), 'orphaned-else diagnostic');
    end;

    // ===== Depth guard (§5.4 — nested if is the primary stack driver) =====

    [Test]
    procedure T08_DeepNestedIf_GuardTripsNoCrash()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
        i: Integer;
        Sb: TextBuilder;
    begin
        // 250-deep nested if — exceeds MaxNestingDepth (200). Must emit ALI901, not
        // overflow the AL stack (uncatchable).
        for i := 1 to 250 do
            Sb.Append('if a then ');
        Sb.Append('x();');
        Parse(Sb.ToText(), Tokens, Ast, Diags);
        Assert.IsTrue(HasCode(Diags, 'ALI901'), 'depth guard fired');
    end;

    [Test]
    procedure T09_DeepExpression_GuardTripsNoCrash()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Tokens: Codeunit "ALI Token Table";
        i: Integer;
        Sb: TextBuilder;
    begin
        // 300 nested parens — expression recursion depth guard.
        for i := 1 to 300 do
            Sb.Append('(');
        Sb.Append('a');
        for i := 1 to 300 do
            Sb.Append(')');
        Sb.Append(';');
        Parse(Sb.ToText(), Tokens, Ast, Diags);
        Assert.IsTrue(HasCode(Diags, 'ALI901'), 'expression depth guard fired');
    end;

    // ===== Helper =====

    // ===== Early input-format detection (ALI949) =====

    [Test]
    procedure T20_ObjectDeclInput_Rejected()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Lexer: Codeunit "ALI Lexer";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lexer.Tokenize('page 50100 "My Page" { }', Tokens, Diags);
        Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        Assert.IsTrue(HasCode(Diags, 'ALI949'), 'page object declaration rejected with ALI949');
        Assert.AreEqual(1, Diags.ErrorCount(), 'exactly ONE diagnostic — no cascade');
    end;

    [Test]
    procedure T21_ObjectDeclInput_IdentifierSpelled()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Lexer: Codeunit "ALI Lexer";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lexer.Tokenize('tableextension 50100 Ext extends Customer { }', Tokens, Diags);
        Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        Assert.IsTrue(HasCode(Diags, 'ALI949'), 'tableextension declaration rejected with ALI949');
    end;

    [Test]
    procedure T22_CodeunitShell_StillAccepted()
    var
        Ast: Codeunit "ALI Ast Store";
        Diags: Codeunit "ALI Diag Bag";
        Lexer: Codeunit "ALI Lexer";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
    begin
        Lexer.Tokenize('codeunit 50999 T { trigger OnRun() begin end }', Tokens, Diags);
        Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        Assert.AreEqual(0, Diags.ErrorCount(), 'codeunit shell must stay accepted');
    end;

    // ===== Verbose diagnostics (source line + caret + hint) =====

    [Test]
    procedure T23_VerboseDiag_QuotesSourceLine()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        Rendered: Text;
    begin
        Engine.SetVerbose(true);
        Assert.IsFalse(Engine.Compile('begin x := 1; end;', Diags), 'undeclared x fails compile');
        Rendered := Diags.ToText();
        Assert.IsTrue(Rendered.Contains('| begin x := 1; end;'), 'verbose output quotes the source line');
        Assert.IsTrue(Rendered.Contains('hint:'), 'verbose output carries a hint');
    end;

    local procedure HasCode(var Diags: Codeunit "ALI Diag Bag"; Code: Text): Boolean
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if Diags.GetCode(i) = Code then
                exit(true);
        exit(false);
    end;

    // ================================================================================================
    // ALI Api Catalog Tests — the editor-facing catalog stays valid JSON and in sync with the
    // interpreter surface: spot-probes compile a snippet per sampled catalog entry so a method
    // listed for completion is guaranteed to actually bind (drift guard between "ALI Api
    // Catalog" and the binder's *MethodId tables).
    // ================================================================================================

    [Test]
    procedure T01_CatalogJsonParsesWithExpectedShape()
    var
        Root: JsonObject;
        Tok: JsonToken;
    begin
        Assert.IsTrue(Root.ReadFrom(ApiCatalog.BuildCatalogJson()), 'catalog must be valid JSON');
        Assert.IsTrue(Root.Get('types', Tok), 'catalog has a types array');
        Assert.IsTrue(Tok.AsArray().Count() > 20, 'types array is populated');
        Assert.IsTrue(Root.Get('builtins', Tok), 'catalog has a builtins array');
        Assert.IsTrue(Tok.AsArray().Count() > 40, 'builtins array is populated');
        Assert.IsTrue(Root.Get('methods', Tok), 'catalog has a methods object');
        Assert.IsTrue(Tok.AsObject().Contains('Record'), 'methods covers Record');
        Assert.IsTrue(Tok.AsObject().Contains('JsonObject'), 'methods covers JsonObject');
        Assert.IsTrue(Tok.AsObject().Contains('HttpClient'), 'methods covers HttpClient');
    end;

    [Test]
    procedure T02_JsonObjectCatalogListsTypedGetters()
    var
        Found: Boolean;
        i: Integer;
        Root: JsonObject;
        MethodTok: JsonToken;
        NameTok: JsonToken;
        Tok: JsonToken;
    begin
        Root.ReadFrom(ApiCatalog.BuildCatalogJson());
        Root.Get('methods', Tok);
        Tok.AsObject().Get('JsonObject', Tok);
        for i := 0 to Tok.AsArray().Count() - 1 do begin
            Tok.AsArray().Get(i, MethodTok);
            MethodTok.AsObject().Get('n', NameTok);
            if NameTok.AsValue().AsText() = 'GetText' then
                Found := true;
        end;
        Assert.IsTrue(Found, 'JsonObject method list includes the typed getter GetText');
    end;

    [Test]
    procedure T03_SampledCatalogMethodsBind()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // One probe per family with fixed, valid arguments — a rename/removal in the binder
        // breaks the corresponding catalog row loudly here.
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var o: JsonObject; procedure P(): Text begin exit(o.GetText(''k'', true)); end;', Diags), 'JsonObject.GetText binds');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var c: HttpClient; procedure P(): Boolean begin exit(c.DefaultRequestHeaders().TryAddWithoutValidation(''a'', ''b'')); end;', Diags), 'HttpClient chained headers bind');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var l: List of [Text]; procedure P(): Integer begin l.Add(''x''); exit(l.Count()); end;', Diags), 'List methods bind');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var tb: TextBuilder; procedure P(): Text begin tb.Append(''x''); exit(tb.ToText()); end;', Diags), 'TextBuilder methods bind');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var bt: BigText; procedure P(): Integer begin bt.AddText(''x''); exit(bt.TextPos(''x'')); end;', Diags), 'BigText methods bind');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var st: SecretText; procedure P(): Text begin st := ''x''; exit(st.Unwrap()); end;', Diags), 'SecretText methods bind');
    end;

    [Test]
    procedure T04_TableFieldsJsonForKnownTable()
    var
        Arr: JsonArray;
        FieldsJson: Text;
    begin
        FieldsJson := ApiCatalog.BuildTableFieldsJson('ALI Stored Script', false);
        Assert.IsTrue(Arr.ReadFrom(FieldsJson), 'field list must be valid JSON');
        Assert.IsTrue(Arr.Count() > 0, 'known table yields a non-empty field list');
    end;

    [Test]
    procedure T05_TableFieldsJsonForUnknownTable()
    var
        Arr: JsonArray;
    begin
        Assert.IsTrue(Arr.ReadFrom(ApiCatalog.BuildTableFieldsJson('No Such Table XYZ', true)), 'unknown table returns valid JSON');
        Assert.AreEqual(0, Arr.Count(), 'unknown table returns an empty array');
    end;

    // Procedure rows only appear when asked for, and never as pseudo-fields: they carry k='p'
    // plus a signature, which is what the editor filters on to keep `SetRange(` field-only.
    [Test]
    procedure T06_TableProcedureRowsAreTagged()
    var
        i: Integer;
        Arr: JsonArray;
        Row: JsonToken;
        Tok: JsonToken;
    begin
        Arr.ReadFrom(ApiCatalog.BuildTableFieldsJson('ALI Stored Script', true));
        for i := 0 to Arr.Count() - 1 do begin
            Arr.Get(i, Row);
            if Row.AsObject().Get('k', Tok) then begin
                Assert.AreEqual('p', Tok.AsValue().AsText(), 'only procedure rows carry a kind');
                Assert.IsTrue(Row.AsObject().Get('s', Tok), 'a procedure row carries its signature');
                Assert.IsTrue(Tok.AsValue().AsText().Contains('('), 'the signature has a parameter list');
            end;
        end;
    end;

    // The editor completes `IsolatedStorage.` from the catalog's methods map and `DataScope::`
    // from its optionsets map — both must be present, and the option members must stay in
    // ordinal order (the editor shows `v` as the member's value).
    [Test]
    procedure T07_StaticReceiverAndOptionSetsArePublished()
    var
        Root: JsonObject;
        MemberTok: JsonToken;
        NameTok: JsonToken;
        Tok: JsonToken;
        i: Integer;
        Names: Text;
    begin
        Root.ReadFrom(ApiCatalog.BuildCatalogJson());
        Root.Get('methods', Tok);
        Assert.IsTrue(Tok.AsObject().Contains('IsolatedStorage'), 'methods covers the IsolatedStorage static receiver');
        Tok.AsObject().Get('IsolatedStorage', Tok);
        for i := 0 to Tok.AsArray().Count() - 1 do begin
            Tok.AsArray().Get(i, MemberTok);
            MemberTok.AsObject().Get('n', NameTok);
            Names += NameTok.AsValue().AsText() + ',';
        end;
        Assert.AreEqual('Set,SetEncrypted,Get,Contains,Delete,', Names, 'every IsolatedStorage member is offered');

        Root.Get('optionsets', Tok);
        Assert.IsTrue(Tok.AsObject().Contains('DataScope'), 'optionsets covers DataScope');
        Assert.IsTrue(Tok.AsObject().Contains('TextEncoding'), 'optionsets covers TextEncoding');
        Tok.AsObject().Get('DataScope', Tok);
        Assert.AreEqual(4, Tok.AsArray().Count(), 'DataScope has four members');
        Tok.AsArray().Get(1, MemberTok);
        MemberTok.AsObject().Get('n', NameTok);
        Assert.AreEqual('Company', NameTok.AsValue().AsText(), 'members are in ordinal order');
        MemberTok.AsObject().Get('v', NameTok);
        Assert.AreEqual(1, NameTok.AsValue().AsInteger(), 'the ordinal rides along as v');
    end;

    // Drift guard for the published option sets: each member name must actually bind through
    // `::` in a script, so a rename in "ALI Binder".TrySystemOptionSet breaks loudly here.
    [Test]
    procedure T08_PublishedOptionSetMembersBind()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsTrue(Pipeline.CompileExpectingErrors('procedure P(): Boolean begin exit(IsolatedStorage.Contains(''k'', DataScope::CompanyAndUser)); end;', Diags), 'DataScope members bind');
        Assert.IsTrue(Pipeline.CompileExpectingErrors('var c: Record "ALI Stored Script"; procedure P() begin c.ReadIsolation(IsolationLevel::UpdLock); end;', Diags), 'IsolationLevel members bind');
    end;

    // ================================================================================================
    // ALI Diagnostics for LLM hosts — "did you mean", no cascade after an unknown callee, hint
    // dedupe, hidden codes, ALI1004 FlowField warning, runtime index hint.
    // ================================================================================================

    [Test]
    procedure D01_DidYouMeanFindsCloseNames()
    var
        Diags: Codeunit "ALI Diag Bag";
        Names: List of [Text];
    begin
        Names.Add('SetAutoCalcFields');
        Names.Add('SetRange');
        Names.Add('G/L Account No.');
        Assert.IsTrue(Diags.DidYouMean('SetAutoCalcField', Names).Contains('''SetAutoCalcFields'''), 'missing plural s');
        Assert.IsTrue(Diags.DidYouMean('Account No.', Names).Contains('''G/L Account No.'''), 'partial field name');
        Assert.IsTrue(Diags.DidYouMean('setrnage', Names).Contains('''SetRange'''), 'transposed letters, any case');
        Assert.AreEqual('', Diags.DidYouMean('Customer', Names), 'nothing close -> no suggestion');
    end;

    [Test]
    procedure D02_UnknownRecordMethodSuggestsWithoutCascade()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        PrepareEngine(false);
        Assert.IsFalse(DiagEngine.Compile('procedure P() var c: Record Customer; begin c.SetOrder("Vendor No."); c.SetAutoCalcField("Balance (LCY)"); end;', Diags), 'unknown methods fail');
        Assert.AreEqual(2, Diags.ErrorCount(), StrSubstNo('one error per unknown method, none for their arguments: %1', Diags.ToText()));
        Assert.IsTrue(Diags.GetMessage(2).Contains('SetAutoCalcFields'), StrSubstNo('suggests the real method: %1', Diags.GetMessage(2)));
    end;

    [Test]
    procedure D03_UnknownFieldSuggestsFieldName()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        PrepareEngine(false);
        Assert.IsFalse(DiagEngine.Compile('procedure P() var c: Record Customer; t: Text; begin t := c."Nam"; end;', Diags), 'unknown field fails');
        Assert.IsTrue(Diags.GetMessage(1).Contains('''Name'''), StrSubstNo('suggests the field: %1', Diags.GetMessage(1)));
    end;

    [Test]
    procedure D04_VerboseHintOncePerRenderAndHiddenCodes()
    var
        Diags: Codeunit "ALI Diag Bag";
        Rendered: Text;
    begin
        Diags.SetVerbose(true);
        Diags.AddError('ALI984', 'Dictionary key type expected after ''of [''', 0, 0);
        Diags.AddError('ALI984', 'Dictionary key type expected after ''of [''', 0, 0);
        Rendered := Diags.ToText();
        Assert.IsTrue(Rendered.Contains('Dictionary of [Text, Integer]'), 'collection hint carries a declaration example');
        Assert.AreEqual(1, Rendered.Split('hint:').Count() - 1, 'the same hint is printed once');
        Assert.IsTrue(Rendered.Contains('ALI984'), 'codes shown by default');
        Diags.SetHideCodes(true);
        Assert.IsFalse(Diags.ToText().Contains('ALI984'), 'codes hidden on request');
    end;

    [Test]
    procedure D05_FlowFieldReadWithoutCalcWarns()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        PrepareEngine(false);
        Assert.IsTrue(DiagEngine.Compile('procedure P() var c: Record Customer; d: Decimal; begin if c.FindFirst() then d := c."Balance (LCY)"; end;', Diags), 'a warning does not fail the compile');
        Assert.AreEqual(1, Diags.WarningCount(), 'uncalculated FlowField read warns');
        Assert.AreEqual('ALI1004', Diags.GetCode(1), 'ALI1004');

        Assert.IsTrue(DiagEngine.Compile('procedure P() var c: Record Customer; d: Decimal; begin c.SetAutoCalcFields("Balance (LCY)"); if c.FindFirst() then d := c."Balance (LCY)"; end;', Diags), 'clean compile');
        Assert.AreEqual(0, Diags.WarningCount(), 'SetAutoCalcFields anywhere in the body silences it');
    end;

    [Test]
    procedure D06_RuntimeListIndexHintsOneBased()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        PrepareEngine(true);
        Assert.IsFalse(DiagEngine.CompileAndRun('procedure P() var l: List of [Integer]; i: Integer; begin l.Add(1); i := l.Get(0); end;', Result), 'Get(0) fails');
        PrepareEngine(false);
        Assert.IsTrue(Result.ToText().Contains('1-based'), StrSubstNo('runtime hint reminds 1-based: %1', Result.ToText()));
    end;

    [Test]
    procedure D07_FormatStringAsLengthIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        PrepareEngine(false);
        Assert.IsFalse(DiagEngine.Compile('procedure P() var d: Decimal; t: Text; begin t := Format(d, ''<0,###,##0.00>''); end;', Diags), 'format string in the Length slot fails');
        Assert.IsTrue(Diags.GetMessage(1).Contains('Length'), StrSubstNo('names the Length argument: %1', Diags.GetMessage(1)));
        Assert.IsTrue(DiagEngine.Compile('procedure P() var d: Decimal; t: Text; begin t := Format(d, 0, ''<Precision,2:2><Standard Format,0>''); end;', Diags), StrSubstNo('3-arg form stays valid: %1', Diags.ToText()));
    end;

    // Engine and Run Options are single-instance: pin every flag these tests depend on.
    local procedure PrepareEngine(Verbose: Boolean)
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        RunOpt.Reset();
        DiagEngine.SetRequireOnRun(false);
        DiagEngine.SetVerbose(Verbose);
    end;
}
#endif
