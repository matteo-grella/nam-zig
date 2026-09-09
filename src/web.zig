//! The local HTTP layer behind the window: serves the embedded page on the
//! loopback interface and maps its polls and controls onto the Gui. One
//! request per connection, handled on the accept thread (the page polls
//! ten times a second; every response is a few kilobytes at most).

const std = @import("std");
const gui_mod = @import("gui.zig");

const index_html = @embedFile("ui/index.html");

const html_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "text/html; charset=utf-8" },
    .{ .name = "cache-control", .value = "no-store" },
};
const json_headers = [_]std.http.Header{
    .{ .name = "content-type", .value = "application/json" },
    .{ .name = "cache-control", .value = "no-store" },
};

pub const Server = struct {
    io: std.Io,
    gui: *gui_mod.Gui,
    listener: std.Io.net.Server = undefined,
    port: u16 = 0,
    shutdown: std.atomic.Value(bool) = .init(false),
    /// Print one line per request (`gui --verbose`).
    verbose: bool = false,

    /// Binds 127.0.0.1 on `preferred`, or on an ephemeral port when that
    /// one is taken; `port` holds the result.
    pub fn bind(self: *Server, preferred: u16) !void {
        const address = try std.Io.net.IpAddress.parse("127.0.0.1", preferred);
        self.listener = address.listen(self.io, .{ .reuse_address = true }) catch blk: {
            const ephemeral = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
            break :blk try ephemeral.listen(self.io, .{ .reuse_address = true });
        };
        self.port = self.listener.socket.address.getPort();
    }

    /// The accept loop; returns after `stop`.
    pub fn run(self: *Server) void {
        defer self.listener.deinit(self.io);
        while (!self.shutdown.load(.acquire)) {
            const stream = self.listener.accept(self.io) catch |err| switch (err) {
                error.SocketNotListening, error.Canceled => break,
                else => {
                    if (self.shutdown.load(.acquire)) break;
                    continue;
                },
            };
            self.handle(stream);
        }
    }

    /// Stops the accept loop from another thread: flags the shutdown, then
    /// wakes `accept` with one loopback connection.
    pub fn stop(self: *Server) void {
        self.shutdown.store(true, .release);
        const address = std.Io.net.IpAddress.parse("127.0.0.1", self.port) catch return;
        const stream = address.connect(self.io, .{ .mode = .stream }) catch return;
        stream.close(self.io);
    }

    fn handle(self: *Server, stream: std.Io.net.Stream) void {
        defer stream.close(self.io);
        var read_buf: [16 * 1024]u8 = undefined;
        var write_buf: [16 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        var http = std.http.Server.init(&reader.interface, &writer.interface);
        var request = http.receiveHead() catch return;
        if (self.verbose) std.debug.print("{s} {s}\n", .{ @tagName(request.head.method), request.head.target });
        self.route(&request) catch {};
    }

    fn route(self: *Server, request: *std.http.Server.Request) !void {
        const target = request.head.target;
        const path_end = std.mem.indexOfScalar(u8, target, '?') orelse target.len;
        const path = target[0..path_end];
        const query = if (path_end < target.len) target[path_end + 1 ..] else "";
        if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
            return request.respond(index_html, .{ .keep_alive = false, .extra_headers = &html_headers });
        }
        if (std.mem.eql(u8, path, "/api/state")) return self.respondState(request);
        if (std.mem.eql(u8, path, "/api/set")) {
            self.gui.apply(query) catch |err| {
                var buf: [128]u8 = undefined;
                const body = std.fmt.bufPrint(&buf, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch "{\"error\":\"failed\"}";
                return request.respond(body, .{ .status = .internal_server_error, .keep_alive = false, .extra_headers = &json_headers });
            };
            return self.respondState(request);
        }
        if (std.mem.eql(u8, path, "/api/quit")) {
            self.gui.requestQuit();
            return request.respond("{\"ok\":true}", .{ .keep_alive = false, .extra_headers = &json_headers });
        }
        return request.respond("not found", .{ .status = .not_found, .keep_alive = false });
    }

    fn respondState(self: *Server, request: *std.http.Server.Request) !void {
        var aw: std.Io.Writer.Allocating = .init(self.gui.allocator);
        defer aw.deinit();
        try self.gui.writeState(&aw.writer);
        try request.respond(aw.written(), .{ .keep_alive = false, .extra_headers = &json_headers });
    }
};
