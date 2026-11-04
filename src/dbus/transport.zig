//! D-Bus byte transport: bus address parsing, the AF_UNIX connection, SASL
//! EXTERNAL authentication, and splitting the byte stream into whole messages.
//! Knows nothing about what the messages mean.
const std = @import("std");
const wire = @import("wire.zig");

const linux = std.os.linux;

pub const default_bus_address = "unix:path=/run/dbus/system_bus_socket";

const SockaddrUn = extern struct {
    family: u16 = linux.AF.UNIX,
    path: [108]u8 = @splat(0),
};

const Endpoint = struct {
    sa: SockaddrUn = .{},
    len: u32 = 0,
};

/// Accepts the first `unix:` entry of a bus address list that has a usable
/// `path=` or `abstract=` key.
fn parseAddress(bus_address: ?[]const u8) !Endpoint {
    var address: []const u8 = bus_address orelse default_bus_address;
    if (std.mem.findScalar(u8, address, ';')) |end| address = address[0..end];
    if (!std.mem.startsWith(u8, address, "unix:")) return error.UnsupportedBusAddress;

    var ep: Endpoint = .{};
    var params = std.mem.splitScalar(u8, address["unix:".len..], ',');
    while (params.next()) |param| {
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        const value = param[eq + 1 ..];
        if (value.len == 0 or value.len >= ep.sa.path.len) continue;
        if (wire.eql(key, "path")) {
            @memcpy(ep.sa.path[0..value.len], value);
            ep.len = @intCast(@sizeOf(u16) + value.len + 1);
            return ep;
        } else if (wire.eql(key, "abstract")) {
            @memcpy(ep.sa.path[1..][0..value.len], value);
            ep.len = @intCast(@sizeOf(u16) + 1 + value.len);
            return ep;
        }
    }
    return error.UnsupportedBusAddress;
}

/// `bus_address` is the value of `DBUS_SYSTEM_BUS_ADDRESS`, if set.
pub fn connect(bus_address: ?[]const u8) !linux.fd_t {
    const ep = try parseAddress(bus_address);
    const sock_rc = linux.socket(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.connect(fd, &ep.sa, ep.len)) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

pub const Transport = struct {
    fd: linux.fd_t,
    next_serial: u32 = 1,
    /// Raw bytes read from the socket.
    rbuf: [16384]u8 = undefined,
    rlen: usize = 0,
    /// Bytes of an oversized frame still to be discarded.
    skip: usize = 0,
    /// The frame most recently returned by `nextFrame`. A copy, so nested
    /// waits that read more data cannot invalidate it.
    cur: [16384]u8 = undefined,

    pub fn takeSerial(self: *Transport) u32 {
        const serial = self.next_serial;
        self.next_serial = if (serial == std.math.maxInt(u32)) 1 else serial + 1;
        return serial;
    }

    pub fn send(self: *Transport, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.sendto(self.fd, data[off..].ptr, data.len - off, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return error.SendFailed,
            }
        }
    }

    /// Reads whatever is available (one syscall). `error.Closed` on EOF.
    pub fn recv(self: *Transport) !void {
        const rc = linux.recvfrom(self.fd, self.rbuf[self.rlen..].ptr, self.rbuf.len - self.rlen, 0, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => return error.RecvFailed,
        }
        if (rc == 0) return error.Closed;
        self.rlen += rc;
    }

    fn consume(self: *Transport, n: usize) void {
        @memmove(self.rbuf[0 .. self.rlen - n], self.rbuf[n..self.rlen]);
        self.rlen -= n;
    }

    /// Removes and returns the next complete frame (valid until the next
    /// call), or null if more data is needed. Frames that cannot fit the
    /// buffer are discarded as they stream in.
    pub fn nextFrame(self: *Transport) error{Protocol}!?[]const u8 {
        while (true) {
            if (self.skip > 0) {
                const n = @min(self.skip, self.rlen);
                self.consume(n);
                self.skip -= n;
                if (self.skip > 0) return null;
            }
            if (self.rlen < wire.header_len) return null;
            const total = wire.frameLength(self.rbuf[0..wire.header_len]) orelse return error.Protocol;
            if (total > self.rbuf.len) {
                self.skip = total;
                continue;
            }
            if (total > self.rlen) return null;
            @memcpy(self.cur[0..total], self.rbuf[0..total]);
            self.consume(total);
            return self.cur[0..total];
        }
    }

    /// SASL EXTERNAL with our effective uid as hex-encoded decimal text.
    /// Leaves the connection ready for the first message.
    pub fn authenticate(self: *Transport) !void {
        var uid_text: [16]u8 = undefined;
        const uid = std.mem.print(&uid_text, "{d}", .{linux.geteuid()}) catch unreachable;
        var line: [64]u8 = undefined;
        var w: wire.Writer = .{ .buf = &line };
        try w.putRaw("\x00AUTH EXTERNAL ");
        const hex = "0123456789abcdef";
        for (uid) |c| try w.putRaw(&.{ hex[c >> 4], hex[c & 0xf] });
        try w.putRaw("\r\n");
        try self.send(w.bytes());

        const line_len = while (true) {
            if (std.mem.find(u8, self.rbuf[0..self.rlen], "\r\n")) |end| break end + 2;
            if (self.rlen == self.rbuf.len) return error.AuthFailed;
            try self.recv();
        };
        const accepted = std.mem.startsWith(u8, self.rbuf[0..line_len], "OK ");
        // Only the reply line is ours; anything after it is already message data.
        self.consume(line_len);
        if (!accepted) return error.AuthFailed;
        try self.send("BEGIN\r\n");
    }
};

