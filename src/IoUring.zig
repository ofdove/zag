const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const Completion = @import("Completion.zig");
const Queue = @import("Queue.zig");

const IoUringBackend = @This();

const max_events = 256;

ring: linux.IoUring,
submissions: Queue.IntrusiveQueue(Completion),
n_pending: u32,

pub fn init() !IoUringBackend {
    return .{
        .ring = try linux.IoUring.init(256, 0),
        .submissions = .{},
        .n_pending = 0,
    };
}

pub fn deinit(self: *IoUringBackend) void {
    self.ring.deinit();
    self.* = undefined;
}

pub fn submit(self: *IoUringBackend, completion: *Completion) void {
    self.submissions.push(completion);
    self.n_pending += 1;
}

pub fn tick(self: *IoUringBackend, timeout_ns: ?u64) !u32 {
    // Stack-allocated storage for timeout timespecs.
    // These must live through the ring.submit() call, since the kernel
    // copies them during io_uring_enter().
    var timespecs: [max_events]linux.kernel_timespec = undefined;
    var ts_count: usize = 0;

    // Process submissions into io_uring SQEs
    while (self.submissions.pop()) |comp| {
        const user_data: u64 = @intFromPtr(comp);

        switch (comp.op) {
            .accept => |op| {
                _ = self.ring.accept(user_data, op.socket, null, null, posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
            .recv => |op| {
                _ = self.ring.recv(user_data, op.socket, .{ .buffer = op.buffer }, 0) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
            .send => |op| {
                _ = self.ring.send(user_data, op.socket, op.buffer, 0) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
            .connect => |op| {
                _ = self.ring.connect(user_data, op.socket, &op.address.any, op.address.getOsSockLen()) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
            .close => |op| {
                _ = self.ring.close(user_data, op.fd) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
            .timeout => |op| {
                if (ts_count >= max_events) {
                    self.submissions.push(comp);
                    break;
                }
                timespecs[ts_count] = .{
                    .sec = @intCast(op.ns / 1_000_000_000),
                    .nsec = @intCast(op.ns % 1_000_000_000),
                };
                _ = self.ring.timeout(user_data, &timespecs[ts_count], 0, 0) catch {
                    self.submissions.push(comp);
                    break;
                };
                ts_count += 1;
            },
            .noop => {
                _ = self.ring.nop(user_data) catch {
                    self.submissions.push(comp);
                    break;
                };
            },
        }
    }

    if (self.n_pending == 0) return 0;

    // Submit all queued SQEs to the kernel.
    // The kernel copies timeout timespecs during this call, so our
    // stack-allocated timespecs only need to live this long.
    _ = try self.ring.submit();

    // Wait for completions
    const wait_nr: u32 = if (timeout_ns != null and timeout_ns.? == 0) 0 else 1;
    var cqes: [max_events]linux.io_uring_cqe = undefined;
    const n_cqes = try self.ring.copy_cqes(&cqes, wait_nr);

    // Process completions
    var n_completed: u32 = 0;
    for (cqes[0..n_cqes]) |cqe| {
        const comp: *Completion = @ptrFromInt(cqe.user_data);

        // io_uring timeout fires with -ETIME, which is the expected "success" case
        if (comp.op == .timeout and cqe.res == -@as(i32, @intCast(@intFromEnum(linux.E.TIME)))) {
            comp.result = 0;
        } else {
            comp.result = cqe.res;
        }

        self.n_pending -= 1;
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }

    return n_completed;
}

pub fn hasPending(self: *const IoUringBackend) bool {
    return self.n_pending > 0 or !self.submissions.isEmpty();
}
