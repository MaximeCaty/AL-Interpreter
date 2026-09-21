// ALI Code Editor — part 3/5: hover tooltips (compiler diagnostics + Record field list).
// The textarea sits on top of the painted layers, so hit-testing is done by measuring pixel
// spans in the hidden mirror <pre> (same font/tab-size as the editor).

function ALICodeEditor_hideErrorTip() {
    if (ALICodeEditor_errorTip) ALICodeEditor_errorTip.style.display = 'none';
}

function ALICodeEditor_hideHoverTip() {
    if (ALICodeEditor_hoverTimer) { clearTimeout(ALICodeEditor_hoverTimer); ALICodeEditor_hoverTimer = null; }
    if (ALICodeEditor_hoverTip) ALICodeEditor_hoverTip.style.display = 'none';
}

// Pixel <-> column math on the monospace editor font, so hit-testing measures the DOM once, not
// per character: charAtX used to rewrite the mirror and force a synchronous layout for every
// character of the hovered line, each one also paying for whatever the last edit left dirty.
// ponytail: assumes one cell per character (true for Consolas, accents included); CJK/emoji
// would drift — measure the line prefix with the mirror if that ever matters.
var ALICodeEditor_cellW = 0, ALICodeEditor_cellDpr = 0;

function ALICodeEditor_cellWidth() {
    if (!ALICodeEditor_cellW || ALICodeEditor_cellDpr !== window.devicePixelRatio) { // zoom changes hinting
        ALICodeEditor_mirror.textContent = new Array(101).join('M');
        ALICodeEditor_cellW = ALICodeEditor_mirror.getBoundingClientRect().width / 100;
        ALICodeEditor_cellDpr = window.devicePixelRatio;
    }
    return ALICodeEditor_cellW;
}

// Visual column of character idx on the line (tab stops every 4 — tab-size in the CSS).
function ALICodeEditor_colOf(lineText, idx) {
    var col = 0;
    for (var i = 0; i < idx && i < lineText.length; i++)
        col = lineText[i] === '\t' ? col - col % 4 + 4 : col + 1;
    return col;
}

// Character index in lineText at pixel offset x: the first character whose right edge passes x.
function ALICodeEditor_charAtX(lineText, x) {
    var w = ALICodeEditor_cellWidth(), col = 0;
    for (var i = 0; i < lineText.length; i++) {
        col = lineText[i] === '\t' ? col - col % 4 + 4 : col + 1;
        if (col * w > x) return i;
    }
    return lineText.length - 1;
}

// Identifier (bare or "quoted") covering charIdx on the line, or null.
function ALICodeEditor_wordAt(lineText, charIdx) {
    if (charIdx < 0 || charIdx >= lineText.length) return null;
    var re = /"[^"]+"|[A-Za-z_][A-Za-z0-9_]*/g;
    var m;
    while ((m = re.exec(lineText))) {
        if (m.index <= charIdx && charIdx < m.index + m[0].length)
            return m[0].replace(/^"|"$/g, '');
    }
    return null;
}

// Place a tooltip near the mouse, flipped/clamped to stay inside the editor box.
function ALICodeEditor_placeTip(tip, e) {
    var rootRect = ALICodeEditor_editorRoot.getBoundingClientRect();
    var tx = e.clientX - rootRect.left + 8;
    var ty = e.clientY - rootRect.top + 18;
    var rootW = ALICodeEditor_contentWidth(); // stop short of the minimap strip when it is shown
    if (tx + tip.offsetWidth > rootW)
        tx = Math.max(0, rootW - tip.offsetWidth - 4);
    if (ty + tip.offsetHeight > ALICodeEditor_editorRoot.clientHeight)
        ty = Math.max(0, e.clientY - rootRect.top - tip.offsetHeight - 8);
    tip.style.left = tx + 'px';
    tip.style.top = ty + 'px';
}

function ALICodeEditor_tryShowRecordHover(e) {
    if (!ALICodeEditor_alLanguage || !ALICodeEditor_hoverTip) return;
    var rect = ALICodeEditor_textarea.getBoundingClientRect();
    var x = e.clientX - rect.left + ALICodeEditor_textarea.scrollLeft - 12;
    var y = e.clientY - rect.top + ALICodeEditor_textarea.scrollTop - 10;
    var lineIdx = Math.floor(y / 22);
    var lines = ALICodeEditor_srcLines();
    if (lineIdx < 0 || lineIdx >= lines.length) { ALICodeEditor_hideHoverTip(); return; }
    var word = ALICodeEditor_wordAt(lines[lineIdx], ALICodeEditor_charAtX(lines[lineIdx], x));
    if (!word) { ALICodeEditor_hideHoverTip(); return; }
    var decl = ALICodeEditor_declNames[word.toUpperCase()]; // render() keeps it current per edit
    if (!decl || !decl.table || (decl.type !== 'Record' && decl.type !== 'Codeunit')) {
        ALICodeEditor_hideHoverTip();
        return;
    }
    var fields = ALICodeEditor_declMembers(decl, 'hover');
    if (!fields) {
        // async fetch fired — remember position so SetObjectMembers can re-show
        ALICodeEditor_pendingFieldCtx.event = { clientX: e.clientX, clientY: e.clientY };
        return;
    }
    ALICodeEditor_showRecordHover(e, word, decl.type + ' ' + decl.table, fields);
}

