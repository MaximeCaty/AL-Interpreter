// ALI Code Editor — part 6/6: the add-in's own chrome (VS Code-style toolbar + tab strip).
// Both live OUTSIDE .ali-editor for the same reason the status strip does: every overlay inside
// that box is absolutely positioned against it, so leaving it untouched keeps all the caret/line
// coordinate math unchanged.
//
// AL is the source of truth for the tabs: this file renders whatever SetTabs() last sent and
// pushes user intent back through the single EditorCommand event. It never holds buffer text —
// the editor is strictly single-buffer (one textarea, one diag set, one member cache), and the
// AL page swaps the record behind it on a tab change.

var ALICodeEditor_toolbar = null;
var ALICodeEditor_tabStrip = null;
var ALICodeEditor_tabs = [];        // [{n, d, a, id}] — n '' means an unsaved tab
var ALICodeEditor_bufferTabId = 0;  // id of the tab whose text the textarea holds (see SetTabs)
var ALICodeEditor_menu = null;      // the one open dropdown, or null
var ALICodeEditor_renaming = false; // an inline tab-rename input is on screen
var ALICodeEditor_simulation = true; // exec mode from SetRunMode: true = writes rolled back
var ALICodeEditor_preprocAvailable = true; // SetPreprocAvailable: off in a cloud build (no source to apply symbols to)

// Every toolbar/tab action reaches AL through this one event; the Result pane declares no
// trigger for it, hence skipIfNotDefined = true.
function ALICodeEditor_invoke(cmd, arg) {
    if (!(window.Microsoft && Microsoft.Dynamics && Microsoft.Dynamics.NAV &&
        Microsoft.Dynamics.NAV.InvokeExtensibilityMethod)) return;
    Microsoft.Dynamics.NAV.InvokeExtensibilityMethod('EditorCommand', [cmd, String(arg === undefined ? '' : arg)], true);
}

// Run, Save, and any tab switch act on the source, and the 1 s debounce is the only channel
// carrying it to AL. Two InvokeExtensibilityMethod calls keep their order, so flushing first is
// enough — the same assumption the blur -> ribbon path already relied on.
function ALICodeEditor_invokeOnSource(cmd, arg) {
    ALICodeEditor_flushChanged();
    ALICodeEditor_invoke(cmd, arg);
}

function ALICodeEditor_activeTab() {
    for (var i = 0; i < ALICodeEditor_tabs.length; i++)
        if (ALICodeEditor_tabs[i].a) return i;
    return -1;
}

function ALICodeEditor_tabCaption(tab, index) {
    return tab.n || ('Untitled-' + (index + 1) + '*'); // '*': never saved (named tabs autosave)
}

// ── Dropdown menus ───────────────────────────────────────────────────────────────────────
function ALICodeEditor_closeMenu() {
    if (!ALICodeEditor_menu) return;
    if (ALICodeEditor_menu.el.parentNode) ALICodeEditor_menu.el.parentNode.removeChild(ALICodeEditor_menu.el);
    if (ALICodeEditor_menu.owner) ALICodeEditor_menu.owner.classList.remove('ali-tb-btn-open');
    ALICodeEditor_menu = null;
}

// items: [{label, cmd, key, icon, toggle}] — a null entry draws a separator. `icon` is a short
// glyph shown in a left column (kept for every row once any row has one, so labels line up);
// `toggle` (true/false) draws a switch instead of the shortcut, and clicking that row flips it
// without closing the menu. The menu opens under `anchor` (default: the owner button).
function ALICodeEditor_openMenuAt(owner, items, anchor) {
    var reopen = ALICodeEditor_menu && ALICodeEditor_menu.owner === owner;
    ALICodeEditor_closeMenu();
    if (reopen) return; // second click on the same button just closes it

    var el = document.createElement('div');
    el.className = 'ali-menu';
    el.innerHTML = ALICodeEditor_menuHtml(items);
    var r = (anchor || owner).getBoundingClientRect();
    el.style.left = Math.round(r.left) + 'px';
    el.style.top = Math.round(r.bottom + 2) + 'px';
    document.body.appendChild(el);
    owner.classList.add('ali-tb-btn-open');
    ALICodeEditor_menu = { el: el, owner: owner };

    el.addEventListener('mousedown', function (e) { e.preventDefault(); });
    el.addEventListener('click', function (e) {
        var item = ALICodeEditor_closestEl(e.target, 'ali-menu-item');
        if (!item) return;
        var cmd = item.getAttribute('data-cmd');
        if (item.classList.contains('ali-menu-toggle')) { ALICodeEditor_runCommand(cmd); return; }
        ALICodeEditor_closeMenu();
        ALICodeEditor_runCommand(cmd);
    });
}

