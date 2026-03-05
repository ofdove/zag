const std = @import("std");
const builtin = @import("builtin");
const Completion = @import("Completion.zig");
const Kqueue = @import("Kqueue.zig");
const Epoll = @import("Epoll.zig");
const IoUringBackend = @import("IoUring.zig");
const Loop = @This();

/// The platform-specific backend, selected at comptime.
/// On Linux, io_uring is preferred with automatic fallback to epoll.
const Backend = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos,
    .freebsd, .netbsd, .openbsd, .dragonfly,
    => Kqueue,
    .linux => LinuxBackend,
    else => @compileError("unsupported OS for zag event loop"),
};

/// Linux backend with io_uring -> epoll runtime fallback.
const LinuxBackend = struct {
    impl: union(enum) {
        io_uring: IoUringBackend,
        epoll: Epoll,
    },

    pub fn init() !LinuxBackend {
        if (IoUringBackend.init()) |ring| {
            return .{ .impl = .{ .io_uring = ring } };
        } else |_| {
            return .{ .impl = .{ .epoll = try Epoll.init() } };
        }
    }

    pub fn deinit(self: *LinuxBackend) void {
        switch (self.impl) {
            inline else => |*b| b.deinit(),
        }
    }

    pub fn submit(self: *LinuxBackend, completion: *Completion) void {
        switch (self.impl) {
            inline else => |*b| b.submit(completion),
        }
    }

    pub fn tick(self: *LinuxBackend, timeout_ns: ?u64) !u32 {
        switch (self.impl) {
            inline else => |*b| return try b.tick(timeout_ns),
        }
    }

    pub fn hasPending(self: *const LinuxBackend) bool {
        switch (self.impl) {
            inline else => |*b| return b.hasPending(),
        }
    }
};

pub const RunMode = enum {
    /// Run until there are no more pending operations.
    until_done,
    /// Run one iteration of the event loop (may block).
    once,
    /// Poll without blocking (non-blocking tick).
    no_wait,
};

backend: Backend,

pub fn init() !Loop {
    return .{
        .backend = try Backend.init(),
    };
}

pub fn deinit(self: *Loop) void {
    self.backend.deinit();
}

/// Submit a completion to the event loop.
/// The completion must remain valid until its callback is invoked.
pub fn submit(self: *Loop, completion: *Completion) void {
    self.backend.submit(completion);
}

/// Run the event loop.
pub fn run(self: *Loop, mode: RunMode) !void {
    switch (mode) {
        .until_done => {
            while (self.backend.hasPending()) {
                _ = try self.backend.tick(null);
            }
        },
        .once => {
            _ = try self.backend.tick(null);
        },
        .no_wait => {
            _ = try self.backend.tick(0);
        },
    }
}
