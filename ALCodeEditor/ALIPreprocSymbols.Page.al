// ON PREMISE ONLY — the table it edits exists only there. See "ALI Preproc Symbol".
#if not CLOUD
// ponytail: plain list page — the table is unusable without one way to enter rows.
page 51107 "ALI Preproc Symbols"
{
    ApplicationArea = All;
    Caption = 'AL Interpreter Preprocessor Symbols', Comment = 'Symboles préprocesseur AL Interpreter';
    PageType = List;
    SourceTable = "ALI Preproc Symbol";

    layout
    {
        area(Content)
        {
            repeater(Rows)
            {
                field("App Package ID"; Rec."App Runtime Package ID") { }
                field("App Name"; Rec."App Name") { }
                field(Symbol; Rec.Symbol) { ToolTip = 'Preprocessor symbol defined at project level (app.json preprocessorSymbols).', Comment = 'Symbole de préprocesseur défini au niveau du projet (app.json preprocessorSymbols).'; }
            }
        }
    }
}
#endif
