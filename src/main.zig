const std = @import("std");

const Engine = @import("./renderer/Engine.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}) {};
    defer _ = gpa.deinit();
    const allocator = &gpa.allocator;

    var engine = try Engine.create(allocator);
    defer engine.destroy(allocator);

    engine.setCallbacks();
    try engine.run(allocator);

    std.log.info("Program completed!.", .{});
}
