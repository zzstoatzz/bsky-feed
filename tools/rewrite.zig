//! one-off: rewrites the cells' kv stores from zkv's first table format,
//! where each table was read whole, into the one it reads by range. for each
//! store still in the old format under `cells/`, it copies every entry into a
//! new store beside it, checks the counts match, and swaps the directories,
//! leaving the old one at `cells/<cell>.v1`. a run cut short starts that cell
//! over.
//!
//! usage: rewrite <tenant dir>

const std = @import("std");
const Io = std.Io;
const old = @import("zkv_v1");
const new = @import("zkv");

const old_manifest_magic: u32 = 0x7a6b766d;

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const arena = init.arena.allocator();
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2) return error.Usage;
    var tenant = try Io.Dir.cwd().openDir(io, args[1], .{});
    defer tenant.close(io);
    var cells = tenant.openDir(io, "cells", .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer cells.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var unfinished: std.ArrayList([]const u8) = .empty;
    var it = cells.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.endsWith(u8, entry.name, ".new")) {
            try unfinished.append(arena, try arena.dupe(u8, entry.name[0 .. entry.name.len - 4]));
        } else if (std.mem.indexOfScalar(u8, entry.name, '.') == null) {
            try names.append(arena, try arena.dupe(u8, entry.name));
        }
    }
    for (unfinished.items) |name| {
        if (contains(names.items, name)) continue;
        try cells.rename(try std.fmt.allocPrint(arena, "{s}.new", .{name}), cells, name, io);
        std.debug.print("{s}: finished a swap a crash cut short\n", .{name});
    }
    for (names.items) |name| {
        if (!try copy(gpa, io, arena, cells, name)) continue;
        try cells.rename(name, cells, try std.fmt.allocPrint(arena, "{s}.v1", .{name}), io);
        try cells.rename(try std.fmt.allocPrint(arena, "{s}.new", .{name}), cells, name, io);
    }
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// copies an old-format store into `<name>.new`; false when the store is
/// already in the new format.
fn copy(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, cells: Io.Dir, name: []const u8) !bool {
    var src = try cells.openDir(io, name, .{});
    defer src.close(io);
    const manifest = src.openFile(io, "manifest", .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    var head: [4]u8 = undefined;
    const read = manifest.readPositionalAll(io, &head, 0);
    manifest.close(io);
    if (try read < 4 or std.mem.readInt(u32, head[0..4], .little) != old_manifest_magic) return false;

    const fresh = try std.fmt.allocPrint(arena, "{s}.new", .{name});
    try cells.deleteTree(io, fresh);
    var dst = try cells.createDirPathOpen(io, fresh, .{});
    defer dst.close(io);

    var old_store = old.DirStore.init(gpa, io, src);
    const from = try old.Db(old.DirStore).open(gpa, &old_store, .{});
    defer from.close();
    var new_store = new.DirStore.init(gpa, io, dst);
    const to = try new.Db(new.DirStore).open(gpa, &new_store, .{ .table_bytes = 2 * 1024 * 1024 });
    defer to.close();

    var copied: usize = 0;
    var entries = try from.scan(.{});
    defer entries.deinit();
    while (entries.next()) |e| {
        try to.put(e.key, e.value);
        copied += 1;
        if (copied % 1000 == 0) try to.commit();
    }
    try to.commit();
    try to.flush();
    while (try to.compact()) {}
    try to.collect();

    var stored: usize = 0;
    var check = try to.scan(.{});
    defer check.deinit();
    while (try check.next()) |_| stored += 1;
    std.debug.print("{s}: {d} entries copied, {d} in the new store\n", .{ name, copied, stored });
    if (stored != copied) return error.CountMismatch;
    return true;
}
