const std = @import("std");
const daemon_mod = @import("daemon.zig");
const profile = @import("profile.zig");

const default_platform_profile_path = "/sys/firmware/acpi/platform_profile";

extern fn ppd_bus_run(state: *anyopaque) c_int;
extern fn ppd_emit_active_profile_changed() void;

const CallbackStatus = enum(c_int) {
    ok = 0,
    unsupported = 1,
    invalid_profile = 2,
    permission_denied = 3,
    write_failed = 4,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const platform_profile_path = parsePlatformProfilePath(args) catch |err| {
        std.log.err("{}", .{err});
        return err;
    };

    var daemon = daemon_mod.Daemon.init(platform_profile_path);
    daemon.refresh();

    const rc = ppd_bus_run(&daemon);
    if (rc < 0) return error.DBusFailed;
}

fn parsePlatformProfilePath(args: []const [:0]const u8) ![:0]const u8 {
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help")) {
            std.debug.print("usage: platform-profile-daemon [--platform-profile PATH]\n", .{});
            std.process.exit(0);
        }
        if (std.mem.eql(u8, arg, "--platform-profile")) {
            if (i + 1 >= args.len) return error.MissingPlatformProfilePath;
            return args[i + 1];
        }
        if (std.mem.startsWith(u8, arg, "--platform-profile=")) {
            return arg["--platform-profile=".len.. :0];
        }
        return error.UnknownArgument;
    }
    return default_platform_profile_path;
}

export fn ppd_get_active_profile(ctx: *anyopaque) [*:0]const u8 {
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    return daemon.activeName().ptr;
}

export fn ppd_set_active_profile(ctx: *anyopaque, raw_profile: [*:0]const u8) c_int {
    const daemon: *daemon_mod.Daemon = @ptrCast(@alignCast(ctx));
    const requested = std.mem.span(raw_profile);
    daemon.setActive(requested) catch |err| {
        return @intFromEnum(switch (err) {
            error.UnsupportedPlatform, error.UnknownKernelProfile => CallbackStatus.unsupported,
            error.UnknownProfile => CallbackStatus.invalid_profile,
            error.PermissionDenied => CallbackStatus.permission_denied,
            error.WriteFailed => CallbackStatus.write_failed,
        });
    };
    ppd_emit_active_profile_changed();
    return @intFromEnum(CallbackStatus.ok);
}

test {
    _ = profile;
    _ = daemon_mod;
}
