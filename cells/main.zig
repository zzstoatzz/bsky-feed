//! the spongebob feed as a zeldi cell: keeps alternating-case posts from
//! jetstream and serves them through getFeedSkeleton, along with the rest of a
//! feed generator: its did document, describeFeedGenerator, and a directory
//! page at `/`.

const std = @import("std");
const zeldi = @import("zeldi");
const filter = @import("filter.zig");
const feed = @import("feed.zig");
const generator = @import("generator.zig");

const post_collection = "app.bsky.feed.post";
const cursor_key = "jetstream";

/// the cell's json from zeldi.json.
const Config = struct {
    hostname: []const u8,
    /// defaults to did:web:<hostname>.
    service_did: ?[]const u8 = null,
    /// at-uris of the feed records this cell answers for.
    feeds: []const []const u8,
    /// tried in order; a connection that never got past the cursor moves to the next.
    jetstreams: []const []const u8 = &.{
        "jetstream1.us-east.bsky.network",
        "jetstream2.us-east.bsky.network",
        "jetstream1.us-west.bsky.network",
        "jetstream2.us-west.bsky.network",
    },
};

/// outlives every call, unlike zeldi.arena.
var config_arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
var config: Config = undefined;
var service_did: []const u8 = undefined;

/// the largest time_us the cell has committed; events at or before it are
/// already in the database.
var committed: ?i64 = null;

const StrongRef = struct { uri: []const u8 };

const Event = struct {
    did: []const u8,
    time_us: i64,
    kind: []const u8,
    commit: ?struct {
        operation: []const u8,
        collection: []const u8,
        rkey: []const u8,
        cid: ?[]const u8 = null,
        record: ?struct {
            text: []const u8 = "",
            reply: ?struct { root: StrongRef, parent: StrongRef } = null,
        } = null,
    } = null,
};

export fn on_start(ptr: u32, len: u32) i32 {
    start(zeldi.input(ptr, len)) catch |err| {
        zeldi.logf("start failed: {t}", .{err});
        return -1;
    };
    return 0;
}

fn start(raw_config: []const u8) !void {
    const persistent = config_arena_state.allocator();
    config = try std.json.parseFromSliceLeaky(Config, persistent, raw_config, .{ .allocate = .alloc_always });
    if (config.jetstreams.len == 0) return error.NoJetstreams;
    service_did = config.service_did orelse try std.fmt.allocPrint(persistent, "did:web:{s}", .{config.hostname});

    try zeldi.exec(feed.schema, .{});
    const rows = try zeldi.query("SELECT cursor FROM subscription_state WHERE service = ?1", .{cursor_key});
    committed = if (rows.len > 0 and rows[0][0] == .integer) rows[0][0].integer else null;
    try zeldi.subscribe(.{ .url = try jetstreamUrl(config.jetstreams[0], committed) });
    zeldi.logf("subscribed to {s} from cursor {?d}", .{ post_collection, committed });
}

fn jetstreamUrl(host: []const u8, cursor: ?i64) ![]const u8 {
    const base = "wss://{s}/subscribe?wantedCollections=" ++ post_collection;
    if (cursor) |c| return std.fmt.allocPrint(zeldi.arena, base ++ "&cursor={d}", .{ host, c });
    return std.fmt.allocPrint(zeldi.arena, base, .{host});
}

var jetstream_index: usize = 0;
var cursor_at_last_connect: ?i64 = null;
var connects: usize = 0;

/// a connection that committed nothing was a bad host, so try the next one,
/// rewound ten seconds since instances lag each other. one that made progress
/// sends the cell back to the first host.
export fn on_connect() u64 {
    zeldi.resetArena();
    var cursor = committed;
    if (connects > 0) {
        if (committed != null and committed != cursor_at_last_connect) {
            jetstream_index = 0;
        } else {
            jetstream_index = (jetstream_index + 1) % config.jetstreams.len;
            if (cursor) |c| cursor = c - 10_000_000;
        }
    }
    connects += 1;
    cursor_at_last_connect = committed;
    const url = jetstreamUrl(config.jetstreams[jetstream_index], cursor) catch return 0;
    zeldi.logf("connecting to {s}", .{url});
    return zeldi.output(url);
}

/// state of the batch window being ingested. a window arrives as one or more
/// chunks and commits as one transaction when the last chunk lands.
const Window = struct {
    open: bool = false,
    failed: bool = false,
    indexed_at: i64 = 0,
    cursor: ?i64 = null,
    added: usize = 0,
    deleted: usize = 0,
};

var window: Window = .{};

export fn on_events(ptr: u32, len: u32, flags: u32) i32 {
    const first = flags & zeldi.events_first != 0;
    const last = flags & zeldi.events_last != 0;
    if (first) {
        if (window.open) zeldi.exec("ROLLBACK", .{}) catch {};
        window = .{};
    }
    if (window.failed) return -1;
    ingest(zeldi.input(ptr, len), first, last) catch |err| {
        if (window.open) zeldi.exec("ROLLBACK", .{}) catch {};
        window.open = false;
        window.failed = true;
        zeldi.logf("batch failed: {t}", .{err});
        return -1;
    };
    return 0;
}

