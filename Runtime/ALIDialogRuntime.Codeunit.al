// ALI Dialog Runtime — Dialog (progress window) execution. Dialog variables live in a SEPARATE
// flat handle space (like records, §7.5/§19.7 — List of [Dialog] is not a supported AL type,
// confirmed by an actual compile failure, so this stays array-backed like "ALI Rec Runtime")
// — a 1-based index into Bank.
//
// Interception (§8): a real dialog is only opened when Dialog mode = Show AND the host session
// has a GUI (see "ALI Run Options".EffectiveGuiAllowed). In Hide mode every method is a no-op,
// so scripts using progress windows run head-less without blocking. Update/Close guard on the
// per-handle open state so they never touch an unopened dialog.
//
// Progress fields (§8): a `@N@@@@` placeholder in the Open text is a progress bar. Native `@`
// fields take a raw number and draw their own bar, but this runtime uses plain text fields, so
// Open rewrites `@N@@@@` -> `#N####` (a text field of the same width) and remembers N as a
// progress field; Update(N, value) then renders a fixed 24-cell ASCII bar. The value must be a
// numeric 0..1 fraction (a value > 1 is read as a 0..100 percentage).
codeunit 51070 "ALI Dialog Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        RunOptions: Codeunit "ALI Run Options";
        IsOpen: array[32] of Boolean;
        ProgFields: array[5000] of Boolean; // Handle*50 + field no
        Bank: array[32] of Dialog;
        HandleCount: Integer;
        FreeIdx: List of [Integer];

    procedure Reset()
    begin
        CloseAll();
        Clear(Bank);
        Clear(IsOpen);
        Clear(ProgFields);
        HandleCount := 0;
        Clear(FreeIdx);
    end;

    local procedure MaxCapacity_(): Integer
    begin
        exit(32);
    end;

    // Reclaim a Dialog handle — NEVER leak an open window: close it first if still open, then
    // clear its progress-field markers and recycle the slot.
    procedure FreeDialog(H: Integer)
    begin
        if (H < 1) or (H > HandleCount) then
            exit;
        if IsOpen[H] then begin
            TryClose(H);
            IsOpen[H] := false;
        end;
        Clear(Bank[H]);
        ClearHandleProg(H);
        FreeIdx.Add(H);
    end;

    // Handle Lifecycle Unification: allocate (or reuse) a fresh Dialog handle — mirrors "ALI
    // List Runtime".NewList/"ALI Rec Runtime".NewRec. A Dialog var gets a fresh handle at
    // whichever proc entry declares it (global or local).
    procedure NewDialog(): Integer
    var
        H: Integer;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
            exit(H);
        end;
        HandleCount += 1;
        if HandleCount > MaxCapacity_() then
            Error('ALI972: too many concurrently live Dialog variables (max %1)', MaxCapacity_());
        exit(HandleCount);
    end;

    // Open(Text) — only shows a real window when Dialog mode = Show on a GUI host; else no-op.
    // `@N@@@@` progress placeholders are recorded and rewritten to `#N####` text fields either way.
    procedure OpenDlg(H: Integer; Msg: Text)
    var
        Rendered: Text;
    begin
        Guard(H);
        ClearHandleProg(H);
        Rendered := ParseProgressFields(H, Msg);
        if not RunOptions.EffectiveGuiAllowed() then
            exit;
        Bank[H].Open(Rendered);
        IsOpen[H] := true;
    end;

    procedure Update0(H: Integer)
    begin
        Guard(H);
        if not IsOpen[H] then
            exit;
        Bank[H].Update();
    end;

    procedure UpdateId(H: Integer; FieldId: Integer)
    begin
        Guard(H);
        if not IsOpen[H] then
            exit;
        Bank[H].Update(FieldId);
    end;

    procedure UpdateVal(H: Integer; FieldId: Integer; Value: Variant)
    begin
        Guard(H);
        if not IsOpen[H] then
            exit;
        if ProgFields[ProgKey(H, FieldId)] then
            Bank[H].Update(FieldId, RenderBar(ToFraction(Value)))
        else
            Bank[H].Update(FieldId, Format(Value));
    end;

    procedure CloseDlg(H: Integer)
    begin
        Guard(H);
        if not IsOpen[H] then
            exit;
        Bank[H].Close();
        IsOpen[H] := false;
    end;

    // ===== Progress fields =====

    // Scan Msg for `@N@@@@` runs: mark N as a progress field and return Msg with each run
    // rewritten to a same-width `#N####` text field (so the native dialog renders it as text).
    local procedure ParseProgressFields(H: Integer; Msg: Text): Text
    var
        FieldNo: Integer;
        i: Integer;
        j: Integer;
        k: Integer;
        RunLen: Integer;
        NumText: Text;
        Result: Text;
    begin
        i := 1;
        while i <= StrLen(Msg) do
            if Msg[i] <> '@' then begin
                Result += Msg[i];
                i += 1;
            end else begin
                // read field-number digits after the leading '@'
                j := i + 1;
                NumText := '';
                while j <= StrLen(Msg) do begin
                    if not IsDigit(Msg[j]) then
                        break;
                    NumText += Msg[j];
                    j += 1;
                end;
                // read the trailing '@' fill
                while j <= StrLen(Msg) do begin
                    if Msg[j] <> '@' then
                        break;
                    j += 1;
                end;
                RunLen := j - i;
                if (NumText <> '') and (RunLen >= 2) then begin
                    Evaluate(FieldNo, NumText);
                    ProgFields[ProgKey(H, FieldNo)] := true;     // mark N as a progress bar field
                    Result += '#' + NumText;                       // text field marker + field no
                    for k := 1 to RunLen - 1 - StrLen(NumText) do  // pad to the same width
                        Result += '#';
                    i := j;
                end else begin
                    Result += Msg[i];   // lone '@' (not a valid field) — keep verbatim
                    i += 1;
                end;
            end;
        exit(Result);
    end;

    // Fixed-width (24-cell) ASCII bar for a 0..1 fraction.
    local procedure RenderBar(Fraction: Decimal): Text
    var
        Filled: Integer;
        i: Integer;
        Result: Text;
    begin
        if Fraction < 0 then
            Fraction := 0;
        if Fraction > 1 then
            Fraction := 1;
        Filled := Round(Fraction * 24, 1, '<');
        for i := 1 to 24 do
            if i <= Filled then
                Result += '▰'
            else
                Result += '▱';
        exit(Result);
    end;

    // Variant -> 0..1 fraction. Accepts a 0..1 fraction directly; a value > 1 is read as a
    // 0..100 percentage and divided down. Non-numeric parses (0 on failure).
    local procedure ToFraction(Value: Variant): Decimal
    begin
        if Value.IsDecimal() or Value.IsInteger() then
            exit(Value)
        else
            exit(0);
    end;

    local procedure IsDigit(C: Char): Boolean
    begin
        exit((C >= '0') and (C <= '9'));
    end;

    // Composite key for the flat progress-field dictionary (AL has no array-of-Dictionary).
    local procedure ProgKey(H: Integer; FieldNo: Integer): Integer
    begin
        exit(H * 50 + FieldNo);
    end;

    local procedure ClearHandleProg(H: Integer)
    var
        K: Integer;
    begin
        // Keys() returns a copy, so removing during the loop is safe.
        for K := H to (H + 50) do
            ProgFields[H] := false;
    end;

    // Close any window still open (run teardown / re-allocate). Platform may have already closed
    // a dialog on its own (e.g. interpreter scope end) before we get here — TryClose() swallows
    // that "dialog not open" error per-handle so one stale handle can't stop the rest from closing.
    local procedure CloseAll()
    var
        i: Integer;
    begin
        for i := 1 to ArrayLen(IsOpen) do
            if IsOpen[i] then begin
                TryClose(i);
                IsOpen[i] := false;
            end;
    end;

    [TryFunction]
    local procedure TryClose(H: Integer)
    begin
        Bank[H].Close();
    end;

    local procedure Guard(H: Integer)
    begin
        if (H < 1) or (H > HandleCount) then
            Error('ALI973: Dialog handle %1 out of range', H);
    end;
}
