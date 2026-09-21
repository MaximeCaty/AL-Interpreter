// ON PREMISE ONLY. Project-level preprocessor symbols only ever apply to the source of an
// ALREADY PUBLISHED object, which a Cloud (SaaS) build cannot read at all ("Application Object
// Metadata" is OnPrem-scoped). With nothing to apply them to the table has no purpose there, and
// its "App Name" flowfield reaches "Published Application", itself OnPrem-scoped.
#if not CLOUD
// Preprocessor symbols defined at PROJECT level for one extension, i.e. the AL project's
// `preprocessorSymbols` in app.json — metadata the runtime cannot give us, so it is declared
// here once per extension and read by the lexer when a harvested object is compiled.
// File-level `#define` / `#undef` are applied on top of this set by the lexer itself.
table 51104 "ALI Preproc Symbol"
{
    Caption = 'AL Interpreter Preprocessor Symbol', Comment = 'Symbole de préprocesseur AL Interpreter';
    DataClassification = SystemMetadata;
    DataPerCompany = false;
    DrillDownPageId = "ALI Preproc Symbols";
    LookupPageId = "ALI Preproc Symbols";

    fields
    {
        // App ID, not Package ID: the package changes on every publish, the app id does not.
        field(1; "App Runtime Package ID"; Guid)
        {
            Caption = 'App Package ID', Comment = 'Package ID de l''extension';
            TableRelation = "Published Application"."Runtime Package ID";

            trigger OnValidate()
            var
                PublishedApp: Record "Published Application";
            begin
                if IsNullGuid("App Runtime Package ID") then
                    Rec."App ID" := ''
                else begin
                    PublishedApp.Get("App Runtime Package ID");
                    Rec."App ID" := PublishedApp.ID;
                end;
            end;
        }
        field(10; "App ID"; Guid)
        {
            Caption = 'App ID', Comment = 'ID de l''extension';
            Editable = false;
        }
        field(20; "App Name"; Text[150])
        {
            Caption = 'App Name', Comment = 'Nom de l''extension';
            Editable = false;
            FieldClass = FlowField;
            CalcFormula = lookup("Published Application".Name where("Runtime Package ID" = Field("App Runtime Package ID")));
        }
        field(30; Symbol; Code[50])
        {
            Caption = 'Symbol', Comment = 'Symbole';
        }
    }

    keys
    {
        key(Key1; "App Runtime Package ID", Symbol)
        {
            Clustered = true;
        }
        key(KeySearchByID; "App ID")
        {

        }
    }

    // Symbols defined for one extension, uppercased (directive matching is case-insensitive).
    procedure SymbolsOf(AppId: Guid) Result: List of [Text]
    var
        PreprocSymbol: Record "ALI Preproc Symbol";
    begin
        if IsNullGuid(AppId) then
            exit;

        PreprocSymbol.SetCurrentKey("App ID");
        PreprocSymbol.SetRange("App ID", AppId);
        if PreprocSymbol.FindSet() then
            repeat
                Result.Add(UpperCase(PreprocSymbol.Symbol));
            until PreprocSymbol.Next() = 0;
    end;
}
#endif
