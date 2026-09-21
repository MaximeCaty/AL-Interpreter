// Self-check for the ALI editor completion context (run: node check.js)
const fs = require('fs'), vm = require('vm'), assert = require('assert');
const dir = __dirname + '/';
global.window = {};
for (const f of ['ALICodeEditorState.js', 'ALICodeEditorSuggest.js', 'ALICodeEditorRender.js', 'ALICodeEditorHover.js'])
    vm.runInThisContext(fs.readFileSync(dir + f, 'utf8'), { filename: f });

// stub textarea: text with the caret at the '|' marker
function at(src) {
    const caret = src.indexOf('|');
    ALICodeEditor_textarea = { value: src.replace('|', ''), selectionStart: caret, selectionEnd: caret, readOnly: false };
    return ALICodeEditor_typeContext();
}
const head = 'var\n  Cust: record Customer;\n  i: INTEGER;\nbegin\n  ';

// --- 3. declarations are case-insensitive (`record` / `INTEGER` like AL) ---
at(head + '|');
const decls = ALICodeEditor_scanDeclarations();
assert.deepStrictEqual(decls['CUST'], { type: 'Record', table: 'Customer', name: 'Cust' });
assert.strictEqual(decls['I'].type, 'Integer');           // canonical spelling, not what was typed
assert.ok(ALICodeEditor_typeSet['INTEGER'] && ALICodeEditor_typeSet['RECORD']); // coloring lookup

// --- 2. field completion inside SetRange/SetFilter/CalcFields ---
let c = at(head + 'Cust.SetRange(|');
assert.strictEqual(c.mode, 'field'); assert.strictEqual(c.receiver, 'Cust'); assert.strictEqual(c.prefix, '');

c = at(head + 'Cust.SetFilter("Doc|');
assert.strictEqual(c.mode, 'field'); assert.strictEqual(c.prefix, 'Doc');
assert.strictEqual(ALICodeEditor_textarea.value.slice(c.start), '"Doc'); // replacement covers the quote

c = at(head + 'cust.setrange(No|');                        // method name case-insensitive
assert.strictEqual(c.mode, 'field'); assert.strictEqual(c.prefix, 'No');

c = at(head + 'Cust.CalcFields(Balance, "Bal|');           // field in every argument
assert.strictEqual(c.mode, 'field'); assert.strictEqual(c.prefix, 'Bal');

assert.strictEqual(at(head + 'Cust.SetRange("No.", |'), null);   // arg 2 of SetRange is a value
assert.strictEqual(at(head + 'Cust.Insert(|'), null);            // not a field-taking method
assert.strictEqual(at('var\n  Cust: record Customer;\n  x: Text|').mode, 'type');   // var block: types
assert.strictEqual(at('var\n  Cust: record Cust|').mode, 'table');                  // var block: tables

// --- pool: field mode yields only fields, member mode fields + methods ---
ALICodeEditor_objMembers['Table:CUSTOMER'] = [{ n: 'No.', t: 'Code', len: 20, pk: true }, { n: 'Name', t: 'Text', len: 100 }];
ALICodeEditor_catalog = { types: ALICodeEditor_TYPES, methods: { Record: [{ n: 'SetRange', s: 'SetRange(Field)', r: '' }] } };
ALICodeEditor_rebuildTypeCanon();
let pool = ALICodeEditor_suggestPool(at(head + 'Cust.SetRange(|'));
assert.deepStrictEqual(pool.map(i => i.l), ['No.', 'Name']);
assert.strictEqual(pool[0].t, '"No."');                    // quoted on insert
assert.strictEqual(pool[0].d, 'Code[20] (PK)');
pool = ALICodeEditor_suggestPool(at(head + 'Cust.|'));
assert.deepStrictEqual(pool.map(i => i.l), ['No.', 'Name', 'SetRange(Field)']);
assert.deepStrictEqual(pool.map(i => i.k), ['f', 'f', 'm']);   // icon kind per row

