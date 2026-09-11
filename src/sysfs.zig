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
        const fd = try openRead(self.path);
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
        const fd = try openRead(self.path);
        defer _ = std.c.close(fd);

        var buf: [64]u8 = undefined;
        const n = try readProfileBytes(fd, &buf);
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return parseCurrentProfile(text) orelse Error.UnknownKernelProfile;
    }

    pub fn writeProfile(self: Sysfs, value: profile.KernelProfile) Error!void {
        const fd = try openWrite(self.path);
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

fn openRead(path: [:0]const u8) Error!std.c.fd_t {
    return openReadWith(path, cOpenRead, cErrno);
}

fn openReadWith(
    path: [:0]const u8,
    open_fn: *const fn ([*:0]const u8) std.c.fd_t,
    errno_fn: *const fn () std.c.E,
) Error!std.c.fd_t {
    while (true) {
        const fd = open_fn(path.ptr);
        if (fd >= 0) return fd;
        const err = errno_fn();
        if (err == .INTR) continue;
        return mapOpenReadError(err);
    }
}

fn openWrite(path: [:0]const u8) Error!std.c.fd_t {
    return openWriteWith(path, cOpenWrite, cErrno);
}

fn openWriteWith(
    path: [:0]const u8,
    open_fn: *const fn ([*:0]const u8) std.c.fd_t,
    errno_fn: *const fn () std.c.E,
) Error!std.c.fd_t {
    while (true) {
        const fd = open_fn(path.ptr);
        if (fd >= 0) return fd;
        const err = errno_fn();
        if (err == .INTR) continue;
        return mapOpenWriteError(err);
    }
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
            const err = errno_fn();
            if (err == .INTR) continue;
            return mapReadError(err);
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
            const err = errno_fn();
            if (err == .INTR) continue;
            return mapWriteError(err);
        }
        if (rc == 0) return Error.WriteFailed;
        written += @intCast(rc);
    }
}

fn cOpenRead(path: [*:0]const u8) std.c.fd_t {
    return std.c.open(path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true });
}

fn cOpenWrite(path: [*:0]const u8) std.c.fd_t {
    return std.c.open(path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true });
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

fn mapOpenReadError(err: std.c.E) Error {
    return switch (err) {
        .NOENT, .NOTDIR => Error.UnsupportedPlatform,
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.ReadFailed,
    };
}

test "open errors preserve semantic mappings" {
    try std.testing.expectEqual(Error.UnsupportedPlatform, mapOpenReadError(.NOENT));
    try std.testing.expectEqual(Error.UnsupportedPlatform, mapOpenWriteError(.NOENT));
    try std.testing.expectEqual(Error.UnsupportedPlatform, mapOpenReadError(.NOTDIR));
    try std.testing.expectEqual(Error.UnsupportedPlatform, mapOpenWriteError(.NOTDIR));
    try std.testing.expectEqual(Error.PermissionDenied, mapOpenReadError(.ACCES));
    try std.testing.expectEqual(Error.PermissionDenied, mapOpenWriteError(.ACCES));
    try std.testing.expectEqual(Error.PermissionDenied, mapOpenReadError(.PERM));
    try std.testing.expectEqual(Error.PermissionDenied, mapOpenWriteError(.PERM));
    try std.testing.expectEqual(Error.ReadFailed, mapOpenReadError(.IO));
    try std.testing.expectEqual(Error.WriteFailed, mapOpenWriteError(.IO));
}

