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
const notify = @import("notify.zig");
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
/// Profile changes that may await Polkit at once.
const max_pending = 8;

const POLLIN: i16 = linux.POLL.IN;
const POLLPRI: i16 = linux.POLL.PRI;
const POLLERR: i16 = linux.POLL.ERR;
const POLLHUP: i16 = linux.POLL.HUP;
const POLLNVAL: i16 = linux.POLL.NVAL;
/// Events requested on the watch fd, and the revents that mean "go look".
const watch_events: i16 = POLLPRI | POLLERR;
const watch_ready: i16 = watch_events | POLLHUP | POLLNVAL;

/// The retained properties. Tag names are the D-Bus property names, so this is
/// the one place that defines them: Get, GetAll, Set and the introspection
/// data are all derived from it.
const Prop = enum {
    ActiveProfile,
    PerformanceDegraded,
    Profiles,
    Actions,
    ActionsInfo,
    ActiveProfileHolds,
    Version,

    /// D-Bus type signature of the property value.
    fn signature(self: Prop) []const u8 {
        return switch (self) {
            .ActiveProfile, .PerformanceDegraded, .Version => "s",
            .Actions => "as",
            .Profiles, .ActionsInfo, .ActiveProfileHolds => "aa{sv}",
        };
    }

    /// Only ActiveProfile can be set, and it is the only one that changes.
    fn writable(self: Prop) bool {
        return self == .ActiveProfile;
    }
};

/// One `<property>` entry. Plain concatenation: std.fmt would drag its
/// error-name table into the binary.
fn propertyXml(comptime prop: Prop) []const u8 {
    const emits = if (prop.writable()) "true" else "false";
    return "  <property name=\"" ++ @tagName(prop) ++ "\" type=\"" ++ prop.signature() ++
        "\" access=\"" ++ (if (prop.writable()) "readwrite" else "read") ++ "\">\n" ++
        "   <annotation name=\"org.freedesktop.DBus.Property.EmitsChangedSignal\" value=\"" ++ emits ++ "\"/>\n" ++
        "  </property>\n";
}

/// Fixed interfaces, then one block per `Prop`, then the closing tags.
/// Built into one exactly-sized array so no intermediate strings are emitted.
const introspection_xml: []const u8 = blk: {
    const head = @embedFile("dbus/introspection_head.xml");
    const tail = @embedFile("dbus/introspection_tail.xml");
    var len = head.len + tail.len;
    for (std.enums.values(Prop)) |prop| len += propertyXml(prop).len;
    var buf: [len]u8 = undefined;
    @memcpy(buf[0..head.len], head);
    var at: usize = head.len;
    for (std.enums.values(Prop)) |prop| {
        const part = propertyXml(prop);
        @memcpy(buf[at..][0..part.len], part);
        at += part.len;
    }
    @memcpy(buf[at..][0..tail.len], tail);
    const final = buf;
    break :blk &final;
};

const ServeError = error{ NoSpace, SendFailed, RecvFailed, Closed, PollFailed, Protocol, Timeout, WatchLost };

