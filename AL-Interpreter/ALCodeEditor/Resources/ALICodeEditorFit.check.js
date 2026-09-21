// Self-check for the auto-height target (run: node ALICodeEditorFit.check.js)
const fs = require('fs'), vm = require('vm'), assert = require('assert');
global.window = {};
vm.runInThisContext(fs.readFileSync(__dirname + '/ALICodeEditorMain.js', 'utf8'), { filename: 'ALICodeEditorMain.js' });

const frame = (top, height) => ({ getBoundingClientRect: () => ({ top, height, bottom: top + height }) });
const vh = 1000, margin = ALICodeEditor_fitMargin;

// side by side (grid on a wide window): both panes get the full height in ONE pass
assert.strictEqual(ALICodeEditor_fitTarget([frame(200, 300), frame(200, 300)], vh), vh - 200 - margin);
// one pane already grown, the other not: same answer, no creeping
assert.strictEqual(ALICodeEditor_fitTarget([frame(200, 700), frame(200, 300)], vh), vh - 200 - margin);
// stacked (narrow window), 40px caption between: split what is left
assert.strictEqual(ALICodeEditor_fitTarget([frame(200, 300), frame(540, 300)], vh), Math.floor((vh - 200 - 40 - margin) / 2));
// stacked result is stable: applying it gives the same target again
const h = Math.floor((vh - 200 - 40 - margin) / 2);
assert.strictEqual(ALICodeEditor_fitTarget([frame(200, h), frame(200 + h + 40, h)], vh), h);
console.log('fit ok');
