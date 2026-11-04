const std = @import("std");
const zon = @import("build.zig.zon");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // Binaries default to ReleaseSmall, which is what the package ships. An explicit
    // -Doptimize applies to both binaries and tests; without it the tests stay in
    // Debug so their overflow and bounds checks still run.
    const requested = b.option(std.lang.Optimize, "optimize", "Prioritize performance, safety, or binary size (default: small; tests: debug)");
    const optimize = requested orelse .small;
    const test_optimize = requested orelse .debug;
    const strip = b.option(bool, "strip", "Strip debug symbols") orelse (optimize != .debug);

    const exe = addRuntime(b, "platform-profile-daemon", "src/main.zig", target, optimize, strip);
    addBuildOptions(b, exe.root_module);
    b.getInstallStep().dependOn(&b.addInstallArtifact(exe, .{
        .dest_dir = .{ .override = .lib },
    }).step);
    b.installFile("data/platform-profile-daemon.service", "lib/systemd/system/platform-profile-daemon.service");

    const initializer = addRuntime(b, "platform-profile-daemon-init", "src/init.zig", target, optimize, strip);
    b.getInstallStep().dependOn(&b.addInstallArtifact(initializer, .{
        .dest_dir = .{ .override = .lib },
    }).step);
    b.installFile("data/platform-profile-daemon-init.service", "lib/systemd/system/platform-profile-daemon-init.service");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.service", "share/dbus-1/system-services/org.freedesktop.UPower.PowerProfiles.service");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.conf", "share/dbus-1/system.d/org.freedesktop.UPower.PowerProfiles.conf");
    b.installFile("data/org.freedesktop.UPower.PowerProfiles.policy", "share/polkit-1/actions/org.freedesktop.UPower.PowerProfiles.policy");

    // Coverage-guided fuzzing (`zig build test --fuzz -Dllvm=true`) needs the
    // LLVM backend; the default Debug backend has no coverage instrumentation.
    const use_llvm = b.option(bool, "llvm", "Build tests with the LLVM backend (required for --fuzz)");
    const tests = b.addTest(.{
        .use_llvm = use_llvm,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = test_optimize,
        }),
    });
    addBuildOptions(b, tests.root_module);

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Check formatting and run tests");
    test_step.dependOn(&b.addFmt(.{
        .paths = b.pathList(&.{ "src", "build.zig", "build.zig.zon" }),
        .check = true,
    }).step);
    test_step.dependOn(&run_tests.step);
    const init_tests = b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("src/init.zig"),
        .target = target,
        .optimize = test_optimize,
    }) });
    test_step.dependOn(&b.addRunArtifact(init_tests).step);
}

/// Both executables are libc-free: raw Linux syscalls, a tiny panic/log
/// runtime (`src/rt.zig`), and a static non-PIE ELF with unused sections
/// garbage-collected.
fn addRuntime(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    strip: bool,
) *std.Build.Step.Compile {
    const release = optimize != .debug;
    const exe = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .single_threaded = true,
            .strip = strip,
            .unwind_tables = if (release) .none else null,
            .omit_frame_pointer = release,
            .error_tracing = !release,
        }),
    });
    exe.lto = if (release) .full else .none;
    if (release) {
        exe.pie = false;
        exe.link_function_sections = true;
        exe.link_data_sections = true;
        exe.link_gc_sections = true;
    }
    return exe;
}

fn addBuildOptions(b: *std.Build, module: *std.Build.Module) void {
    const options = b.addOptions();
    options.addOption([]const u8, "version", zon.version);
    module.addOptions("build_options", options);
}
