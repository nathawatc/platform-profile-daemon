const std = @import("std");
const profile = @import("profile.zig");

pub const Error = error{
    UnsupportedPlatform,
    UnknownKernelProfile,
    PermissionDenied,
    WriteFailed,
    ReadFailed,
};

pub const CurrentProfile = union(enum) {
    supported: profile.KernelProfile,
    custom,
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
        errdefer self.deinit();

        var buf: [64]u8 = undefined;
        _ = try readProfileBytes(self.fd, &buf);
    }

    pub fn pollFd(self: Sysfs) std.c.fd_t {
        return self.fd;
    }

    pub fn checkAndRefreshCurrent(self: *Sysfs) ?CurrentProfile {
        if (self.fd < 0) return null;
        var buf: [64]u8 = undefined;
        if (std.c.lseek(self.fd, 0, 0) < 0) return null;
        const n = readProfileBytes(self.fd, &buf) catch return null;
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        if (text.len == 0) return null;
        return parseCurrentProfile(text);
    }

    pub fn readCurrent(self: Sysfs) Error!profile.KernelProfile {
        const current = try self.readCurrentProfile();
        return switch (current) {
            .supported => |kernel_profile| kernel_profile,
            .custom => Error.UnknownKernelProfile,
        };
    }

    pub fn readCurrentProfile(self: Sysfs) Error!CurrentProfile {
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
        if (fd < 0) return mapOpenReadError();
        defer _ = std.c.close(fd);

        var buf: [64]u8 = undefined;
        const n = try readProfileBytes(fd, &buf);
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return parseCurrentProfile(text) orelse Error.UnknownKernelProfile;
    }

    pub fn writeProfile(self: Sysfs, value: profile.KernelProfile) Error!void {
        const fd = std.c.open(self.path.ptr, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
        if (fd < 0) return mapOpenWriteError();
        defer _ = std.c.close(fd);

        try writeAll(fd, value.writeBytes());
    }
};

fn parseCurrentProfile(text: []const u8) ?CurrentProfile {
    if (profile.KernelProfile.parse(text)) |kernel_profile| {
        return .{ .supported = kernel_profile };
    }
    if (std.mem.eql(u8, text, "custom")) return .custom;
    return null;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) Error!void {
    try writeAllWith(fd, bytes, cWrite, cErrno);
}

fn readProfileBytes(fd: std.c.fd_t, buf: []u8) Error!usize {
    return readProfileBytesWith(fd, buf, cRead, cErrno);
}

fn readProfileBytesWith(
    fd: std.c.fd_t,
    buf: []u8,
    read_fn: *const fn (std.c.fd_t, [*]u8, usize) isize,
    errno_fn: *const fn () std.c.E,
) Error!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = read_fn(fd, buf[total..].ptr, buf.len - total);
        if (rc < 0) {
            if (errno_fn() == .INTR) continue;
            return mapReadError();
        }
        if (rc == 0) break;
        total += @intCast(rc);
    }
    return total;
}

fn writeAllWith(
    fd: std.c.fd_t,
    bytes: []const u8,
    write_fn: *const fn (std.c.fd_t, [*]const u8, usize) isize,
    errno_fn: *const fn () std.c.E,
) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = write_fn(fd, bytes[written..].ptr, bytes.len - written);
        if (rc < 0) {
            if (errno_fn() == .INTR) continue;
            return mapWriteError();
        }
        if (rc == 0) return Error.WriteFailed;
        written += @intCast(rc);
    }
}

fn cWrite(fd: std.c.fd_t, ptr: [*]const u8, len: usize) isize {
    return std.c.write(fd, ptr, len);
}

fn cRead(fd: std.c.fd_t, ptr: [*]u8, len: usize) isize {
    return std.c.read(fd, ptr, len);
}

