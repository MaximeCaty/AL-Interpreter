// ALI Code Editor — part 5/5: DOM setup, key handling and the AL-callable entry points.
// Startup() and the Set* functions must stay global here: the client's method dispatch only
// sees functions defined in a file loaded through the controladdin's Scripts list.

// ── Auto-height ──────────────────────────────────────────────────────────────────────────
// BC sizes the add-in iframe from RequestedHeight, a fixed pixel value: on a page stacking two
// editors that overflows the viewport and BC draws a second, outer scrollbar around them. Same
// fix as the AI chat add-in (ECA AI/Addin/AI-Chat): measure the host window from inside the
// iframe and size the iframe ourselves. Every ALI editor iframe on the page tags itself, and
// one pass sizes them all — a sibling gets no resize event when we shrink this one.
var ALICodeEditor_fitMargin = 4;       // breathing room under the last pane
var ALICodeEditor_minPaneHeight = 120;

// Target pane height, from the panes' current rects. Panes sharing a top edge sit side by side
// on one row (the ALI Script Editor grid puts Source | Result on one row on a wide window, BC
// stacks them on a narrow one) and each get the full row height; rows split what is left.
// Captions and gaps between rows keep their size when the panes resize, so subtracting them
// once gives the exact answer in a single pass. Counting side-by-side panes as stacked made
// that "chrome" negative and each pass only closed half the gap: the editor crept down the
// page one watchdog tick at a time.
function ALICodeEditor_fitTarget(frames, viewportHeight) {
    var rows = [], top = Infinity, bottom = -Infinity, sum = 0, i, j, r;
    for (i = 0; i < frames.length; i++) {
        r = frames[i].getBoundingClientRect();
        if (r.top < top) top = r.top;
        if (r.bottom > bottom) bottom = r.bottom;
        for (j = 0; j < rows.length && Math.abs(rows[j].top - r.top) > 2; j++);
        if (j === rows.length) rows.push({ top: r.top, height: 0 });
        if (r.height > rows[j].height) rows[j].height = r.height;
    }
    for (j = 0; j < rows.length; j++) sum += rows[j].height;
    var chrome = (bottom - top) - sum;
    return Math.floor((viewportHeight - top - chrome - ALICodeEditor_fitMargin) / rows.length);
}

function ALICodeEditor_fitHeight() {
    if (!window.frameElement) return;
    var pwin, pdoc;
    try { pwin = window.parent; pdoc = pwin.document; } catch (e) { return; } // foreign origin: leave BC's sizing alone
    if (!pdoc) return;
    var frames = pdoc.querySelectorAll('iframe[data-ali-editor]');
    if (!frames.length) return;

    var h = ALICodeEditor_fitTarget(frames, pwin.innerHeight);
    if (h < ALICodeEditor_minPaneHeight) h = ALICodeEditor_minPaneHeight;

    for (i = 0; i < frames.length; i++) {
        // Already the right size: don't write, or the watchdog below would thrash the layout
        // (and kill smooth scrolling) 3 times a second for nothing.
        if (Math.abs(frames[i].getBoundingClientRect().height - h) <= 1) continue;
        frames[i].style.removeProperty('max-height');
        frames[i].style.removeProperty('min-height');
        frames[i].style.height = h + 'px';
        // BC also pins the wrapper around the iframe to RequestedHeight; follow it along, or the
        // grown iframe just overflows a box that stayed small. Only touched when BC really did
        // set an inline height there.
        var host = frames[i].parentElement;
        if (host && host.style && host.style.height) host.style.height = h + 'px';
    }
}

// The parent's `resize` event alone is not enough: it misses a drag to a second monitor (only the
// device pixel ratio changes), it fires before BC has finished re-laying out on a maximize /
// fullscreen switch, and it never fires at all when the add-in simply moves down or up the page
// because a field or a group above it appeared, was hidden, or wrapped onto another line.
// ponytail: a cheap poll beats chasing all of those with observers — fitHeight only reads a few
// rects and writes nothing unless the target height actually moved.
var ALICodeEditor_fitTimer = null;

function ALICodeEditor_startFitWatchdog() {
    if (ALICodeEditor_fitTimer) return;
    ALICodeEditor_fitTimer = setInterval(function () {
        ALICodeEditor_fitHeight();
        // Same reason, one layer down: the minimap's width condition and its viewport box both
        // depend on the pane's size, which render() has no way of hearing about.
        ALICodeEditor_updateMinimap();
    }, 300);
}

