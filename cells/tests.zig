const std = @import("std");
const filter = @import("filter.zig");
const feed = @import("feed.zig");
const index = @import("index.zig");

test "filter agrees with bsky-feed's python filter" {
    const gpa = std.testing.allocator;
    const parsed = try std.json.parseFromSlice([]const struct { []const u8, bool }, gpa, @embedFile("testdata/filter_verdicts.json"), .{});
    defer parsed.deinit();
    var failures: usize = 0;
    for (parsed.value) |case| {
        const got = try filter.matches(gpa, case[0]);
        if (got != case[1]) {
            std.debug.print("mismatch: {f} python={} zig={}\n", .{ std.json.fmt(case[0], .{}), case[1], got });
            failures += 1;
        }
    }
    try std.testing.expectEqual(0, failures);
}

test "strip urls removes each alternative to the end of its token" {
    var buf: [128]u8 = undefined;
    try std.testing.expectEqualStrings("see  now", filter.stripUrls("see https://a.b/c now", &buf));
    try std.testing.expectEqualStrings("x", filter.stripUrls("xhttp://y", &buf));
    try std.testing.expectEqualStrings(" tail", filter.stripUrls("x.yz/q tail", &buf));
    try std.testing.expectEqualStrings("a.b/q", filter.stripUrls("a.b/q", &buf));
}

test "cursor round trip" {
    var buf: [64]u8 = undefined;
    const s = try feed.formatCursor(&buf, .{ .indexed_at_ms = 1730000000123, .cid = "bafyabc" });
    try std.testing.expectEqualStrings("1730000000123::bafyabc", s);
    const c = (try feed.parseCursor(s)).at;
    try std.testing.expectEqual(1730000000123, c.indexed_at_ms);
    try std.testing.expectEqualStrings("bafyabc", c.cid);
}

test "cursor edge cases" {
    try std.testing.expectEqual(.start, try feed.parseCursor(null));
    try std.testing.expectEqual(.eof, try feed.parseCursor("eof"));
    try std.testing.expectError(error.MalformedCursor, feed.parseCursor("123"));
    try std.testing.expectError(error.MalformedCursor, feed.parseCursor("abc::cid"));
    try std.testing.expectError(error.MalformedCursor, feed.parseCursor("1::2::3"));
}

test "limit defaults and clamps" {
    try std.testing.expectEqual(20, feed.parseLimit(null));
    try std.testing.expectEqual(20, feed.parseLimit("lots"));
    try std.testing.expectEqual(1, feed.parseLimit("0"));
    try std.testing.expectEqual(100, feed.parseLimit("5000"));
    try std.testing.expectEqual(7, feed.parseLimit("7"));
}

test "directory links each feed to bluesky and escapes what it prints" {
    var page: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer page.deinit();
    try index.write(&page.writer, "a<b", &.{ "at://did:plc:xbtmt2zjwlrfegqvch7fboei/app.bsky.feed.generator/n8", "not-an-at-uri" });
    const html = page.written();
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"https://bsky.app/profile/did:plc:xbtmt2zjwlrfegqvch7fboei/feed/n8\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "<h1>a&lt;b</h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "not-an-at-uri") == null);
}

test "AtUri.parse wants exactly did, collection, rkey" {
    const at = index.AtUri.parse("at://did:web:x.test/app.bsky.feed.generator/abc").?;
    try std.testing.expectEqualStrings("did:web:x.test", at.did);
    try std.testing.expectEqualStrings("abc", at.rkey);
    try std.testing.expectEqual(null, index.AtUri.parse("at://did:plc:x/app.bsky.feed.generator"));
    try std.testing.expectEqual(null, index.AtUri.parse("at://did:plc:x/a/b/c"));
    try std.testing.expectEqual(null, index.AtUri.parse("https://x/a/b"));
}
