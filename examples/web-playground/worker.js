// Runs the Cyber CLI (`cyber.wasm`, the `cyber-wasi.wasm` release asset) off the main thread.
// A run is synchronous, so the page stops a program that does not end by terminating this worker.
//
// Messages to the worker:   { type: 'run', src }
// Messages from the worker: { type: 'ready', version } | { type: 'out' | 'err', text } |
//                           { type: 'done', code, ms } | { type: 'fail', message }

importScripts('wasi.js');

const SOURCE_PATH = './main.cy';
const decoder = new TextDecoder();

function runCli(module, args, files, onOut, onErr) {
    const wasi = createWasi({ args, files, stdout: onOut, stderr: onErr });
    const instance = new WebAssembly.Instance(module, wasi.imports);
    return wasi.start(instance);
}

const modulePromise = fetch('cyber.wasm').then(res => {
    if (!res.ok) throw new Error('Can not load cyber.wasm (HTTP ' + res.status + ').');
    return res.arrayBuffer();
}).then(buf => WebAssembly.compile(buf)).then(module => {
    let version = '';
    const collect = bytes => { version += decoder.decode(bytes); };
    runCli(module, ['cyber', 'version'], {}, collect, collect);
    postMessage({ type: 'ready', version: version.trim() });
    return module;
});

modulePromise.catch(err => postMessage({ type: 'fail', message: String(err.message || err) }));

onmessage = (e) => {
    if (e.data.type !== 'run') return;
    modulePromise.then(module => {
        const outDecoder = new TextDecoder();
        const errDecoder = new TextDecoder();
        const start = performance.now();
        let code;
        try {
            code = runCli(module, ['cyber', SOURCE_PATH], { [SOURCE_PATH]: e.data.src },
                bytes => postMessage({ type: 'out', text: outDecoder.decode(bytes, { stream: true }) }),
                bytes => postMessage({ type: 'err', text: errDecoder.decode(bytes, { stream: true }) }));
        } catch (err) {
            // A trap of the VM itself, for example a feature that the WebAssembly build does not have.
            postMessage({ type: 'err', text: 'The VM stopped: ' + String(err.message || err) + '\n' });
            code = 1;
        }
        postMessage({ type: 'done', code, ms: Math.round(performance.now() - start) });
    }).catch(() => {});
};