function ALICodeEditor_stopFitWatchdog() {
    if (!ALICodeEditor_fitTimer) return;
    clearInterval(ALICodeEditor_fitTimer);
    ALICodeEditor_fitTimer = null;
}

// ── Compile-status strip ─────────────────────────────────────────────────────────────────
// Driven entirely by signals that already exist: the textarea's input event, the TextChangedLong
// round-trip, and the SetDiagnostics answer. No extra add-in event.
var ALICodeEditor_statusBar = null;
var ALICodeEditor_lastStatus = 'idle';   // last compile outcome, restored when a flush sends nothing
var ALICodeEditor_lastStatusCount = 0;

function ALICodeEditor_setStatus(state, errorCount) {
    // Nothing here is compiled when the AL language is off (the Result pane): keep the strip out.
    if (!ALICodeEditor_alLanguage) return;
    if (state !== 'editing' && state !== 'compiling') {
        ALICodeEditor_lastStatus = state;
        ALICodeEditor_lastStatusCount = errorCount || 0;
    }
    var el = ALICodeEditor_statusBar;
    if (!el) return;
    // "Syntax", not "Compilation": the live check stops at the binder and only reads the
    // signatures of the objects a script calls — a full compile can still find more.
    var icon = '<span class="ali-status-ico">', text;
    switch (state) {
        case 'editing': text = icon + '🔄</span>Editing'; break;
        case 'compiling': text = '<span class="ali-spin"></span>Checking syntax...'; break;
        case 'fail': text = icon + '❌</span>Syntax error (' + errorCount + ' error' + (errorCount > 1 ? 's' : '') + ')'; break;
        case 'ok': text = icon + '✅</span>Syntax valid'; break;
        default: text = icon + '○</span>Ready'; break;
    }
    el.className = 'ali-status ali-status-on ali-status-' + state;
    el.innerHTML = text;
}

var ALICodeEditor_changeTimerLong = null;
function ALICodeEditor_notifyChangedLong() {
    if (ALICodeEditor_changeTimerLong) clearTimeout(ALICodeEditor_changeTimerLong);
    ALICodeEditor_changeTimerLong = setTimeout(ALICodeEditor_flushChanged, 1000); // typing pause
}

// Fire the compile round-trip now. Called by the debounce and on blur — the source has to reach
// AL before a ribbon action runs, and blur happens first when the user clicks one.
function ALICodeEditor_flushChanged() {
    if (ALICodeEditor_changeTimerLong) { clearTimeout(ALICodeEditor_changeTimerLong); ALICodeEditor_changeTimerLong = null; }
    // A read-only editor is a viewer (the Result pane): it has no source to hand back, and the
    // page declares no TextChangedLong trigger on it — the event would just be dropped, leaving
    // the strip waiting for an answer that never comes.
    if (ALICodeEditor_textarea.readOnly) return;
    if (!(window.Microsoft && Microsoft.Dynamics && Microsoft.Dynamics.NAV &&
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod)) return;
    // Nothing to compile (edit reverted to the sent text): put the last outcome back, otherwise
    // the strip would stay on "Editing" with no round-trip coming to clear it.
    if (ALICodeEditor_textarea.value === ALICodeEditor_lastSentText) {
        ALICodeEditor_setStatus(ALICodeEditor_lastStatus, ALICodeEditor_lastStatusCount);
        return;
    }
    ALICodeEditor_lastSentText = ALICodeEditor_textarea.value;
    ALICodeEditor_setStatus('compiling');
    // The tab id lets AL drop a text typed into the previous tab's buffer while a tab switch was
    // still on its way back: taken as is, it would overwrite the newly active tab.
    Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('TextChangedLong',
        [ALICodeEditor_textarea.value, ALICodeEditor_bufferTabId], true);
}
var ALICodeEditor_lastSentText = null;

function ALICodeEditor_notifyChanged() {
    ALICodeEditor_notifyChangedLong();
}

