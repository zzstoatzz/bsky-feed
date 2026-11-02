//! the parts of a feed generator that do not depend on which posts it serves:
//! the directory page, the did document, and describeFeedGenerator. the
//! spongebob cell and the front cell answer them the same way.

const std = @import("std");
const zeldi = @import("zeldi");
const index = @import("index.zig");

pub fn directory(hostname: []const u8, feeds: []const []const u8) !u64 {
    var page: std.Io.Writer.Allocating = .init(zeldi.arena);
    try index.write(&page.writer, hostname, feeds);
    return zeldi.respond(200, "text/html; charset=utf-8", page.written());
}

/// served only when the service did is this host's did:web.
pub fn didDocument(hostname: []const u8, service_did: []const u8) !u64 {
    const did_web = try std.fmt.allocPrint(zeldi.arena, "did:web:{s}", .{hostname});
    if (!std.mem.eql(u8, service_did, did_web)) return zeldi.respond(404, "text/plain", "");
    return zeldi.respondJson(200, .{
        .@"@context" = .{"https://www.w3.org/ns/did/v1"},
        .id = service_did,
        .service = .{.{
            .id = "#bsky_fg",
            .type = "BskyFeedGenerator",
            .serviceEndpoint = try std.fmt.allocPrint(zeldi.arena, "https://{s}", .{hostname}),
        }},
    });
}

pub fn describe(service_did: []const u8, feeds: []const []const u8) !u64 {
    const Uri = struct { uri: []const u8 };
    const uris = try zeldi.arena.alloc(Uri, feeds.len);
    for (feeds, uris) |f, *u| u.* = .{ .uri = f };
    return zeldi.respondJson(200, .{ .did = service_did, .feeds = uris });
}
