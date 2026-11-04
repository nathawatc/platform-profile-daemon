//! The `org.freedesktop.UPower.PowerProfiles` service.
//!
//! Implements the surface listed in AGENTS.md: Properties Get/GetAll/Set,
//! Introspect, Peer.Ping and the PropertiesChanged signal. Byte transport lives
//! in `dbus/transport.zig`, marshalling in `dbus/wire.zig`, and the Polkit
//! exchange in `dbus/polkit.zig`.
const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const Daemon = @import("daemon.zig").Daemon;
const profile_mod = @import("profile.zig");
const polkit = @import("dbus/polkit.zig");
const transport = @import("dbus/transport.zig");
const wire = @import("dbus/wire.zig");
const testutil = @import("testutil.zig");

const eql = wire.eql;
const linux = std.os.linux;

const bus_name = "org.freedesktop.UPower.PowerProfiles";
const object_path = "/org/freedesktop/UPower/PowerProfiles";
const interface = bus_name;
const iface_properties = "org.freedesktop.DBus.Properties";
const iface_introspectable = "org.freedesktop.DBus.Introspectable";
const iface_peer = "org.freedesktop.DBus.Peer";
const bus_service = "org.freedesktop.DBus";
const bus_path = "/org/freedesktop/DBus";

const err_failed = "org.freedesktop.DBus.Error.Failed";
const err_not_supported = "org.freedesktop.DBus.Error.NotSupported";
const err_access_denied = "org.freedesktop.DBus.Error.AccessDenied";
const err_invalid_args = "org.freedesktop.DBus.Error.InvalidArgs";
const err_unknown_method = "org.freedesktop.DBus.Error.UnknownMethod";
const err_unknown_object = "org.freedesktop.DBus.Error.UnknownObject";
const err_unknown_interface = "org.freedesktop.DBus.Error.UnknownInterface";
const err_unknown_property = "org.freedesktop.DBus.Error.UnknownProperty";
const err_read_only = "org.freedesktop.DBus.Error.PropertyReadOnly";

const name_flag_do_not_queue: u32 = 4;
const call_timeout_ms: i64 = 25_000;

const POLLIN: i16 = linux.POLL.IN;
const POLLPRI: i16 = linux.POLL.PRI;
const POLLERR: i16 = linux.POLL.ERR;
const POLLHUP: i16 = linux.POLL.HUP;
const POLLNVAL: i16 = linux.POLL.NVAL;
/// Events requested on the watch fd, and the revents that mean "go look".
const watch_events: i16 = POLLPRI | POLLERR;
const watch_ready: i16 = watch_events | POLLHUP | POLLNVAL;

const introspection_xml = @embedFile("dbus/introspection.xml");

/// The retained properties. Tag names are the D-Bus property names, so this is
/// the one list that Get, GetAll and Set share.
const Prop = enum {
    ActiveProfile,
    PerformanceDegraded,
    Profiles,
    Actions,
    ActionsInfo,
    ActiveProfileHolds,
    Version,
};

/// Explicit because message dispatch and Polkit waiting call each other.
const ServeError = error{ NoSpace, SendFailed, RecvFailed, Closed, PollFailed, Protocol, Timeout, WatchLost };

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    // Raw syscall: only called while awaiting Polkit, so skip std's vDSO lookup code.
    _ = linux.syscall2(.clock_gettime, @backingInt(linux.clockid_t.MONOTONIC), @intFromPtr(&ts));
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

