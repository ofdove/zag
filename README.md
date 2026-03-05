# zag

A cross-platform, completion-based async I/O event loop for Zig.

## Features

- **Completion-based API** - submit operations with callbacks, no async/await required
- **Zero-allocation hot path** - intrusive linked lists and user-owned completions
- **Cross-platform** - macOS/BSD (kqueue), Linux (io_uring with epoll fallback)
- **TCP networking** - listen, accept, connect, recv, send
- **Timers** - nanosecond-precision one-shot timers

## Requirements

- Zig 0.15.0 or later

## Quick Start

```zig
const std = @import("std");
const zag = @import("zag");

const Context = struct {
    timer_comp: zag.Completion = .{},

    fn start(self: *Context, loop: *zag.Loop) void {
        zag.Timer.afterS(loop, &self.timer_comp, 1, onTimeout);
    }

    fn onTimeout(completion: *zag.Completion) void {
        const self: *Context = @fieldParentPtr("timer_comp", completion);
        _ = self;
        std.debug.print("timer fired!\n", .{});
    }
};

pub fn main() !void {
    var loop = try zag.Loop.init();
    defer loop.deinit();

    var ctx = Context{};
    ctx.start(&loop);

    try loop.run(.until_done);
}
```

## Usage as a Dependency

Add zag to your `build.zig.zon`:

```
zig fetch --save git+https://github.com/youruser/zag
```

Then in your `build.zig`:

```zig
const zag_dep = b.dependency("zag", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zag", zag_dep.module("zag"));
```

## API Overview

### Loop

```zig
var loop = try zag.Loop.init();
defer loop.deinit();
try loop.run(.until_done);
```

### TCP

```zig
// Listen
const listener = try zag.Tcp.listen(address, .{});

// Accept, recv, send
zag.Tcp.accept(loop, completion, listener, onAccept);
zag.Tcp.recv(loop, completion, socket, buffer, onRecv);
zag.Tcp.send(loop, completion, socket, data, onSend);

// Close (synchronous)
zag.Tcp.close(socket);
```

### Timers

```zig
zag.Timer.after(loop, completion, nanoseconds, callback);
zag.Timer.afterMs(loop, completion, milliseconds, callback);
zag.Timer.afterS(loop, completion, seconds, callback);
```

### Completions

Use `@fieldParentPtr` in callbacks to recover your context struct:

```zig
fn onRecv(completion: *zag.Completion) void {
    const self: *Client = @fieldParentPtr("recv_comp", completion);
    const n = completion.recvBytes() catch |err| { ... };
    // data is in self.buffer[0..n]
}
```

Result helpers: `acceptSocket()`, `recvBytes()`, `sendBytes()`, `connectResult()`, `timeoutResult()`.

## Examples

Run the included examples:

```sh
# TCP echo server on :8080
zig build run-echo

# HTTP server on :8080
zig build run-http
```

## Building

```sh
zig build          # build library and examples
zig build test     # run tests
```

## Platform Backends

| Platform       | Backend                         |
|----------------|----------------------------------|
| macOS / BSD    | kqueue                          |
| Linux          | io_uring (epoll fallback)       |

## License

MIT
