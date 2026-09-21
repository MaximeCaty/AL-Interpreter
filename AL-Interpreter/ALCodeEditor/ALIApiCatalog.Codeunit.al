// ALI Api Catalog — serializes the interpreter's SUPPORTED SURFACE (data types, builtin
// functions, per-receiver-type methods, table metadata) as JSON for the "ALI Code Editor"
// controladdin's autocompletion/hover. Single AL-side source of truth: builtins come straight
// from "ALI Builtin Registry" (the binder's own table, so they can never drift), the
// per-type method tables mirror the binder's *MethodId maps 1:1 (kept HERE, next to the
// compiler, instead of hardcoded in JS — update both when a method family grows; the
// ALIApiCatalogTests probe-compile guard keeps this honest).
codeunit 51149 "ALI Api Catalog"
{
    Access = Public;

    var
        Builtins: Codeunit "ALI Builtin Registry";
        TypeRules: Codeunit "ALI Type Rules";

    // ===== Full catalog: { types: [..], builtins: [..], methods: { Type: [..] } } =====

    procedure BuildCatalogJson(): Text
    var
        Root: JsonObject;
        JsonText: Text;
    begin
        Root.Add('types', BuildTypesArray());
        Root.Add('builtins', BuildBuiltinsArray());
        Root.Add('methods', BuildMethodsObject());
        Root.WriteTo(JsonText);
        exit(JsonText);
    end;

    // Data types accepted in a `var` declaration (see SUPPORTED_FEATURES.md §1).
    local procedure BuildTypesArray(): JsonArray
    var
        Arr: JsonArray;
    begin
        Arr.Add('Integer');
        Arr.Add('BigInteger');
        Arr.Add('Decimal');
        Arr.Add('Boolean');
        Arr.Add('Text');
        Arr.Add('Code');
        Arr.Add('Date');
        Arr.Add('Time');
        Arr.Add('DateTime');
        Arr.Add('Duration');
        Arr.Add('DateFormula');
        Arr.Add('Guid');
        Arr.Add('Option');
        Arr.Add('Label');
        Arr.Add('Variant');
        Arr.Add('RecordId');
        Arr.Add('Record');
        Arr.Add('RecordRef');
        Arr.Add('FieldRef');
        Arr.Add('KeyRef');
        Arr.Add('Codeunit');
        Arr.Add('Enum');
        Arr.Add('Array');
        Arr.Add('List');
        Arr.Add('Dictionary');
        Arr.Add('TextBuilder');
        Arr.Add('BigText');
        Arr.Add('SecretText');
        Arr.Add('Dialog');
        Arr.Add('InStream');
        Arr.Add('OutStream');
        Arr.Add('HttpClient');
        Arr.Add('HttpRequestMessage');
        Arr.Add('HttpResponseMessage');
        Arr.Add('HttpContent');
        Arr.Add('HttpHeaders');
        Arr.Add('JsonObject');
        Arr.Add('JsonArray');
        Arr.Add('JsonToken');
        Arr.Add('JsonValue');
        Arr.Add('XmlDocument');
        Arr.Add('XmlNode');
        Arr.Add('XmlElement');
        Arr.Add('XmlAttribute');
        Arr.Add('XmlNodeList');
        Arr.Add('XmlAttributeCollection');
        Arr.Add('XmlComment');
        Arr.Add('XmlCData');
        Arr.Add('XmlDeclaration');
        Arr.Add('XmlDocumentType');
        Arr.Add('XmlText');
        Arr.Add('XmlProcessingInstruction');
        Arr.Add('XmlNamespaceManager');
        Arr.Add('XmlReadOptions');
        Arr.Add('XmlWriteOptions');
        Arr.Add('XmlNameTable');
        Arr.Add('TextEncoding');
        exit(Arr);
    end;

    // Free-function builtins straight from "ALI Builtin Registry": every row the binder can
    // resolve, with its true arity/result/params and the implemented flag (unimplemented rows
    // are recognized-but-rejected — the editor greys them out rather than hiding them).
    local procedure BuildBuiltinsArray(): JsonArray
    var
        BId: Integer;
        i: Integer;
        PT: Integer;
        Arr: JsonArray;
        Params: JsonArray;
        Row: JsonObject;
    begin
        Builtins.EnsureBuilt();
        for BId := 1 to Builtins.Count() do
            // Native catalogue rows are codeunit METHODS (`TypeHelper.UrlEncode`), not free functions.
            if Builtins.GetDomain(BId) <> "ALI Builtin Domain"::Native then begin
                Clear(Row);
                Clear(Params);
                Row.Add('n', Builtins.GetName(BId));
                Row.Add('min', Builtins.GetMinArity(BId));
                Row.Add('max', Builtins.GetMaxArity(BId));
                Row.Add('r', TypeRules.TypeName(Builtins.GetResultType(BId)));
                for i := 1 to Builtins.GetMaxArity(BId) do begin
                    PT := Builtins.ParamType(BId, i);
                    Params.Add(TypeRules.TypeName(PT));
                end;
                Row.Add('p', Params);
                Row.Add('ok', not Builtins.IsUnimplemented(BId));
                Arr.Add(Row);
            end;
        exit(Arr);
    end;

    // Per-receiver-type method tables. MUST mirror the binder maps: RecMethodId,
    // ListMethodId, DictMethodId, TextBuilderMethodId, DialogMethodId, StreamMethodId,
    // HttpMethodId, JsonMethodId (+ typed GetX getters), BindRecordIdMethod,
    // PopulateTextMethods, PopulateVariantMethods.
    local procedure BuildMethodsObject(): JsonObject
    var
        Obj: JsonObject;
    begin
        Obj.Add('Record', RecordMethods());
        Obj.Add('List', ListMethods());
        Obj.Add('Dictionary', DictMethods());
        Obj.Add('TextBuilder', TextBuilderMethods());
        Obj.Add('BigText', BigTextMethods());
        Obj.Add('SecretText', SecretTextMethods());
        Obj.Add('Media', MediaMethods());
        Obj.Add('MediaSet', MediaSetMethods());
        Obj.Add('Dialog', DialogMethods());
        Obj.Add('InStream', InStreamMethods());
        Obj.Add('OutStream', OutStreamMethods());
        Obj.Add('HttpClient', HttpClientMethods());
        Obj.Add('HttpRequestMessage', HttpRequestMethods());
        Obj.Add('HttpResponseMessage', HttpResponseMethods());
        Obj.Add('HttpContent', HttpContentMethods());
        Obj.Add('HttpHeaders', HttpHeadersMethods());
        Obj.Add('JsonObject', JsonObjectMethods());
        Obj.Add('JsonArray', JsonArrayMethods());
        Obj.Add('JsonToken', JsonTokenMethods());
        Obj.Add('JsonValue', JsonValueMethods());
        Obj.Add('XmlDocument', XmlDocumentMethods());
        Obj.Add('XmlNode', XmlNodeMethods());
        Obj.Add('XmlElement', XmlElementMethods());
        Obj.Add('XmlAttribute', XmlAttributeMethods());
        Obj.Add('XmlNodeList', XmlNodeListMethods());
        Obj.Add('XmlAttributeCollection', XmlAttrColMethods());
        Obj.Add('XmlComment', XmlSimpleValueNodeMethods('XmlComment'));
        Obj.Add('XmlCData', XmlSimpleValueNodeMethods('XmlCData'));
        Obj.Add('XmlText', XmlSimpleValueNodeMethods('XmlText'));
        Obj.Add('XmlProcessingInstruction', XmlProcessingInstrMethods());
        Obj.Add('XmlDeclaration', XmlDeclarationMethods());
        Obj.Add('XmlDocumentType', XmlDocumentTypeMethods());
        Obj.Add('XmlNamespaceManager', XmlNamespaceManagerMethods());
        Obj.Add('XmlReadOptions', XmlOptionsMethods());
        Obj.Add('XmlWriteOptions', XmlOptionsMethods());
        Obj.Add('RecordId', RecordIdMethods());
        Obj.Add('RecordRef', RecordRefMethods());
        Obj.Add('FieldRef', FieldRefMethods());
        Obj.Add('KeyRef', KeyRefMethods());
        Obj.Add('Text', TextMethods());
        Obj.Add('Code', TextMethods());
        Obj.Add('Variant', VariantMethods());
        exit(Obj);
    end;

    // One method row: n = insert text, s = display signature, r = result type ('' = void).
    local procedure M(var Arr: JsonArray; Name: Text; Sig: Text; Result: Text)
    var
        Row: JsonObject;
    begin
        Row.Add('n', Name);
        Row.Add('s', Sig);
        Row.Add('r', Result);
        Arr.Add(Row);
    end;

    // Mirrors "ALI Binder".RecMethodId (ids 1-81).
    local procedure RecordMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Init', 'Init()', '');
        M(A, 'Reset', 'Reset()', '');
        M(A, 'Insert', 'Insert([RunTrigger: Boolean])', 'Boolean');
        M(A, 'Modify', 'Modify([RunTrigger: Boolean])', 'Boolean');
        M(A, 'Delete', 'Delete([RunTrigger: Boolean])', 'Boolean');
        M(A, 'DeleteAll', 'DeleteAll([RunTrigger: Boolean])', '');
        M(A, 'Get', 'Get(Value1 [, Value2, ...])', 'Boolean');
        M(A, 'FindSet', 'FindSet([ForUpdate: Boolean])', 'Boolean');
        M(A, 'FindFirst', 'FindFirst()', 'Boolean');
        M(A, 'FindLast', 'FindLast()', 'Boolean');
        M(A, 'Find', 'Find([Which: Text])', 'Boolean');
        M(A, 'Next', 'Next([Steps: Integer])', 'Integer');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'CountApprox', 'CountApprox()', 'Integer');
        M(A, 'IsEmpty', 'IsEmpty()', 'Boolean');
        M(A, 'SetRange', 'SetRange(Field [, From [, To]])', '');
        M(A, 'SetFilter', 'SetFilter(Field, Filter [, Value, ...])', '');
        M(A, 'GetFilter', 'GetFilter(Field)', 'Text');
        M(A, 'GetFilters', 'GetFilters()', 'Text');
        M(A, 'CopyFilter', 'CopyFilter(FromField, ToRec.ToField)', '');
        M(A, 'CopyFilters', 'CopyFilters(FromRecord)', '');
        M(A, 'SetRecFilter', 'SetRecFilter()', '');
        M(A, 'GetRangeMin', 'GetRangeMin(Field)', '');
        M(A, 'GetRangeMax', 'GetRangeMax(Field)', '');
        M(A, 'ModifyAll', 'ModifyAll(Field, NewValue [, RunTrigger])', '');
        M(A, 'CalcFields', 'CalcFields(Field1 [, Field2, ...])', 'Boolean');
        M(A, 'CalcSums', 'CalcSums(Field1 [, Field2, ...])', 'Boolean');
        M(A, 'Validate', 'Validate(Field [, NewValue])', '');
        M(A, 'TestField', 'TestField(Field [, ExpectedValue])', '');
        M(A, 'FieldError', 'FieldError(Field [, Message])', '');
        M(A, 'FieldName', 'FieldName(Field)', 'Text');
        M(A, 'FieldCaption', 'FieldCaption(Field)', 'Text');
        M(A, 'TableName', 'TableName()', 'Text');
        M(A, 'TableCaption', 'TableCaption()', 'Text');
        M(A, 'FullyQualifiedName', 'FullyQualifiedName()', 'Text');
        M(A, 'SetCurrentKey', 'SetCurrentKey(Field1 [, Field2, ...])', '');
        M(A, 'Ascending', 'Ascending([Ascending: Boolean])', 'Boolean');
        M(A, 'SetAscending', 'SetAscending(Field, Ascending)', '');
        M(A, 'GetAscending', 'GetAscending(Field)', 'Boolean');
        M(A, 'CurrentKey', 'CurrentKey()', 'Text');
        M(A, 'CurrentKeyIndex', 'CurrentKeyIndex()', 'Integer');
        M(A, 'Mark', 'Mark([Set: Boolean])', 'Boolean');
        M(A, 'ClearMarks', 'ClearMarks()', '');
        M(A, 'MarkedOnly', 'MarkedOnly([Set: Boolean])', 'Boolean');
        M(A, 'GetPosition', 'GetPosition([UseCaptions: Boolean])', 'Text');
        M(A, 'SetPosition', 'SetPosition(Position: Text)', '');
        M(A, 'GetView', 'GetView([UseCaptions: Boolean])', 'Text');
        M(A, 'SetView', 'SetView(View: Text)', '');
        M(A, 'ChangeCompany', 'ChangeCompany([CompanyName: Text])', 'Boolean');
        M(A, 'CurrentCompany', 'CurrentCompany()', 'Text');
        M(A, 'HasFilter', 'HasFilter()', 'Boolean');
        M(A, 'SetAutoCalcFields', 'SetAutoCalcFields(Field1 [, Field2, ...])', '');
        M(A, 'SetLoadFields', 'SetLoadFields(Field1 [, Field2, ...])', '');
        M(A, 'AddLoadFields', 'AddLoadFields(Field1 [, Field2, ...])', '');
        M(A, 'LoadFields', 'LoadFields(Field1 [, Field2, ...])', 'Boolean');
        M(A, 'AreFieldsLoaded', 'AreFieldsLoaded(Field1 [, Field2, ...])', 'Boolean');
        M(A, 'LockTable', 'LockTable()', '');
        M(A, 'ReadConsistency', 'ReadConsistency()', 'Boolean');
        M(A, 'FieldCount', 'FieldCount()', 'Integer');
        M(A, 'FieldExist', 'FieldExist(FieldNo: Integer)', 'Boolean');
        M(A, 'KeyCount', 'KeyCount()', 'Integer');
        M(A, 'RecordId', 'RecordId()', 'RecordId');
        M(A, 'FilterGroup', 'FilterGroup([Group: Integer])', 'Integer');
        M(A, 'GetBySystemId', 'GetBySystemId(SystemId: Guid)', 'Boolean');
        M(A, 'Rename', 'Rename(Value1 [, Value2, ...])', 'Boolean');
        M(A, 'Copy', 'Copy(FromRecord [, ShareTable])', '');
        M(A, 'TransferFields', 'TransferFields(FromRecord [, InitPrimaryKey])', '');
        M(A, 'Truncate', 'Truncate()', '');
        M(A, 'IsTemporary', 'IsTemporary()', 'Boolean');
        M(A, 'ReadPermission', 'ReadPermission()', 'Boolean');
        M(A, 'WritePermission', 'WritePermission()', 'Boolean');
        M(A, 'AddLink', 'AddLink(Url [, Description])', 'Integer');
        M(A, 'DeleteLink', 'DeleteLink(LinkId: Integer)', '');
        M(A, 'DeleteLinks', 'DeleteLinks()', '');
        M(A, 'CopyLinks', 'CopyLinks(FromRecord)', '');
        M(A, 'HasLinks', 'HasLinks()', 'Boolean');
        M(A, 'ReadIsolation', 'ReadIsolation([Isolation])', 'Integer');
        M(A, 'SetPermissionFilter', 'SetPermissionFilter()', '');
        M(A, 'SecurityFiltering', 'SecurityFiltering([Filtering])', 'Integer');
        M(A, 'RecordLevelLocking', 'RecordLevelLocking()', 'Boolean');
        exit(A);
    end;

    // Mirrors ListMethodId (ids 1-14).
    local procedure ListMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Add', 'Add(Value)', '');
        M(A, 'AddRange', 'AddRange(List)', '');
        M(A, 'Contains', 'Contains(Value)', 'Boolean');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'Get', 'Get(Index: Integer)', 'T');
        M(A, 'GetRange', 'GetRange(Index, Count)', 'List');
        M(A, 'IndexOf', 'IndexOf(Value)', 'Integer');
        M(A, 'Insert', 'Insert(Index, Value)', '');
        M(A, 'Remove', 'Remove(Value)', 'Boolean');
        M(A, 'RemoveAt', 'RemoveAt(Index)', 'Boolean');
        M(A, 'RemoveRange', 'RemoveRange(Index, Count)', '');
        M(A, 'Reverse', 'Reverse()', '');
        M(A, 'Set', 'Set(Index, Value)', '');
        M(A, 'ToArray', 'ToArray()', 'Array');
        exit(A);
    end;

    // Mirrors DictMethodId (ids 1-9).
    local procedure DictMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Add', 'Add(Key, Value)', '');
        M(A, 'ContainsKey', 'ContainsKey(Key)', 'Boolean');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'Get', 'Get(Key [, var Value])', 'V');
        M(A, 'Keys', 'Keys()', 'List');
        M(A, 'Values', 'Values()', 'List');
        M(A, 'Remove', 'Remove(Key)', 'Boolean');
        M(A, 'Set', 'Set(Key, Value)', '');
        exit(A);
    end;

    // Mirrors TextBuilderMethodId (ids 1-16).
    local procedure TextBuilderMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Append', 'Append(Value: Text)', '');
        M(A, 'AppendLine', 'AppendLine([Value: Text])', '');
        M(A, 'Capacity', 'Capacity([NewCapacity: Integer])', 'Integer');
        M(A, 'Clear', 'Clear()', '');
        M(A, 'EnsureCapacity', 'EnsureCapacity(Capacity: Integer)', 'Integer');
        M(A, 'Insert', 'Insert(Index: Integer, Value: Text)', '');
        M(A, 'Length', 'Length([NewLength: Integer])', 'Integer');
        M(A, 'MaxCapacity', 'MaxCapacity()', 'Integer');
        M(A, 'Remove', 'Remove(StartIndex, Length)', '');
        M(A, 'Replace', 'Replace(Old, New [, StartIndex, Count])', '');
        M(A, 'ToText', 'ToText([StartIndex, Length])', 'Text');
        exit(A);
    end;

    // Mirrors BigTextMethodId (ids 1-12).
    local procedure BigTextMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'AddText', 'AddText(Value: Text|BigText [, Position: Integer])', '');
        M(A, 'GetSubText', 'GetSubText(var Target: Text|BigText, Position: Integer [, Length: Integer])', '');
        M(A, 'Length', 'Length()', 'Integer');
        M(A, 'Read', 'Read(Source: InStream)', '');
        M(A, 'TextPos', 'TextPos(Value: Text)', 'Integer');
        M(A, 'Write', 'Write(Target: OutStream)', '');
        exit(A);
    end;

    // Mirrors SecretTextMethodId (ids 50-51).
    local procedure SecretTextMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'IsEmpty', 'IsEmpty()', 'Boolean');
        M(A, 'Unwrap', 'Unwrap()', 'Text');
        exit(A);
    end;

    // Mirrors MediaMethodId (Media ids 1-3) — query side only; ImportStream is refused (ALI997).
    local procedure MediaMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'ExportStream', 'ExportStream(Target: OutStream)', '');
        M(A, 'HasValue', 'HasValue()', 'Boolean');
        M(A, 'MediaId', 'MediaId()', 'Guid');
        exit(A);
    end;

    // Mirrors MediaMethodId (MediaSet ids 20-22) — query side only; Insert/Remove/ImportStream
    // are refused (ALI997).
    local procedure MediaSetMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'Item', 'Item(Index: Integer)', 'Guid');
        M(A, 'MediaId', 'MediaId()', 'Guid');
        exit(A);
    end;

    // Mirrors DialogMethodId (ids 1-5).
    local procedure DialogMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Open', 'Open(Text)', '');
        M(A, 'Update', 'Update([Number [, Value]])', '');
        M(A, 'Close', 'Close()', '');
        exit(A);
    end;

    // Mirrors StreamMethodId — InStream subset.
    local procedure InStreamMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'ReadText', 'ReadText(var Text: Text [, Length: Integer])', 'Integer');
        M(A, 'Read', 'Read(var Target [, Length: Integer])', 'Integer');
        M(A, 'EOS', 'EOS()', 'Boolean');
        M(A, 'Length', 'Length()', 'Integer');
        M(A, 'Position', 'Position([NewPosition: Integer])', 'Integer');
        M(A, 'ResetPosition', 'ResetPosition()', '');
        M(A, 'Link', 'Link(OutStream)', '');
        exit(A);
    end;

    // Mirrors StreamMethodId — OutStream subset.
    local procedure OutStreamMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'WriteText', 'WriteText([Value: Text[, Length: Integer]])', '');
        M(A, 'WriteLine', 'WriteLine(Value: Text)', '');
        M(A, 'Write', 'Write(Value)', 'Integer');
        M(A, 'Length', 'Length()', 'Integer');
        exit(A);
    end;

    // Mirrors HttpMethodId — HttpClient (ids 2-11).
    local procedure HttpClientMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Get', 'Get(Url: Text, var Response: HttpResponseMessage)', 'Boolean');
        M(A, 'Post', 'Post(Url, Content, var Response)', 'Boolean');
        M(A, 'Put', 'Put(Url, Content, var Response)', 'Boolean');
        M(A, 'Delete', 'Delete(Url, var Response)', 'Boolean');
        M(A, 'Send', 'Send(Request, var Response)', 'Boolean');
        M(A, 'SetBaseAddress', 'SetBaseAddress(Url: Text)', '');
        M(A, 'Timeout', 'Timeout([Value: Duration])', 'Duration');
        M(A, 'DefaultRequestHeaders', 'DefaultRequestHeaders()', 'HttpHeaders');
        M(A, 'Clear', 'Clear()', '');
        exit(A);
    end;

    // Mirrors HttpMethodId — HttpRequestMessage (ids 21-28).
    local procedure HttpRequestMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Method', 'Method([Value: Text])', 'Text');
        M(A, 'SetRequestUri', 'SetRequestUri(Url: Text)', '');
        M(A, 'GetRequestUri', 'GetRequestUri()', 'Text');
        M(A, 'Content', 'Content([Value: HttpContent])', 'HttpContent');
        M(A, 'GetHeaders', 'GetHeaders([var Headers: HttpHeaders])', 'HttpHeaders');
        exit(A);
    end;

    // Mirrors HttpMethodId — HttpResponseMessage (ids 41-46).
    local procedure HttpResponseMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'HttpStatusCode', 'HttpStatusCode()', 'Integer');
        M(A, 'IsSuccessStatusCode', 'IsSuccessStatusCode()', 'Boolean');
        M(A, 'ReasonPhrase', 'ReasonPhrase()', 'Text');
        M(A, 'IsBlockedByEnvironment', 'IsBlockedByEnvironment()', 'Boolean');
        M(A, 'Content', 'Content()', 'HttpContent');
        M(A, 'Headers', 'Headers()', 'HttpHeaders');
        exit(A);
    end;

    // Mirrors HttpMethodId — HttpContent (ids 61-65).
    local procedure HttpContentMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'WriteFrom', 'WriteFrom(Value: Text)', '');
        M(A, 'ReadAs', 'ReadAs([var Target: Text])', 'Text');
        M(A, 'GetHeaders', 'GetHeaders([var Headers: HttpHeaders])', 'HttpHeaders');
        M(A, 'Clear', 'Clear()', '');
        exit(A);
    end;

    // Mirrors HttpMethodId — HttpHeaders (ids 81-86).
    local procedure HttpHeadersMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Add', 'Add(Name, Value)', '');
        M(A, 'TryAddWithoutValidation', 'TryAddWithoutValidation(Name, Value)', 'Boolean');
        M(A, 'Contains', 'Contains(Name)', 'Boolean');
        M(A, 'Remove', 'Remove(Name)', 'Boolean');
        M(A, 'Clear', 'Clear()', '');
        M(A, 'GetValues', 'GetValues(Name, var Values: List of [Text])', 'Boolean');
        exit(A);
    end;

    // Shared typed GetX getters (JsonObject key form / JsonArray index form).
    local procedure AddJsonGetters(var A: JsonArray; KeySig: Text)
    begin
        M(A, 'GetText', StrSubstNo('GetText(%1 [, DefaultIfNotFound])', KeySig), 'Text');
        M(A, 'GetInteger', StrSubstNo('GetInteger(%1 [, DefaultIfNotFound])', KeySig), 'Integer');
        M(A, 'GetBigInteger', StrSubstNo('GetBigInteger(%1 [, DefaultIfNotFound])', KeySig), 'BigInteger');
        M(A, 'GetDecimal', StrSubstNo('GetDecimal(%1 [, DefaultIfNotFound])', KeySig), 'Decimal');
        M(A, 'GetBoolean', StrSubstNo('GetBoolean(%1 [, DefaultIfNotFound])', KeySig), 'Boolean');
        M(A, 'GetDate', StrSubstNo('GetDate(%1 [, DefaultIfNotFound])', KeySig), 'Date');
        M(A, 'GetTime', StrSubstNo('GetTime(%1 [, DefaultIfNotFound])', KeySig), 'Time');
        M(A, 'GetDateTime', StrSubstNo('GetDateTime(%1 [, DefaultIfNotFound])', KeySig), 'DateTime');
        M(A, 'GetDuration', StrSubstNo('GetDuration(%1 [, DefaultIfNotFound])', KeySig), 'Duration');
        M(A, 'GetGuid', StrSubstNo('GetGuid(%1 [, DefaultIfNotFound])', KeySig), 'Guid');
        M(A, 'GetObject', StrSubstNo('GetObject(%1 [, DefaultIfNotFound])', KeySig), 'JsonObject');
        M(A, 'GetArray', StrSubstNo('GetArray(%1 [, DefaultIfNotFound])', KeySig), 'JsonArray');
        M(A, 'GetValue', StrSubstNo('GetValue(%1 [, DefaultIfNotFound])', KeySig), 'JsonValue');
    end;

    // GetByte/GetChar/GetOption — separate from AddJsonGetters: native JsonArray has no DefaultIfNotFound overload.
    local procedure AddJsonOrdinalGetters(var A: JsonArray; KeySig: Text; DefaultSig: Text)
    begin
        M(A, 'GetByte', StrSubstNo('GetByte(%1%2)', KeySig, DefaultSig), 'Byte');
        M(A, 'GetChar', StrSubstNo('GetChar(%1%2)', KeySig, DefaultSig), 'Char');
        M(A, 'GetOption', StrSubstNo('GetOption(%1%2)', KeySig, DefaultSig), 'Option');
    end;

    // Mirrors JsonMethodId — JsonObject (ids 2-18 + getters 101-116).
    local procedure JsonObjectMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Add', 'Add(Name, Value)', '');
        M(A, 'Contains', 'Contains(Name)', 'Boolean');
        M(A, 'Get', 'Get(Name, var Token: JsonToken)', 'Boolean');
        M(A, 'Remove', 'Remove(Name)', 'Boolean');
        M(A, 'Replace', 'Replace(Name, Token: JsonToken)', 'Boolean');
        M(A, 'WriteTo', 'WriteTo(var Target: Text)', 'Boolean');
        M(A, 'ReadFrom', 'ReadFrom(Json: Text)', 'Boolean');
        M(A, 'Keys', 'Keys()', 'List');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'AsToken', 'AsToken()', 'JsonToken');
        M(A, 'Clone', 'Clone()', 'JsonObject');
        AddJsonGetters(A, 'Name: Text');
        AddJsonOrdinalGetters(A, 'Name: Text', ' [, DefaultIfNotFound]');
        exit(A);
    end;

    // Mirrors JsonMethodId — JsonArray (ids 27-43 + getters 131-146).
    local procedure JsonArrayMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Add', 'Add(Value)', '');
        M(A, 'Get', 'Get(Index, var Token: JsonToken)', 'Boolean');
        M(A, 'Set', 'Set(Index, Token: JsonToken)', 'Boolean');
        M(A, 'Insert', 'Insert(Index, Token: JsonToken)', 'Boolean');
        M(A, 'RemoveAt', 'RemoveAt(Index)', 'Boolean');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'IndexOf', 'IndexOf(Token: JsonToken)', 'Integer');
        M(A, 'WriteTo', 'WriteTo(var Target: Text)', 'Boolean');
        M(A, 'ReadFrom', 'ReadFrom(Json: Text)', 'Boolean');
        M(A, 'AsToken', 'AsToken()', 'JsonToken');
        M(A, 'Clone', 'Clone()', 'JsonArray');
        AddJsonGetters(A, 'Index: Integer');
        AddJsonOrdinalGetters(A, 'Index: Integer', '');
        exit(A);
    end;

    // Mirrors JsonMethodId — JsonToken (ids 52-61).
    local procedure JsonTokenMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'ReadFrom', 'ReadFrom(Json: Text)', 'Boolean');
        M(A, 'WriteTo', 'WriteTo(var Target: Text)', 'Boolean');
        M(A, 'IsObject', 'IsObject()', 'Boolean');
        M(A, 'IsArray', 'IsArray()', 'Boolean');
        M(A, 'IsValue', 'IsValue()', 'Boolean');
        M(A, 'AsObject', 'AsObject()', 'JsonObject');
        M(A, 'AsArray', 'AsArray()', 'JsonArray');
        M(A, 'AsValue', 'AsValue()', 'JsonValue');
        M(A, 'Clone', 'Clone()', 'JsonToken');
        M(A, 'SelectToken', 'SelectToken(Path, var Token: JsonToken)', 'Boolean');
        exit(A);
    end;

    // Mirrors JsonMethodId — JsonValue (ids 77-96).
    local procedure JsonValueMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'SetValue', 'SetValue(Value)', '');
        M(A, 'AsText', 'AsText()', 'Text');
        M(A, 'AsCode', 'AsCode()', 'Code');
        M(A, 'AsInteger', 'AsInteger()', 'Integer');
        M(A, 'AsDecimal', 'AsDecimal()', 'Decimal');
        M(A, 'AsBoolean', 'AsBoolean()', 'Boolean');
        M(A, 'AsDate', 'AsDate()', 'Date');
        M(A, 'AsTime', 'AsTime()', 'Time');
        M(A, 'AsDateTime', 'AsDateTime()', 'DateTime');
        M(A, 'AsByte', 'AsByte()', 'Byte');
        M(A, 'AsChar', 'AsChar()', 'Char');
        M(A, 'AsOption', 'AsOption()', 'Option');
        M(A, 'IsNull', 'IsNull()', 'Boolean');
        M(A, 'AsToken', 'AsToken()', 'JsonToken');
        exit(A);
    end;

    // ===== Feature 3: Xml* method tables — MUST mirror "ALI Binder".XmlMethodId /
    // XmlStaticMethodId (XML_DESIGN.md §3). Statics (Create/ReadFrom/...) are listed on their
    // type so the editor completes them after the TYPE NAME receiver (§4). =====

    // Shared node-method rows (every node kind; the binder gates per-kind legality).
    local procedure XmlNodeCommon(var A: JsonArray)
    begin
        M(A, 'AddAfterSelf', 'AddAfterSelf(Content, ...)', '');
        M(A, 'AddBeforeSelf', 'AddBeforeSelf(Content, ...)', '');
        M(A, 'GetDocument', 'GetDocument(var Doc: XmlDocument)', 'Boolean');
        M(A, 'GetParent', 'GetParent(var Parent: XmlElement)', 'Boolean');
        M(A, 'Remove', 'Remove()', '');
        M(A, 'ReplaceWith', 'ReplaceWith(Content, ...)', '');
        M(A, 'SelectNodes', 'SelectNodes(XPath [, NsMgr], var List: XmlNodeList)', 'Boolean');
        M(A, 'SelectSingleNode', 'SelectSingleNode(XPath [, NsMgr], var Node: XmlNode)', 'Boolean');
        M(A, 'WriteTo', 'WriteTo([Options,] var Text | OutStream)', 'Boolean');
    end;

    // Container rows shared by XmlDocument and XmlElement.
    local procedure XmlContainerCommon(var A: JsonArray)
    begin
        M(A, 'Add', 'Add(Content, ...)', '');
        M(A, 'AddFirst', 'AddFirst(Content, ...)', '');
        M(A, 'GetChildElements', 'GetChildElements([LocalName [, NamespaceUri]])', 'XmlNodeList');
        M(A, 'GetChildNodes', 'GetChildNodes()', 'XmlNodeList');
        M(A, 'GetDescendantElements', 'GetDescendantElements([LocalName [, NamespaceUri]])', 'XmlNodeList');
        M(A, 'GetDescendantNodes', 'GetDescendantNodes()', 'XmlNodeList');
        M(A, 'RemoveNodes', 'RemoveNodes()', '');
        M(A, 'ReplaceNodes', 'ReplaceNodes(Content, ...)', '');
    end;

    local procedure XmlDocumentMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create([Content, ...]) [static]', 'XmlDocument');
        M(A, 'ReadFrom', 'ReadFrom(Text | InStream [, Options], var Doc: XmlDocument) [static]', 'Boolean');
        XmlContainerCommon(A);
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'GetDeclaration', 'GetDeclaration(var Decl: XmlDeclaration)', 'Boolean');
        M(A, 'GetDocumentType', 'GetDocumentType(var DocType: XmlDocumentType)', 'Boolean');
        M(A, 'GetRoot', 'GetRoot(var Root: XmlElement)', 'Boolean');
        M(A, 'NameTable', 'NameTable()', 'XmlNameTable');
        M(A, 'SetDeclaration', 'SetDeclaration(Decl: XmlDeclaration)', '');
        exit(A);
    end;

    local procedure XmlNodeMethods(): JsonArray
    var
        A: JsonArray;
    begin
        XmlNodeCommon(A);
        M(A, 'AsXmlAttribute', 'AsXmlAttribute()', 'XmlAttribute');
        M(A, 'AsXmlCData', 'AsXmlCData()', 'XmlCData');
        M(A, 'AsXmlComment', 'AsXmlComment()', 'XmlComment');
        M(A, 'AsXmlDeclaration', 'AsXmlDeclaration()', 'XmlDeclaration');
        M(A, 'AsXmlDocument', 'AsXmlDocument()', 'XmlDocument');
        M(A, 'AsXmlDocumentType', 'AsXmlDocumentType()', 'XmlDocumentType');
        M(A, 'AsXmlElement', 'AsXmlElement()', 'XmlElement');
        M(A, 'AsXmlProcessingInstruction', 'AsXmlProcessingInstruction()', 'XmlProcessingInstruction');
        M(A, 'AsXmlText', 'AsXmlText()', 'XmlText');
        M(A, 'IsXmlAttribute', 'IsXmlAttribute()', 'Boolean');
        M(A, 'IsXmlCData', 'IsXmlCData()', 'Boolean');
        M(A, 'IsXmlComment', 'IsXmlComment()', 'Boolean');
        M(A, 'IsXmlDeclaration', 'IsXmlDeclaration()', 'Boolean');
        M(A, 'IsXmlDocument', 'IsXmlDocument()', 'Boolean');
        M(A, 'IsXmlDocumentType', 'IsXmlDocumentType()', 'Boolean');
        M(A, 'IsXmlElement', 'IsXmlElement()', 'Boolean');
        M(A, 'IsXmlProcessingInstruction', 'IsXmlProcessingInstruction()', 'Boolean');
        M(A, 'IsXmlText', 'IsXmlText()', 'Boolean');
        exit(A);
    end;

    local procedure XmlElementMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(LocalName [, NamespaceUri] [, Content, ...]) [static]', 'XmlElement');
        XmlContainerCommon(A);
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'Attributes', 'Attributes()', 'XmlAttributeCollection');
        M(A, 'GetNamespaceOfPrefix', 'GetNamespaceOfPrefix(Prefix, var NamespaceUri: Text)', 'Boolean');
        M(A, 'GetPrefixOfNamespace', 'GetPrefixOfNamespace(NamespaceUri, var Prefix: Text)', 'Boolean');
        M(A, 'HasAttributes', 'HasAttributes()', 'Boolean');
        M(A, 'HasElements', 'HasElements()', 'Boolean');
        M(A, 'InnerText', 'InnerText()', 'Text');
        M(A, 'InnerXml', 'InnerXml()', 'Text');
        M(A, 'IsEmpty', 'IsEmpty()', 'Boolean');
        M(A, 'LocalName', 'LocalName()', 'Text');
        M(A, 'Name', 'Name()', 'Text');
        M(A, 'NamespaceUri', 'NamespaceUri()', 'Text');
        M(A, 'RemoveAllAttributes', 'RemoveAllAttributes()', '');
        M(A, 'RemoveAttribute', 'RemoveAttribute(LocalName [, NamespaceUri] | Attr: XmlAttribute)', '');
        M(A, 'SetAttribute', 'SetAttribute(Name [, NamespaceUri], Value)', '');
        exit(A);
    end;

    local procedure XmlAttributeMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(Name [, NamespaceUri], Value) [static]', 'XmlAttribute');
        M(A, 'CreateNamespaceDeclaration', 'CreateNamespaceDeclaration(Prefix, NamespaceUri) [static]', 'XmlAttribute');
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'IsNamespaceDeclaration', 'IsNamespaceDeclaration()', 'Boolean');
        M(A, 'LocalName', 'LocalName()', 'Text');
        M(A, 'Name', 'Name()', 'Text');
        M(A, 'NamespacePrefix', 'NamespacePrefix()', 'Text');
        M(A, 'NamespaceUri', 'NamespaceUri()', 'Text');
        M(A, 'Value', 'Value([NewValue: Text])', 'Text');
        exit(A);
    end;

    local procedure XmlNodeListMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'Get', 'Get(Index, var Node: XmlNode)', 'Boolean');
        exit(A);
    end;

    local procedure XmlAttrColMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'Get', 'Get(Index | LocalName [, NamespaceUri], var Attr: XmlAttribute)', 'Boolean');
        M(A, 'Remove', 'Remove(LocalName [, NamespaceUri] | Attr: XmlAttribute)', '');
        M(A, 'RemoveAll', 'RemoveAll()', '');
        M(A, 'Set', 'Set(Name [, NamespaceUri], Value)', '');
        exit(A);
    end;

    // XmlComment / XmlCData / XmlText — identical surface: static Create(Text) + node methods
    // + Value get/set. TypeName feeds the static Create's result type.
    local procedure XmlSimpleValueNodeMethods(TypeName: Text): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(Value: Text) [static]', TypeName);
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'Value', 'Value([NewValue: Text])', 'Text');
        exit(A);
    end;

    local procedure XmlProcessingInstrMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(Target, Data) [static]', 'XmlProcessingInstruction');
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'Target', 'Target()', 'Text');
        M(A, 'Value', 'Value([NewValue: Text])', 'Text');
        exit(A);
    end;

    local procedure XmlDeclarationMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(Version, Encoding, Standalone) [static]', 'XmlDeclaration');
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'Encoding', 'Encoding([NewValue: Text])', 'Text');
        M(A, 'Standalone', 'Standalone([NewValue: Text])', 'Text');
        M(A, 'Version', 'Version([NewValue: Text])', 'Text');
        exit(A);
    end;

    local procedure XmlDocumentTypeMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Create', 'Create(Name [, PublicId [, SystemId [, InternalSubset]]]) [static]', 'XmlDocumentType');
        XmlNodeCommon(A);
        M(A, 'AsXmlNode', 'AsXmlNode()', 'XmlNode');
        M(A, 'GetInternalSubset', 'GetInternalSubset(var Value: Text)', 'Boolean');
        M(A, 'GetName', 'GetName(var Value: Text)', 'Boolean');
        M(A, 'GetPublicId', 'GetPublicId(var Value: Text)', 'Boolean');
        M(A, 'GetSystemId', 'GetSystemId(var Value: Text)', 'Boolean');
        M(A, 'SetInternalSubset', 'SetInternalSubset(Value: Text)', '');
        M(A, 'SetName', 'SetName(Value: Text)', '');
        M(A, 'SetPublicId', 'SetPublicId(Value: Text)', '');
        M(A, 'SetSystemId', 'SetSystemId(Value: Text)', '');
        exit(A);
    end;

    local procedure XmlNamespaceManagerMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'AddNamespace', 'AddNamespace(Prefix, NamespaceUri)', '');
        M(A, 'HasNamespace', 'HasNamespace(Prefix)', 'Boolean');
        M(A, 'LookupNamespace', 'LookupNamespace(Prefix, var NamespaceUri: Text)', 'Boolean');
        M(A, 'LookupPrefix', 'LookupPrefix(NamespaceUri, var Prefix: Text)', 'Boolean');
        M(A, 'NameTable', 'NameTable([NewValue: XmlNameTable])', 'XmlNameTable');
        M(A, 'PopScope', 'PopScope()', 'Boolean');
        M(A, 'PushScope', 'PushScope()', '');
        M(A, 'RemoveNamespace', 'RemoveNamespace(Prefix, NamespaceUri)', 'Boolean');
        exit(A);
    end;

    // XmlReadOptions / XmlWriteOptions share the single PreserveWhitespace property.
    local procedure XmlOptionsMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'PreserveWhitespace', 'PreserveWhitespace([NewValue: Boolean])', 'Boolean');
        exit(A);
    end;

    // Mirrors BindRecordIdMethod.
    // Mirrors "ALI Binder".RecordRefMethodId (the RecordRef-only surface) PLUS the routed set it
    // shares with a Record receiver — from the editor's point of view they are one member list,
    // which is exactly the point of the routing. The field-NUMBER methods (SetRange/SetFilter/
    // CalcFields/SetLoadFields/...) used to be deliberately absent because they raised ALI989 on a
    // RecordRef; phase P4 implemented them, so they are listed now — with FIELD-NUMBER signatures,
    // not the Record path's field-name ones, since that is the only form that compiles here.
    local procedure RecordRefMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Open', 'Open(TableIdOrName [, Temporary] [, CompanyName])', '');
        M(A, 'Close', 'Close()', '');
        M(A, 'Number', 'Number()', 'Integer');
        M(A, 'Name', 'Name()', 'Text');
        M(A, 'Caption', 'Caption()', 'Text');
        M(A, 'GetTable', 'GetTable(Record)', '');
        M(A, 'SetTable', 'SetTable(Record [, IncludeFilters])', '');
        M(A, 'Duplicate', 'Duplicate()', 'RecordRef');
        M(A, 'FieldExist', 'FieldExist(FieldNoOrName)', 'Boolean');
        M(A, 'SystemIdNo', 'SystemIdNo()', 'Integer');
        M(A, 'SystemCreatedAtNo', 'SystemCreatedAtNo()', 'Integer');
        M(A, 'SystemCreatedByNo', 'SystemCreatedByNo()', 'Integer');
        M(A, 'SystemModifiedAtNo', 'SystemModifiedAtNo()', 'Integer');
        M(A, 'SystemModifiedByNo', 'SystemModifiedByNo()', 'Integer');
        // routed to the Record implementation (same REC_* opcodes)
        M(A, 'Init', 'Init()', '');
        M(A, 'Reset', 'Reset()', '');
        M(A, 'Insert', 'Insert([RunTrigger])', 'Boolean');
        M(A, 'Modify', 'Modify([RunTrigger])', 'Boolean');
        M(A, 'Delete', 'Delete([RunTrigger])', 'Boolean');
        M(A, 'DeleteAll', 'DeleteAll([RunTrigger])', 'Boolean');
        M(A, 'Get', 'Get(keyValue, ...)', 'Boolean');
        M(A, 'Find', 'Find([Which])', 'Boolean');
        M(A, 'FindSet', 'FindSet([ForUpdate])', 'Boolean');
        M(A, 'FindFirst', 'FindFirst()', 'Boolean');
        M(A, 'FindLast', 'FindLast()', 'Boolean');
        M(A, 'Next', 'Next([Steps])', 'Integer');
        M(A, 'Count', 'Count()', 'Integer');
        M(A, 'CountApprox', 'CountApprox()', 'Integer');
        M(A, 'IsEmpty', 'IsEmpty()', 'Boolean');
        M(A, 'IsTemporary', 'IsTemporary()', 'Boolean');
        M(A, 'Copy', 'Copy(Record [, IncludeFilters])', '');
        M(A, 'SetRecFilter', 'SetRecFilter()', '');
        M(A, 'GetFilters', 'GetFilters()', 'Text');
        M(A, 'HasFilter', 'HasFilter()', 'Boolean');
        M(A, 'GetView', 'GetView([IncludeSortOrder])', 'Text');
        M(A, 'SetView', 'SetView(View)', '');
        M(A, 'GetPosition', 'GetPosition([Detailed])', 'Text');
        M(A, 'SetPosition', 'SetPosition(Position)', '');
        M(A, 'FieldCount', 'FieldCount()', 'Integer');
        M(A, 'KeyCount', 'KeyCount()', 'Integer');
        M(A, 'CurrentKey', 'CurrentKey()', 'Text');
        M(A, 'CurrentKeyIndex', 'CurrentKeyIndex([Index])', 'Integer');
        M(A, 'RecordId', 'RecordId()', 'RecordId');
        M(A, 'GetBySystemId', 'GetBySystemId(SystemId)', 'Boolean');
        M(A, 'FullyQualifiedName', 'FullyQualifiedName()', 'Text');
        M(A, 'ChangeCompany', 'ChangeCompany([Company])', '');
        M(A, 'CurrentCompany', 'CurrentCompany()', 'Text');
        M(A, 'LockTable', 'LockTable([Wait])', '');
        M(A, 'Mark', 'Mark([Value])', 'Boolean');
        M(A, 'ClearMarks', 'ClearMarks()', '');
        M(A, 'MarkedOnly', 'MarkedOnly([Value])', 'Boolean');
        // P2/P3 — the three constructors of the packed-pair handles.
        M(A, 'Field', 'Field(FieldNoOrName)', 'FieldRef');
        M(A, 'FieldIndex', 'FieldIndex(Index)', 'FieldRef');
        M(A, 'KeyIndex', 'KeyIndex(Index)', 'KeyRef');
        // P4 — field numbers as run-time Integers. Values are Variants (no bind-time field type),
        // which is why GetRangeMin/GetRangeMax advertise Variant and not the field's own type.
        M(A, 'SetRange', 'SetRange(FieldNo [, Value [, ToValue]])', '');
        M(A, 'SetFilter', 'SetFilter(FieldNo, Filter [, Value, ...])', '');
        M(A, 'GetFilter', 'GetFilter(FieldNo)', 'Text');
        M(A, 'CopyFilter', 'CopyFilter(FromFieldNo, ToFieldNo)', '');
        M(A, 'GetRangeMin', 'GetRangeMin(FieldNo)', 'Variant');
        M(A, 'GetRangeMax', 'GetRangeMax(FieldNo)', 'Variant');
        M(A, 'Validate', 'Validate(FieldNo, Value)', '');
        M(A, 'ModifyAll', 'ModifyAll(FieldNo, Value [, RunTrigger])', 'Boolean');
        M(A, 'CalcFields', 'CalcFields(FieldNo, ...)', '');
        M(A, 'CalcSums', 'CalcSums(FieldNo, ...)', '');
        M(A, 'TestField', 'TestField(FieldNo [, Value])', '');
        M(A, 'FieldError', 'FieldError(FieldNo [, Message])', '');
        M(A, 'FieldName', 'FieldName(FieldNo)', 'Text');
        M(A, 'FieldCaption', 'FieldCaption(FieldNo)', 'Text');
        M(A, 'SetAscending', 'SetAscending(FieldNo, Value)', '');
        M(A, 'GetAscending', 'GetAscending(FieldNo)', 'Boolean');
        M(A, 'SetCurrentKey', 'SetCurrentKey(FieldNo, ...)', '');
        M(A, 'SetAutoCalcFields', 'SetAutoCalcFields([FieldNo, ...])', 'Boolean');
        M(A, 'SetLoadFields', 'SetLoadFields([FieldNo, ...])', 'Boolean');
        M(A, 'AddLoadFields', 'AddLoadFields(FieldNo, ...)', 'Boolean');
        M(A, 'LoadFields', 'LoadFields(FieldNo, ...)', 'Boolean');
        M(A, 'AreFieldsLoaded', 'AreFieldsLoaded(FieldNo, ...)', 'Boolean');
        exit(A);
    end;

    // Mirrors "ALI Binder".FieldRefMethodId. The whole documented surface, with no deferrals: a
    // FieldRef needs no field-number encoding at all, because it carries its own number inside the
    // handle. Since P4 the RecordRef list above is complete too, by an independent route.
    local procedure FieldRefMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Value', 'Value() — or `F.Value := x` / `F.Value(x)` to set', 'Variant');
        M(A, 'Validate', 'Validate([Value])', '');
        M(A, 'SetRange', 'SetRange([From [, To]])', '');
        M(A, 'SetFilter', 'SetFilter(Filter [, Value, ...])', '');
        M(A, 'GetFilter', 'GetFilter()', 'Text');
        M(A, 'GetRangeMin', 'GetRangeMin()', 'Variant');
        M(A, 'GetRangeMax', 'GetRangeMax()', 'Variant');
        M(A, 'CalcField', 'CalcField()', '');
        M(A, 'CalcSum', 'CalcSum()', '');
        M(A, 'TestField', 'TestField([Value])', '');
        M(A, 'FieldError', 'FieldError([Text])', '');
        M(A, 'Name', 'Name()', 'Text');
        M(A, 'Number', 'Number()', 'Integer');
        M(A, 'Caption', 'Caption()', 'Text');
        M(A, 'Length', 'Length()', 'Integer');
        M(A, 'Class', 'Class()', 'FieldClass');
        M(A, 'Type', 'Type()', 'FieldType');
        M(A, 'Active', 'Active()', 'Boolean');
        M(A, 'Relation', 'Relation()', 'Integer');
        M(A, 'OptionCaption', 'OptionCaption()', 'Text');
        M(A, 'OptionMembers', 'OptionMembers()', 'Text');
        M(A, 'IsEnum', 'IsEnum()', 'Boolean');
        M(A, 'EnumValueCount', 'EnumValueCount()', 'Integer');
        M(A, 'GetEnumValueName', 'GetEnumValueName(Index)', 'Text');
        M(A, 'GetEnumValueCaption', 'GetEnumValueCaption(Index)', 'Text');
        M(A, 'GetEnumValueOrdinal', 'GetEnumValueOrdinal(Index)', 'Integer');
        M(A, 'GetEnumValueNameFromOrdinalValue', 'GetEnumValueNameFromOrdinalValue(Ordinal)', 'Text');
        M(A, 'GetEnumValueCaptionFromOrdinalValue', 'GetEnumValueCaptionFromOrdinalValue(Ordinal)', 'Text');
        M(A, 'IsOptimizedForTextSearch', 'IsOptimizedForTextSearch()', 'Boolean');
        M(A, 'Record', 'Record()', 'RecordRef');
        exit(A);
    end;

    // Mirrors "ALI Binder".KeyRefMethodId — four methods, the whole type.
    local procedure KeyRefMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Active', 'Active()', 'Boolean');
        M(A, 'FieldCount', 'FieldCount()', 'Integer');
        M(A, 'FieldIndex', 'FieldIndex(Index)', 'FieldRef');
        M(A, 'Record', 'Record()', 'RecordRef');
        exit(A);
    end;

    local procedure RecordIdMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'TableNo', 'TableNo()', 'Integer');
        M(A, 'GetRecord', 'GetRecord() — only as RecVar := id.GetRecord();', 'Record');
        exit(A);
    end;

    // Mirrors PopulateTextMethods (receiver counts as param 1 — method form shown here).
    local procedure TextMethods(): JsonArray
    var
        A: JsonArray;
    begin
        M(A, 'Contains', 'Contains(Value: Text)', 'Boolean');
        M(A, 'EndsWith', 'EndsWith(Value: Text)', 'Boolean');
        M(A, 'StartsWith', 'StartsWith(Value: Text)', 'Boolean');
        M(A, 'IndexOf', 'IndexOf(Value [, StartIndex])', 'Integer');
        M(A, 'IndexOfAny', 'IndexOfAny(Values [, StartIndex])', 'Integer');
        M(A, 'LastIndexOf', 'LastIndexOf(Value [, StartIndex])', 'Integer');
        M(A, 'PadLeft', 'PadLeft(Count [, PadChar])', 'Text');
        M(A, 'PadRight', 'PadRight(Count [, PadChar])', 'Text');
        M(A, 'Remove', 'Remove(StartIndex [, Count])', 'Text');
        M(A, 'Replace', 'Replace(Old, New)', 'Text');
        M(A, 'Split', 'Split(Separator1 [, Separator2])', 'List');
        M(A, 'Substring', 'Substring(StartIndex [, Length])', 'Text');
        M(A, 'ToLower', 'ToLower()', 'Text');
        M(A, 'ToUpper', 'ToUpper()', 'Text');
        M(A, 'Trim', 'Trim()', 'Text');
        M(A, 'TrimStart', 'TrimStart([Chars])', 'Text');
        M(A, 'TrimEnd', 'TrimEnd([Chars])', 'Text');
        exit(A);
    end;

    // Mirrors PopulateVariantMethods (all 0-arg Boolean predicates).
    local procedure VariantMethods(): JsonArray
    var
        A: JsonArray;
        Names: List of [Text];
        Name: Text;
    begin
        Names.Add('IsInteger');
        Names.Add('IsBigInteger');
        Names.Add('IsDecimal');
        Names.Add('IsBoolean');
        Names.Add('IsText');
        Names.Add('IsCode');
        Names.Add('IsChar');
        Names.Add('IsByte');
        Names.Add('IsDate');
        Names.Add('IsTime');
        Names.Add('IsDateTime');
        Names.Add('IsDuration');
        Names.Add('IsGuid');
        Names.Add('IsOption');
        Names.Add('IsDateFormula');
        Names.Add('IsRecordId');
        Names.Add('IsRecord');
        Names.Add('IsList');
        Names.Add('IsDictionary');
        Names.Add('IsArray');
        foreach Name in Names do
            M(A, Name, Name + '()', 'Boolean');
        exit(A);
    end;

    // ===== Table metadata for the editor: table-name completion + per-table field lists =====

    // ===== Name lists for "did you mean" (binder error path only, see "ALI Diag Bag".DidYouMean) =====

    // Method names of a receiver type, as keyed in BuildMethodsObject ('Record', 'List', ...).
    procedure MethodNames(TypeName: Text): List of [Text]
    var
        Methods: JsonObject;
        Tok: JsonToken;
        Row: JsonToken;
        Names: List of [Text];
    begin
        Methods := BuildMethodsObject();
        if Methods.Get(TypeName, Tok) then
            foreach Row in Tok.AsArray() do
                AddUnique(Names, Row.AsObject().GetText('n'));
        exit(Names);
    end;

    procedure BuiltinNames(): List of [Text]
    var
        BId: Integer;
        Names: List of [Text];
    begin
        Builtins.EnsureBuilt();
        for BId := 1 to Builtins.Count() do
            if (Builtins.GetDomain(BId) <> "ALI Builtin Domain"::Native) and not Builtins.IsUnimplemented(BId) then
                AddUnique(Names, Builtins.GetName(BId));
        exit(Names);
    end;

    procedure FieldNames(TableId: Integer): List of [Text]
    var
        Fld: Record Field;
        Names: List of [Text];
    begin
        Fld.SetRange(TableNo, TableId);
        Fld.SetFilter(ObsoleteState, '<>%1', Fld.ObsoleteState::Removed);
        Fld.SetLoadFields(FieldName);
        if Fld.FindSet() then
            repeat
                Names.Add(Fld.FieldName);
            until Fld.Next() = 0;
        exit(Names);
    end;

    procedure TableNames(): List of [Text]
    var
        TableMeta: Record "Table Metadata";
        Names: List of [Text];
    begin
        TableMeta.SetLoadFields(Name);
        if TableMeta.FindSet() then
            repeat
                Names.Add(TableMeta.Name);
            until TableMeta.Next() = 0;
        exit(Names);
    end;

    procedure CodeunitNames(): List of [Text]
    var
        CodeunitMeta: Record "CodeUnit Metadata";
        Names: List of [Text];
    begin
        CodeunitMeta.SetLoadFields(Name);
        if CodeunitMeta.FindSet() then
            repeat
                Names.Add(CodeunitMeta.Name);
            until CodeunitMeta.Next() = 0;
        exit(Names);
    end;

    local procedure AddUnique(var Names: List of [Text]; Name: Text)
    begin
        if not Names.Contains(Name) then
            Names.Add(Name);
    end;

    // All table names: [{n: Name, id: ID}, ...] — pushed once at editor startup for the
    // `MyRec: Record <completion>` case (filtering happens client-side, no round-trips).
    procedure BuildTableListJson(): Text
    var
        TableMeta: Record "Table Metadata";
        Arr: JsonArray;
        Row: JsonObject;
        JsonText: Text;
    begin
        TableMeta.SetLoadFields(ID, Name);
        if TableMeta.FindSet() then
            repeat
                Clear(Row);
                Row.Add('n', TableMeta.Name);
                Row.Add('id', TableMeta.ID);
                Arr.Add(Row);
            until TableMeta.Next() = 0;
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // All codeunit names: [{n: Name, id: ID}, ...] — pushed once at editor startup for the
    // `MyCU: Codeunit <completion>` case, same client-side filtering as the table list.
    procedure BuildCodeunitListJson(): Text
    var
        CodeunitMeta: Record "CodeUnit Metadata";
        Arr: JsonArray;
        Row: JsonObject;
        JsonText: Text;
    begin
        CodeunitMeta.SetLoadFields(ID, Name);
        if CodeunitMeta.FindSet() then
            repeat
                Clear(Row);
                Row.Add('n', CodeunitMeta.Name);
                Row.Add('id', CodeunitMeta.ID);
                Arr.Add(Row);
            until CodeunitMeta.Next() = 0;
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // All enum names: [{n: Name, id: ID}, ...] — `MyEnum: Enum <completion>`. No "Enum Metadata"
    // table exists, so AllObjWithCaption. Enum names may exceed its Text[30] "Object Name" (enum
    // 11512 "Swiss QR-Bill Payment Reference Type"); a full-length row is then taken from the
    // caption when it extends the name — true for an enum without its own Caption. Otherwise the
    // truncated name is offered, which the binder still resolves (prefix match).
    procedure BuildEnumListJson(): Text
    var
        AllObj: Record AllObjWithCaption;
        Arr: JsonArray;
        Row: JsonObject;
        JsonText: Text;
        EnumName: Text;
    begin
        AllObj.SetRange("Object Type", AllObj."Object Type"::Enum);
        AllObj.SetLoadFields("Object ID", "Object Name", "Object Caption");
        if AllObj.FindSet() then
            repeat
                EnumName := AllObj."Object Name";
                if StrLen(EnumName) = MaxStrLen(AllObj."Object Name") then
                    if AllObj."Object Caption".StartsWith(EnumName) then
                        EnumName := AllObj."Object Caption";
                Clear(Row);
                Row.Add('n', EnumName);
                Row.Add('id', AllObj."Object ID");
                Arr.Add(Row);
            until AllObj.Next() = 0;
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // Answer to the addin's RequestObjectMembers event: the members completion/hover needs for
    // one object. 'Table' → fields (+ procedures), 'Codeunit' → procedures only.
    procedure BuildObjectMembersJson(ObjectType: Text; ObjectName: Text; WithProcedures: Boolean): Text
    begin
        if ObjectType = 'Codeunit' then
            exit(BuildCodeunitProcsJson(ObjectName));
        exit(BuildTableFieldsJson(ObjectName, WithProcedures));
    end;

    // Procedures of one codeunit (by name, case-insensitive): [{n, s, r, k:'p'}, ...].
    // procedures are ALL a codeunit variable has, so gating would leave `MyCU.` with a permanently empty dropdown.
    // The list is what the object offers; the compiler still refuses the call when calls are off.
    local procedure BuildCodeunitProcsJson(CodeunitName: Text): Text
    var
        CodeunitMeta: Record "CodeUnit Metadata";
        Arr: JsonArray;
        JsonText: Text;
    begin
        CodeunitMeta.SetLoadFields(ID, Name);
        CodeunitMeta.SetRange(Name, CodeunitName);
        if CodeunitMeta.FindFirst() then begin
            // Catalogued native methods ("Data Compression".AddEntry, …) come from the binder's
            // own NativeFirst map, so they need no stored source and are offered on every target.
            // On cloud this is the ONLY source of rows — the harvest below is compiled out —
            // which is exactly why a native codeunit's dropdown was empty there.
            AddNativeMethods(Arr, CodeunitMeta.ID);
