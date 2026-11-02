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

pub const schema =
    \\CREATE TABLE IF NOT EXISTS post (
    \\  id INTEGER PRIMARY KEY,
    \\  uri TEXT NOT NULL,
    \\  cid TEXT NOT NULL,
    \\  reply_parent TEXT,
    \\  reply_root TEXT,
    \\  indexed_at INTEGER NOT NULL
    \\);
    \\CREATE UNIQUE INDEX IF NOT EXISTS post_uri ON post (uri);
    \\CREATE INDEX IF NOT EXISTS post_page ON post (indexed_at DESC, cid DESC);
    \\CREATE TABLE IF NOT EXISTS subscription_state (
    \\  service TEXT PRIMARY KEY,
    \\  cursor INTEGER NOT NULL
    \\);
;

pub const page_first =
    \\SELECT uri, cid, indexed_at FROM post
    \\ORDER BY indexed_at DESC, cid DESC LIMIT ?1
;

pub const page_after =
    \\SELECT uri, cid, indexed_at FROM post
    \\WHERE (indexed_at = ?1 AND cid < ?2) OR indexed_at < ?1
    \\ORDER BY indexed_at DESC, cid DESC LIMIT ?3
;
