//! Minimal native D-Bus service for org.freedesktop.UPower.PowerProfiles.
//!
//! Speaks the D-Bus wire protocol directly over an AF_UNIX socket (EXTERNAL
//! auth, little-endian only) and implements just the surface listed in
//! AGENTS.md: Properties Get/GetAll/Set, Introspect, Peer.Ping, the
//! PropertiesChanged signal, and a synchronous Polkit CheckAuthorization call.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const daemon_mod = @import("daemon.zig");
const profile_mod = @import("profile.zig");

comptime {
    if (builtin.target.cpu.arch.endian() != .little) @compileError("dbus.zig assumes a little-endian host");
}

const bus_name = "org.freedesktop.UPower.PowerProfiles";
const object_path = "/org/freedesktop/UPower/PowerProfiles";
const interface = "org.freedesktop.UPower.PowerProfiles";
const iface_properties = "org.freedesktop.DBus.Properties";
const iface_introspectable = "org.freedesktop.DBus.Introspectable";
const iface_peer = "org.freedesktop.DBus.Peer";

const polkit_service = "org.freedesktop.PolicyKit1";
const polkit_path = "/org/freedesktop/PolicyKit1/Authority";
const polkit_interface = "org.freedesktop.PolicyKit1.Authority";
const polkit_action = "net.hadess.PowerProfiles.switch-profile";
const polkit_allow_user_interaction: u32 = 1;
const call_timeout_ms: i64 = 25_000;

const default_bus_address = "unix:path=/run/dbus/system_bus_socket";

const err_failed = "org.freedesktop.DBus.Error.Failed";
const err_not_supported = "org.freedesktop.DBus.Error.NotSupported";
const err_access_denied = "org.freedesktop.DBus.Error.AccessDenied";
const err_invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";
const err_unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
const err_unknown_object = "org.freedesktop.DBus.Error.UnknownObject";
const err_unknown_interface = "org.freedesktop.DBus.Error.UnknownInterface";
const err_unknown_property = "org.freedesktop.DBus.Error.UnknownProperty";
const err_read_only = "org.freedesktop.DBus.Error.PropertyReadOnly";

const msg_method_call: u8 = 1;
const msg_method_return: u8 = 2;
const msg_error: u8 = 3;
const msg_signal: u8 = 4;
const flag_no_reply_expected: u8 = 0x1;

const field_path: u8 = 1;
const field_interface: u8 = 2;
const field_member: u8 = 3;
const field_error_name: u8 = 4;
const field_reply_serial: u8 = 5;
const field_destination: u8 = 6;
const field_sender: u8 = 7;
const field_signature: u8 = 8;

const header_len = 16;
const max_message_len: u64 = 1 << 27;

const linux = std.os.linux;

const AF_UNIX = linux.AF.UNIX;
const SOCK_STREAM = linux.SOCK.STREAM;
const SOCK_CLOEXEC = linux.SOCK.CLOEXEC;
const MSG_NOSIGNAL = linux.MSG.NOSIGNAL;
const POLLIN: i16 = linux.POLL.IN;
const POLLPRI: i16 = linux.POLL.PRI;
const POLLERR: i16 = linux.POLL.ERR;
const POLLHUP: i16 = linux.POLL.HUP;
const POLLNVAL: i16 = linux.POLL.NVAL;

const SockaddrUn = extern struct {
    family: u16 = AF_UNIX,
    path: [108]u8 = @splat(0),
};

const introspection_xml =
    \\<!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
    \\ "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
    \\<node>
    \\ <interface name="org.freedesktop.DBus.Peer">
    \\  <method name="Ping"/>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Introspectable">
    \\  <method name="Introspect">
    \\   <arg type="s" direction="out"/>
    \\  </method>
    \\ </interface>
    \\ <interface name="org.freedesktop.DBus.Properties">
    \\  <method name="Get">
    \\   <arg type="s" direction="in"/>
    \\   <arg type="s" direction="in"/>
    \\   <arg type="v" direction="out"/>
    \\  </method>
    \\  <method name="GetAll">
    \\   <arg type="s" direction="in"/>
    \\   <arg type="a{sv}" direction="out"/>
    \\  </method>
    \\  <method name="Set">
    \\   <arg type="s" direction="in"/>
    \\   <arg type="s" direction="in"/>
    \\   <arg type="v" direction="in"/>
    \\  </method>
    \\  <signal name="PropertiesChanged">
    \\   <arg type="s"/>
    \\   <arg type="a{sv}"/>
    \\   <arg type="as"/>
    \\  </signal>
    \\ </interface>
    \\ <interface name="org.freedesktop.UPower.PowerProfiles">
    \\  <property name="ActiveProfile" type="s" access="readwrite">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="true"/>
    \\  </property>
    \\  <property name="PerformanceDegraded" type="s" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\  <property name="Profiles" type="aa{sv}" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\  <property name="Actions" type="as" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\  <property name="ActionsInfo" type="aa{sv}" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\  <property name="ActiveProfileHolds" type="aa{sv}" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\  <property name="Version" type="s" access="read">
    \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
    \\  </property>
    \\ </interface>
    \\</node>
    \\
;

const Prop = enum {
    active_profile,
    performance_degraded,
    profiles,
    actions,
    actions_info,
    active_profile_holds,
    version,
};