// --- declared variables complete on a bare word, anywhere in a code body ---
ALICodeEditor_catalog.builtins = [{ n: 'CopyStr', r: 'Text', ok: true }, { n: 'Cancelled', r: '', ok: false }];
c = at(head + 'Cu|');
assert.strictEqual(c.mode, 'proc'); assert.strictEqual(c.prefix, 'Cu');
pool = ALICodeEditor_suggestPool(c);
assert.deepStrictEqual(pool.filter(i => i.k === 'v').map(i => i.l), ['Cust', 'i']);
assert.strictEqual(pool.find(i => i.l === 'Cust').d, 'Record Customer');
assert.ok(!pool.some(i => i.l === 'Cancelled'));               // unimplemented builtins stay hidden
assert.strictEqual(at('var\n  Cust: record Customer;\n  x: Tex|').mode, 'type');  // var block still types
assert.strictEqual(at(head + 'if Cust.Get(1) then\n    Cu|').mode, 'proc');       // not only after `begin`

// --- table procedures ride on the field list: members, never fields ---
ALICodeEditor_objMembers['Table:CUSTOMER'].push({ n: 'Recalculate', s: 'Recalculate(Integer)', r: 'Boolean', k: 'p' });
assert.deepStrictEqual(ALICodeEditor_suggestPool(at(head + 'Cust.SetRange(|')).map(i => i.l), ['No.', 'Name']);
pool = ALICodeEditor_suggestPool(at(head + 'Cust.|'));
assert.deepStrictEqual(pool.map(i => i.l), ['No.', 'Name', 'Recalculate(Integer)', 'SetRange(Field)']);
assert.strictEqual(pool[2].t, 'Recalculate');                  // insert the name, not the signature
assert.strictEqual(pool[2].k, 'm');

// --- codeunit variables: declaration completion, member completion, member fetch ---
const cuHead = 'var\n  Cust: record Customer;\n  Api: Codeunit "ALI Api Catalog";\nbegin\n  ';
at(cuHead + '|');
assert.deepStrictEqual(ALICodeEditor_scanDeclarations()['API'], { type: 'Codeunit', table: 'ALI Api Catalog', name: 'Api' });

// object names are typed unquoted and contain spaces — a space must not end the prefix
assert.strictEqual(at('var\n  Cust: record Sales Inv|').prefix, 'Sales Inv');
assert.strictEqual(at('var\n  Api: Codeunit ALI Api|').mode, 'codeunit');
assert.strictEqual(at('var\n  Api: Codeunit ALI Api|').prefix, 'ALI Api');
assert.strictEqual(at('var\n  Api: Codeunit "ALI Api|').prefix, 'ALI Api');   // quoted form too
assert.strictEqual(at('var\n  Api: codeunit |').mode, 'codeunit');            // keyword case-insensitive
assert.strictEqual(at('var\n  Api: Codeunit "ALI Api Catalog";|'), null);     // ';' ends the declaration

ALICodeEditor_codeunits = [{ n: 'ALI Api Catalog', id: 51083 }, { n: 'ALI Engine', id: 51080 }];
pool = ALICodeEditor_suggestPool(at('var\n  Api: Codeunit ALI|'));
assert.deepStrictEqual(pool.map(i => i.t), ['"ALI Api Catalog"', '"ALI Engine"']);
assert.strictEqual(pool[0].k, 'c');

// a codeunit receiver asks AL for ITS members (own cache key), then offers only procedures
let asked = null;
// in the client both resolve to the same object; here `window` is a stub, so set both
global.Microsoft = window.Microsoft = { Dynamics: { NAV: { InvokeExtensibilityMethod: (n, a) => { asked = [n, ...a]; } } } };
assert.strictEqual(ALICodeEditor_suggestPool(at(cuHead + 'Api.|')).length, 0);   // fetch in flight
assert.deepStrictEqual(asked, ['RequestObjectMembers', 'Codeunit', 'ALI Api Catalog']);
ALICodeEditor_objMembers['Codeunit:ALI API CATALOG'] = [{ n: 'BuildCatalogJson', s: 'BuildCatalogJson()', r: 'Text', k: 'p' }];
pool = ALICodeEditor_suggestPool(at(cuHead + 'Api.|'));
assert.deepStrictEqual(pool.map(i => i.l), ['BuildCatalogJson()']);
assert.strictEqual(pool[0].t, 'BuildCatalogJson');

