// ALI Code Editor — part 2/5: syntax coloring, gutter, scrolling and the error squiggle layer.

// One token as markup. A token that crosses lines (block comment, or a string whose closing
// quote is not typed yet) is closed and reopened at every newline, so each line of the output
// is self-contained markup that ALICodeEditor_patchLines can swap on its own.
function ALICodeEditor_span(cls, text) {
    return '<span class="' + cls + '">' +
        ALICodeEditor_escapeHtml(text).split('\n').join('</span>\n<span class="' + cls + '">') + '</span>';
}

function ALICodeEditor_highlight(src) {
    var out = '';
    var i = 0;
    var n = src.length;
    var prevWord = '';  // last identifier/keyword seen (lowercased) — detects `procedure X`

    while (i < n) {
        var c = src[i];

        if (c === '/' && src[i + 1] === '/') {
            var start = i;
            while (i < n && src[i] !== '\n') i++;
            out += ALICodeEditor_span('ali-tok-cmt', src.slice(start, i));
            continue;
        }

        if (c === '/' && src[i + 1] === '*') {
            var start = i;
            i += 2;
            while (i < n && !(src[i] === '*' && src[i + 1] === '/')) i++;
            i = Math.min(n, i + 2);
            out += ALICodeEditor_span('ali-tok-cmt', src.slice(start, i));
            continue;
        }

        if (c === "'") {
            var start = i;
            i++;
            while (i < n) {
                if (src[i] === "'" && src[i + 1] === "'") { i += 2; continue; }
                if (src[i] === "'") { i++; break; }
                i++;
            }
            out += ALICodeEditor_span('ali-tok-str', src.slice(start, i));
            continue;
        }

        if (/[0-9]/.test(c)) {
            var start = i;
            while (i < n && /[0-9.]/.test(src[i])) i++;
            out += '<span class="ali-tok-num">' + ALICodeEditor_escapeHtml(src.slice(start, i)) + '</span>';
            continue;
        }

        if (/[A-Za-z_]/.test(c)) {
            var start = i;
            while (i < n && /[A-Za-z0-9_]/.test(src[i])) i++;
            var word = src.slice(start, i);
            var lower = word.toLowerCase();
            // A word that is both a keyword and a data type (`Codeunit`, `Enum`) colors as a
            // type when it sits in type position — right after a declaration colon — so
            // `MyCU: Codeunit "X"` reads like `MyRec: Record Customer`, and as a keyword
            // everywhere else.
            var k = start - 1;
            while (k >= 0 && (src[k] === ' ' || src[k] === '\t')) k--;
            var inTypePos = k >= 0 && src[k] === ':' && ALICodeEditor_typeSet[word.toUpperCase()];
            if (ALICodeEditor_kwSet[lower] && !inTypePos) {
                out += '<span class="ali-tok-kw">' + ALICodeEditor_escapeHtml(word) + '</span>';
            } else if (ALICodeEditor_typeSet[word.toUpperCase()]) { // AL is case-insensitive: `integer` colors like `Integer`
                out += '<span class="ali-tok-type">' + ALICodeEditor_escapeHtml(word) + '</span>';
            } else {
                // function/method: declared right after `procedure`, or followed by '('
                var j = i;
                while (j < n && (src[j] === ' ' || src[j] === '\t')) j++;
                if (prevWord === 'procedure' || src[j] === '(') {
                    out += '<span class="ali-tok-fn">' + ALICodeEditor_escapeHtml(word) + '</span>';
                } else if (ALICodeEditor_declNames[word.toUpperCase()]) {
                    // declared variable/parameter (var block + procedure signatures)
                    out += '<span class="ali-tok-var">' + ALICodeEditor_escapeHtml(word) + '</span>';
                } else {
                    out += ALICodeEditor_escapeHtml(word);
                }
            }
            prevWord = lower;
            continue;
        }

        out += ALICodeEditor_escapeHtml(c);
        i++;
    }
    return out;
}

