//! D-Bus wire format: little-endian marshalling and message parsing.
//!
//! Only what the service needs is implemented: STRING, OBJECT_PATH, SIGNATURE,
//! UINT32, arrays, and the header fields below. Big-endian peers are rejected.
const std = @import("std");

pub const msg_method_call: u8 = 1;
pub const msg_method_return: u8 = 2;
pub const msg_error: u8 = 3;
pub const msg_signal: u8 = 4;
pub const flag_no_reply_expected: u8 = 0x1;

pub const field_path: u8 = 1;
pub const field_interface: u8 = 2;
pub const field_member: u8 = 3;
pub const field_error_name: u8 = 4;
pub const field_reply_serial: u8 = 5;
pub const field_destination: u8 = 6;
pub const field_sender: u8 = 7;
pub const field_signature: u8 = 8;

pub const header_len = 16;
pub const max_message_len: u64 = 1 << 27;

pub fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

pub const Writer = struct {
    buf: []u8,
    len: usize = 0,
    body_start: usize = 0,

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf[0..w.len];
    }

    pub fn alignTo(w: *Writer, n: usize) !void {
        const aligned = std.mem.alignForward(usize, w.len, n);
        if (aligned > w.buf.len) return error.NoSpace;
        @memset(w.buf[w.len..aligned], 0);
        w.len = aligned;
    }

    pub fn putRaw(w: *Writer, data: []const u8) !void {
        if (w.len + data.len > w.buf.len) return error.NoSpace;
        @memcpy(w.buf[w.len..][0..data.len], data);
        w.len += data.len;
    }

    pub fn putU8(w: *Writer, v: u8) !void {
        try w.putRaw(&.{v});
    }

    pub fn putU32(w: *Writer, v: u32) !void {
        try w.alignTo(4);
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try w.putRaw(&tmp);
    }

    /// STRING and OBJECT_PATH.
    pub fn putStr(w: *Writer, s: []const u8) !void {
        try w.putU32(@intCast(s.len));
        try w.putRaw(s);
        try w.putU8(0);
    }

    pub fn putSig(w: *Writer, s: []const u8) !void {
        try w.putU8(@intCast(s.len));
        try w.putRaw(s);
        try w.putU8(0);
    }

    fn patchU32(w: *Writer, offset: usize, v: u32) void {
        std.mem.writeInt(u32, w.buf[offset..][0..4], v, .little);
    }

    /// Starts an array whose elements are aligned to `elem_align`; returns the
    /// position of its length word for `endArray`.
    pub fn beginArray(w: *Writer, elem_align: usize) !usize {
        try w.putU32(0);
        const pos = w.len - 4;
        try w.alignTo(elem_align);
        return pos;
    }

    pub fn endArray(w: *Writer, pos: usize, elem_align: usize) void {
        const data_start = std.mem.alignForward(usize, pos + 4, elem_align);
        w.patchU32(pos, @intCast(w.len - data_start));
    }

    pub fn beginMessage(w: *Writer, kind: u8, flags: u8, serial: u32) !void {
        try w.putRaw(&.{ 'l', kind, flags, 1 });
        try w.putU32(0); // body length, patched by finish()
        try w.putU32(serial);
        try w.putU32(0); // header fields length, patched by endFields()
    }

    pub fn fieldStr(w: *Writer, code: u8, typ: u8, s: []const u8) !void {
        try w.alignTo(8);
        try w.putRaw(&.{ code, 1, typ, 0 });
        if (typ == 'g') try w.putSig(s) else try w.putStr(s);
    }

    pub fn fieldU32(w: *Writer, code: u8, v: u32) !void {
        try w.alignTo(8);
        try w.putRaw(&.{ code, 1, 'u', 0 });
        try w.putU32(v);
    }

    pub fn endFields(w: *Writer) !void {
        w.patchU32(12, @intCast(w.len - header_len));
        try w.alignTo(8);
        w.body_start = w.len;
    }

    pub fn finish(w: *Writer) void {
        w.patchU32(4, @intCast(w.len - w.body_start));
    }

    /// Starts a METHOD_CALL; the caller appends the body and calls `finish`.
    pub fn beginCall(
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

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn alignTo(r: *Reader, n: usize) !void {
        const aligned = std.mem.alignForward(usize, r.pos, n);
        if (aligned > r.buf.len) return error.Malformed;
        r.pos = aligned;
    }

    pub fn getU8(r: *Reader) !u8 {
        if (r.pos >= r.buf.len) return error.Malformed;
        defer r.pos += 1;
        return r.buf[r.pos];
    }

    pub fn getU32(r: *Reader) !u32 {
        try r.alignTo(4);
        if (r.pos + 4 > r.buf.len) return error.Malformed;
        defer r.pos += 4;
        return std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
    }

    pub fn getStr(r: *Reader) ![]const u8 {
        const len = try r.getU32();
        if (@as(u64, r.pos) + len + 1 > r.buf.len) return error.Malformed;
        const s = r.buf[r.pos..][0..len];
        if (r.buf[r.pos + len] != 0) return error.Malformed;
        r.pos += len + 1;
        return s;
    }

    pub fn getSig(r: *Reader) ![]const u8 {
        const len = try r.getU8();
        if (r.pos + len + 1 > r.buf.len) return error.Malformed;
        const s = r.buf[r.pos..][0..len];
        if (r.buf[r.pos + len] != 0) return error.Malformed;
        r.pos += @as(usize, len) + 1;
        return s;
    }
};

