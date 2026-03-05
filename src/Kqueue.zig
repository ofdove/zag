const std = @import("std");
const posix = std.posix;
const system = posix.system;
const Completion = @import("Completion.zig");
const Queue = @import("Queue.zig");

const Kqueue = @This();

const c = system;
const Kevent = posix.Kevent;

const max_events = 256;

kq_fd: i32,
submissions: Queue.IntrusiveQueue(Completion),
n_pending: u32,

pub fn init() !Kqueue {
    return .{
        .kq_fd = try posix.kqueue(),
        .submissions = .{},
        .n_pending = 0,
    };
}

pub fn deinit(self: *Kqueue) void {
    posix.close(self.kq_fd);
    self.* = undefined;
}

pub fn submit(self: *Kqueue, completion: *Completion) void {
    self.submissions.push(completion);
    self.n_pending += 1;
}

/// Run one tick of the event loop.
/// Returns the number of completions processed.
pub fn tick(self: *Kqueue, timeout_ns: ?u64) !u32 {
    // 1. Build changelist from submissions
    var changelist: [max_events]Kevent = undefined;
    var n_changes: usize = 0;

    // Process immediate operations (close, noop) and build kqueue changelist
    var immediate_queue: Queue.IntrusiveQueue(Completion) = .{};

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
                if (n_changes >= max_events) {
                    // Re-queue for next tick
                    self.submissions.push(comp);
                    break;
                }
                changelist[n_changes] = makeReadEvent(comp);
                n_changes += 1;
            },
            .connect => |op| {
                // Start the non-blocking connect syscall
                const res = system.connect(op.socket, @ptrCast(&op.address.any), op.address.getOsSockLen());
                const e = posix.errno(res);
                if (e == .SUCCESS) {
                    // Connected immediately
                    comp.result = 0;
                    immediate_queue.push(comp);
                    self.n_pending -= 1;
                } else if (e == .INPROGRESS) {
                    // Connection in progress, wait for write readiness
                    if (n_changes >= max_events) {
                        self.submissions.push(comp);
                        break;
                    }
                    changelist[n_changes] = makeWriteEvent(comp);
                    n_changes += 1;
                } else {
                    // Immediate error
                    comp.result = -@as(i32, @intCast(@intFromEnum(e)));
                    immediate_queue.push(comp);
                    self.n_pending -= 1;
                }
            },
            .send => {
                if (n_changes >= max_events) {
                    self.submissions.push(comp);
                    break;
                }
                changelist[n_changes] = makeWriteEvent(comp);
                n_changes += 1;
            },
            .timeout => |op| {
                if (n_changes >= max_events) {
                    self.submissions.push(comp);
                    break;
                }
                changelist[n_changes] = makeTimerEvent(comp, op.ns);
                n_changes += 1;
            },
        }
    }

    // Fire callbacks for immediate completions
    var n_completed: u32 = 0;
    while (immediate_queue.pop()) |comp| {
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }

    // 2. Call kevent - submit changes and wait for events
    if (n_changes == 0 and self.n_pending == 0) return n_completed;

    const ts: posix.timespec = if (timeout_ns) |ns| .{
        .sec = @intCast(ns / 1_000_000_000),
        .nsec = @intCast(ns % 1_000_000_000),
    } else .{
        .sec = 0,
        .nsec = 0,
    };

    var events: [max_events]Kevent = undefined;
    const n_events = try posix.kevent(
        self.kq_fd,
        changelist[0..n_changes],
        &events,
        if (timeout_ns != null) &ts else null,
    );

    // 3. Process events
    for (events[0..n_events]) |ev| {
        // Check for errors in changelist registration
        if (ev.flags & c.EV.ERROR != 0) {
            const comp: *Completion = @ptrFromInt(ev.udata);
            comp.result = @intCast(-@as(i64, @intCast(ev.data)));
            self.n_pending -= 1;
            if (comp.callback) |cb| cb(comp);
            n_completed += 1;
            continue;
        }

        const comp: *Completion = @ptrFromInt(ev.udata);
        performOperation(comp);
        self.n_pending -= 1;
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }

    return n_completed;
}

pub fn hasPending(self: *const Kqueue) bool {
    return self.n_pending > 0 or !self.submissions.isEmpty();
}

// --- Kevent construction ---

fn makeReadEvent(comp: *Completion) Kevent {
    const fd: usize = switch (comp.op) {
        .accept => |op| @intCast(op.socket),
        .recv => |op| @intCast(op.socket),
        else => unreachable,
    };
    return .{
        .ident = fd,
        .filter = c.EVFILT.READ,
        .flags = c.EV.ADD | c.EV.ONESHOT,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(comp),
    };
}

fn makeWriteEvent(comp: *Completion) Kevent {
    const fd: usize = switch (comp.op) {
        .connect => |op| @intCast(op.socket),
        .send => |op| @intCast(op.socket),
        else => unreachable,
    };
    return .{
        .ident = fd,
        .filter = c.EVFILT.WRITE,
        .flags = c.EV.ADD | c.EV.ONESHOT,
        .fflags = 0,
        .data = 0,
        .udata = @intFromPtr(comp),
    };
}

fn makeTimerEvent(comp: *Completion, ns: u64) Kevent {
    return .{
        .ident = @intFromPtr(comp),
        .filter = c.EVFILT.TIMER,
        .flags = c.EV.ADD | c.EV.ONESHOT,
        .fflags = c.NOTE.NSECONDS,
        .data = @intCast(ns),
        .udata = @intFromPtr(comp),
    };
}

// --- Perform the actual I/O operation once readiness is signaled ---

fn performOperation(comp: *Completion) void {
    switch (comp.op) {
        .accept => |op| {
            var addr: posix.sockaddr.storage = undefined;
            var addr_len: posix.socklen_t = @sizeOf(posix.sockaddr.storage);
            const result = system.accept(op.socket, @ptrCast(&addr), &addr_len);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                const new_fd: posix.socket_t = @intCast(result);
                // Set non-blocking on the accepted socket
                setNonBlocking(new_fd);
                comp.result = @intCast(new_fd);
            }
        },
        .recv => |op| {
            const result = system.recvfrom(op.socket, op.buffer.ptr, op.buffer.len, 0, null, null);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                comp.result = @intCast(result);
            }
        },
        .send => |op| {
            const result = system.sendto(op.socket, op.buffer.ptr, op.buffer.len, 0, null, 0);
            const e = posix.errno(result);
            if (e != .SUCCESS) {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            } else {
                comp.result = @intCast(result);
            }
        },
        .connect => |op| {
            const result = system.connect(op.socket, @ptrCast(&op.address.any), op.address.getOsSockLen());
            const e = posix.errno(result);
            if (e == .SUCCESS or e == .ALREADY or e == .ISCONN) {
                comp.result = 0;
            } else if (e == .INPROGRESS) {
                // Connection still in progress - this shouldn't happen after
                // EVFILT_WRITE fires, but handle it anyway
                comp.result = 0;
            } else {
                comp.result = -@as(i32, @intCast(@intFromEnum(e)));
            }
        },
        .timeout => {
            // Timer fired successfully
            comp.result = 0;
        },
        .close, .noop => unreachable,
    }
}

fn setNonBlocking(fd: posix.socket_t) void {
    var fl_flags = posix.fcntl(fd, posix.F.GETFL, 0) catch return;
    fl_flags |= 1 << @bitOffsetOf(posix.O, "NONBLOCK");
    _ = posix.fcntl(fd, posix.F.SETFL, fl_flags) catch {};
}
