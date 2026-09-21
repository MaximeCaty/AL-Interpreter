// ALI TypeKind — static type classes per §19.2/§19.3.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
// Register-class mapping (§7.1) keys off these; RefShim types (§19.5/§19.7) use handle
// tables. ObjectId (§19.6) is a plain Int subtype stored as Int.
enum 51109 "ALI TypeKind"
{
    Extensible = false;

    // --- Special ---
    value(0; None) { }
    value(1; ErrorType) { }                 // poisoning type (§6.2) — never cascades
    value(5; Dialog) { }
    // --- Numeric primitives ---
    value(10; Integer) { }
    value(11; BigInteger) { }
    value(12; Decimal) { }
    value(13; Char) { }
    value(14; Byte) { }

    // --- Boolean ---
    value(20; Boolean) { }

    // --- Text family (Text register file) ---
    value(30; Text) { }                     // Text and Text[n]
    value(31; Code) { }                     // Code[n] — upper-on-store, comparison casing
    value(32; Label) { }

    // --- Option ---
    value(40; Option) { }                   // Int-backed; :: yields ordinal
    value(41; Enum) { }                      // Int-backed; distinct metadata source from Option (§D1)

    // --- Date/time family ---
    value(50; Date) { }
    value(51; Time) { }
    value(52; DateTime) { }
    value(53; Duration) { }
    value(54; DateFormula) { }              // equality only, no ordering (§6.4); own register class

    // --- Misc primitives ---
    value(60; Guid) { }                     // equality only, no ordering (§6.4)

    // --- Aggregates ---
    value(70; Array) { }                    // 1-D fixed; element type in TypeArg
    value(71; Variant) { }                  // fallback register file

    // --- RefShim types (§19.3/§19.5/§19.7) ---
    value(80; Record) { }                   // via RecordRef (§7.5); value semantics on :=
    value(81; RecordRef) { }                // reference handle; §19.5
    value(82; FieldRef) { }                 // reference handle; §19.5
    value(83; KeyRef) { }                   // reference handle; §19.5
    value(84; InStream) { }                 // §19.7
    value(85; OutStream) { }                // §19.7
    value(86; CodeunitRef) { }              // object-id / harvested-call target (§18)
    value(87; ObjectId) { }                 // result of :: object access — Int subtype (§19.6)
    value(88; TextBuilder) { }              // §19.7-style handle; own handle space (M9)

    // --- List/Dictionary RefShim (see ListDictionaryPlan.md): Int-handle references, own
    // register class is Int (RegClassFor -> RegClassInt) — reference semantics come free
    // from the normal Int MOV_I/ARG_VAL/RESULT_FETCH machinery. TypeArg carries the packed
    // element class (List) or keyClass*16+valueClass (Dictionary). ---
    value(89; List) { }
    value(90; Dictionary) { }

    // --- RecordID (§7.1): own register class, native RecordId-backed; equality only ---
    value(91; RecordID) { }

    // --- Http* RefShim (M10): Int-handle reference, same scheme as List/Dictionary/Array
    // (RegClassFor -> RegClassInt) — := and handle-returning methods come free from the
    // normal Int MOV_I/ARG_VAL/RESULT_FETCH/GLOB_LOAD/STORE machinery; no own handle space. ---
    value(92; HttpClient) { }
    value(93; HttpRequestMessage) { }
    value(94; HttpResponseMessage) { }
    value(95; HttpContent) { }
    value(96; HttpHeaders) { }

    // --- Json* RefShim (Feature 2): Int-handle reference, same scheme as Http* (M10) —
    // RegClassFor -> RegClassInt; unified bank in "ALI Json Runtime" stores every kind as
    // JsonToken (reference type over one DOM). ---
    value(97; JsonObject) { }
    value(98; JsonArray) { }
    value(99; JsonToken) { }
    value(100; JsonValue) { }

    // --- BLOB table field: not a variable type, only ever the type of a `Rec.MyBlob` member
    // access. Carries no register class (never loaded as a value) — the only legal uses are
    // the four blob methods CreateInStream/CreateOutStream/HasValue/Length. ---
    value(101; Blob) { }

    // --- Xml* RefShim (Feature 3, XML_DESIGN.md): Int-handle reference, same scheme as
    // Json* (Feature 2) — RegClassFor -> RegClassInt; := and handle-returning methods come
    // free from the normal Int MOV_I/ARG_VAL/RESULT_FETCH machinery. The 10 NODE kinds
    // (102-105, 108-113) share ONE unified bank in "ALI Xml Runtime" (List of [XmlNode] —
    // every node kind round-trips AsXmlNode()/AsXml<Kind>(), verified against native alc);
    // XmlNodeList/XmlAttributeCollection/XmlNamespaceManager/Xml{Read,Write}Options/
    // XmlNameTable each get their own bank (all valid List element types — no box-codeunit
    // indirection, unlike Http*). New-allocator method id = ordinal - 101 (XML_DESIGN.md §3). ---
    value(102; XmlDocument) { }
    value(103; XmlNode) { }
    value(104; XmlElement) { }
    value(105; XmlAttribute) { }
    value(106; XmlNodeList) { }
    value(107; XmlAttributeCollection) { }
    value(108; XmlComment) { }
    value(109; XmlCData) { }
    value(110; XmlDeclaration) { }
    value(111; XmlDocumentType) { }
    value(112; XmlText) { }
    value(113; XmlProcessingInstruction) { }
    value(114; XmlNamespaceManager) { }
    value(115; XmlReadOptions) { }
    value(116; XmlWriteOptions) { }
    value(117; XmlNameTable) { }

    // --- SecretText: NOT a handle type. Represented in the Text register file (RegClassFor ->
    // RegClassText) — the value IS the plain text, and SecretText-ness is a purely STATIC
    // property enforced by the binder: Text -> SecretText assigns implicitly (ConvTextToSecret,
    // a same-class no-op move, mirroring native AL), SecretText -> Text does NOT, and the only
    // members are IsEmpty()/Unwrap(). ponytail: no separate secret store — an in-process
    // interpreter has nowhere to hide a secret from itself, so the type buys compile-time
    // leak-prevention only, which is the same guarantee native AL's compiler gives. ---
    value(118; SecretText) { }

    // --- BigText: mutable text buffer, own flat handle bank in "ALI BigText Runtime" (same
    // scheme as TextBuilder — List of [BigText], RegClassFor -> RegClassInt, per-proc-entry
    // fresh handle, freed on frame pop). ---
    value(119; BigText) { }

    // --- Media / MediaSet table fields: not variable types (native alc rejects `M: Media` with
    // AL0157), so — exactly like Blob (101) — these are only ever the type of a `Rec.MyPicture`
    // member access and carry no register class. Legal uses are the media methods only. ---
    value(120; Media) { }
    value(121; MediaSet) { }

    // --- NativeCodeunit: a `Codeunit "X"` variable whose codeunit is on the STATEFUL native
    // catalogue ("ALI Builtin Registry".IsStatefulNative — Data Compression). Unlike CodeunitRef
    // (no register, harvested procedures) it is an Int-handle reference into the instance bank of
    // "ALI Native Runtime": a real platform instance per variable, fresh at every proc entry for a
    // local, freed on frame pop — the TextBuilder scheme. TypeArg = codeunit id. ---
    value(122; NativeCodeunit) { }
}
