//! a mirror cell's store layout, apart from the cell so the one-off import
//! can write it.

const std = @import("std");

/// the store holds `n`, the next id; `i/<id>` for each post, holding
/// `<first_seen_ms> <uri>`; and `u/<uri>` holding its id. ids grow with
/// first_seen, so newest first is a reverse scan of `i/`, and expired posts
/// are the first of a forward one.
pub const next_key = "n";
pub const items_start = "i/";
pub const items_end = "i0";

pub fn itemKey(buf: []u8, id: u64) ![]const u8 {
    return std.fmt.bufPrint(buf, "i/{d:0>20}", .{id});
}

pub fn uriKey(buf: []u8, uri: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "u/{s}", .{uri});
}

pub fn itemValue(buf: []u8, first_seen_ms: i64, uri: []const u8) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d} {s}", .{ first_seen_ms, uri });
}

pub const Item = struct { first_seen_ms: i64, uri: []const u8 };

pub fn parseItem(value: []const u8) error{MalformedItem}!Item {
    const space = std.mem.indexOfScalar(u8, value, ' ') orelse return error.MalformedItem;
    return .{ .first_seen_ms = std.fmt.parseInt(i64, value[0..space], 10) catch return error.MalformedItem, .uri = value[space + 1 ..] };
}
