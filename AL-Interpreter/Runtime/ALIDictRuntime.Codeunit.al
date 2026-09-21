// ALI Dict Runtime — Dictionary of [K, V] RefShim execution (see ListDictionaryPlan.md §2).
//
// Same shape as "ALI List Runtime", one level deeper: a bank is keyed by the (keyClass,
// valueClass) PAIR. Keys are restricted to Integer class (1) or Text class (5)
// (ListDictionaryPlan.md §3.1); values allow all ten register classes -> 20 banks. Each
// bank is a `List of [Dictionary of [K, V]]` (NOT a bare `Dictionary of [K, V]` var) for the
// same reason "ALI List Runtime"'s banks are `List of [List of [T]]` — Dictionary is a
// reference type, so a single shared var would alias every Dictionary of that (K,V) pair
// declared in the script; `.Add()` forces a genuinely distinct backing instance per handle.
//
// Handle encoding: handle = (keyClass*16 + valueClass)*HANDLE_STRIDE + bankIndex.
// keyClass/valueClass ARE "ALI Type Rules" RegClass* ordinals (1..10) directly.
codeunit 51136 "ALI Dict Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        ListRt: Codeunit "ALI List Runtime";
        LiveCount: Integer;
        DctI_Big: List of [Dictionary of [Integer, BigInteger]];
        DctI_Bool: List of [Dictionary of [Integer, Boolean]];
        DctI_Date: List of [Dictionary of [Integer, Date]];
        DctI_DT: List of [Dictionary of [Integer, DateTime]];
        DctI_Dec: List of [Dictionary of [Integer, Decimal]];
        DctI_Dur: List of [Dictionary of [Integer, Duration]];
        DctI_Guid: List of [Dictionary of [Integer, Guid]];
        DctI_Int: List of [Dictionary of [Integer, Integer]];
        DctI_Text: List of [Dictionary of [Integer, Text]];
        DctI_Time: List of [Dictionary of [Integer, Time]];
        DctT_Big: List of [Dictionary of [Text, BigInteger]];
        DctT_Bool: List of [Dictionary of [Text, Boolean]];
        DctT_Date: List of [Dictionary of [Text, Date]];
        DctT_DT: List of [Dictionary of [Text, DateTime]];
        DctT_Dec: List of [Dictionary of [Text, Decimal]];
        DctT_Dur: List of [Dictionary of [Text, Duration]];
        DctT_Guid: List of [Dictionary of [Text, Guid]];
        DctT_Int: List of [Dictionary of [Text, Integer]];
        DctT_Text: List of [Dictionary of [Text, Text]];
        DctT_Time: List of [Dictionary of [Text, Time]];
        FreeI_Big: List of [Integer];
        FreeI_Bool: List of [Integer];
        FreeI_Date: List of [Integer];
        FreeI_Dec: List of [Integer];
        FreeI_DT: List of [Integer];
        FreeI_Dur: List of [Integer];
        FreeI_Guid: List of [Integer];
        // Handle Lifecycle Unification: per-(keyClass,valueClass) recycled bank indices —
        // mirrors "ALI List Runtime".FreeIdx*; fixes the same ALI972-at-4096 leak for
        // Dictionary (NewDict never freed a bank slot before).
        FreeI_Int: List of [Integer];
        FreeI_Text: List of [Integer];
        FreeI_Time: List of [Integer];
        FreeT_Big: List of [Integer];
        FreeT_Bool: List of [Integer];
        FreeT_Date: List of [Integer];
        FreeT_Dec: List of [Integer];
        FreeT_DT: List of [Integer];
        FreeT_Dur: List of [Integer];
        FreeT_Guid: List of [Integer];
        FreeT_Int: List of [Integer];
        FreeT_Text: List of [Integer];
        FreeT_Time: List of [Integer];
        // Scratch references for the per-call bank lookup (DctX.Get(Bank, D..)) of Add/SetKV/Get/
        // ContainsKey/TryGet/Remove/Count/Keys/Values. Members, not locals: a local Dictionary is a
        // fresh object allocated on every call (20 per call here); each use rebinds the reference first.
        DIBig: Dictionary of [Integer, BigInteger];
        DIBool: Dictionary of [Integer, Boolean];
        DIDate: Dictionary of [Integer, Date];
        DIDT: Dictionary of [Integer, DateTime];
        DIDec: Dictionary of [Integer, Decimal];
        DIDur: Dictionary of [Integer, Duration];
        DIGuid: Dictionary of [Integer, Guid];
        DII: Dictionary of [Integer, Integer];
        DIText: Dictionary of [Integer, Text];
        DITime: Dictionary of [Integer, Time];
        DTBig: Dictionary of [Text, BigInteger];
        DTBool: Dictionary of [Text, Boolean];
        DTDate: Dictionary of [Text, Date];
        DTDT: Dictionary of [Text, DateTime];
        DTDec: Dictionary of [Text, Decimal];
        DTDur: Dictionary of [Text, Duration];
        DTGuid: Dictionary of [Text, Guid];
        DTI: Dictionary of [Text, Integer];
        DTText: Dictionary of [Text, Text];
        DTTime: Dictionary of [Text, Time];

    procedure Reset()
    begin
        Clear(DctI_Int);
        Clear(DctI_Big);
        Clear(DctI_Dec);
        Clear(DctI_Bool);
        Clear(DctI_Text);
        Clear(DctI_Date);
        Clear(DctI_Time);
        Clear(DctI_DT);
        Clear(DctI_Dur);
        Clear(DctI_Guid);
        Clear(DctT_Int);
        Clear(DctT_Big);
        Clear(DctT_Dec);
        Clear(DctT_Bool);
        Clear(DctT_Text);
        Clear(DctT_Date);
        Clear(DctT_Time);
        Clear(DctT_DT);
        Clear(DctT_Dur);
        Clear(DctT_Guid);
        Clear(FreeI_Int);
        Clear(FreeI_Big);
        Clear(FreeI_Dec);
        Clear(FreeI_Bool);
        Clear(FreeI_Text);
        Clear(FreeI_Date);
        Clear(FreeI_Time);
        Clear(FreeI_DT);
        Clear(FreeI_Dur);
        Clear(FreeI_Guid);
        Clear(FreeT_Int);
        Clear(FreeT_Big);
        Clear(FreeT_Dec);
        Clear(FreeT_Bool);
        Clear(FreeT_Text);
        Clear(FreeT_Date);
        Clear(FreeT_Time);
        Clear(FreeT_DT);
        Clear(FreeT_Dur);
        Clear(FreeT_Guid);
        LiveCount := 0;
    end;

    // Handle encoding: handle = (keyClass * 16 + valueClass) * 1000000 + bankIndex, so the
    // packed key/value pair is handle div 1000000 and the bank is handle mod 1000000. Those
    // decodes used to be Stride()/PackedKV()/BankIdxOf() helpers; they ran on EVERY dictionary
    // operation and an AL procedure call costs ~450ns — roughly 10x the single div/mod it
    // wrapped, and PackedKV/BankIdxOf each called Stride() on top. Spelled inline now.

    // Handle Lifecycle Unification: see "ALI List Runtime".MaxLiveCollections — same
    // reasoning, now a genuine concurrent-live-set cap since FreeDict() decrements LiveCount.
    local procedure MaxLiveCollections(): Integer
    begin
        exit(65536);
    end;

    // Fresh empty Dictionary of the given key/value register classes; returns the handle.
    procedure NewDict(KeyCls: Integer; ValCls: Integer): Integer
    var
        EmptyIBig: Dictionary of [Integer, BigInteger];
        EmptyIBool: Dictionary of [Integer, Boolean];
        EmptyIDate: Dictionary of [Integer, Date];
        EmptyIDT: Dictionary of [Integer, DateTime];
        EmptyIDec: Dictionary of [Integer, Decimal];
        EmptyIDur: Dictionary of [Integer, Duration];
        EmptyIGuid: Dictionary of [Integer, Guid];
        EmptyII: Dictionary of [Integer, Integer];
        EmptyIText: Dictionary of [Integer, Text];
        EmptyITime: Dictionary of [Integer, Time];
        EmptyTBig: Dictionary of [Text, BigInteger];
        EmptyTBool: Dictionary of [Text, Boolean];
        EmptyTDate: Dictionary of [Text, Date];
        EmptyTDT: Dictionary of [Text, DateTime];
        EmptyTDec: Dictionary of [Text, Decimal];
        EmptyTDur: Dictionary of [Text, Duration];
        EmptyTGuid: Dictionary of [Text, Guid];
        EmptyTI: Dictionary of [Text, Integer];
        EmptyTText: Dictionary of [Text, Text];
        EmptyTTime: Dictionary of [Text, Time];
        BankIdx: Integer;
    begin
        case KeyCls * 16 + ValCls of
            17:
                if FreeI_Int.Count() > 0 then begin
                    BankIdx := FreeI_Int.Get(FreeI_Int.Count());
                    FreeI_Int.RemoveAt(FreeI_Int.Count());
                end else begin
                    DctI_Int.Add(EmptyII);
                    BankIdx := DctI_Int.Count();
                end;
            18:
                if FreeI_Big.Count() > 0 then begin
                    BankIdx := FreeI_Big.Get(FreeI_Big.Count());
                    FreeI_Big.RemoveAt(FreeI_Big.Count());
                end else begin
                    DctI_Big.Add(EmptyIBig);
                    BankIdx := DctI_Big.Count();
                end;
            19:
                if FreeI_Dec.Count() > 0 then begin
                    BankIdx := FreeI_Dec.Get(FreeI_Dec.Count());
                    FreeI_Dec.RemoveAt(FreeI_Dec.Count());
                end else begin
                    DctI_Dec.Add(EmptyIDec);
                    BankIdx := DctI_Dec.Count();
                end;
            20:
                if FreeI_Bool.Count() > 0 then begin
                    BankIdx := FreeI_Bool.Get(FreeI_Bool.Count());
                    FreeI_Bool.RemoveAt(FreeI_Bool.Count());
                end else begin
                    DctI_Bool.Add(EmptyIBool);
                    BankIdx := DctI_Bool.Count();
                end;
            21:
                if FreeI_Text.Count() > 0 then begin
                    BankIdx := FreeI_Text.Get(FreeI_Text.Count());
                    FreeI_Text.RemoveAt(FreeI_Text.Count());
                end else begin
                    DctI_Text.Add(EmptyIText);
                    BankIdx := DctI_Text.Count();
                end;
            22:
                if FreeI_Date.Count() > 0 then begin
                    BankIdx := FreeI_Date.Get(FreeI_Date.Count());
                    FreeI_Date.RemoveAt(FreeI_Date.Count());
                end else begin
                    DctI_Date.Add(EmptyIDate);
                    BankIdx := DctI_Date.Count();
                end;
            23:
                if FreeI_Time.Count() > 0 then begin
                    BankIdx := FreeI_Time.Get(FreeI_Time.Count());
                    FreeI_Time.RemoveAt(FreeI_Time.Count());
                end else begin
                    DctI_Time.Add(EmptyITime);
                    BankIdx := DctI_Time.Count();
                end;
            24:
                if FreeI_DT.Count() > 0 then begin
                    BankIdx := FreeI_DT.Get(FreeI_DT.Count());
                    FreeI_DT.RemoveAt(FreeI_DT.Count());
                end else begin
                    DctI_DT.Add(EmptyIDT);
                    BankIdx := DctI_DT.Count();
                end;
            25:
                if FreeI_Dur.Count() > 0 then begin
                    BankIdx := FreeI_Dur.Get(FreeI_Dur.Count());
                    FreeI_Dur.RemoveAt(FreeI_Dur.Count());
                end else begin
                    DctI_Dur.Add(EmptyIDur);
                    BankIdx := DctI_Dur.Count();
                end;
            26:
                if FreeI_Guid.Count() > 0 then begin
                    BankIdx := FreeI_Guid.Get(FreeI_Guid.Count());
                    FreeI_Guid.RemoveAt(FreeI_Guid.Count());
                end else begin
                    DctI_Guid.Add(EmptyIGuid);
                    BankIdx := DctI_Guid.Count();
                end;
            81:
                if FreeT_Int.Count() > 0 then begin
                    BankIdx := FreeT_Int.Get(FreeT_Int.Count());
                    FreeT_Int.RemoveAt(FreeT_Int.Count());
                end else begin
                    DctT_Int.Add(EmptyTI);
                    BankIdx := DctT_Int.Count();
                end;
            82:
                if FreeT_Big.Count() > 0 then begin
                    BankIdx := FreeT_Big.Get(FreeT_Big.Count());
                    FreeT_Big.RemoveAt(FreeT_Big.Count());
                end else begin
                    DctT_Big.Add(EmptyTBig);
                    BankIdx := DctT_Big.Count();
                end;
            83:
                if FreeT_Dec.Count() > 0 then begin
                    BankIdx := FreeT_Dec.Get(FreeT_Dec.Count());
                    FreeT_Dec.RemoveAt(FreeT_Dec.Count());
                end else begin
                    DctT_Dec.Add(EmptyTDec);
                    BankIdx := DctT_Dec.Count();
                end;
            84:
                if FreeT_Bool.Count() > 0 then begin
                    BankIdx := FreeT_Bool.Get(FreeT_Bool.Count());
                    FreeT_Bool.RemoveAt(FreeT_Bool.Count());
                end else begin
                    DctT_Bool.Add(EmptyTBool);
                    BankIdx := DctT_Bool.Count();
                end;
            85:
                if FreeT_Text.Count() > 0 then begin
                    BankIdx := FreeT_Text.Get(FreeT_Text.Count());
                    FreeT_Text.RemoveAt(FreeT_Text.Count());
                end else begin
                    DctT_Text.Add(EmptyTText);
                    BankIdx := DctT_Text.Count();
                end;
            86:
                if FreeT_Date.Count() > 0 then begin
                    BankIdx := FreeT_Date.Get(FreeT_Date.Count());
                    FreeT_Date.RemoveAt(FreeT_Date.Count());
                end else begin
                    DctT_Date.Add(EmptyTDate);
                    BankIdx := DctT_Date.Count();
                end;
            87:
                if FreeT_Time.Count() > 0 then begin
                    BankIdx := FreeT_Time.Get(FreeT_Time.Count());
                    FreeT_Time.RemoveAt(FreeT_Time.Count());
                end else begin
                    DctT_Time.Add(EmptyTTime);
                    BankIdx := DctT_Time.Count();
                end;
            88:
                if FreeT_DT.Count() > 0 then begin
                    BankIdx := FreeT_DT.Get(FreeT_DT.Count());
                    FreeT_DT.RemoveAt(FreeT_DT.Count());
                end else begin
                    DctT_DT.Add(EmptyTDT);
                    BankIdx := DctT_DT.Count();
                end;
            89:
                if FreeT_Dur.Count() > 0 then begin
                    BankIdx := FreeT_Dur.Get(FreeT_Dur.Count());
                    FreeT_Dur.RemoveAt(FreeT_Dur.Count());
                end else begin
                    DctT_Dur.Add(EmptyTDur);
                    BankIdx := DctT_Dur.Count();
                end;
            90:
                if FreeT_Guid.Count() > 0 then begin
                    BankIdx := FreeT_Guid.Get(FreeT_Guid.Count());
                    FreeT_Guid.RemoveAt(FreeT_Guid.Count());
                end else begin
                    DctT_Guid.Add(EmptyTGuid);
                    BankIdx := DctT_Guid.Count();
                end;
            else
                Error('ALI973: invalid Dictionary key/value class %1/%2', KeyCls, ValCls);
        end;
        LiveCount += 1;
        if LiveCount > MaxLiveCollections() then
            Error('ALI972: too many List/Dictionary collections (max %1)', MaxLiveCollections());
        exit((KeyCls * 16 + ValCls) * 1000000 + BankIdx);
    end;

    // Handle Lifecycle Unification: reclaim a Dictionary handle — empties the bank slot in
    // place (same aliasing reason as ClearDict) and recycles the slot. Out-of-range handles
    // are ignored — see "ALI List Runtime".FreeList for the same guard rationale.
    procedure FreeDict(Handle: Integer)
    var
        EmptyIBig: Dictionary of [Integer, BigInteger];
        EmptyIBool: Dictionary of [Integer, Boolean];
        EmptyIDate: Dictionary of [Integer, Date];
        EmptyIDT: Dictionary of [Integer, DateTime];
        EmptyIDec: Dictionary of [Integer, Decimal];
        EmptyIDur: Dictionary of [Integer, Duration];
        EmptyIGuid: Dictionary of [Integer, Guid];
        EmptyII: Dictionary of [Integer, Integer];
        EmptyIText: Dictionary of [Integer, Text];
        EmptyITime: Dictionary of [Integer, Time];
        EmptyTBig: Dictionary of [Text, BigInteger];
        EmptyTBool: Dictionary of [Text, Boolean];
        EmptyTDate: Dictionary of [Text, Date];
        EmptyTDT: Dictionary of [Text, DateTime];
        EmptyTDec: Dictionary of [Text, Decimal];
        EmptyTDur: Dictionary of [Text, Duration];
        EmptyTGuid: Dictionary of [Text, Guid];
        EmptyTI: Dictionary of [Text, Integer];
        EmptyTText: Dictionary of [Text, Text];
        EmptyTTime: Dictionary of [Text, Time];
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    if (Bank < 1) or (Bank > DctI_Int.Count()) then
                        exit;
                    DctI_Int.Set(Bank, EmptyII);
                    FreeI_Int.Add(Bank);
                end;
            18:
                begin
                    if (Bank < 1) or (Bank > DctI_Big.Count()) then
                        exit;
                    DctI_Big.Set(Bank, EmptyIBig);
                    FreeI_Big.Add(Bank);
                end;
            19:
                begin
                    if (Bank < 1) or (Bank > DctI_Dec.Count()) then
                        exit;
                    DctI_Dec.Set(Bank, EmptyIDec);
                    FreeI_Dec.Add(Bank);
                end;
            20:
                begin
                    if (Bank < 1) or (Bank > DctI_Bool.Count()) then
                        exit;
                    DctI_Bool.Set(Bank, EmptyIBool);
                    FreeI_Bool.Add(Bank);
                end;
            21:
                begin
                    if (Bank < 1) or (Bank > DctI_Text.Count()) then
                        exit;
                    DctI_Text.Set(Bank, EmptyIText);
                    FreeI_Text.Add(Bank);
                end;
            22:
                begin
                    if (Bank < 1) or (Bank > DctI_Date.Count()) then
                        exit;
                    DctI_Date.Set(Bank, EmptyIDate);
                    FreeI_Date.Add(Bank);
                end;
            23:
                begin
                    if (Bank < 1) or (Bank > DctI_Time.Count()) then
                        exit;
                    DctI_Time.Set(Bank, EmptyITime);
                    FreeI_Time.Add(Bank);
                end;
            24:
                begin
                    if (Bank < 1) or (Bank > DctI_DT.Count()) then
                        exit;
                    DctI_DT.Set(Bank, EmptyIDT);
                    FreeI_DT.Add(Bank);
                end;
            25:
                begin
                    if (Bank < 1) or (Bank > DctI_Dur.Count()) then
                        exit;
                    DctI_Dur.Set(Bank, EmptyIDur);
                    FreeI_Dur.Add(Bank);
                end;
            26:
                begin
                    if (Bank < 1) or (Bank > DctI_Guid.Count()) then
                        exit;
                    DctI_Guid.Set(Bank, EmptyIGuid);
                    FreeI_Guid.Add(Bank);
                end;
            81:
                begin
                    if (Bank < 1) or (Bank > DctT_Int.Count()) then
                        exit;
                    DctT_Int.Set(Bank, EmptyTI);
                    FreeT_Int.Add(Bank);
                end;
            82:
                begin
                    if (Bank < 1) or (Bank > DctT_Big.Count()) then
                        exit;
                    DctT_Big.Set(Bank, EmptyTBig);
                    FreeT_Big.Add(Bank);
                end;
            83:
                begin
                    if (Bank < 1) or (Bank > DctT_Dec.Count()) then
                        exit;
                    DctT_Dec.Set(Bank, EmptyTDec);
                    FreeT_Dec.Add(Bank);
                end;
            84:
                begin
                    if (Bank < 1) or (Bank > DctT_Bool.Count()) then
                        exit;
                    DctT_Bool.Set(Bank, EmptyTBool);
                    FreeT_Bool.Add(Bank);
                end;
            85:
                begin
                    if (Bank < 1) or (Bank > DctT_Text.Count()) then
                        exit;
                    DctT_Text.Set(Bank, EmptyTText);
                    FreeT_Text.Add(Bank);
                end;
            86:
                begin
                    if (Bank < 1) or (Bank > DctT_Date.Count()) then
                        exit;
                    DctT_Date.Set(Bank, EmptyTDate);
                    FreeT_Date.Add(Bank);
                end;
            87:
                begin
                    if (Bank < 1) or (Bank > DctT_Time.Count()) then
                        exit;
                    DctT_Time.Set(Bank, EmptyTTime);
                    FreeT_Time.Add(Bank);
                end;
            88:
                begin
                    if (Bank < 1) or (Bank > DctT_DT.Count()) then
                        exit;
                    DctT_DT.Set(Bank, EmptyTDT);
                    FreeT_DT.Add(Bank);
                end;
            89:
                begin
                    if (Bank < 1) or (Bank > DctT_Dur.Count()) then
                        exit;
                    DctT_Dur.Set(Bank, EmptyTDur);
                    FreeT_Dur.Add(Bank);
                end;
            90:
                begin
                    if (Bank < 1) or (Bank > DctT_Guid.Count()) then
                        exit;
                    DctT_Guid.Set(Bank, EmptyTGuid);
                    FreeT_Guid.Add(Bank);
                end;
            else
                exit;
        end;
        if LiveCount > 0 then
            LiveCount -= 1;
    end;

    procedure Count(Handle: Integer): Integer
    var
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    exit(DII.Count());
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    exit(DIBig.Count());
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    exit(DIDec.Count());
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    exit(DIBool.Count());
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    exit(DIText.Count());
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    exit(DIDate.Count());
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    exit(DITime.Count());
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    exit(DIDT.Count());
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    exit(DIDur.Count());
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    exit(DIGuid.Count());
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    exit(DTI.Count());
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    exit(DTBig.Count());
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    exit(DTDec.Count());
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    exit(DTBool.Count());
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    exit(DTText.Count());
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    exit(DTDate.Count());
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    exit(DTTime.Count());
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    exit(DTDT.Count());
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    exit(DTDur.Count());
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    exit(DTGuid.Count());
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    procedure Add(Handle: Integer; K: Variant; V: Variant)
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    DII.Add(KeyInt, V);
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    DIBig.Add(KeyInt, V);
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    DIDec.Add(KeyInt, V);
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    DIBool.Add(KeyInt, V);
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    DIText.Add(KeyInt, V);
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    DIDate.Add(KeyInt, V);
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    DITime.Add(KeyInt, V);
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    DIDT.Add(KeyInt, V);
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    DIDur.Add(KeyInt, V);
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    DIGuid.Add(KeyInt, V);
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    DTI.Add(KeyText, V);
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    DTBig.Add(KeyText, V);
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    DTDec.Add(KeyText, V);
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    DTBool.Add(KeyText, V);
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    DTText.Add(KeyText, V);
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    DTDate.Add(KeyText, V);
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    DTTime.Add(KeyText, V);
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    DTDT.Add(KeyText, V);
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    DTDur.Add(KeyText, V);
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    DTGuid.Add(KeyText, V);
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    // Set(key, value) — add-or-update (native Dictionary.Set semantics).
    procedure SetKV(Handle: Integer; K: Variant; V: Variant)
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    DII.Set(KeyInt, V);
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    DIBig.Set(KeyInt, V);
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    DIDec.Set(KeyInt, V);
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    DIBool.Set(KeyInt, V);
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    DIText.Set(KeyInt, V);
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    DIDate.Set(KeyInt, V);
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    DITime.Set(KeyInt, V);
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    DIDT.Set(KeyInt, V);
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    DIDur.Set(KeyInt, V);
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    DIGuid.Set(KeyInt, V);
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    DTI.Set(KeyText, V);
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    DTBig.Set(KeyText, V);
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    DTDec.Set(KeyText, V);
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    DTBool.Set(KeyText, V);
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    DTText.Set(KeyText, V);
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    DTDate.Set(KeyText, V);
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    DTTime.Set(KeyText, V);
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    DTDT.Set(KeyText, V);
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    DTDur.Set(KeyText, V);
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    DTGuid.Set(KeyText, V);
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    procedure Get(Handle: Integer; K: Variant): Variant
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    exit(DII.Get(KeyInt));
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    exit(DIBig.Get(KeyInt));
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    exit(DIDec.Get(KeyInt));
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    exit(DIBool.Get(KeyInt));
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    exit(DIText.Get(KeyInt));
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    exit(DIDate.Get(KeyInt));
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    exit(DITime.Get(KeyInt));
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    exit(DIDT.Get(KeyInt));
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    exit(DIDur.Get(KeyInt));
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    exit(DIGuid.Get(KeyInt));
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    exit(DTI.Get(KeyText));
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    exit(DTBig.Get(KeyText));
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    exit(DTDec.Get(KeyText));
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    exit(DTBool.Get(KeyText));
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    exit(DTText.Get(KeyText));
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    exit(DTDate.Get(KeyText));
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    exit(DTTime.Get(KeyText));
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    exit(DTDT.Get(KeyText));
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    exit(DTDur.Get(KeyText));
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    exit(DTGuid.Get(KeyText));
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    procedure ContainsKey(Handle: Integer; K: Variant): Boolean
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    exit(DII.ContainsKey(KeyInt));
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    exit(DIBig.ContainsKey(KeyInt));
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    exit(DIDec.ContainsKey(KeyInt));
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    exit(DIBool.ContainsKey(KeyInt));
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    exit(DIText.ContainsKey(KeyInt));
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    exit(DIDate.ContainsKey(KeyInt));
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    exit(DITime.ContainsKey(KeyInt));
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    exit(DIDT.ContainsKey(KeyInt));
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    exit(DIDur.ContainsKey(KeyInt));
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    exit(DIGuid.ContainsKey(KeyInt));
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    exit(DTI.ContainsKey(KeyText));
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    exit(DTBig.ContainsKey(KeyText));
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    exit(DTDec.ContainsKey(KeyText));
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    exit(DTBool.ContainsKey(KeyText));
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    exit(DTText.ContainsKey(KeyText));
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    exit(DTDate.ContainsKey(KeyText));
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    exit(DTTime.ContainsKey(KeyText));
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    exit(DTDT.ContainsKey(KeyText));
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    exit(DTDur.ContainsKey(KeyText));
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    exit(DTGuid.ContainsKey(KeyText));
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    // Get(key, var value) in one call: V is set only on a hit (native Dictionary.Get(K, var V)).
    procedure TryGet(Handle: Integer; K: Variant; var V: Variant): Boolean
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    if not DII.ContainsKey(KeyInt) then
                        exit(false);
                    V := DII.Get(KeyInt);
                    exit(true);
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    if not DIBig.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIBig.Get(KeyInt);
                    exit(true);
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    if not DIDec.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIDec.Get(KeyInt);
                    exit(true);
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    if not DIBool.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIBool.Get(KeyInt);
                    exit(true);
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    if not DIText.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIText.Get(KeyInt);
                    exit(true);
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    if not DIDate.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIDate.Get(KeyInt);
                    exit(true);
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    if not DITime.ContainsKey(KeyInt) then
                        exit(false);
                    V := DITime.Get(KeyInt);
                    exit(true);
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    if not DIDT.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIDT.Get(KeyInt);
                    exit(true);
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    if not DIDur.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIDur.Get(KeyInt);
                    exit(true);
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    if not DIGuid.ContainsKey(KeyInt) then
                        exit(false);
                    V := DIGuid.Get(KeyInt);
                    exit(true);
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    if not DTI.ContainsKey(KeyText) then
                        exit(false);
                    V := DTI.Get(KeyText);
                    exit(true);
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    if not DTBig.ContainsKey(KeyText) then
                        exit(false);
                    V := DTBig.Get(KeyText);
                    exit(true);
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    if not DTDec.ContainsKey(KeyText) then
                        exit(false);
                    V := DTDec.Get(KeyText);
                    exit(true);
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    if not DTBool.ContainsKey(KeyText) then
                        exit(false);
                    V := DTBool.Get(KeyText);
                    exit(true);
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    if not DTText.ContainsKey(KeyText) then
                        exit(false);
                    V := DTText.Get(KeyText);
                    exit(true);
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    if not DTDate.ContainsKey(KeyText) then
                        exit(false);
                    V := DTDate.Get(KeyText);
                    exit(true);
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    if not DTTime.ContainsKey(KeyText) then
                        exit(false);
                    V := DTTime.Get(KeyText);
                    exit(true);
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    if not DTDT.ContainsKey(KeyText) then
                        exit(false);
                    V := DTDT.Get(KeyText);
                    exit(true);
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    if not DTDur.ContainsKey(KeyText) then
                        exit(false);
                    V := DTDur.Get(KeyText);
                    exit(true);
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    if not DTGuid.ContainsKey(KeyText) then
                        exit(false);
                    V := DTGuid.Get(KeyText);
                    exit(true);
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    procedure Remove(Handle: Integer; K: Variant): Boolean
    var
        Bank: Integer;
        KeyInt: Integer;
        KeyText: Text;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyInt := K;
                    exit(DII.Remove(KeyInt));
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyInt := K;
                    exit(DIBig.Remove(KeyInt));
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyInt := K;
                    exit(DIDec.Remove(KeyInt));
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyInt := K;
                    exit(DIBool.Remove(KeyInt));
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyInt := K;
                    exit(DIText.Remove(KeyInt));
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyInt := K;
                    exit(DIDate.Remove(KeyInt));
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyInt := K;
                    exit(DITime.Remove(KeyInt));
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyInt := K;
                    exit(DIDT.Remove(KeyInt));
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyInt := K;
                    exit(DIDur.Remove(KeyInt));
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyInt := K;
                    exit(DIGuid.Remove(KeyInt));
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyText := K;
                    exit(DTI.Remove(KeyText));
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyText := K;
                    exit(DTBig.Remove(KeyText));
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyText := K;
                    exit(DTDec.Remove(KeyText));
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyText := K;
                    exit(DTBool.Remove(KeyText));
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyText := K;
                    exit(DTText.Remove(KeyText));
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyText := K;
                    exit(DTDate.Remove(KeyText));
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyText := K;
                    exit(DTTime.Remove(KeyText));
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyText := K;
                    exit(DTDT.Remove(KeyText));
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyText := K;
                    exit(DTDur.Remove(KeyText));
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyText := K;
                    exit(DTGuid.Remove(KeyText));
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    // Clear(Dictionary): empties it in place (Count -> 0), handle stays valid. Replaces the
    // bank slot with a fresh empty Dictionary — same aliasing reason as "ALI List
    // Runtime".ClearList (Clear() on the local var would only rebind the local reference).
    procedure ClearDict(Handle: Integer)
    var
        EmptyIBig: Dictionary of [Integer, BigInteger];
        EmptyIBool: Dictionary of [Integer, Boolean];
        EmptyIDate: Dictionary of [Integer, Date];
        EmptyIDT: Dictionary of [Integer, DateTime];
        EmptyIDec: Dictionary of [Integer, Decimal];
        EmptyIDur: Dictionary of [Integer, Duration];
        EmptyIGuid: Dictionary of [Integer, Guid];
        EmptyII: Dictionary of [Integer, Integer];
        EmptyIText: Dictionary of [Integer, Text];
        EmptyITime: Dictionary of [Integer, Time];
        EmptyTBig: Dictionary of [Text, BigInteger];
        EmptyTBool: Dictionary of [Text, Boolean];
        EmptyTDate: Dictionary of [Text, Date];
        EmptyTDT: Dictionary of [Text, DateTime];
        EmptyTDec: Dictionary of [Text, Decimal];
        EmptyTDur: Dictionary of [Text, Duration];
        EmptyTGuid: Dictionary of [Text, Guid];
        EmptyTI: Dictionary of [Text, Integer];
        EmptyTText: Dictionary of [Text, Text];
        EmptyTTime: Dictionary of [Text, Time];
        Bank: Integer;
    begin
        Bank := (Handle mod 1000000);
        case (Handle div 1000000) of
            17:
                DctI_Int.Set(Bank, EmptyII);
            18:
                DctI_Big.Set(Bank, EmptyIBig);
            19:
                DctI_Dec.Set(Bank, EmptyIDec);
            20:
                DctI_Bool.Set(Bank, EmptyIBool);
            21:
                DctI_Text.Set(Bank, EmptyIText);
            22:
                DctI_Date.Set(Bank, EmptyIDate);
            23:
                DctI_Time.Set(Bank, EmptyITime);
            24:
                DctI_DT.Set(Bank, EmptyIDT);
            25:
                DctI_Dur.Set(Bank, EmptyIDur);
            26:
                DctI_Guid.Set(Bank, EmptyIGuid);
            81:
                DctT_Int.Set(Bank, EmptyTI);
            82:
                DctT_Big.Set(Bank, EmptyTBig);
            83:
                DctT_Dec.Set(Bank, EmptyTDec);
            84:
                DctT_Bool.Set(Bank, EmptyTBool);
            85:
                DctT_Text.Set(Bank, EmptyTText);
            86:
                DctT_Date.Set(Bank, EmptyTDate);
            87:
                DctT_Time.Set(Bank, EmptyTTime);
            88:
                DctT_DT.Set(Bank, EmptyTDT);
            89:
                DctT_Dur.Set(Bank, EmptyTDur);
            90:
                DctT_Guid.Set(Bank, EmptyTGuid);
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
    end;

    // Keys() -> a FRESH List handle (element class = this dictionary's key class).
    procedure Keys(Handle: Integer): Integer
    var
        Bank: Integer;
        k: Integer;
        KeyCls: Integer;
        NewHandle: Integer;
        KeyIntList: List of [Integer];
        KeyTextList: List of [Text];
    begin
        Bank := (Handle mod 1000000);
        KeyCls := (Handle div 1000000) div 16;
        NewHandle := ListRt.NewList(KeyCls);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    KeyIntList := DII.Keys();
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    KeyIntList := DIBig.Keys();
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    KeyIntList := DIDec.Keys();
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    KeyIntList := DIBool.Keys();
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    KeyIntList := DIText.Keys();
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    KeyIntList := DIDate.Keys();
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    KeyIntList := DITime.Keys();
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    KeyIntList := DIDT.Keys();
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    KeyIntList := DIDur.Keys();
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    KeyIntList := DIGuid.Keys();
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    KeyTextList := DTI.Keys();
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    KeyTextList := DTBig.Keys();
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    KeyTextList := DTDec.Keys();
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    KeyTextList := DTBool.Keys();
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    KeyTextList := DTText.Keys();
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    KeyTextList := DTDate.Keys();
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    KeyTextList := DTTime.Keys();
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    KeyTextList := DTDT.Keys();
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    KeyTextList := DTDur.Keys();
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    KeyTextList := DTGuid.Keys();
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
        if KeyCls = 1 then
            for k := 1 to KeyIntList.Count() do
                ListRt.Add(NewHandle, KeyIntList.Get(k))
        else
            for k := 1 to KeyTextList.Count() do
                ListRt.Add(NewHandle, KeyTextList.Get(k));
        exit(NewHandle);
    end;

    // Values() -> a FRESH List handle (element class = this dictionary's value class).
    procedure Values(Handle: Integer): Integer
    var
        Bank: Integer;
        i: Integer;
        NewHandle: Integer;
        ValCls: Integer;
        ValBigList: List of [BigInteger];
        ValBoolList: List of [Boolean];
        ValDateList: List of [Date];
        ValDTList: List of [DateTime];
        ValDecList: List of [Decimal];
        ValDurList: List of [Duration];
        ValGuidList: List of [Guid];
        ValIntList: List of [Integer];
        ValTextList: List of [Text];
        ValTimeList: List of [Time];
    begin
        Bank := (Handle mod 1000000);
        ValCls := (Handle div 1000000) mod 16;
        NewHandle := ListRt.NewList(ValCls);
        case (Handle div 1000000) of
            17:
                begin
                    DctI_Int.Get(Bank, DII);
                    ValIntList := DII.Values();
                end;
            18:
                begin
                    DctI_Big.Get(Bank, DIBig);
                    ValBigList := DIBig.Values();
                end;
            19:
                begin
                    DctI_Dec.Get(Bank, DIDec);
                    ValDecList := DIDec.Values();
                end;
            20:
                begin
                    DctI_Bool.Get(Bank, DIBool);
                    ValBoolList := DIBool.Values();
                end;
            21:
                begin
                    DctI_Text.Get(Bank, DIText);
                    ValTextList := DIText.Values();
                end;
            22:
                begin
                    DctI_Date.Get(Bank, DIDate);
                    ValDateList := DIDate.Values();
                end;
            23:
                begin
                    DctI_Time.Get(Bank, DITime);
                    ValTimeList := DITime.Values();
                end;
            24:
                begin
                    DctI_DT.Get(Bank, DIDT);
                    ValDTList := DIDT.Values();
                end;
            25:
                begin
                    DctI_Dur.Get(Bank, DIDur);
                    ValDurList := DIDur.Values();
                end;
            26:
                begin
                    DctI_Guid.Get(Bank, DIGuid);
                    ValGuidList := DIGuid.Values();
                end;
            81:
                begin
                    DctT_Int.Get(Bank, DTI);
                    ValIntList := DTI.Values();
                end;
            82:
                begin
                    DctT_Big.Get(Bank, DTBig);
                    ValBigList := DTBig.Values();
                end;
            83:
                begin
                    DctT_Dec.Get(Bank, DTDec);
                    ValDecList := DTDec.Values();
                end;
            84:
                begin
                    DctT_Bool.Get(Bank, DTBool);
                    ValBoolList := DTBool.Values();
                end;
            85:
                begin
                    DctT_Text.Get(Bank, DTText);
                    ValTextList := DTText.Values();
                end;
            86:
                begin
                    DctT_Date.Get(Bank, DTDate);
                    ValDateList := DTDate.Values();
                end;
            87:
                begin
                    DctT_Time.Get(Bank, DTTime);
                    ValTimeList := DTTime.Values();
                end;
            88:
                begin
                    DctT_DT.Get(Bank, DTDT);
                    ValDTList := DTDT.Values();
                end;
            89:
                begin
                    DctT_Dur.Get(Bank, DTDur);
                    ValDurList := DTDur.Values();
                end;
            90:
                begin
                    DctT_Guid.Get(Bank, DTGuid);
                    ValGuidList := DTGuid.Values();
                end;
            else
                Error('ALI973: invalid Dictionary handle %1', Handle);
        end;
        case ValCls of
            1:
                for i := 1 to ValIntList.Count() do
                    ListRt.Add(NewHandle, ValIntList.Get(i));
            2:
                for i := 1 to ValBigList.Count() do
                    ListRt.Add(NewHandle, ValBigList.Get(i));
            3:
                for i := 1 to ValDecList.Count() do
                    ListRt.Add(NewHandle, ValDecList.Get(i));
            4:
                for i := 1 to ValBoolList.Count() do
                    ListRt.Add(NewHandle, ValBoolList.Get(i));
            5:
                for i := 1 to ValTextList.Count() do
                    ListRt.Add(NewHandle, ValTextList.Get(i));
            6:
                for i := 1 to ValDateList.Count() do
                    ListRt.Add(NewHandle, ValDateList.Get(i));
            7:
                for i := 1 to ValTimeList.Count() do
                    ListRt.Add(NewHandle, ValTimeList.Get(i));
            8:
                for i := 1 to ValDTList.Count() do
                    ListRt.Add(NewHandle, ValDTList.Get(i));
            9:
                for i := 1 to ValDurList.Count() do
                    ListRt.Add(NewHandle, ValDurList.Get(i));
            10:
                for i := 1 to ValGuidList.Count() do
                    ListRt.Add(NewHandle, ValGuidList.Get(i));
        end;
        exit(NewHandle);
    end;
}
