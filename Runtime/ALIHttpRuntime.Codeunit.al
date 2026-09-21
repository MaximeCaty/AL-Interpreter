// ALI Http Runtime — Http* RefShim execution (M10).
//
// A Http* VALUE is an Int handle (RegClassInt) — SAME scheme as List/Dictionary/Array
// (ListDictionaryPlan.md §1), NOT an own handle space like TextBuilder/Dialog/Record. Each of
// the 5 kinds gets its own bank — `List of [Codeunit "ALI Http * Box"]`, NOT `List of [Http*]`
// directly: HttpClient/HttpRequestMessage/HttpResponseMessage/HttpContent are not valid List
// of [T] element types on this platform. See "ALI Http Boxes" for why the codeunit-box
// indirection sidesteps that (codeunit vars are always reference-typed, so boxing avoids the
// List-of-value-type aliasing question entirely). The handle is a plain 1-based bank index —
// no classIndex packing needed, since a variable's kind is fixed at compile time and the
// interpreter already knows which bank to hit from the method-id RANGE (see "ALI Opcode"
// HTTP_METHOD header). This gives := / handle-returning methods for free: assigning one
// Http-typed var to another of the same kind is a plain MOV_I (copy the Int handle) via the
// normal register file, and a method that "returns" a handle (e.g. Response.Content()) just
// writes a fresh Int into the result register like any other builtin — no new assignment
// mechanic required.
//
// Each variable gets its own bank slot allocated once, at declaration, by a compiler-emitted
// HTTP_METHOD "New" call (mirrors LIST_NEW/DICT_NEW — see "ALI Lowerer".EmitNewHttpForProc/
// Global). Native Http* data types carry reference semantics on assignment (BC docs): fetching
// the box's value into a local var, calling a native method that takes it as `var`, and
// writing the local var back with Box.SetVal() (belt-and-suspenders — covers both in-place
// mutation and full reassignment by the native method) keeps the box's copy authoritative
// either way.
codeunit 51146 "ALI Http Runtime"
{
    Access = Public;
    SingleInstance = true;

    var
        ListRt: Codeunit "ALI List Runtime";
        RunOptions: Codeunit "ALI Run Options";
        BankClient: List of [Codeunit "ALI Http Client Box"];
        BankContent: List of [Codeunit "ALI Http Content Box"];
        BankHeaders: List of [Codeunit "ALI Http Headers Box"];
        BankRequest: List of [Codeunit "ALI Http Request Box"];
        BankResponse: List of [Codeunit "ALI Http Response Box"];
        FreeClientIdx: List of [Integer];
        FreeContentIdx: List of [Integer];
        FreeHeadersIdx: List of [Integer];
        FreeRequestIdx: List of [Integer];
        FreeResponseIdx: List of [Integer];

    procedure Reset()
    begin
        Clear(BankClient);
        Clear(BankRequest);
        Clear(BankResponse);
        Clear(BankContent);
        Clear(BankHeaders);
        Clear(FreeClientIdx);
        Clear(FreeRequestIdx);
        Clear(FreeResponseIdx);
        Clear(FreeContentIdx);
        Clear(FreeHeadersIdx);
    end;

    // ===== Allocation / reclamation ("New"/Free — Free is called by "ALI Interpreter" on
    // frame pop, mirroring "ALI Array Runtime".FreeBlock; see that codeunit's header for why a
    // freed slot is RECYCLED (pushed to a per-kind FreeIdx list) rather than removed from the
    // bank — RemoveAt would shift every later handle's index. Reuse-before-grow keeps a
    // recursive/looping script's bank bounded instead of growing once per call. ("New" ids
    // are never user-callable — emitted at declaration by the lowerer, mirrors LIST_NEW/
    // DICT_NEW; handle-returning methods below (Content()/GetHeaders()/etc.) also allocate
    // through these, so their fresh handles are reclaimed the same way.) =====

    procedure NewClient(): Integer
    var
        Box: Codeunit "ALI Http Client Box";
        Blank: HttpClient;
        Idx: Integer;
    begin
        if FreeClientIdx.Count() > 0 then begin
            Idx := FreeClientIdx.Get(FreeClientIdx.Count());
            FreeClientIdx.RemoveAt(FreeClientIdx.Count());
            BankClient.Get(Idx, Box);
            Box.SetVal(Blank);
            exit(Idx);
        end;
        BankClient.Add(Box);
        exit(BankClient.Count());
    end;

    procedure FreeClient(H: Integer)
    var
        Box: Codeunit "ALI Http Client Box";
        Blank: HttpClient;
    begin
        if (H < 1) or (H > BankClient.Count()) then
            exit;
        BankClient.Get(H, Box);
        Box.SetVal(Blank);      // drop the reference so the underlying object can be GC'd
        FreeClientIdx.Add(H);
    end;

    procedure NewRequest(): Integer
    var
        Box: Codeunit "ALI Http Request Box";
        Blank: HttpRequestMessage;
        Idx: Integer;
    begin
        if FreeRequestIdx.Count() > 0 then begin
            Idx := FreeRequestIdx.Get(FreeRequestIdx.Count());
            FreeRequestIdx.RemoveAt(FreeRequestIdx.Count());
            BankRequest.Get(Idx, Box);
            Box.SetVal(Blank);
            exit(Idx);
        end;
        BankRequest.Add(Box);
        exit(BankRequest.Count());
    end;

    procedure FreeRequest(H: Integer)
    var
        Box: Codeunit "ALI Http Request Box";
        Blank: HttpRequestMessage;
    begin
        if (H < 1) or (H > BankRequest.Count()) then
            exit;
        BankRequest.Get(H, Box);
        Box.SetVal(Blank);
        FreeRequestIdx.Add(H);
    end;

    procedure NewResponse(): Integer
    var
        Box: Codeunit "ALI Http Response Box";
        Blank: HttpResponseMessage;
        Idx: Integer;
    begin
        if FreeResponseIdx.Count() > 0 then begin
            Idx := FreeResponseIdx.Get(FreeResponseIdx.Count());
            FreeResponseIdx.RemoveAt(FreeResponseIdx.Count());
            BankResponse.Get(Idx, Box);
            Box.SetVal(Blank);
            exit(Idx);
        end;
        BankResponse.Add(Box);
        exit(BankResponse.Count());
    end;

    procedure FreeResponse(H: Integer)
    var
        Box: Codeunit "ALI Http Response Box";
        Blank: HttpResponseMessage;
    begin
        if (H < 1) or (H > BankResponse.Count()) then
            exit;
        BankResponse.Get(H, Box);
        Box.SetVal(Blank);
        FreeResponseIdx.Add(H);
    end;

    procedure NewContent(): Integer
    var
        Box: Codeunit "ALI Http Content Box";
        Blank: HttpContent;
        Idx: Integer;
    begin
        if FreeContentIdx.Count() > 0 then begin
            Idx := FreeContentIdx.Get(FreeContentIdx.Count());
            FreeContentIdx.RemoveAt(FreeContentIdx.Count());
            BankContent.Get(Idx, Box);
            Box.SetVal(Blank);
            exit(Idx);
        end;
        BankContent.Add(Box);
        exit(BankContent.Count());
    end;

    procedure FreeContent(H: Integer)
    var
        Box: Codeunit "ALI Http Content Box";
        Blank: HttpContent;
    begin
        if (H < 1) or (H > BankContent.Count()) then
            exit;
        BankContent.Get(H, Box);
        Box.SetVal(Blank);
        FreeContentIdx.Add(H);
    end;

    procedure NewHeaders(): Integer
    var
        Box: Codeunit "ALI Http Headers Box";
        Blank: HttpHeaders;
        Idx: Integer;
    begin
        if FreeHeadersIdx.Count() > 0 then begin
            Idx := FreeHeadersIdx.Get(FreeHeadersIdx.Count());
            FreeHeadersIdx.RemoveAt(FreeHeadersIdx.Count());
            BankHeaders.Get(Idx, Box);
            Box.SetVal(Blank);
            exit(Idx);
        end;
        BankHeaders.Add(Box);
        exit(BankHeaders.Count());
    end;

    procedure FreeHeaders(H: Integer)
    var
        Box: Codeunit "ALI Http Headers Box";
        Blank: HttpHeaders;
    begin
        if (H < 1) or (H > BankHeaders.Count()) then
            exit;
        BankHeaders.Get(H, Box);
        Box.SetVal(Blank);
        FreeHeadersIdx.Add(H);
    end;

    // Dispatch by receiver TypeKind ordinal (92-96) — "ALI Interpreter" tracks a UNIFIED
    // frame-scoped alloc stack of (Kind, Handle) pairs shared with Array/List/Dictionary and
    // calls this on every PopFrame to reclaim what that frame allocated. Handle Lifecycle
    // Unification (resolved the prior M10 limitation): a Http* handle returned by value
    // (exit(h)) survives its frame's reclaim and is re-tracked as the caller's; one written
    // through a var-param or into a global is untracked at the store site itself
    // (HANDLE_ESCAPE/"ALI Interpreter".ExecHandleEscape, emitted by "ALI Lowerer".StoreToSym)
    // so it is never freed out from under the alias. Remaining accepted limitation: a handle
    // boxed into a Variant is not tracked as escaping (see ExecHandleEscape header).
    procedure FreeByKind(Kind: Integer; H: Integer)
    begin
        case Kind of
            "ALI TypeKind"::HttpClient:
                FreeClient(H);
            "ALI TypeKind"::HttpRequestMessage:
                FreeRequest(H);
            "ALI TypeKind"::HttpResponseMessage:
                FreeResponse(H);
            "ALI TypeKind"::HttpContent:
                FreeContent(H);
            "ALI TypeKind"::HttpHeaders:
                FreeHeaders(H);
        end;
    end;

    // Clear(var H) support (CLEAR_TARGET): reset the box's native value IN PLACE to a fresh
    // default of its kind — unlike Free*, the handle stays live and is NOT recycled (the
    // variable keeps its bank slot; only the content is reset, matching native Clear).
    procedure ClearByKind(Kind: Integer; H: Integer)
    var
        ClientBox: Codeunit "ALI Http Client Box";
        ContentBox: Codeunit "ALI Http Content Box";
        HeadersBox: Codeunit "ALI Http Headers Box";
        RequestBox: Codeunit "ALI Http Request Box";
        ResponseBox: Codeunit "ALI Http Response Box";
        BlankClient: HttpClient;
        BlankContent: HttpContent;
        BlankHeaders: HttpHeaders;
        BlankRequest: HttpRequestMessage;
        BlankResponse: HttpResponseMessage;
    begin
        case Kind of
            "ALI TypeKind"::HttpClient:
                if (H >= 1) and (H <= BankClient.Count()) then begin
                    BankClient.Get(H, ClientBox);
                    ClientBox.SetVal(BlankClient);
                end;
            "ALI TypeKind"::HttpRequestMessage:
                if (H >= 1) and (H <= BankRequest.Count()) then begin
                    BankRequest.Get(H, RequestBox);
                    RequestBox.SetVal(BlankRequest);
                end;
            "ALI TypeKind"::HttpResponseMessage:
                if (H >= 1) and (H <= BankResponse.Count()) then begin
                    BankResponse.Get(H, ResponseBox);
                    ResponseBox.SetVal(BlankResponse);
                end;
            "ALI TypeKind"::HttpContent:
                if (H >= 1) and (H <= BankContent.Count()) then begin
                    BankContent.Get(H, ContentBox);
                    ContentBox.SetVal(BlankContent);
                end;
            "ALI TypeKind"::HttpHeaders:
                if (H >= 1) and (H <= BankHeaders.Count()) then begin
                    BankHeaders.Get(H, HeadersBox);
                    HeadersBox.SetVal(BlankHeaders);
                end;
        end;
    end;

    // ===== HttpClient (method ids 2-11; 1 = New) =====

    local procedure CheckAllowHttp()
    begin
        if not RunOptions.AllowHttp() then
            Error('ALI982: HTTP request are not allowed within current execution setting');
    end;

    procedure ClientGet(ClientH: Integer; Url: Text; RespH: Integer): Boolean
    var
        RespBox: Codeunit "ALI Http Response Box";
        Ok: Boolean;
        Client: HttpClient;
        Response: HttpResponseMessage;
    begin
        CheckAllowHttp();
        GetClient(ClientH, Client);
        Ok := Client.Get(Url, Response);
        GetResponseBox(RespH, RespBox);
        RespBox.SetVal(Response);
        exit(Ok);
    end;

    procedure ClientPost(ClientH: Integer; Url: Text; ContentH: Integer; RespH: Integer): Boolean
    var
        RespBox: Codeunit "ALI Http Response Box";
        Ok: Boolean;
        Client: HttpClient;
        Content: HttpContent;
        Response: HttpResponseMessage;
    begin
        CheckAllowHttp();
        GetClient(ClientH, Client);
        GetContent(ContentH, Content);
        Ok := Client.Post(Url, Content, Response);
        GetResponseBox(RespH, RespBox);
        RespBox.SetVal(Response);
        exit(Ok);
    end;

    procedure ClientPut(ClientH: Integer; Url: Text; ContentH: Integer; RespH: Integer): Boolean
    var
        RespBox: Codeunit "ALI Http Response Box";
        Ok: Boolean;
        Client: HttpClient;
        Content: HttpContent;
        Response: HttpResponseMessage;
    begin
        CheckAllowHttp();
        GetClient(ClientH, Client);
        GetContent(ContentH, Content);
        Ok := Client.Put(Url, Content, Response);
        GetResponseBox(RespH, RespBox);
        RespBox.SetVal(Response);
        exit(Ok);
    end;

    procedure ClientDelete(ClientH: Integer; Url: Text; RespH: Integer): Boolean
    var
        RespBox: Codeunit "ALI Http Response Box";
        Ok: Boolean;
        Client: HttpClient;
        Response: HttpResponseMessage;
    begin
        CheckAllowHttp();
        GetClient(ClientH, Client);
        Ok := Client.Delete(Url, Response);
        GetResponseBox(RespH, RespBox);
        RespBox.SetVal(Response);
        exit(Ok);
    end;

    procedure ClientSend(ClientH: Integer; ReqH: Integer; RespH: Integer): Boolean
    var
        RespBox: Codeunit "ALI Http Response Box";
        Ok: Boolean;
        Client: HttpClient;
        Request: HttpRequestMessage;
        Response: HttpResponseMessage;
    begin
        CheckAllowHttp();
        GetClient(ClientH, Client);
        GetRequest(ReqH, Request);
        Ok := Client.Send(Request, Response);
        GetResponseBox(RespH, RespBox);
        RespBox.SetVal(Response);
        exit(Ok);
    end;

    procedure ClientSetBaseAddress(ClientH: Integer; Value: Text)
    var
        Box: Codeunit "ALI Http Client Box";
        Client: HttpClient;
    begin
        GetClientBox(ClientH, Box);
        Box.GetVal(Client);
        Client.SetBaseAddress(Value);
        Box.SetVal(Client);
    end;

    procedure ClientGetTimeout(ClientH: Integer): Duration
    var
        Client: HttpClient;
    begin
        GetClient(ClientH, Client);
        exit(Client.Timeout());
    end;

    procedure ClientSetTimeout(ClientH: Integer; Value: Duration)
    var
        Box: Codeunit "ALI Http Client Box";
        Client: HttpClient;
    begin
        GetClientBox(ClientH, Box);
        Box.GetVal(Client);
        Client.Timeout(Value);
        Box.SetVal(Client);
    end;

    procedure ClientDefaultRequestHeaders(ClientH: Integer): Integer
    var
        ClientBox: Codeunit "ALI Http Client Box";
        HeadersBox: Codeunit "ALI Http Headers Box";
        Client: HttpClient;
        Headers: HttpHeaders;
        NewH: Integer;
    begin
        GetClientBox(ClientH, ClientBox);
        ClientBox.GetVal(Client);
        Headers := Client.DefaultRequestHeaders();
        ClientBox.SetVal(Client);
        NewH := NewHeaders();
        GetHeadersBox(NewH, HeadersBox);
        HeadersBox.SetVal(Headers);
        exit(NewH);
    end;

    // See HeadersClear: banking a blank local would leave any DefaultRequestHeaders() handle
    // already handed out aliasing the OLD client, so reset the banked client in place.
    procedure ClientClear(ClientH: Integer)
    var
        Box: Codeunit "ALI Http Client Box";
        Client: HttpClient;
    begin
        GetClientBox(ClientH, Box);
        Box.GetVal(Client);
        Client.Clear();
        Box.SetVal(Client);
    end;

    // ===== HttpRequestMessage (method ids 21-27; 20 = New) =====

    procedure RequestGetMethod(ReqH: Integer): Text
    var
        Request: HttpRequestMessage;
    begin
        GetRequest(ReqH, Request);
        exit(Request.Method());
    end;

    procedure RequestSetMethod(ReqH: Integer; Value: Text)
    var
        Box: Codeunit "ALI Http Request Box";
        Request: HttpRequestMessage;
    begin
        GetRequestBox(ReqH, Box);
        Box.GetVal(Request);
        Request.Method(Value);
        Box.SetVal(Request);
    end;

    procedure RequestSetRequestUri(ReqH: Integer; Value: Text)
    var
        Box: Codeunit "ALI Http Request Box";
        Request: HttpRequestMessage;
    begin
        GetRequestBox(ReqH, Box);
        Box.GetVal(Request);
        Request.SetRequestUri(Value);
        Box.SetVal(Request);
    end;

    procedure RequestGetRequestUri(ReqH: Integer): Text
    var
        Request: HttpRequestMessage;
    begin
        GetRequest(ReqH, Request);
        exit(Request.GetRequestUri());
    end;

    procedure RequestGetContent(ReqH: Integer): Integer
    var
        ContentBox: Codeunit "ALI Http Content Box";
        ReqBox: Codeunit "ALI Http Request Box";
        Content: HttpContent;
        Request: HttpRequestMessage;
        NewH: Integer;
    begin
        GetRequestBox(ReqH, ReqBox);
        ReqBox.GetVal(Request);
        Content := Request.Content();
        ReqBox.SetVal(Request);
        NewH := NewContent();
        GetContentBox(NewH, ContentBox);
        ContentBox.SetVal(Content);
        exit(NewH);
    end;

    procedure RequestSetContent(ReqH: Integer; ContentH: Integer)
    var
        Box: Codeunit "ALI Http Request Box";
        Content: HttpContent;
        Request: HttpRequestMessage;
    begin
        GetRequestBox(ReqH, Box);
        Box.GetVal(Request);
        GetContent(ContentH, Content);
        Request.Content(Content);
        Box.SetVal(Request);
    end;

    procedure RequestGetHeaders(ReqH: Integer): Integer
    var
        HeadersBox: Codeunit "ALI Http Headers Box";
        ReqBox: Codeunit "ALI Http Request Box";
        Headers: HttpHeaders;
        Request: HttpRequestMessage;
        NewH: Integer;
    begin
        GetRequestBox(ReqH, ReqBox);
        ReqBox.GetVal(Request);
        Request.GetHeaders(Headers);
        ReqBox.SetVal(Request);
        NewH := NewHeaders();
        GetHeadersBox(NewH, HeadersBox);
        HeadersBox.SetVal(Headers);
        exit(NewH);
    end;

    // Native-shape GetHeaders(var Headers): fills the caller's EXISTING HttpHeaders handle box
    // (no fresh allocation) — same in-place out-param trick as HeadersGetValues' List handle.
    procedure RequestGetHeadersInto(ReqH: Integer; HeadersH: Integer)
    var
        HeadersBox: Codeunit "ALI Http Headers Box";
        ReqBox: Codeunit "ALI Http Request Box";
        Headers: HttpHeaders;
        Request: HttpRequestMessage;
    begin
        GetRequestBox(ReqH, ReqBox);
        ReqBox.GetVal(Request);
        Request.GetHeaders(Headers);
        ReqBox.SetVal(Request);
        GetHeadersBox(HeadersH, HeadersBox);
        HeadersBox.SetVal(Headers);
    end;

    // ===== HttpResponseMessage (method ids 41-46; 40 = New) =====

    procedure ResponseHttpStatusCode(RespH: Integer): Integer
    var
        Response: HttpResponseMessage;
    begin
        GetResponse(RespH, Response);
        exit(Response.HttpStatusCode());
    end;

    procedure ResponseIsSuccessStatusCode(RespH: Integer): Boolean
    var
        Response: HttpResponseMessage;
    begin
        GetResponse(RespH, Response);
        exit(Response.IsSuccessStatusCode());
    end;

    procedure ResponseReasonPhrase(RespH: Integer): Text
    var
        Response: HttpResponseMessage;
    begin
        GetResponse(RespH, Response);
        exit(Response.ReasonPhrase());
    end;

    procedure ResponseIsBlockedByEnvironment(RespH: Integer): Boolean
    var
        Response: HttpResponseMessage;
    begin
        GetResponse(RespH, Response);
        exit(Response.IsBlockedByEnvironment());
    end;

    procedure ResponseContent(RespH: Integer): Integer
    var
        ContentBox: Codeunit "ALI Http Content Box";
        RespBox: Codeunit "ALI Http Response Box";
        Content: HttpContent;
        Response: HttpResponseMessage;
        NewH: Integer;
    begin
        GetResponseBox(RespH, RespBox);
        RespBox.GetVal(Response);
        Content := Response.Content();
        RespBox.SetVal(Response);
        NewH := NewContent();
        GetContentBox(NewH, ContentBox);
        ContentBox.SetVal(Content);
        exit(NewH);
    end;

    procedure ResponseHeaders(RespH: Integer): Integer
    var
        HeadersBox: Codeunit "ALI Http Headers Box";
        RespBox: Codeunit "ALI Http Response Box";
        Headers: HttpHeaders;
        Response: HttpResponseMessage;
        NewH: Integer;
    begin
        GetResponseBox(RespH, RespBox);
        RespBox.GetVal(Response);
        Headers := Response.Headers();
        RespBox.SetVal(Response);
        NewH := NewHeaders();
        GetHeadersBox(NewH, HeadersBox);
        HeadersBox.SetVal(Headers);
        exit(NewH);
    end;

    // ===== HttpContent (method ids 61-64; 60 = New) =====

    procedure ContentWriteFrom(ContentH: Integer; Value: Text)
    var
        Box: Codeunit "ALI Http Content Box";
        Content: HttpContent;
    begin
        GetContentBox(ContentH, Box);
        Box.GetVal(Content);
        Content.WriteFrom(Value);
        Box.SetVal(Content);
    end;

    // Simplified v1 shape vs native ReadAs(var Value: Text): Boolean — returns the text
    // directly (Boolean success is rarely actionable at script scope; deferred if needed).
    procedure ContentReadAs(ContentH: Integer): Text
    var
        Content: HttpContent;
        Value: Text;
    begin
        GetContent(ContentH, Content);
        Content.ReadAs(Value);
        exit(Value);
    end;

    // Native-shape ReadAs(var Value: Text): Boolean — writes the body into the caller's Text var
    // and returns the native success flag (vs ContentReadAs which drops it).
    procedure ContentReadAsInto(ContentH: Integer; var Value: Text): Boolean
    var
        Content: HttpContent;
    begin
        GetContent(ContentH, Content);
        exit(Content.ReadAs(Value));
    end;

    procedure ContentGetHeaders(ContentH: Integer): Integer
    var
        ContentBox: Codeunit "ALI Http Content Box";
        HeadersBox: Codeunit "ALI Http Headers Box";
        Content: HttpContent;
        Headers: HttpHeaders;
        NewH: Integer;
    begin
        GetContentBox(ContentH, ContentBox);
        ContentBox.GetVal(Content);
        Content.GetHeaders(Headers);
        ContentBox.SetVal(Content);
        NewH := NewHeaders();
        GetHeadersBox(NewH, HeadersBox);
        HeadersBox.SetVal(Headers);
        exit(NewH);
    end;

    // Native-shape GetHeaders(var Headers): Boolean — fills the caller's EXISTING handle box,
    // same in-place trick as RequestGetHeadersInto.
    procedure ContentGetHeadersInto(ContentH: Integer; HeadersH: Integer): Boolean
    var
        ContentBox: Codeunit "ALI Http Content Box";
        HeadersBox: Codeunit "ALI Http Headers Box";
        Content: HttpContent;
        Headers: HttpHeaders;
        Ok: Boolean;
    begin
        GetContentBox(ContentH, ContentBox);
        ContentBox.GetVal(Content);
        Ok := Content.GetHeaders(Headers);
        ContentBox.SetVal(Content);
        GetHeadersBox(HeadersH, HeadersBox);
        HeadersBox.SetVal(Headers);
        exit(Ok);
    end;

    // See HeadersClear: a content handle is likewise often an alias (Request.Content(),
    // Response.Content()), so clear the banked value in place instead of banking a blank local.
    procedure ContentClear(ContentH: Integer)
    var
        Box: Codeunit "ALI Http Content Box";
        Content: HttpContent;
    begin
        GetContentBox(ContentH, Box);
        Box.GetVal(Content);
        Content.Clear();
        Box.SetVal(Content);
    end;

    // ===== HttpHeaders (method ids 81-86; 80 = New) =====

    procedure HeadersAdd(HeadersH: Integer; Name: Text; Value: Text)
    var
        Box: Codeunit "ALI Http Headers Box";
        Headers: HttpHeaders;
    begin
        GetHeadersBox(HeadersH, Box);
        Box.GetVal(Headers);
        Headers.Add(Name, Value);
        Box.SetVal(Headers);
    end;

    procedure HeadersTryAddWithoutValidation(HeadersH: Integer; Name: Text; Value: Text): Boolean
    var
        Box: Codeunit "ALI Http Headers Box";
        Ok: Boolean;
        Headers: HttpHeaders;
    begin
        GetHeadersBox(HeadersH, Box);
        Box.GetVal(Headers);
        Ok := Headers.TryAddWithoutValidation(Name, Value);
        Box.SetVal(Headers);
        exit(Ok);
    end;

    procedure HeadersContains(HeadersH: Integer; Name: Text): Boolean
    var
        Headers: HttpHeaders;
    begin
        GetHeaders(HeadersH, Headers);
        exit(Headers.Contains(Name));
    end;

    procedure HeadersRemove(HeadersH: Integer; Name: Text): Boolean
    var
        Box: Codeunit "ALI Http Headers Box";
        Ok: Boolean;
        Headers: HttpHeaders;
    begin
        GetHeadersBox(HeadersH, Box);
        Box.GetVal(Headers);
        Ok := Headers.Remove(Name);
        Box.SetVal(Headers);
        exit(Ok);
    end;

    // Native Headers.Clear() on the BANKED value, not AL's Clear() on a fresh local: a headers
    // handle is usually an ALIAS of some owner's live headers (Client.DefaultRequestHeaders(),
    // Content.GetHeaders(), Response.Headers()). Blanking a local and banking that would swap
    // the alias for a detached empty object — the handle would read back empty while the
    // owner's headers stayed untouched.
    procedure HeadersClear(HeadersH: Integer)
    var
        Box: Codeunit "ALI Http Headers Box";
        Headers: HttpHeaders;
    begin
        GetHeadersBox(HeadersH, Box);
        Box.GetVal(Headers);
        Headers.Clear();
        Box.SetVal(Headers);
    end;

    // GetValues(name, var List of [Text]) — ListHandle is a caller-owned List RefShim handle
    // (RegClassInt, same as any other List arg — ListDictionaryPlan.md §1); refilling it in
    // place via "ALI List Runtime" gives the caller-visible out-param for free, same trick as
    // the Box.SetVal() write-backs above.
    procedure HeadersGetValues(HeadersH: Integer; Name: Text; ListHandle: Integer): Boolean
    var
        Ok: Boolean;
        Headers: HttpHeaders;
        Values: List of [Text];
        Value: Text;
    begin
        GetHeaders(HeadersH, Headers);
        Ok := Headers.GetValues(Name, Values);
        ListRt.ClearList(ListHandle);
        foreach Value in Values do
            ListRt.Add(ListHandle, Value);
        exit(Ok);
    end;

    // ===== Bank accessors =====
    //
    // Two flavors per kind: GetXBox (fetches the box instance itself — needed when the caller
    // must SetVal() back) and GetX (box + GetVal in one step — for read-only callers).

    local procedure GetClientBox(H: Integer; var Box: Codeunit "ALI Http Client Box")
    begin
        if (H < 1) or (H > BankClient.Count()) then
            Error('ALI976: HttpClient handle %1 out of range', H);
        BankClient.Get(H, Box);
    end;

    local procedure GetClient(H: Integer; var Client: HttpClient)
    var
        Box: Codeunit "ALI Http Client Box";
    begin
        GetClientBox(H, Box);
        Box.GetVal(Client);
    end;

    local procedure GetRequestBox(H: Integer; var Box: Codeunit "ALI Http Request Box")
    begin
        if (H < 1) or (H > BankRequest.Count()) then
            Error('ALI977: HttpRequestMessage handle %1 out of range', H);
        BankRequest.Get(H, Box);
    end;

    local procedure GetRequest(H: Integer; var Request: HttpRequestMessage)
    var
        Box: Codeunit "ALI Http Request Box";
    begin
        GetRequestBox(H, Box);
        Box.GetVal(Request);
    end;

    local procedure GetResponseBox(H: Integer; var Box: Codeunit "ALI Http Response Box")
    begin
        if (H < 1) or (H > BankResponse.Count()) then
            Error('ALI978: HttpResponseMessage handle %1 out of range', H);
        BankResponse.Get(H, Box);
    end;

    local procedure GetResponse(H: Integer; var Response: HttpResponseMessage)
    var
        Box: Codeunit "ALI Http Response Box";
    begin
        GetResponseBox(H, Box);
        Box.GetVal(Response);
    end;

    local procedure GetContentBox(H: Integer; var Box: Codeunit "ALI Http Content Box")
    begin
        if (H < 1) or (H > BankContent.Count()) then
            Error('ALI979: HttpContent handle %1 out of range', H);
        BankContent.Get(H, Box);
    end;

    local procedure GetContent(H: Integer; var Content: HttpContent)
    var
        Box: Codeunit "ALI Http Content Box";
    begin
        GetContentBox(H, Box);
        Box.GetVal(Content);
    end;

    local procedure GetHeadersBox(H: Integer; var Box: Codeunit "ALI Http Headers Box")
    begin
        if (H < 1) or (H > BankHeaders.Count()) then
            Error('ALI980: HttpHeaders handle %1 out of range', H);
        BankHeaders.Get(H, Box);
    end;

    local procedure GetHeaders(H: Integer; var Headers: HttpHeaders)
    var
        Box: Codeunit "ALI Http Headers Box";
    begin
        GetHeadersBox(H, Box);
        Box.GetVal(Headers);
    end;
}