test "bus address parsing" {
    const ep = try parseAddress(null);
    try std.testing.expectEqualStrings("/run/dbus/system_bus_socket", ep.sa.path[0 .. ep.len - @sizeOf(u16) - 1]);

    const abs = try parseAddress("unix:guid=abc,abstract=/tmp/dbus-x;unix:path=/ignored");
    try std.testing.expectEqual(@as(u8, 0), abs.sa.path[0]);
    try std.testing.expectEqualStrings("/tmp/dbus-x", abs.sa.path[1 .. abs.len - @sizeOf(u16)]);

    const skipped = try parseAddress("unix:path=,foo,path=/run/real,abstract=/other");
    try std.testing.expectEqualStrings("/run/real", skipped.sa.path[0 .. skipped.len - @sizeOf(u16) - 1]);

    try std.testing.expectError(error.UnsupportedBusAddress, parseAddress("tcp:host=localhost,port=1"));
    try std.testing.expectError(error.UnsupportedBusAddress, parseAddress("unix:guid=abc"));
    try std.testing.expectError(error.UnsupportedBusAddress, parseAddress(""));
}

fn socketPair() ![2]linux.fd_t {
    var sv: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv)));
    return sv;
}

fn putCall(buf: []u8, member: []const u8, padding: []const u8) !wire.Writer {
    var w: wire.Writer = .{ .buf = buf };
    try w.beginCall(1, "d", "/p", "i", member, "", "");
    try w.putRaw(padding);
    w.finish();
    return w;
}

test "frames are split, copied and consumed in order" {
    const sv = try socketPair();
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);
    var t: Transport = .{ .fd = sv[0] };

    var a_buf: [256]u8 = undefined;
    const a = try putCall(&a_buf, "First", "");
    var b_buf: [256]u8 = undefined;
    const b = try putCall(&b_buf, "Second", "");
    var both: [512]u8 = undefined;
    @memcpy(both[0..a.len], a.bytes());
    @memcpy(both[a.len..][0..b.len], b.bytes());
    const total = a.len + b.len;

    // Deliver in two pieces, cutting the second frame in half.
    const cut = a.len + b.len / 2;
    try std.testing.expectEqual(cut, linux.sendto(sv[1], &both, cut, 0, null, 0));
    try t.recv();
    try std.testing.expectEqualStrings("First", wire.parseMessage((try t.nextFrame()).?).?.member);
    try std.testing.expectEqual(@as(?[]const u8, null), try t.nextFrame());

    try std.testing.expectEqual(total - cut, linux.sendto(sv[1], both[cut..].ptr, total - cut, 0, null, 0));
    try t.recv();
    try std.testing.expectEqualStrings("Second", wire.parseMessage((try t.nextFrame()).?).?.member);
    try std.testing.expectEqual(@as(?[]const u8, null), try t.nextFrame());
    try std.testing.expectEqual(@as(usize, 0), t.rlen);
}

