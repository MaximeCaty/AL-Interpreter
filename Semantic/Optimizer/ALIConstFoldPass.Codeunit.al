// ALI Const Fold Pass — the v1 optimizer pass (§12): collapses expressions whose operands are
// ALL constant literals into a single literal node, bottom-up. Conservative on purpose (a wrong
// fold changes program semantics): folds only cases with no side effects, no conversions that
// could change a value, and no overflow/divide-by-zero risk —
//   * Boolean logic:   <boolLit> and/or/xor <boolLit>,  not <boolLit>
//   * Integer arith:   + - * div mod on Int32 literals (div/mod only with a non-zero literal
//                      divisor — a literal 0 divisor is left so the runtime raises the error)
//   * BigInteger arith: + - * div mod on Int32/Int64 literal operands (result kept in Int64
//                      range; * only when both operands fit the overflow-safe bound)
//   * Decimal arith:   + - * / on numeric literal operands (magnitude-guarded so the fold can
//                      never overflow where the runtime would; / needs a non-zero divisor)
//   * Option/Enum:     `X::A` is a bind-time constant (ordinal in SlotIndex) — participates as
//                      an Integer constant in arithmetic and comparisons
//   * Comparisons:     = <> < <= > >= over bool literals (false < true) and over any mix of
//                      Int32/Int64/Decimal/option constants (compared exactly via Decimal)
//   * Negation:        - <int32Lit> / - <int64Lit> / - <decLit>
// Everything else is left untouched (always safe). Because AL has no short-circuit evaluation,
// folding is only attempted when BOTH operands are constants — never dropping an operand's work.
// Text/date/time comparisons are skipped (collation/casing belongs to the runtime).
codeunit 51127 "ALI Const Fold Pass" implements "ALI Opt Pass"
{
    Access = Public;
    SingleInstance = false;

    procedure Run(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Root: Integer)
    begin
        FoldNode(Tokens, Ast, Root);
    end;

    // Post-order: fold children first so a parent sees already-folded literal operands.
    local procedure FoldNode(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        ChildCnt: Integer;
        i: Integer;
    begin
        ChildCnt := Ast.GetChildCount(Node);
        for i := 0 to ChildCnt - 1 do
            FoldNode(Tokens, Ast, Ast.GetChild(Node, i));
        TryFold(Tokens, Ast, Node);
    end;

    local procedure TryFold(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        BigA: BigInteger;
        DecA: Decimal;
        A: Integer;
        L: Integer;
        Op: Integer;
        R: Integer;
    begin
        case Ast.GetKind(Node) of
            60: // BinaryExpr — ExtraInt = operator token kind; children 0=left, 1=right
                begin
                    Op := Ast.GetExtra(Node);
                    L := Ast.GetChild(Node, 0);
                    R := Ast.GetChild(Node, 1);
                    case Op of
                        60, 61, 62: // and / or / xor
                            if IsBoolLit(Tokens, Ast, L) and IsBoolLit(Tokens, Ast, R) then
                                ReplaceWithBool(Tokens, Ast, Node, EvalBoolOp(Op, BoolVal(Tokens, Ast, L), BoolVal(Tokens, Ast, R)));
                        30, 31, 32, 34, 35: // + - * div mod
                            FoldArith(Tokens, Ast, Node, Op, L, R);
                        33: // / — always Decimal result (§6.4)
                            FoldRDiv(Tokens, Ast, Node, L, R);
                        50 .. 55: // = <> < <= > >=
                            FoldCompare(Tokens, Ast, Node, Op, L, R);
                    end;
                end;
            61: // UnaryExpr — ExtraInt = operator token kind; child 0 = operand
                begin
                    Op := Ast.GetExtra(Node);
                    L := Ast.GetChild(Node, 0);
                    case Op of
                        63: // not
                            if IsBoolLit(Tokens, Ast, L) then
                                ReplaceWithBool(Tokens, Ast, Node, not BoolVal(Tokens, Ast, L));
                        31: // unary minus — folded as 0 - operand in the result's own type
                            if IsResultType(Ast, Node, "ALI TypeKind"::Integer.AsInteger()) then begin
                                if TryGetIntConst(Tokens, Ast, L, A) then
                                    TryFoldIntArith(Tokens, Ast, Node, 31, 0, A);
                            end else
                                if IsResultType(Ast, Node, "ALI TypeKind"::BigInteger.AsInteger()) then begin
                                    if TryGetBigConst(Tokens, Ast, L, BigA) then
                                        TryFoldBigArith(Tokens, Ast, Node, 31, 0, BigA);
                                end else
                                    if IsResultType(Ast, Node, "ALI TypeKind"::Decimal.AsInteger()) then
                                        if TryGetDecConst(Tokens, Ast, L, DecA) then
                                            TryFoldDecArith(Tokens, Ast, Node, 31, 0, DecA);
                    end;
                end;
        end;
    end;

    // ===== Per-result-type arithmetic dispatch =====

    // + - * div mod with the fold done in the RESULT type (guarded by the node's TypeOrd, so
    // a converted context — e.g. int literals under a Decimal-typed parent — never folds as
    // the wrong type).
    local procedure FoldArith(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Op: Integer; L: Integer; R: Integer)
    var
        BigA: BigInteger;
        BigB: BigInteger;
        DecA: Decimal;
        DecB: Decimal;
        A: Integer;
        B: Integer;
    begin
        if IsResultType(Ast, Node, "ALI TypeKind"::Integer.AsInteger()) then begin
            if TryGetIntConst(Tokens, Ast, L, A) and TryGetIntConst(Tokens, Ast, R, B) then
                TryFoldIntArith(Tokens, Ast, Node, Op, A, B);
            exit;
        end;
        if IsResultType(Ast, Node, "ALI TypeKind"::BigInteger.AsInteger()) then begin
            if TryGetBigConst(Tokens, Ast, L, BigA) and TryGetBigConst(Tokens, Ast, R, BigB) then
                TryFoldBigArith(Tokens, Ast, Node, Op, BigA, BigB);
            exit;
        end;
        if IsResultType(Ast, Node, "ALI TypeKind"::Decimal.AsInteger()) then
            if (Op <> 34) and (Op <> 35) then // div/mod stay integral — never Decimal-folded
                if TryGetDecConst(Tokens, Ast, L, DecA) and TryGetDecConst(Tokens, Ast, R, DecB) then
                    TryFoldDecArith(Tokens, Ast, Node, Op, DecA, DecB);
    end;

    local procedure FoldRDiv(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; L: Integer; R: Integer)
    var
        DecA: Decimal;
        DecB: Decimal;
    begin
        if not IsResultType(Ast, Node, "ALI TypeKind"::Decimal.AsInteger()) then
            exit;
        if TryGetDecConst(Tokens, Ast, L, DecA) and TryGetDecConst(Tokens, Ast, R, DecB) then
            TryFoldDecArith(Tokens, Ast, Node, 33, DecA, DecB);
    end;

    // Comparisons: both sides bool literals, or both sides numeric constants (Int32/Int64/
    // Decimal/option ordinal) compared exactly via Decimal (28 significant digits covers the
    // full Int64 range). Result node must already be Boolean-typed.
    local procedure FoldCompare(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Op: Integer; L: Integer; R: Integer)
    var
        DecA: Decimal;
        DecB: Decimal;
    begin
        if not IsResultType(Ast, Node, "ALI TypeKind"::Boolean.AsInteger()) then
            exit;
        if IsBoolLit(Tokens, Ast, L) and IsBoolLit(Tokens, Ast, R) then begin
            // false < true, matching native AL boolean ordering.
            if BoolVal(Tokens, Ast, L) then
                DecA := 1
            else
                DecA := 0;
            if BoolVal(Tokens, Ast, R) then
                DecB := 1
            else
                DecB := 0;
            ReplaceWithBool(Tokens, Ast, Node, EvalCmp(Op, DecA, DecB));
            exit;
        end;
        if TryGetDecConst(Tokens, Ast, L, DecA) and TryGetDecConst(Tokens, Ast, R, DecB) then
            ReplaceWithBool(Tokens, Ast, Node, EvalCmp(Op, DecA, DecB));
    end;

    // ===== Constant extraction =====

    local procedure IsBoolLit(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    var
        Tk: Integer;
    begin
        if Ast.GetKind(Node) <> 62 then    // LiteralExpr
            exit(false);
        Tk := Tokens.GetKind(Ast.GetMainToken(Node));
        exit((Tk = 21) or (Tk = 22));      // TrueKeyword / FalseKeyword
    end;

    local procedure BoolVal(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    begin
        exit(Tokens.GetKind(Ast.GetMainToken(Node)) = 21);   // true keyword
    end;

    // Int32 constant in an Integer context: a plain Int32 literal with no attached conversion
    // (ConvOrd 0 — a converted operand, e.g. Int->Dec, must not fold as a plain Integer), or a
    // bind-time option/enum ordinal (`X::A`, SlotIndex holds the folded ordinal).
    local procedure TryGetIntConst(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; var V: Integer): Boolean
    begin
        if Ast.GetKind(Node) = 62 then begin
            if (Tokens.GetKind(Ast.GetMainToken(Node)) = 10) and (Ast.GetConvOrd(Node) = 0) then begin
                V := Tokens.GetInt(Ast.GetExtra(Node));
                exit(true);
            end;
            exit(false);
        end;
        if IsOptionConst(Ast, Node) then begin
            if Ast.GetConvOrd(Node) = 0 then begin
                V := Ast.GetSlotIndex(Node);
                exit(true);
            end;
            exit(false);
        end;
        exit(false);
    end;

    // Int32/Int64/option constant read as BigInteger. Operand ConvOrd is NOT checked: the
    // caller already guarded the RESULT type, and widening Int32 -> Int64 here is exactly the
    // conversion the runtime would apply.
    local procedure TryGetBigConst(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; var V: BigInteger): Boolean
    var
        Tk: Integer;
    begin
        if Ast.GetKind(Node) = 62 then begin
            Tk := Tokens.GetKind(Ast.GetMainToken(Node));
            if Tk = 10 then begin
                V := Tokens.GetInt(Ast.GetExtra(Node));
                exit(true);
            end;
            if Tk = 11 then begin
                V := Tokens.GetBigInt(Ast.GetExtra(Node));
                exit(true);
            end;
            exit(false);
        end;
        if IsOptionConst(Ast, Node) then begin
            V := Ast.GetSlotIndex(Node);
            exit(true);
        end;
        exit(false);
    end;

    // Any numeric constant read as Decimal (exact: Int32/Int64 fit in Decimal's 28 digits).
    local procedure TryGetDecConst(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; var V: Decimal): Boolean
    var
        Tk: Integer;
    begin
        if Ast.GetKind(Node) = 62 then begin
            Tk := Tokens.GetKind(Ast.GetMainToken(Node));
            if Tk = 10 then begin
                V := Tokens.GetInt(Ast.GetExtra(Node));
                exit(true);
            end;
            if Tk = 11 then begin
                V := Tokens.GetBigInt(Ast.GetExtra(Node));
                exit(true);
            end;
            if Tk = 12 then begin
                V := Tokens.GetDec(Ast.GetExtra(Node));
                exit(true);
            end;
            exit(false);
        end;
        if IsOptionConst(Ast, Node) then begin
            V := Ast.GetSlotIndex(Node);
            exit(true);
        end;
        exit(false);
    end;

    // OptionAccessExpr typed as Option/Enum: SlotIndex = folded ordinal (bind-time constant).
    // ObjectId-typed `::` access (§19.6) is excluded — its SlotIndex is an object id.
    local procedure IsOptionConst(var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    var
        T: Integer;
    begin
        if Ast.GetKind(Node) <> 67 then    // OptionAccessExpr
            exit(false);
        T := Ast.GetTypeOrd(Node);
        exit((T = "ALI TypeKind"::Option.AsInteger()) or (T = "ALI TypeKind"::Enum.AsInteger()));
    end;

    local procedure IsResultType(var Ast: Codeunit "ALI Ast Store"; Node: Integer; TypeK: Integer): Boolean
    begin
        exit(Ast.GetTypeOrd(Node) = TypeK);
    end;

    // ===== Evaluators =====

    local procedure EvalBoolOp(Op: Integer; A: Boolean; B: Boolean): Boolean
    begin
        case Op of
            60:
                exit(A and B);
            61:
                exit(A or B);
            else // 62 xor
                exit(A <> B);
        end;
    end;

    local procedure EvalCmp(Op: Integer; A: Decimal; B: Decimal): Boolean
    begin
        case Op of
            50:
                exit(A = B);
            51:
                exit(A <> B);
            52:
                exit(A < B);
            53:
                exit(A <= B);
            54:
                exit(A > B);
            else // 55 >=
                exit(A >= B);
        end;
    end;

    // Compute in BigInteger; only fold when the result is representable as Int32 (else leave it
    // so the runtime raises overflow exactly where native AL would). div/mod fold only with a
    // non-zero divisor — a literal 0 keeps the runtime divide-by-zero error in place.
    local procedure TryFoldIntArith(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Op: Integer; A: Integer; B: Integer)
    var
        Big: BigInteger;
        BigA: BigInteger;
        BigB: BigInteger;
        Narrowed: Integer;
    begin
        BigA := A;
        BigB := B;
        case Op of
            30:
                Big := BigA + BigB;
            31:
                Big := BigA - BigB;
            32:
                Big := BigA * BigB;
            34:
                begin
                    if B = 0 then
                        exit;
                    Big := BigA div BigB;
                end;
            35:
                begin
                    if B = 0 then
                        exit;
                    Big := BigA mod BigB;
                end;
        end;
        if (Big < -2147483647) or (Big > 2147483647) then
            exit;
        Narrowed := Big;    // in range (guarded above) — safe BigInteger -> Integer
        ReplaceWithInt(Tokens, Ast, Node, Narrowed);
    end;

    // BigInteger fold. Overflow strategy per op: +/- pre-checked exactly in Decimal (a sum of
    // two Int64 values has at most 20 digits — exact in Decimal's 28); * only when both
    // operands fit the sqrt(Int64.Max) bound 3037000499 (the product then cannot overflow);
    // div/mod cannot grow past their operands. Out-of-range results are left unfolded so the
    // runtime raises overflow exactly where native AL would.
    local procedure TryFoldBigArith(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Op: Integer; A: BigInteger; B: BigInteger)
    var
        Res: BigInteger;
        DecA: Decimal;
        DecB: Decimal;
        DecRes: Decimal;
    begin
        case Op of
            30, 31:
                begin
                    DecA := A;
                    DecB := B;
                    if Op = 30 then
                        DecRes := DecA + DecB
                    else
                        DecRes := DecA - DecB;
                    if (DecRes < -9223372036854775807.0) or (DecRes > 9223372036854775807.0) then
                        exit;
                    if Op = 30 then
                        Res := A + B
                    else
                        Res := A - B;
                end;
            32:
                begin
                    if (A < -3037000499L) or (A > 3037000499L) then
                        exit;
                    if (B < -3037000499L) or (B > 3037000499L) then
                        exit;
                    Res := A * B;
                end;
            34:
                begin
                    if B = 0 then
                        exit;
                    Res := A div B;
                end;
            35:
                begin
                    if B = 0 then
                        exit;
                    Res := A mod B;
                end;
        end;
        ReplaceWithBig(Tokens, Ast, Node, Res);
    end;

    // Decimal fold with magnitude guards so the compile-time computation can NEVER overflow
    // (Decimal max ~7.9e28): +/- operands capped at 1e28 (sum <= 2e28), * at 1e14 each
    // (product <= 1e28), / needs |A| <= 1e14 and |B| >= 1e-14 (quotient <= 1e28) and B <> 0
    // (a literal 0 divisor keeps the runtime error in place). Oversized literals simply stay
    // unfolded — the runtime then behaves exactly as without the optimizer.
    local procedure TryFoldDecArith(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Op: Integer; A: Decimal; B: Decimal)
    var
        Res: Decimal;
    begin
        case Op of
            30, 31:
                begin
                    if (Abs(A) > 10000000000000000000000000000.0) or (Abs(B) > 10000000000000000000000000000.0) then
                        exit;
                    if Op = 30 then
                        Res := A + B
                    else
                        Res := A - B;
                end;
            32:
                begin
                    if (Abs(A) > 100000000000000.0) or (Abs(B) > 100000000000000.0) then
                        exit;
                    Res := A * B;
                end;
            33:
                begin
                    if B = 0 then
                        exit;
                    if (Abs(A) > 100000000000000.0) or (Abs(B) < 0.00000000000001) then
                        exit;
                    Res := A / B;
                end;
        end;
        ReplaceWithDec(Tokens, Ast, Node, Res);
    end;

    // ===== In-place replacement (§12): turn Node into a literal leaf; result TypeOrd preserved =====

    local procedure ReplaceWithBool(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Value: Boolean)
    var
        Tk: Integer;
        TokKind: Integer;
    begin
        if Value then
            TokKind := 21     // TrueKeyword
        else
            TokKind := 22;    // FalseKeyword
        Tk := Tokens.AddToken(TokKind, 0, 0, 0, 0, 0, 0);
        Ast.SetKind(Node, 62);          // LiteralExpr
        Ast.SetMainToken(Node, Tk);
        Ast.SetExtra(Node, 0);          // bool literals carry no pool index (LowerLiteral ignores it)
        Ast.MakeLeaf(Node);
    end;

    local procedure ReplaceWithInt(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Value: Integer)
    var
        PoolIdx: Integer;
        Tk: Integer;
    begin
        PoolIdx := Tokens.AddIntLiteral(Value);
        Tk := Tokens.AddToken(10, 0, 0, 0, 0, PoolIdx, 0);   // Int32LiteralToken
        Ast.SetKind(Node, 62);          // LiteralExpr
        Ast.SetMainToken(Node, Tk);
        Ast.SetExtra(Node, PoolIdx);    // LowerLiteral reads GetExtra as the int pool index
        Ast.MakeLeaf(Node);
    end;

    local procedure ReplaceWithBig(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Value: BigInteger)
    var
        PoolIdx: Integer;
        Tk: Integer;
    begin
        PoolIdx := Tokens.AddBigIntLiteral(Value);
        Tk := Tokens.AddToken(11, 0, 0, 0, 0, PoolIdx, 0);   // Int64LiteralToken
        Ast.SetKind(Node, 62);
        Ast.SetMainToken(Node, Tk);
        Ast.SetExtra(Node, PoolIdx);
        Ast.MakeLeaf(Node);
    end;

    local procedure ReplaceWithDec(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer; Value: Decimal)
    var
        PoolIdx: Integer;
        Tk: Integer;
    begin
        PoolIdx := Tokens.AddDecLiteral(Value);
        Tk := Tokens.AddToken(12, 0, 0, 0, 0, PoolIdx, 0);   // DecimalLiteralToken
        Ast.SetKind(Node, 62);
        Ast.SetMainToken(Node, Tk);
        Ast.SetExtra(Node, PoolIdx);
        Ast.MakeLeaf(Node);
    end;
}
