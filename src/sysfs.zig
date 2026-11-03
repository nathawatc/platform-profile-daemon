const std = @import("std");
const profile = @import("profile.zig");
const testutil = @import("testutil.zig");

const linux = std.os.linux;

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
    fd: linux.fd_t = -1,

    pub fn init(path: [:0]const u8) Sysfs {
        return .{ .path = path };
    }

    pub fn deinit(self: *Sysfs) void {
        if (self.fd >= 0) {
            _ = linux.close(self.fd);
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

    pub fn pollFd(self: Sysfs) linux.fd_t {
        return self.fd;
    }

    pub fn checkAndRefreshCurrent(self: *Sysfs) ?CurrentProfile {
        if (self.fd < 0) return null;
        var buf: [64]u8 = undefined;
        if (linux.errno(linux.lseek(self.fd, 0, 0)) != .SUCCESS) {
            self.deinit();
            return null;
        }
        const n = readProfileBytes(self.fd, &buf) catch {
            self.deinit();
            return null;
        };
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
        defer _ = linux.close(fd);

        var buf: [64]u8 = undefined;
        const n = try readProfileBytes(fd, &buf);
        const text = std.mem.trim(u8, buf[0..n], " \t\r\n");
        return parseCurrentProfile(text) orelse Error.UnknownKernelProfile;
    }

    pub fn writeProfile(self: Sysfs, value: profile.KernelProfile) Error!void {
        const fd = try openWrite(self.path);
        defer _ = linux.close(fd);

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

// Syscall hooks return the raw kernel result: a value, or -errno.
const OpenFn = *const fn ([*:0]const u8) usize;
const ReadFn = *const fn (linux.fd_t, [*]u8, usize) usize;
const WriteFn = *const fn (linux.fd_t, [*]const u8, usize) usize;

fn openRead(path: [:0]const u8) Error!linux.fd_t {
    return openReadWith(path, rawOpenRead);
}

fn openReadWith(path: [:0]const u8, open_fn: OpenFn) Error!linux.fd_t {
    while (true) {
        const rc = open_fn(path.ptr);
        const err = linux.errno(rc);
        if (err == .SUCCESS) return @intCast(rc);
        if (err == .INTR) continue;
        return mapOpenReadError(err);
    }
}

fn openWrite(path: [:0]const u8) Error!linux.fd_t {
    return openWriteWith(path, rawOpenWrite);
}

fn openWriteWith(path: [:0]const u8, open_fn: OpenFn) Error!linux.fd_t {
    while (true) {
        const rc = open_fn(path.ptr);
        const err = linux.errno(rc);
        if (err == .SUCCESS) return @intCast(rc);
        if (err == .INTR) continue;
        return mapOpenWriteError(err);
    }
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8) Error!void {
    try writeAllWith(fd, bytes, rawWrite, null);
}

/// Like `writeAll`, but reports the failing errno (`.SUCCESS` for a
/// zero-length write) so callers can log it.
pub fn writeAllReport(fd: linux.fd_t, bytes: []const u8, errno_out: *linux.E) Error!void {
    try writeAllWith(fd, bytes, rawWrite, errno_out);
}

pub fn readProfileBytes(fd: linux.fd_t, buf: []u8) Error!usize {
    return readProfileBytesWith(fd, buf, rawRead, null);
}

/// Like `readProfileBytes`, but reports the failing errno.
pub fn readProfileBytesReport(fd: linux.fd_t, buf: []u8, errno_out: *linux.E) Error!usize {
    return readProfileBytesWith(fd, buf, rawRead, errno_out);
}

fn readProfileBytesWith(
    fd: linux.fd_t,
    buf: []u8,
    read_fn: ReadFn,
    errno_out: ?*linux.E,
) Error!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = read_fn(fd, buf[total..].ptr, buf.len - total);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err == .INTR) continue;
            if (errno_out) |out| out.* = err;
            return mapReadError(err);
        }
        if (rc == 0) break;
        total += rc;
    }
    return total;
}

