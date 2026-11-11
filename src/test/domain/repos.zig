const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const allocator = std.testing.allocator;
const Server = fixture.Server;

test "domain: CreateRepo creates a repo for the acting user and names it" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = try (domain.CreateRepo{ .name = "fresh", .description = "a new one", .access = .public, .hash = .sha256 }).run(&bob);
    try std.testing.expectEqualStrings("bob:fresh", created.identity);
    // a public repo, which a stranger reads
    var carol = try server.ctx(&arena, server.carol);
    const resolved = (try domain.resolveRepo(&carol, "bob:fresh")) orelse return error.TestExpectedRepo;
    try std.testing.expectEqualStrings("a new one", resolved.record.event.description);
    try std.testing.expectEqual(.read, resolved.role);
}

test "domain: CreateRepo copies a repo the acting user can read, under its hash" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try server.commitReadme(server.secret);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);

    const created = try (domain.CreateRepo{ .name = "copied", .copy = "alice:secret" }).run(&bob);
    try std.testing.expectEqualStrings("bob:copied", created.identity);
    const resolved = (try domain.resolveRepo(&bob, "bob:copied")) orelse return error.TestExpectedRepo;
    try std.testing.expectEqual(.owner, resolved.role);
    // private by default
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(null, try domain.resolveRepo(&carol, "bob:copied"));
    // the copy holds the source's commits, under its sha-256 ids
    const copied = try server.locate(server.bob, "copied");
    const master = (try server.readBranch(copied, "master")) orelse return error.TestExpectedBranch;
    try std.testing.expectEqual(64, master.len);
    try std.testing.expectEqualStrings((try server.readBranch(server.secret, "master")).?, master);
}

test "domain: CreateRepo refuses a copy source the acting user can't read or that doesn't exist" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var carol = try server.ctx(&arena, server.carol);

    for ([_][]const u8{ "alice:secret", "alice:missing", "alice", "nobody:open" }) |source| {
        try std.testing.expectError(error.InvalidCopySource, (domain.CreateRepo{ .name = "copied", .copy = source }).run(&carol));
    }
    try std.testing.expectEqual(null, try domain.resolveRepo(&carol, "carol:copied"));
}

test "domain: CreateRepo refuses bad and taken names" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.NameEmpty, (domain.CreateRepo{ .name = "" }).run(&alice));
    try std.testing.expectError(error.NameTooLong, (domain.CreateRepo{ .name = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }).run(&alice));
    for ([_][]const u8{ "..", "has space", "a:b", "a/b" }) |name| {
        try std.testing.expectError(error.InvalidName, (domain.CreateRepo{ .name = name }).run(&alice));
    }
    try std.testing.expectError(error.NameTaken, (domain.CreateRepo{ .name = "open" }).run(&alice));
    // another user's repo name is free
    var bob = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateRepo{ .name = "open" }).run(&bob);
}

test "domain: CreateRepo needs a login and a server" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.CreateRepo{ .name = "fresh" }).run(&ctx));
    }

    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.CreateRepo{ .name = "fresh" }).run(&ctx));
}

test "domain: UpdateRepoSettings renames a repo and changes its settings" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    const updated = try (domain.UpdateRepoSettings{ .repo = "alice:open", .name = "renamed", .description = "now private", .access = .private, .discuss_role = null, .issue_role = .write, .patch_role = .read }).run(&alice);
    try std.testing.expectEqualStrings("alice:renamed", updated.identity);
    try std.testing.expectEqual(null, try domain.resolveRepo(&alice, "alice:open"));
    const resolved = (try domain.resolveRepo(&alice, "alice:renamed")) orelse return error.TestExpectedRepo;
    try std.testing.expectEqualStrings("now private", resolved.record.event.description);
    try std.testing.expectEqual(.private, resolved.record.event.read_access);
    try std.testing.expectEqual(null, resolved.record.event.discuss_role);
    try std.testing.expectEqual(.write, resolved.record.event.issue_role);
    try std.testing.expectEqual(.read, resolved.record.event.patch_role);
    // private now, so a stranger no longer sees it
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(null, try domain.resolveRepo(&carol, "alice:renamed"));
}

fn settings(repo: []const u8, name: []const u8) domain.UpdateRepoSettings {
    return .{ .repo = repo, .name = name, .description = "", .access = .public, .discuss_role = .read, .issue_role = .read, .patch_role = null };
}

