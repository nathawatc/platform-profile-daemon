//! Raw Linux syscall I/O shared by both executables.
//!
//! There is no libc and therefore no global `errno`: every failing call returns
//! `error.Sys` and stores the kernel errno through the `errno` out-parameter so
//! callers can map it to their own error names and log it. `EINTR` is retried,
//! short reads and writes are completed, and a write that makes no progress
//! fails with `errno == .SUCCESS`.
//!
//! The `*With` variants take the syscall as a comptime function so tests can
//! inject failures without any runtime indirection in release builds.
const std = @import("std");
const linux = std.os.linux;

pub const Error = error{Sys};

pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub fn open(dir: linux.fd_t, path: [*:0]const u8, flags: linux.O, errno: *linux.E) Error!linux.fd_t {
    return openWith(rawOpen, dir, path, flags, errno);
}

/// Reads from offset 0 until `buf` is full or EOF. Positional, so the same fd
/// can be read repeatedly without seeking.
pub fn readAll(fd: linux.fd_t, buf: []u8, errno: *linux.E) Error!usize {
    return readAllWith(rawPread, fd, buf, errno);
}

pub fn writeAll(fd: linux.fd_t, bytes: []const u8, errno: *linux.E) Error!void {
    return writeAllWith(rawWrite, fd, bytes, errno);
}

fn rawOpen(dir: linux.fd_t, path: [*:0]const u8, flags: linux.O) usize {
    return linux.openat(dir, path, flags, 0);
}

fn rawPread(fd: linux.fd_t, ptr: [*]u8, len: usize, offset: usize) usize {
    return linux.pread(fd, ptr, len, @intCast(offset));
}

fn rawWrite(fd: linux.fd_t, ptr: [*]const u8, len: usize) usize {
    return linux.write(fd, ptr, len);
}

fn openWith(comptime open_fn: anytype, dir: linux.fd_t, path: [*:0]const u8, flags: linux.O, errno: *linux.E) Error!linux.fd_t {
    while (true) {
        const rc = open_fn(dir, path, flags);
        switch (linux.errno(rc)) {
            .SUCCESS => return @intCast(rc),
            .INTR => {},
            else => |e| {
                errno.* = e;
                return error.Sys;
            },
        }
    }
}

fn readAllWith(comptime pread_fn: anytype, fd: linux.fd_t, buf: []u8, errno: *linux.E) Error!usize {
    var total: usize = 0;
    while (total < buf.len) {
        const rc = pread_fn(fd, buf[total..].ptr, buf.len - total, total);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                errno.* = e;
                return error.Sys;
            },
        }
        if (rc == 0) break;
        total += rc;
    }
    return total;
}

fn writeAllWith(comptime write_fn: anytype, fd: linux.fd_t, bytes: []const u8, errno: *linux.E) Error!void {
    var written: usize = 0;
    while (written < bytes.len) {
        const rc = write_fn(fd, bytes[written..].ptr, bytes.len - written);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR => continue,
            else => |e| {
                errno.* = e;
                return error.Sys;
            },
        }
        if (rc == 0) {
            errno.* = .SUCCESS;
            return error.Sys;
        }
        written += rc;
    }
}

const testutil = @import("testutil.zig");

test "open reports errno and retries EINTR" {
    const State = struct {
        var calls: usize = 0;
        fn eintrOnce(dir: linux.fd_t, path: [*:0]const u8, flags: linux.O) usize {
            calls += 1;
            if (calls == 1) return testutil.failure(.INTR);
            return rawOpen(dir, path, flags);
        }
        fn denied(_: linux.fd_t, _: [*:0]const u8, _: linux.O) usize {
            return testutil.failure(.ACCES);
        }
    };
    var errno: linux.E = .SUCCESS;
    const fd = try openWith(State.eintrOnce, linux.AT.FDCWD, "/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, &errno);
    close(fd);
    try std.testing.expectEqual(@as(usize, 2), State.calls);

    try std.testing.expectError(error.Sys, openWith(State.denied, linux.AT.FDCWD, "/x", .{}, &errno));
    try std.testing.expectEqual(linux.E.ACCES, errno);
    try std.testing.expectError(error.Sys, open(linux.AT.FDCWD, "/nonexistent/platform", .{}, &errno));
    try std.testing.expectEqual(linux.E.NOENT, errno);
}

test "readAll retries EINTR, completes short reads and reports errno" {
    const State = struct {
        var calls: usize = 0;
        const text = "performance\n";
        fn shortReads(_: linux.fd_t, ptr: [*]u8, len: usize, offset: usize) usize {
            calls += 1;
            if (calls == 1) return testutil.failure(.INTR);
            if (offset >= text.len) return 0;
            const n = @min(@min(len, text.len - offset), 3);
            @memcpy(ptr[0..n], text[offset..][0..n]);
            return n;
        }
        fn denied(_: linux.fd_t, _: [*]u8, _: usize, _: usize) usize {
            return testutil.failure(.ACCES);
        }
    };
    var errno: linux.E = .SUCCESS;
    var buf: [64]u8 = undefined;
    const n = try readAllWith(State.shortReads, -1, &buf, &errno);
    try std.testing.expectEqualStrings("performance\n", buf[0..n]);

    try std.testing.expectError(error.Sys, readAllWith(State.denied, -1, &buf, &errno));
    try std.testing.expectEqual(linux.E.ACCES, errno);
}

test "writeAll retries EINTR, completes short writes and reports errno" {
    const State = struct {
        var calls: usize = 0;
        var sink: [32]u8 = undefined;
        var len: usize = 0;
        fn flaky(_: linux.fd_t, ptr: [*]const u8, n: usize) usize {
            calls += 1;
            if (calls == 1) return testutil.failure(.INTR);
            const take = @min(n, 4);
            @memcpy(sink[len..][0..take], ptr[0..take]);
            len += take;
            return take;
        }
        fn denied(_: linux.fd_t, _: [*]const u8, _: usize) usize {
            return testutil.failure(.PERM);
        }
        fn stalled(_: linux.fd_t, _: [*]const u8, _: usize) usize {
            return 0;
        }
    };
    var errno: linux.E = .IO;
    try writeAllWith(State.flaky, -1, "balanced\n", &errno);
    try std.testing.expectEqualStrings("balanced\n", State.sink[0..State.len]);

    try std.testing.expectError(error.Sys, writeAllWith(State.denied, -1, "x", &errno));
    try std.testing.expectEqual(linux.E.PERM, errno);

    errno = .IO;
    try std.testing.expectError(error.Sys, writeAllWith(State.stalled, -1, "x", &errno));
    try std.testing.expectEqual(linux.E.SUCCESS, errno);
}

test "readAll and writeAll work on a real file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "f", .data = "" });
    const path = try testutil.tmpPath(tmp.dir, "f", &path_buf);

    var errno: linux.E = .SUCCESS;
    const wfd = try open(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, &errno);
    defer close(wfd);
    try writeAll(wfd, "low-power\n", &errno);

    const rfd = try open(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, &errno);
    defer close(rfd);
    var buf: [64]u8 = undefined;
    // Repeatable: positional reads do not consume the file.
    for (0..2) |_| try std.testing.expectEqualStrings("low-power\n", buf[0..try readAll(rfd, &buf, &errno)]);
}
