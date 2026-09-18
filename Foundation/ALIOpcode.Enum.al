// ALI Opcode — register bytecode operations per §7.3. FINAL M4 LAYOUT.
//
// ===== ORDINAL-FREEZE DISCIPLINE (§3.3 / §10 / §17) — READ BEFORE EDITING =====
// Ordinals are DENSE and EXPLICIT (value(N; ...)), assigned from 0 in first-write order.
// Families are 32 WIDE (family = Op div 32); a member's ordinal = family*32 + slot. BOTH
// dispatch shapes (flat `case Op of` and two-level `case Op div 32 of`) share this ONE
// numbering — the shape choice never renumbers anything (see LAYOUT DECISION below).
//
// Ordinals FREEZE at first serialization (M8, §10). Rules, enforced from that point:
//   (a) never renumber an existing member;
//   (b) additions APPEND at the next free ordinal only (a family may spill past its 32-slot
//       block into fresh ordinal space — density beats block-purity once frozen);
//   (c) a member may be deprecated/reserved but its ordinal is NEVER reused;
//   (d) any violation is a serialization format-version bump (§10).
// Dispatch-shape reordering is a SetDispatchShape() concern, NOT an ordinal concern: the
// benchmark selects a run PROCEDURE, so settling it costs no format bump. Settle the shape
// (below) BEFORE M8 ships any serialized module, then treat this numbering as append-only.
//
// BENCHMARK RESULT (to be filled after the user runs "ALI Benchmarks".RunAll() on a BC
// service — this environment cannot execute AL):
//   TODO(user): benchmark date  = __________  (RunAll() "Run at" line)
//   TODO(user): chosen shape     = __________  (FLAT | TWO-LEVEL — Workload 1 winner)
//   TODO(user): set the default in "ALI Interpreter".Reset() (UseTwoLevel) to match, then
//               this line is the frozen record; no renumbering follows.
//
// FROZEN SERIALIZATION CONTRACT (§10): explicit ordinals, append-only, no reuse from M8 on.
//
// LAYOUT DECISION (M4, §7.4/§17 dispatch-shape benchmark):
// Ordinals are grouped in 32-blocks (family = Op div 32) and families are ordered by
// expected execution frequency (control/stmt hottest, then moves/loads, arithmetic,
// comparisons, conversions; calls and records reserved at the cold end). This numbering is
// deliberately SHAPE-NEUTRAL: it serves BOTH dispatch shapes —
//   * flat single `case Op of` (branches written in frequency order in the interpreter,
//     independent of ordinal order), and
//   * two-level `case Op div 32 of` + nested member `case`,
// so the benchmark ("ALI Dispatch Benchmark") selects a dispatch PROCEDURE, never a
// renumbering. The loser shape can be revived without a format bump.
//
// BENCHMARK STATUS: harness implemented in M4 ("ALI Dispatch Benchmark", 1M-iteration
// integer loop, CurrentDateTime deltas, both shapes on identical bytecode). This
// environment cannot execute AL, so the numbers MUST be produced on a BC service before
// M8 freezes the format. Reasoned default until then: FLAT dispatch (AL lowers `case` to
// sequential compares; with hot ops first the flat loop resolves loop-kernel ops in <10
// compares, while two-level always pays the `div 32` + outer-case walk). The interpreter
// ships both loops behind SetDispatchShape().
//
// Operand convention: four int columns Op,A,B,C. A=dest, B=src1, C=src2 unless noted.
// Jump targets are 1-based instruction indices. Register indices are 1-based per-class
// slots (§7.1/§7.2). Register class implied by the opcode suffix:
//   _I Integer file (Integer/Char/Byte/Option)   _BIG BigInteger   _D Decimal
//   _B Boolean   _T Text (Text/Code/Label)       _DATE/_TIME/_DT/_DUR temporal files
//   _G Guid      _V Variant
enum 51009 "ALI Opcode"
{
    Extensible = false;

    // ===== Family 0 (0..31): control / statement (hottest) =====
    value(0; NOP) { }
    value(1; STMT) { }              // statement boundary: A = debug-map row (line/col); counts + budget check (§7.4)
    value(2; JMP) { }               // A = target PC
    value(3; JMP_IF_FALSE) { }      // A = target PC, B = bool reg
    value(4; JMP_IF_TRUE) { }       // A = target PC, B = bool reg
    value(5; FOR_INIT_UP) { }       // A = loop var (int), B = limit slot, C = loop-exit PC; skips if A > B (§5.3)
    value(6; FOR_INIT_DOWN) { }     // skips if A < B
    value(7; FOR_NEXT_UP) { }       // if A < B then A += 1, PC := C (check-then-increment: no overflow at MaxInt); counts a statement
    value(8; FOR_NEXT_DOWN) { }     // if A > B then A -= 1, PC := C
    value(9; RET) { }               // return: pops frame (entry frame -> halt)
    value(10; ERROR_RAISE) { }      // A = text reg with message -> native Error()

    // ===== Family 1 (32..63): moves / const loads / var stores =====
    value(32; MOV_I) { }            // IntReg[A] := IntReg[B]
    value(33; MOV_BIG) { }
    value(34; MOV_D) { }
    value(35; MOV_B) { }
    value(36; MOV_T) { }
    value(37; MOV_DATE) { }
    value(38; MOV_TIME) { }
    value(39; MOV_DT) { }
    value(40; MOV_DUR) { }
    value(41; MOV_G) { }
    value(42; MOV_V) { }
    value(43; LOAD_CONST_I) { }     // A = dest, B = int const-pool index
    value(44; LOAD_CONST_BIG) { }
    value(45; LOAD_CONST_D) { }
    value(46; LOAD_CONST_B) { }     // B = immediate 0/1 (no pool)
    value(47; LOAD_CONST_T) { }
    value(48; LOAD_CONST_DATE) { }
    value(49; LOAD_CONST_TIME) { }
    value(50; LOAD_CONST_DT) { }
    value(51; STORE_TEXT_CHK) { }   // A = dest VAR slot, B = src text reg, C = MaxLen*2 + IsCode; length check + Code upper (§7.2, temps skip)
    value(52; LOAD_IND) { }         // M5 var-param indirect load: A = dest reg (rel), B = var-param slot (rel), C = reg class (§7.2)
    value(53; STORE_IND) { }        // M5 var-param indirect store: A = var-param slot (rel), B = src reg (rel), C = reg class

    // ===== Family 2 (64..95): arithmetic (native AL semantics — never reimplemented) =====
    value(64; ADD_I) { }
    value(65; SUB_I) { }
    value(66; MUL_I) { }
    value(67; DIV_I) { }            // `div` — native integer division (div-by-zero raises natively)
    value(68; MOD_I) { }            // `mod` — native remainder (negative operands: native)
    value(69; NEG_I) { }            // unary minus
    value(70; ADD_BIG) { }
    value(71; SUB_BIG) { }
    value(72; MUL_BIG) { }
    value(73; DIV_BIG) { }
    value(74; MOD_BIG) { }
    value(75; NEG_BIG) { }
    value(76; ADD_D) { }
    value(77; SUB_D) { }
    value(78; MUL_D) { }
    value(79; DIV_D) { }            // `/` — operands CONV'd to Decimal first (§6.4)
    value(80; NEG_D) { }
    value(81; CAT_T) { }            // binary Text concat
    value(82; CONCAT_N) { }         // fused n-ary concat via TextBuilder (§7.3 pitfall 9): B = operand-pool start, C = count
    value(83; ADD_DATE_I) { }       // Date + Int -> Date (DateAndIntegerAddition)
    value(84; SUB_DATE_I) { }       // Date - Int -> Date
    value(85; SUB_DATE_DATE) { }    // Date - Date -> INTEGER days (BuiltInOperators.ReturnType: Date -> Integer)
    value(86; ADD_DATE_DUR) { }     // Date + Duration -> Date
    value(87; SUB_DATE_DUR) { }     // Date - Duration -> Date
    value(88; ADD_TIME_DUR) { }     // Time + Duration -> Time
    value(89; SUB_TIME_DUR) { }     // Time - Duration -> Time
    value(90; SUB_TIME_TIME) { }    // Time - Time -> INTEGER ms (BuiltInOperators.ReturnType: Time -> Integer)
    value(91; ADD_DT_DUR) { }       // DateTime + Duration -> DateTime
    value(92; SUB_DT_DUR) { }       // DateTime - Duration -> DateTime
    value(93; SUB_DT_DT) { }        // DateTime - DateTime -> Duration

