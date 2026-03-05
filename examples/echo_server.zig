const std = @import("std");
const zag = @import("zag");

/// A simple TCP echo server built with the zag async I/O runtime.
/// Accepts connections on port 8080 and echoes back any data received.

const Client = struct {
    socket: std.posix.socket_t,
    recv_comp: zag.Completion = .{},
    send_comp: zag.Completion = .{},
    buffer: [4096]u8 = undefined,
    loop: *zag.Loop,

    fn start(self: *Client) void {
        zag.Tcp.recv(self.loop, &self.recv_comp, self.socket, &self.buffer, onRecv);
    }

    fn onRecv(completion: *zag.Completion) void {
        const self: *Client = @fieldParentPtr("recv_comp", completion);

        const n = completion.recvBytes() catch |err| {
            if (err == error.EndOfStream) {
                std.log.info("client disconnected (fd={})", .{self.socket});
            } else {
                std.log.err("recv error: {}", .{err});
            }
            self.cleanup();
            return;
        };

        // Echo the data back
        zag.Tcp.send(self.loop, &self.send_comp, self.socket, self.buffer[0..n], onSend);
    }

    fn onSend(completion: *zag.Completion) void {
        const self: *Client = @fieldParentPtr("send_comp", completion);

        _ = completion.sendBytes() catch |err| {
            std.log.err("send error: {}", .{err});
            self.cleanup();
            return;
        };

        // Continue reading
        zag.Tcp.recv(self.loop, &self.recv_comp, self.socket, &self.buffer, onRecv);
    }

    fn cleanup(self: *Client) void {
        zag.Tcp.close(self.socket);
        std.heap.page_allocator.destroy(self);
    }
};

const Server = struct {
    loop: *zag.Loop,
    listener: std.posix.socket_t,
    accept_comp: zag.Completion = .{},

    fn start(self: *Server) void {
        std.log.info("echo server listening on :8080", .{});
        zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
    }

    fn onAccept(completion: *zag.Completion) void {
        const self: *Server = @fieldParentPtr("accept_comp", completion);

        const client_fd = completion.acceptSocket() catch |err| {
            std.log.err("accept error: {}", .{err});
            // Try accepting again
            zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
            return;
        };

        std.log.info("new client connected (fd={})", .{client_fd});

        // Create a new client handler
        const client = std.heap.page_allocator.create(Client) catch {
            std.log.err("out of memory for new client", .{});
            zag.Tcp.close(client_fd);
            zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
            return;
        };
        client.* = .{
            .socket = client_fd,
            .loop = self.loop,
        };
        client.start();

        // Accept next connection
        zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
    }
};

pub fn main() !void {
    var loop = try zag.Loop.init();
    defer loop.deinit();

    const address = try std.net.Address.parseIp4("0.0.0.0", 8080);
    const listener = try zag.Tcp.listen(address, .{});
    defer zag.Tcp.close(listener);

    var server = Server{
        .loop = &loop,
        .listener = listener,
    };
    server.start();

    try loop.run(.until_done);
}