fn cErrno() std.c.E {
    return std.c.errno(-1);
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

fn mapReadError() Error {
    return switch (std.c.errno(-1)) {
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.ReadFailed,
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
    try expectSupportedProfile(&sysfs, .performance);

    try sysfs.writeProfile(.low_power);
    try expectSupportedProfile(&sysfs, .low_power);
}

test "watch closes fd when priming read fails" {
    var sysfs = Sysfs.init("/");
    defer sysfs.deinit();

    try std.testing.expectError(Error.ReadFailed, sysfs.watch());
    try std.testing.expectEqual(@as(std.c.fd_t, -1), sysfs.pollFd());
}

test "checkAndRefreshCurrent returns null for invalid fd and malformed content" {
    var sysfs = Sysfs.init("/tmp/does-not-matter");
    try std.testing.expectEqual(@as(?CurrentProfile, null), sysfs.checkAndRefreshCurrent());

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-invalid-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try writeAll(fd, "quiet\n");

    var watched = Sysfs.init(path);
    defer watched.deinit();
    try watched.watch();
    try std.testing.expectEqual(@as(?CurrentProfile, null), watched.checkAndRefreshCurrent());
}

test "checkAndRefreshCurrent returns null for empty content" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-empty-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    var watched = Sysfs.init(path);
    defer watched.deinit();
    try watched.watch();
    try std.testing.expectEqual(@as(?CurrentProfile, null), watched.checkAndRefreshCurrent());
}

test "old read and refresh APIs stay strict for custom" {
    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-custom-strict-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);
    try writeAll(fd, "custom\n");

    var sysfs = Sysfs.init(path);
    defer sysfs.deinit();

    try std.testing.expectError(Error.UnknownKernelProfile, sysfs.readCurrent());
    try std.testing.expectEqual(@as(std.meta.Tag(CurrentProfile), .custom), std.meta.activeTag(try sysfs.readCurrentProfile()));

    try sysfs.watch();
    const current = sysfs.checkAndRefreshCurrent() orelse return error.TestExpectedCustom;
    try std.testing.expectEqual(@as(std.meta.Tag(CurrentProfile), .custom), std.meta.activeTag(current));
}

fn expectSupportedProfile(sysfs: *Sysfs, expected: profile.KernelProfile) !void {
    const current = sysfs.checkAndRefreshCurrent() orelse return error.TestExpectedSupportedProfile;
    try std.testing.expectEqual(@as(std.meta.Tag(CurrentProfile), .supported), std.meta.activeTag(current));
    try std.testing.expectEqual(expected, current.supported);
}

test "writeAll retries on EINTR and completes write" {
    const State = struct {
        var first_call = true;
        var last_errno: std.c.E = .SUCCESS;

        fn fakeWrite(fd: std.c.fd_t, ptr: [*]const u8, len: usize) isize {
            if (first_call) {
                first_call = false;
                last_errno = .INTR;
                return -1;
            }
            last_errno = .SUCCESS;
            return std.c.write(fd, ptr, len);
        }

        fn fakeErrno() std.c.E {
            return last_errno;
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-eintr-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(fd >= 0);
    defer _ = std.c.close(fd);

    State.first_call = true;
    State.last_errno = .SUCCESS;
    try writeAllWith(fd, "balanced\n", State.fakeWrite, State.fakeErrno);

    const sysfs = Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "readProfileBytes retries EINTR and handles short reads" {
    const State = struct {
        var calls: usize = 0;
        var last_errno: std.c.E = .SUCCESS;
        const text = "performance\n";

        fn fakeRead(fd: std.c.fd_t, ptr: [*]u8, len: usize) isize {
            _ = fd;
            if (calls == 0) {
                calls += 1;
                last_errno = .INTR;
                return -1;
            }
            if (calls > text.len) return 0;

            const remaining = text.len - (calls - 1);
            const n = @min(@min(len, remaining), 3);
            @memcpy(ptr[0..n], text[(calls - 1)..][0..n]);
            calls += n;
            last_errno = .SUCCESS;
            return @intCast(n);
        }

        fn fakeErrno() std.c.E {
            return last_errno;
        }
    };

    var buf: [64]u8 = undefined;
    State.calls = 0;
    State.last_errno = .SUCCESS;

    const n = try readProfileBytesWith(-1, &buf, State.fakeRead, State.fakeErrno);
    try std.testing.expectEqualStrings("performance\n", buf[0..n]);
}
