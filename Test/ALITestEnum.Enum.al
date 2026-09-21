// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Enum — dedicated test enum for Option/Enum support (§14 new item). Exercises both
// metadata sources: as a field on "ALI Test Customer" (FieldRef path, translated caption) and
// as a local `Enum "ALI Test Enum"` variable / bare `"ALI Test Enum"::Member` literal (AL
// source-parse path via page 51017). Gapped ordinals + a Caption <> Name member are
// deliberate — dictionaries only, never index by position (§ risk flag).
enum 51110 "ALI Test Enum"
{
    Extensible = true;

    value(0; " ") { }
    value(1; New) { Caption = 'New'; }
    value(5; Open) { Caption = 'Open Thing'; }
    value(10; Closed) { Caption = 'Closed'; }
}
#endif
