// The tests that run inside VS Code. They use the editor's own commands, so what is checked is what a user
// gets: the extension starts the server, and the providers answer through the language client.

const assert = require('assert');
const path = require('path');
const vscode = require('vscode');

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/** Polls until `fn` returns something truthy. */
async function until(what, fn, timeout = 20000) {
    const start = Date.now();
    for (;;) {
        const res = await fn();
        if (res) return res;
        if (Date.now() - start > timeout) throw new Error(`Timed out waiting for ${what}.`);
        await sleep(100);
    }
}

function positionOf(doc, needle, delta = 0) {
    const offset = doc.getText().indexOf(needle);
    assert.ok(offset >= 0, `"${needle}" is in the document`);
    return doc.positionAt(offset + delta);
}

function hoverText(hovers) {
    return hovers.map((h) => h.contents.map((c) => (typeof c === 'string' ? c : c.value)).join('\n')).join('\n');
}

async function edit(doc, text) {
    const all = new vscode.Range(doc.positionAt(0), doc.positionAt(doc.getText().length));
    const e = new vscode.WorkspaceEdit();
    e.replace(doc.uri, all, text);
    assert.ok(await vscode.workspace.applyEdit(e));
}

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

let doc;
let original;

test('The extension activates on a Cyber file and the server publishes diagnostics', async () => {
    const folder = vscode.workspace.workspaceFolders[0].uri.fsPath;
    doc = await vscode.workspace.openTextDocument(path.join(folder, 'main.cy'));
    assert.strictEqual(doc.languageId, 'cyber');
    await vscode.window.showTextDocument(doc);
    original = doc.getText();

    // No error yet. An edit adds two, in different bodies.
    await edit(doc, original.replace('return total', 'return total + nope1') + 'print(nope2)\n');
    const diags = await until('diagnostics', () => {
        const d = vscode.languages.getDiagnostics(doc.uri);
        return d.length >= 2 ? d : null;
    });
    const messages = diags.map((d) => d.message).sort();
    assert.deepStrictEqual(messages, ['Undeclared variable `nope1`.', 'Undeclared variable `nope2`.']);
    assert.ok(diags.every((d) => d.source === 'cyber' && d.severity === vscode.DiagnosticSeverity.Error));
    const first = diags.find((d) => d.message.includes('nope1'));
    assert.strictEqual(doc.getText(first.range), 'nope1');

    // Fixed again: the diagnostics go away.
    await edit(doc, original);
    await until('no diagnostics', () => vscode.languages.getDiagnostics(doc.uri).length === 0);
});

