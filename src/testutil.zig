//! Test-only raw-syscall helpers. Never imported by runtime code.
const std = @import("std");
const linux = std.os.linux;

/// Encodes an errno as a raw syscall failure return value.
pub fn failure(err: linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(err)));
}

/// Creates or truncates `path` for writing (mode 0600).
pub fn createFile(path: [*:0]const u8) !linux.fd_t {
    const rc = linux.openat(linux.AT.FDCWD, path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, 0o600);
    if (linux.errno(rc) != .SUCCESS) return error.CreateFailed;
    return @intCast(rc);
}

pub fn close(fd: linux.fd_t) void {
    _ = linux.close(fd);
}

pub fn unlink(path: [*:0]const u8) void {
    _ = linux.unlink(path);
}

pub fn pid() linux.pid_t {
    return linux.getpid();
}

/// Writes all of `bytes` with the real `write(2)` syscall.
pub fn writeBytes(fd: linux.fd_t, bytes: []const u8) !void {
    const rc = linux.write(fd, bytes.ptr, bytes.len);
    if (linux.errno(rc) != .SUCCESS or rc != bytes.len) return error.WriteFailed;
}

/// Creates a sealed-contents memfd, as used to force write/open failures.
pub fn memfd(name: [*:0]const u8) !linux.fd_t {
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
    return @intCast(rc);
}

pub fn addSeals(fd: linux.fd_t, seals: usize) bool {
    return linux.errno(linux.fcntl(fd, linux.F.ADD_SEALS, seals)) == .SUCCESS;
}
