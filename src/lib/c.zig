// Just includes from C -- happens here
// Changes based on engine features requested
const options = @import("build_options");

pub usingnamespace @import("wuffs");
pub usingnamespace if (options.hrtsystem) @import("tinyexr") else struct {};
pub usingnamespace if (options.gui) @import("imgui") else struct {};
pub usingnamespace if (options.window) @import("glfw") else struct {};
