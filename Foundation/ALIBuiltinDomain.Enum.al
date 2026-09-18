// ALI Builtin Domain — dispatch domain of a builtin row in "ALI Builtin Registry".
// Ordinals are the values previously returned by DomainStr()/DomainMath()/... — kept
// identical so stored signature tables and the interpreter's dispatch case stay compatible.
enum 51104 "ALI Builtin Domain"
{
    Extensible = false;

    value(0; None) { }          // no Str/Math/DateTime/System/Record handler (arrays, variant tests, unimplemented tier)
    value(1; Str) { }
    value(2; Math) { }
    value(3; DateTime) { }
    value(4; System) { }
    value(5; Record) { }
    value(6; Native) { }        // a catalogued procedure of a real codeunit, called natively ("ALI Native Runtime")
}
