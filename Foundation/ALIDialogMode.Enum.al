// ALI Dialog Mode — governs the interpreter's GuiAllowed() result, so scripts that guard
// progress windows / dialogs with `if GuiAllowed then ...` run or skip that code (§8 handler
// options). Note: a first-class Window/Dialog progress-bar type is separate future work; this
// knob controls the GuiAllowed gate those scripts already use.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51015 "ALI Dialog Mode"
{
    Extensible = false;

    value(0; Show) { }      // GuiAllowed() returns true — dialog-guarded code runs
    value(1; Hide) { }      // GuiAllowed() returns false — dialog-guarded code is skipped (headless default)
}
