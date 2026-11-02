//! boots `zeldi dev` with the spongebob cell on the jetstream fixture, then
//! pages through the feed over http, restarts the process, and checks the cell
//! kept its posts and its cursor. then puts spongebob behind the front cell
//! and checks every response it gave alone comes back the same, and that mirror
//! cells fill from a local stand-in for their source.
//!
//! usage: e2e <zeldi> <spongebob.wasm> <fixture.ndjson> <front.wasm> <mirror.wasm> <graze testdata dir>

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
    if (args.len != 7) return error.Usage;
    // zig build sets NO_COLOR for a run step, and with it zeldi's log never
    // asks whether stderr is a tty; deployed, it does, under the jail.
    var environ = try init.environ_map.clone(arena);
    _ = environ.swapRemove("NO_COLOR");
    _ = environ.swapRemove("CLICOLOR_FORCE");
    harness.environ = &environ;
    const zeldi, const wasm, const base_fixture = .{ args[1], args[2], args[3] };
    const front_wasm, const mirror_wasm, const graze_dir = .{ args[4], args[5], args[6] };

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
    try frontDoor(io, &client, arena, dir, zeldi, .{ .spongebob = wasm, .front = front_wasm, .mirror = mirror_wasm }, graze_dir, fixture);
    std.debug.print("feeds e2e ok: {d} posts paged twice, cursor resumed after restart, {d} cells in one process, spongebob unchanged behind the front, mirrors filled and backed off\n", .{ expected.len, many_cells });
}

const cell_config = .{ .hostname = "smoke.test", .feeds = .{feed_uri} };
/// the hosts spongebob subscribes to by default; with --fixture it never connects.
const jetstreams: []const []const u8 = &.{
    "jetstream1.us-east.bsky.network",
    "jetstream2.us-east.bsky.network",
    "jetstream1.us-west.bsky.network",
    "jetstream2.us-west.bsky.network",
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

/// the fixture batch is delivered asynchronously, so poll until it lands.
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
        if (posts.items.len >= expected.len or tries >= 100) return posts.items;
        try client.io.sleep(Io.Duration.fromMilliseconds(50), .awake);
    }
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

const mirror_did = "did:plc:smoke";
fn mirrorUri(comptime rkey: []const u8) []const u8 {
    return "at://" ++ mirror_did ++ "/app.bsky.feed.generator/" ++ rkey;
}
const graze_source = "at://did:plc:graze/app.bsky.feed.generator/";
const user_agent = "feeds-e2e (+https://smoke.test)";

