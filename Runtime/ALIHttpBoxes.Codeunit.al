// ALI Http Boxes (M10) — one tiny per-instance (NOT SingleInstance) codeunit per Http* kind,
// each holding exactly one native variable of that type.
//
// Why: "ALI Http Runtime" originally banked handles as `List of [HttpClient]` etc. (the same
// scheme as "ALI TextBuilder Runtime"'s `List of [TextBuilder]`) — but unlike TextBuilder,
// HttpClient/HttpRequestMessage/HttpResponseMessage/HttpContent are NOT valid List of [T]
// element types on this platform (compile error). Codeunit variables ARE always reference-
// typed in AL (never value-copied, unlike Record/TextBuilder), so `List of [Codeunit ...]`
// sidesteps the restriction entirely: each box is its own distinct instance (declaring a
// non-SingleInstance codeunit var auto-instantiates a fresh one), and fetching it back out of
// the bank list yields a handle to that SAME instance — no List-of-value-type aliasing risk to
// worry about at all.
codeunit 51076 "ALI Http Client Box"
{
    Access = Public;

    var
        Val: HttpClient;

    procedure GetVal(var V: HttpClient)
    begin
        V := Val;
    end;

    procedure SetVal(V: HttpClient)
    begin
        Val := V;
    end;
}

codeunit 51077 "ALI Http Request Box"
{
    Access = Public;

    var
        Val: HttpRequestMessage;

    procedure GetVal(var V: HttpRequestMessage)
    begin
        V := Val;
    end;

    procedure SetVal(V: HttpRequestMessage)
    begin
        Val := V;
    end;
}

codeunit 51078 "ALI Http Response Box"
{
    Access = Public;

    var
        Val: HttpResponseMessage;

    procedure GetVal(var V: HttpResponseMessage)
    begin
        V := Val;
    end;

    procedure SetVal(V: HttpResponseMessage)
    begin
        Val := V;
    end;
}

codeunit 51079 "ALI Http Content Box"
{
    Access = Public;

    var
        Val: HttpContent;

    procedure GetVal(var V: HttpContent)
    begin
        V := Val;
    end;

    procedure SetVal(V: HttpContent)
    begin
        Val := V;
    end;
}

codeunit 51080 "ALI Http Headers Box"
{
    Access = Public;

    var
        Val: HttpHeaders;

    procedure GetVal(var V: HttpHeaders)
    begin
        V := Val;
    end;

    procedure SetVal(V: HttpHeaders)
    begin
        Val := V;
    end;
}
