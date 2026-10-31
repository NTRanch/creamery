const std = @import("std");

// Creamery — wasm32-freestanding core.
// Contract: build with `zig build` -> zig-out/bin/creamery.wasm
// The game logic lives here; the JS shell is loader/DOM bridge only.
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
    b.installArtifact(exe);
}
