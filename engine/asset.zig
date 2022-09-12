const std = @import("std");

// currently assumes project structure, not shipping structure
pub fn absoluteAssetPath(allocator: std.mem.Allocator, project_root_relative_path: []const u8) ![]u8 {
    const exe_path = try std.fs.selfExeDirPathAlloc(allocator);
    defer allocator.free(exe_path);
    return std.fs.path.join(allocator, &.{ exe_path, "../..", project_root_relative_path });
}

pub fn openAsset(allocator: std.mem.Allocator, project_root_relative_path: []const u8) !std.fs.File {
    const absolute_path = try absoluteAssetPath(allocator, project_root_relative_path);
    defer allocator.free(absolute_path);
    return std.fs.openFileAbsolute(absolute_path, .{});
}
