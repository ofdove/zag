const std = @import("std");
const posix = std.posix;
const system = posix.system;
const linux = std.os.linux;
const Completion = @import("Completion.zig");
const Queue = @import("Queue.zig");

const Epoll = @This();

const max_events = 256;

epoll_fd: i32,
timer_fd: i32,
submissions: Queue.IntrusiveQueue(Completion),
n_pending: u32,

/// Maps epoll-watched fds to their active completions.
/// For each fd we track up to one read and one write completion.
fd_state: std.AutoHashMap(i32, FdState),

const FdState = struct {
    read: ?*Completion = null,
    write: ?*Completion = null,
};

pub fn init() !Epoll {
    const epoll_fd = try posix.epoll_create1(0);
    errdefer posix.close(epoll_fd);

    const timer_fd = try posix.timerfd_create(.MONOTONIC, .{ .NONBLOCK = true });
    errdefer posix.close(timer_fd);

    return .{
        .epoll_fd = epoll_fd,
        .timer_fd = timer_fd,
        .submissions = .{},
        .n_pending = 0,
        .fd_state = std.AutoHashMap(i32, FdState).init(std.heap.page_allocator),
    };
}

pub fn deinit(self: *Epoll) void {
    self.fd_state.deinit();
    posix.close(self.timer_fd);
    posix.close(self.epoll_fd);
    self.* = undefined;
}

pub fn submit(self: *Epoll, completion: *Completion) void {
    self.submissions.push(completion);
    self.n_pending += 1;
}

pub fn tick(self: *Epoll, timeout_ns: ?u64) !u32 {
    // Process immediate operations and register async ones
    var immediate_queue: Queue.IntrusiveQueue(Completion) = .{};
    var timer_queue: Queue.IntrusiveQueue(Completion) = .{};

    while (self.submissions.pop()) |comp| {
        switch (comp.op) {
            .close => |op| {
                posix.close(op.fd);
                comp.result = 0;
                immediate_queue.push(comp);
                self.n_pending -= 1;
            },
            .noop => {
                comp.result = 0;
                immediate_queue.push(comp);
                self.n_pending -= 1;
            },
            .accept, .recv => {
                const fd: i32 = switch (comp.op) {
                    .accept => |op| op.socket,
                    .recv => |op| op.socket,
                    else => unreachable,
                };
                try self.registerFd(fd, comp, .read);
            },
            .connect => |op| {
                // Start the non-blocking connect syscall
                const res = linux.connect(op.socket, @ptrCast(&op.address.any), op.address.getOsSockLen());
                const e = posix.errno(res);
                if (e == .SUCCESS) {
                    comp.result = 0;
                    immediate_queue.push(comp);
                    self.n_pending -= 1;
                } else if (e == .INPROGRESS) {
                    try self.registerFd(op.socket, comp, .write);
                } else {
                    comp.result = -@as(i32, @intCast(@intFromEnum(e)));
                    immediate_queue.push(comp);
                    self.n_pending -= 1;
                }
            },
            .send => |op| {
                try self.registerFd(op.socket, comp, .write);
            },
            .timeout => {
                // Queue timers separately (use timerfd for the nearest one)
                timer_queue.push(comp);
            },
        }
    }

    // Fire immediate callbacks
    var n_completed: u32 = 0;
    while (immediate_queue.pop()) |comp| {
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }

    // Handle timer: set timerfd to the first timer's duration
    // For simplicity, process one timer at a time using timerfd
    var active_timer: ?*Completion = null;
    if (timer_queue.pop()) |timer_comp| {
        active_timer = timer_comp;
        const ns = timer_comp.op.timeout.ns;
        const its = linux.itimerspec{
            .it_interval = .{ .sec = 0, .nsec = 0 },
            .it_value = .{
                .sec = @intCast(ns / 1_000_000_000),
                .nsec = @intCast(ns % 1_000_000_000),
            },
        };
        try posix.timerfd_settime(self.timer_fd, .{}, &its, null);

        var ev = linux.epoll_event{
            .events = linux.EPOLL.IN,
            .data = .{ .ptr = @intFromPtr(timer_comp) },
        };
        posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, self.timer_fd, &ev) catch |err| {
            // If already registered, modify
            if (err == error.FileDescriptorAlreadyPresentInSet) {
                try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, self.timer_fd, &ev);
            } else return err;
        };
    }

    // Re-queue remaining timers
    while (timer_queue.pop()) |remaining| {
        self.submissions.push(remaining);
    }

    if (self.n_pending == 0 and active_timer == null) return n_completed;

    // Wait for events
    const timeout_ms: i32 = if (timeout_ns) |ns|
        @intCast(@min(ns / 1_000_000, std.math.maxInt(i31)))
    else
        -1;

    var events: [max_events]linux.epoll_event = undefined;
    const n_events = posix.epoll_wait(self.epoll_fd, &events, timeout_ms);

    for (events[0..n_events]) |ev| {
        const comp: *Completion = @ptrFromInt(ev.data.ptr);

        // Check if this is a timer completion
        if (active_timer != null and comp == active_timer.?) {
            // Read the timerfd to acknowledge
            var buf: [8]u8 = undefined;
            _ = posix.read(self.timer_fd, &buf) catch {};
            comp.result = 0;
            self.n_pending -= 1;
            if (comp.callback) |cb| cb(comp);
            n_completed += 1;
            active_timer = null;
            continue;
        }

        // Perform the actual I/O operation
        performOperation(comp);

        // Remove fd registration
        const fd: i32 = getFdFromCompletion(comp);
        if (self.fd_state.getPtr(fd)) |state| {
            switch (comp.op) {
                .accept, .recv => state.read = null,
                .connect, .send => state.write = null,
                else => {},
            }
            if (state.read == null and state.write == null) {
                posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_DEL, fd, null) catch {};
                _ = self.fd_state.remove(fd);
            }
        }

        self.n_pending -= 1;
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }

    return n_completed;
}

