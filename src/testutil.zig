//! Test-only helpers. Never imported by runtime code.
const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys.zig");

/// Encodes an errno as a raw syscall failure return value.
pub fn failure(err: linux.E) usize {
    return @bitCast(-@as(isize, @backingInt(err)));
}

/// Absolute, NUL-terminated path of `name` inside `dir` (`"."` for `dir` itself).
pub fn tmpPath(dir: std.Io.Dir, name: []const u8, buf: []u8) ![:0]const u8 {
    var root: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const n = try dir.realPath(std.testing.io, &root);
    return std.mem.printSentinel(buf, "{s}/{s}", .{ root[0..n], name }, 0);
}

/// Creates a sealable memfd, as used to force write/open failures.
pub fn memfd(name: [*:0]const u8) !linux.fd_t {
    const rc = linux.memfd_create(name, linux.MFD.CLOEXEC | linux.MFD.ALLOW_SEALING);
    if (linux.errno(rc) != .SUCCESS) return error.MemfdFailed;
    return @intCast(rc);
}

pub fn addSeals(fd: linux.fd_t, seals: usize) bool {
    return linux.errno(linux.fcntl(fd, linux.F.ADD_SEALS, seals)) == .SUCCESS;
}

/// A bound datagram socket standing in for systemd.
pub fn listenDgram(addr: sys.UnixAddress) !linux.fd_t {
    const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(rc));
    const fd: linux.fd_t = @intCast(rc);
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.bind(fd, @ptrCast(&addr.sa), addr.len)));
    return fd;
}

/// Expects the next datagram on `fd` to be `expected`, or none when null.
pub fn expectDatagram(fd: linux.fd_t, expected: ?[]const u8) !void {
    var buf: [64]u8 = undefined;
    const n = linux.recvfrom(fd, &buf, buf.len, linux.MSG.DONTWAIT, null, null);
    if (expected) |text| {
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(n));
        try std.testing.expectEqualStrings(text, buf[0..n]);
    } else {
        try std.testing.expectEqual(linux.E.AGAIN, linux.errno(n));
    }
}