fn writeAllWith(
    fd: linux.fd_t,
    bytes: []const u8,
    write_fn: WriteFn,
    errno_out: ?*linux.E,
) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = write_fn(fd, bytes[written..].ptr, bytes.len - written);
        const err = linux.errno(rc);
        if (err != .SUCCESS) {
            if (err == .INTR) continue;
            if (errno_out) |out| out.* = err;
            return mapWriteError(err);
        }
        if (rc == 0) {
            if (errno_out) |out| out.* = .SUCCESS;
            return Error.WriteFailed;
        }
        written += rc;
    }
}

fn rawOpenRead(path: [*:0]const u8) usize {
    return linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
}

fn rawOpenWrite(path: [*:0]const u8) usize {
    return linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, 0);
}

fn rawWrite(fd: linux.fd_t, ptr: [*]const u8, len: usize) usize {
    return linux.write(fd, ptr, len);
}

fn rawRead(fd: linux.fd_t, ptr: [*]u8, len: usize) usize {
    return linux.read(fd, ptr, len);
}

fn mapOpenReadError(err: linux.E) Error {
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

fn mapOpenWriteError(err: linux.E) Error {
    return switch (err) {
        .NOENT, .NOTDIR => Error.UnsupportedPlatform,
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

fn mapWriteError(err: linux.E) Error {
    return switch (err) {
        .ACCES, .PERM => Error.PermissionDenied,
        else => Error.WriteFailed,
    };
}

fn mapReadError(err: linux.E) Error {
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
        fn fakeOpen(path: [*:0]const u8) usize {
            _ = path;
            return testutil.failure(.ACCES);
        }

        fn fakeRead(fd: linux.fd_t, ptr: [*]u8, len: usize) usize {
            _ = fd;
            _ = ptr;
            _ = len;
            return testutil.failure(.ACCES);
        }

        fn fakeWrite(fd: linux.fd_t, ptr: [*]const u8, len: usize) usize {
            _ = fd;
            _ = ptr;
            _ = len;
            return testutil.failure(.ACCES);
        }
    };

    try std.testing.expectError(Error.PermissionDenied, openReadWith("/tmp/unused", State.fakeOpen));
    try std.testing.expectError(Error.PermissionDenied, openWriteWith("/tmp/unused", State.fakeOpen));

    var buf: [1]u8 = undefined;
    var errno: linux.E = .SUCCESS;
    try std.testing.expectError(Error.PermissionDenied, readProfileBytesWith(-1, &buf, State.fakeRead, &errno));
    try std.testing.expectEqual(linux.E.ACCES, errno);
    errno = .SUCCESS;
    try std.testing.expectError(Error.PermissionDenied, writeAllWith(-1, "x", State.fakeWrite, &errno));
    try std.testing.expectEqual(linux.E.ACCES, errno);
}

test "zero-length write progress fails with success errno" {
    const State = struct {
        fn fakeWrite(fd: linux.fd_t, ptr: [*]const u8, len: usize) usize {
            _ = fd;
            _ = ptr;
            _ = len;
            return 0;
        }
    };

    var errno: linux.E = .IO;
    try std.testing.expectError(Error.WriteFailed, writeAllWith(-1, "x", State.fakeWrite, &errno));
    try std.testing.expectEqual(linux.E.SUCCESS, errno);
}

test "read, write, watch and refresh platform profile file" {
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);
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
    try std.testing.expectEqual(@as(linux.fd_t, -1), sysfs.pollFd());
}

test "checkAndRefreshCurrent returns null for invalid fd and malformed content" {
    var sysfs = Sysfs.init("/tmp/does-not-matter");
    try std.testing.expectEqual(@as(?CurrentProfile, null), sysfs.checkAndRefreshCurrent());

    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-invalid-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);
    try writeAll(fd, "quiet\n");

    var watched = Sysfs.init(path);
    defer watched.deinit();
    try watched.watch();
    try std.testing.expectEqual(@as(?CurrentProfile, null), watched.checkAndRefreshCurrent());
}