    // ===== Family 3 (96..127): hot comparisons (-> Bool reg) + logical =====
    value(96; CMP_EQ_I) { }
    value(97; CMP_NE_I) { }
    value(98; CMP_LT_I) { }
    value(99; CMP_LE_I) { }
    value(100; CMP_GT_I) { }
    value(101; CMP_GE_I) { }
    value(102; CMP_EQ_D) { }
    value(103; CMP_NE_D) { }
    value(104; CMP_LT_D) { }
    value(105; CMP_LE_D) { }
    value(106; CMP_GT_D) { }
    value(107; CMP_GE_D) { }
    value(108; CMP_EQ_T) { }        // Code casing handled by upper-on-store (§6.4)
    value(109; CMP_NE_T) { }
    value(110; CMP_LT_T) { }
    value(111; CMP_LE_T) { }
    value(112; CMP_GT_T) { }
    value(113; CMP_GE_T) { }
    value(114; AND_B) { }           // NO short-circuit — both operands always lowered (§7.3 pitfall 2)
    value(115; OR_B) { }
    value(116; XOR_B) { }
    value(117; NOT_B) { }

    // ===== Family 4 (128..159): cold comparisons =====
    value(128; CMP_EQ_B) { }        // Bool ordering exists natively (BoolLessThan 0x181D etc.)
    value(129; CMP_NE_B) { }
    value(130; CMP_LT_B) { }
    value(131; CMP_LE_B) { }
    value(132; CMP_GT_B) { }
    value(133; CMP_GE_B) { }
    value(134; CMP_EQ_BIG) { }
    value(135; CMP_NE_BIG) { }
    value(136; CMP_LT_BIG) { }
    value(137; CMP_LE_BIG) { }
    value(138; CMP_GT_BIG) { }
    value(139; CMP_GE_BIG) { }
    value(140; CMP_EQ_DATE) { }
    value(141; CMP_NE_DATE) { }
    value(142; CMP_LT_DATE) { }
    value(143; CMP_LE_DATE) { }
    value(144; CMP_GT_DATE) { }
    value(145; CMP_GE_DATE) { }
    value(146; CMP_EQ_TIME) { }
    value(147; CMP_NE_TIME) { }
    value(148; CMP_LT_TIME) { }
    value(149; CMP_LE_TIME) { }
    value(150; CMP_GT_TIME) { }
    value(151; CMP_GE_TIME) { }
    value(152; CMP_EQ_DT) { }
    value(153; CMP_NE_DT) { }
    value(154; CMP_LT_DT) { }
    value(155; CMP_LE_DT) { }
    value(156; CMP_GT_DT) { }
    value(157; CMP_GE_DT) { }

    // ===== Family 5 (160..191): duration/guid comparisons + conversions =====
    value(160; CMP_EQ_DUR) { }
    value(161; CMP_NE_DUR) { }
    value(162; CMP_LT_DUR) { }
    value(163; CMP_LE_DUR) { }
    value(164; CMP_GT_DUR) { }
    value(165; CMP_GE_DUR) { }
    value(166; CMP_EQ_G) { }        // Guid ordering exists natively (GuidLessThan 0x1833 etc.)
    value(167; CMP_NE_G) { }
    value(168; CMP_LT_G) { }
    value(169; CMP_LE_G) { }
    value(170; CMP_GT_G) { }
    value(171; CMP_GE_G) { }
    value(172; CONV_I_D) { }        // DecReg[A] := IntReg[B]
    value(173; CONV_BIG_D) { }      // DecReg[A] := BigReg[B]
    value(174; CONV_D_I) { }        // IntReg[A] := DecReg[B] — native assignment narrowing (rounds; §6.4 pitfall 24)
    value(175; CONV_D_BIG) { }      // BigReg[A] := DecReg[B] — native rounding
    value(176; CONV_I_BIG) { }      // BigReg[A] := IntReg[B]
    value(177; CONV_BIG_I) { }      // IntReg[A] := BigReg[B] — native overflow check
    value(178; CONV_I_CHAR) { }     // IntReg[A] := (Char)IntReg[B] — native checked 0..65535
    value(179; CONV_I_BYTE) { }     // IntReg[A] := (Byte)IntReg[B] — native checked 0..255
    value(180; CONV_T_CODE) { }     // TextReg[A] := UpperCase(TextReg[B]) — text->code value conversion
    value(181; TO_TEXT) { }         // TextReg[A] := Format(<reg B of class C>) — concat/Error operand (§6.4 StringAndObjectConcatenation)

    // ===== Family 6 (192..223): calls — implemented in M5 (§7.3/§7.4) =====
    // M5 calling convention (documented in full in "ALI Interpreter" header): arguments are
    // pre-staged by ARG_VAL/ARG_REF into the soon-to-be callee frame window (callee param
    // slots are the FIRST slots of the new frame), then CALL pushes the frame. RESULT_FETCH
    // copies the callee's result slot back into a caller register after return.
    value(192; CALL) { }            // M5: A = proc id; pushes frame, jumps to callee entry PC
    value(193; CALL_EXT) { }        // RESERVED M10: module handle + proc id + inline cache (§11)
    value(194; CALL_OBJ) { }        // RESERVED M11: source-harvested cross-object call (§18)
    value(195; CALL_BUILTIN) { }    // RESERVED M7: A = domain, B = builtin id
    value(196; CALL_NATIVE) { }     // RESERVED M11: hand-written native shim (§18.4)
    value(197; RET_VAL) { }         // M5: return-with-value (result already in callee result slot); pops frame
    // --- M5 appends (next free ordinals in the call family; §3.3 append-only) ---
    value(198; ARG_VAL) { }         // M5: A = callee param slot (rel), B = caller src reg (rel), C = reg class; copies by value into the callee window
    value(199; ARG_REF) { }         // M5: A = callee param slot (rel), B = caller src slot (rel or abs), C = class*4 + mode (0=local, 1=indirect var-param, 2=global abs, 3=object global: B is an offset in the current instance's block)
    value(200; RESULT_FETCH) { }    // M5: A = caller dest reg (rel), B = callee result slot (rel to popped callee frame), C = reg class
    value(201; GLOB_LOAD) { }       // M5: A = dest reg (rel), B = ABSOLUTE global slot, C = reg class (module-level vars live below the entry frame)
    value(202; GLOB_STORE) { }      // M5: A = ABSOLUTE global slot, B = src reg (rel), C = reg class
    // M11 phase B2: a HARVESTED OBJECT's global. Same shape as GLOB_LOAD/GLOB_STORE except the
    // slot operand is an OFFSET inside the object's per-instance block; the absolute slot is
    // that offset plus the base of the block belonging to the frame's CURRENT INSTANCE (the
    // hidden instance-index parameter, "ALI Symbol Table".GetProcSelfRow). Two live variables of
    // the same object therefore no longer share one copy of its globals.
    value(203; SELF_LOAD) { }       // A = dest reg (rel), B = offset in block, C = reg class
    value(204; SELF_STORE) { }      // A = offset in block, B = src reg (rel), C = reg class

    // ===== Family 7 (224..255): records — M6 (§7.5); ordinal space frozen =====
    // Operand conventions documented in "ALI Interpreter".ExecRecordOp. Handle operands are
    // ABSOLUTE (separate handle space, §7.5); scalar operands are frame-relative. Field/
    // filter opcodes pack (fieldNo*16 + regClass) or (valueReg*16 + regClass) into C.
    value(224; REC_INIT) { }
    value(225; REC_RESET) { }
    value(226; REC_GET) { }
    value(227; REC_FIND) { }        // B = which: set/first/last
    value(228; REC_NEXT) { }
    value(229; REC_INSERT) { }      // B = run-trigger flag
    value(230; REC_MODIFY) { }
    value(231; REC_DELETE) { }
    value(232; REC_DELETEALL) { }
    value(233; REC_MODIFYALL) { }
    value(234; REC_SETRANGE) { }
    value(235; REC_SETFILTER) { }
    value(236; REC_SETCURRENTKEY) { }
    value(237; REC_COUNT) { }
    value(238; REC_ISEMPTY) { }
    value(239; REC_CALCFIELDS) { }
    value(240; REC_CALCSUMS) { }
    value(241; REC_VALIDATE) { }
    value(242; REC_TESTFIELD) { }
    value(243; REC_FIELDERROR) { }
    value(244; REC_TRANSFERFIELDS) { }
    value(245; REC_COPY) { }        // value-semantics assignment (Duplicate/SetView spike, §7.5)
    value(246; REC_OPEN) { }        // Handle Lifecycle Unification Phase 3: repurposed as REC_NEW (v1 never serialized bytecode, safe) — A = dest int reg (fresh handle), B = table id, C = IsTemp*2 + IsGlobal(0/1)
    value(247; REC_FLD_LOAD) { }    // bind-time-resolved field number (typed)
    value(248; REC_FLD_STORE) { }
    value(249; REC_FLD_LOAD_DYN) { }  // runtime field-number register (§19.5)
    value(250; REC_FLD_STORE_DYN) { }
    value(251; COMMIT) { }          // real commit in Normal; no-op'd in Simulation (CommitBehavior::Ignore, §8)

