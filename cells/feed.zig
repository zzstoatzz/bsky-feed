//! feed paging, matching bsky-feed's algos/feed.py: newest first, cursor is
//! "<indexed_at_ms>::<cid>", and "eof" once the feed is exhausted.

const std = @import("std");

pub const eof = "eof";
pub const default_limit = 20;
pub const max_limit = 100;

pub const Cursor = struct {
    indexed_at_ms: i64,
    cid: []const u8,
};

pub const ParsedCursor = union(enum) {
    start,
    eof,
    at: Cursor,
};

pub fn parseCursor(raw: ?[]const u8) error{MalformedCursor}!ParsedCursor {
    const s = raw orelse return .start;
    if (s.len == 0) return .start;
    if (std.mem.eql(u8, s, eof)) return .eof;
    const sep = std.mem.indexOf(u8, s, "::") orelse return error.MalformedCursor;
    const cid = s[sep + 2 ..];
    if (std.mem.indexOf(u8, cid, "::") != null) return error.MalformedCursor;
    const ms = std.fmt.parseInt(i64, s[0..sep], 10) catch return error.MalformedCursor;
    return .{ .at = .{ .indexed_at_ms = ms, .cid = cid } };
}

pub fn formatCursor(buf: []u8, c: Cursor) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}::{s}", .{ c.indexed_at_ms, c.cid });
}

/// flask's type=int falls back to the default on a bad value; bsky caps limit at 100.
pub fn parseLimit(raw: ?[]const u8) u32 {
    const s = raw orelse return default_limit;
    const n = std.fmt.parseInt(i64, s, 10) catch return default_limit;
    return @intCast(std.math.clamp(n, 1, max_limit));
}

/// a post's key in the store: newest first is a reverse scan of `posts`.
pub fn postKey(buf: []u8, indexed_at_ms: i64, cid: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "t/{d:0>20}/{s}", .{ @as(u64, @intCast(indexed_at_ms)), cid });
}

/// keys of the form `postKey` writes all fall in `[posts_start, posts_end)`.
pub const posts_start = "t/";
pub const posts_end = "t0";

/// maps a post's uri to its key, so a delete can find it.
pub fn uriKey(buf: []u8, uri: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "u/{s}", .{uri});
}

pub fn cursorKey(buf: []u8, service: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "c/{s}", .{service});
}

/// the time and cid a post key holds.
pub fn parsePostKey(key: []const u8) error{MalformedKey}!Cursor {
    if (key.len < 23 or !std.mem.startsWith(u8, key, posts_start) or key[22] != '/') return error.MalformedKey;
    const ms = std.fmt.parseInt(i64, key[2..22], 10) catch return error.MalformedKey;
    return .{ .indexed_at_ms = ms, .cid = key[23..] };
}
