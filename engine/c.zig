// Just includes from C -- happens here
// Changes based on engine features requested

const exr = @import("build_options").exr;

pub usingnamespace @cImport({
    @cInclude("tinyexr.h");
});