// --- a declaration whose TYPE is a keyword must not end the enclosing var block ---
// (`Codeunit` is both; before the fix the next line in the same block lost completion)
const shell = 'codeunit 50100 MyScript\n{\n  var\n    Api: Codeunit "ALI Api Catalog";\n    ';
assert.strictEqual(at(shell + 'Cust: Record Cust|').mode, 'table');
assert.strictEqual(at(shell + 'Cu2: Codeunit ALI|').mode, 'codeunit');
assert.strictEqual(at(shell + 'i: Inte|').mode, 'type');
assert.strictEqual(at(shell + 'Api.|'), null);              // still a var block: no member completion
assert.strictEqual(at(shell + '\n  begin\n    Api.|').mode, 'member');

// --- enums: `x: Enum <pfx>` offers enum names; declaration keeps the enum name ---
ALICodeEditor_enums = [{ n: 'Swiss QR-Bill Payment Reference Type', id: 11512 }, { n: 'Sales Document Type', id: 36 }];
c = at('var\n  R: Enum "Swiss QR|');
assert.strictEqual(c.mode, 'enum'); assert.strictEqual(c.prefix, 'Swiss QR');
pool = ALICodeEditor_suggestPool(at('var\n  R: enum Sales|'));
assert.deepStrictEqual(pool.map(i => i.t), ['"Swiss QR-Bill Payment Reference Type"', '"Sales Document Type"']);
assert.strictEqual(pool[0].k, 'e');
at('var\n  R: Enum "Sales Document Type";\nbegin\n  |');
assert.deepStrictEqual(ALICodeEditor_scanDeclarations()['R'], { type: 'Enum', table: 'Sales Document Type', name: 'R' });

// --- options: `opt::` offers the local Option variable's members (quoted, blank skipped) ---
assert.deepStrictEqual(ALICodeEditor_optionMembers(' ,Open, "Ref (ISO 11649)",,Done '), ['', 'Open', 'Ref (ISO 11649)', '', 'Done']);
assert.deepStrictEqual(ALICodeEditor_optionMembers(''), []);
const optHead = 'var\n  St, St2: Option ,Open,"Pending Approval";\n  i: Integer;\nbegin\n  ';
at(optHead + '|');
assert.deepStrictEqual(ALICodeEditor_scanDeclarations()['ST2'].options, ['', 'Open', 'Pending Approval']);
assert.strictEqual(ALICodeEditor_scanDeclarations()['I'].options, undefined);    // untouched for other types
c = at(optHead + 'if St = St::|');
assert.strictEqual(c.mode, 'optmember'); assert.strictEqual(c.receiver, 'St'); assert.strictEqual(c.prefix, '');
pool = ALICodeEditor_suggestPool(c);
assert.deepStrictEqual(pool.map(i => [i.t, i.d]), [['Open', '1'], ['"Pending Approval"', '2']]);
c = at(optHead + 'St := St::"Pend|');
assert.strictEqual(c.prefix, 'Pend');
assert.strictEqual(ALICodeEditor_textarea.value.slice(c.start), '"Pend');       // replacement covers the quote
assert.strictEqual(at('procedure P(o: Option A,B)\nbegin\n  o::|').mode, 'optmember');
assert.deepStrictEqual(ALICodeEditor_scanDeclarations()['O'].options, ['A', 'B']);  // parameter form ends at ')'
assert.strictEqual(ALICodeEditor_suggestPool(at(optHead + 'i::|')).length, 0);       // not an Option: nothing

// --- record Option/Enum field: `Rec.Field::` offers the field's members (served with the table's fields) ---
ALICodeEditor_objMembers['Table:CUSTOMER'] = [{ n: 'No.', t: 'Code', len: 20, pk: true },
    { n: 'Doc Type', t: 'Option', o: [{ n: 'Quote', v: 0 }, { n: 'Credit Memo', v: 3 }] }];
