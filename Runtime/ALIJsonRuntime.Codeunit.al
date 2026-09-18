// ALI Json Runtime — JsonObject/JsonArray/JsonToken/JsonValue RefShim execution (Feature 2).
//
// A Json* VALUE is an Int handle (RegClassInt) — same scheme as Http*/List/Dictionary (M10,
// see "ALI Http Runtime" header). UNLIKE Http*, all 4 kinds share ONE bank: `List of
// [JsonToken]`, not one box-codeunit bank per kind. Reason: every AL Json* type
// (JsonObject/JsonArray/JsonValue) is a reference-type wrapper over a JsonToken DOM node —
// JsonToken itself IS a valid `List of [T]` element type (unlike HttpClient/
// HttpRequestMessage/..., which are not, forcing the box-codeunit indirection in "ALI Http
// Runtime"). A List.Get() on JsonToken returns a token that shares the underlying DOM with
// whatever wrote it, so mutations through one alias are visible through another, matching
// native reference semantics — no RecordRef-style bound-state loss applies here (that failure
// mode is specific to RecordRef's cursor state, not to Json's DOM references).
//
// Storage convention: every handle's slot holds a JsonToken (AsToken() at allocation time).
// Per-kind accessors (GetObj/GetArr/GetVal) narrow it back via AsObject()/AsArray()/AsValue(),
// which Error natively on a kind mismatch (acceptable — mirrors native AL runtime-error
// behavior, no extra guard needed). After a rebinding operation (ReadFrom/SetValue, which can
// replace what the local JsonObject/JsonArray/JsonValue variable points at rather than mutate
// in place), callers write the narrowed value back into the bank with SetTok() as
// belt-and-suspenders — mirrors "ALI Http Runtime"'s Box.SetVal() write-back after methods
// that might reassign rather than mutate.
codeunit 51081 "ALI Json Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        ListRt: Codeunit "ALI List Runtime";
        FreeIdx: List of [Integer];
        TokBank: List of [JsonToken];

    procedure Reset()
    begin
        Clear(TokBank);
        Clear(FreeIdx);
    end;

    // Allocate (or reuse) a fresh Json handle wrapping the given token — mirrors "ALI
    // TextBuilder Runtime".NewTb / "ALI Http Runtime".NewClient. "New" ids are never
    // user-callable — emitted at declaration/handle-returning-method-result time by the
    // lowerer/interpreter (mirrors LIST_NEW/DICT_NEW/HTTP_METHOD New ids).
    procedure NewHandle(Tok: JsonToken): Integer
    var
        H: Integer;
    begin
        if FreeIdx.Count() > 0 then begin
            H := FreeIdx.Get(FreeIdx.Count());
            FreeIdx.RemoveAt(FreeIdx.Count());
            TokBank.Set(H, Tok);
            exit(H);
        end;
        TokBank.Add(Tok);
        exit(TokBank.Count());
    end;

    // Reclaim a Json handle — clears the slot in place (List.Get then mutate-local would only
    // rebind the LOCAL reference, not the shared bank instance) and recycles the index.
    procedure Free(H: Integer)
    var
        Blank: JsonToken;
    begin
        if (H < 1) or (H > TokBank.Count()) then
            exit;
        TokBank.Set(H, Blank);
        FreeIdx.Add(H);
    end;

    procedure GetTok(H: Integer): JsonToken
    var
        Tok: JsonToken;
    begin
        if (H < 1) or (H > TokBank.Count()) then
            Error('ALI972: Json handle %1 out of range', H);
        TokBank.Get(H, Tok);
        exit(Tok);
    end;

    procedure SetTok(H: Integer; Tok: JsonToken)
    begin
        if (H < 1) or (H > TokBank.Count()) then
            Error('ALI972: Json handle %1 out of range', H);
        TokBank.Set(H, Tok);
    end;

    procedure GetObj(H: Integer; var JO: JsonObject)
    begin
        JO := GetTok(H).AsObject();
    end;

    procedure GetArr(H: Integer; var JA: JsonArray)
    begin
        JA := GetTok(H).AsArray();
    end;

    procedure GetVal(H: Integer; var JV: JsonValue)
    begin
        JV := GetTok(H).AsValue();
    end;

    // ===== "New" allocators (compiler-emitted at declaration; mirror "ALI Http Runtime".
    // NewClient/... — one per kind, since the fresh empty native value differs per kind). =====

    procedure NewObject(): Integer
    var
        JO: JsonObject;
    begin
        exit(NewHandle(JO.AsToken()));
    end;

    procedure NewArray(): Integer
    var
        JA: JsonArray;
    begin
        exit(NewHandle(JA.AsToken()));
    end;

    procedure NewTokenH(): Integer
    var
        Tok: JsonToken;
    begin
        exit(NewHandle(Tok));
    end;

    procedure NewValue(): Integer
    var
        JV: JsonValue;
    begin
        exit(NewHandle(JV.AsToken()));
    end;

    // Clear(var J) support (CLEAR_TARGET): reset the handle's slot IN PLACE to a fresh empty
    // value of the variable's STATIC kind (TypeOrd 97-100) — the variable becomes a new empty
    // JsonObject/JsonArray/JsonToken/JsonValue, matching native Clear; other aliases keep the
    // old DOM (reference semantics — native Clear rebinds the cleared variable only).
    procedure ClearJson(H: Integer; TypeOrd: Integer)
    var
        JA: JsonArray;
        JO: JsonObject;
        Blank: JsonToken;
        JV: JsonValue;
    begin
        case TypeOrd of
            "ALI TypeKind"::JsonObject:
                SetTok(H, JO.AsToken());
            "ALI TypeKind"::JsonArray:
                SetTok(H, JA.AsToken());
            "ALI TypeKind"::JsonValue:
                SetTok(H, JV.AsToken());
            else
                SetTok(H, Blank);   // JsonToken
        end;
    end;

    // Deep clone via serialization round-trip — uniform across all 4 kinds (JsonToken itself
    // has no Clone(); this avoids the per-kind Clone() surface and always produces an
    // independent DOM, exactly what native Clone() guarantees).
    local procedure CloneTok(Tok: JsonToken): JsonToken
    var
        NewTok: JsonToken;
        Buf: Text;
    begin
        Tok.WriteTo(Buf);
        NewTok.ReadFrom(Buf);
        exit(NewTok);
    end;

    // ===== JsonObject (method ids 2-18) =====

    procedure ObjAddText(H: Integer; Name: Text; Val: Text)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddInt(H: Integer; Name: Text; Val: Integer)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddDec(H: Integer; Name: Text; Val: Decimal)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddBig(H: Integer; Name: Text; Val: BigInteger)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddDate(H: Integer; Name: Text; Val: Date)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddTime(H: Integer; Name: Text; Val: Time)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddDateTime(H: Integer; Name: Text; Val: DateTime)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    procedure ObjAddBool(H: Integer; Name: Text; Val: Boolean)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, Val);
    end;

    // Add(name, JsonToken/JsonObject/JsonArray) — the value handle's token is shared into the
    // object (reference semantics); one impl covers all 3 typed overloads (binder distinguishes).
    procedure ObjAddToken(H: Integer; Name: Text; ValH: Integer)
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.Add(Name, GetTok(ValH));
    end;

    procedure ObjContains(H: Integer; Name: Text): Boolean
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        exit(JO.Contains(Name));
    end;

    // Get(name, var JsonToken) — writes the found token into the caller's existing out-handle
    // slot (Http var-out mechanism: the out handle was allocated at its own declaration; we
    // rebind its bank slot, no fresh allocation, no tracking here).
    procedure ObjGet(H: Integer; Name: Text; OutH: Integer): Boolean
    var
        JO: JsonObject;
        Tok: JsonToken;
    begin
        GetObj(H, JO);
        if not JO.Get(Name, Tok) then
            exit(false);
        SetTok(OutH, Tok);
        exit(true);
    end;

    procedure ObjRemove(H: Integer; Name: Text): Boolean
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        exit(JO.Remove(Name));
    end;

    procedure ObjReplace(H: Integer; Name: Text; ValH: Integer): Boolean
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        exit(JO.Replace(Name, GetTok(ValH)));
    end;

    procedure ObjWriteTo(H: Integer; var OutText: Text): Boolean
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        JO.WriteTo(OutText);
        exit(true);
    end;

    // ReadFrom rebinds the object — write the reparsed token back into this handle's slot.
    procedure ObjReadFrom(H: Integer; Src: Text): Boolean
    var
        Ok: Boolean;
        JO: JsonObject;
    begin
        Ok := JO.ReadFrom(Src);
        SetTok(H, JO.AsToken());
        exit(Ok);
    end;

    procedure ObjKeys(H: Integer): Integer
    var
        ListH: Integer;
        JO: JsonObject;
        Name: Text;
    begin
        GetObj(H, JO);
        ListH := ListRt.NewList("ALI Register Class"::"Text");
        foreach Name in JO.Keys() do
            ListRt.Add(ListH, Name);
        exit(ListH);
    end;

    procedure ObjCount(H: Integer): Integer
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        exit(JO.Keys().Count());
    end;

    procedure ObjAsToken(H: Integer): Integer
    begin
        exit(NewHandle(GetTok(H)));
    end;

    procedure ObjClone(H: Integer): Integer
    begin
        exit(NewHandle(CloneTok(GetTok(H))));
    end;

    // ===== JsonObject typed getters (JSON_METHOD2, actual ids 101-116) =====
    // Native signature: Value := JO.GetX(Key [, DefaultIfNotFound]). Key found -> narrow via
    // AsValue().AsX() (kind/conversion mismatch errors natively, matching native timing).
    // Key missing: DefaultIfNotFound=true -> blank default of the type; false -> native-shaped
    // error. Handle-kind getters (GetObject/GetArray/GetValue) allocate a FRESH handle
    // (alloc-stack rule — see header of TokAsObject).

    local procedure ObjMustGetTok(H: Integer; Name: Text; DefaultIfNotFound: Boolean; var Tok: JsonToken): Boolean
    var
        JO: JsonObject;
    begin
        GetObj(H, JO);
        if JO.Get(Name, Tok) then
            exit(true);
        if DefaultIfNotFound then
            exit(false);
        Error('The property ''%1'' does not exist in the JsonObject', Name);
    end;

    procedure ObjGetText(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Text
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit('');
        exit(Tok.AsValue().AsText());
    end;

    procedure ObjGetInteger(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsInteger());
    end;

    procedure ObjGetBigInteger(H: Integer; Name: Text; DefaultIfNotFound: Boolean): BigInteger
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsBigInteger());
    end;

    procedure ObjGetDecimal(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Decimal
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsDecimal());
    end;

    procedure ObjGetBoolean(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Boolean
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(false);
        exit(Tok.AsValue().AsBoolean());
    end;

    procedure ObjGetDate(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Date
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0D);
        exit(Tok.AsValue().AsDate());
    end;

    procedure ObjGetTime(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Time
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0T);
        exit(Tok.AsValue().AsTime());
    end;

    procedure ObjGetDateTime(H: Integer; Name: Text; DefaultIfNotFound: Boolean): DateTime
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0DT);
        exit(Tok.AsValue().AsDateTime());
    end;

    procedure ObjGetDuration(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Duration
    var
        Blank: Duration;
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(Blank);
        exit(Tok.AsValue().AsDuration());
    end;

    procedure ObjGetGuid(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Guid
    var
        G: Guid;
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(G);
        if not Evaluate(G, Tok.AsValue().AsText()) then
            Error('The property ''%1'' is not a valid Guid', Name);
        exit(G);
    end;

    procedure ObjGetObject(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        BlankObj: JsonObject;
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankObj.AsToken()));
        exit(NewHandle(Tok.AsObject().AsToken()));
    end;

    procedure ObjGetArray(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        BlankArr: JsonArray;
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankArr.AsToken()));
        exit(NewHandle(Tok.AsArray().AsToken()));
    end;

    procedure ObjGetValue(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
        BlankVal: JsonValue;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankVal.AsToken()));
        exit(NewHandle(Tok.AsValue().AsToken()));
    end;

    // Byte/Char/Option getters (ids 114-116 / 144-146, JsonValue 94-96) return Integer: all
    // three live in the Int register class, and a Char must reach Integer through an
    // assignment (a Char in an Integer position throws System.Char -> Int32 at runtime).
    procedure ObjGetByte(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsByte(Tok.AsValue()));
    end;

    procedure ObjGetChar(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsChar(Tok.AsValue()));
    end;

    procedure ObjGetOption(H: Integer; Name: Text; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ObjMustGetTok(H, Name, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsOption(Tok.AsValue()));
    end;

    local procedure ValueAsByte(JV: JsonValue): Integer
    var
        Result: Integer;
    begin
        Result := JV.AsByte();
        exit(Result);
    end;

    local procedure ValueAsChar(JV: JsonValue): Integer
    var
        Result: Integer;
    begin
        Result := JV.AsChar();
        exit(Result);
    end;

    local procedure ValueAsOption(JV: JsonValue): Integer
    var
        Result: Integer;
    begin
        Result := JV.AsOption();
        exit(Result);
    end;

    // ===== JsonArray (method ids 27-43) — native 0-based indexes =====

    procedure ArrAddText(H: Integer; Val: Text)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddInt(H: Integer; Val: Integer)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddDec(H: Integer; Val: Decimal)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddBool(H: Integer; Val: Boolean)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddBig(H: Integer; Val: BigInteger)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddDate(H: Integer; Val: Date)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddTime(H: Integer; Val: Time)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddDateTime(H: Integer; Val: DateTime)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(Val);
    end;

    procedure ArrAddToken(H: Integer; ValH: Integer)
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.Add(GetTok(ValH));
    end;

    procedure ArrGet(H: Integer; Idx: Integer; OutH: Integer): Boolean
    var
        JA: JsonArray;
        Tok: JsonToken;
    begin
        GetArr(H, JA);
        if not JA.Get(Idx, Tok) then
            exit(false);
        SetTok(OutH, Tok);
        exit(true);
    end;

    procedure ArrSet(H: Integer; Idx: Integer; ValH: Integer): Boolean
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        exit(JA.Set(Idx, GetTok(ValH)));
    end;

    procedure ArrInsert(H: Integer; Idx: Integer; ValH: Integer): Boolean
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        exit(JA.Insert(Idx, GetTok(ValH)));
    end;

    procedure ArrRemoveAt(H: Integer; Idx: Integer): Boolean
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        exit(JA.RemoveAt(Idx));
    end;

    procedure ArrCount(H: Integer): Integer
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        exit(JA.Count());
    end;

    // Native JsonArray.IndexOf compares by DOM reference — our needle is always a distinct
    // token instance (built from a separate JsonValue), so reference compare returns -1. Match
    // native VALUE-equality semantics by comparing serialized WriteTo text element-by-element.
    procedure ArrIndexOf(H: Integer; ValH: Integer): Integer
    var
        i: Integer;
        JA: JsonArray;
        Elem: JsonToken;
        ElemText: Text;
        NeedleText: Text;
    begin
        GetArr(H, JA);
        GetTok(ValH).WriteTo(NeedleText);
        for i := 0 to JA.Count() - 1 do begin
            JA.Get(i, Elem);
            Elem.WriteTo(ElemText);
            if ElemText = NeedleText then
                exit(i);
        end;
        exit(-1);
    end;

    procedure ArrWriteTo(H: Integer; var OutText: Text): Boolean
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        JA.WriteTo(OutText);
        exit(true);
    end;

    procedure ArrReadFrom(H: Integer; Src: Text): Boolean
    var
        Ok: Boolean;
        JA: JsonArray;
    begin
        Ok := JA.ReadFrom(Src);
        SetTok(H, JA.AsToken());
        exit(Ok);
    end;

    procedure ArrAsToken(H: Integer): Integer
    begin
        exit(NewHandle(GetTok(H)));
    end;

    procedure ArrClone(H: Integer): Integer
    begin
        exit(NewHandle(CloneTok(GetTok(H))));
    end;

    // ===== JsonArray typed getters (JSON_METHOD2, actual ids 131-146) — 0-based index =====
    // Same contract as the JsonObject getters above; index out of range replaces key-missing.

    local procedure ArrMustGetTok(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean; var Tok: JsonToken): Boolean
    var
        JA: JsonArray;
    begin
        GetArr(H, JA);
        if JA.Get(Idx, Tok) then
            exit(true);
        if DefaultIfNotFound then
            exit(false);
        Error('Index %1 is out of range for the JsonArray', Idx);
    end;

    procedure ArrGetText(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Text
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit('');
        exit(Tok.AsValue().AsText());
    end;

    procedure ArrGetInteger(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsInteger());
    end;

    procedure ArrGetBigInteger(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): BigInteger
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsBigInteger());
    end;

    procedure ArrGetDecimal(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Decimal
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(Tok.AsValue().AsDecimal());
    end;

    procedure ArrGetBoolean(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Boolean
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(false);
        exit(Tok.AsValue().AsBoolean());
    end;

    procedure ArrGetDate(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Date
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0D);
        exit(Tok.AsValue().AsDate());
    end;

    procedure ArrGetTime(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Time
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0T);
        exit(Tok.AsValue().AsTime());
    end;

    procedure ArrGetDateTime(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): DateTime
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0DT);
        exit(Tok.AsValue().AsDateTime());
    end;

    procedure ArrGetDuration(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Duration
    var
        Blank: Duration;
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(Blank);
        exit(Tok.AsValue().AsDuration());
    end;

    procedure ArrGetGuid(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Guid
    var
        G: Guid;
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(G);
        if not Evaluate(G, Tok.AsValue().AsText()) then
            Error('The element at index %1 is not a valid Guid', Idx);
        exit(G);
    end;

    procedure ArrGetObject(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        BlankObj: JsonObject;
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankObj.AsToken()));
        exit(NewHandle(Tok.AsObject().AsToken()));
    end;

    procedure ArrGetArray(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        BlankArr: JsonArray;
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankArr.AsToken()));
        exit(NewHandle(Tok.AsArray().AsToken()));
    end;

    procedure ArrGetValue(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
        BlankVal: JsonValue;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(NewHandle(BlankVal.AsToken()));
        exit(NewHandle(Tok.AsValue().AsToken()));
    end;

    // Native JsonArray.GetByte/GetChar/GetOption take the index only — the binder rejects
    // arity 2, so DefaultIfNotFound is always false here (kept for a uniform dispatch).
    procedure ArrGetByte(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsByte(Tok.AsValue()));
    end;

    procedure ArrGetChar(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsChar(Tok.AsValue()));
    end;

    procedure ArrGetOption(H: Integer; Idx: Integer; DefaultIfNotFound: Boolean): Integer
    var
        Tok: JsonToken;
    begin
        if not ArrMustGetTok(H, Idx, DefaultIfNotFound, Tok) then
            exit(0);
        exit(ValueAsOption(Tok.AsValue()));
    end;

    // ===== JsonToken (method ids 52-61) =====

    procedure TokReadFrom(H: Integer; Src: Text): Boolean
    var
        Ok: Boolean;
        Tok: JsonToken;
    begin
        Ok := Tok.ReadFrom(Src);
        SetTok(H, Tok);
        exit(Ok);
    end;

    procedure TokWriteTo(H: Integer; var OutText: Text): Boolean
    begin
        GetTok(H).WriteTo(OutText);
        exit(true);
    end;

    procedure TokIsObject(H: Integer): Boolean
    begin
        exit(GetTok(H).IsObject());
    end;

    procedure TokIsArray(H: Integer): Boolean
    begin
        exit(GetTok(H).IsArray());
    end;

    procedure TokIsValue(H: Integer): Boolean
    begin
        exit(GetTok(H).IsValue());
    end;

    // As* narrow-and-return a FRESH handle sharing the same DOM node (never the receiver's
    // handle integer) — .AsObject()/.AsArray()/.AsValue() Error natively on a kind mismatch,
    // matching native timing.
    procedure TokAsObject(H: Integer): Integer
    var
        JO: JsonObject;
    begin
        JO := GetTok(H).AsObject();
        exit(NewHandle(JO.AsToken()));
    end;

    procedure TokAsArray(H: Integer): Integer
    var
        JA: JsonArray;
    begin
        JA := GetTok(H).AsArray();
        exit(NewHandle(JA.AsToken()));
    end;

    procedure TokAsValue(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        JV := GetTok(H).AsValue();
        exit(NewHandle(JV.AsToken()));
    end;

    procedure TokClone(H: Integer): Integer
    begin
        exit(NewHandle(CloneTok(GetTok(H))));
    end;

    procedure TokSelectToken(H: Integer; Path: Text; OutH: Integer): Boolean
    var
        Found: JsonToken;
        Tok: JsonToken;
    begin
        Tok := GetTok(H);
        if not Tok.SelectToken(Path, Found) then
            exit(false);
        SetTok(OutH, Found);
        exit(true);
    end;

    // ===== JsonValue (method ids 77-96) =====

    procedure ValSetText(H: Integer; Val: Text)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetInt(H: Integer; Val: Integer)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetDec(H: Integer; Val: Decimal)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetBool(H: Integer; Val: Boolean)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetDate(H: Integer; Val: Date)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetTime(H: Integer; Val: Time)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValSetDateTime(H: Integer; Val: DateTime)
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        JV.SetValue(Val);
        SetTok(H, JV.AsToken());
    end;

    procedure ValAsText(H: Integer): Text
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsText());
    end;

    procedure ValAsInteger(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsInteger());
    end;

    procedure ValAsDecimal(H: Integer): Decimal
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsDecimal());
    end;

    procedure ValAsBoolean(H: Integer): Boolean
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsBoolean());
    end;

    procedure ValAsDate(H: Integer): Date
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsDate());
    end;

    procedure ValAsTime(H: Integer): Time
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsTime());
    end;

    procedure ValAsDateTime(H: Integer): DateTime
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.AsDateTime());
    end;

    procedure ValAsByte(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(ValueAsByte(JV));
    end;

    procedure ValAsChar(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(ValueAsChar(JV));
    end;

    procedure ValAsOption(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(ValueAsOption(JV));
    end;

    procedure ValIsNull(H: Integer): Boolean
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(JV.IsNull());
    end;

    procedure ValAsToken(H: Integer): Integer
    var
        JV: JsonValue;
    begin
        GetVal(H, JV);
        exit(NewHandle(JV.AsToken()));
    end;
}
