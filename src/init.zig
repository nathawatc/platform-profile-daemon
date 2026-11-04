const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const rt = @import("rt.zig");
const sys = @import("sys.zig");
const testutil = @import("testutil.zig");

const linux = std.os.linux;

pub const std_options = rt.std_options;
// No std debug I/O: keeps the Io.Threaded singleton and Io.File.Writer out of the binary.
// A null here turns any accidental use of std.debug I/O into a compile error.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const panic = std.debug.FullPanic(rt.panicFn);

/// Returns the exit status directly so std.start never prints error traces.
pub fn main() u8 {
    initialize("/sys/firmware/acpi/platform_profile", "/sys/devices/system/cpu/cpufreq") catch return 1;
    return 0;
}

fn initialize(profilePath: [:0]const u8, cpuPath: [:0]const u8) !void {
    const saved = try readInitial(profilePath);
    const root = try openAt(linux.AT.FDCWD, cpuPath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, cpuPath);
    defer sys.close(root);

    // Process borrowed names immediately, opening relative to the pinned root.
    // A disappearing or symlinked policy remains an error.
    var foundPolicy = false;
    var dents: [4096]u8 align(@alignOf(linux.dirent64)) = undefined;
    while (true) {
        const rc = linux.getdents64(root, &dents, dents.len);
        const err = linux.errno(rc);
        if (err == .INTR) continue;
        if (err != .SUCCESS) return failure(cpuPath, error.EnumerateFailed, err);
        if (rc == 0) break;

        var offset: usize = 0;
        while (offset < rc) {
            const entry: *const linux.dirent64 = @ptrCast(@alignCast(&dents[offset]));
            offset += entry.reclen;
            const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
            if (!isPolicyName(name)) continue;
            foundPolicy = true;
            var pathBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const path = std.mem.printSentinel(&pathBuf, "{s}/{s}/energy_performance_preference", .{ cpuPath, name }, 0) catch |e| {
                return failure(cpuPath, e, .SUCCESS);
            };
            const policyFd = try openAt(root, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, path);
            defer sys.close(policyFd);
            const fd = try openAt(policyFd, "energy_performance_preference", .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, path);
            defer sys.close(fd);
            try write(fd, "dynamic\n", path);
        }
    }
    if (!foundPolicy) return failure(cpuPath, error.NoPolicies, .SUCCESS);

    // Enabling Dynamic EPP may temporarily produce custom. Reapply the snapshot
    // without reading that transient state or verifying the synchronous write.
    const fd = try openAt(linux.AT.FDCWD, profilePath, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, profilePath);
    defer sys.close(fd);
    try write(fd, saved.kernelLine(), profilePath);
}

fn readInitial(path: [:0]const u8) !profile.Profile {
    const fd = try openAt(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, path);
    defer sys.close(fd);
    var buf: [64]u8 = undefined;
    var errno: linux.E = .SUCCESS;
    const n = sys.readAll(fd, &buf, &errno) catch return failure(path, ioError(errno, error.ReadFailed), errno);
    // Strict: one optional trailing newline, no custom fallback.
    return profile.Profile.parseKernel(buf[0..n]) catch failure(path, error.UnknownKernelProfile, .SUCCESS);
}

fn isPolicyName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "policy") or name.len == "policy".len) return false;
    for (name["policy".len..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn openAt(dir: linux.fd_t, name: [:0]const u8, flags: linux.O, path: []const u8) !linux.fd_t {
    var errno: linux.E = .SUCCESS;
    return sys.open(dir, name.ptr, flags, &errno) catch failure(path, error.OpenFailed, errno);
}

fn write(fd: linux.fd_t, bytes: []const u8, path: []const u8) !void {
    var errno: linux.E = .SUCCESS;
    sys.writeAll(fd, bytes, &errno) catch return failure(path, ioError(errno, error.WriteFailed), errno);
}

fn ioError(errno: linux.E, comptime fallback: anyerror) anyerror {
    return switch (errno) {
        .ACCES, .PERM => error.PermissionDenied,
        else => fallback,
    };
}

fn failure(path: []const u8, err: anyerror, errno: linux.E) anyerror {
    if (!builtin.is_test) std.log.err("{s}: {s} (errno {d}: {t})", .{ path, @errorName(err), @backingInt(errno), errno });
    return err;
}

fn seedPolicy(dir: std.Io.Dir, name: []const u8) !void {
    try dir.createDirPath(std.testing.io, name);
    var buf: [128]u8 = undefined;
    const path = try std.mem.print(&buf, "{s}/energy_performance_preference", .{name});
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "default\n" });
}

