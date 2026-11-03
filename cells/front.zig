//! the front cell for a feed host: answers the directory page, the did
//! document, and describeFeedGenerator for every feed on the host, and hands
//! each getFeedSkeleton to the cell that serves that feed.

const std = @import("std");
const zeldi = @import("zeldi");
const generator = @import("generator.zig");

const Config = struct {
    hostname: []const u8,
    /// defaults to did:web:<hostname>.
    service_did: ?[]const u8 = null,
    /// in the order the directory and describeFeedGenerator list them.
    feeds: []const struct { uri: []const u8, cell: []const u8 },
};

var config_arena_state: std.heap.ArenaAllocator = .init(std.heap.wasm_allocator);
var config: Config = undefined;
var service_did: []const u8 = undefined;
var uris: []const []const u8 = undefined;

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
    service_did = config.service_did orelse try std.fmt.allocPrint(persistent, "did:web:{s}", .{config.hostname});
    const list = try persistent.alloc([]const u8, config.feeds.len);
    for (config.feeds, list) |f, *u| u.* = f.uri;
    uris = list;
}

export fn on_fetch(ptr: u32, len: u32) u64 {
    return route(zeldi.Request.parse(zeldi.input(ptr, len))) catch zeldi.respond(500, "text/plain", "internal error");
}

fn route(req: zeldi.Request) !u64 {
    const path = req.path;
    if (std.mem.eql(u8, path, "/")) return generator.directory(config.hostname, uris);
    if (std.mem.eql(u8, path, "/.well-known/did.json")) return generator.didDocument(config.hostname, service_did);
    if (std.mem.eql(u8, path, "/xrpc/app.bsky.feed.describeFeedGenerator")) return generator.describe(service_did, uris);
    if (std.mem.eql(u8, path, "/xrpc/app.bsky.feed.getFeedSkeleton")) {
        const uri = req.param("feed") orelse return zeldi.respond(400, "text/plain", "Feed parameter missing");
        for (config.feeds) |f| {
            if (!std.mem.eql(u8, f.uri, uri)) continue;
            const url = try std.fmt.allocPrint(zeldi.arena, "cell://{s}{s}", .{ f.cell, req.target });
            const res = zeldi.fetch(.{ .url = url }) catch {
                zeldi.logf("{s} did not answer for {s}", .{ f.cell, f.uri });
                return zeldi.respond(502, "text/plain", "feed unavailable");
            };
            return zeldi.respond(res.status, res.header("content-type") orelse "application/json", res.body);
        }
        return zeldi.respond(400, "text/plain", "Unsupported algorithm");
    }
    return zeldi.respond(404, "text/plain", "not found\n");
}
