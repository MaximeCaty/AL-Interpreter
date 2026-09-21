// ALI List Runtime — List of [T] RefShim execution (see ListDictionaryPlan.md §2).
//
// A List/Dict VALUE is an Int handle (RegClassInt) — see "ALI Type Rules".TList()/RegClassFor.
// This codeunit holds the actual backing storage: ONE bank PER register class (Integer,
// BigInteger, Decimal, Boolean, Text, Date, Time, DateTime, Duration, Guid). Each bank is a
// `List of [List of [T]]` (never a fixed array of [T]) — the same reference-aliasing
// concern documented in "ALI TextBuilder Runtime"'s header: a List element that is ITSELF a
// reference type only gets a genuinely distinct backing instance via `.Add()`.
//
// Handle encoding: handle = classIndex*HANDLE_STRIDE + bankIndex (bankIndex 1-based within
// that class's bank). classIndex IS the "ALI Type Rules" RegClass* ordinal (1..10) directly
// — no separate class-numbering scheme (ListDictionaryPlan.md §1/§3.3).
//
// Per-method dispatch: rather than ten separately-named method variants per operation (the
// plan's literal suggestion), each public method takes/returns a Variant and does ONE
// internal `case Cls of` to reach the correctly-typed inner List — the same
// Variant-at-the-call-boundary convention "ALI Interpreter".ReadRegisterAsVariant/
// WriteRegisterFromVariant already use. The BACKING STORE stays fully typed per class
// (the plan's actual concern — avoiding a `List of [Variant]` backing, whose Dictionary
// counterpart would have the wrong key hash/equality semantics); only the transient
// call-boundary value is boxed, exactly like every other builtin/method dispatch in this
// interpreter.
codeunit 51135 "ALI List Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        LiveCount: Integer;
        FreeIdxBig: List of [Integer];
        FreeIdxBool: List of [Integer];
        FreeIdxDate: List of [Integer];
        FreeIdxDec: List of [Integer];
        FreeIdxDT: List of [Integer];
        FreeIdxDur: List of [Integer];
        FreeIdxGuid: List of [Integer];
        // Handle Lifecycle Unification: per-class recycled bank indices (mirrors "ALI Array
        // Runtime".FreeIdx) — FreeList() pushes here instead of leaving the bank to grow
        // forever, so a recursive/looping script's live-collection count stays bounded by its
        // actual concurrent usage rather than its lifetime call count (fixes ALI972 at 4096).
        FreeIdxInt: List of [Integer];
        FreeIdxText: List of [Integer];
        FreeIdxTime: List of [Integer];
        BankBig: List of [List of [BigInteger]];
        BankBool: List of [List of [Boolean]];
        BankDate: List of [List of [Date]];
        BankDT: List of [List of [DateTime]];
        BankDec: List of [List of [Decimal]];
        BankDur: List of [List of [Duration]];
        BankGuid: List of [List of [Guid]];
        BankInt: List of [List of [Integer]];
        BankText: List of [List of [Text]];
        BankTime: List of [List of [Time]];
        // Scratch references for the per-call bank lookup (BankX.Get(Bank, InnerX)). Members, not
        // locals: a local List is a fresh object allocated on every call (10 per call); each use
        // rebinds the reference first. Allocating procedures (NewList/GetRange results) keep locals.
        InnerBig: List of [BigInteger];
        InnerBool: List of [Boolean];
        InnerDate: List of [Date];
        InnerDT: List of [DateTime];
        InnerDec: List of [Decimal];
        InnerDur: List of [Duration];
        InnerGuid: List of [Guid];
        InnerInt: List of [Integer];
        InnerText: List of [Text];
        InnerTime: List of [Time];

    procedure Reset()
    begin
        Clear(BankInt);
        Clear(BankBig);
        Clear(BankDec);
        Clear(BankBool);
        Clear(BankText);
        Clear(BankDate);
        Clear(BankTime);
        Clear(BankDT);
        Clear(BankDur);
        Clear(BankGuid);
        Clear(FreeIdxInt);
        Clear(FreeIdxBig);
        Clear(FreeIdxDec);
        Clear(FreeIdxBool);
        Clear(FreeIdxText);
        Clear(FreeIdxDate);
        Clear(FreeIdxTime);
        Clear(FreeIdxDT);
        Clear(FreeIdxDur);
        Clear(FreeIdxGuid);
        LiveCount := 0;
    end;

    // Handle encoding: handle = registerClass * 1000000 + bankIndex, so class = handle div
    // 1000000 and bank = handle mod 1000000. Those two decodes used to be Stride()/ClassOf()/
    // BankIdxOf() helpers, but they ran on EVERY list operation and an AL procedure call costs
    // ~450ns — roughly 10x the single div/mod it wrapped, and ClassOf/BankIdxOf each called
    // Stride() on top. They are spelled inline now (the interpreter's ExecListOp already
    // decoded handles this way, so the two sides read the same).

    // Handle Lifecycle Unification: LiveCount now tracks CONCURRENTLY live collections (every
    // FreeList() call decrements it), so this cap is a genuine live-set limit, not a lifetime
    // allocation counter — raised accordingly (was 4096, the ceiling a leaking bump-allocator
    // could actually hit; a bounded live set of even a few thousand per frame across 1024
    // frames warrants headroom).
    local procedure MaxLiveCollections(): Integer
    begin
        exit(65536);
    end;

    // Allocate (or reuse) an empty List of the given register class; returns the encoded
    // handle. Reused bank slots were already cleared by FreeList() at free time.
    procedure NewList(Cls: Integer): Integer
    var
        BankIdx: Integer;
        EmptyBig: List of [BigInteger];
        EmptyBool: List of [Boolean];
        EmptyDate: List of [Date];
        EmptyDT: List of [DateTime];
        EmptyDec: List of [Decimal];
        EmptyDur: List of [Duration];
        EmptyGuid: List of [Guid];
        EmptyInt: List of [Integer];
        EmptyText: List of [Text];
        EmptyTime: List of [Time];
    begin
        case Cls of
            1:
                if FreeIdxInt.Count() > 0 then begin
                    BankIdx := FreeIdxInt.Get(FreeIdxInt.Count());
                    FreeIdxInt.RemoveAt(FreeIdxInt.Count());
                end else begin
                    BankInt.Add(EmptyInt);
                    BankIdx := BankInt.Count();
                end;
            2:
                if FreeIdxBig.Count() > 0 then begin
                    BankIdx := FreeIdxBig.Get(FreeIdxBig.Count());
                    FreeIdxBig.RemoveAt(FreeIdxBig.Count());
                end else begin
                    BankBig.Add(EmptyBig);
                    BankIdx := BankBig.Count();
                end;
            3:
                if FreeIdxDec.Count() > 0 then begin
                    BankIdx := FreeIdxDec.Get(FreeIdxDec.Count());
                    FreeIdxDec.RemoveAt(FreeIdxDec.Count());
                end else begin
                    BankDec.Add(EmptyDec);
                    BankIdx := BankDec.Count();
                end;
            4:
                if FreeIdxBool.Count() > 0 then begin
                    BankIdx := FreeIdxBool.Get(FreeIdxBool.Count());
                    FreeIdxBool.RemoveAt(FreeIdxBool.Count());
                end else begin
                    BankBool.Add(EmptyBool);
                    BankIdx := BankBool.Count();
                end;
            5:
                if FreeIdxText.Count() > 0 then begin
                    BankIdx := FreeIdxText.Get(FreeIdxText.Count());
                    FreeIdxText.RemoveAt(FreeIdxText.Count());
                end else begin
                    BankText.Add(EmptyText);
                    BankIdx := BankText.Count();
                end;
            6:
                if FreeIdxDate.Count() > 0 then begin
                    BankIdx := FreeIdxDate.Get(FreeIdxDate.Count());
                    FreeIdxDate.RemoveAt(FreeIdxDate.Count());
                end else begin
                    BankDate.Add(EmptyDate);
                    BankIdx := BankDate.Count();
                end;
            7:
                if FreeIdxTime.Count() > 0 then begin
                    BankIdx := FreeIdxTime.Get(FreeIdxTime.Count());
                    FreeIdxTime.RemoveAt(FreeIdxTime.Count());
                end else begin
                    BankTime.Add(EmptyTime);
                    BankIdx := BankTime.Count();
                end;
            8:
                if FreeIdxDT.Count() > 0 then begin
                    BankIdx := FreeIdxDT.Get(FreeIdxDT.Count());
                    FreeIdxDT.RemoveAt(FreeIdxDT.Count());
                end else begin
                    BankDT.Add(EmptyDT);
                    BankIdx := BankDT.Count();
                end;
            9:
                if FreeIdxDur.Count() > 0 then begin
                    BankIdx := FreeIdxDur.Get(FreeIdxDur.Count());
                    FreeIdxDur.RemoveAt(FreeIdxDur.Count());
                end else begin
                    BankDur.Add(EmptyDur);
                    BankIdx := BankDur.Count();
                end;
            10:
                if FreeIdxGuid.Count() > 0 then begin
                    BankIdx := FreeIdxGuid.Get(FreeIdxGuid.Count());
                    FreeIdxGuid.RemoveAt(FreeIdxGuid.Count());
                end else begin
                    BankGuid.Add(EmptyGuid);
                    BankIdx := BankGuid.Count();
                end;
            else
                Error('ALI973: invalid List element class %1', Cls);
        end;
        LiveCount += 1;
        if LiveCount > MaxLiveCollections() then
            Error('ALI972: too many List/Dictionary collections (max %1)', MaxLiveCollections());
        exit(Cls * 1000000 + BankIdx);
    end;

    // Handle Lifecycle Unification: reclaim a List handle — empties the bank slot in place
    // (same aliasing reason as ClearList: Clear() on a local var would only rebind the local
    // reference, not the shared bank instance) and pushes the slot onto the free-list for
    // NewList() to reuse. Out-of-range handles are ignored (defensive — mirrors "ALI Http
    // Runtime"'s FreeXxx guard style; a handle can only ever be freed once through the
    // interpreter's frame-scoped alloc stack, so double-free is not an expected path).
    procedure FreeList(Handle: Integer)
    var
        Bank: Integer;
        EmptyBig: List of [BigInteger];
        EmptyBool: List of [Boolean];
        EmptyDate: List of [Date];
        EmptyDT: List of [DateTime];
        EmptyDec: List of [Decimal];
        EmptyDur: List of [Duration];
        EmptyGuid: List of [Guid];
        EmptyInt: List of [Integer];
        EmptyText: List of [Text];
        EmptyTime: List of [Time];
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    if (Bank < 1) or (Bank > BankInt.Count()) then
                        exit;
                    BankInt.Set(Bank, EmptyInt);
                    FreeIdxInt.Add(Bank);
                end;
            2:
                begin
                    if (Bank < 1) or (Bank > BankBig.Count()) then
                        exit;
                    BankBig.Set(Bank, EmptyBig);
                    FreeIdxBig.Add(Bank);
                end;
            3:
                begin
                    if (Bank < 1) or (Bank > BankDec.Count()) then
                        exit;
                    BankDec.Set(Bank, EmptyDec);
                    FreeIdxDec.Add(Bank);
                end;
            4:
                begin
                    if (Bank < 1) or (Bank > BankBool.Count()) then
                        exit;
                    BankBool.Set(Bank, EmptyBool);
                    FreeIdxBool.Add(Bank);
                end;
            5:
                begin
                    if (Bank < 1) or (Bank > BankText.Count()) then
                        exit;
                    BankText.Set(Bank, EmptyText);
                    FreeIdxText.Add(Bank);
                end;
            6:
                begin
                    if (Bank < 1) or (Bank > BankDate.Count()) then
                        exit;
                    BankDate.Set(Bank, EmptyDate);
                    FreeIdxDate.Add(Bank);
                end;
            7:
                begin
                    if (Bank < 1) or (Bank > BankTime.Count()) then
                        exit;
                    BankTime.Set(Bank, EmptyTime);
                    FreeIdxTime.Add(Bank);
                end;
            8:
                begin
                    if (Bank < 1) or (Bank > BankDT.Count()) then
                        exit;
                    BankDT.Set(Bank, EmptyDT);
                    FreeIdxDT.Add(Bank);
                end;
            9:
                begin
                    if (Bank < 1) or (Bank > BankDur.Count()) then
                        exit;
                    BankDur.Set(Bank, EmptyDur);
                    FreeIdxDur.Add(Bank);
                end;
            10:
                begin
                    if (Bank < 1) or (Bank > BankGuid.Count()) then
                        exit;
                    BankGuid.Set(Bank, EmptyGuid);
                    FreeIdxGuid.Add(Bank);
                end;
            else
                exit;
        end;
        if LiveCount > 0 then
            LiveCount -= 1;
    end;

    local procedure CheckIndex(Index: Integer; Count: Integer)
    begin
        if (Index < 1) or (Index > Count) then
            Error('ALI973: List index %1 out of range (Count = %2)', Index, Count);
    end;

    procedure Count(Handle: Integer): Integer
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    exit(InnerInt.Count());
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    exit(InnerBig.Count());
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    exit(InnerDec.Count());
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    exit(InnerBool.Count());
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    exit(InnerText.Count());
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    exit(InnerDate.Count());
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    exit(InnerTime.Count());
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    exit(InnerDT.Count());
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    exit(InnerDur.Count());
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    exit(InnerGuid.Count());
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure Add(Handle: Integer; V: Variant)
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    InnerInt.Add(V);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    InnerBig.Add(V);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    InnerDec.Add(V);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    InnerBool.Add(V);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    InnerText.Add(V);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    InnerDate.Add(V);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    InnerTime.Add(V);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    InnerDT.Add(V);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    InnerDur.Add(V);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    InnerGuid.Add(V);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    // Typed Get for the Int element class. The generic Get() below declares 20 locals (10
    // List of [T] banks + 10 value types) and returns a Variant the caller must then unbox —
    // this one has 2 locals and no boxing at all. Same reason the interpreter calls it
    // directly from the LIST_GET arm: the cost on that path is the prologue and the Variant
    // round-trip, not the dispatch.
    procedure GetInt(Handle: Integer; Index: Integer): Integer
    var
        Val: Integer;
    begin
        BankInt.Get(Handle mod 1000000, InnerInt);
        if (Index < 1) or (Index > InnerInt.Count()) then
            Error('ALI973: List index %1 out of range (Count = %2)', Index, InnerInt.Count());
        InnerInt.Get(Index, Val);
        exit(Val);
    end;

    procedure Get(Handle: Integer; Index: Integer): Variant
    var
        ValBig: BigInteger;
        ValBool: Boolean;
        ValDate: Date;
        ValDT: DateTime;
        ValDec: Decimal;
        ValDur: Duration;
        ValGuid: Guid;
        Bank: Integer;
        ValInt: Integer;
        ValText: Text;
        ValTime: Time;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    CheckIndex(Index, InnerInt.Count());
                    InnerInt.Get(Index, ValInt);
                    exit(ValInt);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    CheckIndex(Index, InnerBig.Count());
                    InnerBig.Get(Index, ValBig);
                    exit(ValBig);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    CheckIndex(Index, InnerDec.Count());
                    InnerDec.Get(Index, ValDec);
                    exit(ValDec);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    CheckIndex(Index, InnerBool.Count());
                    InnerBool.Get(Index, ValBool);
                    exit(ValBool);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    CheckIndex(Index, InnerText.Count());
                    InnerText.Get(Index, ValText);
                    exit(ValText);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    CheckIndex(Index, InnerDate.Count());
                    InnerDate.Get(Index, ValDate);
                    exit(ValDate);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    CheckIndex(Index, InnerTime.Count());
                    InnerTime.Get(Index, ValTime);
                    exit(ValTime);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    CheckIndex(Index, InnerDT.Count());
                    InnerDT.Get(Index, ValDT);
                    exit(ValDT);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    CheckIndex(Index, InnerDur.Count());
                    InnerDur.Get(Index, ValDur);
                    exit(ValDur);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    CheckIndex(Index, InnerGuid.Count());
                    InnerGuid.Get(Index, ValGuid);
                    exit(ValGuid);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    // Set(index, value) -> old value (native List.Set semantics).
    procedure SetAt(Handle: Integer; Index: Integer; V: Variant): Variant
    var
        OldBig: BigInteger;
        OldBool: Boolean;
        OldDate: Date;
        OldDT: DateTime;
        OldDec: Decimal;
        OldDur: Duration;
        OldGuid: Guid;
        Bank: Integer;
        OldInt: Integer;
        OldText: Text;
        OldTime: Time;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    CheckIndex(Index, InnerInt.Count());
                    InnerInt.Get(Index, OldInt);
                    InnerInt.Set(Index, V);
                    exit(OldInt);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    CheckIndex(Index, InnerBig.Count());
                    InnerBig.Get(Index, OldBig);
                    InnerBig.Set(Index, V);
                    exit(OldBig);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    CheckIndex(Index, InnerDec.Count());
                    InnerDec.Get(Index, OldDec);
                    InnerDec.Set(Index, V);
                    exit(OldDec);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    CheckIndex(Index, InnerBool.Count());
                    InnerBool.Get(Index, OldBool);
                    InnerBool.Set(Index, V);
                    exit(OldBool);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    CheckIndex(Index, InnerText.Count());
                    InnerText.Get(Index, OldText);
                    InnerText.Set(Index, V);
                    exit(OldText);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    CheckIndex(Index, InnerDate.Count());
                    InnerDate.Get(Index, OldDate);
                    InnerDate.Set(Index, V);
                    exit(OldDate);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    CheckIndex(Index, InnerTime.Count());
                    InnerTime.Get(Index, OldTime);
                    InnerTime.Set(Index, V);
                    exit(OldTime);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    CheckIndex(Index, InnerDT.Count());
                    InnerDT.Get(Index, OldDT);
                    InnerDT.Set(Index, V);
                    exit(OldDT);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    CheckIndex(Index, InnerDur.Count());
                    InnerDur.Get(Index, OldDur);
                    InnerDur.Set(Index, V);
                    exit(OldDur);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    CheckIndex(Index, InnerGuid.Count());
                    InnerGuid.Get(Index, OldGuid);
                    InnerGuid.Set(Index, V);
                    exit(OldGuid);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure Contains(Handle: Integer; V: Variant): Boolean
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    exit(InnerInt.Contains(V));
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    exit(InnerBig.Contains(V));
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    exit(InnerDec.Contains(V));
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    exit(InnerBool.Contains(V));
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    exit(InnerText.Contains(V));
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    exit(InnerDate.Contains(V));
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    exit(InnerTime.Contains(V));
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    exit(InnerDT.Contains(V));
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    exit(InnerDur.Contains(V));
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    exit(InnerGuid.Contains(V));
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure IndexOf(Handle: Integer; V: Variant): Integer
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    exit(InnerInt.IndexOf(V));
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    exit(InnerBig.IndexOf(V));
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    exit(InnerDec.IndexOf(V));
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    exit(InnerBool.IndexOf(V));
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    exit(InnerText.IndexOf(V));
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    exit(InnerDate.IndexOf(V));
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    exit(InnerTime.IndexOf(V));
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    exit(InnerDT.IndexOf(V));
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    exit(InnerDur.IndexOf(V));
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    exit(InnerGuid.IndexOf(V));
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure Remove(Handle: Integer; V: Variant): Boolean
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    exit(InnerInt.Remove(V));
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    exit(InnerBig.Remove(V));
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    exit(InnerDec.Remove(V));
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    exit(InnerBool.Remove(V));
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    exit(InnerText.Remove(V));
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    exit(InnerDate.Remove(V));
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    exit(InnerTime.Remove(V));
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    exit(InnerDT.Remove(V));
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    exit(InnerDur.Remove(V));
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    exit(InnerGuid.Remove(V));
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure RemoveAt(Handle: Integer; Index: Integer)
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    CheckIndex(Index, InnerInt.Count());
                    InnerInt.RemoveAt(Index);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    CheckIndex(Index, InnerBig.Count());
                    InnerBig.RemoveAt(Index);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    CheckIndex(Index, InnerDec.Count());
                    InnerDec.RemoveAt(Index);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    CheckIndex(Index, InnerBool.Count());
                    InnerBool.RemoveAt(Index);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    CheckIndex(Index, InnerText.Count());
                    InnerText.RemoveAt(Index);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    CheckIndex(Index, InnerDate.Count());
                    InnerDate.RemoveAt(Index);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    CheckIndex(Index, InnerTime.Count());
                    InnerTime.RemoveAt(Index);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    CheckIndex(Index, InnerDT.Count());
                    InnerDT.RemoveAt(Index);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    CheckIndex(Index, InnerDur.Count());
                    InnerDur.RemoveAt(Index);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    CheckIndex(Index, InnerGuid.Count());
                    InnerGuid.RemoveAt(Index);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure RemoveRange(Handle: Integer; Index: Integer; Count: Integer)
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    InnerInt.RemoveRange(Index, Count);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    InnerBig.RemoveRange(Index, Count);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    InnerDec.RemoveRange(Index, Count);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    InnerBool.RemoveRange(Index, Count);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    InnerText.RemoveRange(Index, Count);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    InnerDate.RemoveRange(Index, Count);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    InnerTime.RemoveRange(Index, Count);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    InnerDT.RemoveRange(Index, Count);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    InnerDur.RemoveRange(Index, Count);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    InnerGuid.RemoveRange(Index, Count);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure Insert(Handle: Integer; Index: Integer; V: Variant)
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    InnerInt.Insert(Index, V);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    InnerBig.Insert(Index, V);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    InnerDec.Insert(Index, V);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    InnerBool.Insert(Index, V);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    InnerText.Insert(Index, V);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    InnerDate.Insert(Index, V);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    InnerTime.Insert(Index, V);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    InnerDT.Insert(Index, V);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    InnerDur.Insert(Index, V);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    InnerGuid.Insert(Index, V);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    procedure Reverse(Handle: Integer)
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    InnerInt.Reverse();
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    InnerBig.Reverse();
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    InnerDec.Reverse();
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    InnerBool.Reverse();
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    InnerText.Reverse();
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    InnerDate.Reverse();
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    InnerTime.Reverse();
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    InnerDT.Reverse();
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    InnerDur.Reverse();
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    InnerGuid.Reverse();
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    // Clear(List): empties the list in place (Count -> 0), handle stays valid. Replaces the
    // bank slot with a fresh empty inner list — Clear() on the local Inner var would only
    // rebind the local reference, not the shared object in the bank (see file header).
    procedure ClearList(Handle: Integer)
    var
        Bank: Integer;
        EmptyBig: List of [BigInteger];
        EmptyBool: List of [Boolean];
        EmptyDate: List of [Date];
        EmptyDT: List of [DateTime];
        EmptyDec: List of [Decimal];
        EmptyDur: List of [Duration];
        EmptyGuid: List of [Guid];
        EmptyInt: List of [Integer];
        EmptyText: List of [Text];
        EmptyTime: List of [Time];
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            1:
                BankInt.Set(Bank, EmptyInt);
            2:
                BankBig.Set(Bank, EmptyBig);
            3:
                BankDec.Set(Bank, EmptyDec);
            4:
                BankBool.Set(Bank, EmptyBool);
            5:
                BankText.Set(Bank, EmptyText);
            6:
                BankDate.Set(Bank, EmptyDate);
            7:
                BankTime.Set(Bank, EmptyTime);
            8:
                BankDT.Set(Bank, EmptyDT);
            9:
                BankDur.Set(Bank, EmptyDur);
            10:
                BankGuid.Set(Bank, EmptyGuid);
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
    end;

    // AddRange(SrcHandle): both handles must share the same class — the binder already
    // enforced this (ListDictionaryPlan.md §6), so a class mismatch here is an interpreter
    // bug, not a script error.
    procedure AddRange(DestHandle: Integer; SrcHandle: Integer)
    var
        DestBank: Integer;
        SrcBank: Integer;
        DestBig: List of [BigInteger];
        SrcBig: List of [BigInteger];
        DestBool: List of [Boolean];
        SrcBool: List of [Boolean];
        DestDate: List of [Date];
        SrcDate: List of [Date];
        DestDT: List of [DateTime];
        SrcDT: List of [DateTime];
        DestDec: List of [Decimal];
        SrcDec: List of [Decimal];
        DestDur: List of [Duration];
        SrcDur: List of [Duration];
        DestGuid: List of [Guid];
        SrcGuid: List of [Guid];
        DestInt: List of [Integer];
        SrcInt: List of [Integer];
        DestText: List of [Text];
        SrcText: List of [Text];
        DestTime: List of [Time];
        SrcTime: List of [Time];
    begin
        if (DestHandle div 1000000) <> (SrcHandle div 1000000) then
            Error('ALI973: AddRange requires two Lists of the same element class');
        DestBank := (DestHandle mod 1000000);
        SrcBank := (SrcHandle mod 1000000);
        case (DestHandle div 1000000) of
            1:
                begin
                    BankInt.Get(DestBank, DestInt);
                    BankInt.Get(SrcBank, SrcInt);
                    DestInt.AddRange(SrcInt);
                end;
            2:
                begin
                    BankBig.Get(DestBank, DestBig);
                    BankBig.Get(SrcBank, SrcBig);
                    DestBig.AddRange(SrcBig);
                end;
            3:
                begin
                    BankDec.Get(DestBank, DestDec);
                    BankDec.Get(SrcBank, SrcDec);
                    DestDec.AddRange(SrcDec);
                end;
            4:
                begin
                    BankBool.Get(DestBank, DestBool);
                    BankBool.Get(SrcBank, SrcBool);
                    DestBool.AddRange(SrcBool);
                end;
            5:
                begin
                    BankText.Get(DestBank, DestText);
                    BankText.Get(SrcBank, SrcText);
                    DestText.AddRange(SrcText);
                end;
            6:
                begin
                    BankDate.Get(DestBank, DestDate);
                    BankDate.Get(SrcBank, SrcDate);
                    DestDate.AddRange(SrcDate);
                end;
            7:
                begin
                    BankTime.Get(DestBank, DestTime);
                    BankTime.Get(SrcBank, SrcTime);
                    DestTime.AddRange(SrcTime);
                end;
            8:
                begin
                    BankDT.Get(DestBank, DestDT);
                    BankDT.Get(SrcBank, SrcDT);
                    DestDT.AddRange(SrcDT);
                end;
            9:
                begin
                    BankDur.Get(DestBank, DestDur);
                    BankDur.Get(SrcBank, SrcDur);
                    DestDur.AddRange(SrcDur);
                end;
            10:
                begin
                    BankGuid.Get(DestBank, DestGuid);
                    BankGuid.Get(SrcBank, SrcGuid);
                    DestGuid.AddRange(SrcGuid);
                end;
            else
                Error('ALI973: invalid List handle %1', DestHandle);
        end;
    end;

    // GetRange(index, count) -> a FRESH List handle of the same element class.
    procedure GetRange(Handle: Integer; Index: Integer; Count: Integer): Integer
    var
        Bank: Integer;
        Cls: Integer;
        NewHandle: Integer;
        RangeBig: List of [BigInteger];
        RangeBool: List of [Boolean];
        RangeDate: List of [Date];
        RangeDT: List of [DateTime];
        RangeDec: List of [Decimal];
        RangeDur: List of [Duration];
        RangeGuid: List of [Guid];
        RangeInt: List of [Integer];
        RangeText: List of [Text];
        RangeTime: List of [Time];
    begin
        Bank := (Handle mod 1000000);
        Cls := (Handle div 1000000);
        NewHandle := NewList(Cls);
        case Cls of
            1:
                begin
                    BankInt.Get(Bank, InnerInt);
                    RangeInt := InnerInt.GetRange(Index, Count);
                    BankInt.Set((NewHandle mod 1000000), RangeInt);
                end;
            2:
                begin
                    BankBig.Get(Bank, InnerBig);
                    RangeBig := InnerBig.GetRange(Index, Count);
                    BankBig.Set((NewHandle mod 1000000), RangeBig);
                end;
            3:
                begin
                    BankDec.Get(Bank, InnerDec);
                    RangeDec := InnerDec.GetRange(Index, Count);
                    BankDec.Set((NewHandle mod 1000000), RangeDec);
                end;
            4:
                begin
                    BankBool.Get(Bank, InnerBool);
                    RangeBool := InnerBool.GetRange(Index, Count);
                    BankBool.Set((NewHandle mod 1000000), RangeBool);
                end;
            5:
                begin
                    BankText.Get(Bank, InnerText);
                    RangeText := InnerText.GetRange(Index, Count);
                    BankText.Set((NewHandle mod 1000000), RangeText);
                end;
            6:
                begin
                    BankDate.Get(Bank, InnerDate);
                    RangeDate := InnerDate.GetRange(Index, Count);
                    BankDate.Set((NewHandle mod 1000000), RangeDate);
                end;
            7:
                begin
                    BankTime.Get(Bank, InnerTime);
                    RangeTime := InnerTime.GetRange(Index, Count);
                    BankTime.Set((NewHandle mod 1000000), RangeTime);
                end;
            8:
                begin
                    BankDT.Get(Bank, InnerDT);
                    RangeDT := InnerDT.GetRange(Index, Count);
                    BankDT.Set((NewHandle mod 1000000), RangeDT);
                end;
            9:
                begin
                    BankDur.Get(Bank, InnerDur);
                    RangeDur := InnerDur.GetRange(Index, Count);
                    BankDur.Set((NewHandle mod 1000000), RangeDur);
                end;
            10:
                begin
                    BankGuid.Get(Bank, InnerGuid);
                    RangeGuid := InnerGuid.GetRange(Index, Count);
                    BankGuid.Set((NewHandle mod 1000000), RangeGuid);
                end;
            else
                Error('ALI973: invalid List handle %1', Handle);
        end;
        exit(NewHandle);
    end;
}