const prop_table = [_]struct { name: []const u8, prop: Prop }{
    .{ .name = "ActiveProfile", .prop = .active_profile },
    .{ .name = "PerformanceDegraded", .prop = .performance_degraded },
    .{ .name = "Profiles", .prop = .profiles },
    .{ .name = "Actions", .prop = .actions },
    .{ .name = "ActionsInfo", .prop = .actions_info },
    .{ .name = "ActiveProfileHolds", .prop = .active_profile_holds },
    .{ .name = "Version", .prop = .version },
};

fn lookupProp(name: []const u8) ?Prop {
    for (prop_table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.prop;
    }
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Longest prefix of `s` that is at most `max` bytes and does not split a UTF-8 sequence.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

// ---------------------------------------------------------------------------
// Wire encoding
// ---------------------------------------------------------------------------

const Writer = struct {
    buf: []u8,
    len: usize = 0,
    body_start: usize = 0,

    fn bytes(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }

    fn alignTo(w: *Writer, n: usize) !void {
        const aligned = std.mem.alignForward(usize, w.len, n);
        if (aligned > w.buf.len) return error.NoSpace;
        @memset(w.buf[w.len..aligned], 0);
        w.len = aligned;
    }

    fn putRaw(w: *Writer, data: []const u8) !void {
        if (w.len + data.len > w.buf.len) return error.NoSpace;
        @memcpy(w.buf[w.len..][0..data.len], data);
        w.len += data.len;
    }

    fn putU8(w: *Writer, v: u8) !void {
        try w.putRaw(&.{v});
    }

    fn putU32(w: *Writer, v: u32) !void {
        try w.alignTo(4);
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try w.putRaw(&tmp);
    }

    /// STRING and OBJECT_PATH.
    fn putStr(w: *Writer, s: []const u8) !void {
        try w.putU32(@intCast(s.len));
        try w.putRaw(s);
        try w.putU8(0);
    }

    fn putSig(w: *Writer, s: []const u8) !void {
        try w.putU8(@intCast(s.len));
        try w.putRaw(s);
        try w.putU8(0);
    }

    fn patchU32(w: *Writer, offset: usize, v: u32) void {
        std.mem.writeInt(u32, w.buf[offset..][0..4], v, .little);
    }

    fn beginArray(w: *Writer, elem_align: usize) !usize {
        try w.putU32(0);
        const pos = w.len - 4;
        try w.alignTo(elem_align);
        return pos;
    }

    fn endArray(w: *Writer, pos: usize, elem_align: usize) void {
        const data_start = std.mem.alignForward(usize, pos + 4, elem_align);
        w.patchU32(pos, @intCast(w.len - data_start));
    }

    fn beginMessage(w: *Writer, kind: u8, flags: u8, serial: u32) !void {
        try w.putRaw(&.{ 'l', kind, flags, 1 });
        try w.putU32(0); // body length, patched by finish()
        try w.putU32(serial);
        try w.putU32(0); // header fields length, patched by endFields()
    }

    fn fieldStr(w: *Writer, code: u8, typ: u8, s: []const u8) !void {
        try w.alignTo(8);
        try w.putRaw(&.{ code, 1, typ, 0 });
        if (typ == 'g') try w.putSig(s) else try w.putStr(s);
    }

    fn fieldU32(w: *Writer, code: u8, v: u32) !void {
        try w.alignTo(8);
        try w.putRaw(&.{ code, 1, 'u', 0 });
        try w.putU32(v);
    }

    fn endFields(w: *Writer) !void {
        w.patchU32(12, @intCast(w.len - header_len));
        try w.alignTo(8);
        w.body_start = w.len;
    }

    fn finish(w: *Writer) void {
        w.patchU32(4, @intCast(w.len - w.body_start));
    }

    fn beginCall(
        w: *Writer,
        serial: u32,
        dest: []const u8,
        path: []const u8,
        iface: []const u8,
        member: []const u8,
        sig: []const u8,
        sender: []const u8,
    ) !void {
        try w.beginMessage(msg_method_call, 0, serial);
        try w.fieldStr(field_path, 'o', path);
        try w.fieldStr(field_interface, 's', iface);
        try w.fieldStr(field_destination, 's', dest);
        try w.fieldStr(field_member, 's', member);
        if (sig.len > 0) try w.fieldStr(field_signature, 'g', sig);
        if (sender.len > 0) try w.fieldStr(field_sender, 's', sender);
        try w.endFields();
    }
};

// ---------------------------------------------------------------------------
// Wire decoding
// ---------------------------------------------------------------------------

const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn alignTo(r: *Reader, n: usize) !void {
        const aligned = std.mem.alignForward(usize, r.pos, n);
        if (aligned > r.buf.len) return error.Malformed;
        r.pos = aligned;
    }

    fn getU8(r: *Reader) !u8 {
        if (r.pos >= r.buf.len) return error.Malformed;
        defer r.pos += 1;
        return r.buf[r.pos];
    }

    fn getU32(r: *Reader) !u32 {
        try r.alignTo(4);
        if (r.pos + 4 > r.buf.len) return error.Malformed;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
    }

    fn getStr(r: *Reader) ![]const u8 {
        const len = try r.getU32();
        if (@as(u64, r.pos) + len + 1 > r.buf.len) return error.Malformed;
        const s = r.buf[r.pos..][0..len];
        if (r.buf[r.pos + len] != 0) return error.Malformed;
        r.pos += len + 1;
        return s;
    }

    fn getSig(r: *Reader) ![]const u8 {
        const len = try r.getU8();
        if (r.pos + len + 1 > r.buf.len) return error.Malformed;
        const s = r.buf[r.pos..][0..len];
        if (r.buf[r.pos + len] != 0) return error.Malformed;
        r.pos += @as(usize, len) + 1;
        return s;
    }
};

