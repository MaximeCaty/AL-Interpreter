// ALI Code Editor — part 1/5: shared state, language tables and pure helpers.
// Loaded first (see the Scripts list in ALICodeEditor.ControlAddIn.al); every other part
// reads the globals declared here. All symbols are prefixed ALICodeEditor_ because a
// controladdin shares the page's global scope with the client platform.

var ALICodeEditor_textarea, ALICodeEditor_highlightCode, ALICodeEditor_highlightPre, ALICodeEditor_gutter;
var ALICodeEditor_errorLayer, ALICodeEditor_errorTip;
var ALICodeEditor_editorRoot, ALICodeEditor_suggestBox, ALICodeEditor_mirror;
var ALICodeEditor_minimap, ALICodeEditor_minimapInner, ALICodeEditor_minimapSlider;
var ALICodeEditor_highlightLines = [''];  // per-line markup of the highlight layer (the minimap copies it)
var ALICodeEditor_lineCount = 1;
var ALICodeEditor_diags = [];
var ALICodeEditor_ready = false;
var ALICodeEditor_pending = [];

var ALICodeEditor_KEYWORDS = [
    'if', 'then', 'else', 'case', 'of', 'begin', 'end', 'var', 'procedure', 'trigger', 'local',
    'exit', 'repeat', 'until', 'while', 'do', 'for', 'to', 'downto', 'foreach', 'in', 'with',
    'and', 'or', 'not', 'xor', 'div', 'mod', 'true', 'false', 'codeunit', 'table', 'page', 'enum',
    'report', 'query', 'xmlport', 'field', 'fieldgroup', 'key', 'layout', 'actions', 'area',
    'group', 'part', 'action', 'extension', 'pageextension', 'tableextension',
    'protected', 'internal', 'access', 'break'
];
var ALICodeEditor_TYPES = [
    'Dialog', 'Integer', 'Decimal', 'Text', 'Code', 'Boolean', 'Date', 'Time', 'DateTime', 'Duration',
    'Char', 'Guid', 'Option', 'Record', 'RecordRef', 'Codeunit', 'Array',
    'Enum', 'Dictionary', 'List', 'TextBuilder', 'BigInteger', 'DateFormula', 'Array', 'RecordID',
    'InStream', 'OutStream', 'Label', 'RecordID', 'Variant', 'HttpClient', 'HttpRequestMessage', 'HttpResponseMessage', 'HttpHeaders', 'HttpContent',
    'JsonObject', 'JsonArray', 'JsonToken', 'JsonValue',
    'BigText', 'SecretText'
];
// Mirrors ALI Builtin Registry (PopulateString/Math/DateTime/System) — free-function builtins only
var ALICodeEditor_PROCS = [
    'CopyStr', 'StrLen', 'StrPos', 'StrSubstNo', 'Format', 'LowerCase', 'UpperCase', 'DelChr',
    'ConvertStr', 'PadStr', 'IncStr', 'SelectStr',
    'Abs', 'Round', 'Power', 'Random', 'Randomize',
    'Today', 'Time', 'CurrentDateTime', 'WorkDate', 'CalcDate', 'Date2DMY', 'Date2DWY',
    'DMY2Date', 'DWY2Date', 'CreateDateTime', 'DT2Date', 'DT2Time',
    'ClosingDate', 'NormalDate', 'RoundDateTime', 'DaTi2Variant', 'Variant2Date', 'Variant2Time',
    'Message', 'Error', 'Confirm', 'StrMenu', 'Sleep', 'GuiAllowed', 'CompanyName', 'UserId', 'UserSecurityId',
    'CreateGuid', 'IsNullGuid', 'Evaluate', 'GetLastErrorText', 'GetLastErrorCallStack', 'GETLASTERROROBJECT',
    'GETLASTERRORCODE', 'SelectLatestVersion', 'ClearLastError', 'Clear', 'ClearAll',
    'WindowsLanguage', 'GlobalLanguage', 'SessionID',
    'SecretStrSubstNo', 'ClientType', 'CurrentClientType', 'CurrentExecutionMode'
];

