//! A log kept on disk: versioned records written and read back, the last few
//! of them read off the end of the file without reading the rest, a follower
//! over a file being appended to and a second one resumed from where it
//! stood, a tagged union that gained an arm, and a torn record in front of a
//! separated stream. And the same format as a line protocol, where a message
//! past the bound is answered rather than taken for the end of the
//! connection.
//!
//! `zig build examples` builds AND runs this; `ci/readme_usage.sh` extracts
//! its marked regions into README.md, so the snippets a reader copies are
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
    try separated(gpa);
    try arms(arena);
    try protocol(gpa, arena);
}

/// Records appended to the log, a follower that picks them up, and a second
/// follower that carries on from where the first one stood.
fn follow(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, comptime Entry: type) !void {
    const appended = 2;

    const file = try dir.openFile(io, "log.jsonl", .{});
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    // Where the log ends now, measured once through the handle that is open
    // for reading. A handle opened only for writing cannot be asked: Windows
    // refuses the query with `error.AccessDenied`, because reading a file's
    // attributes is read access.
    const end = try file.length(io);
    // Start at the end: only what arrives from now on.
    try file_reader.seekTo(end);

    // The records arrive. In a program this is another process, or another
    // task; here it is the lines above the follower, so that the example
    // finishes on every platform instead of waiting on something that might
    // not come. `zig build test` runs a producer and a follower at once.
    const sink = try dir.openFile(io, "log.jsonl", .{ .mode = .write_only });
    defer sink.close(io);
    var sink_buffer: [512]u8 = undefined;
    var file_writer = sink.writer(io, &sink_buffer);
    file_writer.pos = end;

    // `.per_record` is the policy a log another process is reading wants:
    // every record is on the file, and on the disk under it, before the next
    // one is written. It costs a sync a record.
    var log: strand.Writer(strand.Versioned(Entry)) = .initFile(&file_writer, .{
        .sync = .per_record,
    });
    for (0..appended) |i| {
        try log.write(.{ .value = .{ .kind = "tick", .at = 10 + i } });
    }

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

    // --- README:checkpoint ---

    // Where this follower stands: which file, how far into it, what the next
    // line is numbered, how many files it has been through. Take it after
    // `next` has returned a line and before the next call, which is when the
    // offset in it is a line boundary. It is a struct of integers, so a
    // registry of them is a JSON Lines file like any other.
    const point = try follower.checkpoint();

    // The process ends here, and the log goes on growing without it.
    try log.write(.{ .value = .{ .kind = "tick", .at = 12 } });

    // The next run opens the path afresh. What it finds is not necessarily
    // the file the checkpoint was taken on — a log can rotate while nothing
    // is following it — so `resumeFrom` tells the two apart under
    // `Options.identity`: the same file carries on at the recorded offset
    // with the recorded numbering, a different one is read from its start
    // and counted as a rotation.
    const reopened = try dir.openFile(io, "log.jsonl", .{});
    defer reopened.close(io);
    var reopened_buffer: [4096]u8 = undefined;
    var reopened_reader = reopened.reader(io, &reopened_buffer);

    var resumed: strand.Follower(strand.Versioned(Entry)) = try .resumeFrom(gpa, io, &reopened_reader, .{
        .wait = .{ .poll = .fromMilliseconds(5) },
    }, point);
    defer resumed.deinit();

    const line = try resumed.next();
    std.debug.print("resumed at line {d} of {d} rotation(s): {s} at {d}\n", .{
        line.number,
        resumed.rotations,
        line.value.value.kind,
        line.value.value.at,
    });
    // --- README:checkpoint ---
}

/// The framing that says where a record starts, for a log that has to survive
/// a writer stopping in the middle of one.
fn separated(gpa: std.mem.Allocator) !void {
    // --- README:separator ---

    const Event = struct { kind: []const u8, at: u64 = 0 };

    // A record left half-written by the process before this one. On a plain
    // JSON Lines log these bytes are a line that does not parse, and nothing
    // in the format says whether that is damage or a record from a writer
    // that knows something this reader does not.
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try out.writer.writeAll("{\"kind\":\"ope");

    // With a separator in front of every record there is no such question:
    // 0x1E is the one byte that cannot appear unescaped inside a JSON value,
    // so it marks where a record begins and nothing else can.
    var log: strand.Writer(Event) = .init(&out.writer, .{ .record_separator = true });
    try log.write(.{ .kind = "open", .at = 1 });
    try log.write(.{ .kind = "close", .at = 2 });

    // The reader is told what the writer was told. Every record that was
    // written comes back; what is dropped is exactly the torn bytes, and a
    // line carrying no record at all is `error.MissingSeparator` rather than
    // a line that might have been meant.
    var source: std.Io.Reader = .fixed(out.written());
    var events: strand.Reader(Event) = .init(gpa, &source, .{ .record_separator = true });
    defer events.deinit();
    while (try events.next()) |line| {
        std.debug.print("record {d}: {s} at {d}\n", .{ line.number, line.value.kind, line.value.at });
    }
    // --- README:separator ---
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

/// A line protocol: requests read off a stream as lines, parsed by their own
/// rules, and one far past the bound answered rather than taken for the end
/// of the connection.
fn protocol(gpa: std.mem.Allocator, arena: std.mem.Allocator) !void {
    // --- README:protocol ---

    const Request = union(enum) {
        say: struct { text: []const u8 },
        bye: struct {},
    };
    const Reply = struct { ok: bool, line: u64, message: []const u8 = "" };

    // What a client sent: a request, one far past what this server takes, and
    // one after it. In a program this is a socket's reader.
    var sent: std.Io.Writer.Allocating = .init(gpa);
    defer sent.deinit();
    try strand.writeLine(&sent.writer, Request{ .say = .{ .text = "hello" } });
    try sent.writer.writeAll("{\"say\":{\"text\":\"");
    try sent.writer.splatByteAll('x', 100_000);
    try sent.writer.writeAll("\"}}\n");
    try strand.writeLine(&sent.writer, Request{ .bye = .{} });
    var socket: std.Io.Reader = .fixed(sent.written());

    // Replies go back a record at a time, each one drained as it is written.
    var answered: std.Io.Writer.Allocating = .init(gpa);
    defer answered.deinit();
    var replies: strand.Writer(Reply) = .init(&answered.writer, .{ .flush = .per_record });

    // The lines, framed and bounded. What a line means is the server's own
    // business, so nothing here is parsed until the server parses it.
    var requests: strand.LineReader = .init(gpa, &socket, .{ .max_line_bytes = 64 * 1024 });
    defer requests.deinit();
    while (true) {
        const raw = requests.next() catch |err| switch (err) {
            // That line is gone, and the stream is at the start of the next
            // one: answer it and read on.
            error.LineTooLong => {
                try replies.write(.{ .ok = false, .line = requests.fault.line, .message = "too long" });
                continue;
            },
            else => |e| return e,
        } orelse break;
        const request = strand.parseLine(Request, arena, raw.line, .{}) catch {
            try replies.write(.{ .ok = false, .line = raw.number, .message = "not a request" });
            continue;
        };
        try replies.write(.{ .ok = true, .line = raw.number, .message = @tagName(request) });
    }
    // --- README:protocol ---

    var it = strand.lines(answered.written());
    while (it.next()) |line| std.debug.print("reply: {s}\n", .{line.line});
}
