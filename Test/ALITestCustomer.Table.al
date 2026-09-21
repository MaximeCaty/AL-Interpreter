// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Customer — dedicated test table for the M6 record runtime (§14 item 7).
//
// Kept in the MAIN app (not the test app) so "ALI Rec Meta" can resolve its metadata via
// the virtual Field table at bind time and the interpreter can Open a RecordRef on it. The
// tests exercise CRUD, filters, FindSet/Next iteration and typed field access against this
// table using the native-comparison trick (run the same logic through a native Record and
// compare). Fields span the primitive register classes the field opcodes cover.
table 51102 "ALI Test Customer"
{
    Caption = 'ALI Test Customer';
    DataClassification = CustomerContent;

    fields
    {
        field(1; "No."; Code[20]) { Caption = 'No.'; }
        field(2; Name; Text[100]) { Caption = 'Name'; }
        field(3; Balance; Decimal) { Caption = 'Balance'; }
        field(4; "Credit Limit"; Decimal) { Caption = 'Credit Limit'; }
        field(5; Blocked; Boolean) { Caption = 'Blocked'; }
        field(6; "Post Count"; Integer) { Caption = 'Post Count'; }
        field(7; "Registration Date"; Date)
        {
            Caption = 'Registration Date';

        }
        field(8; Status; Option)
        {
            Caption = 'Status';
            OptionCaption = 'Open,Pending,Closed Out';
            OptionMembers = Open,Pending,"Closed Out";

        }
        field(9; Category; Enum "ALI Test Enum") { Caption = 'Category'; }
        field(10; Notes; Blob) { Caption = 'Notes'; }
    }

    keys
    {
        key(PK; "No.") { Clustered = true; }
        key(Name; Name) { }
    }

    var
        // M11 phase B fixture: object globals. This is the FIRST of two var sections — the second
        // sits further down, between procedures, because AL allows that and the harvester has to
        // hoist both into one block.
        HarvestCounter: Integer;
        LastLabel: Text[50];

    // M11 cross-object execution: procedures declared HERE are harvested from this table's
    // stored AL source at runtime and compiled into the caller's module, so `Cust.HeadRoom()`
    // in an interpreted script executes this body. Deliberately written the way real table code
    // is — unqualified field names, no `Rec.` prefix, sibling calls without a receiver — because
    // that is the shape the binder's implicit-receiver rewrite has to cope with.
    procedure HeadRoom(): Decimal
    begin
        exit("Credit Limit" - Balance);
    end;

    procedure BumpPostCount(By: Integer): Integer
    begin
        "Post Count" := "Post Count" + By;
        exit("Post Count");
    end;

    // Phase A: a sibling call (HeadRoom) and a LOCAL helper call (Fee) from one procedure.
    procedure HeadRoomAfterFee(): Decimal
    begin
        exit(HeadRoom() - Fee());
    end;

    local procedure Fee(): Decimal
    begin
        exit(50);
    end;

    // Phase A: paren-less sibling call — AL lets a no-arg call drop its `()`.
    procedure HeadRoomParenless(): Decimal
    begin
        exit(HeadRoom());
    end;

    // Phase A: the implicit receiver must be threaded THROUGH a sibling call, in statement form
    // and in expression form, so both bumps land on the caller's own record.
    procedure BumpTwice(By: Integer): Integer
    begin
        BumpPostCount(By);
        exit(BumpPostCount(By));
    end;

    // Phase A: mutual recursion between two procedures of the same object — resolvable only
    // because pass 1 declares every signature of the unit before any body is bound.
    procedure StepsDown(n: Integer): Integer
    begin
        if n <= 0 then
            exit(0);
        exit(1 + StepsUp(n - 1));
    end;

    local procedure StepsUp(n: Integer): Integer
    begin
        if n <= 0 then
            exit(0);
        exit(1 + StepsDown(n - 1));
    end;

    // Phase B: a SECOND object-level var section, declared after procedures — legal AL, and the
    // shape the harvester must hoist. `Names` is a handle-kind global: it is opened once, by the
    // script's entry proc, through the same EmitNewCollectionsGlobal pass as a script's own List.
    var
        // A global whose type the interpreter cannot represent (Notification is a declared gap,
        // see SUPPORTED_FEATURES.md). It must be DROPPED from the harvested unit rather than fail
        // the object — only UsesUnsupportedGlobal blocks. Weightless natively, so the fixture
        // costs the real table nothing. This slot keeps sliding DOWN the support ladder as ALI
        // grows: RecordRef until P0/P1 made it representable, then FieldRef until P2/P3 did the
        // same. Notification is the next rung — no UI object model, no plan to add one.
        Helper: Notification;
        Names: List of [Text];

    // Phase B: global state survives across calls on the same record variable.
    procedure BumpHarvestCounter(): Integer
    begin
        HarvestCounter := HarvestCounter + 1;
        exit(HarvestCounter);
    end;

    // Phase B2: one bump here, one through a SIBLING call. The sibling has no receiver variable
    // of its own, so it must inherit the instance its caller is running on — both bumps land on
    // the same block of globals.
    procedure BumpHarvestCounterTwice(): Integer
    begin
        BumpHarvestCounter();
        exit(BumpHarvestCounter());
    end;

    // Phase B: writes one global from the FIRST var section and one from the SECOND, proving
    // both were hoisted into the same unit.
    procedure RememberName(NewName: Text): Integer
    begin
        LastLabel := NewName;
        Names.Add(NewName);
        exit(Names.Count());
    end;

    procedure LastRememberedName(): Text
    begin
        exit(LastLabel);
    end;

    // RECORD ARGUMENTS on a TABLE procedure, passed on to a LOCAL helper — the same combination
    // the codeunit fixture pins. The implicit `Rec` receiver and an explicit record parameter
    // must coexist: descriptor row 1 is the receiver, row 2 is Other.
    procedure HeadRoomDiff(var Other: Record "ALI Test Customer"): Decimal
    begin
        exit(HeadRoom() - OtherHeadRoom(Other));
    end;

    local procedure OtherHeadRoom(var Other: Record "ALI Test Customer"): Decimal
    begin
        exit(Other."Credit Limit" - Other.Balance);
    end;

    // Byval record parameter: the callee copies, so this write must not reach the caller's record.
    procedure BumpCopy(Other: Record "ALI Test Customer"): Integer
    begin
        Other."Post Count" := Other."Post Count" + 1;
        exit(Other."Post Count");
    end;

    // Phase A/B: the procedure that cannot compile — it names the dropped global. Calling it must
    // fail with ALI963 naming the reason; every other procedure of this table stays callable.
    procedure UsesUnsupportedGlobal(): Integer
    begin
        exit(StrLen(Helper.Message()));
    end;
}
#endif
