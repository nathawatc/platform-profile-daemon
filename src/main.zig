const std = @import("std");
const daemon_mod = @import("daemon.zig");
const dbus = @import("dbus.zig");
const rt = @import("rt.zig");

pub const std_options = rt.std_options;
// No std debug I/O: keeps the Io.Threaded singleton and Io.File.Writer out of the binary.
// A null here turns any accidental use of std.debug I/O into a compile error.
pub const std_options_debug_threaded_io: ?*std.Io.Threaded = null;
pub const panic = std.debug.FullPanic(rt.panicFn);

const default_platform_profile_path = "/sys/firmware/acpi/platform_profile";

/// Returns the exit status directly so std.start never prints error traces.
pub fn main(init: std.process.Init.Minimal) u8 {
    run(init) catch return 1;
    return 0;
}

fn run(init: std.process.Init.Minimal) !void {
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

    dbus.run(&daemon, init.environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS")) catch |err| {
        std.log.err("D-Bus service failed: {}", .{err});
        return err;
    };
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
            rt.writeStdout("usage: platform-profile-daemon [--platform-profile PATH]\n");
            rt.exit(0);
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

test {
    _ = @import("daemon.zig");
    _ = @import("dbus.zig");
    _ = @import("profile.zig");
    _ = @import("rt.zig");
    _ = @import("sysfs.zig");
}
