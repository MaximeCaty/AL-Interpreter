// ALI NodeKind — AST node taxonomy per §5.5 node-shape catalog.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
// Child-order per kind is a hard contract shared by parser/binder/lowerer (§5.5) —
// this enum only names the kinds; the child order lives in §5.5, not here.
enum 51007 "ALI NodeKind"
{
    Extensible = false;

    // --- Special ---
    value(0; None) { }
    value(1; MissingNode) { }               // shared sentinel for absent [opt] children (§5.5)
    value(2; ErrorExpr) { }                 // poison node; binder types as ErrorType
    value(3; ErrorStatement) { }
    value(4; SkippedTokens) { }             // recovery: attached skipped-token span

    // --- Top level / declarations ---
    value(10; CompilationUnit) { }
    value(11; VarSection) { }
    value(12; VarDecl) { }
    value(13; ProcDecl) { }
    value(14; Param) { }
    value(15; TypeRef) { }                  // typeRef node referenced by VarDecl/Param/return
    value(16; ParamList) { }                // ProcDecl child 0: parameter list (Param* variable)

    // --- Statements ---
    value(30; Block) { }                    // begin..end
    value(31; IfStatement) { }
    value(32; WhileStatement) { }
    value(33; RepeatStatement) { }
    value(34; ForStatement) { }
    value(35; ForEachStatement) { }         // v2
    value(36; CaseStatement) { }
    value(37; CaseLine) { }
    value(38; CaseElse) { }
    value(39; AssignmentStatement) { }
    value(40; ExpressionStatement) { }
    value(41; ExitStatement) { }
    value(42; BreakStatement) { }
    value(43; EmptyStatement) { }
    value(44; OrphanedElseStatement) { }    // ERR_OrphanedElseStatement (§5.4)

    // --- Expressions ---
    value(60; BinaryExpr) { }
    value(61; UnaryExpr) { }
    value(62; LiteralExpr) { }
    value(63; NameExpr) { }                 // identifier reference
    value(64; MemberAccessExpr) { }         // a.b
    value(65; InvocationExpr) { }           // f(args)
    value(66; IndexExpr) { }                // a[i]
    value(67; OptionAccessExpr) { }         // X::Y (option member or object-id, §19.6)
    value(68; RangeExpr) { }                // lo..hi (case-label / in-list only)
    value(69; InListExpr) { }               // Expr in [v, lo..hi, ...] — child 0 = tested
                                            // expr, children 1..ExtraInt = items (value or
                                            // RangeExpr); ExtraInt = item count
}
