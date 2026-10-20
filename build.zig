const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);

    const exe = b.addExecutable(.{
        .name = "platform-profile-daemon",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = strip,
            .unwind_tables = if (optimize == .debug) null else .none,
            .omit_frame_pointer = optimize != .debug,
            .error_tracing = optimize == .debug,
        }),
    });
    exe.lto = if (optimize == .debug) .none else .full;
    addSystemdShim(b, exe.root_module);

    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .lib },
    }).step);
    b.installFile("data/platform-profile-daemon.service", "lib/systemd/system/platform-profile-daemon.service");
    const initializer = b.addExecutable(.{
        .name = "platform-profile-daemon-init",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/init.zig"),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = strip,
            .unwind_tables = if (optimize == .debug) null else .none,
            .omit_frame_pointer = optimize != .debug,
            .error_tracing = optimize == .debug,
            .link_libc = true,
        }),
    });
    initializer.lto = if (optimize == .debug) .none else .full;
    b.getInstallStep().dependOn(&b.addInstallArtifact(initializer, .{
        .dest_dir = .{ .override = .lib },
    }).step);
    b.installFile("data/platform-profile-daemon-init.service", "lib/systemd/system/platform-profile-daemon-init.service");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.service", "share/dbus-1/system-services/org.freedesktop.UPower.PowerProfiles.service");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.conf", "share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.policy", "share/polkit-1/actions/org.freedesktop.UPower.PowerProfiles.policy");

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    addSystemdShim(b, tests.root_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
    const init_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/init.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    }) });
    test_step.dependOn(&b.addRunArtifact(init_tests).step);
}

fn addSystemdShim(b: *std.Build, module: *std.Build.Module) void {
    module.addCSourceFile(.{
        .file = b.path("src/dbus_shim.c"),
        .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-DVERSION=\"" ++ zon.version ++ "\"" },
    });
    module.linkSystemLibrary("libsystemd", .{ .use_pkg_config = .force });
    module.linkSystemLibrary("c", .{});
}
