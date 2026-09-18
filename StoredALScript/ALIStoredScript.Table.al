table 51013 "ALI Stored Script"
{
    // The row IS the user's own work: the AL they typed, the options they chose and the output of
    // running it. CustomerContent on the table classifies every field, which is what an AppSource
    // / per-tenant submission requires (AS0016) — none of it is telemetry or account data.
    Caption = 'AL Interpreter Stored Script', Comment = 'Script enregistré AL Interpreter';
    DataClassification = CustomerContent;
    DataPerCompany = false;
    DrillDownPageId = "ALI Stored Scripts";
    LookupPageId = "ALI Stored Scripts";

    fields
    {
        field(1; Name; Text[50]) { }
        field(10; Description; Text[250]) { }
        // Editor options (compiler + execution) persisted per script so reopening a
        // script restores the exact run configuration.
        field(20; Verbose; Boolean) { InitValue = false; }
        field(21; Optimize; Boolean) { }
        field(22; "Exec Mode"; Enum "ALI Exec Mode") { }
        field(23; "Allow HTTP"; Boolean) { }
        field(24; "Show Record Ops"; Boolean) { }
        field(25; "Message Mode"; Enum "ALI Message Mode") { }
        field(26; "Interaction Mode"; Enum "ALI Interaction Mode") { }
        field(27; "Dialog Mode"; Enum "ALI Dialog Mode") { }
        field(28; "Allow Protected Write"; Boolean) { }
        field(29; "Apply Record Security"; Boolean) { }
        field(100; "AL Source Code"; Blob) { Compressed = false; }
        // Last compile's diagnostics as the editor add-in JSON ([{line,col,len,sev,msg}]),
        // pushed back to the editor when the script is reopened.
        field(110; "Compile Diagnostics"; Blob) { Compressed = false; }
        // Bytecode of the last successful compile ("ALI Engine".SaveCompiled), run as is while
        // "Compiled Hash" still matches: SHA-256 over the source, the app version and the
        // compile-time options (see "ALI Script Editor".CompiledHash).
        field(120; "Compiled Code"; Blob) { }
        field(121; "Compiled Hash"; Text[64]) { }
        // Output pane of the last successful run, restored when the script is reopened.
        field(130; Output; Blob) { }
    }

    keys
    {
        key(Key1; Name)
        {
            Clustered = true;
        }
    }
}