pub const Message = struct {
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
pub fn frameLength(h: *const [header_len]u8) ?usize {
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
pub fn parseMessage(buf: []const u8) ?Message {
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

test "message round trip preserves header fields and body" {
    var buf: [512]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.beginCall(42, "dest.name", "/a/b", "org.example.Iface", "Get", "ss", ":1.5");
    try w.putStr("first");
    try w.putStr("second");
    w.finish();

    try std.testing.expectEqual(@as(?usize, w.len), frameLength(w.bytes()[0..header_len]));
    const m = parseMessage(w.bytes()).?;
    try std.testing.expectEqual(msg_method_call, m.kind);
    try std.testing.expectEqual(@as(u32, 42), m.serial);
    try std.testing.expectEqualStrings("/a/b", m.path);
    try std.testing.expectEqualStrings("org.example.Iface", m.iface);
    try std.testing.expectEqualStrings("Get", m.member);
    try std.testing.expectEqualStrings("ss", m.sig);
    try std.testing.expectEqualStrings(":1.5", m.sender);

    var r: Reader = .{ .buf = m.body };
    try std.testing.expectEqualStrings("first", try r.getStr());
    try std.testing.expectEqualStrings("second", try r.getStr());
}

test "parser rejects truncated, big-endian and serial-less messages" {
    var buf: [256]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    try w.beginCall(1, "d", "/p", "i", "m", "", "");
    w.finish();
    try std.testing.expect(parseMessage(w.bytes()[0 .. w.len - 1]) == null);

    var copy = buf;
    copy[0] = 'B';
    try std.testing.expect(parseMessage(copy[0..w.len]) == null);

    copy = buf;
    @memset(copy[8..12], 0);
    try std.testing.expect(parseMessage(copy[0..w.len]) == null);
}

test "frameLength bounds oversized frames and rejects unknown endianness" {
    var h: [header_len]u8 = @splat(0);
    h[0] = 'l';
    std.mem.writeInt(u32, h[4..8], 1 << 28, .little);
    try std.testing.expectEqual(@as(?usize, null), frameLength(&h));
    h[0] = 'x';
    try std.testing.expectEqual(@as(?usize, null), frameLength(&h));
}

test "arrays patch their length and honour element alignment" {
    var buf: [64]u8 = undefined;
    var w: Writer = .{ .buf = &buf };
    const arr = try w.beginArray(8);
    try w.alignTo(8);
    try w.putStr("ab");
    w.endArray(arr, 8);
    var r: Reader = .{ .buf = w.bytes() };
    const len = try r.getU32();
    try r.alignTo(8);
    try std.testing.expectEqual(w.len - r.pos, len);
}
