//! Cached `ActiveProfile` state and the rules for changing it.
//!
//! The cache is updated only from a valid read of `platform_profile` or after a
//! successful write. Custom, unknown, empty or malformed content never replaces
//! it, and nothing falls back to a default.
const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const sysfs_mod = @import("sysfs.zig");
const testutil = @import("testutil.zig");

/// Consecutive failed watch reads tolerated before the daemon gives up.
const max_read_failures = 3;

pub const Daemon = struct {
    sysfs: sysfs_mod.Sysfs,
    active: profile.Profile,
    /// Consecutive failed reads of the watch fd; reset by any successful read.
    read_failures: u8 = 0,

    /// Opens `platform_profile` and primes the cache. Startup `custom`,
    /// unknown or unreadable content is an error: nothing is chosen for it.
    pub fn init(path: [:0]const u8) sysfs_mod.Error!Daemon {
        const sysfs = try sysfs_mod.Sysfs.open(path);
        errdefer sysfs.close();
        return .{ .sysfs = sysfs, .active = try sysfs.read() };
    }

    pub fn deinit(self: Daemon) void {
        self.sysfs.close();
    }

    /// Applies an explicit request. The kernel is read fresh and written
    /// unless it already holds `requested`, so a request still reaches the
    /// kernel when its state is custom, unreadable or inconsistent with the
    /// cache; only the write decides the outcome.
    /// Callers detect a visible change by comparing `active` before and after,
    /// including when this fails after refreshing the cache.
    pub fn setActiveProfile(self: *Daemon, requested: profile.Profile) sysfs_mod.IoError!void {
        if (self.sysfs.readFresh()) |current| {
            self.active = current;
            if (current == requested) return;
        } else |err| switch (err) {
            error.Custom, error.Unknown => {},
            else => |io| if (!builtin.is_test) std.log.warn("could not read platform_profile before writing: {t}", .{io}),
        }
        try self.sysfs.write(requested);
        self.active = requested;
    }

    /// Handles a `platform_profile` change event. Returns whether the cached
    /// profile changed. Unusable content keeps the cache. A failed read is
    /// retried on the next wake (the kernel keeps the event pending); the
    /// `max_read_failures`th consecutive failure means the watch is lost and
    /// is returned so the daemon exits and systemd restarts it.
    pub fn checkExternalUpdate(self: *Daemon) sysfs_mod.IoError!bool {
        const current = self.sysfs.read() catch |err| switch (err) {
            error.Custom => return self.ignore("ignoring custom platform_profile; keeping cached ActiveProfile"),
            error.Unknown => return self.ignore("ignoring invalid platform_profile refresh event"),
            else => |io| {
                self.read_failures += 1;
                if (self.read_failures >= max_read_failures) return io;
                if (!builtin.is_test) std.log.warn("platform_profile read failed ({t}); will retry", .{io});
                return false;
            },
        };
        self.read_failures = 0;
        if (current == self.active) return false;
        self.active = current;
        return true;
    }

    /// The read succeeded but the content is unusable.
    fn ignore(self: *Daemon, comptime message: []const u8) bool {
        self.read_failures = 0;
        if (!builtin.is_test) std.log.warn(message, .{});
        return false;
    }
};

const max_path = std.Io.Dir.max_path_bytes;

/// A temp `platform_profile` holding `contents`, with a daemon opened on it
/// when `contents` is a valid profile.
fn tempFile(tmp: *std.testing.TmpDir, buf: []u8, contents: []const u8) ![:0]const u8 {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = contents });
    return testutil.tmpPath(tmp.dir, "p", buf);
}

fn expectFile(tmp: *std.testing.TmpDir, expected: []const u8) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try tmp.dir.readFile(std.testing.io, "p", &buf));
}

test "init primes the cache and rejects unusable startup content" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;

    const daemon = try Daemon.init(try tempFile(&tmp, &buf, "performance\n"));
    defer daemon.deinit();
    try std.testing.expectEqual(profile.Profile.performance, daemon.active);

    try std.testing.expectError(error.Custom, Daemon.init(try tempFile(&tmp, &buf, "custom\n")));
    try std.testing.expectError(error.Unknown, Daemon.init(try tempFile(&tmp, &buf, "quiet\n")));
    try std.testing.expectError(error.Unknown, Daemon.init(try tempFile(&tmp, &buf, "")));
    try std.testing.expectError(error.Unknown, Daemon.init(try tempFile(&tmp, &buf, "balanced \n")));
    try expectFile(&tmp, "balanced \n");
    try std.testing.expectError(error.UnsupportedPlatform, Daemon.init("/nonexistent/platform_profile"));
}

test "requesting the current profile skips the write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    // No trailing newline: a write would add one.
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "balanced"));
    defer daemon.deinit();

    try daemon.setActiveProfile(.balanced);
    try expectFile(&tmp, "balanced");
    try std.testing.expectEqual(profile.Profile.balanced, daemon.active);
}

test "stale cache does not skip the write" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer daemon.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "performance\n" });

    try daemon.setActiveProfile(.balanced);
    try expectFile(&tmp, "balanced\n");
    try std.testing.expectEqual(profile.Profile.balanced, daemon.active);
}

