//! Test assembly above the public API and its consumers.

test {
    _ = @import("strand.zig");
    _ = @import("raw_test.zig");
    _ = @import("tail_test.zig");
    _ = @import("follow_test.zig");
    _ = @import("versioned_test.zig");
    _ = @import("from_value_test.zig");

    _ = @import("owned_tests.zig");
    _ = @import("keep_tests.zig");
    _ = @import("parse_line.zig");
    _ = @import("line.zig");
    _ = @import("line_reader.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("sync.zig");
    _ = @import("control.zig");
    _ = @import("scanner.zig");
    _ = @import("route.zig");
    _ = @import("tests.zig");
    _ = @import("fuzz.zig");
    _ = @import("tail.zig");
    _ = @import("follow.zig");
    _ = @import("versioned.zig");
    _ = @import("raw.zig");
    _ = @import("int.zig");
    _ = @import("file_id.zig");
    _ = @import("from_value.zig");
    _ = @import("codec_tests.zig");
}
