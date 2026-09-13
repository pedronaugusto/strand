//! A log kept on disk: versioned records written and read back, the last few
//! of them read off the end of the file without reading the rest, and one
//! task following the file while another appends to it.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! its two marked regions into README.md, so the snippets a reader copies are
//! code CI executes.

const std = @import("std");
const strand = @import("strand");

pub fn main() !void {
    var debug: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug.deinit();
    const gpa = debug.allocator();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Scratch space under `.zig-cache`, which a build already owns.
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, ".zig-cache/logbook", .{});
    defer {
        dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, ".zig-cache/logbook") catch {};
    }

    // --- README:versioned ---

    // The record, as this build understands it. Version 1 had no `scope` and
    // wrote `at` as a string, so a line stamped 1 goes through the hook.
    const Entry = struct {
        scope: []const u8 = "app",
        kind: []const u8,
        at: u64 = 0,

        pub const jsonl_version: u32 = 2;

        pub fn jsonlMigrate(
            allocator: std.mem.Allocator,
            from: u32,
            data: std.json.Value,
        ) std.json.ParseFromValueError!@This() {
            if (from != 1) return error.UnknownField;
            const old = try strand.payloadOf(struct {
                kind: []const u8,
                at: []const u8 = "0",
            }, allocator, data);
            return .{
                .scope = "app",
                .kind = old.kind,
                .at = std.fmt.parseInt(u64, old.at, 10) catch return error.InvalidNumber,
            };
        }
    };

    // A log with one line of the old shape on it, and two of the new.
    var out: std.Io.Writer.Allocating = .init(arena);
    try out.writer.writeAll(
        \\{"v":1,"data":{"kind":"open","at":"1"}}
        \\
    );
    var log: strand.Writer(strand.Versioned(Entry)) = .init(&out.writer, .{});
    try log.writeAll(&.{
        .{ .value = .{ .scope = "net", .kind = "retry", .at = 2 } },
        .{ .value = .{ .kind = "close", .at = 3 } },
    });

    // Reading it back: every line arrives in today's shape, and says which
    // shape it was written in.
    var source: std.Io.Reader = .fixed(out.written());
    var entries: strand.Reader(strand.Versioned(Entry)) = .init(gpa, &source, .{});
    defer entries.deinit();
    while (try entries.next()) |line| {
        std.debug.print("line {d}: v{d}{s} {s}/{s} at {d}\n", .{
            line.number,
            line.value.from,
            if (line.value.migrated()) " (migrated)" else "",
            line.value.value.scope,
            line.value.value.kind,
            line.value.value.at,
        });
    }
    // --- README:versioned ---

    // The same bytes on disk, for the two readers below.
    try dir.writeFile(io, .{ .sub_path = "log.jsonl", .data = out.written() });

    // --- README:tail ---

    // The last two lines, read off the end of the file. A backwards read
    // touches the blocks those lines are in and nothing before them, so this
    // costs the same on a file of three lines and a file of three million.
    {
        const file = try dir.openFile(io, "log.jsonl", .{});
        defer file.close(io);
        var buffer: [4096]u8 = undefined;
        var file_reader = file.reader(io, &buffer);

        var tail: strand.Tail(strand.Versioned(Entry)) = try .init(gpa, &file_reader, .{});
        defer tail.deinit();

        // In file order, on an arena, borrowing nothing from the reader.
        for (try tail.last(arena, 2)) |entry| {
            std.debug.print("near the end: {s} at {d}\n", .{ entry.value.kind, entry.value.at });
        }
    }
    // --- README:tail ---

    try follow(gpa, io, dir, Entry);
    try arms(arena);
}

/// One task appending to the log while another follows it.
fn follow(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, comptime Entry: type) !void {
    const appended = 2;

    const Appender = struct {
        fn run(inner_io: std.Io, target: std.Io.Dir) !void {
            const file = try target.openFile(inner_io, "log.jsonl", .{ .mode = .write_only });
            defer file.close(inner_io);
            var buffer: [512]u8 = undefined;
            var file_writer = file.writer(inner_io, &buffer);
            file_writer.pos = try file.length(inner_io);

            var log: strand.Writer(strand.Versioned(Entry)) = .init(&file_writer.interface, .{});
            for (0..appended) |i| {
                try log.write(.{ .value = .{ .kind = "tick", .at = 10 + i } });
                try file_writer.interface.flush();
            }
        }
    };

    var task = io.concurrent(Appender.run, .{ io, dir }) catch |err| switch (err) {
        // Nothing to demonstrate on an `Io` that cannot run two things at
        // once, and nothing wrong with one either.
        error.ConcurrencyUnavailable => {
            std.debug.print("following: skipped, this Io has no concurrency\n", .{});
            return;
        },
    };
    defer task.await(io) catch {};

    const file = try dir.openFile(io, "log.jsonl", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    // Start at the end, the way `tail -f` does: only what arrives from now on.
    try file_reader.seekTo(try file.length(io));

    // --- README:follow ---

    // Following: read to the end of the file, wait for it to grow, carry on.
    // There is no end to a file being appended to, so a follower stops when
    // the `std.Io` cancels it — or, as here, when the caller stops asking.
    var follower: strand.Follower(strand.Versioned(Entry)) = .init(gpa, io, &file_reader, .{
        .wait = .{ .poll = .fromMilliseconds(5) },
    });
    defer follower.deinit();

    for (0..appended) |_| {
        const line = try follower.next();
        std.debug.print("followed: {s} at {d}\n", .{ line.value.value.kind, line.value.value.at });
    }
    // --- README:follow ---
}

/// The other way a schema grows: a tagged union that gains an arm.
///
/// `std.json` writes a tagged union as a one-key object naming the arm, so
/// `tagOf` reads the arm without parsing the payload — and an old reader needs
/// somewhere for an arm it has never heard of to land.
fn arms(arena: std.mem.Allocator) !void {
    // A line written by a build that knows an arm this one does not.
    const line = "{\"reload\":{\"path\":\"/etc/app.conf\"}}";

    // --- README:arms ---

    const Message = union(enum) {
        open: struct { path: []const u8 },
        close: struct { code: u8 },
        /// Every arm this build does not know. Keep the bytes, not a guess.
        unknown: std.json.Value,
    };

    // Route on the tag, and give an unknown one the line rather than an error.
    const message: Message = if (strand.tagOf(Message, line)) |_|
        try strand.parseLine(Message, arena, line, .{})
    else
        .{ .unknown = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) };
    // --- README:arms ---

    std.debug.print("unrecognised arm kept whole: {s}\n", .{
        message.unknown.object.keys()[0],
    });
}
