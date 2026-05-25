const std = @import("std");
const profile = @import("profile.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnknownKernelProfile,
    PermissionDenied,
    WriteFailed,
};

pub const Sysfs = struct {
    path: [:0]const u8,

    pub fn init(path: [:0]const u8) Sysfs {
        return .{ .path = path };
    }

    pub fn readCurrent(self: Sysfs) Error!profile.KernelProfile {
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return mapOpenReadError();
        defer _ = std.c.close(fd);

        var buf: [64]u8 = undefined;
        const rc = std.c.read(fd, &buf, buf.len);
        if (rc < 0) return mapOpenReadError();

        const n: usize = @intCast(rc);
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return profile.KernelProfile.parse(text) orelse Error.UnknownKernelProfile;
    }

    pub fn writeProfile(self: Sysfs, value: profile.KernelProfile) Error!void {
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .WRONLY, .CLOEXEC = true });
        if (fd < 0) return mapOpenWriteError();
        defer _ = std.c.close(fd);

        try writeAll(fd, value.writeBytes());
    }
};

fn writeAll(fd: std.c.fd_t, bytes: []const u8) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = std.c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) return mapWriteError();
        if (rc == 0) return Error.WriteFailed;
        written += @intCast(rc);
    }
}

fn mapOpenReadError() Error {
    return switch (std.c.errno(-1)) {
        .NOENT, .NOTDIR => Error.UnsupportedPlatform,
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.UnsupportedPlatform,
    };
}

fn mapOpenWriteError() Error {
    return switch (std.c.errno(-1)) {
        .NOENT, .NOTDIR => Error.UnsupportedPlatform,
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

fn mapWriteError() Error {
    return switch (std.c.errno(-1)) {
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

test "read and write hardcoded platform profile file" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try writeAll(fd, "balanced\n");

    const sysfs = Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
    try sysfs.writeProfile(.performance);
    try std.testing.expectEqual(profile.KernelProfile.performance, try sysfs.readCurrent());
}
