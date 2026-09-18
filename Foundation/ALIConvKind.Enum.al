enum 51103 "ALI Conv Kind"
{
    // ===== Implicit-conversion lattice (§6.4) =====
    //
    // ConvOrd values written onto operand nodes (the lowerer emits CONV_*; the interpreter
    // never type-checks at runtime). 0 = identity (no conversion needed) AND "no implicit
    // conversion exists" — callers gate on "ALI Type Rules".CanConvert() to tell them apart.
    // Binder <-> lowerer contract: dense and append-only.
    value(0; None) { }                    // identity
    value(1; IntToDec) { }                // Int/BigInt/Char/Byte/Option -> Decimal
    value(2; CharToInt) { }               // Char -> Int (arithmetic context)
    value(3; IntToChar) { }               // Int -> Char (checked 0..65535)
    value(4; OptionToInt) { }             // Option -> underlying Int
    value(5; IntToOption) { }             // Int -> Option ordinal
    value(6; IntToBigInt) { }             // Int -> BigInteger
    value(7; TextToCode) { }              // Text -> Code (upper-on-store)
    value(8; CodeToText) { }              // Code -> Text
    value(9; ByteToInt) { }               // Byte -> Int
    value(10; ToText) { }                 // any -> Text (Format, for concat)

    // --- M4 additions (append-only): native narrowing assignments (§6.4 pitfall 24).
    value(11; DecToInt) { }               // Decimal -> Int (native rounding)
    value(12; DecToBigInt) { }            // Decimal -> BigInteger (native rounding)
    value(13; BigIntToInt) { }            // BigInteger -> Int (native overflow check)
    value(14; IntToByte) { }              // Int -> Byte (checked 0..255)
    value(15; TextToDateFormula) { }      // Text/Code literal -> DateFormula (evaluated at runtime)
    value(16; Box) { }                    // any scalar -> Variant (CONV_BOX)
    value(17; Unbox) { }                  // Variant -> any scalar (CONV_UNBOX; runtime-checked)
    value(18; CharToText) { }             // Char -> Text/Code (single-character text; CHAR_TO_TEXT)

    // Text/Code -> SecretText (`Secret := 'literal';`, native implicit and ONE-WAY — the
    // reverse needs an explicit Unwrap()). Both sides live in the Text register file, so this
    // emits nothing: it exists purely to make the assignment legal at bind time.
    value(19; TextToSecret) { }
}
