// ALI Parser Expr — Pratt / precedence-climbing expression parser (§5.2).
//
// Binding powers (from BindingPower.cs + LanguageParser.GetInfixParselet, §5.2):
//   3  = <>  <  <=  >  >=  in  (equality AND comparison share power 3; `in [set]` rides
//                               with them — only when '[' follows, see ParseInList)
//   4  or  xor                 (xor rides with or)
//   5  and
//   7  + -                     (Term)
//   8  * / div mod             (Factor)
//   9  unary not - +           (prefix)
//   10 [index]                 (postfix)
//   11 . member, (...) invoke, :: option   (Call)
//
// FIDELITY TRAPS (do NOT "fix", §5.2): Pascal precedence — and/or bind TIGHTER than
// comparisons; comparisons share power 3 with equality; xor shares power 4 with or.
// `..` (range) is POSITIONAL only (case-labels / in-lists), handled by "ALI Parser",
// never a climbing operator here.
//
// All binaries are left-associative: parse RHS with minPower = thisPower + 1.
codeunit 51023 "ALI Parser Expr"
{
    Access = Public;
    SingleInstance = false;

    // ===== Entry: parse an expression whose operators bind at >= MinPower =====

    procedure ParseExpression(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; MinPower: Integer): Integer
    var
        Left: Integer;
        OpKind: Integer;
        OpToken: Integer;
        Power: Integer;
        Right: Integer;
        Kids: List of [Integer];
    begin
        if not Ctx.EnterDepth(Tokens, Diags) then
            exit(Ast.AddLeaf(NodeErrorExpr(), Ctx.CurIndex(), 0));

        Left := ParseUnary(Ctx, Tokens, Ast, Diags);

        // Infix climbing loop.
        while true do begin
            OpKind := Ctx.CurKind();
            // `expr in [set]` — relational operator, binds at comparison power 3. Only taken
            // when '[' follows 'in', so `foreach x in Coll` keeps its statement-level meaning.
            if (OpKind = KindIn()) and (MinPower <= 3) and (Ctx.PeekKind(1) = KindOpenBracket()) then
                Left := ParseInList(Ctx, Tokens, Ast, Diags, Left)
            else begin
                Power := InfixPower(OpKind);
                if (Power = 0) or (Power < MinPower) then
                    break;
                OpToken := Ctx.Advance();
                Right := ParseExpression(Ctx, Tokens, Ast, Diags, Power + 1);  // left-assoc
                Clear(Kids);
                Kids.Add(Left);
                Kids.Add(Right);
                Left := Ast.AddNode(NodeBinaryExpr(), OpToken, Kids, Tokens.GetKind(OpToken));
            end;
        end;

        Ctx.LeaveDepth();
        exit(Left);
    end;

    // Convenience: full expression (any operator).
    procedure Parse(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    begin
        exit(ParseExpression(Ctx, Tokens, Ast, Diags, 3));
    end;

    // ===== Unary / prefix (power 9): not, unary -, unary + =====

    local procedure ParseUnary(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        K: Integer;
        Operand: Integer;
        OpToken: Integer;
        Kids: List of [Integer];
    begin
        K := Ctx.CurKind();
        if (K = KindNot()) or (K = KindPlus()) or (K = KindMinus()) then begin
            OpToken := Ctx.Advance();
            Operand := ParseExpression(Ctx, Tokens, Ast, Diags, 9);  // unary binds at 9
            Clear(Kids);
            Kids.Add(Operand);
            exit(Ast.AddNode(NodeUnaryExpr(), OpToken, Kids, Tokens.GetKind(OpToken)));
        end;
        exit(ParsePostfix(Ctx, Tokens, Ast, Diags));
    end;

    // ===== Postfix chain (powers 10-11): [index], .member, (args), ::option =====

    local procedure ParsePostfix(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Qualified: Boolean;
        IndexCount: Integer;
        K: Integer;
        MemberTok: Integer;
        Node: Integer;
        Tok: Integer;
        Kids: List of [Integer];
    begin
        // Namespace-qualified builtins as Microsoft source writes them (`System.Evaluate(...)`,
        // `System.Clear(x)`). The System namespace holds exactly the builtins the interpreter
        // already resolves unqualified, so the qualifier is dropped — but it is REMEMBERED on the
        // name node: native AL writes it precisely to reach the builtin where a procedure of the
        // same name would shadow it (codeunit 10 declares its own Evaluate).
        // 20 = IdentifierToken, 77 = DotToken.
        Qualified := false;
        while (Ctx.CurKind() = 20) and (Ctx.PeekKind(1) = 77) and (UpperCase(Tokens.GetIdentText(Ctx.CurIndex())) = 'SYSTEM') do begin
            Ctx.Advance();
            Ctx.Advance();
            Qualified := true;
        end;

        Node := ParsePrimary(Ctx, Tokens, Ast, Diags);
        if Qualified and (Ast.GetKind(Node) = NodeNameExpr()) then
            Ast.SetForceBuiltin(Node);

        // NB: AL case labels must be CONSTANTS, so we compare against raw TokenKind ordinals
        // here (mirrors "ALI TokenKind"; the named Kind*() helpers are only for expression
        // contexts). 77='.', 80='::', 70='(', 72='['.
        while true do begin
            K := Ctx.CurKind();
            case K of
                77:  // DotToken -> member access
                    begin
                        Ctx.Advance();
                        MemberTok := ExpectName(Ctx, Tokens, Diags);
                        Clear(Kids);
                        Kids.Add(Node);
                        Node := Ast.AddNode(NodeMemberAccessExpr(), MemberTok, Kids, Tokens.GetIdentId(MemberTok));
                    end;
                80:  // ColonColonToken -> option access
                    begin
                        Ctx.Advance();
                        // Declaration keywords (Page, Table, Local, Event…) are plain member names
                        // after `::` natively (`"Object Type"::Page`); binder recovers the spelling.
                        if IsDeclarationKeyword(Ctx.CurKind()) then
                            MemberTok := Ctx.Advance()
                        else
                            MemberTok := ExpectName(Ctx, Tokens, Diags);
                        Clear(Kids);
                        Kids.Add(Node);
                        Node := Ast.AddNode(NodeOptionAccessExpr(), MemberTok, Kids, Tokens.GetIdentId(MemberTok));
                    end;
                70:  // OpenParenToken -> invocation
                    Node := ParseInvocation(Ctx, Tokens, Ast, Diags, Node);
                72:  // OpenBracketToken -> index; §20.8 multidim: a[i, j, ...] — comma loop,
                    // index count in ExtraInt (mirrors ParseInvocation's arg-count). Children:
                    // [0]=target, [1..IndexCount]=index expressions.
                    begin
                        Tok := Ctx.Advance();
                        Clear(Kids);
                        Kids.Add(Node);
                        Kids.Add(ParseExpression(Ctx, Tokens, Ast, Diags, 3));
                        IndexCount := 1;
                        while Ctx.Accept(KindComma()) do begin
                            Kids.Add(ParseExpression(Ctx, Tokens, Ast, Diags, 3));
                            IndexCount += 1;
                        end;
                        Ctx.Expect(Tokens, Diags, KindCloseBracket(), ']');
                        Node := Ast.AddNode(NodeIndexExpr(), Tok, Kids, IndexCount);
                    end;
                else
                    // break here would only exit the CASE, not the while — exit directly.
                    exit(Node);
            end;
        end;
    end;

    // `Left in [item, lo..hi, ...]` (§ native AL relational `in`). Children: [0]=tested
    // expr, [1..n]=items (plain expr or RangeExpr, mirroring case labels); ExtraInt = item
    // count. Caller already verified 'in' followed by '['.
    local procedure ParseInList(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Left: Integer): Integer
    var
        InTok: Integer;
        ItemCount: Integer;
        Kids: List of [Integer];
    begin
        InTok := Ctx.Advance();                              // 'in'
        Ctx.Advance();                                       // '[' (peeked by caller)
        Kids.Add(Left);
        Kids.Add(ParseInItem(Ctx, Tokens, Ast, Diags));
        ItemCount := 1;
        while Ctx.Accept(KindComma()) do begin
            Kids.Add(ParseInItem(Ctx, Tokens, Ast, Diags));
            ItemCount += 1;
        end;
        Ctx.Expect(Tokens, Diags, KindCloseBracket(), ']');
        exit(Ast.AddNode(NodeInListExpr(), InTok, Kids, ItemCount));
    end;

    // One in-set item: an expression, optionally `lo..hi` -> RangeExpr (same shape as a
    // case label, § ALI Parser ParseCaseLabel).
    local procedure ParseInItem(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        DotTok: Integer;
        Hi: Integer;
        Lo: Integer;
        Kids: List of [Integer];
    begin
        Lo := ParseExpression(Ctx, Tokens, Ast, Diags, 3);
        if Ctx.CurKind() = KindDotDot() then begin
            DotTok := Ctx.Advance();                         // '..'
            Hi := ParseExpression(Ctx, Tokens, Ast, Diags, 3);
            Kids.Add(Lo);
            Kids.Add(Hi);
            exit(Ast.AddNode(NodeRangeExpr(), DotTok, Kids, 0));
        end;
        exit(Lo);
    end;

    // f(arg, arg, ...) — callee already parsed. arg* variable arity; ExtraInt = arg count.
    local procedure ParseInvocation(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Callee: Integer): Integer
    var
        ArgCount: Integer;
        OpenTok: Integer;
        Kids: List of [Integer];
    begin
        OpenTok := Ctx.Advance();   // '('
        Kids.Add(Callee);                 // child 0 = callee (§5.5)
        if Ctx.CurKind() <> KindCloseParen() then begin
            Kids.Add(ParseExpression(Ctx, Tokens, Ast, Diags, 3));
            ArgCount += 1;
            while Ctx.Accept(KindComma()) do begin
                Kids.Add(ParseExpression(Ctx, Tokens, Ast, Diags, 3));
                ArgCount += 1;
            end;
        end;
        Ctx.Expect(Tokens, Diags, KindCloseParen(), ')');
        exit(Ast.AddNode(NodeInvocationExpr(), OpenTok, Kids, ArgCount));
    end;

    // ===== Primary: literal / name / parenthesized =====

    local procedure ParsePrimary(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Inner: Integer;
        K: Integer;
        Tok: Integer;
    begin
        K := Ctx.CurKind();
        case true of
            IsLiteralKind(K):
                begin
                    Tok := Ctx.Advance();
                    exit(Ast.AddLeaf(NodeLiteralExpr(), Tok, Tokens.GetValueIndex(Tok)));
                end;
            (K = KindOpenParen()):
                begin
                    Ctx.Advance();   // '('
                    Inner := ParseExpression(Ctx, Tokens, Ast, Diags, 3);
                    Ctx.Expect(Tokens, Diags, KindCloseParen(), ')');
                    exit(Inner);           // parens are grouping only — no wrapper node
                end;
            IsNameLike(K):
                begin
                    Tok := Ctx.Advance();
                    exit(Ast.AddLeaf(NodeNameExpr(), Tok, Tokens.GetIdentId(Tok)));
                end;
            else begin
                // Unrecognized primary — poison node, report once, advance to unblock parser.
                Diags.AddError('AL0132', 'Expression expected', Tokens.GetStartPos(Ctx.CurIndex()), 0);
                Ctx.Advance();
                exit(Ast.AddLeaf(NodeErrorExpr(), Ctx.CurIndex() - 1, 0));
            end;
        end;
    end;

    // A name position: identifier, or a keyword acting as identifier (§5.1 IsIdentifierLike),
    // or true/false handled as literals elsewhere. Consumes and returns the token index;
    // on mismatch reports and anchors to the current index without consuming.
    local procedure ExpectName(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"): Integer
    begin
        if IsNameLike(Ctx.CurKind()) then
            exit(Ctx.Advance());
        Diags.AddError('AL0132', 'Identifier expected', Tokens.GetStartPos(Ctx.CurIndex()), 0);
        exit(Ctx.CurIndex());
    end;

    // ===== Precedence table (§5.2) =====

    // Infix binding power for an operator token kind, or 0 if not an infix operator.
    // NOTE: DotDotToken (`..`) is deliberately NOT here — it is positional (§5.2).
    local procedure InfixPower(K: Integer): Integer
    begin
        // Raw TokenKind ordinals (AL case labels must be constants). Powers per §5.2.
        case K of
            50, 51, 52, 53, 54, 55:     // = <> < <= > >=  (equality+comparison share power 3)
                exit(3);
            61, 62:                     // or, xor  (xor rides with or)
                exit(4);
            60:                         // and
                exit(5);
            30, 31:                     // + -
                exit(7);
            32, 33, 34, 35:             // * / div mod
                exit(8);
            else
                exit(0);
        end;
    end;

    local procedure IsLiteralKind(K: Integer): Boolean
    begin
        // literal token kinds + true/false keyword literals
        exit((K >= 10) and (K <= 16) or (K = 21) or (K = 22));
    end;

    // Name-like: IdentifierToken (includes quoted identifiers, which the lexer emits as
    // IdentifierToken). true/false are literals, not names. Keyword-as-identifier
    // rehabilitation (§5.1 IsIdentifierLike, e.g. member named after a contextual keyword)
    // is a later refinement — v1 accepts the plain identifier token, which covers
    // Rec.Field, Foo(), and quoted names; the binder handles genuine keyword misuse.
    //
    // §19.6 addition: the object-kind keywords (Codeunit/Table/Page/Report/Query/XmlPort)
    // are ALSO name-like so `Codeunit::"Sales Post"` parses as an OptionAccessExpr whose
    // left child is a NameExpr — these keywords never otherwise start a primary expression
    // (they only lead top-level object-shell declarations, consumed before expression
    // parsing begins), so accepting them here introduces no grammar ambiguity. Database and
    // Enum are not reserved keywords at all — they already lex as plain IdentifierToken.
    local procedure IsNameLike(K: Integer): Boolean
    begin
        exit((K = 20) or IsObjectKindKeyword(K));   // IdentifierToken, or Codeunit/Table/Page/Report/Query/XmlPort
    end;

    local procedure IsObjectKindKeyword(K: Integer): Boolean
    begin
        exit((K >= 138) and (K <= 143));   // CodeunitKeyword..XmlPortKeyword (§ ALI TokenKind)
    end;

    local procedure IsDeclarationKeyword(K: Integer): Boolean
    begin
        exit((K >= 130) and (K <= 145));   // ProcedureKeyword..EventKeyword (§ ALI TokenKind)
    end;

    // ===== Node kind ordinals (mirror "ALI NodeKind") =====

    local procedure NodeBinaryExpr(): Integer
    begin
        exit(60);
    end;

    local procedure NodeUnaryExpr(): Integer
    begin
        exit(61);
    end;

    local procedure NodeLiteralExpr(): Integer
    begin
        exit(62);
    end;

    local procedure NodeNameExpr(): Integer
    begin
        exit(63);
    end;

    local procedure NodeMemberAccessExpr(): Integer
    begin
        exit(64);
    end;

    local procedure NodeInvocationExpr(): Integer
    begin
        exit(65);
    end;

    local procedure NodeIndexExpr(): Integer
    begin
        exit(66);
    end;

    local procedure NodeOptionAccessExpr(): Integer
    begin
        exit(67);
    end;

    local procedure NodeRangeExpr(): Integer
    begin
        exit(68);
    end;

    local procedure NodeInListExpr(): Integer
    begin
        exit(69);
    end;

    local procedure NodeErrorExpr(): Integer
    begin
        exit(2);
    end;

    // ===== Token kind ordinals (mirror "ALI TokenKind") =====

    local procedure KindPlus(): Integer
    begin
        exit(30);
    end;

    local procedure KindMinus(): Integer
    begin
        exit(31);
    end;

    local procedure KindMultiply(): Integer
    begin
        exit(32);
    end;

    local procedure KindRDiv(): Integer
    begin
        exit(33);
    end;

    local procedure KindIDiv(): Integer
    begin
        exit(34);
    end;

    local procedure KindModulo(): Integer
    begin
        exit(35);
    end;

    local procedure KindEquals(): Integer
    begin
        exit(50);
    end;

    local procedure KindNotEquals(): Integer
    begin
        exit(51);
    end;

    local procedure KindLessThan(): Integer
    begin
        exit(52);
    end;

    local procedure KindLessThanEquals(): Integer
    begin
        exit(53);
    end;

    local procedure KindGreaterThan(): Integer
    begin
        exit(54);
    end;

    local procedure KindGreaterThanEquals(): Integer
    begin
        exit(55);
    end;

    local procedure KindAnd(): Integer
    begin
        exit(60);
    end;

    local procedure KindOr(): Integer
    begin
        exit(61);
    end;

    local procedure KindXor(): Integer
    begin
        exit(62);
    end;

    local procedure KindNot(): Integer
    begin
        exit(63);
    end;

    local procedure KindOpenParen(): Integer
    begin
        exit(70);
    end;

    local procedure KindCloseParen(): Integer
    begin
        exit(71);
    end;

    local procedure KindOpenBracket(): Integer
    begin
        exit(72);
    end;

    local procedure KindCloseBracket(): Integer
    begin
        exit(73);
    end;

    local procedure KindComma(): Integer
    begin
        exit(76);
    end;

    local procedure KindDot(): Integer
    begin
        exit(77);
    end;

    local procedure KindColonColon(): Integer
    begin
        exit(80);
    end;

    local procedure KindDotDot(): Integer
    begin
        exit(78);
    end;

    local procedure KindIn(): Integer
    begin
        exit(113);
    end;
}
