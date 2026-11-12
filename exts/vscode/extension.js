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

async function start() {
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
    client = new LanguageClient('cyber', 'Cyber Language Server', serverOptions, clientOptions);
    try {
        await client.start();
    } catch (err) {
        client = undefined;
        vscode.window.showWarningMessage(
            `The Cyber language server could not be started (${serverCommand()}). ` +
            'Build it with `zig build lsp` and set `cyber.lsp.path`, or turn off `cyber.lsp.enabled`.'
        );
    }
}

async function stop() {
    const running = client;
    client = undefined;
    if (running) {
        await running.stop();
    }
}

async function activate(context) {
    context.subscriptions.push(
        vscode.commands.registerCommand('cyber.restartServer', async () => {
            await stop();
            await start();
        }),
        vscode.workspace.onDidChangeConfiguration(async (event) => {
            if (event.affectsConfiguration('cyber.lsp')) {
                await stop();
                await start();
            }
        })
    );
    await start();
}

function deactivate() {
    return stop();
}

module.exports = { activate, deactivate };
