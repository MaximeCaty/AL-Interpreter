// ALI Array Runtime — handle-based array element storage backed by native-Variant tier blocks
// (ArrayNativeBlockPlan.md). An array VALUE is a plain 1-based Int handle = index into Blocks.
// Each live array is one "ALI Array Block" instance (S/M/L tier, native `array[Cap] of
// Variant`); the tier is picked by TotalN. Freed handles go on FreeIdx and are reused when a
// freed block's tier still fits (first-fit scan). No per-class banks, no block-meta, no
// bump-alloc ceiling — lifecycle is GC-managed via the List of [Interface].
//
// "ALI Interpreter" pushes/pops handles on its own frame-scoped AllocStack (§20.5) and calls
// FreeBlock on frame pop. It NEVER decodes the handle (element class flows via the opcode
// operand), so the handle is a bare index.
codeunit 51138 "ALI Array Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        FreeIdx: List of [Integer];                       // recycled handle indices
        Blocks: List of [Interface "ALI Array Block"];   // handle = 1-based index

    procedure Reset()
    begin
        Clear(Blocks);
        Clear(FreeIdx);
    end;

    procedure ClearArray(Handle: Integer)
    var
        Blk: Interface "ALI Array Block";
    begin
        Blocks.Get(Handle, Blk);
        Blk.ClearArray();
    end;

    // Allocate (or reuse) a block of TotalN zero-init cells for register class Cls; returns the
    // handle. Reused blocks are re-seeded; fresh blocks are seeded on Alloc (native Variant
    // cells default EMPTY, not typed-zero — see "ALI Array Block").
    procedure NewBlock(Cls: Integer; TotalN: Integer): Integer
    var
        Cand: Integer;
        i: Integer;
        Blk: Interface "ALI Array Block";
    begin
        if (TotalN < 1) or (TotalN > 1000000) then
            Error('ALI988: array element count %1 out of range (1..1000000)', TotalN);

        // First-fit reuse: any freed block whose tier capacity still fits TotalN.
        for i := FreeIdx.Count() downto 1 do begin
            Cand := FreeIdx.Get(i);
            Blocks.Get(Cand, Blk);
            if Blk.Cap() >= TotalN then begin
                FreeIdx.RemoveAt(i);
                Blk.Alloc(TotalN, Cls);
                exit(Cand);
            end;
        end;

        // Fresh block — Fresh* helpers each instantiate ONLY their tier's codeunit, so a small
        // array never reserves the 24MB L array (and every Add gets a distinct instance).
        Blk := NewTierBlock(TotalN);
        Blk.Alloc(TotalN, Cls);
        Blocks.Add(Blk);
        exit(Blocks.Count());
    end;

    procedure FreeBlock(Handle: Integer)
    begin
        FreeIdx.Add(Handle);
    end;

    procedure TotalNOf(Handle: Integer): Integer
    var
        Blk: Interface "ALI Array Block";
    begin
        Blocks.Get(Handle, Blk);
        exit(Blk.TotalN());
    end;

    // Read/write ONE cell (1-based flat index) as a Variant — the call-boundary boxing
    // convention "ALI Interpreter".ReadRegisterAsVariant/WriteRegisterFromVariant already use.
    // Range check (1..TotalN) fires inside the block.
    procedure ReadCell(Handle: Integer; FlatIndex: Integer): Variant
    var
        Blk: Interface "ALI Array Block";
    begin
        Blocks.Get(Handle, Blk);
        exit(Blk.GetCell(FlatIndex));
    end;

    procedure WriteCell(Handle: Integer; FlatIndex: Integer; V: Variant)
    var
        Blk: Interface "ALI Array Block";
    begin
        Blocks.Get(Handle, Blk);
        Blk.SetCell(FlatIndex, V);
    end;

    // Bulk ops — resolve the block(s) ONCE (no per-cell Blocks.Get) and let the block loop on
    // its own native Cells. Bounds are pre-validated by the interpreter (ExecArrCompress/Copy).
    procedure CompressBlock(Handle: Integer): Integer
    var
        Blk: Interface "ALI Array Block";
    begin
        Blocks.Get(Handle, Blk);
        exit(Blk.Compress());
    end;

    procedure CopyBlock(DestHandle: Integer; SrcHandle: Integer; SrcPos: Integer; Len: Integer)
    var
        Dest: Interface "ALI Array Block";
        Src: Interface "ALI Array Block";
    begin
        Blocks.Get(DestHandle, Dest);
        Blocks.Get(SrcHandle, Src);
        Dest.CopyFrom(Src, SrcPos, Len);
    end;

    // ===== Tier pick (closed set of 3 — a TotalN threshold, no enum needed) =====

    local procedure NewTierBlock(TotalN: Integer): Interface "ALI Array Block"
    begin
        if TotalN <= 100 then
            exit(FreshS());
        if TotalN <= 1000 then
            exit(FreshM());
        if TotalN <= 10000 then
            exit(FreshL());
        exit(FreshXL());
    end;

    // Each Fresh* declares its own tier codeunit local → a genuinely DISTINCT instance per call
    // (AL instantiates a local codeunit var on entry), and ONLY that tier's array is allocated.
    local procedure FreshS(): Interface "ALI Array Block"
    var
        S: Codeunit "ALI Array Block S";
    begin
        exit(S);
    end;

    local procedure FreshM(): Interface "ALI Array Block"
    var
        M: Codeunit "ALI Array Block M";
    begin
        exit(M);
    end;

    local procedure FreshL(): Interface "ALI Array Block"
    var
        L: Codeunit "ALI Array Block L";
    begin
        exit(L);
    end;

    local procedure FreshXL(): Interface "ALI Array Block"
    var
        XL: Codeunit "ALI Array Block XL";
    begin
        exit(XL);
    end;
}
