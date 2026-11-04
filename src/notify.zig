//! The two `sd_notify(3)` messages the service needs, without libsystemd:
//! `READY=1` once the bus name is owned, and `WATCHDOG=1` pings so systemd
//! restarts a daemon whose service loop has hung.
//!
//! Everything is best effort and a no-op when `NOTIFY_SOCKET` is unset, so
//! running the binary by hand behaves as before.
const std = @import("std");
const sys = @import("sys.zig");

const linux = std.os.linux;

pub const Notifier = struct {
    fd: linux.fd_t = -1,
    addr: sys.UnixAddress = .{},
    /// Time between pings (half of `WatchdogSec=`); 0 means no watchdog.
    interval_ms: i64 = 0,
    next_ping_ms: i64 = 0,

    /// `notify_socket` is `$NOTIFY_SOCKET` (a path, or `@name` for an abstract
    /// socket), `watchdog_usec` is `$WATCHDOG_USEC` and `watchdog_pid` is
    /// `$WATCHDOG_PID`. Anything unusable yields an inactive notifier; a
    /// watchdog meant for another process is ignored (sd_watchdog_enabled(3)).
    pub fn init(notify_socket: ?[]const u8, watchdog_usec: ?[]const u8, watchdog_pid: ?[]const u8) Notifier {
        var n: Notifier = .{};
        const target = notify_socket orelse return n;
        n.addr = (if (std.mem.startsWith(u8, target, "@"))
            sys.UnixAddress.abstract(target[1..])
        else if (std.mem.startsWith(u8, target, "/"))
            sys.UnixAddress.path(target)
        else
            null) orelse return .{};

        const rc = linux.socket(linux.AF.UNIX, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
        if (linux.errno(rc) != .SUCCESS) return .{};
        n.fd = @intCast(rc);

        if (watchdog_pid) |text| {
            const pid = std.fmt.parseUnsigned(linux.pid_t, text, 10) catch return n;
            if (pid != linux.getpid()) return n;
        }
        if (watchdog_usec) |text| {
            if (std.fmt.parseUnsigned(u64, text, 10)) |usec| {
                n.interval_ms = @intCast(@min(usec / 2000, std.math.maxInt(i32)));
            } else |_| {}
        }
        return n;
    }

    pub fn deinit(self: *Notifier) void {
        if (self.fd >= 0) sys.close(self.fd);
        self.fd = -1;
    }

    /// The service is up (the bus name is owned).
    pub fn ready(self: *const Notifier) void {
        self.send("READY=1");
    }

    /// Pings the watchdog if one is due at `now_ms`.
    pub fn ping(self: *Notifier, now_ms: i64) void {
        if (self.interval_ms == 0 or now_ms < self.next_ping_ms) return;
        self.send("WATCHDOG=1");
        self.next_ping_ms = now_ms + self.interval_ms;
    }

    /// Milliseconds until the next ping is due, or -1 without a watchdog.
    pub fn nextPingMs(self: *const Notifier, now_ms: i64) i32 {
        if (self.interval_ms == 0) return -1;
        return @intCast(std.math.clamp(self.next_ping_ms - now_ms, 0, std.math.maxInt(i32)));
    }

    fn send(self: *const Notifier, message: []const u8) void {
        if (self.fd < 0) return;
        _ = linux.sendto(self.fd, message.ptr, message.len, linux.MSG.NOSIGNAL, @ptrCast(&self.addr.sa), self.addr.len);
    }
};

const testutil = @import("testutil.zig");

const listen = testutil.listenDgram;
const expectMessage = testutil.expectDatagram;

test "an abstract socket receives READY=1" {
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "ppd-notify-test-{d}", .{linux.getpid()});
    const server = try listen(sys.UnixAddress.abstract(name).?);
    defer sys.close(server);

    var target_buf: [64]u8 = undefined;
    var n = Notifier.init(try std.mem.print(&target_buf, "@{s}", .{name}), null, null);
    defer n.deinit();
    n.ready();
    try expectMessage(server, "READY=1");
    try expectMessage(server, null);
}

