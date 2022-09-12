// this only partially works -- can only parse headers, nothing more

const std = @import("std");

const Format = enum {
    ascii,
    binary_little_endian,
    binary_big_endian,
};

const AttributeType = enum {
    char,
    uchar,
    short,
    ushort,
    int,
    uint,
    float,
    double,
    list, // TODO

    fn fromMinimalStr(str: [2]u8) AttributeType {
        return switch (str[0]) {
            'l' => AttributeType.list,
            'c' => AttributeType.char,
            's' => AttributeType.short,
            'i' => AttributeType.int,
            'f' => AttributeType.float,
            'd' => AttributeType.double,
            'u' => switch (str[1]) {
                'c' => AttributeType.uchar,
                's' => AttributeType.ushort,
                'i' => AttributeType.uint,
                else => unreachable,
            },
            else => unreachable,
        };
    }
};

pub const Header = struct {
    const Element = struct {
        properties: []AttributeType,
        count: u16,
    };

    elements: []Element,
    format: Format,

    // assumes if magic number is valid then it is a valid ply file,
    // does not do other error checking
    pub fn parse(allocator: std.mem.Allocator, file: std.fs.File) !Header {
        const reader = file.reader();
        const magic_and_format = try reader.readBytesNoEof(21);
        if (!std.mem.eql(u8, magic_and_format[0..3], "ply")) return error.NotPlyFile;

        const format: Format = switch (magic_and_format[18]) {
            '.' => .ascii,
            'l' => .binary_little_endian,
            'b' => .binary_big_endian,
            else => unreachable,
        };

        var elements = try std.ArrayListUnmanaged(Header.Element).initCapacity(allocator, 2); // usually only need two
        errdefer elements.deinit(allocator);

        // skip all non-elements
        while ((try reader.readBytesNoEof(8))[0] != 'e') {
            try reader.skipUntilDelimiterOrEof('\n');
        }
        while (true) {
            if ((try reader.readByte()) == 'e') break;

            try reader.skipUntilDelimiterOrEof(' ');

            var buf: [6]u8 = undefined;
            const element_count = try std.fmt.parseInt(u16, try reader.readUntilDelimiter(&buf, '\n'), 10);

            // parse properties
            var properties = std.ArrayListUnmanaged(AttributeType) {};
            errdefer properties.deinit(allocator);

            while ((try reader.readBytesNoEof(8))[0] != 'e') {
                const bytes = try reader.readBytesNoEof(4);
                const prop_format = AttributeType.fromMinimalStr(bytes[2..4].*);
                try reader.skipUntilDelimiterOrEof('\n');
                try properties.append(allocator, prop_format);
            }

            try elements.append(allocator, .{
                .properties = properties.toOwnedSlice(allocator),
                .count = element_count,
            });
        }

        try reader.skipBytes(3, .{});

        return Header {
            .elements = elements.toOwnedSlice(allocator),
            .format = format,
        };
    }

    pub fn destroy(self: Header, allocator: std.mem.Allocator) void {
        for (self.elements) |element| allocator.free(element.properties);
        allocator.free(self.elements);
    }
};