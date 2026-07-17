const WORD = windows.WORD;
const DWORD = windows.DWORD;
const GUID = windows.GUID;
const USHORT = windows.USHORT;
const WCHAR = windows.WCHAR;
const BOOL = windows.BOOL;
const HANDLE = windows.HANDLE;
const HWND = windows.HWND;
const INT = windows.INT;
const SHORT = windows.SHORT;
const CHAR = windows.CHAR;
const UCHAR = windows.UCHAR;
const LONG = windows.LONG;
const ULONG = windows.ULONG;
const ULONG_PTR = windows.ULONG_PTR;
const PVOID = windows.PVOID;
const LPARAM = windows.LPARAM;
const FARPROC = windows.FARPROC;

pub const TIMER_ALL_ACCESS = 0x1F0003;

pub const OVERLAPPED = extern struct {
    Internal: ULONG_PTR,
    InternalHigh: ULONG_PTR,
    DUMMYUNIONNAME: extern union {
        DUMMYSTRUCTNAME: extern struct {
            Offset: DWORD,
            OffsetHigh: DWORD,
        },
        Pointer: ?PVOID,
    },
    hEvent: ?HANDLE,
};

pub const OVERLAPPED_ENTRY = extern struct {
    lpCompletionKey: ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
    Internal: ULONG_PTR,
    dwNumberOfBytesTransferred: DWORD,
};

pub extern "kernel32" fn CreateIoCompletionPort(
    FileHandle: HANDLE,
    ExistingCompletionPort: ?HANDLE,
    CompletionKey: ULONG_PTR,
    NumberOfConcurrentThreads: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "kernel32" fn GetQueuedCompletionStatusEx(
    CompletionPort: HANDLE,
    lpCompletionPortEntries: [*]OVERLAPPED_ENTRY,
    ulCount: ULONG,
    ulNumEntriesRemoved: *ULONG,
    dwMilliseconds: DWORD,
    fAlertable: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn PostQueuedCompletionStatus(
    CompletionPort: HANDLE,
    dwNumberOfBytesTransferred: DWORD,
    dwCompletionKey: ULONG_PTR,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateWaitableTimerW(
    lpTimerAttributes: ?*windows.SECURITY_ATTRIBUTES,
    bManualReset: BOOL,
    lpTimerName: ?windows.LPCWSTR,
) callconv(.winapi) ?HANDLE;

pub const PTIMERCAPROUTINE = *const fn (
    lpArgToCompletionRoutine: ?*anyopaque,
    dwTimerLowValue: DWORD,
    dwTimerHighValue: DWORD,
) callconv(.winapi) void;

pub extern "kernel32" fn SetWaitableTimer(
    hTimer: HANDLE,
    lpDueTime: *windows.LARGE_INTEGER,
    lPeriod: LONG,
    pfnCompletionRoutine: ?PTIMERCAPROUTINE,
    lpArgToCompletionRoutine: ?*anyopaque,
    fResume: BOOL,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CancelIoEx(
    hFile: HANDLE,
    lpOverlapped: *OVERLAPPED,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    *const fn (dwCtrlType: DWORD) callconv(.winapi) BOOL,
    BOOL,
) callconv(.winapi) BOOL;

pub const PAPCFUNC = *const fn (ULONG_PTR) callconv(.winapi) void;

pub extern "kernel32" fn QueueUserAPC(
    PAPCFUNC,
    HANDLE,
    ULONG_PTR,
) callconv(.winapi) DWORD;

const windows = std.os.windows;
const std = @import("std");