const Message = struct {
    kind: u8,
    flags: u8,
    serial: u32,
    reply_serial: u32 = 0,
    path: []const u8 = "",
    iface: []const u8 = "",
    member: []const u8 = "",
    sender: []const u8 = "",
    sig: []const u8 = "",
    err_name: []const u8 = "",
    body: []const u8 = "",
};

/// Total length of the message that starts with `h`, or null if the header is unusable.
fn frameLength(h: *const [header_len]u8) ?usize {
    const endian: std.lang.Endian = switch (h[0]) {
        'l' => .little,
        'B' => .big,
        else => return null,
    };
    const body_len: u64 = std.mem.readInt(u32, h[4..8], endian);
    const fields_len: u64 = std.mem.readInt(u32, h[12..16], endian);
    const total = header_len + std.mem.alignForward(u64, fields_len, 8) + body_len;
    if (total > max_message_len) return null;
    return @intCast(total);
}

/// Parses exactly one complete little-endian message. Returns null if malformed.
fn parseMessage(buf: []const u8) ?Message {
    if (buf.len < header_len or buf[0] != 'l' or buf[3] != 1) return null;
    const body_len = std.mem.readInt(u32, buf[4..8], .little);
    const fields_len = std.mem.readInt(u32, buf[12..16], .little);
    const body_start = std.mem.alignForward(u64, @as(u64, header_len) + fields_len, 8);
    if (body_start + body_len != buf.len) return null;

    var m: Message = .{
        .kind = buf[1],
        .flags = buf[2],
        .serial = std.mem.readInt(u32, buf[8..12], .little),
        .body = buf[@intCast(body_start)..],
    };
    if (m.serial == 0) return null;

    var r: Reader = .{ .buf = buf[0 .. header_len + fields_len], .pos = header_len };
    while (r.pos < r.buf.len) {
        r.alignTo(8) catch return null;
        const code = r.getU8() catch return null;
        const vsig = r.getSig() catch return null;
        if (vsig.len != 1) return null;
        switch (vsig[0]) {
            's', 'o' => {
                const s = r.getStr() catch return null;
                switch (code) {
                    field_path => m.path = s,
                    field_interface => m.iface = s,
                    field_member => m.member = s,
                    field_sender => m.sender = s,
                    field_error_name => m.err_name = s,
                    else => {},
                }
            },
            'g' => {
                const s = r.getSig() catch return null;
                if (code == field_signature) m.sig = s;
            },
            'u' => {
                const v = r.getU32() catch return null;
                if (code == field_reply_serial) m.reply_serial = v;
            },
            else => return null,
        }
    }
    return m;
}

// ---------------------------------------------------------------------------
// Connection
// ---------------------------------------------------------------------------

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    // Raw syscall: only called while awaiting Polkit, so skip std's vDSO lookup code.
    _ = linux.syscall2(.clock_gettime, @backingInt(linux.clockid_t.MONOTONIC), @intFromPtr(&ts));
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// `bus_address` is the value of `DBUS_SYSTEM_BUS_ADDRESS`, if set.
fn connectBus(bus_address: ?[]const u8) !linux.fd_t {
    var address: []const u8 = bus_address orelse default_bus_address;
    if (std.mem.findScalar(u8, address, ';')) |end| address = address[0..end];
    if (!std.mem.startsWith(u8, address, "unix:")) return error.UnsupportedBusAddress;

    var sa: SockaddrUn = .{};
    var addr_len: usize = 0;
    var params = std.mem.splitScalar(u8, address["unix:".len..], ',');
    while (params.next()) |param| {
        const eq = std.mem.findScalar(u8, param, '=') orelse continue;
        const key = param[0..eq];
        const value = param[eq + 1 ..];
        if (value.len == 0 or value.len >= sa.path.len) continue;
        if (eql(key, "path")) {
            @memcpy(sa.path[0..value.len], value);
            addr_len = @sizeOf(u16) + value.len + 1;
            break;
        } else if (eql(key, "abstract")) {
            @memcpy(sa.path[1..][0..value.len], value);
            addr_len = @sizeOf(u16) + 1 + value.len;
            break;
        }
    }
    if (addr_len == 0) return error.UnsupportedBusAddress;

    const sock_rc = linux.socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (linux.errno(sock_rc) != .SUCCESS) return error.SocketFailed;
    const fd: linux.fd_t = @intCast(sock_rc);
    errdefer _ = linux.close(fd);
    if (linux.errno(linux.connect(fd, &sa, @intCast(addr_len))) != .SUCCESS) return error.ConnectFailed;
    return fd;
}

/// Explicit because message dispatch and Polkit waiting call each other.
const ServeError = error{ NoSpace, SendFailed, RecvFailed, Closed, PollFailed, Protocol, Timeout };

