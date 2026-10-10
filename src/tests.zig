//! Test assembly above the public API and its consumers.
test {
    _ = @import("strand.zig");
    _ = @import("core_test.zig");
    _ = @import("json_test.zig");
    _ = @import("zon_test.zig");
    _ = @import("testing/json_suite.zig");
    _ = @import("testing/reflection_test.zig");
    _ = @import("strand_test.zig");
    // The parts' own roots name the tests of the files under them.
    _ = @import("json/api.zig");
    _ = @import("jsonl/api.zig");
    _ = @import("zon/api.zig");
}
