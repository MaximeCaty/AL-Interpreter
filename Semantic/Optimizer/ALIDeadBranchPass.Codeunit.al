// ALI Dead Branch Pass — statement-level dead-code elimination (§12) over conditions that a
// previous Const Fold / Const Prop run reduced to a bool literal:
//   * if true then A [else B]   -> A          (B never lowered — whole subtree dropped)
//   * if false then A [else B]  -> B / empty
//   * while false do A          -> empty      (while true = deliberate loop, left alone)
//   * repeat A until true       -> A          (run-once idiom) — ONLY when A contains no
//     `break` bound to this repeat (unwrapping would re-bind the break to an outer loop)
// The node is rewritten in place (SetKind/SetChildren); statements have TypeOrd 0, so the
// §12 "preserve result TypeOrd" contract holds trivially. Conditions that are not literal
// bools are left untouched — this pass never evaluates anything itself.
codeunit 51073 "ALI Dead Branch Pass" implements "ALI Opt Pass"
{
    Access = Public;
    SingleInstance = false;

    procedure Run(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Root: Integer)
    begin
        Rewrite(Tokens, Ast, Root);
    end;

    // Pre-order: rewrite this node first, then recurse into the SURVIVING children — dead
    // subtrees are never visited (that is the point of the pass).
    local procedure Rewrite(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        i: Integer;
    begin
        case Ast.GetKind(Node) of
            31: // IfStatement — children: [0]=cond, [1]=then, [2]=else|Missing
                if IsBoolLit(Tokens, Ast, Ast.GetChild(Node, 0)) then
                    if BoolVal(Tokens, Ast, Ast.GetChild(Node, 0)) then
                        WrapAsBlock(Ast, Node, Ast.GetChild(Node, 1))
                    else
                        if Ast.IsMissing(Ast.GetChild(Node, 2)) then
                            MakeEmpty(Ast, Node)
                        else
                            WrapAsBlock(Ast, Node, Ast.GetChild(Node, 2));
            32: // WhileStatement — children: [0]=cond, [1]=body
                if IsBoolLit(Tokens, Ast, Ast.GetChild(Node, 0)) then
                    if not BoolVal(Tokens, Ast, Ast.GetChild(Node, 0)) then
                        MakeEmpty(Ast, Node);
            33: // RepeatStatement — children: stmt* then untilCond LAST; ExtraInt = body count
                UnwrapRepeatUntilTrue(Tokens, Ast, Node);
        end;
        for i := 0 to Ast.GetChildCount(Node) - 1 do
            Rewrite(Tokens, Ast, Ast.GetChild(Node, i));
    end;

    // repeat A until true -> Block(A), but only when A carries no break bound to THIS repeat
    // (breaks inside nested loops belong to those loops and are fine).
    local procedure UnwrapRepeatUntilTrue(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    var
        BodyCount: Integer;
        CondNode: Integer;
        i: Integer;
        BodyList: List of [Integer];
    begin
        BodyCount := Ast.GetExtra(Node);
        CondNode := Ast.GetChild(Node, BodyCount);
        if not IsBoolLit(Tokens, Ast, CondNode) then
            exit;
        if not BoolVal(Tokens, Ast, CondNode) then  // until false = deliberate loop, leave
            exit;
        for i := 0 to BodyCount - 1 do begin
            if HasOwnBreak(Ast, Ast.GetChild(Node, i)) then
                exit;
            BodyList.Add(Ast.GetChild(Node, i));
        end;
        Ast.SetKind(Node, 30);      // Block
        Ast.SetExtra(Node, 0);
        Ast.SetChildren(Node, BodyList);
    end;

    // A BreakStatement in this subtree that would bind to the CURRENT loop: recursion stops
    // at nested loop statements (while/repeat/for/foreach own their breaks).
    local procedure HasOwnBreak(var Ast: Codeunit "ALI Ast Store"; Node: Integer): Boolean
    var
        i: Integer;
        K: Integer;
    begin
        K := Ast.GetKind(Node);
        if K = 42 then      // BreakStatement
            exit(true);
        if (K = 32) or (K = 33) or (K = 34) or (K = 35) then    // nested loop — its own breaks
            exit(false);
        for i := 0 to Ast.GetChildCount(Node) - 1 do
            if HasOwnBreak(Ast, Ast.GetChild(Node, i)) then
                exit(true);
        exit(false);
    end;

    // ===== In-place statement rewrites =====

    local procedure WrapAsBlock(var Ast: Codeunit "ALI Ast Store"; Node: Integer; KeptStmt: Integer)
    var
        ChildList: List of [Integer];
    begin
        ChildList.Add(KeptStmt);
        Ast.SetKind(Node, 30);      // Block
        Ast.SetExtra(Node, 0);
        Ast.SetChildren(Node, ChildList);
    end;

    local procedure MakeEmpty(var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    begin
        Ast.SetKind(Node, 43);      // EmptyStatement — lowerer emits nothing
        Ast.SetExtra(Node, 0);
        Ast.MakeLeaf(Node);
    end;

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
        exit(Tokens.GetKind(Ast.GetMainToken(Node)) = 21);
    end;
}