const Bus = struct {
    t: transport.Transport,
    daemon: *Daemon,
    out: [8192]u8 = undefined,
    authorizing: bool = false,

    fn writer(self: *Bus) wire.Writer {
        return .{ .buf = &self.out };
    }

    /// Dispatches every complete buffered frame. If `awaited` is given and its
    /// reply arrives, returns it instead of dispatching; the reply stays valid
    /// until the next frame is read.
    fn pump(self: *Bus, awaited: ?u32) ServeError!?wire.Message {
        while (try self.t.nextFrame()) |frame| {
            const m = wire.parseMessage(frame) orelse continue;
            if (awaited) |serial| {
                if ((m.kind == wire.msg_method_return or m.kind == wire.msg_error) and m.reply_serial == serial) return m;
            }
            try self.handle(m);
        }
        return null;
    }

    fn waitReply(self: *Bus, serial: u32) ServeError!wire.Message {
        const deadline = nowMs() + call_timeout_ms;
        while (true) {
            if (try self.pump(serial)) |reply| return reply;
            const left = deadline - nowMs();
            if (left <= 0) return error.Timeout;
            // Keep serving profile changes made elsewhere (e.g. a firmware
            // hotkey) while a user sits at an authentication prompt.
            var fds = [2]linux.pollfd{
                .{ .fd = self.t.fd, .events = POLLIN, .revents = 0 },
                .{ .fd = self.daemon.sysfs.fd, .events = watch_events, .revents = 0 },
            };
            const rc = linux.poll(&fds, 2, @intCast(left));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.PollFailed,
            }
            if (rc == 0) return error.Timeout;
            if (fds[0].revents != 0) try self.t.recv();
            if (fds[1].revents & watch_ready != 0) try self.serviceWatch();
        }
    }

    /// Handles a platform_profile change event and announces a visible change.
    /// An unrecoverable watch failure ends the service (systemd restarts it).
    fn serviceWatch(self: *Bus) ServeError!void {
        const changed = self.daemon.checkExternalUpdate() catch |err| {
            if (!builtin.is_test) std.log.err("platform_profile watch lost: {t}", .{err});
            return error.WatchLost;
        };
        if (changed) try self.emitActiveProfileChanged();
    }

    /// Sends the call in `w` and waits for the reply to `serial`.
    fn transact(self: *Bus, w: *wire.Writer, serial: u32) ServeError!wire.Message {
        w.finish();
        try self.t.send(w.bytes());
        return self.waitReply(serial);
    }

    /// Authenticates, says Hello, and claims the service name.
    fn start(self: *Bus) !void {
        try self.t.authenticate();

        var w = self.writer();
        var serial = self.t.takeSerial();
        try w.beginCall(serial, bus_service, bus_path, bus_service, "Hello", "", "");
        if ((try self.transact(&w, serial)).kind != wire.msg_method_return) return error.HelloFailed;

        w = self.writer();
        serial = self.t.takeSerial();
        try w.beginCall(serial, bus_service, bus_path, bus_service, "RequestName", "su", "");
        try w.putStr(bus_name);
        try w.putU32(name_flag_do_not_queue);
        const reply = try self.transact(&w, serial);
        if (reply.kind != wire.msg_method_return or !eql(reply.sig, "u")) return error.NameRequestFailed;
        var r: wire.Reader = .{ .buf = reply.body };
        switch (try r.getU32()) {
            1, 4 => {}, // primary owner, already owner
            else => return error.NameTaken,
        }
    }

    // -- replies ------------------------------------------------------------

    fn beginReply(self: *Bus, w: *wire.Writer, m: wire.Message, kind: u8, sig: []const u8, err_name: []const u8) !void {
        try w.beginMessage(kind, wire.flag_no_reply_expected, self.t.takeSerial());
        if (kind == wire.msg_error) try w.fieldStr(wire.field_error_name, 's', err_name);
        try w.fieldU32(wire.field_reply_serial, m.serial);
        if (m.sender.len > 0) try w.fieldStr(wire.field_destination, 's', m.sender);
        if (sig.len > 0) try w.fieldStr(wire.field_signature, 'g', sig);
        try w.endFields();
    }

    fn replyEmpty(self: *Bus, m: wire.Message) !void {
        if (m.flags & wire.flag_no_reply_expected != 0) return;
        var w = self.writer();
        try self.beginReply(&w, m, wire.msg_method_return, "", "");
        w.finish();
        try self.t.send(w.bytes());
    }

    fn replyError(self: *Bus, m: wire.Message, name: []const u8, text: []const u8) !void {
        if (m.flags & wire.flag_no_reply_expected != 0) return;
        var w = self.writer();
        try self.beginReply(&w, m, wire.msg_error, "s", name);
        try w.putStr(text);
        w.finish();
        try self.t.send(w.bytes());
    }

    fn emitActiveProfileChanged(self: *Bus) !void {
        var w = self.writer();
        try w.beginMessage(wire.msg_signal, wire.flag_no_reply_expected, self.t.takeSerial());
        try w.fieldStr(wire.field_path, 'o', object_path);
        try w.fieldStr(wire.field_interface, 's', iface_properties);
        try w.fieldStr(wire.field_member, 's', "PropertiesChanged");
        try w.fieldStr(wire.field_signature, 'g', "sa{sv}as");
        try w.endFields();
        try w.putStr(interface);
        const changed = try w.beginArray(8);
        try w.alignTo(8);
        try w.putStr(@tagName(Prop.ActiveProfile));
        try self.putPropValue(&w, .ActiveProfile);
        w.endArray(changed, 8);
        const invalidated = try w.beginArray(4);
        w.endArray(invalidated, 4);
        w.finish();
        try self.t.send(w.bytes());
    }

    // -- property values ----------------------------------------------------

    /// Writes a VARIANT holding the property value.
    fn putPropValue(self: *Bus, w: *wire.Writer, prop: Prop) !void {
        switch (prop) {
            .ActiveProfile => {
                try w.putSig("s");
                try w.putStr(self.daemon.active.dbusName());
            },
            .PerformanceDegraded => {
                try w.putSig("s");
                try w.putStr("");
            },
            .Version => {
                try w.putSig("s");
                try w.putStr(build_options.version);
            },
            .Actions => {
                try w.putSig("as");
                const arr = try w.beginArray(4);
                w.endArray(arr, 4);
            },
            .ActionsInfo, .ActiveProfileHolds => {
                try w.putSig("aa{sv}");
                const outer = try w.beginArray(4);
                w.endArray(outer, 4);
            },
            .Profiles => {
                try w.putSig("aa{sv}");
                const outer = try w.beginArray(4);
                for (std.enums.values(profile_mod.Profile)) |p| {
                    const inner = try w.beginArray(8);
                    try w.alignTo(8);
                    try w.putStr("Profile");
                    try w.putSig("s");
                    try w.putStr(p.dbusName());
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

    fn handle(self: *Bus, m: wire.Message) ServeError!void {
        if (m.kind != wire.msg_method_call or m.path.len == 0 or m.member.len == 0) return;

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
            try self.beginReply(&w, m, wire.msg_method_return, "s", "");
            try w.putStr(introspection_xml);
            w.finish();
            return self.t.send(w.bytes());
        }
        if (any_iface or eql(m.iface, iface_properties)) {
            if (eql(m.member, "Get")) return self.handleGet(m);
            if (eql(m.member, "GetAll")) return self.handleGetAll(m);
            if (eql(m.member, "Set")) return self.handleSet(m);
        }
        return self.replyError(m, err_unknown_method, "unknown method");
    }

    fn handleGet(self: *Bus, m: wire.Message) !void {
        if (!eql(m.sig, "ss")) return self.replyError(m, err_invalid_args, "Get expects (ss)");
        var r: wire.Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const name = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        // Like GetAll, an empty interface means "any": there is only one.
        if (iface_arg.len != 0 and !eql(iface_arg, interface)) return self.replyError(m, err_unknown_interface, "unknown interface");
        const prop = std.meta.stringToEnum(Prop, name) orelse return self.replyError(m, err_unknown_property, "unknown property");

        var w = self.writer();
        try self.beginReply(&w, m, wire.msg_method_return, "v", "");
        try self.putPropValue(&w, prop);
        w.finish();
        try self.t.send(w.bytes());
    }

    fn handleGetAll(self: *Bus, m: wire.Message) !void {
        if (!eql(m.sig, "s")) return self.replyError(m, err_invalid_args, "GetAll expects (s)");
        var r: wire.Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        if (iface_arg.len != 0 and !eql(iface_arg, interface)) {
            return self.replyError(m, err_unknown_interface, "unknown interface");
        }

        var w = self.writer();
        try self.beginReply(&w, m, wire.msg_method_return, "a{sv}", "");
        const arr = try w.beginArray(8);
        for (std.enums.values(Prop)) |prop| {
            try w.alignTo(8);
            try w.putStr(@tagName(prop));
            try self.putPropValue(&w, prop);
        }
        w.endArray(arr, 8);
        w.finish();
        try self.t.send(w.bytes());
    }

    fn handleSet(self: *Bus, m: wire.Message) ServeError!void {
        // Validate everything before Polkit or sysfs is touched.
        if (!eql(m.sig, "ssv")) return self.replyError(m, err_invalid_args, "Set expects (ssv)");
        var r: wire.Reader = .{ .buf = m.body };
        const iface_arg = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const name = r.getStr() catch return self.replyError(m, err_invalid_args, "malformed arguments");
        const value_sig = r.getSig() catch return self.replyError(m, err_invalid_args, "malformed arguments");

        if (!eql(iface_arg, interface)) return self.replyError(m, err_unknown_interface, "unsupported interface");
        const prop = std.meta.stringToEnum(Prop, name) orelse return self.replyError(m, err_unknown_property, "unsupported property");
        if (prop != .ActiveProfile) return self.replyError(m, err_read_only, "unsupported property");
        if (!eql(value_sig, "s")) return self.replyError(m, err_invalid_args, "ActiveProfile expects a string value");
        const value = r.getStr() catch return self.replyError(m, err_invalid_args, "ActiveProfile expects a string value");
        const requested = profile_mod.Profile.parseDbus(value) orelse
            return self.replyError(m, err_invalid_args, "unsupported profile");

        if (self.authorizing) {
            return self.replyError(m, err_failed, "another profile change is awaiting authorization");
        }
        if (m.sender.len == 0 or m.sender.len > 255) {
            return self.replyError(m, err_failed, "failed to resolve D-Bus sender");
        }

        // authorize() services other traffic while waiting, which reuses
        // the frame buffer; keep a private copy of what the final reply needs.
        var sender_buf: [255]u8 = undefined;
        @memcpy(sender_buf[0..m.sender.len], m.sender);
        var req = m;
        req.sender = sender_buf[0..m.sender.len];

        var denied_buf: [256]u8 = undefined;
        if (try self.authorize(req.sender, &denied_buf)) |denied| {
            return self.replyError(req, err_access_denied, denied);
        }

        // The cache can move even when the request then fails (the kernel was
        // read first), so announce any visible change on both paths. The
        // caller's answer goes first so a failed signal cannot swallow it.
        const before = self.daemon.active;
        const result = self.daemon.setActiveProfile(requested);
        const changed = self.daemon.active != before;
        if (result) |_| {
            try self.replyEmpty(req);
        } else |err| try switch (err) {
            error.UnsupportedPlatform => self.replyError(req, err_not_supported, "platform_profile sysfs is unavailable"),
            error.PermissionDenied => self.replyError(req, err_access_denied, "permission denied writing platform_profile"),
            error.ReadFailed => self.replyError(req, err_failed, "failed to read platform_profile"),
            error.WriteFailed => self.replyError(req, err_failed, "failed to write platform_profile"),
        };
        if (changed) try self.emitActiveProfileChanged();
    }

    /// Asks Polkit about `sender`. Returns null when authorized, otherwise the
    /// denial text (formatted into `msg_buf`).
    fn authorize(self: *Bus, sender: []const u8, msg_buf: []u8) ServeError!?[]const u8 {
        self.authorizing = true;
        defer self.authorizing = false;

        var w = self.writer();
        const serial = self.t.takeSerial();
        try polkit.writeRequest(&w, serial, sender);
        const reply = self.transact(&w, serial) catch |err| switch (err) {
            error.Timeout => return polkit.failure(msg_buf, "timed out"),
            else => return err,
        };
        return polkit.decide(reply, msg_buf);
    }
};

/// Connects to the system bus, claims the service name, and serves requests
/// and platform_profile change events until the connection or the profile
/// watch fails. `bus_address` overrides the default system bus address
/// (`DBUS_SYSTEM_BUS_ADDRESS` from the environment).
pub fn run(daemon: *Daemon, bus_address: ?[]const u8) !void {
    const fd = try transport.connect(bus_address);
    defer _ = linux.close(fd);

    var bus: Bus = .{ .t = .{ .fd = fd }, .daemon = daemon };
    try bus.start();

    while (true) {
        _ = try bus.pump(null);

        var fds = [2]linux.pollfd{
            .{ .fd = fd, .events = POLLIN, .revents = 0 },
            .{ .fd = daemon.sysfs.fd, .events = watch_events, .revents = 0 },
        };
        switch (linux.errno(linux.poll(&fds, 2, -1))) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.PollFailed,
        }

        if (fds[0].revents != 0) try bus.t.recv();
        if (fds[1].revents & watch_ready != 0) try bus.serviceWatch();
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const max_path = std.Io.Dir.max_path_bytes;

/// A bus wired to a socketpair, with the test acting as the remote peer.
const TestPair = struct {
    bus: *Bus,
    peer: linux.fd_t,

    fn init(bus: *Bus, daemon: *Daemon) !TestPair {
        var sv: [2]linux.fd_t = undefined;
        try std.testing.expectEqual(linux.E.SUCCESS, linux.errno(linux.socketpair(linux.AF.UNIX, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, 0, &sv)));
        bus.* = .{ .t = .{ .fd = sv[0] }, .daemon = daemon };
        return .{ .bus = bus, .peer = sv[1] };
    }

    fn deinit(self: TestPair) void {
        _ = linux.close(self.bus.t.fd);
        _ = linux.close(self.peer);
    }

    /// Queues a finished message from the peer.
    fn queue(self: TestPair, w: *wire.Writer) !void {
        w.finish();
        try std.testing.expectEqual(w.len, linux.sendto(self.peer, w.buf.ptr, w.len, 0, null, 0));
    }

    /// Lets the bus read and serve everything queued so far.
    fn serve(self: TestPair) !void {
        try self.bus.t.recv();
        _ = try self.bus.pump(null);
    }

    /// Everything the bus has sent so far, without blocking.
    fn drain(self: TestPair, out: []u8) []const u8 {
        const n = linux.recvfrom(self.peer, out.ptr, out.len, linux.MSG.DONTWAIT, null, null);
        return if (linux.errno(n) == .SUCCESS) out[0..n] else out[0..0];
    }

    /// Sends one call, serves it, and returns the single reply in `out`.
    fn roundTrip(self: TestPair, w: *wire.Writer, out: []u8) !wire.Message {
        try self.queue(w);
        try self.serve();
        const bytes = self.drain(out);
        try std.testing.expect(bytes.len > 0);
        return wire.parseMessage(bytes) orelse error.BadReply;
    }
};

/// Splits `bytes` into the messages it holds.
const Frames = struct {
    rest: []const u8,

    fn next(self: *Frames) ?wire.Message {
        if (self.rest.len < wire.header_len) return null;
        const total = wire.frameLength(self.rest[0..wire.header_len]).?;
        defer self.rest = self.rest[total..];
        return wire.parseMessage(self.rest[0..total]);
    }
};

fn buildProps(buf: []u8, member: []const u8, sig: []const u8) !wire.Writer {
    var w: wire.Writer = .{ .buf = buf };
    try w.beginCall(7, bus_name, object_path, iface_properties, member, sig, ":1.99");
    return w;
}

fn buildSet(buf: []u8, value: []const u8) !wire.Writer {
    var w = try buildProps(buf, "Set", "ssv");
    try w.putStr(interface);
    try w.putStr("ActiveProfile");
    try w.putSig("s");
    try w.putStr(value);
    return w;
}

/// A Polkit CheckAuthorization reply for `reply_serial`.
fn polkitReply(buf: []u8, reply_serial: u32, authorized: bool) !wire.Writer {
    var w: wire.Writer = .{ .buf = buf };
    try w.beginMessage(wire.msg_method_return, wire.flag_no_reply_expected, 50);
    try w.fieldU32(wire.field_reply_serial, reply_serial);
    try w.fieldStr(wire.field_signature, 'g', "(bba{ss})");
    try w.endFields();
    try w.alignTo(8);
    try w.putU32(@intFromBool(authorized));
    try w.putU32(0);
    const details = try w.beginArray(8);
    w.endArray(details, 8);
    return w;
}

fn testDaemon(tmp: *std.testing.TmpDir, buf: []u8, contents: []const u8) !Daemon {
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = contents });
    return Daemon.init(try testutil.tmpPath(tmp.dir, "p", buf));
}

fn expectProfileFile(tmp: *std.testing.TmpDir, expected: []const u8) !void {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(expected, try tmp.dir.readFile(std.testing.io, "p", &buf));
}

test "Get ActiveProfile returns cached profile as variant string" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "performance\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w = try buildProps(&buf, "Get", "ss");
    try w.putStr(interface);
    try w.putStr("ActiveProfile");
    var out: [512]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    try std.testing.expectEqual(wire.msg_method_return, reply.kind);
    try std.testing.expectEqual(@as(u32, 7), reply.reply_serial);
    try std.testing.expectEqualStrings("v", reply.sig);
    var r: wire.Reader = .{ .buf = reply.body };
    try std.testing.expectEqualStrings("s", try r.getSig());
    try std.testing.expectEqualStrings("performance", try r.getStr());
}

