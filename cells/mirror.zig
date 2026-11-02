//! a feed that mirrors another generator's skeleton: polls its
//! getFeedSkeleton with http_get, keeps each post with when it was first seen,
//! and serves them newest first. one cell per mirrored feed.

const std = @import("std");
const zeldi = @import("zeldi");
const feed = @import("feed.zig");
const items = @import("items.zig");

const Config = struct {
    /// the at-uri this cell answers for.
    feed: []const u8,
    /// the at-uri of the feed being mirrored.
    source: []const u8,
    /// the source generator's service, e.g. https://api.example.com.
    endpoint: []const u8,
    poll_ms: i64 = 60_000,
    /// how long a post stays after it was first seen.
    keep_ms: i64 = 48 * std.time.ms_per_hour,
    page_limit: u32 = 100,
};

/// the longest wait between polls while the source keeps failing.
const max_backoff_ms = 10 * std.time.ms_per_min;

var config_arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
var config: Config = undefined;
/// polls in a row that failed, for backoff.
var failures: u6 = 0;


export fn on_start(ptr: u32, len: u32) i32 {
    start(zeldi.input(ptr, len)) catch |err| {
        zeldi.logf("start failed: {t}", .{err});
        return -1;
    };
    return 0;
}

fn start(raw_config: []const u8) !void {
    config = try std.json.parseFromSliceLeaky(Config, config_arena_state.allocator(), raw_config, .{ .allocate = .alloc_always });
    if (config.poll_ms <= 0) return error.BadPollInterval;
    // cells built from one config would otherwise all poll at the same moment.
    const offset: i64 = @intCast(std.hash.Wyhash.hash(0, config.feed) % @as(u64, @intCast(config.poll_ms)));
    zeldi.setAlarm(zeldi.now() + offset);
}

export fn on_alarm() i32 {
    zeldi.resetArena();
    if (poll()) {
        failures = 0;
    } else |err| {
        failures +|= 1;
        zeldi.logf("poll failed ({d} in a row): {t}", .{ failures, err });
    }
    zeldi.setAlarm(zeldi.now() + nextDelay(config.poll_ms, failures));
    return 0;
}

pub fn nextDelay(poll_ms: i64, fails: u6) i64 {
    if (fails == 0) return poll_ms;
    const shift: u6 = @min(fails, 20);
    return @min(poll_ms << shift, @max(poll_ms, max_backoff_ms));
}

const Page = struct {
    cursor: ?[]const u8 = null,
    feed: []const struct { post: []const u8 },
};

/// page 1 every time; page 2 only when nothing on page 1 was seen before,
/// which means the source moved more than a page since the last poll.
fn poll() !void {
    const first = try fetchPage(null);
    var posts: std.ArrayList([]const u8) = .empty;
    for (first.feed) |item| try posts.append(zeldi.arena, item.post);
    if (first.cursor) |cursor| if (first.feed.len > 0 and try noneSeen(posts.items)) {
        const second = try fetchPage(cursor);
        for (second.feed) |item| try posts.append(zeldi.arena, item.post);
    };

    const now = zeldi.now();
    var next: u64 = if (try zeldi.get(items.next_key)) |v| std.fmt.parseInt(u64, v, 10) catch return error.CorruptStore else 1;
    // the source lists newest first; inserting oldest first gives newer posts
    // the higher ids, which is the order the cell serves.
    var i = posts.items.len;
    while (i > 0) {
        i -= 1;
        const uri = posts.items[i];
        const uri_key = try items.uriKey(try zeldi.arena.alloc(u8, uri.len + 2), uri);
        if (try zeldi.get(uri_key) != null) continue;
        try zeldi.put(try items.itemKey(try zeldi.arena.alloc(u8, 22), next), try items.itemValue(try zeldi.arena.alloc(u8, uri.len + 21), now, uri));
        try zeldi.put(uri_key, try std.fmt.allocPrint(zeldi.arena, "{d}", .{next}));
        next += 1;
    }
    try zeldi.put(items.next_key, try std.fmt.allocPrint(zeldi.arena, "{d}", .{next}));
    try expire(now - config.keep_ms);
}