    // ===== Family 8 (256..287): arrays (M6, re-encoded §20 handle-based multidim) + stream
    // RefShim ops (§19.7). An array VALUE is now an Int handle (like List/Dict, §20.2/20.3) —
    // element storage moved to "ALI Array Runtime"; ARR_LOAD/STORE decode the handle to a
    // block base + TotalN and take an already-computed FLAT index register (§20.7 row-major
    // fold, done by the lowerer with per-dimension bounds via ARR_DIM_CHECK below). Ordinals
    // are NOT yet frozen (M8 benchmark pending, see header) — re-encoded in place rather than
    // appending new ordinals.
    value(256; ARR_LOAD) { }        // A = dest reg, B = handle reg (frame-relative Int reg), C = flatIndexReg*16 + elemClass
    value(257; ARR_STORE) { }       // A = handle reg (frame-relative Int reg), B = src reg, C = flatIndexReg*16 + elemClass
    // Stream ops — handle operands are ABSOLUTE (stream handle space); text/bool/int are
    // frame-relative. Conventions in "ALI Interpreter".ExecStreamOp.
    value(258; STRM_OPEN) { }       // Handle Lifecycle Unification Phase 3: repurposed as STRM_NEW — A = dest int reg (fresh handle), B = IsOut*2 + IsGlobal(0/1)
    value(259; STRM_LINK) { }       // A = inHandle, B = outHandle (share backing for a round-trip)
    value(260; STRM_WRITETEXT) { }  // A = handle, B = src text reg, C = optional Length int reg (0 = absent; -1 = zero-arg WriteText(), i.e. line terminator only — B unused)
    value(261; STRM_WRITELINE) { }  // A = handle, B = src text reg
    value(262; STRM_READTEXT) { }   // A = dest text reg, B = handle, C = destIntReg(chars read)*100000 + optional Length int reg (0 = absent)
    value(263; STRM_EOS) { }        // A = dest bool reg, B = handle
    value(264; STRM_LENGTH) { }     // A = dest int reg, B = handle

    // ===== Family 9 (265..296): record methods, batch 2 (native-Record-method sweep) =====
    // Same conventions as family 7: handle operands ABSOLUTE, scalars frame-relative.
    value(265; REC_RENAME) { }         // A = handle, B = operand-pool start, C = destBoolReg*32(unused)+ArgCount — mirrors REC_GET (§7.5)
    value(266; REC_COPY_REC) { }       // A = dest handle, B = src handle, C = includeFilters(1/0) — distinct from REC_COPY (assignment)
    value(267; REC_COPYFILTERS) { }    // A = dest handle, B = src handle
    value(268; REC_SETRECFILTER) { }   // A = handle
    value(269; REC_TRUNCATE) { }       // A = handle, B = run-trigger flag — BC27+ only (guarded by #if BC27_OR_LATER at emission)
    value(270; REC_SETRANGE_CLR) { }   // SetRange(field) — 1-arg clear-filter form: A = handle, B = field no
    value(271; REC_SETRANGE_2) { }     // SetRange(field, from, to) — A = handle, B = operand-pool start (2 entries, regIdx*16+class), C = field no
    value(272; REC_ISTEMPORARY) { }    // A = handle, B = dest bool reg
    value(273; REC_COUNTAPPROX) { }    // A = handle, B = dest int reg
    value(274; REC_READPERMISSION) { } // A = handle, B = dest bool reg
    value(275; REC_WRITEPERMISSION) { }// A = handle, B = dest bool reg
    value(276; REC_GETFILTER) { }      // A = dest text reg, B = handle, C = fieldNo
    value(277; REC_GETFILTERS) { }     // A = dest text reg, B = handle
    value(278; REC_HASFILTER) { }      // A = handle, B = dest bool reg
    value(279; REC_COPYFILTER) { }     // A = source handle, B = TARGET handle (= A for a same-record
                                       // copy), C = operand-pool start: [fromFieldNo, toFieldNo].
                                       // The field numbers moved out of a packed operand because
                                       // packing capped them at 4095 — extension fields start at
                                       // 50000, and the target is usually another table's field.
    value(280; REC_GETRANGEMIN) { }    // A = dest reg, B = handle, C = fieldNo*16 + destClass
    value(281; REC_GETRANGEMAX) { }    // A = dest reg, B = handle, C = fieldNo*16 + destClass
    value(282; REC_TABLENAME) { }      // A = dest text reg, B = handle
    value(283; REC_TABLECAPTION) { }   // A = dest text reg, B = handle
    value(284; REC_FQNAME) { }         // A = dest text reg, B = handle (FullyQualifiedName)
    // NOTE: SetCurrentKey(Any,...) reuses the family-7 REC_SETCURRENTKEY (236) with the
    // multi-field-numbers-in-the-operand-pool shape (like REC_CALCFIELDS) — no separate
    // ordinal needed (285 was a duplicate, removed before ever being emitted).
    value(286; REC_ASCENDING_GET) { }  // A = handle, B = dest bool reg
    value(287; REC_ASCENDING_SET) { }  // A = handle, B = src bool reg
    value(288; REC_SETASCENDING) { }   // A = handle, B = fieldNo, C = src bool reg*2 packing unused (bool read directly)
    value(289; REC_GETASCENDING) { }   // A = handle, B = fieldNo, C = dest bool reg
    value(290; REC_CURRENTKEY) { }     // A = dest text reg, B = handle
    value(291; REC_MARK_SET) { }       // A = handle, B = src bool reg
    value(292; REC_MARK_GET) { }       // A = handle, B = dest bool reg
    value(293; REC_CLEARMARKS) { }     // A = handle
    value(294; REC_MARKEDONLY_SET) { } // A = handle, B = src bool reg
    value(295; REC_MARKEDONLY_GET) { } // A = handle, B = dest bool reg
    value(296; REC_GETPOSITION) { }    // A = dest text reg, B = handle
    value(297; REC_SETPOSITION) { }    // A = handle, B = src text reg
    value(298; REC_GETVIEW) { }        // A = dest text reg, B = handle, C = includeSortOrder(1/0)
    value(299; REC_SETVIEW) { }        // A = handle, B = src text reg
    value(300; REC_CHANGECOMPANY) { }  // A = handle, B = src text reg
    value(301; REC_CURRENTCOMPANY) { } // A = dest text reg, B = handle
    value(302; REC_FIELDNAME) { }      // A = dest text reg, B = handle, C = fieldNo
    value(303; REC_FIELDCAPTION) { }   // A = dest text reg, B = handle, C = fieldNo
    value(304; REC_TESTFIELD_VAL) { }  // A = handle, B = valueReg*16 + valueClass, C = fieldNo*16 (TestField(field, value) — 2-arg value-match form; REC_TESTFIELD(242) is the 1-arg non-zero/non-blank form)
    // ===== M7 additions (§1.1/§8/§19.4/§19.6): builtin calls + Evaluate/Clear =====
    value(305; EVALUATE_TARGET) { }    // A = target var slot, B = operand-pool start (text + optional numeric-format arg), C = destBoolReg*16 + targetTypeOrd(mod 16 index into a small map) — see LowerBuiltinCall/ExecEvaluateTarget for exact packing
    value(306; CLEAR_TARGET) { }       // A = target var slot, B = targetTypeOrd, C mod 4 = 0 local, 1 global (absolute), 2 object global (A = offset in the current instance's block), 3 object global of instance C div 4 (Clear(MyCU))
    value(307; CALL_BUILTIN_LIVE) { }  // A = BuiltinId, B = operand-pool start (each entry regIdx*16+class, read LIVE — CONCAT_N/REC_GET convention), C = OutReg*512 + OutCls*32 + ArgCount. Supersedes the RESERVED CALL_BUILTIN(195) placeholder — that ordinal is left reserved/unused to avoid renumbering M5-era comments; this is the M7 SHIPPED opcode.

