const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const sysfs = @import("sysfs.zig");
const c = @cImport({
    @cInclude("dirent.h");
    @cInclude("sys/inotify.h");
});

pub const std_options: std.Options = .{ .signal_stack_size = null };

pub fn main() void {
    initialize("/sys/firmware/acpi/platform_profile", "/sys/devices/system/cpu/cpufreq") catch {
        std.process.exit(1);
    };
}

fn initialize(profilePath: [:0]const u8, cpuPath: [:0]const u8) !void {
    const saved = try readInitial(profilePath);
    const root = try openAt(std.c.AT.FDCWD, cpuPath, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, cpuPath);
    const directory = c.fdopendir(root) orelse {
        const err = failure(cpuPath, error.EnumerateFailed, std.c.errno(-1));
        _ = std.c.close(root);
        return err;
    };
    defer _ = c.closedir(directory);

    // Process borrowed names immediately, opening relative to the pinned root.
    // A disappearing or symlinked policy remains an error.
    var foundPolicy = false;
    while (true) {
        std.c._errno().* = 0;
        const entry = c.readdir(directory);
        if (entry == null) {
            const errno = std.c.errno(-1);
            if (errno == .INTR) continue;
            if (errno != .SUCCESS) return failure(cpuPath, error.EnumerateFailed, errno);
            break;
        }
        const name = std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.*.d_name)), 0);
        if (!isPolicyName(name)) continue;
        foundPolicy = true;
        var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrintZ(&pathBuf, "{s}/{s}/energy_performance_preference", .{ cpuPath, name }) catch |err| {
            return failure(cpuPath, err, .SUCCESS);
        };
        const policyFd = try openAt(root, name, .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true, .NOFOLLOW = true }, path);
        defer _ = std.c.close(policyFd);
        const fd = try openAt(policyFd, "energy_performance_preference", .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true, .NOFOLLOW = true }, path);
        defer _ = std.c.close(fd);
        try write(fd, "dynamic\n", path);
    }
    if (!foundPolicy) return failure(cpuPath, error.NoPolicies, .SUCCESS);

    // Enabling Dynamic EPP may temporarily produce custom. Reapply the snapshot
    // without reading that transient state or verifying the synchronous write.
    const fd = try openAt(std.c.AT.FDCWD, profilePath, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, profilePath);
    defer _ = std.c.close(fd);
    try write(fd, saved.writeBytes(), profilePath);
}

fn readInitial(path: [:0]const u8) !profile.KernelProfile {
    const fd = try openAt(std.c.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, path);
    defer _ = std.c.close(fd);
    var buf: [64]u8 = undefined;
    const n = sysfs.readProfileBytes(fd, &buf) catch |err| return failure(path, err, std.c.errno(-1));
    // Sysfs adds one newline. No whitespace normalization or custom fallback.
    const text = if (n > 0 and buf[n - 1] == '\n') buf[0 .. n - 1] else buf[0..n];
    return profile.KernelProfile.parse(text) orelse failure(path, error.UnknownKernelProfile, .SUCCESS);
}

fn isPolicyName(name: []const u8) bool {
    if (!std.mem.startsWith(u8, name, "policy") or name.len == "policy".len) return false;
    for (name["policy".len..]) |byte| if (!std.ascii.isDigit(byte)) return false;
    return true;
}

fn openAt(dir: std.c.fd_t, name: [:0]const u8, flags: std.c.O, path: []const u8) !std.c.fd_t {
    while (true) {
        const fd = std.c.openat(dir, name, flags);
        if (fd >= 0) return fd;
        const errno = std.c.errno(-1);
        if (errno == .INTR) continue;
        return failure(path, error.OpenFailed, errno);
    }
}

fn write(fd: std.c.fd_t, bytes: []const u8, path: []const u8) !void {
    std.c._errno().* = 0;
    sysfs.writeAll(fd, bytes) catch |err| return failure(path, err, std.c.errno(-1));
}

fn failure(path: []const u8, err: anyerror, errno: std.c.E) anyerror {
    if (!builtin.is_test) std.log.err("{s}: {s} (errno {d}: {t})", .{ path, @errorName(err), @intFromEnum(errno), errno });
    return err;
}

fn testPath(dir: std.Io.Dir, name: []const u8, buf: []u8) ![:0]const u8 {
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &root);
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ root[0..n], name });
}

fn seedPolicy(dir: std.Io.Dir, name: []const u8) !void {
    try dir.createDirPath(std.testing.io, name);
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "{s}/energy_performance_preference", .{name});
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
        var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
        try initialize(try testPath(tmp.dir, "profile", &profileBuf), try testPath(tmp.dir, ".", &cpuBuf));
        for ([_][]const u8{ "policy0", "policy2", "policy10" }) |name| {
            var path: [128]u8 = undefined;
            try expectFile(tmp.dir, try std.fmt.bufPrint(&path, "{s}/energy_performance_preference", .{name}), "dynamic\n");
        }
        var expected: [32]u8 = undefined;
        try expectFile(tmp.dir, "profile", try std.fmt.bufPrint(&expected, "{s}\n", .{initial}));
    }
}

