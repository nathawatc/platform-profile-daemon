const std = @import("std");
const builtin = @import("builtin");
const profile = @import("profile.zig");
const sysfs_mod = @import("sysfs.zig");
const testutil = @import("testutil.zig");

pub const Error = error{
    UnsupportedPlatform,
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

    pub fn watch(self: *Daemon) Error!void {
        self.sysfs.watch() catch |err| {
            return mapSysfsError(err);
        };
    }

    pub fn refresh(self: *Daemon) Error!void {
        const current = self.sysfs.readCurrentProfile() catch |err| {
            return mapSysfsError(err);
        };

        switch (current) {
            .supported => |kernel_profile| {
                self.active = profile.dbusForKernel(kernel_profile);
            },
            .custom => {
                return Error.UnknownKernelProfile;
            },
        }
    }

    pub fn activeName(self: *const Daemon) [:0]const u8 {
        return if (self.active) |active| active.name() else "";
    }

    pub fn setActiveProfile(self: *Daemon, requested: profile.DbusProfile) Error!bool {
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
        const current = self.sysfs.checkAndRefreshCurrent() orelse {
            if (!builtin.is_test) {
                std.log.warn("ignoring invalid platform_profile refresh event", .{});
            }
            return false;
        };
        switch (current) {
            .supported => |kernel_profile| {
                const new_active = profile.dbusForKernel(kernel_profile);
                if (new_active != self.active) {
                    self.active = new_active;
                    return true;
                }
                return false;
            },
            .custom => {
                if (!builtin.is_test) {
                    std.log.warn("ignoring custom platform_profile; keeping cached ActiveProfile", .{});
                }
                return false;
            },
        }
    }

    pub fn pollFd(self: *Daemon) std.os.linux.fd_t {
        return self.sysfs.pollFd();
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

fn writeTempProfile(path_buf: []u8, comptime name: []const u8, contents: []const u8) ![:0]const u8 {
    const path = try std.mem.printSentinel(path_buf, "/tmp/platform-profile-daemon-daemon-test-" ++ name ++ "-{d}", .{testutil.pid()}, 0);
    try overwriteProfile(path, contents);
    return path;
}

fn overwriteProfile(path: [:0]const u8, contents: []const u8) !void {
    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);
    try testutil.writeBytes(fd, contents);
}

test "watch propagates setup failure" {
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-watch-missing-{d}", .{testutil.pid()}, 0);
    testutil.unlink(path.ptr);
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    defer daemon.deinit();

    try std.testing.expectError(Error.UnsupportedPlatform, daemon.watch());
    try std.testing.expectEqual(@as(std.os.linux.fd_t, -1), daemon.pollFd());
}

test "setting same profile after refresh skips sysfs write" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "same", "balanced\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    try daemon.refresh();
    try std.testing.expectEqual(false, try daemon.setActiveProfile(.balanced));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}

test "stale cached active profile does not skip write" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "stale", "performance\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    daemon.active = .balanced;
    try std.testing.expectEqual(true, try daemon.setActiveProfile(.balanced));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "unknown current kernel profile still allows write" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "unknown", "quiet\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    try std.testing.expectEqual(true, try daemon.setActiveProfile(.balanced));
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "custom startup profile fails without writing" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "custom", "custom\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    try std.testing.expectError(Error.UnknownKernelProfile, daemon.refresh());
    try std.testing.expectEqualStrings("", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(sysfs_mod.CurrentProfile.custom, try sysfs.readCurrentProfile());
}

test "custom refresh failure preserves cached profile" {
    var path_buf: [128]u8 = undefined;
    const sealed = try sealedCustomProfilePath(&path_buf);
    defer testutil.close(sealed.fd);

    var daemon = Daemon.init(sealed.path);
    daemon.active = .performance;

    try std.testing.expectError(Error.UnknownKernelProfile, daemon.refresh());
    try std.testing.expectEqualStrings("performance", daemon.activeName());
}

test "custom external refresh preserves cache and explicit same cached profile converges" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "refresh-custom", "performance\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("performance", daemon.activeName());

    try overwriteProfile(path, "custom\n");

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("performance", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(sysfs_mod.CurrentProfile.custom, try sysfs.readCurrentProfile());
    try std.testing.expectEqual(true, try daemon.setActiveProfile(.performance));
    try std.testing.expectEqual(profile.KernelProfile.performance, try sysfs.readCurrent());
}

test "custom external refresh on sealed file preserves cached profile" {
    var path_buf: [128]u8 = undefined;
    const sealed = try sealedCustomProfilePath(&path_buf);
    defer testutil.close(sealed.fd);

    var daemon = Daemon.init(sealed.path);
    defer daemon.deinit();
    daemon.active = .performance;
    try daemon.sysfs.watch();

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("performance", daemon.activeName());
}

test "custom external refresh from balanced reports no visible change" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "refresh-custom-balanced", "balanced\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    try overwriteProfile(path, "custom\n");

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    const sysfs = sysfs_mod.Sysfs.init(path);
    try std.testing.expectEqual(sysfs_mod.CurrentProfile.custom, try sysfs.readCurrentProfile());
}

test "invalid external refresh keeps cached profile unchanged and reports no change" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "refresh-invalid", "balanced\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    try overwriteProfile(path, "");

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}

fn sealedCustomProfilePath(path_buf: []u8) !struct { fd: std.os.linux.fd_t, path: [:0]const u8 } {
    const linux = std.os.linux;
    const fd = testutil.memfd("platform-profile-daemon-test") catch return error.SkipZigTest;
    errdefer testutil.close(fd);

    try testutil.writeBytes(fd, "custom\n");
    try std.testing.expect(linux.errno(linux.lseek(fd, 0, 0)) == .SUCCESS);

    const seals = linux.F.SEAL_WRITE | linux.F.SEAL_SHRINK | linux.F.SEAL_GROW | linux.F.SEAL_SEAL;
    if (!testutil.addSeals(fd, seals)) return error.SkipZigTest;

    const path = try std.mem.printSentinel(path_buf, "/proc/self/fd/{d}", .{fd}, 0);
    return .{ .fd = fd, .path = path };
}

test "malformed external refresh keeps cached profile unchanged and reports no change" {
    var path_buf: [128]u8 = undefined;
    const path = try writeTempProfile(&path_buf, "refresh-malformed", "balanced\n");
    defer testutil.unlink(path.ptr);

    var daemon = Daemon.init(path);
    defer daemon.deinit();
    try daemon.refresh();
    try daemon.sysfs.watch();
    try std.testing.expectEqualStrings("balanced", daemon.activeName());

    try overwriteProfile(path, "quiet\n");

    try std.testing.expectEqual(false, daemon.checkExternalUpdate());
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}
