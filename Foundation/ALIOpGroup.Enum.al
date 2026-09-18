enum 51102 "ALI Op Group"
{
    // ===== Operator group ordinals (§6.4) =====
    //
    // The *node's* operator TokenKind is mapped to one of these by
    // "ALI Type Rules".OpGroupFromToken(). Shared contract between binder (operator typing)
    // and lowerer (opcode selection). Dense ordinals 1..15; 0 = not a binary operator.
    // NOT a serialization contract, but keep append-only anyway.
    value(0; " ") { }               // not a binary operator
    value(1; Mul) { }             // *
    value(2; "Add") { }             // +
    value(3; Sub) { }             // -
    value(4; RDiv) { }            // /  (always Decimal)
    value(5; IDiv) { }            // div
    value(6; "Mod") { }             // mod
    value(7; Eq) { }              // =
    value(8; Neq) { }             // <>
    value(9; Lt) { }              // <
    value(10; Le) { }             // <=
    value(11; Gt) { }             // >
    value(12; Ge) { }             // >=
    value(13; "And") { }            // and (Bool logical only, v1)
    value(14; "Or") { }             // or
    value(15; "Xor") { }            // xor
}
