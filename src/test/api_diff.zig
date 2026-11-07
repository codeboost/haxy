const std = @import("std");
const xit = @import("xit");
const api = @import("../api.zig");
const api_commits = @import("../api/commits.zig");
const api_diff = @import("../api/diff.zig");
const ui = @import("../ui.zig");

const Diff = ui.Repo.Diff;

test "a commit's diff hangs off its route, on a server or the local repo" {
    const oid = "0123456789abcdef0123456789abcdef01234567";
    const server = api_commits.route("/api/v1/repos/bobby/linux/commits/" ++ oid ++ "/diff").?;
    try std.testing.expectEqualStrings("bobby", server.target.server.owner);
    try std.testing.expectEqualStrings(oid, server.resource.diff);
    const local = api_commits.route("/api/v1/repo/commits/" ++ oid ++ "/diff").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(local.target));
    try std.testing.expectEqualStrings(oid, local.resource.diff);
    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/commits/" ++ oid ++ "/diff/",
        "/api/v1/repos/bobby/linux/commits/" ++ oid ++ "/diffs",
        "/api/v1/repos/bobby/linux/commits/" ++ oid ++ "/diff/x",
        "/api/v1/repos/bobby/linux/commits//diff",
        "/api/v1/repo/commits/" ++ oid ++ "/files",
    }) |path| {
        try std.testing.expectEqual(null, api_commits.route(path));
    }
}

// a temporary repo whose files a test writes and commits
fn TestRepo(comptime kind: xit.repo.RepoKind) type {
    return struct {
        const opts: xit.repo.RepoOpts(kind) = .{ .is_test = true };
        const Repo = xit.repo.Repo(kind, opts);
        const Oid = [xit.hash.hexLen(opts.hash)]u8;

        temp: std.testing.TmpDir,
        path: [:0]const u8,
        repo: Repo,
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        fn init(self: *Self) !void {
            const io = std.testing.io;
            self.temp = std.testing.tmpDir(.{});
            self.path = try self.temp.dir.realPathFileAlloc(io, ".", std.testing.allocator);
            self.repo = try Repo.init(io, std.testing.allocator, .{ .path = self.path });
            self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        }

        fn deinit(self: *Self) void {
            self.arena.deinit();
            self.repo.deinit(std.testing.io, std.testing.allocator);
            std.testing.allocator.free(self.path);
            self.temp.cleanup();
        }

        // writes `files` (name, content), removes `removed`, and commits
        fn commit(self: *Self, files: []const [2][]const u8, removed: []const []const u8) !Oid {
            const io = std.testing.io;
            var names: std.ArrayList([]const u8) = .empty;
            defer names.deinit(std.testing.allocator);
            for (files) |file| {
                const handle = try self.repo.core.work_dir.createFile(io, file[0], .{});
                defer handle.close(io);
                try handle.writeStreamingAll(io, file[1]);
                try names.append(std.testing.allocator, file[0]);
            }
            if (names.items.len != 0) try self.repo.add(io, std.testing.allocator, names.items);
            if (removed.len != 0) try self.repo.remove(io, std.testing.allocator, removed, .{});
            return self.repo.commit(io, std.testing.allocator, .{ .message = "change", .allow_empty = true });
        }

        // the diff's json for `query`, or the error it answers with
        fn diff(self: *Self, oid: []const u8, query: []const u8) !Answer {
            var out: std.Io.Writer.Allocating = .init(self.arena.allocator());
            if (try api_diff.writeDiff(kind, opts, &self.arena, &self.repo, std.testing.io, std.testing.allocator, oid, query, &out.writer)) |err| return .{ .err = err };
            return .{ .json = try std.json.parseFromSliceLeaky(std.json.Value, self.arena.allocator(), out.written(), .{}) };
        }
    };
}

const Answer = union(enum) {
    json: std.json.Value,
    err: api.Error,

    fn ok(self: Answer) !std.json.ObjectMap {
        return switch (self) {
            .json => |value| value.object,
            .err => |err| {
                std.debug.print("unexpected error: {s} {s}\n", .{ @tagName(err.code), err.message });
                return error.UnexpectedError;
            },
        };
    }

    fn failure(self: Answer) !api.Error {
        return switch (self) {
            .err => |err| err,
            .json => error.ExpectedError,
        };
    }
};