const Bus = struct {
    fd: linux.fd_t,
    daemon: *daemon_mod.Daemon,
    next_serial: u32 = 1,
    /// Raw bytes read from the socket. Complete frames are copied to `cur`
    /// and consumed before dispatch, so nested waits cannot invalidate them.
    rbuf: [16384]u8 = undefined,
    rlen: usize = 0,
    skip: usize = 0,
    cur: [16384]u8 = undefined,
    reply: Message = undefined,
    out: [8192]u8 = undefined,
    authorizing: bool = false,

    fn writer(self: *Bus) Writer {
        return .{ .buf = &self.out };
    }

    fn takeSerial(self: *Bus) u32 {
        const serial = self.next_serial;
        self.next_serial = if (serial == std.math.maxInt(u32)) 1 else serial + 1;
        return serial;
    }

    fn sendAll(self: *Bus, data: []const u8) !void {
        var off: usize = 0;
        while (off < data.len) {
            const rc = linux.sendto(self.fd, data[off..].ptr, data.len - off, MSG_NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => off += rc,
                .INTR => continue,
                else => return error.SendFailed,
            }
        }
    }

    fn recvSome(self: *Bus) !void {
        const rc = linux.recvfrom(self.fd, self.rbuf[self.rlen..].ptr, self.rbuf.len - self.rlen, 0, null, null);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .INTR, .AGAIN => return,
            else => return error.RecvFailed,
        }
        if (rc == 0) return error.Closed;
        self.rlen += rc;
    }

    fn consume(self: *Bus, n: usize) void {
        @memmove(self.rbuf[0 .. self.rlen - n], self.rbuf[n..self.rlen]);
        self.rlen -= n;
    }

    /// Length of the first complete frame in `rbuf`, or null if more data is needed.
    /// Frames that cannot fit the buffer are discarded as they stream in.
    fn frameReady(self: *Bus) !?usize {
        while (true) {
            if (self.skip > 0) {
                const n = @min(self.skip, self.rlen);
                self.consume(n);
                self.skip -= n;
                if (self.skip > 0) return null;
            }
            if (self.rlen < header_len) return null;
            const total = frameLength(self.rbuf[0..header_len]) orelse return error.Protocol;
            if (total > self.rbuf.len) {
                self.skip = total;
                continue;
            }
            if (total > self.rlen) return null;
            return total;
        }
    }

    /// Dispatches every complete buffered frame. If `awaited` is set and the
    /// matching reply arrives, stores it in `self.reply` and returns true.
    fn processFrames(self: *Bus, awaited: ?u32) ServeError!bool {
        while (try self.frameReady()) |total| {
            @memcpy(self.cur[0..total], self.rbuf[0..total]);
            self.consume(total);
            const m = parseMessage(self.cur[0..total]) orelse continue;
            if (awaited) |serial| {
                if ((m.kind == msg_method_return or m.kind == msg_error) and m.reply_serial == serial) {
                    self.reply = m;
                    return true;
                }
            }
            try self.handle(m);
        }
        return false;
    }

    fn waitReply(self: *Bus, serial: u32) ServeError!void {
        const deadline = nowMs() + call_timeout_ms;
        while (true) {
            if (try self.processFrames(serial)) return;
            const left = deadline - nowMs();
            if (left <= 0) return error.Timeout;
            var pfd = [1]linux.pollfd{.{ .fd = self.fd, .events = POLLIN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, @intCast(left));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.PollFailed,
            }
            if (rc == 0) return error.Timeout;
            try self.recvSome();
        }
    }

    fn handshake(self: *Bus) !void {
        // SASL EXTERNAL with our effective uid as hex-encoded decimal text.
        var uid_text: [16]u8 = undefined;
        const uid = std.mem.print(&uid_text, "{d}", .{linux.geteuid()}) catch unreachable;
        var line: [64]u8 = undefined;
        var w: Writer = .{ .buf = &line };
        try w.putRaw("\x00AUTH EXTERNAL ");
        const hex = "0123456789abcdef";
        for (uid) |c| try w.putRaw(&.{ hex[c >> 4], hex[c & 0xf] });
        try w.putRaw("\r\n");
        try self.sendAll(w.bytes());

        while (std.mem.find(u8, self.rbuf[0..self.rlen], "\r\n") == null) {
            if (self.rlen == self.rbuf.len) return error.AuthFailed;
            try self.recvSome();
        }
        if (!std.mem.startsWith(u8, self.rbuf[0..self.rlen], "OK ")) return error.AuthFailed;
        self.rlen = 0;
        try self.sendAll("BEGIN\r\n");

        var w1 = self.writer();
        const hello = self.takeSerial();
        try w1.beginCall(hello, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "Hello", "", "");
        w1.finish();
        try self.sendAll(w1.bytes());
        try self.waitReply(hello);
        if (self.reply.kind != msg_method_return) return error.HelloFailed;

        var w2 = self.writer();
        const request = self.takeSerial();
        try w2.beginCall(request, "org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName", "su", "");
        try w2.putStr(bus_name);
        try w2.putU32(4); // DBUS_NAME_FLAG_DO_NOT_QUEUE
        w2.finish();
        try self.sendAll(w2.bytes());
        try self.waitReply(request);
        if (self.reply.kind != msg_method_return or !eql(self.reply.sig, "u")) return error.NameRequestFailed;
        var r: Reader = .{ .buf = self.reply.body };
        switch (try r.getU32()) {
            1, 4 => {}, // primary owner, already owner
            else => return error.NameTaken,
        }
    }

    // -- replies ------------------------------------------------------------

    fn beginReply(self: *Bus, w: *Writer, m: Message, kind: u8, sig: []const u8, err_name: []const u8) !void {
        try w.beginMessage(kind, flag_no_reply_expected, self.takeSerial());
        if (kind == msg_error) try w.fieldStr(field_error_name, 's', err_name);
        try w.fieldU32(field_reply_serial, m.serial);
        if (m.sender.len > 0) try w.fieldStr(field_destination, 's', m.sender);
        if (sig.len > 0) try w.fieldStr(field_signature, 'g', sig);
        try w.endFields();
    }

    fn replyEmpty(self: *Bus, m: Message) !void {
        if (m.flags & flag_no_reply_expected != 0) return;
        var w = self.writer();
        try self.beginReply(&w, m, msg_method_return, "", "");
        w.finish();
        try self.sendAll(w.bytes());
    }

    fn replyError(self: *Bus, m: Message, name: []const u8, text: []const u8) !void {
        if (m.flags & flag_no_reply_expected != 0) return;
        var w = self.writer();
        try self.beginReply(&w, m, msg_error, "s", name);
        try w.putStr(text);
        w.finish();
        try self.sendAll(w.bytes());
    }

    fn emitActiveProfileChanged(self: *Bus) !void {
        var w = self.writer();
        try w.beginMessage(msg_signal, flag_no_reply_expected, self.takeSerial());
        try w.fieldStr(field_path, 'o', object_path);
        try w.fieldStr(field_interface, 's', iface_properties);
        try w.fieldStr(field_member, 's', "PropertiesChanged");
        try w.fieldStr(field_signature, 'g', "sa{sv}as");
        try w.endFields();
        try w.putStr(interface);
        const changed = try w.beginArray(8);
        try w.alignTo(8);
        try w.putStr("ActiveProfile");
        try self.putPropValue(&w, .active_profile);
        w.endArray(changed, 8);
        const invalidated = try w.beginArray(4);
        w.endArray(invalidated, 4);
        w.finish();
        try self.sendAll(w.bytes());
    }

    // -- property values ----------------------------------------------------

    fn putEmptyDictArray(w: *Writer) !void {
        try w.putSig("aa{sv}");
        const outer = try w.beginArray(4);
        w.endArray(outer, 4);
    }

    /// Writes a VARIANT holding the property value.
    fn putPropValue(self: *Bus, w: *Writer, prop: Prop) !void {
        switch (prop) {
            .active_profile => {
                try w.putSig("s");
                try w.putStr(self.daemon.activeName());
            },
            .performance_degraded => {
                try w.putSig("s");
                try w.putStr("");
            },
            .version => {
                try w.putSig("s");
                try w.putStr(build_options.version);
            },
            .actions => {
                try w.putSig("as");
                const arr = try w.beginArray(4);
                w.endArray(arr, 4);
            },
            .actions_info, .active_profile_holds => try putEmptyDictArray(w),
            .profiles => {
                try w.putSig("aa{sv}");
                const outer = try w.beginArray(4);
                for ([_]profile_mod.DbusProfile{ .power_saver, .balanced, .performance }) |p| {
                    const inner = try w.beginArray(8);
                    try w.alignTo(8);
                    try w.putStr("Profile");
                    try w.putSig("s");
                    try w.putStr(p.name());
                    try w.alignTo(8);
                    try w.putStr("Driver");
                    try w.putSig("s");
                    try w.putStr("platform_profile");
                    w.endArray(inner, 8);
                }
                w.endArray(outer, 4);
            },
        }
    }

    // -- method dispatch ----------------------------------------------------

    fn handle(self: *Bus, m: Message) ServeError!void {
        if (m.kind != msg_method_call or m.path.len == 0 or m.member.len == 0) return;

        if (eql(m.iface, iface_peer)) {
            if (eql(m.member, "Ping")) return self.replyEmpty(m);
            return self.replyError(m, err_unknown_method, "unknown method");
        }
        if (!eql(m.path, object_path)) {
            return self.replyError(m, err_unknown_object, "unknown object path");
        }

        const any_iface = m.iface.len == 0;
        if ((any_iface or eql(m.iface, iface_introspectable)) and eql(m.member, "Introspect")) {
            if (m.sig.len != 0) return self.replyError(m, err_invalid_args, "unexpected arguments");
            var w = self.writer();
            try self.beginReply(&w, m, msg_method_return, "s", "");
            try w.putStr(introspection_xml);
            w.finish();
            return self.sendAll(w.bytes());
        }
        if (any_iface or eql(m.iface, iface_properties)) {
            if (eql(m.member, "Get")) return self.handleGet(m);
            if (eql(m.member, "GetAll")) return self.handleGetAll(m);
            if (eql(m.member, "Set")) return self.handleSet(m);
        }
        return self.replyError(m, err_unknown_method, "unknown method");
    }

    fn handleGet(self: *Bus, m: Message) !void {
        if (!eql(m.sig, "ss")) return self.replyError(m, err_invalid_args, "Get expects (ss)");
        var r: Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const name = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        if (!eql(iface_arg, interface)) return self.replyError(m, err_unknown_interface, "unknown interface");
        const prop = lookupProp(name) orelse return self.replyError(m, err_unknown_property, "unknown property");

        var w = self.writer();
        try self.beginReply(&w, m, msg_method_return, "v", "");
        try self.putPropValue(&w, prop);
        w.finish();
        try self.sendAll(w.bytes());
    }

    fn handleGetAll(self: *Bus, m: Message) !void {
        if (!eql(m.sig, "s")) return self.replyError(m, err_invalid_args, "GetAll expects (s)");
        var r: Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        if (iface_arg.len != 0 and !eql(iface_arg, interface)) {
            return self.replyError(m, err_unknown_interface, "unknown interface");
        }

        var w = self.writer();
        try self.beginReply(&w, m, msg_method_return, "a{sv}", "");
        const arr = try w.beginArray(8);
        for (prop_table) |entry| {
            try w.alignTo(8);
            try w.putStr(entry.name);
            try self.putPropValue(&w, entry.prop);
        }
        w.endArray(arr, 8);
        w.finish();
        try self.sendAll(w.bytes());
    }

    fn handleSet(self: *Bus, m: Message) ServeError!void {
        // Validate everything before Polkit or sysfs is touched.
        if (!eql(m.sig, "ssv")) return self.replyError(m, err_invalid_args, "Set expects (ssv)");
        var r: Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const name = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const value_sig = r.getSig() catch return self.replyError(m, err_invalid_args, "malformed arguments");

        if (!eql(iface_arg, interface)) return self.replyError(m, err_unknown_interface, "unsupported interface");
        const prop = lookupProp(name) orelse return self.replyError(m, err_unknown_property, "unsupported property");
        if (prop != .active_profile) return self.replyError(m, err_read_only, "unsupported property");
        if (!eql(value_sig, "s")) return self.replyError(m, err_invalid_args, "ActiveProfile expects a string value");
        const value = r.getStr() catch return self.replyError(m, err_invalid_args, "ActiveProfile expects a string value");
        const requested = profile_mod.DbusProfile.parseName(value) orelse
            return self.replyError(m, err_invalid_args, "unsupported profile");

        if (self.authorizing) {
            return self.replyError(m, err_failed, "another profile change is awaiting authorization");
        }
        if (m.sender.len == 0 or m.sender.len > 255) {
            return self.replyError(m, err_failed, "failed to resolve D-Bus sender");
        }

        // authorize() services other traffic while waiting, which reuses
        // `cur`; keep a private copy of what the final reply needs.
        var sender_buf: [255]u8 = undefined;
        @memcpy(sender_buf[0..m.sender.len], m.sender);
        var req = m;
        req.sender = sender_buf[0..m.sender.len];

        var denied_buf: [256]u8 = undefined;
        if (try self.authorize(req.sender, &denied_buf)) |denied| {
            return self.replyError(req, err_access_denied, denied);
        }

        const changed = self.daemon.setActiveProfile(requested) catch |err| {
            return switch (err) {
                error.UnsupportedPlatform, error.UnknownKernelProfile => self.replyError(req, err_not_supported, "platform_profile sysfs is unavailable"),
                error.PermissionDenied => self.replyError(req, err_access_denied, "permission denied writing platform_profile"),
                error.ReadFailed => self.replyError(req, err_failed, "failed to read platform_profile"),
                error.WriteFailed => self.replyError(req, err_failed, "failed to write platform_profile"),
            };
        };
        if (changed) try self.emitActiveProfileChanged();
        try self.replyEmpty(req);
    }

    /// Asks Polkit about `sender`. Returns null when authorized, otherwise the
    /// denial text (formatted into `msg_buf`).
    fn authorize(self: *Bus, sender: []const u8, msg_buf: []u8) ServeError!?[]const u8 {
        self.authorizing = true;
        defer self.authorizing = false;

        var w = self.writer();
        const serial = self.takeSerial();
        try w.beginCall(serial, polkit_service, polkit_path, polkit_interface, "CheckAuthorization", "(sa{sv})sa{ss}us", "");
        try w.alignTo(8); // STRUCT subject
        try w.putStr("system-bus-name");
        const details = try w.beginArray(8);
        try w.alignTo(8);
        try w.putStr("name");
        try w.putSig("s");
        try w.putStr(sender);
        w.endArray(details, 8);
        try w.putStr(polkit_action);
        const empty = try w.beginArray(8);
        w.endArray(empty, 8);
        try w.putU32(polkit_allow_user_interaction);
        try w.putStr("");
        w.finish();
        try self.sendAll(w.bytes());

        self.waitReply(serial) catch |err| switch (err) {
            error.Timeout => return denial(msg_buf, "timed out"),
            else => return err,
        };
        const reply = self.reply;

        if (reply.kind == msg_error) {
            var text: []const u8 = "unknown error";
            if (eql(reply.sig, "s")) {
                var r: Reader = .{ .buf = reply.body };
                text = r.getStr() catch text;
            }
            return denial(msg_buf, text);
        }
        if (!eql(reply.sig, "(bba{ss})")) return denial(msg_buf, "malformed reply");

        var r: Reader = .{ .buf = reply.body };
        r.alignTo(8) catch return denial(msg_buf, "malformed reply");
        const authorized = r.getU32() catch return denial(msg_buf, "malformed reply");
        const challenge = r.getU32() catch return denial(msg_buf, "malformed reply");
        if (authorized != 0) return null;
        return if (challenge != 0)
            "authentication required to switch power profile"
        else
            "not authorized to switch power profile";
    }
};