test "GetAll marshals every property with valid alignment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "low-power\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w = try buildProps(&buf, "GetAll", "s");
    try w.putStr(interface);
    var out: [2048]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    try std.testing.expectEqualStrings("a{sv}", reply.sig);

    var r: wire.Reader = .{ .buf = reply.body };
    const array_len = try r.getU32();
    try r.alignTo(8);
    const end = r.pos + array_len;
    var seen: usize = 0;
    while (r.pos < end) : (seen += 1) {
        try r.alignTo(8);
        const name = try r.getStr();
        const vsig = try r.getSig();
        const prop = std.meta.stringToEnum(Prop, name).?;
        switch (prop) {
            .ActiveProfile => {
                try std.testing.expectEqualStrings("s", vsig);
                try std.testing.expectEqualStrings("power-saver", try r.getStr());
            },
            .Profiles => {
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
                    try std.testing.expectEqualStrings(std.enums.values(profile_mod.Profile)[profiles].dbusName(), try r.getStr());
                    try r.alignTo(8);
                    try std.testing.expectEqualStrings("Driver", try r.getStr());
                    try std.testing.expectEqualStrings("s", try r.getSig());
                    try std.testing.expectEqualStrings("platform_profile", try r.getStr());
                    try std.testing.expectEqual(inner_end, r.pos);
                }
                try std.testing.expectEqual(@as(usize, 3), profiles);
            },
            .Version => try std.testing.expectEqualStrings(build_options.version, try r.getStr()),
            .PerformanceDegraded => try std.testing.expectEqualStrings("", try r.getStr()),
            .Actions => try std.testing.expectEqual(@as(u32, 0), try r.getU32()),
            .ActionsInfo, .ActiveProfileHolds => {
                try std.testing.expectEqualStrings("aa{sv}", vsig);
                try std.testing.expectEqual(@as(u32, 0), try r.getU32());
            },
        }
    }
    try std.testing.expectEqual(std.enums.values(Prop).len, seen);
    try std.testing.expectEqual(reply.body.len, r.pos);
}

