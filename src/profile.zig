const std = @import("std");

pub const DbusProfile = enum {
    power_saver,
    balanced,
    performance,

    pub fn parse(value: []const u8) ?DbusProfile {
        if (std.mem.eql(u8, value, "power-saver")) return .power_saver;
        if (std.mem.eql(u8, value, "balanced")) return .balanced;
        if (std.mem.eql(u8, value, "performance")) return .performance;
        return null;
    }

    pub fn name(self: DbusProfile) [:0]const u8 {
        return switch (self) {
            .power_saver => "power-saver",
            .balanced => "balanced",
            .performance => "performance",
        };
    }
};

pub const KernelProfile = enum {
    low_power,
    balanced,
    performance,

    pub fn parse(value: []const u8) ?KernelProfile {
        if (std.mem.eql(u8, value, "low-power")) return .low_power;
        if (std.mem.eql(u8, value, "balanced")) return .balanced;
        if (std.mem.eql(u8, value, "performance")) return .performance;
        return null;
    }

    pub fn name(self: KernelProfile) [:0]const u8 {
        return switch (self) {
            .low_power => "low-power",
            .balanced => "balanced",
            .performance => "performance",
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