// Receiver names that are STATIC pseudo-objects rather than variables — `IsolatedStorage.Get(…)`
// needs no declaration. The names double as the catalog's `methods` keys; anything listed here
// must have a matching entry in "ALI Api Catalog".BuildMethodsObject.
var ALICodeEditor_STATIC_RECEIVERS = ['IsolatedStorage'];

// Record methods that take a field as their FIRST argument only (rec.SetRange(Field, ...)).
var ALICodeEditor_FIELD_ARG1 = {};
('SETRANGE SETFILTER GETFILTER GETRANGEMIN GETRANGEMAX MODIFYALL VALIDATE TESTFIELD FIELDERROR ' +
    'FIELDNAME FIELDCAPTION SETASCENDING GETASCENDING COPYFILTER')
    .split(' ').forEach(function (n) { ALICodeEditor_FIELD_ARG1[n] = true; });
// Record methods that take a field in EVERY argument (rec.CalcFields(A, B, C)).
var ALICodeEditor_FIELD_ARGN = {};
('CALCFIELDS CALCSUMS SETCURRENTKEY SETAUTOCALCFIELDS SETLOADFIELDS ADDLOADFIELDS LOADFIELDS AREFIELDSLOADED')
    .split(' ').forEach(function (n) { ALICodeEditor_FIELD_ARGN[n] = true; });

// Keywords after which a bare word is NOT a code expression, so no name completion is offered
// there: a declaration/signature/object header is being typed, not a statement.
var ALICodeEditor_NO_WORD_KW = {};
('var procedure trigger local protected internal access codeunit table page enum report query ' +
    'xmlport field fieldgroup key layout actions area group part action extension pageextension tableextension')
    .split(' ').forEach(function (n) { ALICodeEditor_NO_WORD_KW[n] = true; });

// Dropdown icons, VS Code-style: purple diamond = method/builtin, blue square = record field,
// bracketed square = declared variable, T = data type, table glyph = table name,
// gear = codeunit name, E = enum name / option member.
var ALICodeEditor_ICONS = { m: '◆', f: '▦', v: '[▪]', t: 'T', b: '▤', c: '⚙', e: 'E' };

// AL is case-insensitive: both lookup sets are keyed on the UPPERCASED word so `myrec: record customer`
// colors and resolves exactly like `MyRec: Record Customer`.
var ALICodeEditor_kwSet = {};
ALICodeEditor_KEYWORDS.forEach(function (w) { ALICodeEditor_kwSet[w.toLowerCase()] = true; });
var ALICodeEditor_typeSet = {};

// ===== API catalog / autocompletion state (fed from AL via SetApiCatalog/SetTableList/
// SetCodeunitList/SetObjectMembers — replaces the hardcoded lists above when present, so completion always
// matches the interpreter's real surface). =====
var ALICodeEditor_catalog = null;        // { types:[], builtins:[{n,min,max,r,p,ok}], methods:{Type:[{n,s,r}]} }
var ALICodeEditor_alLanguage = true;     // SetALLanguage master switch: coloring + completion + hover (Result pane: off)
var ALICodeEditor_tables = [];           // [{n, id}] all table names
var ALICodeEditor_codeunits = [];        // [{n, id}] all codeunit names
var ALICodeEditor_enums = [];            // [{n, id}] all enum names
var ALICodeEditor_objMembers = {};       // 'Table:UPPERNAME' / 'Codeunit:UPPERNAME' -> [{n,…}] | 'pending'
var ALICodeEditor_typeCanon = {};        // UPPER(type) -> canonical type name (catalog key)
var ALICodeEditor_pendingFieldCtx = null; // async RequestObjectMembers continuation ('suggest'|'hover')
var ALICodeEditor_hoverTip = null;
var ALICodeEditor_hoverTimer = null;
var ALICodeEditor_declNames = {};        // UPPER(name) -> decl info, rebuilt per render for var coloring

// Rebuilds both case-insensitive type lookups from the active type list (catalog or fallback).
function ALICodeEditor_rebuildTypeCanon() {
    ALICodeEditor_typeCanon = {};
    ALICodeEditor_typeSet = {};
    var types = ALICodeEditor_catalog && (ALICodeEditor_catalog.types instanceof Array) ?
        ALICodeEditor_catalog.types : ALICodeEditor_TYPES;
    types.forEach(function (t) {
        ALICodeEditor_typeCanon[t.toUpperCase()] = t;
        ALICodeEditor_typeSet[t.toUpperCase()] = true;
    });
}
ALICodeEditor_rebuildTypeCanon();