function ALICodeEditor_fillHoverTable(tbl, fields, query) {
    tbl.innerHTML = '';
    var q = (query || '').toLowerCase();
    fields.forEach(function (f) {
        if (q && f.n.toLowerCase().indexOf(q) === -1) return;
        var tr = document.createElement('tr');
        var td1 = document.createElement('td');
        td1.textContent = f.n;
        var td2 = document.createElement('td');
        td2.textContent = ALICodeEditor_fieldDetail(f);
        tr.appendChild(td1);
        tr.appendChild(td2);
        tbl.appendChild(tr);
    });
}

// declText = "Record Customer" / "Codeunit MyCodeunit" — the variable's declared type.
function ALICodeEditor_showRecordHover(e, varName, declText, fields) {
    var tip = ALICodeEditor_hoverTip;
    tip.innerHTML = '';
    var head = document.createElement('div');
    head.className = 'ali-hover-head';
    head.textContent = varName + ': ' + declText;
    tip.appendChild(head);
    // field search box (substring filter on the field name)
    var search = document.createElement('input');
    search.type = 'text';
    search.className = 'ali-hover-search';
    search.placeholder = 'search field...';
    tip.appendChild(search);
    var tbl = document.createElement('table');
    ALICodeEditor_fillHoverTable(tbl, fields, '');
    tip.appendChild(tbl);
    search.addEventListener('input', function () {
        ALICodeEditor_fillHoverTable(tbl, fields, search.value);
    });
    search.addEventListener('keydown', function (e2) {
        if (e2.key === 'Escape') { ALICodeEditor_hideHoverTip(); ALICodeEditor_textarea.focus(); }
        e2.stopPropagation();
    });
    tip.style.display = 'block';
    ALICodeEditor_placeTip(tip, e);
}

// Result pane: the line style under the mouse when it carries a source link, else null. Only the
// text itself is a hit, not the empty space to its right.
function ALICodeEditor_outLinkAt(e) {
    if (!ALICodeEditor_outLines) return null;
    var rect = ALICodeEditor_textarea.getBoundingClientRect();
    var x = e.clientX - rect.left + ALICodeEditor_textarea.scrollLeft - 12;
    var y = e.clientY - rect.top + ALICodeEditor_textarea.scrollTop - 10;
    var idx = Math.floor(y / 22), lines = ALICodeEditor_srcLines();
    if (idx < 0 || idx >= lines.length || !lines[idx]) return null;
    var st = ALICodeEditor_outLines[idx];
    if (!st || !st.ln) return null;
    if (x < 0 || x > ALICodeEditor_colOf(lines[idx], lines[idx].length) * ALICodeEditor_cellWidth()) return null;
    return st;
}

function ALICodeEditor_onMouseMove(e) {
    // Result pane: links are the only thing to hover (no diagnostics, no records there).
    if (ALICodeEditor_outLines) {
        ALICodeEditor_textarea.style.cursor = ALICodeEditor_outLinkAt(e) ? 'pointer' : '';
        return;
    }
    // record-var hover runs debounced whenever no diag tooltip claims the position
    if (ALICodeEditor_hoverTimer) clearTimeout(ALICodeEditor_hoverTimer);
    ALICodeEditor_hoverTimer = setTimeout(function () { ALICodeEditor_tryShowRecordHover(e); }, 300);
    if (!ALICodeEditor_diags.length) return;
    var rect = ALICodeEditor_textarea.getBoundingClientRect();
    var x = e.clientX - rect.left + ALICodeEditor_textarea.scrollLeft - 12;  // 12 = pre/textarea left padding
    var y = e.clientY - rect.top + ALICodeEditor_textarea.scrollTop - 10;    // 10 = top padding
    var line = Math.floor(y / 22) + 1;                                       // 22 = line-height
    var lines = ALICodeEditor_srcLines();
    var msgs = [];
    for (var i = 0; i < ALICodeEditor_diags.length; i++) {
        var d = ALICodeEditor_diags[i];
        if (d.line !== line || line < 1 || line > lines.length) continue;
        var text = lines[line - 1];
        var r = ALICodeEditor_diagRange(text, d);
        var x1 = ALICodeEditor_colOf(text, r.start) * ALICodeEditor_cellWidth();
        var x2 = ALICodeEditor_colOf(text, r.end) * ALICodeEditor_cellWidth();
        if (x2 <= x1) x2 = x1 + 9; // empty-line diag: give the space-wide span a hit zone
        if (x >= x1 - 3 && x <= x2 + 3) msgs.push(d.msg);
    }
    if (!msgs.length) { ALICodeEditor_hideErrorTip(); return; }
    ALICodeEditor_hideHoverTip(); // diag tooltip wins over the record-field hover
    var tip = ALICodeEditor_errorTip;
    tip.textContent = msgs.join('\n');
    tip.style.display = 'block';
    ALICodeEditor_placeTip(tip, e);
}