function ALICodeEditor_onKeyDown(e) {
    // Toolbar shortcuts. Ctrl was unbound here before; both are no-ops on the Result pane,
    // which carries no chrome to drive.
    if (ALICodeEditor_alLanguage) {
        if (e.key === 'F5') { e.preventDefault(); ALICodeEditor_runCommand(e.ctrlKey ? 'forcerun' : 'run'); return; }
        if ((e.ctrlKey || e.metaKey) && (e.key === 's' || e.key === 'S')) { e.preventDefault(); ALICodeEditor_runCommand('save'); return; }
    }

    if (ALICodeEditor_suggestVisible()) {
        if (e.key === 'ArrowDown') {
            e.preventDefault();
            ALICodeEditor_suggestIndex = (ALICodeEditor_suggestIndex + 1) % ALICodeEditor_suggestItems.length;
            ALICodeEditor_highlightSuggest();
            return;
        }
        if (e.key === 'ArrowUp') {
            e.preventDefault();
            ALICodeEditor_suggestIndex = (ALICodeEditor_suggestIndex - 1 + ALICodeEditor_suggestItems.length) % ALICodeEditor_suggestItems.length;
            ALICodeEditor_highlightSuggest();
            return;
        }
        if (e.key === 'Enter' || e.key === 'Tab') {
            e.preventDefault();
            ALICodeEditor_acceptSuggest();
            return;
        }
        if (e.key === 'Escape') {
            e.preventDefault();
            ALICodeEditor_hideSuggest();
            return;
        }
    }

    if (e.key === 'Tab') {
        e.preventDefault();
        var start = ALICodeEditor_textarea.selectionStart;
        var end = ALICodeEditor_textarea.selectionEnd;
        var val = ALICodeEditor_textarea.value;

        var multiline = start !== end && val.slice(start, end).indexOf('\n') !== -1;

        if (multiline) {
            var selLineStart = val.lastIndexOf('\n', start - 1) + 1;
            var endLineStart = val.lastIndexOf('\n', end - 1) + 1;
            var blockEnd = (end === endLineStart) ? end - 1 : end;
            var lines = val.slice(selLineStart, blockEnd).split('\n');

            if (e.shiftKey) {
                var totalRemoved = 0, firstRemoved = 0;
                var newLines = lines.map(function (l, idx) {
                    var removed = 0;
                    if (l[0] === '\t') removed = 1;
                    else { var m = l.match(/^ {1,4}/); if (m) removed = m[0].length; }
                    if (idx === 0) firstRemoved = removed;
                    totalRemoved += removed;
                    return l.slice(removed);
                });
                ALICodeEditor_textarea.value = val.slice(0, selLineStart) + newLines.join('\n') + val.slice(blockEnd);
                ALICodeEditor_textarea.selectionStart = Math.max(selLineStart, start - firstRemoved);
                ALICodeEditor_textarea.selectionEnd = Math.max(selLineStart, end - totalRemoved);
            } else {
                var indented = lines.map(function (l) { return '\t' + l; }).join('\n');
                ALICodeEditor_textarea.value = val.slice(0, selLineStart) + indented + val.slice(blockEnd);
                ALICodeEditor_textarea.selectionStart = start + 1;
                ALICodeEditor_textarea.selectionEnd = end + lines.length;
            }
        } else if (e.shiftKey) {
            var lineStart = val.lastIndexOf('\n', start - 1) + 1;
            var removed = 0;
            if (val.slice(lineStart, lineStart + 1) === '\t') {
                removed = 1;
            } else {
                var m = val.slice(lineStart, lineStart + 4).match(/^ +/);
                if (m) removed = m[0].length;
            }
            if (removed > 0) {
                ALICodeEditor_textarea.value = val.slice(0, lineStart) + val.slice(lineStart + removed);
                ALICodeEditor_textarea.selectionStart = Math.max(lineStart, start - removed);
                ALICodeEditor_textarea.selectionEnd = Math.max(lineStart, end - removed);
            }
        } else {
            ALICodeEditor_textarea.value = val.slice(0, start) + '\t' + val.slice(end);
            ALICodeEditor_textarea.selectionStart = ALICodeEditor_textarea.selectionEnd = start + 1;
        }
        ALICodeEditor_render();
        ALICodeEditor_scrollCaretIntoView();
        ALICodeEditor_notifyChanged();
        return;
    }

    if (e.key === 'Enter') {
        var start = ALICodeEditor_textarea.selectionStart;
        var end = ALICodeEditor_textarea.selectionEnd;
        var val = ALICodeEditor_textarea.value;
        var indent = ALICodeEditor_currentLineIndent(val, start).replace(/ {1,4}/g, '\t');

        var lineStart = val.lastIndexOf('\n', start - 1) + 1;
        var lineSoFar = val.slice(lineStart, start).trim();
        if (/\b(var|begin|do|then|else|repeat)$/i.test(lineSoFar)) {
            indent += '\t';
        }

        e.preventDefault();
        var insert = '\n' + indent;
        ALICodeEditor_textarea.value = val.slice(0, start) + insert + val.slice(end);
        ALICodeEditor_textarea.selectionStart = ALICodeEditor_textarea.selectionEnd = start + insert.length;
        ALICodeEditor_render();
        ALICodeEditor_scrollCaretIntoView();
        ALICodeEditor_notifyChanged();
    }
}

