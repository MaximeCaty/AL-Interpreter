// ALI Exec Result — structured execution result, MINIMAL M4 version (§9, §16 M4).
//
// M4 fields: Succeeded, Start/End timestamps + DurationMs, ExecutedStatements,
// InstructionsExecuted, runtime error (message + source line/column via the module debug
// map), and the entry proc's result value (formatted text + TypeKind ordinal).
//
// M9 extends (designed not to break): compile diagnostics snapshot, ConsoleOutput,
// CollectedMessages, interpreted call-stack rendering, ToJson — all additive fields and
// getters; nothing here changes shape.
codeunit 51030 "ALI Exec Result"
{
    Access = Public;
    SingleInstance = false;

    var
        HasRun: Boolean;
        SucceededVal: Boolean;
        EndDT: DateTime;
        StartDT: DateTime;
        ErrColumn: Integer;
        ErrLine: Integer;
        ResultTypeOrdVal: Integer; // "ALI TypeKind" ordinal; 0 = no result value
        StmtCount: Integer;
        CollectedMessages: List of [Text];  // Message(...) interception, in call order
        RuntimeWarnings: List of [Text];    // ALI9xx warnings (e.g. unscripted Confirm/StrMenu)
        ErrMessage: Text;
        ErrSourceText: Text;    // verbose: the source instruction line the error points at
        ErrHint: Text;          // verbose: plain-language hint for the runtime error
        ResultTextVal: Text;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        SucceededVal := false;
        StartDT := 0DT;
        EndDT := 0DT;
        StmtCount := 0;
        ErrMessage := '';
        ErrLine := 0;
        ErrColumn := 0;
        ErrSourceText := '';
        ErrHint := '';
        ResultTextVal := '';
        ResultTypeOrdVal := 0;
        HasRun := false;
        Clear(CollectedMessages);
        Clear(RuntimeWarnings);
    end;

    // ===== setters =====

    // Record a Message(...) call (interception — never opens real UI)
    procedure AddCollectedMessage(Text_: Text)
    begin
        CollectedMessages.Add(Text_);
    end;

    // Record a runtime warning (e.g. unscripted Confirm/StrMenu answered by default)
    procedure AddRuntimeWarning(Text_: Text)
    begin
        RuntimeWarnings.Add(Text_);
    end;

    // ===== getters =====

    procedure CollectedMessageCount(): Integer
    begin
        exit(CollectedMessages.Count());
    end;

    procedure GetCollectedMessage(Idx: Integer): Text
    begin
        exit(CollectedMessages.Get(Idx));
    end;

    procedure RuntimeWarningCount(): Integer
    begin
        exit(RuntimeWarnings.Count());
    end;

    procedure GetRuntimeWarning(Idx: Integer): Text
    begin
        exit(RuntimeWarnings.Get(Idx));
    end;

    // ===== Setters (interpreter-facing) =====

    procedure SetStart(DT: DateTime)
    begin
        StartDT := DT;
    end;

    procedure SetEnd(DT: DateTime)
    begin
        EndDT := DT;
        HasRun := true;
    end;

    procedure SetSucceeded(Value: Boolean)
    begin
        SucceededVal := Value;
    end;

    procedure SetCounts(Statements: Integer; Instructions: Integer)
    begin
        StmtCount := Statements;
    end;

    procedure SetError(Msg: Text; LineNo: Integer; ColumnNo: Integer)
    begin
        ErrMessage := Msg;
        ErrLine := LineNo;
        ErrColumn := ColumnNo;
    end;

    // Verbose: the engine attaches the offending source line so runtime errors are
    // self-contained (line/column alone force the reader to re-count the source).
    procedure SetErrorSourceText(SourceLine: Text)
    begin
        ErrSourceText := SourceLine;
    end;

    procedure SetErrorHint(Hint: Text)
    begin
        ErrHint := Hint;
    end;

    procedure SetResultValue(FormattedValue: Text; TypeOrd: Integer)
    begin
        ResultTextVal := FormattedValue;
        ResultTypeOrdVal := TypeOrd;
    end;

    // ===== Getters =====

    procedure Succeeded(): Boolean
    begin
        exit(SucceededVal);
    end;

    procedure StartDateTime(): DateTime
    begin
        exit(StartDT);
    end;

    procedure EndDateTime(): DateTime
    begin
        exit(EndDT);
    end;

    procedure DurationMs(): BigInteger
    var
        DurMs: BigInteger;
    begin
        if (StartDT = 0DT) or (EndDT = 0DT) then
            exit(0);
        DurMs := EndDT - StartDT;
        exit(DurMs);
    end;

    procedure ExecutedStatements(): Integer
    begin
        exit(StmtCount);
    end;

    procedure ErrorMessage(): Text
    begin
        exit(ErrMessage);
    end;

    procedure ErrorLine(): Integer
    begin
        exit(ErrLine);
    end;

    procedure ErrorColumn(): Integer
    begin
        exit(ErrColumn);
    end;

    procedure ErrorSourceText(): Text
    begin
        exit(ErrSourceText);
    end;

    procedure ResultText(): Text
    begin
        exit(ResultTextVal);
    end;

    procedure ResultTypeOrd(): Integer
    begin
        exit(ResultTypeOrdVal);
    end;

    procedure HasResult(): Boolean
    begin
        exit(ResultTypeOrdVal <> 0);
    end;

    // ===== Result Rendering =====
    procedure ToText(): Text
    var
        Sb: TextBuilder;
    begin
        if not HasRun then
            exit('<not run>');
        if SucceededVal then begin
            Sb.Append('OK');
            if HasResult() then begin
                Sb.Append(' -> ');
                Sb.Append(ResultTextVal);
            end;
        end else begin
            Sb.Append('ERROR');
            if ErrLine > 0 then
                Sb.Append(StrSubstNo('(%1,%2)', ErrLine, ErrColumn));
            Sb.Append(': ');
            Sb.Append(RenderedErrorMessage());
        end;
        Sb.Append(StrSubstNo(' [%1 statements, %2 ms]', StmtCount, DurationMs()));
        if (not SucceededVal) and (ErrSourceText <> '') then begin
            Sb.AppendLine();
            Sb.Append('   | ');
            Sb.Append(ErrSourceText);
            if ErrColumn >= 1 then begin
                Sb.AppendLine();
                Sb.Append('   | ');
                Sb.Append(CaretPad(ErrSourceText, ErrColumn));
                Sb.Append('^');
            end;
        end;
        if (not SucceededVal) and (ErrHint <> '') then begin
            Sb.AppendLine();
            Sb.Append('   hint: ');
            Sb.Append(ErrHint);
        end;
        exit(Sb.ToText());
    end;

    // ErrMessage without its leading 'ALI973: ' / 'AL0118: ' code when the host asked for that
    // ("ALI Run Options".SetHideDiagCodes). Only a leading AL/ALI + digits + ': ' is stripped.
    local procedure RenderedErrorMessage(): Text
    var
        RunOpt: Codeunit "ALI Run Options";
        i: Integer;
    begin
        if not RunOpt.GetHideDiagCodes() then
            exit(ErrMessage);
        if not ErrMessage.StartsWith('AL') then
            exit(ErrMessage);
        i := 3;
        if StrLen(ErrMessage) >= 3 then
            if ErrMessage[3] = 'I' then
                i := 4;
        if i > StrLen(ErrMessage) then
            exit(ErrMessage);
        if not (ErrMessage[i] in ['0' .. '9']) then
            exit(ErrMessage);
        while (i <= StrLen(ErrMessage)) and (i < 10) do begin
            if not (ErrMessage[i] in ['0' .. '9']) then
                break;
            i += 1;
        end;
        if CopyStr(ErrMessage, i, 2) <> ': ' then
            exit(ErrMessage);
        exit(CopyStr(ErrMessage, i + 2));
    end;

    // Mirror the source line's whitespace up to Col-1 (tabs stay tabs) so the caret lands
    // under the offending column regardless of the reader's tab width.
    local procedure CaretPad(SrcLine: Text; Col: Integer): Text
    var
        i: Integer;
        TabTxt: Text[1];
        Sb: TextBuilder;
    begin
        TabTxt := ' ';
        TabTxt[1] := 9;
        for i := 1 to Col - 1 do
            if (i <= StrLen(SrcLine)) and (SrcLine[i] = 9) then
                Sb.Append(TabTxt)
            else
                Sb.Append(' ');
        exit(Sb.ToText());
    end;
}
