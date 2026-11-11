const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: files: ReadFile reads a file's lines at the default branch" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = "src/main.zig", .contents = "one\ntwo\nthree\n" },
        .{ .path = "src/other.zig", .contents = "other\n" },
    }, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = try server.ctx(&arena, server.carol);
    const file = try (domain.ReadFile{ .repo = "alice:open", .path = "src/main.zig" }).run(&ctx);
    try std.testing.expectEqualStrings("main.zig", file.name);
    try std.testing.expect(!file.is_binary);
    // the trailing newline ends an empty last line
    try std.testing.expectEqual(4, file.lines.len);
    try std.testing.expectEqualStrings("one", file.lines[0]);
    try std.testing.expectEqualStrings("two", file.lines[1]);
    try std.testing.expectEqualStrings("three", file.lines[2]);
    try std.testing.expectEqualStrings("", file.lines[3]);
    try std.testing.expectEqual(0, file.window_start);
    try std.testing.expect(!file.has_more);
}

// a branch and a file whose names hold a literal `%`, a multi-byte character
// and a `/`, beside ones a second decoding would name
const odd_branch = "team/50%41-é";
const odd_path = "50%41 café/sub/odd.txt";

test "domain: files: ReadFile takes decoded branches and paths" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = odd_path, .contents = "odd on master\n" },
        .{ .path = "50A café/sub/odd.txt", .contents = "plain on master\n" },
    }, "first");
    try fixture.commitServerFiles(server, server.open, odd_branch, &.{.{ .path = odd_path, .contents = "odd on odd\n" }}, "odd");
    try fixture.commitServerFiles(server, server.open, "team/50A-é", &.{.{ .path = odd_path, .contents = "odd on plain\n" }}, "plain");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = odd_path }).run(&ctx);
        try std.testing.expectEqualStrings("odd on master", file.lines[0]);
    }
    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .ref_kind = .branch, .ref = odd_branch, .path = odd_path }).run(&ctx);
        try std.testing.expectEqualStrings("odd on odd", file.lines[0]);
    }
}

test "domain: files: ReadFile reads a window from the given line" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // one more line than a window holds
    var contents: std.Io.Writer.Allocating = .init(allocator);
    defer contents.deinit();
    for (1..5002) |i| try contents.writer.print("line {d}\n", .{i});
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "long.txt", .contents = contents.written() }}, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "long.txt" }).run(&ctx);
        try std.testing.expectEqual(5000, file.lines.len);
        try std.testing.expectEqualStrings("line 1", file.lines[0]);
        try std.testing.expectEqualStrings("line 5000", file.lines[4999]);
        try std.testing.expect(file.has_more);
    }
    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "long.txt", .line = 5001 }).run(&ctx);
        try std.testing.expectEqual(5000, file.window_start);
        try std.testing.expectEqualStrings("line 5001", file.lines[0]);
        // the empty line after the last newline
        try std.testing.expectEqualStrings("", file.lines[1]);
        try std.testing.expect(!file.has_more);
    }
    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "long.txt", .line = 2 }).run(&ctx);
        try std.testing.expectEqualStrings("line 2", file.lines[0]);
    }
}

test "domain: files: ReadFile tells a file, a binary file, a directory and a missing path apart" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = "dir/text.txt", .contents = "text\n" },
        .{ .path = "dir/blob.bin", .contents = "\xff\xfe not utf-8\n" },
    }, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const text = try (domain.ReadFile{ .repo = "alice:open", .path = "dir/text.txt" }).run(&ctx);
    try std.testing.expect(!text.is_binary);
    try std.testing.expectEqualStrings("text", text.lines[0]);
    const binary = try (domain.ReadFile{ .repo = "alice:open", .path = "dir/blob.bin" }).run(&ctx);
    // xit reads invalid utf-8 as binary
    try std.testing.expect(binary.is_binary);
    try std.testing.expectEqual(0, binary.lines.len);
    try std.testing.expect(binary.loaded);
    for ([_][]const u8{ "dir", "" }) |path| {
        try std.testing.expectError(error.NotAFile, (domain.ReadFile{ .repo = "alice:open", .path = path }).run(&ctx));
    }
    for ([_][]const u8{ "missing", "dir/missing", "dir/text.txt/more" }) |path| {
        try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .path = path }).run(&ctx));
    }
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .ref_kind = .branch, .ref = "missing", .path = "dir/text.txt" }).run(&ctx));
}

test "domain: files: ReadFile reads a file among a find's results" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{
        .{ .path = "src/main.zig", .contents = "main\n" },
        .{ .path = "docs/50%41.txt", .contents = "odd\n" },
        .{ .path = "docs/50A.txt", .contents = "plain\n" },
    }, "first");
    try fixture.indexServerFiles(server, server.open);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "src/main.zig", .find = "ma" }).run(&ctx);
        try std.testing.expectEqualStrings("src/main.zig", file.name);
        try std.testing.expectEqualStrings("main", file.lines[0]);
    }
    {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "docs/50%41.txt", .find = "50%41" }).run(&ctx);
        try std.testing.expectEqualStrings("odd", file.lines[0]);
    }
    // the find is not decoded again, so it doesn't match the plain name
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .path = "docs/50A.txt", .find = "50%41" }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .path = "src/main.zig", .find = "zz" }).run(&ctx));
}

