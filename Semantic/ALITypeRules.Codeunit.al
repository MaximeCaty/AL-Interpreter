// ALI Type Rules — operator result-type matrix + implicit-conversion lattice (§6.4).
//
// SOURCE OF TRUTH: decompiled/CodeAnalysis/BinaryOperatorKind.cs. Every legal
// (operator, operand-type) pairing is a named enum member there; a pairing with NO
// member is a native type error. This codeunit transcribes the v1 subset. The enum
// WINS over the plan's §6.4 prose on any disagreement — divergences documented inline.
//
// Encoding recap (§6.4): the native enum value is (OpKind<<8)|OperandTypeKind. We do NOT
// reproduce that packing; instead ResultType() switches on (op, leftType, rightType)
// using the plan's ALI TypeKind ordinals (not the native 0x15 codes) for readability,
// and each branch corresponds to a specific BinaryOperatorKind member (member named in a
// comment). TypeArg (Text length, option-set id, ...) is NOT consulted here — the length
// class is enforced on STORE (§7.2), not in operator typing.
//
// Divergences from §6.4 prose (enum wins):
//   * Guid HAS full ordering: GuidLessThan(0x1833)/GreaterThan(0x1733)/LE(0x1A33)/GE(0x1933)
//     all exist. §6.4's "no Guid ordering" note is WRONG — we allow < <= > >= on Guid.
//   * Bool IS ordered: BoolLessThan(0x181D) etc exist — comparisons legal on Bool.
//   * Char has NO arithmetic member (no CharAddition): Char promotes to Int for +,-,* (the
//     Char↔Int CONV rule below), and Char has its own comparison/equality members.
//   * `/` : plan mandates always-Decimal (CONV both to Decimal, DecimalDivision). We follow
//     the plan; DurationDivision(0x1337) exists natively (Duration/number) but is v1-deferred.
//
// API (§13): ResultType(op,l,r)->TypeKind ord (None=illegal), CanConvert(from,to)->Bool,
// ConvKind(from,to)->ConvOrd (0 = no conversion needed).
//
// Ordinals live in enums, not in fixed-value procedures: operator groups in
// "ALI Op Group" (51102), the conversion lattice in "ALI Conv Kind" (51103), register
// classes in "ALI Register Class" (51019). Enum literals resolve at compile time — no AL
// call overhead on the binder/lowerer hot paths.
codeunit 51042 "ALI Type Rules"
{
    Access = Public;
    SingleInstance = false;

    // Map an "ALI TokenKind" operator ordinal to an operator group (0 = not a binary op).
    procedure OpGroupFromToken(TokKind: Integer): Integer
    begin
        case TokKind of
            32:
                exit("ALI Op Group"::Mul);      // MultiplyToken
            30:
                exit("ALI Op Group"::"Add");      // PlusToken
            31:
                exit("ALI Op Group"::Sub);      // MinusToken
            33:
                exit("ALI Op Group"::RDiv);     // RDivToken  /
            34:
                exit("ALI Op Group"::IDiv);     // IDivKeyword div
            35:
                exit("ALI Op Group"::"Mod");      // ModuloKeyword
            50:
                exit("ALI Op Group"::Eq);       // EqualsToken
            51:
                exit("ALI Op Group"::Neq);      // NotEqualsToken
            52:
                exit("ALI Op Group"::Lt);       // LessThanToken
            53:
                exit("ALI Op Group"::Le);       // LessThanEqualsToken
            54:
                exit("ALI Op Group"::Gt);       // GreaterThanToken
            55:
                exit("ALI Op Group"::Ge);       // GreaterThanEqualsToken
            60:
                exit("ALI Op Group"::"And");      // AndKeyword
            61:
                exit("ALI Op Group"::"Or");       // OrKeyword
            62:
                exit("ALI Op Group"::"Xor");      // XorKeyword
            else
                exit(0);
        end;
    end;


    // Map a native Field.Type option ordinal to an "ALI TypeKind" ordinal, or TNone() when
    // the interpreter has no register class for it (the binder rejects such fields §19.1).
    // Native FieldType ordinals: NOT 0-based by OptionMembers position — the virtual `Field`
    // table's Type option carries its own large, non-sequential backing values (confirmed
    // against the platform's SymbolReference.json OptionOrdinalValues for table 2000000041
    // field "Type"): TableFilter 4912, RecordID 4988, OemText 11519, Date 11775, Time 11776,
    // DateFormula 11797, Decimal 12799, Media 26207, MediaSet 26208, Text 31488, Code 31489,
    // Binary 33791, BLOB 33793, Boolean 34047, Integer 34559, OemCode 35071, Option 35583,
    // BigInteger 36095, Duration 36863, GUID 37119, DateTime 37375. The stable subset we
    // support:
    procedure FieldTypeToTypeKind(NativeType: Integer): Integer
    begin
        case NativeType of
            4988:
                exit("ALI TypeKind"::RecordID);      // own register class (12); equality-only, Format/Evaluate-able
            11775:
                exit("ALI TypeKind"::Date);
            11776:
                exit("ALI TypeKind"::Time);
            11797:
                exit("ALI TypeKind"::DateFormula);
            12799:
                exit("ALI TypeKind"::Decimal);
            31488, 11519:
                exit("ALI TypeKind"::Text);          // Text / OemText
            31489, 35071:
                exit("ALI TypeKind"::Code);          // Code / OemCode
            34047:
                exit("ALI TypeKind"::Boolean);
            34559:
                exit("ALI TypeKind"::Integer);
            35583:
                exit("ALI TypeKind"::Option);        // Option — Int-backed (§6.4); the virtual Field table
                                                     // also reports genuine Enum fields under this same
                                                     // native ordinal, so both land on Option here —
                                                     // enum-ness only matters for metadata SOURCE, decided
                                                     // later at bind time (field path always uses FieldRef).
            36095:
                exit("ALI TypeKind"::BigInteger);
            36863:
                exit("ALI TypeKind"::Duration);
            37119:
                exit("ALI TypeKind"::Guid);
            37375:
                exit("ALI TypeKind"::DateTime);
            33793:
                exit("ALI TypeKind"::Blob);          // BLOB — no register class; only usable through
                                                     // Rec.MyBlob.CreateInStream/CreateOutStream/HasValue/Length
            26207:
                exit("ALI TypeKind"::Media);         // Media — no register class; only usable through
                                                     // Rec.MyPicture.MediaId/HasValue/ExportStream
            26208:
                exit("ALI TypeKind"::MediaSet);      // MediaSet — likewise (MediaId/Count/Item)
            else
                exit("ALI TypeKind"::None);          // unsupported field type (Binary/TableFilter/...)
        end;
    end;

    // ===== Type-class predicates =====

    // Integer-family (participates as Int: Int/BigInt/Char/Byte/Option). Used by div/mod
    // and by promotion. Option compares/assigns as its underlying Int (§6.4).
    procedure IsIntegerFamily(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::Integer) or (T = "ALI TypeKind"::BigInteger) or (T = "ALI TypeKind"::Char) or (T = "ALI TypeKind"::Byte) or (T = "ALI TypeKind"::Option) or (T = "ALI TypeKind"::Enum));
    end;

    // Any numeric (integer-family + Decimal).
    procedure IsNumeric(T: Integer): Boolean
    begin
        exit(IsIntegerFamily(T) or (T = "ALI TypeKind"::Decimal));
    end;

    // Text family: Text/Code/Label all type as Text for operators (§6.4 "Code as Text").
    procedure IsTextFamily(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::Text) or (T = "ALI TypeKind"::Code) or (T = "ALI TypeKind"::Label));
    end;

    // Text/Code only (no Label): the var-param-compatible text kinds.
    procedure IsTextOrCode(T: Integer): Boolean
    begin
        exit((T = "ALI TypeKind"::Text) or (T = "ALI TypeKind"::Code));
    end;

    // Ordered types for < <= > >= (per enum: numeric, Char, Text, Date/Time/DateTime,
    // Bool, Guid). Duration is ordered too (numeric-like) — allow it.
    procedure IsOrdered(T: Integer): Boolean
    begin
        exit(IsNumeric(T) or IsTextFamily(T) or (T = "ALI TypeKind"::Boolean) or (T = "ALI TypeKind"::Guid) or
             (T = "ALI TypeKind"::Date) or (T = "ALI TypeKind"::Time) or (T = "ALI TypeKind"::DateTime) or (T = "ALI TypeKind"::Duration));
    end;

    // ===== ResultType — the matrix (§6.4). Returns the result TypeKind ordinal, or
    // TNone() (0) when the (op, l, r) triple has no BinaryOperatorKind member = type error.
    // ErrorType operands poison to ErrorType (never a further error, §6.2). =====
    procedure ResultType(OpGroup: Integer; L: Integer; R: Integer): Integer
    begin
        // Poison: any ErrorType operand yields ErrorType, suppressing cascades (§6.2).
        if (L = "ALI TypeKind"::ErrorType) or (R = "ALI TypeKind"::ErrorType) then
            exit("ALI TypeKind"::ErrorType);

        case OpGroup of
            "ALI Op Group"::"Add":
                exit(ResultAdd(L, R));
            "ALI Op Group"::Sub:
                exit(ResultSub(L, R));
            "ALI Op Group"::Mul:
                exit(ResultMul(L, R));
            "ALI Op Group"::RDiv:
                exit(ResultRDiv(L, R));
            "ALI Op Group"::IDiv, "ALI Op Group"::"Mod":
                exit(ResultIDivMod(L, R));
            "ALI Op Group"::Eq, "ALI Op Group"::Neq:
                exit(ResultEquality(L, R));
            "ALI Op Group"::Lt, "ALI Op Group"::Le, "ALI Op Group"::Gt, "ALI Op Group"::Ge:
                exit(ResultComparison(L, R));
            "ALI Op Group"::"And", "ALI Op Group"::"Or", "ALI Op Group"::"Xor":
                exit(ResultLogical(L, R));
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // + : numeric addition, string concatenation, date/time arithmetic (§6.4).
    local procedure ResultAdd(L: Integer; R: Integer): Integer
    begin
        // Numeric addition: IntAddition/LongAddition/DecimalAddition. Char promotes to Int.
        if IsNumeric(L) and IsNumeric(R) then
            exit(NumericResult(L, R));
        // String concatenation: StringConcatenation / StringAndObjectConcatenation.
        // Text + anything -> Text (native concatenates the formatted RHS).
        if IsTextFamily(L) or IsTextFamily(R) then
            exit("ALI TypeKind"::Text);
        // Date/Time/DateTime + numeric/Duration (Date on LEFT only — no IntegerAndDate).
        // DateAndIntegerAddition/DateAndDurationAddition -> Date.
        if (L = "ALI TypeKind"::Date) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::Date);
        // DateTimeAndDurationAddition -> DateTime; also DateTimeAndInteger/BigInteger/Decimal
        // Addition (native adds as milliseconds, per BinaryOperatorKind.cs 0x1146-0x114C).
        if (L = "ALI TypeKind"::DateTime) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::DateTime);
        // TimeAndDurationAddition -> Time; also TimeAndInteger/BigInteger/Decimal Addition.
        if (L = "ALI TypeKind"::Time) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::Time);
        exit("ALI TypeKind"::None);
    end;

    // - : numeric subtraction; Date-Date/DateTime-DateTime -> Duration; Date-num/Duration etc.
    local procedure ResultSub(L: Integer; R: Integer): Integer
    begin
        if IsNumeric(L) and IsNumeric(R) then
            exit(NumericResult(L, R));
        // M4 FIX (enum/compiler wins over §6.4 prose): BuiltInOperators.ReturnType maps
        // operand-class Date -> Integer (days) and Time -> Integer (ms); ONLY DateTime
        // subtraction yields Duration. M3 had Duration for all three — corrected here.
        if (L = "ALI TypeKind"::Date) and (R = "ALI TypeKind"::Date) then
            exit("ALI TypeKind"::Integer);
        if (L = "ALI TypeKind"::DateTime) and (R = "ALI TypeKind"::DateTime) then
            exit("ALI TypeKind"::Duration);
        if (L = "ALI TypeKind"::Time) and (R = "ALI TypeKind"::Time) then
            exit("ALI TypeKind"::Integer);
        // DateAndIntegerSubtraction / DateAndDurationSubtraction -> Date.
        if (L = "ALI TypeKind"::Date) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::Date);
        // DateTimeAndDurationSubtraction -> DateTime; also DateTimeAndInteger/BigInteger/Decimal
        // Subtraction (native, per BinaryOperatorKind.cs 0x1246-0x124C).
        if (L = "ALI TypeKind"::DateTime) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::DateTime);
        // TimeAndDurationSubtraction -> Time; also TimeAndInteger/BigInteger/Decimal Subtraction.
        if (L = "ALI TypeKind"::Time) and (IsIntegerFamily(R) or (R = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Duration)) then
            exit("ALI TypeKind"::Time);
        exit("ALI TypeKind"::None);
    end;

    // * : IntMultiplication/DecimalMultiplication. (Duration*number exists natively but
    // v1-deferred; keep it numeric-only for now.)
    local procedure ResultMul(L: Integer; R: Integer): Integer
    begin
        if IsNumeric(L) and IsNumeric(R) then
            exit(NumericResult(L, R));
        exit("ALI TypeKind"::None);
    end;

    // / : ALWAYS Decimal (§6.4). Legal for any numeric/numeric; CONV both to Decimal (the
    // binder inserts CONV where needed). DecimalDivision.
    local procedure ResultRDiv(L: Integer; R: Integer): Integer
    begin
        if IsNumeric(L) and IsNumeric(R) then
            exit("ALI TypeKind"::Decimal);
        exit("ALI TypeKind"::None);
    end;

    // div / mod : integer-family ONLY (IntIDivision/LongIDivision/IntRemainder/LongRemainder).
    // No Decimal member in v1 scope. Result BigInteger if either side is BigInteger, else Int.
    local procedure ResultIDivMod(L: Integer; R: Integer): Integer
    begin
        if IsIntegerFamily(L) and IsIntegerFamily(R) then begin
            if (L = "ALI TypeKind"::BigInteger) or (R = "ALI TypeKind"::BigInteger) then
                exit("ALI TypeKind"::BigInteger);
            exit("ALI TypeKind"::Integer);
        end;
        exit("ALI TypeKind"::None);
    end;

    // = <> : same-type or convertible; all v1 types (incl. Bool, Guid, Date*, Text) -> Bool.
    // *Equal / *NotEqual members. Requires the operands be comparable (a conversion exists).
    local procedure ResultEquality(L: Integer; R: Integer): Integer
    begin
        if EqualityComparable(L, R) then
            exit("ALI TypeKind"::Boolean);
        exit("ALI TypeKind"::None);
    end;

    // < <= > >= : ordered types only -> Bool (*LessThan etc). Guid ordering IS present in
    // the enum (divergence from §6.4 prose — enum wins).
    local procedure ResultComparison(L: Integer; R: Integer): Integer
    begin
        if not (IsOrdered(L) and IsOrdered(R)) then
            exit("ALI TypeKind"::None);
        if OrderComparable(L, R) then
            exit("ALI TypeKind"::Boolean);
        exit("ALI TypeKind"::None);
    end;

    // and/or/xor : v1 = Bool operands ONLY (LogicalBoolAnd/Or/Xor). Integer bitwise forms
    // are out of v1 scope (§1.1/§6.4).
    local procedure ResultLogical(L: Integer; R: Integer): Integer
    begin
        if (L = "ALI TypeKind"::Boolean) and (R = "ALI TypeKind"::Boolean) then
            exit("ALI TypeKind"::Boolean);
        exit("ALI TypeKind"::None);
    end;

    // Numeric result-type rule: Decimal if either side Decimal; else BigInteger if either
    // side BigInteger; else Int (Char/Byte/Option promote to Int).
    local procedure NumericResult(L: Integer; R: Integer): Integer
    begin
        if (L = "ALI TypeKind"::Decimal) or (R = "ALI TypeKind"::Decimal) then
            exit("ALI TypeKind"::Decimal);
        if (L = "ALI TypeKind"::BigInteger) or (R = "ALI TypeKind"::BigInteger) then
            exit("ALI TypeKind"::BigInteger);
        exit("ALI TypeKind"::Integer);
    end;

    // Two types are equality-comparable when they share a category (both numeric, both text,
    // both Bool, both Guid, same date/time kind, or one converts to the other).
    local procedure EqualityComparable(L: Integer; R: Integer): Boolean
    begin
        if IsNumeric(L) and IsNumeric(R) then
            exit(true);
        if IsTextFamily(L) and IsTextFamily(R) then
            exit(true);
        // Char <-> Text/Code: native AL compares a Char (e.g. `Text[i]`) against a Text/Code
        // literal or value as characters, not as its numeric ordinal (§6.4).
        if (L = "ALI TypeKind"::Char) and IsTextFamily(R) then
            exit(true);
        if IsTextFamily(L) and (R = "ALI TypeKind"::Char) then
            exit(true);
        if (L = "ALI TypeKind"::Boolean) and (R = "ALI TypeKind"::Boolean) then
            exit(true);
        if (L = "ALI TypeKind"::Guid) and (R = "ALI TypeKind"::Guid) then
            exit(true);
        if (L = "ALI TypeKind"::RecordID) and (R = "ALI TypeKind"::RecordID) then
            exit(true);
        if (L = "ALI TypeKind"::DateFormula) and (R = "ALI TypeKind"::DateFormula) then
            exit(true);       // equality only, no ordering (§6.4-analog)
        exit(SameTemporal(L, R));
    end;

    // Ordering-comparable: numeric×numeric, text×text, same-temporal, Bool×Bool, Guid×Guid.
    local procedure OrderComparable(L: Integer; R: Integer): Boolean
    begin
        exit(EqualityComparable(L, R));
    end;

    local procedure SameTemporal(L: Integer; R: Integer): Boolean
    begin
        exit(((L = "ALI TypeKind"::Date) and (R = "ALI TypeKind"::Date)) or
             ((L = "ALI TypeKind"::Time) and (R = "ALI TypeKind"::Time)) or
             ((L = "ALI TypeKind"::DateTime) and (R = "ALI TypeKind"::DateTime)) or
             ((L = "ALI TypeKind"::Duration) and (R = "ALI TypeKind"::Duration)));
    end;

    // A type that can cross the Variant boundary (§19.2). Every register-class scalar boxes by
    // value; Record and the Int-handle aggregates (List/Dictionary/Array) box by REFERENCE — the
    // lowerer tags them so the native Variant (which sees only their handle) can still identify
    // them. Variant itself and the remaining RefShim types (RegClassFor = 0) are not boxable.
    procedure VariantBoxable(T: Integer): Boolean
    begin
        if T = "ALI TypeKind"::Variant then
            exit(false);
        if (T = "ALI TypeKind"::Record) or (T = "ALI TypeKind"::List) or (T = "ALI TypeKind"::Dictionary) or (T = "ALI TypeKind"::Array) then
            exit(true);
        // Http* handles (M10): Int-handle RefShim like List/Dict, but not boxable in v1 — no
        // reference tag exists for them yet (unlike Record/List/Dict/Array, which the lowerer
        // tags explicitly). Revisit if a script needs Variant<->Http round-tripping.
        if (T = "ALI TypeKind"::HttpClient) or (T = "ALI TypeKind"::HttpRequestMessage) or (T = "ALI TypeKind"::HttpResponseMessage) or
           (T = "ALI TypeKind"::HttpContent) or (T = "ALI TypeKind"::HttpHeaders)
        then
            exit(false);
        // Json* handles (Feature 2): Int-handle RefShim like Http*, not boxable in v1 — no
        // reference tag exists for them yet (unlike Record/List/Dict/Array).
        if (T = "ALI TypeKind"::JsonObject) or (T = "ALI TypeKind"::JsonArray) or (T = "ALI TypeKind"::JsonToken) or
           (T = "ALI TypeKind"::JsonValue)
        then
            exit(false);
        // Xml* handles (Feature 3, XML_DESIGN.md §1): Int-handle RefShim like Json*, not
        // boxable in v1 — no reference tag exists for them either.
        if IsXmlKind(T) then
            exit(false);
        // RecordRef (P0): its register class IS Int, so the RegClassFor test below would call it
        // boxable and silently box the raw HANDLE as a plain Integer — a Variant that no longer
        // knows it holds a record. Record has BOX_REC/UNBOX_REC for that; RecordRef has no
        // reference tag yet, so it stays unboxable (same call as Http*/Json*/Xml*).
        if T = "ALI TypeKind"::RecordRef then
            exit(false);
        // FieldRef/KeyRef (P2/P3): same reasoning one step further — their Int register holds a
        // PACKED (recHandle, fieldNo/keyIndex) pair, which as a plain Integer in a Variant would
        // be meaningless to every consumer. No reference tag exists for them either.
        if (T = "ALI TypeKind"::FieldRef) or (T = "ALI TypeKind"::KeyRef) then
            exit(false);
        // NativeCodeunit: a bank handle, meaningless as a plain Integer in a Variant.
        if T = "ALI TypeKind"::NativeCodeunit then
            exit(false);
        exit(RegClassFor(T) <> 0);
    end;

    // Any of the 16 Xml* RefShim kinds (Feature 3, XML_DESIGN.md §1) — contiguous frozen
    // ordinal block 102-117. Same-kind-only assignment (no ConvKind entries → CanConvert
    // rejects cross-kind), no operators, no ordering, no implicit conversions.
    procedure IsXmlKind(T: Integer): Boolean
    begin
        exit((T >= "ALI TypeKind"::XmlDocument.AsInteger()) and (T <= "ALI TypeKind"::XmlNameTable.AsInteger()));
    end;

    // Can `From` be implicitly converted to `To`? (assignment / argument-passing context.)
    procedure CanConvert(FromT: Integer; ToT: Integer): Boolean
    begin
        if FromT = ToT then
            exit(true);
        if (FromT = "ALI TypeKind"::ErrorType) or (ToT = "ALI TypeKind"::ErrorType) then
            exit(true);                 // poison: never a further error (§6.2)
        exit(ConvKind(FromT, ToT) <> "ALI Conv Kind"::None);
    end;

    // The conversion ordinal to turn `From` into `To`, or "ALI Conv Kind"::"None" (0) when either no
    // conversion is needed (From = To) OR no implicit conversion exists (caller checks
    // CanConvert first for the "illegal" case). NB: a 0 result is ambiguous between
    // "identity" and "impossible"; callers gate on CanConvert.
    procedure ConvKind(FromT: Integer; ToT: Integer): Integer
    begin
        if FromT = ToT then
            exit("ALI Conv Kind"::None);

        // Numeric widenings.
        if (ToT = "ALI TypeKind"::Decimal) and IsIntegerFamily(FromT) then
            exit("ALI Conv Kind"::IntToDec);
        if (ToT = "ALI TypeKind"::BigInteger) and ((FromT = "ALI TypeKind"::Integer) or (FromT = "ALI TypeKind"::Char) or (FromT = "ALI TypeKind"::Byte) or (FromT = "ALI TypeKind"::Option)) then
            exit("ALI Conv Kind"::IntToBigInt);

        // Numeric narrowings (M4 fix — native AL assignment semantics, §6.4 pitfall 24).
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::Decimal) then
            exit("ALI Conv Kind"::DecToInt);
        if (ToT = "ALI TypeKind"::BigInteger) and (FromT = "ALI TypeKind"::Decimal) then
            exit("ALI Conv Kind"::DecToBigInt);
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::BigInteger) then
            exit("ALI Conv Kind"::BigIntToInt);
        if (ToT = "ALI TypeKind"::Byte) and ((FromT = "ALI TypeKind"::Integer) or (FromT = "ALI TypeKind"::Char) or (FromT = "ALI TypeKind"::Option)) then
            exit("ALI Conv Kind"::IntToByte);

        // Char <-> Int (§6.4).
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::Char) then
            exit("ALI Conv Kind"::CharToInt);
        if (ToT = "ALI TypeKind"::Char) and (FromT = "ALI TypeKind"::Integer) then
            exit("ALI Conv Kind"::IntToChar);       // checked narrowing (0..65535)

        // Byte -> Int widening.
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::Byte) then
            exit("ALI Conv Kind"::ByteToInt);

        // ObjectId -> Int (§19.6). `Database::"X"` / `Codeunit::"Y"` bind to ObjectId, which is an
        // Int SUBTYPE: the binder folds the resolved object id onto the node (SlotIndex) and
        // RegClassFor already puts it in the Int register file, so this is MOV-only — the same
        // no-runtime-opcode conversion Option->Int is, and it reuses that ConvOrd for that reason.
        //
        // Native AL has no separate ObjectId type at all: `Database::Customer` IS an Integer
        // literal there, and every Integer position accepts it. Without this rule ALI accepted the
        // form only where a call site had been written to special-case it by hand (the
        // `(IdT <> ObjectId) and (IdT <> Integer)` test in the binder's Codeunit.Run arm was the
        // only one), so every NEW Integer parameter silently rejected the single most idiomatic way
        // to write a table id — which is what `RRef.Open(Database::"X")` hit: CanConvert(ObjectId,
        // Integer) was false, CanConvert(ObjectId, Text) was false, and Open reported ALI932 on a
        // perfectly valid table id. One conversion rule fixes every such site at once, present and
        // future, instead of adding an ObjectId branch per arm.
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::ObjectId) then
            exit("ALI Conv Kind"::OptionToInt);

        // Option <-> Int (§6.4).
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::Option) then
            exit("ALI Conv Kind"::OptionToInt);
        if (ToT = "ALI TypeKind"::Option) and (FromT = "ALI TypeKind"::Integer) then
            exit("ALI Conv Kind"::IntToOption);

        // Enum <-> Int (§D6 — permissive, mirrors Option; native AL needs .AsInteger() but the
        // interpreter treats Enum exactly like Option here). Reuses the SAME ConvOrd values —
        // both are MOV-only (no runtime opcode), so the lowerer branches identically.
        if (ToT = "ALI TypeKind"::Integer) and (FromT = "ALI TypeKind"::Enum) then
            exit("ALI Conv Kind"::OptionToInt);
        if (ToT = "ALI TypeKind"::Enum) and (FromT = "ALI TypeKind"::Integer) then
            exit("ALI Conv Kind"::IntToOption);

        // Enum <-> Option (native AL accepts both directions implicitly, with an
        // ordinal-mismatch warning we do not reproduce). Same RegClassInt on both sides —
        // MOV-only, so reusing the Option<->Int ConvOrds keeps the lowerer untouched.
        if (ToT = "ALI TypeKind"::Option) and (FromT = "ALI TypeKind"::Enum) then
            exit("ALI Conv Kind"::OptionToInt);
        if (ToT = "ALI TypeKind"::Enum) and (FromT = "ALI TypeKind"::Option) then
            exit("ALI Conv Kind"::IntToOption);

        // Char -> Text/Code (native: a Char is a single-character Text; e.g. `Txt := Ch;`).
        // Cross-register-class (Int -> Text): the lowerer emits CHAR_TO_TEXT (ConvertToType).
        if (FromT = "ALI TypeKind"::Char) and ((ToT = "ALI TypeKind"::Text) or (ToT = "ALI TypeKind"::Code)) then
            exit("ALI Conv Kind"::CharToText);

        // Text <-> Code (§6.4 "Code as Text").
        if IsTextFamily(FromT) and (ToT = "ALI TypeKind"::Code) then
            exit("ALI Conv Kind"::TextToCode);
        if (FromT = "ALI TypeKind"::Code) and ((ToT = "ALI TypeKind"::Text) or (ToT = "ALI TypeKind"::Label)) then
            exit("ALI Conv Kind"::CodeToText);
        if (FromT = "ALI TypeKind"::Label) and ((ToT = "ALI TypeKind"::Text) or (ToT = "ALI TypeKind"::Code)) then begin
            if ToT = "ALI TypeKind"::Code then
                exit("ALI Conv Kind"::TextToCode);
            exit("ALI Conv Kind"::CodeToText);
        end;

        // Text/Code -> DateFormula (native implicit conversion; e.g. `Days := '1M+2D';`).
        if (ToT = "ALI TypeKind"::DateFormula) and IsTextFamily(FromT) then
            exit("ALI Conv Kind"::TextToDateFormula);

        // Text/Code -> SecretText (native implicit, one-way). Deliberately NOT symmetric: a
        // SecretText only reaches Text through an explicit Unwrap(), which is the whole point
        // of the type.
        if (ToT = "ALI TypeKind"::SecretText) and IsTextFamily(FromT) then
            exit("ALI Conv Kind"::TextToSecret);

        // Variant boxing/unboxing (§7.1): any scalar <-> Variant. Native AL boxes on assign to
        // a Variant and unboxes (runtime-checked) on assign from a Variant to a typed target.
        if (ToT = "ALI TypeKind"::Variant) and VariantBoxable(FromT) then
            exit("ALI Conv Kind"::Box);
        if (FromT = "ALI TypeKind"::Variant) and VariantBoxable(ToT) then
            exit("ALI Conv Kind"::Unbox);

        exit("ALI Conv Kind"::None);   // no implicit conversion (illegal unless From = To)
    end;

    // Assignment compatibility: is `Source` assignable to a `Target`-typed lvalue?
    // (target := source). Same as CanConvert plus the identity case.
    procedure AssignmentCompatible(TargetT: Integer; SourceT: Integer): Boolean
    begin
        if (TargetT = "ALI TypeKind"::ErrorType) or (SourceT = "ALI TypeKind"::ErrorType) then
            exit(true);                 // poison
        if TargetT = SourceT then
            exit(true);
        exit(ConvKind(SourceT, TargetT) <> "ALI Conv Kind"::None);
    end;

    // Highest register-class ordinal ("ALI Register Class"::DateFormula). NOT
    // Ordinals().Count() — that counts the 0 placeholder too and returns 14, one past the
    // ClassCounter: array[13] the binder indexes with it.
    procedure RegClassCount(): Integer
    begin
        exit(13); // = enum::"ALI Register Class".Ordinals().Count()

    end;

    // Register class for a TypeKind ordinal; 0 = no register class (None/Error/RefShim).
    procedure RegClassFor(T: Integer): Integer
    begin
        case T of
            "ALI TypeKind"::Integer, "ALI TypeKind"::Char, "ALI TypeKind"::Byte, "ALI TypeKind"::Option, "ALI TypeKind"::Enum, "ALI TypeKind"::ObjectId:
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::BigInteger:
                exit("ALI Register Class"::BigInt);
            "ALI TypeKind"::Decimal:
                exit("ALI Register Class"::"Decimal");
            "ALI TypeKind"::Boolean:
                exit("ALI Register Class"::"Boolean");
            "ALI TypeKind"::Text, "ALI TypeKind"::Code, "ALI TypeKind"::Label,
            "ALI TypeKind"::SecretText:     // value IS the text; secrecy is a bind-time property only
                exit("ALI Register Class"::"Text");
            "ALI TypeKind"::Date:
                exit("ALI Register Class"::"Date");
            "ALI TypeKind"::Time:
                exit("ALI Register Class"::"Time");
            "ALI TypeKind"::DateTime:
                exit("ALI Register Class"::"DateTime");
            "ALI TypeKind"::Duration:
                exit("ALI Register Class"::"Duration");
            "ALI TypeKind"::Guid:
                exit("ALI Register Class"::"Guid");
            71:                             // ALI TypeKind.Variant
                exit("ALI Register Class"::"Variant");
            "ALI TypeKind"::List, "ALI TypeKind"::Dictionary:        // Int-handle reference (ListDictionaryPlan.md §1)
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::Array:                      // Int-handle reference (ArrayMultidimPlan.md §20.2)
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::RecordRef:
                // A user-declared RecordRef is the SAME Int handle into the SAME "ALI Rec
                // Runtime" bank a Record variable uses — the only difference is that its table
                // id is unknown at bind time. Routing it to the Int class is what makes `:=`
                // between two RecordRef variables reference ALIASING for free (plain MOV_I,
                // exactly like List/Dictionary/Http*), and what lets a RecordRef be a parameter
                // (by value or `var`) and a return type with no new register machinery at all.
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::FieldRef, "ALI TypeKind"::KeyRef:
                // P2/P3: a PACKED PAIR in one Int register — slot*2048 + recHandle (see
                // "ALI Opcode"::FLD_METHOD for the full rationale). Routing them to the Int class
                // is what makes `:=` between FieldRef variables the reference-like copy native AL
                // has, and what lets a FieldRef be a parameter (by value or `var`) and a return
                // type with no new register machinery — exactly as for RecordRef above.
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::Record, "ALI TypeKind"::InStream, "ALI TypeKind"::OutStream,
            "ALI TypeKind"::TextBuilder, "ALI TypeKind"::BigText, "ALI TypeKind"::Dialog,
            "ALI TypeKind"::NativeCodeunit:     // handle into "ALI Native Runtime"'s instance bank
                // Handle Lifecycle Unification (Phase 3): Int-handle reference, same scheme as
                // List/Dictionary/Array/Http* — a windowed register slot (per-proc-entry
                // fresh handle, global or local) instead of the old separate compile-time-
                // sealed absolute handle space. Fixes the recursive-proc-shares-one-handle bug
                // and lets Record/Stream/TextBuilder be declared as proc locals for the first
                // time (previously silently non-functional — see "ALI Binder" header notes).
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::RecordID:
                exit("ALI Register Class"::"RecordId");
            "ALI TypeKind"::DateFormula:
                exit("ALI Register Class"::"DateFormula");
            "ALI TypeKind"::HttpClient, "ALI TypeKind"::HttpRequestMessage, "ALI TypeKind"::HttpResponseMessage,
            "ALI TypeKind"::HttpContent, "ALI TypeKind"::HttpHeaders,      // Int-handle reference (M10, List/Dict scheme)
            "ALI TypeKind"::JsonObject, "ALI TypeKind"::JsonArray, "ALI TypeKind"::JsonToken,
            "ALI TypeKind"::JsonValue:                                    // Int-handle reference (Feature 2, same scheme)
                exit("ALI Register Class"::Int);
            "ALI TypeKind"::XmlDocument, "ALI TypeKind"::XmlNode, "ALI TypeKind"::XmlElement,
            "ALI TypeKind"::XmlAttribute, "ALI TypeKind"::XmlNodeList, "ALI TypeKind"::XmlAttributeCollection,
            "ALI TypeKind"::XmlComment, "ALI TypeKind"::XmlCData, "ALI TypeKind"::XmlDeclaration,
            "ALI TypeKind"::XmlDocumentType, "ALI TypeKind"::XmlText, "ALI TypeKind"::XmlProcessingInstruction,
            "ALI TypeKind"::XmlNamespaceManager, "ALI TypeKind"::XmlReadOptions, "ALI TypeKind"::XmlWriteOptions,
            "ALI TypeKind"::XmlNameTable:                                 // Int-handle reference (Feature 3, XML_DESIGN.md §1)
                exit("ALI Register Class"::Int);
            else
                exit(0);
        end;
    end;

    // Canonical TypeKind for a RegClass ordinal (1..10) — used by List/Dictionary binding
    // to recover an element/key/value TYPE (for CheckAssignable) from the packed classIndex
    // stored in TypeArg (ListDictionaryPlan.md §1: classIndex IS the RegClass ordinal).
    // Char/Byte/Option (also RegClassInt) and Code/Label (also RegClassText) collapse to
    // Integer/Text respectively — the requester's frozen scope for List/Dict element types.
    procedure TypeKindForRegClass(Cls: Integer): Integer
    begin
        case Cls of
            "ALI Register Class"::Int:
                exit("ALI TypeKind"::Integer);
            "ALI Register Class"::BigInt:
                exit("ALI TypeKind"::BigInteger);
            "ALI Register Class"::"Decimal":
                exit("ALI TypeKind"::Decimal);
            "ALI Register Class"::"Boolean":
                exit("ALI TypeKind"::Boolean);
            "ALI Register Class"::"Text":
                exit("ALI TypeKind"::Text);
            "ALI Register Class"::"Date":
                exit("ALI TypeKind"::Date);
            "ALI Register Class"::"Time":
                exit("ALI TypeKind"::Time);
            "ALI Register Class"::"DateTime":
                exit("ALI TypeKind"::DateTime);
            "ALI Register Class"::"Duration":
                exit("ALI TypeKind"::Duration);
            "ALI Register Class"::"Guid":
                exit("ALI TypeKind"::Guid);
            else
                exit("ALI TypeKind"::None);
        end;
    end;

    // Human-readable type name for diagnostics (binder messages).
    procedure TypeName(T: Integer): Text
    begin
        case T of
            "ALI TypeKind"::None:
                exit('None');
            "ALI TypeKind"::ErrorType:
                exit('<error>');
            "ALI TypeKind"::Integer:
                exit('Integer');
            "ALI TypeKind"::BigInteger:
                exit('BigInteger');
            "ALI TypeKind"::Decimal:
                exit('Decimal');
            "ALI TypeKind"::Char:
                exit('Char');
            "ALI TypeKind"::Byte:
                exit('Byte');
            "ALI TypeKind"::Boolean:
                exit('Boolean');
            "ALI TypeKind"::Text:
                exit('Text');
            "ALI TypeKind"::Code:
                exit('Code');
            "ALI TypeKind"::Label:
                exit('Label');
            "ALI TypeKind"::Option:
                exit('Option');
            "ALI TypeKind"::Enum:
                exit('Enum');
            "ALI TypeKind"::Date:
                exit('Date');
            "ALI TypeKind"::Time:
                exit('Time');
            "ALI TypeKind"::DateTime:
                exit('DateTime');
            "ALI TypeKind"::Duration:
                exit('Duration');
            "ALI TypeKind"::DateFormula:
                exit('DateFormula');
            "ALI TypeKind"::Guid:
                exit('Guid');
            "ALI TypeKind"::InStream:
                exit('InStream');
            "ALI TypeKind"::OutStream:
                exit('OutStream');
            "ALI TypeKind"::TextBuilder:
                exit('TextBuilder');
            "ALI TypeKind"::BigText:
                exit('BigText');
            "ALI TypeKind"::SecretText:
                exit('SecretText');
            "ALI TypeKind"::Media:
                exit('Media');
            "ALI TypeKind"::MediaSet:
                exit('MediaSet');
            "ALI TypeKind"::List:
                exit('List');
            "ALI TypeKind"::Dictionary:
                exit('Dictionary');
            "ALI TypeKind"::RecordID:
                exit('RecordID');
            "ALI TypeKind"::ObjectId:
                // Missing arm, found while reading an ALI932 that ended in "got <type 87>": the
                // angle-bracket fallback below is not just ugly, some test/log renderers eat it as
                // a markup tag and the reader sees "got " with nothing after it.
                exit('ObjectId');
            "ALI TypeKind"::RecordRef:
                exit('RecordRef');
            "ALI TypeKind"::FieldRef:
                exit('FieldRef');
            "ALI TypeKind"::KeyRef:
                exit('KeyRef');
            "ALI TypeKind"::Blob:
                exit('Blob');
            "ALI TypeKind"::Variant:
                exit('Variant');
            "ALI TypeKind"::HttpClient:
                exit('HttpClient');
            "ALI TypeKind"::HttpRequestMessage:
                exit('HttpRequestMessage');
            "ALI TypeKind"::HttpResponseMessage:
                exit('HttpResponseMessage');
            "ALI TypeKind"::HttpContent:
                exit('HttpContent');
            "ALI TypeKind"::HttpHeaders:
                exit('HttpHeaders');
            "ALI TypeKind"::JsonObject:
                exit('JsonObject');
            "ALI TypeKind"::JsonArray:
                exit('JsonArray');
            "ALI TypeKind"::JsonToken:
                exit('JsonToken');
            "ALI TypeKind"::JsonValue:
                exit('JsonValue');
            "ALI TypeKind"::XmlDocument:
                exit('XmlDocument');
            "ALI TypeKind"::XmlNode:
                exit('XmlNode');
            "ALI TypeKind"::XmlElement:
                exit('XmlElement');
            "ALI TypeKind"::XmlAttribute:
                exit('XmlAttribute');
            "ALI TypeKind"::XmlNodeList:
                exit('XmlNodeList');
            "ALI TypeKind"::XmlAttributeCollection:
                exit('XmlAttributeCollection');
            "ALI TypeKind"::XmlComment:
                exit('XmlComment');
            "ALI TypeKind"::XmlCData:
                exit('XmlCData');
            "ALI TypeKind"::XmlDeclaration:
                exit('XmlDeclaration');
            "ALI TypeKind"::XmlDocumentType:
                exit('XmlDocumentType');
            "ALI TypeKind"::XmlText:
                exit('XmlText');
            "ALI TypeKind"::XmlProcessingInstruction:
                exit('XmlProcessingInstruction');
            "ALI TypeKind"::XmlNamespaceManager:
                exit('XmlNamespaceManager');
            "ALI TypeKind"::XmlReadOptions:
                exit('XmlReadOptions');
            "ALI TypeKind"::XmlWriteOptions:
                exit('XmlWriteOptions');
            "ALI TypeKind"::XmlNameTable:
                exit('XmlNameTable');
            "ALI TypeKind"::CodeunitRef, "ALI TypeKind"::NativeCodeunit:
                exit('Codeunit');
            else
                exit(StrSubstNo('<type %1>', T));
        end;
    end;
}
