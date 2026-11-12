#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "cyber.h"

// This example shows how a host waits outside the VM, for example for a user's approval:
// a host function returns a pending `Future` at once, the script awaits it, the eval returns `CL_AWAIT`,
// the host does the work and completes the future, and `cl_vm_resume` continues the script.
// The script sees a synchronous `write(path, text) -> !void` and does not know that it was suspended.

// Build `libcyber.a` with Zig:
// zig build lib

// Compile this program with any C compiler:
// clang -o host_await host_await.c -I ../../src/include ../../zig-out/lib/libcyber.a

// One request per future. The tag of a future is the number of its request, starting at 1 (the tag 0 is a
// future that this host did not create). The host keeps no future pointers: the VM hands out the future to
// complete, and `cl_future_tag` tells which request it is.
#define MAX_REQUESTS 8
typedef struct Request {
    char path[64];
} Request;
static Request requests[MAX_REQUESTS];
static int num_requests = 0;
static int num_written = 0;

// Host implementation of `fs.write_async`. It does not write and it does not wait: it records the request and
// returns a pending `Future[!void]`.
CLRet write_async(CLThread* t) {
    CLValue* ret = cl_thread_ret(t, sizeof(CLValue));
    CLstr path_s = cl_thread_str(t);
    CLstr text_s = cl_thread_str(t);
    CLBytes path = cl_str_bytes(path_s);

    CLRet res = CL_RET_OK;
    // The type exists because the declaration of this function names it.
    CLType* future_t = cl_find_type(cl_thread_vm(t), CL_BYTES("Future[!void]"));
    CLFuture* f = NULL;
    if (future_t != NULL && num_requests < MAX_REQUESTS) {
        f = cl_future_new(t, future_t, (uint64_t)num_requests + 1);
    }
    if (f == NULL) {
        res = cl_thread_ret_panic(t, CL_BYTES("Too many requests."));
    } else {
        Request* req = &requests[num_requests++];
        snprintf(req->path, sizeof req->path, "%.*s", (int)path.len, path.ptr);
        // The return slot owns the future.
        *ret = (CLValue)(uintptr_t)f;
    }
    cl_str_deinit(t, &path_s);
    cl_str_deinit(t, &text_s);
    return res;
}

// The `fs` module: the host function and a wrapper that awaits it. Scripts call the wrapper.
bool loader(CLVM* vm, CLSym* mod, CLBytes uri, CLLoaderResult* res) {
    if (uri.len == 2 && strncmp("fs", uri.ptr, 2) == 0) {
        cl_mod_add_func(mod, CL_BYTES("write_async"), CL_BIND_FUNC(write_async));
        res->src = CL_BYTES(
            "#[bind] fn write_async(path str, text str) -> Future[!void]\n"
            "fn write(path str, text str) -> !void:\n"
            "    return write_async(path, text).await()\n");
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

// The "user": approves every path except the ones under /etc.
static bool approve(const char* path) {
    return strncmp(path, "/etc/", 5) != 0;
}

// Runs a script to its end. Each `CL_AWAIT` is one request the host decides while the VM is suspended.
// With `cancel_at` >= 0, the host abandons the eval at that request instead (the user pressed Esc).
CLResultCode run(CLVM* vm, char* src, int cancel_at) {
    num_requests = 0;
    CLEvalResult res;
    CLResultCode code = cl_vm_eval(vm, CL_BYTES(src), &res);
    int answered = 0;
    while (code == CL_AWAIT) {
        CLFuture* f = cl_vm_pending_future(vm);
        uint64_t tag = cl_future_tag(f);
        Request* req = tag >= 1 && tag <= (uint64_t)num_requests ? &requests[tag - 1] : NULL;
        if (req == NULL || answered == cancel_at) {
            // Not a future of this host, or the user cancelled. The eval ends like an interrupted one.
            cl_vm_abandon(vm);
            return CL_ERROR_INTERRUPT;
        }
        answered += 1;
        // A wall clock limit would be paused here: the script is not running.
        if (approve(req->path)) {
            printf("approved: %s\n", req->path);
            num_written += 1;
            cl_future_complete(vm, f, NULL);
        } else {
            printf("denied: %s\n", req->path);
            cl_future_complete_error(vm, f, cl_error(vm, CL_BYTES("Denied")));
        }
        code = cl_vm_resume(vm, &res);
    }
    if (code != CL_SUCCESS) {
        CLBytes summary = cl_vm_error_summary(vm);
        printf("%.*s\n", (int)summary.len, summary.ptr);
        cl_vm_freeb(vm, summary);
    }
    return code;
}

int main() {
    CLVM* vm = cl_vm_init();
    cl_vm_set_loader(vm, loader);
    cl_vm_set_printer(vm, printer);

    int failed = 0;

    // Two approved writes and a denied one. The script handles the denial as an ordinary error value.
    failed |= run(vm,
        "use fs\n"
        "fn save(names []str) -> int:\n"
        "    saved := 0\n"
        "    for names |name|:\n"
        "        try:\n"
        "            fs.write(name, 'data')!\n"
        "            saved += 1\n"
        "        else |err|:\n"
        "            print('not saved: %{name} (%{err})')\n"
        "    return saved\n"
        "print(save({'/tmp/a.txt', '/etc/passwd', '/tmp/b.txt'}))\n", -1) != CL_SUCCESS;
    failed |= num_written != 2;

    // The user cancels at the second request. The VM takes the next script.
    failed |= run(vm,
        "use fs\n"
        "fs.write('/tmp/c.txt', 'data')!\n"
        "fs.write('/tmp/d.txt', 'data')!\n"
        "print('not reached')\n", 1) != CL_ERROR_INTERRUPT;
    failed |= num_written != 3;
    failed |= run(vm, "print('still alive')\n", -1) != CL_SUCCESS;

    // A request that the script starts and drops, followed by one that it awaits. The dropped future is freed
    // and the second future can get its address. The tags tell the two requests apart.
    failed |= run(vm,
        "use fs\n"
        "_ = fs.write_async('/tmp/dropped.txt', 'data')\n"
        "fs.write('/tmp/e.txt', 'data')!\n", -1) != CL_SUCCESS;
    failed |= num_written != 4;

    // Check that all references were accounted for. (Should be 0)
    size_t live = cl_thread_count_objects(cl_vm_main_thread(vm));
    printf("Live objects: %zu\n", live);
    failed |= live != 0;

    cl_vm_deinit(vm);
    return failed;
}
