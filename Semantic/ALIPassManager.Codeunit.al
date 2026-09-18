// ALI Pass Manager — runs an ordered list of optimizer passes (§12) over the bound AST,
// between Binder and Lowerer. Holds enum VALUES (not interface instances — AL cannot store
// interfaces in a collection); each value is cast to its "ALI Opt Pass" implementation at run
// time. AddDefault() installs the standard pass order; a host may build a custom order via
// AddPass() before RunAll().
codeunit 51046 "ALI Pass Manager"
{
    Access = Public;
    SingleInstance = false;

    var
        Passes: List of [Enum "ALI Opt Pass Interface"];

    procedure Reset()
    begin
        Clear(Passes);
    end;

    procedure AddPass(Pass: Enum "ALI Opt Pass Interface")
    begin
        Passes.Add(Pass);
    end;

    // Standard pass order (extend here as passes are added). Fold runs TWICE: once so
    // literal-RHS assignments like `x := 2 + 3` become propagation candidates, and again so
    // the propagated literals collapse the expressions (and conditions) they land in —
    // which Dead Branch Elimination then prunes.
    procedure AddDefault()
    begin
        Passes.Add(Enum::"ALI Opt Pass Interface"::ConstantFolding);
        Passes.Add(Enum::"ALI Opt Pass Interface"::ConstantPropagation);
        Passes.Add(Enum::"ALI Opt Pass Interface"::ConstantFolding);
        Passes.Add(Enum::"ALI Opt Pass Interface"::DeadBranchElimination);
    end;

    procedure PassCount(): Integer
    begin
        exit(Passes.Count());
    end;

    procedure RunAll(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Root: Integer)
    var
        PassVal: Enum "ALI Opt Pass Interface";
        Pass: Interface "ALI Opt Pass";
    begin
        foreach PassVal in Passes do begin
            Pass := PassVal;    // enum -> interface implementation (suite dispatch idiom)
            Pass.Run(Tokens, Ast, Symbols, Diags, Root);
        end;
    end;
}
