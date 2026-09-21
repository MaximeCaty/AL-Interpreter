// ALI Exec Mode — execution mode per §8. Both stop at first runtime error.
// FROZEN SERIALIZATION CONTRACT (§10): explicit dense ordinals from 0, append-only.
enum 51101 "ALI Exec Mode"
{
    Extensible = false;

    value(0; Normal) { }        // runs in caller transaction; COMMIT executes
    value(1; Simulation) { }    // Codeunit.Run scope + sentinel-error rollback; COMMIT ignored
}
