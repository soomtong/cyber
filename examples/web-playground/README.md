## Cyber Web Playground

A static page that runs Cyber in the browser. It needs no server besides a file host such as GitHub Pages.

The page runs the WASI build of the CLI (`cyber-wasi.wasm`) in a Web Worker:

* `wasi.js` is a minimal WASI host with an in-memory file system. It captures the output of the program.
* `worker.js` runs `cyber ./main.cy` for each run. The Stop button ends the worker, which stops a program that does not end.
* `examples.js` holds the example programs. `cyber-mode.js` is the CodeMirror mode for the editor.

The WebAssembly build has no threads (`spawn`), no FFI and no file system (`os`).

## Getting started.

Put the WASI build next to the page as `cyber.wasm`. Either download it from a release:
```sh
task playground:wasm            # The `latest` release. `TAG=0.4.9` picks another one.
```
or build it from this checkout:
```sh
task playground:build
```

Start a local file server in this directory:
```sh
task playground:serve           # python3 -m http.server 8000 --directory examples/web-playground
```

Open your browser and visit `http://localhost:8000/index.html`. The page must be served over HTTP: a worker does not load from a `file://` URL.

## Deployment.

`.github/workflows/gen-docs.yml` copies this directory and the wasm of the `latest` release to `play/` of the docs site.
