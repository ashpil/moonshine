const std = @import("std");


fn Entry(comptime Data: type) type {
    return extern struct {
        alias: u32, // index of alias
        weight: f32, // weight by which to do a biased coin flip, if heads, this is the entry, if tails, alias is the entry
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
        pub fn create(allocator: std.mem.Allocator, raw_weights: []const f32, data: []const Data) std.mem.Allocator.Error!Self {
            std.debug.assert(raw_weights.len == data.len);

            const entries = try allocator.alloc(TableEntry, raw_weights.len);
            errdefer allocator.free(entries);

            const running_weights = try allocator.alloc(f32, raw_weights.len);
            defer allocator.free(running_weights);

            var small = std.ArrayList(u32).init(allocator);
            defer small.deinit();

            var large = std.ArrayList(u32).init(allocator);
            defer large.deinit();

            const n = @intCast(u32, raw_weights.len);

            var weight_sum: f32 = 0.0; // maybe kahan sum is a good idea here?
            for (raw_weights) |weight, i| {
                weight_sum += weight;
                running_weights[i] = weight * @intToFloat(f32, n);
                if (running_weights[i] < 1.0) {
                    try small.append(@intCast(u32, i));
                } else {
                    try large.append(@intCast(u32, i));
                }
            }

            while (small.items.len != 0 and large.items.len != 0) {
                const l = small.pop();
                const g = large.pop();
                entries[l] = .{
                    .alias = g,
                    .weight = running_weights[l],
                    .data = data[l],
                };
                running_weights[g] = (running_weights[g] + running_weights[l]) - 1.0;
                if (running_weights[g] < 1.0) {
                    try small.append(g);
                } else {
                    try large.append(g);
                }
            }

            while (large.popOrNull()) |g| {
                entries[g].weight = 1.0; // no alias
                entries[g].data = data[g];
            }

            // should only happen due to floating point, this is actually a large entry
            while (small.popOrNull()) |l| {
                entries[l].weight = 1.0; // no alias
                entries[l].data = data[l];
            }

            return Self {
                .entries = entries,
                .sum = weight_sum,
            };
        }
    };
}
