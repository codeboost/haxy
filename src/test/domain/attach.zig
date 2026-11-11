const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const carols: fixture.Id = @splat(0xc1);
const carols_hex = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

fn attach(ctx: *domain.Ctx, repo: []const u8, thread_id: []const u8, name: []const u8, contents: []const u8) !domain.Attach.Result {
    var reader = std.Io.Reader.fixed(contents);
    return try (domain.Attach{ .repo = repo, .kind = .issue, .thread_id = thread_id, .name = name, .size = contents.len, .reader = &reader }).run(ctx);
}

test "domain: Attach streams a file onto a thread its author or a writer may change" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    // the bytes arrive in several pieces, as from a socket
    const contents = "first line\nsecond line\n\x00\xffbinary tail";
    var buffer: [4]u8 = undefined;
    var reader: std.testing.Reader = .init(&buffer, &.{ .{ .buffer = contents[0..5] }, .{ .buffer = contents[5..17] }, .{ .buffer = contents[17..] } });
    const attached = try (domain.Attach{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .name = "notes.bin", .size = contents.len, .reader = &reader.interface }).run(&carol);
    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = carols_hex }).run(&carol);
    try std.testing.expectEqual(1, entry.attachments.len);
    try std.testing.expectEqualStrings(&attached.id, &entry.attachments[0].id);
    try std.testing.expectEqualStrings("notes.bin", entry.attachments[0].name);
    try std.testing.expectEqualSlices(u8, contents, try server.readAttachment(server.open, &attached.id));

    // a reader may not change someone else's thread; a writer may
    try std.testing.expectError(error.Forbidden, attach(&carol, "alice:open", alices_hex, "notes.txt", "hello\n"));
    var bob = try server.ctx(&arena, server.bob);
    _ = try attach(&bob, "alice:open", alices_hex, "notes.txt", "hello\n");
    try std.testing.expectEqual(1, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob)).attachments.len);
}

test "domain: Attach refuses a bad name, an empty or oversized file and unknown threads" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    for ([_][]const u8{ "", "a/b.txt" }) |name| {
        try std.testing.expectError(error.InvalidAttachmentName, attach(&bob, "alice:open", alices_hex, name, "hello\n"));
    }
    try std.testing.expectError(error.AttachmentEmpty, attach(&bob, "alice:open", alices_hex, "notes.txt", ""));
    {
        // the declared size is checked before anything is read
        var reader = std.Io.Reader.fixed("");
        try std.testing.expectError(error.AttachmentTooLarge, (domain.Attach{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .name = "big.bin", .size = evt.Attachment.max_size + 1, .reader = &reader }).run(&bob));
    }
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, attach(&bob, "alice:open", id, "notes.txt", "hello\n"));
    }
    try std.testing.expectEqual(0, (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob)).attachments.len);
    try std.testing.expectEqual(.invalid_input, domain.classify(error.InvalidAttachmentName).kind);
    try std.testing.expectEqual(.limit_reached, domain.classify(error.AttachmentTooLarge).kind);
}

test "domain: Attach needs a login, the tab's role and a repo the user can see" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, attach(&ctx, "alice:secret", alices_hex, "notes.txt", "hello\n"));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, attach(&carol, "alice:secret", alices_hex, "notes.txt", "hello\n"));

    // carol's own issue, once the tab takes writers, is out of her reach
    try server.addIssue(server.open, Server.carol_author, carols);
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, attach(&carol, "alice:open", carols_hex, "notes.txt", "hello\n"));
    // and a tab that is off doesn't exist
    try server.setTabs(server.open, .read, null, null);
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectError(error.NotFound, attach(&bob, "alice:open", carols_hex, "notes.txt", "hello\n"));
}

fn expectLocalAttach(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    _ = try attach(&ctx, "", alices_hex, "notes.txt", "hello\n");
    try std.testing.expectEqualStrings("notes.txt", (try (domain.GetIssue{ .repo = "", .id = alices_hex }).run(&ctx)).attachments[0].name);
}

test "domain: Attach works in a local git or xit repo" {
    try expectLocalAttach(.git, .sha1);
    try expectLocalAttach(.xit, .sha256);
}