    // ===== M9 addition: TextBuilder RefShim (§19.7-style handle; own handle space) =====
    value(308; TB_METHOD) { }          // A = handle (Int register, Handle Lifecycle Unification Phase 3 — was ABSOLUTE), B = operand-pool start (each entry regIdx*16+class, read LIVE — CALL_BUILTIN_LIVE convention), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount. MethodId 0 = "New" (A/B unused, ArgCount's low digit repurposed as IsGlobal). See "ALI Interpreter".ExecTextBuilderOp / "ALI Binder".TextBuilderMethodId for the method-id table.

    // ===== M6 addition: field-load / lock / key-index record members (§7.5) =====
    // Field-list opcodes share the CalcFields operand-pool shape (B = pool start with field
    // numbers) but also return a Boolean: C = destBoolReg*32 + count (count <= 16 → 5 bits).
    value(309; REC_SETAUTOCALCFIELDS) { } // A = handle, B = field-no pool start, C = destBoolReg*32 + count
    value(310; REC_SETLOADFIELDS) { }     // A = handle, B = field-no pool start, C = destBoolReg*32 + count
    value(311; REC_ADDLOADFIELDS) { }     // A = handle, B = field-no pool start, C = destBoolReg*32 + count
    value(312; REC_LOADFIELDS) { }        // A = handle, B = field-no pool start, C = destBoolReg*32 + count
    value(313; REC_AREFIELDSLOADED) { }   // A = handle, B = field-no pool start, C = destBoolReg*32 + count
    value(314; REC_LOCKTABLE) { }         // A = handle, B = wait flag (const-folded 0/1)
    value(315; REC_READCONSISTENCY_GET) { } // A = handle, B = dest bool reg (getter only)
    value(317; REC_FIELDCOUNT) { }        // A = handle, B = dest int reg
    value(318; REC_FIELDEXIST) { }        // A = dest bool reg, B = handle, C = src int reg (field number)
    value(319; REC_KEYCOUNT) { }          // A = handle, B = dest int reg
    value(320; REC_CURRENTKEYINDEX_GET) { } // A = handle, B = dest int reg
    value(321; REC_CURRENTKEYINDEX_SET) { } // A = handle, B = src int reg
    value(322; TXT_CHAR_GET) { }       // §19.4-analog: A = dest int reg (Char, 1-based bounds-checked), B = src text reg, C = index int reg
    value(323; TXT_CHAR_SET) { }       // A = text reg (in/out), B = char-code int reg (ASCII), C = index int reg — bounds-checked
    value(324; TXT_CHAR_SET_TEXT) { }  // A = text reg (in/out), B = single-character src text reg, C = index int reg — bounds- and length-checked
    value(325; CHAR_TO_TEXT) { }       // §6.4: TextReg[A] := printable 1-char text for the Char code point in IntReg[B] (C unused) — distinct from TO_TEXT(181), which formats an Int register as its DECIMAL digits; a Char register must format as the character itself

    // ===== List/Dictionary RefShim (see ListDictionaryPlan.md) =====
    // A List/Dict VALUE is an Int handle (RegClassInt) — same register class as any other
    // Int variable, so it lives in a normal frame-relative/global Int slot. The handle
    // integer itself encodes which per-class runtime bank holds the backing collection:
    // handle = classIndex*1_000_000 + bankIndex (List) or (keyClass*16+valueClass)*1_000_000
    // + bankIndex (Dictionary) — classIndex/keyClass/valueClass are "ALI Type Rules"
    // RegClass* ordinals (1..10) directly, no separate class-numbering scheme. See
    // "ALI List Runtime" / "ALI Dict Runtime" for the handle decode and "ALI Interpreter".
    // ExecListOp/ExecDictOp for the operand convention (shared by every method opcode
    // below): A = handle reg (frame-relative Int reg holding the LIVE handle value),
    // B = operand-pool start for the method's value args (each pool entry = regIdx*16+
    // regClass, read live — CALL_BUILTIN_LIVE/TB_METHOD convention), C = OutReg*100 +
    // ArgCount (OutReg = 0 when the method returns nothing; OutCls is never packed — the
    // Exec procedure derives it from the handle's classIndex for T-typed results, or a
    // fixed class for Bool/Int-typed results). LIST_NEW/DICT_NEW are the exception: they
    // do not take a receiver handle (A = dest reg for the freshly allocated handle).
    value(326; LIST_NEW) { }        // A = dest int reg (fresh handle), B = elemClass (RegClass ordinal 1-10), C = 0
    value(327; LIST_ADD) { }        // Add(value)
    value(328; LIST_GET) { }        // Get(index) -> T
    value(329; LIST_SET) { }        // Set(index, value) -> T (old)
    value(330; LIST_COUNT) { }      // Count() -> Integer
    value(331; LIST_CONTAINS) { }   // Contains(value) -> Boolean
    value(332; LIST_INDEXOF) { }    // IndexOf(value) -> Integer
    value(333; LIST_REMOVE) { }     // Remove(value) -> Boolean
    value(334; LIST_REMOVEAT) { }   // RemoveAt(index)
    value(335; LIST_REMOVERANGE) { }// RemoveRange(index, count)
    value(336; LIST_INSERT) { }     // Insert(index, value)
    value(337; LIST_ADDRANGE) { }   // AddRange(list) — B's sole pool entry is the SOURCE list's handle reg (class = RegClassInt)
    value(338; LIST_GETRANGE) { }   // GetRange(index, count) -> List of [T] (fresh handle)
    value(339; LIST_REVERSE) { }    // Reverse()
    value(340; LIST_TOARRAY) { }    // RESERVED v1: bound but rejected with ALI985 (array-threading deferred, see plan §6)

    // ===== Dictionary RefShim =====
    value(341; DICT_NEW) { }        // A = dest int reg (fresh handle), B = keyClass*16+valueClass, C = 0
    value(342; DICT_ADD) { }        // Add(key, value) — native errors if key exists
    value(343; DICT_SET) { }        // Set(key, value) — add-or-update
    value(344; DICT_GET) { }        // Get(key) -> V
    value(345; DICT_CONTAINSKEY) { }// ContainsKey(key) -> Boolean
    value(346; DICT_REMOVE) { }     // Remove(key) -> Boolean
    value(347; DICT_COUNT) { }      // Count() -> Integer
    value(348; DICT_KEYS) { }       // Keys() -> List of [K] (fresh handle)
    value(349; DICT_VALUES) { }     // Values() -> List of [V] (fresh handle)
                                    // (350 is MOV_RECID — the two-arg Get is DICT_TRYGET 460)

    // ===== RecordID (own register class, RegClassRecordId=12) =====
    value(350; MOV_RECID) { }       // RecordIdReg[A] := RecordIdReg[B]
    value(351; CMP_EQ_RECID) { }    // equality only — RecordID has no ordering
    value(352; CMP_NE_RECID) { }
    value(353; REC_GET_BY_ID) { }   // A=record handle, B=RecordID reg, C=destBoolReg*2+conditional — Get(RecordID) / GetRecord() bridge (§7.5-analog)
    value(354; REC_RECORDID_GET) { }// A=dest RecordID reg, B=record handle — Record.RecordId()
    value(355; RECID_TABLENO) { }   // A=dest int reg, B=src RecordID reg — RecordID.TableNo() (native errors if blank)

    // ===== DateFormula (own register class, RegClassDateFormula=13) — no literal syntax
    // exists in AL (unlike Date/Time); DateFormula values arise only via implicit Text
    // conversion (CONV_TEXT_DF), Evaluate() (shares EVALUATE_TARGET/305), or var copy
    // (shares MOV_DF/GLOB_LOAD/STORE_IND like every other register class) — so no
    // LOAD_CONST_DF is needed. =====
    value(356; MOV_DF) { }          // DateFormulaReg[A] := DateFormulaReg[B]
    value(357; CMP_EQ_DF) { }       // equality only — DateFormula has no ordering
    value(358; CMP_NE_DF) { }
    value(359; CONV_TEXT_DF) { }    // DateFormulaReg[A] := native Text->DateFormula conversion of TextReg[B]; native runtime error on bad syntax