fn field(object: std.json.ObjectMap, name: []const u8) std.json.Value {
    return object.get(name) orelse std.debug.panic("missing field {s}", .{name});
}

fn items(object: std.json.ObjectMap) []std.json.Value {
    return field(object, "items").array.items;
}

fn page(object: std.json.ObjectMap) std.json.ObjectMap {
    return field(object, "page").object;
}

// the item whose path is `path`
fn itemAt(object: std.json.ObjectMap, path: []const u8) !std.json.ObjectMap {
    for (items(object)) |item| if (std.mem.eql(u8, field(item.object, "path").string, path)) return item.object;
    return error.MissingItem;
}

test "a commit's diff pages through the TUI's diff windows, across files, with its path filter" {
    try testWindows(.git);
    try testWindows(.xit);
}

fn testWindows(comptime kind: xit.repo.RepoKind) !void {
    var t: TestRepo(kind) = undefined;
    try t.init();
    defer t.deinit();
    const root = try t.commit(&.{.{ "shared.txt", "shared\n" }}, &.{});
    // one more file than a window holds, as the TUI's own diff test
    var files: [Diff.page_size + 1][2][]const u8 = undefined;
    for (&files, 0..) |*file, i| file.* = .{ try std.fmt.allocPrint(t.arena.allocator(), "file-{d:0>2}.txt", .{i}), "added\n" };
    const head = try t.commit(&files, &.{});

    const first = try (try t.diff(&head, "")).ok();
    try std.testing.expectEqualStrings(&head, field(first, "commit").string);
    try std.testing.expectEqualStrings(&root, field(first, "parent").string);
    try std.testing.expectEqual(.null, std.meta.activeTag(field(first, "path")));
    try std.testing.expectEqual(Diff.page_size, items(first).len);
    try std.testing.expectEqual(false, field(first, "truncated").bool);
    const added = items(first)[0].object;
    try std.testing.expectEqualStrings("file-00.txt", field(added, "path").string);
    try std.testing.expectEqualStrings("file-00.txt", field(added, "name").string);
    try std.testing.expectEqualStrings("added", field(added, "status").string);
    // an added file shows only its path, as in the TUI
    try std.testing.expectEqualStrings("file", field(added, "kind").string);
    try std.testing.expectEqual(0, field(added, "lines").array.items.len);
    try std.testing.expectEqual(true, field(page(first), "has_more").bool);
    try std.testing.expectEqualStrings("unknown", field(field(page(first), "count").object, "kind").string);
    const cursor = field(page(first), "next_cursor").string;

    const last = try (try t.diff(&head, try std.fmt.allocPrint(t.arena.allocator(), "cursor={s}", .{cursor}))).ok();
    try std.testing.expectEqual(1, items(last).len);
    try std.testing.expectEqualStrings("file-10.txt", field(items(last)[0].object, "path").string);
    try std.testing.expectEqual(false, field(page(last), "has_more").bool);
    try std.testing.expectEqual(.null, std.meta.activeTag(field(page(last), "next_cursor")));

    // the filter narrows the diff to one file, and is echoed
    const filtered = try (try t.diff(&head, "path=file-03.txt")).ok();
    try std.testing.expectEqual(1, items(filtered).len);
    try std.testing.expectEqualStrings("file-03.txt", field(filtered, "path").string);
    try std.testing.expectEqual(false, field(page(filtered), "has_more").bool);
    // a path the commit doesn't change shows no changes
    try std.testing.expectEqual(0, items(try (try t.diff(&head, "path=shared.txt")).ok()).len);

    // a smaller window on request, capped at 100
    const small = try (try t.diff(&head, "page_size=3")).ok();
    try std.testing.expectEqual(3, items(small).len);
    try std.testing.expectEqual(Diff.page_size + 1, items(try (try t.diff(&head, "page_size=1000")).ok()).len);

    // a root commit's diff adds the files it starts with
    const first_commit = try (try t.diff(&root, "")).ok();
    try std.testing.expectEqual(.null, std.meta.activeTag(field(first_commit, "parent")));
    try std.testing.expectEqual(1, items(first_commit).len);
    try std.testing.expectEqualStrings("shared.txt", field(items(first_commit)[0].object, "path").string);
}

test "a commit's diff shows changed lines with their numbers, and placeholders for binary files" {
    try testContent(.git);
    try testContent(.xit);
}

