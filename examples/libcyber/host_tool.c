#include <stdio.h>
#include <string.h>
#include "cyber.h"

// This example shows the embedding pattern for an agent loop:
// the host exposes a `tool(name, args) -> str` function, runs a script that calls it,
// recovers from compile errors and panics, and keeps reusing the same VM.

// Build `libcyber.a` with Zig:
// zig build lib

// Compile this program with any C compiler:
// clang -o host_tool host_tool.c -I ../../src/include ../../zig-out/lib/libcyber.a

// Host implementation of `agent.tool`. Both params arrive as `str`, the result is a new `str`.
CLRet tool(CLThread* t) {
    CLstr* ret = cl_thread_ret(t, sizeof(CLstr));
    CLBytes name = cl_str_bytes(cl_thread_str(t));
    CLBytes args = cl_str_bytes(cl_thread_str(t));

    char buf[256];
    int n = snprintf(buf, sizeof buf, "{\"tool\":\"%.*s\",\"args\":%.*s,\"ok\":true}",
        (int)name.len, name.ptr, (int)args.len, args.ptr);
    *ret = cl_str_init(t, (CLBytes){ buf, (size_t)n });
    return CL_RET_OK;
}

// Only the `agent` module is provided by the host. Everything else falls back to the builtin
// modules compiled into libcyber (`core`, `math`, `io`, ...). `os` is not part of the library.
bool loader(CLVM* vm, CLSym* mod, CLBytes uri, CLLoaderResult* res) {
    if (uri.len == 5 && strncmp("agent", uri.ptr, 5) == 0) {
        cl_mod_add_func(mod, CL_BYTES("tool"), CL_BIND_FUNC(tool));
        res->src = CL_BYTES("#[bind] fn tool(name str, args str) -> str\n");
        res->manage_src = false;
        return true;
    }
    return cl_default_loader(vm, mod, uri, res);
}

void printer(CLThread* t, CLBytes str) {
    if (str.len == 1 && str.ptr[0] == '\n') {
        return;
    }
    printf("My print: %.*s\n", (int)str.len, str.ptr);
}

// Evaluates one script and reports the outcome. Returns the result code so callers can assert on it.
CLResultCode run(CLVM* vm, const char* label, char* src) {
    CLEvalResult res;
    CLResultCode code = cl_vm_eval(vm, CL_BYTES(src), &res);
    if (code == CL_SUCCESS) {
        printf("%s: Success!\n", label);
    } else {
        CLBytes summary = cl_vm_error_summary(vm);
        printf("%s: %.*s\n", label, (int)summary.len, summary.ptr);
        cl_vm_freeb(vm, summary);
    }
    return code;
}

int main() {
    CLVM* vm = cl_vm_init();
    cl_vm_set_loader(vm, loader);
    cl_vm_set_printer(vm, printer);

    int failed = 0;

    // Script calls into the host.
    failed |= run(vm, "tool call",
        "use agent\n"
        "r := agent.tool('read_file', '{\"path\":\"/etc/hosts\"}')\n"
        "print(r)\n") != CL_SUCCESS;

    // A compile error and a panic leave the VM usable.
    failed |= run(vm, "compile error", "print(undefined_thing)\n") != CL_ERROR_COMPILE;
    failed |= run(vm, "panic", "a := Array[int]{1, 2}\nprint(a[5])\n") != CL_ERROR_PANIC;
    failed |= run(vm, "after errors", "print('still alive')\n") != CL_SUCCESS;

    // `os` is a CLI module, so a library script cannot reach the file system through it.
    failed |= run(vm, "use os", "use os\nprint(os.cwd())\n") != CL_ERROR_COMPILE;

    // A script with `main` followed by a script without one.
    failed |= run(vm, "main", "fn main() -> int:\n  return 42\n") != CL_SUCCESS;
    failed |= run(vm, "body after main", "print('body')\n") != CL_SUCCESS;

    // Check that all references were accounted for. (Should be 0)
    CLThread* t = cl_vm_main_thread(vm);
    size_t live = cl_thread_count_objects(t);
    printf("Live objects: %zu\n", live);
    failed |= live != 0;

    cl_vm_deinit(vm);
    return failed;
}
