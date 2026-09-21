// ALI Builtin System — Message/Error/Confirm/StrMenu/Sleep interception + misc system
// builtins (§1.1, §8, §16 M7).
//
// Boundary contract: fixed array[16] of Variant + ArgCount (AL
// rejects `List of [Variant]` as a parameter type, AL0408).
//
// Interception contract (§8, never real UI):
//   * Message(...)  -> appended to CollectedMsg (out param); interpreter pushes it onto
//     ExecResult.CollectedMessages in call order. Never shows a dialog.
//   * Error(...)    -> this codeunit raises a NATIVE AL error via Error(...); the
//     interpreter's [TryFunction] boundary (already used for the whole run loop, §7.4)
//     catches it exactly like any other runtime error — no special plumbing needed here.
//   * Confirm(...)  -> consumes a SCRIPTED answer from "ALI Run Options" (default false
//     unless configured); Warned=true means no scripted answer/default was ever configured,
//     which the interpreter turns into an ALI9xx runtime warning (§8).
//   * StrMenu(...)  -> same scripting mechanism, Integer answer (0 = Cancel).
//   * Sleep(ms)     -> NEVER actually sleeps; capped via "ALI Run Options".SleepCapMs (0 by
//     default = no-op). This satisfies "never opens real UI / never blocks" (§8).
codeunit 51110 "ALI Builtin System"
{
    Access = Public;
    SingleInstance = false;

    var
        RunOptions: Codeunit "ALI Run Options";
        StrmRt: Codeunit "ALI Stream Runtime";
        LastErrorTextVal: Text;

    // CollectedMsg is set (non-empty flag via HasMessage) when the call was a Message(...).
    // Warned is set when a Confirm/StrMenu call fell back to an unconfigured default.
    procedure Invoke(UpperName: Text; var Args: array[16] of Variant; ArgCount: Integer; var ResultV: Variant; var HasMessage: Boolean; var CollectedMsg: Text; var Warned: Boolean; var WarningText: Text)
    begin
        HasMessage := false;
        Warned := false;
        case UpperName of
            'MESSAGE':
                begin
                    CollectedMsg := DoFormatMessage(Args, ArgCount);
                    HasMessage := true;
                    // Show mode: also render a real dialog when the host session has a GUI
                    // (still collected above so the result log keeps a record either way).
                    if (RunOptions.GetMessageMode() = 1) and GuiAllowed() then
                        Message(CollectedMsg);
                end;
            'ERROR':
                DoError(Args, ArgCount);   // raises — never returns
            'CONFIRM':
                ResultV := DoConfirm(Args, ArgCount, Warned, WarningText);
            'STRMENU':
                ResultV := DoStrMenu(Args, ArgCount, Warned, WarningText);
            'SLEEP':
                Sleep(Args[1]);
            'COMMIT':
                // Normal mode: a REAL commit — the run executes inside the interpreter's
                // conditional Codeunit.Run scope, so writes up to here are persisted and a
                // later runtime error no longer rolls them back. Simulation: the run enters
                // through "ALI Interpreter".RunLoopSimulation, which carries
                // [CommitBehavior(CommitBehavior::Ignore)], so this call is silently dropped
                // and the sentinel rollback still undoes every write (§8).
                Commit();
            'GUIALLOWED':
                ResultV := RunOptions.EffectiveGuiAllowed();   // Dialog mode Show + real host GUI (§8)
            'COMPANYNAME':
                ResultV := CompanyName();
            'USERID':
                ResultV := UserId();
            'USERSECURITYID':
                ResultV := UserSecurityId();
            'CREATEGUID':
                ResultV := CreateGuid();
            'ISNULLGUID':
                ResultV := IsNullGuid(GuidOf(Args[1]));
            'EVALUATE':
                Error('ALI981: Evaluate must be lowered as a var-param call, not a plain CALL_BUILTIN (binder contract)');
            'GETLASTERRORTEXT':
                ResultV := LastErrorTextVal;
            'GETLASTERRORCALLSTACK':
                ResultV := GetLastErrorCallStack();
#if not CLOUD
            'GETLASTERROROBJECT':
                ResultV := GetLastErrorObject();
#endif
            'GETLASTERRORCODE':
                ResultV := GetLastErrorCode();
            'SELECTLATESTVERSION':
                if ArgCount = 0 then
                    SelectLatestVersion()
                else
                    SelectLatestVersion(Args[1]);
            'CLEARLASTERROR':
                LastErrorTextVal := '';
            'SESSIONID':
                ResultV := SessionId();
            'GLOBALLANGUAGE':
                if ArgCount > 0 then
                    ResultV := GlobalLanguage(Args[1])
                else
                    ResultV := GlobalLanguage();
            'WINDOWSLANGUAGE':
                ResultV := WindowsLanguage();
            // ClientType / CurrentClientType / CurrentExecutionMode. Neither option type
            // converts to Integer directly (no implicit conversion, no AsInteger) — a Variant
            // round-trip is the only route to the ordinal, and it is exact.
            'CLIENTTYPE', 'CURRENTCLIENTTYPE':
                ResultV := OptionOrdinal(CurrentClientType());
            'CURRENTEXECUTIONMODE':
                ResultV := OptionOrdinal(CurrentExecutionMode());
            'COPYSTREAM':
                // Args 1/2 are stream HANDLES (streams ride the Int register path); the stream
                // runtime is SingleInstance, so this local instance shares its slot bank.
                if ArgCount >= 3 then
                    ResultV := StrmRt.CopyStreamTo(Args[1], Args[2], Args[3], true)
                else
                    ResultV := StrmRt.CopyStreamTo(Args[1], Args[2], 0, false);
            'CLEAR':
                ;   // handled by the lowerer as a typed reset of the var-param slot (no value semantics here)
            else
                Error('ALI980: ''%1'' is not a recognized system builtin function', UpperName);
        end;
    end;

    // Evaluate(var target, text[, number]) needs a live var-param write, which this
    // Variant-in/Variant-out boundary cannot express generically for every target register
    // class. The interpreter calls this DIRECT typed entry point instead (see
    // "ALI Interpreter".ExecEvaluateTarget) when BuiltinId = Evaluate; TypeOrd tells it which
    // native Evaluate overload to use.
    procedure TryEvaluateInt(SourceText: Text; var OutValue: Integer): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateBig(SourceText: Text; var OutValue: BigInteger): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateDec(SourceText: Text; var OutValue: Decimal): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateBool(SourceText: Text; var OutValue: Boolean): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateDate(SourceText: Text; var OutValue: Date): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateTime(SourceText: Text; var OutValue: Time): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    procedure TryEvaluateDateTime(SourceText: Text; var OutValue: DateTime): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    // Evaluate(var RecordID, Text) — native supports RecordID as an Evaluate target
    // (round-trips Format(SomeRecordId)'s text back into a RecordID).
    procedure TryEvaluateRecordId(SourceText: Text; var OutValue: RecordId): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    // Evaluate(var DateFormula, Text) — native DateFormula.Evaluate(Text) parses formula
    // syntax ('1M+2D') into the DateFormula value; false (target unchanged) on bad syntax.
    procedure TryEvaluateDateFormula(SourceText: Text; var OutValue: DateFormula): Boolean
    begin
        exit(Evaluate(OutValue, SourceText));
    end;

    // ===== internals =====

    local procedure DoFormatMessage(var Args: array[16] of Variant; ArgCount: Integer): Text
    var
        i: Integer;
        a: array[10] of Text;
        Fmt: Text;
    begin
        if ArgCount = 0 then
            exit('');
        Fmt := Format(Args[1]);
        if ArgCount = 1 then
            exit(Fmt);
        for i := 2 to ArgCount do
            if i - 1 <= 10 then
                a[i - 1] := Format(Args[i]);
        exit(StrSubstNo(Fmt, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]));
    end;

    local procedure DoError(var Args: array[16] of Variant; ArgCount: Integer)
    var
        i: Integer;
        a: array[10] of Text;
        Fmt: Text;
    begin
        Fmt := Format(Args[1]);
        for i := 2 to ArgCount do
            if i - 1 <= 10 then
                a[i - 1] := Format(Args[i]);
        Error(Fmt, a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9]);
    end;

    local procedure DoConfirm(var Args: array[16] of Variant; ArgCount: Integer; var Warned: Boolean; var WarningText: Text): Boolean
    var
        Answer: Boolean;
        Mode: Integer;
    begin
        Mode := RunOptions.GetInteractionMode();
        if (Mode = 2) and GuiAllowed() then   // Show: real dialog on a GUI host
            exit(Confirm(FirstArgText(Args, ArgCount), false));
        Answer := RunOptions.NextConfirmAnswer(Warned);
        // Error mode: refuse to guess an unconfigured answer — raise instead of warning.
        if Warned and (Mode = 1) then
            Error('ALI972: Confirm(''%1'') has no scripted answer (Interaction mode = Error)', FirstArgText(Args, ArgCount));
        if Warned then
            WarningText := StrSubstNo('ALI970: Confirm(''%1'') answered by unconfigured default (%2) — script an answer via ALI Run Options for deterministic runs', FirstArgText(Args, ArgCount), Format(Answer));
        exit(Answer);
    end;

    local procedure DoStrMenu(var Args: array[16] of Variant; ArgCount: Integer; var Warned: Boolean; var WarningText: Text): Integer
    var
        Answer: Integer;
        Mode: Integer;
    begin
        Mode := RunOptions.GetInteractionMode();
        if (Mode = 2) and GuiAllowed() then   // Show: real menu on a GUI host
            exit(StrMenu(FirstArgText(Args, ArgCount)));
        Answer := RunOptions.NextStrMenuAnswer(Warned);
        if Warned and (Mode = 1) then
            Error('ALI973: StrMenu(''%1'') has no scripted answer (Interaction mode = Error)', FirstArgText(Args, ArgCount));
        if Warned then
            WarningText := StrSubstNo('ALI971: StrMenu(''%1'') answered by unconfigured default (%2) — script an answer via ALI Run Options for deterministic runs', FirstArgText(Args, ArgCount), Answer);
        exit(Answer);
    end;

    local procedure GuidOf(V: Variant): Guid
    begin
        exit(V);
    end;

    // Ordinal of a system option value (ClientType/ExecutionMode). The Variant unbox to Integer
    // is what makes this work — see the call sites.
    local procedure OptionOrdinal(V: Variant): Integer
    var
        Res: Integer;
    begin
        Res := V;
        exit(Res);
    end;

    local procedure FirstArgText(var Args: array[16] of Variant; ArgCount: Integer): Text
    begin
        if ArgCount = 0 then
            exit('');
        exit(Format(Args[1]));
    end;

    procedure SetLastErrorText(Msg: Text)
    begin
        LastErrorTextVal := Msg;
    end;
}
