const std = @import("std");
const math = std.math;

pub const MT19937 = MersenneTwister(
    u64,
    312,
    156,
    31,
    0xB5026F5AA96619E9,
    29,
    0x5555555555555555,
    17,
    0x71D67FFFEDA60000,
    37,
    0xFFF7EEE000000000,
    43,
    6364136223846793005,
);

pub fn MersenneTwister(
    comptime Int: type,
    comptime n: usize,
    comptime m: usize,
    comptime r: Int,
    comptime a: Int,
    comptime u: math.Log2Int(Int),
    comptime d: Int,
    comptime s: math.Log2Int(Int),
    comptime b: Int,
    comptime t: math.Log2Int(Int),
    comptime c: Int,
    comptime l: math.Log2Int(Int),
    comptime f: Int,
) type {
    return struct {
        const Self = @This();

        array: [n]Int,
        index: usize,

        pub fn init(seed: Int) Self {
            var mt = Self{
                .array = undefined,
                .index = n,
            };

            var prev_value = seed;
            mt.array[0] = prev_value;
            var i: usize = 1;
            while (i < n) : (i += 1) {
                prev_value = @as(Int, i) +% f *% (prev_value ^ (prev_value >> (@bitSizeOf(Int) - 2)));
                mt.array[i] = prev_value;
            }
            return mt;
        }

        pub fn get(mt: *Self) Int {
            const mag01: [2]Int = .{ 0, a };
            const LM: Int = (1 << r) - 1;
            const UM = ~LM;

            if (mt.index >= n) {
                var i: usize = 0;

                while (i < n - m) : (i += 1) {
                    const x = (mt.array[i] & UM) | (mt.array[i + 1] & LM);
                    mt.array[i] = mt.array[i + m] ^ (x >> 1) ^ mag01[@as(usize, x & 0x1)];
                }

                while (i < n - 1) : (i += 1) {
                    const x = (mt.array[i] & UM) | (mt.array[i + 1] & LM);
                    mt.array[i] = mt.array[i + m - n] ^ (x >> 1) ^ mag01[@as(usize, x & 0x1)];
                }
                const x = (mt.array[i] & UM) | (mt.array[0] & LM);
                mt.array[i] = mt.array[m - 1] ^ (x >> 1) ^ mag01[@as(usize, x & 0x1)];

                mt.index = 0;
            }

            var x = mt.array[mt.index];
            mt.index += 1;

            x ^= ((x >> u) & d);
            x ^= ((x << s) & b);
            x ^= ((x << t) & c);
            x ^= (x >> l);

            return x;
        }
    };
}
