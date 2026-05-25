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

    pub fn refresh(self: *Daemon) void {
        const kernel_profile = self.sysfs.readCurrent() catch |err| {
            self.active = null;
            std.log.warn("platform_profile unavailable: {}", .{err});
            return;
        };

        self.active = profile.dbusForKernel(kernel_profile);
    }

    pub fn activeName(self: *Daemon) [:0]const u8 {
        self.refresh();
        return if (self.active) |active| active.name() else "";
    }

    pub fn setActiveId(self: *Daemon, requested_id: c_int) Error!bool {
        const requested = profile.DbusProfile.fromId(requested_id) orelse return Error.UnknownProfile;
        return self.setActiveProfile(requested);
    }

    fn setActiveProfile(self: *Daemon, requested: profile.DbusProfile) Error!bool {
        if (self.active == requested) return false;

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

test "setting cached active profile skips sysfs write" {
    var daemon = Daemon.init("/tmp/does-not-exist");
    daemon.active = .balanced;
    try std.testing.expectEqual(false, try daemon.setActiveId(1));
}
