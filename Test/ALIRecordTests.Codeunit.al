// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Record Tests — the data-access surface: Record, RecordRef (incl. the P4 batch) and
// FieldRef. Merged from the former "ALI Record/RecordRef/RecordRef P4/FieldRef Tests"
// codeunits; all sections share the "ALI Test Customer"/"ALI Test Order Line" fixtures.
codeunit 51052 "ALI Record Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Pipeline: Codeunit "ALI Test Pipeline";
        Assert: Codeunit "Library Assert";

    // ================================================================================================
    // ALI Record & Array Tests (§14 item 7 — M6: records via RecordRef, typed field access,
    // CRUD, filters + FindSet/Next iteration, SetRange, Get, value-copy semantics, and 1-D
    // arrays).
    //
    // Native-comparison trick (§14): the test app IS an AL host, so every record operation the
    // interpreter performs is asserted against the SAME operation on a native "ALI Test
    // Customer" record. Test isolation is AutoRollback (default) so the DB is clean per test.
    // ================================================================================================

    // ===== Helpers =====

    local procedure RunInt(Source: Text): Integer
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultInt());
    end;

    local procedure RunText(Source: Text): Text
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultText());
    end;

    local procedure RunDec(Source: Text): Decimal
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultDec());
    end;

    local procedure RunBool(Source: Text): Boolean
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultBool());
    end;

    local procedure CleanSeed()
    var
        Cust: Record "ALI Test Customer";
    begin
        Cust.DeleteAll();
    end;

    local procedure Seed(No: Code[20]; CustName: Text[100]; Bal: Decimal; PostCount: Integer)
    var
        Cust: Record "ALI Test Customer";
    begin
        if Cust.Get(No) then
            Cust.Delete();
        Cust.Init();
        Cust."No." := No;
        Cust.Name := CustName;
        Cust.Balance := Bal;
        Cust."Post Count" := PostCount;
        Cust.Insert();
    end;

    local procedure RunExpectFail(Source: Text; var Result: Codeunit "ALI Exec Result")
    var
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsFalse(Result.Succeeded(), 'Succeeded must be false on a raised error');
    end;

    local procedure AssertDiag(var Diags: Codeunit "ALI Diag Bag"; DiagCode: Text; Fragment: Text)
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if (Diags.GetCode(i) = DiagCode) and (StrPos(Diags.GetMessage(i), Fragment) > 0) then
                exit;
        Assert.Fail(StrSubstNo('expected diagnostic %1 containing <%2>; got: %3', DiagCode, Fragment, Diags.ToText()));
    end;

    // ===== Field write / read =====

    [Test]
    procedure T01_FieldWriteReadInteger()
    begin
        // Set an Integer field, read it back through the entry result.
        Assert.AreEqual(42,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."Post Count" := 42; exit(c."Post Count"); end;'),
            'integer field round-trip through RecordRef');
    end;

    [Test]
    procedure T02_FieldWriteReadText()
    begin
        Assert.AreEqual('Contoso',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c.Name := ''Contoso''; exit(c.Name); end;'),
            'text field round-trip');
    end;

    [Test]
    procedure T03_FieldDecimalArithmetic()
    var
        Native: Decimal;
    begin
        Native := 100.5 + 25.25;
        Assert.AreEqual(Native,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal begin c.Init(); c.Balance := 100.5; c.Balance := c.Balance + 25.25; exit(c.Balance); end;'),
            'decimal field read-modify-write');
    end;

    [Test]
    procedure T04_CodeFieldUppercasesOnStore()
    begin
        // "No." is Code[20]; native uppercases on store. FieldRef.Value applies the same.
        Assert.AreEqual('C0001',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c."No." := ''c0001''; exit(c."No."); end;'),
            'Code field uppercases on store (native semantics)');
    end;

    // ===== Insert / Count / IsEmpty =====

    [Test]
    procedure T05_InsertAndCount()
    var
        Cust: Record "ALI Test Customer";
        RunOptions: Codeunit "ALI Run Options";
        Native: Integer;
    begin
        RunOptions.Reset();     // see T11: a leaked Simulation mode would roll the Delete back
        RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.DeleteAll(); c.Init(); c."No." := ''K1''; c.Insert(); c.Init(); c."No." := ''K2''; c.Insert(); c.Init(); c."No." := ''K3''; c.Insert(); c.Init(); c."No." := ''K4''; c.Insert(); c.Init(); c."No." := ''K5''; c.Insert(); exit(c.Count()); end;');
        Native := Cust.Count();
        Assert.AreEqual(5, Native, 'interpreter inserted 5 rows visible to a native Record');
    end;

    [Test]
    procedure T06_IsEmptyThenNot()
    begin
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin if c.IsEmpty() then begin c.Init(); c."No." := ''X''; c.Insert(); end; if c.IsEmpty() then exit(0); exit(1); end;'),
            'IsEmpty true then false after insert');
    end;

    // ===== FindSet / Next iteration =====

    [Test]
    procedure T07_FindSetNextSumsBalances()
    var
        Cust: Record "ALI Test Customer";
        Native: Decimal;
    begin
        Seed('A', 'Alpha', 10.0, 1);
        Seed('B', 'Bravo', 20.0, 2);
        Seed('C', 'Charlie', 30.0, 3);
        if Cust.FindSet() then
            repeat
                Native += Cust.Balance;
            until Cust.Next() = 0;
        Assert.AreEqual(Native,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal var s: Decimal; begin if c.FindSet() then repeat s := s + c.Balance; until c.Next() = 0; exit(s); end;'),
            'FindSet + Next iteration sums balances like native');
    end;

    [Test]
    procedure T07c_FindSetForUpdateStillFindsAll()
    var
        Cust: Record "ALI Test Customer";
        Native: Decimal;
    begin
        Seed('A', 'Alpha', 10.0, 1);
        Seed('B', 'Bravo', 20.0, 2);
        Seed('C', 'Charlie', 30.0, 3);
        if Cust.FindSet(true) then
            repeat
                Native += Cust.Balance;
            until Cust.Next() = 0;
        Assert.AreEqual(Native,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal var s: Decimal; begin if c.FindSet(true) then repeat s := s + c.Balance; until c.Next() = 0; exit(s); end;'),
            'FindSet(true) (ForUpdate) finds the same rows as FindSet()');
    end;

    [Test]
    procedure T07d_NextWithStepSkipsRows()
    var
        Cust: Record "ALI Test Customer";
        Native: Decimal;
    begin
        Seed('A', 'Alpha', 10.0, 1);
        Seed('B', 'Bravo', 20.0, 2);
        Seed('C', 'Charlie', 30.0, 3);
        Seed('D', 'Delta', 40.0, 4);
        if Cust.FindSet() then
            repeat
                Native += Cust.Balance;
            until Cust.Next(2) = 0;
        Assert.AreEqual(Native,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal var s: Decimal; begin if c.FindSet() then repeat s := s + c.Balance; until c.Next(2) = 0; exit(s); end;'),
            'Next(2) skips every other row like native');
    end;

    // ===== Paren-less no-arg methods (AL allows dropping () on no-arg calls) =====

    [Test]
    procedure T07b_ParenlessFindSetNext()
    var
        Cust: Record "ALI Test Customer";
        Native: Decimal;
    begin
        Seed('A', 'Alpha', 10.0, 1);
        Seed('B', 'Bravo', 20.0, 2);
        Seed('C', 'Charlie', 30.0, 3);
        if Cust.FindSet() then
            repeat
                Native += Cust.Balance;
            until Cust.Next() = 0;
        // `c.FindSet` (expr), `c.Next` (expr), and `c.Reset` (bare statement) — all without ().
        Assert.AreEqual(Native,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal var s: Decimal; begin c.Reset; if c.FindSet then repeat s := s + c.Balance; until c.Next = 0; exit(s); end;'),
            'Paren-less FindSet/Next/Reset behave like their () forms');
    end;

    // ===== SetRange filter =====

    [Test]
    procedure T08_SetRangeFiltersCount()
    var
        Cust: Record "ALI Test Customer";
        Native: Integer;
    begin
        Seed('A', 'Alpha', 10.0, 1);
        Seed('B', 'Bravo', 20.0, 2);
        Seed('C', 'Charlie', 20.0, 3);
        Cust.SetRange(Balance, 20.0);
        Native := Cust.Count();
        Assert.AreEqual(Native,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Balance, 20.0); exit(c.Count()); end;'),
            'SetRange on a decimal field filters the count');
        Assert.AreEqual(2, Native, 'sanity: two rows match balance 20');
    end;

    // ===== Get =====

    [Test]
    procedure T09_GetByPrimaryKey()
    begin
        Seed('PK01', 'KeyedCust', 77.0, 9);
        Assert.AreEqual('KeyedCust',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin if c.Get(''PK01'') then exit(c.Name); exit(''<none>''); end;'),
            'Get by PK loads the row');
    end;

    [Test]
    procedure T10_GetMissingReturnsFalse()
    begin
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin if c.Get(''NOPE'') then exit(1); exit(0); end;'),
            'Get of a missing key returns false');
    end;

    [Test]
    procedure T10a_GetByCompositePrimaryKey()
    var
        Line: Record "ALI Test Order Line";
    begin
        Line.Init();
        Line."Order No." := 'SO001';
        Line."Line No." := 10000;
        Line.Description := 'Widget';
        Line.Quantity := 5;
        Line.Insert();

        Assert.AreEqual('Widget',
            RunText('var l: Record "ALI Test Order Line"; procedure P(): Text begin if l.Get(''SO001'', 10000) then exit(l.Description); exit(''<none>''); end;'),
            'Get with a 2-field composite PK loads the row');
    end;

    [Test]
    procedure T10b_GetByCompositePrimaryKeyMissing()
    begin
        Assert.AreEqual(0,
            RunInt('var l: Record "ALI Test Order Line"; procedure P(): Integer begin if l.Get(''SO999'', 99999) then exit(1); exit(0); end;'),
            'Get with a 2-field composite PK returns false when no row matches');
    end;

    [Test]
    procedure T10c_ConditionalInsertReturnsBool()
    begin
        // `if c.Insert() then` — Insert returns Boolean (true on success), so the conditional
        // form must compile and yield true after a successful insert.
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''CI1''; if c.Insert() then exit(1); exit(0); end;'),
            'conditional Insert() compiles and returns true on success');
    end;

    [Test]
    procedure T10d_GetNoArgUsesCurrentKey()
    begin
        // `c.Get()` with no args = the default form: match on the PK values already in the record.
        Seed('GN1', 'NoArgCust', 55.0, 4);
        Assert.AreEqual('NoArgCust',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c."No." := ''GN1''; if c.Get() then exit(c.Name); exit(''<none>''); end;'),
            'Get() with no args loads the row by the current PK value');
    end;

    [Test]
    procedure T10e_ConditionalInsertDuplicateReturnsFalse()
    begin
        // The reported bug: consuming Insert()'s return must SUPPRESS the failure (return false),
        // not throw/roll back. Insert a duplicate PK inside `if c.Insert() then`.
        Seed('DUP', 'Existing', 1.0, 1);
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''DUP''; if c.Insert() then exit(1); exit(0); end;'),
            'conditional Insert() of a duplicate PK returns false without throwing');
    end;

    [Test]
    procedure T10h_ParenlessGetNoArg()
    begin
        // Parenless 0-arg `c.Get` must lower without recursing (regression: lowerer read the
        // member NameId as an arg count and looped LowerExpr<->LowerRecordMethod to overflow).
        Seed('GP0', 'ParenlessGet', 7.0, 1);
        Assert.AreEqual('ParenlessGet',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c."No." := ''GP0''; if c.Get then exit(c.Name); exit(''<none>''); end;'),
            'parenless 0-arg Get lowers cleanly and loads the row by current PK');
    end;

    [Test]
    procedure T10f_StatementGetMissingThrows()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Unconsumed Get of a missing key must THROW (AL addDataError), not return silently.
        RunExpectFail('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Get(''GHOST''); exit(0); end;', Result);
    end;

    [Test]
    procedure T10g_StatementFindFirstEmptyThrows()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Unconsumed FindFirst on an empty set must throw; the consumed `if` form returns false.
        RunExpectFail('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.DeleteAll(); c.FindFirst(); exit(0); end;', Result);
    end;

    // ===== Modify / Delete =====

    [Test]
    procedure T11_ModifyPersists()
    var
        Cust: Record "ALI Test Customer";
        RunOptions: Codeunit "ALI Run Options";
    begin
        // Single-instance options outlive the run that set them: an AI RunALCode call (Simulation)
        // earlier in this session would silently roll the Modify back.
        RunOptions.Reset();
        Seed('M1', 'Before', 0.0, 0);
        RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Get(''M1''); c.Name := ''After''; c.Modify(); exit(0); end;');
        Cust.Get('M1');
        Assert.AreEqual('After', Cust.Name, 'interpreter Modify persisted to the DB');
    end;

    [Test]
    procedure T12_DeleteRemovesRow()
    var
        Cust: Record "ALI Test Customer";
        RunOptions: Codeunit "ALI Run Options";
    begin
        RunOptions.Reset();     // see T11: a leaked Simulation mode would roll the Delete back
        Seed('D1', 'Doomed', 0.0, 0);
        RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Get(''D1''); c.Delete(); exit(0); end;');
        Assert.IsFalse(Cust.Get('D1'), 'interpreter Delete removed the row');
    end;

    // ===== Value-copy semantics (Record := Record) =====

    [Test]
    procedure T13_RecordCopyIsByValue()
    begin
        // Copy c into d, then mutate c; d must keep the copied value (value semantics §7.5).
        Assert.AreEqual('Snapshot',
            RunText('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c.Name := ''Snapshot''; d := c; c.Name := ''Changed''; exit(d.Name); end;'),
            'Record := Record copies by value; later mutation of source does not affect the copy');
    end;

    // ===== Arrays =====

    [Test]
    procedure T14_ArrayWriteReadInteger()
    var
        arr: array[10] of Integer;
        i: Integer;
        Native: Integer;
    begin
        for i := 1 to 10 do
            arr[i] := i * i;
        Native := arr[7];
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var arr: array[10] of Integer; i: Integer; begin for i := 1 to 10 do arr[i] := i * i; exit(arr[7]); end;'),
            'array element write/read matches native');
    end;

    [Test]
    procedure T15_ArraySumMatchesNative()
    var
        arr: array[5] of Integer;
        i: Integer;
        Native: Integer;
        s: Integer;
    begin
        for i := 1 to 5 do
            arr[i] := i * 10;
        for i := 1 to 5 do
            s += arr[i];
        Native := s;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var arr: array[5] of Integer; i: Integer; s: Integer; begin for i := 1 to 5 do arr[i] := i * 10; for i := 1 to 5 do s := s + arr[i]; exit(s); end;'),
            'array fill + sum matches native');
    end;

    [Test]
    procedure T16_ArrayTextElements()
    begin
        Assert.AreEqual('b',
            RunText('procedure P(): Text var a: array[3] of Text; begin a[1] := ''a''; a[2] := ''b''; a[3] := ''c''; exit(a[2]); end;'),
            'text array elements');
    end;

    [Test]
    procedure T17_ArrayIndexOutOfBoundsRaises()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Pipeline.CompileAndRun('procedure P(): Integer var a: array[3] of Integer; i: Integer; begin i := 5; exit(a[i]); end;', Result, Interp);
        Assert.IsFalse(Result.Succeeded(), 'out-of-bounds array index raises a runtime error');
    end;

    [Test]
    procedure T18_ArrayLenConstant()
    begin
        Assert.AreEqual(7,
            RunInt('procedure P(): Integer var a: array[7] of Integer; begin exit(ArrayLen(a)); end;'),
            'ArrayLen returns the declared length');
        Assert.AreEqual(7,
            RunInt('procedure P(): Integer var a: array[7] of Integer; begin exit(ArrayLen(a, 1)); end;'),
            'ArrayLen(a, 1) returns the declared length');
    end;

    [Test]
    procedure T19_CompressArrayCountAndCompaction()
    begin
        // Non-empty at 1,3,5 -> count 3, compacted to positions 1,2,3.
        Assert.AreEqual(3,
            RunInt('procedure P(): Integer var a: array[5] of Text; begin a[1] := ''x''; a[3] := ''y''; a[5] := ''z''; exit(CompressArray(a)); end;'),
            'CompressArray returns the non-empty count');
        Assert.AreEqual('y',
            RunText('procedure P(): Text var a: array[5] of Text; c: Integer; begin a[1] := ''x''; a[3] := ''y''; a[5] := ''z''; c := CompressArray(a); exit(a[2]); end;'),
            'CompressArray compacts non-empty elements to the front');
        Assert.AreEqual('',
            RunText('procedure P(): Text var a: array[5] of Text; c: Integer; begin a[1] := ''x''; a[3] := ''y''; a[5] := ''z''; c := CompressArray(a); exit(a[4]); end;'),
            'CompressArray blanks the trailing tail');
    end;

    [Test]
    procedure T20_CopyArrayRange()
    begin
        // Source = 10,20,30,40,50. CopyArray(d, s, 2, 3) -> d[1..3] = 20,30,40 (sum 90).
        Assert.AreEqual(90,
            RunInt('procedure P(): Integer var s: array[5] of Integer; d: array[5] of Integer; i: Integer; begin for i := 1 to 5 do s[i] := i * 10; CopyArray(d, s, 2, 3); exit(d[1] + d[2] + d[3]); end;'),
            'CopyArray copies a length-bounded range into the destination');
        // Omitted length -> copies from Position to end of source: s[2..5] -> d[1..4], d[4] = 50.
        Assert.AreEqual(50,
            RunInt('procedure P(): Integer var s: array[5] of Integer; d: array[5] of Integer; i: Integer; begin for i := 1 to 5 do s[i] := i * 10; CopyArray(d, s, 2); exit(d[4]); end;'),
            'CopyArray without a length runs from Position to the end of source');
    end;

    // ===== Streams (§19.7 — temp-Blob-backed InStream/OutStream round-trip) =====

    [Test]
    procedure T21_StreamWriteReadRoundTrip()
    begin
        // Write to an OutStream, link an InStream to the same backing, read it back.
        Assert.AreEqual('hello',
            RunText('var o: OutStream; var i: InStream; procedure P(): Text var s: Text; begin o.WriteText(''hello''); i.Link(o); i.ReadText(s); exit(s); end;'),
            'OutStream write -> InStream read round-trip over a temp Blob');
    end;

    [Test]
    procedure T22_StreamLengthReflectsWrite()
    begin
        // Length of the backing after writing 5 chars is at least 5 (encoding may add bytes).
        Assert.IsTrue(
            RunBool('var o: OutStream; procedure P(): Boolean begin o.WriteText(''12345''); exit(o.Length() >= 5); end;'),
            'stream Length reflects written content');
    end;

    [Test]
    procedure T23_InStreamEOSAfterFullRead()
    begin
        Assert.IsTrue(
            RunBool('var o: OutStream; var i: InStream; procedure P(): Boolean var s: Text; begin o.WriteText(''ab''); i.Link(o); i.ReadText(s); exit(i.EOS()); end;'),
            'InStream reports EOS after the content is consumed');
    end;

    [Test]
    procedure T23c_CopyStreamRoundTrip()
    begin
        // CopyStream(dest OutStream, source InStream): write 'abc', read it back through a
        // linked InStream into a SECOND OutStream, then read THAT one back.
        Assert.AreEqual('abc',
            RunText('var o: OutStream; var i: InStream; var o2: OutStream; var i2: InStream; procedure P(): Text var s: Text; begin o.WriteText(''abc''); i.Link(o); CopyStream(o2, i); i2.Link(o2); i2.ReadText(s); exit(s); end;'),
            'CopyStream copies an InStream''s content into an OutStream');
    end;

    [Test]
    procedure T23d_CopyStreamReturnsTrue()
    begin
        Assert.IsTrue(
            RunBool('var o: OutStream; var i: InStream; var o2: OutStream; procedure P(): Boolean begin o.WriteText(''xy''); i.Link(o); exit(CopyStream(o2, i)); end;'),
            'CopyStream returns true on a successful copy');
    end;

    // ===== Native typed Read/Write, WriteText/ReadText lengths, positioning (§19.7) =====

    [Test]
    procedure T23e_WriteReadIntegerRoundTrip()
    begin
        // OutStream.Write(value) / InStream.Read(var target) — native typed binary I/O.
        Assert.AreEqual(42,
            RunInt('var o: OutStream; var i: InStream; procedure P(): Integer var n: Integer; begin o.Write(42); i.Link(o); i.Read(n); exit(n); end;'),
            'Write(Integer) -> Read(Integer) round-trips through the backing');
    end;

    [Test]
    procedure T23f_WriteReadDecimalRoundTrip()
    begin
        Assert.AreEqual(12.5,
            RunDec('var o: OutStream; var i: InStream; procedure P(): Decimal var d: Decimal; begin o.Write(12.5); i.Link(o); i.Read(d); exit(d); end;'),
            'Write/Read resolve the native typed overload from the target type');
    end;

    [Test]
    procedure T23g_ReadReturnsByteCount()
    begin
        // Native Read/Write return the byte count — usable in expression position.
        Assert.IsTrue(
            RunBool('var o: OutStream; var i: InStream; procedure P(): Boolean var n, c: Integer; begin o.Write(7); i.Link(o); c := i.Read(n); exit(c > 0); end;'),
            'Read returns the number of bytes it consumed');
    end;

    [Test]
    procedure T23h_WriteTextWithLength()
    begin
        Assert.AreEqual('abc',
            RunText('var o: OutStream; var i: InStream; procedure P(): Text var s: Text; begin o.WriteText(''abcdef'', 3); i.Link(o); i.ReadText(s); exit(s); end;'),
            'WriteText(value, length) writes only the first `length` characters');
    end;

    [Test]
    procedure T23i_ReadTextWithLength()
    begin
        Assert.AreEqual('ab',
            RunText('var o: OutStream; var i: InStream; procedure P(): Text var s: Text; begin o.WriteText(''abcdef''); i.Link(o); i.ReadText(s, 2); exit(s); end;'),
            'ReadText(text, length) reads at most `length` characters');
    end;

    [Test]
    procedure T23i2_ReadTextReturnsCount()
    begin
        // Native ReadText(var Text) returns the number read — usable in expression position.
        Assert.IsTrue(
            RunBool('var o: OutStream; var i: InStream; procedure P(): Boolean var s: Text; c: Integer; begin o.WriteText(''abc''); i.Link(o); c := i.ReadText(s); exit((c > 0) and (s = ''abc'')); end;'),
            'ReadText fills its var Text argument and returns the count read');
    end;

    [Test]
    procedure T23i3_ReadTextZeroArgsRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Native signature is ReadText(var Text [, Length]) — 0 args is a compile error.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var i: InStream; procedure P() begin i.ReadText(); end;', Diags),
            'ReadText() without a target must not compile');
        AssertDiag(Diags, 'ALI916', 'between 1 and 2');
    end;

    [Test]
    procedure T23i4_ReadWithLength()
    begin
        Assert.AreEqual('ab',
            RunText('var o: OutStream; var i: InStream; procedure P(): Text var s: Text; begin o.Write(''abcdef''); i.Link(o); i.Read(s, 2); exit(s); end;'),
            'Read(var text, length) reads at most `length` bytes');
    end;

    [Test]
    procedure T23j_ResetPositionRereads()
    begin
        Assert.AreEqual('abc',
            RunText('var o: OutStream; var i: InStream; procedure P(): Text var s: Text; begin o.WriteText(''abc''); i.Link(o); i.ReadText(s); i.ResetPosition(); i.ReadText(s); exit(s); end;'),
            'ResetPosition rewinds the InStream so the content can be read again');
    end;

    [Test]
    procedure T23k_PositionGetAndSet()
    begin
        // `i.Position` (get, paren-less) and `i.Position := n` (property set).
        Assert.AreEqual('abc',
            RunText('var o: OutStream; i: InStream; procedure P(): Text var p: Integer; s: Text; begin o.WriteText(''abc''); i.Link(o); p := i.Position; i.ReadText(s); i.Position := p; i.ReadText(s); exit(s); end;'),
            'Position reads back the current offset and can be assigned to rewind');
    end;

    // ===== BLOB fields (Rec.MyBlob.CreateInStream/CreateOutStream/HasValue/Length) =====

    [Test]
    procedure T23b_BlobFieldWriteReadRoundTrip()
    begin
        // Write through the blob's OutStream, read it back through the blob's InStream. The
        // record stays temporary, so nothing touches the database.
        Assert.AreEqual('blob-hello',
            RunText('var c: Record "ALI Test Customer" temporary; procedure P(): Text var o: OutStream; i: InStream; s: Text; begin c.Init(); c."No." := ''C1''; c.Notes.CreateOutStream(o); o.WriteText(''blob-hello''); c.Insert(); c.Notes.CreateInStream(i); i.ReadText(s); exit(s); end;'),
            'Rec.Blob.CreateOutStream write -> Rec.Blob.CreateInStream read round-trip');
    end;

    [Test]
    procedure T23b2_BlobFieldUtf8EncodingRoundTrip()
    begin
        // Optional TextEncoding argument: écrit/relit en UTF-8 — accents survive the round-trip
        // (MSDos default would mangle them).
        Assert.AreEqual('héllo-éà',
            RunText('var c: Record "ALI Test Customer" temporary; procedure P(): Text var o: OutStream; i: InStream; s: Text; begin c.Init(); c."No." := ''C1''; c.Notes.CreateOutStream(o, TextEncoding::UTF8); o.WriteText(''héllo-éà''); c.Insert(); c.Notes.CreateInStream(i, TextEncoding::UTF8); i.ReadText(s); exit(s); end;'),
            'blob CreateOutStream/CreateInStream honor the TextEncoding::UTF8 argument');
    end;

    [Test]
    procedure T23b3_BlobEncodingFromVariable()
    begin
        // TextEncoding as a declared variable — encoding read from a register at run time.
        Assert.AreEqual('héllo-éà',
            RunText('var c: Record "ALI Test Customer" temporary; procedure P(): Text var o: OutStream; i: InStream; e: TextEncoding; s: Text; begin e := TextEncoding::UTF8; c.Init(); c."No." := ''C1''; c.Notes.CreateOutStream(o, e); o.WriteText(''héllo-éà''); c.Insert(); c.Notes.CreateInStream(i, e); i.ReadText(s); exit(s); end;'),
            'blob CreateOutStream/CreateInStream accept a TextEncoding variable');
    end;

    [Test]
    procedure T23c_BlobHasValueAndLength()
    begin
        Assert.IsFalse(
            RunBool('var c: Record "ALI Test Customer" temporary; procedure P(): Boolean begin c.Init(); exit(c.Notes.HasValue()); end;'),
            'an untouched blob field has no value');
        Assert.IsTrue(
            RunBool('var c: Record "ALI Test Customer" temporary; procedure P(): Boolean var o: OutStream; begin c.Init(); c.Notes.CreateOutStream(o); o.WriteText(''12345''); exit(c.Notes.HasValue() and (c.Notes.Length() >= 5)); end;'),
            'HasValue/Length see the content written through the blob OutStream');
    end;

    // ===== Type verification (§19.1 collect-all) =====

    [Test]
    procedure T18_UnknownTableIsCollected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record "No Such Table 99999"; procedure P() begin end;', Diags),
            'unknown table must not compile');
        AssertDiag(Diags, 'ALI959', 'does not exist');
    end;

    [Test]
    procedure T19_UnknownFieldIsReported()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record "ALI Test Customer"; procedure P() begin c.NotAField := 1; end;', Diags),
            'unknown field must not compile');
        AssertDiag(Diags, 'AL0132', 'is not a field');
    end;

    [Test]
    procedure T20_CollectAllBadTypesInOnePass()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // One unit with an unknown table AND a valid array — the unknown is reported, the
        // valid declaration still binds (collect-all §19.1).
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record "Ghost Table"; var a: array[4] of Integer; procedure P() begin a[1] := 1; end;', Diags),
            'compile fails on the bad type');
        AssertDiag(Diags, 'ALI959', 'does not exist');
    end;

    // ===== Native-method sweep (Batches 1-5) =====

    [Test]
    procedure T24_Rename()
    begin
        Seed('R1', 'Renameable', 0.0, 0);
        Assert.AreEqual('R2',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.Get(''R1''); c.Rename(''R2''); exit(c."No."); end;'),
            'Rename changes the primary key and repositions the record');
    end;

    [Test]
    procedure T25_CopyValueSemantics()
    begin
        Assert.AreEqual('Original',
            RunText('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c.Name := ''Original''; d.Copy(c); c.Name := ''Changed''; exit(d.Name); end;'),
            'Copy(Record) snapshots field values by value');
    end;

    [Test]
    procedure T26_TransferFields()
    begin
        Assert.AreEqual('FromSource',
            RunText('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c.Name := ''FromSource''; d.Init(); d.TransferFields(c); exit(d.Name); end;'),
            'TransferFields copies matching fields from src into dest');
    end;

    [Test]
    procedure T27_IsTemporaryReflectsDeclaration()
    begin
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer" temporary; procedure P(): Integer begin if c.IsTemporary() then exit(1); exit(0); end;'),
            'IsTemporary is true for a temporary record var');
    end;

    [Test]
    procedure T28_CountApproxNonNegative()
    begin
        Seed('CA1', 'Approx', 0.0, 0);
        Assert.IsTrue(
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin exit(c.CountApprox()); end;') >= 0,
            'CountApprox returns a non-negative approximate count');
    end;

    [Test]
    procedure T29_SetFilterAndGetFilter()
    begin
        Seed('F1', 'Filtered29', 10.0, 0);
        Seed('F2', 'Filtered29', 20.0, 0);
        // Scope the count by the test's own unique Name so leftover rows from other tests
        // (e.g. other seeded Balance values) can never satisfy the filter.
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''Filtered29''); c.SetFilter(Balance, ''>15''); exit(c.Count()); end;'),
            'SetFilter with a general filter expression narrows the result set');
        Assert.AreEqual('>15',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetFilter(Balance, ''>15''); exit(c.GetFilter(Balance)); end;'),
            'GetFilter reads back the filter text set on the field');
    end;

    [Test]
    procedure T29b_SetFilterWithSubstitutionValues()
    begin
        Seed('S1', 'Subst29', 10.0, 0);
        Seed('S2', 'Subst29', 20.0, 0);
        Seed('S3', 'Subst29', 30.0, 0);
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; var lo: Decimal; var hi: Decimal; procedure P(): Integer begin lo := 10.0; hi := 30.0; c.SetRange(Name, ''Subst29''); c.SetFilter(Balance, ''<>%1&<>%2'', lo, hi); exit(c.Count()); end;'),
            'SetFilter substitutes %1/%2 from the extra value arguments');
        Assert.AreEqual('S1|S3',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetFilter("No.", ''%1|%2'', ''S1'', ''S3''); exit(c.GetFilter("No.")); end;'),
            'GetFilter reads back the substituted filter expression');
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''Subst29''); c.SetFilter("No.", ''%1'', ''''); exit(c.Count()); end;'),
            'An empty substitution value is quoted by the platform, not pasted raw into the filter');
    end;

    [Test]
    procedure T30_CopyFilter()
    begin
        Assert.AreEqual('>100',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetFilter(Balance, ''>100''); c.CopyFilter(Balance, "Credit Limit"); exit(c.GetFilter("Credit Limit")); end;'),
            'CopyFilter copies one field''s filter onto another field');
    end;

    [Test]
    procedure T31_GetRangeMinMax()
    begin
        CleanSeed();
        Seed('RM1', 'Low', 10.0, 0);
        Seed('RM2', 'High', 90.0, 0);
        Assert.AreEqual(10.0,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal begin c.SetFilter(Balance, ''10..90''); exit(c.GetRangeMin(Balance)); end;'),
            'GetRangeMin reads the lower bound of a range filter');
        Assert.AreEqual(90.0,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal begin c.SetFilter(Balance, ''10..90''); exit(c.GetRangeMax(Balance)); end;'),
            'GetRangeMax reads the upper bound of a range filter');
    end;

    [Test]
    procedure T32_ModifyAll()
    begin
        CleanSeed();
        Seed('MA1', 'Before32', 0.0, 0);
        Seed('MA2', 'Before32', 0.0, 0);
        // Scope the post-check to this test's own No. range AND the renamed Name, so stray
        // 'After32'-named rows from elsewhere can't inflate the count.
        Assert.AreEqual(2,
            RunInt('var c: Record "ALI Test Customer"; var n: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''Before32''); c.ModifyAll(Name, ''After32''); n.SetRange(Name, ''After32''); n.SetFilter("No.", ''MA1|MA2''); exit(n.Count()); end;'),
            'ModifyAll rewrites the field on every record in the current filtered set');
    end;

    [Test]
    procedure T32b_ModifyAllRunTrigger()
    begin
        // Native ModifyAll/DeleteAll take an optional trailing RunTrigger Boolean (default false).
        // Regression: the 3-arg ModifyAll / 1-arg DeleteAll forms must compile & run, not raise
        // "ModifyAll only accepts 2, 2 arguments".
        CleanSeed();
        Seed('MA3', 'Before32b', 0.0, 0);
        Seed('MA4', 'Before32b', 0.0, 0);
        Assert.AreEqual(2,
            RunInt('var c: Record "ALI Test Customer"; var n: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''Before32b''); c.ModifyAll(Name, ''After32b'', true); n.SetRange(Name, ''After32b''); n.SetFilter("No.", ''MA3|MA4''); exit(n.Count()); end;'),
            'ModifyAll(field, value, RunTrigger) 3-arg form runs and rewrites every filtered row');
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetFilter("No.", ''MA3|MA4''); c.DeleteAll(true); exit(c.Count()); end;'),
            'DeleteAll(RunTrigger) 1-arg form runs and clears the filtered set');
    end;

    [Test]
    procedure T33_CalcSums()
    begin
        Seed('CS1', 'Sum33', 10.0, 0);
        Seed('CS2', 'Sum33', 25.0, 0);
        Assert.AreEqual(35.0,
            RunDec('var c: Record "ALI Test Customer"; procedure P(): Decimal begin c.SetRange(Name, ''Sum33''); c.CalcSums(Balance); exit(c.Balance); end;'),
            'CalcSums totals the field across the filtered set into the current record');
    end;

    [Test]
    procedure T34_TestFieldEmptyFails()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('var c: Record "ALI Test Customer"; procedure P() begin c.Init(); c.TestField(Name); end;', Result);
    end;

    [Test]
    procedure T35_TestFieldValueMismatchFails()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('var c: Record "ALI Test Customer"; procedure P() begin c.Init(); c.Balance := 10; c.TestField(Balance, 20); end;', Result);
    end;

    [Test]
    procedure T36_FieldNameAndCaption()
    begin
        Assert.AreEqual('Balance',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin exit(c.FieldName(Balance)); end;'),
            'FieldName returns the field''s AL name');
        Assert.AreEqual('Balance',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin exit(c.FieldCaption(Balance)); end;'),
            'FieldCaption returns the field''s caption');
    end;

    [Test]
    procedure T37_TableNameAndCaption()
    begin
        Assert.AreEqual('ALI Test Customer',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin exit(c.TableName()); end;'),
            'TableName returns the table''s AL name');
        Assert.AreEqual('ALI Test Customer',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin exit(c.TableCaption()); end;'),
            'TableCaption returns the table''s caption');
    end;

    [Test]
    procedure T38_SetCurrentKeyAndAscending()
    begin
        Seed('SK1', 'ZetaSK38', 0.0, 0);
        Seed('SK2', 'AlphaSK38', 0.0, 0);
        // Scope to this test's own No. range — without a filter, FindFirst() would sort over
        // the WHOLE table, and any other test's leftover rows could sort before/after these.
        Assert.AreEqual('AlphaSK38',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetFilter("No.", ''SK1|SK2''); c.SetCurrentKey(Name); c.Ascending(true); c.FindFirst(); exit(c.Name); end;'),
            'SetCurrentKey + Ascending(true) orders by Name ascending');
        Assert.AreEqual('ZetaSK38',
            RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetFilter("No.", ''SK1|SK2''); c.SetCurrentKey(Name); c.Ascending(false); c.FindFirst(); exit(c.Name); end;'),
            'Ascending(false) reverses the sort order');
    end;

    [Test]
    procedure T39_MarkAndMarkedOnly()
    begin
        Seed('MK1', 'Marked', 0.0, 0);
        Seed('MK2', 'Marked', 0.0, 0);
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''Marked''); if c.FindSet() then repeat if c."No." = ''MK1'' then c.Mark(true); until c.Next() = 0; c.MarkedOnly(true); exit(c.Count()); end;'),
            'Mark + MarkedOnly(true) restricts iteration to marked records only');
    end;

    [Test]
    procedure T40_ClearMarksResetsMarkedOnlyView()
    begin
        Seed('CM1', 'ClearMe', 0.0, 0);
        Seed('CM2', 'ClearMe', 0.0, 0);
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''ClearMe''); if c.FindSet() then repeat c.Mark(true); until c.Next() = 0; c.ClearMarks(); c.MarkedOnly(true); exit(c.Count()); end;'),
            'ClearMarks removes all marks, so MarkedOnly(true) then sees zero records');
    end;

    [Test]
    procedure T41_GetPositionAndSetPosition()
    begin
        Seed('GP1', 'PosA', 0.0, 0);
        Seed('GP2', 'PosB', 0.0, 0);
        Assert.AreEqual('PosB',
            RunText('var c: Record "ALI Test Customer"; var pos: Text; procedure P(): Text begin c.Get(''GP1''); pos := c.GetPosition(); c.Get(''GP2''); c.SetPosition(pos); exit(c.Name); end;'),
            'GetPosition/SetPosition round-trips a record''s primary-key position');
    end;

    [Test]
    procedure T42_GetViewAndSetView()
    begin
        Seed('GV1', 'ViewA42', 10.0, 0);
        Seed('GV2', 'ViewB42', 20.0, 0);
        // Scope by this test's own No. range — a bare Balance=10.0 filter matches every other
        // test's rows that happen to share that value across the shared, non-isolated table.
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; var v: Text; procedure P(): Integer begin c.SetFilter("No.", ''GV1|GV2''); c.SetRange(Balance, 10.0); v := c.GetView(); d.SetView(v); exit(d.Count()); end;'),
            'GetView/SetView round-trips filters (and sort order) onto another record var');
    end;

    [Test]
    procedure T43_HasFilterAndGetFilters()
    begin
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin if c.HasFilter() then exit(1); exit(0); end;'),
            'HasFilter is false with no filters applied');
        Assert.AreEqual(1,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.SetRange(Name, ''X''); if c.HasFilter() then exit(1); exit(0); end;'),
            'HasFilter is true once a filter is applied');
        Assert.IsTrue(
            StrPos(RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.SetRange(Name, ''X''); exit(c.GetFilters()); end;'), 'Name') > 0,
            'GetFilters describes the active filter(s) as text');
    end;

    // ===== RecordID (own register class; GetRecord/TableNo; Record.RecordId()/Get(RecordID)) =====

    [Test]
    procedure T44_RecordIdTableNoMatchesNative()
    var
        Cust: Record "ALI Test Customer";
    begin
        Seed('RID1', 'IdGuy', 5.0, 0);
        Cust.Get('RID1');
        Assert.AreEqual(Cust.RecordId().TableNo(),
            RunInt('var c: Record "ALI Test Customer"; var id: RecordID; procedure P(): Integer begin c.Get(''RID1''); id := c.RecordId(); exit(id.TableNo()); end;'),
            'RecordID.TableNo() matches the native table number');
    end;

    [Test]
    procedure T45_GetRecordFetchesRecordById()
    begin
        Seed('GR1', 'GetRecTarget', 33.0, 0);
        Assert.AreEqual('GetRecTarget',
            RunText('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; var id: RecordID; procedure P(): Text begin c.Get(''GR1''); id := c.RecordId(); d := id.GetRecord(); exit(d.Name); end;'),
            'idExpr.GetRecord() fetches the record identified by the RecordID into a Record variable');
    end;

    [Test]
    procedure T46_GetByRecordIdOverload()
    begin
        Seed('GB1', 'GetByIdTarget', 44.0, 0);
        Assert.AreEqual('GetByIdTarget',
            RunText('var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; var id: RecordID; procedure P(): Text begin c.Get(''GB1''); id := c.RecordId(); d.Get(id); exit(d.Name); end;'),
            'Rec.Get(RecordID) is a distinct 1-arg overload from the per-field-key Get()');
    end;

    [Test]
    procedure T47_RecordIdEqualityAndInequality()
    begin
        CleanSeed();
        Seed('EQ1', 'EqA', 0.0, 0);
        Seed('EQ2', 'EqB', 0.0, 0);
        Assert.IsTrue(
            RunBool('var c: Record "ALI Test Customer"; var id1, id2: RecordID; procedure P(): Boolean begin c."No." := ''EQ1''; id1 := c.RecordId(); c."No." := ''EQ1''; id2 := c.RecordId(); exit(id1 = id2); end;'),
            'RecordID equality holds for the same record fetched twice');
        Assert.IsTrue(
            RunBool('var c: Record "ALI Test Customer"; var id1, id2: RecordID; procedure P(): Boolean begin c."No." :=''EQ1''; id1 := c.RecordId(); c."No." :=''EQ2''; id2 := c.RecordId(); exit(id1 <> id2); end;'),
            'RecordID inequality (<>) holds across different records');
    end;

    [Test]
    procedure T48_GetByRecordIdThrowsOnMiss()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        Seed('GM1', 'MissTarget', 1.0, 0);
        RunExpectFail(
            'var c: Record "ALI Test Customer"; var d: Record "ALI Test Customer"; var id: RecordID; procedure P() begin c.Get(''GM1''); id := c.RecordId(); c.Delete(); d.Get(id); end;',
            Result);
    end;

    [Test]
    procedure T49_GetRecordOutsideAssignmentIsRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var d: Record "ALI Test Customer"; var id: RecordID; procedure P(): Integer begin exit(id.GetRecord().TableNo()); end;', Diags),
            'GetRecord() outside ''RecVar := idExpr.GetRecord();'' must not compile');
        AssertDiag(Diags, 'ALI971', 'GetRecord');
    end;

    [Test]
    procedure T50_FilterGroupGetSet()
    begin
        // Default group is 0; FilterGroup(n) activates group n and returns the PRIOR group.
        Assert.AreEqual(0,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin exit(c.FilterGroup()); end;'),
            'FilterGroup() returns the default active group 0');
        Assert.AreEqual(2,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin exit(c.FilterGroup(2)); end;'),
            'FilterGroup(2) returns the set group (2)');
        Assert.AreEqual(2,
            RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.FilterGroup(2); exit(c.FilterGroup()); end;'),
            'FilterGroup() reads back the group activated by FilterGroup(2)');
    end;

    // ===== Handle Lifecycle Unification Phase 3 =====
    //
    // Before this phase, Record/InStream/OutStream/TextBuilder variables could ONLY be
    // declared at module (global) scope — a proc-local declaration silently got slot 0 (no
    // allocator ever ran for it) and was non-functional. These tests exercise the NEW
    // capability (proc-local records) directly, plus the recursion-sharing bug it fixes.

    [Test]
    procedure T51_LocalRecordDeclarationWorks()
    begin
        // `var c: Record "..."` inside a proc's OWN local var section — previously silently
        // broken (slot 0, no allocator ran for it); now an ordinary windowed Int handle.
        Assert.AreEqual('Contoso',
            RunText('procedure P(): Text var c: Record "ALI Test Customer"; begin c.Init(); c.Name := ''Contoso''; exit(c.Name); end;'),
            'a record declared as a PROC LOCAL must Init/field-store/field-load correctly');
    end;

    [Test]
    procedure T52_LocalRecordDoesNotLeakAcrossManyCalls()
    begin
        Assert.AreEqual(10000,
            RunInt('var g: Integer; procedure P(): Integer var i: Integer; begin g := 0; for i := 1 to 10000 do Bump(); exit(g); end; ' +
                   'procedure Bump() var c: Record "ALI Test Customer"; begin c.Init(); c."No." := ''X''; g := g + 1; end;'),
            'a record declared local to a proc called many times must not exhaust the handle cap');
    end;

    [Test]
    procedure T53_RecursiveProcLocalRecordDoesNotBleedAcrossDepths()
    begin
        // The bug Phase 3 fixes: each recursion depth must get its OWN record handle (its own
        // filter/current-row state), not share ONE handle across every depth. Recurse 5 deep,
        // each depth sets a DIFFERENT filter value on its OWN local record and reads it back
        // AFTER the deeper recursive call returns — if depths shared one handle, the deeper
        // call's filter would have clobbered the shallower depth's by the time it reads back.
        Assert.AreEqual('12345',
            RunText('procedure P(): Text begin exit(Rec(1)); end; ' +
                    'procedure Rec(n: Integer): Text var c: Record "ALI Test Customer"; s: Text; begin ' +
                    'c.SetFilter("No.", Format(n)); ' +
                    'if n < 5 then s := Rec(n + 1); ' +
                    'exit(c.GetFilter("No.") + s); end;'),
            'each recursion depth''s local record must keep its OWN filter state independent of deeper calls');
    end;

    [Test]
    procedure T54_RecordVarParamRoundTrip()
    begin
        // A record var-param is now a genuine alias (LOAD_IND/STORE_IND, same generic
        // machinery as List/Http* var-params) — previously non-functional (no register class).
        Assert.AreEqual('Fabrikam',
            RunText('procedure P(): Text var c: Record "ALI Test Customer"; begin c.Init(); SetName(c); exit(c.Name); end; ' +
                    'procedure SetName(var r: Record "ALI Test Customer") begin r.Name := ''Fabrikam''; end;'),
            'a record var-param must alias the caller''s record (mutations visible after return)');
    end;

    [Test]
    procedure T56_RecordVarParamWrongTableRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Var-param exact-type match must also cover the record's TABLE (TypeArg), not just
        // its TypeKind — otherwise a "Record Vendor" could alias a "Record Customer" var-param.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors(
                'procedure P() var c: Record "ALI Test Customer"; var o: Record "ALI Test Order Line"; begin Touch(c); Touch(o); end; ' +
                'procedure Touch(var r: Record "ALI Test Customer") begin r.Init(); end;',
                Diags),
            'a var-param record argument of a DIFFERENT table must be rejected');
    end;

    [Test]
    procedure T57_LocalTextBuilderDeclarationWorks()
    begin
        Assert.AreEqual('ab',
            RunText('procedure P(): Text var tb: TextBuilder; begin tb.Append(''a''); tb.Append(''b''); exit(tb.ToText()); end;'),
            'a TextBuilder declared as a PROC LOCAL must Append/ToText correctly');
    end;

    [Test]
    procedure T58_LocalStreamDeclarationWorks()
    begin
        Assert.AreEqual('hi',
            RunText('procedure P(): Text var o: OutStream; i: InStream; s: Text; begin o.WriteText(''hi''); i.Link(o); i.ReadText(s); exit(s); end;'),
            'InStream/OutStream declared as PROC LOCALS must round-trip correctly');
    end;

    [Test]
    procedure T59_ProtectedTableWriteGatedByOption()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
    begin
        // "ALI Rec Runtime" carries a static Permissions grant on every protected table; the
        // AllowProtectedWrite option is what decides per run whether a script may use it.
        // Reads stay legal in both cases — only the write is gated (ALI983).
        RunOptions.Reset();
        Assert.IsFalse(
            Pipeline.CompileAndRun('procedure P() var e: Record "G/L Entry"; begin e.Init(); e."Entry No." := 999999; e.Insert(); end;', Result, Interp),
            'inserting a protected table without AllowProtectedWrite fails the run (ALI983)');

        RunOptions.SetAllowProtectedWrite(true);
        Assert.IsTrue(
            Pipeline.CompileAndRun('procedure P() var e: Record "G/L Entry"; begin e.Init(); e."Entry No." := 999999; e.Insert(); end;', Result, Interp),
            'the same insert succeeds once the host opts in (rolled back by test isolation)');
        RunOptions.Reset();
    end;

    [Test]
    procedure T59b_RecordSecurityFiltersOptIn()
    var
        SecSub: Codeunit "ALI Test Sec Filter Sub";
        RecRt: Codeunit "ALI Rec Runtime";
        Result: Codeunit "ALI Exec Result";
        RunOptions: Codeunit "ALI Run Options";
        Decl: Text;
    begin
        // "TOO Record Security Filters" subscriber limits "ALI Test Customer" to S1. Off by default;
        // once on, no script-side filter manipulation (Reset, FilterGroup(2), Get) can reach S2/S3.
        CleanSeed();
        Seed('S1', 'Allowed', 10, 1);
        Seed('S2', 'Hidden', 20, 2);
        Seed('S3', 'Hidden', 30, 3);
        BindSubscription(SecSub);
        Decl := 'var c: Record "ALI Test Customer"; procedure P(): ';

        RunOptions.Reset();
        Assert.AreEqual(3, RunInt(Decl + 'Integer begin exit(c.Count()); end;'), 'option off: every row');
        Assert.AreEqual('', RecRt.SecurityNotesText(), 'option off: no security note');

        RunOptions.SetApplyRecordSecurity(true);
        Assert.AreEqual(1, RunInt(Decl + 'Integer var n: Integer; begin if c.FindSet() then repeat n := n + 1; until c.Next() = 0; exit(n); end;'),
            'FindSet loop sees only the allowed row');
        Assert.IsTrue(RecRt.SecurityNotesText().Contains('ALI Test Customer'), 'option on: the run reports the restricted table');
        Assert.AreEqual(1, RunInt(Decl + 'Integer begin c.Reset(); exit(c.Count()); end;'), 'Reset does not drop the security filter');
        Assert.AreEqual(1, RunInt(Decl + 'Integer var n: Integer; begin c.FilterGroup(2); c.SetRange("No."); c.FilterGroup(0); if c.FindSet() then repeat n := n + 1; until c.Next() = 0; exit(n); end;'),
            'clearing filter group 2 does not drop the security filter');
        Assert.AreEqual(1, RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.Count()); end;'),
            'RecordRef open is secured too');
        Assert.AreEqual('Allowed', RunText(Decl + 'Text begin if c.Get(''S1'') then exit(c.Name); exit(''<none>''); end;'), 'Get on the allowed row');
        Assert.AreEqual(0, RunInt(Decl + 'Integer begin if c.Get(''S2'') then exit(1); exit(0); end;'), 'conditional Get on a hidden row is a miss');
        RunExpectFail(Decl + 'Integer begin c.Get(''S2''); exit(0); end;', Result);
        Assert.IsTrue(RunBool(Decl + 'Boolean begin c.SetRange("No.", ''S2''); exit(c.IsEmpty()); end;'), 'IsEmpty on a hidden row');
        Assert.AreEqual(10, RunDec(Decl + 'Decimal begin c.CalcSums(Balance); exit(c.Balance); end;'), 'CalcSums totals only the allowed row');

        RunOptions.Reset();
        UnbindSubscription(SecSub);
    end;

    [Test]
    procedure T60_SimulationRollsBackWritesAndIgnoresCommit()
    var
        TestCust: Record "ALI Test Customer";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
        Src: Text;
    begin
        // Simulation must leave NOTHING behind, even when the script commits explicitly: the run
        // executes inside a conditional Codeunit.Run (real rollback scope) whose entry carries
        // CommitBehavior::Ignore, so COMMIT is dropped and the sentinel error undoes the insert.
        // A [TryFunction] would have caught the sentinel but kept the row.
        Src := 'procedure P() var c: Record "ALI Test Customer"; begin c.Init(); c."No." := ''SIM60''; c.Insert(); Commit(); end;';

        RunOptions.Reset();
        RunOptions.SetMode(1);   // Simulation
        Assert.IsTrue(Pipeline.CompileAndRun(Src, Result, Interp), 'a clean Simulation run reports success');
        Assert.IsFalse(TestCust.Get('SIM60'), 'Simulation must roll back the inserted row despite the script COMMIT');

        RunOptions.Reset();      // back to Normal: the same script really writes
        Assert.IsTrue(Pipeline.CompileAndRun(Src, Result, Interp), 'the same script succeeds in Normal mode');
        Assert.IsTrue(TestCust.Get('SIM60'), 'Normal mode persists the row');
        TestCust.Delete();       // the script COMMIT is real here — undo it explicitly
    end;

    // ================================================================================================
    // ALI RecordRef Tests — user-declared `RecordRef` variables (P0 declarability + P1 methods).
    //
    // The design being pinned here is that a RecordRef is NOT a new runtime object: it is the same
    // Int handle into the same "ALI Rec Runtime" bank a Record variable carries, with the table id
    // unknown at bind time. So the tests come in three groups:
    //   * declarability + aliasing — `:=` between two RecordRef variables must SHARE one record
    //     (reference semantics), which falls straight out of the Int register class;
    //   * the RecordRef-only surface — Open (by id AND by name), Close, Number/Name/Caption,
    //     GetTable/SetTable against the native "ALI Test Customer" fixture, and the truthful
    //     use-before-Open failure that the whole handle-0 convention exists to produce;
    //   * the ROUTED surface — filter/FindSet/Count/field-free methods reaching the SAME REC_*
    //     opcodes a Record receiver uses. If routing ever silently stopped working, these are the
    //     tests that catch it, so they are asserted against native record operations (§14).
    // ================================================================================================

    // ===== P0: declarability =====

    [Test]
    procedure T01_DeclaredAsLocalGlobalParamAndReturn()
    var
        Diags: Codeunit "ALI Diag Bag";
        Ok: Boolean;
        ErrText: Text;
    begin
        // Every declaration position at once: module global, proc local, by-value param, var
        // param, return type. All five are the same Int-handle register, so one compile covers
        // the whole of P0.
        Ok := Pipeline.CompileExpectingErrors(
            'var g: RecordRef; ' +
            'procedure Byval(r: RecordRef): Integer begin exit(r.Number()); end; ' +
            'procedure Byref(var r: RecordRef) begin r.Open(Database::"ALI Test Customer"); end; ' +
            'procedure Make(): RecordRef var l: RecordRef; begin l.Open(Database::"ALI Test Customer"); exit(l); end; ' +
            'procedure P(): Integer var l: RecordRef; begin Byref(l); exit(Byval(l)); end;', Diags);
        if Diags.Count() > 0 then
            ErrText := StrSubstNo('%1: %2', Diags.GetCode(1), Diags.GetMessage(1));
        Assert.IsTrue(Ok, StrSubstNo('RecordRef must be declarable everywhere a handle type is: %1', ErrText));
    end;

    [Test]
    procedure T02_FieldRefKeyRefNowDeclarable()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The gate that used to reject these (ALI927) died with the P2/P3 pass — both are real
        // packed-pair Int-handle types now. The "recognized type with no representation"
        // assertion did not disappear, it MOVED DOWN to Notification ("ALI Procedure Tests" T23);
        // the full FieldRef/KeyRef surface lives in "ALI FieldRef Tests".
        Assert.IsTrue(Pipeline.CompileExpectingErrors('procedure P() var f: FieldRef; begin end;', Diags), 'FieldRef is declarable');
        Diags.Reset();
        Assert.IsTrue(Pipeline.CompileExpectingErrors('procedure P() var k: KeyRef; begin end;', Diags), 'KeyRef is declarable');
    end;

    [Test]
    procedure T03_AssignmentAliasesTheSameRecord()
    var
        Cust: Record "ALI Test Customer";
        Result: Codeunit "ALI Exec Result";
    begin
        // `:=` between RecordRef variables is REFERENCE assignment (a plain MOV_I of the handle),
        // which is the semantic difference from `Record := Record` (a value copy). Positive half:
        // the alias sees the same open ref.
        Assert.AreEqual(Database::"ALI Test Customer",
            RunInt('procedure P(): Integer var a: RecordRef; b: RecordRef; begin ' +
                   'a.Open(Database::"ALI Test Customer"); b := a; exit(b.Number()); end;'),
            'the alias must see the ref the original opened');
        // Negative half, and the sharper proof: closing through the ALIAS leaves the ORIGINAL
        // unusable, because there was only ever one bank slot.
        RunExpectFail('procedure P(): Integer var a: RecordRef; b: RecordRef; begin ' +
                      'a.Open(Database::"ALI Test Customer"); b := a; b.Close(); exit(a.Number()); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'ALI937') > 0,
            StrSubstNo('closing the alias must close the original, got: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T04_LocalStartsUnopened()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // A RecordRef local gets NO handle at proc entry (unlike a Record local) — the handle
        // comes from Open(). Using it before that must fail truthfully, not crash on handle 0.
        RunExpectFail('procedure P(): Integer var r: RecordRef; begin exit(r.Number()); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'ALI937') > 0,
            StrSubstNo('expected ALI937 (not open), got: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T05_RoutedMethodOnUnopenedRefAlsoFails()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // The routed half reaches the ordinary REC_* opcodes, which know nothing about handle 0
        // — the lowerer's assert-open guard is what makes them fail truthfully too.
        RunExpectFail('procedure P(): Integer var r: RecordRef; begin exit(r.Count()); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'ALI937') > 0,
            StrSubstNo('expected ALI937 on a routed method, got: %1', Result.ErrorMessage()));
    end;

    // ===== P1: the RecordRef-only surface =====

    [Test]
    procedure T06_OpenByTableIdThenNumber()
    var
        Cust: Record "ALI Test Customer";
    begin
        Assert.AreEqual(Database::"ALI Test Customer",
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.Number()); end;'),
            'Number() must give back the table the ref was opened on');
    end;

    [Test]
    procedure T07_OpenByTableName()
    var
        Cust: Record "ALI Test Customer";
    begin
        // Not a native overload — an ALI extension, since a script that only knows the table by
        // name would otherwise have to hard-code an id (see "ALI Rec Runtime".OpenRefByName).
        Assert.AreEqual(Database::"ALI Test Customer",
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(''ALI Test Customer''); exit(r.Number()); end;'),
            'Open by table name must resolve to the same table id');
    end;

    [Test]
    procedure T08_OpenByUnknownNameFails()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('procedure P(): Integer var r: RecordRef; begin r.Open(''No Such Table At All''); exit(r.Number()); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'No Such Table At All') > 0,
            StrSubstNo('the error must name the table that could not be resolved, got: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T09_NameAndCaption()
    var
        Cust: Record "ALI Test Customer";
    begin
        Assert.AreEqual(Cust.TableName(),
            RunText('procedure P(): Text var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.Name()); end;'),
            'Name() = the table''s object name');
        Assert.AreEqual(Cust.TableCaption(),
            RunText('procedure P(): Text var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.Caption()); end;'),
            'Caption() = the table''s caption');
    end;

    [Test]
    procedure T10_CloseReturnsToUnopenedState()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Close() hands the bank slot back AND zeroes the variable, so a later use is the same
        // truthful ALI937 a never-opened ref gives — not a read of a recycled slot.
        RunExpectFail('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); r.Close(); exit(r.Number()); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'ALI937') > 0,
            StrSubstNo('expected ALI937 after Close(), got: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T11_ReopenOnAnotherTable()
    var
        Line: Record "ALI Test Order Line";
    begin
        Assert.AreEqual(Database::"ALI Test Order Line",
            RunInt('procedure P(): Integer var r: RecordRef; begin ' +
                   'r.Open(Database::"ALI Test Customer"); r.Open(Database::"ALI Test Order Line"); exit(r.Number()); end;'),
            'a second Open must re-point the same variable');
    end;

    [Test]
    procedure T12_GetTableSetTableRoundTrip()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('C-RT', 'RoundTrip', 5, 3);
        // Record -> RecordRef -> Record. Both sides are handles in the one bank, so this is a
        // handle-to-handle copy; the value has to survive it intact.
        Assert.AreEqual(3,
            RunInt('procedure P(): Integer var c: Record "ALI Test Customer"; d: Record "ALI Test Customer"; r: RecordRef; begin ' +
                   'c.Get(''C-RT''); r.GetTable(c); r.SetTable(d); exit(d."Post Count"); end;'),
            'GetTable/SetTable must round-trip the row');
        Assert.AreEqual('RoundTrip',
            RunText('procedure P(): Text var c: Record "ALI Test Customer"; d: Record "ALI Test Customer"; r: RecordRef; begin ' +
                    'c.Get(''C-RT''); r.GetTable(c); r.SetTable(d); exit(d.Name); end;'),
            'text fields survive the round trip too');
    end;

    [Test]
    procedure T13_GetTableAdoptsTheRecordsTable()
    var
        Cust: Record "ALI Test Customer";
    begin
        // GetTable on a never-opened ref opens it on the record's table — that is what makes
        // `r.GetTable(c)` usable as the FIRST thing a script does with a RecordRef.
        Assert.AreEqual(Database::"ALI Test Customer",
            RunInt('procedure P(): Integer var c: Record "ALI Test Customer"; r: RecordRef; begin ' +
                   'c.Init(); r.GetTable(c); exit(r.Number()); end;'),
            'GetTable must open the ref on the record''s table');
    end;

    [Test]
    procedure T14_SetTableRejectsAnotherTable()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        CleanSeed();
        Seed('C-MM', 'Mismatch', 1, 1);
        // The table check cannot happen at bind time (a RecordRef's table is a run-time fact),
        // so it happens here — and it has to be a truthful error, not a silent field-by-field
        // copy into the wrong table.
        RunExpectFail('procedure P(): Integer var c: Record "ALI Test Customer"; l: Record "ALI Test Order Line"; r: RecordRef; begin ' +
                      'c.Get(''C-MM''); r.GetTable(c); r.SetTable(l); exit(1); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'SetTable') > 0,
            StrSubstNo('the mismatch error must name SetTable, got: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T15_DuplicateIsASecondIndependentCursor()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        Seed('C3', 'Gamma', 30, 3);
        // Duplicate() copies content AND filters into a SECOND handle: moving one must not move
        // the other (contrast T03's `:=`, which shares one handle).
        Assert.AreEqual(3,
            RunInt('procedure P(): Integer var a: RecordRef; b: RecordRef; n: Integer; begin ' +
                   'a.Open(Database::"ALI Test Customer"); b := a.Duplicate(); ' +
                   'a.FindSet(); n := b.Count(); exit(n); end;'),
            'the duplicate sees the same rows through its own cursor');
    end;

    [Test]
    procedure T16_FieldExistByNumberAndByName()
    begin
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.FieldExist(3)); end;'),
            'FieldExist by number');
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.FieldExist(''Balance'')); end;'),
            'FieldExist by name (the two overloads share one opcode id and branch on the operand class)');
        Assert.IsFalse(
            RunBool('procedure P(): Boolean var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.FieldExist(''Nope'')); end;'),
            'FieldExist(name) must be false for a field that is not there');
    end;

    [Test]
    procedure T17_SystemFieldNumbers()
    var
        NativeRef: RecordRef;
    begin
        // The exact numbers are the platform's, so this is a native comparison (§14) rather than
        // a threshold. It used to assert `> 2000000000`, which is wrong by one on the very first
        // system field: SystemIdNo IS 2000000000 (the block STARTS there — SystemCreatedAt is
        // 2000000001 and so on), so the strict inequality could never hold for it however
        // correct the runtime was. Reading the number off a native RecordRef cannot go stale if
        // the platform ever re-numbers the block.
        NativeRef.Open(Database::"ALI Test Customer");
        Assert.AreEqual(NativeRef.SystemIdNo(),
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.SystemIdNo()); end;'),
            'SystemIdNo returns the platform''s SystemId field number');
        Assert.AreEqual(NativeRef.SystemModifiedByNo(),
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.SystemModifiedByNo()); end;'),
            'SystemModifiedByNo returns the platform''s SystemModifiedBy field number');
        NativeRef.Close();
    end;

    // ===== P1: the ROUTED surface (existing REC_* opcodes, RecordRef receiver) =====

    [Test]
    procedure T18_CountThroughARecordRef()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        // Native comparison (§14): the routed REC_COUNT must return exactly what the platform does.
        Assert.AreEqual(Cust.Count(),
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.Count()); end;'),
            'Count() routes to REC_COUNT with the RecordRef''s handle');
    end;

    [Test]
    procedure T19_FilterThenFindSetAndIterate()
    var
        Cust: Record "ALI Test Customer";
        Native: Integer;
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        Seed('C3', 'Gamma', 30, 3);
        Cust.SetFilter("No.", 'C2|C3');
        Native := Cust.Count();
        // The filter is applied through a RECORD and handed to the ref with GetTable, which
        // carries filters. FindSet/Next/Count from there are all routed opcodes. (Since P4 the
        // ref could filter itself — `r.SetFilter(1, ''C2|C3'')` — but this test exists to pin the
        // GetTable filter HAND-OVER, so it deliberately keeps using it.)
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var c: Record "ALI Test Customer"; r: RecordRef; n: Integer; begin ' +
                   'c.SetFilter("No.", ''C2|C3''); r.GetTable(c); ' +
                   'if r.FindSet() then repeat n := n + 1; until r.Next() = 0; exit(n); end;'),
            'filter + FindSet + Next iteration all route through the RecordRef handle');
    end;

    [Test]
    procedure T20_RoutedIsTemporaryFieldCountKeyCount()
    var
        NativeRef: RecordRef;
    begin
        // FieldCount lives on RecordRef, not on Record, so the native comparison uses a native
        // RecordRef here — which is exactly the object the interpreter is holding underneath.
        NativeRef.Open(Database::"ALI Test Customer");
        Assert.AreEqual(NativeRef.FieldCount(),
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.FieldCount()); end;'),
            'FieldCount routes to REC_FIELDCOUNT');
        Assert.AreEqual(NativeRef.KeyCount(),
            RunInt('procedure P(): Integer var r: RecordRef; begin r.Open(Database::"ALI Test Customer"); exit(r.KeyCount()); end;'),
            'KeyCount routes to REC_KEYCOUNT');
        NativeRef.Close();
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var r: RecordRef; begin r.Open(Database::"ALI Test Customer", true); exit(r.IsTemporary()); end;'),
            'the Temporary flag of Open reaches the native RecordRef, and IsTemporary routes back');
    end;

    [Test]
    procedure T21_GetViewSetViewThroughARecordRef()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        // SetView takes a Text, no field numbers — so it routes, and a view built on one ref
        // filters another.
        Assert.AreEqual(1,
            RunInt('procedure P(): Integer var c: Record "ALI Test Customer"; r: RecordRef; begin ' +
                   'c.SetRange("No.", ''C1''); r.Open(Database::"ALI Test Customer"); r.SetView(c.GetView()); exit(r.Count()); end;'),
            'SetView routes to REC_SETVIEW');
    end;

    // ===== Truthful deferrals =====

    [Test]
    procedure T22_FieldReturningMembersNowBind()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Field()/FieldIndex()/KeyIndex() were the P1 pass's 🔶 deferral; P2/P3 implemented them
        // (ids 15/16/17 on the same REF_METHOD opcode). Behaviour is covered by
        // "ALI FieldRef Tests" — this only pins that they are no longer refused.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors(
                'procedure P() var r: RecordRef; f: FieldRef; k: KeyRef; begin r.Open(Database::"ALI Test Customer"); f := r.Field(1); f := r.FieldIndex(1); k := r.KeyIndex(1); end;', Diags),
            'Field/FieldIndex/KeyIndex must bind now');
    end;

    [Test]
    procedure T23_FieldNumberMethodsBindWithRuntimeFieldNumbers()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // *** This test asserted the OPPOSITE before phase P4 (SetLoadFields / SetRange on a
        // RecordRef = ALI989, "recognized but not implemented"). P4 implemented them, so the old
        // assertion became factually wrong, not merely stale — see REF_METHOD ids 18-39. ***
        //
        // What replaces it: the field number is an ordinary Integer-valued EXPRESSION, so it must
        // bind from a variable and from a computed expression, not only from a literal. A literal
        // would let a const-folding path pass a test the dynamic path fails.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; f: Integer; begin r.Open(18); f := 1; r.SetLoadFields(f, f + 1); end;', Diags),
            'SetLoadFields takes run-time field numbers on a RecordRef');
        Diags.Reset();
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; f: Integer; begin r.Open(18); f := 1; r.SetRange(f, 2); end;', Diags),
            'SetRange takes a run-time field number on a RecordRef');
        Diags.Reset();
        // ... and a non-Integer field number is still an error, i.e. widening the surface did not
        // turn the first argument into "anything goes".
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.SetRange(''one'', 2); end;', Diags),
            'a Text field number must not bind');
    end;

    [Test]
    procedure T24_NoStaticFieldAccessOnARecordRef()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // There is no table id at bind time, so there is no field to resolve — `r.Name` is the
        // Name() METHOD, and a genuine field name is simply not a member.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P(): Integer var r: RecordRef; begin r.Open(18); exit(r."Post Count"); end;', Diags),
            'a field name on a RecordRef must not bind');
    end;

    // ================================================================================================
    // ALI RecordRef P4 Tests — the field-NUMBER surface of a user-declared `RecordRef`.
    //
    // Phase P4 closed the last 🔶 arm of the RecordRef family: the 22 methods that take field
    // numbers (SetRange, SetFilter, GetFilter, CopyFilter, GetRangeMin/Max, Validate, ModifyAll,
    // CalcFields, CalcSums, TestField, FieldError, FieldName, FieldCaption, SetAscending,
    // GetAscending, SetCurrentKey, SetAutoCalcFields, SetLoadFields, AddLoadFields, LoadFields,
    // AreFieldsLoaded). They used to answer ALI989 on a RecordRef receiver.
    //
    // WHAT WAS ACTUALLY WRONG, and therefore what these tests protect: nothing in the record engine.
    // Every runtime procedure involved ("ALI Rec Runtime".SetRangeEq, ModifyAllField,
    // SetLoadFieldsRec, ...) has always taken its field number as a plain Integer parameter. The
    // blocker was the ENCODING: on a Record receiver the number is resolved from a field NAME at bind
    // time and burned into the instruction, and a RecordRef supplies it as a run-time Integer that
    // the encoding had nowhere to put. P4 put them on REF_METHOD ids 18-39, whose operand pool is
    // already the live-register kind, and left the Record path byte-for-byte untouched.
    //
    // So EVERY test below feeds the field number as a genuinely RUN-TIME value — a variable, an
    // expression computed from table metadata, or a FieldExist-guarded lookup. A literal would let a
    // constant-folding path pass a test the dynamic path fails, which is exactly the bug class this
    // suite exists to catch.
    //
    // Fixture: "ALI Test Customer" — 1 "No." Code[20], 2 Name Text[100], 3 Balance Decimal,
    // 4 "Credit Limit" Decimal, 5 Blocked Boolean, 6 "Post Count" Integer, 7 "Registration Date"
    // Date, 8 Status Option, 9 Category Enum, 10 Notes Blob; keys PK("No.") and Name(Name).
    // ================================================================================================

    local procedure RunExpectFailQuiet(Source: Text)
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsFalse(Result.Succeeded(), 'Succeeded must be false on a raised error');
    end;
    // The prologue every behavioural test shares. `fNo`/`fNo2` are the RUN-TIME field-number
    // carriers — declared and assigned in the script, never inlined as literals, because that is
    // the whole point of the phase.
    local procedure Open(): Text
    begin
        exit('r.Open(Database::"ALI Test Customer"); ');
    end;

    // ===== Filters =====

    [Test]
    procedure T01_SetRangeAllThreeArities()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        Seed('C3', 'Gamma', 30, 3);
        // 2 args = equality.
        Assert.AreEqual(1, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 1; r.SetRange(fNo, ''C2''); exit(r.Count()); end;'),
            'SetRange(fieldNo, value) filters on the run-time field number');
        // 3 args = from..to.
        Assert.AreEqual(2, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; r.SetRange(fNo, 20, 30); exit(r.Count()); end;'),
            'SetRange(fieldNo, from, to) is the range form');
        // 1 arg = clear that field's filter.
        Assert.AreEqual(3, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 1; r.SetRange(fNo, ''C2''); r.SetRange(fNo); exit(r.Count()); end;'),
            'SetRange(fieldNo) clears the filter again');
    end;

    [Test]
    procedure T02_SetFilterPlainAndWithSubstitutions()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Seed('C2', 'Beta', 20, 2);
        Seed('C3', 'Gamma', 30, 3);
        Assert.AreEqual(2, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 1; r.SetFilter(fNo, ''C2|C3''); exit(r.Count()); end;'),
            'SetFilter(fieldNo, filterText)');
        // The %1-substitution form: the values stay Variants so the platform applies its own
        // filter-safe formatting, exactly as on the Record path.
        Assert.AreEqual(2, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; lo: Integer; hi: Integer; begin ' + Open() +
            'fNo := 3; lo := 20; hi := 40; r.SetFilter(fNo, ''%1..%2'', lo, hi); exit(r.Count()); end;'),
            'SetFilter with %1/%2 substitution args');
    end;

    [Test]
    procedure T03_GetFilterReadsItBack()
    begin
        Assert.AreEqual('>100', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; r.SetFilter(fNo, ''>100''); exit(r.GetFilter(fNo)); end;'),
            'GetFilter(fieldNo) -> Text');
    end;

    [Test]
    procedure T04_CopyFilterBetweenTwoRuntimeFieldNumbers()
    begin
        // The only method in the block with TWO field-number operands — a mis-ordered pool would
        // copy the filter the wrong way and this is what would catch it.
        Assert.AreEqual('>100', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; fNo2: Integer; begin ' + Open() +
            'fNo := 3; fNo2 := 4; r.SetFilter(fNo, ''>100''); r.CopyFilter(fNo, fNo2); exit(r.GetFilter(fNo2)); end;'),
            'CopyFilter(from, to) with both numbers live');
        Assert.AreEqual('', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; fNo2: Integer; begin ' + Open() +
            'fNo := 3; fNo2 := 4; r.SetFilter(fNo, ''>100''); r.CopyFilter(fNo, fNo2); exit(r.GetFilter(1)); end;'),
            'and it must not smear onto an unrelated field');
    end;

    [Test]
    procedure T05_GetRangeMinMaxAreVariants()
    begin
        // NOT the field's own type as on a Record: the field is only known at run time, so the
        // honest static type is Variant. Format() is the ordinary Variant consumer.
        Assert.AreEqual('10', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; r.SetFilter(fNo, ''10..90''); exit(Format(r.GetRangeMin(fNo))); end;'),
            'GetRangeMin(fieldNo) -> Variant');
        Assert.AreEqual('90', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; r.SetFilter(fNo, ''10..90''); exit(Format(r.GetRangeMax(fNo))); end;'),
            'GetRangeMax(fieldNo) -> Variant');
        // Unboxing into a typed target is the normal Variant path — pinned because the packing
        // had to give up its OutCls digit to carry register class 11 at all.
        Assert.AreEqual(10.0, RunDec(
            'procedure P(): Decimal var r: RecordRef; fNo: Integer; v: Variant; d: Decimal; begin ' + Open() +
            'fNo := 3; r.SetFilter(fNo, ''10..90''); v := r.GetRangeMin(fNo); d := v; exit(d); end;'),
            'the Variant result unboxes into a Decimal');
    end;

    // ===== Writes =====

    [Test]
    procedure T06_ValidateWritesThroughTheFieldsOnValidate()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        Assert.AreEqual('Zed', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 2; r.Validate(fNo, ''Zed''); exit(Format(r.Field(fNo).Value())); end;'),
            'Validate(fieldNo, value) assigns through the field');
    end;

    [Test]
    procedure T07_ModifyAllRewritesTheFilteredSet()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('M1', 'Alpha', 10, 1);
        Seed('M2', 'Alpha', 20, 2);
        Seed('M3', 'Other', 30, 3);
        RunInt('procedure P(): Integer var r: RecordRef; fNo: Integer; vNo: Integer; begin ' + Open() +
            'fNo := 2; vNo := 6; r.SetRange(fNo, ''Alpha''); r.ModifyAll(vNo, 99); exit(1); end;');
        Cust.Get('M1');
        Assert.AreEqual(99, Cust."Post Count", 'ModifyAll must rewrite the first filtered row');
        Cust.Get('M2');
        Assert.AreEqual(99, Cust."Post Count", 'and the second');
        Cust.Get('M3');
        Assert.AreEqual(3, Cust."Post Count", 'and leave rows outside the filter alone');
    end;

    [Test]
    procedure T08_ModifyAllBothCallShapesAndTheTriggerFlag()
    begin
        CleanSeed();
        Seed('M1', 'Alpha', 10, 1);
        // The "result consumed" flag is the ONE operand that cannot ride in the pool — it is a
        // property of the call site, so it travels in the freed OutCls digit of the packing (see
        // "ALI Opcode"::REF_METHOD). Both shapes must therefore run: statement form (Flags 0) and
        // consumed form (Flags 1). A mis-decoded digit shows up as a wrong result class here.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 6; exit(r.ModifyAll(fNo, 7)); end;'),
            'the consumed form returns true when every row modified');
        Assert.AreEqual(7, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 6; r.ModifyAll(fNo, 7, true); r.FindFirst(); exit(r.Field(fNo).Value()); end;'),
            'the 3-arg RunTrigger form runs as a statement and writes');
    end;

    [Test]
    procedure T09_ModifyAllOnATemporaryRefNeverTouchesTheTable()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('T1', 'Alpha', 10, 1);
        // Regression guard for a real defect: ModifyAll iterates a SECOND cursor it opens itself,
        // and if that cursor is opened non-temporary while the receiver is temporary, a bulk write
        // against an in-memory dataset lands in the DATABASE table instead. The runtime now
        // propagates IsTemporary() into the internal Open; this pins it, because nothing else did.
        RunInt('procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' +
            'r.Open(Database::"ALI Test Customer", true); fNo := 6; r.Init(); ' +
            'r.Field(1).Value := ''T1''; r.Field(fNo).Value := 5; r.Insert(); ' +
            'r.ModifyAll(fNo, 777); exit(1); end;');
        Cust.Get('T1');
        Assert.AreEqual(1, Cust."Post Count", 'a ModifyAll on a TEMPORARY RecordRef must not reach the real table');
    end;

    // ===== Calculated fields =====

    [Test]
    procedure T10_CalcSumsTotalsTheFilteredSet()
    begin
        CleanSeed();
        Seed('S1', 'Sum10', 10, 1);
        Seed('S2', 'Sum10', 20, 2);
        Seed('S3', 'Other', 40, 3);
        Assert.AreEqual(30.0, RunDec(
            'procedure P(): Decimal var r: RecordRef; fNo: Integer; vNo: Integer; begin ' + Open() +
            'fNo := 2; vNo := 3; r.SetRange(fNo, ''Sum10''); r.CalcSums(vNo); exit(r.Field(vNo).Value()); end;'),
            'CalcSums(fieldNo) totals the field across the filtered set');
    end;

    [Test]
    procedure T11_CalcFieldsBindsWithRuntimeFieldNumbers()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Compile-only, deliberately: the fixture table declares no FlowField, so a behavioural
        // CalcFields would be asserting the platform's "not a FlowField" error rather than the
        // encoding. Same reason the FieldRef suite has no CalcField test. What matters here is
        // that the variadic field-no LIST form binds with live values and a bind-time COUNT.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors(
                'procedure P() var r: RecordRef; a: Integer; b: Integer; begin r.Open(18); a := 3; b := 4; r.CalcFields(a, b); end;', Diags),
            'CalcFields takes a list of run-time field numbers');
    end;

    // ===== Errors =====

    [Test]
    procedure T12_TestFieldEmptyAndMismatchRaise()
    begin
        CleanSeed();
        Seed('C1', '', 10, 1);
        RunExpectFailQuiet('procedure P() var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 2; r.TestField(fNo); end;');
        RunExpectFailQuiet('procedure P() var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 3; r.TestField(fNo, 999); end;');
        // ... and the passing case must NOT raise (a TestField that always threw would let the
        // two lines above pass for the wrong reason).
        Assert.AreEqual(1, RunInt(
            'procedure P(): Integer var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 3; r.TestField(fNo, 10); exit(1); end;'),
            'TestField on a matching value must not raise');
    end;

    [Test]
    procedure T13_FieldErrorRaisesWithAndWithoutText()
    begin
        CleanSeed();
        Seed('C1', 'Alpha', 10, 1);
        RunExpectFailQuiet('procedure P() var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 2; r.FieldError(fNo); end;');
        RunExpectFailQuiet('procedure P() var r: RecordRef; fNo: Integer; begin ' + Open() +
            'r.FindFirst(); fNo := 2; r.FieldError(fNo, ''is wrong''); end;');
    end;

    // ===== Metadata =====

    [Test]
    procedure T14_FieldNameAndFieldCaption()
    begin
        Assert.AreEqual('Balance', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; exit(r.FieldName(fNo)); end;'),
            'FieldName(fieldNo) -> Text');
        Assert.AreEqual('Balance', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 3; exit(r.FieldCaption(fNo)); end;'),
            'FieldCaption(fieldNo) -> Text');
    end;

    [Test]
    procedure T15_FieldNumberFromAComputedExpression()
    begin
        // The field number is derived from TABLE METADATA at run time, so no constant-folding or
        // constant-propagation pass can turn it back into a literal — which is the failure mode
        // a literal-only test would hide. FieldCount() is 10 on the fixture, so 10 - 8 = 2 (Name).
        Assert.AreEqual('Balance', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'exit(r.FieldName(r.FieldCount() - 8)); end;'),
            'a computed field number must reach the instruction as a live register');
    end;

    [Test]
    procedure T16_FieldNumberFromAFieldExistGuardedLookup()
    begin
        // The idiomatic shape in real dynamic code: probe, then use. Both branches must compile
        // and only the taken one must run.
        Assert.AreEqual('Name', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 0; if r.FieldExist(2) then fNo := 2; if r.FieldExist(9999) then fNo := 9999; ' +
            'exit(r.FieldName(fNo)); end;'),
            'a FieldExist-guarded field number');
        // The negative half: a field number that does not exist must fail truthfully at RUN time
        // (there is no table id at bind time to reject it earlier).
        RunExpectFailQuiet('procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 9999; exit(r.FieldName(fNo)); end;');
    end;

    // ===== Sorting =====

    [Test]
    procedure T17_SetCurrentKeyPicksTheKeyByFieldNumber()
    begin
        CleanSeed();
        Seed('K1', 'Zeta', 10, 1);
        Seed('K2', 'Alpha', 20, 2);
        // Field 2 is the Name key. Sorting by it puts 'Alpha' (No. K2) first, whereas the PK
        // would put K1 first — so the assertion cannot pass with the key left unchanged.
        Assert.AreEqual('K2', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 2; r.SetCurrentKey(fNo); r.FindFirst(); exit(Format(r.Field(1).Value())); end;'),
            'SetCurrentKey(fieldNo) selects the declared key starting with that field');
    end;

    [Test]
    procedure T18_SetAscendingAndGetAscending()
    begin
        CleanSeed();
        Seed('K1', 'Zeta', 10, 1);
        Seed('K2', 'Alpha', 20, 2);
        Assert.IsFalse(RunBool(
            'procedure P(): Boolean var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 2; r.SetCurrentKey(fNo); r.SetAscending(fNo, false); exit(r.GetAscending(fNo)); end;'),
            'SetAscending(fieldNo, false) then GetAscending(fieldNo) reads back descending');
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 2; r.SetCurrentKey(fNo); r.SetAscending(fNo, false); r.SetAscending(fNo, true); exit(r.GetAscending(fNo)); end;'),
            'and back to ascending');
        // Descending really reorders the set, not just the view text.
        Assert.AreEqual('K1', RunText(
            'procedure P(): Text var r: RecordRef; fNo: Integer; begin ' + Open() +
            'fNo := 2; r.SetCurrentKey(fNo); r.SetAscending(fNo, false); r.FindFirst(); exit(Format(r.Field(1).Value())); end;'),
            'descending on the Name key puts Zeta (K1) first');
    end;

    // ===== Load sets =====

    [Test]
    procedure T19_LoadFieldFamilyWithRuntimeFieldNumbers()
    begin
        CleanSeed();
        Seed('L1', 'Alpha', 10, 1);
        // The COUNT of the list is bind-time-known even when the values are not, so ArgCount stays
        // in the instruction and only the values are live. Two live values here, so a pool read
        // that was off by one would show up.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; b: Integer; begin ' + Open() +
            'a := 2; b := 3; r.SetLoadFields(a, b); r.FindFirst(); exit(r.AreFieldsLoaded(a, b)); end;'),
            'SetLoadFields then AreFieldsLoaded, both with live field numbers');
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; b: Integer; begin ' + Open() +
            'a := 2; b := 6; r.SetLoadFields(a); r.AddLoadFields(b); r.FindFirst(); exit(r.AreFieldsLoaded(a, b)); end;'),
            'AddLoadFields extends the set');
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; b: Integer; begin ' + Open() +
            'a := 2; b := 6; r.SetLoadFields(a); r.FindFirst(); exit(r.LoadFields(b)); end;'),
            'LoadFields pulls a field that was left out of the load set');
        // The documented 0-arg reset form: no operands at all, so ArgCount 0 must not make the
        // interpreter read a pool entry that was never pushed.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; begin ' + Open() +
            'a := 2; r.SetLoadFields(a); exit(r.SetLoadFields()); end;'),
            'SetLoadFields() with no arguments is the reset form');
    end;

    [Test]
    procedure T20_SetAutoCalcFieldsWithRuntimeFieldNumbers()
    var
        NativeRef: RecordRef;
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // REPLACE semantics, so it shares the Record path's spelled-out arity ladder — the arity
        // is what has to survive the live-register conversion, and 0/1/2 args cover its three
        // distinct shapes. The fixture table has no FlowField, so the RETURN value is whatever
        // the platform makes of that; asserted against the SAME native call (§14) instead of a
        // hard-coded true, because it is the arity plumbing that is under test here, not the
        // platform's verdict on the field class.
        NativeRef.Open(Database::"ALI Test Customer");
        Assert.AreEqual(NativeRef.SetAutoCalcFields(3), RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; begin ' + Open() +
            'a := 3; exit(r.SetAutoCalcFields(a)); end;'),
            'SetAutoCalcFields(fieldNo)');
        Assert.AreEqual(NativeRef.SetAutoCalcFields(3, 4), RunBool(
            'procedure P(): Boolean var r: RecordRef; a: Integer; b: Integer; begin ' + Open() +
            'a := 3; b := 4; exit(r.SetAutoCalcFields(a, b)); end;'),
            'SetAutoCalcFields(fieldNo, fieldNo)');
        Assert.AreEqual(NativeRef.SetAutoCalcFields(), RunBool(
            'procedure P(): Boolean var r: RecordRef; begin ' + Open() +
            'exit(r.SetAutoCalcFields()); end;'),
            'SetAutoCalcFields() reset form');
        NativeRef.Close();
    end;

    // ===== Scope boundaries =====

    [Test]
    procedure T21_TheRecordPathStillTakesFieldNAMES()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The point of the whole encoding split: a Record receiver resolves a field NAME at bind
        // time and must keep doing so (that is the fast path, and it is what the Record suite
        // runs on). A field NUMBER on a Record receiver is still an error, and a field NAME on a
        // RecordRef receiver is still an error — there is no table id to resolve it against.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record "ALI Test Customer"; procedure P() begin c.SetRange(3, 10); end;', Diags),
            'a bare field NUMBER on a Record receiver must not bind');
        Diags.Reset();
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.SetRange(Balance, 10); end;', Diags),
            'a field NAME on a RecordRef receiver must not bind');
    end;

    [Test]
    procedure T22_UseBeforeOpenStillFailsTruthfully()
    begin
        // The P4 block sits BELOW the family's single assert-open guard, so the handle-0 contract
        // must still hold for it: ALI937, not an array-index-0 crash inside the runtime.
        RunExpectFailQuiet('procedure P() var r: RecordRef; fNo: Integer; begin fNo := 1; r.SetRange(fNo, ''X''); end;');
    end;

    [Test]
    procedure T23_WrongArityIsNamedNotSwallowed()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The ALI989 arm of AddRecordRefUnsupportedDiag is gone, so an unusable call must now come
        // out as an arity/unknown-member diagnostic rather than falling through to another
        // family's dispatch (which is what a missed ladder rung looks like).
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.CopyFilter(1); end;', Diags),
            'CopyFilter needs two arguments');
        Diags.Reset();
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.GetFilter(); end;', Diags),
            'GetFilter needs one argument');
    end;

    // ================================================================================================
    // ALI FieldRef Tests — user-declared `FieldRef` and `KeyRef` variables (P2 + P3).
    //
    // The design being pinned here is the PACKED PAIR: a FieldRef value is not a native FieldRef
    // stored in a bank, it is one Integer holding (record handle, interned field-number slot), and
    // every operation re-materializes `RecRefs[h].Field(n)` on demand. See "ALI Opcode"::FLD_METHOD
    // for the full rationale. Four consequences are what these tests exist to protect:
    //
    //   1. WRITE-THROUGH. The whole representation stands on one AL behaviour: the native FieldRef
    //      that `RecordRef.Field(n)` returns writes into the row the RecordRef holds — it is not a
    //      detached copy. T05/T06 are that proof, made permanent: write a field through a FieldRef,
    //      read it back through the RECORD (and through the database after Modify). If AL ever
    //      changed here, or if somebody "optimized" the runtime into caching a native FieldRef, T05
    //      is the test that goes red first. Treat it as load-bearing, not as coverage.
    //   2. ALIASING. `f2 := f1` copies the pair, so both names denote the same field of the same
    //      row — native FieldRef assignment is reference-like, and the Int register class gives
    //      that for free (T03).
    //   3. NO LIFECYCLE. `R.Field(1)` is a pure function of (handle, number): calling it in a loop
    //      returns the identical integer and allocates nothing (T04). That is the property an
    //      array-of-FieldRef bank could not have.
    //   4. FILTERS/VALIDATE/TESTFIELD work here through a route of their own: a FieldRef needs no
    //      field-number encoding at all, because it carries its own number inside the handle. Since
    //      phase P4 the same methods also work on a RecordRef receiver (REF_METHOD ids 18-39, field
    //      number read live from the operand pool) — two independent routes, neither desugaring into
    //      the other, which is what T20 now pins.
    //   5. CHAINING. `RRef.Field(3).Value` / `... := x` / `K.FieldIndex(1).Name()` — a member call on
    //      the RESULT of a call, in both rvalue and lvalue position. Free under the packed-pair
    //      design (an intermediate handle is a plain Int in a temp register: no allocation, nothing
    //      to free), but it needed the binder's receiver predicates to stop being NameExpr-only.
    //      T30-T36.
    //
    // Fixture: "ALI Test Customer" (Code/Text/Decimal/Boolean/Integer/Date/Option/Enum/Blob fields,
    // two keys), so the metadata surface can be asserted against real, stable values.
    // ================================================================================================

    local procedure RunExpectFailMsg(Source: Text; Fragment: Text)
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsTrue(StrPos(Result.ErrorMessage(), Fragment) > 0,
            StrSubstNo('expected error containing <%1>, got <%2>', Fragment, Result.ErrorMessage()));
    end;
    // ===== Declarability =====

    [Test]
    procedure T01_FieldRefDeclaredAsLocalGlobalParamAndReturn()
    var
        Diags: Codeunit "ALI Diag Bag";
        ErrText: Text;
        Ok: Boolean;
    begin
        // Every declaration position at once, for BOTH types: module global, proc local,
        // by-value param, var param, return type. All of them are the same Int-handle register
        // (RegClassFor -> Int), so one compile covers the whole of the declarability surface —
        // the same argument P0 made for RecordRef.
        Ok := Pipeline.CompileExpectingErrors(
            'var gf: FieldRef; gk: KeyRef; ' +
            'procedure Byval(f: FieldRef): Integer begin exit(f.Number()); end; ' +
            'procedure Byref(var f: FieldRef; var r: RecordRef) begin f := r.Field(1); end; ' +
            'procedure Make(var r: RecordRef): FieldRef var l: FieldRef; begin l := r.Field(2); exit(l); end; ' +
            'procedure P(): Integer var r: RecordRef; f: FieldRef; k: KeyRef; begin ' +
            Open() + 'Byref(f, r); gf := Make(r); k := r.KeyIndex(1); gk := k; exit(Byval(f)); end;', Diags);
        if Diags.Count() > 0 then
            ErrText := StrSubstNo('%1: %2', Diags.GetCode(1), Diags.GetMessage(1));
        Assert.IsTrue(Ok, StrSubstNo('FieldRef/KeyRef must be declarable everywhere a handle type is: %1', ErrText));
    end;

    [Test]
    procedure T02_FieldByNumberAndByName()
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        // Field(Integer) is native; Field(Text) is the ALI extension (the same convenience
        // Open(Text) adds on the RecordRef side). Both must land on field 2 = "Name".
        Assert.AreEqual('Name;Name;2;2', RunText(
            'procedure P(): Text var r: RecordRef; a: FieldRef; b: FieldRef; begin ' + Open() +
            'a := r.Field(2); b := r.Field(''Name''); ' +
            'exit(a.Name() + '';'' + b.Name() + '';'' + Format(a.Number()) + '';'' + Format(b.Number())); end;'),
            'Field(no) and Field(name) must resolve to the same field');
    end;

    [Test]
    procedure T03_AssignmentAliasesTheSameField()
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        // `f2 := f1` copies the PAIR, so both names denote the same field of the same row.
        // Writing through one and reading through the other is the observable form of that.
        Assert.AreEqual('Beta', RunText(
            'procedure P(): Text var r: RecordRef; f1: FieldRef; f2: FieldRef; begin ' + Open() +
            'r.FindFirst(); f1 := r.Field(2); f2 := f1; f1.Value := ''Beta''; exit(Format(f2.Value())); end;'),
            'an aliased FieldRef must see the write');
    end;

    [Test]
    procedure T04_FieldIsAllocationFreeAndStable()
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        // The no-lifecycle property, asserted the only way a script can see it: the handle is a
        // pure function of (record handle, field number), so 500 calls yield 500 equal handles
        // and nothing is consumed. A bank-plus-free-list representation would fail this by
        // burning a slot per turn; the loop count is deliberately larger than any plausible bank.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; f: FieldRef; first: Integer; i: Integer; ok: Boolean; begin ' + Open() +
            'ok := true; for i := 1 to 500 do begin f := r.Field(2); if i = 1 then first := f.Number(); ' +
            'if f.Number() <> first then ok := false; end; exit(ok); end;'),
            'Field() must be idempotent and allocation-free');
    end;

    // ===== THE SPIKE, made permanent: write-through =====

    [Test]
    procedure T05_ValueWriteReachesTheRowInMemory()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        // The single assumption the whole packed-pair design rests on. Write through a FieldRef
        // materialized from a RecordRef, then read the SAME field back through a Record variable
        // that was handed the ref with SetTable. If `RecRefs[h].Field(n)` ever yielded a detached
        // copy, this returns 'Alpha' and the representation is wrong.
        Assert.AreEqual('Gamma', RunText(
            'procedure P(): Text var r: RecordRef; c: Record "ALI Test Customer"; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); f.Value := ''Gamma''; r.SetTable(c); exit(c.Name); end;'),
            'a FieldRef write must reach the row the RecordRef holds');
        // and the record itself must be untouched on disk until Modify — write-through is to the
        // in-memory row, exactly as native.
        Cust.Get('F1');
        Assert.AreEqual('Alpha', Cust.Name, 'no Modify was called, so the database must still hold the old value');
    end;

    [Test]
    procedure T06_ValueWriteThenModifyPersists()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        RunInt('procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); f.Value := ''Delta''; r.Modify(); exit(1); end;');
        Cust.Get('F1');
        Assert.AreEqual('Delta', Cust.Name, 'the FieldRef write must be what Modify persists');
    end;

    [Test]
    procedure T07_ValueSetterBothShapes()
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 10, 3);
        // `F.Value := x` (property-set shape, re-marked by the binder) and `F.Value(x)` (plain
        // 1-arg call) must lower to the SAME instruction, id 2.
        Assert.AreEqual('7;9', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; a: Text; begin ' + Open() +
            'r.FindFirst(); f := r.Field(6); f.Value := 7; a := Format(f.Value()); ' +
            'f.Value(9); exit(a + '';'' + Format(f.Value())); end;'),
            'both setter shapes must write the field');
    end;

    [Test]
    procedure T08_ValueUnboxesToTheStaticTarget()
    begin
        CleanSeed();
        Seed('F1', 'Alpha', 12.5, 42);
        // Value() is statically Variant (a FieldRef's field type is only known at run time), so
        // the ordinary Variant unboxing carries it into a typed target — no special converter.
        Assert.AreEqual(42, RunInt(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(6); exit(f.Value()); end;'),
            'Value() must unbox into an Integer result');
    end;

    // ===== Filters through a FieldRef =====

    [Test]
    procedure T09_SetRangeThroughFieldRefThenFindSet()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        Seed('A2', 'Beta', 20, 5);
        Seed('A3', 'Gamma', 30, 9);
        // All three SetRange arities on one field: from..to, then equality, then clear. The
        // filter must land on the RECORD the FieldRef came from, which is what makes FindSet on
        // the RecordRef see it.
        Assert.AreEqual('2;1;3', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; a: Integer; b: Integer; c: Integer; begin ' + Open() +
            'f := r.Field(6); f.SetRange(1, 5); a := r.Count(); f.SetRange(9); b := r.Count(); f.SetRange(); c := r.Count(); ' +
            'exit(Format(a) + '';'' + Format(b) + '';'' + Format(c)); end;'),
            'SetRange(lo,hi) / SetRange(v) / SetRange() through a FieldRef');
    end;

    [Test]
    procedure T10_SetFilterAndGetFilterAndRangeBounds()
    var
        Cust: Record "ALI Test Customer";
        Native: Integer;
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        Seed('A2', 'Beta', 20, 5);
        Seed('A3', 'Gamma', 30, 9);
        // SetFilter with a substitution argument (the variadic form), then GetFilter/GetRangeMin/
        // GetRangeMax read the filter back off the same field.
        //
        // The row count is taken from the platform (§14) instead of written out: the hardcoded
        // '2' this used to carry was copied from T09's SetRange(1, 5) and never re-derived —
        // '1..9' spans ALL THREE seeded Post Counts (1, 5, 9), so the correct answer is 3 and
        // the runtime was right. A native Record applying the same filter cannot be wrong about
        // its own inclusiveness.
        Cust.SetFilter("Post Count", '%1..%2', 1, 9);
        Native := Cust.Count();
        Assert.AreEqual(StrSubstNo('%1;1;9', Native), RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; n: Integer; begin ' + Open() +
            'f := r.Field(6); f.SetFilter(''%1..%2'', 1, 9); n := r.Count(); ' +
            'exit(Format(n) + '';'' + Format(f.GetRangeMin()) + '';'' + Format(f.GetRangeMax())); end;'),
            'SetFilter with substitution args, and the range bounds read back');
        Assert.AreEqual('1..9', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(6); f.SetFilter(''%1..%2'', 1, 9); exit(f.GetFilter()); end;'),
            'GetFilter returns the applied filter');
    end;

    [Test]
    procedure T11_ValidateRunsTheFieldTrigger()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Validate goes through the native FieldRef, so OnValidate (none on this fixture field)
        // and the platform's own type/length checks apply — the point here is that the value
        // lands, through the validate path rather than the raw Value path.
        Assert.AreEqual(77, RunInt(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(6); f.Validate(77); exit(f.Value()); end;'),
            'Validate(value) must set the field');
    end;

    [Test]
    procedure T12_TestFieldRaisesOnBlank()
    begin
        CleanSeed();
        Seed('A1', '', 10, 0);
        // ONE Variant-argument TestField, not native AL's ~30 typed overloads. Both arities.
        RunExpectFailMsg(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); f.TestField(); exit(1); end;', 'Name');
        RunExpectFailMsg(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); f.TestField(''Nope''); exit(1); end;', 'Name');
    end;

    [Test]
    procedure T13_FieldErrorRaisesNamingTheField()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        RunExpectFailMsg(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); f.FieldError(''is wrong''); exit(1); end;', 'is wrong');
    end;

    // ===== Metadata surface =====

    [Test]
    procedure T14_ScalarMetadata()
    var
        NativeRef: RecordRef;
        NativeFld: FieldRef;
    begin
        CleanSeed();
        // Name/Number/Caption/Length/Active on field 1 ("No.", Code[20]), compared against the
        // NATIVE FieldRef (§14) rather than a written-out string. Two of the five members are
        // not the test's to decide: `Caption()` is localized (this suite runs against an fr-CH
        // service) and `Format(Boolean)` is the platform's rendering of a Boolean, which is
        // 'Yes'/'Oui'-shaped and never the 'True' this used to expect. A test that only passes
        // in one locale is a bug in the test; reading both off the platform makes the assertion
        // about ALI's FieldRef, which is what it is for.
        NativeRef.Open(Database::"ALI Test Customer");
        NativeFld := NativeRef.Field(1);
        Assert.AreEqual(
            StrSubstNo('%1;%2;%3;%4;%5', NativeFld.Name(), NativeFld.Number(), NativeFld.Caption(), NativeFld.Length(), Format(NativeFld.Active())),
            RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(1); exit(f.Name() + '';'' + Format(f.Number()) + '';'' + f.Caption() + '';'' + ' +
            'Format(f.Length()) + '';'' + Format(f.Active())); end;'),
            'Name/Number/Caption/Length/Active');
        NativeRef.Close();
    end;

    [Test]
    procedure T15_ClassAndTypeAreOptionTyped()
    begin
        CleanSeed();
        // Class()/Type() return ALI's OWN FieldClass/FieldType option sets, mapped from the
        // platform's values BY NAME (the platform's FieldType ordinals are non-contiguous and
        // cannot be reproduced by an index-ordered option set — see "ALI Option Meta"). So both
        // the `::` comparison and Format() must work, and both must agree.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(1); exit((f.Class() = FieldClass::Normal) and (f.Type() = FieldType::Code)); end;'),
            'field 1 is a Normal Code field');
        Assert.AreEqual('Decimal', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(3); exit(Format(f.Type())); end;'),
            'Format of a FieldType renders the member name');
    end;

    [Test]
    procedure T16_OptionMetadata()
    begin
        CleanSeed();
        // Field 8 Status is a plain Option with three members and a differing caption on the
        // third — OptionMembers/OptionCaption come straight off the native FieldRef.
        Assert.AreEqual('Open,Pending,Closed Out', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(8); exit(f.OptionCaption()); end;'),
            'OptionCaption');
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(8); exit(not f.IsEnum()); end;'),
            'an Option field is not an Enum field');
    end;

    [Test]
    procedure T17_EnumMetadata()
    begin
        CleanSeed();
        // Field 9 Category is Enum "ALI Test Enum": members " "(0), New(1), Open(5, caption
        // 'Open Thing'), Closed(10). The GAPPED ordinals are the point — index 3 is ordinal 5,
        // and the two must never be confused. Native FieldRef's enum introspection is used
        // directly here rather than "ALI Option Meta"'s bind-time parser, because a FieldRef's
        // field is only known at run time.
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(9); exit(f.IsEnum() and (f.EnumValueCount() = 4)); end;'),
            'IsEnum + EnumValueCount');
        Assert.AreEqual('Open;5;Open Thing;Open;Open Thing', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'f := r.Field(9); exit(f.GetEnumValueName(3) + '';'' + Format(f.GetEnumValueOrdinal(3)) + '';'' + ' +
            'f.GetEnumValueCaption(3) + '';'' + f.GetEnumValueNameFromOrdinalValue(5) + '';'' + ' +
            'f.GetEnumValueCaptionFromOrdinalValue(5)); end;'),
            'the by-INDEX and by-ORDINAL enum getters must agree on the gapped member');
    end;

    [Test]
    procedure T18_RecordReturnsTheOwningRef()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Record() is a pure decode under the pair design — the owning record handle IS the low
        // half of the FieldRef handle — so the RecordRef it returns ALIASES the same bank slot,
        // as in native AL. Observable: filter through the returned ref, count through the
        // original.
        Assert.AreEqual('ALI Test Customer', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; r2: RecordRef; begin ' + Open() +
            'f := r.Field(1); r2 := f.Record(); exit(r2.Name()); end;'),
            'FieldRef.Record() names the owning table');
    end;

    // ===== KeyRef (P3) =====

    [Test]
    procedure T19_KeyRefSurface()
    var
        NativeRef: RecordRef;
        NativeKey: KeyRef;
    begin
        CleanSeed();
        // Four methods, that is the whole type. Key 1 of the fixture is the clustered PK on
        // "No." (one field, always active); FieldIndex(1) hands back a FieldRef on the SAME
        // record handle, which is why it is one packing and one opcode rather than two.
        //
        // Native comparison (§14) for the same reason T14 uses one: the leading member is
        // `Format(k.Active())`, and Format of a Boolean renders 'Yes'/'Oui' on the platform, not
        // the 'True' this line used to expect — the assertion was pinning AL's Boolean rendering
        // by accident instead of pinning the KeyRef surface on purpose.
        NativeRef.Open(Database::"ALI Test Customer");
        NativeKey := NativeRef.KeyIndex(1);
        Assert.AreEqual(
            StrSubstNo('%1;%2;%3;%4', Format(NativeKey.Active()), NativeKey.FieldCount(), NativeKey.FieldIndex(1).Name(), NativeRef.Name()),
            RunText(
            'procedure P(): Text var r: RecordRef; k: KeyRef; f: FieldRef; r2: RecordRef; begin ' + Open() +
            'k := r.KeyIndex(1); f := k.FieldIndex(1); r2 := k.Record(); ' +
            'exit(Format(k.Active()) + '';'' + Format(k.FieldCount()) + '';'' + f.Name() + '';'' + r2.Name()); end;'),
            'Active / FieldCount / FieldIndex / Record');
        NativeRef.Close();
    end;

    // ===== Refusals and truthful failures =====

    [Test]
    procedure T20_RecordRefAndFieldRefRoutesAreBothLive()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // *** This test asserted the OPPOSITE before phase P4, and the old assertion became
        // factually wrong rather than merely stale: it pinned `r.SetRange(1, 2)` on a RECORDREF
        // receiver as ALI989 ("recognized but not implemented"), and P4 implemented it — REF_METHOD
        // ids 18-39 read their field numbers live out of the operand pool. Keeping the old
        // assertion would have meant keeping the deferral. ***
        //
        // What is still worth pinning is that the TWO ROUTES coexist and stay independent: the
        // FieldRef route (T09) needs no field-number encoding because the number rides in the
        // handle, and the RecordRef route reads it from a register. Neither desugars into the
        // other, so both must compile.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.SetRange(1, 2); end;', Diags),
            'SetRange on a RecordRef receiver compiles since P4');
        Diags.Reset();
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('procedure P() var r: RecordRef; begin r.Open(18); r.Field(1).SetRange(2); end;', Diags),
            'the FieldRef route still compiles alongside it');
    end;

    [Test]
    procedure T21_BlobThroughFieldRefIsRefused()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Field 10 Notes is a Blob. A FieldRef yields the raw blob id, never a usable Blob
        // object, so Value is refused with the SAME ALI997 reasoning the Media write side
        // carries at bind time — at RUN time here, because a FieldRef's field number is only
        // known then. Silently handing back an unusable value is the failure mode this prevents.
        RunExpectFailMsg(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(10); f.Value(); exit(1); end;', 'ALI997');
    end;

    [Test]
    procedure T22_UnboundFieldRefFailsTruthfully()
    begin
        CleanSeed();
        // A FieldRef local starts at handle 0 (the lowerer zeroes it at proc entry, same rule a
        // RecordRef follows) and every use before Field()/KeyIndex() must say so — never an
        // array-index-0 crash inside the runtime.
        RunExpectFailMsg('procedure P(): Integer var f: FieldRef; begin exit(f.Number()); end;', 'ALI937');
        RunExpectFailMsg('procedure P(): Integer var k: KeyRef; begin exit(k.FieldCount()); end;', 'ALI937');
    end;

    [Test]
    procedure T23_ClearUnbindsWithoutTouchingTheRecord()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Native Clear(FieldRef) UNBINDS the reference. Under the pair design that is just a
        // zeroed register — the handle owns no resource — and it must NOT disturb the record,
        // which stays usable afterwards.
        Assert.AreEqual('Alpha', RunText(
            'procedure P(): Text var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); Clear(f); f := r.Field(2); exit(Format(f.Value())); end;'),
            'Clear unbinds the FieldRef and leaves the record alone');
        RunExpectFailMsg(
            'procedure P(): Integer var r: RecordRef; f: FieldRef; begin ' + Open() +
            'r.FindFirst(); f := r.Field(2); Clear(f); exit(f.Number()); end;', 'ALI937');
    end;

    [Test]
    procedure T24_UnknownMemberIsNamedNotSwallowed()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The whole documented FieldRef/KeyRef surface is implemented, so there is no 🔶
        // deferral arm in this family — an unrecognized name really is unknown, and must be
        // reported as a FieldRef member problem rather than leaking into another family's
        // dispatch (which is what a missed `Sid <= FieldRefMethodMark()` rung would cause).
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors(
                'procedure P() var r: RecordRef; f: FieldRef; begin r.Open(18); f := r.Field(1); f.Nonsense(); end;', Diags),
            'an unknown FieldRef member must not compile');
        AssertDiag(Diags, 'AL0132', 'FieldRef');
    end;

    // ===== Chained member access on a CALL RESULT (`RRef.Field(3).Value`) =====
    //
    // The idiomatic spelling of this whole API, and the one the receiver predicates used to
    // refuse: they matched a ref-typed VARIABLE (NameExpr + Symbols.Lookup) and not an arbitrary
    // expression that merely BINDS to a ref type, so `RRef.Field(3).Value` reported
    // "ALI934: Member access requires a record variable (got FieldRef)".
    //
    // Nothing about the REPRESENTATION had to change for these to work, and that is the point
    // worth pinning: a FieldRef/KeyRef handle is a packed Integer with no bank and no lifecycle,
    // so an intermediate link in a chain is a plain temp register — no allocation, nothing to
    // free, and T33's loop proves it cannot exhaust anything.

    [Test]
    procedure T30_ChainedValueRead()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        Assert.AreEqual('Alpha', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); exit(Format(r.Field(2).Value())); end;'),
            'rvalue chain: Field(n).Value() on a call result');
    end;

    [Test]
    procedure T31_ChainedValueWrite()
    var
        Cust: Record "ALI Test Customer";
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // The commoner of the two forms. `<call>.Value := x` is an lvalue whose RECEIVER is an
        // expression, so it also had to pass the property-set recognizer, not only the dispatcher.
        RunInt('procedure P(): Integer var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); r.Field(2).Value := ''Zeta''; r.Modify(); exit(1); end;');
        Cust.Get('A1');
        Assert.AreEqual('Zeta', Cust.Name, 'lvalue chain: Field(n).Value := x must reach the row and persist');
    end;

    [Test]
    procedure T32_ChainedParenlessBothPositions()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Paren-less links: `.Value` and `.Name` with no `()`. The paren-less path binds its
        // receiver BEFORE dispatching, so it exercises the "already bound" arm of the peek, while
        // T30/T34 exercise the "bind it now" arm.
        Assert.AreEqual('Alpha;Name', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); exit(Format(r.Field(2).Value) + '';'' + r.Field(2).Name); end;'),
            'paren-less chained read');
    end;

    [Test]
    procedure T33_ChainInALoopAllocatesNothing()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // 500 chained writes. Under the packed-pair design each `r.Field(2)` returns the SAME
        // integer and the chain's intermediate lives in a temp register, so there is nothing to
        // exhaust; a bank-backed FieldRef would have burned 500 slots here.
        Assert.AreEqual('499', RunText(
            'procedure P(): Text var r: RecordRef; i: Integer; begin ' + Open() +
            'r.FindFirst(); for i := 1 to 500 do r.Field(6).Value := i - 1; exit(Format(r.Field(6).Value())); end;'),
            'a chained write in a loop must allocate nothing and keep working');
    end;

    [Test]
    procedure T34_DepthThreeChain()
    var
        NativeRef: RecordRef;
    begin
        // KeyIndex(1).FieldIndex(1).Name() — three links, two of them call results. Each link is
        // peeked and bound once, which is what the TypeOrd fast path in the receiver peek buys:
        // without it an n-link chain costs 2^n binds.
        NativeRef.Open(Database::"ALI Test Customer");
        Assert.AreEqual(NativeRef.KeyIndex(1).FieldIndex(1).Name(), RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'exit(r.KeyIndex(1).FieldIndex(1).Name()); end;'),
            'depth-3 chain through KeyRef -> FieldRef -> Text');
        Assert.AreEqual(NativeRef.Field(3).Record().Number(), RunInt(
            'procedure P(): Integer var r: RecordRef; begin ' + Open() +
            'exit(r.Field(3).Record().Number()); end;'),
            'FieldRef.Record() back to a RecordRef, then a RecordRef-only method on it');
        NativeRef.Close();
    end;

    [Test]
    procedure T35_ChainOnAVarParameterAndOnAReturnValue()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // A `var` parameter reaches its handle through a LOAD_IND into a temp, and a procedure
        // RESULT through RESULT_FETCH — neither is a plain local slot, so both prove the chain
        // resolves its receiver generically instead of assuming a declared variable's register.
        // P is declared FIRST on purpose: with no OnRun the entry proc is the first procedure of
        // the unit, so a helper written above P would be the one that runs — with no arguments.
        Assert.AreEqual('Alpha', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); exit(Read(r)); end; ' +
            'procedure Read(var rr: RecordRef): Text begin exit(Format(rr.Field(2).Value())); end;'),
            'chain on a var parameter');
        Assert.AreEqual('Alpha', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); exit(Format(Get2(r).Value())); end; ' +
            'procedure Get2(var rr: RecordRef): FieldRef begin exit(rr.Field(2)); end;'),
            'chain on a procedure return value');
    end;

    [Test]
    procedure T36_ChainInExpressionContexts()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        // Inside StrSubstNo (an argument position, where the chain is lowered into an operand
        // pool of somebody else's call) and inside an `if` condition (a Boolean context).
        Assert.AreEqual('[Alpha]', RunText(
            'procedure P(): Text var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); exit(StrSubstNo(''[%1]'', r.Field(2).Value())); end;'),
            'chain as a call argument');
        Assert.IsTrue(RunBool(
            'procedure P(): Boolean var r: RecordRef; begin ' + Open() +
            'r.FindFirst(); if r.Field(2).Name() = ''Name'' then exit(true); exit(false); end;'),
            'chain inside an if condition');
    end;

    [Test]
    procedure T37_ChainedSetRangeFiltersTheRef()
    begin
        CleanSeed();
        Seed('A1', 'Alpha', 10, 1);
        Seed('A2', 'Beta', 20, 2);
        // A VOID chained call as a statement — the statement dispatch ladder, not the expression
        // one. Asserted by its effect rather than its return value.
        Assert.AreEqual(1, RunInt(
            'procedure P(): Integer var r: RecordRef; begin ' + Open() +
            'r.Field(1).SetRange(''A2''); exit(r.Count()); end;'),
            'chained SetRange must filter the ref the chain came from');
    end;
}
#endif