    // ===== Option/Enum addition: A = out Text reg, B = src Int reg (ordinal), C = set id
    // (memoized in "ALI Option Meta"). Emitted by the lowerer ONLY for Format(x) arity-1 when
    // x is statically TOption/TEnum; every other formatting path keeps the generic TO_TEXT. =====
    value(360; OPT_TO_TEXT) { }

    // ===== DateTime/Time + numeric (native DateTimeAndIntegerAddition/Subtraction,
    // TimeAndIntegerAddition/Subtraction — BinaryOperatorKind.cs 0x1149/0x1249/0x113B/0x123B).
    // RHS pre-converted to Int by the lowerer (mirrors ADD_DATE_I/SUB_DATE_I). =====
    value(361; ADD_DT_I) { }        // DateTime + Int -> DateTime
    value(362; SUB_DT_I) { }        // DateTime - Int -> DateTime
    value(363; ADD_TIME_I) { }      // Time + Int -> Time
    value(364; SUB_TIME_I) { }      // Time - Int -> Time

    // ===== Array intrinsics (re-encoded §20: handle-based, no more base*8192+N spans) =====
    value(365; ARR_COMPRESS) { }    // CompressArray(Text array): A = handle reg (frame-relative Int reg), B = dest count int reg, C = 0 (unused). Compacts non-empty elements to the front over TotalN, blanks the tail, writes count.
    value(366; ARR_COPY) { }        // CopyArray(dest, src, pos[, len]): A = operand-pool start [destHandleReg, srcHandleReg, posReg, lenReg], B = element reg class, C = hasLength (1/0)

    // ===== §20 additions: ARR_NEW (block allocation) + ARR_DIM_CHECK (per-dimension bounds,
    // native-exact multidim indexing, §20.7). Emitted at proc/entry prologue (ARR_NEW, one per
    // array local/global) and by LowerArrayLoad/Store (one ARR_DIM_CHECK per index BEFORE the
    // flat-index fold, so a wrong i_k always raises even if the folded flat index would still
    // land in range — see plan §20.7 option (b)). =====
    value(367; ARR_NEW) { }         // A = dest int reg (fresh handle; stored via StoreToSym like LIST_NEW), B = ElemClass (RegClass ordinal 1..10), C = TotalN*2 + IsGlobal(0/1) — mirrors "ALI Array Runtime".NewBlock
    value(368; ARR_DIM_CHECK) { }   // A = index reg (frame-relative), B = dimension size Nk (compile-time constant), C = 1-based dimension number (for the error message). Native-bounds-checks index 1..Nk, raises ALI957 naming the dimension.
    value(369; REC_FILTERGROUP_GET) { }
    value(370; REC_FILTERGROUP_SET) { }

    // ===== Dialog RefShim (progress window; own handle space, §8) =====
    value(371; DLG_METHOD) { }      // A = handle (Int register, Handle Lifecycle Unification Phase 3 — was ABSOLUTE; for MethodId 0 "New", A = dest int reg for the fresh handle instead), B = operand-pool start (each entry regIdx*16+class, read LIVE), C = MethodId*100 + ArgCount (MethodId 0 repurposes ArgCount as IsGlobal). See "ALI Interpreter".ExecDialogOp / "ALI Binder".DialogMethodId.

    // ===== Variant box/unbox (§7.1/§19.2 fallback register file) — one boxing per crossing =====
    value(372; CONV_BOX) { }        // RegVariant[A] := ReadRegisterAsVariant(C mod 16 = source class, B); RegVarTag[A] := C div 16 (0 = scalar, else aggregate ALI type for handle boxes)
    value(373; CONV_UNBOX) { }      // WriteRegisterFromVariant(C = target class, A, RegVariant[B]) — unbox a Variant into a typed register (native runtime error on type mismatch)
    value(374; BOX_REC) { }         // A = dest variant reg, B = record handle (ABSOLUTE) — box the handle, tag = Record (§19.2 reference semantics)
    value(375; UNBOX_REC) { }       // A = dest record handle (ABSOLUTE), B = src variant reg — REC_COPY content from the boxed record handle

    // ===== Dispatch-count optimization (P1-P3): charged back-edges + fused branch-compares
    // + int-immediate forms. STMT(1) is LEGACY — the lowerer no longer emits it (debug rows
    // are stamped per instruction in the module; the runaway budget is charged at BACK-EDGES
    // and CALLs only). A back-edge is any jump whose resolved target <= its own PC; the
    // lowerer's ClassifyBackEdges pass rewrites plain jumps/branches to their charged _BACK
    // twin (fixed op offsets: JMP/JIF/JIT +374, fused branches +24) after all targets patch.
    // Fused branch operands: A = target PC, B = left int reg, C = right int reg (or the
    // IMMEDIATE int value itself in the _IMM forms — no const pool indirection).
    // BF_* = branch when the comparison is FALSE (if/while exits), BT_* = branch when TRUE
    // (case-label hits). Comparison order in every 6-block: EQ, NE, LT, LE, GT, GE.
    value(376; JMP_BACK) { }            // charged JMP: A = target PC (<= own PC)
    value(377; JMP_IF_FALSE_BACK) { }   // charged JMP_IF_FALSE: A = target, B = bool reg
    value(378; JMP_IF_TRUE_BACK) { }    // charged JMP_IF_TRUE
    value(379; BF_EQ_I) { }             // if IntReg[B] <> IntReg[C] then PC := A
    value(380; BF_NE_I) { }
    value(381; BF_LT_I) { }             // if IntReg[B] >= IntReg[C] then PC := A
    value(382; BF_LE_I) { }
    value(383; BF_GT_I) { }
    value(384; BF_GE_I) { }
    value(385; BT_EQ_I) { }             // if IntReg[B] = IntReg[C] then PC := A
    value(386; BT_NE_I) { }
    value(387; BT_LT_I) { }
    value(388; BT_LE_I) { }
    value(389; BT_GT_I) { }
    value(390; BT_GE_I) { }
    value(391; BF_EQ_I_IMM) { }         // if IntReg[B] <> C then PC := A (C = immediate value)
    value(392; BF_NE_I_IMM) { }
    value(393; BF_LT_I_IMM) { }
    value(394; BF_LE_I_IMM) { }
    value(395; BF_GT_I_IMM) { }
    value(396; BF_GE_I_IMM) { }
    value(397; BT_EQ_I_IMM) { }
    value(398; BT_NE_I_IMM) { }
    value(399; BT_LT_I_IMM) { }
    value(400; BT_LE_I_IMM) { }
    value(401; BT_GT_I_IMM) { }
    value(402; BT_GE_I_IMM) { }
    value(403; BF_EQ_I_BACK) { }        // charged twins of 379-402 (uniform +24)
    value(404; BF_NE_I_BACK) { }
    value(405; BF_LT_I_BACK) { }
    value(406; BF_LE_I_BACK) { }
    value(407; BF_GT_I_BACK) { }
    value(408; BF_GE_I_BACK) { }
    value(409; BT_EQ_I_BACK) { }
    value(410; BT_NE_I_BACK) { }
    value(411; BT_LT_I_BACK) { }
    value(412; BT_LE_I_BACK) { }
    value(413; BT_GT_I_BACK) { }
    value(414; BT_GE_I_BACK) { }
    value(415; BF_EQ_I_IMM_BACK) { }
    value(416; BF_NE_I_IMM_BACK) { }
    value(417; BF_LT_I_IMM_BACK) { }
    value(418; BF_LE_I_IMM_BACK) { }
    value(419; BF_GT_I_IMM_BACK) { }
    value(420; BF_GE_I_IMM_BACK) { }
    value(421; BT_EQ_I_IMM_BACK) { }
    value(422; BT_NE_I_IMM_BACK) { }
    value(423; BT_LT_I_IMM_BACK) { }
    value(424; BT_LE_I_IMM_BACK) { }
    value(425; BT_GT_I_IMM_BACK) { }
    value(426; BT_GE_I_IMM_BACK) { }
    value(427; ADD_I_IMM) { }           // IntReg[A] := IntReg[B] + C (C = immediate value)
    value(428; SUB_I_IMM) { }           // IntReg[A] := IntReg[B] - C
    value(429; CMP_EQ_I_IMM) { }        // BoolReg[A] := IntReg[B] = C (C = immediate value)
    value(430; CMP_NE_I_IMM) { }
    value(431; CMP_LT_I_IMM) { }
    value(432; CMP_LE_I_IMM) { }
    value(433; CMP_GT_I_IMM) { }
    value(434; CMP_GE_I_IMM) { }