fn denial(buf: []u8, reason: []const u8) []const u8 {
    return std.mem.print(buf, "polkit authorization failed: {s}", .{utf8Prefix(reason, 160)}) catch
        "polkit authorization failed";
}

/// Connects to the system bus, claims the service name, and serves requests
/// and platform_profile change events until the connection fails.
/// `bus_address` overrides the default system bus address
/// (`DBUS_SYSTEM_BUS_ADDRESS` from the environment).
pub fn run(daemon: *daemon_mod.Daemon, bus_address: ?[]const u8) !void {
    const fd = try connectBus(bus_address);
    defer _ = linux.close(fd);

    var bus: Bus = .{ .fd = fd, .daemon = daemon };
    try bus.handshake();

    while (true) {
        _ = try bus.processFrames(null);

        const sysfs_fd = daemon.pollFd();
        var fds = [2]linux.pollfd{
            .{ .fd = fd, .events = POLLIN, .revents = 0 },
            .{ .fd = sysfs_fd, .events = POLLPRI | POLLERR, .revents = 0 },
        };
        const nfds: linux.nfds_t = if (sysfs_fd >= 0) 2 else 1;
        switch (linux.errno(linux.poll(&fds, nfds, -1))) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }

        if (fds[0].revents != 0) try bus.recvSome();
        if (sysfs_fd >= 0 and fds[1].revents & (POLLPRI | POLLERR | POLLHUP | POLLNVAL) != 0) {
            if (daemon.checkExternalUpdate()) try bus.emitActiveProfileChanged();
        }
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestPair = struct {
    bus: *Bus,
    peer: linux.fd_t,

    fn deinit(self: TestPair) void {
        _ = linux.close(self.bus.fd);
        _ = linux.close(self.peer);
    }

    /// Sends a method call from the peer, runs the bus, returns the single reply in `out`.
    fn roundTrip(self: TestPair, w: *Writer, out: []u8) !Message {
        w.finish();
        try std.testing.expectEqual(w.len, linux.sendto(self.peer, w.buf.ptr, w.len, 0, null, 0));
        try self.bus.recvSome();
        _ = try self.bus.processFrames(null);
        const n = linux.recvfrom(self.peer, out.ptr, out.len, 0, null, null);
        try std.testing.expect(linux.errno(n) == .SUCCESS and n > 0);
        return parseMessage(out[0..n]) orelse error.BadReply;
    }
};

fn testPair(bus: *Bus, daemon: *daemon_mod.Daemon) !TestPair {
    var sv: [2]linux.fd_t = undefined;
    try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC, 0, &sv)));
    bus.* = .{ .fd = sv[0], .daemon = daemon };
    return .{ .bus = bus, .peer = sv[1] };
}

