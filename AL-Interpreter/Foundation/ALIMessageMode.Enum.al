// ALI Message Mode — how the runtime handles Message(...) calls (§8 handler options).
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51113 "ALI Message Mode"
{
    Extensible = false;

    value(0; Log) { }       // collect into ExecResult only (headless default) — never shows a dialog
    value(1; Show) { }      // collect AND show a real Message() when the host session has a GUI
}
