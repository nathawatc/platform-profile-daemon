const std = @import("std");
const Daemon = @import("daemon.zig").Daemon;
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
    const path = parseArgs(&args) catch |err| {
        std.log.err("{t}", .{err});
        return err;
    };

    var daemon = Daemon.init(path) catch |err| {
        std.log.err("platform_profile unavailable: {t}", .{err});
        return err;
    };
    defer daemon.deinit();

    dbus.run(&daemon, .{
        .bus_address = init.environ.getPosix("DBUS_SYSTEM_BUS_ADDRESS"),
        .notify_socket = init.environ.getPosix("NOTIFY_SOCKET"),
        .watchdog_usec = init.environ.getPosix("WATCHDOG_USEC"),
        .watchdog_pid = init.environ.getPosix("WATCHDOG_PID"),
    }) catch |err| {
        std.log.err("D-Bus service failed: {t}", .{err});
        return err;
    };
}

fn parseArgs(args: anytype) ![:0]const u8 {
    _ = args.next();
    var path: [:0]const u8 = default_platform_profile_path;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help")) {
            rt.writeStdout("usage: platform-profile-daemon [--platform-profile PATH]\n");
            rt.exit(0);
        }
        if (std.mem.eql(u8, arg, "--platform-profile")) {
            path = args.next() orelse return error.MissingPlatformProfilePath;
        } else if (std.mem.startsWith(u8, arg, "--platform-profile=")) {
            path = arg["--platform-profile=".len.. :0];
        } else {
            return error.UnknownArgument;
        }
        if (path.len == 0) return error.MissingPlatformProfilePath;
    }
    return path;
}

const TestArgs = struct {
    args: []const [:0]const u8,
    index: usize = 0,

    fn next(self: *TestArgs) ?[:0]const u8 {
        if (self.index >= self.args.len) return null;
        defer self.index += 1;
        return self.args[self.index];
    }
};

fn parseTest(args: []const [:0]const u8) ![:0]const u8 {
    var it: TestArgs = .{ .args = args };
    return parseArgs(&it);
}

test "argument parser defaults to the real sysfs path" {
    try std.testing.expectEqualStrings(default_platform_profile_path, try parseTest(&.{"platform-profile-daemon"}));
}

test "argument parser rejects unknown arguments" {
    try std.testing.expectError(error.UnknownArgument, parseTest(&.{ "d", "--platform-profile", "/tmp/profile", "--bad" }));
}

test "argument parser rejects empty and missing path values" {
    try std.testing.expectError(error.MissingPlatformProfilePath, parseTest(&.{ "d", "--platform-profile", "" }));
    try std.testing.expectError(error.MissingPlatformProfilePath, parseTest(&.{ "d", "--platform-profile=" }));
    try std.testing.expectError(error.MissingPlatformProfilePath, parseTest(&.{ "d", "--platform-profile" }));
}

test "argument parser accepts explicit path with later valid override" {
    try std.testing.expectEqualStrings("/tmp/second", try parseTest(&.{ "d", "--platform-profile", "/tmp/first", "--platform-profile=/tmp/second" }));
}

test {
    _ = @import("daemon.zig");
    _ = @import("dbus.zig");
    _ = @import("dbus/polkit.zig");
    _ = @import("dbus/transport.zig");
    _ = @import("dbus/wire.zig");
    _ = @import("notify.zig");
    _ = @import("profile.zig");
    _ = @import("rt.zig");
    _ = @import("sys.zig");
    _ = @import("sysfs.zig");
}
