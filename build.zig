//! Use `zig init --strip` next time to generate a project without comments.
const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    const exe = b.addExecutable(.{ .name = "zig_updater", .root_source_file = b.path("src/main.zig"), .target = b.graph.host });

    b.installArtifact(exe);

    const run_exe = b.addRunArtifact(exe);

    const run_step = b.step("run", "Run the application");

    run_step.dependOn(&run_exe.step);
}