function Startup() {
    var root = document.getElementById('controlAddIn');
    // The textarea is the only real content; the painted layers (gutter, coloring, squiggles,
    // minimap, measuring mirror) are aria-hidden so they stay out of the accessibility tree —
    // thousands of spans Chrome would otherwise mirror to the browser process on every edit.
    root.innerHTML =
        '<div id="aliToolbar" class="ali-toolbar"></div>' +
        '<div id="aliTabs" class="ali-tabs"></div>' +
        '<div id="aliPanels" class="ali-panels"></div>' +
        '<div id="aliStatus" class="ali-status"></div>' +
        '<div class="ali-editor">' +
        '<div id="aliGutter" class="ali-gutter" aria-hidden="true">1</div>' +
        '<pre id="aliHighlight" aria-hidden="true"><code id="aliHighlightCode"></code></pre>' +
        '<pre id="aliErrors" class="ali-errors" aria-hidden="true"></pre>' +
        '<textarea id="aliInput" spellcheck="false" autocapitalize="off" autocomplete="off"></textarea>' +
        '<div id="aliMinimap" class="ali-minimap" aria-hidden="true">' +
        '<pre id="aliMinimapCode"></pre>' +
        '<div id="aliMinimapSlider" class="ali-minimap-slider"></div>' +
        '</div>' +
        '<div id="aliSuggest" class="ali-suggest"></div>' +
        '<div id="aliErrTip" class="ali-errtip"></div>' +
        '<div id="aliHoverTip" class="ali-hovertip"></div>' +
        '<pre id="aliMirror" class="ali-mirror" aria-hidden="true"></pre>' +
        '</div>';

    ALICodeEditor_editorRoot = root.querySelector('.ali-editor');
    ALICodeEditor_statusBar = document.getElementById('aliStatus');
    ALICodeEditor_textarea = document.getElementById('aliInput');
    ALICodeEditor_highlightCode = document.getElementById('aliHighlightCode');
    ALICodeEditor_highlightPre = document.getElementById('aliHighlight');
    ALICodeEditor_gutter = document.getElementById('aliGutter');
    ALICodeEditor_suggestBox = document.getElementById('aliSuggest');
    ALICodeEditor_errorLayer = document.getElementById('aliErrors');
    ALICodeEditor_errorTip = document.getElementById('aliErrTip');
    ALICodeEditor_hoverTip = document.getElementById('aliHoverTip');
    ALICodeEditor_mirror = document.getElementById('aliMirror');
    ALICodeEditor_minimap = document.getElementById('aliMinimap');
    ALICodeEditor_minimapInner = document.getElementById('aliMinimapCode');
    ALICodeEditor_minimapSlider = document.getElementById('aliMinimapSlider');
    ALICodeEditor_bindMinimap();
    ALICodeEditor_initChrome();
    ALICodeEditor_panelBar = document.getElementById('aliPanels');
    ALICodeEditor_panelBar.addEventListener('mousedown', function (e) { e.preventDefault(); });
    ALICodeEditor_panelBar.addEventListener('click', function (e) {
        var tab = ALICodeEditor_closestEl(e.target, 'ali-panel-tab');
        if (tab && ALICodeEditor_panels && ALICodeEditor_panels.shown !== tab.getAttribute('data-panel'))
            ALICodeEditor_selectPanel(tab.getAttribute('data-panel'));
    });

    ALICodeEditor_textarea.addEventListener('input', function () {
        ALICodeEditor_clearDiags(); // positions are stale after any edit
        ALICodeEditor_setStatus('editing');
        ALICodeEditor_render();
        ALICodeEditor_updateSuggest();
        ALICodeEditor_notifyChanged();
    });
    ALICodeEditor_textarea.addEventListener('scroll', ALICodeEditor_syncScroll);
    ALICodeEditor_textarea.addEventListener('keydown', ALICodeEditor_onKeyDown);
    // Blur: hide the dropdown ONLY when focus left the editor entirely — clicking the
    // dropdown's scrollbar or its search input must not close it (deferred check: focus
    // lands after blur fires).
    ALICodeEditor_textarea.addEventListener('blur', function () {
        // The 1 s debounce is the only channel that hands the source to AL, so any pending edit
        // has to be flushed before a ribbon action can run against a stale SourceCode.
        ALICodeEditor_flushChanged();
        setTimeout(function () {
            if (ALICodeEditor_suggestBox.contains(document.activeElement)) return;
            ALICodeEditor_hideSuggest();
        }, 0);
    });
    ALICodeEditor_textarea.addEventListener('mousedown', ALICodeEditor_hideSuggest);
    // Scrollbar clicks inside the dropdown: keep the caret in the textarea (preventDefault)
    // unless the click targets the search input, which needs real focus to type into.
    ALICodeEditor_suggestBox.addEventListener('mousedown', function (e) {
        if (e.target && e.target.tagName === 'INPUT') return;
        e.preventDefault();
    });
    ALICodeEditor_textarea.addEventListener('mousemove', ALICodeEditor_onMouseMove);
    // Result pane link: AL relays it to the source pane (each add-in is its own iframe). A click
    // that ends a drag-selection is the user copying text, not following the link.
    ALICodeEditor_textarea.addEventListener('click', function (e) {
        var st = ALICodeEditor_outLinkAt(e);
        if (!st || ALICodeEditor_textarea.selectionStart !== ALICodeEditor_textarea.selectionEnd) return;
        if (window.Microsoft && Microsoft.Dynamics && Microsoft.Dynamics.NAV &&
            Microsoft.Dynamics.NAV.InvokeExtensibilityMethod)
            Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('GotoLocation', [st.ln, st.col]);
    });
    ALICodeEditor_textarea.addEventListener('mouseleave', function (e) {
        ALICodeEditor_hideErrorTip();
        // moving INTO the hover tip (to scroll/search it) must not close it
        if (e.relatedTarget && ALICodeEditor_hoverTip && ALICodeEditor_hoverTip.contains(e.relatedTarget)) {
            if (ALICodeEditor_hoverTimer) { clearTimeout(ALICodeEditor_hoverTimer); ALICodeEditor_hoverTimer = null; }
            return;
        }
        ALICodeEditor_hideHoverTip();
    });
    // leaving the hover tip itself closes it (re-entering the textarea re-triggers it)
    ALICodeEditor_hoverTip.addEventListener('mouseleave', function (e) {
        if (e.relatedTarget && e.relatedTarget.tagName === 'INPUT' && ALICodeEditor_hoverTip.contains(e.relatedTarget)) return;
        ALICodeEditor_hideHoverTip();
    });
    ALICodeEditor_hoverTip.addEventListener('mouseenter', function () {
        if (ALICodeEditor_hoverTimer) { clearTimeout(ALICodeEditor_hoverTimer); ALICodeEditor_hoverTimer = null; }
    });

    ALICodeEditor_render();

    // Tag this iframe so every ALI editor on the page is sized in one pass, then fit. The parent's
    // resize event keeps the panes glued to the window while it is being dragged; the watchdog
    // covers everything resize does not report (see above), including BC's own late layout right
    // after the add-in loads, when the second editor may not even be in the DOM yet.
    if (window.frameElement) {
        window.frameElement.setAttribute('data-ali-editor', '1');
        try {
            window.parent.addEventListener('resize', ALICodeEditor_fitHeight);
            // BC is an SPA: drop the parent listener and the timer with the iframe, or they pile
            // up on navigation.
            window.addEventListener('beforeunload', function () {
                ALICodeEditor_stopFitWatchdog();
                try { window.parent.removeEventListener('resize', ALICodeEditor_fitHeight); } catch (e) { /* gone already */ }
            });
        } catch (e) { /* foreign origin: no auto-height */ }
        ALICodeEditor_fitHeight();
        ALICodeEditor_startFitWatchdog();
    }

    ALICodeEditor_ready = true;
    while (ALICodeEditor_pending.length) ALICodeEditor_pending.shift()();

    if (window.Microsoft && Microsoft.Dynamics && Microsoft.Dynamics.NAV &&
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod) {
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('ControlAddInReady', []);
    }
}

