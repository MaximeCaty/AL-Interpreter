// Application-level record security filters (e.g. User Setup responsibility center, Finance budget
// user filters) applied to every generic data-access path (AI tools, AL interpreter). BC permissions
// already hold because these paths run as the user; this covers what apps restrict by filter.
//
// Subscriber rules: this runs on every table open — check RecordReference.Number first and exit
// early; only SetFilter/SetRange, never change the filter group (the publisher owns group 2).
// When a filter is actually set, APPEND a short reason, never overwrite:
//     if Reason <> '' then Reason += ' ';
//     Reason += 'Restricted by ...';
codeunit 51045 "ALI Record Security Filters"
{
    Access = Public;

    var
        SecurityNoteLbl: Label 'Security: table "%1" is limited to the current user''s authorized view (%2). Records outside this view are invisible: empty or partial result does NOT mean data does not exist.', Locked = true;

    // Returns an LLM-facing note describing the applied filters, '' when nothing was restricted.
    // Scope and filters only — never a count of hidden records.
    procedure ApplyFilters(var RecRef: RecordRef) Note: Text
    var
        AppliedFilters: Text;
        Reason: Text;
        FltTxt: Text;
        i: Integer;
        PrevGroup: Integer;
    begin
        if RecRef.IsTemporary() then
            exit('');
        PrevGroup := RecRef.FilterGroup();
        RecRef.FilterGroup(2);
        OnApplyRecordSecurityFilters(RecRef, Reason);
        // Field loop rather than GetFilters: only group 2 must be reported, whatever GetFilters covers.
        for i := 1 to RecRef.FieldCount() do begin
            FltTxt := RecRef.FieldIndex(i).GetFilter();
            if FltTxt <> '' then begin
                if AppliedFilters <> '' then
                    AppliedFilters += ', ';
                AppliedFilters += RecRef.FieldIndex(i).Name() + ': ' + FltTxt;
            end;
        end;
        RecRef.FilterGroup(PrevGroup);
        if AppliedFilters = '' then
            exit('');
        Note := StrSubstNo(SecurityNoteLbl, RecRef.Caption(), AppliedFilters);
        if Reason <> '' then
            Note += ' ' + Reason;
    end;

    [IntegrationEvent(false, false)]
    procedure OnApplyRecordSecurityFilters(var RecordReference: RecordRef; var Reason: Text)
    begin
    end;
}