fn expectFile(dir: std.Io.Dir, name: []const u8, contents: []const u8) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(contents, try dir.readFile(std.testing.io, name, &buf));
}

test "initial supported profiles enable every policy and reapply saved profile" {
    for ([_][]const u8{ "low-power", "balanced", "performance" }) |initial| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        // No newline initially: the final newline proves reapplication occurred.
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = initial });
        try seedPolicy(tmp.dir, "policy0");
        try seedPolicy(tmp.dir, "policy2");
        try seedPolicy(tmp.dir, "policy10");
        try tmp.dir.createDirPath(std.testing.io, "policy-other");
        var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try initialize(try testutil.tmpPath(tmp.dir, "profile", &profileBuf), try testutil.tmpPath(tmp.dir, ".", &cpuBuf));
        for ([_][]const u8{ "policy0", "policy2", "policy10" }) |name| {
            var path: [128]u8 = undefined;
            try expectFile(tmp.dir, try std.mem.print(&path, "{s}/energy_performance_preference", .{name}), "dynamic\n");
        }
        var expected: [32]u8 = undefined;
        try expectFile(tmp.dir, "profile", try std.mem.print(&expected, "{s}\n", .{initial}));
    }
}

test "unsupported initial profiles fail before any writes" {
    for ([_][]const u8{ "custom\n", "quiet\n", "cool\n", "balanced-performance\n", "unknown\n", "", " balanced\n", "balanced\n\n", "balanced\x00" }) |initial| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = initial });
        try seedPolicy(tmp.dir, "policy0");
        var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.UnknownKernelProfile, initialize(try testutil.tmpPath(tmp.dir, "profile", &profileBuf), try testutil.tmpPath(tmp.dir, ".", &cpuBuf)));
        try expectFile(tmp.dir, "profile", initial);
        try expectFile(tmp.dir, "policy0/energy_performance_preference", "default\n");
    }
}

test "missing profile or no policies fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const profilePath = try testutil.tmpPath(tmp.dir, "profile", &profileBuf);
    const cpuPath = try testutil.tmpPath(tmp.dir, ".", &cpuBuf);
    try std.testing.expectError(error.OpenFailed, initialize(profilePath, cpuPath));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "low-power" });
    try tmp.dir.createDirPath(std.testing.io, "policy-other");
    try std.testing.expectError(error.NoPolicies, initialize(profilePath, cpuPath));
    try expectFile(tmp.dir, "profile", "low-power");
}

test "failed policy stops initialization with no rollback or reapplication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const policies = [_][]const u8{ "policy0", "policy1", "policy2" };
    for (policies) |name| try seedPolicy(tmp.dir, name);
    var sawPartial = false;
    // Fail each policy in turn without changing the root directory entries.
    // Whatever the enumeration order, at least one run fails after a success.
    for (policies) |failed| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "performance" });
        for (policies) |name| try seedPolicy(tmp.dir, name);
        var failedBuf: [128]u8 = undefined;
        const failedPath = try std.mem.print(&failedBuf, "{s}/energy_performance_preference", .{failed});
        try tmp.dir.deleteFile(std.testing.io, failedPath);
        var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.OpenFailed, initialize(try testutil.tmpPath(tmp.dir, "profile", &profileBuf), try testutil.tmpPath(tmp.dir, ".", &cpuBuf)));
        for (policies) |name| {
            if (std.mem.eql(u8, name, failed)) continue;
            var pathBuf: [128]u8 = undefined;
            const path = try std.mem.print(&pathBuf, "{s}/energy_performance_preference", .{name});
            var contents: [32]u8 = undefined;
            const value = try tmp.dir.readFile(std.testing.io, path, &contents);
            if (std.mem.eql(u8, value, "dynamic\n")) {
                sawPartial = true;
            } else {
                try std.testing.expectEqualStrings("default\n", value);
            }
        }
        try expectFile(tmp.dir, "profile", "performance");
    }
    try std.testing.expect(sawPartial);
}

