// ALI Builtin Kind — interpreter dispatch kind, resolved once at registry build time
// (see "ALI Builtin Registry".ClassifyKinds) and read per builtin call by the interpreter.
// Ordinals match the former KindSplit()/KindVariantTest() constants.
enum 51120 "ALI Builtin Kind"
{
    Extensible = false;

    value(0; Ordinary) { }      // routed by Domain to the Str/Math/DateTime/System handler
    value(1; Split) { }         // returns a List of [Text] handle — built in the interpreter
    value(2; VariantTest) { }   // §19.2 IsInteger/IsText/... on a Variant receiver
}
