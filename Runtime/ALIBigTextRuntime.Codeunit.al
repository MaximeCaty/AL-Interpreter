// ALI BigText Runtime — BigText RefShim execution.
//
// BigText variables live in a SEPARATE flat handle space (like records/streams/TextBuilder,
// §7.5/§19.7) — NOT a register class. A handle is a 1-based index into Bank.
//
// Bank is a List, NOT a fixed array: `array[N] of BigText` has the same aliasing trap that was
// measured for TextBuilder (every slot ends up backed by ONE instance under native
// compilation), while List.Add() forces a genuinely distinct instance per element. See
// "ALI TextBuilder Runtime"'s header for the full write-up.
//
// Every mutating operation reads its slot, mutates, and writes it BACK with Bank.Set. That is
// redundant if BigText is a reference type and required if it is a value type — doing it
// unconditionally makes the bank correct either way, at the cost of one list write.
codeunit 51102 "ALI BigText Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        Bank: List of [BigText];
        FreeIdx: List of [Integer];

    procedure Reset()
    begin
        Clear(Bank);
        Clear(FreeIdx);
    end;

    local procedure MaxCapacity_(): Integer
    begin
        exit(4096);
    end;

    // Allocate (or reuse) a fresh BigText handle — mirrors "ALI TextBuilder Runtime".NewTb.
    procedure NewBt(): Integer
    var
        NewBig: BigText;
        H: Integer;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
            exit(H);
        end;
        if Bank.Count() >= MaxCapacity_() then
            Error('ALI992: too many concurrently live BigText variables (max %1)', MaxCapacity_());
        Bank.Add(NewBig);
        exit(Bank.Count());
    end;

    // Reclaim a handle — clears the bank instance IN PLACE (clearing a local copy would only
    // rebind the local, same reason as "ALI TextBuilder Runtime".FreeTb) and recycles the slot.
    procedure FreeBt(H: Integer)
    begin
        if (H < 1) or (H > Bank.Count()) then
            exit;
        ClearBt(H);
        FreeIdx.Add(H);
    end;

    procedure ClearBt(H: Integer)
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        Clear(BT);
        Bank.Set(H, BT);
    end;

    // ===== AddText =====

    procedure AddText(H: Integer; Value: Text)
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        BT.AddText(Value);
        Bank.Set(H, BT);
    end;

    procedure AddTextAt(H: Integer; Value: Text; Pos: Integer)
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        BT.AddText(Value, Pos);
        Bank.Set(H, BT);
    end;

    procedure AddBig(H: Integer; SrcH: Integer)
    var
        BT: BigText;
        Src: BigText;
    begin
        GetBig(H, BT);
        GetBig(SrcH, Src);
        BT.AddText(Src);
        Bank.Set(H, BT);
    end;

    procedure AddBigAt(H: Integer; SrcH: Integer; Pos: Integer)
    var
        BT: BigText;
        Src: BigText;
    begin
        GetBig(H, BT);
        GetBig(SrcH, Src);
        BT.AddText(Src, Pos);
        Bank.Set(H, BT);
    end;

    // ===== GetSubText =====
    // The native signature writes into a `var` target. The Text overloads return the value
    // instead (the lowerer stores it back into the caller's variable, the HttpContent.ReadAs
    // mechanism); the BigText overloads write straight into the destination bank slot.

    procedure GetSubTextToText(H: Integer; Pos: Integer): Text
    var
        BT: BigText;
        Res: Text;
    begin
        GetBig(H, BT);
        BT.GetSubText(Res, Pos);
        exit(Res);
    end;

    procedure GetSubTextToTextLen(H: Integer; Pos: Integer; Len: Integer): Text
    var
        BT: BigText;
        Res: Text;
    begin
        GetBig(H, BT);
        BT.GetSubText(Res, Pos, Len);
        exit(Res);
    end;

    procedure GetSubTextToBig(H: Integer; DestH: Integer; Pos: Integer)
    var
        BT: BigText;
        Dest: BigText;
    begin
        GetBig(H, BT);
        GetBig(DestH, Dest);
        BT.GetSubText(Dest, Pos);
        Bank.Set(DestH, Dest);
    end;

    procedure GetSubTextToBigLen(H: Integer; DestH: Integer; Pos: Integer; Len: Integer)
    var
        BT: BigText;
        Dest: BigText;
    begin
        GetBig(H, BT);
        GetBig(DestH, Dest);
        BT.GetSubText(Dest, Pos, Len);
        Bank.Set(DestH, Dest);
    end;

    // ===== Queries =====

    procedure GetLength(H: Integer): Integer
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        exit(BT.Length());
    end;

    procedure TextPos(H: Integer; Value: Text): Integer
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        exit(BT.TextPos(Value));
    end;

    // ===== Stream I/O =====
    // Called BY "ALI Stream Runtime" (which owns the native stream slots and cannot hand one
    // out — same delegation shape as its Xml entry points).

    procedure ReadFromStream(H: Integer; var Src: InStream)
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        BT.Read(Src);
        Bank.Set(H, BT);
    end;

    procedure WriteToStream(H: Integer; var Dest: OutStream)
    var
        BT: BigText;
    begin
        GetBig(H, BT);
        BT.Write(Dest);
    end;

    local procedure GetBig(H: Integer; var BT: BigText)
    begin
        if (H < 1) or (H > Bank.Count()) then
            Error('ALI993: BigText handle %1 out of range', H);
        Bank.Get(H, BT);
    end;
}
