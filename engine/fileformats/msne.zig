const std = @import("std");

// TODO: make this provide some higher-level, more type-safe API
// currently just some nice-to-have wrappers around a basic reader
pub const MsneReader = struct {
    file: std.fs.File,
    reader: std.fs.File.Reader,

    const Self = @This();

    pub fn fromFilepath(filepath: []const u8) !Self {
        const file = try std.fs.cwd().openFile(filepath, .{});
        const reader = file.reader();

        if (!std.mem.eql(u8, &try reader.readBytesNoEof(4), "MSNE")) return error.InvalidMsne;

        return Self {
            .file = file,
            .reader = reader,
        };
    }

    pub fn destroy(self: Self) void {
        var buf: [1]u8 = undefined;
        std.debug.assert(self.reader.read(&buf) catch unreachable == 0); // make sure all of file is read
        self.file.close();
    }

    pub fn readSize(self: Self) !u32 {
        return self.reader.readIntLittle(u32);
    }

    pub fn readFloat(self: Self) !f32 {
        return @bitCast(f32, try self.reader.readBytesNoEof(4));
    }

    pub fn readStruct(self: Self, comptime T: type) !T {
        return self.reader.readStruct(T);
    }

    pub fn readSlice(self: Self, comptime T: type, slice: []T) !void {
        try self.reader.readNoEof(std.mem.sliceAsBytes(slice));
    }

    pub fn readBool(self: Self) !bool {
        return try self.reader.readByte() != 0;
    }
};