fn testContent(comptime kind: xit.repo.RepoKind) !void {
    var t: TestRepo(kind) = undefined;
    try t.init();
    defer t.deinit();
    _ = try t.commit(&.{ .{ "text.txt", "one\ntwo\nthree\n" }, .{ "image.bin", "\x00\xff" }, .{ "gone.txt", "bye\n" } }, &.{});
    const head = try t.commit(&.{ .{ "text.txt", "one\n2\nthree\n" }, .{ "image.bin", "\x00\xfe" }, .{ "a b%.txt", "new\n" } }, &.{"gone.txt"});
    const diff = try (try t.diff(&head, "")).ok();
    try std.testing.expectEqual(4, items(diff).len);

    const text = try itemAt(diff, "text.txt");
    try std.testing.expectEqualStrings("changed", field(text, "status").string);
    try std.testing.expectEqualStrings("hunk", field(text, "kind").string);
    const lines = field(text, "lines").array.items;
    const expected = [_]struct { kind: []const u8, old: ?i64, new: ?i64, text: []const u8 }{
        .{ .kind = "context", .old = 1, .new = 1, .text = "one" },
        .{ .kind = "removed", .old = 2, .new = null, .text = "two" },
        .{ .kind = "added", .old = null, .new = 2, .text = "2" },
        .{ .kind = "context", .old = 3, .new = 3, .text = "three" },
    };
    for (expected, lines[0..expected.len]) |want, line| {
        try std.testing.expectEqualStrings(want.kind, field(line.object, "kind").string);
        if (want.old) |n| try std.testing.expectEqual(n, field(line.object, "old_number").integer) else try std.testing.expectEqual(.null, std.meta.activeTag(field(line.object, "old_number")));
        if (want.new) |n| try std.testing.expectEqual(n, field(line.object, "new_number").integer) else try std.testing.expectEqual(.null, std.meta.activeTag(field(line.object, "new_number")));
        try std.testing.expectEqualStrings(want.text, field(line.object, "text").string);
    }

    const binary = try itemAt(diff, "image.bin");
    try std.testing.expectEqualStrings("changed", field(binary, "status").string);
    try std.testing.expectEqualStrings("binary", field(binary, "kind").string);
    try std.testing.expectEqual(0, field(binary, "lines").array.items.len);

    const removed = try itemAt(diff, "gone.txt");
    try std.testing.expectEqualStrings("removed", field(removed, "status").string);
    try std.testing.expectEqualStrings("file", field(removed, "kind").string);

    // paths travel percent-encoded, beside a name for display
    const odd = try itemAt(diff, "a%20b%25.txt");
    try std.testing.expectEqualStrings("a b%.txt", field(odd, "name").string);
    const narrowed = try (try t.diff(&head, "path=a%20b%25.txt")).ok();
    try std.testing.expectEqual(1, items(narrowed).len);
    try std.testing.expectEqualStrings("a%20b%25.txt", field(narrowed, "path").string);
}

test "a commit's diff refuses what isn't a commit or a valid window" {
    var t: TestRepo(.git) = undefined;
    try t.init();
    defer t.deinit();
    const head = try t.commit(&.{.{ "a.txt", "a\n" }}, &.{});
    var tree_oid: [40]u8 = undefined;
    {
        var moment = try t.repo.core.latestMoment();
        const state = TestRepo(.git).Repo.State(.read_only){ .core = &t.repo.core, .extra = .{ .moment = &moment } };
        var object = try xit.object.Object(.git, TestRepo(.git).opts).init(state, std.testing.io, std.testing.allocator, &head);
        defer object.deinit();
        tree_oid = object.content.commit.tree;
    }
    for ([_][]const u8{ "", "abc", head[0..39], "0000000000000000000000000000000000000000", &tree_oid }) |oid| {
        try std.testing.expectEqual(.not_found, (try (try t.diff(oid, "")).failure()).code);
    }
    for ([_]struct { query: []const u8, field: []const u8 }{
        .{ .query = "path=%zz", .field = "path" },
        .{ .query = "cursor=x", .field = "cursor" },
        .{ .query = "page_size=0", .field = "page_size" },
    }) |case| {
        const err = try (try t.diff(&head, case.query)).failure();
        try std.testing.expectEqual(.validation, err.code);
        try std.testing.expectEqualStrings(case.field, err.field_errors[0].field);
    }
}
