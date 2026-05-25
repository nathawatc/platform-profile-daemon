const std = @import("std");
const profile = @import("profile.zig");
const sysfs_mod = @import("sysfs.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnknownProfile,
    UnknownKernelProfile,
    PermissionDenied,
    WriteFailed,
};

pub const Daemon = struct {
    sysfs: sysfs_mod.Sysfs,
    active: ?profile.DbusProfile = null,

    pub fn init(platform_profile_path: [:0]const u8) Daemon {
        return .{ .sysfs = sysfs_mod.Sysfs.init(platform_profile_path) };
    }

    pub fn refresh(self: *Daemon) Error!void {
        const kernel_profile = self.sysfs.readCurrent() catch |err| {
            return switch (err) {
                error.UnsupportedPlatform => Error.UnsupportedPlatform,
                error.UnknownKernelProfile => Error.UnknownKernelProfile,
                error.PermissionDenied => Error.PermissionDenied,
                error.WriteFailed => Error.WriteFailed,
            };
        };

        self.active = profile.dbusForKernel(kernel_profile);
    }

    pub fn activeName(self: *const Daemon) [:0]const u8 {
        const active = self.active orelse unreachable;
        return active.name();
    }

    pub fn setActiveId(self: *Daemon, requested_id: c_int) Error!bool {
        const requested = profile.DbusProfile.fromId(requested_id) orelse return Error.UnknownProfile;
        return self.setActiveProfile(requested);
    }

    fn setActiveProfile(self: *Daemon, requested: profile.DbusProfile) Error!bool {
        try self.refresh();
        if (self.active.? == requested) return false;

        const kernel_profile = profile.kernelForDbus(requested);

        self.sysfs.writeProfile(kernel_profile) catch |err| {
            return switch (err) {
                error.UnsupportedPlatform => Error.UnsupportedPlatform,
                error.UnknownKernelProfile => Error.UnknownKernelProfile,
                error.PermissionDenied => Error.PermissionDenied,
                error.WriteFailed => Error.WriteFailed,
            };
        };

        self.active = requested;
        return true;
    }
};

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