test "request matching the kernel but not the cache moves the cache without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer daemon.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "performance" });

    const before = daemon.active;
    try daemon.setActiveProfile(.performance);
    // The visible value changed, so the caller must signal it.
    try std.testing.expect(daemon.active != before);
    try expectFile(&tmp, "performance");
}

test "custom or unknown kernel state still accepts an explicit request" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "performance\n"));
    defer daemon.deinit();

    for ([_][]const u8{ "custom\n", "quiet\n" }) |state| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = state });
        // Same as the cache, yet the kernel must still converge.
        try daemon.setActiveProfile(.performance);
        try expectFile(&tmp, "performance\n");
    }
}

test "failed write after a cache refresh keeps the refreshed cache" {
    const sys = @import("sys.zig");
    const fd = testutil.memfd("daemon-test") catch return error.SkipZigTest;
    defer sys.close(fd);
    var errno: std.os.linux.E = .SUCCESS;
    try sys.writeAll(fd, "performance\n", &errno);
    if (!testutil.addSeals(fd, std.os.linux.F.SEAL_WRITE)) return error.SkipZigTest;
    var path_buf: [64]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/proc/self/fd/{d}", .{fd}, 0);

    var daemon: Daemon = .{ .sysfs = .{ .path = path, .fd = -1 }, .active = .balanced };
    // The fresh read succeeds and moves the cache; the sealed file then refuses the write.
    try std.testing.expectError(error.PermissionDenied, daemon.setActiveProfile(.power_saver));
    // Callers compare `active` before and after, so this visible change is still signalled.
    try std.testing.expectEqual(profile.Profile.performance, daemon.active);
}

test "external updates report change once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer daemon.deinit();

    try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "low-power\n" });
    try std.testing.expectEqual(true, try daemon.checkExternalUpdate());
    try std.testing.expectEqual(profile.Profile.power_saver, daemon.active);
    try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
}

test "custom, malformed and empty external content keep the cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "performance\n"));
    defer daemon.deinit();

    for ([_][]const u8{ "custom\n", "quiet\n", "", "balanced \n", "\n" }) |content| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = content });
        try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
        try std.testing.expectEqual(profile.Profile.performance, daemon.active);
    }
}

fn pipeDaemon(fds: *[2]std.os.linux.fd_t) !Daemon {
    try std.testing.expect(std.os.linux.errno(std.os.linux.pipe2(fds, .{ .CLOEXEC = true })) == .SUCCESS);
    // pread on a pipe fails with ESPIPE.
    return .{ .sysfs = .{ .path = "/unused", .fd = fds[0] }, .active = .balanced };
}

test "the third consecutive watch read failure is returned" {
    const sys = @import("sys.zig");
    var fds: [2]std.os.linux.fd_t = undefined;
    var daemon = try pipeDaemon(&fds);
    defer daemon.deinit();
    defer sys.close(fds[1]);

    try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
    try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
    try std.testing.expectError(error.ReadFailed, daemon.checkExternalUpdate());
    try std.testing.expectEqual(profile.Profile.balanced, daemon.active);
}

test "a successful read resets the failure count" {
    const sys = @import("sys.zig");
    var fds: [2]std.os.linux.fd_t = undefined;
    var daemon = try pipeDaemon(&fds);
    defer sys.close(fds[1]);
    const broken = daemon.sysfs;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    const good = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer good.deinit();

    for (0..4) |_| {
        daemon.sysfs = broken;
        try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
        try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
        daemon.sysfs = good.sysfs;
        try std.testing.expectEqual(false, try daemon.checkExternalUpdate());
        try std.testing.expectEqual(@as(u8, 0), daemon.read_failures);
    }
    sys.close(fds[0]);
}

test "unusable content also resets the failure count" {
    const sys = @import("sys.zig");
    var fds: [2]std.os.linux.fd_t = undefined;
    var daemon = try pipeDaemon(&fds);
    defer sys.close(fds[1]);
    defer sys.close(fds[0]);
    _ = try daemon.checkExternalUpdate();
    try std.testing.expectEqual(@as(u8, 1), daemon.read_failures);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    const odd = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer odd.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "custom\n" });
    daemon.sysfs = odd.sysfs;
    _ = try daemon.checkExternalUpdate();
    try std.testing.expectEqual(@as(u8, 0), daemon.read_failures);
}

test "an explicit request still writes when the pre-read fails" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [max_path]u8 = undefined;
    var daemon = try Daemon.init(try tempFile(&tmp, &buf, "balanced\n"));
    defer daemon.deinit();
    // Write-only: the fresh read fails with EACCES (unless running as root,
    // where it succeeds); either way the request must end up in the file.
    const rc = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, daemon.sysfs.path.ptr, 0o200);
    try std.testing.expect(std.os.linux.errno(rc) == .SUCCESS);

    try daemon.setActiveProfile(.performance);
    try std.testing.expectEqual(profile.Profile.performance, daemon.active);
    _ = std.os.linux.fchmodat(std.os.linux.AT.FDCWD, daemon.sysfs.path.ptr, 0o600);
    try expectFile(&tmp, "performance\n");
}