function ALICodeEditor_menuHtml(items) {
    var html = '', i, it, icons = false;
    for (i = 0; i < items.length; i++) if (items[i] && items[i].icon) icons = true;
    for (i = 0; i < items.length; i++) {
        it = items[i];
        if (!it) { html += '<div class="ali-menu-sep"></div>'; continue; }
        var isToggle = typeof it.toggle === 'boolean';
        html += '<div class="ali-menu-item' + (isToggle ? ' ali-menu-toggle' : '') + '" data-cmd="' + it.cmd + '">' +
            (icons ? '<span class="ali-menu-ico">' + ALICodeEditor_escapeHtml(it.icon || '') + '</span>' : '') +
            '<span class="ali-menu-label">' + ALICodeEditor_escapeHtml(it.label) + '</span>' +
            (isToggle ?
                '<span class="ali-switch' + (it.toggle ? ' ali-switch-on' : '') + '"></span>' :
                '<span class="ali-menu-key">' + ALICodeEditor_escapeHtml(it.key || '') + '</span>') +
            '</div>';
    }
    return html;
}

// Run button + run menu switch follow the exec mode: green triangle in Simulation (writes rolled
// back), red in Normal (writes committed). Called by SetRunMode and optimistically by the switch.
function ALICodeEditor_applyRunMode(simulation) {
    ALICodeEditor_simulation = !!simulation;
    if (!ALICodeEditor_toolbar || !ALICodeEditor_toolbar.querySelector) return;
    var run = ALICodeEditor_toolbar.querySelector('.ali-tb-run');
    if (run) {
        run.classList.toggle('ali-tb-run-normal', !ALICodeEditor_simulation);
        run.title = ALICodeEditor_simulation ?
            'Compile and run (F5) — Simulation mode: database writes are rolled back' :
            'Compile and run (F5) — Normal mode: database writes are COMMITTED';
    }
    var sw = ALICodeEditor_menu && ALICodeEditor_menu.el.querySelector('.ali-menu-toggle[data-cmd="simulation"] .ali-switch');
    if (sw) sw.classList.toggle('ali-switch-on', ALICodeEditor_simulation);
}

// Element.closest is not on the oldest clients BC still runs in; walk up by class instead.
function ALICodeEditor_closestEl(node, cls) {
    while (node && node !== document) {
        if (node.classList && node.classList.contains(cls)) return node;
        node = node.parentNode;
    }
    return null;
}

// ── Command dispatch ─────────────────────────────────────────────────────────────────────
// 'save' and 'rename' on an unnamed tab both mean the same thing: give it a name. That is done
// inline on the tab rather than through an AL dialog page — no extra page, and window.prompt is
// unavailable in the add-in's sandboxed iframe.
function ALICodeEditor_runCommand(cmd) {
    var active = ALICodeEditor_activeTab();
    switch (cmd) {
        case 'new':
        case 'open':
        case 'options':
        case 'preproc':
            ALICodeEditor_invokeOnSource(cmd, '');
            break;
        case 'close':
            if (active >= 0) ALICodeEditor_invokeOnSource('close', active);
            break;
        case 'rename':
            if (active >= 0) ALICodeEditor_startRename(active);
            break;
        case 'save':
            if (active >= 0 && !ALICodeEditor_tabs[active].n) { ALICodeEditor_startRename(active); break; }
            ALICodeEditor_invokeOnSource('save', '');
            break;
        case 'run':
        case 'forcerun':
            ALICodeEditor_invokeOnSource(cmd, '');
            break;
        case 'simulation':
            // Flipped here right away; AL answers with SetRunMode, which settles it either way.
            ALICodeEditor_applyRunMode(!ALICodeEditor_simulation);
            ALICodeEditor_invoke('simulation', ALICodeEditor_simulation ? '1' : '0');
            break;
    }
}

