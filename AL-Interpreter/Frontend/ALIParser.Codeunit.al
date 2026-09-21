// ALI Parser — declarations + statements + error recovery (§5.2, §5.3, §5.4, §5.5).
// Recursive descent over the token table producing the flat AST. Expressions are
// delegated to "ALI Parser Expr" (Pratt). State (cursor + depth) is shared via
// "ALI Parse Ctx"; the token/AST/diag stores are threaded by var.
//
// HARD REQUIREMENTS honoured here:
//   - if/else attaches by HasSemicolon, NOT dangling-else (§5.4). ParseIf transcribed
//     from LanguageParser.ParseIf exactly.
//   - statement lists: ";" SEPARATES, last one optional; a missing separator reports
//     ERR_SemicolonExpected on the following statement (§5.4 rule 4).
//   - orphaned else is its own node + ERR_OrphanedElseStatement (§5.4 rule 3).
//   - `..` is positional (case-labels / in-lists) — never a climbing operator (§5.2).
//   - never stop at first error: missing-token insertion + panic-mode sync (§5.2).
//   - depth guard increments on STATEMENT recursion too (§5.4) — nested if is the
//     primary stack-depth driver.
codeunit 51108 "ALI Parser"
{
    Access = Public;
    SingleInstance = false;

    var
        Expr: Codeunit "ALI Parser Expr";

    // ===== Public entry points (§5.2 API) =====

    // Full compilation unit. v1 accepts three forms (§1.1); v1 parser handles the
    // statement-block and procedure-list forms directly, and a codeunit shell via
    // ParseCodeunitShell. Returns the CompilationUnit root node index.
    procedure ParseCompilationUnit(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Ctx: Codeunit "ALI Parse Ctx";
        FormOrd: Integer;
        K: Integer;
        Kids: List of [Integer];
    begin
        Ctx.Init(Tokens);
        K := Ctx.CurKind();
        // `case true of` (valid AL switch idiom) so the named Kind*() helpers stay readable —
        // AL forbids non-constant case LABELS, but guards on the `true` selector are fine.
        case true of
            (K = KindCodeunit()):
                begin
                    FormOrd := 2;  // CodeunitShell
                    ParseCodeunitShell(Ctx, Tokens, Ast, Diags, Kids);
                end;
            // `[` can never open a statement, so a leading attribute (`[TryFunction] procedure ..`)
            // is unambiguously the procedure-list form.
            (K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()) or (K = KindTrigger()) or (K = KindOpenBracket()):
                begin
                    FormOrd := 1;  // ProcList
                    ParseProcListBody(Ctx, Tokens, Ast, Diags, Kids);
                end;
            (K = KindVar()):
                FormOrd := ParseVarPrefixedBody(Ctx, Tokens, Ast, Diags, Kids);
            else begin
                FormOrd := 0;      // StmtBlock (bare statement list wrapped in synthetic OnRun)
                // Early input-format detection: a source opening with an OBJECT declaration
                // other than the tolerated codeunit shell (table/page/report/... /extension
                // objects) can never be a script — one clear diagnostic instead of a cascade
                // of bogus statement errors.
                if IsObjectDeclStart(Ctx, Tokens) then
                    ReportObjectDeclInput(Ctx, Tokens, Diags)
                else
                    ParseTopLevelStatements(Ctx, Tokens, Ast, Diags, Kids);
            end;
        end;
        exit(Ast.AddNode(NodeCompilationUnit(), 1, Kids, FormOrd));
    end;

    // Statement-block form entry (used directly by tests).
    procedure ParseStatements(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Ctx: Codeunit "ALI Parse Ctx";
        Kids: List of [Integer];
    begin
        Ctx.Init(Tokens);
        ParseTopLevelStatements(Ctx, Tokens, Ast, Diags, Kids);
        exit(Ast.AddNode(NodeCompilationUnit(), 1, Kids, 0));
    end;

    // Parse a single expression (test entry, exercises the Pratt parser standalone).
    procedure ParseExpressionEntry(var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Ctx: Codeunit "ALI Parse Ctx";
    begin
        Ctx.Init(Tokens);
        exit(Expr.Parse(Ctx, Tokens, Ast, Diags));
    end;

    // ===== Compilation-unit bodies =====

    local procedure ParseTopLevelStatements(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer])
    begin
        ParseStatementListInto(Ctx, Tokens, Ast, Diags, Kids, KindEof());
    end;

    // ===== Early input-format detection (§ verbose) =====

    // True when the source opens like an object declaration the interpreter cannot run:
    // either a dedicated object keyword (table/page/report/query/xmlport/dotnet), or an
    // identifier spelling an object type (tableextension, enum, interface, ...) followed by
    // an object id/name. `codeunit` is NOT rejected — the codeunit-shell form is supported.
    local procedure IsObjectDeclStart(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"): Boolean
    var
        K: Integer;
        NextK: Integer;
    begin
        K := Ctx.CurKind();
        if IsObjectKeywordKind(K) then
            exit(true);
        if K <> KindIdentifier() then
            exit(false);
        if not IsObjectTypeWord(Tokens.GetIdentText(Ctx.CurIndex()).ToLower()) then
            exit(false);
        // object id (page 50100 ...), quoted/plain object name — never a valid statement here
        NextK := Ctx.PeekKind(1);
        exit((NextK = KindInt32Literal()) or (NextK = KindIdentifier()) or (NextK = KindStringLiteral()));
    end;

    // TableKeyword..DotNetKeyword — frozen ordinals 139..144 in "ALI TokenKind".
    local procedure IsObjectKeywordKind(K: Integer): Boolean
    begin
        exit(K in [139 .. 144]);
    end;

    // Reserved object-type keywords usable as a VARIABLE type (`x: Codeunit "Y"`): codeunit
    // (138) plus the object-declaration range table/page/report/query/xmlport/dotnet (139..144).
    local procedure IsObjectTypeKeyword(K: Integer): Boolean
    begin
        exit((K = 138) or IsObjectKeywordKind(K));
    end;

    local procedure IsDeclarationKeyword(K: Integer): Boolean
    begin
        exit((K >= 130) and (K <= 145));   // ProcedureKeyword..EventKeyword (§ ALI TokenKind)
    end;

    // Object-type spellings the lexer does NOT reserve as keywords.
    local procedure IsObjectTypeWord(Word: Text): Boolean
    begin
        exit(Word in ['tableextension', 'pageextension', 'pagecustomization', 'reportextension',
                      'enum', 'enumextension', 'interface', 'controladdin', 'permissionset',
                      'permissionsetextension', 'entitlement', 'profile', 'namespace']);
    end;

    local procedure ReportObjectDeclInput(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        Idx: Integer;
        Word: Text;
    begin
        Idx := Ctx.CurIndex();
        if Ctx.CurKind() = KindIdentifier() then
            Word := Tokens.GetIdentText(Idx)
        else
            Word := ObjectKeywordSpelling(Ctx.CurKind());
        Diags.AddError('ALI949',
            StrSubstNo('Source starts with a ''%1'' object declaration — the interpreter runs script code only. Provide a ''var'' section, ''procedure'' declarations, a ''begin .. end'' block or bare statements (a plain ''codeunit ... { }'' shell is also accepted)', Word),
            Tokens.GetStartPos(Idx), Tokens.GetLength(Idx));
    end;

    local procedure ObjectKeywordSpelling(K: Integer): Text
    begin
        case K of
            139:
                exit('table');
            140:
                exit('page');
            141:
                exit('report');
            142:
                exit('query');
            143:
                exit('xmlport');
            144:
                exit('dotnet');
        end;
        exit('object');
    end;

    // A compilation unit that opens with `var` is ambiguous until we see what follows the
    // var section(s): a procedure declaration means form 1 (ProcList); anything else (e.g.
    // `begin`) means form 0 (StmtBlock) with a leading module-scope var section — legal for
    // `var s: Text; begin ... end;`-shaped test sources. Consume the var section(s) once,
    // then dispatch on the next token so neither branch re-parses them.
    local procedure ParseVarPrefixedBody(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer]): Integer
    var
        K: Integer;
    begin
        while Ctx.CurKind() = KindVar() do
            Kids.Add(ParseVarSection(Ctx, Tokens, Ast, Diags, 0));  // scope 0 = module

        K := Ctx.CurKind();
        if (K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()) or (K = KindTrigger()) or (K = KindOpenBracket()) then begin
            ParseProcDeclLoop(Ctx, Tokens, Ast, Diags, Kids);
            exit(1);
        end;
        ParseTopLevelStatements(Ctx, Tokens, Ast, Diags, Kids);
        exit(0);
    end;

    local procedure ParseProcListBody(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer])
    begin
        // Optional module-level var section(s), then procedure declarations. AL allows
        // multiple separate `var` blocks at module scope, so this loops, not a single `if`.
        while Ctx.CurKind() = KindVar() do
            Kids.Add(ParseVarSection(Ctx, Tokens, Ast, Diags, 0));  // scope 0 = module
        ParseProcDeclLoop(Ctx, Tokens, Ast, Diags, Kids);
    end;

    local procedure ParseProcDeclLoop(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer])
    var
        K: Integer;
    begin
        while not Ctx.AtEof() do begin
            K := Ctx.CurKind();
            if (K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()) or IsProcAttributeStart(Ctx) then
                Kids.Add(ParseProcDecl(Ctx, Tokens, Ast, Diags))
            else
                // `trigger OnRun()` at script level: the script's entry point (see "ALI Binder"
                // RequireOnRun). Same ProcDecl shape as in a codeunit shell.
                if K = KindTrigger() then
                    Kids.Add(ParseTrigger(Ctx, Tokens, Ast, Diags))
                else
                    // A module-scope `var` block does not have to come first: AL objects routinely
                    // put their global var section AFTER the last procedure (that is where the AL
                    // formatter leaves it), and pasting such a body into a script has to keep those
                    // globals. The binder classifies root children by kind, not by position, so a
                    // late section declares exactly what a leading one does.
                    if K = KindVar() then
                        Kids.Add(ParseVarSection(Ctx, Tokens, Ast, Diags, 0))
                    else begin
                        Diags.AddError('ALI911', 'Expected procedure declaration', Tokens.GetStartPos(Ctx.CurIndex()), 0);
                        SyncTopLevel(Ctx, Tokens);
                        if Ctx.AtEof() then
                            break;
                    end;
        end;
    end;

    // codeunit N Name { ... } — properties/attributes parsed-and-skipped; only var,
    // procedures and trigger OnRun are semantically kept (§1.1).
    local procedure ParseCodeunitShell(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer])
    var
        K: Integer;
    begin
        Ctx.Advance();                                    // 'codeunit'
        Ctx.Accept(KindInt32Literal());                 // object id (optional in our tolerant parse)
        Expr.Parse(Ctx, Tokens, Ast, Diags);                    // object name (identifier) — value discarded
        Ctx.Expect(Tokens, Diags, KindOpenBrace(), '{');
        while (not Ctx.AtEof()) and (Ctx.CurKind() <> KindCloseBrace()) do begin
            K := Ctx.CurKind();
            case true of
                (K = KindVar()):
                    Kids.Add(ParseVarSection(Ctx, Tokens, Ast, Diags, 0));
                // An attribute list directly above a procedure belongs to it (TryFunction is
                // recorded); any other bracket group is still skipped as a member below.
                (K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()) or IsProcAttributeStart(Ctx):
                    Kids.Add(ParseProcDecl(Ctx, Tokens, Ast, Diags));
                (K = KindTrigger()):
                    Kids.Add(ParseTrigger(Ctx, Tokens, Ast, Diags));
                else
                    // property / attribute / anything else — skip to its terminator.
                    SkipMember(Ctx, Tokens);
            end;
        end;
        Ctx.Expect(Tokens, Diags, KindCloseBrace(), '}');
    end;

    // trigger OnRun() [[RetName] : RetType] [var locals] begin ... end;  — modelled as a ProcDecl,
    // same shape as a procedure. The return value is an ALI extension (native AL triggers have
    // none): a script's `trigger OnRun(): Integer` reports its exit value like an entry procedure.
    local procedure ParseTrigger(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        NameTok: Integer;
    begin
        Ctx.Advance();                                    // 'trigger'
        NameTok := Ctx.Expect(Tokens, Diags, KindIdentifier(), 'trigger name');
        exit(ParseProcTail(Ctx, Tokens, Ast, Diags, NameTok));
    end;

    // ===== Declarations =====

    // [attributes] [local|internal] procedure Name(params) [[RetName] : RetType] [var locals] begin..end [;]
    local procedure ParseProcDecl(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        IsTry: Boolean;
        NameTok: Integer;
        ProcNode: Integer;
    begin
        // optional attribute list — only [TryFunction] means anything to the interpreter
        IsTry := false;
        if Ctx.CurKind() = KindOpenBracket() then
            IsTry := ParseProcAttributes(Ctx, Tokens, Diags);
        // optional access modifier
        if (Ctx.CurKind() = KindLocal()) or (Ctx.CurKind() = KindInternal()) then
            Ctx.Advance();
        Ctx.Expect(Tokens, Diags, KindProcedure(), 'procedure');
        NameTok := Ctx.Expect(Tokens, Diags, KindIdentifier(), 'procedure name');
        ProcNode := ParseProcTail(Ctx, Tokens, Ast, Diags, NameTok);
        if IsTry then
            Ast.SetTryFunction(ProcNode);
        exit(ProcNode);
    end;

    // Consume one or more `[Name]` / `[Name(args)]` groups above a procedure. Returns true when
    // one of them is TryFunction (case-insensitive, like every AL identifier). Every other
    // attribute (EventSubscriber, Scope, Obsolete, NonDebuggable, ...) is parsed and ignored.
    local procedure ParseProcAttributes(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag"): Boolean
    var
        IsTry: Boolean;
    begin
        IsTry := false;
        while Ctx.Accept(KindOpenBracket()) do begin
            if Ctx.CurKind() = KindIdentifier() then
                if Tokens.GetIdentText(Ctx.CurIndex()).ToLower() = 'tryfunction' then
                    IsTry := true;
            SkipBracketedGroup(Ctx, Tokens, Diags);
        end;
        exit(IsTry);
    end;

    // True when the cursor sits on an attribute list (one or more balanced `[...]` groups) that
    // is directly followed by a procedure declaration. Pure lookahead, consumes nothing: a var
    // section must not swallow a procedure's attribute as a declaration attribute, and the
    // codeunit shell must not skip it as a property.
    local procedure IsProcAttributeStart(var Ctx: Codeunit "ALI Parse Ctx"): Boolean
    var
        Depth: Integer;
        K: Integer;
        Offset: Integer;
    begin
        if Ctx.CurKind() <> KindOpenBracket() then
            exit(false);
        Offset := 0;
        while Ctx.PeekKind(Offset) = KindOpenBracket() do begin
            Depth := 1;
            Offset += 1;
            while Depth > 0 do begin
                K := Ctx.PeekKind(Offset);
                if K = KindEof() then
                    exit(false);
                if K = KindOpenBracket() then
                    Depth += 1
                else
                    if K = KindCloseBracket() then
                        Depth -= 1;
                Offset += 1;
            end;
        end;
        K := Ctx.PeekKind(Offset);
        exit((K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()));
    end;

    // Everything after a procedure's / trigger's name: (params) [[RetName] : RetType] [var locals]
    // begin..end [;] — the ProcDecl node.
    local procedure ParseProcTail(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; NameTok: Integer): Integer
    var
        RetNameTok: Integer;
        Kids: List of [Integer];
    begin
        Kids.Add(ParseParamList(Ctx, Tokens, Ast, Diags));

        // optional return value '[Name] : Type' — an identifier here can only be a named
        // return value (next tokens are otherwise var/begin, both keywords).
        RetNameTok := 0;
        if Ctx.CurKind() = KindIdentifier() then begin
            RetNameTok := Ctx.Advance();
            Ctx.Expect(Tokens, Diags, KindColon(), ':');
            Kids.Add(ParseTypeRef(Ctx, Tokens, Ast, Diags));
        end else
            if Ctx.Accept(KindColon()) then
                Kids.Add(ParseTypeRef(Ctx, Tokens, Ast, Diags))
            else
                Kids.Add(Ast.MissingNode());

        // optional local var section
        if Ctx.CurKind() = KindVar() then
            Kids.Add(ParseVarSection(Ctx, Tokens, Ast, Diags, 1))  // scope 1 = local
        else
            Kids.Add(Ast.MissingNode());

        Kids.Add(ParseBlock(Ctx, Tokens, Ast, Diags));
        // child [4]: named return value as a leaf VarDecl (ExtraInt = NameId) or Missing.
        // Type is NOT duplicated here — the binder reuses the proc's resolved return type.
        if RetNameTok <> 0 then
            Kids.Add(Ast.AddLeaf(NodeVarDecl(), RetNameTok, Tokens.GetIdentId(RetNameTok)))
        else
            Kids.Add(Ast.MissingNode());
        Ctx.Accept(KindSemicolon());                    // trailing ';' after proc
        exit(Ast.AddNode(NodeProcDecl(), NameTok, Kids, Tokens.GetIdentId(NameTok)));
    end;

    // (p1: T1; var p2: T2; ...) — empty parens allowed. Param children per §5.5.
    local procedure ParseParamList(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        OpenTok: Integer;
        Params: List of [Integer];
    begin
        OpenTok := Ctx.CurIndex();
        if not Ctx.Accept(KindOpenParen()) then
            // no parameter list at all -> empty param list node
            exit(Ast.AddNode(NodeParamList(), OpenTok, Params, 0));
        if Ctx.CurKind() <> KindCloseParen() then begin
            Params.Add(ParseParam(Ctx, Tokens, Ast, Diags));
            while Ctx.Accept(KindSemicolon()) do
                Params.Add(ParseParam(Ctx, Tokens, Ast, Diags));
        end;
        Ctx.Expect(Tokens, Diags, KindCloseParen(), ')');
        exit(Ast.AddNode(NodeParamList(), OpenTok, Params, 0));
    end;

    // [var] Name: TypeRef   — ExtraInt = NameId; bit0 (Extra beyond NameId) tracked via
    // a dedicated var-param flag folded into ExtraInt sign is fragile, so we store NameId
    // in ExtraInt and the var-flag in a child-free convention: emit a leading MissingNode?
    // Simpler and faithful to §5.5 ("NameId; bit0 = var-param"): pack (NameId<<1)|varbit.
    local procedure ParseParam(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        IsVar: Boolean;
        NameTok: Integer;
        Payload: Integer;
        Kids: List of [Integer];
    begin
        IsVar := Ctx.Accept(KindVar());
        NameTok := Ctx.Expect(Tokens, Diags, KindIdentifier(), 'parameter name');
        Ctx.Expect(Tokens, Diags, KindColon(), ':');
        Kids.Add(ParseTypeRef(Ctx, Tokens, Ast, Diags));
        Payload := Tokens.GetIdentId(NameTok) * 2;
        if IsVar then
            Payload += 1;                                       // bit0 = var-param (§5.5)
        exit(Ast.AddNode(NodeParam(), NameTok, Kids, Payload));
    end;

    // var Name[, Name2]: TypeRef [:= init]; ... — a var section runs until a non-decl
    // start (begin / procedure / } / EOF). scope: 0 module, 1 local.
    local procedure ParseVarSection(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; Scope: Integer): Integer
    var
        VarTok: Integer;
        Decls: List of [Integer];
    begin
        VarTok := Ctx.Advance();                          // 'var'
        // A declaration may carry an ATTRIBUTE — `[SecurityFiltering(SecurityFilter::Filtered)]`
        // above a Record local is ordinary base-app AL. It means nothing to the interpreter, but
        // it has to be CONSUMED: an unread '[' is not an identifier, so it used to end the var
        // section early and leave the rest of the declarations to be parsed as statements.
        // ... but an attribute list followed by `procedure` is the NEXT procedure's (`[TryFunction]`
        // right after a global var block): it ends the section instead of being eaten here.
        while (Ctx.CurKind() = KindIdentifier()) or ((Ctx.CurKind() = KindOpenBracket()) and not IsProcAttributeStart(Ctx)) do
            if Ctx.Accept(KindOpenBracket()) then
                SkipBracketedGroup(Ctx, Tokens, Diags)
            else
                ParseVarDecls(Ctx, Tokens, Ast, Diags, Decls);
        exit(Ast.AddNode(NodeVarSection(), VarTok, Decls, Scope));
    end;

    // One declaration line (possibly comma-grouped names sharing a type) -> one VarDecl
    // per name (init only allowed on a single-name line; grouped names share type, no init).
    local procedure ParseVarDecls(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Decls: List of [Integer])
    var
        InitNode: Integer;
        NameTok: Integer;
        TypeNode: Integer;
        Kids: List of [Integer];
        NameToks: List of [Integer];
    begin
        NameToks.Add(Ctx.Advance());                      // first name
        while Ctx.Accept(KindComma()) do
            NameToks.Add(Ctx.Expect(Tokens, Diags, KindIdentifier(), 'variable name'));
        Ctx.Expect(Tokens, Diags, KindColon(), ':');
        TypeNode := ParseTypeRef(Ctx, Tokens, Ast, Diags);

        InitNode := Ast.MissingNode();
        if (NameToks.Count() = 1) and Ctx.Accept(KindAssign()) then
            InitNode := Expr.Parse(Ctx, Tokens, Ast, Diags);

        Ctx.Accept(KindSemicolon());

        foreach NameTok in NameToks do begin
            Clear(Kids);
            Kids.Add(TypeNode);
            Kids.Add(InitNode);
            Decls.Add(Ast.AddNode(NodeVarDecl(), NameTok, Kids, Tokens.GetIdentId(NameTok)));
        end;
    end;

    // A type reference: Name, Name[len], array[N] of Name, Text[n], Code[n], Record Name.
    // v1 keeps it structurally simple — the whole type expression is captured with the
    // leading type-name token as anchor; length/element details are re-derived by the
    // binder from the token span. We consume tokens greedily but stop at ; := , ) begin.
    local procedure ParseTypeRef(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        IsTemp: Boolean;
        AnchorTok: Integer;
        K: Integer;
    begin
        AnchorTok := Ctx.CurIndex();
        // array[N] of ElemType
        if Ctx.CurKind() = KindArray() then begin
            Ctx.Advance();                                // 'array'
            if Ctx.Accept(KindOpenBracket()) then
                SkipBracketedGroup(Ctx, Tokens, Diags);
            Ctx.Accept(KindOf());
        end;
        // type name (identifier or a type keyword lexed as identifier)
        if not Ctx.Accept(KindIdentifier()) then
            // Object-reference type: `Codeunit "X"`, `Page "Y"`, `Report "Z"`… The lexer RESERVES
            // these words, so they never arrive as identifiers and the line above cannot consume
            // them — which used to leave the whole `Codeunit "X"` in the stream and desync every
            // token after it. Consume the keyword here and let the subtype-name step below take
            // the name; the binder decides which of these object kinds it can actually represent
            // (M11 phase C1: Codeunit yes, the rest still ALI927/ALI924).
            if IsObjectTypeKeyword(Ctx.CurKind()) then
                Ctx.Advance();
        // optional [len] for Text[n]/Code[n], or record subtype token
        if Ctx.Accept(KindOpenBracket()) then
            SkipBracketedGroup(Ctx, Tokens, Diags);
        // `List of [T]` / `Dictionary of [K, V]` element clause — consumed here so the
        // BINDER can reject the type with a precise §19.1 diagnostic instead of the parser
        // choking on the trailing `of [...]` (collect-all type verification, M5). The
        // element/key/value type name inside can itself carry a [n] length suffix
        // (List of [Text[50]]) — SkipBracketedGroup tracks nesting depth so the FIRST ']'
        // (closing Text[50]'s own bracket) does not get mistaken for the outer close.
        if Ctx.CurKind() = KindOf() then begin
            Ctx.Advance();                                // 'of'
            if Ctx.Accept(KindOpenBracket()) then
                SkipBracketedGroup(Ctx, Tokens, Diags);
        end;
        // record/table subtype name after the type keyword (e.g. Record Customer), OR the
        // first member of an inline option string (Option A,B,"C c") — same token shape
        // (identifier or quoted string), disambiguated later by the binder from the anchor.
        K := Ctx.CurKind();
        if (K = KindIdentifier()) or (K = KindStringLiteral()) then
            Ctx.Advance()
        else
            // Unquoted keyword as FIRST option member (`Option Table,Page`) — valid natively.
            // Guarded on the Option type name so `Record X temporary` keeps its flag.
            if IsDeclarationKeyword(K) and (UpperCase(Tokens.GetIdentText(Ctx.CurIndex() - 1)) = 'OPTION') then
                Ctx.Advance();
        // Greedy comma loop: consumes the REST of an inline option member list (`, [name]`
        // repeated). Structure-only (§ v1 philosophy) — the binder re-derives the actual
        // member names from the token span; this loop's only job is re-syncing the token
        // stream so trailing members don't get parsed as garbage statements. Safe for every
        // OTHER type here: ParseTypeRef only runs after the ':' in a var declaration, where a
        // following ',' can only belong to a NEXT option member (grouped var names and proc
        // params separate BEFORE the colon; `of [...]` commas are already consumed above).
        // A missing identifier between two commas (`Option ,One,Two`) is a valid empty slot
        // (§ recurring-idiom "gapped enum ordinals" note) — just skip past the comma.
        while Ctx.CurKind() = KindComma() do begin
            Ctx.Advance();                                // ','
            K := Ctx.CurKind();
            if (K = KindIdentifier()) or (K = KindStringLiteral()) or IsDeclarationKeyword(K) then   // keyword member: `Option " ",Table,Page`
                Ctx.Advance();
            // Label property tail: `Label 'text', Comment = '...', Locked = true, MaxLength = n`.
            // Options never carry `Prop = value`, so consuming a trailing `= <value>` here is
            // safe for every other type. ponytail: props are parsed and ignored (Comment/Locked
            // have no runtime effect; MaxLength truncation is deferred — labels are folded as-is).
            if Ctx.CurKind() = 50 then begin              // EqualsToken


                Ctx.Advance();                            // '='
                Ctx.Advance();                            // value (string / true / false / int)
            end;
        end;
        IsTemp := Ctx.Accept(KindTemporary());          // 'temporary' record flag
        exit(Ast.AddLeaf(NodeTypeRef(), AnchorTok, IsTempFlag(IsTemp)));
    end;

    // Skip a bracketed token group, tracking nesting DEPTH — a `[...]` clause can itself
    // contain a nested `[...]` (e.g. `List of [Text[50]]` nests Text[50]'s own length
    // bracket inside the outer List element clause; a depth-blind scan that stops at the
    // FIRST ']' would consume Text[50]'s close instead of the outer one, leaving the real
    // outer ']' dangling in the stream and desyncing every token after it). Caller has
    // ALREADY consumed the OPENING '['.
    local procedure SkipBracketedGroup(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Diags: Codeunit "ALI Diag Bag")
    var
        Depth: Integer;
    begin
        Depth := 1;
        while (not Ctx.AtEof()) and (Depth > 0) do begin
            if Ctx.CurKind() = KindOpenBracket() then
                Depth += 1
            else
                if Ctx.CurKind() = KindCloseBracket() then
                    Depth -= 1;
            if Depth > 0 then
                Ctx.Advance();
        end;
        Ctx.Expect(Tokens, Diags, KindCloseBracket(), ']');
    end;

    local procedure IsTempFlag(IsTemp: Boolean): Integer
    begin
        if IsTemp then
            exit(1);
        exit(0);
    end;

    // ===== Statements =====

    // Parse exactly ONE statement (the recursion point for if/while/for bodies, §5.4).
    // Sets the HasSemicolon flag on the built node before returning (§5.4 rule 1).
    procedure ParseStatement(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        K: Integer;
        Node: Integer;
    begin
        if not Ctx.EnterDepth(Tokens, Diags) then begin
            // Depth guard tripped — synthesize an error statement and unwind (§5.4).
            Node := Ast.AddLeaf(NodeErrorStatement(), Ctx.CurIndex(), 0);
            exit(Node);
        end;

        // HasSemicolon = "my last terminal token is ';'" (§5.4). Each parse function below
        // owns its own terminating-';' policy so the flag is faithful:
        //   - compound if/while/for INHERIT the flag from their body/branch (no own ';');
        //   - begin..end / case..end / repeat..until CONSUME their own optional trailing ';';
        //   - simple statements CONSUME an optional trailing ';'.
        // This is what makes `if C then Foo();` carry HasSemicolon = true (the ';' belongs to
        // the then-branch, which is the if's last terminal) — no spurious "; expected".
        // `case true of` guards (AL forbids non-constant case labels; guards on `true` are ok).
        K := Ctx.CurKind();
        case true of
            (K = KindIf()):
                Node := ParseIf(Ctx, Tokens, Ast, Diags);           // inherits from branch
            (K = KindWhile()):
                Node := ParseWhile(Ctx, Tokens, Ast, Diags);        // inherits from body
            (K = KindFor()):
                Node := ParseFor(Ctx, Tokens, Ast, Diags);          // inherits from body
            (K = KindForEach()):
                Node := ParseForEach(Ctx, Tokens, Ast, Diags);      // inherits from body
            (K = KindRepeat()):
                Node := ParseRepeat(Ctx, Tokens, Ast, Diags);       // eats own trailing ';'
            (K = KindCase()):
                Node := ParseCase(Ctx, Tokens, Ast, Diags);         // eats own trailing ';'
            (K = KindBegin()):
                Node := ParseBlock(Ctx, Tokens, Ast, Diags);        // eats own trailing ';'
            (K = KindExit()):
                begin
                    Node := ParseExit(Ctx, Tokens, Ast, Diags);
                    EatTrailingSemi(Ctx, Tokens, Ast, Node);
                end;
            (K = KindBreak()):
                begin
                    Node := Ast.AddLeaf(NodeBreakStatement(), Ctx.Advance(), 0);
                    EatTrailingSemi(Ctx, Tokens, Ast, Node);
                end;
            (K = KindElse()):
                // an else with no open if wanting it — dedicated orphaned-else path (§5.4 rule 3)
                Node := ParseOrphanedElse(Ctx, Tokens, Ast, Diags); // inherits from inner stmt
            (K = KindSemicolon()):
                // empty statement: the ';' IS this statement's terminal -> HasSemicolon true.
                begin
                    Node := Ast.AddLeaf(NodeEmptyStatement(), Ctx.Advance(), 0);
                    Ast.SetHasSemicolon(Node, true);
                end;
            (K = KindWith()):
                begin
                    Diags.AddError('ALI902', 'with statement is not supported', Tokens.GetStartPos(Ctx.CurIndex()), 0);
                    SyncStatement(Ctx, Tokens);
                    Node := Ast.AddLeaf(NodeErrorStatement(), Ctx.CurIndex(), 0);
                    Ast.SetHasSemicolon(Node, true);                // sync consumed a ';'
                end;
            else begin
                Node := ParseExprOrAssign(Ctx, Tokens, Ast, Diags);
                EatTrailingSemi(Ctx, Tokens, Ast, Node);
            end;
        end;

        Ctx.LeaveDepth();
        exit(Node);
    end;

    // Consume an optional trailing ';' and record HasSemicolon on the node (§5.4).
    local procedure EatTrailingSemi(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; Node: Integer)
    begin
        if Ctx.Accept(KindSemicolon()) then
            Ast.SetHasSemicolon(Node, true);
    end;

    // if C then Then [else Else] — EXACT transcription of LanguageParser.ParseIf (§5.4).
    local procedure ParseIf(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Cond: Integer;
        ElseStmt: Integer;
        HasElse: Integer;
        IfTok: Integer;
        Node: Integer;
        ThenStmt: Integer;
        Kids: List of [Integer];
    begin
        IfTok := Ctx.Advance();                           // 'if'
        Cond := Expr.Parse(Ctx, Tokens, Ast, Diags);
        Ctx.Expect(Tokens, Diags, KindThen(), 'then');

        if not Ctx.AtEof() then
            ThenStmt := ParseStatement(Ctx, Tokens, Ast, Diags)
        else
            ThenStmt := Ast.AddLeaf(NodeEmptyStatement(), Ctx.CurIndex(), 0);

        ElseStmt := Ast.MissingNode();
        HasElse := 0;
        // else attaches ONLY if the then-branch did NOT already terminate with ';' (§5.4).
        if (Ctx.CurKind() = KindElse()) and (not Ast.GetHasSemicolon(ThenStmt)) then begin
            Ctx.Advance();                                // 'else'
            ElseStmt := ParseStatement(Ctx, Tokens, Ast, Diags);
            HasElse := 1;
        end;

        Kids.Add(Cond);
        Kids.Add(ThenStmt);
        Kids.Add(ElseStmt);
        Node := Ast.AddNode(NodeIfStatement(), IfTok, Kids, HasElse);  // ExtraInt bit0 = has-else
        // HasSemicolon of the if = its last terminal = the last child's HasSemicolon (§5.4).
        if HasElse = 1 then
            Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(ElseStmt))
        else
            Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(ThenStmt));
        exit(Node);
    end;

    // An 'else' that no open if wants — ERR_OrphanedElseStatement (§5.4 rule 3). It is NOT
    // a panic skip: consume 'else' + one statement and wrap them.
    local procedure ParseOrphanedElse(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        ElseTok: Integer;
        Node: Integer;
        Stmt: Integer;
        Kids: List of [Integer];
    begin
        ElseTok := Ctx.Advance();                         // 'else'
        Diags.AddError('ALI903', 'Unexpected else (no matching if)', Tokens.GetStartPos(ElseTok), 0);
        Stmt := ParseStatement(Ctx, Tokens, Ast, Diags);
        Kids.Add(Stmt);
        Node := Ast.AddNode(NodeOrphanedElseStatement(), ElseTok, Kids, 0);
        Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(Stmt));   // inherit from inner statement
        exit(Node);
    end;

    local procedure ParseWhile(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        Node: Integer;
        WhileTok: Integer;
        Kids: List of [Integer];
    begin
        WhileTok := Ctx.Advance();                        // 'while'
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // condition
        Ctx.Expect(Tokens, Diags, KindDo(), 'do');
        Kids.Add(ParseStatement(Ctx, Tokens, Ast, Diags));      // body: single statement (§5.4 rule 5)
        Node := Ast.AddNode(NodeWhileStatement(), WhileTok, Kids, 0);
        Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(Kids.Get(2)));  // inherit body (§5.4)
        exit(Node);
    end;

    // for i := a to|downto b do body   (§5.3: end-value bound once — a lowering concern).
    local procedure ParseFor(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        DownToI: Integer;
        ForTok: Integer;
        Node: Integer;
        Kids: List of [Integer];
    begin
        ForTok := Ctx.Advance();                          // 'for'
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // loop var (an lvalue expr)
        Ctx.Expect(Tokens, Diags, KindAssign(), ':=');
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // init expr
        DownToI := 0;
        if Ctx.CurKind() = KindDownTo() then begin
            Ctx.Advance();
            DownToI := 1;
        end else
            Ctx.Expect(Tokens, Diags, KindTo(), 'to');
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // end expr
        Ctx.Expect(Tokens, Diags, KindDo(), 'do');
        Kids.Add(ParseStatement(Ctx, Tokens, Ast, Diags));      // body
        Node := Ast.AddNode(NodeForStatement(), ForTok, Kids, DownToI);  // ExtraInt bit0 = downto
        Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(Kids.Get(4)));   // inherit body (§5.4)
        exit(Node);
    end;

    // foreach x in Collection do body   (§5.5: [0]=loopVar, [1]=collection, [2]=body).
    local procedure ParseForEach(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        ForEachTok: Integer;
        Node: Integer;
        Kids: List of [Integer];
    begin
        ForEachTok := Ctx.Advance();                      // 'foreach'
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // loop var (an lvalue expr)
        Ctx.Expect(Tokens, Diags, KindIn(), 'in');
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // collection expr
        Ctx.Expect(Tokens, Diags, KindDo(), 'do');
        Kids.Add(ParseStatement(Ctx, Tokens, Ast, Diags));      // body
        Node := Ast.AddNode(NodeForEachStatement(), ForEachTok, Kids, 0);
        Ast.SetHasSemicolon(Node, Ast.GetHasSemicolon(Kids.Get(3)));   // inherit body (§5.4)
        exit(Node);
    end;

    // repeat stmt* until Cond   — stmt list + trailing until (§5.4 rule 5).
    local procedure ParseRepeat(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        BodyCount: Integer;
        Node: Integer;
        RepeatTok: Integer;
        Kids: List of [Integer];
    begin
        RepeatTok := Ctx.Advance();                       // 'repeat'
        ParseStatementListInto(Ctx, Tokens, Ast, Diags, Kids, KindUntil());
        BodyCount := Kids.Count();
        Ctx.Expect(Tokens, Diags, KindUntil(), 'until');
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // until cond = last child (§5.5)
        Node := Ast.AddNode(NodeRepeatStatement(), RepeatTok, Kids, BodyCount);
        EatTrailingSemi(Ctx, Tokens, Ast, Node);                // repeat..until; eats own ';'
        exit(Node);
    end;

    // case Selector of  caseLine* [else stmt*] end  (§5.5). Labels use `..` ranges and
    // comma lists POSITIONALLY (§5.2) — not via the Pratt infix.
    local procedure ParseCase(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        CaseTok: Integer;
        LineCount: Integer;
        Node: Integer;
        StartCursor: Integer;
        Kids: List of [Integer];
    begin
        CaseTok := Ctx.Advance();                         // 'case'
        Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));          // selector
        Ctx.Expect(Tokens, Diags, KindOf(), 'of');
        while (not Ctx.AtEof()) and (Ctx.CurKind() <> KindEnd()) and (Ctx.CurKind() <> KindElse()) do begin
            StartCursor := Ctx.CurIndex();
            Kids.Add(ParseCaseLine(Ctx, Tokens, Ast, Diags));
            LineCount += 1;
            // Guarantee forward progress: with the depth guard tripped, label + body can
            // both synthesize error nodes without consuming — force-advance like the
            // statement-list loop does, or this loop never reaches end/else/EOF.
            if Ctx.CurIndex() = StartCursor then
                Ctx.Advance();
        end;
        if Ctx.CurKind() = KindElse() then
            Kids.Add(ParseCaseElse(Ctx, Tokens, Ast, Diags))
        else
            Kids.Add(Ast.MissingNode());
        Ctx.Expect(Tokens, Diags, KindEnd(), 'end');
        Node := Ast.AddNode(NodeCaseStatement(), CaseTok, Kids, LineCount);
        EatTrailingSemi(Ctx, Tokens, Ast, Node);                // case..end; eats own ';'
        exit(Node);
    end;

    // label [, label | lo..hi ]* : stmt  — labels are values or ranges (§5.5 CaseLine).
    local procedure ParseCaseLine(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        AnchorTok: Integer;
        LabelCount: Integer;
        Kids: List of [Integer];
    begin
        AnchorTok := Ctx.CurIndex();
        Kids.Add(ParseCaseLabel(Ctx, Tokens, Ast, Diags));
        LabelCount += 1;
        while Ctx.Accept(KindComma()) do begin
            Kids.Add(ParseCaseLabel(Ctx, Tokens, Ast, Diags));
            LabelCount += 1;
        end;
        Ctx.Expect(Tokens, Diags, KindColon(), ':');
        Kids.Add(ParseStatement(Ctx, Tokens, Ast, Diags));      // body = last child (§5.5)
        exit(Ast.AddNode(NodeCaseLine(), AnchorTok, Kids, LabelCount));
    end;

    // A single case label: an expression, optionally `lo..hi` -> RangeExpr (positional §5.2).
    local procedure ParseCaseLabel(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        DotTok: Integer;
        Hi: Integer;
        Lo: Integer;
        Kids: List of [Integer];
    begin
        Lo := Expr.Parse(Ctx, Tokens, Ast, Diags);
        if Ctx.CurKind() = KindDotDot() then begin
            DotTok := Ctx.Advance();                      // '..'
            Hi := Expr.Parse(Ctx, Tokens, Ast, Diags);
            Kids.Add(Lo);
            Kids.Add(Hi);
            exit(Ast.AddNode(NodeRangeExpr(), DotTok, Kids, 0));
        end;
        exit(Lo);
    end;

    local procedure ParseCaseElse(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        ElseTok: Integer;
        Kids: List of [Integer];
    begin
        ElseTok := Ctx.Advance();                         // 'else'
        ParseStatementListInto(Ctx, Tokens, Ast, Diags, Kids, KindEnd());
        exit(Ast.AddNode(NodeCaseElse(), ElseTok, Kids, 0));
    end;

    // begin stmt* end [;]  — ends with 'end' then an optional trailing ';' (SemicolonOrNothing,
    // §5.4). So `begin..end;` has HasSemicolon true and `begin..end` false — that flag is what
    // drives if/else attachment (§5.4 table rows 3-4).
    local procedure ParseBlock(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        BeginTok: Integer;
        Node: Integer;
        Kids: List of [Integer];
    begin
        BeginTok := Ctx.Expect(Tokens, Diags, KindBegin(), 'begin');
        ParseStatementListInto(Ctx, Tokens, Ast, Diags, Kids, KindEnd());
        Ctx.Expect(Tokens, Diags, KindEnd(), 'end');
        Node := Ast.AddNode(NodeBlock(), BeginTok, Kids, 0);
        EatTrailingSemi(Ctx, Tokens, Ast, Node);                // begin..end; eats own ';'
        exit(Node);
    end;

    // exit | exit(expr)  — bit0 = has-value (§5.5).
    local procedure ParseExit(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        ExitTok: Integer;
        HasValue: Integer;
        Kids: List of [Integer];
    begin
        ExitTok := Ctx.Advance();                         // 'exit'
        HasValue := 0;
        if Ctx.Accept(KindOpenParen()) then begin
            if Ctx.CurKind() <> KindCloseParen() then begin
                Kids.Add(Expr.Parse(Ctx, Tokens, Ast, Diags));
                HasValue := 1;
            end;
            Ctx.Expect(Tokens, Diags, KindCloseParen(), ')');
        end;
        if HasValue = 0 then
            Kids.Add(Ast.MissingNode());
        exit(Ast.AddNode(NodeExitStatement(), ExitTok, Kids, HasValue));
    end;

    // An expression at statement position: either `target := source` (assignment / compound)
    // or a bare expression statement (typically a call). §5.3 assignment targets.
    local procedure ParseExprOrAssign(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"): Integer
    var
        AnchorTok: Integer;
        K: Integer;
        Lhs: Integer;
        OpTok: Integer;
        Rhs: Integer;
        Kids: List of [Integer];
    begin
        AnchorTok := Ctx.CurIndex();
        Lhs := Expr.Parse(Ctx, Tokens, Ast, Diags);
        K := Ctx.CurKind();
        if IsAssignOp(K) then begin
            OpTok := Ctx.Advance();
            Rhs := Expr.Parse(Ctx, Tokens, Ast, Diags);
            Kids.Add(Lhs);
            Kids.Add(Rhs);
            exit(Ast.AddNode(NodeAssignmentStatement(), OpTok, Kids, Tokens.GetKind(OpTok)));
        end;
        Kids.Add(Lhs);
        exit(Ast.AddNode(NodeExpressionStatement(), AnchorTok, Kids, 0));
    end;

    // ===== Statement list with §5.4-rule-4 semicolon handling =====
    // ";" SEPARATES statements; the last is optional. If a statement's PREDECESSOR lacked
    // ';', report ERR_SemicolonExpected anchored at the current statement. Stops at
    // Terminator (end / until / EOF), which the caller consumes.
    local procedure ParseStatementListInto(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table"; var Ast: Codeunit "ALI Ast Store"; var Diags: Codeunit "ALI Diag Bag"; var Kids: List of [Integer]; Terminator: Integer)
    var
        First: Boolean;
        PrevHadSemi: Boolean;
        StartCursor: Integer;
        Stmt: Integer;
    begin
        First := true;
        PrevHadSemi := true;
        while (not Ctx.AtEof()) and (Ctx.CurKind() <> Terminator) do begin
            // else also terminates a case-line body's implicit list at 'end' — handled by
            // Terminator; a stray 'else' inside a block is parsed as orphaned-else.
            if (not First) and (not PrevHadSemi) then
                Diags.AddError('AL0132', '; expected', Tokens.GetStartPos(Ctx.CurIndex()), 0);

            StartCursor := Ctx.CurIndex();
            Stmt := ParseStatement(Ctx, Tokens, Ast, Diags);
            Kids.Add(Stmt);
            PrevHadSemi := Ast.GetHasSemicolon(Stmt);
            First := false;

            // Guarantee forward progress even if a statement consumed nothing (garbage).
            if Ctx.CurIndex() = StartCursor then begin
                SyncStatement(Ctx, Tokens);
                if Ctx.CurIndex() = StartCursor then
                    Ctx.Advance();
            end;
        end;
    end;

    // ===== Error recovery / panic-mode sync (§5.2) =====

    // Skip tokens until a statement-start / terminator so parsing can resume.
    local procedure SyncStatement(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table")
    begin
        while not Ctx.AtEof() do begin
            if IsStatementStart(Ctx.CurKind()) then
                exit;
            if Ctx.CurKind() = KindSemicolon() then begin
                Ctx.Advance();                            // consume the ';' and stop
                exit;
            end;
            Ctx.Advance();
        end;
    end;

    // Top-level (proc-list / codeunit body) sync: advance to the next decl start.
    local procedure SyncTopLevel(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table")
    var
        K: Integer;
    begin
        Ctx.Advance();                                    // skip the offending token
        while not Ctx.AtEof() do begin
            K := Ctx.CurKind();
            if (K = KindProcedure()) or (K = KindLocal()) or (K = KindInternal()) or (K = KindTrigger()) or (K = KindVar()) or (K = KindCloseBrace()) then
                exit;
            Ctx.Advance();
        end;
    end;

    // Skip an unhandled codeunit member (property/attribute) to its terminator.
    local procedure SkipMember(var Ctx: Codeunit "ALI Parse Ctx"; var Tokens: Codeunit "ALI Token Table")
    var
        K: Integer;
    begin
        Ctx.Advance();
        while not Ctx.AtEof() do begin
            K := Ctx.CurKind();
            if (K = KindSemicolon()) then begin
                Ctx.Advance();
                exit;
            end;
            if (K = KindProcedure()) or (K = KindLocal()) or (K = KindTrigger()) or (K = KindVar()) or (K = KindCloseBrace()) then
                exit;
            Ctx.Advance();
        end;
    end;

    local procedure IsStatementStart(K: Integer): Boolean
    begin
        exit((K = KindIf()) or (K = KindFor()) or (K = KindWhile()) or (K = KindRepeat()) or
             (K = KindCase()) or (K = KindExit()) or (K = KindBreak()) or (K = KindBegin()) or
             (K = KindIdentifier()) or (K = KindEnd()) or (K = KindUntil()) or (K = KindElse()));
    end;

    local procedure IsAssignOp(K: Integer): Boolean
    begin
        exit((K = KindAssign()) or (K = 41) or (K = 42) or (K = 43) or (K = 44));  // := += -= *= /=
    end;

    // ===== NodeKind ordinals (mirror "ALI NodeKind") =====

    local procedure NodeCompilationUnit(): Integer
    begin
        exit(10);
    end;

    local procedure NodeVarSection(): Integer
    begin
        exit(11);
    end;

    local procedure NodeVarDecl(): Integer
    begin
        exit(12);
    end;

    local procedure NodeProcDecl(): Integer
    begin
        exit(13);
    end;

    local procedure NodeParam(): Integer
    begin
        exit(14);
    end;

    local procedure NodeTypeRef(): Integer
    begin
        exit(15);
    end;

    local procedure NodeParamList(): Integer
    begin
        exit(16);
    end;

    local procedure NodeBlock(): Integer
    begin
        exit(30);
    end;

    local procedure NodeIfStatement(): Integer
    begin
        exit(31);
    end;

    local procedure NodeWhileStatement(): Integer
    begin
        exit(32);
    end;

    local procedure NodeRepeatStatement(): Integer
    begin
        exit(33);
    end;

    local procedure NodeForStatement(): Integer
    begin
        exit(34);
    end;

    local procedure NodeForEachStatement(): Integer
    begin
        exit(35);
    end;

    local procedure NodeCaseStatement(): Integer
    begin
        exit(36);
    end;

    local procedure NodeCaseLine(): Integer
    begin
        exit(37);
    end;

    local procedure NodeCaseElse(): Integer
    begin
        exit(38);
    end;

    local procedure NodeAssignmentStatement(): Integer
    begin
        exit(39);
    end;

    local procedure NodeExpressionStatement(): Integer
    begin
        exit(40);
    end;

    local procedure NodeExitStatement(): Integer
    begin
        exit(41);
    end;

    local procedure NodeBreakStatement(): Integer
    begin
        exit(42);
    end;

    local procedure NodeEmptyStatement(): Integer
    begin
        exit(43);
    end;

    local procedure NodeOrphanedElseStatement(): Integer
    begin
        exit(44);
    end;

    local procedure NodeRangeExpr(): Integer
    begin
        exit(68);
    end;

    local procedure NodeErrorStatement(): Integer
    begin
        exit(3);
    end;

    // ===== TokenKind ordinals (mirror "ALI TokenKind") =====

    local procedure KindEof(): Integer
    begin
        exit(1);
    end;

    local procedure KindInt32Literal(): Integer
    begin
        exit(10);
    end;

    local procedure KindStringLiteral(): Integer
    begin
        exit(16);
    end;

    local procedure KindIdentifier(): Integer
    begin
        exit(20);
    end;

    local procedure KindAssign(): Integer
    begin
        exit(40);
    end;

    local procedure KindOpenParen(): Integer
    begin
        exit(70);
    end;

    local procedure KindCloseParen(): Integer
    begin
        exit(71);
    end;

    local procedure KindOpenBracket(): Integer
    begin
        exit(72);
    end;

    local procedure KindCloseBracket(): Integer
    begin
        exit(73);
    end;

    local procedure KindOpenBrace(): Integer
    begin
        exit(74);
    end;

    local procedure KindCloseBrace(): Integer
    begin
        exit(75);
    end;

    local procedure KindComma(): Integer
    begin
        exit(76);
    end;

    local procedure KindDotDot(): Integer
    begin
        exit(78);
    end;

    local procedure KindColon(): Integer
    begin
        exit(79);
    end;

    local procedure KindSemicolon(): Integer
    begin
        exit(81);
    end;

    local procedure KindIf(): Integer
    begin
        exit(100);
    end;

    local procedure KindThen(): Integer
    begin
        exit(101);
    end;

    local procedure KindElse(): Integer
    begin
        exit(102);
    end;

    local procedure KindCase(): Integer
    begin
        exit(103);
    end;

    local procedure KindOf(): Integer
    begin
        exit(104);
    end;

    local procedure KindFor(): Integer
    begin
        exit(105);
    end;

    local procedure KindTo(): Integer
    begin
        exit(106);
    end;

    local procedure KindDownTo(): Integer
    begin
        exit(107);
    end;

    local procedure KindDo(): Integer
    begin
        exit(108);
    end;

    local procedure KindWhile(): Integer
    begin
        exit(109);
    end;

    local procedure KindForEach(): Integer
    begin
        exit(112);
    end;

    local procedure KindIn(): Integer
    begin
        exit(113);
    end;

    local procedure KindRepeat(): Integer
    begin
        exit(110);
    end;

    local procedure KindUntil(): Integer
    begin
        exit(111);
    end;

    local procedure KindBegin(): Integer
    begin
        exit(114);
    end;

    local procedure KindEnd(): Integer
    begin
        exit(115);
    end;

    local procedure KindExit(): Integer
    begin
        exit(116);
    end;

    local procedure KindBreak(): Integer
    begin
        exit(117);
    end;

    local procedure KindWith(): Integer
    begin
        exit(118);
    end;

    local procedure KindProcedure(): Integer
    begin
        exit(130);
    end;

    local procedure KindLocal(): Integer
    begin
        exit(131);
    end;

    local procedure KindInternal(): Integer
    begin
        exit(132);
    end;

    local procedure KindVar(): Integer
    begin
        exit(134);
    end;

    local procedure KindArray(): Integer
    begin
        exit(135);
    end;

    local procedure KindTemporary(): Integer
    begin
        exit(136);
    end;

    local procedure KindTrigger(): Integer
    begin
        exit(137);
    end;

    local procedure KindCodeunit(): Integer
    begin
        exit(138);
    end;
}
