const std = @import("std");
const zeldi_build = @import("zeldi");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // the host the cells run on, always as prod builds it, so the e2e times
    // what serves the feeds.
    const zeldi = b.dependency("zeldi", .{ .target = target, .optimize = .ReleaseSafe });
    b.installArtifact(zeldi.artifact("zeldi"));

    const spongebob = zeldi_build.addCell(b, zeldi, "spongebob", b.path("cells/main.zig"));
    const front = zeldi_build.addCell(b, zeldi, "feeds-front", b.path("cells/front.zig"));
    const cells_step = b.step("cells", "build the cells");
    for ([_]struct { []const u8, std.Build.LazyPath }{ .{ "spongebob", spongebob }, .{ "feeds-front", front } }) |cell| {
        const install = b.addInstallFileWithDir(cell[1], .{ .custom = "cells" }, b.fmt("{s}.wasm", .{cell[0]}));
        cells_step.dependOn(&install.step);
        b.getInstallStep().dependOn(&install.step);
    }

    const test_step = b.step("test", "run the unit tests and the e2e test");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("cells/tests.zig"),
        .target = target,
        .optimize = optimize,
    }) })).step);

    const e2e = b.addExecutable(.{ .name = "feeds-e2e", .root_module = b.createModule(.{
        .root_source_file = b.path("test/e2e.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "harness", .module = b.createModule(.{ .root_source_file = b.path("test/harness.zig") }) }},
    }) });
    const run_e2e = b.addRunArtifact(e2e);
    run_e2e.addArtifactArg(zeldi.artifact("zeldi"));
    run_e2e.addFileArg(spongebob);
    run_e2e.addFileArg(b.path("testdata/jetstream.ndjson"));
    run_e2e.addFileArg(front);
    test_step.dependOn(&run_e2e.step);
    b.step("e2e", "boot zeldi with the feeds on the jetstream fixture").dependOn(&run_e2e.step);
}
