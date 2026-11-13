// Connects a CodeMirror 5 editor to the language server worker (`lsp-worker.js`):
// diagnostics (lint addon), completion (show-hint addon), hover and formatting.
//
// CodeMirror positions (`line`, `ch`) count UTF-16 code units, which is the position encoding the server
// uses for a client that does not ask for another one. So positions pass through unchanged.

function createLspClient(editor, opts) {
    const onStatus = (opts && opts.onStatus) || (() => {});
    const worker = new Worker('lsp-worker.js');
    const pending = new Map();
    let nextId = 1;
    let available = false;
    const whenReady = new Promise(resolve => {
        worker.addEventListener('message', (e) => {
            if (e.data.type === 'ready') {
                available = true;
                onStatus(true, '');
                resolve(true);
            } else if (e.data.type === 'unavailable') {
                onStatus(false, e.data.message);
                resolve(false);
            }
        });
    });

    worker.addEventListener('message', (e) => {
        const msg = e.data;
        if (msg.type !== 'result' && msg.type !== 'error') return;
        const entry = pending.get(msg.id);
        if (!entry) return;
        pending.delete(msg.id);
        if (msg.type === 'result') entry.resolve(msg);
        else entry.resolve({ diagnostics: [], results: entry.count ? new Array(entry.count).fill(null) : [] });
    });

    // Resolves to { diagnostics, results }. `results[i]` belongs to `requests[i]`.
    function batch(text, requests) {
        return whenReady.then(ok => {
            if (!ok) return { diagnostics: [], results: requests.map(() => null) };
            return new Promise(resolve => {
                const id = nextId++;
                pending.set(id, { resolve, count: requests.length });
                worker.postMessage({ type: 'batch', id, text, requests });
            });
        });
    }

    const toPos = p => CodeMirror.Pos(p.line, p.character);
    const fromPos = p => ({ line: p.line, character: p.ch });

    // ------------------------------------------------------------ diagnostics

    function lint(text, callback) {
        batch(text, []).then(res => {
            // An error in a function template is reported once for each instance. The reports differ in their
            // related information, which this client does not show, so the same place and text is kept once.
            const seen = new Set();
            const unique = res.diagnostics.filter(d => {
                const key = JSON.stringify([d.range, d.message]);
                if (seen.has(key)) return false;
                seen.add(key);
                return true;
            });
            callback(unique.map(d => {
                let from = toPos(d.range.start);
                let to = toPos(d.range.end);
                // An empty range has nothing to underline. Mark one character.
                if (from.line === to.line && from.ch === to.ch) {
                    if (from.ch > 0) from = CodeMirror.Pos(from.line, from.ch - 1);
                    else to = CodeMirror.Pos(to.line, to.ch + 1);
                }
                return { from, to, message: d.message, severity: d.severity === 2 ? 'warning' : 'error' };
            }));
        });
    }
    lint.async = true;

    // ------------------------------------------------------------ completion

    const WORD = /[A-Za-z0-9_@]/;
    // The items of the word that is being typed. Typing more of the same word filters them here.
    let completionCache = null;

    function hint(cm, callback) {
        const cursor = cm.getCursor();
        const line = cm.getLine(cursor.line);
        let start = cursor.ch;
        while (start > 0 && WORD.test(line.charAt(start - 1))) start--;
        const prefix = line.slice(start, cursor.ch);
        const from = CodeMirror.Pos(cursor.line, start);
        const key = cursor.line + ':' + start + ':' + line.slice(0, start);

        const show = (items) => {
            const lower = prefix.toLowerCase();
            const list = items
                .filter(item => item.label.toLowerCase().startsWith(lower))
                .map(item => ({
                    text: item.insertText || item.label,
                    displayText: item.label,
                    detail: item.detail || '',
                    render(elem, data, completion) {
                        const label = document.createElement('span');
                        label.className = 'hint-label';
                        label.textContent = completion.displayText;
                        elem.appendChild(label);
                        if (completion.detail) {
                            const detail = document.createElement('span');
                            detail.className = 'hint-detail';
                            detail.textContent = completion.detail;
                            elem.appendChild(detail);
                        }
                    },
                }));
            // A single item that is already typed in full is not a suggestion.
            if (list.length === 1 && list[0].text === prefix) return callback(null);
            callback(list.length ? { list, from, to: cursor } : null);
        };

        if (completionCache && completionCache.key === key) return show(completionCache.items);
        batch(cm.getValue(), [{ method: 'textDocument/completion', params: { position: fromPos(cursor) } }]).then(res => {
            const result = res.results[0];
            const items = !result ? [] : (Array.isArray(result) ? result : (result.items || []));
            completionCache = { key, items };
            show(items);
        });
    }
    hint.async = true;

    function complete(cm) {
        if (!available) return;
        cm.showHint({ hint, completeSingle: false });
    }

    editor.on('inputRead', (cm, change) => {
        if (!available || change.origin !== '+input' || cm.state.completionActive) return;
        const typed = change.text[change.text.length - 1];
        // After a `.` the members are offered, and after two characters of a name the names in scope.
        if (typed === '.') return complete(cm);
        if (typed.length !== 1 || !WORD.test(typed)) return;
        const cursor = cm.getCursor();
        const line = cm.getLine(cursor.line);
        let start = cursor.ch;
        while (start > 0 && WORD.test(line.charAt(start - 1))) start--;
        if (cursor.ch - start >= 2 && !/[0-9]/.test(line.charAt(start))) complete(cm);
    });
    editor.on('change', (cm, change) => {
        if (change.origin !== '+input' && change.origin !== '+delete') completionCache = null;
    });

    // ------------------------------------------------------------ hover

    const tooltip = document.createElement('div');
    tooltip.className = 'lsp-hover';
    tooltip.style.display = 'none';
    document.body.appendChild(tooltip);
    let hoverTimer = null;
    let hoverKey = '';
    let hoverSeq = 0;

    function hideHover() {
        clearTimeout(hoverTimer);
        hoverKey = '';
        hoverSeq++;
        tooltip.style.display = 'none';
    }

    // The server replies with markdown: fenced code and text. Rendered as text, never as HTML.
    function renderHover(contents) {
        let value = '';
        if (typeof contents === 'string') value = contents;
        else if (Array.isArray(contents)) value = contents.map(c => (typeof c === 'string' ? c : c.value)).join('\n\n');
        else if (contents) value = contents.value || '';
        tooltip.textContent = '';
        const parts = value.split(/```[a-z]*\n?/);
        parts.forEach((part, i) => {
            const text = part.trim();
            if (!text) return;
            const elem = document.createElement(i % 2 === 1 ? 'pre' : 'div');
            elem.textContent = text;
            tooltip.appendChild(elem);
        });
        return tooltip.childNodes.length > 0;
    }

    const wrapper = editor.getWrapperElement();
    wrapper.addEventListener('mousemove', (e) => {
        if (!available || e.buttons !== 0) return hideHover();
        const pos = editor.coordsChar({ left: e.clientX, top: e.clientY }, 'window');
        const word = editor.findWordAt(pos);
        const text = editor.getRange(word.anchor, word.head);
        // `coordsChar` snaps to the nearest character. Past the end of a line there is nothing to describe.
        const lineLength = editor.getLine(pos.line).length;
        if (pos.outside || pos.ch >= lineLength || !/^[A-Za-z_@][A-Za-z0-9_@]*$/.test(text)) return hideHover();
        const key = word.anchor.line + ':' + word.anchor.ch + ':' + text;
        if (key === hoverKey) return;
        hideHover();
        hoverKey = key;
        const seq = hoverSeq;
        const x = e.clientX;
        const y = e.clientY;
        hoverTimer = setTimeout(() => {
            batch(editor.getValue(), [{ method: 'textDocument/hover', params: { position: fromPos(pos) } }]).then(res => {
                if (seq !== hoverSeq) return;
                const result = res.results[0];
                if (!result || !renderHover(result.contents)) return;
                tooltip.style.display = 'block';
                const width = tooltip.offsetWidth;
                const height = tooltip.offsetHeight;
                tooltip.style.left = Math.max(4, Math.min(x + 8, window.innerWidth - width - 8)) + 'px';
                tooltip.style.top = (y + 18 + height > window.innerHeight ? y - height - 8 : y + 18) + 'px';
            });
        }, 350);
    });
    wrapper.addEventListener('mouseleave', hideHover);
    editor.on('change', hideHover);
    editor.on('scroll', hideHover);

    // ------------------------------------------------------------ formatting

    // Resolves to whether the document was formatted. A document with a syntax error is not.
    function format() {
        const text = editor.getValue();
        const params = { options: { tabSize: 4, insertSpaces: true } };
        return batch(text, [{ method: 'textDocument/formatting', params }]).then(res => {
            const edits = res.results[0];
            if (!Array.isArray(edits)) return false;
            if (editor.getValue() !== text) return false;
            editor.operation(() => {
                // Applied from the end so that the positions of the earlier edits stay valid.
                const sorted = edits.slice().sort((a, b) =>
                    b.range.start.line - a.range.start.line || b.range.start.character - a.range.start.character);
                for (const edit of sorted) {
                    editor.replaceRange(edit.newText, toPos(edit.range.start), toPos(edit.range.end), 'format');
                }
            });
            return true;
        });
    }

    return { lint, complete, format, whenReady };
}
