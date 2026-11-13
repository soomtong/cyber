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