// Strip // comments, /* */ comments and 'string' literals in one linear scan so each char is
// classified in its real lexical context. A chained regex .replace() can't do this correctly in
// either order: comments-first breaks on a string containing `//` (Label 'http://...'), and
// strings-first breaks on a comment containing an apostrophe (French comments: "l'objet",
// "n'est pas") — either case makes the *other* stripper's regex hunt across the rest of the
// buffer for its closing delimiter, swallowing every declaration in between.
function ALICodeEditor_stripCommentsAndStrings(src) {
    var out = '';
    var i = 0;
    var n = src.length;
    while (i < n) {
        var c = src[i];
        if (c === '/' && src[i + 1] === '/') {
            while (i < n && src[i] !== '\n') i++;
            out += ' ';
            continue;
        }
        if (c === '/' && src[i + 1] === '*') {
            i += 2;
            while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
            i = Math.min(n, i + 2);
            out += ' ';
            continue;
        }
        if (c === "'") {
            i++;
            while (i < n) {
                if (src[i] === "'" && src[i + 1] === "'") { i += 2; continue; }
                if (src[i] === "'") { i++; break; }
                i++;
            }
            out += "''";
            continue;
        }
        out += c;
        i++;
    }
    return out;
}

// Parse every `name : Type` declaration in the buffer (var blocks AND procedure signatures)
// into a map UPPER(varName) -> {type: canonicalType, table: objectNameOrNull}. `table` carries
// the object name of `Record <table>`, `Codeunit <codeunit>` and `Enum <enum>` declarations;
// `Option A,B,"C D"` adds `options: ['A', 'B', 'C D']` (for `Var::` member completion). Cheap
// enough to rebuild on demand (buffer sizes here are scripts, not apps). Case-insensitive like AL:
// `rec: record Customer` is the same declaration as `Rec: Record Customer`.
function ALICodeEditor_scanDeclarations() {
    var map = {};
    var src = ALICodeEditor_stripCommentsAndStrings(ALICodeEditor_textarea.value);
    // name list supports AL's inline multi-declare: `a, b, c: Type;`. Option members run to the
    // `;` (var block) or `)` (parameter) — a quoted member may itself hold one: "Ref (ISO)".
    var re = /([A-Za-z_][A-Za-z0-9_]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_]*)*)\s*:\s*(?:(Record|Codeunit|Enum)\s+("([^"]+)"|[A-Za-z_][A-Za-z0-9_]*)|Option[ \t]+((?:"[^"]*"|[^;)"\n])*)|([A-Za-z_][A-Za-z0-9_]*))/gi;
    var m;
    while ((m = re.exec(src))) {
        var decl;
        if (m[2]) { // Record/Codeunit/Enum <object> — canonical spelling, not what was typed
            decl = {
                type: m[2].charAt(0).toUpperCase() + m[2].slice(1).toLowerCase(),
                table: m[4] ? m[4] : m[3]
            };
        } else if (m[5] !== undefined) {
            decl = { type: 'Option', table: null, options: ALICodeEditor_optionMembers(m[5]) };
        } else {
            var canon = ALICodeEditor_typeCanon[m[6].toUpperCase()];
            if (!canon) continue;
            decl = { type: canon, table: null };
        }
        m[1].split(',').forEach(function (name) {
            name = name.trim();
            if (!name || ALICodeEditor_kwSet[name.toLowerCase()]) return;
            // own copy per name: `name` is the as-typed spelling, used when the variable itself
            // is offered as a completion (the map key is uppercased and cannot be displayed)
            var entry = { type: decl.type, table: decl.table, name: name };
            if (decl.options) entry.options = decl.options;
            map[name.toUpperCase()] = entry;
        });
    }
    return map;
}

// `A, "B C",,D` -> ['A', 'B C', '', 'D']: split on commas outside quotes, unquote. Blank members
// are kept — the array index is the member's ordinal.
function ALICodeEditor_optionMembers(list) {
    return (list.match(/("[^"]*"|[^,"])*(,|$)/g) || [])
        .slice(0, -1) // the regex ends on one empty match at end-of-input
        .map(function (s) { return s.replace(/,$/, '').trim().replace(/^"|"$/g, ''); });
}

