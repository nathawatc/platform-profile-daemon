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
    supported: bool = false,
    active: ?profile.DbusProfile = null,

    pub fn init(platform_profile_path: [:0]const u8) Daemon {
        return .{ .sysfs = sysfs_mod.Sysfs.init(platform_profile_path) };
    }

    pub fn refresh(self: *Daemon) void {
        const kernel_profile = self.sysfs.readCurrent() catch |err| {
            self.active = null;
            self.supported = err != error.UnsupportedPlatform and err != error.PermissionDenied;
            std.log.warn("platform_profile unavailable: {}", .{err});
            return;
        };

        self.supported = true;
        self.active = profile.dbusForKernel(kernel_profile);
    }

    pub fn activeName(self: Daemon) [:0]const u8 {
        return if (self.active) |active| active.name() else "";
    }

    pub fn setActive(self: *Daemon, requested_name: []const u8) Error!bool {
        const requested = profile.DbusProfile.parse(requested_name) orelse return Error.UnknownProfile;
        const kernel_profile = profile.kernelForDbus(requested);
        const changed = self.active != requested;

        self.sysfs.writeProfile(kernel_profile) catch |err| {
            return switch (err) {
                error.UnsupportedPlatform => Error.UnsupportedPlatform,
                error.UnknownKernelProfile => Error.UnknownKernelProfile,
                error.PermissionDenied => Error.PermissionDenied,
                error.WriteFailed => Error.WriteFailed,
            };
        };

        self.supported = true;
        self.active = requested;
        return changed;
    }
};

test "unknown dbus profile is rejected" {
    var daemon = Daemon.init("/tmp/does-not-matter");
    try std.testing.expectError(Error.UnknownProfile, daemon.setActive("quiet"));
}