// ── Output / Problems panels (Result pane) ───────────────────────────────────────────────
// VS Code's panel header over the one read-only textarea. Both texts live here and a panel
// switch just swaps the textarea's content — no AL round trip. AL decides which panel comes to
// the front after a run (ShowPanel); the user's own clicks stay client-side.
var ALICodeEditor_panelBar = null;
var ALICodeEditor_panels = null;   // null until the first ShowPanel: the source pane never has panels

function ALICodeEditor_ensurePanels() {
    if (ALICodeEditor_panels) return ALICodeEditor_panels;
    ALICodeEditor_panels = {
        active: 'output', shown: null, output: '', problems: ALICodeEditor_problemsText([]),
        count: 0, errors: 0, scroll: {}
    };
    ALICodeEditor_panelBar.classList.add('ali-on');
    return ALICodeEditor_panels;
}

function ALICodeEditor_selectPanel(name) {
    var p = ALICodeEditor_ensurePanels();
    if (name !== 'problems') name = 'output';
    if (p.shown && p.shown !== name) p.scroll[p.shown] = ALICodeEditor_textarea.scrollTop;
    p.active = p.shown = name;
    ALICodeEditor_setBuffer(p[name]);
    ALICodeEditor_textarea.scrollTop = p.scroll[name] || 0;
    ALICodeEditor_syncScroll();
    ALICodeEditor_renderPanelBar();
}

