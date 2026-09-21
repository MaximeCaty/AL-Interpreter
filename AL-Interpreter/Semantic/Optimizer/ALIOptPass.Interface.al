// ALI Opt Pass — optimizer pass contract (§12). A pass rewrites the bound AST in place
// between the Binder and the Lowerer. Passes are dispatched from "ALI Pass Manager" through
// the extensible enum "ALI Opt Pass Interface" (add a value + implement this interface to add
// a pass — no case branches).
//
// Contract: the AST is already bound (TypeOrd/ConvOrd/SymbolId annotations present). A pass
// may mutate node kind/children/token via the AstStore mutators but MUST preserve each node's
// result TypeOrd so the Lowerer and the parent's conversion expectations stay valid. Report
// problems through Diags; never throw for ordinary "cannot optimize" cases (just skip).
interface "ALI Opt Pass"
{
    procedure Run(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Symbols: Codeunit "ALI Symbol Table"; var Diags: Codeunit "ALI Diag Bag"; Root: Integer)
}
