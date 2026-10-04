//! Test assembly above the public API and its consumers.

test {
    _ = @import("strand.zig");
    _ = @import("raw_test.zig");
    _ = @import("tail_test.zig");
    _ = @import("follow_test.zig");
    _ = @import("tagging_test.zig");
    _ = @import("versioned_test.zig");
    _ = @import("from_value_test.zig");

    _ = @import("owned_test.zig");
    _ = @import("testing/keep_test.zig");
    _ = @import("codec.zig").parser;
    _ = @import("parse/line.zig");
    _ = @import("line.zig");
    _ = @import("line/reader.zig");
    _ = @import("reader.zig");
    _ = @import("writer.zig");
    _ = @import("sync.zig");
    _ = @import("control.zig");
    _ = @import("scanner.zig");
    _ = @import("route.zig");
    _ = @import("strand_test.zig");
    _ = @import("testing/fuzz_test.zig");
    _ = @import("tail.zig");
    _ = @import("follow.zig");
    _ = @import("versioned.zig");
    _ = @import("codec.zig");
    _ = @import("int.zig");
    _ = @import("file_id.zig");
    _ = @import("member_scan.zig");
    _ = @import("tagging.zig");
    _ = @import("indent.zig");
    _ = @import("leading.zig");
    _ = @import("from_value.zig");
    _ = @import("codec_test.zig");
}
