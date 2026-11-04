//! The one fixed profile mapping shared by the daemon and the init helper:
//!
//!     D-Bus        kernel
//!     power-saver  low-power
//!     balanced     balanced
//!     performance  performance
const std = @import("std");

pub const ParseError = error{ Custom, Unknown };

pub const Profile = enum {
    power_saver,
    balanced,
    performance,

    /// The D-Bus `ActiveProfile` value.
    pub fn dbusName(self: Profile) [:0]const u8 {
        return switch (self) {
            .power_saver => "power-saver",
            .balanced => "balanced",
            .performance => "performance",
        };
    }

    /// The exact bytes written to `platform_profile`.
    pub fn kernelLine(self: Profile) []const u8 {
        return switch (self) {
            .power_saver => "low-power\n",
            .balanced => "balanced\n",
            .performance => "performance\n",
        };
    }

    pub fn parseDbus(value: []const u8) ?Profile {
        inline for (std.enums.values(Profile)) |p| {
            if (std.mem.eql(u8, value, p.dbusName())) return p;
        }
        return null;
    }

    /// Parses `platform_profile` contents: exactly a supported name with at
    /// most one trailing newline, as sysfs produces. No other whitespace is
    /// tolerated and nothing falls back to a default.
    pub fn parseKernel(bytes: []const u8) ParseError!Profile {
        const text = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes[0 .. bytes.len - 1] else bytes;
        inline for (std.enums.values(Profile)) |p| {
            const line = comptime p.kernelLine();
            if (std.mem.eql(u8, text, line[0 .. line.len - 1])) return p;
        }
        if (std.mem.eql(u8, text, "custom")) return error.Custom;
        return error.Unknown;
    }
};

test "kernel lines round trip through the strict parser" {
    for (std.enums.values(Profile)) |p| {
        try std.testing.expectEqual(p, try Profile.parseKernel(p.kernelLine()));
        const line = p.kernelLine();
        try std.testing.expectEqual(p, try Profile.parseKernel(line[0 .. line.len - 1]));
    }
}

test "fixed dbus to kernel mapping" {
    try std.testing.expectEqualStrings("low-power\n", Profile.power_saver.kernelLine());
    try std.testing.expectEqualStrings("balanced\n", Profile.balanced.kernelLine());
    try std.testing.expectEqualStrings("performance\n", Profile.performance.kernelLine());
    try std.testing.expectEqual(Profile.power_saver, try Profile.parseKernel("low-power\n"));
}

test "kernel parsing is strict" {
    try std.testing.expectError(error.Custom, Profile.parseKernel("custom\n"));
    try std.testing.expectError(error.Custom, Profile.parseKernel("custom"));
    for ([_][]const u8{ "", "\n", "quiet\n", "cool\n", "balanced-performance\n", "power-saver\n", " balanced\n", "balanced \n", "balanced\n\n", "balanced\r\n", "balanced\x00" }) |bad| {
        try std.testing.expectError(error.Unknown, Profile.parseKernel(bad));
    }
}

test "dbus profile name parsing is strict" {
    try std.testing.expectEqual(@as(?Profile, .power_saver), Profile.parseDbus("power-saver"));
    try std.testing.expectEqual(@as(?Profile, .balanced), Profile.parseDbus("balanced"));
    try std.testing.expectEqual(@as(?Profile, .performance), Profile.parseDbus("performance"));
    try std.testing.expectEqual(@as(?Profile, null), Profile.parseDbus(""));
    try std.testing.expectEqual(@as(?Profile, null), Profile.parseDbus("low-power"));
    try std.testing.expectEqual(@as(?Profile, null), Profile.parseDbus("balanced "));
    try std.testing.expectEqual(@as(?Profile, null), Profile.parseDbus("turbo"));
}