    // ===== M10 addition: Http* RefShim (Int-handle, same scheme as List/Dictionary — no own
    // handle space). A = receiver handle reg (frame-relative Int reg, LIVE; ignored for New
    // ids), B = operand-pool start (each entry regIdx*16+class, read LIVE — CALL_BUILTIN_LIVE/
    // TB_METHOD convention), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount.
    // MethodId ranges discriminate the receiver kind: 1-19 HttpClient, 20-39
    // HttpRequestMessage, 40-59 HttpResponseMessage, 60-79 HttpContent, 80-99 HttpHeaders;
    // each range's first id (1/20/40/60/80) is the compiler-internal "New" allocator, emitted
    // by the lowerer at declaration (mirrors LIST_NEW/DICT_NEW), never bound from user text.
    // OutCls = RegClassInt for handle-returning methods (e.g. Response.Content()) — a fresh
    // handle is just another Int result, no assignment-lowering mechanic needed. See
    // "ALI Interpreter".ExecHttpOp / "ALI Binder".HttpMethodId.
    value(435; HTTP_METHOD) { }

    // ===== Handle Lifecycle Unification: escape detection (see "ALI Interpreter" header
    // §20.5/§HandleLifecycle) — a handle-kind value (Array/List/Dictionary/Http*) being stored
    // through a var-param alias or into a global must stop being owned by the CURRENT frame's
    // alloc stack; ownership passes to wherever the storage lives. Emitted by "ALI Lowerer".
    // StoreToSym immediately BEFORE the STORE_IND/GLOB_STORE it guards. =====
    value(436; HANDLE_ESCAPE) { }   // A = src Int reg (frame-relative, holds the handle value), B = "ALI TypeKind" ordinal of the handle, C = 0

    // ===== Handle Lifecycle Unification Phase 5: array-return =====
    // `localArrayVar := ProcCall()` — the sole legal array-assignment shape (see "ALI Binder"
    // BindAssignment's Array block). The new handle was already escape-tracked into THIS
    // frame by PopFrame when the call returned (Array is a plain IsAllocStackHandleKind
    // member, same machinery as List/Dictionary/Http*); ARR_REBIND only needs to free the
    // var's OLD block (guaranteed frame-local — the binder requires a local target) and
    // rebind the register.
    value(437; ARR_REBIND) { }   // A = array var's Int reg (frame-relative), B = src Int reg holding the fresh handle, C = 0

    // --- Record family, second sweep (§7.5): Find(Text)/GetBySystemId/links/isolation/
    // permission/security/record-level-locking. Routed to ExecRecordOp via the dispatch
    // case list; numbers are non-contiguous with the original record family but that is
    // irrelevant — membership in the case list is what routes them. ---
    value(438; REC_FIND_TEXT) { }           // A=handle, B=which text reg, C=destBoolReg*2+conditional
    value(439; REC_GETBYSYSTEMID) { }       // A=handle, B=guid reg, C=destBoolReg*2+conditional
    value(440; REC_ADDLINK) { }             // A=handle, B=url text reg, C=descTextReg*8192+destIntReg (descReg 0 = no description)
    value(441; REC_DELETELINK) { }          // A=handle, B=src int reg (link id)
    value(442; REC_DELETELINKS) { }         // A=handle
    value(443; REC_COPYLINKS) { }           // A=dest handle, B=src handle
    value(444; REC_HASLINKS) { }            // A=handle, B=dest bool reg
    value(445; REC_READISOLATION_GET) { }   // A=handle, B=dest int reg (IsolationLevel ordinal)
    value(446; REC_READISOLATION_SET) { }   // A=handle, B=src int reg (IsolationLevel ordinal)
    value(447; REC_SETPERMISSIONFILTER) { } // A=handle
    value(448; REC_SECURITYFILTERING_GET) { } // A=handle, B=dest int reg (SecurityFilter ordinal)
    value(449; REC_SECURITYFILTERING_SET) { } // A=handle, B=src int reg (SecurityFilter ordinal)
    value(450; REC_RECORDLEVELLOCKING) { }  // A=handle, B=dest bool reg

    // ===== Feature 2 addition: Json* RefShim (JsonObject/JsonArray/JsonToken/JsonValue).
    // Int-handle reference, same scheme as Http* (M10, HTTP_METHOD header above) — A =
    // receiver handle reg (frame-relative Int reg, LIVE; ignored for New ids), B = operand-
    // pool start (each entry regIdx*16+class, read LIVE — CALL_BUILTIN_LIVE/TB_METHOD/
    // HTTP_METHOD convention), C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount.
    // Unlike Http*, all 4 kinds share ONE unified bank (List of [JsonToken]) in "ALI Json
    // Runtime" — every AL Json* type is a reference wrapper over the same underlying DOM, so
    // one bank + AsObject()/AsArray()/AsValue() per-kind accessors is sufficient (no box-
    // codeunit indirection needed, unlike HttpClient/HttpRequestMessage/... which are not
    // valid List of [T] element types).
    // MethodId ranges discriminate the receiver kind: 1-25 JsonObject, 26-50 JsonArray,
    // 51-75 JsonToken, 76-99 JsonValue; each range's first id (1/26/51/76) is the compiler-
    // internal "New" allocator, emitted by the lowerer at declaration (mirrors LIST_NEW/
    // DICT_NEW/HTTP_METHOD New ids), never bound from user text. See "ALI Interpreter".
    // ExecJsonOp / "ALI Binder".JsonMethodId.
    value(451; JSON_METHOD) { }

    // JSON_METHOD2 — overflow id space for Json* methods beyond the 99-id C-pack limit of
    // JSON_METHOD (same A/B/C packing; C's MethodId field carries ACTUAL id - 100, so packed
    // 1-99 = actual 101-199). Carries the typed GetX helper getters (GetText/GetInteger/
    // GetObject/... [, DefaultIfNotFound]): actual 101-125 JsonObject, 131-155 JsonArray.
    // See "ALI Interpreter".ExecJsonOp2 / "ALI Binder".JsonMethodId.
    value(452; JSON_METHOD2) { }

    // ===== BLOB table fields (Rec.MyBlob.<method>) — executed by ExecRecordOp, so the record
    // handle operand follows the family-7 convention (register holding the handle) and the
    // field number is a literal in C. The stream operand is a register holding a stream handle
    // (Handle Lifecycle Unification), the same shape STRM_* uses.
    value(453; REC_BLOB_INSTREAM) { }   // A = rec handle reg, B = stream handle reg, C = fieldNo
    value(454; REC_BLOB_OUTSTREAM) { }  // A = rec handle reg, B = stream handle reg, C = fieldNo
    value(455; REC_BLOB_HASVALUE) { }   // A = dest bool reg, B = rec handle reg, C = fieldNo
    value(456; REC_BLOB_LENGTH) { }     // A = dest int reg, B = rec handle reg, C = fieldNo
    value(457; REC_SETFILTER_ARGS) { }  // A = handle, B = operand-pool start (0=fieldNo, 1=filterText reg packed, 2.. = %1-substitution value regs packed), C = substitution value count (1..14)

    // ===== Feature 3: Xml* RefShim (all 16 Xml types, XML_DESIGN.md). Int-handle reference,
    // same A/B/C packing as JSON_METHOD — A = receiver handle reg (frame-relative Int reg,
    // LIVE; 0 / NOT READ for New ids 1-16 and static ids), B = operand-pool start (each entry
    // regIdx*16+class, read LIVE; variadic content methods add a PAIR per content arg:
    // regIdx*16+class THEN the arg's bound TypeOrd — XML_DESIGN.md §6), C = OutReg*100000 +
    // OutCls*10000 + MethodId*100 + ArgCount.
    // DEVIATION from JSON_METHOD: method ids are NOT partitioned per receiver kind — the
    // receiver kind is statically known at bind time and the 10 node kinds share ONE unified
    // bank (List of [XmlNode]) in "ALI Xml Runtime", so one shared id serves a method on
    // every legal receiver kind (AddAfterSelf/WriteTo/SelectNodes/...); the runtime narrows
    // via AsXml<Kind>() and dispatches on the ACTUAL node kind where behavior differs
    // (Value/LocalName/...). Ids 1-16 ("New", id = TypeKind ordinal - 101) are compiler-
    // internal allocators emitted at declaration (IsGlobal in the low ArgCount slot — Json
    // New convention). Static ids (no receiver, A = 0): 60-65 XmlDocument Create/ReadFrom.
    // Full id table: XML_DESIGN.md §3. See "ALI Interpreter".ExecXmlOp / "ALI Binder".
    // BindXmlMethod (mark -12000, MOST negative — checked FIRST in every dispatch cascade).
    value(458; XML_METHOD) { }

