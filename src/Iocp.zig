const std = @import("std");
const Completion = @import("Completion.zig");
const Queue = @import("Queue.zig");

const Iocp = @This();

submissions: Queue.IntrusiveQueue(Completion),
n_pending: u32,

pub fn init() !Iocp {
    // TODO: Full IOCP implementation
    // CreateIoCompletionPort, GetQueuedCompletionStatusEx, etc.
    return .{
        .submissions = .{},
        .n_pending = 0,
    };
}

pub fn deinit(self: *Iocp) void {
    self.* = undefined;
}

pub fn submit(self: *Iocp, completion: *Completion) void {
    self.submissions.push(completion);
    self.n_pending += 1;
}

pub fn tick(self: *Iocp, timeout_ns: ?u64) !u32 {
    _ = timeout_ns;
    // Stub: process all submissions as immediate completions with errors
    var n_completed: u32 = 0;
    while (self.submissions.pop()) |comp| {
        comp.result = -1; // Not implemented
        self.n_pending -= 1;
        if (comp.callback) |cb| cb(comp);
        n_completed += 1;
    }
    return n_completed;
}

pub fn hasPending(self: *const Iocp) bool {
    return self.n_pending > 0 or !self.submissions.isEmpty();
}
