#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "cyber.h"

// This example shows the embedding pattern for an agent loop:
// the host exposes a `tool(name, args) -> str` function, runs a script that calls it,
// recovers from compile errors and panics, and keeps reusing the same VM.
// The VM takes its memory from the host's functions and a runaway script is stopped by a memory limit.

// Build `libcyber.a` with Zig:
// zig build lib

// Compile this program with any C compiler:
// clang -o host_tool host_tool.c -I ../../src/include ../../zig-out/lib/libcyber.a

// The memory of the VM comes from these two functions. This host only counts what the VM holds.
// A host whose scripts `spawn` threads has to make them thread safe.
typedef struct HostMem {
    size_t held;
    size_t blocks;
} HostMem;

void* host_alloc(void* ctx, size_t size, size_t align) {
    HostMem* mem = ctx;
    // `align` can be larger than what `malloc` guarantees: over-allocate and keep the start of the block in front.
    if (align < sizeof(void*)) {
        align = sizeof(void*);
    }
    void* base = malloc(sizeof(void*) + align + size);
    if (base == NULL) {
        return NULL;
    }
    uintptr_t addr = ((uintptr_t)base + sizeof(void*) + align - 1) & ~(uintptr_t)(align - 1);
    ((void**)addr)[-1] = base;
    mem->held += size;
    mem->blocks += 1;
    return (void*)addr;
}

void host_free(void* ctx, void* ptr, size_t size, size_t align) {
    HostMem* mem = ctx;
    (void)align;
    mem->held -= size;
    mem->blocks -= 1;
    free(((void**)ptr)[-1]);
}

// Host implementation of `agent.tool`. Both params arrive as `str`, the result is a new `str`.
// A host function owns its by-value params, so it releases them with `cl_str_deinit`.
// (Declare a `[&]T` span param instead when the host only needs to borrow.)
CLRet tool(CLThread* t) {
    CLstr* ret = cl_thread_ret(t, sizeof(CLstr));
    CLstr name_s = cl_thread_str(t);
    CLstr args_s = cl_thread_str(t);
    CLBytes name = cl_str_bytes(name_s);
    CLBytes args = cl_str_bytes(args_s);

    char buf[256];
    int n = snprintf(buf, sizeof buf, "{\"tool\":\"%.*s\",\"args\":%.*s,\"ok\":true}",
        (int)name.len, name.ptr, (int)args.len, args.ptr);
    *ret = cl_str_init(t, (CLBytes){ buf, (size_t)n });

    cl_str_deinit(t, &name_s);
    cl_str_deinit(t, &args_s);
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
    HostMem mem = {0};
    CLVM* vm = cl_vm_init_mem((CLMemFuncs){ .ctx = &mem, .alloc = host_alloc, .free = host_free });
    cl_vm_set_loader(vm, loader);
    cl_vm_set_printer(vm, printer);

    int failed = 0;

    // Script calls into the host. `args` is built at runtime, so it is a heap string the host releases.
    // The lib test "Host functions release their owned str params." checks this with a leak-checking allocator.
    failed |= run(vm, "tool call",
        "use agent\n"
        "args := '{\"path\":' + '\"/etc/hosts\"}'\n"
        "r := agent.tool('read_file', args)\n"
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

    // Give the next script 8 MiB on top of what the VM holds now. Growing past it is a panic that frees the
    // script's memory, and the VM stays usable under the same limit.
    size_t before = cl_vm_memory_used(vm);
    cl_vm_set_memory_limit(vm, (int64_t)(before + 8 * 1024 * 1024));
    failed |= run(vm, "memory limit",
        "a := Array[int]{}\n"
        "for 0..1000000000 |i|:\n"
        "  a << i\n") != CL_ERROR_PANIC;
    failed |= cl_vm_memory_used(vm) > before + 1024 * 1024;
    failed |= run(vm, "after memory limit", "print('still alive')\n") != CL_SUCCESS;
    cl_vm_set_memory_limit(vm, 0);

    // Check that all references were accounted for. (Should be 0)
    CLThread* t = cl_vm_main_thread(vm);
    size_t live = cl_thread_count_objects(t);
    printf("Live objects: %zu\n", live);
    failed |= live != 0;

    // What the host's functions hold is what the VM counts, plus the VM object itself.
    printf("VM memory: %zu KiB, host blocks: %zu\n", cl_vm_memory_used(vm) / 1024, mem.blocks);
    failed |= mem.held < cl_vm_memory_used(vm);

    // Every block comes back when the VM is destroyed.
    cl_vm_deinit(vm);
    printf("Host blocks after deinit: %zu\n", mem.blocks);
    failed |= mem.blocks != 0 || mem.held != 0;
    return failed;
}
