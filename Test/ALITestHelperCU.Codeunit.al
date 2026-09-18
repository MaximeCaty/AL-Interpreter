// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Helper CU — fixture for M11 phase C (codeunit variables + codeunit procedure calls).
//
// Kept in the MAIN app, like "ALI Test Customer", so its AL source is reachable through
// Application Object Metadata at bind time and "ALI Object Registry" can harvest it.
//
// Written the way a real helper codeunit is: public entry points, a local helper, object state in
// a var block, and two var sections to exercise the phase-B hoist on a codeunit as well as a
// table. The OnRun trigger is deliberately present — the harvester must skip it (T67). Phase C3's
// `Codeunit.Run` reaches OnRun anyway, natively; its own fixtures are "ALI Test Run CU" /
// "ALI Test Run Rec CU", which exist to be EXECUTED rather than harvested.
codeunit 51016 "ALI Test Helper CU"
{
    var
        CallCount: Integer;

    trigger OnRun()
    begin
        CallCount := -1;    // must never run: triggers are not harvested
    end;

    procedure Add(a: Integer; b: Integer): Integer
    begin
        exit(a + b);
    end;

    // Sibling + local-helper calls inside a codeunit unit. Unlike a table's, these take no
    // receiver at all, so they are plain interpreted calls.
    procedure AddWithBonus(a: Integer; b: Integer): Integer
    begin
        exit(Add(a, b) + Bonus());
    end;

    local procedure Bonus(): Integer
    begin
        exit(100);
    end;

    // Object state: one copy per declared codeunit VARIABLE (phase B2), so this counts the calls
    // made through one variable and two variables never see each other's writes.
    procedure Bump(): Integer
    begin
        CallCount := CallCount + 1;
        exit(CallCount);
    end;

    procedure Tag(): Text
    begin
        exit(Prefix + '-cu');
    end;

    // A SECOND var section, after procedures — same hoist the table fixture pins.
    var
        Prefix: Text[20];

    procedure SetPrefix(NewPrefix: Text)
    begin
        Prefix := NewPrefix;
    end;

    // Cross-object: a codeunit procedure calling a TABLE procedure through a local record
    // variable. Harvesting is recursive, so binding this pulls in "ALI Test Customer" too.
    procedure HeadRoomOf(No: Code[20]): Decimal
    var
        Cust: Record "ALI Test Customer";
    begin
        if not Cust.Get(No) then
            exit(0);
        exit(Cust.HeadRoom());
    end;

    // RECORD ARGUMENTS, the shape real helper codeunits are written in.
    //
    // Byval: the callee gets its own handle with the caller's field values copied in, so writing
    // a field here must NOT reach the caller's record.
    procedure DescribeByVal(Cust: Record "ALI Test Customer"): Text
    begin
        Cust."Post Count" := 999;               // local to this copy
        exit(Cust."No." + '/' + Format(Cust."Credit Limit"));
    end;

    // Var: an alias, so the write DOES reach the caller — and the record is handed on to a LOCAL
    // helper by var as well, which is the combination reported as broken.
    procedure BumpVia(var Cust: Record "ALI Test Customer"; By: Integer): Integer
    begin
        exit(ApplyBump(Cust, By));
    end;

    local procedure ApplyBump(var Cust: Record "ALI Test Customer"; By: Integer): Integer
    begin
        Cust."Post Count" := Cust."Post Count" + By;
        exit(Cust."Post Count");
    end;

    // A local helper taking a record BYVAL, called from a public procedure that holds it by var:
    // the callee prologue must open a fresh handle and copy, not alias.
    procedure HeadRoomVia(var Cust: Record "ALI Test Customer"): Decimal
    begin
        exit(ComputeHeadRoom(Cust));
    end;

    local procedure ComputeHeadRoom(Cust: Record "ALI Test Customer"): Decimal
    begin
        exit(Cust."Credit Limit" - Cust.Balance);
    end;
}
#endif
