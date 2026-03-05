const std = @import("std");
const zag = @import("zag");

/// A minimal HTTP/1.1 server built with zag.
/// Responds with "Hello from zag!" to every request.

const response =
    "HTTP/1.1 200 OK\r\n" ++
    "Content-Type: text/plain\r\n" ++
    "Content-Length: 15\r\n" ++
    "Connection: close\r\n" ++
    "\r\n" ++
    "Hello from zag!";

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

        _ = completion.recvBytes() catch {
            self.cleanup();
            return;
        };

        // Send HTTP response (we don't parse the request for simplicity)
        zag.Tcp.send(self.loop, &self.send_comp, self.socket, response, onSend);
    }

    fn onSend(completion: *zag.Completion) void {
        const self: *Client = @fieldParentPtr("send_comp", completion);
        _ = completion.sendBytes() catch {};
        self.cleanup();
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
        std.log.info("http server listening on http://127.0.0.1:8080", .{});
        zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
    }

    fn onAccept(completion: *zag.Completion) void {
        const self: *Server = @fieldParentPtr("accept_comp", completion);

        const client_fd = completion.acceptSocket() catch |err| {
            std.log.err("accept error: {}", .{err});
            zag.Tcp.accept(self.loop, &self.accept_comp, self.listener, onAccept);
            return;
        };

        const client = std.heap.page_allocator.create(Client) catch {
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
