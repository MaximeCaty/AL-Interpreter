// ALI Rec Meta Cache — SESSION-lifetime store of raw table/field metadata (§6.3 perf).
//
// "ALI Rec Meta" is instance-scoped and Reset() on every Compile, because its field memo is
// keyed on the INTERNED field-name id — and the identifier intern pool is rebuilt per compile
// (a name's pool index is only valid within one compile). So the interned view cannot survive
// a compile. The RAW metadata behind it, however, is session-static: object ids and the
// virtual `Field` table do not change between two Compile() calls in the same session.
//
// This codeunit caches exactly that raw layer — the SQL/virtual-table reads (AllObjWithCaption
// for table ids, the `Field` table for field rows) — SingleInstance so each table is queried
// ONCE per session instead of on every compile. "ALI Rec Meta" delegates its two resolver
// entry points here; per-compile work then collapses to re-interning the cached field NAMES
// into the current pool (in-memory, cheap), with no server round trip.
codeunit 51151 "ALI Rec Meta Cache"
{
    Access = Public;
    SingleInstance = true;

    var
        // Per-table field rows, keyed by table id. Parallel lists mirror EnumerateFields' out
        // params. A table is memoized (incl. the empty case) once it appears in FieldsLoaded.
        FieldsLoaded: Dictionary of [Integer, Boolean];
        CFieldClasses: Dictionary of [Integer, List of [Integer]];
        CFieldLens: Dictionary of [Integer, List of [Integer]];
        CFieldNativeTypes: Dictionary of [Integer, List of [Integer]];
        CFieldNos: Dictionary of [Integer, List of [Integer]];
        CFieldNames: Dictionary of [Integer, List of [Text]];
        // UPPER(table name) -> table id; 0 is the "queried, does not exist" sentinel so a
        // miss is not re-queried either.
        TableIdMap: Dictionary of [Text, Integer];

    // Resolve a table id from its (unquoted) name via object metadata, memoized. Returns false
    // when no table of that name is deployed (the miss is cached too).
    procedure ResolveTableId(TableName: Text; var TableId: Integer): Boolean
    var
        AllObj: Record AllObjWithCaption;
        Id: Integer;
        UpperName: Text;
    begin
        UpperName := UpperCase(TableName);
        if TableIdMap.Get(UpperName, Id) then begin
            TableId := Id;
            exit(Id <> 0);
        end;
        AllObj.SetRange("Object Type", AllObj."Object Type"::Table);
        AllObj.SetRange("Object Name", CopyStr(TableName, 1, MaxStrLen(AllObj."Object Name")));   // >30-char names stored truncated
        if AllObj.FindFirst() then
            Id := AllObj."Object ID"
        else
            Id := 0;
        TableIdMap.Set(UpperName, Id);
        TableId := Id;
        exit(Id <> 0);
    end;

    // Field rows for a table (normal + flow, system fields excluded), memoized. Out lists are
    // freshly filled from the cache each call (the caller re-interns the names into its own
    // pool). Native field TYPE is handed back un-mapped — the binder owns TypeRules. Returns
    // the field count.
    procedure GetFields(TableId: Integer; var FldNos: List of [Integer]; var FldNames: List of [Text]; var FldNativeTypes: List of [Integer]; var FldLens: List of [Integer]; var FldClasses: List of [Integer]): Integer
    var
        i: Integer;
        Classes: List of [Integer];
        Lens: List of [Integer];
        NativeTypes: List of [Integer];
        Nos: List of [Integer];
        Names: List of [Text];
    begin
        if not FieldsLoaded.ContainsKey(TableId) then
            LoadFields(TableId);
        Clear(FldNos);
        Clear(FldNames);
        Clear(FldNativeTypes);
        Clear(FldLens);
        Clear(FldClasses);
        CFieldNos.Get(TableId, Nos);
        CFieldNames.Get(TableId, Names);
        CFieldNativeTypes.Get(TableId, NativeTypes);
        CFieldLens.Get(TableId, Lens);
        CFieldClasses.Get(TableId, Classes);
        // Copy out (do not alias the cached lists — the caller receives fresh, mutable lists,
        // matching the original EnumerateFields contract).
        for i := 1 to Nos.Count() do begin
            FldNos.Add(Nos.Get(i));
            FldNames.Add(Names.Get(i));
            FldNativeTypes.Add(NativeTypes.Get(i));
            FldLens.Add(Lens.Get(i));
            FldClasses.Add(Classes.Get(i));
        end;
        exit(FldNos.Count());
    end;

    // One-time SQL read of a table's fields into the cache (§6.3 — the sole server round trip;
    // every later GetFields for this table serves from memory).
    local procedure LoadFields(TableId: Integer)
    var
        FieldRec: Record Field;
        Classes: List of [Integer];
        Lens: List of [Integer];
        NativeTypes: List of [Integer];
        Nos: List of [Integer];
        Names: List of [Text];
    begin
        FieldRec.SetRange(TableNo, TableId);
        FieldRec.SetFilter("No.", '<%1', 2000000000);   // skip system fields (>= 2e9)
        if FieldRec.FindSet() then
            repeat
                Nos.Add(FieldRec."No.");
                Names.Add(FieldRec.FieldName);
                NativeTypes.Add(FieldRec.Type);
                Lens.Add(FieldRec.Len);
                case FieldRec.Class of
                    FieldRec.Class::FlowField:
                        Classes.Add(1);
                    FieldRec.Class::FlowFilter:
                        Classes.Add(2);
                    else
                        Classes.Add(0);
                end;
            until FieldRec.Next() = 0;
        CFieldNos.Set(TableId, Nos);
        CFieldNames.Set(TableId, Names);
        CFieldNativeTypes.Set(TableId, NativeTypes);
        CFieldLens.Set(TableId, Lens);
        CFieldClasses.Set(TableId, Classes);
        FieldsLoaded.Set(TableId, true);
    end;
}