    // XML_METHOD2 — overflow id space for Xml* methods beyond the 99-id C-pack limit of
    // XML_METHOD (same A/B/C packing; C's MethodId field carries ACTUAL id - 100, so packed
    // 1-99 = actual 101-199). Carries XmlElement statics/instance tail (101-113), XmlAttribute
    // (116-120), XmlNodeList (123-124, NATIVE 1-BASED), XmlAttributeCollection (127-136),
    // simple-node Create statics (140-148), XmlDeclaration (150-155), XmlDocumentType
    // (158-165), XmlProcessingInstruction (168), XmlNamespaceManager (171-179),
    // Xml{Read,Write}Options (182-185). Static ids in this space (A = 0): 101-104, 116-118,
    // 140-148. See "ALI Interpreter".ExecXmlOp2 / XML_DESIGN.md §3.
    value(459; XML_METHOD2) { }

    // Dictionary Get(key, var value) -> Boolean (native two-arg overload). Same A/B/C shape as
    // the other DICT_* ops, executed by ExecDictOp; operand 1 is the CALLER's value register
    // (read live), written back only on a hit — on a miss it keeps the value it came in with,
    // so the lowerer's unconditional StoreToSym leaves the variable untouched. Numbered out of
    // the 341-349 block because 350+ is already MOV_RECID (enum values are append-only).
    value(460; DICT_TRYGET) { }

    // Native typed stream I/O (§19.7): OutStream.Write(value) / InStream.Read(var target).
    // Both go through "ALI Stream Runtime".WriteValue/ReadValue, which resolves the native
    // typed overload from the TypeKind ordinal. Numbered outside the 258-264 stream block
    // (enum values are append-only) but dispatched by the same ExecStreamOp arm.
    value(461; STRM_WRITEVAL) { }   // A = handle reg, B = value reg, C = destIntReg(byte count)*100000 + typeOrd*16 + valueClass
    value(462; STRM_READVAL) { }    // A = dest value reg (target's class), B = handle reg, C = destIntReg(byte count)*100000 + typeOrd*16 + targetClass, or -poolIdx when a Length is given (pool[idx] = that packing, pool[idx+1] = Length int reg)

    // InStream positioning (§19.7) — native InStream.Position (get/set) / ResetPosition().
    value(463; STRM_POSGET) { }     // A = dest int reg, B = handle reg
    value(464; STRM_POSSET) { }     // A = handle reg, B = new-position int reg
    value(465; STRM_RESETPOS) { }   // A = handle reg

    // BigText RefShim — same A/B/C packing as TB_METHOD: A = handle (Int register), B =
    // operand-pool start (each entry regIdx*16+class, read LIVE), C = OutReg*100000 +
    // OutCls*10000 + MethodId*100 + ArgCount. MethodId 0 = "New" (A/B unused; IsGlobal in the
    // low ArgCount digit). GetSubText's `var` target rides the operand pool as a fresh temp the
    // lowerer stores back afterwards (the HttpContent.ReadAs mechanism). See
    // "ALI Interpreter".ExecBigTextOp / "ALI Binder".BigTextMethodId (mark -13000).
    value(466; BIGTEXT_METHOD) { }

    // SecretText members — A = receiver TEXT register (SecretText has no handle: its value is
    // the text itself), B = operand-pool start (unused, no method takes args), C = OutReg*100000
    // + OutCls*10000 + MethodId*100 + ArgCount. Ids: 1 IsEmpty()->Boolean, 2 Unwrap()->Text.
    value(467; SECRET_METHOD) { }

    // Media / MediaSet field members (`Rec.Picture.MediaId()`). A = record handle reg,
    // C = MethodId, and EVERYTHING else rides the operand pool starting at B (three ints —
    // there is no room left in C for a field number on top of out-reg/out-class):
    //   [B+0] = FieldNo   [B+1] = OutReg*16 + OutCls   [B+2] = ArgReg*16 + ArgCls (arg methods only)
    // Media ids 1-9, MediaSet ids 20-29 share one op (identical receiver shape). See
    // "ALI Interpreter".ExecMediaOp / "ALI Binder".MediaMethodId (mark -14000).
    value(468; MEDIA_METHOD) { }

    // Non-constant TextEncoding for the NEXT REC_BLOB_INSTREAM/OUTSTREAM (which carries
    // encoding 4 = "dynamic" in its packed C operand — there is no free operand left).
    // A = Int register holding the TextEncoding ordinal. Emitted immediately before it.
    value(469; REC_BLOB_ENC) { }

    // M11 phase C3 — native `Codeunit.Run(id[, Rec])`. The codeunit is executed by the PLATFORM,
    // never harvested, so this single instruction replaces a whole compiled unit.
    //   A = destination Boolean register, or 0 when the result is discarded (statement form:
    //       a failure then RAISES, exactly as native AL does with an unconsumed Run result)
    //   B = Int register holding the codeunit id
    //   C = Int register holding the record handle to pass by reference, or 0 for no record
    value(470; CU_RUN) { }

    // ===== User-declared RecordRef (P1) — the RecordRef-ONLY method surface =====
    // A RecordRef VALUE is the very same Int handle a Record variable carries: both index the
    // one "ALI Rec Runtime" bank of native RecordRefs (see that codeunit's header for why the
    // bank is an array and not a List). The ONLY thing that separates the two static types is
    // that a RecordRef's table id is unknown at BIND time, which is why:
    //   * every method that needs no table id at all (Find/FindSet/Count/Insert/SetView/...)
    //     is NOT re-implemented here — the binder routes it to the EXISTING REC_* opcode,
    //     receiver and all, because the receiver register already holds the same handle; and
    //   * every method that takes a FIELD NUMBER (SetRange/Validate/CalcFields/...) DOES live
    //     here (ids 18-39, phase P4) rather than on its REC_* twin: on a Record the number is
    //     resolved from a field NAME at bind time and burned into the instruction, while a
    //     RecordRef supplies it as a run-time Integer — and THIS opcode's operand pool is
    //     already the live-register kind (each entry regIdx*16+class), so a field number is
    //     just one more live operand. The runtime procedures called are the very same ones the
    //     REC_* twins call; they have always taken the field number as a plain Integer, so P4
    //     changed the ENCODING only and the Record fast path is byte-for-byte untouched.
    // So this opcode carries what a Record variable genuinely cannot express: opening and
    // closing the handle, asking the table id/name back, the Record<->RecordRef bridges, the
    // FieldRef/KeyRef constructors, and the run-time-field-number surface.
    //
    // Packing = the TB_METHOD convention:
    //   A = receiver handle reg (frame-relative Int reg, read LIVE; 0 before Open())
    //   B = operand-pool start (each entry regIdx*16+regClass, read LIVE)
    //   C = OutReg*100000 + OutCls*10000 + MethodId*100 + ArgCount        (ids 1-17)
    //   C = OutReg*100000 + Flags*10000  + MethodId*100 + ArgCount        (ids 18-39, P4)
    // For the P4 block the OutCls digit is repurposed as FLAGS (bit0 = "result consumed", the
    // optional-return contract ModifyAll needs and the one thing that cannot ride in the pool
    // because it is a property of the CALL SITE). The result class is derived from the method id
    // instead — RecordRefDynOutClass, the same trick FLD_METHOD uses wholesale — because
    // GetRangeMin/GetRangeMax return a VARIANT and class 11 does not fit in one digit.
    // Method ids (mirror "ALI Binder".RecordRefMethodId, mark -15000):
    //   1 Open(Integer|Text [, Boolean] [, Text])   2 Close()          3 Number()
    //   4 Name()        5 Caption()                 6 GetTable(Record) 7 SetTable(Record[,Bool])
    //   8 Duplicate()   9 FieldExist(Integer|Text) 10 SystemIdNo()
    //  11 SystemCreatedAtNo() 12 SystemCreatedByNo() 13 SystemModifiedAtNo()
    //  14 SystemModifiedByNo()
    //  15 Field(Integer|Text) -> FieldRef  16 FieldIndex(Integer) -> FieldRef
    //  17 KeyIndex(Integer) -> KeyRef
    //  --- P4, field number(s) FIRST in the pool, then the method's own arguments ---
    //  18 SetRange(f[,v[,hi]])   19 SetFilter(f,Text[,args…])  20 GetFilter(f) -> Text
    //  21 CopyFilter(fFrom,fTo)  22 GetRangeMin(f) -> Variant   23 GetRangeMax(f) -> Variant
    //  24 Validate(f,v)          25 ModifyAll(f,v[,Bool]) -> Bool
    //  26 CalcFields(f,…)        27 CalcSums(f,…)               28 TestField(f[,v])
    //  29 FieldError(f[,Text])   30 FieldName(f) -> Text        31 FieldCaption(f) -> Text
    //  32 SetAscending(f,Bool)   33 GetAscending(f) -> Bool     34 SetCurrentKey(f,…)
    //  35 SetAutoCalcFields(f,…) -> Bool                        36 SetLoadFields(f,…) -> Bool
    //  37 AddLoadFields(f,…) -> Bool  38 LoadFields(f,…) -> Bool
    //  39 AreFieldsLoaded(f,…) -> Bool
    //     (the five list forms keep their COUNT in ArgCount — bind-time-known even when the
    //     values are not — so nothing here is run-time variadic.)
    //  99 <compiler-internal> assert-open: emitted by the lowerer immediately BEFORE a routed
    //     REC_* instruction whose receiver is statically a RecordRef, so a use-before-Open()
    //     fails with the truthful ALI937 instead of an array-index-0 crash inside the runtime.
    //     Costs one dispatch per routed RecordRef call and exactly nothing on the Record path.
    // The overloads that differ only in ARGUMENT TYPE (Open by table id vs by table name,
    // FieldExist by number vs by name) deliberately share ONE id and branch on the operand's
    // register class at run time: the binder would otherwise have to bind the argument before
    // it can pick a method id, which is the one ordering the member-dispatch cascade forbids.
    value(471; REF_METHOD) { }

