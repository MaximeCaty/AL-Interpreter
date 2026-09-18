// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Run CU — fixture for M11 phase C3 (`Codeunit.Run`).
//
// Unlike "ALI Test Helper CU" this one is meant to be EXECUTED, not harvested: Codeunit.Run
// hands the object to the platform, so its OnRun is real AL running natively and nothing here
// has to stay inside the interpreter's supported surface.
//
// SingleInstance is what makes the run observable from the test: the platform gives every
// `Codeunit.Run` a fresh instance, but a single-instance codeunit's state is the session's, so
// the counter survives for the assertion. It also survives a FAILED run — a rolled-back
// Codeunit.Run undoes database writes, never variables.
codeunit 51108 "ALI Test Run CU"
{
    SingleInstance = true;

    var
        FailOnRun: Boolean;
        Runs: Integer;

    trigger OnRun()
    begin
        Runs += 1;
        if FailOnRun then
            Error('ALI test: OnRun failed on purpose');
    end;

    procedure ResetCounters()
    begin
        Runs := 0;
        FailOnRun := false;
    end;

    procedure RunCount(): Integer
    begin
        exit(Runs);
    end;

    procedure SetFailOnRun(Value: Boolean)
    begin
        FailOnRun := Value;
    end;
}
#endif