// ── Result pane styling ──────────────────────────────────────────────────────────────────
// The style of each output line is decided in AL ("ALI Script Editor".OutAt), not guessed here
// from the text: a line may open with <SOH>StyleName[@line,col]<STX>. The marker is stripped —
// the textarea must hold exactly the text the user sees and copies — and kept per line in
// ALICodeEditor_outLines. An unmarked line carries on the marker above it, so every line of a
// multi-line message keeps its style and its link.
var ALICodeEditor_outLines = null;   // [{c: css class, ln, col}] per line; null = no markers, plain text

function ALICodeEditor_parseOut(text) {
    // The textarea hands its value back LF-only; the per-line array must count lines the same way.
    var lines = text.replace(/\r\n?/g, '\n').split('\n'), cur = { c: '', ln: 0, col: 0 }, m;
    ALICodeEditor_outLines = [];
    for (var i = 0; i < lines.length; i++) {
        m = /^\x01([A-Za-z]+)(?:@(\d+),(\d+))?\x02/.exec(lines[i]);
        if (m) {
            cur = { c: 'ali-out-' + m[1].toLowerCase(), ln: +(m[2] || 0), col: +(m[3] || 0) };
            lines[i] = lines[i].slice(m[0].length);
        }
        ALICodeEditor_outLines.push(cur);
    }
    return lines.join('\n');
}

function ALICodeEditor_outHtml(src) {
    var lines = src.split('\n');
    for (var i = 0; i < lines.length; i++) {
        var st = ALICodeEditor_outLines[i];
        lines[i] = ALICodeEditor_escapeHtml(lines[i]);
        if (st && lines[i])
            lines[i] = '<span class="' + st.c + (st.ln ? ' ali-out-link' : '') + '">' + lines[i] + '</span>';
    }
    return lines.join('\n');
}

// Text last painted into the highlight layer. Re-highlighting a large buffer and replacing its
// innerHTML is the most expensive thing this add-in does, so a render that would repaint the
// same text is skipped — SetText echoes from the page and duplicate input events are free.
// A render that must happen anyway (language switch, new catalog) clears this first.
var ALICodeEditor_lastRendered = null;

function ALICodeEditor_render() {
    if (ALICodeEditor_textarea.value === ALICodeEditor_lastRendered) return;
    ALICodeEditor_lastRendered = ALICodeEditor_textarea.value;
    var html;
    // AL language off (Result pane): plain monospace text, no syntax coloring.
    if (ALICodeEditor_alLanguage) {
        ALICodeEditor_declNames = ALICodeEditor_scanDeclarations(); // variable coloring
        html = ALICodeEditor_highlight(ALICodeEditor_textarea.value);
    } else if (ALICodeEditor_outLines)
        html = ALICodeEditor_outHtml(ALICodeEditor_textarea.value);
    else
        html = ALICodeEditor_escapeHtml(ALICodeEditor_textarea.value);
    ALICodeEditor_highlightLines = html.split('\n');
    ALICodeEditor_patchLines(ALICodeEditor_highlightCode, ALICodeEditor_highlightLines);
    ALICodeEditor_renderGutter();
    ALICodeEditor_updateMinimap();
}

// Bring a layer (highlight code, minimap) to `lines`, one <span> per source line, touching only
// the run between the unchanged head and tail. A keystroke thus swaps one line's markup instead
// of the whole buffer's: on a 1000-line script a full innerHTML rebuilt ~10k nodes per key, each
// to be laid out, repainted and — when Chrome's accessibility tree is live — serialized to the
// browser process, which is what froze Chrome (not Edge) on big scripts.
function ALICodeEditor_patchLines(container, lines) {
    var old = container.aliLines || [];
    var n = Math.min(old.length, lines.length), head = 0, tail = 0, i;
    while (head < n && old[head] === lines[head]) head++;
    while (tail < n - head && old[old.length - 1 - tail] === lines[lines.length - 1 - tail]) tail++;
    var kids = container.children;
    for (i = old.length - tail - 1; i >= head; i--) container.removeChild(kids[i]);
    var html = '';
    for (i = head; i < lines.length - tail; i++) html += '<span>' + lines[i] + '\n</span>';
    if (html) {
        if (kids[head]) kids[head].insertAdjacentHTML('beforebegin', html);
        else container.insertAdjacentHTML('beforeend', html);
    }
    container.aliLines = lines;
}