fn ingest(chunk: []const u8, first: bool, last: bool) !void {
    if (first) {
        try zeldi.exec("BEGIN", .{});
        window.open = true;
        window.indexed_at = zeldi.now();
    }
    if (!window.open) return error.NoOpenWindow;

    var line_arena: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
    defer line_arena.deinit();
    var lines = std.mem.splitScalar(u8, chunk, '\n');
    while (lines.next()) |line| {
        _ = line_arena.reset(.retain_capacity);
        if (line.len == 0) continue;
        try ingestLine(line_arena.allocator(), line);
    }

    if (!last) return;
    if (window.cursor) |c| try zeldi.exec(
        "INSERT INTO subscription_state (service, cursor) VALUES (?1, ?2) ON CONFLICT (service) DO UPDATE SET cursor = excluded.cursor",
        .{ cursor_key, c },
    );
    try zeldi.exec("COMMIT", .{});
    window.open = false;
    if (window.cursor) |c| committed = c;
    if (window.added > 0) zeldi.logf("batch: {d} matched, {d} deletes, cursor {?d}", .{ window.added, window.deleted, window.cursor });
}

fn ingestLine(scratch: std.mem.Allocator, line: []const u8) !void {
    const ev = std.json.parseFromSliceLeaky(Event, scratch, line, .{ .ignore_unknown_fields = true }) catch return;
    if (committed) |c| if (ev.time_us <= c) return;
    window.cursor = @max(window.cursor orelse ev.time_us, ev.time_us);
    const commit = ev.commit orelse return;
    if (!std.mem.eql(u8, ev.kind, "commit") or !std.mem.eql(u8, commit.collection, post_collection)) return;
    const uri = try std.fmt.allocPrint(scratch, "at://{s}/{s}/{s}", .{ ev.did, commit.collection, commit.rkey });

    if (std.mem.eql(u8, commit.operation, "create")) {
        const record = commit.record orelse return;
        const cid = commit.cid orelse return;
        if (!try filter.matches(scratch, record.text)) return;
        const reply = record.reply;
        try zeldi.exec(
            "INSERT OR IGNORE INTO post (uri, cid, reply_parent, reply_root, indexed_at) VALUES (?1, ?2, ?3, ?4, ?5)",
            .{ uri, cid, if (reply) |r| r.parent.uri else null, if (reply) |r| r.root.uri else null, window.indexed_at },
        );
        window.added += 1;
    } else if (std.mem.eql(u8, commit.operation, "delete")) {
        try zeldi.exec("DELETE FROM post WHERE uri = ?1", .{uri});
        window.deleted += 1;
    }
}

export fn on_fetch(ptr: u32, len: u32) u64 {
    const req = zeldi.Request.parse(zeldi.input(ptr, len));
    return route(req) catch |err| switch (err) {
        error.MalformedCursor => zeldi.respond(400, "text/plain", "Malformed cursor"),
        else => zeldi.respond(500, "text/plain", "internal error"),
    };
}

fn route(req: zeldi.Request) !u64 {
    const path = req.path;
    if (std.mem.eql(u8, path, "/")) return generator.directory(config.hostname, config.feeds);
    if (std.mem.eql(u8, path, "/.well-known/did.json")) return generator.didDocument(config.hostname, service_did);
    if (std.mem.eql(u8, path, "/xrpc/app.bsky.feed.describeFeedGenerator")) return generator.describe(service_did, config.feeds);
    if (std.mem.eql(u8, path, "/xrpc/app.bsky.feed.getFeedSkeleton")) {
        const uri = req.param("feed") orelse return zeldi.respond(400, "text/plain", "Feed parameter missing");
        for (config.feeds) |f| {
            if (std.mem.eql(u8, f, uri)) return skeleton(req);
        }
        return zeldi.respond(400, "text/plain", "Unsupported algorithm");
    }
    return zeldi.respond(404, "text/plain", "not found\n");
}

const SkeletonPost = struct { post: []const u8 };
const Skeleton = struct { cursor: []const u8, feed: []const SkeletonPost };

fn skeleton(req: zeldi.Request) !u64 {
    const limit = feed.parseLimit(req.param("limit"));
    const rows = switch (try feed.parseCursor(req.param("cursor"))) {
        .eof => return zeldi.respondJson(200, Skeleton{ .cursor = feed.eof, .feed = &.{} }),
        .start => try zeldi.query(feed.page_first, .{limit}),
        .at => |c| try zeldi.query(feed.page_after, .{ c.indexed_at_ms, c.cid, limit }),
    };

    const posts = try zeldi.arena.alloc(SkeletonPost, rows.len);
    for (rows, posts) |row, *p| p.* = .{ .post = row[0].string };
    var cursor: []const u8 = feed.eof;
    if (rows.len > 0) {
        const last = rows[rows.len - 1];
        const buf = try zeldi.arena.alloc(u8, 32 + last[1].string.len);
        cursor = try feed.formatCursor(buf, .{ .indexed_at_ms = last[2].integer, .cid = last[1].string });
    }
    return zeldi.respondJson(200, Skeleton{ .cursor = cursor, .feed = posts });
}

export fn on_alarm() i32 {
    zeldi.resetArena();
    return 0;
}
