// The extension's one assignable permission set. Required for a cloud publication: every table an
// extension declares must be covered by a permission set it ships (PTE0004 / AS0103), because a
// tenant administrator has no other way to grant access to it.
//
// RIMD on both tables, because both are things the USER maintains from the UI: stored scripts are
// written, renamed and deleted from the Script Editor, and preprocessor symbols are typed into
// their own list page. A read-only variant would make the app look installed but unusable.
permissionset 51101 "ALI Interpreter"
{
    Access = Public;
    Assignable = true;
    Caption = 'AL Interpreter', MaxLength = 30, Comment = 'Interpréteur AL';

    Permissions =
#if not CLOUD
        // On premise only — the table does not exist in a cloud build (see "ALI Preproc Symbol").
        tabledata "ALI Preproc Symbol" = RIMD,
#endif
#if TEST
        // Test build only. The test tables are real published objects (the interpreter harvests
        // their AL source at run time), so they need covering like any other table this app
        // declares — they simply are not there in a release build.
        tabledata "ALI Test Customer" = RIMD,
        tabledata "ALI Test Order Line" = RIMD,
#endif
        tabledata "ALI Stored Script" = RIMD;
}