test "checkAndRefreshCurrent returns null for empty content" {
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-empty-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);

    var watched = Sysfs.init(path);
    defer watched.deinit();
    try watched.watch();
    try std.testing.expectEqual(@as(?CurrentProfile, null), watched.checkAndRefreshCurrent());
}

test "checkAndRefreshCurrent closes fd on seek error" {
    var pipe_fds: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&pipe_fds, .{ .CLOEXEC = true })) == .SUCCESS);
    defer testutil.close(pipe_fds[1]);

    var sysfs = Sysfs{ .path = "/tmp/unused", .fd = pipe_fds[0] };
    defer sysfs.deinit();

    try std.testing.expectEqual(@as(?CurrentProfile, null), sysfs.checkAndRefreshCurrent());
    try std.testing.expectEqual(@as(linux.fd_t, -1), sysfs.pollFd());
}

test "old read and refresh APIs stay strict for custom" {
    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-custom-strict-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);
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

        fn fakeWrite(fd: linux.fd_t, ptr: [*]const u8, len: usize) usize {
            if (first_call) {
                first_call = false;
                return testutil.failure(.INTR);
            }
            return linux.write(fd, ptr, len);
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-eintr-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const fd = try testutil.createFile(path.ptr);
    defer testutil.close(fd);

    State.first_call = true;
    try writeAllWith(fd, "balanced\n", State.fakeWrite, null);

    const sysfs = Sysfs.init(path);
    try std.testing.expectEqual(profile.KernelProfile.balanced, try sysfs.readCurrent());
}

test "readProfileBytes retries EINTR and handles short reads" {
    const State = struct {
        var calls: usize = 0;
        const text = "performance\n";

        fn fakeRead(fd: linux.fd_t, ptr: [*]u8, len: usize) usize {
            _ = fd;
            if (calls == 0) {
                calls += 1;
                return testutil.failure(.INTR);
            }
            if (calls > text.len) return 0;

            const remaining = text.len - (calls - 1);
            const n = @min(@min(len, remaining), 3);
            @memcpy(ptr[0..n], text[(calls - 1)..][0..n]);
            calls += n;
            return n;
        }
    };

    var buf: [64]u8 = undefined;
    State.calls = 0;

    const n = try readProfileBytesWith(-1, &buf, State.fakeRead, null);
    try std.testing.expectEqualStrings("performance\n", buf[0..n]);
}

test "read open retries EINTR and succeeds" {
    const State = struct {
        var calls: usize = 0;

        fn fakeOpen(path: [*:0]const u8) usize {
            calls += 1;
            if (calls == 1) return testutil.failure(.INTR);
            return rawOpenRead(path);
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-open-read-eintr-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const seed_fd = try testutil.createFile(path.ptr);
    defer testutil.close(seed_fd);
    try writeAll(seed_fd, "balanced\n");

    State.calls = 0;
    const fd = try openReadWith(path, State.fakeOpen);
    defer testutil.close(fd);

    try std.testing.expectEqual(@as(usize, 2), State.calls);
}

test "write open retries EINTR and succeeds" {
    const State = struct {
        var calls: usize = 0;

        fn fakeOpen(path: [*:0]const u8) usize {
            calls += 1;
            if (calls == 1) return testutil.failure(.INTR);
            return rawOpenWrite(path);
        }
    };

    var path_buf: [128]u8 = undefined;
    const path = try std.mem.printSentinel(&path_buf, "/tmp/platform-profile-daemon-test-open-write-eintr-{d}", .{testutil.pid()}, 0);
    defer testutil.unlink(path.ptr);

    const seed_fd = try testutil.createFile(path.ptr);
    defer testutil.close(seed_fd);
    try writeAll(seed_fd, "balanced\n");

    State.calls = 0;
    const fd = try openWriteWith(path, State.fakeOpen);
    defer testutil.close(fd);

    try writeAll(fd, "performance\n");
    try std.testing.expectEqual(@as(usize, 2), State.calls);
}
