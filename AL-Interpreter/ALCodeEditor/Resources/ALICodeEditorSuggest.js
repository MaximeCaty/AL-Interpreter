// ALI Code Editor — part 4/5: the completion dropdown (context detection, item pool, rendering).

var ALICodeEditor_suggestItems = [];      // currently visible (search-filtered) items
var ALICodeEditor_suggestAllItems = [];   // prefix-filtered pool behind the search box
var ALICodeEditor_suggestIndex = 0;
var ALICodeEditor_suggestPrefixStart = -1;
var ALICodeEditor_suggestListEl = null;   // scrollable list container inside the box
var ALICodeEditor_suggestSearchEl = null; // optional search input inside the box

// Last AL keyword (lowercased) found before caret, scanning the whole buffer. Used to tell
// whether caret sits in a "var" declaration block or past a "begin" in code body.
function ALICodeEditor_lastKeyword(caret) {
    var text = ALICodeEditor_textarea.value.slice(0, caret);
    var re = /[A-Za-z_][A-Za-z0-9_]*/g;
    var m, last = null;
    while ((m = re.exec(text))) {
        var w = m[0].toLowerCase();
        // A keyword in TYPE position (`Api: Codeunit "X";`) is part of a declaration, not the
        // block the caret sits in — counting it would make the NEXT declaration line in the
        // same var block look like it is no longer inside a var block, killing completion there.
        if (ALICodeEditor_kwSet[w] && !ALICodeEditor_afterColon(text, m.index)) last = w;
    }
    return last;
}

// True when the only thing between pos and the preceding ':' is whitespace.
function ALICodeEditor_afterColon(text, pos) {
    var i = pos - 1;
    while (i >= 0 && (text[i] === ' ' || text[i] === '\t')) i--;
    return i >= 0 && text[i] === ':';
}

