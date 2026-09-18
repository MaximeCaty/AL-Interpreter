// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Event Pub CU — fixture for event publishers raised from harvested code.
//
// Kept in the MAIN app, like "ALI Test Helper CU", so its AL source is harvestable. Its
// subscribers live in "ALI Test Event Sub CU" (and a manual one in "ALI Test Event Manual Sub").
// Nothing raises these events natively: they only ever fire through the interpreter.
codeunit 51113 "ALI Test Event Pub CU"
{
    // IsHandled pattern: a subscriber may take over, visible here through the var parameter.
    // Otherwise OnAfterPost's subscriber rescales Amount (its parameters are declared in the
    // opposite order to the publisher's — matching is by name).
    procedure Post(Amount: Decimal): Decimal
    var
        IsHandled: Boolean;
    begin
        OnBeforePost(Amount, IsHandled);
        if IsHandled then
            exit(-Amount);
        OnAfterPost(Amount, 3);
        exit(Amount);
    end;

    // Two subscribers append to Log; the result shows which ran and in what order.
    procedure Trace(): Text
    var
        Log: Text;
    begin
        OnTrace(Log);
        exit(Log);
    end;

    // An event nobody subscribes to: the call must compile and do nothing.
    procedure Quiet(Value: Integer): Integer
    begin
        OnNoSubscriber(Value);
        exit(Value);
    end;

    // The only subscriber of this event cannot be compiled by the interpreter.
    procedure RaiseUnsupported(): Integer
    begin
        OnUnsupported();
        exit(1);
    end;

    // Raised twice: a StaticAutomatic subscriber counts 1 (fresh instance per raise), the
    // SingleInstance one counts 2.
    procedure CountTwice(): Integer
    var
        Seen: Integer;
    begin
        OnCount(Seen);
        OnCount(Seen);
        exit(Seen);
    end;

    procedure CountSingleTwice(): Integer
    var
        Seen: Integer;
    begin
        OnCountSingle(Seen);
        OnCountSingle(Seen);
        exit(Seen);
    end;

    [IntegrationEvent(false, false)]
    local procedure OnCount(var Seen: Integer)
    begin
    end;

    [IntegrationEvent(false, false)]
    local procedure OnCountSingle(var Seen: Integer)
    begin
    end;

    [IntegrationEvent(false, false)]
    local procedure OnBeforePost(var Amount: Decimal; var IsHandled: Boolean)
    begin
    end;

    [IntegrationEvent(false, false)]
    local procedure OnAfterPost(var Amount: Decimal;
        Factor: Integer)
    begin
    end;

    [BusinessEvent(false)]
    local procedure OnTrace(var Log: Text)
    begin
    end;

    [IntegrationEvent(false, false)]
    local procedure OnNoSubscriber(var Value: Integer)
    begin
    end;

    [IntegrationEvent(false, false)]
    local procedure OnUnsupported()
    begin
    end;
}
#endif
