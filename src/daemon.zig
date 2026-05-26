const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const sysfs_mod = @import("sysfs.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnknownProfile,
    UnknownKernelProfile,
    PermissionDenied,
    WriteFailed,
    ReadFailed,
};

pub const Daemon = struct {
    sysfs: sysfs_mod.Sysfs,
    active: ?profile.DbusProfile = null,

    pub fn init(platform_profile_path: [:0]const u8) Daemon {
        return .{ .sysfs = sysfs_mod.Sysfs.init(platform_profile_path) };
    }

    pub fn deinit(self: *Daemon) void {
        self.sysfs.deinit();
    }

    pub fn watch(self: *Daemon) void {
        self.sysfs.watch() catch |err| {
            std.log.warn("failed to watch platform_profile: {}", .{err});
        };
    }

    pub fn refresh(self: *Daemon) Error!void {
        const kernel_profile = self.sysfs.readCurrent() catch |err| {
            self.active = null;
            return mapSysfsError(err);
        };

        self.active = profile.dbusForKernel(kernel_profile);
    }

    pub fn activeName(self: *const Daemon) [:0]const u8 {
        return if (self.active) |active| active.name() else "";
    }

    pub fn setActiveId(self: *Daemon, requested_id: c_int) Error!bool {
        const requested = profile.DbusProfile.fromId(requested_id) orelse return Error.UnknownProfile;
        return self.setActiveProfile(requested);
    }

    fn setActiveProfile(self: *Daemon, requested: profile.DbusProfile) Error!bool {
        const current_kernel_profile: ?profile.KernelProfile = self.sysfs.readCurrent() catch |err| blk: {
            const mapped = mapSysfsError(err);
            if (mapped != Error.UnknownKernelProfile) return mapped;
            break :blk null;
        };

        if (current_kernel_profile) |kernel_profile| {
            const current = profile.dbusForKernel(kernel_profile);
            self.active = current;
            if (current == requested) return false;
        }

        const kernel_profile = profile.kernelForDbus(requested);

        self.sysfs.writeProfile(kernel_profile) catch |err| {
            return mapSysfsError(err);
        };

        self.active = requested;
        return true;
    }

    pub fn checkExternalUpdate(self: *Daemon) bool {
        const kernel_profile = (&self.sysfs).checkAndRefresh() orelse {
            if (!builtin.is_test) {
                std.log.warn("ignoring invalid platform_profile refresh event", .{});
            }
            return false;
        };
        const new_active = profile.dbusForKernel(kernel_profile);
        if (new_active != self.active) {
            self.active = new_active;
            return true;
        }
        return false;
    }

    pub fn pollFd(self: *Daemon) std.c.fd_t {
        return (&self.sysfs).pollFd();
    }
};

fn mapSysfsError(err: sysfs_mod.Error) Error {
    return switch (err) {
        error.UnsupportedPlatform => Error.UnsupportedPlatform,
        error.UnknownKernelProfile => Error.UnknownKernelProfile,
        error.PermissionDenied => Error.PermissionDenied,
        error.WriteFailed => Error.WriteFailed,
        error.ReadFailed => Error.ReadFailed,
    };
}

test "unknown dbus profile is rejected" {
    var daemon = Daemon.init("/tmp/does-not-matter");
    try std.testing.expectError(Error.UnknownProfile, daemon.setActiveId(99));
}

test "setting same profile after refresh skips sysfs write" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-daemon-test-same-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    const written = std.c.write(fd, "balanced\n", "balanced\n".len);
    try std.testing.expectEqual(@as(isize, "balanced\n".len), written);

    var daemon = Daemon.init(path);
    try daemon.refresh();
    try std.testing.expectEqual(false, try daemon.setActiveId(1));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}

test "stale cached active profile does not skip write" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-daemon-test-stale-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    const written = std.c.write(fd, "performance\n", "performance\n".len);
    try std.testing.expectEqual(@as(isize, "performance\n".len), written);

    var daemon = Daemon.init(path);
    daemon.active = .balanced;
    try std.testing.expectEqual(true, try daemon.setActiveId(1));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "unknown current kernel profile still allows write" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-daemon-test-unknown-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    const written = std.c.write(fd, "quiet\n", "quiet\n".len);
    try std.testing.expectEqual(@as(isize, "quiet\n".len), written);

    var daemon = Daemon.init(path);
    try std.testing.expectEqual(true, try daemon.setActiveId(1));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "invalid external refresh keeps cached profile unchanged and reports no change" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-daemon-test-refresh-invalid-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const written = std.c.write(fd, "balanced\n", "balanced\n".len);
    try std.testing.expectEqual(@as(isize, "balanced\n".len), written);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const truncate_fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
    try std.testing.expect(truncate_fd >= 0);
    defer _ = std.c.close(truncate_fd);

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}

test "malformed external refresh keeps cached profile unchanged and reports no change" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-daemon-test-refresh-malformed-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    const written = std.c.write(fd, "balanced\n", "balanced\n".len);
    try std.testing.expectEqual(@as(isize, "balanced\n".len), written);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const write_fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
    try std.testing.expect(write_fd >= 0);
    defer _ = std.c.close(write_fd);
    const malformed_written = std.c.write(write_fd, "quiet\n", "quiet\n".len);
    try std.testing.expectEqual(@as(isize, "quiet\n".len), malformed_written);

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}
