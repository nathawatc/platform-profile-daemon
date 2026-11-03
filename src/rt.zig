//! Minimal libc-free runtime shared by both executables.
//!
//! Replaces the std panic and log handlers, which would otherwise pull in
//! stack unwinding, debug-info loading and `std.Io.Threaded`. Everything here
//! is a raw `write(2)` to a file descriptor.
const std = @import("std");
const linux = std.os.linux;

pub const std_options: std.Options = .{
    .logFn = logFn,
    .signal_stack_size = null,
    .enable_segfault_handler = false,
    .allow_stack_tracing = false,
    .unexpected_error_tracing = false,
    .networking = false,
};

/// Best-effort write of all bytes. Errors are ignored: this only reports.
pub fn writeFd(fd: linux.fd_t, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const rc = linux.write(fd, rest.ptr, rest.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                if (rc == 0) return;
                rest = rest[rc..];
            },
            .INTR => {},
            else => return,
        }
    }
}

pub fn writeStdout(bytes: []const u8) void {
    writeFd(1, bytes);
}

pub fn exit(code: u8) noreturn {
    linux.exit_group(code);
}

/// Panic handler body for `std.debug.FullPanic`. Trapping (SIGILL) makes
/// systemd record a failure so `Restart=on-failure` applies.
pub fn panicFn(msg: []const u8, _: ?usize) noreturn {
    @branchHint(.cold);
    writeFd(2, "panic: ");
    writeFd(2, msg);
    writeFd(2, "\n");
    @trap();
}

/// Logs one line to stderr with an sd-daemon priority prefix that journald
/// understands. Messages longer than the buffer are truncated.
pub fn logFn(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    var buf: [512]u8 = undefined;
    writeFd(2, formatLine(&buf, level, scope, format, args));
}

/// Formats `<prio>[scope: ]message\n` into `buf`, truncating the message but
/// always keeping the trailing newline.
fn formatLine(
    buf: []u8,
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) []const u8 {
    const prefix = comptime switch (level) {
        .err => "<3>",
        .warn => "<4>",
        .info => "<6>",
        .debug => "<7>",
    };
    const scope_prefix = comptime if (scope == .default) "" else @tagName(scope) ++ ": ";

    // Reserve the last byte for the newline.
    var w: std.Io.Writer = .fixed(buf[0 .. buf.len - 1]);
    w.writeAll(prefix ++ scope_prefix) catch {};
    w.print(format, args) catch {};
    // Annotated: @min against a comptime bound would otherwise narrow.
    const len: usize = @min(w.end, buf.len - 1);
    buf[len] = '\n';
    return buf[0 .. len + 1];
}

test "formatLine adds priority prefix, scope and newline" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("<3>boom 7\n", formatLine(&buf, .err, .default, "boom {d}", .{7}));
    try std.testing.expectEqualStrings("<4>net: hi\n", formatLine(&buf, .warn, .net, "hi", .{}));
}

test "formatLine truncates without overflowing and keeps the newline" {
    const long: [1024]u8 = @splat('x');
    var buf: [32]u8 = undefined;
    const line = formatLine(&buf, .debug, .default, "{s}", .{&long});
    try std.testing.expectEqual(buf.len, line.len);
    try std.testing.expectEqual(@as(u8, '\n'), line[line.len - 1]);
    try std.testing.expect(std.mem.startsWith(u8, line, "<7>xxx"));
}
