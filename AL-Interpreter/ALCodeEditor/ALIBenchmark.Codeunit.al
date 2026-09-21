// Native AL vs ALI benchmark (Script Options page, "Benchmark" action). The SAME workload exists
// twice in this codeunit: once as native procedures (NativeMain + helpers) and once as ALI source
// text (BenchmarkSource). Keep both in sync — the run compares their checksums to prove both sides
// did identical work before comparing durations.
// Workload per Customer: SetLoadFields read, Text ops, Char arithmetic loop, Decimal rounding,
// Date check, Dictionary/List updates and three sub procedure calls. Read-only.
codeunit 51129 "ALI Benchmark"
{
    Access = Internal;

    var
        CountryCount: Dictionary of [Code[10], Integer];

    procedure RunWithSizePrompt(Optimize: Boolean)
    var
        Choice: Integer;
        SizeMenuLbl: Label '10 000 customers,100 000 customers,All customers';
    begin
        Choice := StrMenu(SizeMenuLbl, 2, 'Benchmark size');
        case Choice of
            1:
                Message(Run(10000, Optimize));
            2:
                Message(Run(100000, Optimize));
            3:
                Message(Run(2147483647, Optimize));
        end;
    end;

    procedure Run(MaxRecords: Integer; Optimize: Boolean): Text
    var
        Engine: Codeunit "ALI Engine";
        Diags: Codeunit "ALI Diag Bag";
        Result: Codeunit "ALI Exec Result";
        RunOptions: Codeunit "ALI Run Options";
        CompileStart: DateTime;
        NativeStart: DateTime;
        CompileMs: BigInteger;
        NativeMs: BigInteger;
        AliMs: BigInteger;
        NativeChecksum: BigInteger;
        Window: Dialog;
        Sb: TextBuilder;
    begin
        if GuiAllowed then
            Window.Open('Running benchmark...\#1##########################');

        RunOptions.Reset();
        RunOptions.SetMode("ALI Exec Mode"::Simulation.AsInteger());
        Engine.SetOptimize(Optimize);
        Engine.SetRequireOnRun(false);
        Engine.SetVerbose(false);
        Engine.Warmup();

        // Untimed pass: whichever side reads the customers first pays the SQL cache warm-up.
        if GuiAllowed then
            Window.Update(1, 'Warm-up');
        NativeMain(MaxRecords);

        if GuiAllowed then
            Window.Update(1, 'Native AL');
        NativeStart := CurrentDateTime();
        NativeChecksum := NativeMain(MaxRecords);
        NativeMs := CurrentDateTime() - NativeStart;

        if GuiAllowed then
            Window.Update(1, 'ALI compile');
        CompileStart := CurrentDateTime();
        if not Engine.Compile(BenchmarkSource(MaxRecords), Diags) then
            Error('Benchmark script does not compile: %1', Diags.ToText());
        CompileMs := CurrentDateTime() - CompileStart;

        if GuiAllowed then
            Window.Update(1, 'ALI run');
        Engine.RunCompiled(Result);
        if GuiAllowed then
            Window.Close();
        if not Result.Succeeded() then
            Error('Benchmark script failed: %1', Result.ToText());
        AliMs := Result.DurationMs();

        Sb.AppendLine(StrSubstNo('Customers processed: %1', CountryRecordTotal()));
        Sb.AppendLine(StrSubstNo('Native AL: %1 ms', NativeMs));
        Sb.AppendLine(StrSubstNo('ALI: %1 ms (+ compile %2 ms, optimize %3)', AliMs, CompileMs, Optimize));
        if NativeMs > 0 then
            Sb.AppendLine(StrSubstNo('ALI / native: x%1', Round(AliMs / NativeMs, 0.1)));
        if Result.ResultText() = Format(NativeChecksum) then
            Sb.AppendLine(StrSubstNo('Checksum match: %1', NativeChecksum))
        else
            Sb.AppendLine(StrSubstNo('CHECKSUM MISMATCH: native %1, ALI %2', NativeChecksum, Result.ResultText()));
        exit(Sb.ToText());
    end;

    local procedure CountryRecordTotal() Total: Integer
    var
        CountryCode: Code[10];
    begin
        foreach CountryCode in CountryCount.Keys() do
            Total += CountryCount.Get(CountryCode);
    end;

    // ===== Native workload — mirrored line for line by BenchmarkSource =====

    local procedure NativeMain(MaxRecords: Integer): BigInteger
    var
        Cust: Record Customer;
        Names: List of [Text];
        CountryCode: Code[10];
        NameKey: Text;
        Amount: Decimal;
        Checksum: BigInteger;
        Processed: Integer;
    begin
        Clear(CountryCount);
        Cust.SetLoadFields("No.", Name, City, "Country/Region Code", "Credit Limit (LCY)", "Last Date Modified");
        if Cust.FindSet() then
            repeat
                Processed += 1;
                NameKey := NormalizeName(Cust.Name, Cust.City);
                Checksum += StrLen(NameKey) + HashText(Cust."No.");
                CountByCountry(Cust."Country/Region Code");
                Amount := Round(Cust."Credit Limit (LCY)" * 1.077, 0.01);
                if Amount > 1000 then
                    Checksum += 1;
                if Cust."Last Date Modified" <> 0D then
                    Checksum += Date2DMY(Cust."Last Date Modified", 3);
                if Processed mod 1000 = 0 then
                    Names.Add(NameKey);
            until (Cust.Next() = 0) or (Processed >= MaxRecords);
        foreach CountryCode in CountryCount.Keys() do
            Checksum += CountryCount.Get(CountryCode);
        exit(Checksum + Names.Count());
    end;

    local procedure NormalizeName(Name: Text; City: Text): Text
    begin
        exit(UpperCase(DelChr(Name, '<>', ' ')) + '|' + CopyStr(City, 1, 3));
    end;

    local procedure HashText(Value: Text): Integer
    var
        i: Integer;
        h: Integer;
    begin
        for i := 1 to StrLen(Value) do
            h := (h * 31 + Value[i]) mod 1000003;
        exit(h);
    end;

    local procedure CountByCountry(CountryCode: Code[10])
    var
        n: Integer;
    begin
        if CountryCount.Get(CountryCode, n) then
            CountryCount.Set(CountryCode, n + 1)
        else
            CountryCount.Add(CountryCode, 1);
    end;

    // ===== Same workload as ALI source =====

    local procedure BenchmarkSource(MaxRecords: Integer): Text
    var
        Src: TextBuilder;
    begin
        Src.AppendLine('var');
        Src.AppendLine('    CountryCount: Dictionary of [Code[10], Integer];');
        Src.AppendLine('');
        Src.AppendLine('procedure Main(): BigInteger');
        Src.AppendLine('var');
        Src.AppendLine('    Cust: Record Customer;');
        Src.AppendLine('    Names: List of [Text];');
        Src.AppendLine('    CountryCode: Code[10];');
        Src.AppendLine('    NameKey: Text;');
        Src.AppendLine('    Amount: Decimal;');
        Src.AppendLine('    Checksum: BigInteger;');
        Src.AppendLine('    Processed: Integer;');
        Src.AppendLine('begin');
        Src.AppendLine('    Cust.SetLoadFields("No.", Name, City, "Country/Region Code", "Credit Limit (LCY)", "Last Date Modified");');
        Src.AppendLine('    if Cust.FindSet() then');
        Src.AppendLine('        repeat');
        Src.AppendLine('            Processed += 1;');
        Src.AppendLine('            NameKey := NormalizeName(Cust.Name, Cust.City);');
        Src.AppendLine('            Checksum += StrLen(NameKey) + HashText(Cust."No.");');
        Src.AppendLine('            CountByCountry(Cust."Country/Region Code");');
        Src.AppendLine('            Amount := Round(Cust."Credit Limit (LCY)" * 1.077, 0.01);');
        Src.AppendLine('            if Amount > 1000 then');
        Src.AppendLine('                Checksum += 1;');
        Src.AppendLine('            if Cust."Last Date Modified" <> 0D then');
        Src.AppendLine('                Checksum += Date2DMY(Cust."Last Date Modified", 3);');
        Src.AppendLine('            if Processed mod 1000 = 0 then');
        Src.AppendLine('                Names.Add(NameKey);');
        Src.AppendLine(StrSubstNo('        until (Cust.Next() = 0) or (Processed >= %1);', MaxRecords));
        Src.AppendLine('    foreach CountryCode in CountryCount.Keys() do');
        Src.AppendLine('        Checksum += CountryCount.Get(CountryCode);');
        Src.AppendLine('    exit(Checksum + Names.Count());');
        Src.AppendLine('end;');
        Src.AppendLine('');
        Src.AppendLine('local procedure NormalizeName(Name: Text; City: Text): Text');
        Src.AppendLine('begin');
        Src.AppendLine('    exit(UpperCase(DelChr(Name, ''<>'', '' '')) + ''|'' + CopyStr(City, 1, 3));');
        Src.AppendLine('end;');
        Src.AppendLine('');
        Src.AppendLine('local procedure HashText(Value: Text): Integer');
        Src.AppendLine('var');
        Src.AppendLine('    i: Integer;');
        Src.AppendLine('    h: Integer;');
        Src.AppendLine('begin');
        Src.AppendLine('    for i := 1 to StrLen(Value) do');
        Src.AppendLine('        h := (h * 31 + Value[i]) mod 1000003;');
        Src.AppendLine('    exit(h);');
        Src.AppendLine('end;');
        Src.AppendLine('');
        Src.AppendLine('local procedure CountByCountry(CountryCode: Code[10])');
        Src.AppendLine('var');
        Src.AppendLine('    n: Integer;');
        Src.AppendLine('begin');
        Src.AppendLine('    if CountryCount.Get(CountryCode, n) then');
        Src.AppendLine('        CountryCount.Set(CountryCode, n + 1)');
        Src.AppendLine('    else');
        Src.AppendLine('        CountryCount.Add(CountryCode, 1);');
        Src.AppendLine('end;');
        exit(Src.ToText());
    end;
}
