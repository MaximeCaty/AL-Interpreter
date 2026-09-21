// ALI Symbol Kind — symbol classification per §6.1.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51107 "ALI Symbol Kind"
{
    Extensible = false;

    value(0; None) { }
    value(1; GlobalVar) { }         // module-level var
    value(2; LocalVar) { }
    value(3; Param) { }
    value(4; VarParam) { }          // by-reference param (indirection, §7.2)
    value(5; Proc) { }
    value(6; RecordVar) { }
    value(7; OptionMember) { }
    value(8; BuiltinProc) { }
}