test "a filesystem socket receives READY=1" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testutil.tmpPath(tmp.dir, "notify", &buf);
    const addr = sys.UnixAddress.path(path) orelse return error.SkipZigTest; // path too long for sockaddr_un
    const server = try listen(addr);
    defer sys.close(server);

    var n = Notifier.init(path, null, null);
    defer n.deinit();
    n.ready();
    try expectMessage(server, "READY=1");
}

test "the watchdog pings at half the configured period" {
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "ppd-notify-wd-{d}", .{linux.getpid()});
    const server = try listen(sys.UnixAddress.abstract(name).?);
    defer sys.close(server);
    var target_buf: [64]u8 = undefined;
    // WatchdogSec=30s arrives as 30000000 microseconds.
    var n = Notifier.init(try std.mem.print(&target_buf, "@{s}", .{name}), "30000000", null);
    defer n.deinit();
    try std.testing.expectEqual(@as(i64, 15_000), n.interval_ms);

    try std.testing.expectEqual(@as(i32, 0), n.nextPingMs(1_000)); // first ping is due at once
    n.ping(1_000);
    try expectMessage(server, "WATCHDOG=1");
    try std.testing.expectEqual(@as(i32, 15_000), n.nextPingMs(1_000));
    n.ping(10_000);
    try expectMessage(server, null);
    try std.testing.expectEqual(@as(i32, 6_000), n.nextPingMs(10_000));
    n.ping(16_000);
    try expectMessage(server, "WATCHDOG=1");
}

test "without NOTIFY_SOCKET or with junk everything is a no-op" {
    var too_long: [200]u8 = @splat('x');
    too_long[0] = '/';
    for ([_]?[]const u8{ null, "", "relative/path", "@", &too_long }) |target| {
        var n = Notifier.init(target, "30000000", null);
        defer n.deinit();
        try std.testing.expectEqual(@as(i32, -1), n.nextPingMs(0));
        n.ready();
        n.ping(1);
        try std.testing.expectEqual(@as(linux.fd_t, -1), n.fd);
    }
    var no_watchdog = Notifier.init(null, null, null);
    try std.testing.expectEqual(@as(i32, -1), no_watchdog.nextPingMs(5));
}

test "a malformed WATCHDOG_USEC disables the watchdog only" {
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "ppd-notify-bad-{d}", .{linux.getpid()});
    const server = try listen(sys.UnixAddress.abstract(name).?);
    defer sys.close(server);
    var target_buf: [64]u8 = undefined;
    var n = Notifier.init(try std.mem.print(&target_buf, "@{s}", .{name}), "soon", null);
    defer n.deinit();
    try std.testing.expectEqual(@as(i64, 0), n.interval_ms);
    n.ready();
    try expectMessage(server, "READY=1");
}

test "WATCHDOG_PID must name this process" {
    var name_buf: [64]u8 = undefined;
    const name = try std.mem.print(&name_buf, "ppd-notify-pid-{d}", .{linux.getpid()});
    const server = try listen(sys.UnixAddress.abstract(name).?);
    defer sys.close(server);
    var target_buf: [64]u8 = undefined;
    const target = try std.mem.print(&target_buf, "@{s}", .{name});
    var pid_buf: [16]u8 = undefined;
    const own = try std.mem.print(&pid_buf, "{d}", .{linux.getpid()});

    var mine = Notifier.init(target, "30000000", own);
    defer mine.deinit();
    try std.testing.expectEqual(@as(i64, 15_000), mine.interval_ms);

    // Someone else's or malformed: no watchdog, but READY still works.
    for ([_][]const u8{ "1", "", "x", "-5" }) |other| {
        var n = Notifier.init(target, "30000000", other);
        defer n.deinit();
        try std.testing.expectEqual(@as(i64, 0), n.interval_ms);
        n.ready();
        try expectMessage(server, "READY=1");
    }
}
