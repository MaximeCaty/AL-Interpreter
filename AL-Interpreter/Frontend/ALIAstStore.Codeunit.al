// ALI Ast Store — flat AST (struct-of-arrays) + CSR child edges + binder annotation
// columns + per-node HasSemicolon flag (§4.2, §5.5).
//
// Node columns (parallel, 1-based node index):
//   KindOrd        "ALI NodeKind" ordinal
//   MainTokenIdx   position anchor for diagnostics (token index into the Token Table)
//   FirstChildEdge index into Edges of this node's first child (0 if none)
//   ChildCount     number of children
//   ExtraInt       kind-specific payload (§5.5 last column: op token kind / pool idx /
//                  NameId / bit flags / counts)
//   Flags          bit0 = HasSemicolon (§5.4) — computed once at statement-build time;
//                  bit1 = ForceBuiltin (NameExpr); bit2 = TryFunction (ProcDecl)
//
// Children live in a SEPARATE edge array (CSR adjacency): children of node n are
// Edges[FirstChildEdge .. FirstChildEdge+ChildCount-1]. Because children must be
// contiguous, the parser builds BOTTOM-UP: children complete before the parent is
// added; recursive descent yields exactly this order (§4.2).
//
// Binder annotations are separate parallel columns written LATER (AST stays immutable
// after parse): TypeOrd, SymbolId, ConvOrd, SlotIndex, TypeArg (§4.2). TypeArg carries the
// option/enum set id for TOption/TEnum-typed expression nodes (Rec.Field access, proc-call
// results) — the SlotIndex column is already overloaded (folded ordinal / object id) on
// OptionAccessExpr, so it cannot also carry the set id.
//
// A single shared MissingNode handle represents absent [opt] children so binder/lowerer
// indexing stays positional (§5.5). It is created lazily at index 1 on first use.
codeunit 51105 "ALI Ast Store"
{
    Access = Public;
    SingleInstance = false;

    var

        MissingNodeIdx: Integer;    // shared sentinel handle, 0 until created
        ChildCount: List of [Integer];
        ConvOrd: List of [Integer];

        // --- Child edge array (CSR) ---
        Edges: List of [Integer];
        ExtraInt: List of [Integer];
        FirstChildEdge: List of [Integer];
        Flags: List of [Integer];
        // --- Node columns (1-based) ---
        KindOrd: List of [Integer];
        MainTokenIdx: List of [Integer];
        SlotIndex: List of [Integer];
        SymbolId: List of [Integer];
        TypeArg: List of [Integer];   // option/enum set id (Option/Enum); unused otherwise

        // --- Binder annotation columns (written later; parallel to node columns) ---
        TypeOrd: List of [Integer];

    // Flag bit constants (AL has no constants, §3.3).
    procedure FlagHasSemicolon(): Integer
    begin
        exit(1);
    end;

    procedure FlagForceBuiltin(): Integer
    begin
        exit(2);
    end;

    procedure FlagTryFunction(): Integer
    begin
        exit(4);
    end;

    // ===== Add =====

    // Add a node with its already-collected child node indices (bottom-up, §4.2).
    // ChildList entries are node indices; they are copied contiguously into Edges.
    procedure AddNode(Kind: Integer; MainToken: Integer; ChildList: List of [Integer]; Extra: Integer): Integer
    var
        ChildIdx: Integer;
        First: Integer;
    begin
        if ChildList.Count() > 0 then
            First := Edges.Count() + 1
        else
            First := 0;
        foreach ChildIdx in ChildList do
            Edges.Add(ChildIdx);

        KindOrd.Add(Kind);
        MainTokenIdx.Add(MainToken);
        FirstChildEdge.Add(First);
        ChildCount.Add(ChildList.Count());
        ExtraInt.Add(Extra);
        Flags.Add(0);

        // annotation columns grow in lock-step (default/unset)
        TypeOrd.Add(0);
        SymbolId.Add(0);
        ConvOrd.Add(0);
        SlotIndex.Add(0);
        TypeArg.Add(0);

        exit(KindOrd.Count());
    end;

    // Leaf convenience (no children).
    procedure AddLeaf(Kind: Integer; MainToken: Integer; Extra: Integer): Integer
    var
        Empty: List of [Integer];
    begin
        exit(AddNode(Kind, MainToken, Empty, Extra));
    end;

    // The shared missing-node sentinel (created once, §5.5). Used for absent [opt] children.
    procedure MissingNode(): Integer
    begin
        if MissingNodeIdx = 0 then
            MissingNodeIdx := AddLeaf(1, 0, 0);  // NodeKind.MissingNode = 1
        exit(MissingNodeIdx);
    end;

    // ===== Node getters (1-based node index) =====

    procedure Count(): Integer
    begin
        exit(KindOrd.Count());
    end;

    procedure GetKind(NodeIdx: Integer): Integer
    begin
        exit(KindOrd.Get(NodeIdx));
    end;

    procedure GetMainToken(NodeIdx: Integer): Integer
    begin
        exit(MainTokenIdx.Get(NodeIdx));
    end;

    procedure GetExtra(NodeIdx: Integer): Integer
    begin
        exit(ExtraInt.Get(NodeIdx));
    end;

    procedure GetChildCount(NodeIdx: Integer): Integer
    begin
        exit(ChildCount.Get(NodeIdx));
    end;

    // i is 0-based within the node's child span.
    procedure GetChild(NodeIdx: Integer; i: Integer): Integer
    begin
        exit(Edges.Get(FirstChildEdge.Get(NodeIdx) + i));
    end;

    // Hand the STRUCTURAL columns to a consumer that walks the tree densely (the binder).
    // `List of [T]` is a reference type in AL, so this shares the columns rather than copying —
    // and structure is immutable during binding (§5: the binder only writes the parallel
    // annotation columns TypeOrd/SymbolId/ConvOrd/SlotIndex), so sharing is safe and stays
    // coherent. Deliberately EXCLUDES ExtraInt, which the binder does write (foreach's
    // collection-kind lowerer contract) and which must therefore keep going through Get/SetExtra.
    //
    // Motive: the binder made ~740 cross-codeunit calls into these four columns —
    // GetChild/GetMainToken/GetKind/GetChildCount — at ~450ns each, several per AST node.
    // Reading them locally turns each into a plain List.Get.
    procedure GetStructureColumns(var Kind: List of [Integer]; var MainTok: List of [Integer]; var FirstChild: List of [Integer]; var ChildCnt: List of [Integer]; var Edge: List of [Integer])
    begin
        Kind := KindOrd;
        MainTok := MainTokenIdx;
        FirstChild := FirstChildEdge;
        ChildCnt := ChildCount;
        Edge := Edges;
    end;

    procedure IsMissing(NodeIdx: Integer): Boolean
    begin
        exit(KindOrd.Get(NodeIdx) = 1);  // NodeKind.MissingNode
    end;

    // ===== Optimizer mutators (§12) — post-parse in-place rewrite by opt passes only =====
    // Node columns are otherwise immutable after parse; these let a pass collapse a subtree
    // (e.g. constant folding a BinaryExpr into a LiteralExpr). MakeLeaf orphans the old child
    // edges (unreachable, not compacted). Callers MUST preserve the node's result TypeOrd.

    procedure SetKind(NodeIdx: Integer; Kind: Integer)
    begin
        KindOrd.Set(NodeIdx, Kind);
    end;

    procedure SetMainToken(NodeIdx: Integer; TokenIdx: Integer)
    begin
        MainTokenIdx.Set(NodeIdx, TokenIdx);
    end;

    procedure SetExtra(NodeIdx: Integer; V: Integer)
    begin
        ExtraInt.Set(NodeIdx, V);
    end;

    // Turn a node into a childless leaf (old child edges become unreachable).
    procedure MakeLeaf(NodeIdx: Integer)
    begin
        FirstChildEdge.Set(NodeIdx, 0);
        ChildCount.Set(NodeIdx, 0);
    end;

    // Repoint a node at a NEW child list. The children are appended to Edges (CSR only
    // requires per-node contiguity); the node's old edge span becomes unreachable, same
    // as MakeLeaf. Used by opt passes that keep a subtree but change its shape (e.g.
    // dead-branch elimination turning an IfStatement into a Block of the taken branch).
    procedure SetChildren(NodeIdx: Integer; ChildList: List of [Integer])
    var
        ChildIdx: Integer;
        First: Integer;
    begin
        if ChildList.Count() = 0 then begin
            MakeLeaf(NodeIdx);
            exit;
        end;
        First := Edges.Count() + 1;
        foreach ChildIdx in ChildList do
            Edges.Add(ChildIdx);
        FirstChildEdge.Set(NodeIdx, First);
        ChildCount.Set(NodeIdx, ChildList.Count());
    end;

    // ===== HasSemicolon flag (§5.4 — consulted by the parser on every if/stmt-list elem) =====

    procedure SetHasSemicolon(NodeIdx: Integer; Value: Boolean)
    var
        F: Integer;
    begin
        // AL has no bitwise integer ops — power-of-two bits via div/mod arithmetic.
        F := Flags.Get(NodeIdx);
        if Value then begin
            if (F div FlagHasSemicolon()) mod 2 = 0 then
                F += FlagHasSemicolon();
        end else
            if (F div FlagHasSemicolon()) mod 2 = 1 then
                F -= FlagHasSemicolon();
        Flags.Set(NodeIdx, F);
    end;

    procedure GetHasSemicolon(NodeIdx: Integer): Boolean
    begin
        exit((Flags.Get(NodeIdx) div FlagHasSemicolon()) mod 2 = 1);
    end;

    // ===== ForceBuiltin flag =====
    // Set by the parser on a NameExpr that carried the `System.` qualifier (`System.Evaluate(...)`).
    // Native AL uses it to name the SYSTEM builtin explicitly where an object procedure of the
    // same name would otherwise shadow it (codeunit 10 "Type Helper" declares its own Evaluate).

    procedure SetForceBuiltin(NodeIdx: Integer)
    var
        F: Integer;
    begin
        F := Flags.Get(NodeIdx);
        if (F div FlagForceBuiltin()) mod 2 = 0 then
            Flags.Set(NodeIdx, F + FlagForceBuiltin());
    end;

    procedure GetForceBuiltin(NodeIdx: Integer): Boolean
    begin
        exit((Flags.Get(NodeIdx) div FlagForceBuiltin()) mod 2 = 1);
    end;

    // ===== TryFunction flag =====
    // Set by the parser on a ProcDecl carrying the `[TryFunction]` attribute. A Flags bit rather
    // than a child or an ExtraInt packing: ProcDecl children are positional (§5.5) and ExtraInt
    // is the NameId every consumer reads raw, so a bit here is the one change nobody else sees.

    procedure SetTryFunction(NodeIdx: Integer)
    var
        F: Integer;
    begin
        F := Flags.Get(NodeIdx);
        if (F div FlagTryFunction()) mod 2 = 0 then
            Flags.Set(NodeIdx, F + FlagTryFunction());
    end;

    procedure GetTryFunction(NodeIdx: Integer): Boolean
    begin
        exit((Flags.Get(NodeIdx) div FlagTryFunction()) mod 2 = 1);
    end;

    // ===== Binder annotation setters/getters (written after parse, §4.2) =====

    procedure SetTypeOrd(NodeIdx: Integer; V: Integer)
    begin
        TypeOrd.Set(NodeIdx, V);
    end;

    procedure GetTypeOrd(NodeIdx: Integer): Integer
    begin
        exit(TypeOrd.Get(NodeIdx));
    end;

    procedure SetSymbolId(NodeIdx: Integer; V: Integer)
    begin
        SymbolId.Set(NodeIdx, V);
    end;

    procedure GetSymbolId(NodeIdx: Integer): Integer
    begin
        exit(SymbolId.Get(NodeIdx));
    end;

    procedure SetConvOrd(NodeIdx: Integer; V: Integer)
    begin
        ConvOrd.Set(NodeIdx, V);
    end;

    procedure GetConvOrd(NodeIdx: Integer): Integer
    begin
        exit(ConvOrd.Get(NodeIdx));
    end;

    procedure SetSlotIndex(NodeIdx: Integer; V: Integer)
    begin
        SlotIndex.Set(NodeIdx, V);
    end;

    procedure GetSlotIndex(NodeIdx: Integer): Integer
    begin
        exit(SlotIndex.Get(NodeIdx));
    end;

    procedure SetTypeArg(NodeIdx: Integer; V: Integer)
    begin
        TypeArg.Set(NodeIdx, V);
    end;

    procedure GetTypeArg(NodeIdx: Integer): Integer
    begin
        exit(TypeArg.Get(NodeIdx));
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        ClearAll();
    end;
}
