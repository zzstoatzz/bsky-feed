//! one-off: moves the feeds' SQLite databases into the zkv stores zeldi abi 2
//! gives each cell. for every `<cell>.sqlite` in the tenant directory it
//! writes the cell's rows into `cells/<cell>/` with the layout the cell reads,
//! checks the store holds as many entries as the database, and renames the
//! database to `<cell>.sqlite.migrated`. writes are idempotent, so a run cut
//! short is simply run again.
//!
//! usage: import <tenant dir>

const std = @import("std");
const Io = std.Io;
const zkv = @import("zkv");
const c = @import("sqlite");
const feed = @import("feed");
const mirror = @import("items");

const Db = zkv.Db(zkv.DirStore);

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 2) return error.Usage;
    var tenant = try Io.Dir.cwd().openDir(io, args[1], .{ .iterate = true });
    defer tenant.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = tenant.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".sqlite")) continue;
        try names.append(init.arena.allocator(), try init.arena.allocator().dupe(u8, entry.name));
    }
    for (names.items) |name| try importOne(gpa, io, init.arena.allocator(), tenant, args[1], name);
}

fn importOne(gpa: std.mem.Allocator, io: Io, arena: std.mem.Allocator, tenant: Io.Dir, tenant_path: []const u8, file: []const u8) !void {
    const cell = file[0 .. file.len - ".sqlite".len];
    const path = try std.fmt.allocPrintSentinel(arena, "{s}/{s}", .{ tenant_path, file }, 0);
    var sql: ?*c.sqlite3 = null;
    if (c.sqlite3_open_v2(path.ptr, &sql, c.SQLITE_OPEN_READONLY, null) != c.SQLITE_OK) return error.OpenSqlite;
    defer _ = c.sqlite3_close(sql);

    const dir = try tenant.createDirPathOpen(io, try std.fmt.allocPrint(arena, "cells/{s}", .{cell}), .{});
    defer dir.close(io);
    var store = zkv.DirStore.init(gpa, io, dir);
    const db = try Db.open(gpa, &store, .{ .table_bytes = 2 * 1024 * 1024 });
    defer db.close();

    const rows, const entries = if (has(sql, "post"))
        try importPosts(db, sql)
    else if (has(sql, "item"))
        try importItems(db, sql)
    else
        .{ 0, 0 };
    try db.commit();
    try db.flush();
    while (try db.compact()) {}
    try db.collect();

    const stored = try count(db);
    std.debug.print("{s}: {d} rows, {d} entries written, {d} in the store\n", .{ cell, rows, entries, stored });
    if (stored != entries) return error.CountMismatch;
    try tenant.rename(file, tenant, try std.fmt.allocPrint(arena, "{s}.migrated", .{file}), io);
    for ([_][]const u8{ "-wal", "-shm" }) |suffix| {
        const side = try std.fmt.allocPrint(arena, "{s}{s}", .{ file, suffix });
        tenant.rename(side, tenant, try std.fmt.allocPrint(arena, "{s}.migrated", .{side}), io) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return err,
        };
    }
}

fn has(sql: ?*c.sqlite3, table: [:0]const u8) bool {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sql, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?1", -1, &stmt, null) != c.SQLITE_OK) return false;
    defer _ = c.sqlite3_finalize(stmt);
    _ = c.sqlite3_bind_text(stmt, 1, table.ptr, -1, null);
    return c.sqlite3_step(stmt) == c.SQLITE_ROW;
}

fn text(stmt: ?*c.sqlite3_stmt, col: c_int) []const u8 {
    const p = c.sqlite3_column_text(stmt, col) orelse return "";
    return p[0..@intCast(c.sqlite3_column_bytes(stmt, col))];
}

/// spongebob: a post under its time and cid, its uri pointing back, and the
/// jetstream cursor.
fn importPosts(db: *Db, sql: ?*c.sqlite3) !struct { usize, usize } {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sql, "SELECT uri, cid, indexed_at FROM post", -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
    defer _ = c.sqlite3_finalize(stmt);
    var rows: usize = 0;
    var post_buf: [512]u8 = undefined;
    var uri_buf: [512]u8 = undefined;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const uri = text(stmt, 0);
        const post_key = try feed.postKey(&post_buf, c.sqlite3_column_int64(stmt, 2), text(stmt, 1));
        try db.put(post_key, uri);
        try db.put(try feed.uriKey(&uri_buf, uri), post_key);
        rows += 1;
        if (rows % 1000 == 0) try db.commit();
    }
    var entries = rows * 2;
    var cursor: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sql, "SELECT cursor FROM subscription_state WHERE service = 'jetstream'", -1, &cursor, null) == c.SQLITE_OK) {
        defer _ = c.sqlite3_finalize(cursor);
        if (c.sqlite3_step(cursor) == c.SQLITE_ROW) {
            var key_buf: [64]u8 = undefined;
            var value_buf: [32]u8 = undefined;
            try db.put(try feed.cursorKey(&key_buf, "jetstream"), try std.fmt.bufPrint(&value_buf, "{d}", .{c.sqlite3_column_int64(cursor, 0)}));
            entries += 1;
        }
    }
    return .{ rows, entries };
}

/// a mirror: each item under its id, its uri pointing back, and the next id.
fn importItems(db: *Db, sql: ?*c.sqlite3) !struct { usize, usize } {
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(sql, "SELECT id, uri, first_seen_ms FROM item", -1, &stmt, null) != c.SQLITE_OK) return error.Prepare;
    defer _ = c.sqlite3_finalize(stmt);
    var rows: usize = 0;
    var next: u64 = 1;
    var item_buf: [32]u8 = undefined;
    var uri_buf: [512]u8 = undefined;
    var value_buf: [512]u8 = undefined;
    var id_buf: [32]u8 = undefined;
    while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
        const id: u64 = @intCast(c.sqlite3_column_int64(stmt, 0));
        const uri = text(stmt, 1);
        try db.put(try mirror.itemKey(&item_buf, id), try mirror.itemValue(&value_buf, c.sqlite3_column_int64(stmt, 2), uri));
        try db.put(try mirror.uriKey(&uri_buf, uri), try std.fmt.bufPrint(&id_buf, "{d}", .{id}));
        next = @max(next, id + 1);
        rows += 1;
        if (rows % 1000 == 0) try db.commit();
    }
    try db.put(mirror.next_key, try std.fmt.bufPrint(&id_buf, "{d}", .{next}));
    return .{ rows, rows * 2 + 1 };
}

fn count(db: *Db) !usize {
    var it = try db.scan(.{});
    defer it.deinit();
    var n: usize = 0;
    while (it.next()) |_| n += 1;
    return n;
}
