// ALI TokenKind — token taxonomy (subset of Microsoft SyntaxKind.cs) per §1.1/§3.3.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, first-write order.
// Rules: never renumber; additions APPEND at next free ordinal only; never reuse an
// ordinal; any violation is a format-version bump. Do NOT rely on AL auto-numbering.
// Names mirror Microsoft SyntaxKind.cs so the decompiled source stays a usable reference.
enum 51012 "ALI TokenKind"
{
    Extensible = false;

    // --- Special / control ---
    value(0; None) { }
    value(1; EndOfFileToken) { }
    value(2; BadToken) { }
    value(3; MissingToken) { }   // synthetic zero-width token from error recovery (§5.2)

    // --- Literals ---
    value(10; Int32LiteralToken) { }
    value(11; Int64LiteralToken) { }        // BigInteger literal
    value(12; DecimalLiteralToken) { }
    value(13; DateLiteralToken) { }
    value(14; TimeLiteralToken) { }
    value(15; DateTimeLiteralToken) { }
    value(16; StringLiteralToken) { }

    // --- Identifiers / keywords baseline ---
    value(20; IdentifierToken) { }          // includes quoted identifiers
    value(21; TrueKeyword) { }
    value(22; FalseKeyword) { }

    // --- Arithmetic operators ---
    value(30; PlusToken) { }                // +
    value(31; MinusToken) { }               // -
    value(32; MultiplyToken) { }            // *
    value(33; RDivToken) { }                // /  (always Decimal result, §6.4)
    value(34; IDivKeyword) { }              // div
    value(35; ModuloKeyword) { }            // mod

    // --- Assignment operators ---
    value(40; AssignToken) { }              // :=
    value(41; AssignPlusToken) { }          // +=
    value(42; AssignMinusToken) { }         // -=
    value(43; AssignMultiplyToken) { }      // *=
    value(44; AssignRDivToken) { }          // /=

    // --- Comparison operators (all power 3, §5.2) ---
    value(50; EqualsToken) { }              // =
    value(51; NotEqualsToken) { }           // <>
    value(52; LessThanToken) { }            // <
    value(53; LessThanEqualsToken) { }      // <=
    value(54; GreaterThanToken) { }         // >
    value(55; GreaterThanEqualsToken) { }   // >=

    // --- Logical keyword operators ---
    value(60; AndKeyword) { }               // and (power 5)
    value(61; OrKeyword) { }                // or  (power 4)
    value(62; XorKeyword) { }               // xor (power 4, with or)
    value(63; NotKeyword) { }               // not (unary)

    // --- Punctuation / structural ---
    value(70; OpenParenToken) { }           // (
    value(71; CloseParenToken) { }          // )
    value(72; OpenBracketToken) { }         // [
    value(73; CloseBracketToken) { }        // ]
    value(74; OpenBraceToken) { }           // {
    value(75; CloseBraceToken) { }          // }
    value(76; CommaToken) { }               // ,
    value(77; DotToken) { }                 // .
    value(78; DotDotToken) { }              // ..  (positional only, §5.2)
    value(79; ColonToken) { }               // :
    value(80; ColonColonToken) { }          // ::
    value(81; SemicolonToken) { }           // ;

    // --- Statement / declaration keywords ---
    value(100; IfKeyword) { }
    value(101; ThenKeyword) { }
    value(102; ElseKeyword) { }
    value(103; CaseKeyword) { }
    value(104; OfKeyword) { }
    value(105; ForKeyword) { }
    value(106; ToKeyword) { }
    value(107; DownToKeyword) { }
    value(108; DoKeyword) { }
    value(109; WhileKeyword) { }
    value(110; RepeatKeyword) { }
    value(111; UntilKeyword) { }
    value(112; ForEachKeyword) { }          // v2, recognized now
    value(113; InKeyword) { }
    value(114; BeginKeyword) { }
    value(115; EndKeyword) { }
    value(116; ExitKeyword) { }
    value(117; BreakKeyword) { }
    value(118; WithKeyword) { }             // rejected with diagnostic (NoImplicitWith)

    // --- Object / member declaration keywords ---
    value(130; ProcedureKeyword) { }
    value(131; LocalKeyword) { }
    value(132; InternalKeyword) { }
    value(133; ProtectedKeyword) { }
    value(134; VarKeyword) { }
    value(135; ArrayKeyword) { }
    value(136; TemporaryKeyword) { }
    value(137; TriggerKeyword) { }
    value(138; CodeunitKeyword) { }
    value(139; TableKeyword) { }
    value(140; PageKeyword) { }
    value(141; ReportKeyword) { }
    value(142; QueryKeyword) { }
    value(143; XmlPortKeyword) { }
    value(144; DotNetKeyword) { }           // detected for the §18.3 gate
    value(145; EventKeyword) { }
}