fn nowMs() i64 {
    var ts: linux.timespec = undefined;
    // Raw syscall: skip std's vDSO lookup code.
    _ = linux.syscall2(.clock_gettime, @backingInt(linux.clockid_t.MONOTONIC), @intFromPtr(&ts));
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

/// `poll(2)` on the bus socket and the profile watch fd. A parameter of
/// `serveOnce` so tests can report events a regular file never raises.
fn rawPoll(fds: *[2]linux.pollfd, timeout_ms: i32) usize {
    return linux.poll(fds, 2, timeout_ms);
}

/// A profile change waiting for Polkit: everything needed to answer the
/// original call once the verdict arrives.
const Pending = struct {
    polkit_serial: u32,
    deadline_ms: i64,
    call_serial: u32,
    call_flags: u8,
    sender: [255]u8,
    sender_len: u8,
    requested: profile_mod.Profile,

    /// The original call, as far as replies need it.
    fn call(self: *const Pending) wire.Message {
        return .{
            .kind = wire.msg_method_call,
            .flags = self.call_flags,
            .serial = self.call_serial,
            .sender = self.sender[0..self.sender_len],
        };
    }
};

const Bus = struct {
    t: transport.Transport,
    daemon: *Daemon,
    out: [8192]u8 = undefined,
    /// Entries are valid only where `pending_mask` has the bit set. Kept apart
    /// so the default `Bus` value stays tiny: a default array of entries
    /// would be emitted into `.rodata`.
    pending: [max_pending]Pending = undefined,
    pending_mask: u8 = 0,
    notifier: notify.Notifier = .{},

    fn writer(self: *Bus) wire.Writer {
        return .{ .buf = &self.out };
    }

    /// Dispatches every complete buffered frame: Polkit verdicts complete
    /// their pending change, method calls are handled, the rest is ignored.
    fn pump(self: *Bus) ServeError!void {
        while (try self.t.nextFrame()) |frame| {
            const m = wire.parseMessage(frame) orelse continue;
            if (m.kind == wire.msg_method_return or m.kind == wire.msg_error) {
                if (self.findPending(m.reply_serial)) |i| try self.finishAuthorization(i, m);
                continue;
            }
            try self.handle(m);
        }
    }

    /// One iteration of the service loop: serve buffered frames, time out
    /// overdue authorizations, then wait for the bus or the profile watch.
    fn serveOnce(self: *Bus, comptime poll_fn: anytype) ServeError!void {
        self.notifier.ping(nowMs());
        try self.pump();
        try self.expirePending();

        var fds = [2]linux.pollfd{
            .{ .fd = self.t.fd, .events = POLLIN, .revents = 0 },
            .{ .fd = self.daemon.sysfs.fd, .events = watch_events, .revents = 0 },
        };
        switch (linux.errno(poll_fn(&fds, self.nextTimeoutMs()))) {
            .SUCCESS => {},
            .INTR => return,
            else => return error.PollFailed,
        }
        if (fds[0].revents != 0) try self.t.recv();
        if (fds[1].revents & watch_ready != 0) try self.serviceWatch();
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

    // -- pending authorizations ---------------------------------------------

    fn isPending(self: *const Bus, i: usize) bool {
        return self.pending_mask & (@as(u8, 1) << @intCast(i)) != 0;
    }

    fn setPending(self: *Bus, i: usize, used: bool) void {
        const bit = @as(u8, 1) << @intCast(i);
        if (used) self.pending_mask |= bit else self.pending_mask &= ~bit;
    }

    fn pendingCount(self: *const Bus) usize {
        return @popCount(self.pending_mask);
    }

    fn findPending(self: *const Bus, polkit_serial: u32) ?usize {
        for (0..max_pending) |i| {
            if (self.isPending(i) and self.pending[i].polkit_serial == polkit_serial) return i;
        }
        return null;
    }

    fn freePending(self: *const Bus) ?usize {
        for (0..max_pending) |i| {
            if (!self.isPending(i)) return i;
        }
        return null;
    }

    /// Milliseconds until the loop must wake without any I/O: the earliest
    /// authorization deadline or the next watchdog ping. -1 means never.
    fn nextTimeoutMs(self: *const Bus) i32 {
        const now = nowMs();
        var wait = self.notifier.nextPingMs(now);
        for (0..max_pending) |i| {
            if (!self.isPending(i)) continue;
            const left: i32 = @intCast(std.math.clamp(self.pending[i].deadline_ms - now, 0, std.math.maxInt(i32)));
            wait = if (wait < 0) left else @min(wait, left);
        }
        return wait;
    }

    /// Answers every authorization whose deadline has passed.
    fn expirePending(self: *Bus) ServeError!void {
        const now = nowMs();
        for (0..max_pending) |i| {
            if (!self.isPending(i) or self.pending[i].deadline_ms > now) continue;
            self.setPending(i, false);
            var buf: [256]u8 = undefined;
            try self.replyError(self.pending[i].call(), err_access_denied, polkit.failure(&buf, "timed out"));
        }
    }

    /// Polkit answered: deny, or apply the change.
    fn finishAuthorization(self: *Bus, i: usize, verdict: wire.Message) ServeError!void {
        self.setPending(i, false);
        const slot = &self.pending[i];
        const req = slot.call();
        var denied_buf: [256]u8 = undefined;
        if (polkit.decide(verdict, &denied_buf)) |denied| {
            return self.replyError(req, err_access_denied, denied);
        }
        try self.applyProfile(req, slot.requested);
    }

    /// Writes the authorized request and answers the caller.
    fn applyProfile(self: *Bus, req: wire.Message, requested: profile_mod.Profile) ServeError!void {
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

    // -- startup ------------------------------------------------------------

    /// Startup only: sends the call in `w` and waits for its reply. No method
    /// call can arrive before the name is owned, so nothing is dispatched.
    fn transact(self: *Bus, w: *wire.Writer, serial: u32) ServeError!wire.Message {
        w.finish();
        try self.t.send(w.bytes());
        const deadline = nowMs() + call_timeout_ms;
        while (true) {
            while (try self.t.nextFrame()) |frame| {
                const m = wire.parseMessage(frame) orelse continue;
                if ((m.kind == wire.msg_method_return or m.kind == wire.msg_error) and m.reply_serial == serial) return m;
            }
            const left = deadline - nowMs();
            if (left <= 0) return error.Timeout;
            var pfd = [1]linux.pollfd{.{ .fd = self.t.fd, .events = POLLIN, .revents = 0 }};
            const rc = linux.poll(&pfd, 1, @intCast(left));
            switch (linux.errno(rc)) {
                .SUCCESS => {},
                .INTR => continue,
                else => return error.PollFailed,
            }
            if (rc == 0) return error.Timeout;
            try self.t.recv();
        }
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
        self.notifier.ready();
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
        try w.putSig(prop.signature());
        switch (prop) {
            .ActiveProfile => try w.putStr(self.daemon.active.dbusName()),
            .PerformanceDegraded => try w.putStr(""),
            .Version => try w.putStr(build_options.version),
            .Actions, .ActionsInfo, .ActiveProfileHolds => {
                const empty = try w.beginArray(4);
                w.endArray(empty, 4);
            },
            .Profiles => {
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

        if (m.sender.len == 0 or m.sender.len > 255) {
            return self.replyError(m, err_failed, "failed to resolve D-Bus sender");
        }
        const i = self.freePending() orelse
            return self.replyError(m, err_failed, "too many pending profile changes");

        // Ask Polkit and return to the loop; the verdict arrives as a reply
        // that `pump` routes to `finishAuthorization`.
        const serial = self.t.takeSerial();
        var w = self.writer();
        try polkit.writeRequest(&w, serial, m.sender);
        w.finish();
        try self.t.send(w.bytes());
        self.pending[i] = .{
            .polkit_serial = serial,
            .deadline_ms = nowMs() + call_timeout_ms,
            .call_serial = m.serial,
            .call_flags = m.flags,
            .sender = undefined,
            .sender_len = @intCast(m.sender.len),
            .requested = requested,
        };
        @memcpy(self.pending[i].sender[0..m.sender.len], m.sender);
        self.setPending(i, true);
    }
};

/// Process environment the service reads; all optional.
pub const RunOptions = struct {
    /// `DBUS_SYSTEM_BUS_ADDRESS`: overrides the default system bus address.
    bus_address: ?[]const u8 = null,
    /// `NOTIFY_SOCKET`: where to report readiness (systemd `Type=notify`).
    notify_socket: ?[]const u8 = null,
    /// `WATCHDOG_USEC`: the watchdog period (systemd `WatchdogSec=`).
    watchdog_usec: ?[]const u8 = null,
};

/// Connects to the system bus, claims the service name, and serves requests
/// and platform_profile change events until the connection or the profile
/// watch fails.
pub fn run(daemon: *Daemon, options: RunOptions) !void {
    const fd = try transport.connect(options.bus_address);
    defer _ = linux.close(fd);

    var bus: Bus = .{
        .t = .{ .fd = fd },
        .daemon = daemon,
        .notifier = .init(options.notify_socket, options.watchdog_usec),
    };
    defer bus.notifier.deinit();
    try bus.start();
    while (true) try bus.serveOnce(rawPoll);
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
        try self.bus.pump();
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
    return buildSetAs(buf, 7, value);
}

fn buildSetAs(buf: []u8, serial: u32, value: []const u8) !wire.Writer {
    var w: wire.Writer = .{ .buf = buf };
    try w.beginCall(serial, bus_name, object_path, iface_properties, "Set", "ssv", ":1.99");
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
    try std.testing.expectEqual(@as(usize, 0), bus.pendingCount());
    var idle: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&idle).len);
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

test "generated introspection describes every property from Prop" {
    try std.testing.expect(std.mem.find(u8, introspection_xml,
        \\  <property name="ActiveProfile" type="s" access="readwrite">
        \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="true"/>
        \\  </property>
        \\
    ) != null);
    try std.testing.expect(std.mem.find(u8, introspection_xml,
        \\  <property name="Profiles" type="aa{sv}" access="read">
        \\   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
        \\  </property>
        \\
    ) != null);
    try std.testing.expect(std.mem.endsWith(u8, introspection_xml, "  </property>\n </interface>\n</node>\n"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, introspection_xml, "access=\"readwrite\""));
}

test "property variants carry the signature that introspection declares" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    for (std.enums.values(Prop)) |prop| {
        var buf: [512]u8 = undefined;
        var w = try buildProps(&buf, "Get", "ss");
        try w.putStr(interface);
        try w.putStr(@tagName(prop));
        var out: [1024]u8 = undefined;
        const reply = try pair.roundTrip(&w, &out);
        var r: wire.Reader = .{ .buf = reply.body };
        try std.testing.expectEqualStrings(prop.signature(), try r.getSig());
    }
}

fn queueSet(pair: TestPair, serial: u32, value: []const u8) !void {
    var buf: [512]u8 = undefined;
    var w = try buildSetAs(&buf, serial, value);
    try pair.queue(&w);
}

fn queueVerdict(pair: TestPair, request_serial: u32, authorized: bool) !void {
    var buf: [256]u8 = undefined;
    var w = try polkitReply(&buf, request_serial, authorized);
    try pair.queue(&w);
}

fn errorText(m: wire.Message) ![]const u8 {
    var r: wire.Reader = .{ .buf = m.body };
    return r.getStr();
}

test "Set returns to the loop while Polkit is pending" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    try queueSet(pair, 7, "performance");
    try pair.serve();
    var out: [2048]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    const request = frames.next().?;
    try std.testing.expectEqualStrings("CheckAuthorization", request.member);
    // Nothing else yet: no reply, no signal, no write.
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expect(bus.isPending(0));
    try expectProfileFile(&tmp, "balanced\n");

    try queueVerdict(pair, request.serial, true);
    try pair.serve();
    frames = .{ .rest = pair.drain(&out) };
    const reply = frames.next().?;
    try std.testing.expectEqual(wire.msg_method_return, reply.kind);
    try std.testing.expectEqual(@as(u32, 7), reply.reply_serial);
    try std.testing.expectEqualStrings("PropertiesChanged", frames.next().?.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expectEqual(@as(usize, 0), bus.pendingCount());
    try expectProfileFile(&tmp, "performance\n");
}

test "concurrent Sets complete in the order Polkit answers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    try queueSet(pair, 7, "performance");
    try queueSet(pair, 8, "power-saver");
    try pair.serve();
    var out: [4096]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    const first = frames.next().?;
    const second = frames.next().?;
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());

    // Answer the second request first.
    try queueVerdict(pair, second.serial, true);
    try queueVerdict(pair, first.serial, true);
    try pair.serve();
    frames = .{ .rest = pair.drain(&out) };
    try std.testing.expectEqual(@as(u32, 8), frames.next().?.reply_serial);
    try std.testing.expectEqualStrings("PropertiesChanged", frames.next().?.member);
    try std.testing.expectEqual(@as(u32, 7), frames.next().?.reply_serial);
    try std.testing.expectEqualStrings("PropertiesChanged", frames.next().?.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    // The slower verdict was applied last, on top of the faster one.
    try expectProfileFile(&tmp, "performance\n");
}

test "a Set beyond the pending limit fails immediately" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    for (0..max_pending + 1) |i| try queueSet(pair, @intCast(10 + i), "performance");
    try pair.serve();
    var out: [8192]u8 = undefined;
    var frames: Frames = .{ .rest = pair.drain(&out) };
    for (0..max_pending) |_| try std.testing.expectEqualStrings("CheckAuthorization", frames.next().?.member);
    const refused = frames.next().?;
    try std.testing.expectEqual(wire.msg_error, refused.kind);
    try std.testing.expectEqualStrings(err_failed, refused.err_name);
    try std.testing.expectEqual(@as(u32, 10 + max_pending), refused.reply_serial);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
}

test "an unanswered authorization times out as denied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    try queueSet(pair, 7, "performance");
    try pair.serve();
    var out: [2048]u8 = undefined;
    _ = pair.drain(&out);

    try bus.expirePending();
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&out).len); // not overdue yet
    bus.pending[0].deadline_ms = 0;
    try bus.expirePending();
    var frames: Frames = .{ .rest = pair.drain(&out) };
    const reply = frames.next().?;
    try std.testing.expectEqualStrings(err_access_denied, reply.err_name);
    try std.testing.expect(std.mem.find(u8, try errorText(reply), "timed out") != null);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expectEqual(@as(usize, 0), bus.pendingCount());
    try expectProfileFile(&tmp, "balanced");
}

