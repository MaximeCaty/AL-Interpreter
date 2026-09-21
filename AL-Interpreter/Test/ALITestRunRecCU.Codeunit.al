// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Run Rec CU — fixture for `Codeunit.Run(id, Rec)` (M11 phase C3).
//
// This is the fixture that PINS the record bridge. ALI holds every record as a RecordRef, and
// native AL refuses a RecordRef where `Codeunit.Run` wants a record ("cannot convert from
// 'RecordRef' to 'var Table'"), so the interpreter hands it over as a Variant instead. Whether
// the platform then presents that Variant to OnRun as the right row is not something ALI can
// decide — this codeunit writes the row, and T85 reads it back from the database.
codeunit 51155 "ALI Test Run Rec CU"
{
    TableNo = "ALI Test Customer";

    trigger OnRun()
    begin
        Rec."Post Count" := Rec."Post Count" + 5;
        Rec.Modify();
    end;
}
#endif
