// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Runtime Tests — interpreter behaviour that is not tied to one library type:
// expression evaluation, control flow, foreach, option/enum semantics, Label/Variant and
// the builtin function surface. Merged from the former "ALI Runtime Expr/Runtime Flow/
// ForEach/Option Enum/Label Variant/Builtin Tests" codeunits.
codeunit 51132 "ALI Runtime Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Pipeline: Codeunit "ALI Test Pipeline";
        Assert: Codeunit "Library Assert";

    // ================================================================================================
    // ALI Runtime Expr Tests (§14 item 5 — EXPRESSION scope only; control flow is a later task).
    //
    // THE KILLER TRICK (§14): the test app is itself an AL host. For every fidelity case we
    // compute the SAME expression in NATIVE AL right here and Assert equality against the
    // interpreted result. If native AL and the interpreter disagree, the interpreter is wrong —
    // there is no third opinion to consult. Overflow / div-by-zero / rounding / range checks are
    // all inherited from the platform, so "matches native" IS the specification.
    //
    // Pipeline via "ALI Test Pipeline" (Lexer->Parser->Binder->Lowerer->Interpreter). Every run
    // Resets all single-instance codeunits (helper does it). Result read through the typed
    // getters on "ALI Interpreter" (GetResultInt/Dec/Big/Bool/Text/Date/Time/DT/Dur), which
    // address the entry proc's inferred result slot.
    //
    // Source convention: a bare statement block whose first `exit(expr)` fixes the result
    // type/slot — e.g. 'exit(2 + 3 * 4);'. For failure cases we compute into the result then
    // exit, so the raising instruction carries a debug row (line/col capture).
    // ================================================================================================

    // ===== Helpers: run + typed native-comparison asserts =====

    local procedure RunInt(Source: Text): Integer
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultInt());
    end;

    local procedure RunBig(Source: Text): BigInteger
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultBig());
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

    local procedure RunText(Source: Text): Text
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultText());
    end;

    local procedure RunDate(Source: Text): Date
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultDate());
    end;

    local procedure RunTime(Source: Text): Time
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultTime());
    end;

    local procedure RunDT(Source: Text): DateTime
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultDT());
    end;

    local procedure RunDur(Source: Text): Duration
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Interp.GetResultDur());
    end;

    // Run expecting a RUNTIME failure; return the ExecResult (by var) so caller inspects.
    local procedure RunExpectFail(Source: Text; var Result: Codeunit "ALI Exec Result")
    var
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsFalse(Result.Succeeded(), 'Succeeded must be false on a raised error');
    end;

    // ===== Integer arithmetic + precedence (native comparison) =====

    [Test]
    procedure T01_IntPrecedence()
    begin
        // + binds looser than *; interpreter must equal native evaluation.
        Assert.AreEqual(2 + 3 * 4, RunInt('exit(2 + 3 * 4);'), 'a + b*c');
        Assert.AreEqual((2 + 3) * 4, RunInt('exit((2 + 3) * 4);'), 'paren overrides');
        Assert.AreEqual(10 - 4 - 3, RunInt('exit(10 - 4 - 3);'), 'left assoc -');
        Assert.AreEqual(2 + 3 * 4 - 5 * 6, RunInt('exit(2 + 3 * 4 - 5 * 6);'), 'mixed');
    end;

    [Test]
    procedure T02_IntDivMod()
    begin
        Assert.AreEqual(17 div 5, RunInt('exit(17 div 5);'), 'div');
        Assert.AreEqual(17 mod 5, RunInt('exit(17 mod 5);'), 'mod');
        // Negative operands: AL truncates toward zero for div, mod takes dividend sign.
        Assert.AreEqual(-17 div 5, RunInt('exit(-17 div 5);'), 'neg div');
        Assert.AreEqual(-17 mod 5, RunInt('exit(-17 mod 5);'), 'neg mod');
        Assert.AreEqual(17 div -5, RunInt('exit(17 div -5);'), 'div neg divisor');
        Assert.AreEqual(17 mod -5, RunInt('exit(17 mod -5);'), 'mod neg divisor');
        Assert.AreEqual(-17 div -5, RunInt('exit(-17 div -5);'), 'both neg div');
        Assert.AreEqual(-17 mod -5, RunInt('exit(-17 mod -5);'), 'both neg mod');
    end;

    [Test]
    procedure T03_UnaryMinus()
    begin
        Assert.AreEqual(-(3 + 4), RunInt('exit(-(3 + 4));'), 'unary of paren');
        Assert.AreEqual(- -5, RunInt('exit(- -5);'), 'double negate');
    end;

    [Test]
    procedure T04_BigIntegerArithmetic()
    begin
        Assert.AreEqual(9999999999L + 1, RunBig('exit(9999999999 + 1);'), 'big add');
        Assert.AreEqual(1000000000L * 1000000000L, RunBig('exit(1000000000000000000 * 1);'), 'big mul stays big');
        Assert.AreEqual(9999999999L div 7, RunBig('exit(9999999999 div 7);'), 'big div');
        Assert.AreEqual(9999999999L mod 7, RunBig('exit(9999999999 mod 7);'), 'big mod');
    end;

    [Test]
    procedure T05_IntOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // 2000000000 + 2000000000 overflows Int32; native AL raises -> interpreter must too.
        RunExpectFail('exit(2000000000 + 2000000000);', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'overflow message captured');
    end;

    // ===== Division `/` always Decimal =====

    [Test]
    procedure T06_SlashIsDecimal()
    begin
        // 7 / 2 = 3.5 exactly — compare to native Decimal division, not integer.
        Assert.AreEqual(7 / 2, RunDec('exit(7 / 2);'), '7/2 = 3.5');
        Assert.AreEqual(1 / 3, RunDec('exit(1 / 3);'), '1/3 decimal');
        Assert.AreEqual(10 / 4, RunDec('exit(10 / 4);'), '10/4 = 2.5');
    end;

    [Test]
    procedure T07_DivByZeroRaisesWithPosition()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // `/` div-by-zero. Line/col captured from the debug map (the exit statement's row).
        RunExpectFail('exit(1 / 0);', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'divzero message');
        Assert.IsTrue(Result.ErrorLine() >= 1, 'line captured');
        Assert.IsTrue(Result.ErrorColumn() >= 1, 'column captured');
    end;

    [Test]
    procedure T08_IntDivByZeroRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('exit(5 div 0);', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'div-by-zero message');
    end;

    [Test]
    procedure T09_ModByZeroRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('exit(5 mod 0);', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'mod-by-zero message');
    end;

    // ===== Decimal arithmetic + Int/Decimal mixing =====

    [Test]
    procedure T10_DecimalArithmetic()
    begin
        Assert.AreEqual(1.5 + 2.25, RunDec('exit(1.5 + 2.25);'), 'dec add');
        Assert.AreEqual(2.5 * 4, RunDec('exit(2.5 * 4);'), 'dec * int (CONV int side)');
        Assert.AreEqual(10 + 0.5, RunDec('exit(10 + 0.5);'), 'int + dec');
        Assert.AreEqual(3.75 - 1.25, RunDec('exit(3.75 - 1.25);'), 'dec sub');
    end;

    // ===== Compound assignments — fidelity vs native (the /= trap) =====

    [Test]
    procedure T11_CompoundAssignInt()
    var
        Expected: Integer;
    begin
        Expected := 10;
        Expected += 5;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var x: Integer; begin x := 10; x += 5; exit(x); end;'), '+=');

        Expected := 10;
        Expected -= 3;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var x: Integer; begin x := 10; x -= 3; exit(x); end;'), '-=');

        Expected := 10;
        Expected *= 4;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var x: Integer; begin x := 10; x *= 4; exit(x); end;'), '*=');
    end;

    [Test]
    procedure T12_CompoundSlashEqualsNarrowsLikeNative()
    var
        Result: Codeunit "ALI Exec Result";
        ExpectedHalf: Integer;
        ExpectedQuarter: Integer;
    begin
        // CRITICAL (§6.4 pitfall 24): x /= n type-checks as x := x / n whose RHS is Decimal,
        // then narrows Decimal->Integer on store. Native AL RAISES on a fractional narrow
        // (verified: "Overflow under conversion of Decimal18 value 3,5 to System.Int32"),
        // it does NOT round. Exact results store fine; fractional results must error in
        // the interpreter exactly as they do natively.
        ExpectedHalf := 8;
        ExpectedHalf /= 2;                        // exact: native narrowing succeeds
        Assert.AreEqual(ExpectedHalf, RunInt('procedure P(): Integer var x: Integer; begin x := 8; x /= 2; exit(x); end;'), 'x /= 2 exact');

        ExpectedQuarter := 12;
        ExpectedQuarter /= 3;
        Assert.AreEqual(ExpectedQuarter, RunInt('procedure P(): Integer var x: Integer; begin x := 12; x /= 3; exit(x); end;'), 'x /= 3 exact');

        // 7 /= 2 -> 3.5: native raises; interpreter must too.
        asserterror NativeSlashEquals(7, 2);
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 7; x /= 2; exit(x); end;', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'fractional /= must raise like native');
    end;

    [Test]
    procedure T13_SlashEqualsBankersRoundingPair()
    var
        Result5: Codeunit "ALI Exec Result";
        Result9: Codeunit "ALI Exec Result";
    begin
        // 5/2 = 2.5 and 9/2 = 4.5 exercise ties. Native does NOT round-half-to-even on the
        // narrow — it raises overflow (verified against BC runtime). Interpreter must match.
        asserterror NativeSlashEquals(5, 2);
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 5; x /= 2; exit(x); end;', Result5);
        Assert.AreNotEqual('', Result5.ErrorMessage(), '5 /= 2 tie must raise like native');

        asserterror NativeSlashEquals(9, 2);
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 9; x /= 2; exit(x); end;', Result9);
        Assert.AreNotEqual('', Result9.ErrorMessage(), '9 /= 2 tie must raise like native');
    end;

    // ===== CONV fidelity =====

    [Test]
    procedure T14_DecimalToIntegerAssignmentRounds()
    var
        R1: Codeunit "ALI Exec Result";
        R2: Codeunit "ALI Exec Result";
        EExact: Integer;
    begin
        // Decimal->Integer on store: exact values narrow fine; fractional values RAISE
        // natively ("Overflow under conversion of Decimal18 value 2,5 to System.Int32").
        // Interpreter must match both behaviors.
        EExact := Round3Native(3.0);
        Assert.AreEqual(EExact, RunInt('procedure P(): Integer var x: Integer; begin x := 6 / 2; exit(x); end;'), '3.0 -> int exact');

        asserterror EExact := Round3Native(2.5);
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 5 / 2; exit(x); end;', R1);
        Assert.AreNotEqual('', R1.ErrorMessage(), '2.5 -> int must raise like native');

        asserterror EExact := Round3Native(2.4);
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 12 / 5; exit(x); end;', R2);
        Assert.AreNotEqual('', R2.ErrorMessage(), '2.4 -> int must raise like native');
    end;

    [Test]
    procedure T15_BigIntegerToIntegerOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // 9999999999 (BigInteger) narrowed to Integer overflows -> native raises.
        RunExpectFail('procedure P(): Integer var x: Integer; begin x := 9999999999; exit(x); end;', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'big->int overflow captured');
    end;

    [Test]
    procedure T16_CharToIntegerBothDirections()
    var
        C: Char;
        ExpectedChar: Char;
        ExpectedCharOrd: Integer;
        ExpectedOrd: Integer;
    begin
        // Char -> Integer: ordinal of 'A'. NB: a 1-char string does NOT implicitly convert to
        // Char in the interpreter (no Text->Char conv), so the Char is built from its ordinal 65.
        C := 'A';
        ExpectedOrd := C;
        Assert.AreEqual(ExpectedOrd, RunInt('procedure P(): Integer var c: Char; begin c := 65; exit(c); end;'), 'Char->Int ordinal');

        // Integer -> Char: 66 stored into a Char then read as its ordinal (round trip).
        ExpectedChar := 66;
        ExpectedCharOrd := ExpectedChar;
        Assert.AreEqual(ExpectedCharOrd, RunInt('procedure P(): Integer var c: Char; begin c := 66; exit(c); end;'), 'Int->Char->ord');
    end;

    [Test]
    procedure T17_CharArithmetic()
    var
        C: Char;
        Expected: Integer;
    begin
        // Char + Int: a Char promotes to Int in arithmetic -> Integer 66 ('A' is 65).
        // NB: Char must come from its ordinal (no Text->Char conv in M4); a bare 'A' + 1 would
        // be string concatenation, not Char arithmetic.
        C := 'A';
        Expected := C + 1;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var c: Char; begin c := 65; exit(c + 1); end;'), 'Char + 1 = 66');
    end;

    [Test]
    procedure T17b_OneCharLiteralAsCharInArithmetic()
    begin
        // Native AL: a 1-char literal converts to Char in arithmetic ('a' = 97, 'A' = 65).
        Assert.AreEqual(2, RunInt('procedure P(): Integer var t: Text; begin t := ''xcx''; exit(t[2] - ''a''); end;'), 'Text[i] - literal');
        Assert.AreEqual(12, RunInt('procedure P(): Integer var t: Code[10]; begin t := ''QCQ''; exit(10 + t[2] - ''A''); end;'), 'Int - literal (QR-bill shape)');
        Assert.AreEqual(1, RunInt('procedure P(): Integer var c: Char; begin c := 98; exit(c - ''a''); end;'), 'Char var - literal');
        Assert.AreEqual(1, RunInt('procedure P(): Integer var c: Char; t: Text; begin c := 97; t := ''b''; exit(t[1] - c); end;'), 'Text[i] - Char var');
        Assert.AreEqual(3, RunInt('procedure P(): Integer var i: Integer; begin i := 100; i -= ''a''; exit(i); end;'), 'compound -= literal');
        AssertBindError('procedure P(): Integer var t: Text; begin t := ''b''; exit(t[1] - ''ab''); end;', 'ALI930');   // multi-char literal still rejected
    end;

    [Test]
    procedure T18_ByteRangeOverflowRaises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Storing 300 into a Byte exceeds 0..255 -> native raises.
        RunExpectFail('procedure P(): Integer var b: Byte; begin b := 300; exit(b); end;', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'byte range overflow captured');
    end;

    [Test]
    procedure T19_ByteInRange()
    var
        B: Byte;
        Expected: Integer;
    begin
        B := 200;
        Expected := B;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var b: Byte; begin b := 200; exit(b); end;'), 'byte 200 ok');
    end;

    // ===== Text: concatenation, casing, length check, comparison =====

    [Test]
    procedure T20_TextConcatPair()
    begin
        Assert.AreEqual('foo' + 'bar', RunText('exit(''foo'' + ''bar'');'), 'a + b');
    end;

    [Test]
    procedure T21_TextConcatChainExercisesConcatN()
    begin
        // Long chain a+b+c+d fuses into CONCAT_N — result must equal native concatenation.
        Assert.AreEqual('a' + 'b' + 'c' + 'd', RunText('exit(''a'' + ''b'' + ''c'' + ''d'');'), '4-chain');
        Assert.AreEqual('one' + 'two' + 'three' + 'four' + 'five',
            RunText('exit(''one'' + ''two'' + ''three'' + ''four'' + ''five'');'), '5-chain');
    end;

    [Test]
    procedure T22_CodeUppercasesOnStore()
    var
        C: Code[20];
        Expected: Text;
    begin
        // Code uppercases on store; Text does not. Compare against native Code var behavior.
        C := 'abc';
        Expected := C;
        Assert.AreEqual(Expected, RunText('procedure P(): Code[20] var c: Code[20]; begin c := ''abc''; exit(c); end;'), 'Code -> ABC');
        // Text keeps original case.
        Assert.AreEqual('abc', RunText('procedure P(): Text[20] var t: Text[20]; begin t := ''abc''; exit(t); end;'), 'Text keeps case');
    end;

    [Test]
    procedure T23_TextLengthCheckRaisesOnStore()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // 'abcdef' into Text[3] exceeds the declared length -> native raises on store (§7.2).
        RunExpectFail('procedure P(): Text[3] var t: Text[3]; begin t := ''abcdef''; exit(t); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'length') > 0, 'length-check message text');
    end;

    [Test]
    procedure T24_StringComparisonOperators()
    begin
        Assert.AreEqual('abc' = 'abc', RunBool('exit(''abc'' = ''abc'');'), '= true');
        Assert.AreEqual('abc' = 'abd', RunBool('exit(''abc'' = ''abd'');'), '= false');
        Assert.AreEqual('abc' < 'abd', RunBool('exit(''abc'' < ''abd'');'), '< true');
        Assert.AreEqual('abd' > 'abc', RunBool('exit(''abd'' > ''abc'');'), '> true');
        Assert.AreEqual('abc' <> 'xyz', RunBool('exit(''abc'' <> ''xyz'');'), '<> true');
    end;

    // ===== Date / Time / DateTime / Duration arithmetic vs native =====

    [Test]
    procedure T25_DatePlusInteger()
    var
        D: Date;
        Expected: Date;
    begin
        D := DMY2Date(1, 1, 2025);
        Expected := D + 10;
        Assert.AreEqual(Expected, RunDate('procedure P(): Date var d: Date; begin d := 20250101D; d := d + 10; exit(d); end;'), 'Date + 10');
    end;

    [Test]
    procedure T26_DateMinusDateIsInteger()
    var
        D1: Date;
        D2: Date;
        Expected: Integer;
    begin
        D1 := DMY2Date(11, 1, 2025);
        D2 := DMY2Date(1, 1, 2025);
        Expected := D1 - D2;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var a: Date; b: Date; begin a := 20250111D; b := 20250101D; exit(a - b); end;'), 'Date - Date days');
    end;

    [Test]
    procedure T25b_DateMinusInteger()
    var
        D: Date;
        Expected: Date;
    begin
        D := DMY2Date(15, 1, 2025);
        Expected := D - 5;
        Assert.AreEqual(Expected, RunDate('procedure P(): Date var d: Date; begin d := 20250115D; d := d - 5; exit(d); end;'), 'Date - 5');
    end;

    [Test]
    procedure T27_DateTimeMinusDateTimeIsDuration()
    var
        A: DateTime;
        B: DateTime;
        Expected: Duration;
    begin
        // DateTime - DateTime -> Duration (opcode 93). NOTE: the only DateTime value reachable
        // from M4 source is the 0DT literal — there is no Duration literal and no Int->Duration
        // conversion (see ENGINE LIMITATION report), so a nonzero DateTime cannot be built in
        // source yet. This still exercises the opcode + Duration result plumbing; native 0DT-0DT
        // is 0 and the interpreter must agree.
        A := 0DT;
        B := 0DT;
        Expected := A - B;
        Assert.AreEqual(Expected, RunDur('procedure P(): Duration var a: DateTime; b: DateTime; begin exit(a - b); end;'), '0DT - 0DT -> 0 Duration');
    end;

    [Test]
    procedure T28_TimeMinusTimeIsInteger()
    var
        Expected: Integer;
        T1: Time;
        T2: Time;
    begin
        T1 := 120000T;
        T2 := 110000T;
        Expected := T1 - T2;    // milliseconds
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var a: Time; b: Time; begin a := 120000T; b := 110000T; exit(a - b); end;'), 'Time - Time ms');
    end;

    [Test]
    procedure T28b_TimePlusInteger()
    var
        Expected: Time;
        T1: Time;
    begin
        // Native AL: Time + Integer adds milliseconds (TimeAndIntegerAddition,
        // BinaryOperatorKind.cs 0x113B) — opcode ADD_TIME_I (363).
        T1 := 120000T;
        Expected := T1 + 1000;
        Assert.AreEqual(Expected, RunTime('procedure P(): Time var t: Time; begin t := 120000T; t := t + 1000; exit(t); end;'), 'Time + 1000');
    end;

    [Test]
    procedure T28c_TimeMinusInteger()
    var
        Expected: Time;
        T1: Time;
    begin
        T1 := 120000T;
        Expected := T1 - 1000;
        Assert.AreEqual(Expected, RunTime('procedure P(): Time var t: Time; begin t := 120000T; t := t - 1000; exit(t); end;'), 'Time - 1000');
    end;

    // ===== Boolean: results, comparison, NON-SHORT-CIRCUIT =====

    [Test]
    procedure T30_BooleanOps()
    begin
        Assert.AreEqual(true and false, RunBool('exit(true and false);'), 'and');
        Assert.AreEqual(true or false, RunBool('exit(true or false);'), 'or');
        Assert.AreEqual(true xor true, RunBool('exit(true xor true);'), 'xor');
        Assert.AreEqual(not true, RunBool('exit(not true);'), 'not');
        Assert.AreEqual((true and false) or (not false), RunBool('exit((true and false) or (not false));'), 'compound');
    end;

    [Test]
    procedure T31_BooleanComparison()
    begin
        Assert.AreEqual(true = true, RunBool('exit(true = true);'), 'bool =');
        Assert.AreEqual(true <> false, RunBool('exit(true <> false);'), 'bool <>');
        // false < true in AL ordering.
        Assert.AreEqual(false < true, RunBool('exit(false < true);'), 'false < true');
    end;

    [Test]
    procedure T32_NonShortCircuit_Disassembly()
    var
        Module: Codeunit "ALI Module";
        AndPos: Integer;
        FirstCmpPos: Integer;
        Asm: Text;
    begin
        // (§15.2) NO short-circuit: BOTH operands are evaluated. Verify structurally — both
        // operands' compare instructions must be emitted BEFORE the AND_B that combines them.
        Pipeline.CompileToModule('exit((1 = 1) and (2 = 2));', Module);
        Asm := Module.Disassemble();
        AndPos := StrPos(Asm, 'AND_B');
        FirstCmpPos := StrPos(Asm, 'CMP_EQ_I');
        Assert.IsTrue(FirstCmpPos > 0, 'left compare emitted');
        Assert.IsTrue(AndPos > 0, 'AND_B emitted');
        Assert.IsTrue(FirstCmpPos < AndPos, 'operands precede AND_B (no short-circuit)');
    end;

    [Test]
    procedure T33_NonShortCircuit_RightSideStillEvaluatedRaises()
    var
        Result: Codeunit "ALI Exec Result";
        NativeRaised: Boolean;
    begin
        // Native AL evaluates BOTH sides of `or`. `(1 div x = 1) or (x = 0)` with x = 0 must
        // raise div-by-zero because the LEFT operand runs even though the right would be true.
        // Confirm native AL behaves the same via a TryFunction, then require the interpreter to
        // raise as well.
        NativeRaised := not TryNativeNonShortCircuit();
        Assert.IsTrue(NativeRaised, 'native AL evaluates both sides -> raises');

        RunExpectFail('procedure P(): Boolean var x: Integer; begin x := 0; exit((1 div x = 1) or (x = 0)); end;', Result);
        Assert.AreNotEqual('', Result.ErrorMessage(), 'interpreter raised too (non-short-circuit)');
    end;

    [TryFunction]
    local procedure TryNativeNonShortCircuit()
    var
        Dummy: Boolean;
        X: Integer;
    begin
        X := 0;
        Dummy := (1 div X = 1) or (X = 0);   // native AL: both sides run -> div-by-zero here
    end;

    // ===== Comparison operators per numeric type =====

    [Test]
    procedure T34_IntComparisons()
    begin
        Assert.AreEqual(3 < 5, RunBool('exit(3 < 5);'), '<');
        Assert.AreEqual(5 <= 5, RunBool('exit(5 <= 5);'), '<=');
        Assert.AreEqual(7 > 2, RunBool('exit(7 > 2);'), '>');
        Assert.AreEqual(2 >= 9, RunBool('exit(2 >= 9);'), '>=');
        Assert.AreEqual(4 = 4, RunBool('exit(4 = 4);'), '=');
        Assert.AreEqual(4 <> 5, RunBool('exit(4 <> 5);'), '<>');
    end;

    [Test]
    procedure T35_DecimalComparisons()
    begin
        Assert.AreEqual(1.5 < 2.5, RunBool('exit(1.5 < 2.5);'), 'dec <');
        Assert.AreEqual(2.5 >= 2.5, RunBool('exit(2.5 >= 2.5);'), 'dec >=');
        Assert.AreEqual(1.25 = 1.25, RunBool('exit(1.25 = 1.25);'), 'dec =');
    end;

    [Test]
    procedure T36_DateComparisons()
    var
        Earlier: Boolean;
    begin
        Earlier := DMY2Date(1, 1, 2025) < DMY2Date(2, 1, 2025);
        Assert.AreEqual(Earlier, RunBool('exit(20250101D < 20250102D);'), 'date <');
        Assert.AreEqual(DMY2Date(1, 1, 2025) = DMY2Date(1, 1, 2025),
            RunBool('exit(20250101D = 20250101D);'), 'date =');
    end;

    [Test]
    procedure T37_GuidEquality()
    var
        Expected: Boolean;
        A: Guid;
        B: Guid;
    begin
        // Two default (null) guids are equal natively; the interpreter must agree.
        Expected := A = B;
        Assert.AreEqual(Expected, RunBool('procedure P(): Boolean var a: Guid; b: Guid; begin exit(a = b); end;'), 'default guids equal');
    end;

    // ===== Case-insensitive keyword / identifier end-to-end =====

    [Test]
    procedure T38_CaseInsensitiveEndToEnd()
    var
        Expected: Integer;
    begin
        // Keywords and identifiers are case-folded; MyVar / MYVAR / myvar are the same slot,
        // EXIT/exit the same keyword. Whole pipeline must agree with native.
        Expected := 40;
        Assert.AreEqual(Expected, RunInt('procedure P(): Integer var MyVar: Integer; begin MyVar := 40; EXIT(MYVAR); end;'), 'case-insensitive');
    end;

    // ===== `in` set operator (native comparison) =====

    [Test]
    procedure T39_InListInteger()
    begin
        Assert.AreEqual(3 in [1, 2, 3], RunBool('exit(3 in [1, 2, 3]);'), 'int hit');
        Assert.AreEqual(5 in [1, 2, 3], RunBool('exit(5 in [1, 2, 3]);'), 'int miss');
        Assert.AreEqual(3 in [1 .. 4], RunBool('exit(3 in [1 .. 4]);'), 'range hit');
        Assert.AreEqual(5 in [1 .. 4], RunBool('exit(5 in [1 .. 4]);'), 'range miss');
        Assert.AreEqual(7 in [1 .. 3, 5, 7 .. 9], RunBool('exit(7 in [1 .. 3, 5, 7 .. 9]);'), 'mixed values+ranges');
        Assert.AreEqual(4 in [1 .. 3, 5, 7 .. 9], RunBool('exit(4 in [1 .. 3, 5, 7 .. 9]);'), 'mixed miss');
    end;

    [Test]
    procedure T40_InListTextAndDate()
    begin
        Assert.AreEqual('Two' in ['One', 'Two'], RunBool('exit(''Two'' in [''One'', ''Two'']);'), 'text hit');
        Assert.AreEqual('two' in ['One', 'Two'], RunBool('exit(''two'' in [''One'', ''Two'']);'), 'text case-sensitivity matches native');
        Assert.AreEqual(20260101D in [0D, 20260101D], RunBool('exit(20260101D in [0D, 20260101D]);'), 'date hit');
        Assert.AreEqual(20260115D in [20260101D .. 20260131D], RunBool('exit(20260115D in [20260101D .. 20260131D]);'), 'date range hit');
        Assert.AreEqual(20260215D in [20260101D .. 20260131D], RunBool('exit(20260215D in [20260101D .. 20260131D]);'), 'date range miss');
    end;

    // ===== Native comparison helpers =====

    local procedure Round3Native(D: Decimal): Integer
    var
        I: Integer;
    begin
        I := D;   // native Decimal->Integer narrowing (raises on fractional value)
        exit(I);
    end;

    local procedure NativeSlashEquals(X: Integer; N: Integer): Integer
    begin
        X /= N;   // native /= narrowing (raises when result is fractional)
        exit(X);
    end;

    // ================================================================================================
    // ALI Runtime Flow Tests (§14 item 5 — CONTROL-FLOW scope + golden disassembly).
    //
    // Same KILLER TRICK as the expression tests: the test app IS an AL host, so every
    // control-flow semantic question is answered by writing the SAME construct in NATIVE AL
    // right here and Assert-ing equality against the interpreted result. Where a value can be
    // computed natively (loop counts, control-var-after-loop, case selection, exit values),
    // we do so and compare — no hand-coded "expected" magic numbers unless the value is a
    // trivial literal.
    //
    // Pipeline via "ALI Test Pipeline" (Lexer->Parser->Binder->Lowerer->Interpreter). Result
    // read through the typed getters on "ALI Interpreter". Golden disassembly tests compare the
    // module's MNEMONIC SEQUENCE (opcodes only, operands/PC stripped) against a golden string —
    // a deterministic function of the Lowerer, following the exact-equality golden style used
    // in the parser tests. Operands are intentionally NOT pinned: register/PC numbering is an
    // allocator detail, whereas the opcode sequence IS the lowering contract under test.
    // ================================================================================================

    // Run and return ExecutedStatements from the ExecResult (for statement-count tests).
    local procedure RunStmtCount(Source: Text): Integer
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        exit(Result.ExecutedStatements());
    end;
    // ===== if / then / else =====

    [Test]
    procedure T01_IfThenBranchTaken()
    var
        Native: Integer;
    begin
        // Condition true -> then-branch value; compare to the native if.
        if 1 = 1 then
            Native := 5
        else
            Native := 7;
        Assert.AreEqual(Native, RunInt('procedure P(): Integer var x: Integer; begin if 1 = 1 then x := 5 else x := 7; exit(x); end;'), 'then taken');
    end;

    [Test]
    procedure T02_IfElseBranchTaken()
    var
        Native: Integer;
    begin
        if 1 = 2 then
            Native := 5
        else
            Native := 7;
        Assert.AreEqual(Native, RunInt('procedure P(): Integer var x: Integer; begin if 1 = 2 then x := 5 else x := 7; exit(x); end;'), 'else taken');
    end;

    [Test]
    procedure T03_IfNoElseConditionFalseLeavesUnchanged()
    var
        Native: Integer;
    begin
        // No else, condition false: variable keeps its prior value (native: 99).
        Native := 99;
        if 1 = 2 then
            Native := 5;
        Assert.AreEqual(Native, RunInt('procedure P(): Integer var x: Integer; begin x := 99; if 1 = 2 then x := 5; exit(x); end;'), 'no-else false: unchanged');
    end;

    [Test]
    procedure T04_NestedIf()
    var
        A: Integer;
        B: Integer;
        Native: Integer;
    begin
        A := 3;
        B := 4;
        if A > 0 then
            if B > 0 then
                Native := 1
            else
                Native := 2
        else
            Native := 3;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var a: Integer; b: Integer; r: Integer; begin a := 3; b := 4; if a > 0 then if b > 0 then r := 1 else r := 2 else r := 3; exit(r); end;'),
            'nested if inner-then');
    end;

    [Test]
    procedure T05_DanglingElseBindsToNearestIf()
    var
        A: Integer;
        B: Integer;
        Native: Integer;
    begin
        // Classic dangling-else: the else binds to the INNER if (§5.4). a>0 true, b>0 FALSE ->
        // inner else runs -> 2. Native AL resolves it identically; compare.
        A := 3;
        B := -1;
        Native := 99;
        if A > 0 then
            if B > 0 then
                Native := 1
            else
                Native := 2;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var a: Integer; b: Integer; r: Integer; begin a := 3; b := -1; r := 99; if a > 0 then if b > 0 then r := 1 else r := 2; exit(r); end;'),
            'dangling else -> nearest if');
    end;

    // ===== while =====

    [Test]
    procedure T06_WhileZeroTrip()
    var
        I: Integer;
        Native: Integer;
    begin
        // Condition false at entry: body never runs.
        Native := 0;
        I := 10;
        while I < 0 do begin
            Native += 1;
            I -= 1;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; i := 10; while i < 0 do begin n += 1; i -= 1; end; exit(n); end;'),
            'while zero-trip');
    end;

    [Test]
    procedure T07_WhileNTrip()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        I := 0;
        while I < 5 do begin
            Native += 1;
            I += 1;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; i := 0; while i < 5 do begin n += 1; i += 1; end; exit(n); end;'),
            'while 5-trip');
    end;

    // ===== repeat / until =====

    [Test]
    procedure T08_RepeatRunsAtLeastOnce()
    var
        Native: Integer;
    begin
        // until-cond is true immediately, but the body still runs once (post-tested loop).
        Native := 0;
        repeat
            Native += 1;
        until true;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var n: Integer; begin n := 0; repeat n += 1; until true; exit(n); end;'),
            'repeat runs once even when until true');
    end;

    [Test]
    procedure T09_RepeatUntilNTrip()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        I := 0;
        repeat
            Native += 1;
            I += 1;
        until I >= 4;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; i := 0; repeat n += 1; i += 1; until i >= 4; exit(n); end;'),
            'repeat 4-trip, until after body');
    end;

    // ===== for / to and for / downto =====

    [Test]
    procedure T10_ForToNTrip()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        for I := 1 to 5 do
            Native += 1;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 5 do n += 1; exit(n); end;'),
            'for/to 5 iterations');
    end;

    [Test]
    procedure T11_ForToZeroTripWhenStartGtEnd()
    var
        I: Integer;
        Native: Integer;
    begin
        // start > end: FOR_INIT_UP skips the body entirely (§5.3).
        Native := 0;
        for I := 5 to 1 do
            Native += 1;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 5 to 1 do n += 1; exit(n); end;'),
            'for/to zero-trip when start>end');
    end;

    [Test]
    procedure T12_ForDownToNTrip()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        for I := 5 downto 1 do
            Native += 1;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 5 downto 1 do n += 1; exit(n); end;'),
            'for/downto 5 iterations');
    end;

    [Test]
    procedure T13_ForDownToZeroTripWhenStartLtEnd()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        for I := 1 downto 5 do
            Native += 1;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 downto 5 do n += 1; exit(n); end;'),
            'for/downto zero-trip when start<end');
    end;

    [Test]
    procedure T14_ForBoundEvaluatedOnce_MutatingEndInBody()
    var
        Bound: Integer;
        I: Integer;
        Native: Integer;
    begin
        // REGRESSION guard (§5.3 pitfall 17): the end bound is captured ONCE at FOR_INIT;
        // mutating the bound variable inside the body must NOT change the iteration count.
        // Native AL evaluates the bound once too — compare the counts.
        Native := 0;
        Bound := 3;
        for I := 1 to Bound do begin
            Native += 1;
            Bound := 100;   // must NOT extend the loop
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; b: Integer; n: Integer; begin n := 0; b := 3; for i := 1 to b do begin n += 1; b := 100; end; exit(n); end;'),
            'for bound captured once at FOR_INIT');
    end;

    [Test]
    procedure T15_ForControlVarAfterLoop()
    var
        I: Integer;
        Last: Integer;
        Native: Integer;
    begin
        // Whatever native AL leaves in the control variable after a normal for/to loop, the
        // interpreter must leave the same. (AL leaves the last in-range value; do NOT assume —
        // compute it natively and compare.)
        Last := -999;
        for I := 1 to 5 do
            Last := I;
        Native := Last;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; last: Integer; begin last := -999; for i := 1 to 5 do last := i; exit(last); end;'),
            'for control-var last body value matches native');
    end;

    // ===== break =====

    [Test]
    procedure T16_BreakInWhile()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        I := 0;
        while I < 100 do begin
            if I = 3 then
                break;
            Native += 1;
            I += 1;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; i := 0; while i < 100 do begin if i = 3 then break; n += 1; i += 1; end; exit(n); end;'),
            'break exits while');
    end;

    [Test]
    procedure T17_BreakInRepeat()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        I := 0;
        repeat
            if I = 3 then
                break;
            Native += 1;
            I += 1;
        until I >= 100;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; i := 0; repeat if i = 3 then break; n += 1; i += 1; until i >= 100; exit(n); end;'),
            'break exits repeat');
    end;

    [Test]
    procedure T18_BreakInForTo()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        for I := 1 to 100 do begin
            if I = 4 then
                break;
            Native += 1;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 100 do begin if i = 4 then break; n += 1; end; exit(n); end;'),
            'break exits for/to');
    end;

    [Test]
    procedure T19_BreakInForDownTo()
    var
        I: Integer;
        Native: Integer;
    begin
        Native := 0;
        for I := 100 downto 1 do begin
            if I = 97 then
                break;
            Native += 1;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 100 downto 1 do begin if i = 97 then break; n += 1; end; exit(n); end;'),
            'break exits for/downto');
    end;

    [Test]
    procedure T20_NestedLoopsBreakExitsInnerOnly()
    var
        Inner: Integer;
        Native: Integer;
        Outer: Integer;
    begin
        // break in the inner loop must only exit the inner loop; outer keeps going.
        Native := 0;
        for Outer := 1 to 3 do
            for Inner := 1 to 100 do begin
                if Inner = 2 then
                    break;
                Native += 1;
            end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var o: Integer; i2: Integer; n: Integer; begin n := 0; for o := 1 to 3 do for i2 := 1 to 100 do begin if i2 = 2 then break; n += 1; end; exit(n); end;'),
            'inner break does not exit outer');
    end;

    // ===== exit =====

    [Test]
    procedure T21_ExitMidLoop()
    begin
        // exit(value) from inside a loop returns immediately with that value. Native mirror: a
        // loop that captures the exit value the first time i=3 and stops touching it thereafter.
        Assert.AreEqual(NativeExitMidLoop(),
            RunInt('procedure P(): Integer var i: Integer; begin for i := 1 to 100 do begin if i = 3 then exit(42); end; exit(0); end;'),
            'exit mid-loop returns immediately');
    end;

    local procedure NativeExitMidLoop(): Integer
    var
        I: Integer;
    begin
        for I := 1 to 100 do
            if I = 3 then
                exit(42);
        exit(0);
    end;

    [Test]
    procedure T22_ExitFromNestedBlocks()
    begin
        // exit from inside nested begin/if blocks returns the value.
        Assert.AreEqual(7,
            RunInt('procedure P(): Integer var x: Integer; begin x := 1; begin if x = 1 then begin exit(7); end; end; exit(0); end;'),
            'exit from nested blocks');
    end;

    [Test]
    procedure T23_BareExitHaltsEarly()
    begin
        // Bare `exit` (no value) halts the procedure. It does NOT touch the result slot, so the
        // returned value is the slot default (0). The later `exit(0)` fixes the result type; the
        // taken path is the bare exit, which must halt BEFORE reaching `x := 999`. If the bare
        // exit did not halt, x would become 999 and the trailing exit would return 999.
        Assert.AreEqual(0,
            RunInt('procedure P(): Integer var x: Integer; begin x := 1; if x = 1 then exit; x := 999; exit(0); end;'),
            'bare exit halts early, result slot default (0)');
    end;

    // ===== case =====

    [Test]
    procedure T24_CaseValueMatch()
    var
        Native: Integer;
        Sel: Integer;
    begin
        Sel := 2;
        case Sel of
            1:
                Native := 10;
            2:
                Native := 20;
            3:
                Native := 30;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Integer; r: Integer; begin s := 2; case s of 1: r := 10; 2: r := 20; 3: r := 30; end; exit(r); end;'),
            'case single value match');
    end;

    [Test]
    procedure T25_CaseValueList()
    var
        Native: Integer;
        Sel: Integer;
    begin
        Sel := 3;
        case Sel of
            1, 3, 5:
                Native := 100;
            2, 4, 6:
                Native := 200;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Integer; r: Integer; begin s := 3; case s of 1, 3, 5: r := 100; 2, 4, 6: r := 200; end; exit(r); end;'),
            'case value-list branch (1,3,5)');
    end;

    [Test]
    procedure T26_CaseRangeBranch()
    var
        Native: Integer;
        Sel: Integer;
    begin
        Sel := 7;
        case Sel of
            1 .. 4:
                Native := 1;
            5 .. 9:
                Native := 2;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Integer; r: Integer; begin s := 7; case s of 1..4: r := 1; 5..9: r := 2; end; exit(r); end;'),
            'case range branch (5..9)');
    end;

    [Test]
    procedure T27_CaseElseBranch()
    var
        Native: Integer;
        Sel: Integer;
    begin
        Sel := 42;
        case Sel of
            1:
                Native := 1;
            2:
                Native := 2;
            else
                Native := 999;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Integer; r: Integer; begin s := 42; case s of 1: r := 1; 2: r := 2; else r := 999; end; exit(r); end;'),
            'case else branch');
    end;

    [Test]
    procedure T28_CaseNoMatchNoElseFallsThrough()
    var
        Native: Integer;
        Sel: Integer;
    begin
        // No branch matches and there is no else: nothing runs, prior value stands.
        Native := 77;
        Sel := 42;
        case Sel of
            1:
                Native := 1;
            2:
                Native := 2;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Integer; r: Integer; begin r := 77; s := 42; case s of 1: r := 1; 2: r := 2; end; exit(r); end;'),
            'case no-match no-else falls through');
    end;

    [Test]
    procedure T29_CaseTextSelector()
    var
        Native: Integer;
        Sel: Text;
    begin
        Sel := 'bee';
        case Sel of
            'ant':
                Native := 1;
            'bee':
                Native := 2;
            'cat':
                Native := 3;
        end;
        Assert.AreEqual(Native,
            RunInt('procedure P(): Integer var s: Text; r: Integer; begin s := ''bee''; case s of ''ant'': r := 1; ''bee'': r := 2; ''cat'': r := 3; end; exit(r); end;'),
            'case Text selector');
    end;

    [Test]
    procedure T30_CaseSelectorTempClobberRegression()
    var
        A: Integer;
        B: Integer;
        C: Integer;
        I: Integer;
        Native: Integer;
    begin
        // CRITICAL REGRESSION (§7.2 selector caching / Lowerer TempFloor fix):
        // `case <expression> of` where the selector is a computed temp (i + 1), 3+ branches,
        // and EARLY branch bodies allocate their own temps (x := a + b * c). Before the fix the
        // selector temp was re-handed to a later line's test and clobbered, mis-selecting the
        // branch. With i=4 the selector is 5, so the THIRD branch (5:) must be taken.
        A := 2;
        B := 3;
        C := 4;
        I := 4;
        case I + 1 of
            3:
                Native := A + B * C;      // early body allocates temps
            4:
                Native := A * B + C;      // early body allocates temps
            5:
                Native := 555;            // the correct, LATER branch
            6:
                Native := A - B - C;
        end;
        Assert.AreEqual(555, Native, 'native mirror: 5th selects branch 5');
        Assert.AreEqual(555,
            RunInt('procedure P(): Integer var i: Integer; a: Integer; b: Integer; c: Integer; r: Integer; begin a := 2; b := 3; c := 4; i := 4; case i + 1 of 3: r := a + b * c; 4: r := a * b + c; 5: r := 555; 6: r := a - b - c; end; exit(r); end;'),
            'case-selector temp NOT clobbered by early-branch temps -> correct later branch');
    end;

    [Test]
    procedure T32_StatementCountScalesWithIterations()
    var
        C5: Integer;
        C10: Integer;
    begin
        // A loop program's statement count grows with the iteration count: each extra
        // iteration adds a fixed number of counted statements. Assert C10 > C5 and that the
        // per-iteration delta is constant (5-iter to 10-iter adds 5 * per-iter cost).
        C5 := RunStmtCount('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 5 do n += 1; exit(n); end;');
        C10 := RunStmtCount('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 10 do n += 1; exit(n); end;');
        Assert.IsTrue(C10 > C5, 'more iterations -> more statements');
        // per-iteration counted work is the FOR_NEXT back-edge; 5 extra iterations add 5x.
        Assert.AreEqual((C10 - C5) mod 5, 0, 'delta is a multiple of the 5 extra iterations');
    end;

    // ===== statement budget (runaway guard) =====

    [Test]
    procedure T33_StatementBudgetHaltsRunaway()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Module: Codeunit "ALI Module";
    begin
        // SetBudget is live (not a stub): an unbounded `while true` must fail cleanly with the
        // ALI950 budget message rather than hang. Wire the interpreter directly so we can set a
        // small budget before Run (the Pipeline helper uses the default budget).
        Pipeline.CompileToModule('procedure P(): Integer var x: Integer; begin x := 0; while true do x += 1; exit(x); end;', Module);
        Interp.Reset();
        Interp.SetBudget(1000);
        Interp.LoadModule(Module);
        Interp.Run(Result);
        Assert.IsFalse(Result.Succeeded(), 'runaway while true must fail');
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'budget') > 0, 'ALI950 budget message');
    end;

    // ===== Golden disassembly (§14 golden tests) =====
    //
    // We compare the MNEMONIC SEQUENCE (opcode names in program order, comma-joined) against a
    // golden string. This is a deterministic function of the Lowerer: operands/PC are stripped
    // because register/PC numbering is an allocator detail, but the opcode sequence is the
    // lowering contract. Each golden is derived directly from ALILowerer control-flow lowering.

    local procedure Mnemonics(Source: Text): Text
    var
        Module: Codeunit "ALI Module";
        First: Boolean;
        Started: Boolean;
        ColonPos: Integer;
        SpacePos: Integer;
        Asm: Text;
        Line: Text;
        Mnem: Text;
        NL: Text;
        Rest: Text;
        Sb: TextBuilder;
    begin
        Pipeline.CompileToModule(Source, Module);
        Asm := Module.Disassemble();
        NL := TypeHelperNewLine();
        First := true;
        Started := false;
        // Disassemble() emits one "<PC>: <MNEM> <A> <B> <C>" per line, AppendLine-separated.
        while StrPos(Asm, NL) > 0 do begin
            Line := CopyStr(Asm, 1, StrPos(Asm, NL) - 1);
            Asm := CopyStr(Asm, StrPos(Asm, NL) + StrLen(NL));
            if Line <> '' then begin
                ColonPos := StrPos(Line, ':');
                Rest := DelStr(Line, 1, ColonPos);        // drop "<PC>:"
                Rest := DelChr(Rest, '<', ' ');            // trim leading spaces
                SpacePos := StrPos(Rest, ' ');
                if SpacePos > 0 then
                    Mnem := CopyStr(Rest, 1, SpacePos - 1)
                else
                    Mnem := Rest;
                // Skip the proc PROLOGUE (per-local CLEAR_TARGET, REC_OPEN, *_NEW handle setup
                // emitted before any statement). The goldens pin the CONTROL-FLOW contract,
                // which begins at the first NON-PROLOGUE instruction (P1: there is no STMT
                // marker anymore); prologue is an allocator/lifetime detail (like reg/PC
                // numbering) and is intentionally not pinned.
                if (not Started) and (Mnem <> 'CLEAR_TARGET') and (Mnem <> 'REC_OPEN') and
                   (Mnem <> 'STRM_OPEN') and (Mnem <> 'LIST_NEW') and (Mnem <> 'DICT_NEW') and
                   (Mnem <> 'ARR_NEW')
                then
                    Started := true;
                if Started then begin
                    if not First then
                        Sb.Append(',');
                    Sb.Append(Mnem);
                    First := false;
                end;
            end;
        end;
        exit(Sb.ToText());
    end;

    local procedure TypeHelperNewLine(): Text
    var
        TB: TextBuilder;
    begin
        // Same line terminator TextBuilder.AppendLine uses, obtained from TextBuilder itself so
        // the golden splitter matches Disassemble()'s AppendLine exactly (platform newline).
        TB.AppendLine();
        exit(TB.ToText());
    end;

    [Test]
    procedure T34_GoldenIfElse()
    var
        Golden: Text;
    begin
        // procedure P(): Integer var x: Integer; begin if 1 = 1 then x := 5 else x := 7; exit(x); end;
        //   if 1 = 1: LOAD_CONST_I(left 1); right literal folds into CMP_EQ_I_IMM (P3), which
        //             then fuses with the conditional jump into BF_EQ_I_IMM (branch when false)
        //   then: LOAD_CONST_I(5), MOV_I            (StoreToVar int -> MOV_I)
        //   else present -> JMP; else: LOAD_CONST_I(7), MOV_I
        //   exit(x): MOV_I (name slot -> result slot), RET_VAL (M5)
        //   Lower() appends a trailing RET after the body. (P1: no STMT markers.)
        Golden :=
            'LOAD_CONST_I,BF_EQ_I_IMM,' +
            'LOAD_CONST_I,MOV_I,JMP,' +
            'LOAD_CONST_I,MOV_I,' +
            'MOV_I,RET_VAL,' +
            'RET';
        Assert.AreEqual(Golden,
            Mnemonics('procedure P(): Integer var x: Integer; begin if 1 = 1 then x := 5 else x := 7; exit(x); end;'),
            'golden if/else disassembly');
    end;

    [Test]
    procedure T35_GoldenForTo()
    var
        Golden: Text;
    begin
        // procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 5 do n += 1; exit(n); end;
        //   n := 0:  LOAD_CONST_I(0), MOV_I
        //   for i := 1 to 5:
        //     LOAD_CONST_I(1), MOV_I(loopvar), LOAD_CONST_I(5), MOV_I(limit), FOR_INIT_UP
        //     body n += 1: literal folds into ADD_I_IMM (P3), MOV_I
        //     FOR_NEXT_UP
        //   exit(n): MOV_I, RET_VAL (M5)
        //   trailing RET (P1: no STMT markers)
        Golden :=
            'LOAD_CONST_I,MOV_I,' +
            'LOAD_CONST_I,MOV_I,LOAD_CONST_I,MOV_I,FOR_INIT_UP,' +
            'ADD_I_IMM,MOV_I,' +
            'FOR_NEXT_UP,' +
            'MOV_I,RET_VAL,' +
            'RET';
        Assert.AreEqual(Golden,
            Mnemonics('procedure P(): Integer var i: Integer; n: Integer; begin n := 0; for i := 1 to 5 do n += 1; exit(n); end;'),
            'golden for/to disassembly');
    end;

    [Test]
    procedure T36_GoldenCaseRanges()
    var
        Golden: Text;
    begin
        // procedure P(): Integer var s: Integer; r: Integer; begin s := 3; case s of 1..4: r := 1; 5..9: r := 2; end; exit(r); end;
        //   s := 3:  LOAD_CONST_I(3), MOV_I
        //   case s of (selector is a NAME -> LowerExpr emits no instr):
        //     line 1 (1..4 range): range bounds are literals — each folds into the compare
        //        (P3): CMP_GE_I_IMM(sel,1), CMP_LE_I_IMM(sel,4), AND_B; AND_B is not fusable
        //        with the branch, so a plain JMP_IF_TRUE remains ; JMP(next-line)
        //        body r := 1: LOAD_CONST_I(1), MOV_I ; JMP(end)
        //     line 2 (5..9 range): same shape
        //   exit(r): MOV_I, RET_VAL (M5) ; trailing RET (P1: no STMT markers)
        Golden :=
            'LOAD_CONST_I,MOV_I,' +
            'CMP_GE_I_IMM,CMP_LE_I_IMM,AND_B,JMP_IF_TRUE,JMP,' +
            'LOAD_CONST_I,MOV_I,JMP,' +
            'CMP_GE_I_IMM,CMP_LE_I_IMM,AND_B,JMP_IF_TRUE,JMP,' +
            'LOAD_CONST_I,MOV_I,JMP,' +
            'MOV_I,RET_VAL,' +
            'RET';
        Assert.AreEqual(Golden,
            Mnemonics('procedure P(): Integer var s: Integer; r: Integer; begin s := 3; case s of 1..4: r := 1; 5..9: r := 2; end; exit(r); end;'),
            'golden case-with-ranges disassembly');
    end;

    [Test]
    procedure T37_GoldenCompoundSlashEquals()
    var
        Golden: Text;
    begin
        // procedure P(): Integer var x: Integer; begin x := 8; x /= 2; exit(x); end;
        //   x := 8:  LOAD_CONST_I(8), MOV_I
        //   x /= 2:  compound -> target := target / source. `/` is DIV_D (Decimal), so both
        //            operands CONV to Decimal, DIV_D, then narrow back to Integer on store
        //            (no int-imm fold — division is not ADD/SUB and runs in Decimal).
        //     LOAD_CONST_I(2)(src), CONV_I_D(target x -> dec), CONV_I_D(src -> dec),
        //     DIV_D, CONV_D_I(result -> int), MOV_I(store)
        //   exit(x): MOV_I, RET_VAL (M5) ; trailing RET (P1: no STMT markers)
        Golden :=
            'LOAD_CONST_I,MOV_I,' +
            'LOAD_CONST_I,CONV_I_D,CONV_I_D,DIV_D,CONV_D_I,MOV_I,' +
            'MOV_I,RET_VAL,' +
            'RET';
        Assert.AreEqual(Golden,
            Mnemonics('procedure P(): Integer var x: Integer; begin x := 8; x /= 2; exit(x); end;'),
            'golden compound /= disassembly');
    end;

    // ===== Handle Lifecycle Unification regressions =====

    [Test]
    procedure T38_GlobalCollectionsUsedFromEntryProc()
    begin
        // Regression: the global-init HANDLE_ESCAPE runs in the ENTRY frame (FrameSP = 0);
        // reading FrAllocBase[0] raised an index-out-of-range for ANY global List/Dict/array.
        Assert.AreEqual(6,
            RunInt('var l: List of [Integer]; d: Dictionary of [Integer, Integer]; a: array[3] of Integer; ' +
                   'procedure P(): Integer begin l.Add(1); d.Add(1, 2); a[1] := 3; exit(l.Get(1) + d.Get(1) + a[1]); end;'),
            'global List/Dictionary/array declared and used from the entry proc');
    end;

    [Test]
    procedure T39_DialogDeclarationLocalAndGlobal()
    begin
        // Regression: DLG_METHOD MethodId 0 ("New", emitted for every Dialog declaration)
        // was rejected by the interpreter with ALI952. Headless run: Open/Close are no-ops.
        Assert.AreEqual(7,
            RunInt('var g: Dialog; procedure P(): Integer var d: Dialog; begin g.Open(''w''); d.Open(''x''); d.Close(); g.Close(); exit(7); end;'),
            'global + local Dialog declaration, Open/Close headless');
    end;

    // ================================================================================================
    // ALI ForEach Tests — `foreach x in Collection do body` over List of [T] and JsonArray
    // (§5.5 ForEachStatement; lowering desugars onto FOR_INIT_UP/FOR_NEXT_UP — see
    // "ALI Lowerer".LowerForEach). Mirrors "ALI List Dict Tests"' pipeline-driven style.
    // ================================================================================================

    local procedure AssertBindError(Source: Text; ExpectedCode: Text)
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors(Source, Diags), StrSubstNo('expected a compile error for <%1>', Source));
        Assert.IsTrue(HasCode(Diags, ExpectedCode), StrSubstNo('expected %1 for <%2>', ExpectedCode, Source));
    end;

    local procedure HasCode(var Diags: Codeunit "ALI Diag Bag"; Code: Text): Boolean
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if Diags.GetCode(i) = Code then
                exit(true);
        exit(false);
    end;

    // ===== List foreach =====

    [Test]
    procedure T01_ForEachListIntegerSum()
    begin
        Assert.AreEqual(60,
            RunInt('var l: List of [Integer]; procedure P(): Integer var x: Integer; n: Integer; begin l.Add(10); l.Add(20); l.Add(30); n := 0; foreach x in l do n += x; exit(n); end;'),
            'foreach sums all List of [Integer] elements in order');
    end;

    [Test]
    procedure T02_ForEachListTextConcat()
    begin
        Assert.AreEqual('abc',
            RunText('var l: List of [Text]; procedure P(): Text var s: Text; t: Text; begin l.Add(''a''); l.Add(''b''); l.Add(''c''); foreach s in l do t += s; exit(t); end;'),
            'foreach visits List of [Text] elements in insertion order');
    end;

    [Test]
    procedure T03_ForEachEmptyListSkipsBody()
    begin
        Assert.AreEqual(0,
            RunInt('var l: List of [Integer]; procedure P(): Integer var x: Integer; n: Integer; begin n := 0; foreach x in l do n += 1; exit(n); end;'),
            'foreach over an empty List never runs the body');
    end;

    [Test]
    procedure T04_ForEachBreak()
    begin
        Assert.AreEqual(30,
            RunInt('var l: List of [Integer]; procedure P(): Integer var x: Integer; n: Integer; begin l.Add(10); l.Add(20); l.Add(99); n := 0; foreach x in l do begin if x = 99 then break; n += x; end; exit(n); end;'),
            'break exits the foreach loop');
    end;

    [Test]
    procedure T05_ForEachDictKeys()
    begin
        Assert.AreEqual(3,
            RunInt('var d: Dictionary of [Integer, Text]; procedure P(): Integer var k: Integer; n: Integer; begin d.Add(1, ''a''); d.Add(2, ''b''); d.Add(4, ''c''); n := 0; foreach k in d.Keys() do n += 1; exit(n); end;'),
            'foreach iterates the fresh List returned by Dictionary.Keys()');
    end;

    [Test]
    procedure T06_ForEachNested()
    begin
        Assert.AreEqual(9,
            RunInt('var l: List of [Integer]; procedure P(): Integer var a: Integer; b: Integer; n: Integer; begin l.Add(1); l.Add(2); l.Add(3); n := 0; foreach a in l do foreach b in l do n += 1; exit(n); end;'),
            'nested foreach over the same List runs count*count iterations');
    end;

    [Test]
    procedure T07_ForEachCollectionSnapshotOfMutation()
    begin
        // The element COUNT is bound once (FOR_INIT/NEXT limit slot) — appends during
        // iteration do not extend the loop (mirrors the for-loop bound-once rule §5.3).
        Assert.AreEqual(2,
            RunInt('var l: List of [Integer]; procedure P(): Integer var x: Integer; n: Integer; begin l.Add(1); l.Add(2); n := 0; foreach x in l do begin n += 1; l.Add(9); end; exit(n); end;'),
            'foreach visits exactly the initial element count');
    end;

    // ===== JsonArray foreach =====

    [Test]
    procedure T08_ForEachJsonArraySum()
    begin
        Assert.AreEqual(6,
            RunInt('var a: JsonArray; procedure P(): Integer var t: JsonToken; n: Integer; begin a.Add(1); a.Add(2); a.Add(3); n := 0; foreach t in a do n += t.AsValue().AsInteger(); exit(n); end;'),
            'foreach over a JsonArray yields each element as a JsonToken');
    end;

    [Test]
    procedure T09_ForEachJsonArrayEmpty()
    begin
        Assert.AreEqual(0,
            RunInt('var a: JsonArray; procedure P(): Integer var t: JsonToken; n: Integer; begin n := 0; foreach t in a do n += 1; exit(n); end;'),
            'foreach over an empty JsonArray never runs the body');
    end;

    [Test]
    procedure T10_ForEachJsonArrayFromParse()
    begin
        Assert.AreEqual('xyz',
            RunText('var a: JsonArray; procedure P(): Text var t: JsonToken; s: Text; begin a.ReadFrom(''["x","y","z"]''); foreach t in a do s += t.AsValue().AsText(); exit(s); end;'),
            'foreach iterates a parsed JsonArray in document order');
    end;

    // ===== Binder diagnostics =====

    [Test]
    procedure T11_ForEachDictionaryRejected()
    begin
        AssertBindError('var d: Dictionary of [Integer, Text]; procedure P(): Integer var k: Integer; begin foreach k in d do; exit(0); end;', 'ALI907');
    end;

    [Test]
    procedure T12_ForEachElemTypeMismatch()
    begin
        AssertBindError('var l: List of [Text]; procedure P(): Integer var x: Integer; begin foreach x in l do; exit(0); end;', 'ALI907');
    end;

    [Test]
    procedure T13_ForEachJsonArrayVarMustBeToken()
    begin
        AssertBindError('var a: JsonArray; procedure P(): Integer var x: Integer; begin foreach x in a do; exit(0); end;', 'ALI907');
    end;

    [Test]
    procedure T14_ForEachGlobalLoopVarRejected()
    begin
        AssertBindError('var l: List of [Integer]; g: Integer; procedure P(): Integer begin foreach g in l do; exit(0); end;', 'ALI907');
    end;

    // ================================================================================================
    // ALI Option Enum Tests — Option/Enum support (local var + table field + bare Enum literal,
    // §D plan). Native-comparison trick (§14) where practical; otherwise assert against the
    // documented v1 semantics directly (Format -> caption, `::Member` -> ordinal by name).
    // ================================================================================================

    local procedure CleanSeed()
    var
        Cust: Record "ALI Test Customer";
    begin
        Cust.DeleteAll();
    end;

    // ===== 1: inline option — default, assign, compare, Format after reassignment =====

    [Test]
    procedure T01_InlineOption_DefaultAssignFormat()
    begin
        Assert.AreEqual(0, RunInt('procedure P(): Integer var o: Option A,B,"C c"; begin exit(o); end;'), 'default ordinal is 0');
        Assert.IsTrue(RunBool('procedure P(): Boolean var o: Option A,B,"C c"; begin o := o::B; exit(o = 1); end;'), 'o::B = 1');
        Assert.AreEqual('C c', RunText('procedure P(): Text var o: Option A,B,"C c"; begin o := 2; exit(Format(o)); end;'), 'Format(2) -> quoted caption');
    end;

    // ===== 2: quoted member with space, unknown member, empty slot =====

    [Test]
    procedure T02_QuotedMember_UnknownMember_EmptySlot()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.AreEqual(2, RunInt('procedure P(): Integer var o: Option A,B,"C c"; begin exit(o::"C c"); end;'), 'quoted member ordinal');
        Assert.AreEqual(8, RunInt('procedure P(): Integer var r: Record AllObj; begin exit(r."Object Type"::Page); end;'), 'unquoted keyword member (Page)');
        Assert.AreEqual(5, RunInt('procedure P(): Integer var r: Record AllObj; begin exit(r."Object Type"::codeunit); end;'), 'unquoted keyword member, any casing');
        Assert.AreEqual('Page', RunText('procedure P(): Text var o: Option " ",Table,Page; begin o := o::Page; exit(Format(o)); end;'), 'keyword members in inline option declaration');
        Assert.AreEqual(0, RunInt('procedure P(): Integer var o: Option Table,Page; begin exit(o::Table); end;'), 'keyword as first inline option member');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var o: Option A,B; begin exit(o::Nope); end;', Diags), 'unknown member is a compile error');
        Assert.IsTrue(HasCode(Diags, 'ALI986'), 'ALI986 unknown member');
        Assert.AreEqual('', RunText('procedure P(): Text var o: Option ,One,Two; begin exit(Format(o)); end;'), 'empty first slot formats to blank');
    end;

    // ===== 3: implicit conversion both ways =====

    [Test]
    procedure T03_ImplicitConversionBothWays()
    begin
        Assert.AreEqual(1, RunInt('procedure P(): Integer var o: Option A,B,C; i: Integer; begin o := o::B; i := o; exit(i); end;'), 'Option -> Integer');
        Assert.AreEqual(2, RunInt('procedure P(): Integer var o: Option A,B,C; i: Integer; begin i := 2; o := i; exit(o); end;'), 'Integer -> Option');
        Assert.IsTrue(RunBool('procedure P(): Boolean var o: Option A,B,C; begin o := o::C; exit(o <> 0); end;'), '<> as integers');
    end;

    // ===== 4: table Option field =====

    [Test]
    procedure T04_TableOptionField()
    begin
        CleanSeed();
        Assert.AreEqual(1, RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''O1''; c.Status := c.Status::Pending; exit(c.Status); end;'), 'Status ordinal after ::Pending');
        Assert.AreEqual('Closed Out', RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c."No." := ''O2''; c.Status := c.Status::"Closed Out"; exit(Format(c.Status)); end;'), 'Format returns FieldRef caption');
        Assert.AreEqual(2, RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''O3''; c.Status := 2; c.Insert(); c.Get(''O3''); exit(c.Status); end;'), 'REC_FLD round-trip preserves ordinal');
    end;

    // ===== 5: table Enum field — gapped ordinals, Caption <> Name =====

    [Test]
    procedure T05_TableEnumField_GappedOrdinalsAndCaption()
    begin
        CleanSeed();
        Assert.AreEqual('Open Thing', RunText('var c: Record "ALI Test Customer"; procedure P(): Text begin c.Init(); c."No." := ''E1''; c.Category := c.Category::Open; exit(Format(c.Category)); end;'), 'Format -> Caption, not Name');
        Assert.AreEqual(5, RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''E2''; c.Category := c.Category::Open; exit(c.Category); end;'), '::Open matches its gapped ordinal 5');
        Assert.AreEqual(10, RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''E3''; c.Category := 10; c.Insert(); c.Get(''E3''); exit(c.Category); end;'), 'integer store on enum field is ordinal-based');
    end;

    // ===== 6/7: local Enum variable + bare literal (source-parse metadata path) =====

    [Test]
    procedure T06_LocalEnumVariable_BareLiteral()
    begin
        Assert.AreEqual(5, RunInt('procedure P(): Integer var e: Enum "ALI Test Enum"; begin e := "ALI Test Enum"::Open; exit(e); end;'), 'local Enum var := bare literal');
        Assert.IsTrue(RunBool('procedure P(): Boolean var e: Enum "ALI Test Enum"; begin e := "ALI Test Enum"::Open; exit(e = "ALI Test Enum"::Open); end;'), 'equality on Enum');
        Assert.AreEqual('Open Thing', RunText('procedure P(): Text var e: Enum "ALI Test Enum"; begin e := "ALI Test Enum"::Open; exit(Format(e)); end;'), 'Format on a local Enum var (source-parse caption)');
    end;

    // A module var section declared AFTER the procedures — where the AL formatter leaves an
    // object's globals. Those globals must still be in scope, `::` on them included; before the
    // fix the section was an ALI911 and every `Global::Member` then failed as an unknown name.
    [Test]
    procedure T06b_TrailingModuleVarSection()
    begin
        Assert.AreEqual(5, RunInt('procedure P(): Integer begin exit(g::Open); end; var g: Enum "ALI Test Enum";'), 'Enum global declared after the procedures');
        Assert.AreEqual(1, RunInt('procedure P(): Integer begin exit(o::B); end; var o: Option A,B,C;'), 'Option global declared after the procedures');
    end;

    // ===== 8: memoization — same set referenced twice builds exactly once =====

    [Test]
    procedure T08_Memoization_SingleBuild()
    var
        OptionMeta: Codeunit "ALI Option Meta";
        Before: Integer;
    begin
        CleanSeed();
        RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''M1''; c.Status := c.Status::Open; exit(c.Status); end;');
        Before := OptionMeta.BuildCount();
        RunInt('var c: Record "ALI Test Customer"; procedure P(): Integer begin c.Init(); c."No." := ''M2''; c.Status := c.Status::Pending; exit(c.Status); end;');
        Assert.AreEqual(Before, OptionMeta.BuildCount(), 'second script reuses the memoized set — no rebuild');
    end;

    // ===== 9: recovery — trailing comma, `::` on non-option var, unknown enum =====

    [Test]
    procedure T09_Recovery()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer var i: Integer; begin exit(i::Nope); end;', Diags), ':: on a non-option variable is a compile error');
        Assert.IsTrue(HasCode(Diags, 'ALI934'), 'ALI934 :: on a non-option variable');

        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(): Integer begin exit("ALI No Such Enum 12345"::Whatever); end;', Diags), 'unknown enum is a compile error');
        Assert.IsTrue(HasCode(Diags, 'ALI934') or HasCode(Diags, 'ALI984'), 'unknown enum reported');
    end;

    // Enum names may exceed AllObj's Text[30] "Object Name" (Base App enum 5769 = 32 chars).
    [Test]
    procedure T09_LongEnumName()
    begin
        Assert.AreEqual(8, RunInt('procedure P(): Integer var e: Enum "Warehouse Activity Document Type"; begin e := e::Assembly; exit(e); end;'), 'Enum var with a >30-char name');
        Assert.AreEqual(8, RunInt('procedure P(): Integer begin exit("Warehouse Activity Document Type"::Assembly); end;'), 'bare >30-char Enum literal');
    end;

    // ===== 10: Enum <-> Option implicit conversion (native: accepted, ordinal-mismatch warning) =====

    [Test]
    procedure T10_EnumOptionImplicitConversion()
    begin
        Assert.AreEqual(5,
            RunInt('procedure P(): Integer var e: Enum "ALI Test Enum"; o: Option A,B,C; begin e := "ALI Test Enum"::Open; o := e; exit(o); end;'),
            'Enum -> Option carries the ordinal');
        Assert.AreEqual(1,
            RunInt('procedure P(): Integer var e: Enum "ALI Test Enum"; o: Option A,B,C; begin o := o::B; e := o; exit(e); end;'),
            'Option -> Enum carries the ordinal');
    end;

    // ================================================================================================
    // ALI Label / Variant Tests (§19.2). Label = compile-time text constant (folded, read-only);
    // Variant = fallback register file with box/unbox on assignment, Format, and .IsXxx() type
    // detection. Same killer-trick harness as "ALI Runtime Expr Tests": interpreted result is
    // asserted against what native AL yields for the equivalent expression.
    // ================================================================================================

    local procedure AssertDiag(var Diags: Codeunit "ALI Diag Bag"; DiagCode: Text)
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if Diags.GetCode(i) = DiagCode then
                exit;
        Assert.Fail(StrSubstNo('expected diagnostic %1; got: %2', DiagCode, Diags.ToText()));
    end;

    // ===== Label =====

    [Test]
    procedure T01_LabelFoldedText()
    begin
        Assert.AreEqual('Hello', RunText('procedure P(): Text var L: Label ''Hello''; begin exit(L); end;'), 'Label folds to its text');
    end;

    [Test]
    procedure T02_LabelConcat()
    begin
        Assert.AreEqual('Hello world', RunText('procedure P(): Text var L: Label ''Hello''; begin exit(L + '' world''); end;'), 'Label participates as Text');
    end;

    [Test]
    procedure T03_LabelWithProperties()
    begin
        // Comment / Locked property tail must parse and be ignored (text still folds).
        Assert.AreEqual('Hi', RunText('procedure P(): Text var L: Label ''Hi'', Comment = ''fr=Salut'', Locked = true; begin exit(L); end;'), 'Label props parsed + ignored');
    end;

    [Test]
    procedure T04_LabelNotAssignable()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Pipeline.CompileExpectingErrors('procedure P() var L: Label ''x''; begin L := ''y''; end;', Diags);
        AssertDiag(Diags, 'ALI940');
    end;

    // ===== Variant box / unbox =====

    [Test]
    procedure T10_VariantRoundtripInt()
    begin
        Assert.AreEqual(42, RunInt('procedure P(): Integer var v: Variant; i: Integer; begin i := 42; v := i; i := 0; i := v; exit(i); end;'), 'Int -> Variant -> Int roundtrip');
    end;

    [Test]
    procedure T11_VariantFormat()
    begin
        Assert.AreEqual('7', RunText('procedure P(): Text var v: Variant; begin v := 7; exit(Format(v)); end;'), 'Format(Variant)');
    end;

    [Test]
    procedure T12_VariantHoldsText()
    begin
        Assert.AreEqual('abc', RunText('procedure P(): Text var v: Variant; t: Text; begin v := ''abc''; t := v; exit(t); end;'), 'Variant holds + yields Text');
    end;

    [Test]
    procedure T13_VariantArgPassing()
    begin
        // Int boxed into a Variant parameter, formatted inside the callee.
        Assert.AreEqual('99', RunText('procedure P(): Text begin exit(Show(99)); end; procedure Show(v: Variant): Text begin exit(Format(v)); end;'), 'Int -> Variant param');
    end;

    // ===== Variant type detection =====

    [Test]
    procedure T20_IsInteger()
    begin
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; begin v := 5; exit(v.IsInteger()); end;'), 'v.IsInteger() true for Int');
    end;

    [Test]
    procedure T21_IsTextNotInteger()
    begin
        Assert.IsFalse(RunBool('procedure P(): Boolean var v: Variant; begin v := ''x''; exit(v.IsInteger()); end;'), 'v.IsInteger() false for Text');
    end;

    [Test]
    procedure T22_IsText()
    begin
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; begin v := ''x''; exit(v.IsText()); end;'), 'v.IsText() true for Text');
    end;

    [Test]
    procedure T23_UnknownVariantMethodRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Pipeline.CompileExpectingErrors('procedure P(): Boolean var v: Variant; begin v := 1; exit(v.Frobnicate()); end;', Diags);
        AssertDiag(Diags, 'ALI941');
    end;

    [Test]
    procedure T24_IsRecordId()
    begin
        // RecordId boxes as a real value (tag 0) — native predicate answers.
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; c: Record "ALI Test Customer"; begin v := c.RecordId(); exit(v.IsRecordId()); end;'), 'v.IsRecordId() true');
    end;

    // ===== Variant holding reference types (List/Dictionary/Record) — tag subsystem =====

    [Test]
    procedure T30_VariantHoldsList()
    begin
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; l: List of [Integer]; begin l.Add(5); v := l; exit(v.IsList()); end;'), 'v.IsList() true for a boxed list');
    end;

    [Test]
    procedure T31_BoxedListNotInteger()
    begin
        // The tag makes scalar tests correctly false even though the handle is an Int.
        Assert.IsFalse(RunBool('procedure P(): Boolean var v: Variant; l: List of [Integer]; begin l.Add(5); v := l; exit(v.IsInteger()); end;'), 'boxed list is not Integer');
    end;

    [Test]
    procedure T32_ListRoundtrip()
    begin
        // Reference semantics: unbox recovers the same handle; count survives.
        Assert.AreEqual(2, RunInt('procedure P(): Integer var v: Variant; l: List of [Integer]; l2: List of [Integer]; begin l.Add(1); l.Add(2); v := l; l2 := v; exit(l2.Count()); end;'), 'List -> Variant -> List roundtrip');
    end;

    [Test]
    procedure T33_VariantHoldsDictionary()
    begin
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; d: Dictionary of [Integer, Text]; begin d.Add(1, ''a''); v := d; exit(v.IsDictionary()); end;'), 'v.IsDictionary() true');
    end;

    [Test]
    procedure T34_VariantHoldsRecord()
    begin
        Assert.IsTrue(RunBool('procedure P(): Boolean var v: Variant; c: Record "ALI Test Customer"; begin v := c; exit(v.IsRecord()); end;'), 'v.IsRecord() true for a boxed record');
    end;

    [Test]
    procedure T35_BoxedRecordNotList()
    begin
        Assert.IsFalse(RunBool('procedure P(): Boolean var v: Variant; c: Record "ALI Test Customer"; begin v := c; exit(v.IsList()); end;'), 'boxed record is not a List');
    end;

    [Test]
    procedure T36_ListArgIntoVariantParam()
    begin
        // Aggregate boxed into a Variant parameter keeps its tag across the call boundary.
        Assert.IsTrue(RunBool('procedure P(): Boolean var l: List of [Integer]; begin l.Add(1); exit(Check(l)); end; procedure Check(v: Variant): Boolean begin exit(v.IsList()); end;'), 'List arg -> Variant param -> IsList');
    end;

    // ================================================================================================
    // ALI Builtin Tests — M7 coverage (§16 M7 / §1.1 / §8 / §19.4 / §19.6 / §19.8).
    //
    // Same killer trick as "ALI Runtime Expr Tests": compute the same operation natively where
    // possible and compare. Pipeline via "ALI Test Pipeline" (reuses 50205 helper).
    // ================================================================================================

    local procedure RunExpectCompileError(Source: Text; ExpectedCode: Text)
    var
        Diags: Codeunit "ALI Diag Bag";
        Found: Boolean;
        i: Integer;
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors(Source, Diags), StrSubstNo('expected compile error <%1>', Source));
        for i := 1 to Diags.Count() do
            if Diags.GetCode(i) = ExpectedCode then
                Found := true;
        Assert.IsTrue(Found, StrSubstNo('expected diag %1 for <%2>, got none matching', ExpectedCode, Source));
    end;

    // ===== String builtins =====

    [Test]
    procedure CopyStr_Basic()
    begin
        Assert.AreEqual(CopyStr('Hello World', 7), RunText('exit(CopyStr(''Hello World'', 7));'), 'CopyStr(s,start)');
        Assert.AreEqual(CopyStr('Hello World', 1, 5), RunText('exit(CopyStr(''Hello World'', 1, 5));'), 'CopyStr(s,start,len)');
    end;

    [Test]
    procedure CopyStr_OutOfRange_Raises()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        RunExpectFail('exit(CopyStr(''abc'', 10));', Result);
    end;

    [Test]
    procedure StrLen_StrPos()
    begin
        Assert.AreEqual(StrLen('Hello'), RunInt('exit(StrLen(''Hello''));'), 'StrLen');
        Assert.AreEqual(StrPos('Hello World', 'World'), RunInt('exit(StrPos(''Hello World'', ''World''));'), 'StrPos');
    end;

    [Test]
    procedure StrSubstNo_Substitution()
    begin
        Assert.AreEqual(StrSubstNo('%1 and %2', 'A', 'B'), RunText('exit(StrSubstNo(''%1 and %2'', ''A'', ''B''));'), 'StrSubstNo 2 args');
        Assert.AreEqual(StrSubstNo('%1-%2-%3', 1, 2, 3), RunText('exit(StrSubstNo(''%1-%2-%3'', 1, 2, 3));'), 'StrSubstNo numeric args formatted');
    end;

    [Test]
    procedure LowerUpperCase()
    begin
        Assert.AreEqual('hello', RunText('exit(LowerCase(''HELLO''));'), 'LowerCase');
        Assert.AreEqual('HELLO', RunText('exit(UpperCase(''hello''));'), 'UpperCase');
    end;

    [Test]
    procedure DelChr_Variants()
    begin
        Assert.AreEqual(DelChr('  hi  ', '<'), RunText('exit(DelChr(''  hi  '', ''<''));'), 'DelChr leading');
        Assert.AreEqual(DelChr('  hi  ', '>'), RunText('exit(DelChr(''  hi  '', ''>''));'), 'DelChr trailing');
        Assert.AreEqual(DelChr('a.b.c', '=', '.'), RunText('exit(DelChr(''a.b.c'', ''='', ''.''));'), 'DelChr specific chars');
    end;

    [Test]
    procedure ConvertStr_PadStr_IncStr_SelectStr()
    begin
        Assert.AreEqual(ConvertStr('abc', 'ac', 'xy'), RunText('exit(ConvertStr(''abc'', ''ac'', ''xy''));'), 'ConvertStr');
        Assert.AreEqual(PadStr('ab', 5), RunText('exit(PadStr(''ab'', 5));'), 'PadStr default fill');
        Assert.AreEqual(IncStr('A009'), RunText('exit(IncStr(''A009''));'), 'IncStr');
        Assert.AreEqual(SelectStr(2, 'One,Two,Three'), RunText('exit(SelectStr(2, ''One,Two,Three''));'), 'SelectStr');
    end;

    [Test]
    procedure DelStr_InsStr_StrCheckSum()
    begin
        Assert.AreEqual(DelStr('Hello World', 6), RunText('exit(DelStr(''Hello World'', 6));'), 'DelStr(s,pos)');
        Assert.AreEqual(DelStr('Hello World', 6, 1), RunText('exit(DelStr(''Hello World'', 6, 1));'), 'DelStr(s,pos,len)');
        Assert.AreEqual(InsStr('Helo', 'l', 4), RunText('exit(InsStr(''Helo'', ''l'', 4));'), 'InsStr(s,sub,pos)');
        Assert.AreEqual(StrCheckSum('12345'), RunInt('exit(StrCheckSum(''12345''));'), 'StrCheckSum(s)');
        Assert.AreEqual(StrCheckSum('12345', '13', 10), RunInt('exit(StrCheckSum(''12345'', ''13'', 10));'), 'StrCheckSum(s,weight,mod)');
    end;

    [Test]
    procedure Format_Basic()
    begin
        Assert.AreEqual(Format(1234), RunText('exit(Format(1234));'), 'Format(int)');
    end;

    // ===== §19.4 Text member-accessors — equivalence with free-function twin =====

    [Test]
    procedure TextAccessors_Trim()
    begin
        Assert.AreEqual('hi', RunText('var s: Text; begin s := ''  hi  ''; exit(s.Trim()); end;'), 'Trim method');
    end;

    [Test]
    procedure TextAccessors_ReplaceContainsIndexOf()
    begin
        Assert.AreEqual('hxllo', RunText('var s: Text; begin s := ''hello''; exit(s.Replace(''e'', ''x'')); end;'), 'Replace method');
        Assert.IsTrue(RunBool('var s: Text; begin s := ''hello''; exit(s.Contains(''ell'')); end;'), 'Contains method');
        Assert.AreEqual(StrPos('hello', 'llo'), RunInt('var s: Text; begin s := ''hello''; exit(s.IndexOf(''llo'')); end;'), 'IndexOf method matches StrPos');
    end;

    [Test]
    procedure TextAccessors_StartsEndsWith_CaseChange()
    begin
        Assert.IsTrue(RunBool('var s: Text; begin s := ''hello''; exit(s.StartsWith(''he'')); end;'), 'StartsWith');
        Assert.IsTrue(RunBool('var s: Text; begin s := ''hello''; exit(s.EndsWith(''lo'')); end;'), 'EndsWith');
        Assert.AreEqual('HELLO', RunText('var s: Text; begin s := ''hello''; exit(s.ToUpper()); end;'), 'ToUpper == UpperCase');
        Assert.AreEqual('hello', RunText('var s: Text; begin s := ''HELLO''; exit(s.ToLower()); end;'), 'ToLower == LowerCase');
    end;

    [Test]
    procedure TextAccessors_Substring_MatchesCopyStr()
    begin
        Assert.AreEqual(CopyStr('Hello World', 7), RunText('var s: Text; begin s := ''Hello World''; exit(s.Substring(7)); end;'), 'Substring(start) == CopyStr');
        Assert.AreEqual(CopyStr('Hello World', 1, 5), RunText('var s: Text; begin s := ''Hello World''; exit(s.Substring(1, 5)); end;'), 'Substring(start,len) == CopyStr');
    end;

    [Test]
    procedure TextAccessors_PadLeftRight_Remove()
    var
        S: Text;
    begin
        S := 'ab';
        Assert.AreEqual(S.PadLeft(5), RunText('var s: Text; begin s := ''ab''; exit(s.PadLeft(5)); end;'), 'PadLeft default');
        Assert.AreEqual(S.PadLeft(5, '0'), RunText('var s: Text; begin s := ''ab''; exit(s.PadLeft(5, ''0'')); end;'), 'PadLeft with char');
        Assert.AreEqual(S.PadRight(5, '0'), RunText('var s: Text; begin s := ''ab''; exit(s.PadRight(5, ''0'')); end;'), 'PadRight with char');
        S := 'Hello World';
        Assert.AreEqual(S.Remove(6), RunText('var s: Text; begin s := ''Hello World''; exit(s.Remove(6)); end;'), 'Remove(start)');
        Assert.AreEqual(S.Remove(6, 1), RunText('var s: Text; begin s := ''Hello World''; exit(s.Remove(6, 1)); end;'), 'Remove(start,count)');
    end;

    [Test]
    procedure TextAccessors_IndexOfAny_StartIndex()
    var
        S: Text;
    begin
        S := 'a.b,c';
        Assert.AreEqual(S.IndexOfAny('.,'), RunInt('var s: Text; begin s := ''a.b,c''; exit(s.IndexOfAny(''.,'')); end;'), 'IndexOfAny');
        S := 'abcabc';
        Assert.AreEqual(S.IndexOf('b', 3), RunInt('var s: Text; begin s := ''abcabc''; exit(s.IndexOf(''b'', 3)); end;'), 'IndexOf with startIndex');
        Assert.AreEqual(S.LastIndexOf('b'), RunInt('var s: Text; begin s := ''abcabc''; exit(s.LastIndexOf(''b'')); end;'), 'LastIndexOf');
    end;

    [Test]
    procedure TextAccessors_Split_ReturnsList()
    begin
        Assert.AreEqual(3,
            RunInt('var s: Text; l: List of [Text]; procedure P(): Integer begin s := ''a,b,c''; l := s.Split('',''); exit(l.Count()); end;'),
            'Split(sep) count');
        Assert.AreEqual('MyValue2',
            RunText('var s: Text; l: List of [Text]; procedure P(): Text begin s := ''MyValue1,MyValue2,MyValue3''; l := s.Split('',''); exit(l.Get(2)); end;'),
            'Split(sep) element 2');
        Assert.AreEqual(4,
            RunInt('var s: Text; l: List of [Text]; procedure P(): Integer begin s := ''a,b;c,d''; l := s.Split('','', '';''); exit(l.Count()); end;'),
            'Split(sep1, sep2) count');
    end;

    // ===== Math builtins =====

    [Test]
    procedure Abs_Power()
    begin
        Assert.AreEqual(Abs(-5.5), RunDec('exit(Abs(-5.5));'), 'Abs');
        Assert.AreEqual(Power(2, 10), RunDec('exit(Power(2, 10));'), 'Power');
    end;

    [Test]
    procedure Round_Modes()
    begin
        Assert.AreEqual(Round(1.245, 0.01), RunDec('exit(Round(1.245, 0.01));'), 'Round nearest default');
        Assert.AreEqual(Round(1.246, 0.01, '<'), RunDec('exit(Round(1.246, 0.01, ''<''));'), 'Round down');
        Assert.AreEqual(Round(1.241, 0.01, '>'), RunDec('exit(Round(1.241, 0.01, ''>''));'), 'Round up');
    end;

    [Test]
    procedure Random_InRange()
    var
        R: Integer;
    begin
        R := RunInt('exit(Random(10));');
        Assert.IsTrue((R >= 1) and (R <= 10), 'Random(10) in 1..10');
    end;

    // ===== Date/time builtins =====

    [Test]
    procedure Today_MatchesNative()
    begin
        Assert.AreEqual(Today(), RunDate('exit(Today());'), 'Today matches native (same transaction date)');
    end;

    [Test]
    procedure Today_BareNoParens_MatchesNative()
    begin
        // Native AL allows a 0-arg builtin to be invoked without (); binder must not reject it.
        Assert.AreEqual(Today(), RunDate('exit(Today);'), 'bare Today (no parens) matches native');
    end;

    [Test]
    procedure CalcDate_Expressions()
    begin
        Assert.AreEqual(CalcDate('<1D>', 20250101D), RunDate('exit(CalcDate(''<1D>'', 20250101D));'), 'CalcDate +1D');
        Assert.AreEqual(CalcDate('<1M>', 20250101D), RunDate('exit(CalcDate(''<1M>'', 20250101D));'), 'CalcDate +1M');
        Assert.AreEqual(CalcDate('<-CM>', 20250115D), RunDate('exit(CalcDate(''<-CM>'', 20250115D));'), 'CalcDate start of month');
    end;

    [Test]
    procedure Date2DMY_DMY2Date_RoundTrip()
    begin
        Assert.AreEqual(Date2DMY(20250315D, 1), RunInt('exit(Date2DMY(20250315D, 1));'), 'Date2DMY day');
        Assert.AreEqual(DMY2Date(15, 3, 2025), RunDate('exit(DMY2Date(15, 3, 2025));'), 'DMY2Date');
    end;

    [Test]
    procedure CreateDateTime_DT2Date_DT2Time()
    begin
        Assert.AreEqual(DT2Date(CreateDateTime(20250315D, 120000T)), RunDate('exit(DT2Date(CreateDateTime(20250315D, 120000T)));'), 'DT2Date(CreateDateTime(...))');
    end;

    [Test]
    procedure ClosingDate_NormalDate_RoundDateTime()
    begin
        Assert.AreEqual(ClosingDate(20250315D), RunDate('exit(ClosingDate(20250315D));'), 'ClosingDate');
        Assert.AreEqual(NormalDate(ClosingDate(20250315D)), RunDate('exit(NormalDate(ClosingDate(20250315D)));'), 'NormalDate strips closing flag');
        Assert.IsTrue(RunBool('exit(RoundDateTime(CreateDateTime(20250315D, 120001T), 3600000) = CreateDateTime(20250315D, 120000T));'), 'RoundDateTime hour precision rounds 12:00:01 down to 12:00:00');
        Assert.IsTrue(RunBool('exit(RoundDateTime(CreateDateTime(20250315D, 120000T)) = CreateDateTime(20250315D, 120000T));'), 'RoundDateTime default precision is a no-op on a whole second');
    end;

    [Test]
    procedure IsNullGuid_And_VariantDateTimeConversions()
    begin
        Assert.IsTrue(RunBool('var g: Guid; begin exit(IsNullGuid(g)); end;'), 'IsNullGuid on blank guid');
        Assert.IsFalse(RunBool('var g: Guid; begin g := CreateGuid(); exit(IsNullGuid(g)); end;'), 'IsNullGuid on CreateGuid()');
        Assert.AreEqual(Format(UserSecurityId()), RunText('var g: Guid; begin g := UserSecurityId(); exit(Format(g)); end;'), 'UserSecurityId()');
        Assert.AreEqual(Format(UserSecurityId()), RunText('var g: Guid; begin g := UserSecurityId; exit(Format(g)); end;'), 'UserSecurityId paren-less');
        Assert.AreEqual(20250315D, RunDate('var v: Variant; begin v := DaTi2Variant(20250315D, 120000T); exit(Variant2Date(v)); end;'), 'DaTi2Variant/Variant2Date round-trip');
        Assert.IsTrue(RunBool('var v: Variant; begin v := DaTi2Variant(20250315D, 120000T); exit(Variant2Time(v) = 120000T); end;'), 'DaTi2Variant/Variant2Time round-trip');
    end;

    // ===== DateFormula (own register class; no literal syntax — Text implicitly converts) =====

    [Test]
    procedure DateFormula_TextAssignAndEquality()
    begin
        Assert.IsTrue(RunBool('var Days: DateFormula; Other: DateFormula; begin Days := ''<1M+2D>''; Other := ''<1M+2D>''; exit(Days = Other); end;'), 'equal formulas compare equal');
        Assert.IsTrue(RunBool('var Days: DateFormula; Other: DateFormula; begin Days := ''<1M+2D>''; Other := ''<1D>''; exit(Days <> Other); end;'), 'different formulas compare unequal');
    end;

    [Test]
    procedure DateFormula_Format_RoundTripsFormulaText()
    var
        Days: DateFormula;
    begin
        Evaluate(Days, '<1M+2D>');
        Assert.AreEqual(Format(Days), RunText('var Days: DateFormula; begin Days := ''<1M+2D>''; exit(Format(Days)); end;'), 'Format(DateFormula) returns the formula text');
    end;

    [Test]
    procedure CalcDate_WithDateFormulaVariable()
    begin
        Assert.AreEqual(CalcDate('<1M>', 20250101D), RunDate('var Days: DateFormula; begin Days := ''<1M>''; exit(CalcDate(Days, 20250101D)); end;'), 'CalcDate accepts a real DateFormula variable, not just a Text literal');
    end;

    [Test]
    procedure Evaluate_DateFormula_Succeeds()
    begin
        Assert.IsTrue(RunBool('var Days: DateFormula; begin exit(Evaluate(Days, ''<1M+2D>'')); end;'), 'Evaluate(var DateFormula, Text) succeeds on valid formula syntax');
        Assert.AreEqual(CalcDate('<1M+2D>', 20250101D), RunDate('var Days: DateFormula; begin Evaluate(Days, ''<1M+2D>''); exit(CalcDate(Days, 20250101D)); end;'), 'evaluated formula behaves like the equivalent Text literal in CalcDate');
    end;

    [Test]
    procedure Evaluate_DateFormula_BadSyntax_Fails()
    begin
        Assert.IsFalse(RunBool('var Days: DateFormula; begin exit(Evaluate(Days, ''not a formula''));end;'), 'Evaluate returns false (not a runtime error) on bad formula syntax');
    end;

    [Test]
    procedure Clear_DateFormula_ResetsToBlank()
    begin
        Assert.AreEqual('', RunText('var Days: DateFormula; begin Days := ''<1M>''; Clear(Days); exit(Format(Days)); end;'), 'Clear(DateFormula) resets to the blank formula');
    end;

    // ===== §19.6 :: object-id folding =====

    [Test]
    procedure ObjectId_Codeunit_FoldsToNativeId()
    var
        AllObj: Record AllObjWithCaption;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Codeunit);
        AllObj.SetRange("Object ID", 50205); // "ALI Test Pipeline" itself — guaranteed deployed
        Assert.IsTrue(AllObj.FindFirst(), 'ALI Test Pipeline must be deployed for this test');
        Assert.AreEqual(50205, RunInt(StrSubstNo('exit(Codeunit::"%1");', AllObj."Object Name")), ':: folds to native object id');
    end;

    [Test]
    procedure ObjectId_UnknownName_EarlyError()
    begin
        RunExpectCompileError('exit(Codeunit::"Totally Not A Real Codeunit Name 12345");', 'ALI984');
    end;

    // ===== §8 interception: Message / Confirm / Error / Sleep =====

    [Test]
    procedure Message_CollectedInOrder()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        Assert.IsTrue(Pipeline.CompileAndRun('begin Message(''first''); Message(''second %1'', 2); end;', Result, Interp), 'run OK');
        Assert.AreEqual(2, Result.CollectedMessageCount(), 'two messages collected');
        Assert.AreEqual('first', Result.GetCollectedMessage(1), 'message 1 order');
        Assert.AreEqual('second 2', Result.GetCollectedMessage(2), 'message 2 substituted');
    end;

    [Test]
    procedure Message_ConcatWithNestedBuiltinCallArg()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Source: Text;
    begin
        // ALI990 regression: a nested pool-based construct (Format(...), itself lowered via
        // the CALL_BUILTIN_LIVE operand-pool convention) inside a concat argument used to
        // desync the outer Message(...) call's OperStart, so it read Placeholder's own raw
        // register instead of the concatenated text — dropping the literal prefix entirely.
        Source := 'var Placeholder: Integer; begin Placeholder := 42; Message(''Value = '' + Format(Placeholder)); end;';
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        Assert.AreEqual(1, Result.CollectedMessageCount(), 'one message collected');
        Assert.AreEqual('Value = 42', Result.GetCollectedMessage(1), 'literal prefix must survive the concat');
    end;

    [Test]
    procedure Message_ThreeTermConcatArg()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Source: Text;
    begin
        // Same ALI990 class: 3+ terms fuse into ONE CONCAT_N (own pool push) instead of CAT_T,
        // so this hits the bug even without a nested builtin call.
        Source := 'var Placeholder: Text; begin Placeholder := ''X''; Message(''A'' + Placeholder + ''B''); end;';
        Assert.IsTrue(Pipeline.CompileAndRun(Source, Result, Interp), StrSubstNo('run OK <%1>: %2', Source, Result.ErrorMessage()));
        Assert.AreEqual(1, Result.CollectedMessageCount(), 'one message collected');
        Assert.AreEqual('AXB', Result.GetCollectedMessage(1), 'all three terms must survive the concat');
    end;

    [Test]
    procedure Error_CapturedWithLine()
    var
        Result: Codeunit "ALI Exec Result";
        Nl: Char;
        Source: Text;
    begin
        Nl := 10;
        Source := 'begin' + Format(Nl) + 'Message(''before'');' + Format(Nl) + 'Error(''boom %1'', 42);' + Format(Nl) + 'end;';
        RunExpectFail(Source, Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'boom 42') > 0, 'error text substituted');
        Assert.IsTrue(Result.ErrorLine() > 0, 'error line captured');
    end;

    [Test]
    procedure Confirm_ScriptedTrue()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
    begin
        RunOptions.Reset();
        RunOptions.SetDefaultConfirmAnswer(true);
        Assert.IsTrue(Pipeline.CompileAndRun('exit(Confirm(''Proceed?''));', Result, Interp), 'run OK');
        Assert.IsTrue(Interp.GetResultBool(), 'scripted Confirm answer true');
        RunOptions.Reset();
    end;

    [Test]
    procedure Confirm_ScriptedFalse_NoWarningWhenConfigured()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
    begin
        RunOptions.Reset();
        RunOptions.SetDefaultConfirmAnswer(false);
        Assert.IsTrue(Pipeline.CompileAndRun('exit(Confirm(''Proceed?''));', Result, Interp), 'run OK');
        Assert.IsFalse(Interp.GetResultBool(), 'scripted Confirm answer false');
        Assert.AreEqual(0, Result.RuntimeWarningCount(), 'no warning when an answer was explicitly configured');
        RunOptions.Reset();
    end;

    [Test]
    procedure Confirm_UnconfiguredDefault_WarnsOnce()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
    begin
        RunOptions.Reset();   // no scripted answer configured -> default false + warning
        Assert.IsTrue(Pipeline.CompileAndRun('exit(Confirm(''Proceed?''));', Result, Interp), 'run OK');
        Assert.IsFalse(Interp.GetResultBool(), 'unconfigured default is false');
        Assert.AreEqual(1, Result.RuntimeWarningCount(), 'unscripted Confirm warns once');
    end;

    [Test]
    procedure Sleep_Blocks()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunOptions: Codeunit "ALI Run Options";
        StartT: DateTime;
    begin
        RunOptions.Reset();
        StartT := CurrentDateTime();
        Assert.IsTrue(Pipeline.CompileAndRun('begin Sleep(2000); end;', Result, Interp), 'run OK');
        Assert.IsTrue((CurrentDateTime() - StartT) > 1990, 'Sleep(2000) shall take at least 2s to compile and run');
    end;

    // ===== Evaluate / Clear =====

    [Test]
    procedure Evaluate_Success()
    begin
        Assert.AreEqual(123, RunInt('var n: Integer; ok: Boolean; begin ok := Evaluate(n, ''123''); exit(n); end;'), 'Evaluate int success writes target');
    end;

    [Test]
    procedure Evaluate_Failure_LeavesTargetAndReturnsFalse()
    begin
        Assert.IsFalse(RunBool('var n: Integer; begin exit(Evaluate(n, ''not a number'')); end;'), 'Evaluate returns false on failure');
    end;

    [Test]
    procedure Clear_ResetsToDefault()
    begin
        Assert.AreEqual(0, RunInt('var n: Integer; begin n := 42; Clear(n); exit(n); end;'), 'Clear resets Integer to 0');
        Assert.AreEqual('', RunText('var s: Text; begin s := ''x''; Clear(s); exit(s); end;'), 'Clear resets Text to blank');
    end;

    [Test]
    procedure SystemQualifiedBuiltins()
    begin
        // Namespaced Microsoft source writes builtins as `System.X` — the qualifier is dropped.
        Assert.AreEqual(0, RunInt('var n: Integer; begin n := 42; System.Clear(n); exit(n); end;'), 'System.Clear behaves like Clear');
        Assert.IsTrue(RunBool('var n: Integer; begin exit(System.Evaluate(n, ''7'')); end;'), 'System.Evaluate behaves like Evaluate');
        // The qualifier also reaches PAST a same-named procedure in scope — which is why native
        // AL code writes it (codeunit 10 "Type Helper" declares its own 4-argument Evaluate).
        Assert.IsTrue(
            RunBool('procedure P(): Boolean var n: Integer; begin exit(System.Evaluate(n, ''7'')); end; procedure Evaluate(a: Integer; b: Integer; c: Integer; d: Integer): Boolean begin exit(false); end;'),
            'System.Evaluate is the builtin even when a procedure of that name is in scope');
    end;

    [Test]
    procedure GetLastErrorText_ClearLastError_Recognized()
    begin
        // Recognized + bindable (not a compile error). The value after a caught [TryFunction]
        // error is covered by TryFunction_Error_ReturnsFalseAndSetsLastError.
        Assert.AreEqual('', RunText('ClearLastError(); exit(GetLastErrorText());'), 'GetLastErrorText after ClearLastError is blank');
    end;

    // ===== [TryFunction] (TRY_CALL) =====

    [Test]
    procedure TryFunction_Success_ReturnsTrue()
    begin
        Assert.IsTrue(
            RunBool('procedure P(): Boolean begin exit(T()); end; [TryFunction] procedure T() var n: Integer; begin n := 1; end;'),
            'a try procedure that completes returns true');
    end;

    [Test]
    procedure TryFunction_Error_ReturnsFalseAndSetsLastError()
    begin
        // The caller keeps running after the caught error, and the script sees its text.
        Assert.AreEqual('boom|after',
            RunText('procedure P(): Text var ok: Boolean; begin ok := T(); if ok then exit(''unexpected''); exit(GetLastErrorText() + ''|after''); end; [TryFunction] procedure T() begin Error(''boom''); end;'),
            'a failing try procedure returns false, GetLastErrorText carries its message');
    end;

    [Test]
    procedure TryFunction_StatementForm_ErrorPropagates()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Native AL: a try call whose result is not used is an ordinary call.
        RunExpectFail('procedure P() begin T(); end; [TryFunction] procedure T() begin Error(''boom''); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'boom') > 0, 'the unconsumed try call raises the callee error');
    end;

    [Test]
    procedure TryFunction_NestedError_KeepsWritesAndUnwinds()
    begin
        // The error is raised two frames deep (T -> Inner): both frames are unwound, and the
        // var-param / global writes made before the error survive (native: no rollback of values).
        Assert.AreEqual(703,
            RunInt('var g: Integer; procedure P(): Integer var n: Integer; begin if not T(n) then exit(n * 100 + g); exit(-1); end; ' +
                   '[TryFunction] procedure T(var n: Integer) begin n := 7; g := 3; Inner(); end; procedure Inner() begin Error(''deep''); end;'),
            'values written before the caught error are kept; caller resumes on its own frame');
    end;

    [Test]
    procedure MaxStrLen_TextReturnsDeclaredLength()
    var
        t: Text[30];
    begin
        // Compile-time fold: declared Text length, regardless of the runtime string content.
        Assert.AreEqual(MaxStrLen(t), RunInt('procedure P(): Integer var t: Text[30]; begin t := ''hi''; exit(MaxStrLen(t)); end;'), 'MaxStrLen(Text[30]) = 30');
    end;

    [Test]
    procedure MaxStrLen_CodeReturnsDeclaredLength()
    var
        c: Code[20];
    begin
        Assert.AreEqual(MaxStrLen(c), RunInt('procedure P(): Integer var c: Code[20]; begin exit(MaxStrLen(c)); end;'), 'MaxStrLen(Code[20]) = 20');
    end;

    [Test]
    procedure MaxStrLen_UnboundedTextReturnsMaxInt()
    var
        t: Text;
    begin
        // Unbounded Text -> Integer.MaxValue, matching native AL.
        Assert.AreEqual(MaxStrLen(t), RunInt('procedure P(): Integer var t: Text; begin exit(MaxStrLen(t)); end;'), 'MaxStrLen(unbounded Text) = 2147483647');
    end;

    // ===== Paren-less zero-arg builtins (Feature 1) =====

    [Test]
    procedure Today_ParenlessAssignment()
    begin
        // d := Today (no parens) in an assignment RHS, not just inside exit()/an expression.
        Assert.AreEqual(Today(), RunDate('procedure P(): Date var d: Date; begin d := Today; exit(d); end;'), 'bare Today assigned into a local var matches native');
    end;

    [Test]
    procedure SelectLatestVersion_BareStatement_NotSilentlyDropped()
    begin
        // Before Feature 1, a bare 0-arg builtin used AS A STATEMENT (no assignment, no exit())
        // was silently dropped by the lowerer instead of being executed. SelectLatestVersion is
        // harmless (no side effect observed via g), so the g increment after it is the proof:
        // if the statement were mis-parsed/dropped and desynced the statement list, g would not
        // reach 1.
        // Void builtins (SelectLatestVersion / Commit / ClearLastError) as the FIRST statements:
        // the bare form must bind in statement context (no ALI929) and allocate no out register
        // (an unset result Variant copied into a Text register raised NavIndirectValue -> NavText).
        Assert.AreEqual(1,
            RunInt('var g: Integer; procedure P(): Integer begin SelectLatestVersion; Commit; ClearLastError; SelectLatestVersion(); g := 1; exit(g); end;'),
            'a bare 0-arg builtin call used as a statement is compiled and executed, not dropped');
    end;
}
#endif