// Methods of a canonical type from the catalog (Text/Code share; Label reads as Text).
function ALICodeEditor_methodsOf(typeName) {
    if (!ALICodeEditor_catalog || !ALICodeEditor_catalog.methods) return null;
    if (typeName === 'Label') typeName = 'Text';
    return ALICodeEditor_catalog.methods[typeName] || null;
}

// The catalog's method rows for a STATIC pseudo-receiver named in the script (`IsolatedStorage`),
// or null when the name is not one. AL is case-insensitive, so the catalog key is matched that
// way — the script may type `isolatedstorage.` and still get the list.
function ALICodeEditor_staticMethodsOf(name) {
    if (!ALICodeEditor_catalog || !ALICodeEditor_catalog.methods) return null;
    var want = String(name).toUpperCase();
    var keys = ALICodeEditor_STATIC_RECEIVERS;
    for (var i = 0; i < keys.length; i++)
        if (keys[i].toUpperCase() === want) return ALICodeEditor_catalog.methods[keys[i]] || null;
    return null;
}

// Members of a built-in system option set (`DataScope`, `TextEncoding`, …) as [{n, v}], or null
// when the name is not one. Case-insensitive for the same reason as above.
function ALICodeEditor_systemOptionSet(name) {
    var sets = ALICodeEditor_catalog && ALICodeEditor_catalog.optionsets;
    if (!sets) return null;
    var want = String(name).toUpperCase();
    var keys = Object.keys(sets);
    for (var i = 0; i < keys.length; i++)
        if (keys[i].toUpperCase() === want) return sets[keys[i]];
    return null;
}

// Cached members of an object ('Table' → fields + procedures, 'Codeunit' → procedures), or
// null after firing a RequestObjectMembers round-trip. Object type is part of the cache key so
// a table and a codeunit sharing a name never collide.
function ALICodeEditor_membersOf(objType, objName, ctxKind) {
    var key = objType + ':' + objName.toUpperCase();
    var cached = ALICodeEditor_objMembers[key];
    if (cached && cached !== 'pending') return cached;
    if (cached !== 'pending') {
        ALICodeEditor_objMembers[key] = 'pending';
        if (window.Microsoft && Microsoft.Dynamics && Microsoft.Dynamics.NAV &&
            Microsoft.Dynamics.NAV.InvokeExtensibilityMethod) {
            Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('RequestObjectMembers', [objType, objName]);
        }
    }
    ALICodeEditor_pendingFieldCtx = { kind: ctxKind, key: key };
    return null;
}

// Members of the object behind a Record/Codeunit declaration, or null while the round-trip is
// in flight (null for any other type — nothing to fetch).
function ALICodeEditor_declMembers(decl, ctxKind) {
    if (!decl || !decl.table) return null;
    if (decl.type !== 'Record' && decl.type !== 'Codeunit') return null;
    return ALICodeEditor_membersOf(decl.type === 'Record' ? 'Table' : 'Codeunit', decl.table, ctxKind);
}

// "Text[50] (PK)" — the detail column shown next to a field name in completion and hover.
// A table-procedure row (k:'p') has no field type; it shows its own signature instead.
function ALICodeEditor_fieldDetail(f) {
    if (f.k === 'p') return f.s || '';
    return f.t + (f.len ? '[' + f.len + ']' : '') + (f.pk ? ' (PK)' : '');
}

// AL-quote a field/table name for insertion: bare if a plain identifier, "quoted" otherwise.
function ALICodeEditor_alQuote(name) {
    return /^[A-Za-z_][A-Za-z0-9_]*$/.test(name) ? name : '"' + name + '"';
}

// Source lines, split once per edit rather than on every mouse move / error-layer pass.
var ALICodeEditor_splitSrc = null, ALICodeEditor_splitLines = [''];
function ALICodeEditor_srcLines() {
    var v = ALICodeEditor_textarea.value;
    if (v !== ALICodeEditor_splitSrc) { ALICodeEditor_splitSrc = v; ALICodeEditor_splitLines = v.split('\n'); }
    return ALICodeEditor_splitLines;
}

function ALICodeEditor_escapeHtml(s) {
    return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