#if not CLOUD
            AddObjectProcedures(Arr, 'Codeunit', CodeunitMeta.ID);
#endif
        end;
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // One completion row per catalogued native method of CodeunitId, with every overload's
    // signature. A native method is a platform call the binder resolves through
    // "ALI Builtin Registry".ResolveNative — never harvested from source — so these rows are
    // the same on cloud and on prem, and they are what DataComp. must offer.
    local procedure AddNativeMethods(var Arr: JsonArray; CodeunitId: Integer)
    var
        BId: Integer;
        Row: JsonObject;
    begin
        foreach BId in Builtins.NativeMethodsOf(CodeunitId) do
            // A row the binder recognizes but rejects (GetEnvironmentSetting on cloud) is left
            // out: member rows carry no 'ok' flag the way builtins do, so the only honest way to
            // keep the dropdown and the compiler in agreement is to not offer it at all.
            if not Builtins.IsUnimplemented(BId) then begin
                Clear(Row);
                Row.Add('n', Builtins.GetName(BId));
                Row.Add('s', NativeSignature(BId));
                Row.Add('r', NativeReturnText(BId));
                Row.Add('k', 'p');
                Arr.Add(Row);
            end;
    end;

    // "AddEntry(InStream, Text)" — the first overload's display signature, with " | +N overloads"
    // appended when the method has more. The receiver slot ('Self', the variable written before
    // the dot) is never shown: the user has already typed it.
    local procedure NativeSignature(BId: Integer): Text
    var
        Extra: Integer;
        i: Integer;
        Next: Integer;
        First: Boolean;
        Sb: TextBuilder;
    begin
        Sb.Append(Builtins.GetName(BId));
        Sb.Append('(');
        First := true;
        for i := 1 to Builtins.GetMaxArity(BId) do
            if not IsSelfParam(BId, i) then begin
                if not First then
                    Sb.Append(', ');
                if Builtins.IsVarParam(BId, i) then
                    Sb.Append('var ');
                Sb.Append(TypeRules.TypeName(Builtins.ParamType(BId, i)));
                First := false;
            end;
        Sb.Append(')');
        Next := Builtins.NextOverload(BId);
        while Next <> 0 do begin
            Extra += 1;
            Next := Builtins.NextOverload(Next);
        end;
        if Extra > 0 then
            Sb.Append(StrSubstNo(' | +%1 overload(s)', Extra));
        exit(Sb.ToText());
    end;

    // A stateful native's first parameter is the receiver instance itself (registered as 'Self'),
    // which the user typed before the dot — showing it would misstate the call's arity.
    local procedure IsSelfParam(BId: Integer; Idx: Integer): Boolean
    begin
        exit((Idx = 1) and (Builtins.ParamType(BId, 1) = "ALI TypeKind"::NativeCodeunit.AsInteger()));
    end;

    // Void reads as no return, matching the harvested rows' ReturnText.
    local procedure NativeReturnText(BId: Integer): Text
    begin
        if Builtins.GetResultType(BId) = "ALI TypeKind"::None.AsInteger() then
            exit('');
        exit(TypeRules.TypeName(Builtins.GetResultType(BId)));
    end;

    // Fields of one table (by name, case-insensitive): [{n, t, len, pk[, o]}, ...] — served on
    // demand via the addin's RequestObjectMembers event (per-object cache lives in JS).
    // '[]' when the table name is unknown.
    // WithProcedures appends the table's own AL procedures as extra rows [{n, s, r, k:'p'}]
    // on the SAME array — one round-trip feeds both `Rec.<field>` and `Rec.<procedure>`.
    procedure BuildTableFieldsJson(TableName: Text; WithProcedures: Boolean): Text
    var
        FieldRec: Record Field;
        TableMeta: Record "Table Metadata";
        RRef: RecordRef;
        Arr: JsonArray;
        Row: JsonObject;
        JsonText: Text;
    begin
        TableMeta.SetLoadFields(ID, Name);
        TableMeta.SetRange(Name, TableName);
        if not TableMeta.FindFirst() then begin
            Arr.WriteTo(JsonText);
            exit(JsonText);
        end;
        FieldRec.SetRange(TableNo, TableMeta.ID);
        FieldRec.SetRange(Enabled, true);
        FieldRec.SetRange(Class, FieldRec.Class::Normal, FieldRec.Class::FlowField);
        if FieldRec.FindSet() then
            repeat
                Clear(Row);
                Row.Add('n', FieldRec.FieldName);
                Row.Add('t', Format(FieldRec.Type));
                Row.Add('len', FieldRec.Len);
                Row.Add('pk', FieldRec.IsPartOfPrimaryKey);
                if FieldRec.Type = FieldRec.Type::Option then     // Enum fields report Option too
                    Row.Add('o', OptionMembersJson(RRef, TableMeta.ID, FieldRec."No."));
                Arr.Add(Row);
            until FieldRec.Next() = 0;
