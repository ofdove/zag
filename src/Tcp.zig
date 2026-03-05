const std = @import("std");
const posix = std.posix;
const Completion = @import("Completion.zig");
const Loop = @import("Loop.zig");

pub const ListenOptions = struct {
    backlog: u31 = 128,
    reuse_address: bool = true,
    reuse_port: bool = false,
};

/// Create a non-blocking TCP listener socket, bound and listening on the given address.
pub fn listen(address: std.net.Address, options: ListenOptions) !posix.socket_t {
    const sock = try posix.socket(
        address.any.family,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
    errdefer posix.close(sock);

    if (options.reuse_address) {
        try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEADDR, &std.mem.toBytes(@as(c_int, 1)));
    }

    if (options.reuse_port) {
        if (@hasDecl(posix.SO, "REUSEPORT")) {
            try posix.setsockopt(sock, posix.SOL.SOCKET, posix.SO.REUSEPORT, &std.mem.toBytes(@as(c_int, 1)));
        }
    }

    try posix.bind(sock, &address.any, address.getOsSockLen());
    try posix.listen(sock, options.backlog);

    return sock;
}

/// Create a non-blocking TCP socket for outgoing connections.
pub fn createSocket(family: u32) !posix.socket_t {
    return posix.socket(
        family,
        posix.SOCK.STREAM | posix.SOCK.NONBLOCK | posix.SOCK.CLOEXEC,
        0,
    );
}

/// Submit an accept operation. When a client connects, the callback is invoked.
/// Use `completion.acceptSocket()` in the callback to get the new socket.
pub fn accept(loop: *Loop, completion: *Completion, socket: posix.socket_t, cb: Completion.Callback) void {
    completion.op = .{ .accept = .{ .socket = socket } };
    completion.callback = cb;
    completion.result = 0;
    completion.next = null;
    loop.submit(completion);
}

/// Submit a connect operation.
/// Use `completion.connectResult()` in the callback to check success.
/// The backend handles initiating the non-blocking connect and waiting for completion.
pub fn connect(loop: *Loop, completion: *Completion, socket: posix.socket_t, address: std.net.Address, cb: Completion.Callback) void {
    completion.op = .{ .connect = .{ .socket = socket, .address = address } };
    completion.callback = cb;
    completion.result = 0;
    completion.next = null;
    loop.submit(completion);
}

/// Submit a receive operation.
/// Use `completion.recvBytes()` in the callback to get the number of bytes received.
/// The data is in `completion.op.recv.buffer[0..n]`.
pub fn recv(loop: *Loop, completion: *Completion, socket: posix.socket_t, buffer: []u8, cb: Completion.Callback) void {
    completion.op = .{ .recv = .{ .socket = socket, .buffer = buffer } };
    completion.callback = cb;
    completion.result = 0;
    completion.next = null;
    loop.submit(completion);
}

/// Submit a send operation.
/// Use `completion.sendBytes()` in the callback to get the number of bytes sent.
pub fn send(loop: *Loop, completion: *Completion, socket: posix.socket_t, buffer: []const u8, cb: Completion.Callback) void {
    completion.op = .{ .send = .{ .socket = socket, .buffer = buffer } };
    completion.callback = cb;
    completion.result = 0;
    completion.next = null;
    loop.submit(completion);
}

/// Close a socket. This is synchronous and does not go through the event loop.
pub fn close(fd: posix.socket_t) void {
    posix.close(fd);
}
