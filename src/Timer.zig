const Completion = @import("Completion.zig");
const Loop = @import("Loop.zig");

/// Submit a one-shot timer that fires after the given duration.
/// Use `completion.timeoutResult()` in the callback to check for errors.
pub fn after(loop: *Loop, completion: *Completion, ns: u64, cb: Completion.Callback) void {
    completion.op = .{ .timeout = .{ .ns = ns } };
    completion.callback = cb;
    completion.result = 0;
    completion.next = null;
    loop.submit(completion);
}

/// Convenience: timeout in milliseconds.
pub fn afterMs(loop: *Loop, completion: *Completion, ms: u64, cb: Completion.Callback) void {
    after(loop, completion, ms * 1_000_000, cb);
}

/// Convenience: timeout in seconds.
pub fn afterS(loop: *Loop, completion: *Completion, seconds: u64, cb: Completion.Callback) void {
    after(loop, completion, seconds * 1_000_000_000, cb);
}
