// A minimal WASI (snapshot preview1) host for running `cyber-wasi.wasm` in a browser worker or in Node.
// It provides an in-memory file system, captured stdout/stderr, a clock and random bytes.
// There is no network and no access to real files.

const ERRNO_SUCCESS = 0;
const ERRNO_BADF = 8;
const ERRNO_EXIST = 20;
const ERRNO_INVAL = 28;
const ERRNO_NOENT = 44;
const ERRNO_NOSYS = 52;

const FILETYPE_CHARACTER_DEVICE = 2;
const FILETYPE_DIRECTORY = 3;
const FILETYPE_REGULAR_FILE = 4;

const OFLAGS_CREAT = 1;
const OFLAGS_DIRECTORY = 2;
const OFLAGS_EXCL = 4;
const OFLAGS_TRUNC = 8;

const PREOPEN_FD = 3;
const PREOPEN_NAME = '.';

// Thrown by `proc_exit` to unwind the WebAssembly stack.
class WasiExit extends Error {
    constructor(code) {
        super('exit ' + code);
        this.code = code;
    }
}

function normalizePath(path) {
    const parts = [];
    for (const part of path.split('/')) {
        if (part === '' || part === '.') continue;
        if (part === '..') parts.pop();
        else parts.push(part);
    }
    return parts.join('/');
}