test "verdicts for unknown requests are ignored" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();

    try queueVerdict(pair, 12345, true);
    try pair.serve();
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&out).len);
    try expectProfileFile(&tmp, "balanced");
}

const FakePoll = struct {
    var timeout: i32 = 0;
    fn watchEvent(fds: *[2]linux.pollfd, timeout_ms: i32) usize {
        timeout = timeout_ms;
        fds[1].revents = POLLPRI;
        return 1;
    }
};

test "the loop waits indefinitely when idle and never starves the profile watch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();
    var out: [2048]u8 = undefined;

    // Idle: no deadline, so poll may block indefinitely; an unchanged
    // profile announces nothing.
    try bus.serveOnce(FakePoll.watchEvent);
    try std.testing.expectEqual(@as(i32, -1), FakePoll.timeout);
    try std.testing.expectEqual(@as(usize, 0), pair.drain(&out).len);

    // With an authorization pending, poll is bounded by its deadline, and a
    // hardware profile change is still announced while the prompt is open.
    try queueSet(pair, 7, "performance");
    try pair.serve();
    _ = pair.drain(&out);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "p", .data = "low-power\n" });
    try bus.serveOnce(FakePoll.watchEvent);
    try std.testing.expect(FakePoll.timeout > 0 and FakePoll.timeout <= call_timeout_ms);
    var frames: Frames = .{ .rest = pair.drain(&out) };
    try std.testing.expectEqualStrings("PropertiesChanged", frames.next().?.member);
    try std.testing.expectEqual(@as(?wire.Message, null), frames.next());
    try std.testing.expect(bus.isPending(0));
    try std.testing.expectEqual(profile_mod.Profile.power_saver, daemon.active);
}

test "the watchdog ping bounds the poll timeout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path: [max_path]u8 = undefined;
    var daemon = try testDaemon(&tmp, &path, "balanced\n");
    defer daemon.deinit();
    var bus: Bus = undefined;
    const pair = try TestPair.init(&bus, &daemon);
    defer pair.deinit();
    // No socket (fd -1) so nothing is sent, but the schedule still runs.
    bus.notifier = .{ .interval_ms = 10_000 };

    try bus.serveOnce(FakePoll.watchEvent);
    try std.testing.expect(FakePoll.timeout > 0 and FakePoll.timeout <= 10_000);
}
