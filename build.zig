const std = @import("std");

// Creamery — wasm32-freestanding core.
// Contract: build with `zig build` -> zig-out/bin/creamery.wasm
// The game logic lives here; the JS shell is loader/DOM bridge only.
// `zig build test` runs the native test suite (validation + adversarial).
pub fn build(b: *std.Build) void {
    const target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
    const exe = b.addExecutable(.{
        .name = "creamery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = .ReleaseSmall,
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;
    exe.export_memory = true;
    b.installArtifact(exe);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = b.standardTargetOptions(.{}),
            .optimize = .Debug,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run the core test suite");
    test_step.dependOn(&run_tests.step);
}
