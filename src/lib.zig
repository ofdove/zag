//! zag - An async I/O runtime for Zig
//!
//! A cross-platform, completion-based async I/O event loop, inspired by
//! tokio (Rust), libuv (C), and io_uring (Linux).
//!
//! Supported platforms:
//!   - macOS / iOS / BSD (kqueue)
//!   - Linux (io_uring preferred, epoll + timerfd fallback)

pub const Completion = @import("Completion.zig");
pub const Loop = @import("Loop.zig");
pub const Tcp = @import("Tcp.zig");
pub const Timer = @import("Timer.zig");

test {
    _ = Completion;
    _ = Loop;
    _ = Tcp;
    _ = Timer;
}