pub fn hasPending(self: *const Epoll) bool {
    return self.n_pending > 0 or !self.submissions.isEmpty();
}

const Direction = enum { read, write };

fn registerFd(self: *Epoll, fd: i32, comp: *Completion, dir: Direction) !void {
    const gop = try self.fd_state.getOrPut(fd);

    if (!gop.found_existing) {
        gop.value_ptr.* = .{};
    }

    switch (dir) {
        .read => gop.value_ptr.read = comp,
        .write => gop.value_ptr.write = comp,
    }

    var events: u32 = linux.EPOLL.ONESHOT;
    if (gop.value_ptr.read != null) events |= linux.EPOLL.IN;
    if (gop.value_ptr.write != null) events |= linux.EPOLL.OUT;

    var ev = linux.epoll_event{
        .events = events,
        .data = .{ .ptr = @intFromPtr(comp) },
    };

    if (gop.found_existing) {
        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_MOD, fd, &ev);
    } else {
        try posix.epoll_ctl(self.epoll_fd, linux.EPOLL.CTL_ADD, fd, &ev);
    }
}

fn getFdFromCompletion(comp: *Completion) i32 {
    return switch (comp.op) {
        .accept => |op| op.socket,
        .recv => |op| op.socket,
        .connect => |op| op.socket,
        .send => |op| op.socket,
        .close => |op| op.fd,
        else => -1,
    };
}

fn performOperation(comp: *Completion) void {
    switch (comp.op) {
        .accept => |op| {
            var addr: posix.sockaddr.storage = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const result = linux.accept4(op.socket, @ptrCast(&addr), &addr_len, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                comp.result = @intCast(result);
            }
        },
        .recv => |op| {
            const result = linux.recvfrom(op.socket, op.buffer.ptr, op.buffer.len, 0, null, null);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                comp.result = @intCast(result);
            }
        },
        .send => |op| {
            const result = linux.sendto(op.socket, op.buffer.ptr, op.buffer.len, 0, null, 0);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                comp.result = @intCast(result);
            }
        },
        .connect => |op| {
            const result = linux.connect(op.socket, @ptrCast(&op.address.any), op.address.getOsSockLen());
            const e = posix.errno(result);
            if (e == .SUCCESS or e == .ALREADY or e == .ISCONN) {
                comp.result = 0;
            } else {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            }
        },
        .timeout => {
            comp.result = 0;
        },
        .close, .noop => unreachable,
    }
}