function ALICodeEditor_renderPanelBar() {
    var p = ALICodeEditor_panels;
    ALICodeEditor_panelBar.innerHTML =
        '<div class="ali-panel-tab' + (p.active === 'output' ? ' ali-panel-active' : '') + '" data-panel="output">Output</div>' +
        '<div class="ali-panel-tab' + (p.active === 'problems' ? ' ali-panel-active' : '') + '" data-panel="problems">Problems' +
        (p.count ? '<span class="ali-panel-badge' + (p.errors ? ' ali-panel-badge-err' : '') + '">' + p.count + '</span>' : '') +
        '</div>';
}

// Diagnostics as styled Result lines (same <SOH>Style@line,col<STX> markers the page writes for
// Output), sorted by position, in fixed columns: severity, location, message. A located line is
// a link to the source like any other Result line.
function ALICodeEditor_problemsText(diags) {
    if (!diags.length) return '\x01Dim\x02No problems have been detected.';
    function pad(s, n) { while (s.length < n) s += ' '; return s; }
    return diags.slice().sort(function (a, b) { return (a.line - b.line) || (a.col - b.col); })
        .map(function (d) {
            var sev = d.sev === 2 ? 'Error' : (d.sev === 1 ? 'Warning' : 'Info');
            var col = d.col || 1;
            return '\x01' + sev + (d.line > 0 ? '@' + d.line + ',' + col : '') + '\x02' +
                pad(sev, 9) + pad(d.line > 0 ? 'Ln ' + d.line + ', Col ' + col : '', 17) + (d.msg || '');
        }).join('\n');
}

// The textarea's content, styled when it carries line markers. Every text shown in the add-in
// goes through here — SetText, and a panel switch on the Result pane.
function ALICodeEditor_setBuffer(text) {
    text = text || '';
    // Styled output (Result pane) carries line markers; anything else is shown as sent.
    if (text.indexOf('\x01') !== -1) text = ALICodeEditor_parseOut(text);
    else ALICodeEditor_outLines = null;
    ALICodeEditor_textarea.value = text;
    ALICodeEditor_textarea.style.cursor = '';
    ALICodeEditor_lastRendered = null; // same text may come back with other styles
    ALICodeEditor_hideSuggest();
    ALICodeEditor_clearDiags();
    ALICodeEditor_render();
}

