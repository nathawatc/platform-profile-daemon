const std = @import("std");
const daemon_mod = @import("daemon.zig");
const profile_mod = @import("profile.zig");

pub const std_options: std.Options = .{
    .signal_stack_size = null,
};

const default_platform_profile_path = "/sys/firmware/acpi/platform_profile";

extern fn ppd_bus_run(state: *anyopaque) c_int;
extern fn ppd_emit_active_profile_changed() void;

const CallbackStatus = enum(c_int) {
    ok = 0,
    unsupported = 1,
    invalid_profile = 2,
    permission_denied = 3,
    write_failed = 4,
    read_failed = 5,
};

export fn ppd_profile_id_from_name(name: [*:0]const u8) c_int {
    const text = std.mem.sliceTo(name, 0);
    const dbus_profile = profile_mod.DbusProfile.parseName(text) orelse return -1;
    return switch (dbus_profile) {
        .power_saver => 0,
        .balanced => 1,
        .performance => 2,
    };
}

pub fn main(init: std.process.Init.Minimal) !void {
    var args = std.process.Args.Iterator.init(init.args);
    const platform_profile_path = parsePlatformProfilePathIterator(&args) catch |err| {
        std.log.err("{}", .{err});
        return err;
    };

    var daemon = daemon_mod.Daemon.init(platform_profile_path);
    defer daemon.deinit();
    daemon.watch() catch |err| {
        std.log.err("failed to watch platform_profile: {}", .{err});
        return err;
    };
    daemon.refresh() catch |err| {
        std.log.err("platform_profile unavailable: {}", .{err});
        return err;
    };

    const rc = ppd_bus_run(&daemon);
    if (rc < 0) return error.DBusFailed;
}

fn parsePlatformProfilePath(args: []const [:0]const u8) ![:0]const u8 {
    var iterator = SliceArgIterator{ .args = args };
    return parsePlatformProfilePathIterator(&iterator);
}

const SliceArgIterator = struct {
    args: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *SliceArgIterator) ?[:0]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

fn parsePlatformProfilePathIterator(args: anytype) ![:0]const u8 {
    _ = args.next();
    var platform_profile_path: [:0]const u8 = default_platform_profile_path;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: platform-profile-daemon [--platform-profile PATH]\n", .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--platform-profile")) {
            const path = args.next() orelse return error.MissingPlatformProfilePath;
            if (path.len == 0) return error.MissingPlatformProfilePath;
            platform_profile_path = path;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--platform-profile=")) {
            const path = arg["--platform-profile=".len.. :0];
            if (path.len == 0) return error.MissingPlatformProfilePath;
            platform_profile_path = path;
            continue;
        }
        return error.UnknownArgument;
    }
    return platform_profile_path;
}

export fn ppd_get_active_profile(ctx: *anyopaque) [*:0]const u8 {
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    return daemon.activeName().ptr;
}

export fn ppd_set_active_profile_id(ctx: *anyopaque, profile_id: c_int) c_int {
    const requested = profile_mod.DbusProfile.fromId(profile_id) orelse return @backingInt(CallbackStatus.invalid_profile);
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    const changed = daemon.setActiveProfile(requested) catch |err| {
        return @backingInt(switch (err) {
            error.UnsupportedPlatform, error.UnknownKernelProfile => CallbackStatus.unsupported,
            error.PermissionDenied => CallbackStatus.permission_denied,
            error.WriteFailed => CallbackStatus.write_failed,
            error.ReadFailed => CallbackStatus.read_failed,
        });
    };
    if (changed) ppd_emit_active_profile_changed();
    return @backingInt(CallbackStatus.ok);
}
export fn ppd_poll_fd(ctx: *anyopaque) c_int {
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    return daemon.pollFd();
}

export fn ppd_check_external_update(ctx: *anyopaque) c_int {
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    if (daemon.checkExternalUpdate()) {
        ppd_emit_active_profile_changed();
        return 1;
    }
    return 0;
}

test "platform profile path parser rejects trailing unknown args" {
    const args = &[_][:0]const u8{ "platform-profile-daemon", "--platform-profile", "/tmp/profile", "--bad" };
    try std.testing.expectError(error.UnknownArgument, parsePlatformProfilePath(args));
}

test "platform profile path parser rejects empty path values" {
    const split_args = &[_][:0]const u8{ "platform-profile-daemon", "--platform-profile", "" };
    try std.testing.expectError(error.MissingPlatformProfilePath, parsePlatformProfilePath(split_args));

    const equals_args = &[_][:0]const u8{ "platform-profile-daemon", "--platform-profile=" };
    try std.testing.expectError(error.MissingPlatformProfilePath, parsePlatformProfilePath(equals_args));
}

test "platform profile path parser accepts explicit path with later valid override" {
    const args = &[_][:0]const u8{ "platform-profile-daemon", "--platform-profile", "/tmp/first", "--platform-profile=/tmp/second" };
    try std.testing.expectEqualStrings("/tmp/second", try parsePlatformProfilePath(args));
}

test "D-Bus setter callback converges custom even when requested profile matches cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profile", .data = "custom\n" });
    const path = try tmp.dir.realPathFileAlloc(std.testing.io, "profile", std.testing.allocator);
    defer std.testing.allocator.free(path);
    var daemon = daemon_mod.Daemon.init(path);
    daemon.active = .performance;
    try std.testing.expectEqual(@as(c_int, 0), ppd_set_active_profile_id(&daemon, 2));
    try std.testing.expectEqual(profile_mod.KernelProfile.performance, try daemon.sysfs.readCurrent());
    try std.testing.expectEqualStrings("performance", daemon.activeName());
}
