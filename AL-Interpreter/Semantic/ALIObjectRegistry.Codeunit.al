// ALI Object Registry (M11) — resolves `Rec.SomeUserProcedure()` and `MyCU.SomeProcedure()` by
// HARVESTING the owning object's AL source at runtime and compiling it into the SAME module as
// the script. Objects are keyed by ("ALI Object Type", id): tables (phase 1/A/B) and codeunits
// (phase C1/C2) go through one code path, differing only in whether procedures get an implicit
// `Rec` receiver.
//
// Why bind-time and not first-execution: ALI is statically typed end to end — "no runtime type
// checks, fully annotated at bind" (ARCHITECTURE.md §5). A call site cannot be lowered without
// the callee's signature, so the object is harvested while the caller is still being bound.
// "ALI Binder".Bind therefore threads the Module through: the harvested unit's procedures are
// bound AND lowered before the caller's bind returns.
//
// Unit model (phase A): ONE OBJECT PER UNIT. Every procedure of the object is harvested and
// compiled together, which is what makes a harvested procedure able to call a SIBLING of its own
// object — an ordinary in-unit lookup, no new machinery, and no cross-token-table problem, since
// one unit means one intern pool. Phase 1's one-procedure-per-unit model could not do that.
//
// What that costs, and how it is paid: one unsupported procedure would now fail the WHOLE
// object. So the binder binds each procedure in its own diagnostic sandbox ("ALI Binder".
// SetIsolateProcErrors) — a procedure that does not compile is marked Blocked, its diagnostics
// are discarded, its siblings compile normally, and only a call TO it reports the failure
// (ALI922). Its proc row is still emitted, as a stub that raises when reached, so a sibling
// holding a CALL to it cannot jump into nothing.
//
// Object GLOBALS (phase B) are harvested too: every top-level var section of the object, however
// many there are and wherever they sit between procedures, is hoisted into one leading `var`
// block.
//
// Phase B2 gives them PER-VARIABLE storage, which is what native AL has. Every declared variable
// of the object's type — script global, local or parameter — owns one INSTANCE: a block of that
// object's globals carved out of the register bank above the script's own globals. An object
// global's slot is an offset inside that block; SELF_LOAD/SELF_STORE add the running instance's
// base at runtime. The instance itself is decided at COMPILE time, because AL variables are all
// statically declared: every call site passes the receiver variable's instance index as a hidden
// leading argument, and a sibling call inside the object forwards the one its own frame received
// (so recursion and call chains stay on the right block). An object that declares no globals gets
// no hidden argument and no instance — its calls are shaped exactly as they were.
//
//   *** Ceiling: a `var` record PARAMETER is its own instance. ***
//
// Aliasing shares the record — fields, filters, position — but not the caller's block of object
// globals: the parameter is a declared variable, so it got a block of its own. Same for a record
// LOCAL of a recursive script procedure, which has one block across all depths. Closing both
// needs the instance index to travel with every var-param, i.e. a companion hidden row per record
// parameter; the machinery here (hidden rows, SELF_*, the layout) already carries it.
//
// What is NOT harvested: TRIGGERS (ten field triggers named OnValidate would be ten duplicate
// declarations; the record runtime already runs native triggers on Insert/Modify) and DECORATED
// procedures whose attribute the interpreter does not model (CommitBehavior, ErrorBehavior, …):
// keeping the body without its attribute would silently misexecute. `[TryFunction]` IS harvested
// — the source extraction re-emits it and parser/binder/TRY_CALL treat it like a script's own —
// and NonDebuggable / Scope / Obsolete are dropped as run-time neutral ("ALI App. Obj. Metadata"
// DecorationKeepsProc). A call to an excluded procedure reports ALI961, as if it did not exist. A global whose TYPE the interpreter cannot represent (Codeunit, Report, DotNet…)
// is dropped from the unit, so only the procedures that mention it block.
//
// EVENTS need nothing from this codeunit, the binder or the lowerer: they are resolved in the
// SOURCE. The extraction replaces an event publisher's empty body with a codeunit variable and a
// by-name call per active, non-manual "Event Subscription" row (record order), and keeps
// `[EventSubscriber]` procedures as plain procedures ("ALI App. Obj. Metadata".
// EventPublisherBody). Raising the event is then an ordinary sibling call, and each subscriber an
// ordinary `MyCU.Proc()` harvest. Each call is preceded by `Clear(<subscriber variable>)` unless
// the subscriber is SingleInstance, which resets that instance's globals ("ALI Lowerer".
// EmitClearInstance) — the platform's fresh-instance-per-raise. Subscriptions are read once per object per SESSION, since the
// synthesized text is what SourceByObject caches. Trigger events (OnAfterInsertEvent…) are not
// part of this: the record runtime runs Insert/Modify/Validate natively, so the platform fires them.
//
// Scoping: every object gets ONE scope, parented to the ROOT rather than to the script's module
// scope, so object and script never see each other's names. Cross-unit lookup goes by NAME TEXT
// (Symbol Table LookupProcByName) because identifiers are interned per Token Table, so a NameId
// from one unit means nothing in another.
//
// The receiver: a TABLE procedure is bound with an implicit `Rec` VAR parameter of the owning
// table (see "ALI Binder".SetObjectContext), so `Rec.Field`, bare field names and `Rec.Modify`
// all work through machinery that already existed, and the call site passes the receiver by
// reference — the callee mutates the caller's record, exactly like native AL.
//
// TABLEEXTENSIONS: a procedure the base table does not declare is looked for in every
// tableextension of that table (TryBindObjectProc / TryLookupObjectProc fall back on
// ExtensionsOfTable). This is not a nicety — a standard table's own "User AL Code" is usually
// empty, so on Customer or Sales Header EVERY procedure a script can call lives in an extension.
//
// Each tableextension is its OWN unit: own source, own scope, own blocked/requested caches. The
// alternative — appending the extensions' source to the base table's and compiling one unit —
// hoists every extension's `var` section into ONE block, so two extensions that both declare
// `Setup: Record ...` collide as a duplicate declaration at UNIT level, which the per-procedure
// sandbox cannot contain. That would break a table that works today. Separate scopes cannot
// collide at all.
//
// What ties the unit back to the table is the object CONTEXT, not the scope: an extension unit is
// bound with SetObjectContext(Table, <base table>), which gives its procedures the implicit `Rec`
// of the base table AND puts its globals in the base table's per-instance block — the only block
// a receiver variable of that table ever allocates ("ALI Binder".AllocateGlobalSlots).
//
// A CODEUNIT procedure gets no receiver at all — it has no fields. `MyCU.P(a)` binds to an
// ordinary proc symbol and lowers to a plain CALL (phase C2); when the codeunit declares globals
// it additionally carries the phase-B2 instance index, so two codeunit variables of the same
// object keep separate state exactly as native AL does. `Codeunit.Run` (phase C3) never reaches
// this registry at all: the PLATFORM executes the codeunit, so OnRun stays unharvested and the
// error trap is native AL's own conditional Run — see "ALI Binder".BindRunCall.
codeunit 51152 "ALI Object Registry"
{
    Access = Public;
#if not CLOUD
    Permissions = tabledata "Application Object Metadata" = r;
#endif
    SingleInstance = true;

    var
        SignaturesOnly: Boolean;                        // see SetSignaturesOnly (live-check mode)
#if not CLOUD
        SymbolsByApp: Dictionary of [Guid, List of [Text]];
        // Conditional compilation: the harvested source is the extension's own AL, so it is lexed
        // with THAT extension's project-level preprocessor symbols. Same session lifetime and the
        // same staleness trade as SourceByObject.
        AppIdByObject: Dictionary of [Integer, Guid];    // ObjKey -> owning extension's app id
#endif
        ScopeByObject: Dictionary of [Integer, Integer]; // ObjKey -> symbol scope of that object
        BoundNamesByObject: Dictionary of [Integer, List of [Text]];  // ObjKey -> UPPER names already bound+lowered
        // ObjKey -> the harvested unit source. SESSION-lifetime, deliberately NOT cleared by
        // Reset: reading the blob off "Application Object Metadata" and re-running the whole-
        // object extraction is the same work every time, and an object's stored AL code does not
        // change between two Compile() calls. Same rationale (and same staleness trade) as
        // "ALI Rec Meta Cache" — a republish inside one session serves the old text until the
        // session ends. Pays off twice: repeated compiles of a script, and the ReuseSignatures
        // recompile a second procedure of the same object triggers.
        SourceByObject: Dictionary of [Integer, Text];
        // Tableextension fallback. SESSION-lifetime for the same reason as SourceByObject: the
        // set of extensions of a table does not change between two Compile() calls, and the
        // AllObjWithCaption scan that finds them is the same work every time.
        ExtIdsByTable: Dictionary of [Integer, List of [Integer]];   // base table id -> ext object ids, ascending
        BaseTableByExt: Dictionary of [Integer, Integer];            // ext object id -> base table id
        BlockedByProc: Dictionary of [Text, Text];       // ProcKey -> why that procedure did not compile
        HarvestDepth: Integer;
        CompiledObjects: List of [Integer];              // ObjKeys already harvested (compiled or missing)
        InProgress: List of [Integer];                   // ObjKeys currently compiling (re-entrancy)
        RequestedProcs: List of [Text];                  // ProcKeys whose BODY has been asked for (bound or absent)

    procedure Reset()
    begin
        Clear(ScopeByObject);
        Clear(BlockedByProc);
        Clear(CompiledObjects);
        Clear(RequestedProcs);
        Clear(BoundNamesByObject);
        Clear(InProgress);
        HarvestDepth := 0;
        // SignaturesOnly is a property of ONE compile, not of the session — and this codeunit is
        // SingleInstance, so a live check that turned it on used to leave it on for every later
        // compile driven by anything that did not explicitly turn it back off ("ALI Engine".
        // Compile did; "ALI Script Editor".CompileAndRun did not). The run that followed an edit
        // then harvested SIGNATURES ONLY: the callee's proc rows were reserved but no body was
        // ever lowered into them, and a CALL to such a row jumped to the module's first
        // instruction — the script's own entry prologue — which recursed until ALI952. Cleared
        // here so every compile starts from the honest default; LiveCheck sets it AFTER Reset.
        SignaturesOnly := false;
    end;

    // Live-check mode: harvest each referenced object for its SIGNATURES only — no body is bound,
    // nothing is lowered. Call sites still type-check exactly as before (the signature is all they
    // read), but the callee's body is never bound, so its own cross-object references are never
    // followed: one object per reference instead of a whole dependency graph, and no bytecode.
    // What is lost: ALI922 ("procedure could not be compiled") cannot be known without binding the
    // body, so such a call passes silently here and reports on the next full Compile(). Not
    // cleared by Reset — it is a host mode, like Enabled.
    procedure SetSignaturesOnly(Value: Boolean)
    begin
        SignaturesOnly := Value;
    end;

    // Resolve <object>.ProcName to a bound procedure symbol, harvesting and compiling the WHOLE
    // object on first use. ObjType is an "ALI Object Type" ordinal (Table or Codeunit). Returns
    // false when the feature is off, the object has no such procedure, or its source does not
    // compile (in which case Diags carries the object's own diagnostics, prefixed). A procedure
    // that compiled but was Blocked still resolves here — the pre-scan only warms the registry;
    // TryLookupObjectProc is where the refusal happens.
    //
    // A Table that does not declare the procedure falls back to its TABLEEXTENSIONS, in ascending
    // object id.
    //
    // ponytail: two extensions declaring the same name resolve to the lower object id, where
    // native AL would call the call ambiguous. Upgrade path if a real script ever hits it: keep
    // scanning after the first hit and report ALI961 naming both candidates.
    procedure TryBindObjectProc(ObjType: Integer; ObjId: Integer; ProcName: Text; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; var Diags: Codeunit "ALI Diag Bag"; var ProcSid: Integer): Boolean
    var
        ExtId: Integer;
    begin
        ProcSid := 0;

        EnsureObjectCompiled(ObjType, ObjId, ProcName, Symbols, Module, Diags);
        ProcSid := Symbols.LookupProcByName(ScopeOfObject(ObjType, ObjId, Symbols), ProcName);
        if ProcSid <> 0 then
            exit(true);

        // The base table does not declare it (or has no readable source at all, which is the
        // normal state of a standard table) — try the tableextensions, first one wins.
        if ObjType <> "ALI Object Type"::Table.AsInteger() then
            exit(false);
        foreach ExtId in ExtensionsOfTable(ObjId) do begin
            EnsureObjectCompiled("ALI Object Type"::"TableExtension".AsInteger(), ExtId, ProcName, Symbols, Module, Diags);
            ProcSid := Symbols.LookupProcByName(ScopeOfObject("ALI Object Type"::"TableExtension".AsInteger(), ExtId, Symbols), ProcName);
            if ProcSid <> 0 then
                exit(true);
        end;
        exit(false);
    end;

    // Cache-only resolution: does <object>.ProcName already exist as a bound, USABLE symbol?
    // Takes no Module because it never compiles anything — which is exactly what lets the binder
    // call it from deep inside expression binding, where the Module is out of reach. The
    // pre-scan ("ALI Binder".HarvestObjectRefs) is what puts the entry there first.
    //
    // BlockedReason is set (and false returned) when the procedure exists but did not compile,
    // so the call site can say that instead of "no procedure of that name".
    procedure TryLookupObjectProc(ObjType: Integer; ObjId: Integer; ProcName: Text; var Symbols: Codeunit "ALI Symbol Table"; var ProcSid: Integer; var BlockedReason: Text): Boolean
    var
        ExtId: Integer;
    begin
        ProcSid := 0;
        BlockedReason := '';
        if TryLookupInUnit(ObjType, ObjId, ProcName, Symbols, ProcSid, BlockedReason) then
            exit(true);
        if BlockedReason <> '' then
            exit(false);                                 // it IS this table's, it just did not compile

        // Same fallback as TryBindObjectProc, minus the compiling: whatever the pre-scan
        // harvested is already in a scope, and this runs where the Module is out of reach.
        if ObjType <> "ALI Object Type"::Table.AsInteger() then
            exit(false);
        foreach ExtId in ExtensionsOfTable(ObjId) do begin
            if TryLookupInUnit("ALI Object Type"::"TableExtension".AsInteger(), ExtId, ProcName, Symbols, ProcSid, BlockedReason) then
                exit(true);
            if BlockedReason <> '' then
                exit(false);
        end;
        exit(false);
    end;

    // One unit's cache lookup, shared by the base table and each of its extensions. Same contract
    // as TryLookupObjectProc: false + a BlockedReason means the procedure exists here but did not
    // compile, which must STOP the search — a later extension declaring the same name is not what
    // the call meant.
    local procedure TryLookupInUnit(ObjType: Integer; ObjId: Integer; ProcName: Text; var Symbols: Codeunit "ALI Symbol Table"; var ProcSid: Integer; var BlockedReason: Text): Boolean
    var
        ObjScope: Integer;
    begin
        ProcSid := 0;
        BlockedReason := '';
        if not ScopeByObject.Get(KeyOfObject(ObjType, ObjId), ObjScope) then
            exit(false);
        ProcSid := Symbols.LookupProcByName(ObjScope, ProcName);
        if ProcSid = 0 then
            exit(false);
        if BlockedByProc.Get(KeyOfProc(ObjType, ObjId, ProcName), BlockedReason) then begin
            ProcSid := 0;
            exit(false);
        end;
        exit(true);
    end;

    // Harvest + compile the whole object, once. Silent on a missing object (negative-cached so
    // metadata is not re-read); re-entrant calls short-circuit because pass 1 of the bind has
    // already declared every signature of the unit by the time any body can call back in.
    // Only the requested procedure and what it transitively calls get BODIES (the binder's
    // reachability worklist); every signature of the object is declared regardless, so a
    // reachable procedure can call any sibling. Compiling all ~50 procedures of a helper codeunit
    // to serve one call is what made a single `cu.Proc()` take tens of seconds: each extra body
    // ran the cross-object pre-scan and dragged in that body's own dependency graph.
    //
    // A LATER request for a procedure this pass did not reach recompiles the object in
    // ReuseSignatures mode: the signatures (and their proc rows) are already in the scope, so
    // only the newly reachable bodies are bound and lowered into the rows left empty.
    local procedure EnsureObjectCompiled(ObjType: Integer; ObjId: Integer; ProcName: Text; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; var Diags: Codeunit "ALI Diag Bag")
    var
        Known: Boolean;
        ObjKey: Integer;
        ObjScope: Integer;
        ProcKey: Text;
        Source: Text;
    begin
        ObjKey := KeyOfObject(ObjType, ObjId);
        // Re-entrancy: the object is mid-compile further up the stack. Pass 1 has already
        // declared every signature by the time any body can call back in, so the lookup that
        // follows this call succeeds — and starting a second compile here would duplicate them.
        if InProgress.Contains(ObjKey) then
            exit;

        ProcKey := KeyOfProc(ObjType, ObjId, ProcName);
        Known := CompiledObjects.Contains(ObjKey);
        if Known then begin
            if (ProcName = '') or RequestedProcs.Contains(ProcKey) then
                exit;                                    // asked before — bound, or known absent
            if BoundNamesOf(ObjType, ObjId).Contains(UpperCase(ProcName)) then
                exit;                                    // already bound as somebody's callee
        end;

        ObjScope := ScopeOfObject(ObjType, ObjId, Symbols);
        if not TryGetObjectSource(ObjType, ObjId, Source) then begin
            CompiledObjects.Add(ObjKey);                 // negative cache: do not re-read metadata
            exit;
        end;

        // Does this object DECLARE the wanted procedure at all? A text probe over the (already
        // cached) source, before committing to lex + parse + a signature pass.
        //
        // This is not a micro-optimisation. `Cust.SomeEcaProcedure()` used to compile the WHOLE
        // of table 18 — 3900 lines of Microsoft's Customer table — purely to discover the name
        // is not there, and only then look in the tableextension that really declares it. That
        // wasted pass is where the wall of parse diagnostics came from: full base-app AL run
        // through ALI's subset parser, for an object nobody asked about.
        //
        // Safe because it can only ever over-match: a name that merely PREFIXES a real
        // declaration costs the compile this avoids, while a declaration that is really there
        // always contains `procedure <name>` (or `procedure "<name>"` when the author quoted
        // it) somewhere in the harvested text.
        //
        // ponytail: ToLower() over the whole source on each probed name. Cache the lowered text
        // alongside SourceByObject if a script ever probes one big object enough times to care.
        if ProcName <> '' then
            if not SourceDeclaresProc(Source, ProcName) then
                exit;

        if HarvestDepth >= MaxHarvestDepth() then begin
            Diags.AddError('ALI962', StrSubstNo('Cross-object call chain too deep (max %1) while resolving %2', MaxHarvestDepth(), ObjectLabel(ObjType, ObjId)), 0, 0);
            exit;
        end;

        // Remember the request BEFORE compiling: a procedure the source does not have must not
        // be re-attempted on every call site that mentions it.
        if ProcName <> '' then
            RequestedProcs.Add(ProcKey);

        InProgress.Add(ObjKey);
        HarvestDepth += 1;
        CompileObjectUnit(ObjType, ObjId, ProcName, Known, Source, ObjScope, Symbols, Module, Diags);
        HarvestDepth -= 1;
        InProgress.Remove(ObjKey);
        CompiledObjects.Add(ObjKey);
    end;

    // The scope every procedure of this object is bound into. Parent 0 = the root: an object
    // sees neither the script's globals nor another object's names.
    local procedure ScopeOfObject(ObjType: Integer; ObjId: Integer; var Symbols: Codeunit "ALI Symbol Table"): Integer
    var
        ObjKey: Integer;
        Saved: Integer;
        Scope: Integer;
    begin
        ObjKey := KeyOfObject(ObjType, ObjId);
        if ScopeByObject.Get(ObjKey, Scope) then
            exit(Scope);
        // Restore the CALLER's scope, not the module scope: the harvest pre-scan runs while a
        // procedure BODY is being bound, and that body's locals live in the proc scope. Dropping
        // back to the module scope made every local invisible for the rest of the bind (AL0118).
        Saved := Symbols.CurrentScope();
        Scope := Symbols.PushScope(0);
        Symbols.SetCurrentScope(Saved);                  // PushScope made it current; undo that
        ScopeByObject.Set(ObjKey, Scope);
        exit(Scope);
    end;

    // Front end + lowerer for one harvested OBJECT. Its own Token Table / Ast Store / Diag Bag;
    // the Symbol Table and Module are shared with the caller. Diagnostics are collected apart and
    // copied over with the object named, because their line numbers refer to the HARVESTED
    // source, not to the script the user is looking at. Per-PROCEDURE failures never reach that
    // bag at all — they are sealed off by the binder and recorded as Blocked here instead.
    local procedure CompileObjectUnit(ObjType: Integer; ObjId: Integer; ProcName: Text; Reuse: Boolean; Source: Text; ObjScope: Integer; var Symbols: Codeunit "ALI Symbol Table"; var Module: Codeunit "ALI Module"; var Diags: Codeunit "ALI Diag Bag")
    var
        Ast: Codeunit "ALI Ast Store";
        Binder: Codeunit "ALI Binder";
        ObjDiags: Codeunit "ALI Diag Bag";
        Lexer: Codeunit "ALI Lexer";
        Lowerer: Codeunit "ALI Lowerer";
        Parser: Codeunit "ALI Parser";
        Tokens: Codeunit "ALI Token Table";
        ParseErrs: Integer;
        ParseMark: Integer;
        Root: Integer;
        SavedScope: Integer;
        EntryNames: List of [Text];
        FirstErr: Text;
    begin
        SavedScope := Symbols.CurrentScope();
        Tokens.Reset();
        Ast.Reset();
        ObjDiags.Reset();

#if not CLOUD
        Lexer.SetDefinedSymbols(PreprocSymbolsOf(ObjType, ObjId));
#endif
        Lexer.Tokenize(Source, Tokens, ObjDiags);
        if not ObjDiags.HasErrors() then begin
            ParseMark := ObjDiags.Count();
            Root := Parser.ParseCompilationUnit(Tokens, Ast, ObjDiags);
            // A PARSE error is NOT fatal to the object. ParseProcDeclLoop resyncs to the next
            // procedure keyword (SyncTopLevel), so everything that parsed cleanly is in the tree
            // and is worth binding — refusing the whole object because one declaration confused
            // the reader is what turned a single ALI911 in a 1000-line codeunit into "this
            // codeunit has no procedures at all". Carry on, and any procedure the mis-parse
            // actually damaged fails its own per-procedure sandbox.
            //
            // COLLAPSED TO ONE LINE. Recovery diagnostics come in avalanches: one confused
            // declaration in a large object desynchronises the reader until the next `procedure`
            // keyword, and each skipped line adds its own "X expected". Harvesting a standard
            // table this way produced HUNDREDS of them — for source the reader did not write,
            // cannot edit, and was not asking about, drowning the one diagnostic that was
            // actually about their script. They are already non-fatal, which is the admission
            // that nothing is meant to be done about them; printing every one just made the
            // output unreadable. Keep the count and the first message, drop the rest.
            //
            // LEXER errors stay fatal — a broken token stream has no recovery point.
            if ObjDiags.HasErrors() then begin
                ParseErrs := ObjDiags.ErrorCount();
                FirstErr := ParseErrorSample(ObjDiags, ParseMark, Source);
                ObjDiags.TruncateTo(ParseMark);
                ObjDiags.AddWarning('ALI911', StrSubstNo('%1 statement(s)/declaration(s) could not be read and were skipped; the procedures containing them are unavailable. %2', ParseErrs, FirstErr), 0, 0);
            end;
            begin
                Binder.SetAppendMode(true);              // shared Symbol Table — never reset it
                Binder.SetUnitScope(ObjScope);
                // Only a TABLE unit gets the implicit `Rec` receiver. A codeunit has no fields and
                // (phase B) no per-instance state, so its procedures are plain procedures.
                //
                // A TABLEEXTENSION is bound as its base table, which is the whole trick: `Rec` and
                // every bare field name resolve against the base table exactly as native AL does,
                // and the unit's globals land in the base table's instance block — the only block
                // a receiver variable of that table ever allocates. Its SCOPE stays its own, so
                // two extensions cannot collide over a name.
                if ObjType = "ALI Object Type"::"TableExtension".AsInteger() then
                    Binder.SetObjectContext("ALI Object Type"::Table.AsInteger(), BaseTableOf(ObjId))
                else
                    Binder.SetObjectContext(ObjType, ObjId);
                Binder.SetIsolateProcErrors(true);       // one bad procedure must not sink the object
                // Reachability: only ProcName's body and what it calls. '' would mean "all", which
                // is what made one call compile a whole dependency graph.
                if ProcName <> '' then
                    EntryNames.Add(ProcName);
                Binder.SetEntryProcNames(EntryNames);
                Binder.SetReuseSignatures(Reuse);
                Binder.SetSignaturesOnly(SignaturesOnly);
                Binder.SetAlreadyBoundProcNames(BoundNamesOf(ObjType, ObjId));
                if Binder.Bind(Tokens, Ast, Symbols, ObjDiags, Module, Root) and not SignaturesOnly then begin
                    Lowerer.SetUnboundProcs(Binder.UnboundProcNodes());
                    NoteBoundProcs(ObjType, ObjId, Binder.BoundProcNames());
                    RecordBlockedProcs(ObjType, ObjId, Binder, Lowerer);
                    Lowerer.SetObjectUnit(true);         // no module-global initializers here
                    Lowerer.LowerUnit(Tokens, Ast, Symbols, ObjDiags, Module, Root);
                end;
            end;
        end;

        Symbols.SetCurrentScope(SavedScope);             // the caller's bind resumes where it was
        CopyDiags(ObjDiags, Diags, ObjType, ObjId, Source);
    end;

    // UPPER-cased names of this object's procedures whose bodies are already bound and lowered.
    local procedure BoundNamesOf(ObjType: Integer; ObjId: Integer) Names: List of [Text]
    begin
        if BoundNamesByObject.Get(KeyOfObject(ObjType, ObjId), Names) then
            exit(Names);
        Clear(Names);
    end;

    // Record what this compile bound, so a later compile of the same object skips those bodies
    // instead of binding them twice (two symbol sets against one proc id, body emitted twice).
    local procedure NoteBoundProcs(ObjType: Integer; ObjId: Integer; NewNames: List of [Text])
    var
        ObjKey: Integer;
        Names: List of [Text];
        Name: Text;
    begin
        ObjKey := KeyOfObject(ObjType, ObjId);
        if not BoundNamesByObject.Get(ObjKey, Names) then
            Clear(Names);
        foreach Name in NewNames do
            if not Names.Contains(UpperCase(Name)) then
                Names.Add(UpperCase(Name));
        BoundNamesByObject.Set(ObjKey, Names);
    end;

    // Carry the binder's Blocked list into the registry cache (so call sites can refuse with a
    // reason) and into the lowerer (so their bodies become raising stubs instead of real code).
    local procedure RecordBlockedProcs(ObjType: Integer; ObjId: Integer; var Binder: Codeunit "ALI Binder"; var Lowerer: Codeunit "ALI Lowerer")
    var
        i: Integer;
        Msgs: List of [Text];
        Names: List of [Text];
        Reasons: List of [Text];
        Msg: Text;
    begin
        Names := Binder.BlockedProcNames();
        Reasons := Binder.BlockedProcReasons();
        for i := 1 to Names.Count() do begin
            Msg := StrSubstNo('Procedure ''%1'' of %2 could not be compiled by the AL interpreter: %3', Names.Get(i), ObjectLabel(ObjType, ObjId), Reasons.Get(i));
            BlockedByProc.Set(KeyOfProc(ObjType, ObjId, Names.Get(i)), Reasons.Get(i));
            Msgs.Add(Msg);
        end;
        Lowerer.SetBlockedProcs(Binder.BlockedProcNodes(), Msgs);
    end;

    // SEVERITY IS PRESERVED. It used to be forced to Error, which was invisible while a harvest
    // could only ever produce errors — but a NESTED harvest (a codeunit whose procedure calls a
    // table procedure) copies the inner object's bag through here, and phase B's ALI923 is an
    // INFO. Promoting it turned "this object has globals" into a hard compile failure for every
    // script that reached a second object.
    local procedure CopyDiags(var From: Codeunit "ALI Diag Bag"; var Into: Codeunit "ALI Diag Bag"; ObjType: Integer; ObjId: Integer; Source: Text)
    var
        i: Integer;
        Lines: List of [Text];
    begin
        if From.Count() = 0 then
            exit;
        Lines := Source.Split(NewLineChar());
        for i := 1 to From.Count() do
            Into.AddAtPos(From.GetCode(i), From.GetSeverity(i),
                StrSubstNo('In %1 (harvested line %2): %3%4', ObjectLabel(ObjType, ObjId), From.GetLine(i), From.GetMessage(i), QuotedLine(Lines, From.GetLine(i))),
                0, 0, From.GetStage(i));
    end;

    // ` -> <source text>` for a harvested line, or '' when the line number is out of range. The
    // harvested unit is assembled from several places in the object's source and is not something
    // the reader can open, so a diagnostic that only cites a line number in it is unactionable.
    local procedure QuotedLine(Lines: List of [Text]; LineNo: Integer): Text
    begin
        if (LineNo < 1) or (LineNo > Lines.Count()) then
            exit('');
        exit(StrSubstNo(' -> %1', Lines.Get(LineNo).Trim()));
    end;

    local procedure NewLineChar(): Char
    begin
        exit(10);
    end;

    // Source of every PROCEDURE of the object, straight from its stored AL code (triggers and
    // decorated procedures excluded, globals hoisted — see the header). False when the object has
    // no metadata row or nothing harvestable in it.
    local procedure TryGetObjectSource(ObjType: Integer; ObjId: Integer; var Source: Text): Boolean
    var
#if not CLOUD
        AppObj: Record "Application Object Metadata";
        MetaPage: Page "ALI App. Obj. Metadata";
#endif
        ObjKey: Integer;
    begin
        Source := '';
        // Session cache (see SourceByObject). The blob read has to go through the page — a Blob
        // read off a bare record variable returns empty outside a page context — but nothing
        // says it has to happen twice for the same object.
        ObjKey := KeyOfObject(ObjType, ObjId);
        if SourceByObject.Get(ObjKey, Source) then
            exit(Source <> '');

#if CLOUD
        // CLOUD: there is no way in. "Application Object Metadata" is OnPrem-scoped and no
        // platform API hands AL the source of a published object on SaaS, so every object reads
        // as "no metadata row" — exactly the state a standard object with nothing harvestable
        // already produces on premise. The caller negative-caches it and the call resolves as
        // ALI961 (no such procedure), with NoSourceReason() explaining why in the message.
        SourceByObject.Set(ObjKey, '');
        exit(false);
#else
        case ObjType of
            "ALI Object Type"::Table.AsInteger():
                AppObj.SetRange("Object Type", AppObj."Object Type"::Table);
            "ALI Object Type"::Codeunit.AsInteger():
                AppObj.SetRange("Object Type", AppObj."Object Type"::Codeunit);
            "ALI Object Type"::"TableExtension".AsInteger():
                AppObj.SetRange("Object Type", AppObj."Object Type"::"TableExtension");
            else
                exit(false);
        end;
        AppObj.SetRange("Object ID", ObjId);
        if AppObj.FindFirst() then begin
            Source := MetaPage.GetALObjectProceduresCode(AppObj);
            AppIdByObject.Set(ObjKey, AppIdOfPackage(AppObj."Package ID"));
        end;
        if Source.Trim() = '' then
            Source := '';
        SourceByObject.Set(ObjKey, Source);      // '' caches the miss too — do not re-read
        exit(Source <> '');
#endif
    end;

    // Up to three DISTINCT parse messages, each with the harvested line and that line's text.
    // A bare count says "something is wrong" and nothing else; the whole reason the individual
    // diagnostics were collapsed is that they repeat the same few causes hundreds of times, so
    // the distinct ones are exactly the information the count throws away. Distinct by message,
    // not by position — one unsupported construct appearing in forty procedures is ONE cause.
    local procedure ParseErrorSample(var ObjDiags: Codeunit "ALI Diag Bag"; ParseMark: Integer; Source: Text): Text
    var
        i: Integer;
        Lines: List of [Text];
        Seen: List of [Text];
        Msg: Text;
        Sb: TextBuilder;
    begin
        Lines := Source.Split(NewLineChar());
        for i := ParseMark + 1 to ObjDiags.Count() do begin
            Msg := ObjDiags.GetMessage(i);
            if not Seen.Contains(Msg) then begin
                Seen.Add(Msg);
                if Sb.Length() > 0 then
                    Sb.Append('; ');
                Sb.Append(StrSubstNo('%1 %2 (harvested line %3)%4', ObjDiags.GetCode(i), Msg, ObjDiags.GetLine(i), QuotedLine(Lines, ObjDiags.GetLine(i))));
                if Seen.Count() >= 3 then
                    break;
            end;
        end;
        if Sb.Length() = 0 then
            exit('');
        exit('Causes: ' + Sb.ToText());
    end;

    // Could this harvested source declare ProcName? Both spellings AL allows for the name are
    // accepted; anything else is not a declaration of it. See the call site for why a false
    // POSITIVE is harmless and a false negative would not be.
    local procedure SourceDeclaresProc(Source: Text; ProcName: Text): Boolean
    var
        Lowered: Text;
        Wanted: Text;
    begin
        Lowered := Source.ToLower();
        Wanted := ProcName.ToLower();
        exit(Lowered.Contains('procedure ' + Wanted) or Lowered.Contains('procedure "' + Wanted));
    end;

    // Object ids of every tableextension of TableId, ascending, or an empty list. The link is
    // AllObjWithCaption."Object Subtype", which for an extension object holds the BASE object's
    // id — nothing on "Application Object Metadata" carries it, so that scan is the only way in.
    // Ascending order is what makes "first extension that declares the name wins" reproducible.
    //
    // Public because the editor's completion list has to walk exactly the same set: a procedure
    // the compiler resolves but the dropdown does not offer reads as a missing feature. Sharing
    // this also shares the session cache, so the two never disagree and the scan is paid once.
    procedure ExtensionsOfTable(TableId: Integer) ExtIds: List of [Integer]
    var
        ExtObj: Record AllObjWithCaption;
        ExtId: Integer;
    begin
        if ExtIdsByTable.Get(TableId, ExtIds) then
            exit(ExtIds);

        ExtObj.SetCurrentKey("Object Type", "Object ID");
        ExtObj.SetRange("Object Type", ExtObj."Object Type"::"TableExtension");
        ExtObj.SetRange("Object Subtype", Format(TableId));
        if ExtObj.FindSet() then
            repeat
                ExtIds.Add(ExtObj."Object ID");
            until ExtObj.Next() = 0;

        foreach ExtId in ExtIds do
            BaseTableByExt.Set(ExtId, TableId);
        ExtIdsByTable.Set(TableId, ExtIds);              // an empty list caches the miss too
        exit(ExtIds);
    end;

    // The table a tableextension extends. Normally already known — ExtensionsOfTable is what
    // produced the id in the first place — but resolved on its own rather than trusted, because
    // getting it wrong would bind the unit against the wrong table's fields.
    local procedure BaseTableOf(ExtId: Integer) TableId: Integer
    var
        ExtObj: Record AllObjWithCaption;
    begin
        if BaseTableByExt.Get(ExtId, TableId) then
            exit(TableId);
        if ExtObj.Get(ExtObj."Object Type"::"TableExtension", ExtId) then
            Evaluate(TableId, ExtObj."Object Subtype");
        BaseTableByExt.Set(ExtId, TableId);
        exit(TableId);
    end;

#if not CLOUD
    local procedure AppIdOfPackage(PackageId: Guid) AppId: Guid
    var
        InstalledApp: Record "NAV App Installed App";
    begin
        if IsNullGuid(PackageId) then
            exit;
        InstalledApp.SetRange("Package ID", PackageId);
        if InstalledApp.FindFirst() then
            AppId := InstalledApp."App ID";
    end;

    // Project-level preprocessor symbols of the extension the object belongs to (empty when the
    // object has none configured — the common case).
    local procedure PreprocSymbolsOf(ObjType: Integer; ObjId: Integer) Result: List of [Text]
    var
        PreprocSymbol: Record "ALI Preproc Symbol";
        AppId: Guid;
    begin
        if not AppIdByObject.Get(KeyOfObject(ObjType, ObjId), AppId) then
            exit;
        if SymbolsByApp.Get(AppId, Result) then
            exit;
        Result := PreprocSymbol.SymbolsOf(AppId);
        SymbolsByApp.Set(AppId, Result);
    end;
#endif

    /// <summary>
    /// Why NO object has readable source in this build, as a sentence to append to a diagnostic,
    /// or '' when reading source is possible at all. On Cloud a call into an existing object can
    /// only ever fail, and "table 18 has no procedure of that name" would send the reader hunting
    /// for a typo that is not there — so the real cause is named instead.
    /// </summary>
    procedure NoSourceReason(): Text
    begin
#if CLOUD
        exit(' Calls into existing published objects are not available in this build: a cloud (SaaS) installation cannot read the AL source of a published object.');
#else
        exit('');
#endif
    end;

    // 'table 51018' / 'codeunit 51016' — diagnostics name the object the way the user wrote it.
    // An extension names its base table too: the reader asked about `Cust.Foo()` and has no
    // reason to know which of the table's extensions the procedure turned out to live in.
    local procedure ObjectLabel(ObjType: Integer; ObjId: Integer): Text
    begin
        if ObjType = "ALI Object Type"::Codeunit.AsInteger() then
            exit(StrSubstNo('codeunit %1', ObjId));
        if ObjType = "ALI Object Type"::"TableExtension".AsInteger() then
            exit(StrSubstNo('tableextension %1 (extends table %2)', ObjId, BaseTableOf(ObjId)));
        exit(StrSubstNo('table %1', ObjId));
    end;

    // One integer key space across object types, so a table and a codeunit sharing an id never
    // collide: ObjType is an "ALI Object Type" ordinal (1 Codeunit, 2 Page, 3 Table,
    // 4 TableExtension).
    local procedure KeyOfObject(ObjType: Integer; ObjId: Integer): Integer
    begin
        exit(ObjType * 1000000 + ObjId);
    end;

    local procedure KeyOfProc(ObjType: Integer; ObjId: Integer; ProcName: Text): Text
    begin
        exit(StrSubstNo('%1|%2', KeyOfObject(ObjType, ObjId), UpperCase(ProcName)));
    end;

    local procedure MaxHarvestDepth(): Integer
    begin
        exit(16);
    end;
}