// Source pane: the buffer. Result pane with panels on: the Output panel's text (shown only when
// that panel is in front), scrolled back to the top since it is a new run.
function SetText(text) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetText(text); }); return; }
    var p = ALICodeEditor_panels;
    if (!p) {
        // AL holds exactly this text now. An edit still waiting on the debounce belonged to the
        // buffer being replaced (often another tab's): sending it later would land on this one.
        if (ALICodeEditor_changeTimerLong) {
            clearTimeout(ALICodeEditor_changeTimerLong);
            ALICodeEditor_changeTimerLong = null;
            ALICodeEditor_setStatus(ALICodeEditor_lastStatus, ALICodeEditor_lastStatusCount);
        }
        ALICodeEditor_setBuffer(text);
        ALICodeEditor_lastSentText = ALICodeEditor_textarea.value; // read back: the textarea LF-normalizes
        return;
    }
    p.output = text || '';
    p.scroll.output = 0;
    if (p.active === 'output') ALICodeEditor_selectPanel('output');
}

// Diagnostics JSON (same shape as SetDiagnostics) for the Problems panel.
function SetProblems(diagJson) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetProblems(diagJson); }); return; }
    var diags, p = ALICodeEditor_ensurePanels(), i;
    try { diags = diagJson ? JSON.parse(diagJson) : []; } catch (e) { diags = []; }
    if (!(diags instanceof Array)) diags = [];
    p.problems = ALICodeEditor_problemsText(diags);
    p.count = diags.length;
    p.errors = 0;
    for (i = 0; i < diags.length; i++) if (diags[i].sev === 2) p.errors++;
    p.scroll.problems = 0;
    if (p.active === 'problems') ALICodeEditor_selectPanel('problems');
    else ALICodeEditor_renderPanelBar();
}

function ShowPanel(panel) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { ShowPanel(panel); }); return; }
    ALICodeEditor_selectPanel(panel);
}

function SetRunMode(simulation) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetRunMode(simulation); }); return; }
    ALICodeEditor_applyRunMode(simulation);
}

// Answer to a Result pane link, relayed by the page: select the token at (line, col), 1-based,
// and bring it into view. Selecting the token rather than parking a caret makes the spot visible.
function GotoLine(line, col) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { GotoLine(line, col); }); return; }
    var lines = ALICodeEditor_srcLines(), pos = 0;
    line = Math.min(Math.max(1, line), lines.length);
    for (var i = 0; i < line - 1; i++) pos += lines[i].length + 1;
    var r = ALICodeEditor_diagRange(lines[line - 1], { col: col, len: 0 });
    ALICodeEditor_textarea.focus();
    ALICodeEditor_textarea.setSelectionRange(pos + r.start, pos + r.end);
    ALICodeEditor_scrollCaretIntoView();
}

function SetDiagnostics(diagJson) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetDiagnostics(diagJson); }); return; }
    try { ALICodeEditor_diags = diagJson ? JSON.parse(diagJson) : []; }
    catch (e) { ALICodeEditor_diags = []; }
    if (!(ALICodeEditor_diags instanceof Array)) ALICodeEditor_diags = [];
    ALICodeEditor_renderErrors();
    ALICodeEditor_hideErrorTip();

    // Same call doubles as the compile-finished signal for the status strip (sev 2 = error;
    // warnings alone still count as a successful compile).
    var errors = 0;
    for (var i = 0; i < ALICodeEditor_diags.length; i++)
        if (ALICodeEditor_diags[i].sev === 2) errors++;
    ALICodeEditor_setStatus(errors ? 'fail' : 'ok', errors);
}

function SetReadOnly(readOnly) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetReadOnly(readOnly); }); return; }
    ALICodeEditor_textarea.readOnly = !!readOnly;
    ALICodeEditor_textarea.classList.toggle('ali-readonly', !!readOnly);
    if (readOnly) ALICodeEditor_hideSuggest();
}

// Whether the Run menu offers "Preprocessor directives...". Off in a cloud build: the page it
// opens does not exist there, and project-level symbols only ever applied to the AL source of a
// PUBLISHED object, which a cloud installation cannot read.
function SetPreprocAvailable(available) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetPreprocAvailable(available); }); return; }
    ALICodeEditor_preprocAvailable = !!available;
}

