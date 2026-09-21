// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Sec Filter Sub — a MANUAL subscriber to "TOO Record Security Filters" that restricts
// "ALI Test Customer" to "No." = 'S1'. Bound only by the record-security test in "ALI Record Tests".
codeunit 51160 "ALI Test Sec Filter Sub"
{
    EventSubscriberInstance = Manual;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Record Security Filters", OnApplyRecordSecurityFilters, '', false, false)]
    local procedure RestrictTestCustomer(var RecordReference: RecordRef; var Reason: Text)
    var
        TestCust: Record "ALI Test Customer";
    begin
        if RecordReference.Number() <> Database::"ALI Test Customer" then
            exit;
        RecordReference.Field(TestCust.FieldNo("No.")).SetRange('S1');
        if Reason <> '' then
            Reason += ' ';
        Reason += 'Restricted by ALI test subscriber.';
    end;
}
#endif
