// ALI Run Options — budget/deadline, scripted Confirm/StrMenu answers, exec mode (§8/§13).
//
// M7: consolidates the statement budget (previously only "ALI Interpreter".SetBudget) with
// the NEW UI-interception knobs required by §8: Message/Error/Sleep are ALWAYS intercepted
// (never real UI — no option to turn that off); Confirm/StrMenu need a SCRIPTED answer
// because there is no user to click a dialog. Defaults mirror native "no interaction
// possible" behavior: Confirm defaults to the caller-chosen DefaultConfirmAnswer (false
// unless scripted), StrMenu defaults to 0 (Cancel), both recording an ALI9xx runtime
// warning through the caller (interpreter reads Warned* flags after each call — see
// "ALI Builtin System").
//
// SingleInstance mirrors "ALI Interpreter" (also single-instance) so options set by a host
// before Run() are visible without threading a var-param through every builtin call.
codeunit 51035 "ALI Run Options"
{
    Access = Public;
    SingleInstance = true;

    var
        AllowHttpVal: Boolean;             // M10: outbound HTTP capability gate (default false)
        AllowProtectedWriteVal: Boolean;   // write gate on protected/posted tables (default false)
        ApplyRecSecurityVal: Boolean;      // re-apply "TOO Record Security Filters" on every read (default false)
        DefaultConfirmAnswerVal: Boolean;
        HasScriptedConfirm: Boolean;
        HasScriptedStrMenu: Boolean;
        VerboseVal: Boolean;               // verbose diagnostics (source line + caret + hint; default false)
        HideDiagCodesVal: Boolean;         // render diagnostics / runtime errors without their ALI code (default false)
        DefaultStrMenuAnswerVal: Integer;
        DialogModeVal: Integer;            // "ALI Dialog Mode" ordinal (0 Hide / 1 Show)
        InteractionModeVal: Integer;       // "ALI Interaction Mode" ordinal (0 Default / 1 Error / 2 Show)
        MessageModeVal: Integer;           // "ALI Message Mode" ordinal (0 Log / 1 Show)
        ModeVal: Integer;                  // "ALI Exec Mode" ordinal (0 Normal / 1 Simulation)
        ScriptedConfirmCursor: Integer;
        ScriptedStrMenuCursor: Integer;
        StatementBudget: Integer;
        ScriptedConfirmQueue: List of [Boolean];
        ScriptedStrMenuQueue: List of [Integer];

    procedure Reset()
    begin
        ModeVal := 0;
        StatementBudget := 10000000;
        DefaultConfirmAnswerVal := false;
        HasScriptedConfirm := false;
        Clear(ScriptedConfirmQueue);
        ScriptedConfirmCursor := 0;
        DefaultStrMenuAnswerVal := 0;
        HasScriptedStrMenu := false;
        Clear(ScriptedStrMenuQueue);
        ScriptedStrMenuCursor := 0;
        MessageModeVal := 0;
        InteractionModeVal := 0;
        DialogModeVal := 0;
        AllowHttpVal := false;
        AllowProtectedWriteVal := false;
        ApplyRecSecurityVal := false;
        VerboseVal := false;
        HideDiagCodesVal := false;
    end;

    // ===== Verbose diagnostics =====
    //
    // Single-instance twin of "ALI Engine".SetVerbose: hosts that only reach the engine
    // through a facade (e.g. the script editor's CompileAndRun) flip it here; the engine
    // honors EITHER flag.
    procedure SetVerbose(Value: Boolean)
    begin
        VerboseVal := Value;
    end;

    procedure GetVerbose(): Boolean
    begin
        exit(VerboseVal);
    end;

    // Render compile diagnostics and runtime errors without their code ('ALI984: '). LLM hosts turn
    // it on — the code costs tokens and tells the model nothing; the script editor keeps it.
    procedure SetHideDiagCodes(Value: Boolean)
    begin
        HideDiagCodesVal := Value;
    end;

    procedure GetHideDiagCodes(): Boolean
    begin
        exit(HideDiagCodesVal);
    end;

    // ===== Protected-table write gate =====
    //
    // "ALI Rec Runtime" carries a Permissions property covering every protected (posted/ledger)
    // table, because the property is static — it cannot be granted per run. This flag is the
    // dynamic half: off by default, so scripts get the native "you can't write posted entries"
    // behavior; a host turns it on for the rare data-fix script.
    procedure SetAllowProtectedWrite(Value: Boolean)
    begin
        AllowProtectedWriteVal := Value;
    end;

    procedure AllowProtectedWrite(): Boolean
    begin
        exit(AllowProtectedWriteVal);
    end;

    // ===== Record security filters =====
    //
    // On: every real table the script opens gets the application security filters raised by
    // "TOO Record Security Filters" (filter group 2), re-applied before each read and checked
    // after each Get. Off by default; AI hosts turn it on.
    procedure SetApplyRecordSecurity(Value: Boolean)
    begin
        ApplyRecSecurityVal := Value;
    end;

    procedure ApplyRecordSecurity(): Boolean
    begin
        exit(ApplyRecSecurityVal);
    end;

    // ===== Http capability gate (M10) =====
    //
    // Scripts gain outbound HTTP = a new capability class, distinct from every other builtin
    // (which only ever touches the BC database/session). Off by default — stored scripts run
    // server-side and must not ship open to the network unless a host explicitly opts in.
    procedure SetAllowHttp(Value: Boolean)
    begin
        AllowHttpVal := Value;
    end;

    procedure AllowHttp(): Boolean
    begin
        exit(AllowHttpVal);
    end;

    // ===== Runtime handler modes (§8) =====

    procedure SetMessageMode(Mode: Integer)
    begin
        MessageModeVal := Mode;
    end;

    procedure GetMessageMode(): Integer
    begin
        exit(MessageModeVal);
    end;

    procedure SetInteractionMode(Mode: Integer)
    begin
        InteractionModeVal := Mode;
    end;

    procedure GetInteractionMode(): Integer
    begin
        exit(InteractionModeVal);
    end;

    procedure SetDialogMode(Mode: Integer)
    begin
        DialogModeVal := Mode;
    end;

    procedure GetDialogMode(): Integer
    begin
        exit(DialogModeVal);
    end;

    // GuiAllowed() the interpreter reports to scripts: true only in Dialog "Show" mode AND when
    // the host BC session actually has a GUI (a job-queue/web-service host never has one).
    procedure EffectiveGuiAllowed(): Boolean
    begin
        exit((DialogModeVal = 0) and GuiAllowed());
    end;

    // ===== Mode =====

    procedure SetMode(Mode: Integer)
    begin
        ModeVal := Mode;
    end;

    procedure GetMode(): Integer
    begin
        exit(ModeVal);
    end;

    procedure IsSimulation(): Boolean
    begin
        exit(ModeVal = 1);
    end;

    // ===== Budget / deadline =====

    procedure SetStatementBudget(MaxStatements: Integer)
    begin
        StatementBudget := MaxStatements;
    end;

    procedure GetStatementBudget(): Integer
    begin
        exit(StatementBudget);
    end;

    // ===== Scripted Confirm (§8: "configurable scripted answers") =====

    // Set a single default answer used for every Confirm() call that doesn't consume a
    // queued answer.
    procedure SetDefaultConfirmAnswer(Value: Boolean)
    begin
        DefaultConfirmAnswerVal := Value;
        HasScriptedConfirm := true;
    end;

    // Queue a sequence of answers consumed in order, one per Confirm() call; once exhausted,
    // falls back to DefaultConfirmAnswer.
    procedure QueueConfirmAnswer(Value: Boolean)
    begin
        ScriptedConfirmQueue.Add(Value);
        HasScriptedConfirm := true;
    end;

    procedure ClearConfirmAnswers()
    begin
        Clear(ScriptedConfirmQueue);
        ScriptedConfirmCursor := 0;
    end;

    // Consume the next scripted answer (queue first, then default). Warned = true when NO
    // answer was ever configured (pure default fallback with nothing scripted at all) — the
    // caller (builtin handler) turns that into an ALI9xx runtime warning (§8).
    procedure NextConfirmAnswer(var Warned: Boolean): Boolean
    var
    begin
        Warned := not HasScriptedConfirm;
        if ScriptedConfirmCursor < ScriptedConfirmQueue.Count() then begin
            ScriptedConfirmCursor += 1;
            exit(ScriptedConfirmQueue.Get(ScriptedConfirmCursor));
        end;
        exit(DefaultConfirmAnswerVal);
    end;

    // ===== Scripted StrMenu (§8) =====

    procedure SetDefaultStrMenuAnswer(Value: Integer)
    begin
        DefaultStrMenuAnswerVal := Value;
        HasScriptedStrMenu := true;
    end;

    procedure QueueStrMenuAnswer(Value: Integer)
    begin
        ScriptedStrMenuQueue.Add(Value);
        HasScriptedStrMenu := true;
    end;

    procedure ClearStrMenuAnswers()
    begin
        Clear(ScriptedStrMenuQueue);
        ScriptedStrMenuCursor := 0;
    end;

    procedure NextStrMenuAnswer(var Warned: Boolean): Integer
    begin
        Warned := not HasScriptedStrMenu;
        if ScriptedStrMenuCursor < ScriptedStrMenuQueue.Count() then begin
            ScriptedStrMenuCursor += 1;
            exit(ScriptedStrMenuQueue.Get(ScriptedStrMenuCursor));
        end;
        exit(DefaultStrMenuAnswerVal);
    end;
}
