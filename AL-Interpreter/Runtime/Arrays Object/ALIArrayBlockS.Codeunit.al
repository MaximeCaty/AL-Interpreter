// ALI Array Block S — small tier (Cap 100), one native array[100] of Variant per instance
// (~2KB). Bodies of S/M/L are identical except the Cells size and Cap() — see
// ArrayNativeBlockPlan.md. Seeding/range-check live here; tier pick + lifecycle in
// "ALI Array Runtime".
codeunit 51139 "ALI Array Block S" implements "ALI Array Block"
{
    Access = Public;

    var
        LiveCls: Integer;
        LiveN: Integer;
        Cells: array[100] of Variant;

    procedure Alloc(N: Integer; Cls: Integer)
    begin
        LiveN := N;
        LiveCls := Cls;
        ClearArray();
    end;

    procedure ClearArray()
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
        i: Integer;
        Z: Integer;
        T: Text;
        Tm: Time;
        Vr: Variant;
    begin
        case LiveCls of
            1:
                for i := 1 to LiveN do
                    Cells[i] := Z;        // Integer/Char/Byte/Option
            2:
                for i := 1 to LiveN do
                    Cells[i] := Bg;       // BigInteger
            3:
                for i := 1 to LiveN do
                    Cells[i] := D;        // Decimal
            4:
                for i := 1 to LiveN do
                    Cells[i] := Bo;       // Boolean
            5:
                for i := 1 to LiveN do
                    Cells[i] := T;        // Text/Code/Label
            6:
                for i := 1 to LiveN do
                    Cells[i] := Dt;       // Date
            7:
                for i := 1 to LiveN do
                    Cells[i] := Tm;       // Time
            8:
                for i := 1 to LiveN do
                    Cells[i] := DtTm;     // DateTime
            9:
                for i := 1 to LiveN do
                    Cells[i] := Dur;      // Duration
            10:
                for i := 1 to LiveN do
                    Cells[i] := G;        // Guid
            12:
                for i := 1 to LiveN do
                    Cells[i] := RId;      // RecordID
            13:
                for i := 1 to LiveN do
                    Cells[i] := DF;       // DateFormula
            else
                for i := 1 to LiveN do
                Cells[i] := Vr;       // 11=Variant: EMPTY is its own correct native default
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
        exit(100);
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