test "domain: UpdateRepoSettings refuses bad and taken names" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.NameEmpty, settings("alice:open", "").run(&alice));
    try std.testing.expectError(error.InvalidName, settings("alice:open", "a b").run(&alice));
    try std.testing.expectError(error.NameTaken, settings("alice:open", "secret").run(&alice));
    // keeping its own name is no clash
    _ = try settings("alice:open", "open").run(&alice);
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
}

test "domain: UpdateRepoSettings needs the owner role" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expectError(error.Forbidden, settings("alice:open", "taken").run(&bob));
    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectError(error.Forbidden, settings("alice:open", "taken").run(&carol));
    // a private repo doesn't exist to a stranger
    try std.testing.expectError(error.NotFound, settings("alice:secret", "taken").run(&carol));
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, settings("alice:open", "taken").run(&ctx));
    }
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expectError(error.NotFound, settings("alice:missing", "taken").run(&alice));
    try std.testing.expectError(error.NotFound, settings("alice", "taken").run(&alice));
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:taken") == null);

    // a granted owner may change it
    try evt.grantRole(std.testing.io, allocator, server.users_dir, &server.alice, &server.open.repo_id, &server.bob, .owner, Server.alice_author);
    const updated = try settings("alice:open", "taken").run(&bob);
    try std.testing.expectEqualStrings("alice:taken", updated.identity);
}

test "domain: UpdateRepoSettings is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, settings("", "renamed").run(&ctx));
}

test "domain: DeleteRepo deletes the creator's repo once its name and their password are given" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    const path = try server.repoPath(server.open);

    try (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&alice);
    try std.testing.expectEqual(null, try domain.resolveRepo(&alice, "alice:open"));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, path, .{}));
    // the other repo stays
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:secret") != null);
}

test "domain: DeleteRepo checks the typed name before the password" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.WrongConfirm, (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:opne", .password = "wrong" }).run(&alice));
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
}

test "domain: DeleteRepo needs the acting user's password" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    try std.testing.expectError(error.WrongPassword, (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "wrong" }).run(&alice));
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
}

test "domain: DeleteRepo finds nothing for anyone but the creator, a granted owner too" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try evt.grantRole(std.testing.io, allocator, server.users_dir, &server.alice, &server.open.repo_id, &server.bob, .owner, Server.alice_author);

    for ([_]fixture.Id{ server.bob, server.carol }) |user| {
        var ctx = try server.ctx(&arena, user);
        for ([_][]const u8{ "alice:open", "alice:secret" }) |repo| {
            try std.testing.expectError(error.NotFound, (domain.DeleteRepo{ .repo = repo, .confirm = repo, .password = "password" }).run(&ctx));
        }
    }
    var alice = try server.ctx(&arena, server.alice);
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:secret") != null);
}

test "domain: DeleteRepo doesn't take another owner's repo for the acting user's of the same name" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    _ = try (domain.CreateRepo{ .name = "open" }).run(&bob);

    try std.testing.expectError(error.NotFound, (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&bob));
    try std.testing.expect(try domain.resolveRepo(&bob, "bob:open") != null);
    try std.testing.expect(try domain.resolveRepo(&bob, "alice:open") != null);
}

test "domain: DeleteRepo needs a login" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for ([_]?fixture.Id{ server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.LoginRequired, (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&ctx));
    }
}

test "domain: DeleteRepo is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.DeleteRepo{ .repo = "", .confirm = "", .password = "" }).run(&ctx));
}

test "domain: UpdateRepoSettings replaces the whole settings, so the description is required" {
    // an omitted description would clear the one there
    try std.testing.expect(std.meta.fieldInfo(domain.UpdateRepoSettings, .description).attrs.default_value_ptr == null);
}

test "domain: UpdateRepoSettings refuses an owners-only tab, which no form offers" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);

    var owners_only = settings("alice:open", "renamed");
    owners_only.issue_role = .owner;
    try std.testing.expectError(error.InvalidTabRole, owners_only.run(&alice));
    owners_only = settings("alice:open", "renamed");
    owners_only.patch_role = .owner;
    try std.testing.expectError(error.InvalidTabRole, owners_only.run(&alice));
    try std.testing.expect(try domain.resolveRepo(&alice, "alice:open") != null);
    try std.testing.expectEqual(.invalid_input, domain.classify(error.InvalidTabRole).kind);
}