#if not CLOUD
        if WithProcedures then
            AddObjectProcedures(Arr, 'Table', TableMeta.ID);
#endif
        Arr.WriteTo(JsonText);
        exit(JsonText);
    end;

    // `Rec.Field::` completion rows [{n, v}] — name + real ordinal (enum ordinals can be sparse).
    // Same FieldRef source the compiler binds against ("ALI Option Meta".BuildFromField), so
    // enumextension values are included. The RecordRef is opened once per table, on first use.
    local procedure OptionMembersJson(var RRef: RecordRef; TableId: Integer; FieldNo: Integer) Members: JsonArray
    var
        FRef: FieldRef;
        i: Integer;
        Member: JsonObject;
    begin
        if RRef.Number() = 0 then
            RRef.Open(TableId, true);
        FRef := RRef.Field(FieldNo);
        for i := 1 to FRef.EnumValueCount() do
            if FRef.GetEnumValueName(i) <> '' then begin
                Clear(Member);
                Member.Add('n', FRef.GetEnumValueName(i));
                Member.Add('v', FRef.GetEnumValueOrdinal(i));
                Members.Add(Member);
            end;
    end;

    // Everything from here to ReturnText() serves the completion list with an object's OWN AL
    // procedures, read from its stored source. A cloud build cannot reach that source at all
    // ("ALI Object Registry".TryGetObjectSource), and the dropdown must offer exactly what the
    // compiler resolves — nothing — so the whole region is excluded there rather than left as
    // unreachable code.
