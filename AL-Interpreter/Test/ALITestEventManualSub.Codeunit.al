// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Event Manual Sub — a MANUAL subscriber to OnTrace. It only runs once bound with
// BindSubscription, which the interpreter does not model, so it must never run there.
codeunit 51158 "ALI Test Event Manual Sub"
{
    EventSubscriberInstance = Manual;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnTrace', '', false, false)]
    local procedure TraceManual(var Log: Text)
    begin
        Log += 'M';
    end;
}
#endif
