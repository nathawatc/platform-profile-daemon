//! Polkit `CheckAuthorization` request encoding and reply decoding.
//!
//! Pure functions over wire messages: no I/O, so every outcome is unit tested.
const std = @import("std");
const wire = @import("wire.zig");

pub const service = "org.freedesktop.PolicyKit1";
pub const path = "/org/freedesktop/PolicyKit1/Authority";
pub const interface = "org.freedesktop.PolicyKit1.Authority";
pub const action = "net.hadess.PowerProfiles.switch-profile";

const allow_user_interaction: u32 = 1;

/// Longest reason text copied into a denial message.
const max_reason_len = 160;

/// Writes the CheckAuthorization call for the bus name `sender`; the caller
/// calls `finish`.
pub fn writeRequest(w: *wire.Writer, serial: u32, sender: []const u8) !void {
    try w.beginCall(serial, service, path, interface, "CheckAuthorization", "(sa{sv})sa{ss}us", "");
    try w.alignTo(8); // STRUCT subject
    try w.putStr("system-bus-name");
    const details = try w.beginArray(8);
    try w.alignTo(8);
    try w.putStr("name");
    try w.putSig("s");
    try w.putStr(sender);
    w.endArray(details, 8);
    try w.putStr(action);
    const empty = try w.beginArray(8);
    w.endArray(empty, 8);
    try w.putU32(allow_user_interaction);
    try w.putStr("");
}

/// Decodes the reply. Returns null when the sender is authorized, otherwise
/// the denial text (formatted into `buf`).
pub fn decide(reply: wire.Message, buf: []u8) ?[]const u8 {
    if (reply.kind == wire.msg_error) {
        var text: []const u8 = "unknown error";
        if (wire.eql(reply.sig, "s")) {
            var r: wire.Reader = .{ .buf = reply.body };
            text = r.getStr() catch text;
        }
        return failure(buf, text);
    }
    if (!wire.eql(reply.sig, "(bba{ss})")) return failure(buf, "malformed reply");

    var r: wire.Reader = .{ .buf = reply.body };
    r.alignTo(8) catch return failure(buf, "malformed reply");
    const authorized = r.getU32() catch return failure(buf, "malformed reply");
    const challenge = r.getU32() catch return failure(buf, "malformed reply");
    if (authorized != 0) return null;
    return if (challenge != 0)
        "authentication required to switch power profile"
    else
        "not authorized to switch power profile";
}

/// "polkit authorization failed: <reason>", with `reason` cut on a UTF-8 boundary.
pub fn failure(buf: []u8, reason: []const u8) []const u8 {
    return std.mem.print(buf, "polkit authorization failed: {s}", .{utf8Prefix(reason, max_reason_len)}) catch
        "polkit authorization failed";
}

/// Longest prefix of `s` that is at most `max` bytes and does not split a UTF-8 sequence.
fn utf8Prefix(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var n = max;
    while (n > 0 and (s[n] & 0xC0) == 0x80) n -= 1;
    return s[0..n];
}

fn testReply(kind: u8, sig: []const u8, body: []const u8) wire.Message {
    return .{ .kind = kind, .flags = 0, .serial = 1, .sig = sig, .body = body };
}

fn authorityReply(buf: []u8, authorized: u32, challenge: u32) !wire.Message {
    var w: wire.Writer = .{ .buf = buf };
    try w.alignTo(8);
    try w.putU32(authorized);
    try w.putU32(challenge);
    const details = try w.beginArray(8);
    w.endArray(details, 8);
    return testReply(wire.msg_method_return, "(bba{ss})", w.bytes());
}

test "request is a well formed call carrying subject, action and flags" {
    var buf: [512]u8 = undefined;
    var w: wire.Writer = .{ .buf = &buf };
    try writeRequest(&w, 9, ":1.42");
    w.finish();
    const m = wire.parseMessage(w.bytes()).?;
    try std.testing.expectEqual(@as(u32, 9), m.serial);
    try std.testing.expectEqualStrings(service, "org.freedesktop.PolicyKit1");
    try std.testing.expectEqualStrings(path, m.path);
    try std.testing.expectEqualStrings(interface, m.iface);
    try std.testing.expectEqualStrings("CheckAuthorization", m.member);
    try std.testing.expectEqualStrings("(sa{sv})sa{ss}us", m.sig);

    var r: wire.Reader = .{ .buf = m.body };
    try r.alignTo(8);
    try std.testing.expectEqualStrings("system-bus-name", try r.getStr());
    const details_len = try r.getU32();
    try r.alignTo(8);
    const details_end = r.pos + details_len;
    try std.testing.expectEqualStrings("name", try r.getStr());
    try std.testing.expectEqualStrings("s", try r.getSig());
    try std.testing.expectEqualStrings(":1.42", try r.getStr());
    try std.testing.expectEqual(details_end, r.pos);
    try std.testing.expectEqualStrings(action, try r.getStr());
    try std.testing.expectEqual(@as(u32, 0), try r.getU32()); // empty a{ss}
    try r.alignTo(8); // dict entries are 8-aligned even when there are none
    try std.testing.expectEqual(allow_user_interaction, try r.getU32());
    try std.testing.expectEqualStrings("", try r.getStr());
    try std.testing.expectEqual(m.body.len, r.pos);
}

