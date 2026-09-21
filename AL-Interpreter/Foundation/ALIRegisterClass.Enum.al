enum 51115 "ALI Register Class"
{
    // ===== Register classes (§7.1) — ADDED IN M4 =====
    //
    // The typed register files of the interpreter. This mapping is the shared contract
    // between binder (slot allocation §7.2), lowerer (opcode selection) and interpreter
    // (register arrays). Dense ordinals 1..11; NOT a serialization contract on its own
    // (opcodes carry the class), but keep append-only anyway.
    value(0; " ") { }
    value(1; Int) { }
    value(2; BigInt) { }
    value(3; "Decimal") { }
    value(4; "Boolean") { }
    value(5; "Text") { }
    value(6; "Date") { }
    value(7; "Time") { }
    value(8; "DateTime") { }
    value(9; "Duration") { }
    value(10; "Guid") { }
    value(11; "Variant") { }
    value(12; "RecordId") { }
    value(13; "DateFormula") { }
}