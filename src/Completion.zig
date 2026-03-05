const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const Completion = @This();

const is_windows = builtin.os.tag == .windows;

/// Intrusive linked list pointer (used by the event loop)
next: ?*Completion = null,

/// The I/O operation to perform
op: Operation = .{ .noop = {} },

/// User callback invoked when the operation completes.
/// The completion's `result` field is set before this is called.
callback: ?Callback = null,

/// Opaque user data. Use @intFromPtr/@ptrFromInt to store a typed pointer,
/// or use @fieldParentPtr in the callback to recover your struct.
userdata: usize = 0,

/// Result of the operation, set by the backend before invoking the callback.
/// Interpretation depends on the operation type.
result: i32 = 0,

pub const Callback = *const fn (*Completion) void;

pub const Operation = union(enum) {
    noop: void,

    accept: struct {
        socket: posix.socket_t,
    },

    connect: struct {
        socket: posix.socket_t,
        address: std.net.Address,
    },

    recv: struct {
        socket: posix.socket_t,
        buffer: []u8,
    },

    send: struct {
        socket: posix.socket_t,
        buffer: []const u8,
    },

    close: struct {
        fd: posix.fd_t,
    },

    timeout: struct {
        /// Timeout duration in nanoseconds
        ns: u64,
    },
};

// --- Result interpretation helpers ---

pub const AcceptError = error{
    Again,
    ConnectionAborted,
    SystemResources,
    Unexpected,
};

/// Interpret the result as an accepted socket fd.
pub fn acceptSocket(self: *const Completion) AcceptError!posix.socket_t {
    if (self.result < 0) return mapAcceptError(self.result);
    if (is_windows) {
        // On Windows, socket_t is an opaque pointer; result stores the raw handle value
        return @ptrFromInt(@as(usize, @intCast(self.result)));
    }
    return @intCast(self.result);
}

pub const RecvError = error{
    ConnectionReset,
    ConnectionRefused,
    Again,
    SystemResources,
    Unexpected,
    EndOfStream,
};

/// Interpret the result as the number of bytes received.
pub fn recvBytes(self: *const Completion) RecvError!usize {
    if (self.result < 0) return mapRecvError(self.result);
    if (self.result == 0) return error.EndOfStream;
    return @intCast(self.result);
}

pub const SendError = error{
    ConnectionReset,
    BrokenPipe,
    Again,
    SystemResources,
    Unexpected,
};

/// Interpret the result as the number of bytes sent.
pub fn sendBytes(self: *const Completion) SendError!usize {
    if (self.result < 0) return mapSendError(self.result);
    return @intCast(self.result);
}

pub const ConnectError = error{
    ConnectionRefused,
    ConnectionReset,
    NetworkUnreachable,
    AddressInUse,
    TimedOut,
    Again,
    Unexpected,
};

/// Check if a connect operation succeeded.
pub fn connectResult(self: *const Completion) ConnectError!void {
    if (self.result < 0) return mapConnectError(self.result);
}

/// Check if a timeout fired successfully (result == 0 means success).
pub fn timeoutResult(self: *const Completion) error{Unexpected}!void {
    if (self.result < 0) return error.Unexpected;
}

// --- Error mapping ---

fn mapAcceptError(res: i32) AcceptError {
    const e = std.posix.errno(@as(usize, @bitCast(@as(isize, res))));
    return switch (e) {
        .AGAIN => error.Again,
        .CONNABORTED => error.ConnectionAborted,
        .NOMEM, .NOBUFS, .MFILE, .NFILE => error.SystemResources,
        else => error.Unexpected,
    };
}

fn mapRecvError(res: i32) RecvError {
    const e = std.posix.errno(@as(usize, @bitCast(@as(isize, res))));
    return switch (e) {
        .CONNRESET => error.ConnectionReset,
        .CONNREFUSED => error.ConnectionRefused,
        .AGAIN => error.Again,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

fn mapSendError(res: i32) SendError {
    const e = std.posix.errno(@as(usize, @bitCast(@as(isize, res))));
    return switch (e) {
        .CONNRESET => error.ConnectionReset,
        .PIPE => error.BrokenPipe,
        .AGAIN => error.Again,
        .NOMEM, .NOBUFS => error.SystemResources,
        else => error.Unexpected,
    };
}

fn mapConnectError(res: i32) ConnectError {
    const e = std.posix.errno(@as(usize, @bitCast(@as(isize, res))));
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionReset,
        .NETUNREACH, .HOSTUNREACH => error.NetworkUnreachable,
        .ADDRINUSE => error.AddressInUse,
        .TIMEDOUT => error.TimedOut,
        .AGAIN, .INPROGRESS => error.Again,
        else => error.Unexpected,
    };
}
