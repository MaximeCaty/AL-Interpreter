// ALI Severity — diagnostic severity per §4.3.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51106 "ALI Severity"
{
    Extensible = false;

    value(0; Info) { }
    value(1; Warning) { }
    value(2; Error) { }
}