// Rewritten only when the line count moves: typing inside a line leaves the numbers alone.
function ALICodeEditor_renderGutter() {
    var count = ALICodeEditor_highlightLines.length;
    if (count === ALICodeEditor_lineCount) return;
    ALICodeEditor_lineCount = count;
    var lines = [];
    for (var i = 1; i <= count; i++) lines.push(i);
    ALICodeEditor_gutter.textContent = lines.join('\n');
}

function ALICodeEditor_syncScroll() {
    ALICodeEditor_highlightPre.scrollTop = ALICodeEditor_textarea.scrollTop;
    ALICodeEditor_highlightPre.scrollLeft = ALICodeEditor_textarea.scrollLeft;
    ALICodeEditor_errorLayer.scrollTop = ALICodeEditor_textarea.scrollTop;
    ALICodeEditor_errorLayer.scrollLeft = ALICodeEditor_textarea.scrollLeft;
    ALICodeEditor_gutter.scrollTop = ALICodeEditor_textarea.scrollTop;
    ALICodeEditor_syncMinimapSlider();
    ALICodeEditor_hideSuggest();
    ALICodeEditor_hideErrorTip();
}

// ── Minimap ──────────────────────────────────────────────────────────────────────────────
// VS Code-style overview strip: the highlight layer's own HTML a second time, at 1/8 scale,
// pinned to the right edge — so it costs no extra tokenizing, only a copy of the markup.
// Shown on the AL source pane only, and only when there is enough code and enough width for
// it to earn the space it takes from the text.
var ALICodeEditor_MINIMAP_SCALE = 0.125;
var ALICodeEditor_MINIMAP_WIDTH = 110;      // keep in sync with .ali-minimap in the CSS
var ALICodeEditor_MINIMAP_MIN_LINES = 10;
var ALICodeEditor_MINIMAP_MIN_WIDTH = 400;
var ALICodeEditor_minimapTimer = null;
var ALICodeEditor_minimapDragging = false;

function ALICodeEditor_minimapVisible() {
    return !!ALICodeEditor_minimap && ALICodeEditor_editorRoot.classList.contains('ali-has-minimap');
}

// Width left to the text once the minimap has taken its strip — what the suggest dropdown and
// the tooltips must clamp against, or they slide underneath it.
function ALICodeEditor_contentWidth() {
    return ALICodeEditor_editorRoot.clientWidth - (ALICodeEditor_minimapVisible() ? ALICodeEditor_MINIMAP_WIDTH : 0);
}

function ALICodeEditor_updateMinimap() {
    if (!ALICodeEditor_minimap) return;
    var show = ALICodeEditor_alLanguage &&
        ALICodeEditor_lineCount > ALICodeEditor_MINIMAP_MIN_LINES &&
        ALICodeEditor_editorRoot.clientWidth >= ALICodeEditor_MINIMAP_MIN_WIDTH;
    ALICodeEditor_editorRoot.classList.toggle('ali-has-minimap', show);
    if (!show) return;
    ALICodeEditor_refreshMinimapContent();
    ALICodeEditor_syncMinimapSlider();
}

// The map only has to be roughly current — it is unreadable at this scale — so redrawing it
// on every keystroke would be pure waste. Coalesce into one copy per typing pause.
function ALICodeEditor_refreshMinimapContent() {
    if (ALICodeEditor_minimapInner.aliLines === ALICodeEditor_highlightLines || ALICodeEditor_minimapTimer) return;
    ALICodeEditor_minimapTimer = setTimeout(function () {
        ALICodeEditor_minimapTimer = null;
        if (!ALICodeEditor_minimapVisible()) return;
        ALICodeEditor_patchLines(ALICodeEditor_minimapInner, ALICodeEditor_highlightLines);
        ALICodeEditor_syncMinimapSlider();
    }, 300);
}

