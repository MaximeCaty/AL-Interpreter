// Self-check for the ALI editor chrome: tab rendering and command routing.
// Run: node ALICodeEditorChrome.check.js
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const dir = __dirname + '/';

// Minimal stubs — Chrome.js only touches the DOM through these while rendering.
const sent = [];
global.window = {
    Microsoft: {
        Dynamics: {
            NAV: {
                InvokeExtensibilityMethod: function (name, args) { sent.push([name].concat(args)); }
            }
        }
    }
};
// In a browser window.Microsoft and bare Microsoft are the same object; node needs both.
global.Microsoft = global.window.Microsoft;
global.document = { addEventListener: function () { } };
let flushed = 0;

// Render.js / Main.js only for their pure helpers (parseOut, problemsText); Main's flushChanged
// is stubbed out below.
for (const f of ['ALICodeEditorState.js', 'ALICodeEditorRender.js', 'ALICodeEditorChrome.js', 'ALICodeEditorMain.js'])
    vm.runInThisContext(fs.readFileSync(dir + f, 'utf8'), { filename: f });
const realFlush = ALICodeEditor_flushChanged;
global.ALICodeEditor_flushChanged = function () { flushed++; };

const strip = { innerHTML: '', querySelector: function () { return null; } };
ALICodeEditor_tabStrip = strip;

// --- 1. an unnamed tab gets a placeholder caption, a named one keeps its name ---
ALICodeEditor_tabs = [{ n: 'Hello', d: 'demo', a: false }, { n: '', d: '', a: true }];
assert.strictEqual(ALICodeEditor_activeTab(), 1);
assert.strictEqual(ALICodeEditor_tabCaption(ALICodeEditor_tabs[0], 0), 'Hello');
assert.strictEqual(ALICodeEditor_tabCaption(ALICodeEditor_tabs[1], 1), 'Untitled-2*');

// --- 2. rendering: index attribute, active class on the active tab only, trailing [+] ---
ALICodeEditor_renderTabs();
assert.ok(strip.innerHTML.indexOf('data-i="0"') !== -1);
assert.ok(strip.innerHTML.indexOf('data-i="1"') !== -1);
assert.strictEqual(strip.innerHTML.split('ali-tab-active').length - 1, 1); // exactly one tab carries it
assert.ok(strip.innerHTML.indexOf('title="demo"') !== -1);                 // Description rides as the tooltip
assert.ok(strip.innerHTML.indexOf('ali-tab-add') !== -1);

// --- 3. a name from the database is escaped, never injected as markup ---
ALICodeEditor_tabs = [{ n: '<img src=x>', d: '', a: true }];
ALICodeEditor_renderTabs();
assert.strictEqual(strip.innerHTML.indexOf('<img'), -1);

// --- 4. source-acting commands flush the pending edit BEFORE the command reaches AL ---
sent.length = 0; flushed = 0;
ALICodeEditor_runCommand('run');
assert.strictEqual(flushed, 1);
assert.deepStrictEqual(sent[0], ['EditorCommand', 'run', '']);

// --- 5. Save on a tab that was never named asks for the name inline instead of calling AL ---
sent.length = 0;
ALICodeEditor_tabs = [{ n: '', d: '', a: true }];
ALICodeEditor_runCommand('save');
assert.strictEqual(sent.length, 0);

// --- 6. Save on a named tab does reach AL ---
sent.length = 0;
ALICodeEditor_tabs = [{ n: 'Hello', d: '', a: true }];
ALICodeEditor_runCommand('save');
assert.deepStrictEqual(sent[0], ['EditorCommand', 'save', '']);

// --- 7. menus: an icon column on every row once one row has an icon, none otherwise; a toggle
//        row draws the switch in its current state ---
const menu = ALICodeEditor_menuHtml([{ label: 'Force', cmd: 'forcerun', icon: '↻' }, null,
    { label: 'Simulation mode', cmd: 'simulation', toggle: true }]);
assert.strictEqual(menu.split('ali-menu-ico').length - 1, 2);
assert.ok(menu.indexOf('ali-switch ali-switch-on') !== -1);
assert.strictEqual(ALICodeEditor_menuHtml([{ label: 'New', cmd: 'new' }]).indexOf('ali-menu-ico'), -1);
assert.strictEqual(ALICodeEditor_menuHtml([{ label: 'S', cmd: 'simulation', toggle: false }]).indexOf('ali-switch-on'), -1);

// --- 8. the Simulation switch flips locally and sends AL the NEW mode, with no source flush ---
sent.length = 0; flushed = 0; ALICodeEditor_simulation = true;
ALICodeEditor_runCommand('simulation');
assert.strictEqual(ALICodeEditor_simulation, false);
assert.deepStrictEqual(sent[0], ['EditorCommand', 'simulation', '0']);
assert.strictEqual(flushed, 0);

// --- 9. Force Compile & Run acts on the source exactly like Run ---
sent.length = 0; flushed = 0;
ALICodeEditor_runCommand('forcerun');
assert.strictEqual(flushed, 1);
assert.deepStrictEqual(sent[0], ['EditorCommand', 'forcerun', '']);

// --- 10. Problems panel: sorted by position, each located line links to its source spot ---
const probs = ALICodeEditor_problemsText([{ line: 9, col: 2, sev: 1, msg: 'W1' }, { line: 3, col: 5, sev: 2, msg: 'ALI911: x' }]).split('\n');
assert.ok(probs[0].startsWith('\x01Error@3,5\x02Error'));
assert.ok(probs[0].endsWith('ALI911: x'));
assert.ok(probs[1].startsWith('\x01Warning@9,2\x02'));
assert.ok(ALICodeEditor_problemsText([]).indexOf('No problems') !== -1);
assert.strictEqual(ALICodeEditor_parseOut(probs.join('\n')).indexOf('\x01'), -1);   // markers stripped
assert.deepStrictEqual(ALICodeEditor_outLines[0], { c: 'ali-out-error', ln: 3, col: 5 });   // ...kept as a link

// --- 11. the text sent back names the tab it was typed in (AL drops any other tab's) ---
ALICodeEditor_ready = true;
SetTabs(JSON.stringify([{ n: 'A', d: '', a: false, id: 3 }, { n: '', d: '', a: true, id: 7 }]));
assert.strictEqual(ALICodeEditor_bufferTabId, 7);
ALICodeEditor_textarea = { value: 'typed', readOnly: false };
sent.length = 0;
realFlush();
assert.deepStrictEqual(sent[0], ['TextChangedLong', 'typed', 7]);

// --- 12. a buffer swap from AL cancels an edit still waiting on the debounce: fired later, it
//         would send the new buffer as if typed, or (before the swap) the old tab's text ---
global.ALICodeEditor_setBuffer = function (t) { ALICodeEditor_textarea.value = t; };
ALICodeEditor_changeTimerLong = setTimeout(function () { assert.fail('stale debounce fired'); }, 60000);
SetText('other tab');
assert.strictEqual(ALICodeEditor_changeTimerLong, null);
assert.strictEqual(ALICodeEditor_lastSentText, 'other tab');   // AL holds it: a flush now sends nothing
sent.length = 0;
realFlush();
assert.strictEqual(sent.length, 0);

console.log('ok');
