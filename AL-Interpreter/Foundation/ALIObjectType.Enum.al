// ALI Object Type — cross-object source-harvest target kinds per §18.5.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
// Used by ALI Source Provider + CALL_OBJ + module-registry keying (§18).
enum 51104 "ALI Object Type"
{
    Extensible = false;

    value(0; None) { }
    value(1; Codeunit) { }
    value(2; Page) { }
    value(3; Table) { }
    // A tableextension is a harvest unit of its own (own source, own scope, own caches), but it
    // is BOUND with the base table's object context — see "ALI Object Registry".CompileObjectUnit.
    value(4; "TableExtension") { }
}
