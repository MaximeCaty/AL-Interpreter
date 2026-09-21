// ALI Interaction Mode — how the runtime handles Confirm(...) / StrMenu(...) calls when no
// scripted answer is configured (§8 handler options).
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51112 "ALI Interaction Mode"
{
    Extensible = false;

    value(0; Default) { }   // use scripted/default answer; warn (ALI970/971) if none configured
    value(1; Error) { }     // raise a runtime error instead of guessing an unconfigured answer
    value(2; Show) { }      // show a real Confirm()/StrMenu() when the host session has a GUI
}