test "unsupported initial profiles fail before any writes" {
    for ([_][]const u8{ "custom\n", "quiet\n", "cool\n", "balanced-performance\n", "unknown\n", "", " balanced\n", "balanced\n\n", "balanced\x00" }) |initial| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = initial });
        try seedPolicy(tmp.dir, "policy0");
        var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.UnknownKernelProfile, initialize(try testPath(tmp.dir, "profile", &profileBuf), try testPath(tmp.dir, ".", &cpuBuf)));
        try expectFile(tmp.dir, "profile", initial);
        try expectFile(tmp.dir, "policy0/energy_performance_preference", "default\n");
    }
}

test "missing profile or no policies fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
    var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
    const profilePath = try testPath(tmp.dir, "profile", &profileBuf);
    const cpuPath = try testPath(tmp.dir, ".", &cpuBuf);
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
        const failedPath = try std.fmt.bufPrint(&failedBuf, "{s}/energy_performance_preference", .{failed});
        try tmp.dir.deleteFile(std.testing.io, failedPath);
        var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.OpenFailed, initialize(try testPath(tmp.dir, "profile", &profileBuf), try testPath(tmp.dir, ".", &cpuBuf)));
        for (policies) |name| {
            if (std.mem.eql(u8, name, failed)) continue;
            var pathBuf: [128]u8 = undefined;
            const path = try std.fmt.bufPrint(&pathBuf, "{s}/energy_performance_preference", .{name});
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
        const fd = std.c.memfd_create("init-test", std.c.MFD.CLOEXEC | std.c.MFD.ALLOW_SEALING);
        try std.testing.expect(fd >= 0);
        defer _ = std.c.close(fd);
        try sysfs.writeAll(fd, "low-power\n");
        const seals = std.c.F.SEAL_WRITE | (if (failOpen) @as(c_int, std.c.F.SEAL_SHRINK | std.c.F.SEAL_GROW) else 0);
        try std.testing.expect(std.c.fcntl(fd, std.c.F.ADD_SEALS, @as(c_int, seals)) >= 0);
        var profileBuf: [128]u8 = undefined;
        const profilePath = try std.fmt.bufPrintZ(&profileBuf, "/proc/self/fd/{d}", .{fd});
        var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectError(if (failOpen) error.OpenFailed else error.PermissionDenied, initialize(profilePath, try testPath(tmp.dir, ".", &cpuBuf)));
        try expectFile(tmp.dir, "policy0/energy_performance_preference", "dynamic\n");
    }
}

test "symlinked policies and EPP attributes fail without following them" {
    for ([_]bool{ false, true }) |attribute| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "balanced" });
        try seedPolicy(tmp.dir, "target");
        var linkBuf: [std.fs.max_path_bytes]u8 = undefined;
        if (attribute) {
            try tmp.dir.createDirPath(std.testing.io, "policy0");
            const link = try testPath(tmp.dir, "policy0/energy_performance_preference", &linkBuf);
            try std.testing.expect(std.c.symlink("../target/energy_performance_preference", link) == 0);
        } else {
            const link = try testPath(tmp.dir, "policy0", &linkBuf);
            try std.testing.expect(std.c.symlink("target", link) == 0);
        }
        var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
        var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
        try std.testing.expectError(error.OpenFailed, initialize(try testPath(tmp.dir, "profile", &profileBuf), try testPath(tmp.dir, ".", &cpuBuf)));
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
    const fd = c.inotify_init1(c.IN_NONBLOCK | c.IN_CLOEXEC);
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var pathBuf: [std.fs.max_path_bytes]u8 = undefined;
    var watches: [3]c_int = undefined;
    for ([_][]const u8{ "profile", "policy0/energy_performance_preference", "policy1/energy_performance_preference" }, 0..) |path, i| {
        watches[i] = c.inotify_add_watch(fd, try testPath(tmp.dir, path, &pathBuf), c.IN_ACCESS | c.IN_CLOSE_WRITE);
        try std.testing.expect(watches[i] >= 0);
    }
    var profileBuf: [std.fs.max_path_bytes]u8 = undefined;
    var cpuBuf: [std.fs.max_path_bytes]u8 = undefined;
    try initialize(try testPath(tmp.dir, "profile", &profileBuf), try testPath(tmp.dir, ".", &cpuBuf));
    var events: [4096]u8 align(@alignOf(c.struct_inotify_event)) = undefined;
    const n = std.c.read(fd, &events, events.len);
    try std.testing.expect(n > 0);
    var offset: usize = 0;
    var reads: usize = 0;
    var writes: usize = 0;
    var written = [_]bool{false} ** 3;
    while (offset < @as(usize, @intCast(n))) {
        const event: *const c.struct_inotify_event = @ptrCast(@alignCast(&events[offset]));
        if (event.mask & c.IN_ACCESS != 0) {
            try std.testing.expectEqual(watches[0], event.wd);
            try std.testing.expectEqual(@as(usize, 0), writes);
            reads += 1;
        }
        if (event.mask & c.IN_CLOSE_WRITE != 0) {
            const index = std.mem.indexOfScalar(c_int, &watches, event.wd) orelse return error.UnexpectedWatch;
            try std.testing.expect(!written[index]);
            if (index == 0) try std.testing.expectEqual(@as(usize, 2), writes);
            written[index] = true;
            writes += 1;
        }
        offset += @sizeOf(c.struct_inotify_event) + event.len;
    }
    try std.testing.expectEqual(@as(usize, 1), reads);
    try std.testing.expectEqual(@as(usize, 3), writes);
}
