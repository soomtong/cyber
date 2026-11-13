// Runs the extension in a real VS Code (downloaded on first use) against a built `cyber-lsp`.
// Usage: node test/runTest.js <path of cyber-lsp>
// On Linux without a display: xvfb-run -a node test/runTest.js <path of cyber-lsp>

const path = require('path');
const fs = require('fs');
const os = require('os');
const { runTests } = require('@vscode/test-electron');

async function main() {
    const server = process.argv[2] || process.env.CYBER_LSP;
    if (!server) {
        console.error('Usage: node test/runTest.js <path of cyber-lsp>');
        process.exit(2);
    }
    // A workspace of its own, so that the settings of the test do not touch the repository.
    const workspace = fs.mkdtempSync(path.join(os.tmpdir(), 'cyber-vscode-test-'));
    fs.mkdirSync(path.join(workspace, '.vscode'));
    fs.writeFileSync(
        path.join(workspace, '.vscode', 'settings.json'),
        JSON.stringify({ 'cyber.lsp.path': path.resolve(server) })
    );
    for (const name of fs.readdirSync(path.join(__dirname, 'workspace'))) {
        if (name.endsWith('.cy')) {
            fs.copyFileSync(path.join(__dirname, 'workspace', name), path.join(workspace, name));
        }
    }
    // VS Code listens on a socket in its user data directory, and the path of a socket is short (about 100
    // characters). The default is inside this directory, which can be deep.
    const userData = fs.mkdtempSync(path.join(os.tmpdir(), 'cy-ud-'));
    try {
        await runTests({
            extensionDevelopmentPath: path.resolve(__dirname, '..'),
            extensionTestsPath: path.resolve(__dirname, 'suite.js'),
            // `--no-sandbox` lets it run as root in a container.
            launchArgs: [workspace, `--user-data-dir=${userData}`, '--disable-extensions', '--disable-gpu', '--no-sandbox'],
        });
    } finally {
        fs.rmSync(workspace, { recursive: true, force: true });
        fs.rmSync(userData, { recursive: true, force: true });
    }
}

main().catch((err) => {
    console.error(err);
    process.exit(1);
});
