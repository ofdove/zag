const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Library module
    const zag_mod = b.addModule("zag", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Echo server example
    const echo = b.addExecutable(.{
        .name = "echo_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/echo_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag", .module = zag_mod },
            },
        }),
    });
    b.installArtifact(echo);

    const run_echo = b.addRunArtifact(echo);
    run_echo.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_echo.addArgs(args);

    const run_step = b.step("run-echo", "Run the echo server example");
    run_step.dependOn(&run_echo.step);

    // HTTP server example
    const http = b.addExecutable(.{
        .name = "http_server",
        .root_module = b.createModule(.{
            .root_source_file = b.path("examples/http_server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zag", .module = zag_mod },
            },
        }),
    });
    b.installArtifact(http);

    const run_http = b.addRunArtifact(http);
    run_http.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_http.addArgs(args);

    const run_http_step = b.step("run-http", "Run the HTTP server example");
    run_http_step.dependOn(&run_http.step);

    // Tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lib.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}