    // ===== FLD_METHOD (P2/P3) — user-declared FieldRef AND KeyRef =====
    //
    // ONE opcode for both families, because a KeyRef is four methods and a third opcode would
    // have bought nothing but a third dispatch arm. They are told apart by METHOD ID RANGE:
    // 1-39 FieldRef, 40-49 KeyRef. The binder never mixes them up — the receiver's static type
    // decides which id table it reads — so the runtime needs no tag bit.
    //
    // THE REPRESENTATION (this is the whole design, read it before touching anything):
    // a FieldRef value is NOT a native FieldRef stored anywhere. It is a plain Integer that
    // PACKS THE PAIR (record handle, field number):
    //
    //     FieldRef handle = FieldNoSlot * 2048 + RecHandle
    //     KeyRef   handle = KeyIndex    * 2048 + RecHandle
    //
    // where RecHandle is the very same "ALI Rec Runtime" bank index a Record/RecordRef variable
    // carries (1..1024, hence the 2048 stride), and FieldNoSlot is a 1-based index into a small
    // INTERNED field-number pool in "ALI Rec Runtime" (AL field numbers reach 2000000000 for the
    // system fields, so the raw number does not fit next to a handle in one 32-bit Integer;
    // interning the handful of DISTINCT numbers a script mentions does fit, and is idempotent).
    // KeyIndex is small and 1-based, so it is packed raw.
    //
    // Every operation re-materializes `RecRefs[rh].Field(fno)` on demand and throws the native
    // FieldRef away again. Consequences, all of them good:
    //   * NO bank, NO free list, NO lifecycle, NO leak. `F := R.Field(1)` inside a loop returns
    //     the SAME integer every iteration (the pool lookup is idempotent), so it cannot exhaust
    //     anything — contrast an array-of-FieldRef bank, which would need a free list and would
    //     leak one slot per loop turn because `:=` gives the lowerer no place to release the old
    //     handle.
    //   * `:=` between FieldRef variables is a plain MOV_I (RegClassFor -> Int) and matches
    //     native AL's reference-like copy semantics for free, exactly as it does for RecordRef.
    //   * writes reach the row: `RecRefs[h].Field(n).Value := x` is the SAME call the shipped,
    //     tested REC_FLD_STORE path already makes ("ALI Rec Runtime".SetFieldText & co.), so
    //     write-through is not a new assumption — it is the assumption the record runtime has
    //     been standing on since M6.
    //   * a FieldRef needs NO compile-time field-number operand pool, which is why the FieldRef
    //     forms of SetRange/SetFilter/Validate/TestField/CalcField/GetRangeMin/... shipped in P2
    //     while the same methods on a RecordRef receiver still answered ALI989. P4 closed that
    //     gap from the other side — REF_METHOD ids 18-39 read their field numbers live out of
    //     REF_METHOD's own pool — so the two routes now both work and stay independent: neither
    //     desugars into the other, and a FieldRef receiver still never touches a field-no pool.
    // Handle 0 = an unbound FieldRef/KeyRef (a local starts there, like a RecordRef before
    // Open()); every arm asserts it first and raises ALI938.
    //
    // Packing = the TB_METHOD convention with ONE deliberate change — no OutCls field:
    //   A = receiver handle reg (frame-relative Int reg, read LIVE; 0 = unbound)
    //   B = operand-pool start (each entry regIdx*16+regClass, read LIVE)
    //   C = OutReg*10000 + MethodId*100 + ArgCount
    // TB_METHOD's `OutReg*100000 + OutCls*10000 + …` cannot carry this family: three of its
    // methods (Value, GetRangeMin, GetRangeMax) return a VARIANT, whose register class is 11,
    // and an 11 in a one-digit OutCls field overflows straight into OutReg. Dropping the field
    // costs nothing, because unlike the generic families every method id here has ONE fixed
    // result class — the interpreter derives it from the id (FieldRefOutClass) instead of being
    // told. The freed digit goes to OutReg, which now reaches 214747 rather than 21474.
    // Method ids (mirror "ALI Binder".FieldRefMethodId / KeyRefMethodId, mark -16000):
    //   FieldRef —  1 Value() get       2 Value(v) set (also `F.Value := v`)
    //               3 Validate([v])     4 SetRange([lo[,hi]])   5 SetFilter(Text[,args…])
    //               6 GetFilter()       7 GetRangeMin()         8 GetRangeMax()
    //               9 CalcField()      10 CalcSum()            11 TestField([v])
    //              12 FieldError([Text])
    //              13 Name()           14 Number()             15 Caption()
    //              16 Length()         17 Class()              18 Type()
    //              19 Active()         20 Relation()           21 OptionCaption()
    //              22 OptionMembers()  23 IsEnum()             24 EnumValueCount()
    //              25 GetEnumValueName(i)                      26 GetEnumValueCaption(i)
    //              27 GetEnumValueOrdinal(i)
    //              28 GetEnumValueNameFromOrdinalValue(o)
    //              29 GetEnumValueCaptionFromOrdinalValue(o)
    //              30 IsOptimizedForTextSearch()               31 Record() -> RecordRef
    //   KeyRef   — 40 Active()         41 FieldCount()
    //              42 FieldIndex(i) -> FieldRef                43 Record() -> RecordRef
    // Arity-overloaded ids (2/3/4/11/12) share ONE id and branch on ArgCount at run time, the
    // same rule REF_METHOD's Open/FieldExist follow for TYPE-overloaded pairs.
    value(472; FLD_METHOD) { }

    // Native stateful codeunit instance (TypeKind NativeCodeunit, Data Compression): allocate a
    // fresh platform instance in "ALI Native Runtime" and write its handle into Int register A.
    //   A = destination Int register   B = codeunit id   C = IsGlobal (0 = local → tracked, freed on frame pop)
    // Its METHODS are not an opcode of their own: they are catalogued builtin rows (Domain Native)
    // lowered to CALL_BUILTIN_LIVE with the handle as operand 1.
    value(473; NCU_NEW) { }

    // [TryFunction] call consumed as a value (`ok := MyTry()`, `if MyTry() then`). Same argument
    // staging as CALL (ARG_VAL/ARG_REF first), no RESULT_FETCH after.
    //   A = proc id   B = destination Boolean register (frame-relative)   C = unused
    // Cold path: the interpreter pushes the frame with a return PC of InstrTotal and re-enters
    // RunLoopFlat under a native [TryFunction], so the callee's RET ends that nested loop by
    // itself; on an error the frames above the call are unwound and B receives false. A try call
    // used as a STATEMENT is lowered as a plain CALL — its error propagates, as in native AL.
    value(474; TRY_CALL) { }
}
