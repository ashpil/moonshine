const std = @import("std");


fn Entry(comptime Data: type) type {
    return extern struct {
        alias: u32, // index of alias
        select: f32, // weight by which to do a biased coin flip, if heads, this is the entry, if tails, alias is the entry
        data: Data,
    };
}

pub fn AliasTable(comptime Data: type) type {
    return struct {
        const Self = @This();

        pub const TableEntry = Entry(Data);

        entries: []TableEntry,
        sum: f32, // total unnormalized weight

        // https://www.keithschwarz.com/darts-dice-coins/
        // Vose's Method
        // weights may not be normalized
        // O(n) where n = raw_weights.len
        pub fn create(allocator: std.mem.Allocator, raw_weights: []const f32, datas: []const Data) std.mem.Allocator.Error!Self {
            std.debug.assert(raw_weights.len == datas.len);

            const entries = try allocator.alloc(TableEntry, raw_weights.len);
            errdefer allocator.free(entries);

            var weight_sum: f32 = 0.0;
            for (raw_weights) |weight| {
                weight_sum += weight;
            }

            var less_head: u32 = std.math.maxInt(u32);
            var more_head: u32 = std.math.maxInt(u32);

            const n = @intCast(u32, raw_weights.len);
            for (raw_weights, entries, datas, 0..) |weight, *entry, data, i| {
                entry.data = data;

                const adjusted_weight = (weight * @intToFloat(f32, n)) / weight_sum;
                entry.select = adjusted_weight;
                if (adjusted_weight < 1.0) {
                    entry.alias = less_head;
                    less_head = @intCast(u32, i);
                } else {
                    entry.alias = more_head;
                    more_head = @intCast(u32, i);
                }
            }

            while (less_head != std.math.maxInt(u32) and more_head != std.math.maxInt(u32)) {
                const less = less_head;
                less_head = entries[less].alias;

                const more = more_head;
                more_head = entries[more].alias;

                entries[less].alias = more;
                entries[more].select = (entries[more].select + entries[less].select) - 1.0;

                if (entries[more].select < 1.0) {
                    entries[more].alias = less_head;
                    less_head = more;
                } else {
                    entries[more].alias = more_head;
                    more_head = more;
                }
            }

            // while (more_head != std.math.maxInt(u32)) {
            //     const more = more_head;
            //     more_head = entries[more].alias;

            //     entries[more].select = 1.0;
            // }

            // should only happen due to floating point, this is actually a large entry
            while (less_head != std.math.maxInt(u32)) {
                const less = less_head;
                less_head = entries[less].alias;

                entries[less].select = 1.0;
            }

            return Self {
                .entries = entries,
                .sum = weight_sum,
            };
        }
    };
}

pub const NormalizedAliasTable = struct {
    pub const TableEntry = Entry(f32);

    entries: []TableEntry,
    sum: f32, // total unnormalized weight

    // https://www.keithschwarz.com/darts-dice-coins/
    // Vose's Method
    // weights may not be normalized
    // O(n) where n = raw_weights.len
    pub fn create(allocator: std.mem.Allocator, raw_weights: []const f32) std.mem.Allocator.Error!NormalizedAliasTable {
        const entries = try allocator.alloc(TableEntry, raw_weights.len);
        errdefer allocator.free(entries);

        var weight_sum: f32 = 0.0;
        for (raw_weights) |weight| {
            weight_sum += weight;
        }

        var less_head: u32 = std.math.maxInt(u32);
        var more_head: u32 = std.math.maxInt(u32);

        const n = @intCast(u32, raw_weights.len);
        for (raw_weights, 0..) |weight, i| {
            entries[i].data = weight / weight_sum;

            const adjusted_weight = (weight / weight_sum) * @intToFloat(f32, n);
            entries[i].select = adjusted_weight;
            if (adjusted_weight < 1.0) {
                entries[i].alias = less_head;
                less_head = @intCast(u32, i);
            } else {
                entries[i].alias = more_head;
                more_head = @intCast(u32, i);
            }
        }

        while (less_head != std.math.maxInt(u32) and more_head != std.math.maxInt(u32)) {
            const less = less_head;
            less_head = entries[less].alias;

            const more = more_head;
            more_head = entries[more].alias;

            entries[less].alias = more;
            entries[more].select = (entries[more].select + entries[less].select) - 1.0;

            if (entries[more].select < 1.0) {
                entries[more].alias = less_head;
                less_head = more;
            } else {
                entries[more].alias = more_head;
                more_head = more;
            }
        }

        while (more_head != std.math.maxInt(u32)) {
            const more = more_head;
            more_head = entries[more].alias;

            entries[more].select = 1.0;
            entries[more].alias = std.math.maxInt(u32); // make it clear
        }

        // should only happen due to floating point, this is actually a large entry
        while (less_head != std.math.maxInt(u32)) {
            const less = less_head;
            less_head = entries[less].alias;

            entries[less].select = 1.0;
            entries[less].alias = std.math.maxInt(u32); // make it clear
        }

        return NormalizedAliasTable {
            .entries = entries,
            .sum = weight_sum,
        };
    }
};
