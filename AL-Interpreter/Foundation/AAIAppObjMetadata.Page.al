// ON PREMISE ONLY. "Application Object Metadata" has scope OnPrem, so neither this page nor the
// table behind it exists in a Cloud (SaaS) build — see "ALI Object Registry".TryGetObjectSource
// for what the interpreter does instead when no stored AL source can be read.
#if not CLOUD

page 51102 "ALI App. Obj. Metadata"
{
    ApplicationArea = All;
    Caption = 'Application Object Metadata';
    Editable = false;
    PageType = List;
    Permissions = tabledata "Application Object Metadata" = r;
    SourceTable = "Application Object Metadata";

    layout
    {
        area(Content)
        {
            repeater(Group)
            {
                field("Object ID"; Rec."Object ID") { }
                field("Object Type"; Rec."Object Type") { }
                field("Object Subtype"; Rec."Object Subtype") { }
                field("Metadata Version"; Rec."Metadata Version") { }
                field("Metadata Format"; Rec."Metadata Format") { }
                field(Metadata; Rec.Metadata)
                {
                    trigger OnDrillDown()
                    var
                        InStr: InStream;
                        Txt: Text;
                    begin
                        Rec.Metadata.CreateInStream(InStr);
                        InStr.Read(Txt);
                        Message(Txt);
                    end;
                }
                field("User Code"; Rec."User Code")
                {
                    trigger OnDrillDown()
                    var
                        InStr: InStream;
                        Txt: Text;
                    begin
                        Rec."User Code".CreateInStream(InStr);
                        InStr.Read(Txt);
                        Message(Txt);
                    end;
                }
                field("User AL Code"; Rec."User AL Code")
                {
                    trigger OnDrillDown()
                    var
                        InStr: InStream;
                        Txt: Text;
                    begin
                        Rec."User AL Code".CreateInStream(InStr);
                        InStr.Read(Txt);
                        Message(Txt);
                    end;
                }
                field("Schema Hash"; Rec."Schema Hash") { }
                field("Emit Version"; Rec."Emit Version") { }

            }
        }
    }

    procedure GetUserALCodeInStream(var AppObj: Record "Application Object Metadata") Result: Text
    var
        InStr: InStream;
    begin
        // only way to get AL source at runtime is to expose this on the page, return empty stream from record itself
        Rec.Get(AppObj.RecordId);
        Rec."User AL Code".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(Result);
    end;

    /// <summary>
    /// Source of the FIRST record matching AppObj's FILTERS — AppObj is never read from the
    /// database, only its filters are taken. Empty text when nothing matches.
    /// </summary>
    /// <remarks>
    /// Same blob-through-the-page trick as GetUserALCodeInStream, one server round trip instead
    /// of two: a caller that seeks the row itself and then hands it over pays for the seek twice,
    /// because the blob only materializes on THIS page's own Rec. The record's primary key is
    /// ("Runtime Package ID","Object Type","Object ID","Emit Version"), so a caller who knows the
    /// package, type and id still cannot Get() it — it does not know the emit version. Filtering
    /// on those first three is an index seek on the clustered key, which is what this takes.
    /// </remarks>
    procedure GetUserALCodeFromFilters(var AppObj: Record "Application Object Metadata") Result: Text
    var
        InStr: InStream;
    begin
        Rec.Reset();
        Rec.CopyFilters(AppObj);
        if not Rec.FindFirst() then
            exit('');
        Rec."User AL Code".CreateInStream(InStr, TextEncoding::UTF8);
        InStr.Read(Result);
        // A find does not always materialize a BLOB the way Get() does; only pay for the extra
        // read when the stream really did come back empty.
        if Result = '' then begin
            Rec.CalcFields("User AL Code");
            Rec."User AL Code".CreateInStream(InStr, TextEncoding::UTF8);
            InStr.Read(Result);
        end;
    end;

    /// <summary>
    /// Signature of every procedure/trigger of the object: name, parameter types (in declaration
    /// order) and return type. The three lists are parallel — entry N of each describes the same
    /// procedure. Overloads appear as separate entries sharing a name.
    /// </summary>
    /// <remarks>
    /// Types are reported as "TOO Fields Types", i.e. the BC FIELD type set: anything that is not
    /// a field type (Record, Codeunit, Page, List, Dictionary, Variant, Json*, streams, arrays…)
    /// comes back as " " (0), and an Enum parameter is reported as Option — exactly how BC types
    /// an enum FIELD. A caller needing the exact declared type (a Record's table, an enum's id)
    /// must read the declaration text via GetALProcedureCode.
    /// </remarks>
    procedure GetALProcedureDefinition(var AppObj: Record "Application Object Metadata"; var ProcedureNames: List of [Text]; var ProcedureArguments: List of [List of [Enum "ALI Fields Types"]]; var ProcedureReturnType: List of [Enum "ALI Fields Types"])
    var
        ALLineInGlobalVar: array[25000] of Boolean;
        ALLineInProcedure: array[25000] of Boolean;
        ALLineInProcedureBody: array[50000] of Boolean;
        ALLineInVar: array[25000] of Boolean;
        LF: Char;
        I: Integer;
        Lines: List of [Text];
        ALcode: Text;
        ALLineInProcedureName: array[25000] of Text;
        Declaration: Text;
        PrevProcName: Text;
    begin
        Clear(ProcedureNames);
        Clear(ProcedureArguments);
        Clear(ProcedureReturnType);
        ALcode := GetUserALCodeInStream(AppObj);
        if ALcode = '' then
            exit;

        LF := 10;
        Lines := ALcode.Split(LF);
        CacheALLinesState(Lines, ALLineInProcedure, ALLineInProcedureName, ALLineInProcedureBody, ALLineInGlobalVar, ALLineInVar);

        // PrevProcName tracks EVERY transition, empty ones included: a procedure's closing `end;`
        // resets the name to '', which is what separates two same-named overloads.
        for I := 2 to (Lines.Count() - 1) do
            if ALLineInProcedureName[I] <> PrevProcName then begin
                PrevProcName := ALLineInProcedureName[I];
                if PrevProcName <> '' then
                    // Ignore local and internal procedure
                    if not (Lines.Get(I).ToLower().Trim().Substring(1, 6) = 'local ') then begin
                        Declaration := JoinDeclarationLines(Lines, I);
                        ProcedureNames.Add(PrevProcName);
                        ProcedureArguments.Add(ParameterTypesOf(Declaration));
                        ProcedureReturnType.Add(ReturnTypeOf(Declaration));
                    end;
            end;
    end;

#region Signature parsing

    // The declaration as ONE line: a signature may wrap over several source lines, so keep
    // appending until the parameter parentheses balance. Quotes are honoured ("(" inside a
    // quoted identifier is not a parenthesis). Bounded to 20 lines so a malformed declaration
    // cannot swallow the rest of the object.
    local procedure JoinDeclarationLines(Lines: List of [Text]; StartIdx: Integer): Text
    var
        InQuote: Boolean;
        SawOpen: Boolean;
        Chr: Char;
        Depth: Integer;
        J: Integer;
        K: Integer;
        Joined: Text;
        Line: Text;
    begin
        for J := StartIdx to Lines.Count() do begin
            Line := Lines.Get(J).Trim();
            if Joined = '' then
                Joined := Line
            else
                Joined += ' ' + Line;

            for K := 1 to StrLen(Line) do begin
                Chr := Line[K];
                if Chr = '"' then
                    InQuote := not InQuote
                else
                    if not InQuote then
                        if Chr = '(' then begin
                            Depth += 1;
                            SawOpen := true;
                        end else
                            if Chr = ')' then
                                Depth -= 1;
            end;

            if SawOpen and (Depth <= 0) then
                exit(Joined);
            if J - StartIdx >= 20 then
                exit(Joined);
        end;
        exit(Joined);
    end;

    // Parameter types in declaration order. Parameters are separated by ';' — no AL type spells
    // one, so a plain split is safe (a ',' is not: `Dictionary of [Text, Integer]` contains one).
    local procedure ParameterTypesOf(Declaration: Text) Types: List of [Enum "ALI Fields Types"]
    var
        ClosePos: Integer;
        ColonPos: Integer;
        OpenPos: Integer;
        Params: List of [Text];
        Inner: Text;
        Param: Text;
    begin
        OpenPos := UnquotedPos(Declaration, '(');
        if OpenPos = 0 then
            exit;
        ClosePos := MatchingParen(Declaration, OpenPos);
        if ClosePos <= OpenPos + 1 then
            exit;                                   // `()` — no parameters

        Inner := CopyStr(Declaration, OpenPos + 1, ClosePos - OpenPos - 1);
        Params := Inner.Split(';');
        foreach Param in Params do begin
            Param := Param.Trim();
            if Param <> '' then begin
                // `[var ]Name: Type` — the first ':' separates name from type. A quoted parameter
                // name containing ':' would fool this; AL allows it, nobody writes it.
                ColonPos := Param.IndexOf(':');
                if ColonPos > 0 then
                    Types.Add(ALTypeToFieldType(CopyStr(Param, ColonPos + 1)))
                else
                    Types.Add("ALI Fields Types"::" ");
            end;
        end;
    end;

    // Return type of a declaration: whatever follows the parameter list, in either AL spelling —
    // `): Text` or the named form `) Result: Text`. " " when the procedure returns nothing.
    local procedure ReturnTypeOf(Declaration: Text): Enum "ALI Fields Types"
    var
        ClosePos: Integer;
        ColonPos: Integer;
        OpenPos: Integer;
        Tail: Text;
    begin
        OpenPos := UnquotedPos(Declaration, '(');
        if OpenPos = 0 then
            exit("ALI Fields Types"::" ");
        ClosePos := MatchingParen(Declaration, OpenPos);
        if ClosePos = 0 then
            exit("ALI Fields Types"::" ");

        Tail := CopyStr(Declaration, ClosePos + 1).Trim().TrimEnd(';');
        if Tail = '' then
            exit("ALI Fields Types"::" ");
        ColonPos := Tail.IndexOf(':');
        if ColonPos = 0 then
            exit("ALI Fields Types"::" ");
        exit(ALTypeToFieldType(CopyStr(Tail, ColonPos + 1)));
    end;

    // Declared AL type -> BC field type. Only the leading type WORD matters: `Text[100]` is Text,
    // `Code[20]` is Code, `Record "Customer" temporary` is a Record. Everything with no field-type
    // equivalent returns " " (see the GetALProcedureDefinition remarks).
    local procedure ALTypeToFieldType(TypeText: Text): Enum "ALI Fields Types"
    var
        Chr: Char;
        Cut: Integer;
        i: Integer;
        Word: Text;
    begin
        TypeText := TypeText.Trim();
        Cut := 0;
        for i := 1 to StrLen(TypeText) do
            if Cut = 0 then begin
                Chr := TypeText[i];
                if (Chr = ' ') or (Chr = '[') or (Chr = '"') then
                    Cut := i;
            end;
        if Cut > 0 then
            Word := CopyStr(TypeText, 1, Cut - 1)
        else
            Word := TypeText;

        case Word.ToLower() of
            'integer':
                exit("ALI Fields Types"::Integer);
            'biginteger':
                exit("ALI Fields Types"::BigInteger);
            'decimal':
                exit("ALI Fields Types"::Decimal);
            'boolean':
                exit("ALI Fields Types"::Boolean);
            'text':
                exit("ALI Fields Types"::Text);
            'code':
                exit("ALI Fields Types"::Code);
            'date':
                exit("ALI Fields Types"::Date);
            'time':
                exit("ALI Fields Types"::Time);
            'datetime':
                exit("ALI Fields Types"::DateTime);
            'dateformula':
                exit("ALI Fields Types"::DateFormula);
            'duration':
                exit("ALI Fields Types"::Duration);
            'guid':
                exit("ALI Fields Types"::GUID);
            'option', 'enum':                       // an enum FIELD is typed Option by BC
                exit("ALI Fields Types"::Option);
            'recordid':
                exit("ALI Fields Types"::RecordID);
            'blob':
                exit("ALI Fields Types"::BLOB);
            'media':
                exit("ALI Fields Types"::Media);
            'mediaset':
                exit("ALI Fields Types"::MediaSet);
            'tablefilter':
                exit("ALI Fields Types"::TableFilter);
            else
                exit("ALI Fields Types"::" ");      // Record, Codeunit, List, Variant, Json*, …
        end;
    end;

    // 1-based position of Chr outside double quotes, 0 when absent.
    local procedure UnquotedPos(Txt: Text; Wanted: Char): Integer
    var
        InQuote: Boolean;
        Chr: Char;
        i: Integer;
    begin
        for i := 1 to StrLen(Txt) do begin
            Chr := Txt[i];
            if Chr = '"' then
                InQuote := not InQuote
            else
                if not InQuote then
                    if Chr = Wanted then
                        exit(i);
        end;
        exit(0);
    end;

    // Position of the ')' closing the '(' at OpenPos (nesting- and quote-aware), 0 when unclosed.
    local procedure MatchingParen(Txt: Text; OpenPos: Integer): Integer
    var
        InQuote: Boolean;
        Chr: Char;
        Depth: Integer;
        i: Integer;
    begin
        for i := OpenPos to StrLen(Txt) do begin
            Chr := Txt[i];
            if Chr = '"' then
                InQuote := not InQuote
            else
                if not InQuote then
                    if Chr = '(' then
                        Depth += 1
                    else
                        if Chr = ')' then begin
                            Depth -= 1;
                            if Depth = 0 then
                                exit(i);
                        end;
        end;
        exit(0);
    end;
#endregion


#region Specific Function
    procedure GetALProcedureCode(var AppObj: Record "Application Object Metadata"; ProcedureName: Text): Text
    var
        ALLineInGlobalVar: array[25000] of Boolean;
        ALLineInProcedure: array[25000] of Boolean;
        ALLineInProcedureBody: array[25000] of Boolean;
        ALLineInVar: array[25000] of Boolean;
        ProcedureFound: Boolean;
        LF: Char;
        I: Integer;
        Lines: List of [Text];
        ALcode: Text;
        ALLineInProcedureName: array[25000] of Text;
        Line: Text;
        ResultBuilder: TextBuilder;
    begin
        ALcode := GetUserALCodeInStream(AppObj);
        if ALcode = '' then
            exit('');
        if ProcedureName = '' then
            Error('Procedure name is required');
        ProcedureName := ProcedureName.Trim();

        LF := 10;
        Lines := ALcode.Split(LF);
        CacheALLinesState(Lines, ALLineInProcedure, ALLineInProcedureName, ALLineInProcedureBody, ALLineInGlobalVar, ALLineInVar);

        // Split the text into lines (handles both CRLF and LF, Trim will handle trailing CR)
        for I := 2 to (Lines.Count() - 1) do begin // ignore first and last line
            Line := Lines.Get(I);

            // Entering field/item
            if ALLineInProcedure[I] then
                // Entering procedure — the name match (procedure/trigger OR action) must be
                // scoped to the requested field/item. The parentheses around the OR are required:
                // "and" binds tighter than "or", so without them the field/item scope only
                // applied to the action branch and the first trigger of that name anywhere in
                // the object was returned regardless of which field/item it belonged to.
                if (ALLineInProcedureName[I].ToLower() = ProcedureName.ToLower()) then begin
                    // Add procedure definition line
                    if not ProcedureFound then begin
                        // Check for procedure decoration
                        if I > 2 then
                            if Lines.Get(I - 1).Trim().StartsWith('[') then
                                ResultBuilder.AppendLine(Lines.Get(I - 1).Trim());
                        ProcedureFound := true;
                    end;
                    // AL Code
                    ResultBuilder.AppendLine(Line);
                end;
        end;
        if not ProcedureFound then
            exit(StrSubstNo('Procedure "%1" not found in AL source code.', ProcedureName))
        else begin
            ResultBuilder.AppendLine('end;');
            exit(ResultBuilder.ToText());
        end;
    end;

    local procedure pif()
    var
        AC: Record "Access Control";
        EP: Record "Expanded Permission";
    begin
        AC.SetRange("User Security ID", UserSecurityId());
        if AC.FindSet() then
            repeat
                EP.SetRange("Role ID", AC."Role ID");
                EP.SetRange("Object Type", EP."Object Type"::Page);
                EP.SetRange("Object ID");
                Message('%1 (%2): page rows=%3', AC."Role ID", AC."Company Name", EP.Count());
                EP.SetRange("Object ID", 0);
                if not EP.IsEmpty() then
                    Message('  -> grants ALL pages (wildcard)');
            until AC.Next() = 0;
    end;


    /// <summary>
    /// The object's global var section(s) followed by every PROCEDURE, as one compilable text —
    /// the whole-object counterpart of GetALProcedureCode, extracted in a single pass instead of
    /// one pass per name.
    /// </summary>
    /// <remarks>
    /// AL lets an object declare SEVERAL top-level var sections, interleaved with procedures.
    /// They are all hoisted into ONE leading `var` block here, because a consumer that compiles
    /// this text sees a plain compilation unit, where declarations come first. Hoisting is safe:
    /// object-level declarations have no ordering semantics — they are all in scope in every
    /// procedure regardless of where they were written.
    ///
    /// TRIGGERS are excluded on purpose: a table with ten field triggers yields ten declarations
    /// named OnValidate, which is a duplicate-name error in any compiler, and the ALI record
    /// runtime already runs native triggers on Insert/Modify. DECORATED procedures are excluded
    /// too, except `[TryFunction]` (re-emitted, the interpreter models it) and the run-time-neutral
    /// NonDebuggable / Scope / Obsolete (dropped) — see DecorationKeepsProc. Event, CommitBehavior
    /// and friends change what the declaration MEANS; dropping the attribute and keeping the body
    /// would silently misexecute, so such a procedure is left out entirely instead.
    ///
    /// local/internal/protected procedures ARE included — a public procedure calling a local
    /// helper is the ordinary shape, and the helper has to be in the same unit for that call to
    /// resolve. `protected` is normalised away: it is an access modifier with no meaning inside
    /// a single unit, and consumers need not know the spelling.
    ///
    /// EVENTS are the one place the text is rewritten rather than copied. An event PUBLISHER
    /// (`[IntegrationEvent]`, `[BusinessEvent]`, `[InternalEvent]`, `[ExternalBusinessEvent]`)
    /// keeps its declaration, but its body — always empty in AL — is replaced by plain calls to
    /// every active subscriber of that event, read from "Event Subscription" in record order
    /// (see EventPublisherBody). An `[EventSubscriber]` procedure is kept with its attribute
    /// dropped: it is now an ordinary procedure that the synthesized publisher body calls.
    /// </remarks>
    procedure GetALObjectProceduresCode(var AppObj: Record "Application Object Metadata"): Text
    var
        ALLineInGlobalVar: array[25000] of Boolean;
        ALLineInProcedure: array[25000] of Boolean;
        ALLineInProcedureBody: array[50000] of Boolean;
        ALLineInVar: array[25000] of Boolean;
        IsPublisher: Boolean;
        IsTry: Boolean;
        SkipProc: Boolean;
        SubscribersLoaded: Boolean;
        LF: Char;
        I: Integer;
        PublisherHeader: Integer;
        SubscriberSources: Dictionary of [Integer, Text];
        SubscribersByEvent: Dictionary of [Text, Text];
        Lines: List of [Text];
        ALcode: Text;
        ALLineInProcedureName: array[25000] of Text;
        PrevProcName: Text;
        ProcBuilder: TextBuilder;
        ResultBuilder: TextBuilder;
        VarBuilder: TextBuilder;
    begin
        ALcode := GetUserALCodeInStream(AppObj);
        if ALcode = '' then
            exit('');

        LF := 10;
        Lines := ALcode.Split(LF);
        CacheALLinesState(Lines, ALLineInProcedure, ALLineInProcedureName, ALLineInProcedureBody, ALLineInGlobalVar, ALLineInVar);

        // A procedure's closing `end;` is the line that CLEARS the name, so it is never itself
        // "in procedure" — every transition back to '' emits the `end;` the extraction dropped,
        // exactly as GetALProcedureCode appends one at the end.
        for I := 2 to (Lines.Count() - 1) do begin
            if ALLineInProcedureName[I] <> PrevProcName then begin
                if (PrevProcName <> '') and not SkipProc then
                    ProcBuilder.AppendLine('end;');
                PrevProcName := ALLineInProcedureName[I];
                SkipProc := false;
                if PrevProcName <> '' then begin
                    SkipProc := Lines.Get(I).Trim().ToLower().StartsWith('trigger ');
                    IsTry := false;
                    IsPublisher := false;
                    if not SkipProc then
                        SkipProc := not DecorationKeepsProc(Lines, I, IsTry, IsPublisher);
                    if not SkipProc then begin
                        if IsPublisher then begin
                            PublisherHeader := I;
                            if not SubscribersLoaded then begin
                                LoadEventSubscribers(AppObj, SubscribersByEvent);
                                SubscribersLoaded := true;
                            end;
                        end;
                        if IsTry then
                            ProcBuilder.AppendLine('[TryFunction]');
                        ProcBuilder.AppendLine(StripProtected(Lines.Get(I)));
                        continue;
                    end;
                end;
            end;
            // Global declarations, from however many separate var sections the object has. The
            // `var` keyword line itself is dropped — one is emitted below for the merged block.
            if ALLineInGlobalVar[I] then begin
                if Lines.Get(I).Trim().ToLower() <> 'var' then
                    VarBuilder.AppendLine(Lines.Get(I));
                continue;
            end;
            if ALLineInProcedure[I] and not SkipProc then
                if not IsPublisher then
                    ProcBuilder.AppendLine(Lines.Get(I))
                else
                    // Publisher: declaration lines are copied as written (a wrapped signature may
                    // carry comments), the `begin` line is where the synthesized var section and
                    // calls go, and the empty body after it is dropped. The closing `end;` comes
                    // from the transition above, as for any procedure.
                    if Lines.Get(I).Trim().ToLower() = 'begin' then
                        ProcBuilder.Append(EventPublisherBody(Lines, PublisherHeader, PrevProcName, AppObj."Object Type" <> AppObj."Object Type"::Codeunit, SubscribersByEvent, SubscriberSources))
                    else
                        if not ALLineInProcedureBody[I] then
                            ProcBuilder.AppendLine(Lines.Get(I));
        end;
        if (PrevProcName <> '') and not SkipProc then
            ProcBuilder.AppendLine('end;');

        if VarBuilder.Length() > 0 then begin
            ResultBuilder.AppendLine('var');
            ResultBuilder.Append(VarBuilder.ToText());
        end;
        ResultBuilder.Append(ProcBuilder.ToText());
        exit(ResultBuilder.ToText());
    end;

    // The attribute lines directly above the procedure header at HeaderLine decide whether it is
    // harvested. `[TryFunction]` is kept (re-emitted, IsTry) because the interpreter models it;
    // NonDebuggable / Scope / Obsolete change nothing at run time and are dropped. An event
    // publisher is kept with its body synthesized (IsPublisher, see EventPublisherBody) and an
    // event subscriber is kept as a plain procedure. Any other attribute (CommitBehavior,
    // ErrorBehavior, …) changes what the procedure means and the interpreter does not model it —
    // the procedure is left out.
    local procedure DecorationKeepsProc(Lines: List of [Text]; HeaderLine: Integer; var IsTry: Boolean; var IsPublisher: Boolean): Boolean
    var
        AttrName: Text;
        AttrLine: Text;
        EndPos: Integer;
        J: Integer;
    begin
        J := HeaderLine - 1;
        while J >= 2 do begin
            AttrLine := Lines.Get(J).Trim();
            if not AttrLine.StartsWith('[') then
                exit(true);
            AttrName := CopyStr(AttrLine, 2);
            EndPos := AttrName.IndexOfAny('(]');
            if EndPos > 0 then
                AttrName := CopyStr(AttrName, 1, EndPos - 1);
            case AttrName.Trim().ToLower() of
                'tryfunction':
                    IsTry := true;
                'nondebuggable', 'scope', 'obsolete', 'eventsubscriber':
                    ;
                'integrationevent', 'businessevent', 'internalevent', 'externalbusinessevent':
                    IsPublisher := true;
                else
                    exit(false);
            end;
            J -= 1;
        end;
        exit(true);
    end;

    // `protected procedure Foo(...)` -> `procedure Foo(...)`, indentation preserved. Access
    // modifiers mean nothing inside a single compilation unit.
    local procedure StripProtected(DeclLine: Text): Text
    var
        Pos: Integer;
    begin
        if not DeclLine.Trim().ToLower().StartsWith('protected ') then
            exit(DeclLine);
        Pos := DeclLine.ToLower().IndexOf('protected ');
        exit(DelStr(DeclLine, Pos, StrLen('protected ')));
    end;
#endregion


#region Events
    // Every active, non-manual subscription to an event of AppObj's object, as
    // UPPER(published function) -> LF-joined `<codeunit id>|<subscriber function>` entries, in
    // "Event Subscription" record order — the order the platform raises them in. One read per
    // object, not per publisher: the virtual table enumerates subscriptions on every query.
    // Manual subscribers are left out: they only run once BindSubscription was called, which the
    // interpreter does not model, so from its point of view they are never bound.
    local procedure LoadEventSubscribers(var AppObj: Record "Application Object Metadata"; var SubscribersByEvent: Dictionary of [Text, Text])
    var
        ExtObj: Record AllObjWithCaption;
        EventSub: Record "Event Subscription";
        LF: Char;
        PublisherId: Integer;
        Entries: Text;
        EventKey: Text;
    begin
        Clear(SubscribersByEvent);
        LF := 10;
        PublisherId := AppObj."Object ID";
        case AppObj."Object Type" of
            AppObj."Object Type"::Codeunit:
                EventSub.SetRange("Publisher Object Type", EventSub."Publisher Object Type"::Codeunit);
            AppObj."Object Type"::Table:
                EventSub.SetRange("Publisher Object Type", EventSub."Publisher Object Type"::Table);
            AppObj."Object Type"::TableExtension:
                begin
                    // A tableextension's events are subscribed to, and registered, under its BASE table.
                    if not ExtObj.Get(ExtObj."Object Type"::TableExtension, AppObj."Object ID") then
                        exit;
                    if not Evaluate(PublisherId, ExtObj."Object Subtype") then
                        exit;
                    EventSub.SetRange("Publisher Object Type", EventSub."Publisher Object Type"::Table);
                end;
            else
                exit;
        end;
        EventSub.SetRange("Publisher Object ID", PublisherId);
        EventSub.SetRange(Active, true);
        EventSub.SetFilter("Subscriber Instance", '<>%1', 'Manual');
        if EventSub.FindSet() then
            repeat
                EventKey := UpperCase(EventSub."Published Function");
                if not SubscribersByEvent.Get(EventKey, Entries) then
                    Entries := '';
                Entries += Format(EventSub."Subscriber Codeunit ID") + '|' + EventSub."Subscriber Function" + LF;
                SubscribersByEvent.Set(EventKey, Entries);
            until EventSub.Next() = 0;
    end;

    // What replaces a publisher's `begin` line: a var section with one codeunit variable per
    // subscriber, then `begin` and one call per subscriber. The caller emits the closing `end;`.
    //
    //   var ALIEvtSub1: Codeunit "X"; ...  begin ALIEvtSub1.Handler(Rec, IsHandled); ...
    //
    // Arguments are matched BY NAME, as the platform matches them: a subscriber declares any
    // subset of the publisher's parameters, in any order. `sender` (IncludeSender) is the
    // publishing record for a table/tableextension event — the unit's implicit `Rec`. A codeunit
    // sender cannot be passed (a codeunit is not a value in the interpreter, ALI927), so that call
    // raises instead of silently not running.
    //
    // A subscriber whose declaration cannot be read (no AL source) is still called, with no
    // arguments: the call then fails to bind, the publisher is Blocked, and a call reaching it
    // says why — truthful, where dropping the subscriber would not be.
    //
    // Instance lifetime: each variable is ONE compile-time instance (registry phase B2), while
    // the platform gives a StaticAutomatic subscriber a fresh instance per raise. `Clear(var)`
    // before the call restores that — the lowerer resets the variable's whole block of codeunit
    // globals. A SingleInstance subscriber is not cleared: its state is meant to survive.
    //
    // ponytail: that SingleInstance state is per publisher variable, not one session-wide
    // singleton shared with other raise sites or with native code.
    local procedure EventPublisherBody(Lines: List of [Text]; HeaderLine: Integer; PublisherName: Text; IsTablePublisher: Boolean; var SubscribersByEvent: Dictionary of [Text, Text]; var SubscriberSources: Dictionary of [Integer, Text]): Text
    var
        SubObj: Record AllObjWithCaption;
        LF: Char;
        CodeunitId: Integer;
        N: Integer;
        SepPos: Integer;
        PublisherParams: List of [Text];
        Args: Text;
        Entries: Text;
        Entry: Text;
        Failure: Text;
        SubscriberDecl: Text;
        SubscriberFunc: Text;
        Calls: TextBuilder;
        Vars: TextBuilder;
    begin
        LF := 10;
        if SubscribersByEvent.Get(UpperCase(PublisherName), Entries) then begin
            PublisherParams := ParameterNamesOf(JoinDeclarationLines(Lines, HeaderLine));
            foreach Entry in Entries.Split(LF) do
                if Entry <> '' then begin
                    SepPos := Entry.IndexOf('|');
                    Evaluate(CodeunitId, CopyStr(Entry, 1, SepPos - 1));
                    SubscriberFunc := CopyStr(Entry, SepPos + 1);
                    Failure := '';
                    Args := '';
                    if not SubObj.Get(SubObj."Object Type"::Codeunit, CodeunitId) then
                        Failure := StrSubstNo('codeunit %1 is not installed', CodeunitId)
                    else begin
                        SubscriberDecl := SubscriberDeclaration(CodeunitId, SubscriberFunc, SubscriberSources);
                        if SubscriberDecl <> '' then
                            Failure := SubscriberArguments(ParameterNamesOf(SubscriberDecl), PublisherParams, IsTablePublisher, Args);
                    end;
                    if Failure <> '' then
                        Calls.AppendLine(StrSubstNo('    Error(''%1'');', StrSubstNo('The AL interpreter cannot raise event %1 to subscriber %2 of codeunit %3: %4.', PublisherName, SubscriberFunc, CodeunitId, Failure).Replace('''', '''''')))
                    else begin
                        N += 1;
                        Vars.AppendLine(StrSubstNo('    ALIEvtSub%1: Codeunit "%2";', N, SubObj."Object Name"));
                        if not IsSingleInstance(CodeunitId, SubscriberSources) then
                            Calls.AppendLine(StrSubstNo('    Clear(ALIEvtSub%1);', N));
                        Calls.AppendLine(StrSubstNo('    ALIEvtSub%1.%2(%3);', N, IdentifierText(SubscriberFunc), Args));
                    end;
                end;
        end;
        if Vars.Length() > 0 then
            exit('var' + Format(LF) + Vars.ToText() + 'begin' + Format(LF) + Calls.ToText());
        exit('begin' + Format(LF) + Calls.ToText());
    end;

    // The publisher-side argument for each subscriber parameter, comma-joined into Args. Returns
    // '' on success, or why the subscriber cannot be called.
    local procedure SubscriberArguments(SubscriberParams: List of [Text]; PublisherParams: List of [Text]; IsTablePublisher: Boolean; var Args: Text): Text
    var
        Found: Boolean;
        PublisherParam: Text;
        SubscriberParam: Text;
        Arg: Text;
    begin
        Args := '';
        foreach SubscriberParam in SubscriberParams do begin
            Found := false;
            foreach PublisherParam in PublisherParams do
                if not Found then
                    if NormalizedName(PublisherParam) = NormalizedName(SubscriberParam) then begin
                        Arg := PublisherParam;
                        Found := true;
                    end;
            if not Found then begin
                if NormalizedName(SubscriberParam) <> 'sender' then
                    exit(StrSubstNo('parameter %1 is not a parameter of the event', SubscriberParam));
                if not IsTablePublisher then
                    exit('a codeunit sender cannot be passed');
                Arg := 'Rec';
            end;
            if Args <> '' then
                Args += ', ';
            Args += Arg;
        end;
        exit('');
    end;

    // Declaration (one line) of SubscriberFunc in codeunit CodeunitId, or '' when its source is
    // not readable or does not declare it. Sources are cached per extraction call: several
    // subscribers of one object often live in the same codeunit.
    //
    // ponytail: first declaration of that name wins; an overloaded subscriber name would need the
    // `[EventSubscriber(...)]` line above each candidate checked against the event.
    local procedure SubscriberDeclaration(CodeunitId: Integer; SubscriberFunc: Text; var SubscriberSources: Dictionary of [Integer, Text]): Text
    var
        SubAppObj: Record "Application Object Metadata";
        LF: Char;
        J: Integer;
        Lines: List of [Text];
        Line: Text;
        Source: Text;
        Wanted: Text;
    begin
        if not SubscriberSources.Get(CodeunitId, Source) then begin
            SubAppObj.SetRange("Object Type", SubAppObj."Object Type"::Codeunit);
            SubAppObj.SetRange("Object ID", CodeunitId);
            Source := GetUserALCodeFromFilters(SubAppObj);
            SubscriberSources.Set(CodeunitId, Source);
        end;
        if Source = '' then
            exit('');

        LF := 10;
        Lines := Source.Split(LF);
        Wanted := SubscriberFunc.ToLower();
        for J := 1 to Lines.Count() do begin
            Line := Lines.Get(J).Trim().ToLower();
            if Line.StartsWith('local ') or Line.StartsWith('internal ') or Line.StartsWith('protected ') then
                Line := CopyStr(Line, Line.IndexOf(' ') + 1).TrimStart();
            if Line.StartsWith('procedure ') then begin
                Line := CopyStr(Line, StrLen('procedure ') + 1).TrimStart();
                if Line.StartsWith('"' + Wanted + '"') then
                    exit(JoinDeclarationLines(Lines, J));
                if Line.StartsWith(Wanted) then
                    if (StrLen(Line) = StrLen(Wanted)) or (CopyStr(Line, StrLen(Wanted) + 1, 1) in ['(', ' ']) then
                        exit(JoinDeclarationLines(Lines, J));
            end;
        end;
        exit('');
    end;

    // Parameter names in declaration order, as written (quotes kept, `var` dropped) — the
    // name-side sibling of ParameterTypesOf.
    local procedure ParameterNamesOf(Declaration: Text) Names: List of [Text]
    var
        ClosePos: Integer;
        ColonPos: Integer;
        OpenPos: Integer;
        Params: List of [Text];
        Inner: Text;
        Param: Text;
    begin
        OpenPos := UnquotedPos(Declaration, '(');
        if OpenPos = 0 then
            exit;
        ClosePos := MatchingParen(Declaration, OpenPos);
        if ClosePos <= OpenPos + 1 then
            exit;
        Inner := CopyStr(Declaration, OpenPos + 1, ClosePos - OpenPos - 1);
        Params := Inner.Split(';');
        foreach Param in Params do begin
            ColonPos := Param.IndexOf(':');
            if ColonPos > 0 then
                Param := CopyStr(Param, 1, ColonPos - 1);
            Param := Param.Trim();
            if Param.ToLower().StartsWith('var ') then
                Param := CopyStr(Param, 5).Trim();
            if Param <> '' then
                Names.Add(Param);
        end;
    end;

    // Does the subscriber codeunit declare `SingleInstance = true`? Read off the source that
    // SubscriberDeclaration already cached. ponytail: a text probe, so the property written in a
    // comment would count too.
    local procedure IsSingleInstance(CodeunitId: Integer; var SubscriberSources: Dictionary of [Integer, Text]): Boolean
    var
        Source: Text;
    begin
        if not SubscriberSources.Get(CodeunitId, Source) then
            exit(false);
        exit(DelChr(Source.ToLower(), '=', ' ').Contains('singleinstance=true;'));
    end;

    local procedure NormalizedName(Name: Text): Text
    begin
        exit(Name.Trim().TrimStart('"').TrimEnd('"').ToLower());
    end;

    // A procedure name as AL source: bare when it is a plain identifier, quoted otherwise.
    local procedure IdentifierText(Name: Text): Text
    var
        i: Integer;
    begin
        if Name = '' then
            exit('""');
        if Name[1] in ['0' .. '9'] then
            exit('"' + Name + '"');
        for i := 1 to StrLen(Name) do
            if not (Name[i] in ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '_']) then
                exit('"' + Name + '"');
        exit(Name);
    end;
#endregion


#region Cach.Ln.State
    local procedure CacheALLinesState(ALLines: List of [Text]; var ALLineInProcedure: array[25000] of Boolean; var ALLineInProcedureName: array[25000] of Text; var ALLineInProcedureBody: array[25000] of Boolean; var ALLineInGlobalVar: array[25000] of Boolean; var ALLineInVar: array[25000] of Boolean)
    var
        InGlobalVarSection, InLocalVarSection : Boolean;
        InProcedureBody: Boolean;
        InProcedureOrTrigger: Boolean;
        BlockDepth, I : Integer;
        InProcedureName: Text;
        Line, TrimmedLineLower : Text;
    begin
        I := 0;
        BlockDepth := 1;
        foreach Line in ALLines do begin
            I += 1;
            ALLineInProcedure[I] := InProcedureOrTrigger;
            ALLineInProcedureBody[I] := InProcedureBody;
            ALLineInVar[I] := InLocalVarSection;
            ALLineInGlobalVar[I] := InGlobalVarSection;
            ALLineInProcedureName[I] := InProcedureName;

            TrimmedLineLower := Line.Trim().ToLower();
            if TrimmedLineLower = '' then
                continue;

            // Track procedure/trigger entry — any of these open a local scope
            if TrimmedLineLower.StartsWith('procedure ')
                or TrimmedLineLower.StartsWith('local procedure ')
                or TrimmedLineLower.StartsWith('protected procedure ')
                or TrimmedLineLower.StartsWith('internal procedure ')
                or TrimmedLineLower.StartsWith('trigger ')
            then begin
                InProcedureOrTrigger := true;
                InLocalVarSection := false; // reset, any var after this is local
                InGlobalVarSection := false;
                InProcedureBody := false;
                if StrPos(Line, 'procedure ') > 0 then
                    InProcedureName := CopyStr(Line, StrPos(Line, 'procedure ') + 10)
                else
                    InProcedureName := CopyStr(Line, StrPos(Line, 'trigger ') + 8);
                if InProcedureName.IndexOf('(') > 0 then
                    InProcedureName := CopyStr(InProcedureName, 1, InProcedureName.IndexOf('(') - 1).Trim().TrimStart('"').TrimEnd('"')
                else
                    // Parameter list opening on the NEXT line (`procedure Hello` / newline / `(`):
                    // there is no '(' to cut at, so the name still carries the line's trailing
                    // whitespace — and a CR, since the caller splits on LF alone.
                    InProcedureName := InProcedureName.Trim().TrimStart('"').TrimEnd('"');
                BlockDepth := 1;
                ALLineInProcedureName[I] := InProcedureName;
                ALLineInProcedure[I] := InProcedureOrTrigger;
                ALLineInProcedureBody[I] := InProcedureBody;
                ALLineInVar[I] := InLocalVarSection;
                ALLineInGlobalVar[I] := InGlobalVarSection;

                continue;
            end;

            // Track exit from procedure/trigger via begin/end depth
            if InProcedureOrTrigger then begin
                if not InProcedureBody then begin
                    InProcedureBody := (TrimmedLineLower = 'begin') or (TrimmedLineLower.Contains(' begin '));
                    if InProcedureBody then begin
                        // Exit local var
                        InLocalVarSection := false;
                        ALLineInVar[I] := InLocalVarSection;
                    end else
                        // Detect var section (local scope only — we are inside procedure)
                        if not InProcedureBody then
                            if TrimmedLineLower = 'var' then begin
                                InLocalVarSection := true;
                                ALLineInVar[I] := InLocalVarSection;
                            end;
                end;
                if InProcedureBody then begin
                    ///////// Track depth
                    // 1 = base, 2 = inside procedure, 3 ...
                    // multy-line statement only
                    if (TrimmedLineLower = 'begin')
                    or (TrimmedLineLower.EndsWith(' begin') and not TrimmedLineLower.EndsWith(' else begin'))
                    or (TrimmedLineLower.EndsWith(' else begin') and not TrimmedLineLower.StartsWith('end'))
                    or TrimmedLineLower.Contains(' do begin') or TrimmedLineLower.Contains('repeat')
                    or (TrimmedLineLower.StartsWith('case ') and TrimmedLineLower.EndsWith('of')) then
                        BlockDepth += 1;

                    if (TrimmedLineLower = 'end;')
                    or TrimmedLineLower.Contains('until ')
                    or TrimmedLineLower.Contains('until(')
                    or TrimmedLineLower.EndsWith('end;')
                    or (TrimmedLineLower.Contains('end else') and not TrimmedLineLower.EndsWith('begin')) then
                        BlockDepth -= 1;
                    if BlockDepth < 1 then
                        BlockDepth := 1; // safety

                    if BlockDepth <= 1 then begin
                        InProcedureOrTrigger := false;
                        InProcedureBody := false;
                        InLocalVarSection := false;
                        InGlobalVarSection := false;
                        InProcedureName := '';
                        BlockDepth := 1;
                        ALLineInProcedure[I] := InProcedureOrTrigger;
                        ALLineInProcedureBody[I] := InProcedureBody;
                        ALLineInVar[I] := InLocalVarSection;
                        ALLineInGlobalVar[I] := InGlobalVarSection;
                        ALLineInProcedureName[I] := InProcedureName;
                    end;
                end;
                continue; // skip everything inside procedures and tirggers
            end;

            // Detect var section (global scope only — we skipped procedure lines above)
            if TrimmedLineLower = 'var' then begin
                InLocalVarSection := true;
                ALLineInVar[I] := InLocalVarSection;
                if not InProcedureOrTrigger then begin
                    InGlobalVarSection := true;
                    ALLineInGlobalVar[I] := InGlobalVarSection;
                end;
                continue;
            end;

            // Track exit from global vars
            if InLocalVarSection then
                if TrimmedLineLower in ['begin', 'keys', 'fieldgroups', 'schema', 'dataset', 'layout', 'actions', 'requestpage', '}', '{']
                    or TrimmedLineLower.StartsWith('procedure ')
                    or TrimmedLineLower.StartsWith('local procedure ')
                    or TrimmedLineLower.StartsWith('protected procedure ')
                    or TrimmedLineLower.StartsWith('internal procedure ')
                    or TrimmedLineLower.StartsWith('trigger ')
                    or TrimmedLineLower.StartsWith('[')
                then begin
                    InLocalVarSection := false;
                    InGlobalVarSection := false;
                    InProcedureName := '';
                    ALLineInVar[I] := InLocalVarSection;
                    ALLineInGlobalVar[I] := InGlobalVarSection;
                    ALLineInProcedureName[I] := InProcedureName;
                    continue;
                end;
        end;
    end;
#endregion
}
#endif