// ── Inline tab rename ────────────────────────────────────────────────────────────────────
function ALICodeEditor_startRename(index) {
    var tab = ALICodeEditor_tabStrip.querySelector('.ali-tab[data-i="' + index + '"]');
    if (!tab) return;
    var label = tab.querySelector('.ali-tab-label');
    if (!label) return;
    ALICodeEditor_renaming = true;

    var input = document.createElement('input');
    input.className = 'ali-tab-input';
    input.type = 'text';
    input.maxLength = 50;                        // "ALI Stored Script".Name is Text[50]
    input.value = ALICodeEditor_tabs[index].n || '';
    label.parentNode.replaceChild(input, label);
    input.focus();
    input.select();

    var done = false;
    function commit(apply) {
        if (done) return;
        done = true;
        ALICodeEditor_renaming = false;
        var name = input.value.replace(/^\s+|\s+$/g, '');
        // Re-render from the state AL last sent: that puts the old label back, and the answer to
        // a successful rename arrives as a fresh SetTabs anyway.
        ALICodeEditor_renderTabs();
        if (apply && name && name !== (ALICodeEditor_tabs[index].n || ''))
            ALICodeEditor_invokeOnSource('rename', name);
    }
    input.addEventListener('keydown', function (e) {
        e.stopPropagation();
        if (e.key === 'Enter') { e.preventDefault(); commit(true); }
        else if (e.key === 'Escape') { e.preventDefault(); commit(false); }
    });
    input.addEventListener('blur', function () { commit(true); });
    input.addEventListener('mousedown', function (e) { e.stopPropagation(); });
    input.addEventListener('dblclick', function (e) { e.stopPropagation(); });
}

// ── Rendering ────────────────────────────────────────────────────────────────────────────
function ALICodeEditor_renderTabs() {
    if (!ALICodeEditor_tabStrip) return;
    var html = '', i, t;
    for (i = 0; i < ALICodeEditor_tabs.length; i++) {
        t = ALICodeEditor_tabs[i];
        html += '<div class="ali-tab' + (t.a ? ' ali-tab-active' : '') + '" data-i="' + i + '"' +
            (t.d ? ' title="' + ALICodeEditor_escapeHtml(t.d) + '"' : '') + '>' +
            '<span class="ali-tab-label">' + ALICodeEditor_escapeHtml(ALICodeEditor_tabCaption(t, i)) + '</span>' +
            '<span class="ali-tab-x" data-close="' + i + '" title="Close">&#10005;</span>' +
            '</div>';
    }
    html += '<div class="ali-tab-add" data-add="1" title="New or open a script">&#43;</div>';
    ALICodeEditor_tabStrip.innerHTML = html;

    var act = ALICodeEditor_tabStrip.querySelector('.ali-tab-active');
    if (act && act.scrollIntoView) act.scrollIntoView({ block: 'nearest', inline: 'nearest' });
}

