// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Pipeline — shared front-to-back driver for runtime tests (§14).
//
// Wires Lexer -> Parser -> Binder -> Lowerer -> Interpreter by hand (there is NO Engine
// facade yet — that lands in M5). Reused by BOTH the expression tests and the later
// control-flow tests, so it stays GENERIC: no assertions about specific values, no test
// logic. It only guarantees a clean pipeline contract:
//   * every single-instance codeunit is Reset() before each run (§14 item 6);
//   * CompileAndRun asserts the front end produced NO diagnostics, then runs — the returned
//     Boolean is the run's Succeeded flag (a raised runtime error is a legitimate result,
//     surfaced via ExecResult, NOT an assertion failure);
//   * CompileExpectingErrors compiles WITHOUT running and hands back the DiagBag so a caller
//     can assert on expected compile-time errors.
//
// Source convention: callers pass a bare AL statement block (form 0) OR a single
// `procedure` (form 1). ParseCompilationUnit classifies automatically; a bare block with a
// leading `exit(expr)` infers the result type/slot so typed getters work (§ binder BindExit).
codeunit 51055 "ALI Test Pipeline"
{
    Access = Public;
    SingleInstance = false;

    var
        Assert: Codeunit "Library Assert";
        OptimizeEnabled: Boolean;

    // Run the optimizer passes (§12) between Bind and Lower for subsequent compiles — off by
    // default so existing tests exercise the unoptimized path unchanged.
    procedure SetOptimize(Value: Boolean)
    begin
        OptimizeEnabled := Value;
    end;

    // Compile Source through the whole front end + lowerer, load, and run.
    // Asserts a clean compile (no diagnostics). Returns ExecResult.Succeeded().
    // A failed run is NOT an assertion failure — inspect Result for the captured error.
    procedure CompileAndRun(Source: Text; var Result: Codeunit "ALI Exec Result"; var Interp: Codeunit "ALI Interpreter"): Boolean
    var
        Diags: Codeunit "ALI Diag Bag";
        Module: Codeunit "ALI Module";
    begin
        if not Compile(Source, Module, Diags) then begin
            Assert.Fail(StrSubstNo('Unexpected compile diagnostics for <%1>: %2', Source, FirstDiag(Diags)));
            exit(false);
        end;

        Interp.Reset();
        Interp.LoadModule(Module);
        Interp.Run(Result);
        exit(Result.Succeeded());
    end;

    [TryFunction]
    procedure TryCompileAndRun(Source: Text; var Result: Codeunit "ALI Exec Result"; var Interp: Codeunit "ALI Interpreter")
    begin
        CompileAndRun(Source, Result, Interp);
    end;

    // Compile only (no run). Returns the front-end success flag; the caller inspects Diags.
    // Use for expected compile-time-error cases.
    procedure CompileExpectingErrors(Source: Text; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Module: Codeunit "ALI Module";
    begin
        exit(Compile(Source, Module, Diags));
    end;

    // Compile and hand back the Module (for disassembly / white-box inspection).
    // Asserts a clean compile.
    procedure CompileToModule(Source: Text; var Module: Codeunit "ALI Module")
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        if not Compile(Source, Module, Diags) then
            Assert.Fail(StrSubstNo('Unexpected compile diagnostics for <%1>: %2', Source, FirstDiag(Diags)));
    end;

    // ===== Internal wiring =====

    local procedure Compile(Source: Text; var Module: Codeunit "ALI Module"; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        Lexer: Codeunit "ALI Lexer";
        Lowerer: Codeunit "ALI Lowerer";
        ObjRegistry: Codeunit "ALI Object Registry";
        Parser: Codeunit "ALI Parser";
        PassMgr: Codeunit "ALI Pass Manager";
        Symbols: Codeunit "ALI Symbol Table";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Symbols.Reset();
        ObjRegistry.Reset();
        Module.Reset();

        Lexer.Tokenize(Source, Tokens, Diags);
        if Diags.HasErrors() then
            exit(false);

        Root := Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        if Diags.HasErrors() then
            exit(false);

        if not Binder.Bind(Tokens, Ast, Symbols, Diags, Module, Root) then
            exit(false);

        if OptimizeEnabled then begin
            PassMgr.Reset();
            PassMgr.AddDefault();
            PassMgr.RunAll(Tokens, Ast, Symbols, Diags, Root);
        end;

        exit(Lowerer.Lower(Tokens, Ast, Symbols, Diags, Module, Root));
    end;

    // First ERROR, not first diagnostic: the bag also carries informationals (M11 phase B's
    // ALI923, added early during the harvest), and blaming a failed compile on one of those
    // sends the reader after the wrong thing.
    local procedure FirstDiag(var Diags: Codeunit "ALI Diag Bag"): Text
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if Diags.GetSeverity(i) = "ALI Severity"::Error then
                exit(StrSubstNo('%1 %2 (line %3)', Diags.GetCode(i), Diags.GetMessage(i), Diags.GetLine(i)));
        exit('<none>');
    end;

    // ================================================================================================
    // ALI Ast Dump — S-expression golden renderer for a parsed AST (§4.2 DumpSExpression,
    // §14 golden-text principle). Stable, position-free shape so precedence/child-order
    // assertions read cleanly:
    //
    //   (KindName payload child child ...)
    //
    // - Leaf literal/name nodes render their value inline: (Lit 42), (Name Customer),
    //   (Bin + (..) (..)), (Member .Field (..)), (Option ::Open (..)).
    // - MissingNode renders as `_`.
    // - Operator tokens on Binary/Unary/Assignment render the operator SYMBOL, not ordinal.
    //
    // Test-side only so the golden format can evolve without touching the engine. Needs the
    // Token Table (to resolve literal/identifier values by pool index).
    // ================================================================================================

    // Render the subtree rooted at NodeIdx as an S-expression.
    procedure DumpAst(var Ast: Codeunit "ALI Ast Store"; var Tokens: Codeunit "ALI Token Table"; NodeIdx: Integer): Text
    var
        Sb: TextBuilder;
    begin
        Emit(Ast, Tokens, NodeIdx, Sb);
        exit(Sb.ToText());
    end;

    local procedure Emit(var Ast: Codeunit "ALI Ast Store"; var Tokens: Codeunit "ALI Token Table"; NodeIdx: Integer; var Sb: TextBuilder)
    var
        i: Integer;
        Kind: Integer;
    begin
        if NodeIdx = 0 then begin
            Sb.Append('_');
            exit;
        end;
        Kind := Ast.GetKind(NodeIdx);
        if Kind = 1 then begin          // MissingNode
            Sb.Append('_');
            exit;
        end;

        Sb.Append('(');
        Sb.Append(AstKindName(Kind));

        // Inline payload for the value-bearing / operator-bearing kinds.
        AppendPayload(Ast, Tokens, NodeIdx, Kind, Sb);

        // Children.
        for i := 0 to Ast.GetChildCount(NodeIdx) - 1 do begin
            Sb.Append(' ');
            Emit(Ast, Tokens, Ast.GetChild(NodeIdx, i), Sb);
        end;

        Sb.Append(')');
    end;

    // Per-kind inline payload (rendered right after the kind name).
    local procedure AppendPayload(var Ast: Codeunit "ALI Ast Store"; var Tokens: Codeunit "ALI Token Table"; NodeIdx: Integer; Kind: Integer; var Sb: TextBuilder)
    var
        Extra: Integer;
        MainTok: Integer;
    begin
        MainTok := Ast.GetMainToken(NodeIdx);
        Extra := Ast.GetExtra(NodeIdx);
        case Kind of
            60, 61, 39:                 // Binary / Unary / Assignment -> operator symbol
                begin
                    Sb.Append(' ');
                    Sb.Append(OpSymbol(Extra));
                end;
            62:                         // LiteralExpr -> the literal's value
                begin
                    Sb.Append(' ');
                    Sb.Append(LiteralText(Tokens, MainTok));
                end;
            63:                         // NameExpr -> identifier spelling
                begin
                    Sb.Append(' ');
                    Sb.Append(Tokens.GetIdentText(MainTok));
                end;
            64:                         // MemberAccess -> .member
                begin
                    Sb.Append(' .');
                    Sb.Append(Tokens.GetIdentText(MainTok));
                end;
            67:                         // OptionAccess -> ::member
                begin
                    Sb.Append(' ::');
                    Sb.Append(Tokens.GetIdentText(MainTok));
                end;
            12, 13, 14:                 // VarDecl / ProcDecl / Param -> name
                begin
                    Sb.Append(' ');
                    Sb.Append(Tokens.GetIdentText(MainTok));
                end;
        end;
    end;

    // The literal token's rendered value (type inferred from token kind, §5.5).
    local procedure LiteralText(var Tokens: Codeunit "ALI Token Table"; TokenIdx: Integer): Text
    var
        Vi: Integer;
    begin
        Vi := Tokens.GetValueIndex(TokenIdx);
        case Tokens.GetKind(TokenIdx) of
            10:
                exit(Format(Tokens.GetInt(Vi), 0, 9));
            11:
                exit(Format(Tokens.GetBigInt(Vi), 0, 9));
            12:
                exit(Format(Tokens.GetDec(Vi), 0, 9));
            13:
                exit(Format(Tokens.GetDate(Vi), 0, 9));
            14:
                exit(Format(Tokens.GetTime(Vi), 0, 9));
            15:
                exit(Format(Tokens.GetDateTime(Vi), 0, 9));
            16:
                exit('''' + Tokens.GetText(Vi) + '''');
            21:
                exit('true');
            22:
                exit('false');
            else
                exit('?');
        end;
    end;

    // Operator token-kind ordinal -> symbol.
    local procedure OpSymbol(K: Integer): Text
    begin
        case K of
            30:
                exit('+');
            31:
                exit('-');
            32:
                exit('*');
            33:
                exit('/');
            34:
                exit('div');
            35:
                exit('mod');
            40:
                exit(':=');
            41:
                exit('+=');
            42:
                exit('-=');
            43:
                exit('*=');
            44:
                exit('/=');
            50:
                exit('=');
            51:
                exit('<>');
            52:
                exit('<');
            53:
                exit('<=');
            54:
                exit('>');
            55:
                exit('>=');
            60:
                exit('and');
            61:
                exit('or');
            62:
                exit('xor');
            63:
                exit('not');
            else
                exit(StrSubstNo('op%1', K));
        end;
    end;

    // NodeKind ordinal -> short S-expr tag (mirrors "ALI NodeKind"; compact for goldens).
    local procedure AstKindName(Kind: Integer): Text
    begin
        case Kind of
            1:
                exit('Missing');
            2:
                exit('Err');
            3:
                exit('ErrStmt');
            4:
                exit('Skipped');
            10:
                exit('Unit');
            11:
                exit('VarSec');
            12:
                exit('Var');
            13:
                exit('Proc');
            14:
                exit('Param');
            15:
                exit('Type');
            16:
                exit('Params');
            30:
                exit('Block');
            31:
                exit('If');
            32:
                exit('While');
            33:
                exit('Repeat');
            34:
                exit('For');
            35:
                exit('ForEach');
            36:
                exit('Case');
            37:
                exit('CaseLine');
            38:
                exit('CaseElse');
            39:
                exit('Assign');
            40:
                exit('ExprStmt');
            41:
                exit('Exit');
            42:
                exit('Break');
            43:
                exit('Empty');
            44:
                exit('OrphanElse');
            60:
                exit('Bin');
            61:
                exit('Un');
            62:
                exit('Lit');
            63:
                exit('Name');
            64:
                exit('Member');
            65:
                exit('Call');
            66:
                exit('Index');
            67:
                exit('Option');
            68:
                exit('Range');
            69:
                exit('InList');
            else
                exit(StrSubstNo('Node%1', Kind));
        end;
    end;

    // ================================================================================================
    // ALI Token Dump — golden-text renderer for a tokenized source (§14 principle:
    // golden-text comparison for structures). One token per line, stable shape:
    //
    //   <KindName> @<line>:<col> +<len> [<value>] {<trivia>}
    //
    // - <value> printed only for tokens that carry a pool value (literals / identifiers).
    // - {<trivia>} printed only when trivia bits are set ('c'=leading-comment, 'n'=precedes-newline).
    // - EndOfFileToken has no value/trivia section.
    //
    // Kept in the TEST app so the golden format can evolve without touching the engine.
    // ================================================================================================

    // TokenKind ordinal -> human name (mirrors "ALI TokenKind"). Test-side only.
    local procedure TokenKindName(Kind: Integer): Text
    begin
        case Kind of
            0:
                exit('None');
            1:
                exit('EndOfFileToken');
            2:
                exit('BadToken');
            3:
                exit('MissingToken');
            10:
                exit('Int32LiteralToken');
            11:
                exit('Int64LiteralToken');
            12:
                exit('DecimalLiteralToken');
            13:
                exit('DateLiteralToken');
            14:
                exit('TimeLiteralToken');
            15:
                exit('DateTimeLiteralToken');
            16:
                exit('StringLiteralToken');
            20:
                exit('IdentifierToken');
            21:
                exit('TrueKeyword');
            22:
                exit('FalseKeyword');
            30:
                exit('PlusToken');
            31:
                exit('MinusToken');
            32:
                exit('MultiplyToken');
            33:
                exit('RDivToken');
            34:
                exit('IDivKeyword');
            35:
                exit('ModuloKeyword');
            40:
                exit('AssignToken');
            41:
                exit('AssignPlusToken');
            42:
                exit('AssignMinusToken');
            43:
                exit('AssignMultiplyToken');
            44:
                exit('AssignRDivToken');
            50:
                exit('EqualsToken');
            51:
                exit('NotEqualsToken');
            52:
                exit('LessThanToken');
            53:
                exit('LessThanEqualsToken');
            54:
                exit('GreaterThanToken');
            55:
                exit('GreaterThanEqualsToken');
            60:
                exit('AndKeyword');
            61:
                exit('OrKeyword');
            62:
                exit('XorKeyword');
            63:
                exit('NotKeyword');
            70:
                exit('OpenParenToken');
            71:
                exit('CloseParenToken');
            72:
                exit('OpenBracketToken');
            73:
                exit('CloseBracketToken');
            74:
                exit('OpenBraceToken');
            75:
                exit('CloseBraceToken');
            76:
                exit('CommaToken');
            77:
                exit('DotToken');
            78:
                exit('DotDotToken');
            79:
                exit('ColonToken');
            80:
                exit('ColonColonToken');
            81:
                exit('SemicolonToken');
            100:
                exit('IfKeyword');
            101:
                exit('ThenKeyword');
            102:
                exit('ElseKeyword');
            103:
                exit('CaseKeyword');
            104:
                exit('OfKeyword');
            105:
                exit('ForKeyword');
            106:
                exit('ToKeyword');
            107:
                exit('DownToKeyword');
            108:
                exit('DoKeyword');
            109:
                exit('WhileKeyword');
            110:
                exit('RepeatKeyword');
            111:
                exit('UntilKeyword');
            112:
                exit('ForEachKeyword');
            113:
                exit('InKeyword');
            114:
                exit('BeginKeyword');
            115:
                exit('EndKeyword');
            116:
                exit('ExitKeyword');
            117:
                exit('BreakKeyword');
            118:
                exit('WithKeyword');
            130:
                exit('ProcedureKeyword');
            131:
                exit('LocalKeyword');
            132:
                exit('InternalKeyword');
            133:
                exit('ProtectedKeyword');
            134:
                exit('VarKeyword');
            135:
                exit('ArrayKeyword');
            136:
                exit('TemporaryKeyword');
            137:
                exit('TriggerKeyword');
            138:
                exit('CodeunitKeyword');
            139:
                exit('TableKeyword');
            140:
                exit('PageKeyword');
            141:
                exit('ReportKeyword');
            142:
                exit('QueryKeyword');
            143:
                exit('XmlPortKeyword');
            144:
                exit('DotNetKeyword');
            145:
                exit('EventKeyword');
            else
                exit(StrSubstNo('Kind%1', Kind));
        end;
    end;

    // ---- Compact kind-sequence dump (kinds only, space-separated) for precedence-free
    //      shape assertions where positions/values are noise. ----
    procedure DumpKinds(var Tokens: Codeunit "ALI Token Table"): Text
    var
        I: Integer;
        Sb: TextBuilder;
    begin
        for I := 1 to Tokens.Count() do begin
            if I > 1 then
                Sb.Append(' ');
            Sb.Append(TokenKindName(Tokens.GetKind(I)));
        end;
        exit(Sb.ToText());
    end;
}
#endif
