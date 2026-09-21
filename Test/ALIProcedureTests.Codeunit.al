// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Procedure Tests (§14 item 6 — M5: frames, CALL/RET/RET_VAL, var params, recursion,
// type-verification collect-all, Engine facade v0).
//
// Same native-comparison trick as the other runtime tests: the test app IS an AL host, so
// interpreted results are asserted against the SAME computation written in native AL.
//
// Conventions exercised (see "ALI Interpreter" header for the frozen calling convention):
//   * entry proc = first declared proc — every multi-proc source puts its driver first;
//   * interpreted-to-interpreted calls never use AL recursion: the 1000-deep recursion
//     test would blow the (uncatchable) AL stack if CALL recursed natively;
//   * frame/register exhaustion is a clean captured runtime error, never a crash.
codeunit 51130 "ALI Procedure Tests"
{
    Subtype = Test;
    TestPermissions = Disabled;

    var
        Pipeline: Codeunit "ALI Test Pipeline";
        Assert: Codeunit "Library Assert";
        HandlerHits: Integer;
        HandledCustomerNo: Text;

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

    local procedure RunExpectFail(Source: Text; var Result: Codeunit "ALI Exec Result")
    var
        Interp: Codeunit "ALI Interpreter";
        Ok: Boolean;
    begin
        Ok := Pipeline.CompileAndRun(Source, Result, Interp);
        Assert.IsFalse(Ok, StrSubstNo('expected runtime failure <%1>', Source));
        Assert.IsFalse(Result.Succeeded(), 'Succeeded must be false on a raised error');
    end;

    // Compile expecting errors; assert a diagnostic with Code whose message contains
    // Fragment exists in the bag.
    local procedure AssertDiag(var Diags: Codeunit "ALI Diag Bag"; DiagCode: Text; Fragment: Text)
    var
        i: Integer;
    begin
        for i := 1 to Diags.Count() do
            if (Diags.GetCode(i) = DiagCode) and (StrPos(Diags.GetMessage(i), Fragment) > 0) then
                exit;
        Assert.Fail(StrSubstNo('expected diagnostic %1 containing <%2>; got: %3', DiagCode, Fragment, Diags.ToText()));
    end;

    // ===== Basic calls / results =====

    [Test]
    procedure T01_SimpleCallWithResult()
    begin
        // entry proc P calls Add — forward reference (Add declared after P) must bind
        // (two-pass signatures, §6.2).
        Assert.AreEqual(7,
            RunInt('trigger OnRun(): Integer begin exit(Add(3, 4)); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;'),
            'simple call + forward reference');
    end;

    [Test]
    procedure T02_VoidCallAsStatement()
    begin
        // A void proc called as a statement; result flows through a module-level var.
        Assert.AreEqual(6,
            RunInt('var g: Integer; trigger OnRun(): Integer begin g := 0; Inc3(); Inc3(); exit(g); end; procedure Inc3() begin g := g + 3; end;'),
            'void proc + module-level var across procs');
    end;

    [Test]
    procedure T03_CallInExpression()
    var
        Native: Integer;
    begin
        Native := 2 * (3 + 4) + 5;
        Assert.AreEqual(Native,
            RunInt('trigger OnRun(): Integer begin exit(2 * Add(3, 4) + 5); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;'),
            'call result inside a larger expression');
    end;

    [Test]
    procedure T04_NestedCallsAsArguments()
    var
        Native: Integer;
    begin
        // F(a, G(x)): inner call is evaluated into a caller register BEFORE the outer
        // staging — the callee window must not be clobbered (see Lowerer LowerCall).
        Native := (1 + (10 * 2)) + ((10 * 3) + (10 * 4));
        Assert.AreEqual(Native,
            RunInt('trigger OnRun(): Integer begin exit(Add(Add(1, Ten(2)), Add(Ten(3), Ten(4)))); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end; procedure Ten(n: Integer): Integer begin exit(10 * n); end;'),
            'nested calls in argument positions');
    end;

    [Test]
    procedure T05_TextResultThroughCall()
    begin
        Assert.AreEqual('ab-cd',
            RunText('trigger OnRun(): Text begin exit(Glue(''ab'', ''cd'')); end; procedure Glue(l: Text; r: Text): Text begin exit(l + ''-'' + r); end;'),
            'Text params + Text result through a call');
    end;

    // ===== Recursion (interpreted frames, never AL recursion) =====

    [Test]
    procedure T06_FactorialMatchesNative()
    var
        i: Integer;
        Native: Integer;
    begin
        Native := 1;
        for i := 2 to 12 do
            Native := Native * i;
        Assert.AreEqual(Native,
            RunInt('trigger OnRun(): Integer begin exit(Fact(12)); end; procedure Fact(n: Integer): Integer begin if n <= 1 then exit(1); exit(n * Fact(n - 1)); end;'),
            'recursive factorial(12) vs native');
    end;

    [Test]
    procedure T07_RecursionDepth1000()
    begin
        // 1000-deep interpreted recursion: CALL pushes interpreter frames, so this MUST
        // NOT touch the AL call stack (§7.4). Sum(1000) = 500500.
        Assert.AreEqual(500500,
            RunInt('trigger OnRun(): Integer begin exit(Sum(1000)); end; procedure Sum(n: Integer): Integer begin if n <= 1 then exit(1); exit(n + Sum(n - 1)); end;'),
            'recursion to depth 1000 without AL stack growth');
    end;

    [Test]
    procedure T08_MutualRecursion()
    begin
        // IsEven/IsOdd mutual recursion, depth 101; encode boolean as 1/0.
        Assert.AreEqual(0,
            RunInt('trigger OnRun(): Integer begin exit(IsEven(101)); end; procedure IsEven(n: Integer): Integer begin if n = 0 then exit(1); exit(IsOdd(n - 1)); end; procedure IsOdd(n: Integer): Integer begin if n = 0 then exit(0); exit(IsEven(n - 1)); end;'),
            'mutual recursion IsEven(101) = false');
    end;

    [Test]
    procedure T09_ExitFromNestedCallLevels()
    begin
        // exit(value) from deep inside a callee's control flow returns to the RIGHT
        // frame with the RIGHT value.
        Assert.AreEqual(99,
            RunInt('trigger OnRun(): Integer begin exit(Pick(3)); end; procedure Pick(k: Integer): Integer var i: Integer; begin for i := 1 to 10 do if i = k then exit(99); exit(-1); end;'),
            'exit from inside a loop in a callee');
    end;

    // ===== var params (§7.2 — indirection, aliasing) =====

    [Test]
    procedure T10_VarParamSwap()
    begin
        // classic swap: a=3,b=4 -> a=4,b=3 -> 43.
        Assert.AreEqual(43,
            RunInt('trigger OnRun(): Integer var a: Integer; b: Integer; begin a := 3; b := 4; Swap(a, b); exit(a * 10 + b); end; procedure Swap(var x: Integer; var y: Integer) var t: Integer; begin t := x; x := y; y := t; end;'),
            'var-param swap aliases caller storage');
    end;

    [Test]
    procedure T11_VarParamThroughNestedCalls()
    begin
        // v passed var through TWO levels — the alias dereferences to the ORIGINAL slot.
        Assert.AreEqual(42,
            RunInt('trigger OnRun(): Integer var v: Integer; begin v := 5; Outer(v); exit(v); end; procedure Outer(var x: Integer) begin Inner(x); end; procedure Inner(var y: Integer) begin y := y + 37; end;'),
            'var param forwarded through nested calls');
    end;

    [Test]
    procedure T12_ByValueMutationInvisible()
    begin
        Assert.AreEqual(10,
            RunInt('trigger OnRun(): Integer var v: Integer; begin v := 10; Mut(v); exit(v); end; procedure Mut(x: Integer) begin x := 99; end;'),
            'by-value param mutation must not leak to the caller');
    end;

    [Test]
    procedure T13_VarParamOnGlobal()
    begin
        // module-level var passed as var argument (ARG_REF mode 2 — absolute slot).
        Assert.AreEqual(21,
            RunInt('var g: Integer; trigger OnRun(): Integer begin g := 20; Bump(g); exit(g); end; procedure Bump(var x: Integer) begin x := x + 1; end;'),
            'global passed by var aliases the global slot');
    end;

    [Test]
    procedure T14_VarParamReadModifyWrite()
    begin
        // read AND write through the same var param in one statement (LOAD_IND + STORE_IND).
        Assert.AreEqual(16,
            RunInt('trigger OnRun(): Integer var v: Integer; begin v := 2; Dbl(v); Dbl(v); Dbl(v); exit(v); end; procedure Dbl(var x: Integer) begin x := x * 2; end;'),
            'compound read/write through var param');
    end;

    // ===== Compile-time enforcement =====

    [Test]
    procedure T15_VarParamExactTypeEnforced()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Decimal var passed to `var Integer` param: exact type required, no conversion.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var d: Decimal; begin Take(d); end; procedure Take(var x: Integer) begin x := 1; end;', Diags),
            'var-param type mismatch must fail the compile');
        AssertDiag(Diags, 'ALI917', 'exact type');
    end;

    [Test]
    procedure T15b_VarTextCodeAnyLength()
    var
        Result: Codeunit "ALI Exec Result";
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Text[n] -> var Text: allowed (native AL), write visible.
        Assert.AreEqual('ab',
            RunText('trigger OnRun(): Text var r: Text[2048]; begin r := ''a''; Add(r); exit(r); end; procedure Add(var t: Text) begin t += ''b''; end;'),
            'Text[n] arg to var Text param');
        // Code -> var Text: caller's Code uppercasing re-applied after the call.
        Assert.AreEqual('AB',
            RunText('trigger OnRun(): Text var c: Code[10]; begin c := ''A''; Add(c); exit(c); end; procedure Add(var t: Text) begin t += ''b''; end;'),
            'Code arg to var Text param');
        // Text -> var Code: callee writes uppercase.
        Assert.AreEqual('AB',
            RunText('trigger OnRun(): Text var r: Text; begin r := ''a''; Add(r); exit(r); end; procedure Add(var c: Code[10]) begin c += ''b''; end;'),
            'Text arg to var Code param');
        // Text[2] -> var Text: callee overflow of the caller's length raises.
        RunExpectFail('trigger OnRun() var r: Text[2]; begin r := ''a''; Add(r); end; procedure Add(var t: Text) begin t += ''bc''; end;', Result);
        // Text[50] -> var Text[10]: compiles, possible-overflow warning only.
        Assert.IsTrue(
            Pipeline.CompileExpectingErrors('trigger OnRun() var r: Text[50]; begin Add(r); end; procedure Add(var t: Text[10]) begin t := ''x''; end;', Diags),
            'longer arg to shorter var param must compile');
        AssertDiag(Diags, 'ALI917', 'Possible overflow');
    end;

    [Test]
    procedure T16_VarParamNeedsLvalue()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() begin Take(1 + 2); end; procedure Take(var x: Integer) begin x := 1; end;', Diags),
            'var-param non-lvalue must fail the compile');
        AssertDiag(Diags, 'ALI917', 'assignable variable');
    end;

    [Test]
    procedure T17_ArgumentCountMismatch()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun(): Integer begin exit(Add(1)); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;', Diags),
            'wrong arity must fail the compile');
        AssertDiag(Diags, 'ALI916', 'expects 2 argument');
    end;

    [Test]
    procedure T18_ByValueParamConversionAllowed()
    var
        Native: Decimal;
    begin
        // Non-var params take normal assignment conversions: Integer arg -> Decimal param.
        Native := 5 / 2;
        Assert.AreEqual(Format(Native),
            RunText('trigger OnRun(): Text begin exit(Half(5)); end; procedure Half(d: Decimal): Text begin exit(FormatVia(d / 2)); end; procedure FormatVia(x: Decimal): Text begin exit('''' + x); end;'),
            'Int -> Decimal by-value param conversion');
    end;

    // ===== Frame / register capacity =====

    [Test]
    procedure T19_FrameExhaustionCleanError()
    var
        Result: Codeunit "ALI Exec Result";
    begin
        // Unbounded recursion: must fail with the clean ALI952 "call stack exhausted"
        // runtime error (captured in the result), never an uncatchable AL stack overflow.
        RunExpectFail('trigger OnRun(): Integer begin exit(R(1)); end; procedure R(n: Integer): Integer begin exit(R(n + 1)); end;', Result);
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'call stack exhausted') > 0,
            StrSubstNo('ALI952 expected, got: %1', Result.ErrorMessage()));
    end;

    // ===== Multiple procs / entry selection =====

    [Test]
    procedure T20_OnRunTriggerIsEntry()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // Codeunit-shell form: the OnRun trigger is the entry proc even when declared
        // AFTER other procedures. OnRun has no return type, so observe via the global.
        Assert.IsTrue(
            Pipeline.CompileAndRun('codeunit 50999 T { var g: Integer; procedure Triple(n: Integer): Integer begin exit(3 * n); end; trigger OnRun() begin g := Triple(10); end }', Result, Interp),
            StrSubstNo('codeunit shell run: %1', Result.ErrorMessage()));
        Assert.AreEqual(30, Interp.PeekGlobalInt(1), 'OnRun trigger selected as entry proc');
    end;

    [Test]
    procedure T21_ManyProcsSharedGlobals()
    var
        Native: Integer;
    begin
        Native := ((1 + 5) * 2) + ((2 + 5) * 2) + ((3 + 5) * 2);
        Assert.AreEqual(Native,
            RunInt('var acc: Integer; trigger OnRun(): Integer var i: Integer; begin acc := 0; for i := 1 to 3 do Accumulate(i); exit(acc); end; procedure Accumulate(n: Integer) begin acc := acc + Weight(n); end; procedure Weight(n: Integer): Integer begin exit((n + 5) * 2); end;'),
            'three procs cooperating over a module-level accumulator');
    end;

    [Test]
    procedure T23_UnrepresentableTypeNotYetSupported()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // A recognized AL type with no interpreter representation must be NAMED (ALI924), never
        // reported as "unknown type". This assertion keeps sliding down the support ladder as
        // ALI grows: it was RecordRef until the P0/P1 pass, then FieldRef/KeyRef until P2/P3
        // gave them their packed-pair representation. Notification is the current rung.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var n: Notification; begin end;', Diags),
            'Notification must still be rejected');
        AssertDiag(Diags, 'ALI924', 'Notification');
    end;

    [Test]
    procedure T24_RecordVarInProcCompiles()
    var
        Diags: Codeunit "ALI Diag Bag";
        Ok: Boolean;
        ErrText: Text;
    begin
        // M6: record vars are now supported (contrast T23's RecordRef, still rejected above).
        Ok := Pipeline.CompileExpectingErrors('trigger OnRun() var c: Record "ALI Test Customer"; begin end;', Diags);
        if Diags.Count() > 0 then
            ErrText := StrSubstNo('%1: %2', Diags.GetCode(1), Diags.GetMessage(1));
        Assert.IsTrue(Ok, StrSubstNo('record var in a procedure should compile under M6: %1', ErrText));
    end;

    // ===== Engine facade v0 (§13) =====

    [Test]
    procedure T25_EngineCompileAndRun()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        Assert.IsTrue(
            Engine.CompileAndRun('trigger OnRun(): Integer begin exit(Add(20, 22)); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;', Result),
            StrSubstNo('engine run failed: %1', Result.ErrorMessage()));
        Assert.IsTrue(Result.Succeeded(), 'engine result succeeded');
        Assert.AreEqual('42', Result.ResultText(), 'engine result value');
    end;

    [Test]
    procedure T26_EngineCompileCollectsDiagnostics()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        Assert.IsFalse(Engine.Compile('trigger OnRun() var u: NoSuchType; begin end;', Diags), 'engine compile must fail');
        AssertDiag(Diags, 'ALI925', 'NoSuchType');
    end;

    [Test]
    procedure T27_EngineCompileFailureFillsResult()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        Assert.IsFalse(Engine.CompileAndRun('trigger OnRun() var u: NoSuchType; begin end;', Result), 'run of failing compile');
        Assert.IsFalse(Result.Succeeded(), 'result reports failure');
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'ALI925') > 0, StrSubstNo('first diagnostic surfaced: %1', Result.ErrorMessage()));
    end;

    // ===== Regression guards around frames =====

    [Test]
    procedure T28_CallerLocalsSurviveCall()
    var
        Native: Integer;
    begin
        // Callee frames sit ABOVE the caller window — caller locals/temps must be intact
        // after the call returns.
        Native := 100 + (2 * 7) + 3;
        Assert.AreEqual(Native,
            RunInt('trigger OnRun(): Integer var a: Integer; b: Integer; begin a := 100; b := 3; exit(a + Twice(7) + b); end; procedure Twice(n: Integer): Integer begin exit(2 * n); end;'),
            'caller registers survive the callee frame');
    end;

    [Test]
    procedure T29_RecursiveVarParamAccumulator()
    begin
        // var param aliased down a RECURSIVE chain: every level adds into the same slot.
        Assert.AreEqual(15,
            RunInt('trigger OnRun(): Integer var total: Integer; begin total := 0; AddDown(5, total); exit(total); end; procedure AddDown(n: Integer; var acc: Integer) begin if n = 0 then exit; acc := acc + n; AddDown(n - 1, acc); end;'),
            'var param through recursive frames hits the one caller slot');
    end;

    [Test]
    procedure T30_StatementBudgetCountsCalleeStatements()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // budget/watchdog keeps firing inside callees: every CALL charges the budget (P1 —
        // statements are no longer charged individually; back-edges + calls are), so a
        // 50-deep recursion must report at least its 50 calls.
        Assert.IsTrue(Pipeline.CompileAndRun('trigger OnRun(): Integer begin exit(Sum(50)); end; procedure Sum(n: Integer): Integer begin if n <= 1 then exit(1); exit(n + Sum(n - 1)); end;', Result, Interp), 'run OK');
        Assert.IsTrue(Result.ExecutedStatements() >= 50, 'callee calls are counted');
    end;

    // ===== Paren-less zero-arg calls (Feature 1) — native AL allows `MyProc;` / `x := MyFunc` =====

    [Test]
    procedure T31_ParenlessVoidProcAsStatement()
    begin
        // `Inc3;` with no parens, no args — must resolve as a call (previously ALI928).
        Assert.AreEqual(6,
            RunInt('var g: Integer; trigger OnRun(): Integer begin g := 0; Inc3; Inc3; exit(g); end; procedure Inc3() begin g := g + 3; end;'),
            'paren-less void proc call as a statement');
    end;

    [Test]
    procedure T32_ParenlessFuncAssignment()
    begin
        // `x := MyFunc` with no parens — resolves as a zero-arg call, not a name lookup.
        Assert.AreEqual(42,
            RunInt('trigger OnRun(): Integer var x: Integer; begin x := MyFunc; exit(x); end; procedure MyFunc(): Integer begin exit(42); end;'),
            'paren-less function call in an assignment RHS');
    end;

    [Test]
    procedure T33_ParenlessCallInExpression()
    begin
        Assert.AreEqual(45,
            RunInt('trigger OnRun(): Integer begin exit(MyFunc + 3); end; procedure MyFunc(): Integer begin exit(42); end;'),
            'paren-less function call inside a larger expression');
    end;

    [Test]
    procedure T34_ParenlessCallWithParamsRaisesArity()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Proc HAS params: paren-less form must fail arity (ALI916), the native-equivalent
        // rule — paren-less is only legal when the call resolves with 0 args.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun(): Integer begin exit(Add); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;', Diags),
            'paren-less call to a proc that requires params must fail the compile');
        AssertDiag(Diags, 'ALI916', 'expects 2 argument');
    end;

    [Test]
    procedure T35_ParenlessVoidProcWithParamsAsStatementRaisesArity()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() begin Bump; end; procedure Bump(n: Integer) begin end;', Diags),
            'paren-less statement-form call to a proc that requires params must fail the compile');
        AssertDiag(Diags, 'ALI916', 'expects 1 argument');
    end;

    // ===== Named return values — native AL `trigger OnRun() Result : T` =====

    [Test]
    procedure T36_NamedReturnFallThrough()
    begin
        // Assign the named result, fall off the end — value must be returned (no exit).
        Assert.AreEqual(42,
            RunInt('trigger OnRun() Result: Integer begin Result := 42; end;'),
            'named return value returned on fall-through');
    end;

    [Test]
    procedure T37_NamedReturnBareExit()
    begin
        // Bare `exit` after assigning the named result returns the current value.
        Assert.AreEqual(7,
            RunInt('trigger OnRun() Result: Integer begin Result := 7; if Result > 0 then exit; Result := 99; end;'),
            'bare exit returns the named result value');
    end;

    [Test]
    procedure T38_NamedReturnReadAndAccumulate()
    begin
        // The name is readable like a local — accumulate into it across a loop.
        Assert.AreEqual(15,
            RunInt('trigger OnRun() Sum: Integer var i: Integer; begin for i := 1 to 5 do Sum := Sum + i; end;'),
            'named result readable/accumulatable inside the proc');
    end;

    [Test]
    procedure T39_NamedReturnOnCallee()
    begin
        // Named return on a CALLEE — caller consumes it like any function result.
        Assert.AreEqual(21,
            RunInt('trigger OnRun(): Integer begin exit(Triple(7)); end; procedure Triple(n: Integer) Result: Integer begin Result := 3 * n; end;'),
            'callee named return flows back through RESULT_FETCH');
    end;

    [Test]
    procedure T40_NamedReturnText()
    begin
        Assert.AreEqual('ab',
            RunText('trigger OnRun() Result: Text begin Result := ''a''; Result := Result + ''b''; end;'),
            'named return value of type Text');
    end;

    [Test]
    procedure T41_NamedReturnExitWithValueStillWins()
    begin
        // exit(v) overrides whatever the named result held.
        Assert.AreEqual(5,
            RunInt('trigger OnRun() Result: Integer begin Result := 1; exit(5); end;'),
            'exit(value) overrides the named result');
    end;

    [Test]
    procedure T42_NamedReturnDuplicateNameFails()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Named result clashing with a parameter name must fail like any duplicate.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P(x: Integer) x: Integer begin end;', Diags),
            'named result duplicating a parameter name must fail the compile');
        AssertDiag(Diags, 'AL0198', 'already defined');
    end;

    // ===== Procedure overloading (native AL: same name, different param count/types) =====

    [Test]
    procedure T43_OverloadByArity()
    begin
        Assert.AreEqual(24,
            RunInt('trigger OnRun(): Integer begin exit(F(2) + F(3, 7)); end; procedure F(a: Integer): Integer begin exit(a + 1); end; procedure F(a: Integer; b: Integer): Integer begin exit(a * b); end;'),
            'overloads picked by argument count');
    end;

    [Test]
    procedure T44_OverloadByArgType()
    begin
        Assert.AreEqual('inttxt',
            RunText('trigger OnRun(): Text begin exit(G(1) + G(''x'')); end; procedure G(a: Integer): Text begin exit(''int''); end; procedure G(a: Text): Text begin exit(''txt''); end;'),
            'same-arity overloads picked by argument type');
    end;

    [Test]
    procedure T45_OverloadExactBeatsConvertible()
    begin
        // 1 fits both G(Integer) (exact) and G(Decimal) (implicit widening) — exact wins.
        Assert.AreEqual('ID',
            RunText('trigger OnRun(): Text begin exit(G(1) + G(1.5)); end; procedure G(a: Integer): Text begin exit(''I''); end; procedure G(a: Decimal): Text begin exit(''D''); end;'),
            'exact type match beats an implicit-convertible overload');
    end;

    [Test]
    procedure T46_OverloadZeroArgParenless()
    begin
        // Paren-less `F;` statement must pick the zero-arg overload, not the 1-arg one.
        Assert.AreEqual(15,
            RunInt('var g: Integer; trigger OnRun(): Integer begin F; exit(g + F(5)); end; procedure F() begin g := 10; end; procedure F(a: Integer): Integer begin exit(a); end;'),
            'paren-less call resolves to the zero-arg overload');
    end;

    [Test]
    procedure T47_DuplicateSignatureStillAL0198()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // Same name AND same parameter types (param NAMES are irrelevant) stays an error.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('procedure P(a: Integer): Integer begin exit(a); end; procedure P(b: Integer): Integer begin exit(b); end;', Diags),
            'identical signatures must fail the compile');
        AssertDiag(Diags, 'AL0198', 'already defined');
    end;

    // ===== M11 phase 0/1 foundation: two compilation units linked into ONE module =====
    //
    // The mechanism every cross-object call rides on ("ALI Lowerer".LowerUnit +
    // "ALI Binder".SetAppendMode/SetUnitScope): each unit brings its own Token Table and Ast
    // Store, but they SHARE one Symbol Table and one Module. A harvested object unit is bound
    // into its OWN scope, parented to the root — so object and script cannot see each other's
    // names, which is what makes `Rec.Proc()` the only way in.
    //
    // Cross-unit resolution therefore goes by NAME TEXT, never by NameId: identifiers are
    // interned per Token Table (§4.1), so unit B's id for "Add" denotes a different string in
    // unit A's pool. LookupProcByName is the bridge; this test pins both halves.

    [Test]
    procedure T48_TwoUnitsLinkedIntoOneModule()
    var
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Lowerer: Codeunit "ALI Lowerer";
        Module: Codeunit "ALI Module";
        Symbols: Codeunit "ALI Symbol Table";
        EntryProc: Integer;
        ObjScope: Integer;
        ProcsAfterLib: Integer;
    begin
        Module.Reset();
        Symbols.Reset();
        ObjScope := Symbols.PushScope(0);                       // root-parented, like a harvested object
        Symbols.SetCurrentScope(Symbols.ModuleScope());

        // Unit A stands in for a harvested object: two procs, bound into the object scope.
        LinkUnit('procedure Dummy(zzz: Integer): Integer begin exit(zzz); end; procedure Add(a: Integer; b: Integer): Integer begin exit(a + b); end;',
                 Symbols, Module, Lowerer, ObjScope);
        ProcsAfterLib := Module.ProcCount();
        Assert.AreEqual(2, ProcsAfterLib, 'object unit contributes two procs');
        Assert.AreNotEqual(0, Symbols.LookupProcByName(ObjScope, 'add'), 'object proc is findable by name text, case-insensitively');
        Assert.AreEqual(0, Symbols.LookupProcByName(Symbols.ModuleScope(), 'add'), 'object procs must NOT leak into the script scope');

        // Unit B is the script. Appended — its proc row follows the object's.
        EntryProc := LinkUnit('exit(7 * 6);', Symbols, Module, Lowerer, 0);
        Assert.AreEqual(ProcsAfterLib + 1, Module.ProcCount(), 'appended unit adds one proc row');
        Assert.AreEqual(ProcsAfterLib + 1, EntryProc, 'appended entry proc follows the object procs');

        Module.SetEntryProcId(EntryProc);
        Assert.IsTrue(FinalizeModule(Lowerer, Module), 'module finalizes without diagnostics');

        Interp.Reset();
        Interp.LoadModule(Module);
        Interp.Run(Result);
        Assert.IsTrue(Result.Succeeded(), StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(42, Interp.GetResultInt(), 'the appended script unit is what runs');
    end;

    // Lex + parse + bind + lower one unit into the shared Symbols/Module; returns the unit's
    // entry proc id. UnitScope 0 = the script's module scope, anything else = an object scope.
    // Symbols are never reset here — the caller owns the shared table.
    local procedure LinkUnit(Source: Text; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; var Lowerer: Codeunit "ALI Lowerer"; UnitScope: Integer): Integer
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        Diags: Codeunit "ALI Diag Bag";
        Lexer: Codeunit "ALI Lexer";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
        Root: Integer;
    begin
        Tokens.Reset();
        Ast.Reset();
        Diags.Reset();

        Lexer.Tokenize(Source, Tokens, Diags);
        AssertNoDiags(Diags, Source);

        Root := Parser.ParseCompilationUnit(Tokens, Ast, Diags);
        AssertNoDiags(Diags, Source);

        Binder.SetAppendMode(true);
        Binder.SetUnitScope(UnitScope);
        Lowerer.SetObjectUnit(UnitScope <> 0);
        Binder.Bind(Tokens, Ast, Symbols, Diags, Module, Root);
        AssertNoDiags(Diags, Source);

        exit(Lowerer.LowerUnit(Tokens, Ast, Symbols, Diags, Module, Root));
    end;

    local procedure FinalizeModule(var Lowerer: Codeunit "ALI Lowerer"; var Module: Codeunit "ALI Module"): Boolean
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        Diags.Reset();
        exit(Lowerer.FinalizeModule(Module, Diags));
    end;

    local procedure AssertNoDiags(var Diags: Codeunit "ALI Diag Bag"; Source: Text)
    begin
        if Diags.Count() = 0 then
            exit;
        Assert.Fail(StrSubstNo('Unexpected diagnostic for <%1>: %2 %3', Source, Diags.GetCode(1), Diags.GetMessage(1)));
    end;

    // ===== M11 phase 1: calling a procedure declared on a TABLE =====
    //
    // End to end: the script calls "ALI Test Customer".HeadRoom(), whose body lives in that
    // table's own AL source. The compiler reads that source from the object's stored metadata,
    // compiles the procedure into this module with an implicit `Rec` receiver, and the CALL
    // passes the script's record by reference.
    //
    // Both table procedures address their fields UNQUALIFIED ("Credit Limit", "Post Count"),
    // which is how real table code is written and what the binder's implicit-receiver rewrite
    // exists to handle.

    [Test]
    procedure T49_TableProcedureIsHarvestedAndCalled()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";   // SingleInstance: this IS the instance Engine ran
    begin
        Cust.DeleteAll();
        Cust.Init();
        Cust."No." := 'C-M11';
        Cust."Credit Limit" := 1000;
        Cust.Balance := 250;
        Cust."Post Count" := 7;
        Cust.Insert();

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11''); exit(c.HeadRoom()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'HeadRoom() = Credit Limit - Balance, computed by harvested table code');
    end;

    [Test]
    procedure T51_UnknownTableProcedureStillErrors()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // The harvest path must not swallow genuine mistakes: a name that is neither a builtin
        // record method nor a procedure of the table stays ALI961.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var c: Record "ALI Test Customer"; begin c.NoSuchThing(); end;', Diags),
            'unknown record method must fail the compile');
        AssertDiag(Diags, 'ALI961', 'NoSuchThing');
    end;

    // ===== M11 phase A: the harvested unit is the whole OBJECT, so siblings resolve =====
    //
    // Phase 1 harvested one procedure at a time, which made a table procedure unable to call
    // another procedure of its own table. Phase A compiles every procedure of the object as ONE
    // unit — sibling calls are then ordinary in-unit lookups, and the implicit `Rec` receiver is
    // threaded through them so caller and callee share one record.

    [Test]
    procedure T52_SiblingAndLocalHelperCalls()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11C');

        // HeadRoomAfterFee() calls the PUBLIC sibling HeadRoom() and the LOCAL helper Fee().
        // 1000 - 250 - 50 = 700. A local procedure has to be in the unit for this to bind at all.
        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11C''); exit(c.HeadRoomAfterFee()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(700, Interp.GetResultDec(), 'sibling call + local helper call, both inside the harvested object');
    end;

    [Test]
    procedure T53_ParenlessSiblingCall()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11D');

        // `exit(HeadRoom)` — AL drops the parentheses on a no-arg call, so the sibling path has
        // to be reachable from the NameExpr binder too, not only from InvocationExpr.
        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11D''); exit(c.HeadRoomParenless()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'paren-less sibling call resolves like the parenthesised form');
    end;

    [Test]
    procedure T55_MutualRecursionBetweenSiblings()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11F');

        // StepsDown <-> StepsUp call each other. Only pass 1 declaring every signature of the
        // unit before any body is bound makes the forward reference resolvable.
        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11F''); exit(c.StepsDown(6)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(6, Interp.GetResultInt(), 'mutual recursion across two procedures of one object');
    end;

    [Test]
    procedure T56_BlockedProcedureDoesNotSinkItsSiblings()
    var
        Cust: Record "ALI Test Customer";
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11G');

        // UsesUnsupportedGlobal names a global the interpreter cannot represent (a Codeunit), so
        // that declaration was dropped from the harvested unit and this procedure does not
        // compile. The failure must be reported HERE, naming the procedure and the reason, and
        // must not be reported as "no procedure of that name" (ALI961).
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('var c: Record "ALI Test Customer"; begin c.UsesUnsupportedGlobal(); end;', Diags),
            'a procedure that cannot be compiled must fail the compile');
        AssertDiag(Diags, 'ALI922', 'UsesUnsupportedGlobal');

        // ...and every other procedure of the SAME table still compiles and runs. This is the
        // whole point of per-procedure error isolation.
        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11G''); exit(c.HeadRoomAfterFee()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(700, Interp.GetResultDec(), 'the blocked procedure''s siblings are unaffected');
    end;

    [Test]
    procedure T57_FieldTriggersDoNotCollide()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11H');

        // "ALI Test Customer" declares OnValidate on two fields. Harvesting them as procedures
        // would be two declarations of the same name (AL0198) and would take the whole object
        // down; the harvester skips every trigger, so this compiles at all.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11H''); exit(c.HeadRoom()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'same-named field triggers are excluded from the harvested unit');
    end;

    // ===== M11 phase B/B2: the object's own global variables =====
    //
    // Harvested with the procedures, from however many separate var sections the object declares,
    // and stored PER DECLARED VARIABLE (phase B2): each variable of the object's type owns a
    // block, so T60's two record variables keep separate counters the way native AL does.

    [Test]
    procedure T58_GlobalSurvivesAcrossCalls()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11I');

        // Three calls on one record variable: the counter has to persist BETWEEN calls, which is
        // exactly what a proc local would not do.
        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11I''); c.BumpHarvestCounter(); c.BumpHarvestCounter(); exit(c.BumpHarvestCounter()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(3, Interp.GetResultInt(), 'the object global kept its value across three calls');
    end;

    [Test]
    procedure T59_GlobalsFromBothVarSections()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11J');

        // RememberName writes LastLabel (first var section) and Names (SECOND var section, the
        // one declared between procedures). `Names` is also a handle-kind global, so this proves
        // the script's entry proc opened it — an unopened List handle would fail at runtime.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; n: Integer; ' +
                'begin c.Get(''C-M11J''); c.RememberName(''alpha''); n := c.RememberName(''beta''); ' +
                'if c.LastRememberedName() <> ''beta'' then exit(-1); exit(n); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, Interp.GetResultInt(), 'both var sections were hoisted into one unit; the List global was opened once');
    end;

    [Test]
    procedure T60_GlobalsArePerVariableNotPerObject()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11K');

        // TWO record variables of the same table, each with its OWN block of the table's globals
        // (phase B2). `a`'s bump must not be visible to `b`, so b's first bump returns 1 — the
        // native AL answer. Before B2 there was one copy per object and this returned 2.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var a: Record "ALI Test Customer"; b: Record "ALI Test Customer"; ' +
                'begin a.Get(''C-M11K''); b.Get(''C-M11K''); a.BumpHarvestCounter(); exit(b.BumpHarvestCounter()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'each record variable owns its copy of the table''s globals');
    end;

    [Test]
    procedure T61_UnrepresentableGlobalIsDroppedNotFatal()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11L');

        // The table declares `Helper: Codeunit "ALI Engine"`, which has no interpreter
        // representation. That declaration is dropped from the harvested unit — it must not fail
        // the object, because a unit-level error is the one failure per-procedure isolation
        // cannot contain. Only UsesUnsupportedGlobal (T56) is lost.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11L''); exit(c.HeadRoomAfterFee()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(700, Interp.GetResultDec(), 'an unrepresentable global costs only the procedures that name it');
    end;

    // ===== M11 phase C1/C2: codeunit variables and codeunit procedure calls =====
    //
    // `Codeunit "X"` is now a declarable type (TypeArg = object id). It carries NO register:
    // with object globals stored per object (phase B) there is nothing per-instance left to hold,
    // so `MyCU.Proc(a)` is an ORDINARY receiver-less call — the same CALL a script-local
    // procedure gets. That is why C2 needed no new opcode, no new mark and no lowerer path
    // beyond recognising a positive SymbolId on a member access (the paren-less form).
    //
    // Codeunit.Run (C3) is NOT part of this — it does not harvest anything at all. See T83+.

    [Test]
    procedure T62_CodeunitVariableAndProcedureCall()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; ' +
                'begin exit(cu.Add(3, 4)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(7, Interp.GetResultInt(), 'a codeunit procedure runs from harvested source');
    end;

    [Test]
    procedure T63_CodeunitSiblingAndLocalHelper()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // AddWithBonus calls the public sibling Add and the local helper Bonus. Inside a codeunit
        // unit these are plain calls — no implicit receiver, unlike the table case.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; ' +
                'begin exit(cu.AddWithBonus(3, 4)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(107, Interp.GetResultInt(), 'sibling + local-helper calls inside a harvested codeunit');
    end;

    [Test]
    procedure T64_CodeunitGlobalsFromBothVarSections()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // CallCount (first var section) persists across calls; Prefix (second var section,
        // declared between procedures) proves the phase-B hoist works on a codeunit too.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; ' +
                'begin cu.SetPrefix(''ali''); cu.Bump(); cu.Bump(); ' +
                'if cu.Tag() <> ''ali-cu'' then exit(-1); exit(cu.Bump()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(3, Interp.GetResultInt(), 'codeunit globals persist across calls, from both var sections');
    end;

    [Test]
    procedure T65_ParenlessCodeunitCall()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // `cu.Bump` with no parentheses, as a statement AND as a value — the lowerer reaches
        // these through the MemberAccessExpr paths, not the InvocationExpr one.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; n: Integer; ' +
                'begin cu.Bump; n := cu.Bump; exit(n); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, Interp.GetResultInt(), 'paren-less codeunit calls work as statement and as value');
    end;

    [Test]
    procedure T66_CodeunitCallsTableProcedure()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11M');

        // Harvesting is recursive: binding the codeunit pulls in "ALI Test Customer" because
        // HeadRoomOf calls a procedure on a local record variable.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var cu: Codeunit "ALI Test Helper CU"; ' +
                'begin exit(cu.HeadRoomOf(''C-M11M'')); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'a harvested codeunit calling a harvested table procedure');
    end;

    [Test]
    procedure T67_OnRunIsNotHarvested()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        // The fixture's OnRun would set CallCount to -1 if it ever ran. It is a trigger, so it is
        // not harvested at all — calling it BY NAME must fail to bind. `cu.Run` still reaches it
        // (T87), because Run never goes through the harvester in the first place.

        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var cu: Codeunit "ALI Test Helper CU"; begin cu.OnRun(); end;', Diags),
            'a trigger is not callable as a procedure');
        AssertDiag(Diags, 'ALI961', 'OnRun');
    end;

    [Test]
    procedure T68_UnknownCodeunitRejected()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        // A codeunit subtype is resolved at bind time through AllObjWithCaption, like a record's
        // table name — a name that does not exist is a type error, not a runtime surprise.

        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var cu: Codeunit "ALI No Such Codeunit"; begin exit(1); end;', Diags),
            'an unknown codeunit name must fail the compile');
        AssertDiag(Diags, 'ALI959', 'ALI No Such Codeunit');
    end;

    // ===== Record arguments to harvested procedures, and hand-off to local helpers =====
    //
    // The shape real helper code is written in: a public procedure takes a record (by value or by
    // var) and passes it straight to a local helper. Both halves are exercised on a CODEUNIT and
    // on a TABLE, because a table procedure also carries the implicit `Rec` receiver in
    // descriptor row 1 — an explicit record parameter has to sit at row 2 without disturbing it.

    [Test]
    procedure T69_CodeunitVarRecordArgThroughLocalHelper()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11N');

        // BumpVia(var Cust) hands the alias to the local helper ApplyBump(var Cust). The write
        // must travel back through both frames to the script's own record.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; c: Record "ALI Test Customer"; n: Integer; ' +
                'begin c.Get(''C-M11N''); n := cu.BumpVia(c, 5); c.Modify(); exit(n + c."Post Count"); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(24, Interp.GetResultInt(), 'var record arg aliased through a local helper (12 + 12)');

        Cust.Get('C-M11N');
        Assert.AreEqual(12, Cust."Post Count", 'the write reached the database through two frames');
    end;

    [Test]
    procedure T70_CodeunitByvalRecordArgIsACopy()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11O');

        // DescribeByVal writes Post Count on its own copy; the caller must still read 7.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; c: Record "ALI Test Customer"; s: Text; ' +
                'begin c.Get(''C-M11O''); s := cu.DescribeByVal(c); ' +
                'if not s.StartsWith(''C-M11O/'') then exit(-1); exit(c."Post Count"); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(7, Interp.GetResultInt(), 'a byval record argument is a copy — the caller is untouched');
    end;

    [Test]
    procedure T71_CodeunitVarRecordToByvalLocalHelper()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11P');

        // HeadRoomVia holds the record by var and passes it BYVAL to ComputeHeadRoom — the helper
        // prologue has to open a fresh handle and copy rather than alias.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var cu: Codeunit "ALI Test Helper CU"; c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11P''); exit(cu.HeadRoomVia(c)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'var record arg handed to a byval local helper');
    end;

    [Test]
    procedure T72_TableProcedureWithRecordArgAndLocalHelper()
    var
        CustA: Record "ALI Test Customer";
        CustB: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(CustA, 'C-M11Q');
        SeedCustomer(CustB, 'C-M11R');
        CustB."Credit Limit" := 400;
        CustB.Modify();

        // HeadRoomDiff carries BOTH the implicit receiver (row 1) and an explicit var record
        // parameter (row 2), and forwards the latter to a local helper: 750 - 150 = 600.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var a: Record "ALI Test Customer"; b: Record "ALI Test Customer"; ' +
                'begin a.Get(''C-M11Q''); b.Get(''C-M11R''); exit(a.HeadRoomDiff(b)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(600, Interp.GetResultDec(), 'implicit receiver + explicit record param + local helper');
    end;

    [Test]
    procedure T74_NestedObjectCallInAnArgument()
    var
        CustA: Record "ALI Test Customer";
        CustB: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(CustA, 'C-M11U');
        SeedCustomer(CustB, 'C-M11V');

        // An object call INSIDE another object call's argument. The outer call's receiver used to
        // be staged before the argument was evaluated, so the inner call's own staging overwrote
        // it — the outer procedure then ran against the wrong record. b.BumpPostCount(1) = 8;
        // a.BumpTwice(8) = 7+8+8 = 23; b is left at 8.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var a: Record "ALI Test Customer"; b: Record "ALI Test Customer"; n: Integer; ' +
                'begin a.Get(''C-M11U''); b.Get(''C-M11V''); n := a.BumpTwice(b.BumpPostCount(1)); ' +
                'exit(n * 100 + b."Post Count"); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2308, Interp.GetResultInt(), 'the outer call kept its own receiver across the nested call');
    end;

    [Test]
    procedure T75_MissingRecordMethodArgumentDoesNotRecurse()
    var
        Diags: Codeunit "ALI Diag Bag";
    begin
        // `GetBySystemId` requires its Guid argument. The arm binds argument 1 at a FIXED position,
        // regardless of the arity error already queued — and an unguarded read of a child that
        // does not exist returns another node's edge from the shared edge array. When that node
        // was an ancestor the binder recursed until AL killed the session with "insufficient
        // memory ... may be caused by recursive functions". Must be a plain diagnostic.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('trigger OnRun() var c: Record "ALI Test Customer"; begin c.GetBySystemId; end;', Diags),
            'a record method missing a required argument must fail the compile');
        AssertDiag(Diags, 'ALI916', 'GETBYSYSTEMID');
    end;

    [Test]
    procedure T77_ParenlessTableProcedureFromScript()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11X');

        // `c.HeadRoom` — no parentheses on a no-arg TABLE procedure, in expression position.
        // The codeunit receiver already allowed this; the record receiver used to report AL0132
        // "is not a field of the record", because only the BUILT-IN record methods were tried.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11X''); exit(c.HeadRoom); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'paren-less table procedure call from the script');
    end;

    [Test]
    procedure T78_ParenlessTableProcedureAsStatement()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11Y');

        // Statement form (`c.BumpHarvestCounter;`) binds in STATEMENT context, so a value-returning
        // procedure may have its result discarded and a void one would not trip ALI929.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-M11Y''); c.BumpHarvestCounter; exit(c.BumpHarvestCounter); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, Interp.GetResultInt(), 'paren-less table procedure runs as a statement');
    end;

    [Test]
    procedure T79_CodeunitGlobalsArePerVariable()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // Two variables of the same CODEUNIT. Native AL gives each its own instance, so x's two
        // bumps leave y's counter untouched: 2 + 1 = 3. One shared copy would have said 2 + 3.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var x: Codeunit "ALI Test Helper CU"; y: Codeunit "ALI Test Helper CU"; n: Integer; ' +
                'begin x.Bump(); n := x.Bump(); exit(n + y.Bump()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(3, Interp.GetResultInt(), 'each codeunit variable owns its copy of the codeunit''s globals');
    end;

    [Test]
    procedure T80_HandleKindGlobalIsPerVariableToo()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11Z');

        // `Names` is a List global of the table — a HANDLE-kind one. Per-variable storage only
        // works if the entry proc opened a SEPARATE list for each instance's block, so b's first
        // Add must see a list of one, not of two.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var a: Record "ALI Test Customer"; b: Record "ALI Test Customer"; ' +
                'begin a.Get(''C-M11Z''); b.Get(''C-M11Z''); a.RememberName(''alpha''); ' +
                'if a.LastRememberedName() <> ''alpha'' then exit(-1); ' +
                'if b.LastRememberedName() <> '''' then exit(-2); ' +
                'exit(b.RememberName(''beta'')); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'each instance got its own List handle and its own Text global');
    end;

    [Test]
    procedure T81_SiblingCallStaysOnTheCallersInstance()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11AA');

        // BumpHarvestCounterTwice bumps once itself and once through a SIBLING call. The sibling
        // has no receiver variable to read an instance index off, so it forwards the one its
        // caller's frame was given — both bumps must land on `a`, and `b` must still read 1.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var a: Record "ALI Test Customer"; b: Record "ALI Test Customer"; ' +
                'begin a.Get(''C-M11AA''); b.Get(''C-M11AA''); ' +
                'if a.BumpHarvestCounterTwice() <> 2 then exit(-1); exit(b.BumpHarvestCounter()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'a sibling call inherits the caller''s instance');
    end;

    [Test]
    procedure T82_LiveCheckHarvestsSignaturesOnly()
    var
        Cust: Record "ALI Test Customer";
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-M11SO');


        // CheckDiagnostics binds NO harvested body, but the signature still has to be there:
        // the call type-checks (Decimal into a Decimal) and the check comes back clean.
        Assert.IsTrue(
            Engine.CheckDiagnostics('trigger OnRun() var c: Record "ALI Test Customer"; d: Decimal; begin c.Get(''C-M11SO''); d := c.HeadRoom(); end;', Diags),
            StrSubstNo('live check must be clean: %1', Diags.GetMessage(1)));

        // Signatures-only must not swallow a real mistake either.
        Assert.IsFalse(
            Engine.CheckDiagnostics('trigger OnRun() var c: Record "ALI Test Customer"; begin c.NoSuchThing(); end;', Diags),
            'unknown record method must still fail the live check');
        AssertDiag(Diags, 'ALI961', 'NoSuchThing');

        // The registry is SingleInstance: a real compile after a live check must get bodies back.
        Assert.IsTrue(
            Engine.CompileAndRun('trigger OnRun(): Decimal var c: Record "ALI Test Customer"; begin c.Get(''C-M11SO''); exit(c.HeadRoom()); end;', Result),
            StrSubstNo('run after live check failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(750, Interp.GetResultDec(), 'the harvested body is compiled again by Compile()');
    end;

    // ===== M11 phase C3: Codeunit.Run =====
    //
    // Run is the one cross-object call that is NOT harvested — the platform executes the
    // codeunit, so OnRun is never lexed, parsed, bound or lowered, and the Boolean/error
    // contract is native AL's own. These tests assert both halves: that the run really happens,
    // and that nothing was compiled to make it happen.

    [Test]
    procedure T83_StaticCodeunitRunWithoutRecord()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunCU: Codeunit "ALI Test Run CU";
    begin
        RunCU.ResetCounters();

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var ok: Boolean; ' +
                'begin ok := Codeunit.Run(Codeunit::"ALI Test Run CU"); ' +
                'if ok then exit(1) else exit(0); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'Codeunit.Run returns true for a codeunit that completes');
        Assert.AreEqual(1, RunCU.RunCount(), 'OnRun really executed, natively');
    end;

    [Test]
    procedure T84_CodeunitRunSwallowsTheErrorWhenTheResultIsUsed()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunCU: Codeunit "ALI Test Run CU";
    begin
        // Native contract: a consumed Boolean means the error is caught and the script carries on.
        // No interpreted error trap is involved — the platform's own conditional Run is the trap.
        RunCU.ResetCounters();
        RunCU.SetFailOnRun(true);

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var ok: Boolean; n: Integer; ' +
                'begin ok := Codeunit.Run(Codeunit::"ALI Test Run CU"); ' +
                'n := 42; if ok then n := -1; exit(n); end;', Result),
            StrSubstNo('the script itself must not fail: %1', Result.ErrorMessage()));
        Assert.AreEqual(42, Interp.GetResultInt(), 'a failed Codeunit.Run returns false and execution continues');
        Assert.AreEqual(1, RunCU.RunCount(), 'OnRun was entered before it failed');
        RunCU.SetFailOnRun(false);
    end;

    [Test]
    procedure T85_CodeunitRunWithRecordArgument()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        SeedCustomer(Cust, 'C-M11R1');       // "Post Count" = 7

        // THE record-bridge check. ALI holds records as RecordRef and native Codeunit.Run will
        // not take one, so the record travels as a Variant. If the platform does not present it
        // to OnRun as the right row, this fails here rather than silently doing nothing.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; ok: Boolean; ' +
                'begin c.Get(''C-M11R1''); ' +
                'ok := Codeunit.Run(Codeunit::"ALI Test Run Rec CU", c); ' +
                'if not ok then exit(0); exit(1); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));

        Cust.Get('C-M11R1');
        Assert.AreEqual(12, Cust."Post Count", 'OnRun received the caller''s record and modified it');
    end;

    [Test]
    procedure T86_DiscardedRunResultRaises()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        RunCU: Codeunit "ALI Test Run CU";
    begin
        // Native contract, other half: with the Boolean discarded, a failing Run is an error.
        RunCU.ResetCounters();
        RunCU.SetFailOnRun(true);

        Assert.IsFalse(
            Engine.CompileAndRun('trigger OnRun() begin Codeunit.Run(Codeunit::"ALI Test Run CU"); end;', Result),
            'a discarded Run result must let the error through');
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'on purpose') > 0, StrSubstNo('the codeunit''s own error must surface: %1', Result.ErrorMessage()));
        RunCU.SetFailOnRun(false);
    end;

    [Test]
    procedure T87_InstanceRunIsNativeAndNotHarvested()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        RunCU: Codeunit "ALI Test Run CU";
    begin
        // `cu.Run` through a codeunit VARIABLE. T67 pins that OnRun is not harvestable as a
        // procedure; this pins that Run reaches it anyway, by not going through the harvester at
        // all — including the paren-less shape.
        RunCU.ResetCounters();

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Run CU"; ok: Boolean; ' +
                'begin cu.Run; ok := cu.Run(); if ok then exit(1) else exit(0); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'MyCU.Run returns the native Boolean');
        Assert.AreEqual(2, RunCU.RunCount(), 'both the paren-less and the parenthesised form ran OnRun');
    end;

    [Test]
    procedure T88_RunMixedWithProcedureCallsIsRefused()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        // A native Run gets a fresh platform instance; interpreted procedure calls mutate ALI's
        // own per-variable instance block. One variable cannot mean both.

        Assert.IsFalse(
            Pipeline.CompileExpectingErrors(
                'trigger OnRun() var cu: Codeunit "ALI Test Helper CU"; begin cu.Bump(); cu.Run(); end;', Diags),
            'Run and procedure calls through one codeunit variable must not compile');
        AssertDiag(Diags, 'ALI928', 'fresh instance');
    end;

    [Test]
    procedure T89_RunArgumentsAreChecked()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin


        // The record argument is passed by reference, so it has to be a variable.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors(
                'trigger OnRun() begin Codeunit.Run(Codeunit::"ALI Test Run Rec CU", 5); end;', Diags),
            'a non-record second argument must not compile');
        AssertDiag(Diags, 'ALI931', 'record VARIABLE');

        // And the first argument is an object number, not anything Int-shaped by accident.
        Assert.IsFalse(
            Pipeline.CompileExpectingErrors('begin Codeunit.Run(''nope''); end;', Diags),
            'a Text codeunit id must not compile');
        AssertDiag(Diags, 'ALI931', 'codeunit id');
    end;

    // ===== Script editor: stored bytecode + strict `trigger OnRun` entry =====

    [Test]
    procedure T91_StoredModuleRunsInALaterSession()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        OptMeta: Codeunit "ALI Option Meta";
        Result: Codeunit "ALI Exec Result";
        Names: List of [Text];
        Serialized: Text;
    begin
        // Option caption (OPT_TO_TEXT carries a session-scoped set id), decimal and free text in
        // the constant pools — everything the serializer has to carry across.
        Assert.IsTrue(Engine.Compile('trigger OnRun(): Text var o: Option Alpha,Beta; begin o := o::Beta; exit(Format(o) + ''|'' + Format(1.5) + ''|é,"x"''); end;', Diags), Diags.ToText());
        Serialized := Engine.SaveCompiled();
        Assert.AreNotEqual('', Serialized, 'module serialized');

        // "Later session": the option sets are interned anew, in another order.
        OptMeta.Reset();
        Names.Add('Other');
        Names.Add('Set');
        OptMeta.InternInlineSet(Names);

        Assert.IsTrue(Engine.LoadCompiled(Serialized), 'stored module loads');
        Engine.RunCompiled(Result);
        Assert.IsTrue(Result.Succeeded(), Result.ErrorMessage());
        Assert.AreEqual('Beta|' + Format(1.5) + '|é,"x"', Result.ResultText(), 'stored module runs like the compiled one');
        Assert.IsFalse(Engine.LoadCompiled('{"v":0}'), 'a module of another serial version is refused');
    end;

    [Test]
    procedure T92_StrictEntryIsTriggerOnRun()
    var
        BareDiags: Codeunit "ALI Diag Bag";
        ProcDiags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        NamedResult: Codeunit "ALI Exec Result";
        Result: Codeunit "ALI Exec Result";
        TypedResult: Codeunit "ALI Exec Result";
        BareOk: Boolean;
        ProcOk: Boolean;
    begin
        Engine.SetRequireOnRun(true);
        // Boom is declared first: the default rule would have run it.
        Engine.CompileAndRun('procedure Boom() begin Error(''wrong entry''); end; trigger OnRun() begin Helper(); end; procedure Helper() begin end;', Result);
        // ALI extension: the entry trigger may return a value, typed or named, like a procedure.
        Engine.CompileAndRun('trigger OnRun(): Integer begin exit(Twice(21)); end; procedure Twice(n: Integer): Integer begin exit(2 * n); end;', TypedResult);
        Engine.CompileAndRun('trigger OnRun() Msg: Text begin Msg := ''named''; end;', NamedResult);
        ProcOk := Engine.Compile('procedure OnRun() begin end;', ProcDiags);
        BareOk := Engine.Compile('begin end;', BareDiags);
        Engine.SetRequireOnRun(false);   // single instance: every other test uses the first-procedure rule

        Assert.IsTrue(Result.Succeeded(), StrSubstNo('trigger OnRun is the entry: %1', Result.ErrorMessage()));
        Assert.IsTrue(TypedResult.Succeeded(), TypedResult.ErrorMessage());
        Assert.AreEqual('42', TypedResult.ResultText(), 'trigger OnRun(): Integer returns its exit value');
        Assert.IsTrue(NamedResult.Succeeded(), NamedResult.ErrorMessage());
        Assert.AreEqual('named', NamedResult.ResultText(), 'trigger OnRun() Msg: Text returns its named value');
        Assert.IsFalse(ProcOk, 'a procedure named OnRun is not the trigger');
        AssertDiag(ProcDiags, 'ALI1000', 'trigger OnRun()');
        Assert.IsFalse(BareOk, 'a bare block has no entry point');
        AssertDiag(BareDiags, 'ALI1000', 'no entry point');
    end;

    // ===== Native codeunit catalogue ("ALI Builtin Registry".PopulateNative) =====
    //
    // Every test runs with the object-call gate CLOSED: a catalogued call is made natively and
    // never harvested, so passing here is also the proof that nothing was compiled from source
    // (UrlEncode, ToBase64, Pow, zip... are all DotNet inside, which the harvester can never do).

    [Test]
    procedure T93_TypeHelperIsCalledNatively()
    var
        Engine: Codeunit "ALI Engine";
        TypeHelper: Codeunit "Type Helper";
        Encoded: Text;
        Value: Text;
    begin
        Value := 'a b&c';
        Encoded := TypeHelper.UrlEncode(Value);
        Assert.AreEqual(Encoded + '|' + Value,
            RunText('var th: Codeunit "Type Helper"; procedure P(): Text var s: Text; r: Text; begin s := ''a b&c''; r := th.UrlEncode(s); exit(r + ''|'' + s); end;'),
            'expression form: native result, and the var parameter is written back');
        Value := '<b>';
        TypeHelper.HtmlEncode(Value);
        Assert.AreEqual(Value,
            RunText('var th: Codeunit "Type Helper"; g: Text; procedure P(): Text begin g := ''<b>''; th.HtmlEncode(g); exit(g); end;'),
            'statement form: the var write-back reaches a GLOBAL');
        Assert.AreEqual(2, RunInt('var th: Codeunit "Type Helper"; procedure P(): Integer begin exit(StrLen(th.CRLFSeparator)); end;'), 'paren-less member call');
        Assert.AreEqual(11,
            RunInt('var th: Codeunit "Type Helper"; procedure P(): Integer var d: Date; begin if not th.Evaluate(d, ''2026-09-11'', ''yyyy-MM-dd'', '''') then exit(-1); exit(Date2DMY(d, 1)); end;'),
            'a `var Variant` parameter writes back into the Date variable passed to it');

    end;

    [Test]
    procedure T94_Base64ConvertTextAndStreamOverloads()
    var
        Base64: Codeunit "Base64 Convert";
        Engine: Codeunit "ALI Engine";
    begin
        Assert.AreEqual(Base64.ToBase64('abc'), RunText('var b: Codeunit "Base64 Convert"; procedure P(): Text begin exit(b.ToBase64(''abc'')); end;'), 'ToBase64(Text)');
        Assert.AreEqual('héllo',
            RunText('var b: Codeunit "Base64 Convert"; procedure P(): Text begin exit(b.FromBase64(b.ToBase64(''héllo'', TextEncoding::UTF8), TextEncoding::UTF8)); end;'),
            'TextEncoding overloads round-trip, one native call nested in another');
        // The native call reads/writes the very stream the script's handle owns: FromBase64 writes
        // through `o`, the linked `i` sees it, and ToBase64 reads it back.
        Assert.AreEqual('aGVsbG8=',
            RunText('var b: Codeunit "Base64 Convert"; procedure P(): Text var o: OutStream; i: InStream; begin b.FromBase64(''aGVsbG8='', o); i.Link(o); exit(b.ToBase64(i)); end;'),
            'FromBase64(Text, OutStream) then ToBase64(InStream)');

    end;

    [Test]
    procedure T95_MathAndEncoding()
    var
        EncodingCU: Codeunit Encoding;
        Engine: Codeunit "ALI Engine";
        MathCU: Codeunit Math;
    begin
        // Integer arguments to Decimal parameters; Log is overloaded by arity.
        Assert.AreEqual(Format(MathCU.Pow(2, 10) + MathCU.Log(8, 2) + MathCU.Log(1) + MathCU.Sqrt(16)),
            RunText('var m: Codeunit Math; procedure P(): Text begin exit(Format(m.Pow(2, 10) + m.Log(8, 2) + m.Log(1) + m.Sqrt(16))); end;'),
            'Math.Pow / Log(2 args) / Log(1 arg) / Sqrt');
        Assert.AreEqual(EncodingCU.Convert(1252, 65001, 'abc'),
            RunText('var e: Codeunit Encoding; procedure P(): Text begin exit(e.Convert(1252, 65001, ''abc'')); end;'),
            'Encoding.Convert');

    end;

    [Test]
    procedure T96_NativeCallDiagnostics()
    var
        OverloadDiags: Codeunit "ALI Diag Bag";
        VarDiags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var b: Codeunit "Base64 Convert"; procedure P(): Text begin exit(b.ToBase64(''a'', 5)); end;', OverloadDiags),
            'no ToBase64 overload takes (Text, Integer)');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('var th: Codeunit "Type Helper"; procedure P(): Text begin exit(th.UrlEncode(''x'')); end;', VarDiags),
            'UrlEncode takes its argument by var');

        AssertDiag(OverloadDiags, 'ALI916', 'No overload');
        AssertDiag(VarDiags, 'ALI917', 'by var');
    end;

    [Test]
    procedure T97_DataCompressionZipRoundTrip()
    var
        Engine: Codeunit "ALI Engine";
    begin
        // The archive lives INSIDE the Data Compression instance between calls — the reason its
        // variables are handles into "ALI Native Runtime" rather than stateless names.
        Assert.AreEqual('1|a.txt|9|zip-hello',
            RunText('var dc: Codeunit "Data Compression"; procedure P(): Text ' +
                'var o: OutStream; i: InStream; zo: OutStream; zi: InStream; eo: OutStream; ei: InStream; names: List of [Text]; len: Integer; s: Text; ' +
                'begin o.WriteText(''zip-hello''); i.Link(o); ' +
                'dc.CreateZipArchive(); dc.AddEntry(i, ''a.txt''); dc.SaveZipArchive(zo); dc.CloseZipArchive(); ' +
                'zi.Link(zo); dc.OpenZipArchive(zi, false); dc.GetEntryList(names); ' +
                'dc.ExtractEntry(names.Get(1), eo, len); dc.CloseZipArchive(); ' +
                'ei.Link(eo); ei.ReadText(s); ' +
                'exit(Format(names.Count()) + ''|'' + names.Get(1) + ''|'' + Format(len) + ''|'' + s); end;'),
            'zip: create / add / save / open / list / extract (var length written back)');
        Assert.AreEqual(Format(true) + '|gzip-hello',
            RunText('procedure P(): Text var dc: Codeunit "Data Compression"; o: OutStream; i: InStream; co: OutStream; ci: InStream; dout: OutStream; din: InStream; s: Text; gz: Boolean; ' +
                'begin o.WriteText(''gzip-hello''); i.Link(o); dc.GZipCompress(i, co); ci.Link(co); gz := dc.IsGZip(ci); ' +
                'dc.GZipDecompress(ci, dout); din.Link(dout); din.ReadText(s); exit(Format(gz) + ''|'' + s); end;'),
            'gzip round-trip through a LOCAL Data Compression variable');

    end;

    [Test]
    procedure T98_DataCompressionInstancesAreFreedAndSeparate()
    var
        Engine: Codeunit "ALI Engine";
    begin
        // 20 calls > the 16-slot bank: only passes if every local instance is freed on frame pop.
        Assert.AreEqual(20,
            RunInt('procedure P(): Integer var k: Integer; t: Integer; begin for k := 1 to 20 do t += Probe(); exit(t); end; ' +
                'procedure Probe(): Integer var dc: Codeunit "Data Compression"; begin dc.CreateZipArchive(); dc.CloseZipArchive(); exit(1); end;'),
            'a local Data Compression gets a fresh instance per call and gives it back');
        // Two variables, two archives — built interleaved, so a shared instance would mix them.
        Assert.AreEqual('1|2',
            RunText('var d1: Codeunit "Data Compression"; d2: Codeunit "Data Compression"; procedure P(): Text ' +
                'var o: OutStream; i: InStream; z1: OutStream; z2: OutStream; r1: InStream; r2: InStream; n1: List of [Text]; n2: List of [Text]; ' +
                'begin o.WriteText(''x''); ' +
                'i.Link(o); d1.CreateZipArchive(); d1.AddEntry(i, ''a.txt''); ' +
                'i.Link(o); d2.CreateZipArchive(); d2.AddEntry(i, ''b.txt''); ' +
                'i.Link(o); d2.AddEntry(i, ''c.txt''); ' +
                'd1.SaveZipArchive(z1); d2.SaveZipArchive(z2); r1.Link(z1); r2.Link(z2); ' +
                'd1.OpenZipArchive(r1, false); d2.OpenZipArchive(r2, false); d1.GetEntryList(n1); d2.GetEntryList(n2); ' +
                'exit(Format(n1.Count()) + ''|'' + Format(n2.Count())); end;'),
            'each Data Compression variable owns its own archive');

    end;

    [Test]
    procedure T99_NativeCodeunitShapeRulesAndStoredModule()
    var
        AssignDiags: Codeunit "ALI Diag Bag";
        CompileDiags: Codeunit "ALI Diag Bag";
        ParamDiags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Serialized: Text;
    begin
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P() var d1: Codeunit "Data Compression"; d2: Codeunit "Data Compression"; begin d1 := d2; end;', AssignDiags),
            'a Data Compression variable cannot be assigned');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('procedure P(d: Codeunit "Data Compression") begin end;', ParamDiags),
            'nor passed as a parameter');

        // CALL_BUILTIN_LIVE stores the raw BuiltinId: a module saved with native calls must load
        // and run — the catalogue rows are appended after every other row, so ids never move.
        Assert.IsTrue(Engine.Compile('trigger OnRun(): Text var b: Codeunit "Base64 Convert"; th: Codeunit "Type Helper"; s: Text; begin s := ''a b''; exit(b.ToBase64(th.UrlEncode(s))); end;', CompileDiags), CompileDiags.ToText());
        Serialized := Engine.SaveCompiled();
        Assert.IsTrue(Engine.LoadCompiled(Serialized), 'stored module with native calls loads');
        Engine.RunCompiled(Result);


        AssertDiag(AssignDiags, 'ALI927', 'cannot be assigned');
        AssertDiag(ParamDiags, 'ALI927', 'procedure parameter');
        Assert.IsTrue(Result.Succeeded(), Result.ErrorMessage());
        Assert.AreEqual(ExpectedB64OfUrlEncoded('a b'), Result.ResultText(), 'stored module runs the native calls');
    end;

    [Test]
    procedure T100_TempBlobNative()
    var
        Engine: Codeunit "ALI Engine";
    begin
        // Temp Blob runs natively (no harvest): each variable owns its blob, and every stream
        // created on one Temp Blob meets the same content.
        Assert.AreEqual('hello|hello|5|' + Format(true) + '|' + Format(false),
            RunText('procedure P(): Text var tb1: Codeunit "Temp Blob"; tb2: Codeunit "Temp Blob"; tb3: Codeunit "Temp Blob"; o1: OutStream; o2: OutStream; i1: InStream; i2: InStream; s1: Text; s2: Text; ' +
                'begin tb1.CreateOutStream(o1); o1.WriteText(''hello''); ' +
                'tb1.CreateInStream(i1); tb2.CreateOutStream(o2); CopyStream(o2, i1); ' +
                'tb1.CreateInStream(i1); i1.ReadText(s1); tb2.CreateInStream(i2); i2.ReadText(s2); ' +
                'exit(s1 + ''|'' + s2 + ''|'' + Format(tb2.Length()) + ''|'' + Format(tb2.HasValue()) + ''|'' + Format(tb3.HasValue())); end;'),
            'several Temp Blobs in one procedure, copied one into another through their streams');
        Assert.AreEqual('héllo-éà',
            RunText('procedure P(): Text var tb: Codeunit "Temp Blob"; o: OutStream; i: InStream; s: Text; ' +
                'begin tb.CreateOutStream(o, TextEncoding::UTF8); o.WriteText(''héllo-éà''); tb.CreateInStream(i, TextEncoding::UTF8); i.ReadText(s); exit(s); end;'),
            'CreateOutStream / CreateInStream TextEncoding overloads');
        // 20 iterations > the 16-slot instance and stream banks: passes only if the helper's locals
        // are given back on frame pop — and the helper takes the caller's Temp Blob by var.
        Assert.AreEqual('x20',
            RunText('procedure P(): Text var tb: Codeunit "Temp Blob"; k: Integer; i: InStream; s: Text; ' +
                'begin for k := 1 to 20 do begin Clear(tb); Fill(tb, ''x'' + Format(k)); tb.CreateInStream(i); i.ReadText(s); end; exit(s); end; ' +
                'procedure Fill(var b: Codeunit "Temp Blob"; v: Text) var scratch: Codeunit "Temp Blob"; o: OutStream; i: InStream; ' +
                'begin scratch.CreateOutStream(o); o.WriteText(v); scratch.CreateInStream(i); b.CreateOutStream(o); CopyStream(o, i); end;'),
            'var Temp Blob parameter; local Temp Blobs and streams freed per call');
        // Record bridges: into a record's blob field and back out through a second Temp Blob.
        Assert.AreEqual('rec-blob|rec-blob',
            RunText('var c: Record "ALI Test Customer" temporary; procedure P(): Text var tb: Codeunit "Temp Blob"; tb2: Codeunit "Temp Blob"; tb3: Codeunit "Temp Blob"; r: RecordRef; o: OutStream; i: InStream; s: Text; s2: Text; ' +
                'begin tb.CreateOutStream(o); o.WriteText(''rec-blob''); c.Init(); c."No." := ''C1''; r.GetTable(c); tb.ToRecordRef(r, 10); r.SetTable(c); ' +
                'tb2.FromRecord(c, 10); tb2.CreateInStream(i); i.ReadText(s); ' +
                'tb3.FromFieldRef(r.Field(10)); tb3.CreateInStream(i); i.ReadText(s2); exit(s + ''|'' + s2); end;'),
            'ToRecordRef / FromRecord / FromFieldRef');

    end;

    [Test]
    procedure T101_EnvironmentInformationAndLanguageNative()
    var
        EnvInfo: Codeunit "Environment Information";
        Engine: Codeunit "ALI Engine";
        LanguageCU: Codeunit Language;
        TempWinLanguage: Record "Windows Language" temporary;
    begin
        Assert.AreEqual(Format(EnvInfo.IsOnPrem()) + '|' + EnvInfo.GetEnvironmentName() + '|' + Format(EnvInfo.VersionInstalled('{00000000-0000-0000-0000-000000000000}')),
            RunText('var e: Codeunit "Environment Information"; procedure P(): Text var g: Guid; begin exit(Format(e.IsOnPrem()) + ''|'' + e.GetEnvironmentName() + ''|'' + Format(e.VersionInstalled(g))); end;'),
            'Environment Information: Boolean, Text and Guid-argument rows');
        LanguageCU.GetApplicationLanguages(TempWinLanguage);
        Assert.AreEqual(Format(LanguageCU.GetLanguageIdOrDefault('FRS')) + '|' + LanguageCU.GetWindowsLanguageName(1036) + '|' + LanguageCU.GetCultureName(1036) + '|' + Format(TempWinLanguage.Count()),
            RunText('var l: Codeunit Language; procedure P(): Text var w: Record "Windows Language" temporary; begin l.GetApplicationLanguages(w); ' +
                'exit(Format(l.GetLanguageIdOrDefault(''FRS'')) + ''|'' + l.GetWindowsLanguageName(1036) + ''|'' + l.GetCultureName(1036) + ''|'' + Format(w.Count())); end;'),
            'Language: Code/Int overloads and the temporary Windows Language buffer filled through the shared dataset');

    end;

    [Test]
    procedure T102_CryptographyManagementNative()
    var
        CryptoMgt: Codeunit "Cryptography Management";
        Engine: Codeunit "ALI Engine";
        HashAlgorithmType: Option MD5,SHA1,SHA256,SHA384,SHA512;
        KeyText: Text;
        SecKey: SecretText;
    begin
        KeyText := 'a2V5';
        SecKey := KeyText;
        Assert.AreEqual('BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD',
            RunText('var c: Codeunit "Cryptography Management"; procedure P(): Text begin exit(c.GenerateHash(''abc'', 2)); end;'),
            'GenerateHash(Text, SHA256) — known vector');
        Assert.AreEqual(CryptoMgt.GenerateBase64KeyedHashAsBase64String('abc', SecKey, HashAlgorithmType::SHA256) + '|' + CryptoMgt.GenerateHashAsBase64String('abc', HashAlgorithmType::MD5),
            RunText('var c: Codeunit "Cryptography Management"; procedure P(): Text var h: Option MD5,SHA1,SHA256,SHA384,SHA512; ' +
                'begin exit(c.GenerateBase64KeyedHashAsBase64String(''abc'', ''a2V5'', h::SHA256) + ''|'' + c.GenerateHashAsBase64String(''abc'', h::MD5)); end;'),
            'keyed (SecretText key from Text) and Base64 overloads, Option argument');
        Assert.AreEqual(CryptoMgt.GenerateHash('stream-data', HashAlgorithmType::SHA1),
            RunText('var c: Codeunit "Cryptography Management"; procedure P(): Text var tb: Codeunit "Temp Blob"; o: OutStream; i: InStream; ' +
                'begin tb.CreateOutStream(o); o.WriteText(''stream-data''); tb.CreateInStream(i); exit(c.GenerateHash(i, 1)); end;'),
            'GenerateHash(InStream, SHA1)');

    end;

    [Test]
    procedure T103_RegexNative()
    var
        Engine: Codeunit "ALI Engine";
    begin
        Assert.AreEqual(ExpectedRegexText(),
            RunText('procedure P(): Text var r: Codeunit Regex; r2: Codeunit Regex; m: Record Matches temporary; g: Record Groups temporary; o: Record "Regex Options" temporary; l: List of [Text]; s: Text; ' +
                'begin s := r.Replace(''a1b2'', ''\d'', ''#''); ' +
                'r.Match(''x12y345'', ''\d+'', m); m.FindFirst(); s += ''|'' + Format(m.Count()) + '','' + Format(m.Index) + '','' + Format(m.Length); ' +
                'l.Add(''old''); r.Split(''a,b;c'', ''[,;]'', l); s += ''|'' + Format(l.Count()) + '','' + l.Get(3); ' +
                'r2.Regex(''^\d+$''); s += ''|'' + Format(r2.IsMatch(''123'')) + '','' + Format(r2.IsMatch(''12a'')); ' +
                'o.IgnoreCase := true; s += ''|'' + Format(r.IsMatch(''ABC'', ''abc'', o)); ' +
                'r.Match(''k=v'', ''(?<key>\w)=(?<val>\w)'', m); m.FindFirst(); r.Groups(m, g); s += ''|'' + Format(g.Count()); ' +
                'exit(s); end;'),
            'Regex: static Replace, Match into shared Matches, Split into a pre-filled list, instance pattern, Regex Options, Groups');

    end;

    // ===== Static Page.Run / Report.Run / File dialogs (native catalogue, pseudo ids) =====
    //
    // The platform opens the page / runs the report, so what the script did is only visible
    // through a UI handler. The Page.Run handler reads the card's "No.": that is the check that
    // the record reached the page through the Variant bridge, as T85 does for Codeunit.Run.
    // File dialogs need a client, so they are compile-only here.

    [Test]
    [HandlerFunctions('CustomerCardHandler')]
    procedure T104_StaticPageRunIsNative()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        SeedCustomer(Cust, 'C-PGRUN1');
        HandlerHits := 0;
        HandledCustomerNo := '';

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun() var c: Record "ALI Test Customer"; ' +
                'begin Page.Run(Page::"ALI Test Customer Card"); ' +
                'c.Get(''C-PGRUN1''); Page.Run(Page::"ALI Test Customer Card", c); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, HandlerHits, 'both Page.Run shapes opened the page');
        Assert.AreEqual('C-PGRUN1', HandledCustomerNo, 'Page.Run(id, Rec) opened the page on the script''s record');
    end;

    [Test]
    [HandlerFunctions('CustomerReportHandler')]
    procedure T105_StaticReportRunIsNative()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        SeedCustomer(Cust, 'C-RPRUN1');
        HandlerHits := 0;

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun() var c: Record "ALI Test Customer"; ' +
                'begin Report.Run(Report::"ALI Test Customer Report", false); ' +
                'c.SetRange("No.", ''C-RPRUN1''); Report.Run(Report::"ALI Test Customer Report", false, false, c); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, HandlerHits, 'both Report.Run shapes ran the report');
    end;

    [Test]
    procedure T106_FileDialogsBindWithoutTheObjectGate()
    var
        Diags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin
        // File dialogs are not object calls: they compile with Allow Object Calls OFF. The bare
        // legacy names bind to the same rows as the `File.` forms.
        Assert.IsTrue(
            Engine.Compile(
                'trigger OnRun() var InS: InStream; f: Text; ok: Boolean; ' +
                'begin ok := File.DownloadFromStream(InS, '''', '''', '''', f); ' +
                'ok := File.UploadIntoStream(''*.*'', InS); ' +
                'ok := File.UploadIntoStream(''Pick'', '''', ''*.*'', f, InS); ' +
                'DownloadFromStream(InS, '''', '''', '''', f); ' +
                'ok := UploadIntoStream(''*.*'', InS); end;', Diags),
            Diags.ToText());

    end;

    [Test]
    procedure T107_StaticPageReportDiagnostics()
    var
        GateDiags: Codeunit "ALI Diag Bag";
        MemberDiags: Codeunit "ALI Diag Bag";
        OverloadDiags: Codeunit "ALI Diag Bag";
        VarDiags: Codeunit "ALI Diag Bag";
        Engine: Codeunit "ALI Engine";
    begin

        Assert.IsFalse(Pipeline.CompileExpectingErrors('trigger OnRun() begin Page.RunModal(Page::"ALI Test Customer Card"); end;', MemberDiags),
            'Page.RunModal is not catalogued');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('trigger OnRun() begin Report.Run(''nope''); end;', OverloadDiags),
            'a Text report id must not compile');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('trigger OnRun() var InS: InStream; begin File.DownloadFromStream(InS, '''', '''', '''', ''x.txt''); end;', VarDiags),
            'the file name of DownloadFromStream is passed by var');
        Assert.IsFalse(Pipeline.CompileExpectingErrors('trigger OnRun() begin Page.Run(Page::"ALI Test Customer Card"); end;', GateDiags),
            'Page.Run must be gated');


        AssertDiag(MemberDiags, 'ALI961', 'Page.RunModal');
        AssertDiag(OverloadDiags, 'ALI916', 'No overload');
        AssertDiag(VarDiags, 'ALI917', 'by var');
        AssertDiag(GateDiags, 'ALI961', 'Allow object procedure calls');
    end;

    // ===== Events raised from harvested code =====
    //
    // A publisher's empty body is replaced at extraction by calls to every active subscriber of
    // the event ("Event Subscription", record order), and subscribers are harvested as plain
    // procedures. Fixtures: "ALI Test Event Pub CU" / "ALI Test Event Sub CU" /
    // "ALI Test Event Manual Sub" / "ALI Test Customer Ext".

    [Test]
    procedure T108_EventWithoutSubscriberIsNoOp()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.Quiet(5)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(5, Interp.GetResultInt(), 'a procedure raising an event without subscribers compiles and runs');
    end;

    [Test]
    procedure T109_SubscriberVarParamReachesPublisherCaller()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // HandleBeforePost sets IsHandled for Amount >= 1000 -> Post exits with -Amount.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.Post(2000)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(-2000, Interp.GetResultDec(), 'IsHandled set by the subscriber is seen by the publisher''s caller');
    end;

    [Test]
    procedure T110_SubscriberParametersMatchedByName()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // Not handled (10 < 1000); ScaleAfterPost(Factor, var Amount) is declared in the opposite
        // order to OnAfterPost(var Amount, Factor): 10 * 3.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Decimal var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.Post(10)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(30, Interp.GetResultDec(), 'subscriber arguments are matched by name, not position');
    end;

    [Test]
    procedure T111_SubscribersRunInEventSubscriptionOrderManualSkipped()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
        Expected: Text;
    begin
        Expected := ExpectedTraceOrder();
        Assert.AreEqual(2, StrLen(Expected), 'fixture: TraceA and TraceB must both be active subscriptions');


        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Text var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.Trace()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(Expected, Interp.GetResultText(), 'both static subscribers run, in Event Subscription order, and the manual one does not');
    end;

    [Test]
    procedure T112_TableExtensionEventSenderIsRec()
    var
        Cust: Record "ALI Test Customer";
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        SeedCustomer(Cust, 'C-EVT1');

        // OnBumpExtScore (IncludeSender) is published by the tableextension; its subscriber takes
        // `var Sender` and bumps "Ext Score" on the caller's own record.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var c: Record "ALI Test Customer"; ' +
                'begin c.Get(''C-EVT1''); c."Ext Score" := 2; exit(c.BumpExtScoreViaEvent(5)); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(7, Interp.GetResultInt(), 'a table event''s sender is the publishing record');
    end;

    [Test]
    procedure T113_UncompilableSubscriberIsNotSilentlySkipped()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
    begin
        // HandleUnsupported declares a Notification. Skipping it would silently misexecute, so the
        // publisher is Blocked and reaching it fails, naming the event.

        Assert.IsFalse(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.RaiseUnsupported()); end;', Result),
            'raising an event whose subscriber cannot be compiled must fail');
        Assert.IsTrue(StrPos(Result.ErrorMessage(), 'OnUnsupported') > 0, StrSubstNo('the failure names the event: %1', Result.ErrorMessage()));
    end;

    [Test]
    procedure T114_SubscriberGetsFreshInstancePerRaise()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // CountRaise increments a global of "ALI Test Event Sub CU". The publisher body clears its
        // subscriber variable before each call, so the second raise starts from 0 again.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.CountTwice()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'a StaticAutomatic subscriber''s globals do not survive between raises');
    end;

    [Test]
    procedure T115_SingleInstanceSubscriberKeepsState()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Event Pub CU"; ' +
                'begin exit(cu.CountSingleTwice()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(2, Interp.GetResultInt(), 'a SingleInstance subscriber keeps its globals between raises');
    end;

    [Test]
    procedure T116_ClearCodeunitVariableResetsGlobals()
    var
        Engine: Codeunit "ALI Engine";
        Result: Codeunit "ALI Exec Result";
        Interp: Codeunit "ALI Interpreter";
    begin
        // Native Clear(MyCU) = a fresh instance. It used to lower to a silent no-op.

        Assert.IsTrue(
            Engine.CompileAndRun(
                'trigger OnRun(): Integer var cu: Codeunit "ALI Test Helper CU"; ' +
                'begin cu.Bump(); cu.Bump(); Clear(cu); exit(cu.Bump()); end;', Result),
            StrSubstNo('run failed: %1', Result.ErrorMessage()));
        Assert.AreEqual(1, Interp.GetResultInt(), 'Clear on a codeunit variable resets its globals');
    end;

    // Native reference for T111: the letters of the static OnTrace subscribers, in the order the
    // platform enumerates their Event Subscription rows.
    local procedure ExpectedTraceOrder() Expected: Text
    var
        EventSub: Record "Event Subscription";
    begin
        EventSub.SetRange("Publisher Object Type", EventSub."Publisher Object Type"::Codeunit);
        EventSub.SetRange("Publisher Object ID", Codeunit::"ALI Test Event Pub CU");
        EventSub.SetRange("Published Function", 'OnTrace');
        EventSub.SetRange(Active, true);
        if EventSub.FindSet() then
            repeat
                case EventSub."Subscriber Function" of
                    'TraceA':
                        Expected += 'A';
                    'TraceB':
                        Expected += 'B';
                end;
            until EventSub.Next() = 0;
    end;

    [PageHandler]
    procedure CustomerCardHandler(var CustomerCard: TestPage "ALI Test Customer Card")
    begin
        HandlerHits += 1;
        HandledCustomerNo := CustomerCard."No.".Value();
    end;

    [ReportHandler]
    procedure CustomerReportHandler(var CustomerReport: Report "ALI Test Customer Report")
    begin
        HandlerHits += 1;
    end;

    local procedure ExpectedRegexText(): Text
    var
        TempGroups: Record Groups;
        TempMatches: Record Matches;
        TempRegexOptions: Record "Regex Options";
        Rgx: Codeunit Regex;
        Rgx2: Codeunit Regex;
        Items: List of [Text];
        Result: Text;
    begin
        Result := Rgx.Replace('a1b2', '\d', '#');
        Rgx.Match('x12y345', '\d+', TempMatches);
        TempMatches.FindFirst();
        Result += '|' + Format(TempMatches.Count()) + ',' + Format(TempMatches.Index) + ',' + Format(TempMatches.Length);
        Items.Add('old');
        Rgx.Split('a,b;c', '[,;]', Items);
        Result += '|' + Format(Items.Count()) + ',' + Items.Get(3);
        Rgx2.Regex('^\d+$');
        Result += '|' + Format(Rgx2.IsMatch('123')) + ',' + Format(Rgx2.IsMatch('12a'));
        TempRegexOptions.IgnoreCase := true;
        Result += '|' + Format(Rgx.IsMatch('ABC', 'abc', TempRegexOptions));
        Rgx.Match('k=v', '(?<key>\w)=(?<val>\w)', TempMatches);
        TempMatches.FindFirst();
        Rgx.Groups(TempMatches, TempGroups);
        Result += '|' + Format(TempGroups.Count());
        exit(Result);
    end;

    local procedure ExpectedB64OfUrlEncoded(Value: Text): Text
    var
        Base64: Codeunit "Base64 Convert";
        TypeHelper: Codeunit "Type Helper";
    begin
        exit(Base64.ToBase64(TypeHelper.UrlEncode(Value)));
    end;

    local procedure SeedCustomer(var Cust: Record "ALI Test Customer"; No: Code[20])
    begin
        if Cust.Get(No) then
            Cust.Delete();
        Cust.Init();
        Cust."No." := No;
        Cust."Credit Limit" := 1000;
        Cust.Balance := 250;
        Cust."Post Count" := 7;
        Cust.Insert();
    end;
}
#endif
