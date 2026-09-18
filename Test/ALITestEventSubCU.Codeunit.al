// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Event Sub CU — subscribers to "ALI Test Event Pub CU" and "ALI Test Customer Ext".
//
// Main app, so the interpreter can read their source. They never run natively: the events they
// subscribe to are only raised through the interpreter.
codeunit 51114 "ALI Test Event Sub CU"
{
    var
        RaiseCount: Integer;

    // A global of a StaticAutomatic subscriber: every raise sees a fresh instance, so it is 1.
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnCount', '', false, false)]
    local procedure CountRaise(var Seen: Integer)
    begin
        RaiseCount += 1;
        Seen := RaiseCount;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnBeforePost', '', false, false)]
    local procedure HandleBeforePost(var Amount: Decimal; var IsHandled: Boolean)
    begin
        IsHandled := Amount >= 1000;
    end;

    // Subset of the publisher's parameters, in the opposite order.
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnAfterPost', '', false, false)]
    local procedure ScaleAfterPost(Factor: Integer; var Amount: Decimal)
    begin
        Amount := Amount * Factor;
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnTrace', '', false, false)]
    local procedure TraceA(var Log: Text)
    begin
        Log += 'A';
    end;

    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnTrace', '', false, false)]
    local procedure TraceB(var Log: Text)
    begin
        Log += 'B';
    end;

    // Notification is not a type the interpreter supports, so this subscriber is Blocked.
    [EventSubscriber(ObjectType::Codeunit, Codeunit::"ALI Test Event Pub CU", 'OnUnsupported', '', false, false)]
    local procedure HandleUnsupported()
    var
        Notif: Notification;
    begin
        Notif.Message('unsupported');
    end;

    // Table event with IncludeSender: `sender` is the publishing record.
    [EventSubscriber(ObjectType::Table, Database::"ALI Test Customer", 'OnBumpExtScore', '', false, false)]
    local procedure HandleBumpExtScore(var Sender: Record "ALI Test Customer"; By: Integer)
    begin
        Sender."Ext Score" := Sender."Ext Score" + By;
    end;
}
#endif
