//! helpers for tests that boot `zeldi dev` as a child process and talk to it
//! over http.

const std = @import("std");
const Io = std.Io;

/// the log of the server started last, for `printLastLog`.
var last_log_path: ?[]const u8 = null;

pub const Server = struct {
    child: std.process.Child,
    log: Io.File,
    /// `http://127.0.0.1:<port>`, the public port the server bound.
    base: []const u8,
    /// the same for its operator port, which serves /debug/cells.
    operator: []const u8,

    /// starts zeldi on ports the kernel picks (`--port 0 --operator-port 0`,
    /// appended to `argv`) and waits for it to log which. a port picked here
    /// and reused across restarts could be taken in between by any other
    /// test's listener, since a freed ephemeral port goes back to the shared
    /// pool. `log_path` must outlive the test run.
    pub fn start(io: Io, arena: std.mem.Allocator, argv: []const []const u8, log_path: []const u8) !Server {
        const log = try Io.Dir.cwd().createFile(io, log_path, .{});
        errdefer log.close(io);
        const full = try std.mem.concat(arena, []const u8, &.{ argv, &.{ "--port", "0", "--operator-port", "0" } });
        var child = try std.process.spawn(io, .{ .argv = full, .stdout = .ignore, .stderr = .{ .file = log }, .environ_map = environ });
        errdefer child.kill(io);
        last_log_path = log_path;
        for (0..600) |_| {
            const text = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(16 * 1024 * 1024));
            const public = portAfter(text, "(zeldi): listening on http://127.0.0.1:");
            const operator = portAfter(text, "(zeldi): operator listening on http://127.0.0.1:");
            if (public != null and operator != null) return .{
                .child = child,
                .log = log,
                .base = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{public.?}),
                .operator = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{operator.?}),
            };
            try io.sleep(Io.Duration.fromMilliseconds(50), .awake);
        }
        return error.ServerNotListening;
    }

    /// the port in the complete log line that `marker` starts.
    fn portAfter(text: []const u8, marker: []const u8) ?u16 {
        const at = std.mem.indexOf(u8, text, marker) orelse return null;
        const digits = text[at + marker.len ..];
        const end = std.mem.indexOfScalar(u8, digits, '\n') orelse return null;
        return std.fmt.parseInt(u16, digits[0..end], 10) catch null;
    }

    pub fn stop(s: *Server, io: Io) void {
        s.child.kill(io);
        s.log.close(io);
    }
};

/// prints the tail of the last server's log, so a failure in a phase that
/// boots a server says what that server did. call it before the scratch
/// directory holding the log is deleted.
/// the environment servers start with, when set: the test's own, less what
/// `zig build` adds that a deployed zeldi doesn't see.
pub var environ: ?*const std.process.Environ.Map = null;

pub fn printLastLog(io: Io, arena: std.mem.Allocator) void {
    const path = last_log_path orelse return;
    const bytes = Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(1 << 20)) catch return;
    std.debug.print("last server log ({s}):\n{s}\n", .{ path, bytes[bytes.len -| 4000..] });
}

/// a scratch directory under .zig-cache. caller deletes it.
pub fn tempDir(io: Io, arena: std.mem.Allocator, name: []const u8) ![]const u8 {
    var seed: [8]u8 = undefined;
    io.random(&seed);
    const dir = try std.fmt.allocPrint(arena, ".zig-cache/{s}-{x}", .{ name, seed });
    try Io.Dir.cwd().createDirPath(io, dir);
    return dir;
}

pub fn writeJson(io: Io, arena: std.mem.Allocator, path: []const u8, value: anytype) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = try std.json.Stringify.valueAlloc(arena, value, .{}) });
}

pub fn get(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8) !struct { std.http.Status, []u8 } {
    return getAs(client, arena, url, null);
}

/// like get, with the Host header set to `host` instead of the url's.
///
/// every request gets its own connection. the tests restart servers on the
/// same port, and std.http.Client returns a pooled connection to the pool even
/// after a write to it failed, so once a server died under a pooled
/// connection every later request on that port failed until the deadline.
pub fn getAs(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8, host: ?[]const u8) !struct { std.http.Status, []u8 } {
    var body: std.Io.Writer.Allocating = .init(arena);
    const res = try client.fetch(.{
        .location = .{ .url = url },
        .keep_alive = false,
        .response_writer = &body.writer,
        .headers = .{ .host = if (host) |h| .{ .override = h } else .default },
    });
    return .{ res.status, body.written() };
}

pub fn expectStatus(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8, want: std.http.Status) !void {
    const status, const body = try get(client, arena, url);
    if (status != want) {
        std.debug.print("{s}: got {d} {s}, want {d}\n", .{ url, @backingInt(status), body, @backingInt(want) });
        return error.UnexpectedStatus;
    }
}

/// polls the host's own `/debug/cells` until the server answers. cells start
/// one after another before the port opens, so a process with many of them on
/// one slow core can take seconds; 30s is for a server that never comes up.
pub fn waitReady(io: Io, client: *std.http.Client, arena: std.mem.Allocator, base: []const u8) !void {
    const url = try std.fmt.allocPrint(arena, "{s}/debug/cells", .{base});
    var attempts: usize = 0;
    while (attempts < 600) : (attempts += 1) {
        if (get(client, arena, url)) |r| {
            if (r[0] == .ok) return;
        } else |_| {}
        try io.sleep(Io.Duration.fromMilliseconds(50), .awake);
    }
    return error.ServerNotReady;
}

test "a get after its server restarts on the same port reaches the new server" {
    const io = std.testing.io;
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = io };
    defer client.deinit();

    const any = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var first = try any.listen(io, .{ .reuse_address = true });
    const port = first.socket.address.getPort();
    const url = try std.fmt.allocPrint(arena.allocator(), "http://127.0.0.1:{d}/", .{port});
    var serving = try io.concurrent(answerOnce, .{ io, &first, "first" });
    _, const body = try get(&client, arena.allocator(), url);
    try std.testing.expectEqualStrings("first", body);
    try serving.await(io);
    first.deinit(io);

    var second = try (try Io.net.IpAddress.parseIp4("127.0.0.1", port)).listen(io, .{ .reuse_address = true });
    defer second.deinit(io);
    var serving_again = try io.concurrent(answerOnce, .{ io, &second, "second" });
    _, const again = try get(&client, arena.allocator(), url);
    try std.testing.expectEqualStrings("second", again);
    try serving_again.await(io);
}

/// answers one request on one connection, offering keep-alive, then closes it.
fn answerOnce(io: Io, server: *Io.net.Server, body: []const u8) !void {
    const stream = try server.accept(io);
    defer stream.close(io);
    var recv_buf: [1024]u8 = undefined;
    var send_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &recv_buf);
    var writer = stream.writer(io, &send_buf);
    var http_server = std.http.Server.init(&reader.interface, &writer.interface);
    var request = try http_server.receiveHead();
    try request.respond(body, .{});
}