// `opts.args`: the argument list, starting with the program name.
// `opts.files`: an object that maps a path to a string or a `Uint8Array`.
// `opts.stdout(bytes)` and `opts.stderr(bytes)`: receive the `Uint8Array` of each write.
function createWasi(opts) {
    const args = opts.args || ['cyber'];
    const onStdout = opts.stdout || (() => {});
    const onStderr = opts.stderr || (() => {});
    const encoder = new TextEncoder();
    const decoder = new TextDecoder();

    // Path -> { data: Uint8Array }.
    const files = new Map();
    for (const [path, content] of Object.entries(opts.files || {})) {
        const data = typeof content === 'string' ? encoder.encode(content) : content;
        files.set(normalizePath(path), { data });
    }

    // Fd -> { file, pos } or { dir }.
    const fds = new Map();
    let nextFd = PREOPEN_FD + 1;
    let memory = null;

    const view = () => new DataView(memory.buffer);
    const bytes = (ptr, len) => new Uint8Array(memory.buffer, ptr, len);
    const readString = (ptr, len) => decoder.decode(bytes(ptr, len).slice());
    const nowNs = () => BigInt(Math.round((performance.timeOrigin + performance.now()) * 1e6));

    function isDir(path) {
        if (path === '') return true;
        const prefix = path + '/';
        for (const name of files.keys()) {
            if (name.startsWith(prefix)) return true;
        }
        return false;
    }

    function writeFilestat(ptr, filetype, size) {
        const v = view();
        bytes(ptr, 64).fill(0);
        v.setUint8(ptr + 16, filetype);
        v.setBigUint64(ptr + 24, 1n, true);
        v.setBigUint64(ptr + 32, BigInt(size), true);
    }

    function readIovs(iovs, iovsLen, fn) {
        const v = view();
        let total = 0;
        for (let i = 0; i < iovsLen; i++) {
            const ptr = v.getUint32(iovs + i * 8, true);
            const len = v.getUint32(iovs + i * 8 + 4, true);
            const n = fn(ptr, len);
            total += n;
            if (n < len) break;
        }
        return total;
    }

    function fileRead(entry, pos, ptr, len) {
        const data = entry.file.data;
        const n = Math.max(0, Math.min(len, data.length - pos));
        bytes(ptr, n).set(data.subarray(pos, pos + n));
        return n;
    }

    function fileWrite(entry, pos, ptr, len) {
        const file = entry.file;
        const end = pos + len;
        if (end > file.data.length) {
            const grown = new Uint8Array(end);
            grown.set(file.data);
            file.data = grown;
        }
        file.data.set(bytes(ptr, len), pos);
        return len;
    }

    const nosys = () => ERRNO_NOSYS;

    const imports = {
        args_sizes_get(argcPtr, bufSizePtr) {
            const v = view();
            v.setUint32(argcPtr, args.length, true);
            v.setUint32(bufSizePtr, args.reduce((sum, a) => sum + encoder.encode(a).length + 1, 0), true);
            return ERRNO_SUCCESS;
        },
        args_get(argvPtr, bufPtr) {
            const v = view();
            for (const arg of args) {
                const data = encoder.encode(arg);
                v.setUint32(argvPtr, bufPtr, true);
                bytes(bufPtr, data.length).set(data);
                v.setUint8(bufPtr + data.length, 0);
                argvPtr += 4;
                bufPtr += data.length + 1;
            }
            return ERRNO_SUCCESS;
        },
        environ_sizes_get(countPtr, bufSizePtr) {
            const v = view();
            v.setUint32(countPtr, 0, true);
            v.setUint32(bufSizePtr, 0, true);
            return ERRNO_SUCCESS;
        },
        environ_get() {
            return ERRNO_SUCCESS;
        },
        clock_res_get(id, resPtr) {
            view().setBigUint64(resPtr, 1000n, true);
            return ERRNO_SUCCESS;
        },
        clock_time_get(id, precision, timePtr) {
            view().setBigUint64(timePtr, nowNs(), true);
            return ERRNO_SUCCESS;
        },
        random_get(ptr, len) {
            // `getRandomValues` takes at most 65536 bytes and no view of a shared buffer.
            for (let off = 0; off < len; off += 65536) {
                const chunk = new Uint8Array(Math.min(65536, len - off));
                crypto.getRandomValues(chunk);
                bytes(ptr + off, chunk.length).set(chunk);
            }
            return ERRNO_SUCCESS;
        },
        proc_exit(code) {
            throw new WasiExit(code);
        },
        poll_oneoff(inPtr, outPtr, nsubs, neventsPtr) {
            // Only a single clock subscription (a sleep) is supported. It waits by spinning.
            const v = view();
            if (nsubs !== 1 || v.getUint8(inPtr + 8) !== 0) return ERRNO_NOSYS;
            const userdata = v.getBigUint64(inPtr, true);
            let timeout = v.getBigUint64(inPtr + 24, true);
            const absolute = (v.getUint16(inPtr + 40, true) & 1) !== 0;
            if (!absolute) timeout += nowNs();
            while (nowNs() < timeout) {}
            bytes(outPtr, 32).fill(0);
            view().setBigUint64(outPtr, userdata, true);
            view().setUint32(neventsPtr, 1, true);
            return ERRNO_SUCCESS;
        },

        fd_prestat_get(fd, ptr) {
            if (fd !== PREOPEN_FD) return ERRNO_BADF;
            const v = view();
            v.setUint8(ptr, 0);
            v.setUint32(ptr + 4, PREOPEN_NAME.length, true);
            return ERRNO_SUCCESS;
        },
        fd_prestat_dir_name(fd, ptr, len) {
            if (fd !== PREOPEN_FD) return ERRNO_BADF;
            bytes(ptr, len).set(encoder.encode(PREOPEN_NAME).subarray(0, len));
            return ERRNO_SUCCESS;
        },
        fd_fdstat_get(fd, ptr) {
            let filetype;
            if (fd <= 2) filetype = FILETYPE_CHARACTER_DEVICE;
            else if (fd === PREOPEN_FD) filetype = FILETYPE_DIRECTORY;
            else if (fds.has(fd)) filetype = fds.get(fd).dir !== undefined ? FILETYPE_DIRECTORY : FILETYPE_REGULAR_FILE;
            else return ERRNO_BADF;
            const v = view();
            bytes(ptr, 24).fill(0);
            v.setUint8(ptr, filetype);
            v.setBigUint64(ptr + 8, 0xffffffffffffffffn, true);
            v.setBigUint64(ptr + 16, 0xffffffffffffffffn, true);
            return ERRNO_SUCCESS;
        },
        fd_filestat_get(fd, ptr) {
            if (fd <= 2) {
                writeFilestat(ptr, FILETYPE_CHARACTER_DEVICE, 0);
            } else if (fd === PREOPEN_FD) {
                writeFilestat(ptr, FILETYPE_DIRECTORY, 0);
            } else if (fds.has(fd)) {
                const entry = fds.get(fd);
                if (entry.dir !== undefined) writeFilestat(ptr, FILETYPE_DIRECTORY, 0);
                else writeFilestat(ptr, FILETYPE_REGULAR_FILE, entry.file.data.length);
            } else {
                return ERRNO_BADF;
            }
            return ERRNO_SUCCESS;
        },
        path_filestat_get(fd, flags, pathPtr, pathLen, ptr) {
            const path = normalizePath(readString(pathPtr, pathLen));
            if (files.has(path)) writeFilestat(ptr, FILETYPE_REGULAR_FILE, files.get(path).data.length);
            else if (isDir(path)) writeFilestat(ptr, FILETYPE_DIRECTORY, 0);
            else return ERRNO_NOENT;
            return ERRNO_SUCCESS;
        },
        path_open(dirFd, dirFlags, pathPtr, pathLen, oflags, rightsBase, rightsInheriting, fdFlags, fdPtr) {
            const path = normalizePath(readString(pathPtr, pathLen));
            let entry;
            if (files.has(path)) {
                if (oflags & OFLAGS_DIRECTORY) return ERRNO_INVAL;
                if ((oflags & OFLAGS_CREAT) && (oflags & OFLAGS_EXCL)) return ERRNO_EXIST;
                const file = files.get(path);
                if (oflags & OFLAGS_TRUNC) file.data = new Uint8Array(0);
                entry = { file, pos: 0 };
            } else if (isDir(path)) {
                entry = { dir: path };
            } else if (oflags & OFLAGS_CREAT) {
                const file = { data: new Uint8Array(0) };
                files.set(path, file);
                entry = { file, pos: 0 };
            } else {
                return ERRNO_NOENT;
            }
            const fd = nextFd++;
            fds.set(fd, entry);
            view().setUint32(fdPtr, fd, true);
            return ERRNO_SUCCESS;
        },
        fd_close(fd) {
            fds.delete(fd);
            return ERRNO_SUCCESS;
        },
        fd_read(fd, iovs, iovsLen, nreadPtr) {
            let total = 0;
            if (fd !== 0) {
                const entry = fds.get(fd);
                if (!entry || entry.file === undefined) return ERRNO_BADF;
                total = readIovs(iovs, iovsLen, (ptr, len) => {
                    const n = fileRead(entry, entry.pos, ptr, len);
                    entry.pos += n;
                    return n;
                });
            }
            view().setUint32(nreadPtr, total, true);
            return ERRNO_SUCCESS;
        },
        fd_pread(fd, iovs, iovsLen, offset, nreadPtr) {
            const entry = fds.get(fd);
            if (!entry || entry.file === undefined) return ERRNO_BADF;
            let pos = Number(offset);
            const total = readIovs(iovs, iovsLen, (ptr, len) => {
                const n = fileRead(entry, pos, ptr, len);
                pos += n;
                return n;
            });
            view().setUint32(nreadPtr, total, true);
            return ERRNO_SUCCESS;
        },
        fd_write(fd, iovs, iovsLen, nwrittenPtr) {
            let total;
            if (fd === 1 || fd === 2) {
                const sink = fd === 1 ? onStdout : onStderr;
                total = readIovs(iovs, iovsLen, (ptr, len) => {
                    if (len > 0) sink(bytes(ptr, len).slice());
                    return len;
                });
            } else {
                const entry = fds.get(fd);
                if (!entry || entry.file === undefined) return ERRNO_BADF;
                total = readIovs(iovs, iovsLen, (ptr, len) => {
                    const n = fileWrite(entry, entry.pos, ptr, len);
                    entry.pos += n;
                    return n;
                });
            }
            view().setUint32(nwrittenPtr, total, true);
            return ERRNO_SUCCESS;
        },
        fd_pwrite(fd, iovs, iovsLen, offset, nwrittenPtr) {
            const entry = fds.get(fd);
            if (!entry || entry.file === undefined) return ERRNO_BADF;
            let pos = Number(offset);
            const total = readIovs(iovs, iovsLen, (ptr, len) => {
                const n = fileWrite(entry, pos, ptr, len);
                pos += n;
                return n;
            });
            view().setUint32(nwrittenPtr, total, true);
            return ERRNO_SUCCESS;
        },
        fd_seek(fd, offset, whence, newOffsetPtr) {
            const entry = fds.get(fd);
            if (!entry || entry.file === undefined) return ERRNO_BADF;
            let base = 0;
            if (whence === 1) base = entry.pos;
            else if (whence === 2) base = entry.file.data.length;
            const pos = base + Number(offset);
            if (pos < 0) return ERRNO_INVAL;
            entry.pos = pos;
            view().setBigUint64(newOffsetPtr, BigInt(pos), true);
            return ERRNO_SUCCESS;
        },
        fd_filestat_set_size(fd, size) {
            const entry = fds.get(fd);
            if (!entry || entry.file === undefined) return ERRNO_BADF;
            const resized = new Uint8Array(Number(size));
            resized.set(entry.file.data.subarray(0, resized.length));
            entry.file.data = resized;
            return ERRNO_SUCCESS;
        },
        fd_sync() {
            return ERRNO_SUCCESS;
        },
        fd_readdir(fd, bufPtr, bufLen, cookie, usedPtr) {
            view().setUint32(usedPtr, 0, true);
            return ERRNO_SUCCESS;
        },
        path_unlink_file(fd, pathPtr, pathLen) {
            return files.delete(normalizePath(readString(pathPtr, pathLen))) ? ERRNO_SUCCESS : ERRNO_NOENT;
        },

        fd_filestat_set_times: nosys,
        path_create_directory: nosys,
        path_filestat_set_times: nosys,
        path_link: nosys,
        path_readlink: nosys,
        path_remove_directory: nosys,
        path_rename: nosys,
        path_symlink: nosys,
    };

    return {
        imports: { wasi_snapshot_preview1: imports },
        // Runs `_start` and returns the exit code.
        start(instance) {
            memory = instance.exports.memory;
            try {
                instance.exports._start();
            } catch (err) {
                if (err instanceof WasiExit) return err.code;
                throw err;
            }
            return 0;
        },
    };
}

if (typeof module !== 'undefined') {
    module.exports = { createWasi };
}
