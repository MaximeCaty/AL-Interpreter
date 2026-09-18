// ALI TextBuilder Runtime — TextBuilder RefShim execution (M9).
//
// TextBuilder variables live in a SEPARATE flat handle space (like records/streams, §7.5/
// §19.7) — NOT a register class. A handle is a 1-based index into Bank.
//
// Bank is a List, NOT a fixed array. array[N] of TextBuilder was tried first but under native
// compilation all array slots ended up aliasing the SAME underlying StringBuilder — Append on
// any handle landed in one shared instance, so ToText(H) returned the concatenation of every
// builder appended so far, not just handle H. List.Add() forces a genuinely distinct instance
// per element (same reference semantics that already work for a single TextBuilder var), which
// avoids the aliasing.
codeunit 51037 "ALI TextBuilder Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        FreeIdx: List of [Integer];
        Bank: List of [TextBuilder];

    procedure Reset()
    begin
        Clear(Bank);
        Clear(FreeIdx);
    end;

    local procedure MaxCapacity_(): Integer
    begin
        exit(4096);
    end;

    // Handle Lifecycle Unification: allocate (or reuse) a fresh TextBuilder handle — mirrors
    // "ALI List Runtime".NewList. Replaces Allocate(N)'s eager binder-sealed pre-fill; a
    // TextBuilder var now gets a fresh handle at whichever proc entry declares it (global or
    // local, like every other handle-kind type), freed on frame pop.
    procedure NewTb(): Integer
    var
        H: Integer;
        NewBuilder: TextBuilder;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
            exit(H);
        end;
        if Bank.Count() >= MaxCapacity_() then
            Error('ALI970: too many concurrently live TextBuilder variables (max %1)', MaxCapacity_());
        Bank.Add(NewBuilder);
        exit(Bank.Count());
    end;

    // Reclaim a TextBuilder handle — clears it in place (Get() then Clear() on the local var
    // would only rebind the LOCAL reference, not the shared bank instance, same aliasing
    // reason as "ALI List Runtime".ClearList) and recycles the slot.
    procedure FreeTb(H: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            exit;
        Bank.Get(H, TB);
        Clear(TB);
        Bank.Set(H, TB);
        FreeIdx.Add(H);
    end;

    procedure Append(H: Integer; Value: Text)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Append(Value);
    end;

    procedure AppendLine(H: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.AppendLine();
    end;

    procedure AppendLineText(H: Integer; Value: Text)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.AppendLine(Value);
    end;

    procedure GetCapacity(H: Integer): Integer
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        exit(TB.Capacity());
    end;

    procedure SetCapacity(H: Integer; Value: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Capacity(Value);
    end;

    procedure ClearI(H: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Clear();
    end;

    procedure EnsureCapacity(H: Integer; Value: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.EnsureCapacity(Value);
    end;

    procedure Insert(H: Integer; Pos: Integer; Value: Text)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Insert(Pos, Value);
    end;

    procedure GetLength(H: Integer): Integer
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        exit(TB.Length());
    end;

    procedure SetLength(H: Integer; Value: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Length(Value);
    end;

    procedure MaxCapacity(H: Integer): Integer
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        exit(TB.MaxCapacity());
    end;

    procedure Remove(H: Integer; StartPos: Integer; Len: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Remove(StartPos, Len);
    end;

    procedure Replace(H: Integer; OldValue: Text; NewValue: Text)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Replace(OldValue, NewValue);
    end;

    procedure ReplaceRange(H: Integer; OldValue: Text; NewValue: Text; StartPos: Integer; Count: Integer)
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        TB.Replace(OldValue, NewValue, StartPos, Count);
    end;

    procedure ToText(H: Integer): Text
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        exit(TB.ToText());
    end;

    procedure ToTextRange(H: Integer; StartPos: Integer; Len: Integer): Text
    var
        TB: TextBuilder;
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error(HandleErr, H);
        Bank.Get(H, TB);
        exit(TB.ToText(StartPos, Len));
    end;

    var
        HandleErr: Label 'ALI971: TextBuilder handle %1 out of range';
}
