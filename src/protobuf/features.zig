const remielle = @import("../remielle.zig");
const protobuf = remielle.protobuf;

pub const Feature = enum {
    player_kick,
};

const desc_set: protobuf.Descriptors = .main;

/// Indicates whether a protocol `feature` is available.
pub inline fn isAvailable(comptime feature: Feature) bool {
    return switch (feature) {
        .player_kick => if (desc_set.getDescriptorByName("PlayerKickScNotify")) |message|
            message.hasField("reason")
        else
            false,
    };
}