test "Set rejects invalid input before Polkit and without writing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    // No trailing newline: any write would add one.
    var daemon = try testDaemon(&tmp, &path, "balanced");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    const Case = struct { iface: []const u8, prop: []const u8, vsig: []const u8, value: []const u8, err: []const u8 };
    const cases = [_]Case{
        .{ .iface = "", .prop = "ActiveProfile", .vsig = "s", .value = "performance", .err = err_unknown_interface },
        .{ .iface = interface, .prop = "ActiveProfile", .vsig = "s", .value = "turbo", .err = err_invalid_args },
        .{ .iface = interface, .prop = "ActiveProfile", .vsig = "s", .value = "low-power", .err = err_invalid_args },
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
        try std.testing.expectEqual(wire.msg_error, reply.kind);
        try std.testing.expectEqualStrings(c.err, reply.err_name);
    }
    try std.testing.expect(!bus.authorizing);
    try expectProfileFile(&tmp, "balanced");
    try std.testing.expectEqual(profile_mod.Profile.balanced, daemon.active);
}

test "authorized Set writes sysfs, replies, then signals the change" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    // The Polkit answer is already waiting when the request goes out.
    var set_buf: [512]u8 = undefined;
    var set = try buildSet(&set_buf, "performance");
    try pair.queue(&set);
    var auth_buf: [256]u8 = undefined;
    var auth = try polkitReply(&auth_buf, bus.t.next_serial, true);
    try pair.queue(&auth);
    try pair.serve();

    var out: [2048]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    const request = frames.next().?;
    try std.testing.expectEqualStrings("CheckAuthorization", request.member);
    const reply = frames.next().?;
    try std.testing.expectEqual(wire.msg_method_return, reply.kind);
    try std.testing.expectEqual(@as(u32, 7), reply.reply_serial);
    const signal = frames.next().?;
    try std.testing.expectEqual(wire.msg_signal, signal.kind);
    try std.testing.expectEqualStrings("PropertiesChanged", signal.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());

    try expectProfileFile(&tmp, "performance\n");
    try std.testing.expectEqual(profile_mod.Profile.performance, daemon.active);
}

