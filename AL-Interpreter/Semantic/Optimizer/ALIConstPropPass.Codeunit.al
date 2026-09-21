// ALI Const Prop Pass — single-assignment constant propagation (§12). When a scalar local is
// assigned a literal exactly ONCE in its whole procedure, and that assignment is a straight-
// line top-level statement of the procedure body, every read AFTER the assignment must see
// that literal — so the read is rewritten into the literal in place. A following Const Fold
// run then collapses the expressions the propagated literals land in.
//
// Safety rules (all conservative — a symbol failing any rule is simply skipped):
//   * candidate symbols: proc-local scalars only (Integer/BigInteger/Decimal/Boolean whose
//     literal kind matches the symbol type exactly). In form 0 (bare statement list, no
//     procedures) module-scope vars qualify too — with no procs they behave as locals.
//     Params/var-params/globals(with procs)/text are never propagated (aliasing / casing —
//     Code uppercases on store, so a propagated Text literal could change comparisons).
//   * exactly ONE write anywhere in the body: assignment target (plain or compound),
//     for/foreach control var. Any second write disqualifies.
//   * the symbol never appears as a DIRECT argument of an InvocationExpr — a var-param (user
//     proc or builtin like Evaluate) could write it through the call. Nested expressions
//     (`Foo(x + 1)`) cannot alias, so only direct NameExpr children disqualify.
//   * only reads in statements AFTER the assignment are replaced. Node indices give this for
//     free: the parser builds bottom-up left-to-right, so every node of a later statement has
//     a higher index than the assignment statement's node.
// The assignment itself is left in place (one dead store — harmless, not worth a pass).
codeunit 51144 "ALI Const Prop Pass" implements "ALI Opt Pass"
{
    Access = Public;
    SingleInstance = false;

    var
        UnsafeSid: Dictionary of [Integer, Boolean];    // SymbolId set: appears as a call argument
        CandExtra: Dictionary of [Integer, Integer];    // SymbolId -> literal ExtraInt (pool idx)
        CandStmt: Dictionary of [Integer, Integer];     // SymbolId -> assignment stmt node index
        CandTok: Dictionary of [Integer, Integer];      // SymbolId -> literal MainToken to copy
        WriteCnt: Dictionary of [Integer, Integer];     // SymbolId -> write count

    procedure Run(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Root: Integer)
    var
        Body: Integer;
        Child: Integer;
        i: Integer;
        ProcBodies: List of [Integer];
    begin
        for i := 0 to Ast.GetChildCount(Root) - 1 do begin
            Child := Ast.GetChild(Root, i);
            if Ast.GetKind(Child) = 13 then     // ProcDecl — child 3 = body block (§5.5)
                ProcBodies.Add(Ast.GetChild(Child, 3));
        end;
        if ProcBodies.Count() = 0 then
            PropagateBody(Tokens, Ast, Symbols, Root, true)     // form 0: bare stmts under Root
        else
            foreach Body in ProcBodies do
                PropagateBody(Tokens, Ast, Symbols, Body, false);
    end;

    // One procedure body (or the form-0 root): scan writes/unsafe uses over the whole body,
    // pick candidates among the body's DIRECT child statements, then rewrite the reads.
    local procedure PropagateBody(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; Body: Integer; AllowGlobals: Boolean)
    var
        Cnt: Integer;
        i: Integer;
        Sid: Integer;
        Stmt: Integer;
        Target: Integer;
    begin
        Clear(WriteCnt);
        Clear(UnsafeSid);
        Clear(CandTok);
        Clear(CandExtra);
        Clear(CandStmt);

        ScanUsage(Ast, Body);

        for i := 0 to Ast.GetChildCount(Body) - 1 do begin
            Stmt := Ast.GetChild(Body, i);
            if Ast.GetKind(Stmt) = 39 then                  // AssignmentStatement
                if Ast.GetExtra(Stmt) = 40 then begin       // plain := (no compound)
                    Target := Ast.GetChild(Stmt, 0);
                    if Ast.GetKind(Target) = 63 then begin  // NameExpr
                        Sid := Ast.GetSymbolId(Target);
                        if Sid > 0 then
                            if SymKindAllowed(Symbols, Sid, AllowGlobals) then
                                if not UnsafeSid.ContainsKey(Sid) then
                                    if WriteCnt.Get(Sid, Cnt) then
                                        if Cnt = 1 then
                                            if LiteralMatchesSym(Tokens, Ast, Symbols, Ast.GetChild(Stmt, 1), Sid) then begin
                                                CandTok.Set(Sid, Ast.GetMainToken(Ast.GetChild(Stmt, 1)));
                                                CandExtra.Set(Sid, Ast.GetExtra(Ast.GetChild(Stmt, 1)));
                                                CandStmt.Set(Sid, Stmt);
                                            end;
                    end;
                end;
        end;

        if CandStmt.Count() > 0 then
            ReplaceReads(Ast, Body);
    end;

    // ===== Usage scan: count writes, flag call-argument appearances =====

    local procedure ScanUsage(var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        Child: Integer;
        i: Integer;
        K: Integer;
        Target: Integer;
    begin
        K := Ast.GetKind(Node);
        case K of
            39: // AssignmentStatement — child 0 target is a write (plain AND compound)
                begin
                    Target := Ast.GetChild(Node, 0);
                    if Ast.GetKind(Target) = 63 then
                        IncWrite(Ast.GetSymbolId(Target))
                    else
                        ScanUsage(Ast, Target);     // arr[i]/Rec.Field target: index/receiver reads
                    ScanUsage(Ast, Ast.GetChild(Node, 1));
                end;
            34, 35: // For / ForEach — child 0 control var is a write
                begin
                    IncWrite(Ast.GetSymbolId(Ast.GetChild(Node, 0)));
                    for i := 1 to Ast.GetChildCount(Node) - 1 do
                        ScanUsage(Ast, Ast.GetChild(Node, i));
                end;
            65: // InvocationExpr — a DIRECT NameExpr child may be a var-param argument
                for i := 0 to Ast.GetChildCount(Node) - 1 do begin
                    Child := Ast.GetChild(Node, i);
                    if Ast.GetKind(Child) = 63 then begin
                        if Ast.GetSymbolId(Child) > 0 then
                            UnsafeSid.Set(Ast.GetSymbolId(Child), true);
                    end else
                        ScanUsage(Ast, Child);
                end;
            else
                for i := 0 to Ast.GetChildCount(Node) - 1 do
                    ScanUsage(Ast, Ast.GetChild(Node, i));
        end;
    end;

    local procedure IncWrite(Sid: Integer)
    var
        Cnt: Integer;
    begin
        if Sid <= 0 then
            exit;
        if WriteCnt.Get(Sid, Cnt) then
            WriteCnt.Set(Sid, Cnt + 1)
        else
            WriteCnt.Set(Sid, 1);
    end;

    // ===== Candidate filters =====

    local procedure SymKindAllowed(var Symbols: Codeunit "ALI Symbol Table"; Sid: Integer; AllowGlobals: Boolean): Boolean
    var
        K: Integer;
    begin
        K := Symbols.GetKind(Sid);
        if K = Symbols.KindLocalVar() then
            exit(true);
        if K = Symbols.KindGlobalVar() then
            exit(AllowGlobals);
        exit(false);
    end;

    // RHS literal whose token kind matches the symbol type EXACTLY (no cross-type literal,
    // so the rewritten read lowers to the very same constant class the variable read would
    // have produced). ConvOrd 0 = no conversion attached by the binder.
    local procedure LiteralMatchesSym(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; ValueNode: Integer; Sid: Integer): Boolean
    var
        SymT: Integer;
        Tk: Integer;
    begin
        if Ast.GetKind(ValueNode) <> 62 then    // LiteralExpr
            exit(false);
        if Ast.GetConvOrd(ValueNode) <> 0 then
            exit(false);
        Tk := Tokens.GetKind(Ast.GetMainToken(ValueNode));
        SymT := Symbols.GetType(Sid);
        case Tk of
            10: // Int32
                exit(SymT = "ALI TypeKind"::Integer.AsInteger());
            11: // Int64
                exit(SymT = "ALI TypeKind"::BigInteger.AsInteger());
            12: // Decimal
                exit(SymT = "ALI TypeKind"::Decimal.AsInteger());
            21, 22: // true / false
                exit(SymT = "ALI TypeKind"::Boolean.AsInteger());
        end;
        exit(false);
    end;

    // ===== Rewrite: turn qualifying reads into the literal =====

    local procedure ReplaceReads(var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        i: Integer;
        K: Integer;
        Sid: Integer;
        StmtIdx: Integer;
        Target: Integer;
    begin
        K := Ast.GetKind(Node);
        case K of
            63: // NameExpr — a read (write positions are skipped by the parents below)
                begin
                    Sid := Ast.GetSymbolId(Node);
                    if Sid > 0 then
                        if CandStmt.Get(Sid, StmtIdx) then
                            if Node > StmtIdx then begin    // statement AFTER the assignment


                                Ast.SetKind(Node, 62);      // LiteralExpr; TypeOrd stays = sym type
                                Ast.SetMainToken(Node, GetInt(CandTok, Sid));
                                Ast.SetExtra(Node, GetInt(CandExtra, Sid));
                            end;
                end;
            39: // AssignmentStatement — never rewrite a NameExpr TARGET
                begin
                    Target := Ast.GetChild(Node, 0);
                    if Ast.GetKind(Target) <> 63 then
                        ReplaceReads(Ast, Target);
                    ReplaceReads(Ast, Ast.GetChild(Node, 1));
                end;
            34, 35: // For / ForEach — child 0 control var is a write position
                for i := 1 to Ast.GetChildCount(Node) - 1 do
                    ReplaceReads(Ast, Ast.GetChild(Node, i));
            else
                for i := 0 to Ast.GetChildCount(Node) - 1 do
                    ReplaceReads(Ast, Ast.GetChild(Node, i));
        end;
    end;

    local procedure GetInt(var D: Dictionary of [Integer, Integer]; Sid: Integer): Integer
    var
        V: Integer;
    begin
        if D.Get(Sid, V) then
            exit(V);
        exit(0);
    end;
}
