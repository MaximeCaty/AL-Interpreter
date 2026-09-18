// TEST BUILD ONLY — excluded unless the TEST preprocessor symbol is defined (app.json
// preprocessorSymbols). The public release ships without it, so it needs no dependency on
// Microsoft's "Library Assert" test library, which is not installed by default.
#if TEST
// ALI Test Customer Report — fixture for the static `Report.Run(id, ..., Rec)` native rows.
//
// Processing-only and never really executed: the test's ReportHandler takes the run over, so
// all it has to be is a report on "ALI Test Customer" the handler can be typed against.
report 51000 "ALI Test Customer Report"
{
    ProcessingOnly = true;
    UseRequestPage = false;
    Caption = 'ALI Test Customer Report';

    dataset
    {
        dataitem(Customer; "ALI Test Customer")
        {
        }
    }
}
#endif
