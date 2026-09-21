// ALI Array Block — storage contract for one interpreter array instance, backed by a native
// AL array of Variant (ArrayNativeBlockPlan.md). One implementing codeunit per fixed tier
// (S/M/L), each carrying an `array[Cap] of Variant`. "ALI Array Runtime" owns the instances
// (List of [Interface], handle = 1-based index) and picks the tier by TotalN; nothing else
// touches a block directly.
interface "ALI Array Block"
{
    // Zero-init cells 1..N with Cls's typed default (Seed). Native Variant cells default to
    // EMPTY, not typed-zero — Seed must be filled or reads of untouched cells return an empty
    // Variant (breaks the "array is zero-init" contract, and throws on read where native AL
    // would silently hand back the type's default).
    procedure Alloc(N: Integer; Cls: Integer)
    procedure ClearArray()
    procedure SetCell(FlatIdx: Integer; V: Variant)
    procedure GetCell(FlatIdx: Integer): Variant

    // Logical live element count (product of declared dimension sizes) — the range checked on
    // every access, NOT the physical Cap.
    procedure TotalN(): Integer

    // Physical tier capacity — used by the runtime's free-list reuse to test tier fit.
    procedure Cap(): Integer

    // Text-array CompressArray (§20.14): compact non-empty cells to the front over 1..TotalN,
    // blank the tail, return the kept count. Runs on the block's own native Cells (no per-cell
    // interface dispatch, no List.Get) — the interpreter's old cell-by-cell loop is gone.
    procedure Compress(): Integer

    // CopyArray dest side: copy Len cells from Src[SrcPos..] into THIS block's [1..Len]. Dest
    // writes its own native Cells directly; only the src side goes through GetCell (the two
    // blocks are distinct instances / possibly distinct tiers, so no native CopyArray).
    procedure CopyFrom(Src: Interface "ALI Array Block"; SrcPos: Integer; Len: Integer)
}
