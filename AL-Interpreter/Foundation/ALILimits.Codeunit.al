// ALI Limits — single home for every capacity constant (§3.2/§17).
// Runtime hot structures use fixed arrays sized from these; the Lowerer "seals"
// List-built compile columns into fixed arrays at load/link time. Overflow of any
// of these produces a clean "program too large / call stack too deep" diagnostic.
// Tuned with benchmarks (§16 M4) — change here only; ordinals/format unaffected.
codeunit 51103 "ALI Limits"
{
    Access = Public;

    // ===== Module / bytecode =====
    procedure MaxInstructions(): Integer
    begin
        exit(65536);            // instructions per module (§17; M11 phase 0 doubled this to 131072 —
                                // a module holds the entry script PLUS every harvested object unit
                                // linked into the same stream. Halved back: the interpreter reserves
                                // FOUR arrays of this size (Op/A/B/C), so the ceiling costs 4x its
                                // own size in cold-start allocation, and no observed module came
                                // near even 32768. Over-limit is a clean ALI940 at lower/load, so
                                // raising it again is one number here + the four array literals in
                                // "ALI Interpreter" — AssertArrayCapacities() fails loudly if only
                                // one side is changed.)
    end;

    // ===== Register files (per type, per frame window §7.1) =====
    procedure MaxIntRegisters(): Integer
    begin
        exit(8192);             // widened in M5: deep interpreted recursion consumes one Int window per frame
    end;

    procedure MaxDecimalRegisters(): Integer
    begin
        exit(4096);
    end;

    procedure MaxBoolRegisters(): Integer
    begin
        exit(4096);
    end;

    procedure MaxTextRegisters(): Integer
    begin
        exit(2048);
    end;

    procedure MaxScalarRegisters(): Integer
    begin
        exit(2048);             // date/time/datetime/duration/guid/bigint scalar file
    end;

    procedure MaxVariantRegisters(): Integer
    begin
        exit(256);              // fallback file — deliberately small (§7.1)
    end;

    procedure MaxRecordSlots(): Integer
    begin
        // RecordRef bank capacity (§17; Handle Lifecycle Unification Phase 3). This is the
        // PUBLISHED copy, not the source of truth: the bank is `array[1024] of RecordRef` in
        // "ALI Rec Runtime" and AL array dimensions must be literals, so that literal decides
        // and every bounds check there reads it back with ArrayLen. This value is asserted equal
        // to it once per run by "ALI Rec Runtime".AssertBankCapacity — the old "keep in sync BY
        // HAND" note had already rotted (this said 4096 while the array held 1024, which turned
        // an in-range check into an out-of-bounds index).
        // 1024 and not more: a FieldRef handle packs (fieldNoSlot * 2048 + recHandle), so the
        // bank must stay strictly under that 2048 stride. Raising it means raising the stride
        // in lockstep, and the assertion enforces exactly that.
        // 256 since the cold-start pass: this is the only bank whose slots are CONSTRUCTED
        // objects (RecordRef), so it is the most expensive per slot of any fixed array in the
        // interpreter, and 256 concurrently OPEN records is far past what a script reaches
        // (frame-scoped handles are reclaimed at RET). Overflow is a clean ALI954 with a census
        // of what filled the bank.
        exit(256);
    end;

    // ===== Module pools (M4) =====
    // NB: AL array dimensions must be literals, so the fixed arrays in "ALI Interpreter"
    // hardcode these same numbers — keep them in sync BY HAND (cross-referenced there).

    procedure MaxConstPoolEntries(): Integer
    begin
        exit(2048);             // per-type const pool entries per module (SEVEN pools are sized
                                // from this, one of them Text — halved from 4096 for cold start;
                                // over-limit is a clean ALI942)
    end;

    procedure MaxConcatOperands(): Integer
    begin
        exit(4096);             // CONCAT_N operand-pool entries per module (§7.3)
    end;

    procedure MaxDebugEntries(): Integer
    begin
        exit(65536);            // statement debug-map rows (line/col; per-instruction DbgRowOfPC points here) (§7.3)
    end;

    // ===== Frame / call stack =====
    procedure MaxFrames(): Integer
    begin
        exit(1024);             // interpreter frame stack depth (§17; widened in M5 for 1000-deep recursion)
    end;

    procedure MaxProcsPerModule(): Integer
    begin
        exit(1024);             // proc-table rows per module (M5, §7.3; M11 phase 0: raised from
                                // 256 — one harvested table/codeunit can contribute dozens of procs)
    end;

    // M11 phase B2: distinct Record/Codeunit VARIABLES a compilation may declare across the
    // script and every object it harvests. Each one owns a block of its object's globals, so the
    // ceiling is on the instance table, not on live objects at runtime.
    procedure MaxObjectInstances(): Integer
    begin
        exit(1024);             // quartered for cold start: the interpreter's InstBaseArr is this
                                // x 13 register classes, so 4096 reserved 53248 slots to serve
                                // scripts that declare a handful. Over-limit is a clean ALI954.
    end;

    // ===== Parser guards =====
    procedure MaxNestingDepth(): Integer
    begin
        exit(200);              // expression + statement recursion guard (§5.2/§5.4)
    end;

    // ===== Execution budget / watchdog (§7.4) =====
    procedure DefaultStatementBudget(): Integer
    begin
        exit(100000000);         // 100M statements before runaway abort
    end;

    procedure WatchdogCheckInterval(): Integer
    begin
        exit(1024);             // check wall-clock deadline every N statements
    end;
}
