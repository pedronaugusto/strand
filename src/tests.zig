//! Test assembly above the public API and its consumers.
test {
    _ = @import("strand.zig");
    _ = @import("core_test.zig");
    _ = @import("json_test.zig");
    _ = @import("json_shape_test.zig");
    _ = @import("jsonl_test.zig");
    _ = @import("zon_test.zig");
    _ = @import("testing/json_suite.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("tail_test.zig");
    _ = @import("follow_test.zig");
    _ = @import("versioned_test.zig");
    _ = @import("raw_test.zig");
    _ = @import("tagging_test.zig");
    _ = @import("clone_test.zig");
    _ = @import("testing/keep_test.zig");
    // The parts' own roots name the tests of the files under them.
    _ = @import("json/api.zig");
    _ = @import("jsonl/api.zig");
    _ = @import("zon/api.zig");
}
