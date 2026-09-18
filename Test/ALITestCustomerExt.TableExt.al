// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Customer Ext — M11 tableextension fixture.
//
// Kept in the MAIN app for the same reason as "ALI Test Customer": the registry harvests this
// object's AL source from "Application Object Metadata" at run time, so it has to be a published
// object of the app under test, not a test-app one.
//
// What it pins: a procedure declared HERE is reachable as `Cust.Proc()` even though the BASE
// table does not declare it. The extension is compiled as a unit of its own but bound with the
// base table's object context, so everything a table procedure may do must work unchanged —
// unqualified base-table fields, a field this very extension adds, object globals, sibling calls,
// and a call back into a base-table procedure through `Rec`.
tableextension 51112 "ALI Test Customer Ext" extends "ALI Test Customer"
{
    fields
    {
        field(51112; "Ext Score"; Integer) { Caption = 'Ext Score'; }
    }

    var
        // Object globals of the EXTENSION. They share the base table's per-instance block (that is
        // the only block a `Record "ALI Test Customer"` variable allocates), so two record
        // variables must still keep separate copies — same contract as the base table's own.
        ExtCounter: Integer;
        ExtLabel: Text[50];

    // Unqualified BASE-table fields, no `Rec.` prefix — the implicit receiver rewrite has to work
    // against the extended table, not against the extension.
    procedure ExtHeadRoomBonus(): Decimal
    begin
        exit("Credit Limit" - Balance + 100);
    end;

    // A field the EXTENSION adds, read and written unqualified.
    procedure BumpExtScore(By: Integer): Integer
    begin
        "Ext Score" := "Ext Score" + By;
        exit("Ext Score");
    end;

    // A call back into a BASE-table procedure. Written `Rec.HeadRoom()` because that is what
    // native AL requires here: the base table is a different object, and a bare `HeadRoom()` is
    // not in this unit's scope. Resolving it harvests the base table from inside the extension's
    // own bind — a nested harvest.
    procedure ExtHeadRoomViaBase(): Decimal
    begin
        exit(Rec.HeadRoom() + 1);
    end;

    // Sibling call INSIDE the extension: no receiver, exactly as in a table.
    procedure ExtHeadRoomTwice(): Decimal
    begin
        exit(ExtHeadRoomBonus() + ExtHeadRoomBonus());
    end;

    // Extension object globals survive across calls on the same record variable.
    procedure BumpExtCounter(): Integer
    begin
        ExtCounter := ExtCounter + 1;
        exit(ExtCounter);
    end;

    procedure RememberExtLabel(NewLabel: Text): Text
    begin
        ExtLabel := CopyStr(NewLabel, 1, MaxStrLen(ExtLabel));
        exit(ExtLabel);
    end;

    // Overloads inside an extension resolve by arity, same as anywhere else.
    procedure ExtScaled(): Decimal
    begin
        exit(ExtScaled(2));
    end;

    procedure ExtScaled(Factor: Decimal): Decimal
    begin
        exit(Balance * Factor);
    end;

    // A `local` procedure of the extension, called only by its siblings.
    procedure ExtHeadRoomAfterExtFee(): Decimal
    begin
        exit(ExtHeadRoomBonus() - ExtFee());
    end;

    local procedure ExtFee(): Decimal
    begin
        exit(25);
    end;

    // An event published by the EXTENSION, with IncludeSender: its subscriber receives the
    // record as `sender`, i.e. this unit's implicit `Rec`.
    procedure BumpExtScoreViaEvent(By: Integer): Integer
    begin
        OnBumpExtScore(By);
        exit("Ext Score");
    end;

    [IntegrationEvent(true, false)]
    local procedure OnBumpExtScore(By: Integer)
    begin
    end;
}
#endif
