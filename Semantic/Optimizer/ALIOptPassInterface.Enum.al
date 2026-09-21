// ALI Opt Pass Interface — the extensible dispatch enum for optimizer passes (§12). Each
// value binds to an "ALI Opt Pass" implementation; "ALI Pass Manager" runs an ordered list of
// these values. Add a pass = add a value + implement the interface (suite extensibility idiom).
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51114 "ALI Opt Pass Interface" implements "ALI Opt Pass"
{
    Extensible = true;

    value(0; ConstantFolding)
    {
        Caption = 'Constant Folding', Locked = true;
        Implementation = "ALI Opt Pass" = "ALI Const Fold Pass";
    }
    value(1; ConstantPropagation)
    {
        Caption = 'Constant Propagation', Locked = true;
        Implementation = "ALI Opt Pass" = "ALI Const Prop Pass";
    }
    value(2; DeadBranchElimination)
    {
        Caption = 'Dead Branch Elimination', Locked = true;
        Implementation = "ALI Opt Pass" = "ALI Dead Branch Pass";
    }
}