fn buildProps(buf: []u8, member: []const u8, sig: []const u8) !Writer {
    var w: Writer = .{ .buf = buf };
    try w.beginCall(7, bus_name, object_path, iface_properties, member, sig, ":1.99");
    return w;
}

test "message round trip preserves header fields and body" {
    var buf: [512]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.beginCall(42, "dest.name", object_path, iface_properties, "Get", "ss", "");
    try w.putStr(interface);
    try w.putStr("ActiveProfile");
    w.finish();

    try std.testing.expectEqual(@as(?usize, w.len), frameLength(w.bytes()[0..header_len]));
    const m = parseMessage(w.bytes()).?;
    try std.testing.expectEqual(msg_method_call, m.kind);
    try std.testing.expectEqual(@as(u32, 42), m.serial);
    try std.testing.expectEqualStrings(object_path, m.path);
    try std.testing.expectEqualStrings(iface_properties, m.iface);
    try std.testing.expectEqualStrings("Get", m.member);
    try std.testing.expectEqualStrings("ss", m.sig);

    var r: Reader = .{ .buf = m.body };
    try std.testing.expectEqualStrings(interface, try r.getStr());
    try std.testing.expectEqualStrings("ActiveProfile", try r.getStr());
}

test "parser rejects truncated and big-endian messages" {
    var buf: [256]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.beginCall(1, "d", object_path, iface_properties, "Get", "", "");
    w.finish();
    try std.testing.expect(parseMessage(w.bytes()[0 .. w.len - 1]) == null);
    var copy = buf;
    copy[0] = 'B';
    try std.testing.expect(parseMessage(copy[0..w.len]) == null);
}

