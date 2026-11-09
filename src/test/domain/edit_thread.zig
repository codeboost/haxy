const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const alices: fixture.Id = @splat(0xa1);
const alices_hex = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1";
const carols: fixture.Id = @splat(0xc1);
const carols_hex = "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1";

test "domain: EditThread replaces an issue's title, labels and body" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .title = "renamed", .labels = "bug ui", .body = "steps" }).run(&bob);
    const entry = try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob);
    try std.testing.expectEqualStrings("renamed", entry.record.event.title);
    try std.testing.expectEqualStrings("bug ui", entry.record.event.labels);
    try std.testing.expectEqualStrings("steps", entry.record.event.description);
    try std.testing.expectEqual(.open, entry.record.event.status);
}

test "domain: EditThread refuses a blank title and an overlong label" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    try std.testing.expectError(error.InvalidTitle, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .title = "  " }).run(&bob));
    try std.testing.expectError(error.InvalidLabels, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .title = "fine", .labels = &@as([65]u8, @splat('x')) }).run(&bob));
    try std.testing.expectEqualStrings("an issue", (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob)).record.event.title);
}

test "domain: EditThread lets a writer edit any thread and a reader only their own" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addIssue(server.open, Server.carol_author, carols);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try std.testing.expectError(error.Forbidden, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = alices_hex, .title = "mine now" }).run(&carol));
    try std.testing.expectEqualStrings("an issue", (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&carol)).record.event.title);
    try (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .title = "carol's" }).run(&carol);
    try std.testing.expectEqualStrings("carol's", (try (domain.GetIssue{ .repo = "alice:open", .id = carols_hex }).run(&carol)).record.event.title);
}

test "domain: EditThread needs a login, the tab's role, a repo the user can see and a known thread" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.addIssue(server.open, Server.carol_author, carols);
    try server.addIssue(server.secret, Server.alice_author, alices);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .title = "t" }).run(&ctx));
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.NotFound, (domain.EditThread{ .repo = "alice:secret", .kind = .issue, .thread_id = alices_hex, .title = "t" }).run(&carol));

    var bob = try server.ctx(&arena, server.bob);
    for ([_][]const u8{ "22222222222222222222222222222222", "not an id" }) |id| {
        try std.testing.expectError(error.NotFound, (domain.EditThread{ .repo = "alice:secret", .kind = .issue, .thread_id = id, .title = "t" }).run(&bob));
    }

    // only writers may write to the public repo's issues, even their own
    try server.setTabs(server.open, .read, .write, null);
    try std.testing.expectError(error.Forbidden, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .title = "t" }).run(&carol));
    // a tab that is off doesn't exist
    try server.setTabs(server.open, .read, null, null);
    try std.testing.expectError(error.NotFound, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .title = "t" }).run(&bob));
}

