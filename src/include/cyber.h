#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>

#ifndef CYBER_H
#define CYBER_H

#ifdef __cplusplus
extern "C" {
#endif
typedef struct CLVM CLVM;
typedef struct CLThread CLThread;
typedef struct CLHeap CLHeap;
// A `FutureValue[T]` object, the shared state behind a `Future[T]` value.
typedef struct CLFuture CLFuture;

typedef uint64_t CLValue;
typedef uint8_t CLRet;

enum {
    CL_RET_OK = 0,
    CL_RET_INTERRUPT = 1,
};

typedef struct CLValueSlice {
    const CLValue* ptr;
    size_t len;
} CLValueSlice;

typedef struct CLResolverParams CLResolverParams;
typedef struct CLUnit CLUnit;
typedef struct CLExprResult CLExprResult;
typedef struct CLNode CLNode;
typedef struct CLFuncSig CLFuncSig;
typedef struct CLFunc CLFunc;
typedef struct CLSym CLSym;

#define CL_NULLID UINT32_MAX

typedef int CLResultCode;

enum {
    CL_SUCCESS = 0,
    CL_AWAIT,
    CL_ERROR_COMPILE,
    CL_ERROR_PANIC,
    CL_ERROR_UNKNOWN,
    // `cl_vm_interrupt` or the fuel limit (`cl_vm_set_fuel`) stopped the eval.
    CL_ERROR_INTERRUPT,
    // An eval of this VM is suspended at an `await` (`CL_AWAIT`). Resume or abandon it first.
    CL_ERROR_SUSPENDED,
};

enum {
    CL_TYPE_NULL = 0,
    CL_TYPE_VOID,
    CL_TYPE_BOOL,
    CL_TYPE_I8,
    CL_TYPE_I16,
    CL_TYPE_I32,
    CL_TYPE_I64,
    CL_TYPE_INT_LIT,
    CL_TYPE_R8,
    CL_TYPE_R16,
    CL_TYPE_R32,
    CL_TYPE_R64,
    CL_TYPE_F32,
    CL_TYPE_F64,
    CL_TYPE_ERROR,
    CL_TYPE_SYMBOL,
    CL_TYPE_OBJECT,
    CL_TYPE_ANY,
    CL_TYPE_TYPE,
    CL_TYPE_THREAD,
    CL_TYPE_CODE,
    CL_TYPE_FUNC_SIG,
    CL_TYPE_PARTIAL_STRUCT_LAYOUT,
    CL_TYPE_STR,
    CL_TYPE_STR_BUFFER,
    CL_TYPE_STR_LIT,
    CL_TYPE_NEVER,
    CL_TYPE_INFER,
    CL_TYPE_DEPENDENT,
    CL_TYPE_TCC_STATE,
    CL_TYPE_RANGE,
    CL_TYPE_TABLE,
    CL_TYPE_NO_COPY,
    CL_TYPE_MUT_STR,
};
typedef uint32_t CLTypeId;
typedef struct CLType CLType;
typedef struct CLTypeValue {
    CLType* type;
    CLValue value;
} CLTypeValue;

// Some API functions may require string slices rather than a null terminated string.
// Creating a CLBytes can be simplified with a macro:
// #define bytes(x) ((CLBytes){ x, strlen(x) })
// NOTE: Returned `CLBytes`s are not always null terminated.
typedef struct CLBytes {
    char* ptr;
    size_t len;
} CLBytes;

// Type layout of a Cyber `str` at runtime.
typedef struct CLstr {
    void* buf;
    uint8_t* ptr;
    uint64_t header;
} CLstr;

typedef struct CLSlice {
    void* buf;
    void* ptr;
    uint64_t len;
    uint64_t header;
} CLSlice;

// A host function is bound to a runtime function symbol declared with `#[bind]`.
typedef CLRet (*CLHostFn)(CLThread* t);

typedef struct CLConstEvalContext {
    CLFunc* func;
    CLValue* args;
    CLNode* node;
} CLConstEvalContext;

typedef CLTypeValue (*CLConstEvalFn)(CLUnit* unit, CLConstEvalContext* ctx);

typedef struct CLBuiltinContext {
    CLFunc* func;
    CLNode* args;
    CLNode* node;
} CLBuiltinContext;

typedef bool (*CLBuiltinFn)(CLUnit* unit, CLBuiltinContext* ctx, CLExprResult* res);
typedef CLTypeValue (*CLBuiltinEvalFn)(CLUnit* unit, CLBuiltinContext* ctx);

typedef struct CLResolverParams {
    /// Chunk that invoked the resolver.
    /// If `CL_NULLID`, then the invoker did not originate from another chunk module.
    uint32_t chunkId;

    /// The current URI.
    /// If it's the empty string, then the invoker did not originate from another chunk module.
    CLBytes curUri;

    /// The unresolved URI.
    CLBytes uri;

    // Buffer to write a dynamic the result to.
    char* buf;
    size_t bufLen;
} CLResolverParams;

// Given the current module's resolved URI and the "to be" imported module specifier,
// set `params.resUri`, `params.resUriLen`, and return true.
// If the result uri is dynamic, write to `params.buf` to build the uri and set `params.resUri` to `params.buf`.
// If the result uri is a shared reference, `params.buf` does not need to be used.
// Return false if the uri can not be resolved.
// Most embedders do not need a resolver and can rely on the default resolver which
// simply returns `params.spec` without any adjustments.
typedef bool (*CLResolverFn)(CLVM* vm, CLResolverParams params, size_t* res_uri_len);

typedef bool (*CLDlResolverFn)(CLVM* vm, CLBytes uri, CLBytes* out);

// Callback invoked after all symbols in the module's src are loaded.
// This could be used to inject symbols not declared in the module's src.
typedef void (*CLModuleOnLoadFn)(CLVM* vm, CLSym* mod);

// Callback invoked just before the module is destroyed.
// This could be used to cleanup (eg. release) injected symbols from `CLPostLoadModuleFn`,
typedef void (*CLModuleOnDestroyFn)(CLVM* vm, CLSym* mod);

typedef enum {
    // Invokes a runtime VM host function.
    CL_BIND_FUNC_VM,

    // Parameters are const evaluated and returns a const value.
    CL_BIND_FUNC_CONST_EVAL,

    // Matching and sema is done by a compiler hook.
    CL_BIND_FUNC_BUILTIN,

    // Compile the function with the declaration body.
    CL_BIND_FUNC_DECL,
} CLBindFuncKind;

typedef struct CLBindFunc {
    // CLHostFn or CLCtFn
    const void* ptr;
    // CLCtEvalFn
    const void* ptr2;
    CLBindFuncKind kind;
} CLBindFunc;

typedef struct CLBindGlobal {
    void* ptr;
} CLBindGlobal;

typedef enum {
    // Use the provided declaration with a predefined or generated type id.
    CL_BIND_TYPE_DECL,

    CL_BIND_TYPE_CREATE,
    CL_BIND_TYPE_ALIAS,
} CLBindTypeKind;

// Creates the type of a `#[bind]` declaration. NULL fails the compile.
typedef CLType* (*CLCreateTypeFn)(CLVM* vm, CLSym* ctx_chunk, CLNode* decl);
typedef CLSym* (*CLResolveAliasFn)(CLVM* vm, CLSym* sym);

// Result given to Cyber when binding a `#[bind]` type.
typedef struct CLBindType {
    union {
        struct {
            // If `CL_NULLID`, a new type id is generated.
            CLTypeId type_id;
        } decl;
        struct {
            // Pointer to callback.
            CLCreateTypeFn create_fn;
        } create;     
        struct {
            // Pointer to callback.
            CLResolveAliasFn resolve_fn;
        } alias;     
    } data;
    // `CLBindTypeKind`.
    uint8_t type;
} CLBindType;

size_t cl_strlen(const char* s);

#define CL_BITCAST(type, x) (((union {typeof(x) src; type dst;})(x)).dst)
#define CL_BYTES(str) ((CLBytes){ .ptr = str, .len = cl_strlen(str) })
// Type bindings for `cl_mod_add_type`.
#define CL_BIND_DECL_TYPE(id) ((CLBindType){ .data = { .decl = { .type_id = id }}, .type = CL_BIND_TYPE_DECL })
#define CL_BIND_CREATE_TYPE(fn) ((CLBindType){ .data = { .create = { .create_fn = fn }}, .type = CL_BIND_TYPE_CREATE })
#define CL_BIND_ALIAS_TYPE(fn) ((CLBindType){ .data = { .alias = { .resolve_fn = fn }}, .type = CL_BIND_TYPE_ALIAS })
#define CL_BIND_FUNC(host_ptr) ((CLBindFunc){.kind = CL_BIND_FUNC_VM, .ptr = host_ptr})
#define CL_BIND_GLOBAL(val_ptr) ((CLBindGlobal){.ptr = val_ptr})

typedef struct CLLoaderResult {
    CLBytes src;

    // Whether `src` should be managed by the compiler (frees automatically). Defaults to false.
    bool manage_src;
} CLLoaderResult;

// Given the resolved import specifier of the module, return the module source code.
typedef bool (*CLModuleLoaderFn)(CLVM* vm, CLSym* mod, CLBytes resolved_uri, CLLoaderResult* res);

// Handler for printing. The builtin `print` would invoke this.
// The default behavior is a no-op.
typedef void (*CLPrintFn)(CLThread* t, CLBytes str);

// Handler for printing errors.
// The default behavior is a no-op.
typedef void (*CLPrintErrorFn)(CLThread* t, CLBytes str);

// Handler for compiler logs as well as `core.log`.
// The default behavior is a no-op.
typedef void (*CLLogFn)(CLVM*, CLBytes str);

typedef void (*CLGlobalLogFn)(CLBytes str);

// Deprecated: temporary used during the transition to VM logger.
extern CLGlobalLogFn cl_logger;

// Whether library was compiled with `Trace`.
extern bool CL_TRACE;

typedef enum {
    CL_VM = 0,
    CL_JIT,
    CL_TCC,
    CL_CC,
    CL_LLVM,
} CLBackend;

typedef struct CLEvalConfig {
    /// Compiler options.
    bool single_run;
    bool gen_all_debug_syms;
    CLBackend backend;

    bool spawn_exe;
    
    /// Persist main locals / use imports into the VM env. For REPL-like behavior.
    bool persist_main;

    /// Reject raw pointers (`Ptr[T]`, `PtrSpan[T]`) in every chunk that is not a standard module.
    /// An expression of such a type is a compile error, so an untrusted script can not build or dereference
    /// an arbitrary address. The core library keeps using raw pointers internally. Default false.
    bool deny_raw_ptrs;

    /// Reject `spawn` in every chunk that is not a standard module: a call is a compile error. A script then
    /// runs on the thread of the eval only, and so does every host function it calls. Default false.
    bool deny_spawn;
} CLEvalConfig;

typedef struct CLEvalResult {
    CLValue* res;
    CLTypeId res_t;
} CLEvalResult;

typedef struct CLCompileConfig {
    /// Whether this process intends to perform eval once and exit.
    /// In that scenario, the compiler can skip generating the final release ops for the main block.
    bool single_run;

    bool skip_codegen;

    /// By default, debug syms are only generated for insts that can potentially fail.
    bool gen_all_debug_syms;

    CLBackend backend;

    bool emit_source_map;

    /// Persist main locals / use imports into the VM env. For REPL-like behavior.
    bool persist_main;

    /// See `CLEvalConfig.deny_raw_ptrs`.
    bool deny_raw_ptrs;

    /// See `CLEvalConfig.deny_spawn`.
    bool deny_spawn;
} CLCompileConfig;

typedef struct CLValidateConfig {
    /// Compiler options.
    bool stub;
} CLValidateConfig;

// A Zig `std.mem.Allocator`. A C host passes its memory functions with `CLMemFuncs` instead.
typedef struct CLAllocator {
    void* ptr;
    const void* vtable;
} CLAllocator;

// The memory functions of a C host for `cl_vm_init_mem`.
// Both functions must be safe to call from several threads at once: the threads a script spawns allocate too.
typedef struct CLMemFuncs {
    // Passed back as the first argument of both functions.
    void* ctx;

    // Returns `size` bytes aligned to `align`, or NULL. `size` is not zero. `align` is a power of two and can be
    // larger than the alignment `malloc` guarantees.
    void* (*alloc)(void* ctx, size_t size, size_t align);

    // Frees a block returned by `alloc`. `size` and `align` are the values the block was allocated with.
    void (*free)(void* ctx, void* ptr, size_t size, size_t align);
} CLMemFuncs;

typedef struct CLFieldInit {
    CLBytes name;
    CLValue value;
} CLFieldInit;

// -----------------------------------
// [ Top level ]
// -----------------------------------
CLBytes cl_full_version(void);
CLBytes cl_version(void);
CLBytes cl_build(void);
CLBytes cl_commit(void);
CLBytes clResultName(CLResultCode code);

// -----------------------------------
// [ VM ]
// -----------------------------------

// Create a new VM with `malloc` as the allocator.
CLVM* cl_vm_init(void);

// Create a new VM with a Zig allocator.
CLVM* cl_vm_initx(CLAllocator allocator);

// Create a new VM that takes all of its memory from the functions of the host, including the `CLVM` object.
// `cl_vm_deinit` returns every block.
// To bound the memory of a script use `cl_vm_set_memory_limit` and not an `alloc` that returns NULL: a limit
// ends the script alone, in an `OutOfMemory` panic. An `alloc` that returns NULL during an eval fails that eval
// (see `cl_vm_eval`), and while the VM is created (`cl_vm_init_mem` itself) it aborts the process.
CLVM* cl_vm_init_mem(CLMemFuncs funcs);

// Deinitializes the VM and frees all memory associated with it. Any operation on `vm` afterwards is undefined.
void cl_vm_deinit(CLVM* vm);

// The allocator the VM allocates with. It counts every byte for `cl_vm_memory_used` on top of the allocator
// given to `cl_vm_initx`, so memory taken from it must be returned to it and not to the host's allocator.
// It is freed by `cl_vm_deinit`.
CLAllocator cl_vm_allocator(CLVM* vm);
CLThread* cl_vm_main_thread(CLVM* vm);

CLResolverFn cl_vm_resolver(CLVM* vm);
void cl_vm_set_resolver(CLVM* vm, CLResolverFn resolver);
CLBytes cl_vm_resolve(CLVM* vm, CLBytes uri);

// This is only relevant for binding dynamic libs.
void cl_vm_set_dl_resolver(CLVM* vm, CLDlResolverFn resolver);

// The default module resolver. It returns `spec`.
bool cl_default_resolver(CLVM* vm, CLResolverParams params, size_t* res_uri_len);

CLModuleLoaderFn cl_vm_get_loader(CLVM* vm);
void cl_vm_set_loader(CLVM* vm, CLModuleLoaderFn loader);

// The default module loader. It knows how to load the `builtins` module.
bool cl_default_loader(CLVM* vm, CLSym* mod, CLBytes resolved_uri, CLLoaderResult* res);

CLPrintFn cl_vm_printer(CLVM* vm);
void cl_vm_set_printer(CLVM* vm, CLPrintFn print);
CLPrintErrorFn cl_vm_eprinter(CLVM* vm);
void cl_vm_set_eprinter(CLVM* vm, CLPrintErrorFn print);
CLLogFn cl_vm_logger(CLVM* vm);
void cl_vm_set_logger(CLVM* vm, CLLogFn log);

CLEvalConfig clDefaultEvalConfig(void);
CLCompileConfig clDefaultCompileConfig(void);

// Resets the compiler and runtime state.
void cl_vm_reset(CLVM* vm);

/// Whether the next `cl_vm_eval` or `cl_vm_validate` starts from a reset VM, like `cl_vm_reset`: persisted locals,
/// declarations and `use` imports of earlier evals are then gone. True after the first compile of the VM (or the
/// first since a reset) failed, and after an allocation failed in the compiler or while main locals were carried
/// over. A compile error in a later eval keeps the session and leaves this false. Ask after an eval that did not
/// return `CL_SUCCESS` to know whether the session has to be set up again.
bool cl_vm_reset_pending(CLVM* vm);

// Evalutes the source code and returns the result code.
// Subsequent evals will reuse the same compiler and runtime state.
// On `CL_SUCCESS`, `res` holds the value that `fn main() -> T` returned, or with `persist_main` the value of
// the script's last statement if that is a bare expression. `res->res_t` is `CL_TYPE_VOID` when there is no value.
// On any other result code `res` is not set.
// When the allocator of the VM fails during an eval, the eval returns an error and the VM can be used again:
// - In the compiler: `CL_ERROR_COMPILE`. The summary names `OutOfMemory` or `WriteFailed`, or it is empty without
//   memory for the report. The compiler was stopped at an arbitrary point, so the next eval starts from a reset
//   VM, like `cl_vm_reset`: persisted locals and declarations of earlier evals are gone.
// - In the script: `CL_ERROR_PANIC` with `panic: OutOfMemory`. Without memory for a panic's own message or
//   stack trace, the message is `OutOfMemory` and the trace is empty.
// - In the bookkeeping after the run (the result, the persisted locals): `CL_ERROR_UNKNOWN`, with no summary.
CLResultCode cl_vm_eval(CLVM* vm, CLBytes src, CLEvalResult* res);

// The VM owns the value in `res`. It is released by the next eval, by `cl_vm_reset`, by `cl_vm_deinit` or by
// `cl_vm_release_result`, and `res->res` is not valid after that.
//
// Accepts a `uri` and EvalConfig.
CLResultCode cl_vm_evalx(CLVM* vm, CLBytes uri, CLBytes src, CLEvalConfig config, CLEvalResult* res);

// -----------------------------------
// [ Suspended evals and host futures ]
// -----------------------------------
//
// `Future[T].await()` on the main thread returns from the eval with `CL_AWAIT` when the future is not completed
// and no spawned thread completes it. The eval is suspended: its stack, its locals and the fuel that is left
// stay as they are. The host completes the future and calls `cl_vm_resume`, as often as the eval awaits:
//
//     CLResultCode r = cl_vm_evalx(vm, uri, src, config, &res);
//     while (r == CL_AWAIT) {
//         CLFuture* f = cl_vm_pending_future(vm);
//         int64_t n = answer(cl_future_tag(f));
//         cl_future_complete(vm, f, &n);
//         r = cl_vm_resume(vm, &res);
//     }
//
// The await can be at any call depth and in the body of a generator. It can not be inside a function that a
// host function called (`panic: Cannot await across a host call.`) or in a spawned thread.
// An await inside a fiber does not suspend the eval: it suspends the fiber, and the script goes on in the
// context that resumed it. The eval is suspended when the root context waits: with an `await` of its own,
// with `Future.wait_any`, or with `Fiber.wait_ready()`, which waits for the futures of all suspended fibers.
// While an eval is suspended, `cl_vm_eval*`, `cl_vm_validate` and `cl_vm_compile*` return `CL_ERROR_SUSPENDED`.
// `cl_vm_reset` and `cl_vm_deinit` abandon the suspended eval first.
// All of these functions are called from the thread that runs the evals of the VM. A future is not completed
// from another thread.

// Creates a pending future for a host function to return. `future_t` is a `Future[T]` type, from
// `cl_find_type(vm, CL_BYTES("Future[int]"))` once a script has named that type (the declaration of the host
// function does). Call it from a host function on the main thread, and write the result to the return slot:
//
//     CLValue* ret = cl_thread_ret(t, sizeof(CLValue));
//     CLFuture* f = cl_future_new(t, future_t, request_id);
//     *ret = (CLValue)(uintptr_t)f;
//
// The return slot is a `CLValue` (8 bytes on every target) and owns the reference.
// Returns `NULL` if `future_t` is not a `Future[T]` type or the allocator fails.
//
// `tag` is the host's own number for the request behind the future, read back with `cl_future_tag`. Use it to
// find the request of the future that a suspended eval waits for. Do not compare future pointers for that:
// a pending future that the script drops is freed like any other object, and the next `cl_future_new` can
// return the same address. Futures that the host did not create have the tag 0, so give no request that tag.
//
// The host does not have to keep the pointer: `cl_vm_pending_future` and `cl_vm_pending_futures` hand out the
// futures to complete, and those are alive. Only a host that completes a future the eval is not waiting for at
// that moment keeps its pointer, and then it retains it: `cl_thread_retain(t, (CLValue)(uintptr_t)f)`.
// It gives the reference back with `cl_thread_release` after it completed the future, or when the eval ends
// with `CL_SUCCESS`. When the eval ends with `CL_ERROR_PANIC` or `CL_ERROR_INTERRUPT`, or is dropped with
// `cl_vm_abandon` or `cl_vm_reset`, the heap of the eval is freed together with every future in it, retained
// or not: the host then forgets its pointers and does not release them.
CLFuture* cl_future_new(CLThread* t, CLType* future_t, uint64_t tag);

// The tag that `cl_future_new` gave the future. 0 for a future that the host did not create (one of a spawned
// thread, or of the script's own `FutureResolver`).
uint64_t cl_future_tag(CLFuture* future);

// Completes a pending future with a value. `value` points to a `T`, which is copied (`sizeof` the type as host
// functions return it: 8 bytes for an `int`, a `CLstr` for a `str`, a `CLSlice` for a `[]T`). The future takes
// ownership of the value, as a return slot does: do not release it afterwards.
// For a `Future[!U]`, `value` points to the `U`. `value` is not read when the type has no size (`void`).
// Returns false and takes nothing if the future is already completed or was created by `spawn`.
bool cl_future_complete(CLVM* vm, CLFuture* future, const void* value);

// Completes a pending `Future[!U]` with an error value from `cl_error`.
// Returns false if the future is already completed, was created by `spawn`, or is not a `Future[!U]`.
bool cl_future_complete_error(CLVM* vm, CLFuture* future, int64_t err);

// The future that the suspended eval waits for, or `NULL` when no eval is suspended. The pointer is borrowed:
// it is valid until `cl_vm_resume` or `cl_vm_abandon`. `cl_future_tag` tells which request it belongs to.
// A script can also wait for a future of its own that it never completes (`FutureResolver`). The host does not
// know such a future and abandons the eval.
CLFuture* cl_vm_pending_future(CLVM* vm);

// The futures that the suspended eval waits for: one for `await`, the whole list for `Future.wait_any`, in the
// order of the list. For `Fiber.wait_ready` they are the futures that the suspended fibers await, in no
// particular order: identify them by their tags. Writes at most `cap` of them to `out` (which can be `NULL`) and returns how many there are,
// 0 when no eval is suspended. Completing any one of them lets `cl_vm_resume` continue. More than one can be
// completed before the resume. The pointers are borrowed like the one of `cl_vm_pending_future`, which returns
// the first of this list.
size_t cl_vm_pending_futures(CLVM* vm, CLFuture** out, size_t cap);

// Continues the suspended eval. The result code and `res` follow the rules of `cl_vm_evalx`, including another
// `CL_AWAIT`, which is also the result when the pending future was not completed.
// An interrupt request that arrived while the eval was suspended is cleared, as at the start of an eval: only a
// request after this call stops the eval. Use `cl_vm_abandon` to stop a suspended eval.
// The fuel is not refilled: it counts the checkpoints of the whole eval.
// Returns `CL_ERROR_UNKNOWN` when no eval is suspended.
CLResultCode cl_vm_resume(CLVM* vm, CLEvalResult* res);

// Drops the suspended eval. The outcome is that of `cl_vm_interrupt`: the main locals are gone (also the
// persisted ones of `persist_main`), the declarations stay, and the VM takes the next eval.
// `cl_thread_panic_summary` names the abandoned `await`. Does nothing when no eval is suspended.
void cl_vm_abandon(CLVM* vm);

// Asks the running eval to stop at its next checkpoint (a loop back edge or a call).
// Safe to call from another thread. The eval returns `CL_ERROR_INTERRUPT` after unwinding like a panic,
// and the VM can be used again. Each eval clears an earlier request when it starts.
void cl_vm_interrupt(CLVM* vm);

// Limits each following eval to `fuel` checkpoints (loop back edges and calls). Zero or less removes the limit.
// An eval that runs out returns `CL_ERROR_INTERRUPT`.
void cl_vm_set_fuel(CLVM* vm, int64_t fuel);

// Caps the VM stack of the main thread and of threads it spawns at `bytes` (rounded down to 8-byte slots).
// The default is 128 MiB. A call that needs more stack panics with `Stack overflow.` and the eval returns
// `CL_ERROR_PANIC`; the VM can be used again. Zero or less removes the limit.
void cl_vm_set_stack_limit(CLVM* vm, int64_t bytes);

// Limits the memory of the VM to `bytes`. Zero or less removes the limit, which is the default.
// The limit covers everything the VM holds through its allocator (`cl_vm_memory_used`): the compiler and the
// loaded modules, about 2 MiB for a VM that has run a first eval, as well as the heap and the stacks of its
// threads. A host that wants to give a script N bytes sets `cl_vm_memory_used(vm) + N`.
// The limit is enforced where a script makes the heap or a stack grow: a new object, string or buffer that
// does not fit panics with `OutOfMemory` and the eval returns `CL_ERROR_PANIC`. The panic frees the heap
// and returns its pages and the grown stack, so the VM can be used again under the same limit.
// Memory the compiler or a host function allocates on its own is counted but not refused. It is seen by the
// next growth of the heap. A limit below what the VM already holds therefore still compiles a script and
// runs it until its first allocation.
void cl_vm_set_memory_limit(CLVM* vm, int64_t bytes);

// Bytes the VM currently holds through its allocator. Does not include the `CLVM` object itself.
size_t cl_vm_memory_used(CLVM* vm);

// Uses a `uri` to load the source code.
CLResultCode cl_vm_eval_path(CLVM* vm, CLBytes uri, CLEvalConfig config, CLEvalResult* res);

// Consumes and evaluates all ready tasks. Returns `CL_SUCCESS` if succesfully emptied the ready queue.
// CLResultCode cl_run_ready_tasks(CLThread* t);

// Compiles the source as a whole program without running it. The VM is reset first, like `cl_vm_reset`:
// persisted locals and declarations from earlier evals are gone. Used by `cyber compile` to dump bytecode.
CLResultCode cl_vm_compile(CLVM* vm, CLBytes uri, CLBytes src, CLCompileConfig config);
CLResultCode cl_vm_compile_path(CLVM* vm, CLBytes uri, CLCompileConfig config);

// Checks the source for compile errors against the current session without running it or resetting the VM.
// Persisted locals and declarations from earlier evals are visible to it, and nothing it declares is kept for
// the next eval. A module the source loads first (`use math`) is initialized by the next eval that runs.
// On `CL_ERROR_COMPILE` the report is available from `cl_vm_compile_error_summary`.
CLResultCode cl_vm_validate(CLVM* vm, CLBytes src);

/// Convenience function to return the last error summary.
/// Returns `cl_vm_compile_error_summary` if the last result was a CL_ERROR_COMPILE,
/// or `cl_thread_panic_summary` if the last result was a CL_ERROR_PANIC,
/// or the null string.
CLBytes cl_vm_error_summary(CLVM* vm);

/// Returns the compile error summary: the message, the source line and a marker under the reported range,
/// followed by the context the compiler attached (an earlier declaration, the call sites of a template).
/// The compiler stops at its first error, so there is one error per compile.
/// Returns the null string if no compile error is recorded, or if there is no memory for the summary.
/// Must be freed with `cl_vm_freeb`.
/// The text has no terminal escape codes unless `cl_vm_set_error_color` turned them on.
CLBytes cl_vm_compile_error_summary(CLVM* vm);

typedef enum {
    /// `out` is the formatted source. It ends with a new line unless it is empty.
    CL_FORMAT_OK = 0,
    /// The source does not parse. `out` is `line:col: message` (1-based). The author of the source can fix it.
    CL_FORMAT_SYNTAX_ERROR,
    /// The formatter refused its own output: the result did not parse back to the same syntax tree.
    /// The source is not at fault and should be kept as it is. `out` describes the failure.
    CL_FORMAT_INTERNAL_ERROR,
    /// No memory for the result. `out` is the null string.
    CL_FORMAT_NO_MEMORY,
} CLFormatResult;

/// Formats Cyber source the way `cyber fmt` does. Only the parser runs, nothing is compiled or evaluated,
/// and the state of the VM does not change. The VM provides the allocator.
/// `out` is set for every result. Unless it is the null string it must be freed with `cl_vm_freeb`.
/// The message of an error is the null string if there is no memory for it.
CLFormatResult cl_vm_format(CLVM* vm, CLBytes src, CLBytes* out);

/// Whether a compile error summary colors the marker under the reported range with ANSI escape codes.
/// Off by default. Survives `cl_vm_reset`.
void cl_vm_set_error_color(CLVM* vm, bool enabled);

/// Matches the title of the summary: `TokenError`, `ParseError` or `CompileError`.
typedef enum {
    CL_REPORT_TOKEN_ERROR = 0,
    CL_REPORT_PARSE_ERROR,
    CL_REPORT_COMPILE_ERROR,
    /// An entry of the chain behind a report, see `cl_vm_compile_report_note`.
    CL_REPORT_NOTE,
} CLReportKind;

typedef struct CLCompileError {
    CLReportKind kind;

    /// The message without the location. Owned by the VM.
    CLBytes msg;

    /// The source that the error is in. Empty if the error does not belong to a source. Owned by the VM.
    CLBytes uri;

    /// Whether `line`, `col` and `len` are set. An error can belong to a source without a position in it.
    bool has_loc;

    /// Starts at 0.
    uint32_t line;

    /// Byte offset in the line. Starts at 0.
    uint32_t col;

    /// Bytes of the reported range on `line`. A range that continues on later lines ends at the end of `line`.
    /// A token or parse error reports a position: `len` is 1.
    uint32_t len;
} CLCompileError;

/// Writes the compile error of the last `cl_vm_eval`, `cl_vm_compile` or `cl_vm_validate` to `out` and
/// returns true. Returns false and zeroes `out` if the last result was not `CL_ERROR_COMPILE`.
/// `msg` and `uri` stay valid until the next eval, compile, validate or reset of the VM.
bool cl_vm_compile_error(CLVM* vm, CLCompileError* out);

/// A compile error or a note of one, with the reported range. See `cl_vm_compile_report`.
typedef struct CLReport {
    CLReportKind kind;

    /// The message without the location. Owned by the VM.
    /// Empty for a note that only names a place: the call that expanded a template.
    CLBytes msg;

    /// The source that the range is in. Empty if the report does not belong to a source. Owned by the VM.
    CLBytes uri;

    /// Whether the fields below are set. A report can belong to a source without a position in it.
    bool has_loc;

    /// Start of the range. `line` starts at 0, `col` is the byte offset in the line.
    uint32_t line;
    uint32_t col;

    /// End of the range, exclusive. A range can end on a later line than it starts.
    uint32_t end_line;
    uint32_t end_col;

    /// The same range as byte offsets in the source.
    /// A token or parse error reports a position: the range is the code point there, or empty at the end of a line.
    uint32_t pos;
    uint32_t end_pos;
} CLReport;

/// Whether the compiler goes on after a compile error to report more than one. Off by default.
/// With it a body (the main block, a function, a method) that has an error is abandoned at its first error and
/// the other bodies are still checked, so there is at most one error per body. A syntax error or an error in a
/// declaration (a type, a signature, a global) still ends the compile at once.
/// The result is `CL_ERROR_COMPILE` as before and nothing is run. `cl_vm_compile_error` and the summary describe
/// the first error, `cl_vm_compile_report` gives all of them. The setting is kept across `cl_vm_reset`.
void cl_vm_set_error_recovery(CLVM* vm, bool enabled);

/// The number of compile errors of the last `cl_vm_eval`, `cl_vm_compile` or `cl_vm_validate`.
/// 0 if the last result was not `CL_ERROR_COMPILE`. At most 1 unless `cl_vm_set_error_recovery` is on.
size_t cl_vm_compile_report_count(CLVM* vm);

/// Writes compile error `idx` to `out` and returns true. Returns false and zeroes `out` if there is no such error.
/// `msg` and `uri` stay valid until the next eval, compile, validate or reset of the VM.
bool cl_vm_compile_report(CLVM* vm, size_t idx, CLReport* out);

/// Writes note `note_idx` of compile error `idx` to `out` and returns true. Returns false and zeroes `out` after the
/// last note. Notes are in the order the summary prints them: context such as `First declared at:` with its place,
/// then the calls that expanded the template the error is in, innermost first. `kind` is `CL_REPORT_NOTE`.
bool cl_vm_compile_report_note(CLVM* vm, size_t idx, size_t note_idx, CLReport* out);

/// Whether the compiler records what the names in the main source refer to. Off by default, kept across
/// `cl_vm_reset`. For editor tooling: see `cl_vm_symbol_at`.
/// The functions that read the record (`cl_vm_symbol_at`, `cl_vm_symbol_refs`, `cl_vm_symbol_refs_to`,
/// `cl_vm_members_at`, `cl_vm_names_at`, `cl_vm_symbol_tokens`) answer for the last eval, compile or validate.
/// They find nothing (false or 0) if that one ran with the recording off, before the first compile, after
/// `cl_vm_reset`, and after a compile that failed before it reached its main source (a uri that does not load).
void cl_vm_set_symbol_info(CLVM* vm, bool enabled);

typedef enum {
    /// An expression that is not a name. `detail` is its type.
    CL_SYMBOL_EXPR,
    /// A local or a parameter. It is only visible in the function that declares it.
    CL_SYMBOL_LOCAL,
    /// Something declared outside of a function body: a function, a type, a field, a case, a constant,
    /// a global, a module.
    CL_SYMBOL_DECL,
} CLSymbolKind;

/// What a name or an expression of the main source is, see `cl_vm_symbol_at`.
typedef struct CLSymbolInfo {
    CLSymbolKind kind;

    /// The range of the name or expression, as byte offsets in the main source. `end_pos` is exclusive.
    uint32_t pos;
    uint32_t end_pos;

    /// One line that describes it: the first line of the declaration (`fn add(a int, b int) -> int`),
    /// `name Type` for a local or a field, the type for any other expression. Owned by the VM.
    CLBytes detail;

    /// Whether it has a declaration in a source. A builtin type has none.
    bool has_def;

    /// The source that declares it, as the compiler names it: the resolved uri of the module.
    /// A standard module is embedded and has a name like `core`. Owned by the VM.
    CLBytes def_uri;

    /// The range of the declaration as byte offsets in that source: the name of a local or a field,
    /// otherwise the whole declaration.
    uint32_t def_pos;
    uint32_t def_end_pos;
} CLSymbolInfo;

/// Describes what is at byte offset `pos` of the main source of the last `cl_vm_compile`, `cl_vm_validate` or
/// `cl_vm_eval`, which has to have run with `cl_vm_set_symbol_info` on. The compile may have failed: what was
/// resolved before the error is there. Returns false and zeroes `out` if nothing was recorded at `pos`.
/// A position right after a name counts as the name. Only the main source is recorded, not the modules it uses.
/// `detail` and `def_uri` stay valid until the next call of this function, eval, compile, validate or reset.
bool cl_vm_symbol_at(CLVM* vm, uint32_t pos, CLSymbolInfo* out);

/// A range of the main source as byte offsets. `end_pos` is exclusive.
typedef struct CLRange {
    uint32_t pos;
    uint32_t end_pos;
} CLRange;

/// Finds every place in the main source that names what is named at byte offset `pos`: the uses and, if it is
/// declared in the main source, the name in its declaration. Returns the number of ranges and sets `out` to
/// them, sorted and without duplicates. Returns 0 and sets `out` to NULL if `pos` is not at a local or a
/// declared name. Uses in other modules are not found: only the main source is recorded.
/// The ranges are owned by the VM and stay valid until the next call of this function or of
/// `cl_vm_symbol_refs_to`, eval, compile, validate or reset.
size_t cl_vm_symbol_refs(CLVM* vm, uint32_t pos, const CLRange** out);

typedef enum {
    /// A local or a parameter.
    CL_ITEM_LOCAL,
    CL_ITEM_FUNCTION,
    CL_ITEM_TYPE,
    CL_ITEM_FIELD,
    /// A case of an enum, a choice or a C union.
    CL_ITEM_CASE,
    CL_ITEM_CONSTANT,
    CL_ITEM_GLOBAL,
    CL_ITEM_MODULE,
    CL_ITEM_OTHER,
    /// A function with a receiver.
    CL_ITEM_METHOD,
} CLItemKind;

/// A name that can be written at a place in the source, for completion.
typedef struct CLItem {
    CLBytes name;

    /// One line, like `CLSymbolInfo.detail`.
    CLBytes detail;

    CLItemKind kind;
} CLItem;

/// Lists the members of the expression that ends at byte offset `pos` of the main source: the fields and
/// methods of its type (through `&T` and `^T`), or what a module or a type declares when the expression names
/// one (`math`, `Color`). Returns the number of items and sets `out` to them, sorted by name. Returns 0 and
/// sets `out` to NULL if no expression ends at `pos`.
/// To complete `v.` the host compiles the source without the `.` and asks at the end of `v`.
/// Needs `cl_vm_set_symbol_info`. Private members of other modules, hooks and operators are left out.
/// The items are owned by the VM and stay valid until the next call of this function or of `cl_vm_names_at`,
/// eval, compile, validate or reset.
size_t cl_vm_members_at(CLVM* vm, uint32_t pos, const CLItem** out);

/// Lists the names that can be used at byte offset `pos` of the main source: the locals and parameters that
/// the function around `pos` declares before it, what the main source declares and uses, and the builtins.
/// A name that is declared more than once is listed as the innermost declaration. Blocks are not told apart:
/// a local of a block that ended before `pos` is listed too.
/// Returns, needs and owns like `cl_vm_members_at`.
size_t cl_vm_names_at(CLVM* vm, uint32_t pos, const CLItem** out);

/// Finds every place in the main source that names the symbol declared at byte offset `def_pos` of the source
/// `def_uri`, as `cl_vm_symbol_at` reports a declaration (`def_uri`, `def_pos`). For the uses of a symbol in the
/// other sources of a project: the host compiles each of them as the main source and asks here.
/// The name in the declaration is included when the main source is the one that declares it.
/// Returns and owns like `cl_vm_symbol_refs`, and replaces its result.
size_t cl_vm_symbol_refs_to(CLVM* vm, CLBytes def_uri, uint32_t def_pos, const CLRange** out);

/// A name of the main source and what it is. `kind` is a `CLItemKind`.
typedef struct CLToken {
    uint32_t pos;
    uint32_t end_pos;
    uint32_t kind;
} CLToken;

/// Lists the names of the main source that the last compile resolved, with what each one is, for highlighting
/// by meaning. Sorted by position, one entry per name, no overlaps. Keywords, literals, and names that did not
/// resolve or were not reached are not listed. Needs `cl_vm_set_symbol_info`.
/// The tokens are owned by the VM and stay valid until the next call of this function, eval, compile,
/// validate or reset.
size_t cl_vm_symbol_tokens(CLVM* vm, const CLToken** out);

// For embedded, Cyber by default uses malloc (it can be configured to use the high-perf mimalloc).
// If the host uses a different allocator than Cyber, use `cl_vm_alloc` to allocate memory
// that is handed over to Cyber so it knows how to free it.
// This is also used to manage accessible buffers when embedding WASM.
// Only pointer is returned so wasm callsite can just receive the return value.
void* cl_vm_alloc(CLVM* vm, size_t size);
CLBytes cl_vm_allocb(CLVM* vm, size_t size);

// When using the Zig allocator, you'll need to pass the original memory size.
// For all other allocators, use 1 for `len`.
void cl_vm_free(CLVM* vm, void* ptr, size_t size);
void cl_vm_freeb(CLVM* vm, CLBytes bytes);
void cl_vm_freez(CLVM* vm, const char* str);

/// Some API callbacks use this to report errors.
void clReportApiError(CLVM* vm, CLBytes msg);

// Attach a userdata pointer inside the VM.
void* cl_vm_user_data(CLVM* vm);
void cl_vm_set_user_data(CLVM* vm, void* data);

void cl_vm_dump_bytecode(CLVM* vm);

// Verbose flag. In a debug build, this would print more logs.
extern bool clVerbose;

// Silent flag. Whether to print errors.
extern bool clSilent;

// -----------------------------------
// [ Threads ]
// -----------------------------------

CLVM* cl_thread_vm(CLThread* t);
CLAllocator cl_thread_allocator(CLThread* t);

typedef struct CLStackFrame {
    // Name identifier (e.g. function name, or "main")
    CLBytes name;
    // Starts at 0.
    uint32_t line;
    // Starts at 0.
    uint32_t col;
    // Where the line starts in the source file.
    uint32_t line_pos;
    uint32_t chunk;
} CLStackFrame;

typedef struct CLStackTrace {
    CLStackFrame* frames;
    size_t frames_len;
} CLStackTrace;

CLStackTrace cl_thread_panic_trace(CLThread* t);

/// Returns runtime panic summary, or the null string if the thread's last run did not panic or if there is no
/// memory for the summary. Must be freed with `cl_vm_freeb`.
CLBytes cl_thread_panic_summary(CLThread* t);

/// Return and parameters for host functions.
/// The parameters are read one by one in the order they are declared, each with the function of its type
/// (`cl_thread_str`, `cl_thread_int`, ..., or `cl_thread_param` with its size). Every call moves on to the next
/// parameter, so reading out of order or with another type returns the bytes of another parameter.
/// `cl_thread_ret` returns the slot for the return value and may be called before or after the parameters are
/// read, but not in between: it starts the parameters over from the first.
void* cl_thread_ret(CLThread* t, size_t size);
CLRet cl_thread_ret_panic(CLThread* t, CLBytes msg);
void* cl_thread_param(CLThread* t, size_t size);
CLstr cl_thread_str(CLThread* t);
void* cl_thread_ptr(CLThread* t);
double cl_thread_float(CLThread* t);
float cl_thread_f32(CLThread* t);
int64_t cl_thread_int(CLThread* t);
int32_t cl_thread_i32(CLThread* t);
int16_t cl_thread_i16(CLThread* t);
int8_t cl_thread_i8(CLThread* t);
uint64_t cl_thread_r64(CLThread* t);
uint32_t cl_thread_r32(CLThread* t);
uint16_t cl_thread_r16(CLThread* t);
uint8_t cl_thread_byte(CLThread* t);
CLSlice cl_thread_slice(CLThread* t);

void cl_thread_release(CLThread* t, CLValue val);
void cl_thread_retain(CLThread* t, CLValue val);

// Releases the value that the last eval returned in its `CLEvalResult`. The result must not be read after this.
// Does nothing when there is no result. A host that counts references (`cl_thread_rc`) calls it first.
void cl_vm_release_result(CLVM* vm);

// Get's the current global reference count.
// NOTE: This will panic if the lib was not built with `Trace`.
// RELATED: `cl_thread_count_objects()`
size_t cl_thread_rc(CLThread* t);

// Logs eval stats about the thread.
void cl_thread_dump_stats(CLThread* t);

// Returns the number of live objects.
// This can be used to check if all objects were cleaned up after `clDeinit`.
size_t cl_thread_count_objects(CLThread* t);

// TRACE mode: Dump live objects recorded in global object map.
void cl_thread_dump_live_objects(CLThread* t);

void cl_thread_signal_host_panic(CLThread* t);
void cl_thread_signal_host_segfault(CLThread* t);

typedef struct CLMemoryCheck {
    uint32_t num_cyc_objects;
} CLMemoryCheck;

// Check memory for reference cycles which indicates a bug in the program.
CLMemoryCheck cl_thread_check_memory(CLThread* t);

typedef struct CLTraceInfo {
    uint32_t num_retains;
    uint32_t num_releases;
} CLTraceInfo;

CLTraceInfo cl_thread_trace_info(CLThread* t);

// -----------------------------------
// [ Modules ]
// -----------------------------------

void cl_mod_set_data(CLSym* mod, void* data);
void* cl_mod_get_data(CLSym* mod);
// Adds a binding from a module loader. Without memory for it, the compile that is loading the module fails.
void cl_mod_add_func(CLSym* mod, CLBytes name, CLBindFunc binding);
void cl_mod_add_type(CLSym* mod, CLBytes name, CLBindType binding);
void cl_mod_add_global(CLSym* mod, CLBytes name, CLBindGlobal binding);
void cl_mod_on_destroy(CLSym* mod, CLModuleOnDestroyFn on_destroy);
void cl_mod_on_load(CLSym* mod, CLModuleOnLoadFn on_load);
void cl_mod_set_fallback_func(CLSym* mod, CLBindFunc binding);

// Each module binding registers the relevant functions and returns the source that should be returned to the module loader.
// Source returned is static memory. When returning the source to the module loader either `manage_src` should be false or it should be duplicated with `cl_vm_allocb` .
typedef CLBytes (*CLModuleBindFn)(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_core(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_cy(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_c(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_io(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_meta(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_math(CLVM* vm, CLSym* mod);
CLBytes cl_mod_bind_test(CLVM* vm, CLSym* mod);

// -----------------------------------
// [ Symbols ]
// -----------------------------------

// Expand type template for given arguments.
// Returns `NULL` if the expansion fails. During a compile (called from a module loader or a `CLCreateTypeFn`)
// the compile then fails with that error.
CLType* clExpandTypeTemplate(CLVM* vm, CLSym* type_t, const CLType* param_types, const CLValue* args, size_t nargs);

// Find and return the type from a given type specifier (a symbol name in main, then in the builtins).
// Returns `NULL` before the first compile, if the symbol could not be found or the symbol is not a type.
// Returns `NULL` for a template expansion that doesn't already exist. Use `clExpandTypeTemplate` to create one.
// Also `NULL` if the allocator of the VM fails.
// If a type is returned, the type specifier is memoized to return the same result.
CLType* cl_find_type(CLVM* vm, CLBytes spec);

// -----------------------------------
// [ Values ]
// -----------------------------------

// Returns a short description about a value given their type id.
// Specializes for common types. Other types will only output the type id and the address.
// This is very basic compared to the core API's `to_print_string` and `dump`.
CLBytes cl_value_desc(CLVM* vm, CLTypeId val_t, CLValue* val);

// Symbol value.
int64_t cl_symbol(CLVM* vm, CLBytes str);
int64_t cl_error(CLVM* vm, CLBytes str);

// `cl_str` is the recommended way to initialize a new string.
// `cl_astr` or `cl_ustr` asserts an ASCII or UTF-8 string respectively.
CLstr cl_str_init(CLThread* t, CLBytes str);
CLstr cl_astr_init(CLThread* t, CLBytes str);
CLstr cl_ustr_init(CLThread* t, CLBytes str);
void cl_str_deinit(CLThread* t, CLstr* str);
CLBytes cl_str_bytes(CLstr str);
CLBytes cl_object_string(CLThread* t, CLValue val);  // Conversion from value to a basic string description.

// Initializes a new slice with undefined elements.
CLSlice cl_slice_init(CLThread* t, size_t num_elems, size_t elem_size);
// Releases a slice that a host function owns, such as a `[]T` param from `cl_thread_slice`.
// `elem_t` is the element type, or NULL when the elements are not managed.
// The elements are destructed only when this slice holds the last reference to the buffer.
void cl_slice_deinit(CLThread* t, CLType* elem_t, CLSlice* s);

// Functions.
CLFuncSig* cl_vm_ensure_func_sig(CLVM* vm, const CLType* params, size_t nparams, CLType* ret_t);
CLValue cl_new_func_union(CLThread* t, CLType* union_t, CLHostFn func);

// Types.
CLType* cl_type_from_id(CLVM* vm, CLTypeId id);
CLTypeId cl_type_id(CLType* type);

// Consumes and lifts a value (given as a pointer to the value) to the heap.
CLValue cl_lift(CLThread* t, CLType* type, void* value);

// Creates an empty array value.
// Expects an array type `Array[T]` as `array_t` which can be obtained from `clExpandTypeTemplate` or `cl_find_type`.
CLValue cl_array_empty(CLThread* t, CLType* array_t);

// Creates an empty map value. Expects a map type `Map[K, V]` as `map_t`.
CLValue cl_map_empty(CLThread* t, CLType* map_t);

#ifdef __cplusplus
} // extern "C"
#endif // __cplusplus

#endif // !CYBER_H