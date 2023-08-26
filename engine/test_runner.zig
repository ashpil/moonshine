const std = @import("std");
const builtin = @import("builtin");

const engine = @import("engine");

pub const vulkan_context_device_functions = engine.hrtsystem.required_device_functions;

pub fn main() void {
    const enable_print = true;
    const print_all = true;

    var passed: u64 = 0;
    var skipped: u64 = 0;
    var failed: u64 = 0;
    const stderr = if (enable_print) std.io.getStdErr() else {};
    for (builtin.test_functions) |test_fn| {
        if (enable_print and print_all) {
            stderr.writeAll(test_fn.name) catch {};
            stderr.writeAll("... ") catch {};
        }
        test_fn.func() catch |err| {
            if (enable_print and !print_all) {
                stderr.writeAll(test_fn.name) catch {};
                stderr.writeAll("... ") catch {};
            }
            if (err != error.SkipZigTest) {
                if (enable_print) stderr.writeAll("FAIL\n") catch {};
                failed += 1;
                if (!enable_print) return err;
                continue;
            }
            if (enable_print) stderr.writeAll("SKIP\n") catch {};
            skipped += 1;
            continue;
        };
        if (enable_print and print_all) stderr.writeAll("PASS\n") catch {};
        passed += 1;
    }
    if (enable_print) {
        stderr.writer().print("{} passed, {} skipped, {} failed\n", .{ passed, skipped, failed }) catch {};
        if (failed != 0) std.process.exit(1);
    }
}