/// spongebob behind a front cell, on the same sqlite it used alone, then
/// joined by mirror cells that poll a local stand-in for the source feeds.
fn frontDoor(io: Io, client: *std.http.Client, arena: std.mem.Allocator, dir: []const u8, zeldi: []const u8, wasms: struct { spongebob: []const u8, front: []const u8, mirror: []const u8 }, graze_dir: []const u8, fixture: []const u8) !void {
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

    const graze_addr = try Io.net.IpAddress.parseIp4("127.0.0.1", 0);
    var graze = try graze_addr.listen(io, .{});
    defer graze.deinit(io);
    var stand_in: Graze = .{ .io = io, .arena = arena, .dir = graze_dir };
    var serving = try io.concurrent(Graze.serve, .{ &stand_in, &graze });
    defer serving.cancel(io) catch {};
    const endpoint = try std.fmt.allocPrint(arena, "http://127.0.0.1:{d}", .{graze.socket.address.getPort()});

    const config = try std.fmt.allocPrint(arena, "{s}/full.json", .{dir});
    const Mirror = struct { name: []const u8, wasm: []const u8, egress: []const []const u8, user_agent: []const u8, config: struct { feed: []const u8, source: []const u8, endpoint: []const u8, poll_ms: i64 } };
    const mirror = struct {
        fn of(wasm: []const u8, endpoint_: []const u8, comptime rkey: []const u8, comptime source: []const u8, poll_ms: i64) Mirror {
            return .{ .name = "feed:" ++ rkey, .wasm = wasm, .egress = &.{"127.0.0.1"}, .user_agent = user_agent, .config = .{
                .feed = mirrorUri(rkey),
                .source = graze_source ++ source,
                .endpoint = endpoint_,
                .poll_ms = poll_ms,
            } };
        }
    }.of;
    try harness.writeJson(io, arena, config, .{ .tenants = .{.{
        .name = "feeds",
        .hosts = .{"*"},
        .cells = .{
            .{ .name = "feed:front", .wasm = wasms.front, .config = .{ .hostname = "smoke.test", .feeds = .{
                .{ .uri = feed_uri, .cell = "feed:spongebob" },
                .{ .uri = mirrorUri("live-mi"), .cell = "feed:live-mi" },
                .{ .uri = mirrorUri("live-desk"), .cell = "feed:live-desk" },
                .{ .uri = mirrorUri("live-busy"), .cell = "feed:live-busy" },
            } } },
            spongebob,
            mirror(wasms.mirror, endpoint, "live-mi", "races-mi", 300),
            mirror(wasms.mirror, endpoint, "live-desk", "desk-natl", 300),
            mirror(wasms.mirror, endpoint, "live-busy", "busy", 100),
        },
        .routes = .{.{ .prefix = "/", .cell = "feed:front" }},
    }} });
    const argv = [_][]const u8{ zeldi, "dev", "--config", config, "--data", data, "--fixture", fixture, "--dev-loopback-egress" };
    var server = try Server.start(io, arena, &argv, try std.fmt.allocPrint(arena, "{s}/full.log", .{dir}));
    defer server.stop(io);
    const base = server.base;
    try waitReady(io, client, arena, server.operator);
    try expectSame(&unchanged_paths, before[0..unchanged_paths.len], try seeAll(client, arena, base, &unchanged_paths));

    _, const described = try get(client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.describeFeedGenerator", .{base}));
    const Described = struct { did: []const u8, feeds: []const struct { uri: []const u8 } };
    const d = try std.json.parseFromSliceLeaky(Described, arena, described, .{});
    if (!std.mem.eql(u8, d.did, "did:web:smoke.test") or d.feeds.len != 4 or !std.mem.eql(u8, d.feeds[0].uri, feed_uri) or !std.mem.eql(u8, d.feeds[1].uri, mirrorUri("live-mi"))) {
        std.debug.print("describe lists the wrong feeds: {s}\n", .{described});
        return error.WrongDescribe;
    }
    _, const page = try get(client, arena, try std.fmt.allocPrint(arena, "{s}/", .{base}));
    for ([_][]const u8{ "/feed/sponge\"", "/feed/live-mi\"", "/feed/live-desk\"" }) |link| {
        if (std.mem.indexOf(u8, page, link) == null) {
            std.debug.print("directory does not link {s}\n", .{link});
            return error.WrongDirectory;
        }
    }

    const mi = try mirroredFeed(io, client, arena, base, mirrorUri("live-mi"), 160);
    try expectPosts(mi, &.{ try stand_in.posts("races-mi-1.json"), try stand_in.posts("races-mi-2.json") });
    const desk = try mirroredFeed(io, client, arena, base, mirrorUri("live-desk"), 76);
    try expectPosts(desk, &.{try stand_in.posts("desk-natl-1.json")});
    try harness.expectStatus(client, arena, try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed=at%3A%2F%2Fdid%3Aplc%3Asmoke%2Fapp.bsky.feed.generator%2Flive-mi&cursor=x", .{base}), .bad_request);

    // a few more polls: page 1 every time, page 2 only on the first, when
    // everything on page 1 was new.
    try io.sleep(Io.Duration.fromMilliseconds(1_500), .awake);
    const h = stand_in.snapshot();
    if (h.mi_first < 3 or h.mi_second != 1 or h.desk_second != 1) {
        std.debug.print("live-mi polled page 1 {d} times and page 2 {d} times; live-desk page 2 {d} times\n", .{ h.mi_first, h.mi_second, h.desk_second });
        return error.WrongPolling;
    }
    // live-busy polls every 100ms but its source answers 503, so it backs off.
    if (h.busy < 2 or h.busy > 6) {
        std.debug.print("live-busy hit a failing source {d} times in about 2s\n", .{h.busy});
        return error.NoBackoff;
    }
    if (h.wrong_agent) return error.WrongUserAgent;
}

fn mirroredFeed(io: Io, client: *std.http.Client, arena: std.mem.Allocator, base: []const u8, uri: []const u8, want: usize) ![]const []const u8 {
    var encoded: std.Io.Writer.Allocating = .init(arena);
    try std.Uri.Component.percentEncode(&encoded.writer, uri, isUnreserved);
    var tries: usize = 0;
    while (true) : (tries += 1) {
        var posts: std.ArrayList([]const u8) = .empty;
        var cursor: ?[]const u8 = null;
        while (true) {
            const url = if (cursor) |cur|
                try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed={s}&limit=100&cursor={s}", .{ base, encoded.written(), cur })
            else
                try std.fmt.allocPrint(arena, "{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed={s}&limit=100", .{ base, encoded.written() });
            const status, const body = try get(client, arena, url);
            if (status != .ok) {
                std.debug.print("{s}: {d} {s}\n", .{ url, @backingInt(status), body });
                return error.UnexpectedStatus;
            }
            const page = try std.json.parseFromSliceLeaky(Skeleton, arena, body, .{});
            for (page.feed) |item| try posts.append(arena, item.post);
            if (std.mem.eql(u8, page.cursor, "eof")) break;
            cursor = page.cursor;
        }
        if (posts.items.len >= want or tries >= 100) return posts.items;
        try io.sleep(Io.Duration.fromMilliseconds(50), .awake);
    }
}

fn expectPosts(got: []const []const u8, pages: []const []const []const u8) !void {
    var i: usize = 0;
    for (pages) |page| for (page) |want| {
        if (i >= got.len or !std.mem.eql(u8, got[i], want)) {
            std.debug.print("post {d}: got {s}, want {s}\n", .{ i, if (i < got.len) got[i] else "nothing", want });
            return error.WrongMirror;
        }
        i += 1;
    };
    if (i != got.len) {
        std.debug.print("got {d} posts, want {d}\n", .{ got.len, i });
        return error.WrongMirror;
    }
}

fn isUnreserved(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
}

/// a stand-in for the source generator, answering getFeedSkeleton from the
/// recorded pages: races-mi has two, desk-natl one, and busy always fails.
const Graze = struct {
    io: Io,
    arena: std.mem.Allocator,
    dir: []const u8,
    mutex: Io.Mutex = .init,
    hits: Hits = .{},

    const Hits = struct { mi_first: u32 = 0, mi_second: u32 = 0, desk_second: u32 = 0, busy: u32 = 0, wrong_agent: bool = false };

    fn snapshot(g: *Graze) Hits {
        g.mutex.lockUncancelable(g.io);
        defer g.mutex.unlock(g.io);
        return g.hits;
    }

    fn posts(g: *Graze, name: []const u8) ![]const []const u8 {
        const bytes = try Io.Dir.cwd().readFileAlloc(g.io, try std.fs.path.join(g.arena, &.{ g.dir, name }), g.arena, .limited(1 << 20));
        const page = try std.json.parseFromSliceLeaky(struct { feed: []const struct { post: []const u8 } }, g.arena, bytes, .{ .ignore_unknown_fields = true });
        const out = try g.arena.alloc([]const u8, page.feed.len);
        for (page.feed, out) |item, *p| p.* = item.post;
        return out;
    }

    fn serve(g: *Graze, server: *Io.net.Server) !void {
        var group: Io.Group = .init;
        defer group.cancel(g.io);
        while (true) {
            const stream = try server.accept(g.io);
            group.concurrent(g.io, connection, .{ g, stream }) catch stream.close(g.io);
        }
    }

    fn connection(g: *Graze, stream: Io.net.Stream) void {
        defer stream.close(g.io);
        g.answer(stream) catch {};
    }

    fn answer(g: *Graze, stream: Io.net.Stream) !void {
        var recv_buf: [4096]u8 = undefined;
        var send_buf: [4096]u8 = undefined;
        var reader = stream.reader(g.io, &recv_buf);
        var writer = stream.writer(g.io, &send_buf);
        var http_server = std.http.Server.init(&reader.interface, &writer.interface);
        while (true) {
            var request = http_server.receiveHead() catch return;
            const target = request.head.target;
            var agent: []const u8 = "";
            var it = request.iterateHeaders();
            while (it.next()) |h| if (std.ascii.eqlIgnoreCase(h.name, "user-agent")) {
                agent = h.value;
            };
            const paged = std.mem.indexOf(u8, target, "&cursor=") != null;
            const file: ?[]const u8 = blk: {
                g.mutex.lockUncancelable(g.io);
                defer g.mutex.unlock(g.io);
                if (!std.mem.eql(u8, agent, user_agent)) g.hits.wrong_agent = true;
                if (std.mem.indexOf(u8, target, "races-mi") != null) {
                    if (paged) g.hits.mi_second += 1 else g.hits.mi_first += 1;
                    break :blk if (paged) "races-mi-2.json" else "races-mi-1.json";
                }
                if (std.mem.indexOf(u8, target, "desk-natl") != null) {
                    if (paged) g.hits.desk_second += 1;
                    break :blk if (paged) null else "desk-natl-1.json";
                }
                g.hits.busy += 1;
                break :blk null;
            };
            const json: std.http.Header = .{ .name = "content-type", .value = "application/json" };
            if (file) |name| {
                const body = try Io.Dir.cwd().readFileAlloc(g.io, try std.fs.path.join(g.arena, &.{ g.dir, name }), std.heap.page_allocator, .limited(1 << 20));
                defer std.heap.page_allocator.free(body);
                try request.respond(body, .{ .extra_headers = &.{json} });
            } else if (paged) {
                try request.respond("{\"feed\":[]}", .{ .extra_headers = &.{json} });
            } else {
                try request.respond("busy", .{ .status = .service_unavailable });
            }
        }
    }
};