test "denied Set neither writes nor signals" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var set_buf: [512]u8 = undefined;
    var set = try buildSet(&set_buf, "performance");
    try pair.queue(&set);
    var auth_buf: [256]u8 = undefined;
    var auth = try polkitReply(&auth_buf, bus.t.next_serial, false);
    try pair.queue(&auth);
    try pair.serve();

    var out: [2048]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    try std.testing.expectEqualStrings("CheckAuthorization", frames.next().?.member);
    const reply = frames.next().?;
    try std.testing.expectEqual(wire.msg_error, reply.kind);
    try std.testing.expectEqualStrings(err_access_denied, reply.err_name);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try expectProfileFile(&tmp, "balanced");
}

test "Set that finds the kernel already at the request still signals a stale cache" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    // The kernel moved without the daemon noticing yet. No trailing newline,
    // so a write would be visible.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "performance" });
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var set_buf: [512]u8 = undefined;
    var set = try buildSet(&set_buf, "performance");
    try pair.queue(&set);
    var auth_buf: [256]u8 = undefined;
    var auth = try polkitReply(&auth_buf, bus.t.next_serial, true);
    try pair.queue(&auth);
    try pair.serve();

    var out: [2048]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    _ = frames.next().?; // CheckAuthorization
    try std.testing.expectEqual(wire.msg_method_return, frames.next().?.kind);
    try std.testing.expectEqualStrings("PropertiesChanged", frames.next().?.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try expectProfileFile(&tmp, "performance");
}