// Completion context under the caret. Modes:
//   'type'     — `x: <pfx>` inside a var block            → data type names
//   'table'    — `x: Record <pfx>` inside a var block     → table names (SetTableList)
//   'codeunit' — `x: Codeunit <pfx>` inside a var block   → codeunit names (SetCodeunitList)
//   'enum'     — `x: Enum <pfx>` inside a var block       → enum names (SetEnumList)
//   'field'    — `rec.SetRange(<pfx>` inside code         → field names of rec's table
//   'member'   — `recv.<pfx>` inside code                 → methods (+ fields for Record vars,
//                                                           procedures for Codeunit vars)
//   'optmember'— `opt::<pfx>` inside code                 → members of a local Option variable
//   'proc'     — bare word inside code                    → builtins
function ALICodeEditor_typeContext() {
    if (ALICodeEditor_textarea.readOnly || !ALICodeEditor_alLanguage) return null;
    var caret = ALICodeEditor_textarea.selectionStart;
    if (caret !== ALICodeEditor_textarea.selectionEnd) return null;
    var val = ALICodeEditor_textarea.value;
    var lineStart = val.lastIndexOf('\n', caret - 1) + 1;
    var line = val.slice(lineStart, caret);
    if (line.indexOf('//') !== -1) return null;
    if ((line.split("'").length - 1) % 2 === 1) return null;

    // `x: Record <pfx>` / `x: Codeunit <pfx>` — object-name completion (prefix may be empty,
    // bare or "quoted…). The bare form deliberately accepts spaces and dots: most object names
    // are phrases ("Sales Line", "Cust. Ledger Entry") and are typed unquoted, so a space must
    // not end the prefix and drop the list. `;()"` stop it, which keeps the rest of the line out.
    var objMatch = line.match(/:[ \t]*(Record|Codeunit|Enum)[ \t]+("([^"]*)|[^;()"]*)$/i);
    if (objMatch) {
        // scan for the enclosing keyword up to the declaration colon, not up to the caret:
        // `Codeunit` is itself a keyword and would otherwise mask the `var` block it sits in
        if (ALICodeEditor_lastKeyword(lineStart + objMatch.index) !== 'var') return null;
        var raw = objMatch[2] || '';
        var pfx = objMatch[3] !== undefined ? objMatch[3] : raw;
        var objMode = { record: 'table', codeunit: 'codeunit', 'enum': 'enum' }[objMatch[1].toLowerCase()];
        return { mode: objMode, start: caret - raw.length, prefix: pfx };
    }

    // `opt::<pfx>` — members of a local Option variable; `rec.Field::<pfx>` — members of an
    // Option/Enum field (served with the table's fields). Bare or "quoted…" member prefix.
    // ponytail: Enum-typed variables and `Enum::"X"::` still offer nothing — needs enum source from AL.
    var optMatch = line.match(/(?:([A-Za-z_][A-Za-z0-9_]*|"[^"]+")[ \t]*\.[ \t]*)?([A-Za-z_][A-Za-z0-9_]*|"[^"]+")[ \t]*::[ \t]*("[^"]*|[A-Za-z0-9_]*)$/);
    if (optMatch) {
        var kwo = ALICodeEditor_lastKeyword(caret);
        if (!kwo || kwo === 'var') return null;
        var rawo = optMatch[3];
        var unq = function (s) { return s.replace(/^"|"$/g, ''); };
        return optMatch[1]
            ? { mode: 'optmember', start: caret - rawo.length, prefix: rawo.replace(/^"/, ''), receiver: unq(optMatch[1]), field: unq(optMatch[2]) }
            : { mode: 'optmember', start: caret - rawo.length, prefix: rawo.replace(/^"/, ''), receiver: unq(optMatch[2]) };
    }

    // `rec.SetRange(<pfx>` / `rec.CalcFields(A, <pfx>` — field completion inside a call whose
    // argument is a field, so filtering reads like `rec.` member completion.
    var ctx = ALICodeEditor_fieldArgContext(line, caret);
    if (ctx) return ctx;

    // `recv.<pfx>` — member completion (methods + record fields).
    var memMatch = line.match(/([A-Za-z_][A-Za-z0-9_]*|"[^"]+")\.([A-Za-z_][A-Za-z0-9_]*)?$/);
    if (memMatch) {
        var kw = ALICodeEditor_lastKeyword(caret);
        // anywhere in code (begin/then/do/else/...), just not in a var declaration block
        if (kw && kw !== 'var') {
            var recvName = memMatch[1].replace(/^"|"$/g, '');
            var pfx2 = memMatch[2] || '';
            return { mode: 'member', start: caret - pfx2.length, prefix: pfx2, receiver: recvName };
        }
    }

    var typeMatch = line.match(/(^|[^:]):[ \t]*([A-Za-z_][A-Za-z0-9_]*)$/);
    if (typeMatch) {
        if (ALICodeEditor_lastKeyword(caret) !== 'var') return null;
        return { mode: 'type', start: caret - typeMatch[2].length, prefix: typeMatch[2] };
    }

    // Bare word in a code body — builtins + the script's own declared variables. Allowed after
    // any keyword that opens/continues code (begin/then/else/do/until/…), which is every
    // keyword except the declaration ones: `x: Rec|` must stay type completion, not a name.
    var wordMatch = line.match(/([A-Za-z_][A-Za-z0-9_]*)$/);
    if (wordMatch) {
        var kw2 = ALICodeEditor_lastKeyword(caret);
        if (kw2 && !ALICodeEditor_NO_WORD_KW[kw2])
            return { mode: 'proc', start: caret - wordMatch[1].length, prefix: wordMatch[1] };
    }
    return null;
}

// 'field' context when the caret sits on a field argument of a Record call. Handles both
// SetRange/Validate/… (field is argument 1 only) and CalcFields/SetLoadFields/… (every argument).
function ALICodeEditor_fieldArgContext(line, caret) {
    // `[^()]*` on purpose: a nested call in the argument list (SetRange(F, CopyStr(x, 1, 2)))
    // means the caret is no longer on a bare field name, so no completion is offered there.
    var m = line.match(/([A-Za-z_][A-Za-z0-9_]*|"[^"]+")[ \t]*\.[ \t]*([A-Za-z_][A-Za-z0-9_]*)[ \t]*\(([^()]*)$/);
    if (!m) return null;
    var method = m[2].toUpperCase();
    var args = m[3];
    // ponytail: splitting on ',' also splits commas inside a string literal, which can only
    // over-count the argument index — that hides the dropdown, never offers a wrong field.
    var argIdx = args.split(',').length - 1;
    if (!(ALICodeEditor_FIELD_ARGN[method] || (ALICodeEditor_FIELD_ARG1[method] && argIdx === 0))) return null;
    var kw = ALICodeEditor_lastKeyword(caret);
    if (!kw || kw === 'var') return null;

    var tail = args.slice(args.lastIndexOf(',') + 1).replace(/^[ \t]+/, '');
    var quoted = tail.charAt(0) === '"';
    var prefix = quoted ? tail.slice(1) : tail;
    // bail out on anything that isn't the start of a field name (operators, half-typed exprs)
    if (quoted ? prefix.indexOf('"') !== -1 : !/^[A-Za-z0-9_]*$/.test(prefix)) return null;
    return {
        mode: 'field',
        start: caret - tail.length,
        prefix: prefix,
        receiver: m[1].replace(/^"|"$/g, '')
    };
}

// Fields of the declaration's table as completion items, or nothing while the fetch is in flight.
// The same array also carries the table's AL procedures (k:'p') — those are members, not fields.
function ALICodeEditor_pushFieldItems(items, decl) {
    var fields = ALICodeEditor_declMembers(decl, 'suggest');
    if (!fields) return;
    fields.forEach(function (f) {
        if (f.k === 'p') return;
        items.push({ t: ALICodeEditor_alQuote(f.n), l: f.n, d: ALICodeEditor_fieldDetail(f), k: 'f' });
    });
}

// The object's own AL procedures (served with the table's fields, or alone for a codeunit)
// — same row shape as a catalog method, so they render as methods.
function ALICodeEditor_pushTableProcItems(items, decl) {
    var rows = ALICodeEditor_declMembers(decl, 'suggest');
    if (!rows) return;
    rows.forEach(function (p) {
        if (p.k === 'p') items.push({ t: p.n, l: p.s || p.n, d: p.r || '', k: 'm' });
    });
}

// Build the item pool for a context. Items are {t: insertText, l: label, d: detail, k: iconKind}.
function ALICodeEditor_suggestPool(ctx) {
    var items = [];
    if (ctx.mode === 'type') {
        var types = ALICodeEditor_catalog ? ALICodeEditor_catalog.types : ALICodeEditor_TYPES;
        types.forEach(function (t) { items.push({ t: t, l: t, d: '', k: 't' }); });
        return items;
    }
    if (ctx.mode === 'proc') {
        // ponytail: every declaration in the buffer, no scope filtering — another procedure's
        // locals are offered too. Per-procedure scoping needs the caret's enclosing procedure
        // range, which is only worth building if the noise becomes a problem.
        var decls = ALICodeEditor_scanDeclarations();
        Object.keys(decls).forEach(function (up) {
            var d = decls[up];
            items.push({ t: d.name, l: d.name, d: d.table ? d.type + ' ' + d.table : d.type, k: 'v' });
        });
        if (ALICodeEditor_catalog && ALICodeEditor_catalog.builtins) {
            ALICodeEditor_catalog.builtins.forEach(function (b) {
                if (!b.ok) return; // recognized-but-unimplemented: hide from completion
                items.push({ t: b.n, l: b.n, d: (b.r && b.r !== 'None') ? b.r : '', k: 'm' });
            });
        } else {
            ALICodeEditor_PROCS.forEach(function (p) { items.push({ t: p, l: p, d: '', k: 'm' }); });
        }
        // Static pseudo-receivers (`IsolatedStorage`) are names a script types on their own, not
        // declarations and not free functions, so neither loop above offers them. A variable of
        // the same name already pushed its own row — skip ours rather than list the name twice.
        ALICodeEditor_STATIC_RECEIVERS.forEach(function (n) {
            if (!decls[n.toUpperCase()]) items.push({ t: n, l: n, d: '', k: 'c' });
        });
        return items;
    }
    if (ctx.mode === 'optmember') {
        var od = ALICodeEditor_scanDeclarations()[ctx.receiver.toUpperCase()];
        if (ctx.field) {
            var fup = ctx.field.toUpperCase();
            var fld = (ALICodeEditor_declMembers(od, 'suggest') || []).find(function (f) { return f.k !== 'p' && f.n.toUpperCase() === fup; });
            if (fld && fld.o) fld.o.forEach(function (o) {
                items.push({ t: ALICodeEditor_alQuote(o.n), l: o.n, d: String(o.v), k: 'e' });
            });
            return items;
        }
        if (od && od.options) od.options.forEach(function (o, ord) {
            if (o) items.push({ t: ALICodeEditor_alQuote(o), l: o, d: String(ord), k: 'e' });
        });
        // `DataScope::` / `TextEncoding::` / … — a built-in system option set, named directly
        // rather than through a variable. Checked only when no local declaration claimed the
        // name, so a script's own `DataScope: Option ...` still shadows it.
        if (!od) {
            var sys = ALICodeEditor_systemOptionSet(ctx.receiver);
            if (sys) sys.forEach(function (o) {
                items.push({ t: ALICodeEditor_alQuote(o.n), l: o.n, d: String(o.v), k: 'e' });
            });
        }
        return items;
    }
    if (ctx.mode === 'table' || ctx.mode === 'codeunit' || ctx.mode === 'enum') {
        var objs = { table: ALICodeEditor_tables, codeunit: ALICodeEditor_codeunits, 'enum': ALICodeEditor_enums }[ctx.mode];
        var ico = { table: 'b', codeunit: 'c', 'enum': 'e' }[ctx.mode];
        objs.forEach(function (ob) {
            items.push({ t: ALICodeEditor_alQuote(ob.n), l: ob.n, d: String(ob.id), k: ico });
        });
        return items;
    }
    if (ctx.mode === 'field' || ctx.mode === 'member') {
        var decl = ALICodeEditor_scanDeclarations()[ctx.receiver.toUpperCase()];
        // Static pseudo-receiver (`IsolatedStorage.`): a NAME, not a declared variable, so the
        // declaration scan finds nothing. Only in 'member' mode — `IsolatedStorage.SetRange(`
        // is not a thing, so 'field' must keep returning nothing. A real declaration of the same
        // name wins, which keeps a script that declares `IsolatedStorage: Text` honest.
        if (!decl && ctx.mode === 'member') {
            var statics = ALICodeEditor_staticMethodsOf(ctx.receiver);
            if (statics) statics.forEach(function (sm) {
                items.push({ t: sm.n, l: sm.s || sm.n, d: sm.r || '', k: 'm' });
            });
            return items;
        }
        if (!decl) return items;
        ALICodeEditor_pushFieldItems(items, decl);
        if (ctx.mode === 'field') return items; // only fields belong in `SetRange(...)`
        ALICodeEditor_pushTableProcItems(items, decl);
        var methods = ALICodeEditor_methodsOf(decl.type);
        if (methods) methods.forEach(function (mm) {
            items.push({ t: mm.n, l: mm.s || mm.n, d: mm.r || '', k: 'm' });
        });
        return items;
    }
    return items;
}

function ALICodeEditor_updateSuggest() {
    var ctx = ALICodeEditor_typeContext();
    if (!ctx) { ALICodeEditor_hideSuggest(); return; }
    var pfx = ctx.prefix.toLowerCase();
    var pool = ALICodeEditor_suggestPool(ctx);
    var items = pool.filter(function (it) {
        var lower = it.l.toLowerCase();
        // member/object/field modes: full list on an empty prefix (right after '.'/'::'/'Record '/'(')
        if (!pfx) return ctx.mode !== 'type' && ctx.mode !== 'proc';
        // field/object/member names are phrases ("Document No.", "Sales Line") — substring beats prefix
        if (ctx.mode === 'field' || ctx.mode === 'table' || ctx.mode === 'codeunit' || ctx.mode === 'enum' || ctx.mode === 'optmember')
            return lower.indexOf(pfx) !== -1;
        return lower.indexOf(pfx) === 0 && lower !== pfx;
    });
    if (!items.length) { ALICodeEditor_hideSuggest(); return; }
    if (items.length > 500) items = items.slice(0, 500);
    ALICodeEditor_suggestAllItems = items;
    ALICodeEditor_suggestItems = items;
    ALICodeEditor_suggestIndex = 0;
    ALICodeEditor_suggestPrefixStart = ctx.start;
    ALICodeEditor_renderSuggest();
    ALICodeEditor_positionSuggest(ctx.start);
}

// Re-filter the visible items by the search box (substring, case-insensitive).
function ALICodeEditor_applySuggestSearch() {
    var q = ALICodeEditor_suggestSearchEl ? ALICodeEditor_suggestSearchEl.value.toLowerCase() : '';
    ALICodeEditor_suggestItems = !q ? ALICodeEditor_suggestAllItems :
        ALICodeEditor_suggestAllItems.filter(function (it) { return it.l.toLowerCase().indexOf(q) !== -1; });
    ALICodeEditor_suggestIndex = 0;
    ALICodeEditor_renderSuggestList();
}

function ALICodeEditor_renderSuggest() {
    var box = ALICodeEditor_suggestBox;
    box.innerHTML = '';
    ALICodeEditor_suggestSearchEl = null;
    // Long lists (table names, wide method sets) get a substring search box on top.
    if (ALICodeEditor_suggestAllItems.length > 25) {
        var search = document.createElement('input');
        search.type = 'text';
        search.className = 'ali-suggest-search';
        search.placeholder = 'search...';
        search.addEventListener('input', ALICodeEditor_applySuggestSearch);
        search.addEventListener('keydown', function (e) {
            if (e.key === 'ArrowDown' || e.key === 'ArrowUp' || e.key === 'Enter' || e.key === 'Tab' || e.key === 'Escape') {
                ALICodeEditor_onKeyDown(e);
                if (e.key === 'Enter' || e.key === 'Tab' || e.key === 'Escape') ALICodeEditor_textarea.focus();
            }
            e.stopPropagation();
        });
        box.appendChild(search);
        ALICodeEditor_suggestSearchEl = search;
    }
    ALICodeEditor_suggestListEl = document.createElement('div');
    ALICodeEditor_suggestListEl.className = 'ali-suggest-list';
    box.appendChild(ALICodeEditor_suggestListEl);
    ALICodeEditor_renderSuggestList();
    box.style.display = 'block';
}

function ALICodeEditor_renderSuggestList() {
    var list = ALICodeEditor_suggestListEl;
    if (!list) return;
    list.innerHTML = '';
    ALICodeEditor_suggestItems.forEach(function (it, i) {
        var el = document.createElement('div');
        var kind = it.k || 'm';
        var ico = document.createElement('span');
        ico.className = 'ali-suggest-ico ali-ico-' + kind;
        ico.textContent = ALICodeEditor_ICONS[kind] || '';
        el.appendChild(ico);
        var lbl = document.createElement('span');
        lbl.textContent = it.l;
        el.appendChild(lbl);
        if (it.d) {
            var det = document.createElement('span');
            det.className = 'ali-suggest-detail';
            det.textContent = it.d;
            el.appendChild(det);
        }
        if (i === ALICodeEditor_suggestIndex) el.className = 'ali-suggest-sel';
        el.addEventListener('mousedown', function (e) {
            e.preventDefault();
            ALICodeEditor_suggestIndex = i;
            ALICodeEditor_acceptSuggest();
        });
        el.addEventListener('mouseenter', function () {
            ALICodeEditor_suggestIndex = i;
            ALICodeEditor_highlightSuggest();
        });
        list.appendChild(el);
    });
}

function ALICodeEditor_highlightSuggest() {
    if (!ALICodeEditor_suggestListEl) return;
    var children = ALICodeEditor_suggestListEl.children;
    for (var i = 0; i < children.length; i++) {
        children[i].className = i === ALICodeEditor_suggestIndex ? 'ali-suggest-sel' : '';
    }
    var sel = children[ALICodeEditor_suggestIndex];
    if (sel && sel.scrollIntoView) sel.scrollIntoView({ block: 'nearest' });
}

function ALICodeEditor_positionSuggest(anchor) {
    var val = ALICodeEditor_textarea.value;
    var before = val.slice(0, anchor);
    var lineStart = before.lastIndexOf('\n') + 1;
    var lineIdx = before.split('\n').length - 1;
    ALICodeEditor_mirror.textContent = before.slice(lineStart);
    var x = 44 + 12 + ALICodeEditor_mirror.getBoundingClientRect().width - ALICodeEditor_textarea.scrollLeft;
    var y = 10 + (lineIdx + 1) * 22 - ALICodeEditor_textarea.scrollTop;
    var box = ALICodeEditor_suggestBox;
    var rootW = ALICodeEditor_contentWidth(); // stop short of the minimap strip when it is shown
    var rootH = ALICodeEditor_editorRoot.clientHeight;
    if (y + box.offsetHeight > rootH && y - 22 - box.offsetHeight >= 0) y = y - 22 - box.offsetHeight;
    if (x + box.offsetWidth > rootW) x = Math.max(0, rootW - box.offsetWidth - 4);
    box.style.left = x + 'px';
    box.style.top = y + 'px';
}

function ALICodeEditor_suggestVisible() {
    return ALICodeEditor_suggestBox && ALICodeEditor_suggestBox.style.display === 'block';
}

function ALICodeEditor_hideSuggest() {
    if (ALICodeEditor_suggestBox) ALICodeEditor_suggestBox.style.display = 'none';
    ALICodeEditor_suggestItems = [];
}

function ALICodeEditor_acceptSuggest() {
    var item = ALICodeEditor_suggestItems[ALICodeEditor_suggestIndex];
    if (!item) { ALICodeEditor_hideSuggest(); return; }
    var insert = item.t !== undefined ? item.t : item;
    var val = ALICodeEditor_textarea.value;
    var caret = ALICodeEditor_textarea.selectionStart;
    var start = ALICodeEditor_suggestPrefixStart;
    ALICodeEditor_textarea.value = val.slice(0, start) + insert + val.slice(caret);
    ALICodeEditor_textarea.selectionStart = ALICodeEditor_textarea.selectionEnd = start + insert.length;
    ALICodeEditor_hideSuggest();
    ALICodeEditor_textarea.focus(); // accept may come from the dropdown's search input
    ALICodeEditor_render();
    ALICodeEditor_scrollCaretIntoView();
    ALICodeEditor_notifyChanged();
}