test "domain: EditThread edits a discussion and finds no thread of the wrong kind" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.addIssue(server.open, Server.alice_author, alices);
    try server.addEvent(server.open, Server.carol_author, carols, .{ .discuss = .{ .title = "a talk", .description = "", .labels = "" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    try (domain.EditThread{ .repo = "alice:open", .kind = .discuss, .thread_id = carols_hex, .title = "a better talk", .labels = "meta", .body = "agenda" }).run(&carol);
    const entry = try (domain.GetDiscussion{ .repo = "alice:open", .id = carols_hex }).run(&carol);
    try std.testing.expectEqualStrings("a better talk", entry.record.event.title);
    try std.testing.expectEqualStrings("meta", entry.record.event.labels);
    try std.testing.expectEqualStrings("agenda", entry.record.event.description);

    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectError(error.NotFound, (domain.EditThread{ .repo = "alice:open", .kind = .discuss, .thread_id = alices_hex, .title = "t" }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.EditThread{ .repo = "alice:open", .kind = .issue, .thread_id = carols_hex, .title = "t" }).run(&bob));
    try std.testing.expectEqualStrings("an issue", (try (domain.GetIssue{ .repo = "alice:open", .id = alices_hex }).run(&bob)).record.event.title);
}

fn expectLocalEdit(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // written by someone else, which the local owner may still edit
    try local.addEvent(Server.alice_author, alices, .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    try (domain.EditThread{ .repo = "", .kind = .issue, .thread_id = alices_hex, .title = "edited here" }).run(&ctx);
    try std.testing.expectEqualStrings("edited here", (try (domain.GetIssue{ .repo = "", .id = alices_hex }).run(&ctx)).record.event.title);
}

test "domain: EditThread edits an issue in a local git or xit repo" {
    try expectLocalEdit(.git, .sha1);
    try expectLocalEdit(.git, .sha256);
    try expectLocalEdit(.xit, .sha1);
    try expectLocalEdit(.xit, .sha256);
}

fn expectLocalPatchEdit(comptime kind: hx.xit.repo.RepoKind, comptime hash_kind: hx.xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    try local.addEvent(Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "", .labels = "", .target_branch = "master" } });
    try std.testing.expectError(error.InvalidTargetBranch, (domain.EditThread{ .repo = "", .kind = .patch, .thread_id = alices_hex, .title = "t", .target_branch = "nowhere" }).run(&ctx));
    try std.testing.expectError(error.InvalidTargetBranch, (domain.EditThread{ .repo = "", .kind = .patch, .thread_id = alices_hex, .title = "t", .target_branch = "" }).run(&ctx));
    try (domain.EditThread{ .repo = "", .kind = .patch, .thread_id = alices_hex, .title = "a better patch", .labels = "fix", .body = "why", .target_branch = "master" }).run(&ctx);
    const patch = (try (domain.GetPatch{ .repo = "", .id = alices_hex }).run(&ctx)).record;
    try std.testing.expectEqualStrings("a better patch", patch.event.title);
    try std.testing.expectEqualStrings("fix", patch.event.labels);
    try std.testing.expectEqualStrings("why", patch.event.description);
    try std.testing.expectEqualStrings("master", patch.event.target_branch);
}

test "domain: EditThread edits a patch in a local git or xit repo and checks its target branch" {
    try expectLocalPatchEdit(.git, .sha1);
    try expectLocalPatchEdit(.xit, .sha256);
}

fn expectServerPatchEdit(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    try server.addEvent(server.open, Server.alice_author, alices, .{ .patch = .{ .title = "a patch", .description = "", .labels = "", .target_branch = "master" } });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    for ([_][]const u8{ "nowhere", "" }) |target_branch| {
        try std.testing.expectError(error.InvalidTargetBranch, (domain.EditThread{ .repo = "alice:open", .kind = .patch, .thread_id = alices_hex, .title = "t", .target_branch = target_branch }).run(&bob));
    }
    try (domain.EditThread{ .repo = "alice:open", .kind = .patch, .thread_id = alices_hex, .title = "a better patch", .labels = "fix", .body = "why", .target_branch = "master" }).run(&bob);
    {
        const patch = (try (domain.GetPatch{ .repo = "alice:open", .id = alices_hex }).run(&bob)).record;
        try std.testing.expectEqualStrings("a better patch", patch.event.title);
        try std.testing.expectEqualStrings("fix", patch.event.labels);
        try std.testing.expectEqualStrings("why", patch.event.description);
    }

    // a draft lives in its author's fork, which only they may edit
    const bobs: fixture.Id = @splat(0xb1);
    const bobs_hex = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";
    try server.addDraft(server.open, server.bob, Server.bob_author, bobs);
    try (domain.EditThread{ .repo = "alice:open", .kind = .patch, .thread_id = bobs_hex, .title = "a better draft", .body = "soon", .target_branch = "master" }).run(&bob);
    {
        const draft = (try (domain.GetPatch{ .repo = "alice:open", .id = bobs_hex }).run(&bob)).record;
        try std.testing.expectEqualStrings("a better draft", draft.event.title);
        try std.testing.expectEqualStrings("soon", draft.event.description);
    }
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, (domain.EditThread{ .repo = "alice:open", .kind = .patch, .thread_id = bobs_hex, .title = "carol's draft", .target_branch = "master" }).run(&carol));
    try std.testing.expectEqualStrings("a better draft", (try (domain.GetPatch{ .repo = "alice:open", .id = bobs_hex }).run(&bob)).record.event.title);
}

test "domain: EditThread edits a server patch or its author's draft and checks the target branch" {
    try expectServerPatchEdit(.sha1);
    try expectServerPatchEdit(.sha256);
}
