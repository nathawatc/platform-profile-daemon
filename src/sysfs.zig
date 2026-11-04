//! The one sysfs file the daemon touches: `platform_profile`.
//!
//! The file is held open read-only for the daemon's lifetime. A read arms the
//! kernel's `sysfs_notify` event, so the fd can be polled for `POLLPRI`.
const std = @import("std");
const profile = @import("profile.zig");
const sys = @import("sys.zig");
const testutil = @import("testutil.zig");

const linux = std.os.linux;

pub const IoError = error{ UnsupportedPlatform, PermissionDenied, ReadFailed, WriteFailed };
pub const Error = IoError || profile.ParseError;

pub const Sysfs = struct {
    path: [:0]const u8,
    /// Open for the whole process lifetime; poll it for `POLLPRI | POLLERR`.
    fd: linux.fd_t,

    /// Opens the file. Callers read once afterwards, which also arms polling.
    pub fn open(path: [:0]const u8) IoError!Sysfs {
        var errno: linux.E = .SUCCESS;
        const fd = sys.open(linux.AT.FDCWD, path, .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, &errno) catch
            return fail(errno, error.ReadFailed, true);
        return .{ .path = path, .fd = fd };
    }

    pub fn close(self: Sysfs) void {
        sys.close(self.fd);
    }

    /// Reads the current profile through the held fd (re-arming its poll event).
    pub fn read(self: Sysfs) Error!profile.Profile {
        return readFd(self.fd);
    }

    /// Reads the current profile through a fresh open. Used by explicit
    /// requests so they never depend on, or consume, the watch fd's state.
    pub fn readFresh(self: Sysfs) Error!profile.Profile {
        const reader = try open(self.path);
        defer reader.close();
        return reader.read();
    }

    pub fn write(self: Sysfs, value: profile.Profile) IoError!void {
        var errno: linux.E = .SUCCESS;
        const fd = sys.open(linux.AT.FDCWD, self.path, .{ .ACCMODE = .WRONLY, .TRUNC = true, .CLOEXEC = true }, &errno) catch
            return fail(errno, error.WriteFailed, true);
        defer sys.close(fd);
        sys.writeAll(fd, value.kernelLine(), &errno) catch return fail(errno, error.WriteFailed, false);
    }
};

fn readFd(fd: linux.fd_t) Error!profile.Profile {
    var buf: [64]u8 = undefined;
    var errno: linux.E = .SUCCESS;
    const n = sys.readAll(fd, &buf, &errno) catch return fail(errno, error.ReadFailed, false);
    return profile.Profile.parseKernel(buf[0..n]);
}

/// Maps a failing errno to a semantic error. A missing path only means an
/// unsupported platform while opening.
fn fail(errno: linux.E, comptime fallback: IoError, opening: bool) IoError {
    return switch (errno) {
        .NOENT, .NOTDIR => if (opening) error.UnsupportedPlatform else fallback,
        .ACCES, .PERM => error.PermissionDenied,
        else => fallback,
    };
}

test "errno mapping preserves semantic errors" {
    try std.testing.expectEqual(error.UnsupportedPlatform, fail(.NOENT, error.ReadFailed, true));
    try std.testing.expectEqual(error.UnsupportedPlatform, fail(.NOTDIR, error.WriteFailed, true));
    try std.testing.expectEqual(error.WriteFailed, fail(.NOENT, error.WriteFailed, false));
    try std.testing.expectEqual(error.PermissionDenied, fail(.ACCES, error.ReadFailed, true));
    try std.testing.expectEqual(error.PermissionDenied, fail(.PERM, error.WriteFailed, false));
    try std.testing.expectEqual(error.ReadFailed, fail(.IO, error.ReadFailed, true));
    try std.testing.expectEqual(error.WriteFailed, fail(.IO, error.WriteFailed, false));
}

test "open maps a missing file to UnsupportedPlatform" {
    try std.testing.expectError(error.UnsupportedPlatform, Sysfs.open("/nonexistent/platform_profile"));
}

test "read, readFresh and write round trip" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "balanced\n" });
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sysfs = try Sysfs.open(try testutil.tmpPath(tmp.dir, "p", &buf));
    defer sysfs.close();

    try std.testing.expectEqual(profile.Profile.balanced, try sysfs.read());
    try sysfs.write(.performance);
    try std.testing.expectEqual(profile.Profile.performance, try sysfs.read());
    try std.testing.expectEqual(profile.Profile.performance, try sysfs.readFresh());
    try sysfs.write(.power_saver);
    try std.testing.expectEqual(profile.Profile.power_saver, try sysfs.readFresh());
}

test "read reports custom, malformed and empty content strictly" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "" });
    const sysfs = try Sysfs.open(try testutil.tmpPath(tmp.dir, "p", &buf));
    defer sysfs.close();

    try std.testing.expectError(error.Unknown, sysfs.read());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "custom\n" });
    try std.testing.expectError(error.Custom, sysfs.read());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "quiet\n" });
    try std.testing.expectError(error.Unknown, sysfs.read());
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "balanced \n" });
    try std.testing.expectError(error.Unknown, sysfs.read());
}

test "read failure maps to ReadFailed" {
    const sysfs = try Sysfs.open("/");
    defer sysfs.close();
    try std.testing.expectError(error.ReadFailed, sysfs.read());
}

test "write failure maps errno" {
    // A directory cannot be opened for writing.
    const dir: Sysfs = .{ .path = "/", .fd = -1 };
    try std.testing.expectError(error.WriteFailed, dir.write(.balanced));
    const missing: Sysfs = .{ .path = "/nonexistent/platform_profile", .fd = -1 };
    try std.testing.expectError(error.UnsupportedPlatform, missing.write(.balanced));
}
