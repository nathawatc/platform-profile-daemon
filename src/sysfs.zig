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
    fd: std.c.fd_t = -1,

    pub fn init(path: [:0]const u8) Sysfs {
        return .{ .path = path };
    }

    pub fn deinit(self: *Sysfs) void {
        if (self.fd >= 0) {
            _ = std.c.close(self.fd);
            self.fd = -1;
        }
    }

    pub fn watch(self: *Sysfs) !void {
        if (self.fd >= 0) return;
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return mapOpenReadError();
        self.fd = fd;

        var buf: [64]u8 = undefined;
        _ = std.c.read(self.fd, &buf, buf.len);
    }

    pub fn pollFd(self: Sysfs) std.c.fd_t {
        return self.fd;
    }

    pub fn checkAndRefresh(self: *Sysfs) profile.KernelProfile {
        if (self.fd < 0) return .balanced;
        var buf: [64]u8 = undefined;
        _ = std.c.lseek(self.fd, 0, 0);
        const rc = std.c.read(self.fd, &buf, buf.len);
        if (rc <= 0) return .balanced;
        const n: usize = @intCast(rc);
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return profile.KernelProfile.parse(text) orelse .balanced;
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
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
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

test "read, write, watch and refresh platform profile file" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try writeAll(fd, "balanced\n");

    var sysfs = Sysfs.init(path);
    defer sysfs.deinit();

    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
    try sysfs.writeProfile(.performance);
    try std.testing.expectEqual(profile.KernelProfile.performance, try sysfs.readCurrent());

    try sysfs.watch();
    try std.testing.expect(sysfs.pollFd() >= 0);
    try std.testing.expectEqual(profile.KernelProfile.performance, sysfs.checkAndRefresh());

    try sysfs.writeProfile(.low_power);
    try std.testing.expectEqual(profile.KernelProfile.low_power, sysfs.checkAndRefresh());
}