test "utf8 prefix never splits a sequence" {
    try std.testing.expectEqualStrings("ab", utf8Prefix("ab\xc3\xa9", 3));
    try std.testing.expectEqualStrings("ab\xc3\xa9", utf8Prefix("ab\xc3\xa9", 4));
}

test "Get ActiveProfile returns cached profile as variant string" {
    var daemon = daemon_mod.Daemon.init("/nonexistent");
    daemon.active = .performance;
    var bus: Bus = undefined;
    const pair = try testPair(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w = try buildProps(&buf, "Get", "ss");
    try w.putStr(interface);
    try w.putStr("ActiveProfile");
    var out: [512]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    try std.testing.expectEqual(msg_method_return, reply.kind);
    try std.testing.expectEqual(@as(u32, 7), reply.reply_serial);
    try std.testing.expectEqualStrings("v", reply.sig);
    var r: Reader = .{ .buf = reply.body };
    try std.testing.expectEqualStrings("s", try r.getSig());
    try std.testing.expectEqualStrings("performance", try r.getStr());
}

test "GetAll marshals every property with valid alignment" {
    var daemon = daemon_mod.Daemon.init("/nonexistent");
    daemon.active = .power_saver;
    var bus: Bus = undefined;
    const pair = try testPair(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w = try buildProps(&buf, "GetAll", "s");
    try w.putStr(interface);
    var out: [2048]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    try std.testing.expectEqualStrings("a{sv}", reply.sig);

    var r: Reader = .{ .buf = reply.body };
    const array_len = try r.getU32();
    try r.alignTo(8);
    const end = r.pos + array_len;
    var seen: usize = 0;
    while (r.pos < end) : (seen += 1) {
        try r.alignTo(8);
        const name = try r.getStr();
        const vsig = try r.getSig();
        try std.testing.expect(lookupProp(name) != null);
        if (eql(name, "ActiveProfile")) {
            try std.testing.expectEqualStrings("s", vsig);
            try std.testing.expectEqualStrings("power-saver", try r.getStr());
        } else if (eql(name, "Profiles")) {
            try std.testing.expectEqualStrings("aa{sv}", vsig);
            const outer_len = try r.getU32();
            const outer_end = r.pos + outer_len;
            var profiles: usize = 0;
            while (r.pos < outer_end) : (profiles += 1) {
                const inner_len = try r.getU32();
                try r.alignTo(8);
                const inner_end = r.pos + inner_len;
                try r.alignTo(8);
                try std.testing.expectEqualStrings("Profile", try r.getStr());
                try std.testing.expectEqualStrings("s", try r.getSig());
                _ = try r.getStr();
                try r.alignTo(8);
                try std.testing.expectEqualStrings("Driver", try r.getStr());
                try std.testing.expectEqualStrings("s", try r.getSig());
                try std.testing.expectEqualStrings("platform_profile", try r.getStr());
                try std.testing.expectEqual(inner_end, r.pos);
            }
            try std.testing.expectEqual(@as(usize, 3), profiles);
        } else if (eql(name, "Version")) {
            try std.testing.expectEqualStrings(build_options.version, try r.getStr());
        } else if (eql(name, "PerformanceDegraded")) {
            try std.testing.expectEqualStrings("", try r.getStr());
        } else if (eql(name, "Actions")) {
            try std.testing.expectEqual(@as(u32, 0), try r.getU32());
        } else {
            // ActionsInfo / ActiveProfileHolds: empty aa{sv}
            try std.testing.expectEqualStrings("aa{sv}", vsig);
            try std.testing.expectEqual(@as(u32, 0), try r.getU32());
        }
    }
    try std.testing.expectEqual(prop_table.len, seen);
    try std.testing.expectEqual(reply.body.len, r.pos);
}

test "Set rejects invalid input before Polkit and without writing" {
    var daemon = daemon_mod.Daemon.init("/nonexistent/never-written");
    daemon.active = .balanced;
    var bus: Bus = undefined;
    const pair = try testPair(&bus, &daemon);
    defer pair.deinit();

    const Case = struct { iface: []const u8, prop: []const u8, vsig: []const u8, value: []const u8, err: []const u8 };
    const cases = [_]Case{
        .{ .iface = interface, .prop = "ActiveProfile", .vsig = "s", .value = "turbo", .err = err_invalid_args },
        .{ .iface = interface, .prop = "ActiveProfile", .vsig = "b", .value = "", .err = err_invalid_args },
        .{ .iface = "org.freedesktop.UPower.NotPowerProfiles", .prop = "ActiveProfile", .vsig = "s", .value = "balanced", .err = err_unknown_interface },
        .{ .iface = interface, .prop = "NotARealProperty", .vsig = "s", .value = "balanced", .err = err_unknown_property },
        .{ .iface = interface, .prop = "Version", .vsig = "s", .value = "balanced", .err = err_read_only },
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        var w = try buildProps(&buf, "Set", "ssv");
        try w.putStr(c.iface);
        try w.putStr(c.prop);
        try w.putSig(c.vsig);
        if (eql(c.vsig, "s")) try w.putStr(c.value) else try w.putU32(1);
        var out: [512]u8 = undefined;
        const reply = try pair.roundTrip(&w, &out);
        try std.testing.expectEqual(msg_error, reply.kind);
        try std.testing.expectEqualStrings(c.err, reply.err_name);
    }
    try std.testing.expect(!bus.authorizing);
    try std.testing.expectEqualStrings("balanced", daemon.activeName());
}

test "Introspect lists the retained properties only" {
    var daemon = daemon_mod.Daemon.init("/nonexistent");
    var bus: Bus = undefined;
    const pair = try testPair(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.beginCall(7, bus_name, object_path, iface_introspectable, "Introspect", "", ":1.99");
    var out: [4096]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    var r: Reader = .{ .buf = reply.body };
    const xml = try r.getStr();
    for (prop_table) |entry| {
        var needle: [64]u8 = undefined;
        const text = try std.mem.print(&needle, "<property name=\"{s}\"", .{entry.name});
        try std.testing.expect(std.mem.find(u8, xml, text) != null);
    }
    try std.testing.expect(std.mem.find(u8, xml, "HoldProfile") == null);
}