/// deletes the posts first seen before `cutoff`, oldest first.
fn expire(cutoff: i64) !void {
    while (true) {
        const page = try zeldi.scan(.{ .start = items.items_start, .end = items.items_end, .limit = 100 });
        for (page.entries) |e| {
            const item = items.parseItem(e.value) catch return error.CorruptStore;
            if (item.first_seen_ms >= cutoff) return;
            try zeldi.del(e.key);
            try zeldi.del(try items.uriKey(try zeldi.arena.alloc(u8, item.uri.len + 2), item.uri));
        }
        if (!page.more) return;
    }
}

fn noneSeen(uris: []const []const u8) !bool {
    for (uris) |uri| {
        if (try zeldi.get(try items.uriKey(try zeldi.arena.alloc(u8, uri.len + 2), uri)) != null) return false;
    }
    return true;
}

fn fetchPage(cursor: ?[]const u8) !Page {
    var url: std.Io.Writer.Allocating = .init(zeldi.arena);
    const w = &url.writer;
    try w.print("{s}/xrpc/app.bsky.feed.getFeedSkeleton?feed=", .{config.endpoint});
    try percentEncode(w, config.source);
    try w.print("&limit={d}", .{config.page_limit});
    if (cursor) |c| {
        try w.writeAll("&cursor=");
        try percentEncode(w, c);
    }
    const res = try zeldi.httpGet(url.written());
    if (res.status != 200) {
        zeldi.logf("source answered {d}", .{res.status});
        return error.SourceStatus;
    }
    return std.json.parseFromSliceLeaky(Page, zeldi.arena, res.body, .{ .ignore_unknown_fields = true });
}

fn percentEncode(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~') {
            try w.writeByte(c);
        } else try w.print("%{X:0>2}", .{c});
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
    if (!std.mem.eql(u8, req.path, "/xrpc/app.bsky.feed.getFeedSkeleton")) return zeldi.respond(404, "text/plain", "not found\n");
    const uri = req.param("feed") orelse return zeldi.respond(400, "text/plain", "Feed parameter missing");
    if (!std.mem.eql(u8, uri, config.feed)) return zeldi.respond(400, "text/plain", "Unsupported algorithm");
    return skeleton(req);
}

const SkeletonPost = struct { post: []const u8 };
const Skeleton = struct { cursor: []const u8, feed: []const SkeletonPost };

/// newest first; the cursor is the id of the last post on the page.
fn skeleton(req: zeldi.Request) !u64 {
    const limit = feed.parseLimit(req.param("limit"));
    const end = switch (try parseCursor(req.param("cursor"))) {
        .eof => return zeldi.respondJson(200, Skeleton{ .cursor = feed.eof, .feed = &.{} }),
        .start => items.items_end,
        .before => |id| try items.itemKey(try zeldi.arena.alloc(u8, 22), @intCast(@max(id, 0))),
    };
    const page = try zeldi.scan(.{ .start = items.items_start, .end = end, .limit = limit, .reverse = true });
    const posts = try zeldi.arena.alloc(SkeletonPost, page.entries.len);
    for (page.entries, posts) |e, *p| p.* = .{ .post = (items.parseItem(e.value) catch return error.CorruptStore).uri };
    const cursor = if (page.entries.len > 0)
        try std.fmt.allocPrint(zeldi.arena, "{d}", .{std.fmt.parseInt(u64, page.entries[page.entries.len - 1].key[2..], 10) catch return error.CorruptStore})
    else
        feed.eof;
    return zeldi.respondJson(200, Skeleton{ .cursor = cursor, .feed = posts });
}

pub const Cursor = union(enum) { start, eof, before: i64 };

pub fn parseCursor(raw: ?[]const u8) error{MalformedCursor}!Cursor {
    const s = raw orelse return .start;
    if (s.len == 0) return .start;
    if (std.mem.eql(u8, s, feed.eof)) return .eof;
    return .{ .before = std.fmt.parseInt(i64, s, 10) catch return error.MalformedCursor };
}