test "Set with an unreadable kernel file replies with an error and no signal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    daemon.sysfs.path = "/nonexistent/platform_profile";
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var set_buf: [512]u8 = undefined;
    var set = try buildSet(&set_buf, "performance");
    try pair.queue(&set);
    var auth_buf: [256]u8 = undefined;
    var auth = try polkitReply(&auth_buf, bus.t.next_serial, true);
    try pair.queue(&auth);
    try pair.serve();

    var out: [2048]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    _ = frames.next().?;
    const reply = frames.next().?;
    try std.testing.expectEqual(wire.msg_error, reply.kind);
    try std.testing.expectEqualStrings(err_not_supported, reply.err_name);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expectEqual(profile_mod.Profile.balanced, daemon.active);
}

test "Introspect lists the retained properties only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w: wire.Writer = .{ .buf = &buf };
    try w.beginCall(7, bus_name, object_path, iface_introspectable, "Introspect", "", ":1.99");
    var out: [4096]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    var r: wire.Reader = .{ .buf = reply.body };
    const xml = try r.getStr();
    for (std.enums.values(Prop)) |prop| {
        var needle: [64]u8 = undefined;
        const text = try std.mem.print(&needle, "<property name=\"{s}\"", .{@tagName(prop)});
        try std.testing.expect(std.mem.find(u8, xml, text) != null);
    }
    try std.testing.expect(std.mem.find(u8, xml, "HoldProfile") == null);
    try std.testing.expectEqual(std.enums.values(Prop).len, std.mem.count(u8, xml, "<property "));
}

