// Runs the language server (`cyber-lsp.wasm`, the WASI build of `cyber-lsp`) off the main thread.
//
// The server reads the Language Server Protocol from stdin and blocks there, which a worker can not do without
// shared memory. So the server is not kept running: each batch starts a fresh instance, opens the document,
// sends its requests and ends the server. A batch takes about 50 ms.
//
// Messages to the worker:   { type: 'batch', id, text, requests: [{ method, params }] }
// Messages from the worker: { type: 'ready' } | { type: 'unavailable', message } |
//                           { type: 'result', id, diagnostics, results } | { type: 'error', id, message }
// `results[i]` is the result of `requests[i]`, or null when the server replied with an error.
// `diagnostics` is the list that the server published for the document.

importScripts('wasi.js');

const DOCUMENT_URI = 'file:///main.cy';
const encoder = new TextEncoder();
const decoder = new TextDecoder();

function frame(message) {
    const body = encoder.encode(JSON.stringify(message));
    const header = encoder.encode('Content-Length: ' + body.length + '\r\n\r\n');
    const out = new Uint8Array(header.length + body.length);
    out.set(header);
    out.set(body, header.length);
    return out;
}

// Splits the output of the server into its messages. The lengths are in bytes.
function parseFrames(chunks) {
    let size = 0;
    for (const chunk of chunks) size += chunk.length;
    const all = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
        all.set(chunk, offset);
        offset += chunk.length;
    }
    const messages = [];
    let pos = 0;
    while (pos < all.length) {
        let headerEnd = -1;
        for (let i = pos; i + 3 < all.length; i++) {
            if (all[i] === 13 && all[i + 1] === 10 && all[i + 2] === 13 && all[i + 3] === 10) {
                headerEnd = i;
                break;
            }
        }
        if (headerEnd === -1) break;
        const match = /content-length:\s*(\d+)/i.exec(decoder.decode(all.subarray(pos, headerEnd)));
        if (!match) break;
        const bodyStart = headerEnd + 4;
        const bodyEnd = bodyStart + Number(match[1]);
        if (bodyEnd > all.length) break;
        messages.push(JSON.parse(decoder.decode(all.subarray(bodyStart, bodyEnd))));
        pos = bodyEnd;
    }
    return messages;
}

function runBatch(module, text, requests) {
    const messages = [
        { jsonrpc: '2.0', id: 0, method: 'initialize', params: { processId: null, rootUri: null, capabilities: {} } },
        { jsonrpc: '2.0', method: 'initialized', params: {} },
        {
            jsonrpc: '2.0',
            method: 'textDocument/didOpen',
            params: { textDocument: { uri: DOCUMENT_URI, languageId: 'cyber', version: 1, text } },
        },
    ];
    requests.forEach((request, i) => {
        const params = Object.assign({}, request.params, { textDocument: { uri: DOCUMENT_URI } });
        messages.push({ jsonrpc: '2.0', id: i + 1, method: request.method, params });
    });
    messages.push({ jsonrpc: '2.0', id: requests.length + 1, method: 'shutdown' });
    messages.push({ jsonrpc: '2.0', method: 'exit' });

    // The server gets one message per read. When it finds no further message buffered after `didOpen`,
    // it checks the document and publishes the diagnostics before it reads the next request.
    const frames = messages.map(frame);
    let frameIndex = 0;
    let framePos = 0;
    const stdin = (maxLen) => {
        if (frameIndex >= frames.length) return new Uint8Array(0);
        const current = frames[frameIndex];
        const data = current.subarray(framePos, framePos + maxLen);
        framePos += data.length;
        if (framePos >= current.length) {
            frameIndex++;
            framePos = 0;
        }
        return data;
    };

    const chunks = [];
    const wasi = createWasi({ args: ['cyber-lsp'], files: {}, stdin, stdout: bytes => chunks.push(bytes) });
    wasi.start(new WebAssembly.Instance(module, wasi.imports));

    const results = requests.map(() => null);
    let diagnostics = [];
    for (const message of parseFrames(chunks)) {
        if (message.method === 'textDocument/publishDiagnostics') {
            diagnostics = message.params.diagnostics || [];
        } else if (typeof message.id === 'number' && message.id >= 1 && message.id <= requests.length) {
            results[message.id - 1] = message.result === undefined ? null : message.result;
        }
    }
    return { diagnostics, results };
}

const modulePromise = fetch('cyber-lsp.wasm').then(res => {
    if (!res.ok) throw new Error('Can not load cyber-lsp.wasm (HTTP ' + res.status + ').');
    return res.arrayBuffer();
}).then(buf => WebAssembly.compile(buf)).then(module => {
    postMessage({ type: 'ready' });
    return module;
});

modulePromise.catch(err => postMessage({ type: 'unavailable', message: String(err.message || err) }));

onmessage = (e) => {
    const msg = e.data;
    if (msg.type !== 'batch') return;
    modulePromise.then(module => {
        try {
            const res = runBatch(module, msg.text, msg.requests || []);
            postMessage({ type: 'result', id: msg.id, diagnostics: res.diagnostics, results: res.results });
        } catch (err) {
            postMessage({ type: 'error', id: msg.id, message: String(err.message || err) });
        }
    }).catch(() => postMessage({ type: 'error', id: msg.id, message: 'The language server is not available.' }));
};