test "domain: files: ReadFile reads a patch revision's file" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "a.txt", .contents = "master\n" }}, "first");
    try fixture.commitServerFiles(server, server.open, "topic", &.{.{ .path = "a.txt", .contents = "topic\n" }}, "topic");
    const revision: fixture.Id = @splat(0x77);
    try fixture.addServerRevision(server, server.open, Server.alice_author, revision, "topic");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    const file = try (domain.ReadFile{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .path = "a.txt" }).run(&ctx);
    try std.testing.expectEqualStrings("topic", file.lines[0]);
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .patchrev = "88888888888888888888888888888888", .path = "a.txt" }).run(&ctx));
    // a revision has no file index to find in, nor a ref beside it
    try std.testing.expectError(error.InvalidReadArguments, (domain.ReadFile{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .path = "a.txt", .find = "a" }).run(&ctx));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ReadFile{ .repo = "alice:open", .patchrev = "77777777777777777777777777777777", .path = "a.txt", .ref_kind = .tag, .ref = "v1" }).run(&ctx));
}

test "domain: files: ReadFile finds no repo the viewer can't see, and lets anyone read a public one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.commitReadme(server.open);
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:secret", .path = "README" }).run(&ctx));
    }
    var ctx = try server.ctx(&arena, null);
    const file = try (domain.ReadFile{ .repo = "alice:open", .path = "README" }).run(&ctx);
    try std.testing.expectEqualStrings("repo", file.lines[0]);
}

fn expectLocalRead(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    try fixture.commitLocalFiles(kind, &local, odd_branch, &.{.{ .path = odd_path, .contents = "odd\n" }}, "odd");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    {
        const file = try (domain.ReadFile{ .repo = "", .path = "readme.txt" }).run(&ctx);
        try std.testing.expectEqualStrings("hello", file.lines[0]);
    }
    {
        const file = try (domain.ReadFile{ .repo = "", .ref_kind = .branch, .ref = odd_branch, .path = odd_path }).run(&ctx);
        try std.testing.expectEqualStrings("odd", file.lines[0]);
    }
    {
        const file = try (domain.ReadFile{ .repo = "", .ref_kind = .object, .ref = &local.master_oid, .path = "readme.txt" }).run(&ctx);
        try std.testing.expectEqualStrings("hello", file.lines[0]);
    }
    // only a server branch has a file index
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "", .path = "readme.txt", .find = "read" }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "alice:open", .path = "readme.txt" }).run(&ctx));
}

test "domain: files: ReadFile reads a local git or xit repo" {
    try expectLocalRead(.git, .sha1);
    try expectLocalRead(.git, .sha256);
    try expectLocalRead(.xit, .sha1);
    try expectLocalRead(.xit, .sha256);
}

test "domain: files: ReadFile pages a file by the next window's line, each line once" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // two full windows of 5000 and a part, ending in a newline
    const count = 10_500;
    var contents: std.Io.Writer.Allocating = .init(allocator);
    defer contents.deinit();
    for (1..count + 1) |i| try contents.writer.print("line {d}\n", .{i});
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "long.txt", .contents = contents.written() }}, "first");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.carol);

    // the rule the description gives: the next window's `line` is
    // window_start + lines.len + 1, while has_more holds
    var seen: std.ArrayList([]const u8) = .empty;
    defer seen.deinit(allocator);
    var line: usize = 1;
    var windows: usize = 0;
    while (true) {
        const file = try (domain.ReadFile{ .repo = "alice:open", .path = "long.txt", .line = line }).run(&ctx);
        windows += 1;
        try std.testing.expectEqual(line - 1, file.window_start);
        try seen.appendSlice(allocator, file.lines);
        if (!file.has_more) break;
        line = file.window_start + file.lines.len + 1;
    }
    try std.testing.expectEqual(3, windows);
    // every line once, then the empty string after the final newline
    try std.testing.expectEqual(count + 1, seen.items.len);
    var expected: [32]u8 = undefined;
    for (seen.items[0..count], 1..) |text, i| {
        try std.testing.expectEqualStrings(try std.fmt.bufPrint(&expected, "line {d}", .{i}), text);
    }
    try std.testing.expectEqualStrings("", seen.items[count]);
}

test "domain: files: ReadFile and ListFiles report a content or tree read that fails" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try fixture.commitLocalFiles(.git, &local, "master", &.{
        .{ .path = "dir/lost.txt", .contents = "lost\n" },
        .{ .path = "gone/kept.txt", .contents = "kept\n" },
    }, "second");
    // the tree still names them, but their objects are gone
    try fixture.removeGitObject(&local, "dir/lost.txt");
    try fixture.removeGitObject(&local, "gone");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // the page shows an empty file and an empty listing; a read fails
    // internally, never as an empty result or a missing path
    try expectInternal((domain.ReadFile{ .repo = "", .path = "dir/lost.txt" }).run(&ctx));
    try expectInternal((domain.ListFiles{ .repo = "", .path = "dir" }).run(&ctx));
    try expectInternal((domain.ListFiles{ .repo = "", .path = "gone" }).run(&ctx));
    try expectInternal((domain.ReadFile{ .repo = "", .path = "gone/kept.txt" }).run(&ctx));
    // what is still there reads as before
    const file = try (domain.ReadFile{ .repo = "", .path = "readme.txt" }).run(&ctx);
    try std.testing.expectEqualStrings("hello", file.lines[0]);
}

fn expectInternal(result: anytype) !void {
    if (result) |_| return error.TestExpectedError else |err| {
        try std.testing.expectEqual(.internal, domain.classify(err).kind);
    }
}
