// ALI Array Block M — medium tier (Cap 1000), one native array[1000] of Variant per instance
// (~24KB). Identical to "ALI Array Block S" except Cells size and Cap().
codeunit 51140 "ALI Array Block M" implements "ALI Array Block"
{
    Access = Public;

    var
        LiveCls: Integer;
        LiveN: Integer;
        Cells: array[1000] of Variant;

    procedure Alloc(N: Integer; Cls: Integer)
    var
        i: Integer;
    begin
        LiveN := N;
        LiveCls := Cls;
        for i := 1 to N do
            Cells[i] := DefaultOf(Cls);
    end;

    procedure ClearArray()
    var
        i: Integer;
    begin
        for i := 1 to LiveN do
            Cells[i] := DefaultOf(LiveCls);
    end;

    // Uninitialized locals ARE their type's default — no explicit assignment needed; this
    // just picks the right one per class so array reads never see a bare empty Variant.
    local procedure DefaultOf(Cls: Integer): Variant
    var
        DF: DateFormula;
        RId: RecordId;
        Bg: BigInteger;
        Bo: Boolean;
        Dt: Date;
        DtTm: DateTime;
        D: Decimal;
        Dur: Duration;
        G: Guid;
        Z: Integer;
        T: Text;
        Tm: Time;
        Vr: Variant;
    begin
        case Cls of
            1:
                exit(Z);        // Integer/Char/Byte/Option
            2:
                exit(Bg);       // BigInteger
            3:
                exit(D);        // Decimal
            4:
                exit(Bo);       // Boolean
            5:
                exit(T);        // Text/Code/Label
            6:
                exit(Dt);       // Date
            7:
                exit(Tm);       // Time
            8:
                exit(DtTm);     // DateTime
            9:
                exit(Dur);      // Duration
            10:
                exit(G);        // Guid
            12:
                exit(RId);      // RecordID
            13:
                exit(DF);       // DateFormula
            else
                exit(Vr);       // 11=Variant: EMPTY is its own correct native default
        end;
    end;


    procedure SetCell(FlatIdx: Integer; V: Variant)
    begin
        if (FlatIdx < 1) or (FlatIdx > LiveN) then
            Error('ALI957: array index %1 out of bounds (1..%2)', FlatIdx, LiveN);
        Cells[FlatIdx] := V;
    end;

    procedure GetCell(FlatIdx: Integer): Variant
    begin
        if (FlatIdx < 1) or (FlatIdx > LiveN) then
            Error('ALI957: array index %1 out of bounds (1..%2)', FlatIdx, LiveN);
        exit(Cells[FlatIdx]);
    end;

    procedure TotalN(): Integer
    begin
        exit(LiveN);
    end;

    procedure Cap(): Integer
    begin
        exit(1000);
    end;

    procedure Compress(): Integer
    var
        i: Integer;
        w: Integer;
    begin
        w := 0;
        for i := 1 to LiveN do
            if Format(Cells[i]) <> '' then begin
                w += 1;
                if w <> i then
                    Cells[w] := Cells[i];
            end;
        for i := w + 1 to LiveN do
            Cells[i] := '';
        exit(w);
    end;

    procedure CopyFrom(Src: Interface "ALI Array Block"; SrcPos: Integer; Len: Integer)
    var
        i: Integer;
    begin
        for i := 0 to Len - 1 do
            Cells[i + 1] := Src.GetCell(SrcPos + i);
    end;
}
