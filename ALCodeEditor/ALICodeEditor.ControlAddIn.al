// ALI Code Editor — controladdin wrapping a textarea+<pre> overlay for AL source editing:
// bigger monospace font, lightweight AL-flavored syntax coloring, and Tab/Enter auto-indent.
// Used by "ALI Playground" in place of a plain MultiLine text field.
//
// AL-callable procedures (SetText, SetReadOnly) must resolve as global functions in a file
// loaded via Scripts — the StartupScript blob runs in a context where the client's method
// dispatch can't see functions defined only there. So the actual editor logic lives in the
// ALICodeEditor*.js files (Scripts); StartupScript is just the one-line call that kicks it off.
//
// Those files share one global scope and are loaded in the order listed below — State first
// (globals + helpers everything else reads), Main last (Startup + the AL entry points).
//
// Controladdin calls into JS are fire-and-forget (no return value), so there is no GetText.
// JS pushes the current text back to AL via TextChanged on every edit; callers read the
// latest value from the page variable that trigger keeps in sync instead of pulling it.
controladdin "ALI Code Editor"
{
    HorizontalShrink = true;
    HorizontalStretch = true;
    // Height is taken over by the add-in itself (ALICodeEditor_fitHeight in Main.js): it measures
    // the host window and sizes the iframe(s) to fill it, so the page never needs an outer
    // scrollbar around the editors. These values only matter before that first pass runs.
    MinimumHeight = 120;
    MinimumWidth = 400;
    RequestedHeight = 300;
    RequestedWidth = 800;

    Scripts = 'ALCodeEditor/Resources/ALICodeEditorState.js',
              'ALCodeEditor/Resources/ALICodeEditorRender.js',
              'ALCodeEditor/Resources/ALICodeEditorHover.js',
              'ALCodeEditor/Resources/ALICodeEditorSuggest.js',
              'ALCodeEditor/Resources/ALICodeEditorChrome.js',
              'ALCodeEditor/Resources/ALICodeEditorMain.js';
    StartupScript = 'ALCodeEditor/Resources/ALICodeEditorStartup.js';
    StyleSheets = 'ALCodeEditor/Resources/ALICodeEditor.css';
    VerticalShrink = true;

    VerticalStretch = true;

    event ControlAddInReady();
    // TabId: the 'id' SetTabs gave the tab whose text this is (0 before any SetTabs).
    event TextChangedLong(Text: Text; TabId: Integer);

    // Fired when the editor needs the member list of an object it has not cached yet (record
    // field completion / hover, codeunit procedure completion). ObjectType is 'Table' or
    // 'Codeunit'. The page answers with SetObjectMembers(ObjectType, ObjectName, MembersJson).
    event RequestObjectMembers(ObjectType: Text; ObjectName: Text);

    // Single channel for every toolbar / tab-strip action. Command is one of 'new', 'open',
    // 'save', 'rename', 'select', 'close', 'run', 'forcerun', 'options', 'preproc',
    // 'simulation'; Arg carries the tab index for 'select'/'close', the new name for 'rename',
    // '1'/'0' for 'simulation', and is '' otherwise. One event rather than eleven: the page
    // answers with a case, the add-in with one invoke helper.
    event EditorCommand(Command: Text; Arg: Text);

    // Fired by a click on a Result pane line that carries a source link (1-based line/column).
    // The page relays it to the source pane's GotoLine: the two panes are separate iframes.
    event GotoLocation(Line: Integer; Column: Integer);

    // Lines may open with the marker <SOH>StyleName[@line,col]<STX> ("ALI Script Editor".OutAt):
    // stripped from the text, the line is painted with CSS class ali-out-<stylename> and, with
    // a location, becomes a link firing GotoLocation. Text without markers shows as sent.
    procedure SetText(Text: Text)

    // Selects the token at Line/Column (1-based), scrolls it into view and focuses the editor.
    procedure GotoLine(Line: Integer; Column: Integer)

    procedure SetReadOnly(ReadOnly: Boolean)

    // JSON array of {line, col, len, sev, msg} (1-based line/col, sev: 2=error 1=warning).
    // Draws wavy underlines under the ranges; hovering a range shows msg. '[]' clears.
    procedure SetDiagnostics(DiagJson: Text)

    // Master AL-language switch: syntax coloring + autocompletion + record hover. OFF turns
    // the control into a plain monospace viewer (the Result pane shows raw output, not AL).
    procedure SetALLanguage(Enabled: Boolean)

    // Full interpreter API catalog from "ALI Api Catalog".BuildCatalogJson():
    // { types: [..], builtins: [{n,min,max,r,p,ok}], methods: { TypeName: [{n,s,r}] } }.
    // Replaces the JS-hardcoded type/proc lists so completion always matches the interpreter.
    procedure SetApiCatalog(CatalogJson: Text)

    // Whether the "Preprocessor directives..." entry belongs in the Run menu. Off in a cloud
    // build, where there is no published-object source for those symbols to apply to and the
    // page behind the entry does not exist — see table "ALI Preproc Symbol".
    procedure SetPreprocAvailable(Available: Boolean)

    // All table names for `MyRec: Record <completion>`: [{n: Name, id: ID}, ...].
    procedure SetTableList(TablesJson: Text)

    // All codeunit names for `MyCU: Codeunit <completion>`: [{n: Name, id: ID}, ...].
    procedure SetCodeunitList(CodeunitsJson: Text)

    // All enum names for `MyEnum: Enum <completion>`: [{n: Name, id: ID}, ...].
    procedure SetEnumList(EnumsJson: Text)

    // Answer to RequestObjectMembers: for a table, its field list [{n, t, len, pk}, ...] plus
    // its own AL procedures as [{n, s, r, k:'p'}] rows when object calls are allowed; for a
    // codeunit, only those procedure rows.
    procedure SetObjectMembers(ObjectType: Text; ObjectName: Text; MembersJson: Text)

    // Full state of the tab strip, AL being the source of truth for it:
    // [{n: Name ('' = unsaved), d: Description (tooltip), a: is the active tab, id: tab id}, ...].
    // The array position is the tab index the EditorCommand event reports back; id is stable
    // for the life of the tab's buffer and is echoed by TextChangedLong.
    procedure SetTabs(TabsJson: Text)

    // Execution mode shown on the toolbar: the Run triangle is green in Simulation (writes rolled
    // back) and red in Normal (writes committed), and the run menu's switch follows it.
    procedure SetRunMode(Simulation: Boolean)

    // Output / Problems panels (the Result pane). The first ShowPanel call turns the panel strip
    // on; from then SetText fills the Output panel. SetProblems takes the SetDiagnostics JSON and
    // lists it as clickable lines. Panel is 'output' or 'problems'.
    procedure SetProblems(DiagJson: Text)
    procedure ShowPanel(Panel: Text)
}