// ── Wiring ───────────────────────────────────────────────────────────────────────────────
function ALICodeEditor_initChrome() {
    ALICodeEditor_toolbar = document.getElementById('aliToolbar');
    ALICodeEditor_tabStrip = document.getElementById('aliTabs');
    if (!ALICodeEditor_toolbar || !ALICodeEditor_tabStrip) return;

    ALICodeEditor_toolbar.innerHTML =
        '<div class="ali-tb-btn" data-menu="file">File <span class="ali-tb-caret">&#9662;</span></div>' +
        '<div class="ali-tb-sep"></div>' +
        // Split button: the left half runs, the caret opens what configures the run.
        '<div class="ali-tb-split">' +
        '<div class="ali-tb-btn ali-tb-run" data-cmd="run"><span class="ali-tb-play">&#9654;</span>Compile & Run (F5)</div>' +
        '<div class="ali-tb-btn ali-tb-more" data-menu="run" title="Run settings"><span class="ali-tb-caret">&#9662;</span></div>' +
        '</div>';
    ALICodeEditor_applyRunMode(ALICodeEditor_simulation);

    // One delegated listener per row: the tab strip is re-rendered wholesale on every SetTabs,
    // so per-element handlers would have to be re-attached each time.
    ALICodeEditor_toolbar.addEventListener('mousedown', function (e) { e.preventDefault(); });
    ALICodeEditor_toolbar.addEventListener('click', function (e) {
        var btn = ALICodeEditor_closestEl(e.target, 'ali-tb-btn');
        if (!btn) return;
        var menu = btn.getAttribute('data-menu');
        if (menu === 'file') {
            ALICodeEditor_openMenuAt(btn, [
                { label: 'New', cmd: 'new' },
                { label: 'Open...', cmd: 'open' },
                null,
                { label: 'Save', cmd: 'save', key: 'Ctrl+S' },
                { label: 'Rename...', cmd: 'rename' },
                null,
                { label: 'Close tab', cmd: 'close' }
            ]);
            return;
        }
        // The caret half of the Run split button: the other ways to run and what configures a
        // run — clicking the Run half is still a plain compile-and-run. Opens under the whole
        // split button, left-aligned with "Compile & Run".
        if (menu === 'run') {
            var runItems = [
                { label: 'Force Compile & Run', cmd: 'forcerun', icon: '↻', key: 'Ctrl+F5' },
                null,
                { label: 'Simulation mode', cmd: 'simulation', toggle: ALICodeEditor_simulation },
                null,
                { label: 'Settings...', cmd: 'options', icon: '⚙' }
            ];
            if (ALICodeEditor_preprocAvailable)
                runItems.push({ label: 'Preprocessor directives...', cmd: 'preproc', icon: '#' });
            ALICodeEditor_openMenuAt(btn, runItems, btn.parentNode);
            return;
        }
        ALICodeEditor_closeMenu();
        ALICodeEditor_runCommand(btn.getAttribute('data-cmd'));
    });

    ALICodeEditor_tabStrip.addEventListener('mousedown', function (e) {
        if (e.target && e.target.tagName === 'INPUT') return; // the rename box needs real focus
        e.preventDefault();
    });
    ALICodeEditor_tabStrip.addEventListener('click', function (e) {
        ALICodeEditor_closeMenu();
        if (ALICodeEditor_renaming) return;
        var x = ALICodeEditor_closestEl(e.target, 'ali-tab-x');
        if (x) { ALICodeEditor_invokeOnSource('close', x.getAttribute('data-close')); return; }
        var add = ALICodeEditor_closestEl(e.target, 'ali-tab-add');
        if (add) {
            ALICodeEditor_openMenuAt(add, [
                { label: 'New', cmd: 'new' },
                { label: 'Open...', cmd: 'open' }
            ]);
            return;
        }
        var tab = ALICodeEditor_closestEl(e.target, 'ali-tab');
        if (!tab) return;
        var i = parseInt(tab.getAttribute('data-i'), 10);
        if (ALICodeEditor_tabs[i] && ALICodeEditor_tabs[i].a) return; // already active
        ALICodeEditor_invokeOnSource('select', i);
    });
    ALICodeEditor_tabStrip.addEventListener('dblclick', function (e) {
        var tab = ALICodeEditor_closestEl(e.target, 'ali-tab');
        if (!tab || ALICodeEditor_renaming) return;
        ALICodeEditor_startRename(parseInt(tab.getAttribute('data-i'), 10));
    });

    document.addEventListener('mousedown', function (e) {
        if (!ALICodeEditor_menu) return;
        if (ALICodeEditor_menu.el.contains(e.target)) return;
        if (ALICodeEditor_menu.owner.contains(e.target)) return;
        ALICodeEditor_closeMenu();
    });
}

// Toolbar and tabs are source-pane furniture: they ride on the same switch as the status strip,
// so the read-only Result viewer never shows them.
function ALICodeEditor_showChrome(on) {
    if (ALICodeEditor_toolbar) ALICodeEditor_toolbar.classList.toggle('ali-on', !!on);
    if (ALICodeEditor_tabStrip) ALICodeEditor_tabStrip.classList.toggle('ali-on', !!on);
    if (!on) ALICodeEditor_closeMenu();
}