test "oversized frames are discarded without losing the next frame" {
    const sv = try socketPair();
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);
    var t: Transport = .{ .fd = sv[0] };

    var big_buf: [40000]u8 = undefined;
    const zeros: [30000]u8 = @splat(0);
    const big = try putCall(&big_buf, "Big", &zeros);
    var small_buf: [256]u8 = undefined;
    const small = try putCall(&small_buf, "Small", "");

    const sent_big = linux.sendto(sv[1], big.bytes().ptr, big.len, 0, null, 0);
    try std.testing.expectEqual(big.len, sent_big);
    try std.testing.expectEqual(small.len, linux.sendto(sv[1], small.bytes().ptr, small.len, 0, null, 0));

    var found: ?wire.Message = null;
    for (0..8) |_| {
        try t.recv();
        if (try t.nextFrame()) |frame| {
            found = wire.parseMessage(frame);
            break;
        }
    }
    try std.testing.expectEqualStrings("Small", found.?.member);
}

test "an unusable header is a protocol error" {
    const sv = try socketPair();
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);
    var t: Transport = .{ .fd = sv[0] };
    const junk: [wire.header_len]u8 = @splat('x');
    _ = linux.sendto(sv[1], &junk, junk.len, 0, null, 0);
    try t.recv();
    try std.testing.expectError(error.Protocol, t.nextFrame());
}

test "serials wrap past zero" {
    var t: Transport = .{ .fd = -1, .next_serial = std.math.maxInt(u32) };
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), t.takeSerial());
    try std.testing.expectEqual(@as(u32, 1), t.takeSerial());
}

test "authenticate sends EXTERNAL with the hex uid and keeps bytes after OK" {
    const sv = try socketPair();
    defer _ = linux.close(sv[0]);
    defer _ = linux.close(sv[1]);
    var t: Transport = .{ .fd = sv[0] };

    const reply = "OK 0123456789abcdef\r\nxyz";
    try std.testing.expectEqual(reply.len, linux.sendto(sv[1], reply, reply.len, 0, null, 0));
    try t.authenticate();
    try std.testing.expectEqualStrings("xyz", t.rbuf[0..t.rlen]);

    var uid_text: [16]u8 = undefined;
    const uid = try std.mem.print(&uid_text, "{d}", .{linux.geteuid()});
    var expected: [64]u8 = undefined;
    var w: wire.Writer = .{ .buf = &expected };
    try w.putRaw("\x00AUTH EXTERNAL ");
    for (uid) |c| try w.putRaw(&.{ "0123456789abcdef"[c >> 4], "0123456789abcdef"[c & 0xf] });
    try w.putRaw("\r\nBEGIN\r\n");
    var got: [64]u8 = undefined;
    const n = linux.recvfrom(sv[1], &got, got.len, 0, null, null);
    try std.testing.expectEqualStrings(w.bytes(), got[0..n]);
}

test "authenticate rejects anything but OK" {
    for ([_][]const u8{ "REJECTED EXTERNAL\r\n", "DATA\r\n", "ERROR\r\n" }) |reply| {
        const sv = try socketPair();
        defer _ = linux.close(sv[0]);
        defer _ = linux.close(sv[1]);
        var t: Transport = .{ .fd = sv[0] };
        try std.testing.expectEqual(reply.len, linux.sendto(sv[1], reply.ptr, reply.len, 0, null, 0));
        try std.testing.expectError(error.AuthFailed, t.authenticate());
    }
}
