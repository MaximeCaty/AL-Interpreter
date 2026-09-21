// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Order Line — dedicated composite-primary-key test table (§14 item 7, M6).
//
// Same rationale as "ALI Test Customer" (kept in the MAIN app so RecMeta can resolve its
// metadata via the virtual Field table). Exercises Get() with a 2-field primary key — the
// interpreter must pass BOTH key values through to RecordRef.Get(RecordId) (§7.5).
table 51103 "ALI Test Order Line"
{
    Caption = 'ALI Test Order Line';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "Order No."; Code[20]) { Caption = 'Order No.'; }
        field(2; "Line No."; Integer) { Caption = 'Line No.'; }
        field(3; Description; Text[100]) { Caption = 'Description'; }
        field(4; Quantity; Decimal) { Caption = 'Quantity'; }
    }

    keys
    {
        key(PK; "Order No.", "Line No.") { Clustered = true; }
    }
}
#endif