fn mapOpenWriteError(err: std.c.E) Error {
    return switch (err) {
        .NOENT, .NOTDIR => Error.UnsupportedPlatform,
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

fn mapWriteError(err: std.c.E) Error {
    return switch (err) {
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

fn mapReadError(err: std.c.E) Error {
    return switch (err) {
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.ReadFailed,
    };
}

test "read and write errors preserve permission and fallback mappings" {
    try std.testing.expectEqual(Error.PermissionDenied, mapReadError(.ACCES));
    try std.testing.expectEqual(Error.PermissionDenied, mapWriteError(.ACCES));
    try std.testing.expectEqual(Error.PermissionDenied, mapReadError(.PERM));
    try std.testing.expectEqual(Error.PermissionDenied, mapWriteError(.PERM));
    try std.testing.expectEqual(Error.ReadFailed, mapReadError(.IO));
    try std.testing.expectEqual(Error.WriteFailed, mapWriteError(.IO));
}

test "injected errno drives syscall helper mappings" {
    const State = struct {
        fn fakeOpen(path: [*:0]const u8) std.c.fd_t {
            _ = path;
            return -1;
        }

        fn fakeRead(fd: std.c.fd_t, ptr: [*]u8, len: usize) isize {
            _ = fd;
            _ = ptr;
            _ = len;
            return -1;
        }

        fn fakeWrite(fd: std.c.fd_t, ptr: [*]const u8, len: usize) isize {
            _ = fd;
            _ = ptr;
            _ = len;
            return -1;
        }

        fn fakeErrno() std.c.E {
            return .ACCES;
        }
    };

    const errno_ptr = std.c._errno();
    const previous_errno = errno_ptr.*;
    defer errno_ptr.* = previous_errno;
    errno_ptr.* = @intFromEnum(std.c.E.IO);

    try std.testing.expectError(Error.PermissionDenied, openReadWith("/tmp/unused", State.fakeOpen, State.fakeErrno));
    try std.testing.expectError(Error.PermissionDenied, openWriteWith("/tmp/unused", State.fakeOpen, State.fakeErrno));

    var buf: [1]u8 = undefined;
    try std.testing.expectError(Error.PermissionDenied, readProfileBytesWith(-1, &buf, State.fakeRead, State.fakeErrno));
    try std.testing.expectError(Error.PermissionDenied, writeAllWith(-1, "x", State.fakeWrite, State.fakeErrno));
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

test "read open retries EINTR and succeeds" {
    const State = struct {
        var calls: usize = 0;
        var last_errno: std.c.E = .SUCCESS;

        fn fakeOpen(path: [*:0]const u8) std.c.fd_t {
            calls += 1;
            if (calls == 1) {
                last_errno = .INTR;
                return -1;
            }
            last_errno = .SUCCESS;
            return cOpenRead(path);
        }

        fn fakeErrno() std.c.E {
            return last_errno;
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-open-read-eintr-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const seed_fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(seed_fd >= 0);
    defer _ = std.c.close(seed_fd);
    try writeAll(seed_fd, "balanced\n");

    State.calls = 0;
    State.last_errno = .SUCCESS;
    const fd = try openReadWith(path, State.fakeOpen, State.fakeErrno);
    defer _ = std.c.close(fd);

    try std.testing.expectEqual(@as(usize, 2), State.calls);
}

test "write open retries EINTR and succeeds" {
    const State = struct {
        var calls: usize = 0;
        var last_errno: std.c.E = .SUCCESS;

        fn fakeOpen(path: [*:0]const u8) std.c.fd_t {
            calls += 1;
            if (calls == 1) {
                last_errno = .INTR;
                return -1;
            }
            last_errno = .SUCCESS;
            return cOpenWrite(path);
        }

        fn fakeErrno() std.c.E {
            return last_errno;
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "/tmp/platform-profile-daemon-test-open-write-eintr-{d}", .{std.c.getpid()});
    defer _ = std.c.unlink(path.ptr);

    const seed_fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    try std.testing.expect(seed_fd >= 0);
    defer _ = std.c.close(seed_fd);
    try writeAll(seed_fd, "balanced\n");

    State.calls = 0;
    State.last_errno = .SUCCESS;
    const fd = try openWriteWith(path, State.fakeOpen, State.fakeErrno);
    defer _ = std.c.close(fd);

    try writeAll(fd, "performance\n");
    try std.testing.expectEqual(@as(usize, 2), State.calls);
}
