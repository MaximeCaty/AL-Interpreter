// ALI Rec Meta — table/field metadata oracle, memoized (§6.3).
//
// M3 SCOPE DECISION (documented per the M3 note in the task / §6.3 / §16 M6):
// RecMeta is fully an M6 deliverable. For M3 we ship the MEMOIZATION SHAPE only — the
// cache columns, the name->id map, and the public API surface the binder codes against —
// but the actual metadata *lookup* is left unpopulated. Both resolver entry points
// (TryTableId / TryFieldInfo) return false in M3, which the binder turns into a clean
// deferral diagnostic (ALI910 "record field binding is not available until M6") rather
// than a crash or a misleading AL0132. When M6 wires AllObjWithCaption + the virtual
// `Field` table into Populate*, the binder needs no change: it already consults this
// oracle and handles the false case gracefully.
//
// Memoization design (for M6 to fill in): TableNameMap uppercase-name -> table id; a
// per-table field cache keyed on (tableId, fieldNameId) -> packed (fieldNo, TypeOrd,
// length, class). Isolated so tests can stub it (§6.3) and a future harvested-object
// feature can extend it.
codeunit 51040 "ALI Rec Meta"
{
    Access = Public;
    SingleInstance = false;

    var
        // Session-lifetime raw-metadata cache (SingleInstance): the SQL/virtual-table reads
        // (table-id + field rows) run once per session, not per compile. See its file header.
        Cache: Codeunit "ALI Rec Meta Cache";

        Enabled: Boolean;                   // M3: false. M6: true once populated.
        // --- Field memo: key = tableId * FieldStride + fieldNameId -> row index. BigInteger
        // because real table ids (AppSource ranges included) overflow Int32 once multiplied
        // by FieldStride. ---
        FieldMemo: Dictionary of [BigInteger, Integer];
        TableIDLoaded: Dictionary of [Integer, Boolean];
        // --- Table name (uppercase) -> table id memo (M6 populates) ---
        TableNameMap: Dictionary of [Text, Integer];
        FieldClass: List of [Integer];      // 0 Normal / 1 FlowField / 2 FlowFilter
        FieldLen: List of [Integer];
        FieldNo: List of [Integer];
        FieldType: List of [Integer];       // "ALI TypeKind" ordinal

    local procedure FieldStride(): BigInteger
    begin
        exit(1000000);
    end;

    // ===== Lifecycle =====

    procedure Reset()
    begin
        Clear(TableNameMap);
        Clear(FieldMemo);
        Clear(FieldNo);
        Clear(FieldType);
        Clear(FieldLen);
        Clear(FieldClass);
        Enabled := false;   // M3: metadata resolution disabled (see file header)
    end;

    // Whether real table/field metadata resolution is available. M3 returns false; M6 flips
    // this on after wiring the virtual tables. The binder branches on this to choose between
    // real resolution and the clean deferral diagnostic.
    procedure IsEnabled(): Boolean
    begin
        exit(Enabled);
    end;

    // ===== Resolution (M3: always false; shape ready for M6) =====

    // Resolve a table by (uppercase) name. M3: false. Returns table id via `TableId`.
    procedure TryTableId(UpperName: Text; var TableId: Integer): Boolean
    var
        Id: Integer;
    begin
        if not Enabled then
            exit(false);
        if TableNameMap.Get(UpperName, Id) then begin
            TableId := Id;
            exit(true);
        end;
        exit(false);
    end;

    // Resolve a field by (tableId, fieldNameId). M3: false. On success fills fieldNo/type/len.
    procedure TryFieldInfo(TableId: Integer; FieldNameId: Integer; var FNo: Integer; var FType: Integer; var FLen: Integer; var FClass: Integer): Boolean
    var
        KeyI: BigInteger;
        Row: Integer;
    begin
        if not Enabled then
            exit(false);
        KeyI := TableId * FieldStride() + FieldNameId;
        if FieldMemo.Get(KeyI, Row) then begin
            FNo := FieldNo.Get(Row);
            FType := FieldType.Get(Row);
            FLen := FieldLen.Get(Row);
            FClass := FieldClass.Get(Row);
            exit(true);
        end;
        exit(false);
    end;

    // ===== M6 population helpers =====

    procedure RegisterTable(UpperName: Text; TableId: Integer)
    begin
        TableNameMap.Set(UpperName, TableId);
        TableIDLoaded.Set(TableId, true);
        Enabled := true;
    end;

    procedure RegisterField(TableId: Integer; FieldNameId: Integer; FNo: Integer; FType: Integer; FLen: Integer; FClass: Integer)
    var
        KeyI: BigInteger;
    begin
        FieldNo.Add(FNo);
        FieldType.Add(FType);
        FieldLen.Add(FLen);
        FieldClass.Add(FClass);
        KeyI := TableId * FieldStride() + FieldNameId;
        FieldMemo.Set(KeyI, FieldNo.Count());
    end;

    // ===== M6 real metadata wiring (§6.3) =====
    //
    // Resolve a table by name against object metadata (AllObjWithCaption) and memoize its
    // fields from the virtual Field table. Field NAMES are interned into the SAME identifier
    // pool the binder compares against (integer NameId) so TryFieldInfo takes a pool index,
    // not a string. FieldNameId here IS that interned pool index — the binder passes the
    // Tokens' interned id for the member name; population interns the field's real name via
    // the caller-supplied intern callback. To keep RecMeta free of a Tokens dependency, the
    // binder drives population: it enumerates the table's fields (EnumerateFields) and
    // registers each one with an interned name id it computes.

    // Resolve a table id from its (unquoted) name via object metadata. Returns false when no
    // table of that name is deployed. Does NOT populate fields (the binder calls
    // EnsureTablePopulated with an intern callback once the id is known). Delegated to the
    // session cache so the object-metadata read happens once per table per session.
    procedure ResolveTableIdByName(TableName: Text; var TableId: Integer): Boolean
    begin
        exit(Cache.ResolveTableId(TableName, TableId));
    end;

    // Whether this table's fields have already been memoized (avoids re-enumerating).
    procedure IsTablePopulated(TableId: Integer): Boolean
    begin
        exit(TableIDLoaded.ContainsKey(TableId));
    end;

    // Enumerate a table's normal + flow fields from the virtual Field table. The binder
    // consumes this (interning each name into the identifier pool) via RegisterField. Field
    // TYPE is mapped to an "ALI TypeKind" ordinal by the binder (it owns TypeRules); here we
    // hand back the native FieldType option ordinal so the binder can map it. Returns the
    // field count; the parallel out lists are cleared then filled.
    procedure EnumerateFields(TableId: Integer; var FldNos: List of [Integer]; var FldNames: List of [Text]; var FldNativeTypes: List of [Integer]; var FldLens: List of [Integer]; var FldClasses: List of [Integer]): Integer
    begin
        // Delegated to the session cache: the virtual `Field` table is read once per table per
        // session; later compiles re-intern the cached names without a server round trip.
        exit(Cache.GetFields(TableId, FldNos, FldNames, FldNativeTypes, FldLens, FldClasses));
    end;
}