// Place the viewport box, and slide the map itself when the scaled code is taller than the
// pane — the map travels its own overflow at the same fraction as the editor travels its.
function ALICodeEditor_syncMinimapSlider() {
    if (!ALICodeEditor_minimapVisible()) return;
    var ta = ALICodeEditor_textarea;
    var maxScroll = Math.max(0, ta.scrollHeight - ta.clientHeight);
    var mapOverflow = Math.max(0, ta.scrollHeight * ALICodeEditor_MINIMAP_SCALE - ALICodeEditor_minimap.clientHeight);
    var mapTop = maxScroll > 0 ? (ta.scrollTop / maxScroll) * mapOverflow : 0;
    ALICodeEditor_minimapInner.style.top = (-mapTop) + 'px';
    ALICodeEditor_minimapSlider.style.top = (ta.scrollTop * ALICodeEditor_MINIMAP_SCALE - mapTop) + 'px';
    ALICodeEditor_minimapSlider.style.height = Math.max(6, ta.clientHeight * ALICodeEditor_MINIMAP_SCALE) + 'px';
}

// Click or drag anywhere on the map: centre the editor on the line under the pointer.
function ALICodeEditor_minimapScrollTo(clientY) {
    var ta = ALICodeEditor_textarea;
    var mapTop = -parseFloat(ALICodeEditor_minimapInner.style.top || '0') || 0;
    var y = clientY - ALICodeEditor_minimap.getBoundingClientRect().top + mapTop; // px into the whole map
    var target = y / ALICodeEditor_MINIMAP_SCALE - ta.clientHeight / 2;
    ta.scrollTop = Math.max(0, Math.min(Math.max(0, ta.scrollHeight - ta.clientHeight), target));
    ALICodeEditor_syncScroll();
}

function ALICodeEditor_bindMinimap() {
    ALICodeEditor_minimap.addEventListener('mousedown', function (e) {
        ALICodeEditor_minimapDragging = true;
        ALICodeEditor_minimapScrollTo(e.clientY);
        e.preventDefault(); // keep the caret in the textarea
    });
    document.addEventListener('mousemove', function (e) {
        if (ALICodeEditor_minimapDragging) ALICodeEditor_minimapScrollTo(e.clientY);
    });
    document.addEventListener('mouseup', function () { ALICodeEditor_minimapDragging = false; });
    // The map is not a scroller of its own, so give the wheel the same meaning it has over the code.
    ALICodeEditor_minimap.addEventListener('wheel', function (e) {
        ALICodeEditor_textarea.scrollTop += e.deltaY;
        ALICodeEditor_syncScroll();
        e.preventDefault();
    });
}

// Manual edits (Enter/Tab handlers, suggest accept) bypass the browser's native
// "scroll caret into view" because we preventDefault and set .value ourselves —
// so after moving the caret we scroll the textarea to keep it visible.
function ALICodeEditor_scrollCaretIntoView() {
    var ta = ALICodeEditor_textarea;
    var before = ta.value.slice(0, ta.selectionStart);
    var lineStart = before.lastIndexOf('\n') + 1;
    var lineIdx = before.split('\n').length - 1;
    ALICodeEditor_mirror.textContent = before.slice(lineStart);
    var caretX = ALICodeEditor_mirror.getBoundingClientRect().width; // px from line start (12 = left padding)
    var caretY = lineIdx * 22;                                       // 22 = line height
    if (caretY < ta.scrollTop)
        ta.scrollTop = caretY;
    else if (caretY + 22 + 10 > ta.scrollTop + ta.clientHeight)
        ta.scrollTop = caretY + 22 + 10 - ta.clientHeight;
    if (caretX < ta.scrollLeft)
        ta.scrollLeft = Math.max(0, caretX - 8);
    else if (caretX + 12 + 24 > ta.scrollLeft + ta.clientWidth)
        ta.scrollLeft = caretX + 12 + 24 - ta.clientWidth;
    ALICodeEditor_syncScroll();
}