// Master AL-language switch: syntax coloring + autocompletion + record hover.
// OFF = plain monospace viewer (Result pane shows raw output, not AL source).
function SetALLanguage(enabled) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetALLanguage(enabled); }); return; }
    ALICodeEditor_alLanguage = !!enabled;
    // The status strip only means something where code is compiled, so it rides on this switch:
    // on for the AL source pane, off for the plain result viewer.
    if (ALICodeEditor_statusBar) {
        if (ALICodeEditor_alLanguage)
            ALICodeEditor_setStatus(ALICodeEditor_lastStatus, ALICodeEditor_lastStatusCount);
        else
            ALICodeEditor_statusBar.className = 'ali-status';
    }
    // Toolbar and tab strip are source-pane furniture and ride on the same switch.
    ALICodeEditor_showChrome(ALICodeEditor_alLanguage);
    if (!ALICodeEditor_alLanguage) { ALICodeEditor_hideSuggest(); ALICodeEditor_hideHoverTip(); }
    ALICodeEditor_lastRendered = null; // coloring changed, not the text
    ALICodeEditor_render();
    ALICodeEditor_updateMinimap();     // the map is source-pane only, so it follows this switch
}

// Interpreter API catalog from "ALI Api Catalog".BuildCatalogJson(). Also refreshes the
// syntax-highlight type/builtin sets so coloring matches the interpreter's real surface.
function SetApiCatalog(catalogJson) {
    try { ALICodeEditor_catalog = catalogJson ? JSON.parse(catalogJson) : null; }
    catch (e) { ALICodeEditor_catalog = null; }
    ALICodeEditor_rebuildTypeCanon();
    ALICodeEditor_lastRendered = null; // coloring changed, not the text
    if (ALICodeEditor_ready) ALICodeEditor_render();
}

// All table names: [{n, id}] — for `MyRec: Record <completion>`.
function SetTableList(tablesJson) {
    try { ALICodeEditor_tables = tablesJson ? JSON.parse(tablesJson) : []; }
    catch (e) { ALICodeEditor_tables = []; }
    if (!(ALICodeEditor_tables instanceof Array)) ALICodeEditor_tables = [];
}

// All codeunit names: [{n, id}] — for `MyCU: Codeunit <completion>`.
function SetCodeunitList(codeunitsJson) {
    try { ALICodeEditor_codeunits = codeunitsJson ? JSON.parse(codeunitsJson) : []; }
    catch (e) { ALICodeEditor_codeunits = []; }
    if (!(ALICodeEditor_codeunits instanceof Array)) ALICodeEditor_codeunits = [];
}

// All enum names: [{n, id}] — for `MyEnum: Enum <completion>`.
function SetEnumList(enumsJson) {
    try { ALICodeEditor_enums = enumsJson ? JSON.parse(enumsJson) : []; }
    catch (e) { ALICodeEditor_enums = []; }
    if (!(ALICodeEditor_enums instanceof Array)) ALICodeEditor_enums = [];
}

// Answer to the RequestObjectMembers event: cache + resume the waiting suggest/hover.
// objType is 'Table' or 'Codeunit' — same key space as ALICodeEditor_membersOf builds.
function SetObjectMembers(objType, objName, membersJson) {
    var fields;
    try { fields = membersJson ? JSON.parse(membersJson) : []; }
    catch (e) { fields = []; }
    if (!(fields instanceof Array)) fields = [];
    var key = objType + ':' + (objName || '').toUpperCase();
    ALICodeEditor_objMembers[key] = fields;
    var ctx = ALICodeEditor_pendingFieldCtx;
    if (!ctx || ctx.key !== key) return;
    ALICodeEditor_pendingFieldCtx = null;
    if (ctx.kind === 'suggest') ALICodeEditor_updateSuggest();
    else if (ctx.kind === 'hover' && ctx.event) ALICodeEditor_tryShowRecordHover(ctx.event);
}

// Full tab-strip state from the page: [{n, d, a}], array position = tab index. AL owns this
// list; the add-in only draws it and reports clicks back through EditorCommand.
function SetTabs(tabsJson) {
    if (!ALICodeEditor_ready) { ALICodeEditor_pending.push(function () { SetTabs(tabsJson); }); return; }
    try { ALICodeEditor_tabs = tabsJson ? JSON.parse(tabsJson) : []; }
    catch (e) { ALICodeEditor_tabs = []; }
    if (!(ALICodeEditor_tabs instanceof Array)) ALICodeEditor_tabs = [];
    // AL sends a switched tab's SetText before its SetTabs, so the textarea holds the active
    // tab's text from here on: stamp it.
    var act = ALICodeEditor_activeTab();
    ALICodeEditor_bufferTabId = act >= 0 ? (ALICodeEditor_tabs[act].id || 0) : 0;
    ALICodeEditor_renderTabs();
}