test('Hover', async () => {
    let hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', doc.uri, positionOf(doc, 'add(1', 1));
    assert.ok(hoverText(hovers).includes('fn add(first int, second int) -> int'), hoverText(hovers));
    hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', doc.uri, positionOf(doc, 'n := add'));
    assert.ok(hoverText(hovers).includes('n int'), hoverText(hovers));
});

test('Go to definition, in the document and in a module', async () => {
    let defs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', doc.uri, positionOf(doc, 'add(1', 1));
    assert.strictEqual(defs.length, 1);
    assert.strictEqual((defs[0].uri || defs[0].targetUri).fsPath, doc.uri.fsPath);
    assert.strictEqual((defs[0].range || defs[0].targetRange).start.line, positionOf(doc, 'fn add').line);

    defs = await vscode.commands.executeCommand('vscode.executeDefinitionProvider', doc.uri, positionOf(doc, 'twice', 1));
    assert.strictEqual(defs.length, 1);
    assert.strictEqual(path.basename((defs[0].uri || defs[0].targetUri).fsPath), 'lib.cy');
});

test('References and highlights', async () => {
    const refs = await vscode.commands.executeCommand('vscode.executeReferenceProvider', doc.uri, positionOf(doc, 'total :='));
    assert.strictEqual(refs.length, 2);
    const marks = await vscode.commands.executeCommand('vscode.executeDocumentHighlights', doc.uri, positionOf(doc, 'first +'));
    assert.strictEqual(marks.length, 2);
});

test('References across files and workspace symbols', async () => {
    // `lib.cy` is not open. The use here and the declaration there are both found.
    const refs = await vscode.commands.executeCommand('vscode.executeReferenceProvider', doc.uri, positionOf(doc, 'twice', 1));
    const files = refs.map((r) => path.basename(r.uri.fsPath)).sort();
    assert.deepStrictEqual(files, ['lib.cy', 'main.cy']);

    const syms = await vscode.commands.executeCommand('vscode.executeWorkspaceSymbolProvider', 'twi');
    assert.ok(syms.some((s) => s.name === 'twice' && path.basename(s.location.uri.fsPath) === 'lib.cy'), JSON.stringify(syms.map((s) => s.name)));
    const all = await vscode.commands.executeCommand('vscode.executeWorkspaceSymbolProvider', 'scale');
    assert.ok(all.some((s) => s.name === 'Vec2.scale'));
});

test('Semantic tokens', async () => {
    const legend = await vscode.commands.executeCommand('vscode.provideDocumentSemanticTokensLegend', doc.uri);
    assert.ok(legend.tokenTypes.includes('method') && legend.tokenTypes.includes('namespace'));
    const tokens = await vscode.commands.executeCommand('vscode.provideDocumentSemanticTokens', doc.uri);
    assert.ok(tokens.data.length >= 5 * 10, `tokens: ${tokens.data.length / 5}`);
    // Decode to (line, char, type name) and look for the method call and the module name.
    const found = [];
    let line = 0;
    let char = 0;
    for (let i = 0; i < tokens.data.length; i += 5) {
        if (tokens.data[i] !== 0) char = 0;
        line += tokens.data[i];
        char += tokens.data[i + 1];
        const text = doc.getText(new vscode.Range(line, char, line, char + tokens.data[i + 2]));
        found.push(`${text}:${legend.tokenTypes[tokens.data[i + 3]]}`);
    }
    for (const want of ['scale:method', 'lib:namespace', 'twice:function', 'Vec2:type', 'x:property', 'n:variable']) {
        assert.ok(found.includes(want), `${want} in ${found}`);
    }
});

test('Rename of a local, and no rename of a function', async () => {
    const edits = await vscode.commands.executeCommand('vscode.executeDocumentRenameProvider', doc.uri, positionOf(doc, 'total :='), 'sum_');
    const changes = edits.entries();
    assert.strictEqual(changes.length, 1);
    assert.strictEqual(changes[0][1].length, 2);
    assert.ok(changes[0][1].every((e) => e.newText === 'sum_'));

    // The editor asks whether the place can be renamed first, and the server says no for a function.
    await assert.rejects(
        () => vscode.commands.executeCommand('vscode.executeDocumentRenameProvider', doc.uri, positionOf(doc, 'add(1', 1), 'plus'),
        /can't be renamed|local variable or a parameter/
    );
});

test('Outline and folding', async () => {
    const syms = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', doc.uri);
    const names = syms.map((s) => s.name);
    for (const name of ['Vec2', 'Vec2.scale', 'add', 'v', 'n']) {
        assert.ok(names.includes(name), `${name} in ${names}`);
    }
    assert.deepStrictEqual(syms.find((s) => s.name === 'Vec2').children.map((s) => s.name), ['x', 'y']);
    const folds = await vscode.commands.executeCommand('vscode.executeFoldingRangeProvider', doc.uri);
    assert.ok(folds.some((f) => f.start === positionOf(doc, 'type Vec2').line));
});

test('Completion and signature help while typing', async () => {
    // The document does not parse while the line ends in the `.` or in the open bracket.
    await edit(doc, original + 'w := v.');
    let end = doc.positionAt(doc.getText().length);
    let list = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', doc.uri, end, '.');
    let labels = list.items.map((i) => (typeof i.label === 'string' ? i.label : i.label.label));
    assert.ok(labels.includes('x') && labels.includes('y') && labels.includes('scale'), String(labels));
    const scale = list.items.find((i) => (i.label.label || i.label) === 'scale');
    assert.strictEqual(scale.detail, 'fn (&Vec2) scale(by float) -> float');
    assert.strictEqual(scale.kind, vscode.CompletionItemKind.Method);

    await edit(doc, original + 'w := ');
    end = doc.positionAt(doc.getText().length);
    list = await vscode.commands.executeCommand('vscode.executeCompletionItemProvider', doc.uri, end);
    labels = list.items.map((i) => (typeof i.label === 'string' ? i.label : i.label.label));
    for (const name of ['v', 'n', 'add', 'Vec2', 'lib', 'print']) {
        assert.ok(labels.includes(name), `${name} is offered`);
    }

    await edit(doc, original + 'w := add(1, ');
    end = doc.positionAt(doc.getText().length);
    const help = await vscode.commands.executeCommand('vscode.executeSignatureHelpProvider', doc.uri, end, ',');
    assert.strictEqual(help.signatures[0].label, 'fn add(first int, second int) -> int');
    assert.strictEqual(help.signatures[0].parameters.length, 2);
    assert.strictEqual(help.activeParameter, 1);

    await edit(doc, original);
});

test('Format Document', async () => {
    await edit(doc, original.replace('fn add(first int, second int) -> int:', 'fn add(first int,second int)->int:'));
    const edits = await vscode.commands.executeCommand('vscode.executeFormatDocumentProvider', doc.uri, { tabSize: 4, insertSpaces: true });
    // The server sends one edit for the whole document and the editor reduces it to the parts that differ.
    assert.ok(edits.length >= 1);
    const e = new vscode.WorkspaceEdit();
    e.set(doc.uri, edits);
    assert.ok(await vscode.workspace.applyEdit(e));
    assert.strictEqual(doc.getText(), original);
});

let hdoc;

test('Lint diagnostics: an unused module, an unused local and a scope exit', async () => {
    const folder = vscode.workspace.workspaceFolders[0].uri.fsPath;
    hdoc = await vscode.workspace.openTextDocument(path.join(folder, 'hints.cy'));
    await vscode.window.showTextDocument(hdoc);
    const diags = await until('lint diagnostics', () => {
        const d = vscode.languages.getDiagnostics(hdoc.uri);
        return d.length >= 3 ? d : null;
    });
    const byCode = (code) => diags.find((d) => (d.code && d.code.value !== undefined ? d.code.value : d.code) === code);

    const use = byCode('unused-use');
    assert.strictEqual(use.message, 'The module `math` is never used.');
    assert.strictEqual(use.severity, vscode.DiagnosticSeverity.Warning);
    assert.deepStrictEqual(use.tags, [vscode.DiagnosticTag.Unnecessary]);

    const local = byCode('unused-local');
    assert.strictEqual(local.message, '`spare` is never used. Prefix it with `_` to keep it.');
    assert.strictEqual(hdoc.getText(local.range), 'spare');

    const exit = byCode('scope-exit');
    assert.strictEqual(exit.severity, vscode.DiagnosticSeverity.Information);
    assert.strictEqual(hdoc.getText(exit.range), 'return');
    assert.strictEqual(exit.range.start.line, positionOf(hdoc, 'return 1').line);
});

test('Quick fixes for the lint diagnostics and for a compile error', async () => {
    const fixesAt = async (needle) => {
        const at = positionOf(hdoc, needle);
        const actions = await vscode.commands.executeCommand('vscode.executeCodeActionProvider', hdoc.uri, new vscode.Range(at, at));
        return actions.filter((a) => a.kind && a.kind.value === 'quickfix');
    };
    let fixes = await fixesAt('spare');
    assert.deepStrictEqual(fixes.map((a) => a.title), ['Prefix `spare` with `_`']);
    let edits = fixes[0].edit.get(hdoc.uri);
    assert.strictEqual(edits[0].newText, '_');
    assert.deepStrictEqual(edits[0].range.start, positionOf(hdoc, 'spare'));

    fixes = await fixesAt('use math');
    assert.deepStrictEqual(fixes.map((a) => a.title), ['Remove `use math`']);
    edits = fixes[0].edit.get(hdoc.uri);
    assert.strictEqual(edits[0].newText, '');
    assert.strictEqual(edits[0].range.start.line, 0);
    assert.strictEqual(edits[0].range.end.line, 1);

    // The compiler sends the fix with the error, and the editor applies it as it is.
    const original = hdoc.getText();
    await edit(hdoc, 'use math\nprint(math.isNaN(1.0))\n');
    await until('the compile error', () => vscode.languages.getDiagnostics(hdoc.uri).some((d) => d.severity === vscode.DiagnosticSeverity.Error));
    fixes = await fixesAt('isNaN');
    assert.deepStrictEqual(fixes.map((a) => a.title), ['Change to `is_nan`']);
    assert.ok(await vscode.workspace.applyEdit(fixes[0].edit));
    assert.strictEqual(hdoc.getText(), 'use math\nprint(math.is_nan(1.0))\n');
    await until('no errors after the fix', () => !vscode.languages.getDiagnostics(hdoc.uri).some((d) => d.severity === vscode.DiagnosticSeverity.Error));

    await edit(hdoc, original);
    await until('the lint diagnostics again', () => vscode.languages.getDiagnostics(hdoc.uri).length >= 3);
});

test('Inlay hints: inferred types, the statement that waits for fibers and parameter names', async () => {
    const all = new vscode.Range(0, 0, hdoc.lineCount, 0);
    const hints = await vscode.commands.executeCommand('vscode.executeInlayHintProvider', hdoc.uri, all);
    const label = (h) => (typeof h.label === 'string' ? h.label : h.label.map((p) => p.value).join(''));
    const at = (needle, delta) => hints.find((h) => h.position.isEqual(positionOf(hdoc, needle, delta)));

    const spare = at('spare', 'spare'.length);
    assert.ok(spare, JSON.stringify(hints.map(label)));
    assert.strictEqual(label(spare).trim(), 'int');
    assert.strictEqual(spare.kind, vscode.InlayHintKind.Type);
    assert.ok(at('total :=', 'total'.length));

    const waits = hints.find((h) => label(h).includes('waits for fibers'));
    assert.ok(waits, JSON.stringify(hints.map(label)));
    assert.deepStrictEqual(waits.position, positionOf(hdoc, 'return 1', 'return 1'.length));

    // The parameter names before the arguments of `s.start(step, {1})`.
    const func = at('step, {1}', 0);
    assert.ok(func, JSON.stringify(hints.map(label)));
    assert.strictEqual(label(func), 'func:');
    assert.strictEqual(func.kind, vscode.InlayHintKind.Parameter);
    assert.strictEqual(label(at('{1})', 0)), 'args:');
});

test('Hover shows the doc comment of the declaration', async () => {
    const hovers = await vscode.commands.executeCommand('vscode.executeHoverProvider', hdoc.uri, positionOf(hdoc, 'halve(4', 1));
    const text = hoverText(hovers);
    assert.ok(text.includes('fn halve(n int) -> int'), text);
    assert.ok(text.includes('Halves a number.'), text);
});

test('Every syntax error gets a diagnostic', async () => {
    const original = hdoc.getText();
    await edit(hdoc, 'fn a():\n    x := )\n\nfn b():\n    y := ]\n\nprint(1 +)\n');
    const diags = await until('three syntax errors', () => {
        const d = vscode.languages.getDiagnostics(hdoc.uri).filter((x) => x.severity === vscode.DiagnosticSeverity.Error);
        return d.length >= 3 ? d : null;
    });
    assert.deepStrictEqual(diags.map((d) => d.range.start.line).sort(), [1, 4, 6]);
    // The outline keeps the declarations that parse.
    const syms = await vscode.commands.executeCommand('vscode.executeDocumentSymbolProvider', hdoc.uri);
    assert.ok(syms.some((s) => s.name === 'a') && syms.some((s) => s.name === 'b'), JSON.stringify(syms.map((s) => s.name)));
    await edit(hdoc, original);
});

test('The server is restarted by the command and answers again', async () => {
    await vscode.commands.executeCommand('cyber.restartServer');
    const hovers = await until('a hover after the restart', async () => {
        const h = await vscode.commands.executeCommand('vscode.executeHoverProvider', doc.uri, positionOf(doc, 'add(1', 1));
        return h.length > 0 ? h : null;
    });
    assert.ok(hoverText(hovers).includes('fn add('));
});

exports.run = async function run() {
    let failed = 0;
    for (const t of tests) {
        try {
            await t.fn();
            console.log(`  ok    ${t.name}`);
        } catch (err) {
            failed += 1;
            console.log(`  FAIL  ${t.name}\n        ${String(err && err.stack ? err.stack : err).split('\n').join('\n        ')}`);
        }
    }
    console.log(`${tests.length - failed} of ${tests.length} passed`);
    if (failed > 0) throw new Error(`${failed} test(s) failed.`);
};
