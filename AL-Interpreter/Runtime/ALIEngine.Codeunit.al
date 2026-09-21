// ALI Engine — the facade (§13, M5 v0). The only object external consumers need.
//
// v0 API:
//   Compile(Source, var Diags): Boolean
//       Runs lexer -> parser -> binder -> lowerer over Source; all diagnostics land in
//       Diags (collect-all — never stops at the first error, §19.1). Returns true on a
//       clean compile. The compiled Module stays inside this instance for a later Run.
//   CompileAndRun(Source, var Result): Boolean
//       Compile + LoadModule + Run. On compile failure Result carries the first
//       diagnostic as its error; returns Result.Succeeded().
//
// Every store/state codeunit is Reset() before use (§13 facade row, pitfall 19) — the
// single-instance interpreter included.
codeunit 51111 "ALI Engine"
{
    Access = Public;
    SingleInstance = true;

    var
        CompiledModule: Codeunit "ALI Module";
        HasModule: Boolean;
        OptimizeEnabled: Boolean;   // run optimizer passes (§12) between Bind and Lower; default off
        RequireOnRunEnabled: Boolean; // script entry must be `trigger OnRun()`; default off
        VerboseEnabled: Boolean;    // verbose diagnostics: quote source line + caret + hint; default off
        Warmed: Boolean;            // Warmup() already ran in this session
        SrcLines: List of [Text];   // source of the last Compile, split per line (verbose only)

    procedure SetAllowHttp(Allow: Boolean)
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        RunOpt.SetAllowHttp(Allow);
    end;

    procedure SetAllowProtectedWrite(Allow: Boolean)
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        RunOpt.SetAllowProtectedWrite(Allow);
    end;

    procedure SetApplyRecordSecurity(Apply: Boolean)
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        RunOpt.SetApplyRecordSecurity(Apply);
    end;

    // Enable/disable optimizer passes for subsequent Compile() calls. Off by default so
    // bytecode goldens and existing callers are unaffected until a host opts in.
    procedure SetOptimize(Value: Boolean)
    begin
        OptimizeEnabled := Value;
    end;

    // Strict entry point: the script must declare `trigger OnRun()`, which is then the ONLY entry
    // (no first-procedure fallback, no bare statement block) — ALI1000 otherwise. Off by default:
    // the test suite and the AI tool rely on the first-procedure rule. Single-instance, so a host
    // that wants either behavior sets it before every compile.
    procedure SetRequireOnRun(Value: Boolean)
    begin
        RequireOnRunEnabled := Value;
    end;

    // Verbose error reporting (aimed at LLM/agent hosts): every compile diagnostic rendered
    // by the Diag Bag additionally quotes the offending source line with a column caret and
    // a plain-language hint; runtime errors carry the failing instruction's source line in
    // the Exec Result. Off by default — golden diagnostic shapes are unchanged until a host
    // opts in. Hosts without an engine reference can flip "ALI Run Options".SetVerbose
    // instead — either flag enables it.
    procedure SetVerbose(Value: Boolean)
    begin
        VerboseEnabled := Value;
    end;

    local procedure EffectiveVerbose(): Boolean
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        exit(VerboseEnabled or RunOpt.GetVerbose());
    end;

    // Compile Source through the full front end + lowerer. Diagnostics collect in Diags;
    // returns true when the compile is clean. The Module is retained for RunCompiled().
    procedure Compile(Source: Text; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        Lexer: Codeunit "ALI Lexer";
        Lowerer: Codeunit "ALI Lowerer";
        ObjRegistry: Codeunit "ALI Object Registry";
        Parser: Codeunit "ALI Parser";
        PassMgr: Codeunit "ALI Pass Manager";
        Symbols: Codeunit "ALI Symbol Table";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        HasModule := false;
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Symbols.Reset();
        ObjRegistry.Reset();        // cached symbols/scopes belong to the table we just reset
        ObjRegistry.SetSignaturesOnly(false);   // a real compile needs the bodies (the registry is single-instance)
        CompiledModule.Reset();
        Clear(SrcLines);
        Diags.SetHideCodes(HideDiagCodes());
        if EffectiveVerbose() then begin
            Diags.SetVerbose(true);
            Diags.SetSource(Source);
            SplitLines(Source, SrcLines);   // kept for runtime-error enrichment in RunCompiled
        end;

        Lexer.Tokenize(Source, Tokens, Diags);
        if Diags.HasErrors() then
            exit(false);

        Root := Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        if Diags.HasErrors() then
            exit(false);

        // Binder + type verification collect ALL semantic diagnostics in one pass (§19.1).
        // The Module goes in because binding reserves the proc-table rows (M11) — it was reset
        // above, before any of this.
        Binder.SetRequireOnRun(RequireOnRunEnabled);
        if not Binder.Bind(Tokens, Ast, Symbols, Diags, CompiledModule, Root) then
            exit(false);

        // Optimizer passes (§12) rewrite the bound AST in place before lowering.
        if OptimizeEnabled then begin
            PassMgr.Reset();
            PassMgr.AddDefault();
            PassMgr.RunAll(Tokens, Ast, Symbols, Diags, Root);
        end;

        if not Lowerer.Lower(Tokens, Ast, Symbols, Diags, CompiledModule, Root) then
            exit(false);

        HasModule := true;
        exit(true);
    end;

    // Front end only (lexer -> parser -> binder) for live error checking: collects every
    // syntax/semantic diagnostic in Diags without lowering to bytecode. Skips the optimizer
    // (emits no diagnostics) and the lowerer (only ever emits ALI940/941 "program too large",
    // which the interactive editor doesn't need and which still surface on a real Run). No
    // Module is produced — RunCompiled after this fails; use Compile() when you intend to run.
    procedure CheckDiagnostics(Source: Text; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        Lexer: Codeunit "ALI Lexer";
        Scratch: Codeunit "ALI Module";     // binding reserves proc rows (M11); nothing is lowered
        ObjRegistry: Codeunit "ALI Object Registry";
        Parser: Codeunit "ALI Parser";
        Symbols: Codeunit "ALI Symbol Table";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        HasModule := false;
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();
        Symbols.Reset();
        ObjRegistry.Reset();
        // A live check only has to say what is wrong in the SCRIPT: a referenced object is
        // harvested for its signatures (so `cu.Proc(a)` still type-checks) but none of its bodies
        // is bound or lowered, which is what dragged in the callee's whole dependency graph.
        // Whatever that costs is paid by the next real Compile(), which restores the flag.
        ObjRegistry.SetSignaturesOnly(true);
        Scratch.Reset();
        Diags.SetHideCodes(HideDiagCodes());
        if EffectiveVerbose() then begin
            Diags.SetVerbose(true);
            Diags.SetSource(Source);
        end;

        Lexer.Tokenize(Source, Tokens, Diags);
        if Diags.HasErrors() then
            exit(false);

        Root := Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        if Diags.HasErrors() then
            exit(false);

        Binder.SetRequireOnRun(RequireOnRunEnabled);
        exit(Binder.Bind(Tokens, Ast, Symbols, Diags, Scratch, Root));
    end;

    // The module of the last successful Compile as text, to be stored and handed back to
    // LoadCompiled in a later session — '' when there is none. It is only as current as the
    // source AND every object it harvested (M11 object calls): the host keys it on a hash of what
    // it controls and offers a forced recompile for the rest.
    procedure SaveCompiled(): Text
    begin
        if not HasModule then
            exit('');
        exit(CompiledModule.Serialize());
    end;

    // Makes a stored module the one RunCompiled executes, skipping the whole compile. False when
    // the text is not a module this build can run — compile the source instead.
    procedure LoadCompiled(Serialized: Text): Boolean
    begin
        Clear(SrcLines);    // no source here: runtime errors keep their line/column, not the quote
        HasModule := CompiledModule.Deserialize(Serialized);
        exit(HasModule);
    end;

    // Compile and, when clean, execute. Returns Result.Succeeded(); a compile failure
    // surfaces as a failed Result carrying the first diagnostic.
    procedure CompileAndRun(Source: Text; var Result: Codeunit "ALI Exec Result"): Boolean
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        if not Compile(Source, Diags) then begin
            Result.Reset();
            Result.SetStart(CurrentDateTime());
            Result.SetEnd(CurrentDateTime());
            Result.SetSucceeded(false);
            Result.SetError(FirstErrorText(Diags), FirstErrorLine(Diags), 0);
            AttachErrorSource(Result);
            exit(false);
        end;
        exit(RunCompiled(Result));
    end;

    // Execute the most recently compiled module (Compile must have returned true).
    procedure RunCompiled(var Result: Codeunit "ALI Exec Result"): Boolean
    var
        Interp: Codeunit "ALI Interpreter";
    begin
        if not HasModule then begin
            Result.Reset();
            Result.SetStart(CurrentDateTime());
            Result.SetEnd(CurrentDateTime());
            Result.SetSucceeded(false);
            Result.SetError('ALI945: no module compiled', 0, 0);
            exit(false);
        end;
        Interp.Reset();                 // single-instance — always reset (pitfall 19)
        Interp.LoadModule(CompiledModule);
        Interp.Run(Result);
        AttachErrorSource(Result);
        exit(Result.Succeeded());
    end;

    // Compile+run one throwaway script so the pipeline is instantiated BEFORE the user's first
    // real Compile & Run. AL builds a procedure's codeunit locals on ENTRY, so that first call
    // pays for every store at once — the interpreter alone reserves ~90 fixed arrays (registers,
    // constant pools, four 65536-slot instruction arrays) — plus the single-instance Builtin
    // Registry Populate. Measured ~600ms first run vs ~130ms warm. A host with a startup step of
    // its own (the script editor's metadata load) calls this there, and the cost disappears into
    // a wait the user already accepts. Idempotent; single-instance, so once per session.
    procedure Warmup()
    var
        Result: Codeunit "ALI Exec Result";
        RunOpt: Codeunit "ALI Run Options";
        SavedRequireOnRun: Boolean;
        WarmupScript: Label 'var l: List of [Integer]; d: Dictionary of [Text, Integer]; tb: TextBuilder; procedure P(): Integer var a: array[4] of Integer; t: Text; i: Integer; begin l.Add(1); d.Add(''k'', 2); tb.Append(''w''); t := Format(1) + UpperCase(tb.ToText()); for i := 1 to 2 do a[i] := i; if a[2] > 0 then t := t + ''!''; exit(a[2] + l.Count() + d.Count() + StrLen(t)); end;', Locked = true;
    begin
        if Warmed then
            exit;
        Warmed := true;         // set BEFORE the run: a warmup that errors must not retry forever
        RunOpt.Reset();
        // ponytail: no Record/RecordRef in the script — "ALI Rec Runtime" is already a member of
        // the editor page, so it is instantiated at page open. Add a `Rec: Record x` line here if
        // a host without that member ever shows the same first-run lag on record scripts.
        // The warmup script uses the first-procedure entry rule, whatever the host asked for.
        SavedRequireOnRun := RequireOnRunEnabled;
        RequireOnRunEnabled := false;
        CompileAndRun(WarmupScript, Result);
        RequireOnRunEnabled := SavedRequireOnRun;
        HasModule := false;     // never leave the warmup module loaded for a later RunCompiled
    end;

    // Verbose: hand the failing instruction's source line to the result (§ verbose).
    // No verbose check needed — SrcLines is only ever filled when verbose was on at Compile.
    // Verbose also attaches a plain-language hint keyed on the runtime error text (1-based
    // indexes, 0-based JsonArray, missing Dictionary key...).
    local procedure AttachErrorSource(var Result: Codeunit "ALI Exec Result")
    var
        HintSource: Codeunit "ALI Diag Bag";
    begin
        if Result.Succeeded() then
            exit;
        if (Result.ErrorLine() >= 1) and (Result.ErrorLine() <= SrcLines.Count()) then
            Result.SetErrorSourceText(SrcLines.Get(Result.ErrorLine()));
        if EffectiveVerbose() then
            Result.SetErrorHint(HintSource.HintFor('', Result.ErrorMessage()));
    end;

    local procedure HideDiagCodes(): Boolean
    var
        RunOpt: Codeunit "ALI Run Options";
    begin
        exit(RunOpt.GetHideDiagCodes());
    end;

    local procedure SplitLines(Source: Text; var Lines: List of [Text])
    var
        CR: Text[1];
        LF: Text[1];
    begin
        CR := ' ';
        CR[1] := 13;
        LF := ' ';
        LF[1] := 10;
        Lines := Source.Replace(CR + LF, LF).Replace(CR, LF).Split(LF);
    end;

    // Index of the first ERROR, not of the first diagnostic: the bag also carries warnings and
    // informationals, some of them added early (during an M11 harvest), so reporting entry 1
    // blamed the compile failure on a message that was not the failure. 0 = the bag holds no
    // error at all.
    local procedure FirstErrorIdx(var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if Diags.GetSeverity(i) = "ALI Severity"::Error then
                exit(i);
        exit(0);
    end;

    local procedure FirstErrorText(var Diags: Codeunit "ALI Diag Bag"): Text
    var
        Idx: Integer;
    begin
        Idx := FirstErrorIdx(Diags);
        if Idx = 0 then
            exit('compilation failed');
        exit(StrSubstNo('%1: %2', Diags.GetCode(Idx), Diags.GetMessage(Idx)));
    end;

    local procedure FirstErrorLine(var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Idx: Integer;
    begin
        Idx := FirstErrorIdx(Diags);
        if Idx = 0 then
            exit(0);
        exit(Diags.GetLine(Idx));
    end;
}
