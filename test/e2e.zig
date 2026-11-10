//! boots `zeldi dev` with the spongebob cell on the jetstream fixture, then
//! pages through the feed over http, restarts the process, and checks the cell
//! kept its posts and its cursor. then puts spongebob behind the front cell
//! and checks every response it gave alone comes back the same.
//!
//! usage: e2e <zeldi> <spongebob.wasm> <fixture.ndjson> <front.wasm>

const std = @import("std");
const Io = std.Io;
const harness = @import("harness");
const Server = harness.Server;
const get = harness.get;
const expectStatus = harness.expectStatus;
const waitReady = harness.waitReady;

const feed_uri = "at://did:plc:smoke/app.bsky.feed.generator/sponge";
const feed_param = "at%3A%2F%2Fdid%3Aplc%3Asmoke%2Fapp.bsky.feed.generator%2Fsponge";

const expected = [_][]const u8{
    "at://did:plc:fixtureivan/app.bsky.feed.post/3m00000000i1",
    "at://did:plc:fixtureerin/app.bsky.feed.post/3m00000000e1",
    "at://did:plc:fixturecarol/app.bsky.feed.post/3m00000000c1",
    "at://did:plc:fixturealice/app.bsky.feed.post/3m00000000a1",
};

const Skeleton = struct {
    cursor: []const u8,
    feed: []const struct { post: []const u8 },
};

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 5) return error.Usage;
    // zig build sets NO_COLOR for a run step, and with it zeldi's log never
    // asks whether stderr is a tty; deployed, it does, under the jail.
    var environ = try init.environ_map.clone(arena);
    _ = environ.swapRemove("NO_COLOR");
    _ = environ.swapRemove("CLICOLOR_FORCE");
    harness.environ = &environ;
    const zeldi, const wasm, const base_fixture = .{ args[1], args[2], args[3] };
    const front_wasm = args[4];

    const dir = try harness.tempDir(io, arena, "feeds-e2e");
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    errdefer harness.printLastLog(io, arena);

    const config = try std.fmt.allocPrint(arena, "{s}/zeldi.json", .{dir});
    try harness.writeJson(io, arena, config, .{
        .tenants = .{.{
            .name = "feeds",
            .hosts = .{"*"},
            .cells = .{.{ .name = "feed:spongebob", .wasm = wasm, .egress = jetstreams, .config = cell_config }},
            .routes = .{.{ .prefix = "/", .cell = "feed:spongebob" }},
        }},
    });
    const data = try std.fmt.allocPrint(arena, "{s}/data", .{dir});
    const fixture = try std.fmt.allocPrint(arena, "{s}/jetstream.ndjson", .{dir});
    try writePaddedFixture(io, arena, base_fixture, fixture);

    const argv = [_][]const u8{ zeldi, "dev", "--config", config, "--data", data, "--fixture", fixture };

    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    {
        var server = try Server.start(io, arena, &argv, try std.fmt.allocPrint(arena, "{s}/first.log", .{dir}));
        defer server.stop(io);
        const base = server.base;
        try waitReady(io, &client, arena, server.operator);

        try expectStatus(&client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton", .{base}), .bad_request);
        try expectStatus(&client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed={s}&cursor=nope", .{ base, feed_param }), .bad_request);
        try expectStatus(&client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed=at%3A%2F%2Fdid%3Aplc%3Asmoke%2Fapp.bsky.feed.generator%2Fother", .{base}), .bad_request);
        try expectStatus(&client, arena, try std.fmt.allocPrint(arena, "{s}/nope", .{base}), .not_found);
        try expectGenerator(&client, arena, base);

        const posts = try pageAll(&client, arena, base, 3);
        try expectFeed(posts);
    }

    {
        const log_path = try std.fmt.allocPrint(arena, "{s}/restart.log", .{dir});
        var server = try Server.start(io, arena, &argv, log_path);
        defer server.stop(io);
        const base = server.base;
        try waitReady(io, &client, arena, server.operator);
        try expectFeed(try pageAll(&client, arena, base, 2));
        const log_bytes = try Io.Dir.cwd().readFileAlloc(io, log_path, arena, .limited(1 << 20));
        if (std.mem.indexOf(u8, log_bytes, "from cursor 1793560000000012") == null) {
            std.debug.print("restart did not resume from the stored cursor:\n{s}\n", .{log_bytes});
            return error.CursorNotResumed;
        }
    }
    try manyCells(io, &client, arena, dir, wasm, fixture, zeldi);
    try frontDoor(io, &client, arena, dir, zeldi, .{ .spongebob = wasm, .front = front_wasm }, fixture);
    std.debug.print("feeds e2e ok: {d} posts paged twice, cursor resumed after restart, {d} cells in one process, spongebob unchanged behind the front\n", .{ expected.len, many_cells });
}

const cell_config = .{ .hostname = "smoke.test", .feeds = .{feed_uri} };
/// the hosts spongebob subscribes to by default; with --fixture it never connects.
const jetstreams: []const []const u8 = &.{
    "wss://jetstream1.us-east.bsky.network",
    "wss://jetstream2.us-east.bsky.network",
    "wss://jetstream1.us-west.bsky.network",
    "wss://jetstream2.us-west.bsky.network",
};

/// the rest of a feed generator: the directory page, did document, and describe.
fn expectGenerator(client: *std.http.Client, arena: std.mem.Allocator, base: []const u8) !void {
    _, const page = try get(client, arena, try std.fmt.allocPrint(arena, "{s}/", .{base}));
    if (std.mem.indexOf(u8, page, "href=\"https://bsky.app/profile/did:plc:smoke/feed/sponge\"") == null) {
        std.debug.print("directory page does not link the feed:\n{s}\n", .{page});
        return error.WrongDirectory;
    }
    _, const did_doc = try get(client, arena, try std.fmt.allocPrint(arena, "{s}/.well-known/did.json", .{base}));
    const Did = struct { id: []const u8, service: []const struct { serviceEndpoint: []const u8 } };
    const did = try std.json.parseFromSliceLeaky(Did, arena, did_doc, .{ .ignore_unknown_fields = true });
    if (!std.mem.eql(u8, did.id, "did:web:smoke.test") or !std.mem.eql(u8, did.service[0].serviceEndpoint, "https://smoke.test")) return error.WrongDidDocument;
    _, const described = try get(client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.describeFeedGenerator", .{base}));
    const Described = struct { did: []const u8, feeds: []const struct { uri: []const u8 } };
    const d = try std.json.parseFromSliceLeaky(Described, arena, described, .{});
    if (!std.mem.eql(u8, d.did, "did:web:smoke.test") or d.feeds.len != 1 or !std.mem.eql(u8, d.feeds[0].uri, feed_uri)) return error.WrongDescribe;
}

/// the fixture batch is delivered asynchronously, and requests run between
/// its chunks, so poll until the whole batch has landed.
fn pageAll(client: *std.http.Client, arena: std.mem.Allocator, base: []const u8, limit: u32) ![]const []const u8 {
    var posts: std.ArrayList([]const u8) = .empty;
    var tries: usize = 0;
    while (true) : (tries += 1) {
        posts.clearRetainingCapacity();
        var cursor: ?[]const u8 = null;
        var pages: usize = 0;
        while (true) : (pages += 1) {
            if (pages > expected.len + 2) return error.TooManyPages;
            const url = if (cursor) |cur|
                try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed={s}&limit={d}&cursor={s}", .{ base, feed_param, limit, cur })
            else
                try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed={s}&limit={d}", .{ base, feed_param, limit });
            const status, const body = try get(client, arena, url);
            if (status != .ok) {
                std.debug.print("{s}: {d} {s}\n", .{ url, @backingInt(status), body });
                return error.UnexpectedStatus;
            }
            const page = try std.json.parseFromSliceLeaky(Skeleton, arena, body, .{});
            if (page.feed.len > limit) return error.PageTooLarge;
            for (page.feed) |item| try posts.append(arena, item.post);
            if (std.mem.eql(u8, page.cursor, "eof")) break;
            cursor = page.cursor;
        }
        if (matches(posts.items) or tries >= 100) return posts.items;
        try client.io.sleep(Io.Duration.fromMilliseconds(50), .awake);
    }
}

fn matches(posts: []const []const u8) bool {
    if (posts.len != expected.len) return false;
    for (expected, posts) |want, got| if (!std.mem.eql(u8, want, got)) return false;
    return true;
}

fn expectFeed(posts: []const []const u8) !void {
    if (posts.len != expected.len) {
        std.debug.print("got {d} posts, want {d}: {f}\n", .{ posts.len, expected.len, std.json.fmt(posts, .{}) });
        return error.WrongFeed;
    }
    for (expected, posts) |want, got| {
        if (!std.mem.eql(u8, want, got)) {
            std.debug.print("got {s}, want {s}\n", .{ got, want });
            return error.WrongFeed;
        }
    }
}

/// copies the fixture with enough non-matching posts ahead of its delete that
/// the window spans several on_events chunks, so the delete only takes effect
/// if the cell commits the whole window as one transaction.
fn writePaddedFixture(io: Io, arena: std.mem.Allocator, src: []const u8, dst: []const u8) !void {
    const base = try Io.Dir.cwd().readFileAlloc(io, src, arena, .limited(1 << 20));
    const delete_at = std.mem.indexOf(u8, base, "{\"did\":\"did:plc:fixturegrace\",\"time_us\":1793560000000011") orelse return error.FixtureChanged;
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(base[0..delete_at]);
    for (0..400) |i| try out.writer.print(
        \\{{"did":"did:plc:fixturefiller","time_us":1793560000000011,"kind":"commit","commit":{{"operation":"create","collection":"app.bsky.feed.post","rkey":"3mfill{d:0>6}","cid":"bafyreifiller{d:0>6}","record":{{"$type":"app.bsky.feed.post","createdAt":"2026-11-01T19:00:01.000Z","text":"filler post {d} that should never match the spongebob filter at all"}}}}}}
        \\
    , .{ i, i, i });
    try out.writer.writeAll(base[delete_at..]);
    if (out.written().len < 2 * 64 * 1024) return error.FixtureTooSmall;
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = dst, .data = out.written() });
}

const many_cells = 64;

/// a process full of cells: every one must start and ingest without a trap.
/// cells reuse freed host memory once enough of them exist, which is how
/// non-zeroed linear memory once broke the 12th to 45th cell.
fn manyCells(io: Io, client: *std.http.Client, arena: std.mem.Allocator, dir: []const u8, wasm: []const u8, fixture: []const u8, zeldi: []const u8) !void {
    const Spec = struct { name: []const u8, wasm: []const u8, egress: []const []const u8 = jetstreams, config: @TypeOf(cell_config) = cell_config };
    const specs = try arena.alloc(Spec, many_cells);
    for (specs, 0..) |*s, i| s.* = .{ .name = try std.fmt.allocPrint(arena, "feed:many{d}", .{i}), .wasm = wasm };
    const config = try std.fmt.allocPrint(arena, "{s}/many.json", .{dir});
    try harness.writeJson(io, arena, config, .{ .tenants = .{.{ .name = "many", .cells = specs }} });
    const data = try std.fmt.allocPrint(arena, "{s}/many-data", .{dir});
    const argv = [_][]const u8{ zeldi, "dev", "--config", config, "--data", data, "--fixture", fixture };

    var server = try Server.start(io, arena, &argv, try std.fmt.allocPrint(arena, "{s}/many.log", .{dir}));
    defer server.stop(io);
    try waitReady(io, client, arena, server.operator);

    const Stats = struct { cells: []const struct { name: []const u8, calls: u64, traps: u64 } };
    const url = try std.fmt.allocPrint(arena, "{s}/debug/cells", .{server.operator});
    // a slow machine is fine; a machine where calls stop climbing is not. so
    // the test fails after 5s without progress, not after 5s in total.
    var last_calls: u64 = 0;
    var stalled: usize = 0;
    while (true) : (stalled += 1) {
        const status, const body = try get(client, arena, url);
        if (status != .ok) return error.UnexpectedStatus;
        const stats = try std.json.parseFromSliceLeaky(Stats, arena, body, .{ .ignore_unknown_fields = true });
        if (stats.cells.len != many_cells) return error.WrongCellCount;
        var ingested: usize = 0;
        var calls: u64 = 0;
        for (stats.cells) |cell| {
            if (cell.traps != 0) {
                std.debug.print("{s} trapped {d} times\n", .{ cell.name, cell.traps });
                return error.CellTrapped;
            }
            if (cell.calls >= 3) ingested += 1;
            calls += cell.calls;
        }
        if (ingested == many_cells) return;
        if (calls > last_calls) {
            last_calls = calls;
            stalled = 0;
        }
        if (stalled >= 100) {
            for (stats.cells) |cell| if (cell.calls < 3) std.debug.print("{s}: {d} calls\n", .{ cell.name, cell.calls });
            const log_bytes = Io.Dir.cwd().readFileAlloc(io, try std.fmt.allocPrint(arena, "{s}/many.log", .{dir}), arena, .limited(1 << 20)) catch "";
            std.debug.print("server log tail:\n{s}\n", .{log_bytes[log_bytes.len -| 4000..]});
            return error.CellsDidNotIngest;
        }
        try io.sleep(Io.Duration.fromMilliseconds(50), .awake);
    }
}

/// what a client sees of one response, compared byte for byte.
const Seen = struct { status: u16, content_type: []const u8, body: []const u8 };

fn fetchSeen(client: *std.http.Client, arena: std.mem.Allocator, url: []const u8) !Seen {
    var req = try client.request(.GET, try std.Uri.parse(url), .{});
    defer req.deinit();
    try req.sendBodiless();
    var response = try req.receiveHead(&.{});
    const content_type = try arena.dupe(u8, response.head.content_type orelse "");
    const body = try response.reader(&.{}).allocRemaining(arena, .limited(1 << 20));
    return .{ .status = @backingInt(response.head.status), .content_type = content_type, .body = body };
}

/// the requests a feed host answered before the front cell existed. each must
/// come back the same through the front.
const unchanged_paths = [_][]const u8{
    "/.well-known/did.json",
    "/xrpc/app.bsky.feed.getFeedSkeleton",
    "/xrpc/app.bsky.feed.getFeedSkeleton?feed=" ++ feed_param,
    "/xrpc/app.bsky.feed.getFeedSkeleton?feed=" ++ feed_param ++ "&limit=2",
    "/xrpc/app.bsky.feed.getFeedSkeleton?feed=" ++ feed_param ++ "&limit=2&cursor=nope",
    "/xrpc/app.bsky.feed.getFeedSkeleton?feed=at%3A%2F%2Fdid%3Aplc%3Asmoke%2Fapp.bsky.feed.generator%2Fother",
    "/nope",
};
/// these list every feed on the host, so they match only while spongebob is the only one.
const listing_paths = [_][]const u8{ "/", "/xrpc/app.bsky.feed.describeFeedGenerator" };

fn seeAll(client: *std.http.Client, arena: std.mem.Allocator, base: []const u8, paths: []const []const u8) ![]Seen {
    const out = try arena.alloc(Seen, paths.len);
    for (paths, out) |path, *s| s.* = try fetchSeen(client, arena, try std.fmt.allocPrint(arena, "{s}{s}", .{ base, path }));
    return out;
}

fn expectSame(paths: []const []const u8, want: []const Seen, got: []const Seen) !void {
    for (paths, want, got) |path, w, g| {
        if (w.status != g.status or !std.mem.eql(u8, w.content_type, g.content_type) or !std.mem.eql(u8, w.body, g.body)) {
            std.debug.print("{s} changed behind the front:\n  was {d} {s} {s}\n  now {d} {s} {s}\n", .{ path, w.status, w.content_type, w.body, g.status, g.content_type, g.body });
            return error.FrontChangedResponse;
        }
    }
}


/// spongebob behind a front cell, on the same data it used alone.
fn frontDoor(io: Io, client: *std.http.Client, arena: std.mem.Allocator, dir: []const u8, zeldi: []const u8, wasms: struct { spongebob: []const u8, front: []const u8 }, fixture: []const u8) !void {
    const data = try std.fmt.allocPrint(arena, "{s}/front-data", .{dir});
    const spongebob = .{ .name = "feed:spongebob", .wasm = wasms.spongebob, .egress = jetstreams, .config = cell_config };

    const all_paths = unchanged_paths ++ listing_paths;
    const before = blk: {
        const config = try std.fmt.allocPrint(arena, "{s}/alone.json", .{dir});
        try harness.writeJson(io, arena, config, .{ .tenants = .{.{
            .name = "feeds",
            .hosts = .{"*"},
            .cells = .{spongebob},
            .routes = .{.{ .prefix = "/", .cell = "feed:spongebob" }},
        }} });
        const argv = [_][]const u8{ zeldi, "dev", "--config", config, "--data", data, "--fixture", fixture };
        var server = try Server.start(io, arena, &argv, try std.fmt.allocPrint(arena, "{s}/alone.log", .{dir}));
        defer server.stop(io);
        const base = server.base;
        try waitReady(io, client, arena, server.operator);
        try expectFeed(try pageAll(client, arena, base, 3));
        break :blk try seeAll(client, arena, base, &all_paths);
    };

    {
        const config = try std.fmt.allocPrint(arena, "{s}/front-only.json", .{dir});
        try harness.writeJson(io, arena, config, .{ .tenants = .{.{
            .name = "feeds",
            .hosts = .{"*"},
            .cells = .{
                .{ .name = "feed:front", .wasm = wasms.front, .config = .{ .hostname = "smoke.test", .feeds = .{.{ .uri = feed_uri, .cell = "feed:spongebob" }} } },
                spongebob,
            },
            .routes = .{.{ .prefix = "/", .cell = "feed:front" }},
        }} });
        const argv = [_][]const u8{ zeldi, "dev", "--config", config, "--data", data, "--fixture", fixture };
        var server = try Server.start(io, arena, &argv, try std.fmt.allocPrint(arena, "{s}/front-only.log", .{dir}));
        defer server.stop(io);
        const base = server.base;
        try waitReady(io, client, arena, server.operator);
        try expectSame(&all_paths, before, try seeAll(client, arena, base, &all_paths));
    }
}