test "authorized reply yields no denial" {
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    try std.testing.expectEqual(@as(?[]const u8, null), decide(try authorityReply(&buf, 1, 0), &out));
    try std.testing.expectEqual(@as(?[]const u8, null), decide(try authorityReply(&buf, 1, 1), &out));
}

test "denied replies distinguish challenge from refusal" {
    var buf: [64]u8 = undefined;
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings("authentication required to switch power profile", decide(try authorityReply(&buf, 0, 1), &out).?);
    try std.testing.expectEqualStrings("not authorized to switch power profile", decide(try authorityReply(&buf, 0, 0), &out).?);
}

test "error and malformed replies deny with a reason" {
    var body: [64]u8 = undefined;
    var w: wire.Writer = .{ .buf = &body };
    try w.putStr("no such action");
    var out: [256]u8 = undefined;
    try std.testing.expectEqualStrings(
        "polkit authorization failed: no such action",
        decide(testReply(wire.msg_error, "s", w.bytes()), &out).?,
    );
    try std.testing.expectEqualStrings(
        "polkit authorization failed: unknown error",
        decide(testReply(wire.msg_error, "", ""), &out).?,
    );
    try std.testing.expectEqualStrings(
        "polkit authorization failed: malformed reply",
        decide(testReply(wire.msg_method_return, "u", ""), &out).?,
    );
    try std.testing.expectEqualStrings(
        "polkit authorization failed: malformed reply",
        decide(testReply(wire.msg_method_return, "(bba{ss})", "\x01"), &out).?,
    );
}

test "denial text is truncated on a UTF-8 boundary and fits its buffer" {
    try std.testing.expectEqualStrings("ab", utf8Prefix("ab\xc3\xa9", 3));
    try std.testing.expectEqualStrings("ab\xc3\xa9", utf8Prefix("ab\xc3\xa9", 4));

    // 159 ASCII bytes then two-byte characters: the limit falls mid-character.
    var long: [259]u8 = undefined;
    @memset(long[0..159], 'a');
    for (0..50) |i| @memcpy(long[159 + 2 * i ..][0..2], "\xc3\xa9");
    var out: [256]u8 = undefined;
    const text = failure(&out, &long);
    try std.testing.expectEqual("polkit authorization failed: ".len + 159, text.len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(text));

    var tiny: [8]u8 = undefined;
    try std.testing.expectEqualStrings("polkit authorization failed", failure(&tiny, "x"));
}

/// Whatever Polkit (or a confused peer) sends, `decide` returns a bounded
/// answer: authorized, or text that fits `out` or is one of the fixed strings.
fn checkDecide(m: wire.Message) !void {
    var out: [256]u8 = undefined;
    const denial = decide(m, &out) orelse return;
    try std.testing.expect(denial.len > 0 and denial.len <= out.len);
    try std.testing.expect(std.mem.startsWith(u8, denial, "polkit authorization failed") or
        std.mem.endsWith(u8, denial, "to switch power profile"));
}

fn fuzzDecide(_: void, smith: *std.testing.Smith) anyerror!void {
    const signatures = [_][]const u8{ "(bba{ss})", "s", "", "u" };
    var sig_buf: [16]u8 = undefined;
    var body: [256]u8 = undefined;
    const sig: []const u8 = if (smith.value(bool))
        signatures[smith.value(u2)]
    else
        sig_buf[0..smith.slice(&sig_buf)];
    try checkDecide(testReply(
        if (smith.value(bool)) wire.msg_method_return else wire.msg_error,
        sig,
        body[0..smith.slice(&body)],
    ));
}

test "fuzz: decide gives a bounded answer for any reply" {
    try std.testing.fuzz({}, fuzzDecide, .{});
}

test "decide survives every truncation of valid and error replies" {
    var buf: [64]u8 = undefined;
    const valid = try authorityReply(&buf, 0, 1);
    for (0..valid.body.len + 1) |n| {
        var m = valid;
        m.body = valid.body[0..n];
        try checkDecide(m);
        m.kind = wire.msg_error;
        m.sig = "s";
        try checkDecide(m);
    }

    // An error text longer than the output buffer is cut, not overrun.
    var long: [600]u8 = undefined;
    var w: wire.Writer = .{ .buf = &long };
    try w.putStr(&@as([300]u8, @splat('x')));
    try checkDecide(testReply(wire.msg_error, "s", w.bytes()));
}