c = at(head + 'if Cust."Doc Type" = Cust."Doc Type"::|');
assert.strictEqual(c.mode, 'optmember'); assert.strictEqual(c.receiver, 'Cust'); assert.strictEqual(c.field, 'Doc Type');
assert.deepStrictEqual(ALICodeEditor_suggestPool(c).map(i => [i.t, i.d]), [['Quote', '0'], ['"Credit Memo"', '3']]);
c = at(head + 'Cust."Doc Type" := Cust."Doc Type"::"Cre|');
assert.strictEqual(c.prefix, 'Cre'); assert.strictEqual(c.field, 'Doc Type');
assert.strictEqual(ALICodeEditor_suggestPool(at(head + 'Cust."No."::|')).length, 0); // not an Option field: nothing

// --- render: every highlighted line is self-contained markup (multi-line tokens reopened) ---
ALICodeEditor_declNames = {};
for (const src of ['/* a\nb */ x := 1;', "x := 'abc\ny\nz"])   // block comment, unterminated string
    ALICodeEditor_highlight(src).split('\n').forEach(l =>
        assert.strictEqual((l.match(/<span/g) || []).length, (l.match(/<\/span>/g) || []).length, l));

// --- render: patchLines swaps only the changed run of lines, keeps the rest ---
function fakeLayer() {
    const kids = [];
    const mk = html => html.split('\n</span>').slice(0, -1).map(s => ({
        html: s.slice('<span>'.length),
        insertAdjacentHTML(pos, h) { kids.splice(kids.indexOf(this), 0, ...mk(h)); }   // beforebegin
    }));
    return { children: kids, removeChild(k) { kids.splice(kids.indexOf(k), 1); },
             insertAdjacentHTML(pos, h) { kids.push(...mk(h)); } };                   // beforeend
}
const layer = fakeLayer(), txt = () => layer.children.map(k => k.html);
ALICodeEditor_patchLines(layer, ['a', 'b', 'c']);
const kept = layer.children.slice();
ALICodeEditor_patchLines(layer, ['a', 'B', 'c']);
assert.deepStrictEqual(txt(), ['a', 'B', 'c']);
assert.ok(layer.children[0] === kept[0] && layer.children[2] === kept[2]);   // untouched lines reused
ALICodeEditor_patchLines(layer, ['a', 'B', 'x', 'y', 'c']);                  // lines inserted
assert.deepStrictEqual(txt(), ['a', 'B', 'x', 'y', 'c']);
ALICodeEditor_patchLines(layer, ['c']);                                      // lines deleted
assert.deepStrictEqual(txt(), ['c']);
ALICodeEditor_patchLines(layer, ['c', 'c', 'c']);                            // repeated lines
assert.deepStrictEqual(txt(), ['c', 'c', 'c']);

// --- hover hit-testing: column math with tab stops of 4, no DOM measure per character ---
ALICodeEditor_cellW = 10; ALICodeEditor_cellDpr = window.devicePixelRatio;   // stub the one measure
assert.strictEqual(ALICodeEditor_colOf('\tab', 1), 4);          // tab jumps to the next stop
assert.strictEqual(ALICodeEditor_colOf('ab\tc', 3), 4);         // tab after 2 chars fills to 4
assert.strictEqual(ALICodeEditor_charAtX('\tCust', 35), 0);     // inside the tab cell
assert.strictEqual(ALICodeEditor_charAtX('\tCust', 45), 1);     // 'C' spans 40..50
assert.strictEqual(ALICodeEditor_charAtX('ab', 500), 1);        // past the end: last char

// --- result pane: AL line markers stripped, style + link carried onto unmarked lines ---
const plain = ALICodeEditor_parseOut('\x01Dim\x02Lexer: 3\r\n\x01Error@12,5\x02error(12,5) X\r\n   | quote\r\n\x01Normal\x02done');
assert.strictEqual(plain, 'Lexer: 3\nerror(12,5) X\n   | quote\ndone');     // textarea gets clean LF text
assert.deepStrictEqual(ALICodeEditor_outLines.map(s => [s.c, s.ln, s.col]), [
    ['ali-out-dim', 0, 0], ['ali-out-error', 12, 5], ['ali-out-error', 12, 5], ['ali-out-normal', 0, 0]]);
assert.strictEqual(ALICodeEditor_outHtml(plain).split('\n')[2],
    '<span class="ali-out-error ali-out-link">   | quote</span>');       // continuation keeps the link

console.log('ok');
