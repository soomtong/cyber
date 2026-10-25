//! The kernel32 functions Cyber calls. Zig 0.16 dropped most kernel32 bindings from std.

const std = @import("std");
const windows = std.os.windows;

pub const MEM_COMMIT = 0x1000;
pub const MEM_RESERVE = 0x2000;
pub const MEM_RELEASE = 0x8000;
pub const PAGE_READWRITE = 0x04;

pub const HRESULT = c_long;
pub const S_OK: HRESULT = 0;
pub const E_OUTOFMEMORY: HRESULT = @bitCast(@as(c_ulong, 0x8007000E));
pub const KF_FLAG_CREATE = 0x00008000;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const u16) callconv(.winapi) ?windows.HMODULE;
pub extern "kernel32" fn LoadLibraryW(lpLibFileName: [*:0]const u16) callconv(.winapi) ?windows.HMODULE;
pub extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) callconv(.winapi) ?windows.FARPROC;
pub extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn VirtualAlloc(lpAddress: ?*anyopaque, dwSize: usize, flAllocationType: u32, flProtect: u32) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn VirtualFree(lpAddress: ?*anyopaque, dwSize: usize, dwFreeType: u32) callconv(.winapi) windows.BOOL;
pub extern "kernel32" fn GetConsoleOutputCP() callconv(.winapi) u32;
pub extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) windows.BOOL;
