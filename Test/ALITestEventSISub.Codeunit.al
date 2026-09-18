// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Event SI Sub — a SingleInstance subscriber: its globals must survive between raises.
codeunit 51116 "ALI Test Event SI Sub"
{
    SingleInstance = true;

    var
        RaiseCount: Integer;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnCountSingle', '', false, false)]
    local procedure CountRaise(var Seen: Integer)
    begin
        RaiseCount += 1;
        Seen := RaiseCount;
    end;
}
#endif
