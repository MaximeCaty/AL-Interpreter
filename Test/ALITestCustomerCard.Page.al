// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Customer Card — fixture for the static `Page.Run(id, Rec)` native row.
//
// Page.Run is executed by the platform, so the only way a test sees what it opened is a
// PageHandler over a TestPage — which needs a real page on the record the script passes. The
// card shows "No.", so the handler can check the Variant record bridge delivered the right row.
page 51028 "ALI Test Customer Card"
{
    PageType = Card;
    SourceTable = "ALI Test Customer";
    ApplicationArea = All;
    Caption = 'ALI Test Customer Card';

    layout
    {
        area(Content)
        {
            field("No."; Rec."No.") { }
            field(Name; Rec.Name) { }
        }
    }
}
#endif
