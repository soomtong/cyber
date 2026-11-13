// The client of the Cyber language server. It starts `cyber-lsp` and leaves the rest to the protocol.
// Syntax highlighting does not depend on it: without the server the extension still colors the source.

const vscode = require('vscode');
const { LanguageClient, TransportKind } = require('vscode-languageclient/node');

/** @type {LanguageClient | undefined} */
let client;

function serverCommand() {
    const path = vscode.workspace.getConfiguration('cyber').get('lsp.path');
    return typeof path === 'string' && path.length > 0 ? path : 'cyber-lsp';
}

async function startClient() {
    if (!vscode.workspace.getConfiguration('cyber').get('lsp.enabled', true)) {
        return;
    }
    // The stdio transport adds `--stdio` to the arguments.
    const serverOptions = { command: serverCommand(), transport: TransportKind.stdio };
    const clientOptions = {
        // Documents that were never saved are checked too.
        documentSelector: [
            { scheme: 'file', language: 'cyber' },
            { scheme: 'untitled', language: 'cyber' },
        ],
    };
    const started = new LanguageClient('cyber', 'Cyber Language Server', serverOptions, clientOptions);
    client = started;
    try {
        await started.start();
    } catch (err) {
        // Only if no other client took its place meanwhile.
        if (client === started) {
            client = undefined;
        }
        vscode.window.showWarningMessage(
            `The Cyber language server could not be started (${serverCommand()}). ` +
            'Build it with `zig build lsp` and set `cyber.lsp.path`, or turn off `cyber.lsp.enabled`.'
        );
    }
}

async function stopClient() {
    const running = client;
    client = undefined;
    if (!running) {
        return;
    }
    try {
        await running.stop();
    } catch (err) {
        // A client that never came up has nothing to stop.
    }
}

// Starts and stops run one after another. A restart while the server is still starting, or two changes of
// the settings in a row, would otherwise leave a server running that nothing refers to.
let queue = Promise.resolve();

function enqueue(fn) {
    queue = queue.then(fn, fn);
    return queue;
}

const start = () => enqueue(startClient);
const stop = () => enqueue(stopClient);
const restart = () => enqueue(async () => {
    await stopClient();
    await startClient();
});

async function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand('cyber.restartServer', restart),
        vscode.workspace.onDidChangeConfiguration((event) => {
            if (event.affectsConfiguration('cyber.lsp')) {
                return restart();
            }
            return undefined;
        })
    );
    await start();
}

function deactivate() {
    return stop();
}

module.exports = { activate, deactivate };