#if not CLOUD
    // The object's own AL procedures, read from its stored source — the same source
    // "ALI Object Registry" harvests to compile a `Rec.MyProcedure()` / `MyCU.MyProcedure()`
    // call. Only requested when the script has "Allow Object Calls" on, so the metadata read is
    // paid for only where the call would actually bind.
    local procedure AddObjectProcedures(var Arr: JsonArray; ObjectType: Text; ObjectId: Integer)
    var
        Registry: Codeunit "ALI Object Registry";
        ExtId: Integer;
    begin
        AddOneObjectsProcedures(Arr, ObjectType, ObjectId, false);
        // A TABLE's callable procedures are mostly NOT on the table: on a standard table its own
        // AL source is empty and everything a script can call was added by a tableextension. The
        // compiler resolves those (see "ALI Object Registry".TryBindObjectProc), so the dropdown
        // has to offer them or the two disagree about what exists.
        if ObjectType = 'Codeunit' then
            exit;
        foreach ExtId in Registry.ExtensionsOfTable(ObjectId) do
            AddOneObjectsProcedures(Arr, ObjectType, ExtId, true);
    end;

    // One object's procedures. IsExtension picks the TableExtension metadata row rather than the
    // Table one; the rows it produces are otherwise identical, because to the caller of
    // `Rec.Foo()` it makes no difference which object declared Foo.
    local procedure AddOneObjectsProcedures(var Arr: JsonArray; ObjectType: Text; ObjectId: Integer; IsExtension: Boolean)
    var
        AppObj: Record "Application Object Metadata";
        MetaPage: Page "ALI App. Obj. Metadata";
        i: Integer;
        Row: JsonObject;
        ProcedureReturnType: List of [Enum "ALI Fields Types"];
        ProcedureArguments: List of [List of [Enum "ALI Fields Types"]];
        ProcedureNames: List of [Text];
        ProcName: Text;
    begin
        if ObjectType = 'Codeunit' then
            AppObj.SetRange("Object Type", AppObj."Object Type"::Codeunit)
        else
            if IsExtension then
                AppObj.SetRange("Object Type", AppObj."Object Type"::"TableExtension")
            else
                AppObj.SetRange("Object Type", AppObj."Object Type"::Table);
        AppObj.SetRange("Object ID", ObjectId);
        if not AppObj.FindFirst() then
            exit;
        MetaPage.GetALProcedureDefinition(AppObj, ProcedureNames, ProcedureArguments, ProcedureReturnType);
        for i := 1 to ProcedureNames.Count() do begin
            ProcName := ProcedureNames.Get(i);
            // GetALProcedureDefinition reports triggers and procedures alike; every AL trigger
            // name starts with "On", which is cheaper than parsing the declaration again.
            if not ProcName.StartsWith('On') then begin
                Clear(Row);
                Row.Add('n', ProcName);
                Row.Add('s', ProcSignature(ProcName, ProcedureArguments.Get(i)));
                // Void and "not a field type" (Record, Variant, …) are indistinguishable here,
                // so an unknown return shows nothing rather than a wrong type.
                Row.Add('r', ReturnText(ProcedureReturnType.Get(i)));
                Row.Add('k', 'p');
                Arr.Add(Row);
            end;
        end;
    end;

    // "Post(Integer, Text)" — display signature for the completion list.
    local procedure ProcSignature(Name: Text; Args: List of [Enum "ALI Fields Types"]): Text
    var
        First: Boolean;
        ArgType: Enum "ALI Fields Types";
        Sb: TextBuilder;
    begin
        Sb.Append(Name);
        Sb.Append('(');
        First := true;
        foreach ArgType in Args do begin
            if not First then
                Sb.Append(', ');
            Sb.Append(TypeText(ArgType));
            First := false;
        end;
        Sb.Append(')');
        exit(Sb.ToText());
    end;

    // " " (0) is what GetALProcedureDefinition reports for anything outside the BC FIELD type
    // set (Record, Variant, List, Json*, streams…) and for a void return — shown as '?'.
    local procedure TypeText(FieldType: Enum "ALI Fields Types"): Text
    begin
        if FieldType = FieldType::" " then
            exit('?');
        exit(Format(FieldType));
    end;

    local procedure ReturnText(FieldType: Enum "ALI Fields Types"): Text
    begin
        if FieldType = FieldType::" " then
            exit('');
        exit(Format(FieldType));
    end;
#endif
}