// Error layer: a <pre> stacked on the highlight pre with transparent text; error ranges are
// wrapped in spans whose wavy text-decoration paints the VS Code-style zigzag underline.
// Positions come from the compile-time source, so decorations are cleared on any edit (stale).
// Patched line by line like the highlight layer: a compile answer or a clear only swaps the lines
// that gain or lose a squiggle, instead of rebuilding the whole buffer and leaving a full layout
// for the next mouse move's getBoundingClientRect to pay (that was a 1.7 s mousemove in Chrome).
function ALICodeEditor_renderErrors() {
    if (!ALICodeEditor_errorLayer) return;
    var lines = ALICodeEditor_srcLines();
    var byLine = {};
    ALICodeEditor_diags.forEach(function (d) {
        if (d.line >= 1 && d.line <= lines.length) (byLine[d.line] = byLine[d.line] || []).push(d);
    });
    var out = [];
    for (var i = 1; i <= lines.length; i++) {
        var text = lines[i - 1];
        var ds = byLine[i];
        if (!ds) { out.push(ALICodeEditor_escapeHtml(text)); continue; }
        ds.sort(function (a, b) { return a.col - b.col; });
        var html = '';
        var pos = 0;
        ds.forEach(function (d) {
            var r = ALICodeEditor_diagRange(text, d);
            if (r.start < pos) return; // overlapping ranges: first wins
            html += ALICodeEditor_escapeHtml(text.slice(pos, r.start));
            html += '<span class="' + (d.sev === 2 ? 'ali-err' : 'ali-err-warn') + '">' +
                (ALICodeEditor_escapeHtml(text.slice(r.start, r.end)) || ' ') + '</span>';
            pos = Math.max(r.end, r.start + 1);
        });
        html += ALICodeEditor_escapeHtml(text.slice(pos));
        out.push(html);
    }
    ALICodeEditor_patchLines(ALICodeEditor_errorLayer, out);
    // Diagnostics arrive async (after the compile round-trip) and may land while the view is
    // already scrolled; a content change doesn't inherit the textarea's scroll position,
    // so without this the squiggles paint at scrollTop/Left 0 until the next scroll event.
    ALICodeEditor_errorLayer.scrollTop = ALICodeEditor_textarea.scrollTop;
    ALICodeEditor_errorLayer.scrollLeft = ALICodeEditor_textarea.scrollLeft;
}

// Char range [start, end) of a diag on its line. Compiler diags often carry len 0/1;
// widen those to the whole identifier under the position so the squiggle is visible.
function ALICodeEditor_diagRange(text, d) {
    var start = Math.min(Math.max(0, d.col - 1), text.length);
    var end = Math.min(text.length, start + Math.max(1, d.len || 1));
    if (start >= text.length && text.length > 0) { start = text.length - 1; end = text.length; }
    if (end - start <= 1) {
        var wordChar = /[A-Za-z0-9_]/;
        if (text[start] === '"') {
            // quoted identifier ("Document No."): underline through the closing quote
            end = text.indexOf('"', start + 1);
            end = end === -1 ? text.length : end + 1;
        } else if (wordChar.test(text[start] || '')) {
            while (start > 0 && wordChar.test(text[start - 1])) start--;
            end = start;
            while (end < text.length && wordChar.test(text[end])) end++;
        }
    }
    return { start: start, end: end };
}

function ALICodeEditor_clearDiags() {
    if (!ALICodeEditor_diags.length) return;
    ALICodeEditor_diags = [];
    ALICodeEditor_renderErrors();
    ALICodeEditor_hideErrorTip();
}

function ALICodeEditor_currentLineIndent(text, caret) {
    var lineStart = text.lastIndexOf('\n', caret - 1) + 1;
    var line = text.slice(lineStart, caret);
    var m = line.match(/^[ \t]*/);
    return m ? m[0] : '';
}
