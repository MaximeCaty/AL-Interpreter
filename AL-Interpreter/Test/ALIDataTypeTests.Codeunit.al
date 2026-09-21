// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Data Type Tests — the library types the interpreter exposes: arrays, List/Dictionary,
// TextBuilder, text indexing/slicing, BigText, Json, Xml and HttpClient. Merged from the
// former "ALI Array/List Dict/TextBuilder/Text Index/BigText/Json/Xml/Http Tests" codeunits.
// NOTE: the Xml section uses RunXmlText (RunText + XML-declaration stripping), not RunText.
codeunit 51134 "ALI Data Type Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Pipeline: Codeunit "ALI Test Pipeline";
        Assert: Codeunit "Library Assert";

    // ================================================================================================
    // ALI Array Tests — multidimensional arrays + handle-based storage (ArrayMultidimPlan.md
    // §20.14). "ALI Record Tests" T14-T20 cover 1-D arrays and stay green across the storage
    // swap (§20.13 Phase 1); this codeunit covers the multidim additions (Phase 2) plus a couple
    // of storage-swap sanity checks (independent arrays / free-list reuse, Phase 1/3).
    // ================================================================================================

    local procedure RunInt(Source: Text): Integer
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultInt());
    end;

    [Test]
    procedure T01_TwoDimWriteRead()
    begin
        Assert.AreEqual(23,
            RunInt('trigger OnRun(): Integer var a: array[3,4] of Integer; i: Integer; j: Integer; begin for i := 1 to 3 do for j := 1 to 4 do a[i,j] := i*10+j; exit(a[2,3]); end;'),
            '2-D array write/read matches i*10+j at [2,3]');
    end;

    [Test]
    procedure T02_RowMajorOrderDistinct()
    begin
        // a[2,1] and a[1,2] must be distinct cells (row-major, native layout).
        Assert.AreEqual(21,
            RunInt('trigger OnRun(): Integer var a: array[3,4] of Integer; begin a[1,2] := 12; a[2,1] := 21; exit(a[2,1]); end;'),
            'a[2,1] independent of a[1,2]');
        Assert.AreEqual(12,
            RunInt('trigger OnRun(): Integer var a: array[3,4] of Integer; begin a[1,2] := 12; a[2,1] := 21; exit(a[1,2]); end;'),
            'a[1,2] independent of a[2,1]');
    end;

    [Test]
    procedure T03_ThreeDimSumMatchesNative()
    var
        a: array[2, 3, 4] of Integer;
        Expected: Integer;
        i: Integer;
        j: Integer;
        k: Integer;
    begin
        for i := 1 to 2 do
            for j := 1 to 3 do
                for k := 1 to 4 do begin
                    a[i, j, k] := i * 100 + j * 10 + k;
                    Expected += a[i, j, k];
                end;
        Assert.AreEqual(Expected,
            RunInt('trigger OnRun(): Integer var a: array[2,3,4] of Integer; i: Integer; j: Integer; k: Integer; s: Integer; begin for i := 1 to 2 do for j := 1 to 3 do for k := 1 to 4 do begin a[i,j,k] := i*100+j*10+k; s := s + a[i,j,k]; end; exit(s); end;'),
            '3-D array fill+sum matches native');
    end;

    [Test]
    procedure T04_WrongIndexArityIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var a: array[3,4] of Integer; begin exit(a[1]); end;', Diags),
            'indexing a 2-D array with 1 index is a compile error');
    end;

    [Test]
    procedure T05_PerDimensionOutOfBoundsRaises()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // array[3,4]: a[4,1] — dimension-1 index 4 is out of range (1..3) even though the
        // folded flat index (13) still lands inside 1..12 — native-exact bounds (§20.7 (b)).
        Pipeline.CompileAndRun('procedure P(): Integer var a: array[3,4] of Integer; i: Integer; begin i := 4; exit(a[i,1]); end;', Result, Interp);
        Assert.IsFalse(Result.Succeeded(), 'out-of-range dimension-1 index raises even when the flat index would be in range');
    end;

    [Test]
    procedure T05b_WraparoundDimensionOutOfBoundsRaises()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // array[3,4]: a[1,5] — dimension-2 index 5 is out of range (1..4), yet the folded
        // flat index ((1-1)*4+(5-1)+1 = 5) would silently land inside 1..12 and read a[2,1]
        // under the "final bounds check only" option (a) — per-dimension checks (option b)
        // must catch this even though the naive flat check would not (§20.7).
        Pipeline.CompileAndRun('procedure P(): Integer var a: array[3,4] of Integer; i: Integer; begin i := 5; exit(a[1,i]); end;', Result, Interp);
        Assert.IsFalse(Result.Succeeded(), 'dimension-2 wraparound out-of-bounds raises even though the flat index would still be in 1..TotalN');
    end;

    [Test]
    procedure T06_ArrayLenPerDimension()
    begin
        Assert.AreEqual(3,
            RunInt('trigger OnRun(): Integer var a: array[3,4] of Integer; begin exit(ArrayLen(a)); end;'),
            'ArrayLen(a) with no dim = N1 (first dimension), not TotalN');
        Assert.AreEqual(4,
            RunInt('trigger OnRun(): Integer var a: array[3,4] of Integer; begin exit(ArrayLen(a, 2)); end;'),
            'ArrayLen(a, 2) = N2');
    end;

    [Test]
    procedure T07_ArrayLenDimOutOfRangeIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var a: array[3,4] of Integer; begin exit(ArrayLen(a, 3)); end;', Diags),
            'ArrayLen dim > rank is a compile error');
    end;

    [Test]
    procedure T08_TotalElementCountOverMillionIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var a: array[1000,1001] of Integer; begin exit(0); end;', Diags),
            'total element count > 1000000 is a compile error at ResolveArrayType');
    end;

    [Test]
    procedure T09_TenDimSmallestCaseBindsAndIndexes()
    begin
        Assert.AreEqual(42,
            RunInt('trigger OnRun(): Integer var a: array[2,1,1,1,1,1,1,1,1,1] of Integer; begin a[2,1,1,1,1,1,1,1,1,1] := 42; exit(a[2,1,1,1,1,1,1,1,1,1]); end;'),
            '10-D rank binds, indexes and reclaims');
    end;

    [Test]
    procedure T11_ArrayVarParamIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(var a: array[3] of Integer) begin end; procedure Q(): Integer begin exit(1); end;', Diags),
            'an array cannot be passed by reference (v1 escape guard)');
    end;

    [Test]
    procedure T12_TwoArraysInOneProcAreIndependent()
    begin
        Assert.AreEqual(18,
            RunInt('trigger OnRun(): Integer var a: array[3] of Integer; b: array[3] of Integer; i: Integer; s: Integer; begin for i := 1 to 3 do begin a[i] := i; b[i] := i*2; end; for i := 1 to 3 do s := s + a[i] + b[i]; exit(s); end;'),
            'two local arrays in the same proc get distinct blocks (independent storage)');
    end;

    [Test]
    procedure T13_ArrayLocalReusedAcrossLoopCalls()
    begin
        // A proc with a local array, called K times in a loop: each call gets a fresh block
        // (allocated at proc entry) and it is freed on return (§20.5 frame-pop reclamation) —
        // the free-list should let this run without growing unbounded (Phase 1/3 sanity).
        // P must be declared FIRST — entry proc = first proc named OnRun, else proc 1.
        Assert.AreEqual(275,
            RunInt('trigger OnRun(): Integer var k: Integer; total: Integer; begin for k := 1 to 5 do total := total + Sum10(); exit(total); end; procedure Sum10(): Integer var a: array[10] of Integer; i: Integer; s: Integer; begin for i := 1 to 10 do a[i] := i; for i := 1 to 10 do s := s + a[i]; exit(s); end;'),
            'repeated calls reusing a freed local-array block each see the correct fresh sum (5*55=275)');
    end;

    [Test]
    procedure T14_ManyConcurrentBlocksNoPoolCeiling()
    begin
        // 9 concurrent tier-L arrays (10000 elems each) in one frame. The old storage capped
        // this tier's live blocks at BlockCountLimit=8 and would raise "array pool exhausted" on
        // the 9th; native-Variant blocks are GC-bounded, so this must run. Proves the ceiling is
        // gone. Sum of the single written cell in each = 1+2+..+9 = 45.
        Assert.AreEqual(45,
            RunInt('trigger OnRun(): Integer var a1: array[10000] of Integer; a2: array[10000] of Integer; a3: array[10000] of Integer; a4: array[10000] of Integer; a5: array[10000] of Integer; a6: array[10000] of Integer; a7: array[10000] of Integer; a8: array[10000] of Integer; a9: array[10000] of Integer; begin a1[1] := 1; a2[1] := 2; a3[1] := 3; a4[1] := 4; a5[1] := 5; a6[1] := 6; a7[1] := 7; a8[1] := 8; a9[1] := 9; exit(a1[1]+a2[1]+a3[1]+a4[1]+a5[1]+a6[1]+a7[1]+a8[1]+a9[1]); end;'),
            '9 concurrent tier-L arrays allocate without a pool-exhausted ceiling');
    end;

    [Test]
    procedure T15_LogicalBoundBeforePhysicalCap()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // array[50] routes to tier S (physical Cap 100). Index 51 is inside the physical array
        // but past the logical TotalN=50 — must raise ALI957 (range check is on TotalN, never
        // on Cap).
        Pipeline.CompileAndRun('procedure P(): Integer var a: array[50] of Integer; i: Integer; begin a[50] := 5; i := 51; exit(a[i]); end;', Result, Interp);
        Assert.IsFalse(Result.Succeeded(), 'index 51 on array[50] raises even though physical tier Cap is 100');
    end;

    [Test]
    procedure T16_UninitializedIntCellReadsZero()
    begin
        // A never-written element must read back as the type's default, like native AL —
        // not throw (the block used to leave untouched cells as a bare empty Variant).
        Assert.AreEqual(0,
            RunInt('trigger OnRun(): Integer var a: array[5] of Integer; begin exit(a[3]); end;'),
            'untouched Integer element reads as 0');
    end;

    [Test]
    procedure T17_UninitializedBoolCellReadsFalse()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun('procedure P(): Boolean var a: array[5] of Boolean; begin exit(a[3]); end;', Result, Interp),
            StrSubstNo('run OK: %1', Result.ErrorMessage()));
        Assert.IsFalse(Interp.GetResultBool(), 'untouched Boolean element reads as false');
    end;

    [Test]
    procedure T18_UninitializedTextCellReadsEmpty()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun('procedure P(): Text var a: array[5] of Text; begin exit(a[3]); end;', Result, Interp),
            StrSubstNo('run OK: %1', Result.ErrorMessage()));
        Assert.AreEqual('', Interp.GetResultText(), 'untouched Text element reads as empty string');
    end;

    // ===== Handle Lifecycle Unification Phase 5 (array-return, ARR_REBIND) =====

    [Test]
    procedure T19_ArrayReturnedByValueUsableAfterCalleePop()
    begin
        // MakeArr's own local array is returned by value; ALI990 no longer rejects this, and
        // the caller's ARR_REBIND must free its own declared-at-entry block and rebind to the
        // fresh one (still escape-tracked correctly across the callee's frame pop).
        Assert.AreEqual(20,
            RunInt('trigger OnRun(): Integer var a: array[3] of Integer; begin a := MakeArr(); exit(a[2]); end; ' +
                   'procedure MakeArr(): array[3] of Integer var r: array[3] of Integer; begin r[1] := 10; r[2] := 20; r[3] := 30; exit(r); end;'),
            'an array handle returned by value from a proc must be usable after that proc''s frame pops');
    end;

    [Test]
    procedure T20_RepeatedArrayRebindDoesNotLeak()
    begin
        // Calls MakeArr() in a loop, rebinding the same local array var each time — ARR_REBIND
        // must free the PREVIOUS iteration's block every time, not just leave them all live.
        // A large iteration count would previously have been fine anyway (arrays were never the
        // leaking type), but this exercises the free/rebind path repeatedly for correctness.
        Assert.AreEqual(500,
            RunInt('trigger OnRun(): Integer var a: array[2] of Integer; i: Integer; begin for i := 1 to 500 do a := MakeArr(i); exit(a[1]); end; ' +
                   'procedure MakeArr(n: Integer): array[2] of Integer var r: array[2] of Integer; begin r[1] := n; exit(r); end;'),
            'repeated array rebind in a loop must reflect the LAST call and not error/leak');
    end;

    // ================================================================================================
    // ALI List/Dictionary Tests — List of [T] / Dictionary of [K, V] RefShim surface (see
    // ListDictionaryPlan.md §8), mirroring "ALI TextBuilder Tests"' pipeline-driven style.
    // ================================================================================================

    local procedure RunText(Source: Text): Text
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultText());
    end;

    local procedure RunBool(Source: Text): Boolean
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultBool());
    end;

    local procedure RunExpectFailure(Source: Text; var Result: Codeunit "ALI Exec Result")
    var
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsFalse(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('expected a runtime failure for <%1>', Source));
    end;

    // ===== List: Add/Count/Get round-trip per class =====

    [Test]
    procedure T01_ListIntegerRoundTrip()
    begin
        Assert.AreEqual(42,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(42); l.Add(7); exit(l.Get(1)); end;'),
            'List of [Integer] Add/Get round-trip');
    end;

    [Test]
    procedure T02_ListTextRoundTrip()
    begin
        Assert.AreEqual('b',
            RunText('var l: List of [Text]; procedure P(): Text begin l.Add(''a''); l.Add(''b''); exit(l.Get(2)); end;'),
            'List of [Text] Add/Get round-trip');
    end;

    [Test]
    procedure T03_ListDecimalCount()
    begin
        Assert.AreEqual(3,
            RunInt('var l: List of [Decimal]; procedure P(): Integer begin l.Add(1.1); l.Add(2.2); l.Add(3.3); exit(l.Count()); end;'),
            'List of [Decimal] Count() reflects Adds');
    end;

    [Test]
    procedure T04_ListBooleanRoundTrip()
    begin
        Assert.IsTrue(
            RunBool('var l: List of [Boolean]; procedure P(): Boolean begin l.Add(false); l.Add(true); exit(l.Get(2)); end;'),
            'List of [Boolean] Add/Get round-trip');
    end;

    [Test]
    procedure T05_ListDateCount()
    begin
        Assert.AreEqual(2,
            RunInt('var l: List of [Date]; procedure P(): Integer begin l.Add(20250101D); l.Add(20250102D); exit(l.Count()); end;'),
            'List of [Date] Count() reflects Adds');
    end;

    // ===== List: remaining core surface =====

    [Test]
    procedure T06_ListContains()
    begin
        Assert.IsTrue(
            RunBool('var l: List of [Integer]; procedure P(): Boolean begin l.Add(1); l.Add(2); exit(l.Contains(2)); end;'),
            'Contains finds an added value');
    end;

    [Test]
    procedure T07_ListIndexOf()
    begin
        Assert.AreEqual(2,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(10); l.Add(20); l.Add(30); exit(l.IndexOf(20)); end;'),
            'IndexOf returns the 1-based position');
    end;

    [Test]
    procedure T08_ListRemove()
    begin
        Assert.AreEqual(1,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(1); l.Add(2); l.Remove(1); exit(l.Count()); end;'),
            'Remove(value) removes the first match');
    end;

    [Test]
    procedure T09_ListRemoveAt()
    begin
        Assert.AreEqual(20,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(10); l.Add(20); l.RemoveAt(1); exit(l.Get(1)); end;'),
            'RemoveAt shifts subsequent elements down');
    end;

    [Test]
    procedure T10_ListInsert()
    begin
        Assert.AreEqual(99,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(1); l.Add(2); l.Insert(2, 99); exit(l.Get(2)); end;'),
            'Insert splices a value at the given 1-based position');
    end;

    [Test]
    procedure T11_ListReverse()
    begin
        Assert.AreEqual(1,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(1); l.Add(2); l.Add(3); l.Reverse(); exit(l.Get(3)); end;'),
            'Reverse() flips element order in place');
    end;

    [Test]
    procedure T12_ListGetRange()
    begin
        // Method calls cannot be chained in this interpreter (receivers must be a plain
        // variable, matching the existing TextBuilder/stream method-call limitation) —
        // GetRange's result is stored into a variable first, which also exercises the
        // List-assignment element-type check (ListDictionaryPlan.md §5.3).
        Assert.AreEqual(2,
            RunInt('var l: List of [Integer]; r: List of [Integer]; procedure P(): Integer begin l.Add(1); l.Add(2); l.Add(3); r := l.GetRange(2, 2); exit(r.Count()); end;'),
            'GetRange returns a new List of the requested slice');
    end;

    [Test]
    procedure T13_ListAddRange()
    begin
        Assert.AreEqual(3,
            RunInt('var l1, l2: List of [Integer]; procedure P(): Integer begin l1.Add(1); l2.Add(2); l2.Add(3); l1.AddRange(l2); exit(l1.Count()); end;'),
            'AddRange appends every element of the source List');
    end;

    [Test]
    procedure T14_ListSetReturnsOldValue()
    begin
        Assert.AreEqual(10,
            RunInt('var l: List of [Integer]; procedure P(): Integer begin l.Add(10); l.Set(1, 20); exit(l.Get(1) - 10); end;'),
            'Set(index, value) overwrites; Get reflects the new value');
    end;

    // ===== Reference semantics (ListDictionaryPlan.md §5.3 — `L2 := L1` shares backing) =====

    [Test]
    procedure T15_ReferenceAssignmentSharesBacking()
    begin
        Assert.AreEqual(2,
            RunInt('var l1: List of [Integer]; var l2: List of [Integer]; procedure P(): Integer begin l1.Add(1); l2 := l1; l1.Add(2); exit(l2.Count()); end;'),
            'l2 := l1 aliases the same backing List (native reference semantics)');
    end;

    [Test]
    procedure T16_HandleIsolation()
    begin
        Assert.AreEqual(1,
            RunInt('var l1: List of [Integer]; var l2: List of [Integer]; procedure P(): Integer begin l1.Add(1); l1.Add(2); l2.Add(99); exit(l2.Count()); end;'),
            'Two independently-declared Lists of the same element class do not alias');
    end;

    // ===== Local-collection freshness across a recursive proc (guards §5.1 prologue) =====

    [Test]
    procedure T17_RecursiveLocalListIsFreshEveryCall()
    begin
        Assert.AreEqual(5,
            RunInt('trigger OnRun(): Integer begin exit(Depth(1)); end; procedure Depth(N: Integer): Integer var l: List of [Integer]; begin l.Add(N); if N < 5 then exit(l.Count() + Depth(N + 1)); exit(l.Count()); end;'),
            'each recursion depth gets its OWN fresh local List (Count()=1 at every depth); an aliasing bug would inflate the sum');
    end;

    // ===== Dictionary: Add/Get/Set/ContainsKey/Remove/Count =====

    [Test]
    procedure T18_DictIntKeyRoundTrip()
    begin
        Assert.AreEqual('x',
            RunText('var d: Dictionary of [Integer, Text]; procedure P(): Text begin d.Add(1, ''x''); exit(d.Get(1)); end;'),
            'Dictionary of [Integer, Text] Add/Get round-trip');
    end;

    [Test]
    procedure T19_DictTextKeyRoundTrip()
    begin
        Assert.AreEqual(42,
            RunInt('var d: Dictionary of [Text, Integer]; procedure P(): Integer begin d.Add(''k'', 42); exit(d.Get(''k'')); end;'),
            'Dictionary of [Text, Integer] Add/Get round-trip');
    end;

    [Test]
    procedure T20_DictContainsKey()
    begin
        Assert.IsTrue(
            RunBool('var d: Dictionary of [Integer, Boolean]; procedure P(): Boolean begin d.Add(1, true); exit(d.ContainsKey(1)); end;'),
            'ContainsKey finds an added key');
    end;

    [Test]
    procedure T21_DictRemove()
    begin
        Assert.AreEqual(0,
            RunInt('var d: Dictionary of [Integer, Integer]; procedure P(): Integer begin d.Add(1, 1); d.Remove(1); exit(d.Count()); end;'),
            'Remove(key) removes the entry');
    end;

    [Test]
    procedure T22_DictSetUpserts()
    begin
        Assert.AreEqual(2,
            RunInt('var d: Dictionary of [Integer, Integer]; procedure P(): Integer begin d.Add(1, 1); d.Set(1, 2); exit(d.Get(1)); end;'),
            'Set(key, value) updates an existing key (add-or-update)');
    end;

    [Test]
    procedure T23_DictAddOnExistingKeyRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFailure('var d: Dictionary of [Integer, Integer]; procedure P(): Integer begin d.Add(1, 1); d.Add(1, 2); exit(d.Count()); end;', Result);
    end;

    [Test]
    procedure T24_DictKeysReturnsList()
    begin
        Assert.AreEqual(2,
            RunInt('var d: Dictionary of [Integer, Text]; ks: List of [Integer]; procedure P(): Integer begin d.Add(1, ''a''); d.Add(2, ''b''); ks := d.Keys(); exit(ks.Count()); end;'),
            'Keys() returns a List of the dictionary''s keys');
    end;

    [Test]
    procedure T25_DictValuesReturnsList()
    begin
        Assert.AreEqual(2,
            RunInt('var d: Dictionary of [Integer, Text]; vs: List of [Text]; procedure P(): Integer begin d.Add(1, ''a''); d.Add(2, ''b''); vs := d.Values(); exit(vs.Count()); end;'),
            'Values() returns a List of the dictionary''s values');
    end;

    // ===== Type errors (ListDictionaryPlan.md §8) =====

    [Test]
    procedure T26_ListOfVariantRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var l: List of [Variant]; procedure P(): Integer begin exit(0); end;', Diags), 'List of [Variant] must be rejected');
        Assert.IsTrue(Diags.HasErrors(), 'a diagnostic must be raised for List of [Variant]');
    end;

    [Test]
    procedure T27_DictionaryDecimalKeyRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var d: Dictionary of [Decimal, Integer]; procedure P(): Integer begin exit(0); end;', Diags), 'Dictionary key must be Integer or Text class only');
        Assert.IsTrue(Diags.HasErrors(), 'a diagnostic must be raised for a Decimal dictionary key');
    end;

    [Test]
    procedure T28_ListPlusIntegerRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var l: List of [Integer]; procedure P(): Integer begin exit(l + 1); end;', Diags), 'List is not a numeric operand');
        Assert.IsTrue(Diags.HasErrors(), 'a diagnostic must be raised for List + Integer');
    end;

    [Test]
    procedure T29_ListIndexOutOfRangeRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFailure('var l: List of [Integer]; procedure P(): Integer begin l.Add(1); exit(l.Get(5)); end;', Result);
    end;

    // Regression: List of [Text[50]] nests Text[50]'s own length bracket inside the outer
    // element clause. A depth-blind parser closes on the FIRST ']' (Text[50]'s), leaving the
    // real outer ']' dangling and desyncing every token after — cascading "begin expected"
    // parse errors on the next statement. See ALIParser.SkipBracketedGroup.
    [Test]
    procedure T30_ListOfLengthQualifiedTextParses()
    begin
        Assert.AreEqual('hello',
            RunText('var l: List of [Text[50]]; procedure P(): Text begin l.Add(''hello''); exit(l.Get(1)); end;'),
            'List of [Text[50]] parses and round-trips (5-char value is within the declared element length)');
    end;

    [Test]
    procedure T31_DictOfLengthQualifiedTextKeyParses()
    begin
        Assert.AreEqual(42,
            RunInt('var d: Dictionary of [Text[50], Integer]; procedure P(): Integer begin d.Add(''k'', 42); exit(d.Get(''k'')); end;'),
            'Dictionary of [Text[50], Integer] parses and round-trips');
    end;

    // ===== Collection element length: declaration validation + runtime enforcement =====

    [Test]
    procedure T32_ListZeroLengthElemRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var l: List of [Text[0]]; procedure P(): Integer begin exit(0); end;', Diags), 'List of [Text[0]] must be rejected');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for List of [Text[0]]');
    end;

    [Test]
    procedure T33_ListCodeElemWithoutLengthRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var l: List of [Code]; procedure P(): Integer begin exit(0); end;', Diags), 'List of [Code] (no length) must be rejected');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for List of [Code]');
    end;

    [Test]
    procedure T34_ListTextElemOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Adding a value longer than the declared element length is a runtime error.
        RunExpectFailure('var l: List of [Text[5]]; procedure P(): Integer begin l.Add(''abcdefg''); exit(l.Count()); end;', Result);
    end;

    [Test]
    procedure T35_ListTextElemWithinLengthOk()
    begin
        Assert.AreEqual('abc',
            RunText('var l: List of [Text[5]]; procedure P(): Text begin l.Add(''abc''); exit(l.Get(1)); end;'),
            'a value within the declared element length round-trips');
    end;

    [Test]
    procedure T36_ListCodeElemUppercasedOnAdd()
    begin
        Assert.AreEqual('ABC',
            RunText('var l: List of [Code[10]]; procedure P(): Text begin l.Add(''abc''); exit(l.Get(1)); end;'),
            'Code element is upper-cased on store, like a scalar Code');
    end;

    [Test]
    procedure T37_DictValueOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFailure('var d: Dictionary of [Integer, Text[5]]; procedure P(): Integer begin d.Add(1, ''abcdefg''); exit(d.Count()); end;', Result);
    end;

    [Test]
    procedure T38_ArrayTextElemOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFailure('var a: array[3] of Text[5]; procedure P(): Integer begin a[1] := ''abcdefg''; exit(1); end;', Result);
    end;

    // ===== Handle Lifecycle Unification (List/Dict free-list reuse + escape-correct pop) =====

    [Test]
    procedure T39_ListDeclaredLocalDoesNotLeakAcrossManyCalls()
    begin
        // Before the fix, LIST_NEW was never freed at all (no frame-scoped tracking existed
        // for List/Dict) — repeated calls to a proc with its own local List hit ALI972 (cap
        // 4096) long before finishing (10000 > 4096 by a comfortable margin). After the fix,
        // PopFrame reclaims Bump's local list every call, so LiveCount stays flat and the
        // loop completes.
        Assert.AreEqual(10000,
            RunInt('var g: Integer; procedure P(): Integer var i: Integer; begin g := 0; for i := 1 to 10000 do Bump(); exit(g); end; ' +
                   'procedure Bump() var l: List of [Integer]; begin l.Add(1); g := g + l.Get(1); end;'),
            'a local List declared in a proc called many times must not exhaust the live-collection cap');
    end;

    [Test]
    procedure T40_DictDeclaredLocalDoesNotLeakAcrossManyCalls()
    begin
        Assert.AreEqual(10000,
            RunInt('var g: Integer; procedure P(): Integer var i: Integer; begin g := 0; for i := 1 to 10000 do Bump(); exit(g); end; ' +
                   'procedure Bump() var d: Dictionary of [Integer, Integer]; begin d.Add(1, 1); g := g + d.Get(1); end;'),
            'a local Dictionary declared in a proc called many times must not exhaust the live-collection cap');
    end;

    [Test]
    procedure T41_ListReturnedByValueSurvivesCalleePop()
    begin
        // MakeList's own local `r` is frame-tracked; exit(r) must be recognized as a return-
        // escape in PopFrame so it is skipped from the reclaim, not freed out from under the
        // caller who reads it right after the call returns.
        Assert.AreEqual(20,
            RunInt('trigger OnRun(): Integer var l: List of [Integer]; begin l := MakeList(); exit(l.Get(2)); end; ' +
                   'procedure MakeList(): List of [Integer] var r: List of [Integer]; begin r.Add(10); r.Add(20); r.Add(30); exit(r); end;'),
            'a List handle returned by value from a proc must still be valid after that proc''s frame pops');
    end;

    [Test]
    procedure T42_DictReturnedByValueSurvivesCalleePop()
    begin
        Assert.AreEqual(99,
            RunInt('trigger OnRun(): Integer var d: Dictionary of [Integer, Integer]; begin d := MakeDict(); exit(d.Get(1)); end; ' +
                   'procedure MakeDict(): Dictionary of [Integer, Integer] var r: Dictionary of [Integer, Integer]; begin r.Add(1, 99); exit(r); end;'),
            'a Dictionary handle returned by value from a proc must still be valid after that proc''s frame pops');
    end;

    [Test]
    procedure T43_ListAssignedThroughVarParamSurvivesCalleePop()
    begin
        // MakeInto assigns its OWN local `r` through the var-param alias into P's `l` — the
        // lowerer must emit HANDLE_ESCAPE at that store so MakeInto's pop does not free `r`
        // (which is now the value `l` holds).
        Assert.AreEqual(77,
            RunInt('trigger OnRun(): Integer var l: List of [Integer]; begin MakeInto(l); exit(l.Get(1)); end; ' +
                   'procedure MakeInto(var outp: List of [Integer]) var r: List of [Integer]; begin r.Add(77); outp := r; end;'),
            'a List handle assigned through a var-param must still be valid after the callee''s frame pops');
    end;

    [Test]
    procedure T44_ListAssignedToGlobalSurvivesCalleePop()
    begin
        Assert.AreEqual(55,
            RunInt('var g: List of [Integer]; procedure P(): Integer begin MakeGlobal(); exit(g.Get(1)); end; ' +
                   'procedure MakeGlobal() var r: List of [Integer]; begin r.Add(55); g := r; end;'),
            'a List handle assigned to a global must still be valid after the assigning proc''s frame pops');
    end;

    // ===== Paren-less zero-arg member methods (Feature 1) =====

    [Test]
    procedure T45_ParenlessListCount()
    begin
        Assert.AreEqual(2,
            RunInt('var l: List of [Integer]; var n: Integer; procedure P(): Integer begin l.Add(1); l.Add(2); n := l.Count; exit(n); end;'),
            'n := l.Count (no parens) resolves as a paren-less 0-arg method call');
    end;

    [Test]
    procedure T46_ParenlessDictCount()
    begin
        Assert.AreEqual(1,
            RunInt('var d: Dictionary of [Integer, Integer]; procedure P(): Integer begin d.Add(1, 1); exit(d.Count); end;'),
            'd.Count (no parens) resolves as a paren-less 0-arg method call');
    end;

    // ===== Dictionary Get(key, var value) -> Boolean =====

    [Test]
    procedure T47_DictTryGetHitWritesValue()
    begin
        Assert.AreEqual('x',
            RunText('var d: Dictionary of [Text, Text]; var v: Text; procedure P(): Text begin d.Add(''k'', ''x''); if d.Get(''k'', v) then exit(v); exit(''miss''); end;'),
            'Get(key, var value) returns true and writes the value on a hit');
    end;

    [Test]
    procedure T48_DictTryGetMissReturnsFalse()
    begin
        Assert.IsFalse(
            RunBool('var d: Dictionary of [Integer, Integer]; var v: Integer; procedure P(): Boolean begin d.Add(1, 1); exit(d.Get(2, v)); end;'),
            'Get(key, var value) returns false for an absent key');
    end;

    [Test]
    procedure T49_DictTryGetMissLeavesValueUntouched()
    begin
        Assert.AreEqual(99,
            RunInt('var d: Dictionary of [Integer, Integer]; var v: Integer; procedure P(): Integer begin d.Add(1, 1); v := 99; if d.Get(2, v) then exit(-1); exit(v); end;'),
            'a missed Get(key, var value) leaves the target variable unchanged');
    end;

    [Test]
    procedure T50_DictTryGetIntoLocalOfCallee()
    begin
        Assert.AreEqual(7,
            RunInt('var d: Dictionary of [Integer, Integer]; procedure P(): Integer begin d.Add(1, 7); exit(Fetch(1)); end; procedure Fetch(K: Integer): Integer var v: Integer; begin if d.Get(K, v) then exit(v); exit(0); end;'),
            'Get(key, var value) writes a callee-local target (frame-relative register)');
    end;

    // ================================================================================================
    // ALI TextBuilder Tests (M9) — Append/AppendLine/Capacity/Clear/EnsureCapacity/Insert/
    // Length/MaxCapacity/Remove/Replace/ToText, mirroring the native TextBuilder method surface.
    // ================================================================================================

    [Test]
    procedure T01_AppendAndToText()
    begin
        Assert.AreEqual('helloworld',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); tb.Append(''world''); exit(tb.ToText()); end;'),
            'Append concatenates in order');
    end;

    [Test]
    procedure T02_AppendLineNoArg()
    var
        Len: Integer;
    begin
        Len := RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''a''); tb.AppendLine(); tb.Append(''b''); exit(tb.Length()); end;');
        Assert.IsTrue(Len > 2, StrSubstNo('AppendLine() appends a non-empty line terminator between a and b (got Length()=%1)', Len));
    end;

    [Test]
    procedure T03_AppendLineWithText()
    begin
        Assert.IsTrue(
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.AppendLine(''a''); tb.Append(''b''); exit(tb.ToText()); end;').StartsWith('a'),
            'AppendLine(Text) appends text then a line terminator');
    end;

    [Test]
    procedure T04_LengthGetter()
    begin
        Assert.AreEqual(5,
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''hello''); exit(tb.Length()); end;'),
            'Length() reflects appended content');
    end;

    [Test]
    procedure T05_LengthSetterTruncates()
    begin
        Assert.AreEqual('he',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); tb.Length(2); exit(tb.ToText()); end;'),
            'Length(Int) truncates the buffer');
    end;

    [Test]
    procedure T06_Clear()
    begin
        Assert.AreEqual(0,
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''hello''); tb.Clear(); exit(tb.Length()); end;'),
            'Clear() empties the buffer');
    end;

    [Test]
    procedure T07_Insert()
    begin
        Assert.AreEqual('heNEWllo',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); tb.Insert(3, ''NEW''); exit(tb.ToText()); end;'),
            'Insert splices text at the given 1-based position');
    end;

    [Test]
    procedure T08_Remove()
    begin
        Assert.AreEqual('hlo',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); tb.Remove(2, 2); exit(tb.ToText()); end;'),
            'Remove deletes the given range');
    end;

    [Test]
    procedure T09_Replace2Arg()
    begin
        Assert.AreEqual('heLLo',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); tb.Replace(''ll'', ''LL''); exit(tb.ToText()); end;'),
            'Replace(Text,Text) replaces all occurrences');
    end;

    [Test]
    procedure T10_Replace4Arg()
    begin
        // Replace within the first 5 chars ("hello") only — the second "hello" is untouched.
        Assert.AreEqual('heLLohello',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hellohello''); tb.Replace(''ll'', ''LL'', 1, 5); exit(tb.ToText()); end;'),
            'Replace(Text,Text,Int,Int) is scoped to the given substring');
    end;

    [Test]
    procedure T11_ToTextRange()
    begin
        Assert.AreEqual('ell',
            RunText('var tb: TextBuilder; procedure P(): Text begin tb.Append(''hello''); exit(tb.ToText(2, 3)); end;'),
            'ToText(Int,Int) extracts the given substring');
    end;

    [Test]
    procedure T12_CapacityGetterAtLeastLength()
    begin
        Assert.IsTrue(
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''hello''); exit(tb.Capacity()); end;') >= 5,
            'Capacity() is at least the current length');
    end;

    [Test]
    procedure T13_EnsureCapacity()
    begin
        Assert.IsTrue(
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.EnsureCapacity(100); exit(tb.Capacity()); end;') >= 100,
            'EnsureCapacity grows Capacity() to at least the requested value');
    end;

    [Test]
    procedure T14_MaxCapacityPositive()
    begin
        Assert.IsTrue(
            RunInt('var tb: TextBuilder; procedure P(): Integer begin exit(tb.MaxCapacity()); end;') > 0,
            'MaxCapacity() returns a positive bound');
    end;

    [Test]
    procedure T15_MultipleHandlesIndependent()
    begin
        Assert.AreEqual('AB',
            RunText('var tb1: TextBuilder; var tb2: TextBuilder; procedure P(): Text begin tb1.Append(''A''); tb2.Append(''B''); exit(tb1.ToText() + tb2.ToText()); end;'),
            'distinct TextBuilder variables get distinct handles');
    end;

    // ===== Paren-less zero-arg member methods (Feature 1) =====

    [Test]
    procedure T16_ParenlessAppendLineAsStatement()
    begin
        // `Tb.AppendLine;` with no parens/args as a bare statement (previously "field not found").
        Assert.IsTrue(
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''a''); tb.AppendLine; tb.Append(''b''); exit(tb.Length()); end;') > 2,
            'paren-less AppendLine as a statement still appends a line terminator');
    end;

    [Test]
    procedure T17_ParenlessLengthGetter()
    begin
        Assert.AreEqual(5,
            RunInt('var tb: TextBuilder; procedure P(): Integer begin tb.Append(''hello''); exit(tb.Length); end;'),
            'x := Tb.Length (no parens) resolves as a paren-less 0-arg method call');
    end;

    // ================================================================================================
    // ALI Text Index Tests — §19.4-analog "native AL text array access" (Text[i] get/set).
    //
    // Same KILLER TRICK as the other runtime suites: the test app IS an AL host, so every
    // semantic question ("what does Text[i] return / accept?") is answered by writing the SAME
    // construct in NATIVE AL right here and Assert-ing equality against the interpreted result.
    // ================================================================================================

    local procedure RunExpectFail(Source: Text; var Result: Codeunit "ALI Exec Result")
    var
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsFalse(Result.Succeeded(), 'Succeeded must be false on a raised error');
    end;

    [Test]
    procedure T01_ReadReturnsAsciiCode()
    var
        Native: Integer;
        NativeText: Text;
    begin
        NativeText := 'Hello';
        Native := NativeText[2];
        Assert.AreEqual(Native, RunInt('trigger OnRun(): Integer var t: Text; begin t := ''Hello''; exit(t[2]); end;'), 'text[i] read returns the ASCII code');
    end;

    [Test]
    procedure T02_WriteAsciiCodeMutatesInPlace()
    var
        NativeText: Text;
    begin
        NativeText := 'Hello';
        NativeText[2] := 111;
        Assert.AreEqual(NativeText, RunText('procedure P(): Text var t: Text; begin t := ''Hello''; t[2] := 111; exit(t); end;'), 'text[i] := <ASCII int>');
    end;

    [Test]
    procedure T03_WriteSingleCharTextMutatesInPlace()
    var
        NativeText: Text;
    begin
        NativeText := 'Hello';
        NativeText[2] := 'o';
        Assert.AreEqual(NativeText, RunText('procedure P(): Text var t: Text; begin t := ''Hello''; t[2] := ''o''; exit(t); end;'), 'text[i] := <1-char text>');
    end;

    [Test]
    procedure T04_WriteFromCharVariable()
    var
        Ch: Char;
        NativeText: Text;
    begin
        NativeText := 'Hello';
        Ch := 111;
        NativeText[2] := Ch;
        Assert.AreEqual(NativeText, RunText('procedure P(): Text var t: Text; c: Char; begin t := ''Hello''; c := 111; t[2] := c; exit(t); end;'), 'text[i] := <Char variable>');
    end;

    [Test]
    procedure T05_OutOfBoundsRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('procedure P(): Text var t: Text; begin t := ''Hi''; t[9] := 111; exit(t); end;', Result);
    end;

    [Test]
    procedure T06_MultiCharTextSourceRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('procedure P(): Text var t: Text; begin t := ''Hello''; t[2] := ''xy''; exit(t); end;', Result);
    end;

    [Test]
    procedure T07_IndexingIntegerIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var n: Integer; begin n := 5; exit(n[1]); end;', Diags), 'indexing an Integer must be a compile error');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics');
    end;

    // ===== String-length declaration rules (native AL: fixed length 1..2048; Code bounded) =====

    [Test]
    procedure T08_BoundedTextOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Assigning a longer value than the declared Text length is a runtime error (native AL).
        RunExpectFail('procedure P(): Text var t: Text[5]; begin t := ''abcdefg''; exit(t); end;', Result);
    end;

    [Test]
    procedure T09_ZeroLengthTextIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Text var t: Text[0]; begin exit(''''); end;', Diags), 'Text[0] must be a compile error');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for Text[0]');
    end;

    [Test]
    procedure T10_NegativeLengthCodeIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Code var c: Code[-1]; begin exit(''''); end;', Diags), 'Code[-1] must be a compile error');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for Code[-1]');
    end;

    [Test]
    procedure T11_CodeWithoutLengthIsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Code var c: Code; begin exit(''''); end;', Diags), 'Code without a length must be a compile error');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for unbounded Code');
    end;

    [Test]
    procedure T12_LengthOver2048IsCompileError()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Text var t: Text[3000]; begin exit(''''); end;', Diags), 'Text[3000] exceeds the 2048 max and must be a compile error');
        Assert.IsTrue(Diags.HasErrors(), 'expected diagnostics for Text[3000]');
    end;

    [Test]
    procedure T13_UnboundedTextStillLegal()
    begin
        // `Text` without a length stays valid (only Code is required to be bounded).
        Assert.AreEqual('hello world', RunText('procedure P(): Text var t: Text; begin t := ''hello world''; exit(t); end;'), 'unbounded Text remains legal');
    end;

    [Test]
    procedure T14_IndexWriteBeyondContentSpaceExtends()
    begin
        // t[4] on a 2-char value: space-extends up to 4 (declared length 10 permits it).
        Assert.AreEqual('ab x', RunText('procedure P(): Text var t: Text[10]; begin t := ''ab''; t[4] := ''x''; exit(t); end;'), 'index write past content space-extends within declared length');
    end;

    [Test]
    procedure T15_IndexWriteBeyondDeclaredLengthRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // t[8] on Text[5]: extends past the declared length -> STORE_TEXT_CHK error.
        RunExpectFail('procedure P(): Text var t: Text[5]; begin t := ''ab''; t[8] := ''x''; exit(t); end;', Result);
    end;

    [Test]
    procedure T16_CharToTextImplicitConversion()
    begin
        // Native: a Char assigns implicitly into Text/Code as its single character.
        Assert.AreEqual('A', RunText('procedure P(): Text var t: Text; c: Char; begin c := 65; t := c; exit(t); end;'), 'Char -> Text assignment');
        Assert.AreEqual('B', RunText('procedure P(): Text var c: Char; begin c := 66; exit(F(c)); end; procedure F(t: Text): Text begin exit(t); end;'), 'Char -> Text argument');
        Assert.AreEqual('C', RunText('procedure P(): Text var c: Char; begin c := 67; exit(c); end;'), 'Char returned from a Text proc');
    end;

    // ================================================================================================
    // ALI BigText / SecretText / session-option tests.
    //
    // Covers the three surfaces added together: the BigText handle bank (AddText/GetSubText/
    // Length/TextPos/Read/Write), SecretText (IsEmpty/Unwrap/SecretStrSubstNo + the one-way
    // Text->SecretText conversion), and the ClientType/CurrentClientType/CurrentExecutionMode
    // builtins. Media/MediaSet are covered by their bind-time contract only — exercising the read
    // side needs a table with a Media field AND a Tenant Media row, which no test fixture has.
    // ================================================================================================

    local procedure AssertDiag(var Diags: Codeunit "ALI Diag Bag"; DiagCode: Text; Fragment: Text)
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if (Diags.GetCode(i) = DiagCode) and (StrPos(Diags.GetMessage(i), Fragment) > 0) then
                exit;
        Assert.Fail(StrSubstNo('expected diagnostic %1 containing <%2>; got: %3', DiagCode, Fragment, Diags.ToText()));
    end;

    // ===== BigText =====

    [Test]
    procedure T01_AddTextAndLength()
    begin
        Assert.AreEqual(10,
            RunInt('var bt: BigText; procedure P(): Integer begin bt.AddText(''hello''); bt.AddText(''world''); exit(bt.Length()); end;'),
            'AddText appends; Length() counts every character');
    end;

    [Test]
    procedure T02_GetSubTextIntoText()
    begin
        Assert.AreEqual('ell',
            RunText('var bt: BigText; var s: Text; procedure P(): Text begin bt.AddText(''hello''); bt.GetSubText(s, 2, 3); exit(s); end;'),
            'GetSubText(var Text, pos, len) writes back into the caller''s variable');
    end;

    [Test]
    procedure T03_GetSubTextToEnd()
    begin
        Assert.AreEqual('llo',
            RunText('var bt: BigText; var s: Text; procedure P(): Text begin bt.AddText(''hello''); bt.GetSubText(s, 3); exit(s); end;'),
            'the 2-arg overload runs to the end of the BigText');
    end;

    [Test]
    procedure T04_AddTextAtPosition()
    begin
        Assert.AreEqual('haello',
            RunText('var bt: BigText; var s: Text; procedure P(): Text begin bt.AddText(''hello''); bt.AddText(''a'', 2); bt.GetSubText(s, 1); exit(s); end;'),
            'AddText(Text, Integer) inserts at the 1-based position');
    end;

    [Test]
    procedure T05_TextPos()
    begin
        Assert.AreEqual(3,
            RunInt('var bt: BigText; procedure P(): Integer begin bt.AddText(''hello''); exit(bt.TextPos(''ll'')); end;'),
            'TextPos returns the 1-based position of the first occurrence');
    end;

    [Test]
    procedure T06_TextPosMissIsZero()
    begin
        Assert.AreEqual(0,
            RunInt('var bt: BigText; procedure P(): Integer begin bt.AddText(''hello''); exit(bt.TextPos(''zz'')); end;'),
            'TextPos returns 0 when the substring is absent');
    end;

    [Test]
    procedure T07_AddTextFromAnotherBigText()
    begin
        Assert.AreEqual('abcdef',
            RunText('var a: BigText; var b: BigText; var s: Text; procedure P(): Text begin a.AddText(''abc''); b.AddText(''def''); a.AddText(b); a.GetSubText(s, 1); exit(s); end;'),
            'AddText(BigText) resolves the BigText overload, not the Text one');
    end;

    [Test]
    procedure T08_GetSubTextIntoBigText()
    begin
        Assert.AreEqual('ell',
            RunText('var a: BigText; var b: BigText; var s: Text; procedure P(): Text begin a.AddText(''hello''); a.GetSubText(b, 2, 3); b.GetSubText(s, 1); exit(s); end;'),
            'GetSubText(var BigText, ...) fills the destination bank slot');
    end;

    [Test]
    procedure T09_WriteThenReadRoundTrip()
    begin
        Assert.AreEqual('roundtrip',
            RunText('var a: BigText; var b: BigText; var os: OutStream; var ins: InStream; var s: Text; procedure P(): Text begin a.AddText(''roundtrip''); a.Write(os); ins.Link(os); b.Read(ins); b.GetSubText(s, 1); exit(s); end;'),
            'Write(OutStream) then Read(InStream) round-trips the content');
    end;

    [Test]
    procedure T10_ClearResetsContent()
    begin
        Assert.AreEqual(0,
            RunInt('var bt: BigText; procedure P(): Integer begin bt.AddText(''hello''); Clear(bt); exit(bt.Length()); end;'),
            'Clear(BigText) empties the buffer in place');
    end;

    [Test]
    procedure T11_LocalBigTextIsFreshEveryCall()
    begin
        // A local handle is reclaimed at frame pop and reused, so the second call must NOT see
        // the first call's content (the recursion/reuse bug the handle lifecycle rules exist for).
        Assert.AreEqual(3,
            RunInt('trigger OnRun(): Integer begin Fill(); exit(Fill()); end; procedure Fill(): Integer var bt: BigText; begin bt.AddText(''abc''); exit(bt.Length()); end;'),
            'a BigText local starts empty on every call');
    end;

    [Test]
    procedure T12_UnknownMethodIsReported()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var bt: BigText; procedure P() begin bt.NoSuchMethod(); end;', Diags),
            'an unknown BigText method must not compile');
        AssertDiag(Diags, 'AL0132', 'BigText');
    end;

    [Test]
    procedure T13_WrongArityIsReported()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var bt: BigText; procedure P() begin bt.TextPos(); end;', Diags),
            'a known BigText method called with the wrong arity must not compile');
        AssertDiag(Diags, 'ALI916', 'TextPos');
    end;

    // ===== SecretText =====

    [Test]
    procedure T20_TextAssignsIntoSecretText()
    begin
        Assert.AreEqual('hunter2',
            RunText('var st: SecretText; procedure P(): Text begin st := ''hunter2''; exit(st.Unwrap()); end;'),
            'Text -> SecretText is implicit; Unwrap() gets the value back');
    end;

    [Test]
    procedure T21_IsEmptyOnUnassigned()
    begin
        Assert.IsTrue(
            RunBool('var st: SecretText; procedure P(): Boolean begin exit(st.IsEmpty()); end;'),
            'an unassigned SecretText is empty');
    end;

    [Test]
    procedure T22_IsEmptyAfterAssign()
    begin
        Assert.IsFalse(
            RunBool('var st: SecretText; procedure P(): Boolean begin st := ''x''; exit(st.IsEmpty()); end;'),
            'an assigned SecretText is not empty');
    end;

    [Test]
    procedure T23_SecretStrSubstNo()
    begin
        Assert.AreEqual('user=bob pwd=s3cr3t',
            RunText('var st: SecretText; var r: SecretText; procedure P(): Text begin st := ''s3cr3t''; r := SecretStrSubstNo(''user=%1 pwd=%2'', ''bob'', st); exit(r.Unwrap()); end;'),
            'SecretStrSubstNo formats like StrSubstNo and yields a SecretText');
    end;

    [Test]
    procedure T24_SecretTextDoesNotAssignToText()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The whole point of the type: the conversion is one-way, so a leak needs an explicit
        // Unwrap() the reader can see.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var st: SecretText; var t: Text; procedure P() begin st := ''x''; t := st; end;', Diags),
            'SecretText -> Text must not compile without Unwrap()');
    end;

    // ===== Media / MediaSet =====

    [Test]
    procedure T30_MediaIsNotAVariableType()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Matches native alc, which rejects `M: Media` with AL0157.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var m: Media; procedure P() begin end;', Diags),
            'Media must not be declarable as a variable');
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var m: MediaSet; procedure P() begin end;', Diags),
            'MediaSet must not be declarable as a variable');
        AssertDiag(Diags, 'ALI924', 'MediaSet');
    end;

    [Test]
    procedure T31_MediaFieldQueryMethodsBind()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Bind-time only: reading a real picture needs a Tenant Media row no fixture creates.
        // Customer.Image is Media and Item.Picture is MediaSet in the base application.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('var c: Record Customer; procedure P(): Boolean begin exit(c.Image.HasValue()); end;', Diags),
            StrSubstNo('Media query methods must bind: %1', Diags.ToText()));
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('var i: Record Item; procedure P(): Integer begin exit(i.Picture.Count()); end;', Diags),
            StrSubstNo('MediaSet query methods must bind: %1', Diags.ToText()));
    end;

    [Test]
    procedure T32_MediaImportIsRefused()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The write side has no FieldRef-only equivalent, so it is refused at bind time rather
        // than silently doing nothing at runtime.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record Customer; var ins: InStream; procedure P() begin c.Image.ImportStream(ins, ''image/png''); end;', Diags),
            'Media.ImportStream must not compile');
        AssertDiag(Diags, 'ALI997', 'ImportStream');
    end;

    // ===== Session options =====

    [Test]
    procedure T40_CurrentClientTypeIsAnOrdinal()
    begin
        Assert.IsTrue(
            RunInt('trigger OnRun(): Integer begin exit(CurrentClientType()); end;') >= 0,
            'CurrentClientType() returns the client-type ordinal');
    end;

    [Test]
    procedure T41_CurrentClientTypeParenLess()
    begin
        Assert.AreEqual(
            RunInt('trigger OnRun(): Integer begin exit(CurrentClientType()); end;'),
            RunInt('trigger OnRun(): Integer begin exit(CurrentClientType); end;'),
            'the paren-less spelling resolves to the same builtin');
    end;

    [Test]
    procedure T42_CurrentExecutionMode()
    begin
        Assert.IsTrue(
            RunInt('trigger OnRun(): Integer begin exit(CurrentExecutionMode()); end;') >= 0,
            'CurrentExecutionMode() returns the execution-mode ordinal');
    end;

    // ================================================================================================
    // ALI Json Tests (Feature 2) — JsonObject/JsonArray/JsonToken/JsonValue surface over the
    // unified "ALI Json Runtime" token bank, mirroring "ALI Http Tests"' pipeline-driven style.
    // ================================================================================================

    local procedure ExpectCompileError(Source: Text)
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsFalse(Pipeline.TryCompileAndRun(Source, Result, Interp), StrSubstNo('expected a compile error for <%1>', Source));
    end;

    // ===== JsonObject: ReadFrom/WriteTo round-trip, Add overload dispatch, Get/Contains =====

    [Test]
    procedure T01_ObjectReadFromWriteToRoundTrip()
    begin
        Assert.AreEqual('{"a":1}',
            RunText('var o: JsonObject; var out: Text; procedure P(): Text begin o.ReadFrom(''{"a":1}''); o.WriteTo(out); exit(out); end;'),
            'JsonObject ReadFrom then WriteTo round-trips the same JSON text');
    end;

    [Test]
    procedure T02_ObjectAddTextThenContains()
    begin
        Assert.IsTrue(
            RunBool('var o: JsonObject; procedure P(): Boolean begin o.Add(''name'', ''eca''); exit(o.Contains(''name'')); end;'),
            'Add(Text) then Contains() sees the added key');
    end;

    [Test]
    procedure T03_ObjectAddIntegerGetAsValue()
    begin
        Assert.AreEqual(42,
            RunInt('var o: JsonObject; var t: JsonToken; procedure P(): Integer begin o.Add(''n'', 42); o.Get(''n'', t); exit(t.AsValue().AsInteger()); end;'),
            'Add(Integer) then Get(var JsonToken) navigates to the stored integer via AsValue().AsInteger()');
    end;

    [Test]
    procedure T04_ObjectAddDecimalBoolean()
    begin
        Assert.IsTrue(
            RunBool('var o: JsonObject; var t: JsonToken; procedure P(): Boolean begin o.Add(''d'', 1.5); o.Add(''b'', true); o.Get(''b'', t); exit(t.AsValue().AsBoolean()); end;'),
            'Add(Decimal) and Add(Boolean) overloads dispatch and store correctly');
    end;

    [Test]
    procedure T05_ObjectAddNestedObjectValue()
    begin
        Assert.AreEqual(7,
            RunInt('var o: JsonObject; var inner: JsonObject; var t: JsonToken; var innerTok: JsonToken; procedure P(): Integer begin inner.Add(''x'', 7); o.Add(''child'', inner); o.Get(''child'', t); t.AsObject().Get(''x'', innerTok); exit(innerTok.AsValue().AsInteger()); end;'),
            'Add(JsonObject) stores a nested object; navigating back down finds the same value');
    end;

    [Test]
    procedure T06_ObjectAddNestedArray()
    begin
        Assert.AreEqual(1,
            RunInt('var o: JsonObject; var arr: JsonArray; var t: JsonToken; procedure P(): Integer begin arr.Add(1); o.Add(''list'', arr); o.Get(''list'', t); exit(t.AsArray().Count()); end;'),
            'Add(JsonArray) stores a nested array reachable via Get + AsArray');
    end;

    [Test]
    procedure T07_ObjectAddTokenOverload()
    begin
        Assert.AreEqual(9,
            RunInt('var o: JsonObject; var v: JsonValue; var t: JsonToken; var got: JsonToken; procedure P(): Integer begin v.SetValue(9); o.Add(''k'', v.AsToken()); o.Get(''k'', got); exit(got.AsValue().AsInteger()); end;'),
            'Add(JsonToken) overload (via JsonValue.AsToken()) stores the token value');
    end;

    [Test]
    procedure T08_ObjectRemove()
    begin
        Assert.IsFalse(
            RunBool('var o: JsonObject; procedure P(): Boolean begin o.Add(''k'', 1); o.Remove(''k''); exit(o.Contains(''k'')); end;'),
            'Remove(name) drops the key');
    end;

    [Test]
    procedure T09_ObjectReplace()
    begin
        Assert.AreEqual(2,
            RunInt('var o: JsonObject; var nv: JsonValue; var t: JsonToken; procedure P(): Integer begin o.Add(''k'', 1); nv.SetValue(2); o.Replace(''k'', nv.AsToken()); o.Get(''k'', t); exit(t.AsValue().AsInteger()); end;'),
            'Replace(name, JsonToken) overwrites the existing value');
    end;

    [Test]
    procedure T10_ObjectKeysCount()
    begin
        Assert.AreEqual(2,
            RunInt('var o: JsonObject; var ks: List of [Text]; procedure P(): Integer begin o.Add(''a'', 1); o.Add(''b'', 2); ks := o.Keys(); exit(ks.Count()); end;'),
            'Keys() returns a List of [Text] with one entry per key');
    end;

    [Test]
    procedure T11_ObjectCount()
    begin
        Assert.AreEqual(2,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.Add(''a'', 1); o.Add(''b'', 2); exit(o.Count()); end;'),
            'Count() reflects the number of added keys');
    end;

    [Test]
    procedure T12_ObjectGetMissingKeyReturnsFalse()
    begin
        Assert.IsFalse(
            RunBool('var o: JsonObject; var t: JsonToken; procedure P(): Boolean begin exit(o.Get(''missing'', t)); end;'),
            'Get() on a missing key returns false');
    end;

    // ===== JsonArray: 0-based indexes, Add overload dispatch, Get/Set/Insert/RemoveAt/IndexOf =====

    [Test]
    procedure T13_ArrayAddIntegerGetZeroBased()
    begin
        Assert.AreEqual(10,
            RunInt('var a: JsonArray; var t: JsonToken; procedure P(): Integer begin a.Add(10); a.Add(20); a.Get(0, t); exit(t.AsValue().AsInteger()); end;'),
            'JsonArray uses native 0-based indexes: Get(0, ...) is the FIRST element');
    end;

    [Test]
    procedure T14_ArrayGetSecondElement()
    begin
        Assert.AreEqual(20,
            RunInt('var a: JsonArray; var t: JsonToken; procedure P(): Integer begin a.Add(10); a.Add(20); a.Get(1, t); exit(t.AsValue().AsInteger()); end;'),
            'Get(1, ...) is the SECOND element under 0-based indexing');
    end;

    [Test]
    procedure T15_ArrayCount()
    begin
        Assert.AreEqual(3,
            RunInt('var a: JsonArray; procedure P(): Integer begin a.Add(1); a.Add(2); a.Add(3); exit(a.Count()); end;'),
            'Count() reflects the number of added elements');
    end;

    [Test]
    procedure T16_ArraySet()
    begin
        Assert.AreEqual(99,
            RunInt('var a: JsonArray; var v: JsonValue; var t: JsonToken; procedure P(): Integer begin a.Add(1); v.SetValue(99); a.Set(0, v.AsToken()); a.Get(0, t); exit(t.AsValue().AsInteger()); end;'),
            'Set(idx, JsonToken) overwrites the element at the given 0-based index');
    end;

    [Test]
    procedure T17_ArrayInsert()
    begin
        Assert.AreEqual(77,
            RunInt('var a: JsonArray; var v: JsonValue; var t: JsonToken; procedure P(): Integer begin a.Add(1); a.Add(2); v.SetValue(77); a.Insert(1, v.AsToken()); a.Get(1, t); exit(t.AsValue().AsInteger()); end;'),
            'Insert(idx, JsonToken) splices a value at the given 0-based position');
    end;

    [Test]
    procedure T18_ArrayRemoveAt()
    begin
        Assert.AreEqual(2,
            RunInt('var a: JsonArray; var t: JsonToken; procedure P(): Integer begin a.Add(1); a.Add(2); a.RemoveAt(0); a.Get(0, t); exit(t.AsValue().AsInteger()); end;'),
            'RemoveAt(0) drops the first (0-based) element, shifting the rest down');
    end;

    [Test]
    procedure T19_ArrayIndexOf()
    begin
        Assert.AreEqual(1,
            RunInt('var a: JsonArray; var v: JsonValue; procedure P(): Integer begin a.Add(10); a.Add(20); a.Add(30); v.SetValue(20); exit(a.IndexOf(v.AsToken())); end;'),
            'IndexOf(JsonToken) returns the 0-based position of a matching value');
    end;

    [Test]
    procedure T20_ArrayWriteToReadFromRoundTrip()
    begin
        Assert.AreEqual('[1,2,3]',
            RunText('var a: JsonArray; var out: Text; procedure P(): Text begin a.ReadFrom(''[1,2,3]''); a.WriteTo(out); exit(out); end;'),
            'JsonArray ReadFrom then WriteTo round-trips the same JSON text');
    end;

    // ===== Alias sharing vs Clone independence (reference semantics of `o2 := o1`) =====

    [Test]
    procedure T21_AssignmentAliasesSameDom()
    begin
        // o2 := o1 (same kind) shares the underlying DOM node — a mutation through o2 must be
        // visible through o1, matching native AL JsonObject reference semantics.
        Assert.IsTrue(
            RunBool('var o1: JsonObject; var o2: JsonObject; procedure P(): Boolean begin o1.Add(''x'', 1); o2 := o1; o2.Add(''y'', 2); exit(o1.Contains(''y'')); end;'),
            'o2 := o1 aliases the same backing JsonObject DOM');
    end;

    [Test]
    procedure T22_CloneIsIndependent()
    begin
        Assert.IsFalse(
            RunBool('var o1: JsonObject; var o2: JsonObject; procedure P(): Boolean begin o1.Add(''x'', 1); o2 := o1.Clone(); o2.Add(''y'', 2); exit(o1.Contains(''y'')); end;'),
            'Clone() produces an independent DOM: mutating the clone must NOT affect the original');
    end;

    [Test]
    procedure T23_TwoIndependentlyDeclaredObjectsDoNotAlias()
    begin
        Assert.IsFalse(
            RunBool('var o1: JsonObject; var o2: JsonObject; procedure P(): Boolean begin o1.Add(''x'', 1); exit(o2.Contains(''x'')); end;'),
            'two separately declared JsonObject variables do not share a DOM by default');
    end;

    // ===== Nested navigation: AsToken/AsObject/AsArray/AsValue chains =====

    [Test]
    procedure T24_TokenIsObjectIsArrayIsValue()
    begin
        Assert.IsTrue(
            RunBool('var o: JsonObject; var t: JsonToken; procedure P(): Boolean begin t := o.AsToken(); exit(t.IsObject() and (not t.IsArray()) and (not t.IsValue())); end;'),
            'AsToken() on a JsonObject yields a token that reports IsObject() true, IsArray()/IsValue() false');
    end;

    [Test]
    procedure T25_TokenAsObjectAsValueChain()
    begin
        Assert.AreEqual(5,
            RunInt('var o: JsonObject; var t: JsonToken; var vt: JsonToken; procedure P(): Integer begin o.Add(''n'', 5); t := o.AsToken(); t.SelectToken(''n'', vt); exit(vt.AsValue().AsInteger()); end;'),
            'SelectToken navigates a path from the root token down to a leaf value');
    end;

    [Test]
    procedure T26_TokenAsArrayCount()
    begin
        Assert.AreEqual(2,
            RunInt('var a: JsonArray; var t: JsonToken; procedure P(): Integer begin a.Add(1); a.Add(2); t := a.AsToken(); exit(t.AsArray().Count()); end;'),
            'JsonArray.AsToken() then JsonToken.AsArray() round-trips back to an array view with the same Count()');
    end;

    // ===== JsonValue: SetValue/As* conversions + IsNull =====

    [Test]
    procedure T27_ValueSetTextAsText()
    begin
        Assert.AreEqual('hello',
            RunText('var v: JsonValue; procedure P(): Text begin v.SetValue(''hello''); exit(v.AsText()); end;'),
            'SetValue(Text) then AsText() round-trips');
    end;

    [Test]
    procedure T28_ValueSetIntegerAsInteger()
    begin
        Assert.AreEqual(123,
            RunInt('var v: JsonValue; procedure P(): Integer begin v.SetValue(123); exit(v.AsInteger()); end;'),
            'SetValue(Integer) then AsInteger() round-trips');
    end;

    [Test]
    procedure T29_ValueSetBooleanAsBoolean()
    begin
        Assert.IsTrue(
            RunBool('var v: JsonValue; procedure P(): Boolean begin v.SetValue(true); exit(v.AsBoolean()); end;'),
            'SetValue(Boolean) then AsBoolean() round-trips');
    end;

    [Test]
    procedure T30_ValueSetDateAsDate()
    begin
        Assert.IsTrue(
            RunBool('var v: JsonValue; procedure P(): Boolean begin v.SetValue(20250101D); exit(v.AsDate() = 20250101D); end;'),
            'SetValue(Date) then AsDate() round-trips');
    end;

    [Test]
    procedure T31_ValueIsNullOnFreshValue()
    begin
        Assert.IsTrue(
            RunBool('var v: JsonValue; procedure P(): Boolean begin exit(v.IsNull()); end;'),
            'a freshly declared JsonValue reports IsNull() true before SetValue is called');
    end;

    [Test]
    procedure T32_ValueIsNullFalseAfterSetValue()
    begin
        Assert.IsFalse(
            RunBool('var v: JsonValue; procedure P(): Boolean begin v.SetValue(1); exit(v.IsNull()); end;'),
            'IsNull() is false once a value has been set');
    end;

    // ===== WriteTo into local, global, and var-param Text =====

    [Test]
    procedure T33_WriteToLocalText()
    begin
        Assert.AreEqual('{"a":1}',
            RunText('procedure P(): Text var o: JsonObject; buf: Text; begin o.Add(''a'', 1); o.WriteTo(buf); exit(buf); end;'),
            'WriteTo writes into a proc-local Text variable');
    end;

    [Test]
    procedure T34_WriteToGlobalText()
    begin
        Assert.AreEqual('{"a":1}',
            RunText('var g: Text; procedure P(): Text var o: JsonObject; begin o.Add(''a'', 1); o.WriteTo(g); exit(g); end;'),
            'WriteTo writes into a module-level global Text variable');
    end;

    [Test]
    procedure T35_WriteToVarParamText()
    begin
        Assert.AreEqual('{"a":1}',
            RunText('procedure P(): Text var out: Text; begin Dump(out); exit(out); end; ' +
                     'procedure Dump(var t: Text) var o: JsonObject; begin o.Add(''a'', 1); o.WriteTo(t); end;'),
            'WriteTo writes back through a var-param Text argument');
    end;

    // ===== Handle lifecycle =====

    [Test]
    procedure T36_LocalJsonDoesNotLeakAcrossManyCalls()
    begin
        // Before the Feature 2 fix, every proc-local Json* handle allocated in a loop of this
        // size would exhaust the live-collection cap (ALI972-style) unless PopFrame reclaims
        // Bump's local handle each call. Mirrors ALIListDictTests T39/T40.
        Assert.AreEqual(10000,
            RunInt('var g: Integer; procedure P(): Integer var i: Integer; begin g := 0; for i := 1 to 10000 do Bump(); exit(g); end; ' +
                   'procedure Bump() var o: JsonObject; t: JsonToken; begin o.Add(''n'', 1); o.Get(''n'', t); g := g + t.AsValue().AsInteger(); end;'),
            'a local JsonObject declared in a proc called many times must not exhaust the live-collection cap');
    end;

    [Test]
    procedure T37_GlobalJsonSurvivesProcExit()
    begin
        Assert.AreEqual(1,
            RunInt('var g: JsonObject; procedure P(): Integer begin Fill(); exit(g.Count()); end; procedure Fill() begin g.Add(''x'', 1); end;'),
            'a global JsonObject mutated in one proc is still populated after that proc returns');
    end;

    [Test]
    procedure T38_JsonReturnedByValueSurvivesCalleePop()
    begin
        Assert.AreEqual(20,
            RunInt('trigger OnRun(): Integer var o: JsonObject; t: JsonToken; begin o := MakeObj(); o.Get(''v'', t); exit(t.AsValue().AsInteger()); end; ' +
                   'procedure MakeObj(): JsonObject var r: JsonObject; begin r.Add(''v'', 20); exit(r); end;'),
            'a JsonObject handle returned by value (exit(r)) must still be valid after that proc''s frame pops (HANDLE_ESCAPE)');
    end;

    [Test]
    procedure T39_JsonAssignedThroughVarParamSurvivesCalleePop()
    begin
        Assert.AreEqual(30,
            RunInt('trigger OnRun(): Integer var o: JsonObject; t: JsonToken; begin MakeInto(o); o.Get(''v'', t); exit(t.AsValue().AsInteger()); end; ' +
                   'procedure MakeInto(var outp: JsonObject) var r: JsonObject; begin r.Add(''v'', 30); outp := r; end;'),
            'a JsonObject handle assigned through a var-param must still be valid after the callee''s frame pops');
    end;

    // ===== Compile errors =====

    [Test]
    procedure T40_UnknownMethodRejected()
    begin
        ExpectCompileError('var o: JsonObject; procedure P() begin o.Frobnicate(); end;');
    end;

    [Test]
    procedure T41_WrongArityRejected()
    begin
        // Add on JsonObject needs exactly 2 args (name, value).
        ExpectCompileError('var o: JsonObject; procedure P() begin o.Add(''onlyname''); end;');
    end;

    [Test]
    procedure T42_CrossKindAssignmentRejected()
    begin
        ExpectCompileError('var o: JsonObject; var t: JsonToken; procedure P() begin o := t; end;');
    end;

    [Test]
    procedure T43_ObjectAddUnsupportedValueTypeRejected()
    begin
        ExpectCompileError('var o: JsonObject; var d: Record "Customer"; procedure P() begin o.Add(''k'', d); end;');
    end;

    [Test]
    procedure T44_WriteToNonTextArgRejected()
    begin
        ExpectCompileError('var o: JsonObject; var i: Integer; procedure P() begin o.WriteTo(i); end;');
    end;

    // ===== Paren-less calls on Json handles (Feature 1 dispatch hooked into TryDispatchMemberMethod) =====

    [Test]
    procedure T45_ParenlessCountOnObject()
    begin
        Assert.AreEqual(1,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.Add(''a'', 1); exit(o.Count); end;'),
            'o.Count (no parens) resolves as a paren-less 0-arg method call');
    end;

    [Test]
    procedure T46_ParenlessIsObjectAsStatement()
    begin
        // IsObject() as a paren-less statement: return value discarded, must not raise ALI913
        // (it dispatches through TryDispatchMemberMethod, not the plain-field-read path).
        Assert.AreEqual(1,
            RunInt('var o: JsonObject; var t: JsonToken; procedure P(): Integer begin t := o.AsToken(); t.IsObject; exit(1); end;'),
            'a paren-less Json method used as a bare statement compiles and runs');
    end;

    // ===== Typed GetX getters (JSON_METHOD2): GetText/GetInteger/... [, DefaultIfNotFound] =====

    [Test]
    procedure T47_ObjectGetText()
    begin
        Assert.AreEqual('eca',
            RunText('var o: JsonObject; procedure P(): Text begin o.ReadFrom(''{"name":"eca"}''); exit(o.GetText(''name'')); end;'),
            'JsonObject.GetText(key) returns the text value directly');
    end;

    [Test]
    procedure T48_ObjectGetIntegerAndDecimal()
    begin
        Assert.AreEqual(42,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.ReadFrom(''{"n":42,"d":1.5}''); exit(o.GetInteger(''n'')); end;'),
            'JsonObject.GetInteger(key) returns the integer value directly');
    end;

    [Test]
    procedure T49_ObjectGetBoolean()
    begin
        Assert.IsTrue(
            RunBool('var o: JsonObject; procedure P(): Boolean begin o.ReadFrom(''{"b":true}''); exit(o.GetBoolean(''b'')); end;'),
            'JsonObject.GetBoolean(key) returns the boolean value directly');
    end;

    [Test]
    procedure T50_ObjectGetObjectChained()
    begin
        Assert.AreEqual(7,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.ReadFrom(''{"child":{"x":7}}''); exit(o.GetObject(''child'').GetInteger(''x'')); end;'),
            'JsonObject.GetObject(key) returns a JsonObject usable as a chained receiver');
    end;

    [Test]
    procedure T51_ObjectGetArrayCount()
    begin
        Assert.AreEqual(3,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.ReadFrom(''{"l":[1,2,3]}''); exit(o.GetArray(''l'').Count()); end;'),
            'JsonObject.GetArray(key) returns a JsonArray usable as a chained receiver');
    end;

    [Test]
    procedure T52_ObjectGetValueAsInteger()
    begin
        Assert.AreEqual(9,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.ReadFrom(''{"v":9}''); exit(o.GetValue(''v'').AsInteger()); end;'),
            'JsonObject.GetValue(key) returns a JsonValue usable as a chained receiver');
    end;

    [Test]
    procedure T53_ObjectGetTextDefaultIfNotFound()
    begin
        Assert.AreEqual('',
            RunText('var o: JsonObject; procedure P(): Text begin o.ReadFrom(''{"a":1}''); exit(o.GetText(''missing'', true)); end;'),
            'GetText(key, true) returns blank default when the key is missing');
    end;

    [Test]
    procedure T54_ObjectGetMissingKeyErrors()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsFalse(
            Pipeline.CompileAndRun('var o: JsonObject; procedure P(): Text begin o.ReadFrom(''{"a":1}''); exit(o.GetText(''missing'')); end;', Result, Interp),
            'GetText(key) without DefaultIfNotFound raises a runtime error on a missing key');
    end;

    [Test]
    procedure T55_ArrayGetTextAndInteger()
    begin
        Assert.AreEqual('b',
            RunText('var a: JsonArray; procedure P(): Text begin a.ReadFrom(''["a","b"]''); exit(a.GetText(1)); end;'),
            'JsonArray.GetText(index) returns the element text (0-based index)');
    end;

    [Test]
    procedure T56_ArrayGetObjectChained()
    begin
        Assert.AreEqual(5,
            RunInt('var a: JsonArray; procedure P(): Integer begin a.ReadFrom(''[{"x":5}]''); exit(a.GetObject(0).GetInteger(''x'')); end;'),
            'JsonArray.GetObject(index) returns a JsonObject usable as a chained receiver');
    end;

    [Test]
    procedure T57_ArrayGetIntegerDefaultIfNotFound()
    begin
        Assert.AreEqual(0,
            RunInt('var a: JsonArray; procedure P(): Integer begin a.ReadFrom(''[1]''); exit(a.GetInteger(9, true)); end;'),
            'JsonArray.GetInteger(index, true) returns blank default when the index is out of range');
    end;

    [Test]
    procedure T58_ObjectGetDecimal()
    begin
        Assert.IsTrue(
            RunBool('var o: JsonObject; procedure P(): Boolean begin o.ReadFrom(''{"d":1.5}''); exit(o.GetDecimal(''d'') = 1.5); end;'),
            'JsonObject.GetDecimal(key) returns the decimal value directly');
    end;

    [Test]
    procedure T59_GetterBadArgTypeRejected()
    begin
        ExpectCompileError('var o: JsonObject; procedure P(): Text begin exit(o.GetText(1)); end;');
    end;

    [Test]
    procedure T60_ObjectGetByteCharOption()
    begin
        Assert.AreEqual(200 + 65 + 2,
            RunInt('var o: JsonObject; b: Byte; c: Char; op: Option A,B,C; procedure P(): Integer begin o.ReadFrom(''{"b":200,"c":"A","o":2}''); b := o.GetByte(''b''); c := o.GetChar(''c''); op := o.GetOption(''o''); exit(b + c + op); end;'),
            'JsonObject.GetByte/GetChar/GetOption(key) return the typed values');
    end;

    [Test]
    procedure T61_ObjectGetByteDefaultIfNotFound()
    begin
        Assert.AreEqual(0,
            RunInt('var o: JsonObject; procedure P(): Integer begin o.ReadFrom(''{}''); exit(o.GetByte(''x'', true) + o.GetChar(''x'', true) + o.GetOption(''x'', true)); end;'),
            'GetByte/GetChar/GetOption(key, true) return blank default when the key is missing');
    end;

    [Test]
    procedure T62_ArrayGetByteCharOption()
    begin
        Assert.AreEqual(7 + 66 + 1,
            RunInt('var a: JsonArray; c: Char; procedure P(): Integer begin a.ReadFrom(''[7,"B",1]''); c := a.GetChar(1); exit(a.GetByte(0) + c + a.GetOption(2)); end;'),
            'JsonArray.GetByte/GetChar/GetOption(index) return the typed values');
    end;

    [Test]
    procedure T63_ArrayGetByteDefaultRejected()
    begin
        // native JsonArray.GetByte/GetChar/GetOption have no DefaultIfNotFound overload
        ExpectCompileError('var a: JsonArray; procedure P(): Integer begin exit(a.GetByte(0, true)); end;');
    end;

    [Test]
    procedure T64_ValueAsByteCharOption()
    begin
        Assert.AreEqual(9 + 9 + 67,
            RunInt('var v: JsonValue; w: JsonValue; t: JsonToken; c: Char; procedure P(): Integer begin t.ReadFrom(''9''); v := t.AsValue(); t.ReadFrom(''"C"''); w := t.AsValue(); c := w.AsChar(); exit(v.AsByte() + v.AsOption() + c); end;'),
            'JsonValue.AsByte/AsChar/AsOption convert the value');
    end;

    // ================================================================================================
    // ALI Http Tests (M10) — network-free: HttpClient/HttpRequestMessage/HttpResponseMessage/
    // HttpContent/HttpHeaders declare/bind/lower correctly, := gives reference semantics (List/
    // Dict Int-handle scheme), and the network-facing methods stay gated by AllowHttp (default
    // false) even when reached. No test calls Client.Get/Post/Put/Delete/Send against a real
    // endpoint — that needs a live BC service (see "ALI Http Runtime" AllowHttp gate) and is
    // deliberately out of scope here.
    // ================================================================================================

    [Test]
    procedure T01_HeadersAddContains()
    begin
        Assert.IsTrue(
            RunBool('var h: HttpHeaders; procedure P(): Boolean begin h.Add(''X-Test'', ''1''); exit(h.Contains(''X-Test'')); end;'),
            'Add() then Contains() sees the header name');
    end;

    [Test]
    procedure T02_HeadersRemove()
    begin
        Assert.IsFalse(
            RunBool('var h: HttpHeaders; procedure P(): Boolean begin h.Add(''X-Test'', ''1''); h.Remove(''X-Test''); exit(h.Contains(''X-Test'')); end;'),
            'Remove() drops a header Contains() no longer sees');
    end;

    [Test]
    procedure T03_AssignmentIsReferenceSemantics()
    begin
        // h2 := h1 (same kind) is a plain Int-handle copy (List/Dict scheme) — mutating
        // through h2 must be visible via h1, proving both point at the SAME backing object.
        Assert.IsTrue(
            RunBool('var h1: HttpHeaders; var h2: HttpHeaders; procedure P(): Boolean begin h2 := h1; h2.Add(''X-Test'', ''1''); exit(h1.Contains(''X-Test'')); end;'),
            ':= between same-kind Http vars shares the underlying handle');
    end;

    [Test]
    procedure T04_ContentWriteAndReadAs()
    begin
        Assert.AreEqual('hello',
            RunText('var c: HttpContent; procedure P(): Text begin c.WriteFrom(''hello''); exit(c.ReadAs()); end;'),
            'WriteFrom/ReadAs round-trip the body text');
    end;

    [Test]
    procedure T05_RequestMethodSetterGetter()
    begin
        Assert.AreEqual('GET',
            RunText('var r: HttpRequestMessage; procedure P(): Text begin r.Method(''GET''); exit(r.Method()); end;'),
            'Method(Text) setter then Method() getter round-trips');
    end;

    [Test]
    procedure T06_HandleReturningMethodAssignment()
    begin
        // request.GetHeaders() -> HttpHeaders assigned into a var, then mutated via that var —
        // the "handle-returning method + assignment" mechanic the plan called out as new
        // ground; here it is a plain Int result write, same as any other builtin.
        Assert.IsTrue(
            RunBool('var r: HttpRequestMessage; h: HttpHeaders; procedure P(): Boolean begin h := r.GetHeaders(); h.Add(''X-Test'', ''1''); exit(h.Contains(''X-Test'')); end;'),
            'A handle-returning method assigns a usable Http* handle into a var');
    end;

    [Test]
    procedure T07_CrossKindAssignmentRejected()
    begin
        ExpectCompileError('var c: HttpContent; var h: HttpHeaders; procedure P() begin h := c; end;');
    end;

    [Test]
    procedure T08_UnknownMethodRejected()
    begin
        ExpectCompileError('var c: HttpClient; procedure P() begin c.Frobnicate(); end;');
    end;

    [Test]
    procedure T09_GetValuesWrongListElementRejected()
    begin
        ExpectCompileError('var h: HttpHeaders; var l: List of [Integer]; procedure P() begin h.GetValues(''X'', l); end;');
    end;

    [Test]
    procedure T10_GetValuesIntoTextList()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(
            'var h: HttpHeaders; var l: List of [Text]; procedure P(): Integer begin h.Add(''X-Test'', ''1''); h.GetValues(''X-Test'', l); exit(l.Count()); end;',
            Result, Interp), StrSubstNo('compile/run OK: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'GetValues refills the caller-owned List of [Text] in place');
    end;

    [Test]
    procedure T11_HttpSendGatedByAllowHttp()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // Network methods stay off by default (AllowHttp() = false) even when reached at
        // runtime — this is the ALI982 capability gate, not a compile-time restriction.
        Assert.IsFalse(
            Pipeline.CompileAndRun('var cl: HttpClient; var resp: HttpResponseMessage; procedure P(): Boolean begin exit(cl.Get(''https://example.invalid'', resp)); end;',
                Result, Interp),
            'Get() without AllowHttp fails the run (ALI982)');
    end;

    // ===== Handle Lifecycle Unification (the "stale Http* handle" bug) =====
    //
    // Before the fix, PopFrame freed EVERY Http* handle a frame allocated unconditionally —
    // including one being handed back to the caller via exit(h) or a var-param. The caller
    // then held a handle into a bank slot that had already been reset (Box.SetVal(Blank)),
    // so reads through it silently came back empty/wrong instead of the value the callee set.

    [Test]
    procedure T12_ReturnedHttpHeadersSurvivesCalleePop()
    begin
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var h: HttpHeaders; begin h := MakeHeaders(); exit(h.Contains(''X-Test'')); end; ' +
                    'procedure MakeHeaders(): HttpHeaders var r: HttpHeaders; begin r.Add(''X-Test'', ''1''); exit(r); end;'),
            'a HttpHeaders handle returned by value from a proc must still see the header set before that proc''s frame popped');
    end;

    [Test]
    procedure T13_HttpHeadersAssignedThroughVarParamSurvivesCalleePop()
    begin
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var h: HttpHeaders; begin MakeInto(h); exit(h.Contains(''X-Test'')); end; ' +
                    'procedure MakeInto(var outp: HttpHeaders) var r: HttpHeaders; begin r.Add(''X-Test'', ''1''); outp := r; end;'),
            'a HttpHeaders handle assigned through a var-param must still be valid after the callee''s frame pops');
    end;

    [Test]
    procedure T14_RequestGetHeadersIntoArgForm()
    begin
        // Native shape GetHeaders(var Headers) — fills the passed handle in place; adding through
        // it mutates the request's headers (reference semantics), same as native AL.
        Assert.IsTrue(
            RunBool('var r: HttpRequestMessage; var h: HttpHeaders; procedure P(): Boolean begin r.GetHeaders(h); h.Add(''X-Test'', ''1''); exit(h.Contains(''X-Test'')); end;'),
            'GetHeaders(var Headers) fills the caller''s handle in place');
    end;

    [Test]
    procedure T15_RequestMethodPropertyAssignment()
    begin
        // `r.Method := 'GET'` property-set form (vs the method-call setter r.Method('GET')).
        Assert.AreEqual('GET',
            RunText('var r: HttpRequestMessage; procedure P(): Text begin r.Method := ''GET''; exit(r.Method()); end;'),
            'Method := value assigns the request method as a property');
    end;

    [Test]
    procedure T16_ContentReadAsIntoArgForm()
    begin
        // Native shape ReadAs(var Text): Boolean — writes the body into the arg and returns
        // success; used here in an `if ... then` to prove both the write-back and the result.
        Assert.AreEqual('hello',
            RunText('var c: HttpContent; var t: Text; procedure P(): Text begin c.WriteFrom(''hello''); if c.ReadAs(t) then exit(t); exit(''''); end;'),
            'ReadAs(var Text) writes the body back into the caller''s Text variable');
    end;

    [Test]
    procedure T16a_ContentGetHeadersIntoArgForm()
    begin
        // Native shape HttpContent.GetHeaders(var Headers) — fills the passed handle in place;
        // the Content-Type written through it must be visible on the content's own headers.
        Assert.IsTrue(
            RunBool('var c: HttpContent; var h: HttpHeaders; procedure P(): Boolean begin c.WriteFrom(''{}''); c.GetHeaders(h); h.Remove(''Content-Type''); h.Add(''Content-Type'', ''application/json''); exit(c.GetHeaders().Contains(''Content-Type'')); end;'),
            'HttpContent.GetHeaders(var Headers) fills the caller''s handle in place');
    end;

    [Test]
    procedure T16b_RequestContentPropertyAssignment()
    begin
        // `r.Content := c` property-set form (vs the method-call setter r.Content(c)).
        Assert.AreEqual('body',
            RunText('var r: HttpRequestMessage; var c: HttpContent; procedure P(): Text begin c.WriteFrom(''body''); r.Content := c; exit(r.Content().ReadAs()); end;'),
            'Content := value assigns the request content as a property');
    end;

    // ===== Chained Http receivers (call-result receiver, no intermediate variable) =====

    [Test]
    procedure T17_ChainedDefaultRequestHeadersTryAdd()
    begin
        // Client.DefaultRequestHeaders().TryAddWithoutValidation(...) — the receiver of the
        // headers method is itself a handle-returning call, not a variable. Mutation through
        // the chained handle must reach the client's default headers (reference semantics).
        Assert.IsTrue(
            RunBool('var c: HttpClient; procedure P(): Boolean begin c.DefaultRequestHeaders().TryAddWithoutValidation(''Authorization'', ''Bearer x''); exit(c.DefaultRequestHeaders().Contains(''Authorization'')); end;'),
            'chained DefaultRequestHeaders().TryAddWithoutValidation() mutates the client''s headers');
    end;

    [Test]
    procedure T18_ChainedDefaultRequestHeadersParenless()
    begin
        // Same chain with the paren-less property form: c.DefaultRequestHeaders.TryAdd...
        Assert.IsTrue(
            RunBool('var c: HttpClient; procedure P(): Boolean begin c.DefaultRequestHeaders.TryAddWithoutValidation(''X-K'', ''v''); exit(c.DefaultRequestHeaders.Contains(''X-K'')); end;'),
            'paren-less DefaultRequestHeaders chained call compiles and mutates the client''s headers');
    end;

    [Test]
    procedure T19_ChainedContentReadAs()
    begin
        // Chained receiver on a request: r.Content().ReadAs() — same peek-typed dispatch.
        Assert.AreEqual('body',
            RunText('var r: HttpRequestMessage; var c: HttpContent; procedure P(): Text begin c.WriteFrom(''body''); r.Content(c); exit(r.Content().ReadAs()); end;'),
            'chained Content().ReadAs() reads through the call-result receiver');
    end;

    [Test]
    procedure T20_ChainedHeadersAddAsStatement()
    begin
        // Chained void method as a bare statement: c.DefaultRequestHeaders().Clear();
        Assert.IsTrue(
            RunBool('var c: HttpClient; procedure P(): Boolean begin c.DefaultRequestHeaders().Add(''X-A'', ''1''); c.DefaultRequestHeaders().Clear(); exit(not c.DefaultRequestHeaders().Contains(''X-A'')); end;'),
            'chained headers Add/Clear as statements run against the client''s live headers');
    end;

    // ================================================================================================
    // ALI Xml Tests (Feature 3) — Xml* family surface over "ALI Xml Runtime" (unified NodeBank +
    // side banks), mirroring "ALI Json Tests"' pipeline-driven style. Covers declaration-time New,
    // statics on type-name receivers (XML_DESIGN.md §4), variadic content (§6), var-out shapes
    // (§7), XPath, attributes, foreach over XmlNodeList/XmlAttributeCollection (§9).
    // ================================================================================================

    local procedure RunXmlText(Source: Text): Text
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(StripXmlDeclaration(Interp.GetResultText()));
    end;

    // Native XmlDocument.WriteTo(Text) prefixes '<?xml version="1.0" encoding="utf-16"?>' and
    // pretty-prints (CRLF + indentation); tests assert on bare compact markup, so drop the
    // declaration and per-line indentation before comparing.
    local procedure StripXmlDeclaration(T: Text): Text
    var
        CR: Char;
        LF: Char;
        Seps: List of [Text];
        Line: Text;
        Compact: TextBuilder;
    begin
        if T.StartsWith('<?xml') then
            T := T.Substring(T.IndexOf('?>') + 2);
        CR := 13;
        LF := 10;
        Seps.Add(Format(CR));
        Seps.Add(Format(LF));
        foreach Line in T.Split(Seps) do
            Compact.Append(Line.Trim());
        exit(Compact.ToText());
    end;
    // ===== XmlDocument: statics, ReadFrom/WriteTo, root navigation =====

    [Test]
    procedure T01_DocumentCreateWriteTo()
    begin
        Assert.AreEqual('',
            RunXmlText('var d: XmlDocument; t: Text; procedure P(): Text begin d := XmlDocument.Create(); d.WriteTo(t); exit(t); end;'),
            'a blank XmlDocument serializes to empty text');
    end;

    [Test]
    procedure T02_DocumentReadFromRoundTrip()
    begin
        Assert.AreEqual('<a><b>1</b></a>',
            RunXmlText('var d: XmlDocument; t: Text; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b>1</b></a>'', d); d.WriteTo(t); exit(t); end;'),
            'ReadFrom(Text, var XmlDocument) then WriteTo round-trips the markup');
    end;

    [Test]
    procedure T03_DocumentReadFromReturnsFalseOnBadXml()
    begin
        Assert.IsFalse(
            RunBool('var d: XmlDocument; procedure P(): Boolean begin exit(XmlDocument.ReadFrom(''<a><unclosed'', d)); end;'),
            'ReadFrom returns false on malformed XML (native semantics, no throw)');
    end;

    [Test]
    procedure T04_DocumentGetRootName()
    begin
        Assert.AreEqual('root',
            RunXmlText('var d: XmlDocument; e: XmlElement; procedure P(): Text begin XmlDocument.ReadFrom(''<root/>'', d); d.GetRoot(e); exit(e.Name()); end;'),
            'GetRoot(var XmlElement) rebinds the out handle; Name() reads it');
    end;

    [Test]
    procedure T05_DocumentCreateWithContent()
    begin
        // Create(''r'', ''hi'') would resolve to the (localName, namespaceUri) overload —
        // native conversion ranking prefers Text->Text over Text->content Joker — so the
        // text content goes through the 3-arg form (empty namespace).
        Assert.AreEqual('<r>hi</r>',
            RunXmlText('var d: XmlDocument; e: XmlElement; t: Text; procedure P(): Text begin e := XmlElement.Create(''r'', '''', ''hi''); d := XmlDocument.Create(e); d.WriteTo(t); exit(t); end;'),
            'XmlDocument.Create(Any,...) accepts an element content arg');
    end;

    [Test]
    procedure T06_ParenLessStaticCreate()
    begin
        Assert.IsTrue(
            RunBool('var d: XmlDocument; e: XmlElement; procedure P(): Boolean begin d := XmlDocument.Create; exit(not d.GetRoot(e)); end;'),
            'paren-less static (`XmlDocument.Create`) binds in expression context; blank doc has no root');
    end;

    // ===== XmlElement: Create (content coercion), children, inner text/xml =====

    [Test]
    procedure T07_ElementCreateTextContentBecomesXmlText()
    begin
        // 2 Text args = (localName, namespaceUri) — matches native overload resolution
        // (see T08). Text CONTENT therefore needs the 3-arg form: (localName, ns, content).
        Assert.AreEqual('hello',
            RunXmlText('var e: XmlElement; procedure P(): Text begin e := XmlElement.Create(''a'', '''', ''hello''); exit(e.InnerText()); end;'),
            'Text content arg coerces to XmlText (§6): InnerText sees it');
    end;

    [Test]
    procedure T08_ElementCreateNamespace()
    begin
        Assert.AreEqual('urn:x',
            RunXmlText('var e: XmlElement; procedure P(): Text begin e := XmlElement.Create(''a'', ''urn:x''); exit(e.NamespaceUri()); end;'),
            'Create(localName, namespaceUri) sets the namespace');
    end;

    [Test]
    procedure T09_ElementAddChildElements()
    begin
        Assert.AreEqual(2,
            RunInt('var e: XmlElement; var c1: XmlElement; var c2: XmlElement; var l: XmlNodeList; procedure P(): Integer begin e := XmlElement.Create(''p''); c1 := XmlElement.Create(''c''); c2 := XmlElement.Create(''c''); e.Add(c1); e.Add(c2); l := e.GetChildElements(); exit(l.Count()); end;'),
            'Add(element) twice then GetChildElements().Count() = 2');
    end;

    [Test]
    procedure T10_ElementInnerXml()
    begin
        Assert.AreEqual('<b>1</b>',
            RunXmlText('var d: XmlDocument; e: XmlElement; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b>1</b></a>'', d); d.GetRoot(e); exit(e.InnerXml()); end;'),
            'InnerXml() returns child markup only');
    end;

    [Test]
    procedure T11_ElementHasElementsIsEmpty()
    begin
        Assert.IsTrue(
            RunBool('var e: XmlElement; procedure P(): Boolean begin e := XmlElement.Create(''a''); exit(e.IsEmpty() and (not e.HasElements())); end;'),
            'fresh element: IsEmpty true, HasElements false');
    end;

    [Test]
    procedure T12_ElementGetDescendantElements()
    begin
        Assert.AreEqual(3,
            RunInt('var d: XmlDocument; e: XmlElement; l: XmlNodeList; procedure P(): Integer begin XmlDocument.ReadFrom(''<a><b><c/></b><c/></a>'', d); d.GetRoot(e); l := e.GetDescendantElements(); exit(l.Count()); end;'),
            'GetDescendantElements() walks the whole subtree (b, c, c)');
    end;

    // ===== Attributes =====

    [Test]
    procedure T13_SetAttributeThenValue()
    begin
        Assert.AreEqual('v1',
            RunXmlText('var e: XmlElement; a: XmlAttribute; col: XmlAttributeCollection; procedure P(): Text begin e := XmlElement.Create(''a''); e.SetAttribute(''k'', ''v1''); col := e.Attributes(); col.Get(''k'', a); exit(a.Value()); end;'),
            'SetAttribute then Attributes().Get(name, var attr) then Value()');
    end;

    [Test]
    procedure T14_AttributeStaticCreate()
    begin
        Assert.AreEqual('n',
            RunXmlText('var a: XmlAttribute; procedure P(): Text begin a := XmlAttribute.Create(''n'', ''v''); exit(a.LocalName()); end;'),
            'XmlAttribute.Create(name, value) static');
    end;

    [Test]
    procedure T15_HasAttributesRemoveAttribute()
    begin
        Assert.IsFalse(
            RunBool('var e: XmlElement; procedure P(): Boolean begin e := XmlElement.Create(''a''); e.SetAttribute(''k'', ''v''); e.RemoveAttribute(''k''); exit(e.HasAttributes()); end;'),
            'RemoveAttribute(name) drops the only attribute');
    end;

    [Test]
    procedure T16_AttributeValueSetter()
    begin
        Assert.AreEqual('v2',
            RunXmlText('var e: XmlElement; a: XmlAttribute; col: XmlAttributeCollection; procedure P(): Text begin e := XmlElement.Create(''a''); e.SetAttribute(''k'', ''v1''); col := e.Attributes(); col.Get(''k'', a); a.Value(''v2''); col.Get(''k'', a); exit(a.Value()); end;'),
            'Value(Text) setter writes through to the live DOM');
    end;

    [Test]
    procedure T17_NamespaceDeclarationAttr()
    begin
        Assert.IsTrue(
            RunBool('var a: XmlAttribute; procedure P(): Boolean begin a := XmlAttribute.CreateNamespaceDeclaration(''p'', ''urn:x''); exit(a.IsNamespaceDeclaration()); end;'),
            'CreateNamespaceDeclaration yields IsNamespaceDeclaration() = true');
    end;

    // ===== XmlNode: As*/Is*, navigation, ReplaceWith/Remove =====

    [Test]
    procedure T18_AsXmlNodeIsXmlElement()
    begin
        Assert.IsTrue(
            RunBool('var e: XmlElement; n: XmlNode; procedure P(): Boolean begin e := XmlElement.Create(''a''); n := e.AsXmlNode(); exit(n.IsXmlElement() and (not n.IsXmlComment())); end;'),
            'AsXmlNode() then Is* discriminates the actual kind');
    end;

    [Test]
    procedure T19_AsXmlElementRoundTrip()
    begin
        Assert.AreEqual('a',
            RunXmlText('var e: XmlElement; n: XmlNode; e2: XmlElement; procedure P(): Text begin e := XmlElement.Create(''a''); n := e.AsXmlNode(); e2 := n.AsXmlElement(); exit(e2.LocalName()); end;'),
            'node -> AsXmlElement() -> same element');
    end;

    [Test]
    procedure T20_GetParentGetDocument()
    begin
        Assert.AreEqual('a',
            RunXmlText('var d: XmlDocument; n: XmlNode; par: XmlElement; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b/></a>'', d); d.SelectSingleNode(''//b'', n); n.GetParent(par); exit(par.Name()); end;'),
            'GetParent(var XmlElement) from an XPath-selected node');
    end;

    [Test]
    procedure T21_RemoveNode()
    begin
        Assert.AreEqual('<a />',
            RunXmlText('var d: XmlDocument; n: XmlNode; t: Text; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b/></a>'', d); d.SelectSingleNode(''//b'', n); n.Remove(); d.WriteTo(t); exit(t); end;'),
            'Remove() detaches the node from the live DOM');
    end;

    [Test]
    procedure T22_ReplaceWithText()
    begin
        Assert.AreEqual('<a>x</a>',
            RunXmlText('var d: XmlDocument; n: XmlNode; t: Text; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b/></a>'', d); d.SelectSingleNode(''//b'', n); n.ReplaceWith(''x''); d.WriteTo(t); exit(t); end;'),
            'ReplaceWith(Text) swaps the element for a text node');
    end;

    // ===== XPath =====

    [Test]
    procedure T23_SelectNodesCount()
    begin
        Assert.AreEqual(2,
            RunInt('var d: XmlDocument; l: XmlNodeList; procedure P(): Integer begin XmlDocument.ReadFrom(''<a><b/><b/><c/></a>'', d); d.SelectNodes(''//b'', l); exit(l.Count()); end;'),
            'SelectNodes(XPath, var XmlNodeList) finds both <b>');
    end;

    [Test]
    procedure T24_SelectSingleNodeMiss()
    begin
        Assert.IsFalse(
            RunBool('var d: XmlDocument; n: XmlNode; procedure P(): Boolean begin XmlDocument.ReadFrom(''<a/>'', d); exit(d.SelectSingleNode(''//zzz'', n)); end;'),
            'SelectSingleNode returns false on no match');
    end;

    [Test]
    procedure T25_SelectNodesWithNamespaceManager()
    begin
        Assert.AreEqual(1,
            RunInt('var d: XmlDocument; l: XmlNodeList; m: XmlNamespaceManager; procedure P(): Integer begin XmlDocument.ReadFrom(''<a xmlns:p="urn:x"><p:b/></a>'', d); m.AddNamespace(''q'', ''urn:x''); d.SelectNodes(''//q:b'', m, l); exit(l.Count()); end;'),
            'SelectNodes with XmlNamespaceManager resolves the prefix');
    end;

    // ===== XmlNodeList / XmlAttributeCollection: Get + foreach (§9) =====

    [Test]
    procedure T26_NodeListGetIsOneBased()
    begin
        Assert.AreEqual('b1',
            RunXmlText('var d: XmlDocument; l: XmlNodeList; n: XmlNode; procedure P(): Text begin XmlDocument.ReadFrom(''<a><b1/><b2/></a>'', d); d.SelectNodes(''/a/*'', l); l.Get(1, n); exit(n.AsXmlElement().Name()); end;'),
            'XmlNodeList.Get is native 1-based');
    end;

    [Test]
    procedure T27_ForEachNodeList()
    begin
        Assert.AreEqual(3,
            RunInt('var d: XmlDocument; l: XmlNodeList; procedure P(): Integer var n: XmlNode; c: Integer; begin XmlDocument.ReadFrom(''<a><b/><b/><b/></a>'', d); d.SelectNodes(''//b'', l); foreach n in l do c := c + 1; exit(c); end;'),
            'foreach over XmlNodeList iterates every node (loop var must be a local — ALI907)');
    end;

    [Test]
    procedure T28_ForEachAttributeCollection()
    begin
        Assert.AreEqual('v1v2',
            RunXmlText('var e: XmlElement; col: XmlAttributeCollection; procedure P(): Text var a: XmlAttribute; t: Text; begin e := XmlElement.Create(''x''); e.SetAttribute(''a1'', ''v1''); e.SetAttribute(''a2'', ''v2''); col := e.Attributes(); foreach a in col do t := t + a.Value(); exit(t); end;'),
            'foreach over XmlAttributeCollection yields each attribute in order (loop var local — ALI907)');
    end;

    [Test]
    procedure T29_ForEachWrongLoopVarTypeRejected()
    begin
        ExpectCompileError('var l: XmlNodeList; e: XmlElement; c: Integer; procedure P() begin foreach e in l do c := c + 1; end;');
    end;

    // ===== Comment / CData / Declaration / PI =====

    [Test]
    procedure T30_CommentValueAndSerialization()
    begin
        Assert.AreEqual('<a><!--note--></a>',
            RunXmlText('var e: XmlElement; c: XmlComment; t: Text; procedure P(): Text begin e := XmlElement.Create(''a''); c := XmlComment.Create(''note''); e.Add(c); e.WriteTo(t); exit(t); end;'),
            'XmlComment.Create + Add serializes as a comment node');
    end;

    [Test]
    procedure T31_CDataValue()
    begin
        Assert.AreEqual('raw<>&',
            RunXmlText('var c: XmlCData; procedure P(): Text begin c := XmlCData.Create(''raw<>&''); exit(c.Value()); end;'),
            'XmlCData holds unescaped text');
    end;

    [Test]
    procedure T32_DeclarationProperties()
    begin
        Assert.AreEqual('1.0|utf-8|yes',
            RunXmlText('var dl: XmlDeclaration; procedure P(): Text begin dl := XmlDeclaration.Create(''1.0'', ''utf-8'', ''yes''); exit(dl.Version() + ''|'' + dl.Encoding() + ''|'' + dl.Standalone()); end;'),
            'XmlDeclaration.Create + Version/Encoding/Standalone getters');
    end;

    [Test]
    procedure T33_SetDeclarationGetDeclaration()
    begin
        Assert.AreEqual('1.0',
            RunXmlText('var d: XmlDocument; dl: XmlDeclaration; got: XmlDeclaration; procedure P(): Text begin d := XmlDocument.Create(); dl := XmlDeclaration.Create(''1.0'', ''utf-8'', ''''); d.SetDeclaration(dl); d.GetDeclaration(got); exit(got.Version()); end;'),
            'SetDeclaration then GetDeclaration(var XmlDeclaration) round-trips');
    end;

    [Test]
    procedure T34_ProcessingInstruction()
    begin
        Assert.AreEqual('tgt|dat',
            RunXmlText('var pi: XmlProcessingInstruction; procedure P(): Text begin pi := XmlProcessingInstruction.Create(''tgt'', ''dat''); exit(pi.Target() + ''|'' + pi.Value()); end;'),
            'XmlProcessingInstruction.Create + Target()/Value() (Value emulates GetData)');
    end;

    // ===== XmlNamespaceManager / options =====

    [Test]
    procedure T35_NamespaceManagerLookup()
    begin
        Assert.AreEqual('urn:x',
            RunXmlText('var m: XmlNamespaceManager; ns: Text; procedure P(): Text begin m.AddNamespace(''p'', ''urn:x''); m.LookupNamespace(''p'', ns); exit(ns); end;'),
            'AddNamespace then LookupNamespace(prefix, var Text)');
    end;

    [Test]
    procedure T36_ReadOptionsPreserveWhitespace()
    begin
        Assert.IsTrue(
            RunBool('var o: XmlReadOptions; procedure P(): Boolean begin o.PreserveWhitespace(true); exit(o.PreserveWhitespace()); end;'),
            'XmlReadOptions.PreserveWhitespace get/set round-trips (value-bank write-back)');
    end;

    // ===== Streams (§7.3) + procedure boundaries =====

    [Test]
    procedure T37_WriteToOutStream()
    begin
        Assert.IsTrue(
            RunBool('var d: XmlDocument; os: OutStream; procedure P(): Boolean begin XmlDocument.ReadFrom(''<a/>'', d); exit(d.WriteTo(os)); end;'),
            'WriteTo(OutStream) succeeds against a stream handle');
    end;

    [Test]
    procedure T38_XmlHandleAcrossProcedureCall()
    begin
        // Entry proc = first proc named OnRun, else the FIRST declared proc (binder contract) —
        // so P must be declared before the AddChild helper (forward refs bind via pass 1).
        Assert.AreEqual('child',
            RunXmlText('var d: XmlDocument; root: XmlElement; l: XmlNodeList; n: XmlNode; procedure P(): Text begin XmlDocument.ReadFrom(''<r/>'', d); d.GetRoot(root); AddChild(root); d.GetRoot(root); l := root.GetChildElements(); l.Get(1, n); exit(n.AsXmlElement().Name()); end; procedure AddChild(e: XmlElement) begin e.Add(XmlElement.Create(''child'')); end;'),
            'Xml handles are reference values across procedure calls (mutation visible to caller)');
    end;

    // ===== Compile-time rejections =====

    [Test]
    procedure T39_UnknownMethodRejected()
    begin
        ExpectCompileError('var d: XmlDocument; procedure P() begin d.Frobnicate(); end;');
    end;

    [Test]
    procedure T40_WrongKindAssignmentRejected()
    begin
        ExpectCompileError('var d: XmlDocument; e: XmlElement; procedure P() begin d := e; end;');
    end;

    [Test]
    procedure T41_BadContentArgRejected()
    begin
        ExpectCompileError('var e: XmlElement; i: Integer; procedure P() begin e := XmlElement.Create(''a''); e.Add(i); end;');
    end;
}
#endif
