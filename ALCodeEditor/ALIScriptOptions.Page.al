// Interpreter options of "ALI Script Editor", split out of the editor card so the whole page
// width stays available for the source/result panes. Runs on a temporary copy of the script:
// the editor may hold a not-yet-saved record (Name = ''), which a DB-bound card cannot open.
page 51104 "ALI Script Options"
{
    ApplicationArea = All;
    Caption = 'AL Script Options';
    PageType = Card;
    SourceTable = "ALI Stored Script";
    SourceTableTemporary = true;
    InsertAllowed = false;
    DeleteAllowed = false;

    layout
    {
        area(Content)
        {
            group(Compiler)
            {
                Caption = 'Compiler Options';

                field(Verbose; Rec.Verbose)
                {
                    Caption = 'Verbose';
                    ToolTip = 'Give more detailed compilation/runtime errors, and report per-stage sizes/diags (lexer/parser/binder/lowerer) instead of single-call engine.';
                }
                field(Optimize; Rec.Optimize)
                {
                    Caption = 'Optimize';
                    ToolTip = 'Run optimizer passes (constant folding, constant propagation, dead-branch elimination) on AST before lowering.';
                }
            }
            group(ExecutionMode)
            {
                Caption = 'Execution Options';

                field(ExecMode; Rec."Exec Mode")
                {
                    Caption = 'Execution mode';
                    ToolTip = 'Normal writes to the database and honors COMMIT; an error rolls the run back. Simulation rolls back every DB write at the end and never commits.';  // Comment = 'Mode d''exécution';
                }
                field(AllowHttp; Rec."Allow HTTP")
                {
                    Caption = 'Allow HTTP';
                    ToolTip = 'Allow any http request during execution throught HttpClient.';
                }
                field(AllowProtectedWrite; Rec."Allow Protected Write")
                {
                    Caption = 'Allow protected table write';
                    ToolTip = 'Allow insert/modify/delete/rename on protected tables (posted documents, ledger entries, registers). Off by default.';
                }
                field(ApplyRecordSecurity; Rec."Apply Record Security")
                {
                    Caption = 'Apply record security filters', Comment = 'Appliquer les filtres de sécurité enregistrement';
                    ToolTip = 'Apply the application record security filters (e.g. responsibility center, budget user filters) to every table read by the script, like the AI does. Off by default.', Comment = 'Applique les filtres de sécurité applicatifs (ex. centre de gestion, filtres budget utilisateur) à chaque lecture de table du script, comme l''IA. Désactivé par défaut.';
                }
                group(ShowRecOpsVisible)
                {
                    ShowCaption = false;
                    Visible = Rec."Exec Mode" = Rec."Exec Mode"::Normal;
                    field(ShowRecOps; Rec."Show Record Ops")
                    {
                        Caption = 'Show record operation counts';
                        ToolTip = 'List insert/modify/delete counts per table after the run (always shown in Simulation mode).';  // Comment = 'Afficher le nombre d''opérations enregistrement';
                    }
                }
            }
            group("UI Handler")
            {
                field(MessageMode; Rec."Message Mode")
                {
                    Caption = 'Message handler';
                    ToolTip = 'Log collects Message() into the result; Show also displays a real dialog when a GUI is available.';  // Comment = 'Gestion des messages';
                }
                field(InteractionMode; Rec."Interaction Mode")
                {
                    Caption = 'Confirm / StrMenu handler';
                    ToolTip = 'Default uses scripted/default answers; Error stops on an unscripted call; Show prompts for real when a GUI is available.';  // Comment = 'Gestion Confirm / StrMenu';
                }
                field(DialogMode; Rec."Dialog Mode")
                {
                    Caption = 'Dialog (GuiAllowed)';
                    ToolTip = 'Hide makes GuiAllowed() false so dialog-guarded code is skipped; Show makes it true so that code runs.';  // Comment = 'Boîtes de dialogue';
                }
            }
        }
    }

    actions
    {
        area(Processing)
        {
            action(Benchmark)
            {
                Caption = 'Benchmark';
                ToolTip = 'Run the same mixed workload (customer reads, text, char arithmetic, decimal, date, list, dictionary, sub procedures) as native AL and through ALI, and compare durations. Read-only. Uses the Optimize option.';
                Image = Calculate;

                trigger OnAction()
                var
                    ALIBenchmark: Codeunit "ALI Benchmark";
                begin
                    ALIBenchmark.RunWithSizePrompt(Rec.Optimize);
                end;
            }
        }
        area(Promoted)
        {
            actionref(Benchmark_Promoted; Benchmark) { }
        }
    }

    procedure SetOptions(StoredScript: Record "ALI Stored Script")
    begin
        Rec.Reset();
        Rec.DeleteAll();
        Rec.Init();
        Rec.Name := StoredScript.Name;
        CopyOptions(StoredScript, Rec);
        Rec.Insert();
    end;

    procedure GetOptions(var StoredScript: Record "ALI Stored Script")
    begin
        CopyOptions(Rec, StoredScript);
    end;

    // Field-by-field on purpose: TransferFields would blank the uncalculated blobs
    // ("AL Source Code", "Compile Diagnostics") of the caller's record.
    local procedure CopyOptions(FromScript: Record "ALI Stored Script"; var ToScript: Record "ALI Stored Script")
    begin
        ToScript.Verbose := FromScript.Verbose;
        ToScript.Optimize := FromScript.Optimize;
        ToScript."Exec Mode" := FromScript."Exec Mode";
        ToScript."Allow HTTP" := FromScript."Allow HTTP";
        ToScript."Show Record Ops" := FromScript."Show Record Ops";
        ToScript."Message Mode" := FromScript."Message Mode";
        ToScript."Interaction Mode" := FromScript."Interaction Mode";
        ToScript."Dialog Mode" := FromScript."Dialog Mode";
        ToScript."Allow Protected Write" := FromScript."Allow Protected Write";
        ToScript."Apply Record Security" := FromScript."Apply Record Security";
    end;
}