test "Ping, unknown methods and unknown objects get replies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    const Case = struct { path: []const u8, iface: []const u8, member: []const u8, err: ?[]const u8 };
    const cases = [_]Case{
        .{ .path = object_path, .iface = iface_peer, .member = "Ping", .err = null },
        .{ .path = object_path, .iface = interface, .member = "HoldProfile", .err = err_unknown_method },
        .{ .path = "/org/freedesktop/UPower/Other", .iface = iface_properties, .member = "Get", .err = err_unknown_object },
    };
    for (cases) |c| {
        var buf: [512]u8 = undefined;
        var w: wire.Writer = .{ .buf = &buf };
        try w.beginCall(7, bus_name, c.path, c.iface, c.member, "", ":1.99");
        var out: [512]u8 = undefined;
        const reply = try pair.roundTrip(&w, &out);
        if (c.err) |name| {
            try std.testing.expectEqual(wire.msg_error, reply.kind);
            try std.testing.expectEqualStrings(name, reply.err_name);
        } else {
            try std.testing.expectEqual(wire.msg_method_return, reply.kind);
        }
    }
}

test "Get accepts an empty interface like GetAll" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "performance\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    var buf: [512]u8 = undefined;
    var w = try buildProps(&buf, "Get", "ss");
    try w.putStr("");
    try w.putStr("ActiveProfile");
    var out: [512]u8 = undefined;
    const reply = try pair.roundTrip(&w, &out);
    try std.testing.expectEqual(wire.msg_method_return, reply.kind);

    w = try buildProps(&buf, "Get", "ss");
    try w.putStr("org.freedesktop.UPower.Other");
    try w.putStr("ActiveProfile");
    const bad = try pair.roundTrip(&w, &out);
    try std.testing.expectEqualStrings(err_unknown_interface, bad.err_name);
}

test "serviceWatch announces an external change exactly once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();
    var out: [1024]u8 = undefined;

    try bus.serviceWatch();
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&out).len);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "low-power\n" });
    try bus.serviceWatch();
    var frames: Frames = .{ .rest = pair.drain(&out) };
    const signal = frames.next().?;
    try std.testing.expectEqualStrings("PropertiesChanged", signal.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expectEqual(profile_mod.Profile.power_saver, daemon.active);

    try bus.serviceWatch();
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&out).len);
}

test "serviceWatch reports a lost watch after repeated read failures" {
    var fds: [2]linux.fd_t = undefined;
    try std.testing.expect(linux.errno(linux.pipe2(&fds, .{ .CLOEXEC = true })) == .SUCCESS);
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);
    // pread on a pipe fails with ESPIPE.
    var daemon: Daemon = .{ .sysfs = .{ .path = "/unused", .fd = fds[0] }, .active = .balanced };
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    try bus.serviceWatch();
    try bus.serviceWatch();
    try std.testing.expectError(error.WatchLost, bus.serviceWatch());
}
