// ALI Playground — ad-hoc page to type AL source, compile + run it through the interpreter
// (via "ALI Engine"), and see the result. Not part of the test suite; a manual dev tool.
//
// The page is deliberately chrome-less: the toolbar (File / Run / Options / Preprocessor) and
// the tab strip live inside the "ALI Code Editor" add-in, which gives the two editor panes the
// vertical space the Name/Description fields and the ribbon used to take. Everything the user
// clicks up there comes back through the single EditorCommand event below.
//
// The Result pane has two panels: Output (what the last SUCCESSFUL run printed — kept when a
// later compile fails) and Problems (the diagnostics of the last compile or live syntax check).
// Scripts run in strict entry mode: `trigger OnRun()` is the one and only entry point.
page 51016 "ALI Script Editor"
{
    ApplicationArea = All;
    Caption = 'AL Script Editor';
    PageType = Card;
    SourceTable = "ALI Stored Script";
    UsageCategory = Administration;

    layout
    {
        area(Content)
        {
            // grid (not group): a plain card group lays children out responsively over up to
            // 3 columns, leaving a phantom empty third column. Grid with two child groups
            // gives exactly two columns that split the full page width.
            grid(SourceResult)
            {
                GridLayout = Rows;
                ShowCaption = false;

                group(Input)
                {
                    Caption = 'AL Code Editor';

                    usercontrol(SourceEditor; "ALI Code Editor")
                    {

                        trigger ControlAddInReady()
                        var
                            ApiCatalog: Codeunit "ALI Api Catalog";
                            Engine: Codeunit "ALI Engine";
                            Win: Dialog;
                            LoadingMetadata: Label 'Loading Application Metadata...';
                        begin
                            if (Rec.Name = '') and (SourceCode = '') then
                                SourceCode := NewScriptTemplate();
                            CurrPage.SourceEditor.SetText(SourceCode);
                            LastPushedSource := SourceCode;
                            LastSavedSource := SourceCode;
                            SourceEditorInit := true;
                            InitTabs();
                            PushRunMode();
                            if DiagnosticsJson <> '' then
                                PushDiagnostics();
                            // AL language on: coloring + autocompletion (interpreter surface +
                            // table/codeunit names; members served on demand via RequestObjectMembers).
                            // It also switches on the toolbar and the tab strip, which is why the
                            // read-only Result pane below never grows any.
                            Win.Open(LoadingMetadata);
                            CurrPage.SourceEditor.SetALLanguage(true);
#if CLOUD
                            // No published-object source to apply project symbols to, and no page
                            // behind the entry — keep it out of the Run menu entirely.
                            CurrPage.SourceEditor.SetPreprocAvailable(false);
#endif
                            CurrPage.SourceEditor.SetApiCatalog(ApiCatalog.BuildCatalogJson());
                            CurrPage.SourceEditor.SetTableList(ApiCatalog.BuildTableListJson());
                            CurrPage.SourceEditor.SetCodeunitList(ApiCatalog.BuildCodeunitListJson());
                            CurrPage.SourceEditor.SetEnumList(ApiCatalog.BuildEnumListJson());
                            // Pay the pipeline's one-time instantiation cost here, inside the load
                            // the user is already waiting on, instead of on their first Compile & Run.
                            Engine.Warmup();
                            Win.Close();
                        end;

                        trigger RequestObjectMembers(ObjectType: Text; ObjectName: Text)
                        var
                            ApiCatalog: Codeunit "ALI Api Catalog";
                        begin
                            // Object procedures ride along on the same answer, but only when the
                            // script may call them — reading the object's AL source is not free.
                            CurrPage.SourceEditor.SetObjectMembers(ObjectType, ObjectName, ApiCatalog.BuildObjectMembersJson(ObjectType, ObjectName, true));
                        end;

                        // The only channel carrying the source back to AL: fired 1 s after the last
                        // keystroke, and immediately on blur so a ribbon action never runs stale
                        // source. A per-keystroke channel used to exist alongside it; every one of
                        // its events was a full BC client<->server hop, which blocks the client.
                        //
                        // A tab switch is a round trip too: text the add-in sent after the switch
                        // command but before SetText swapped its buffer is still the PREVIOUS tab's.
                        // TabId says whose text it is; anything but the active tab's is dropped,
                        // or it would overwrite the newly active tab (its blob when named).
                        trigger TextChangedLong(Text: Text; TabId: Integer)
                        var
                            OutStr: OutStream;
                        begin
                            if not IsActiveTabId(TabId) then begin
                                PushDiagnostics(); // the status strip waits for an answer to every round trip
                                exit;
                            end;
                            SourceCode := Text;
                            LastPushedSource := Text;
                            // The active tab's buffer follows the text: for a named script this is
                            // only a mirror of the blob written just below, but for a tab that was
                            // never named it is the only place its source exists while another tab
                            // is on screen.
                            TabBuffers.Set(ActiveTab, Text);
                            // Rec.Name alone does not prove Rec is this tab's script (see
                            // OnAfterGetCurrRecord): never write a blank tab's text into a stored one.
                            if (Text <> LastSavedSource) and RecIsActiveScript() then begin
                                Rec."AL Source Code".CreateOutStream(OutStr, TextEncoding::UTF8);
                                OutStr.Write(SourceCode);
                                if Rec.Modify() then;
                                LastSavedSource := Text;
                            end;
                            // + live compile
                            LiveCompileCheck();
                        end;

                        // Every toolbar button, menu entry and tab click arrives here. Commands
                        // that act on the source ('run', 'save', 'select', 'close', 'rename') are
                        // sent by the add-in right after a TextChangedLong flush, so SourceCode is
                        // current by the time they run.
                        trigger EditorCommand(Command: Text; Arg: Text)
                        begin
                            case Command of
                                'new':
                                    NewTab();
                                'open':
                                    OpenScript();
                                'save':
                                    SaveScript();
                                'rename':
                                    RenameActiveTab(Arg);
                                'select':
                                    SwitchTab(TabIndexArg(Arg));
                                'close':
                                    CloseTab(TabIndexArg(Arg));
                                'run':
                                    RunScript(false);
                                'forcerun':
                                    RunScript(true);
                                'simulation':
                                    SetSimulation(Arg = '1');
                                'options':
                                    ShowOptions();
#if not CLOUD
                                'preproc':
                                    Page.Run(Page::"ALI Preproc Symbols");
#endif
                            end;
                        end;
                    }
                }
                group(Output)
                {
                    Caption = 'Output';

                    usercontrol(ResultEditor; "ALI Code Editor")
                    {

                        trigger ControlAddInReady()
                        begin
                            CurrPage.ResultEditor.SetReadOnly(true);
                            CurrPage.ResultEditor.SetALLanguage(false); // plain output viewer: no coloring, no completion, no chrome
                            CurrPage.ResultEditor.ShowPanel('output');  // Output / Problems panels on
                            ResultInit := true;
                            LastPushedOutput := OutputText;
                            CurrPage.ResultEditor.SetText(OutputText);
                            LastPushedProblems := '';
                            PushProblems();
                        end;

                        // A click on a Result line tagged with a location (see OutAt), in either panel.
                        trigger GotoLocation(Line: Integer; Column: Integer)
                        begin
                            if SourceEditorInit then
                                CurrPage.SourceEditor.GotoLine(Line, Column);
                        end;
                    }
                }
            }
        }
    }

    var
        RecRt: Codeunit "ALI Rec Runtime";
        ActionStart: DateTime;
        ResultInit: Boolean;
        SourceEditorInit: Boolean;
        ActiveTab: Integer;
        NextTabId: Integer;
        DiagnosticsJson: Text;
        LastCheckedSource: Text;
        LastPushedOutput: Text;
        LastPushedProblems: Text;
        LastPushedSource: Text;
        LastSavedDiags: Text;
        LastSavedSource: Text;
        OutputText: Text;
        SourceCode: Text;
        TabBuffers: List of [Text];
        // One id per tab buffer, sent with SetTabs and echoed by TextChangedLong. Indexes shift on
        // a close and a reused blank tab keeps its index, so neither can say whose text arrived.
        TabIds: List of [Integer];
        TabNames: List of [Text];
        // Output panel per tab. Named scripts also keep theirs in the Output blob; for a tab that
        // was never named this list is the only copy while another tab is on screen.
        TabOutputs: List of [Text];

    #region Trigger
    trigger OnOpenPage()
    var
        IsSuper: Codeunit "User Permissions";
    begin
        if not IsSuper.IsSuper(UserSecurityId()) then
            Error('This page is only allowed to Super user.');
    end;

    // Named scripts are written on every typing pause, so only a tab that was never named can
    // still hold work at this point — including the ones that are not on screen.
    trigger OnQueryClosePage(CloseAction: Action): Boolean
    var
        i: Integer;
        Unsaved: Boolean;
    begin
        if TabNames.Count() = 0 then
            Unsaved := (Rec.Name = '') and not IsUntouchedSource(SourceCode);
        for i := 1 to TabNames.Count() do
            if TabNames.Get(i) = '' then begin
                if i = ActiveTab then
                    Unsaved := Unsaved or not IsUntouchedSource(SourceCode)
                else
                    Unsaved := Unsaved or not IsUntouchedSource(TabBuffers.Get(i));
            end;
        if not Unsaved then
            exit(true);
        exit(Confirm('You have unsaved source code, are you sure to close the page ? Any code written here will be lost.'));
    end;

    procedure SetStoredScript(var StoredScript: Record "ALI Stored Script")
    var
        InStr: InStream;
    begin
        StoredScript.CalcFields("AL Source Code");
        StoredScript."AL Source Code".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(SourceCode);
        LastSavedSource := SourceCode;
        PushSource();
        LoadDiagnostics();
        LoadOutput();
    end;

    // Any Rec.Modify() (the live-check save, SaveDiagnostics) makes the client re-read the
    // record and run this trigger again. Without the PushSource guard that echoed the whole
    // source back to the add-in on every save, forcing a full re-highlight of the buffer.
    trigger OnAfterGetCurrRecord()
    var
        InStr: InStream;
    begin
        // A blank tab has no row behind it, yet the client still runs this trigger against
        // whatever record its own bookmark points at — reloading from Rec here dragged the
        // previous tab's script straight onto the new one.
        if ActiveTabIsBlank() then begin
            // Skipping the reload is not enough: the re-read left Rec ON that stored script, and
            // every save keyed on Rec.Name (typing pause, diagnostics, output, run options) went
            // into it — the blank tab's code silently replaced the other tab's script.
            if Rec.Name <> '' then begin
                InitBlankRec();
                PushRunMode();
            end;
            exit;
        end;
        if Rec.Name <> '' then begin
            Rec.CalcFields("AL Source Code");
            Rec."AL Source Code".CreateInStream(InStr, TextEncoding::UTF8);
            InStr.Read(SourceCode);
            LastSavedSource := SourceCode;
            PushSource();
            LoadDiagnostics();
            LoadOutput();
            PushRunMode();
        end;
        SyncActiveTab();
    end;

    // Send the source to the editor only when the editor does not already hold it.
    local procedure PushSource()
    begin
        if not SourceEditorInit then
            exit;
        if SourceCode = LastPushedSource then
            exit;
        LastPushedSource := SourceCode;
        CurrPage.SourceEditor.SetText(SourceCode);
    end;

    // Page opened from a URL/bookmark: the client keeps re-finding that bookmark on every
    // CurrPage.Update, not the record LoadActiveTab just got — every opened script landed back on
    // the URL's one (and SyncActiveTab relabelled the tab to it). A named tab owns the record.
    // A blank tab owns no record: InitBlankRec's Name = '' filter is not enough there, the URL
    // bookmark still brought the client back onto its script under the blank tab.
    trigger OnFindRecord(Which: Text): Boolean
    begin
        if ActiveTabIsBlank() then
            exit(false);
        if (ActiveTab >= 1) and (ActiveTab <= TabNames.Count()) then
            if Rec.Get(CopyStr(TabNames.Get(ActiveTab), 1, MaxStrLen(Rec.Name))) then
                exit(true);
        exit(Rec.Find(Which));
    end;

    trigger OnNextRecord(Steps: Integer): Integer
    begin
        ClearResult();
    end;

    trigger OnNewRecord(BelowxRec: Boolean)
    begin
        // A blank tab filters the source table to nothing, so every CurrPage.Update on it lands
        // here: its source is the tab's buffer (already loaded by LoadActiveTab), not an empty
        // new record's. Clearing it here is what emptied the editor on a switch back to the tab.
        if not ActiveTabIsBlank() then begin
            SourceCode := '';
            DiagnosticsJson := '[]';
            LastSavedSource := '';
            if SourceEditorInit then begin
                LastPushedSource := '';
                CurrPage.SourceEditor.SetText('');
            end;
            ClearResult();
        end;
        Rec."Exec Mode" := Rec."Exec Mode"::Simulation;
        Rec.Verbose := false;
    end;
    #endregion

    #region Tabs
    // The tab strip is AL state: the add-in draws whatever PushTabs() sends it and reports the
    // clicks back, but never holds buffer text. That split is what keeps the editor single-buffer
    // (one textarea, one diagnostics set, one member cache) — a tab switch is a record swap here,
    // not a second editor over there. TabBuffers only earns its keep for tabs that were never
    // named: a named script is already on disk after every typing pause.

    local procedure InitTabs()
    begin
        Clear(TabNames);
        Clear(TabBuffers);
        Clear(TabOutputs);
        Clear(TabIds);
        TabNames.Add(Rec.Name);
        TabBuffers.Add(SourceCode);
        TabOutputs.Add(OutputText);
        TabIds.Add(NewTabId());
        ActiveTab := 1;
        PushTabs();
    end;

    local procedure NewTabId(): Integer
    begin
        NextTabId += 1;
        exit(NextTabId);
    end;

    local procedure IsActiveTabId(TabId: Integer): Boolean
    begin
        if (ActiveTab < 1) or (ActiveTab > TabIds.Count()) then
            exit(false);
        exit(TabIds.Get(ActiveTab) = TabId);
    end;

    local procedure PushTabs()
    var
        Script: Record "ALI Stored Script";
        Tab: JsonObject;
        Tabs: JsonArray;
        i: Integer;
        TabName: Text;
        TabsJson: Text;
    begin
        if not SourceEditorInit then
            exit;
        for i := 1 to TabNames.Count() do begin
            TabName := TabNames.Get(i);
            Clear(Tab);
            Tab.Add('n', TabName);
            // Description is no longer a field on this page; it rides along as the tab's tooltip
            // and stays editable on the "ALI Stored Scripts" list.
            if (TabName <> '') and Script.Get(TabName) then
                Tab.Add('d', Script.Description)
            else
                Tab.Add('d', '');
            Tab.Add('a', i = ActiveTab);
            Tab.Add('id', TabIds.Get(i));
            Tabs.Add(Tab);
        end;
        Tabs.WriteTo(TabsJson);
        CurrPage.SourceEditor.SetTabs(TabsJson);
    end;

    local procedure SwitchTab(NewIndex: Integer)
    begin
        if (NewIndex < 1) or (NewIndex > TabNames.Count()) then
            exit;
        if NewIndex = ActiveTab then
            exit;
        StashActiveTab();
        ActiveTab := NewIndex;
        LoadActiveTab();
    end;

    local procedure ActiveTabIsBlank(): Boolean
    begin
        if (ActiveTab < 1) or (ActiveTab > TabNames.Count()) then
            exit(false);
        exit(TabNames.Get(ActiveTab) = '');
    end;

    // Rec is the active tab's stored script. Rec.Name alone does not prove it (see
    // OnAfterGetCurrRecord / OnFindRecord): every write keyed on the page record checks this, so a
    // blank tab never writes into, or hits a stale version of, another tab's script.
    local procedure RecIsActiveScript(): Boolean
    begin
        if Rec.Name = '' then
            exit(false);
        if (ActiveTab < 1) or (ActiveTab > TabNames.Count()) then
            exit(true);   // tabs not built yet: the page record is the only script
        exit(TabNames.Get(ActiveTab) = Rec.Name);
    end;

    local procedure StashActiveTab()
    begin
        if (ActiveTab >= 1) and (ActiveTab <= TabBuffers.Count()) then begin
            TabBuffers.Set(ActiveTab, SourceCode);
            TabOutputs.Set(ActiveTab, OutputText);
        end;
    end;

    // Brings the active tab's script under the page. A named tab is a plain record swap and
    // reuses SetStoredScript; an unnamed one has no record to read, so the page runs on an
    // uncommitted Rec.Init() and the source comes back from the buffer.
    local procedure LoadActiveTab()
    var
        TabName: Text;
    begin
        TabName := TabNames.Get(ActiveTab);
        Rec.Reset();
        if TabName <> '' then begin
            Rec.Get(CopyStr(TabName, 1, MaxStrLen(Rec.Name)));
            SetStoredScript(Rec);
        end else begin
            InitBlankRec();
            SourceCode := TabBuffers.Get(ActiveTab);
            LastSavedSource := SourceCode;
            PushSource();
            DiagnosticsJson := '[]';
            LastSavedDiags := DiagnosticsJson;
            PushDiagnostics();
            OutputText := TabOutputs.Get(ActiveTab);
            PushOutput();
        end;
        TabBuffers.Set(ActiveTab, SourceCode);
        TabOutputs.Set(ActiveTab, OutputText);
        CurrPage.Update(false);
        PushTabs();
        PushRunMode();
    end;

    // Init alone does not give a blank tab: the client keeps its own bookmark and re-reads the
    // previous record on the next Update. Filtering the source table down to nothing leaves it
    // no record to go back to. Init also keeps the primary key, hence Name cleared by hand:
    // left as is, Rec still named the previous tab's script and the blank tab saved into it.
    local procedure InitBlankRec()
    begin
        Rec.Reset();
        Rec.SetRange(Name, '');
        Rec.Init();
        Rec.Name := '';
        Rec."Exec Mode" := Rec."Exec Mode"::Simulation;
    end;

    local procedure NewTab()
    begin
        StashActiveTab();
        TabNames.Add('');
        TabBuffers.Add(NewScriptTemplate());
        TabOutputs.Add('');
        TabIds.Add(NewTabId());
        ActiveTab := TabNames.Count();
        LoadActiveTab();
    end;

    local procedure NewScriptTemplate(): Text
    var
        Lf: Text[1];
    begin
        Lf[1] := 10;   // LF only: the textarea hands text back LF-normalized, IsUntouchedSource compares against it
        exit('trigger OnRun()' + Lf + 'begin' + Lf + '    Message(''Hello World'');' + Lf + 'end;');
    end;

    // Empty or still the untouched template: nothing worth a confirm, and the tab may be reused.
    local procedure IsUntouchedSource(Source: Text): Boolean
    begin
        exit((Source.Trim() = '') or (Source.Trim() = NewScriptTemplate()));
    end;

    local procedure CloseTab(Index: Integer)
    begin
        if (Index < 1) or (Index > TabNames.Count()) then
            exit;
        StashActiveTab();
        if (TabNames.Get(Index) = '') and not IsUntouchedSource(TabBuffers.Get(Index)) then
            if not Confirm('This tab was never saved. Close it and lose the source code it holds?') then
                exit;

        TabNames.RemoveAt(Index);
        TabBuffers.RemoveAt(Index);
        TabOutputs.RemoveAt(Index);
        TabIds.RemoveAt(Index);
        // Closing the last tab leaves a blank one behind rather than an empty strip.
        if TabNames.Count() = 0 then begin
            TabNames.Add('');
            TabBuffers.Add(NewScriptTemplate());
            TabOutputs.Add('');
            TabIds.Add(NewTabId());
        end;
        if Index < ActiveTab then
            ActiveTab -= 1;
        if ActiveTab > TabNames.Count() then
            ActiveTab := TabNames.Count();
        LoadActiveTab();
    end;

    // Naming happens inline on the tab, so this covers both "Save As" on a tab that was never
    // named (insert) and a plain rename of a stored script.
    local procedure RenameActiveTab(NewName: Text)
    var
        Existing: Record "ALI Stored Script";
        OutStr: OutStream;
        TabName: Text;
    begin
        NewName := NewName.Trim();
        if NewName = '' then
            exit;
        TabName := TabNames.Get(ActiveTab);
        if NewName = TabName then
            exit;
        if Existing.Get(CopyStr(NewName, 1, MaxStrLen(Existing.Name))) then
            Error('A script named %1 already exists.', NewName);
        // After the check: an Error above must leave a blank tab's filter in place, or the
        // client re-reads its bookmark (a stored script) under it.
        Rec.Reset();   // a blank tab filters the source table to nothing; the insert below leaves it

        if TabName = '' then begin
            // Rec is the unnamed tab's in-memory record: naming it is all that is missing, and
            // keeping it (rather than a fresh Init) preserves the run options set on the tab.
            Rec.Name := CopyStr(NewName, 1, MaxStrLen(Rec.Name));
            Rec.Insert(true);
            // The Output panel of a tab that was never named only lived in TabOutputs.
            Rec.Output.CreateOutStream(OutStr, TextEncoding::UTF8);
            OutStr.Write(OutputText);
        end else begin
            Rec.Get(TabName);
            Rec.Rename(CopyStr(NewName, 1, MaxStrLen(Rec.Name)));
        end;

        Rec."AL Source Code".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(SourceCode);
        Rec.Modify();
        LastSavedSource := SourceCode;
        TabNames.Set(ActiveTab, Rec.Name);   // before SaveDiagnostics: it only writes into the active tab's script
        LastSavedDiags := '';   // force the diagnostics to follow the source onto the new record
        SaveDiagnostics();

        CurrPage.Update(false);
        PushTabs();
    end;

    // Named scripts are already written by TextChangedLong; this only makes the menu entry (and
    // Ctrl+S) mean something. An unnamed tab never reaches here — the add-in asks for a name
    // inline first, which comes back as 'rename'.
    local procedure SaveScript()
    var
        OutStr: OutStream;
    begin
        if not RecIsActiveScript() then
            exit;
        if SourceCode = LastSavedSource then
            exit;
        Rec."AL Source Code".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(SourceCode);
        Rec.Modify();
        LastSavedSource := SourceCode;
    end;

    local procedure OpenScript()
    var
        SelectedScript: Record "ALI Stored Script";
        ScriptList: Page "ALI Stored Scripts";
        i: Integer;
    begin
        ScriptList.LookupMode(true);
        ScriptList.SetRecord(Rec);
        if ScriptList.RunModal() <> Action::LookupOK then
            exit;

        // Get selected script
        ScriptList.SetSelectionFilter(SelectedScript);
        if not SelectedScript.FindFirst() then
            exit;

        // Already open: go to its tab instead of opening the same script twice.
        for i := 1 to TabNames.Count() do
            if TabNames.Get(i) = SelectedScript.Name then begin
                SwitchTab(i);
                exit;
            end;

        StashActiveTab();
        // An untouched blank tab is reused rather than left behind next to the opened script.
        // Reused: same index, other buffer — a new id, so no text of the blank one lands on it.
        if (TabNames.Get(ActiveTab) = '') and IsUntouchedSource(SourceCode) then begin
            TabNames.Set(ActiveTab, SelectedScript.Name);
            TabIds.Set(ActiveTab, NewTabId());
        end else begin
            TabNames.Add(SelectedScript.Name);
            TabBuffers.Add('');
            TabOutputs.Add('');
            TabIds.Add(NewTabId());
            ActiveTab := TabNames.Count();
        end;
        LoadActiveTab();
    end;

    // Compile & Run. The Problems panel always gets the compile's diagnostics; the Output panel is
    // only replaced by a run that compiled — a failed compile leaves the last good output in place
    // and brings Problems to the front instead.
    local procedure RunScript(ForceCompile: Boolean)
    var
        CompileSucceeded: Boolean;
        RunOutput: Text;
    begin
        // Stamped here, not inside Execute: the codeunit locals of Execute and of the stage
        // runners are built on procedure ENTRY, so their instantiation cost sits between this
        // line and the first statement of any of them. That is exactly the cold-start cost
        // Engine.Warmup() is meant to remove, and the stage timers can't see it.
        ActionStart := CurrentDateTime();
        RunOutput := Execute(ForceCompile, CompileSucceeded);
        // These diagnostics stand until the text changes: a live check of the SAME source (blur
        // flush) would replace the full compile's findings with its shallower ones.
        LastCheckedSource := SourceCode;
        SaveDiagnostics();
        PushDiagnostics();
        if not CompileSucceeded then begin
            ShowPanel('problems');
            exit;
        end;
        OutputText := RunOutput;
        SaveOutput();
        PushOutput();
        ShowPanel('output');
    end;

    local procedure ShowOptions()
    var
        OptionsPage: Page "ALI Script Options";
    begin
        OptionsPage.SetOptions(Rec);
        OptionsPage.LookupMode(true);
        if OptionsPage.RunModal() <> Action::LookupOK then
            exit;
        OptionsPage.GetOptions(Rec);
        if RecIsActiveScript() then
            if Rec.Modify() then;
        PushRunMode();
    end;

    // The run menu's Simulation switch: the same field the Settings page edits.
    local procedure SetSimulation(Simulation: Boolean)
    begin
        if Simulation then
            Rec."Exec Mode" := Rec."Exec Mode"::Simulation
        else
            Rec."Exec Mode" := Rec."Exec Mode"::Normal;
        if RecIsActiveScript() then
            if Rec.Modify() then;
        PushRunMode();
    end;

    local procedure PushRunMode()
    begin
        if SourceEditorInit then
            CurrPage.SourceEditor.SetRunMode(Rec."Exec Mode" = Rec."Exec Mode"::Simulation);
    end;

    // BC's own card navigation (next/previous record) still moves the page off the tab's script;
    // re-label the active tab to follow it instead of fighting it.
    local procedure SyncActiveTab()
    begin
        if (ActiveTab < 1) or (ActiveTab > TabNames.Count()) then
            exit;
        if TabNames.Get(ActiveTab) = Rec.Name then
            exit;
        TabNames.Set(ActiveTab, Rec.Name);
        TabBuffers.Set(ActiveTab, SourceCode);
        TabOutputs.Set(ActiveTab, OutputText);
        PushTabs();
    end;

    // The add-in indexes its tabs from 0, AL lists from 1.
    local procedure TabIndexArg(Arg: Text): Integer
    var
        Index: Integer;
    begin
        if not Evaluate(Index, Arg) then
            exit(0);
        exit(Index + 1);
    end;

    local procedure ClearResult()
    begin
        OutputText := '';
        PushOutput();
    end;
    #endregion

    #region Result panels
    // Send the Output panel only when it changed: OnAfterGetCurrRecord reloads it after every
    // Rec.Modify, and the live check modifies once per typing pause.
    local procedure PushOutput()
    begin
        if not ResultInit then
            exit;
        if OutputText = LastPushedOutput then
            exit;
        LastPushedOutput := OutputText;
        CurrPage.ResultEditor.SetText(OutputText);
    end;

    local procedure PushProblems()
    begin
        if not ResultInit then
            exit;
        if DiagnosticsJson = LastPushedProblems then
            exit;
        LastPushedProblems := DiagnosticsJson;
        CurrPage.ResultEditor.SetProblems(DiagnosticsJson);
    end;

    local procedure ShowPanel(Panel: Text)
    begin
        if ResultInit then
            CurrPage.ResultEditor.ShowPanel(Panel);
    end;

    // Named script: the Output blob. Unnamed tab: TabOutputs, kept by StashActiveTab.
    local procedure SaveOutput()
    var
        OutStr: OutStream;
    begin
        if (ActiveTab >= 1) and (ActiveTab <= TabOutputs.Count()) then
            TabOutputs.Set(ActiveTab, OutputText);
        if not RecIsActiveScript() then
            exit;
        Rec.Output.CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(OutputText);
        Rec.Modify();
    end;

    local procedure LoadOutput()
    var
        InStr: InStream;
    begin
        OutputText := '';
        Rec.CalcFields(Output);
        if Rec.Output.HasValue() then begin
            Rec.Output.CreateInStream(InStr, TextEncoding::UTF8);
            InStr.Read(OutputText);
        end;
        PushOutput();
    end;
    #endregion

    #region Procedure

    // Runs the source honoring the page options: sets exec mode on the shared "ALI Run Options",
    // picks the detailed/engine path, then appends the record-op report when requested. The text
    // returned is the Output panel's — only meaningful when CompileSucceeded.
    local procedure Execute(ForceCompile: Boolean; var CompileSucceeded: Boolean): Text
    var
        ObjRegistry: Codeunit "ALI Object Registry";
        RunOptions: Codeunit "ALI Run Options";
        Window: Dialog;
        Sb: TextBuilder;
    begin
        RunOptions.Reset();
        RunOptions.SetMode(Rec."Exec Mode".AsInteger());
        RunOptions.SetMessageMode(Rec."Message Mode".AsInteger());
        RunOptions.SetInteractionMode(Rec."Interaction Mode".AsInteger());
        RunOptions.SetDialogMode(Rec."Dialog Mode".AsInteger());
        RunOptions.SetAllowHttp(Rec."Allow HTTP");
        RunOptions.SetAllowProtectedWrite(Rec."Allow Protected Write");
        RunOptions.SetApplyRecordSecurity(Rec."Apply Record Security");
        RunOptions.SetVerbose(Rec.Verbose);

        Window.Open('Running AL-Interpreter...');

        if Rec."Exec Mode" = Rec."Exec Mode"::Simulation then begin
            Sb.AppendLine('');
            Out(Sb, "ALI Out Style"::Info, 'Simulation mode enabled : all DB writes rolled back, COMMIT ignored');
        end;

        // Compile+Run. Stored bytecode is checked first; verbose only changes how a real compile reports.
        Sb.Append(RunViaEngine(SourceCode, ForceCompile, CompileSucceeded));
        Window.Close();

        if CompileSucceeded then begin
            if Rec."Show Record Ops" then begin
                Sb.AppendLine('');
                Out(Sb, "ALI Out Style"::Header, '=== Record Operations ===');
                Out(Sb, "ALI Out Style"::Normal, RecRt.OpLogText());
            end;
        end;
        exit(Sb.ToText());
    end;

    // Runs each pipeline stage by hand (mirrors "ALI Engine"/"ALI Test Pipeline") instead of
    // calling Engine.Compile as one step, so every stage's timing + size can be reported even
    // when a later stage fails.
    local procedure CompileAndRun(Source: Text; var CompileSucceeded: Boolean): Text
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        Diags: Codeunit "ALI Diag Bag";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Lexer: Codeunit "ALI Lexer";
        Lowerer: Codeunit "ALI Lowerer";
        Module: Codeunit "ALI Module";
        ObjRegistry: Codeunit "ALI Object Registry";
        Parser: Codeunit "ALI Parser";
        PassMgr: Codeunit "ALI Pass Manager";
        RunOpt: Codeunit "ALI Run Options";
        Symbols: Codeunit "ALI Symbol Table";
        Tokens: Codeunit "ALI Token Table";
        CompileStart: DateTime;
        Window: Dialog;
        Root: Integer;
        Sb: TextBuilder;
    begin
        CompileSucceeded := false;
        Window.Open('Running AL Intepereter...\#1#####');
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Symbols.Reset();
        ObjRegistry.Reset();
        ObjRegistry.SetSignaturesOnly(false);   // a live check may have left it on (single instance)
        Module.Reset();
        if RunOpt.GetVerbose() then begin
            Diags.SetVerbose(true);
            Diags.SetSource(Source);
        end;

        // One total for the whole pipeline instead of a per-stage split. CurrentDateTime() has
        // ~8-16ms granularity on Windows, so individual stages (typically low tens of ms) land in
        // one or two clock ticks and the per-stage split was mostly quantization noise. The
        // aggregate spans enough ticks to be worth reading. Per-stage COUNTS stay — they are
        // exact and useful.
        Out(Sb, "ALI Out Style"::Header, '=== Compiler stages ===');
        CompileStart := CurrentDateTime();

        Window.Update(1, 'Lexer');
        Lexer.Tokenize(Source, Tokens, Diags);
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Lexer:     %1 tokens, %2 diag(s)', Tokens.Count(), Diags.Count()));
        if Diags.HasErrors() then
            exit(Finish(Sb, Diags));

        Window.Update(1, 'Parser');
        Root := Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Parser:    %1 AST node(s), %2 diag(s)', Ast.Count(), Diags.Count()));
        if Diags.HasErrors() then
            exit(Finish(Sb, Diags));

        Window.Update(1, 'Binder');
        Binder.SetRequireOnRun(true);
        if not Binder.Bind(Tokens, Ast, Symbols, Diags, Module, Root) then
            exit(Finish(Sb, Diags));
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Binder:    %1 symbol(s), %2 diag(s)', Symbols.Count(), Diags.Count()));

        if Rec.Optimize then begin
            Window.Update(1, 'Optimizer');
            PassMgr.Reset();
            PassMgr.AddDefault();
            PassMgr.RunAll(Tokens, Ast, Symbols, Diags, Root);
            Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Optimizer: %1 pass(es)', PassMgr.PassCount()));
        end;

        Window.Update(1, 'Lowerer');
        if not Lowerer.Lower(Tokens, Ast, Symbols, Diags, Module, Root) then
            exit(Finish(Sb, Diags));
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Lowerer:   %1 instr, %2 operand(s), %3 diag(s)', Module.InstrCount(), Module.OperandCount(), Diags.Count()));
        AppendCompileTotal(Sb, CompileStart);
        CompileSucceeded := true;
        DiagnosticsJson := Diags.ToJson(); // compile OK — still surface warnings/infos
        StoreModule(Module.Serialize(), CompiledHash(Source));

        Window.Update(1, 'Execute bytecode...');
        Interp.LoadModule(Module);
        RunOpt.SetAllowHttp(Rec."Allow HTTP");
        RunOpt.SetAllowProtectedWrite(Rec."Allow Protected Write");
        RunOpt.SetApplyRecordSecurity(Rec."Apply Record Security");
        Interp.Run(Result);
        // Verbose: quote the failing instruction in the result (line map lives in the bag).
        if (not Result.Succeeded()) and RunOpt.GetVerbose() and (Result.ErrorLine() >= 1) then
            Result.SetErrorSourceText(Diags.GetSourceLine(Result.ErrorLine()));
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Interpreter: %1 statement(s) executed (%2 ms)', Result.ExecutedStatements(), Result.DurationMs()));

        Sb.AppendLine('');
        Out(Sb, "ALI Out Style"::Header, '=== Log ===');
        OutRunMessages(Sb, Result);

        Sb.AppendLine('');
        Out(Sb, "ALI Out Style"::Header, '=== Result ===');
        OutResult(Sb, Result);

        Window.Close();
        exit(Sb.ToText());
    end;

    // Total wall time for the whole front-to-back compile. Reported once rather than per stage:
    // see the granularity note at the call sites.
    local procedure AppendCompileTotal(var Sb: TextBuilder; CompileStart: DateTime)
    begin
        Out(Sb, "ALI Out Style"::Dim, StrSubstNo('Compile:   %1 ms total', CurrentDateTime() - CompileStart));
    end;

    // Failed compile: the diagnostics go to the Problems panel; the stage log is not shown (the
    // Output panel keeps the last good run).
    local procedure Finish(var Sb: TextBuilder; var Diags: Codeunit "ALI Diag Bag"): Text
    begin
        DiagnosticsJson := Diags.ToJson();
        exit(Sb.ToText());
    end;

    // ── Result pane output ───────────────────────────────────────────────────────────────
    // Every line written to the Output panel goes through OutAt, which opens it with the marker
    // <SOH>StyleName[@line,col]<STX>. The "ALI Code Editor" add-in strips the marker, paints the
    // line with the style's CSS class and, when a location is given, makes it a link to that
    // spot in the source pane. Lines of a multi-line Txt carry the style and link of the first.
    // The style is decided here, next to the text, so rewording an output line never silently
    // breaks its coloring. (The Problems panel is drawn by the add-in from the diagnostics JSON.)
    local procedure Out(var Sb: TextBuilder; Style: Enum "ALI Out Style"; Txt: Text)
    begin
        OutAt(Sb, Style, Txt, 0, 0);
    end;

    local procedure OutAt(var Sb: TextBuilder; Style: Enum "ALI Out Style"; Txt: Text; Ln: Integer; Col: Integer)
    var
        Soh: Text[1];
        Stx: Text[1];
    begin
        Soh[1] := 1;
        Stx[1] := 2;
        Sb.Append(Soh);
        Sb.Append(Style.Names.Get(Style.Ordinals.IndexOf(Style.AsInteger())));
        if Ln > 0 then
            Sb.Append('@' + Format(Ln, 0, 9) + ',' + Format(Col, 0, 9)); // format 9: no thousands separator
        Sb.Append(Stx);
        Sb.AppendLine(Txt);
    end;

    local procedure OutRunMessages(var Sb: TextBuilder; var Result: Codeunit "ALI Exec Result")
    var
        SecRecRt: Codeunit "ALI Rec Runtime";
        i: Integer;
    begin
        // "Apply Record Security" option: which tables the run saw restricted (single-instance runtime).
        if SecRecRt.SecurityNotesText() <> '' then
            Out(Sb, "ALI Out Style"::Info, SecRecRt.SecurityNotesText());
        for i := 1 to Result.CollectedMessageCount() do
            Out(Sb, "ALI Out Style"::Normal, StrSubstNo('[Message] %1', Result.GetCollectedMessage(i)));
        for i := 1 to Result.RuntimeWarningCount() do
            Out(Sb, "ALI Out Style"::Warning, StrSubstNo('[Warning] %1', Result.GetRuntimeWarning(i)));
    end;

    local procedure OutResult(var Sb: TextBuilder; var Result: Codeunit "ALI Exec Result")
    begin
        if Result.Succeeded() then
            Out(Sb, "ALI Out Style"::Ok, Result.ToText())
        else
            OutAt(Sb, "ALI Out Style"::Error, Result.ToText(), Result.ErrorLine(), Result.ErrorColumn());
    end;

    // Compile-only pass on every (JS-debounced) text change: no execution, no dialogs —
    // just push the fresh diagnostics back to the editor so squiggles track typing. Runs
    // synchronously in this client-initiated callback (the only context BC lets us call the
    // editor add-in back from); the JS side debounces to a 1s typing pause so a large script
    // is compiled once per pause, not per keystroke. A Page Background Task can't drive this:
    // BC forbids control add-in callbacks from OnPageBackgroundTaskCompleted/Error.
    //
    // ponytail: the live check binds referenced objects' signatures only, so an error the full
    // compile found inside a harvested object body disappears from Problems on the next edit and
    // comes back on the next Compile & Run. Tracking which diagnostics the live check cannot see
    // would cost it its speed.
    local procedure LiveCompileCheck()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        ObjRegistry: Codeunit "ALI Object Registry";
    begin
        // Source unchanged since the last check (dupe input event, navigation): squiggles are
        // already current — skip the whole front-end pass.
        if SourceCode = LastCheckedSource then begin
            // The editor's status strip waits for a SetDiagnostics answer to every round-trip it
            // started, so still push the (unchanged) diagnostics before leaving.
            PushDiagnostics();
            exit;
        end;
        LastCheckedSource := SourceCode;

        if SourceCode.Trim() = '' then
            DiagnosticsJson := '[]'
        else begin
            // Front-end only (lexer+parser+binder, no optimizer/lowerer): all syntax/semantic
            // errors, none of the codegen cost — no execution here, no Module needed.
            Engine.SetRequireOnRun(true);
            Engine.SetVerbose(false);   // see RunViaEngine
            Engine.CheckDiagnostics(SourceCode, Diags);
            DiagnosticsJson := Diags.ToJson();
        end;
        SaveDiagnostics();
        PushDiagnostics();
    end;

    // Send diagnostics to the editor after every live check, unchanged ones included: the same
    // call is what tells the editor's status strip that the compile round-trip finished. Pushing
    // identical diagnostics only redraws the squiggle layer, which is a no-op when there are none.
    // The Problems panel gets them too, but only when they changed.
    local procedure PushDiagnostics()
    begin
        if SourceEditorInit then
            CurrPage.SourceEditor.SetDiagnostics(DiagnosticsJson);
        PushProblems();
    end;

    // Persist/restore the last compile's diagnostics with the script, so squiggles
    // reappear when a stored script is reopened.
    local procedure SaveDiagnostics()
    var
        OutStr: OutStream;
    begin
        if not RecIsActiveScript() then
            exit;
        // Unchanged diagnostics: skip the write. Rec.Modify() forces the client to re-read the
        // record, and the live check runs once per typing pause.
        if DiagnosticsJson = LastSavedDiags then
            exit;
        LastSavedDiags := DiagnosticsJson;
        Clear(Rec."Compile Diagnostics");
        Rec."Compile Diagnostics".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(DiagnosticsJson);
        Rec.Modify();
    end;

    local procedure LoadDiagnostics()
    var
        InStr: InStream;
    begin
        DiagnosticsJson := '[]';
        Rec.CalcFields("Compile Diagnostics");
        if Rec."Compile Diagnostics".HasValue() then begin
            Rec."Compile Diagnostics".CreateInStream(InStr, TextEncoding::UTF8);
            InStr.Read(DiagnosticsJson);
        end;
        if DiagnosticsJson = '' then
            DiagnosticsJson := '[]';
        LastSavedDiags := DiagnosticsJson;
        PushDiagnostics();
    end;

    // Single-call path through the real facade (no per-stage breakdown) — exercises the same
    // "ALI Engine" a real external caller would use, as a sanity check against the hand-rolled
    // stage-by-stage path above. A named script whose stored bytecode still matches the hash
    // skips the compile entirely (ForceCompile overrides).
    local procedure RunViaEngine(Source: Text; ForceCompile: Boolean; var CompileSucceeded: Boolean): Text
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Hash: Text;
        Sb: TextBuilder;
    begin
        Engine.SetOptimize(Rec.Optimize);
        Engine.SetRequireOnRun(true);
        Engine.SetVerbose(false);   // single instance: the AI tool leaves it on; the editor drives verbose through RunOptions
        Hash := CompiledHash(Source);
        if not ForceCompile then
            CompileSucceeded := LoadStoredModule(Engine, Hash);
        if CompileSucceeded then
            // Diagnostics stay what the live check last found for this same source.
            Out(Sb, "ALI Out Style"::Dim, 'Compile skipped, stored bytecode up to date (use the Force Compile & Run to recompile external procedure if they''ve changed)')
        else begin
            if Rec.Verbose then
                exit(CompileAndRun(Source, CompileSucceeded));  // reports every stage, stores the module too
            if not Engine.Compile(Source, Diags) then begin
                DiagnosticsJson := Diags.ToJson();
                exit('');
            end;
            CompileSucceeded := true;
            DiagnosticsJson := Diags.ToJson(); // compile OK — still surface warnings/infos
            StoreModule(Engine.SaveCompiled(), Hash);
        end;
        Engine.SetAllowHttp(Rec."Allow HTTP");
        Engine.SetAllowProtectedWrite(Rec."Allow Protected Write");
        Engine.SetApplyRecordSecurity(Rec."Apply Record Security");
        Engine.RunCompiled(Result);

        OutRunMessages(Sb, Result);
        OutResult(Sb, Result);

        exit(Sb.ToText());
    end;
    #endregion

    #region Stored bytecode
    // The stored module is only as current as what it was compiled from. The hash covers what
    // this page controls: the source, this app's version (opcodes, builtin ids, serialized shape)
    // and the options that change the bytecode. Objects the script calls into (M11 object calls)
    // are NOT covered — changing one of them is what "Force Compile & Run" is for.
    local procedure CompiledHash(Source: Text): Text
    var
#if not CLOUD
        PreprocSymbol: Record "ALI Preproc Symbol";
#endif
        Crypto: Codeunit "Cryptography Management";
        AppInfo: ModuleInfo;
        HashAlgorithmType: Option MD5,SHA1,SHA256,SHA384,SHA512;
        Sb: TextBuilder;
    begin
        NavApp.GetCurrentModuleInfo(AppInfo);
        Sb.Append(Format(AppInfo.AppVersion()));
        Sb.Append(Format(Rec.Optimize, 0, 9));
        // Project-level preprocessor symbols steer which code of a harvested object compiles.
        // Nothing is harvested in a cloud build, so there is nothing for them to steer.
#if not CLOUD
        if PreprocSymbol.FindSet() then
            repeat
                Sb.Append(Format(PreprocSymbol."App ID") + ':' + PreprocSymbol.Symbol + ';');
            until PreprocSymbol.Next() = 0;
#endif
        Sb.Append('|');
        Sb.Append(Source);
        exit(Crypto.GenerateHash(Sb.ToText(), HashAlgorithmType::SHA256));
    end;

    // An unnamed tab has no row to keep bytecode in: it always compiles.
    local procedure LoadStoredModule(var Engine: Codeunit "ALI Engine"; Hash: Text) HasCompiled: Boolean
    var
        InStr: InStream;
        Serialized: Text;
    begin
        if not RecIsActiveScript() then
            exit(false);
        if Rec."Compiled Hash" <> Hash then
            exit(false);
        Rec.CalcFields("Compiled Code");
        if not Rec."Compiled Code".HasValue() then
            exit(false);
        Rec."Compiled Code".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(Serialized);
        exit(Engine.LoadCompiled(Serialized));
    end;

    // Written BEFORE the run: the interpreter commits pending writes when it opens the run's own
    // rollback scope, so a Simulation rollback never takes the stored bytecode with it.
    local procedure StoreModule(Serialized: Text; Hash: Text)
    var
        OutStr: OutStream;
    begin
        if not RecIsActiveScript() then
            exit;
        if Serialized = '' then
            exit;
        Rec."Compiled Code".CreateOutStream(OutStr, TextEncoding::UTF8);
        OutStr.Write(Serialized);
        Rec."Compiled Hash" := CopyStr(Hash, 1, MaxStrLen(Rec."Compiled Hash"));
        Rec.Modify();
    end;
    #endregion
}