test "reapply failure leaves initialized policies and fails" {
    for ([_]bool{ false, true }) |failOpen| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try seedPolicy(tmp.dir, "policy0");
        const fd = try testutil.memfd("init-test");
        defer sys.close(fd);
        var errno: linux.E = .SUCCESS;
        try sys.writeAll(fd, "low-power\n", &errno);
        const seals: usize = linux.F.SEAL_WRITE | (if (failOpen) @as(usize, linux.F.SEAL_SHRINK | linux.F.SEAL_GROW) else 0);
        try std.testing.expect(testutil.addSeals(fd, seals));
        var profileBuf: [128]u8 = undefined;
        const profilePath = try std.mem.printSentinel(&profileBuf, "/proc/self/fd/{d}", .{fd}, 0);
        var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expectError(if (failOpen) error.OpenFailed else error.PermissionDenied, initialize(profilePath, try testutil.tmpPath(tmp.dir, ".", &cpuBuf)));
        try expectFile(tmp.dir, "policy0/energy_performance_preference", "dynamic\n");
    }
}

test "symlinked policies and EPP attributes fail without following them" {
    for ([_]bool{ false, true }) |attribute| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "balanced" });
        try seedPolicy(tmp.dir, "target");
        var linkBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        if (attribute) {
            try tmp.dir.createDirPath(std.testing.io, "policy0");
            const link = try testutil.tmpPath(tmp.dir, "policy0/energy_performance_preference", &linkBuf);
            try std.testing.expect(linux.errno(linux.symlink("../target/energy_performance_preference", link.ptr)) == .SUCCESS);
        } else {
            const link = try testutil.tmpPath(tmp.dir, "policy0", &linkBuf);
            try std.testing.expect(linux.errno(linux.symlink("target", link.ptr)) == .SUCCESS);
        }
        var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.OpenFailed, initialize(try testutil.tmpPath(tmp.dir, "profile", &profileBuf), try testutil.tmpPath(tmp.dir, ".", &cpuBuf)));
        try expectFile(tmp.dir, "target/energy_performance_preference", "default\n");
        try expectFile(tmp.dir, "profile", "balanced");
    }
}

test "initialization I/O reads profile once then writes policies before profile without probes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "low-power\n" });
    try seedPolicy(tmp.dir, "policy0");
    try seedPolicy(tmp.dir, "policy1");
    const inotify_rc = linux.inotify_init1(linux.IN.NONBLOCK | linux.IN.CLOEXEC);
    try std.testing.expect(linux.errno(inotify_rc) == .SUCCESS);
    const fd: linux.fd_t = @intCast(inotify_rc);
    defer sys.close(fd);
    var pathBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var watches: [3]c_int = undefined;
    for ([_][]const u8{ "profile", "policy0/energy_performance_preference", "policy1/energy_performance_preference" }, 0..) |path, i| {
        const watch_rc = linux.inotify_add_watch(fd, (try testutil.tmpPath(tmp.dir, path, &pathBuf)).ptr, linux.IN.ACCESS | linux.IN.CLOSE_WRITE);
        try std.testing.expect(linux.errno(watch_rc) == .SUCCESS);
        watches[i] = @intCast(watch_rc);
    }
    var profileBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var cpuBuf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try initialize(try testutil.tmpPath(tmp.dir, "profile", &profileBuf), try testutil.tmpPath(tmp.dir, ".", &cpuBuf));
    var events: [4096]u8 align(@alignOf(linux.inotify_event)) = undefined;
    const n = linux.read(fd, &events, events.len);
    try std.testing.expect(linux.errno(n) == .SUCCESS and n > 0);
    var offset: usize = 0;
    var reads: usize = 0;
    var writes: usize = 0;
    var written: [3]bool = @splat(false);
    while (offset < n) {
        const event: *const linux.inotify_event = @ptrCast(@alignCast(&events[offset]));
        if (event.mask & linux.IN.ACCESS != 0) {
            try std.testing.expectEqual(watches[0], event.wd);
            try std.testing.expectEqual(@as(usize, 0), writes);
            reads += 1;
        }
        if (event.mask & linux.IN.CLOSE_WRITE != 0) {
            const index = std.mem.findScalar(c_int, &watches, event.wd) orelse return error.UnexpectedWatch;
            try std.testing.expect(!written[index]);
            if (index == 0) try std.testing.expectEqual(@as(usize, 2), writes);
            written[index] = true;
            writes += 1;
        }
        offset += @sizeOf(linux.inotify_event) + event.len;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 3), writes);
}
