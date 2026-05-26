const std = @import("std");

pub const DbusProfile = enum {
    power_saver,
    balanced,
    performance,

    pub fn fromId(id: c_int) ?DbusProfile {
        return switch (id) {
            0 => .power_saver,
            1 => .balanced,
            2 => .performance,
            else => null,
        };
    }

    pub fn name(self: DbusProfile) [:0]const u8 {
        return switch (self) {
            .power_saver => "power-saver",
            .balanced => "balanced",
            .performance => "performance",
        };
    }

    pub fn parseName(value: []const u8) ?DbusProfile {
        if (std.mem.eql(u8, value, "power-saver")) return .power_saver;
        if (std.mem.eql(u8, value, "balanced")) return .balanced;
        if (std.mem.eql(u8, value, "performance")) return .performance;
        return null;
    }
};

pub const KernelProfile = enum {
    low_power,
    balanced,
    performance,

    pub fn parse(value: []const u8) ?KernelProfile {
        return switch (value.len) {
            "balanced".len => if (std.mem.eql(u8, value, "balanced")) .balanced else null,
            "low-power".len => if (std.mem.eql(u8, value, "low-power")) .low_power else null,
            "performance".len => if (std.mem.eql(u8, value, "performance")) .performance else null,
            else => null,
        };
    }

    pub fn writeBytes(self: KernelProfile) []const u8 {
        return switch (self) {
            .low_power => "low-power\n",
            .balanced => "balanced\n",
            .performance => "performance\n",
        };
    }
};

pub fn kernelForDbus(value: DbusProfile) KernelProfile {
    return switch (value) {
        .power_saver => .low_power,
        .balanced => .balanced,
        .performance => .performance,
    };
}

pub fn dbusForKernel(value: KernelProfile) DbusProfile {
    return switch (value) {
        .low_power => .power_saver,
        .balanced => .balanced,
        .performance => .performance,
    };
}

test "fixed dbus to kernel mapping" {
    try std.testing.expectEqual(KernelProfile.low_power, kernelForDbus(.power_saver));
    try std.testing.expectEqual(KernelProfile.balanced, kernelForDbus(.balanced));
    try std.testing.expectEqual(KernelProfile.performance, kernelForDbus(.performance));
}

test "reverse mapping rejects non-hardcoded kernel values" {
    try std.testing.expectEqual(DbusProfile.power_saver, dbusForKernel(KernelProfile.low_power));
    try std.testing.expectEqual(@as(?KernelProfile, null), KernelProfile.parse("quiet"));
    try std.testing.expectEqual(@as(?KernelProfile, null), KernelProfile.parse("balanced-performance"));
}

test "dbus profile name parsing is strict" {
    try std.testing.expectEqual(@as(?DbusProfile, .power_saver), DbusProfile.parseName("power-saver"));
    try std.testing.expectEqual(@as(?DbusProfile, .balanced), DbusProfile.parseName("balanced"));
    try std.testing.expectEqual(@as(?DbusProfile, .performance), DbusProfile.parseName("performance"));
    try std.testing.expectEqual(@as(?DbusProfile, null), DbusProfile.parseName(""));
    try std.testing.expectEqual(@as(?DbusProfile, null), DbusProfile.parseName("balanced "));
    try std.testing.expectEqual(@as(?DbusProfile, null), DbusProfile.parseName("turbo"));
}
