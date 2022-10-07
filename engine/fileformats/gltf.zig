const std = @import("std");

// example loader
// const Loader = struct {
//     meshes: []const vk.Buffer,

//     fn load_meshes(self: *Loader) void {
//         self.meshes = ...;
//     } 
// };

pub fn parse(comptime Loader: type, allocator: std.mem.Allocator, file: std.fs.File) !Loader {
    _ = allocator;
    const reader = file.reader(); // TODO: experiment with buffering
    _ = reader;

    return undefined;
}

// api i'd like to have for a json parser
// declare an object 
// const op = ObjectParser(enum { materials, meshes });
// while (op.next()) |child| {
//     switch (child) {
//          .materials |el| => {
//              const mp = ObjectParser(struct { doubleSided: bool });
//              const material = mp.parse()
//          }
//     }
// }
//
// or hmmmm struct with load functions?
//
// for each JSON object:
//    - you define a "loader" struct, which, for each field of that object:
//       - has a function of the form load_<field> which as a single parameter takes either:
//          - bool, for a json true/false
//          - uN/fN, for a json number
//          - an array, for a fixed size json array
//          - anytype, for arbitrary data, but typically strings
//          - a custom loader struct, for a custom json object
//       - note the lack of pointers/slices -- this is to ensure zero allocations, if a field is of an array type the load_<field> function will simply be called multiple times 
// const Loader = struct {
//    const MaterialLoader = struct {
//        fn loadDoubleSided(b: bool) void {
//            
//        }
//    }
//    fn load_materials(x: MaterialLoader) void {
//        
//    }
// }