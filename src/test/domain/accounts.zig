const std = @import("std");
const hx = @import("../../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const fixture = @import("fixture.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

// add accounts named each of `names`
fn addUsers(server: *Server, names: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (names) |name| {
        _ = try evt.createUser(io, allocator, server.users_dir, &server.admin, name, try arena.allocator().print("{s}@example.test", .{name}), "password", "password");
    }
}

test "domain: accounts: ListUsers lists the active accounts by name, without the removed one" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ null, server.carol }) |user| {
        var ctx = try server.ctx(&arena, user);
        const users = try (domain.ListUsers{}).run(&ctx);
        try std.testing.expectEqual(3, users.users.len);
        try std.testing.expectEqualStrings("alice", users.users[0].name);
        try std.testing.expectEqualStrings("bob", users.users[1].name);
        try std.testing.expectEqualStrings("carol", users.users[2].name);
        try std.testing.expectEqual(0, users.start);
        try std.testing.expectEqual(null, users.next_start);
        try std.testing.expectEqual(null, users.search);
    }
}

test "domain: accounts: ListUsers searches by a decoded name prefix" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    {
        const users = try (domain.ListUsers{ .search = "b" }).run(&ctx);
        try std.testing.expectEqual(1, users.users.len);
        try std.testing.expectEqualStrings("bob", users.users[0].name);
        try std.testing.expectEqualStrings("b", users.search.?);
    }
    // "%61" would decode to "a", and no name holds a `%` or "é"
    for ([_][]const u8{ "%61", "é", "a/" }) |search| {
        const users = try (domain.ListUsers{ .search = search }).run(&ctx);
        try std.testing.expectEqual(0, users.users.len);
        try std.testing.expectEqualStrings(search, users.search.?);
    }
}

test "domain: accounts: ListUsers pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try addUsers(server, &.{ "user01", "user02", "user03", "user04", "user05", "user06", "user07", "user08", "user09", "user10", "user11", "user12", "user13", "user14", "user15", "user16", "user17", "user18" });
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.bob);

    const first = try (domain.ListUsers{}).run(&ctx);
    try std.testing.expectEqual(20, first.users.len);
    try std.testing.expectEqualStrings("alice", first.users[0].name);
    try std.testing.expectEqualStrings("user17", first.users[19].name);
    try std.testing.expectEqual(20, first.next_start.?);

    const second = try (domain.ListUsers{ .start = 20 }).run(&ctx);
    try std.testing.expectEqual(1, second.users.len);
    try std.testing.expectEqualStrings("user18", second.users[0].name);
    try std.testing.expectEqual(null, second.next_start);

    // the search narrows before the window
    const searched = try (domain.ListUsers{ .search = "user1" }).run(&ctx);
    try std.testing.expectEqual(9, searched.users.len);
    try std.testing.expectEqualStrings("user10", searched.users[0].name);

    // a start past the end starts no window
    try std.testing.expectError(error.NotFound, (domain.ListUsers{ .start = 21 }).run(&ctx));
    try std.testing.expectError(error.NotFound, (domain.ListUsers{ .search = "user1", .start = 20 }).run(&ctx));
}

test "domain: accounts: ListUsers is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.ListUsers{}).run(&ctx));
}

// carol's repos, made in this order: two public ones and a private one
fn addCarolsRepos(server: *Server) !void {
    for ([_][]const u8{ "first", "second", "hidden" }, [_]evt.Repo.Access{ .public, .public, .private }) |name, access| {
        _ = try evt.createRepo(io, allocator, server.users_dir, &server.carol, Server.carol_author, name, "", access, .sha1, null);
    }
}

// the repos' names in name order, as `expected` lists them. the unsearched
// order is by activity, which repos made within one second of each other
// share, so a test can't know it.
fn expectNameSet(expected: []const []const u8, repos: []const evt.Repo.Record) !void {
    var names: [32][]const u8 = undefined;
    for (repos, 0..) |repo, i| names[i] = repo.event.name;
    std.mem.sort([]const u8, names[0..repos.len], {}, lessThan);
    errdefer for (names[0..repos.len]) |name| std.debug.print("got {s}\n", .{name});
    try std.testing.expectEqual(expected.len, repos.len);
    for (expected, names[0..repos.len]) |name, got| try std.testing.expectEqualStrings(name, got);
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn expectNames(expected: []const []const u8, repos: []const evt.Repo.Record) !void {
    errdefer for (repos) |repo| std.debug.print("got {s}\n", .{repo.event.name});
    try std.testing.expectEqual(expected.len, repos.len);
    for (expected, repos) |name, repo| try std.testing.expectEqualStrings(name, repo.event.name);
}

test "domain: accounts: ListRepos lists a user's repos as the viewer may read them" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try addCarolsRepos(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the owner sees the private one
    {
        var ctx = try server.ctx(&arena, server.carol);
        const repos = try (domain.ListRepos{ .user = "carol" }).run(&ctx);
        try expectNameSet(&.{ "first", "hidden", "second" }, repos.repos);
        try std.testing.expectEqual(0, repos.start);
        try std.testing.expectEqual(null, repos.next_start);
        try std.testing.expectEqual(null, repos.search);
    }
    // a stranger, a removed member and a logged-out reader don't
    for ([_]?fixture.Id{ server.bob, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        const repos = try (domain.ListRepos{ .user = "carol" }).run(&ctx);
        try expectNameSet(&.{ "first", "second" }, repos.repos);
    }
    // alice's private repo is listed for her member
    {
        var ctx = try server.ctx(&arena, server.bob);
        const repos = try (domain.ListRepos{ .user = "alice", .search = "s" }).run(&ctx);
        try expectNames(&.{"secret"}, repos.repos);
    }
    {
        var ctx = try server.ctx(&arena, server.carol);
        const repos = try (domain.ListRepos{ .user = "alice", .search = "s" }).run(&ctx);
        try expectNames(&.{}, repos.repos);
    }
}

test "domain: accounts: ListRepos searches by a decoded name prefix" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try addCarolsRepos(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, null);

    {
        const repos = try (domain.ListRepos{ .user = "carol", .search = "s" }).run(&ctx);
        try expectNames(&.{"second"}, repos.repos);
        try std.testing.expectEqualStrings("s", repos.search.?);
    }
    // "%66" would decode to "f", and no name holds a `%`, a "/" or "é"
    for ([_][]const u8{ "%66", "f/", "é" }) |search| {
        const repos = try (domain.ListRepos{ .user = "carol", .search = search }).run(&ctx);
        try expectNames(&.{}, repos.repos);
        try std.testing.expectEqualStrings(search, repos.search.?);
    }
}

test "domain: accounts: ListRepos pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (1..22) |i| {
        // every fourth is private, which its window leaves out for others
        const access: evt.Repo.Access = if (i % 4 == 0) .private else .public;
        _ = try evt.createRepo(io, allocator, server.users_dir, &server.carol, Server.carol_author, try arena.allocator().print("repo{d:0>2}", .{i}), "", access, .sha1, null);
    }

    // every repo is in one of the two windows
    const all = [_][]const u8{ "repo01", "repo02", "repo03", "repo04", "repo05", "repo06", "repo07", "repo08", "repo09", "repo10", "repo11", "repo12", "repo13", "repo14", "repo15", "repo16", "repo17", "repo18", "repo19", "repo20", "repo21" };
    const public = [_][]const u8{ "repo01", "repo02", "repo03", "repo05", "repo06", "repo07", "repo09", "repo10", "repo11", "repo13", "repo14", "repo15", "repo17", "repo18", "repo19", "repo21" };
    for ([_]fixture.Id{ server.carol, server.bob }, [_][]const []const u8{ &all, &public }) |user, expected| {
        var ctx = try server.ctx(&arena, user);
        const first = try (domain.ListRepos{ .user = "carol" }).run(&ctx);
        try std.testing.expectEqual(20, first.next_start.?);
        const second = try (domain.ListRepos{ .user = "carol", .start = 20 }).run(&ctx);
        try std.testing.expectEqual(null, second.next_start);
        // the stranger's windows are short by the private ones, not shifted
        var both: std.ArrayList(evt.Repo.Record) = .empty;
        try both.appendSlice(arena.allocator(), first.repos);
        try both.appendSlice(arena.allocator(), second.repos);
        try expectNameSet(expected, both.items);
        try std.testing.expectError(error.NotFound, (domain.ListRepos{ .user = "carol", .start = 21 }).run(&ctx));
    }
    {
        var ctx = try server.ctx(&arena, server.carol);
        // searched, the names come in order
        const first = try (domain.ListRepos{ .user = "carol", .search = "repo" }).run(&ctx);
        try std.testing.expectEqual(20, first.repos.len);
        try std.testing.expectEqualStrings("repo01", first.repos[0].event.name);
        try std.testing.expectEqualStrings("repo20", first.repos[19].event.name);
        try std.testing.expectEqual(20, first.next_start.?);
        const second = try (domain.ListRepos{ .user = "carol", .search = "repo", .start = 20 }).run(&ctx);
        try expectNames(&.{"repo21"}, second.repos);
        try std.testing.expectEqual(null, second.next_start);
    }
    {
        var ctx = try server.ctx(&arena, server.bob);
        const first = try (domain.ListRepos{ .user = "carol", .search = "repo" }).run(&ctx);
        try std.testing.expectEqual(15, first.repos.len);
        try std.testing.expectEqual(20, first.next_start.?);
        // a window holding only a private repo is short, not past the end
        const private = try (domain.ListRepos{ .user = "carol", .search = "repo20" }).run(&ctx);
        try expectNames(&.{}, private.repos);
        const second = try (domain.ListRepos{ .user = "carol", .search = "repo2", .start = 1 }).run(&ctx);
        try expectNames(&.{"repo21"}, second.repos);
        try std.testing.expectError(error.NotFound, (domain.ListRepos{ .user = "carol", .search = "repo", .start = 21 }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListRepos{ .user = "carol", .search = "repo20", .start = 1 }).run(&ctx));
    }
}

test "domain: accounts: ListRepos and ListForks name an active user" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = try server.ctx(&arena, server.alice);
    for ([_][]const u8{ "dave", "nobody", "", "Alice" }) |name| {
        errdefer std.debug.print("user {s}\n", .{name});
        try std.testing.expectError(error.NotFound, (domain.ListRepos{ .user = name }).run(&ctx));
        try std.testing.expectError(error.NotFound, (domain.ListForks{ .user = name }).run(&ctx));
    }
    // a user with no repos has an empty first window
    const repos = try (domain.ListRepos{ .user = "bob" }).run(&ctx);
    try expectNames(&.{}, repos.repos);
    try std.testing.expectError(error.NotFound, (domain.ListRepos{ .user = "bob", .start = 20 }).run(&ctx));
}

test "domain: accounts: ListRepos and ListForks are server only" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.ListRepos{ .user = "alice" }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.ListForks{ .user = "alice" }).run(&ctx));
}

const open_draft: fixture.Id = @splat(0xb1);
const open_draft_hex = "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1";
const secret_draft: fixture.Id = @splat(0xb2);
const secret_draft_hex = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2";

// bob's drafts on alice's public and private repos, with their patch tabs on
fn addBobsDrafts(server: *Server) !void {
    for ([_]evt.RepoLocation{ server.open, server.secret }, [_]fixture.Id{ open_draft, secret_draft }) |location, id| {
        try server.setTabs(location, .read, .read, .read);
        try server.commitReadme(location);
        try server.addDraft(location, server.bob, Server.bob_author, id);
    }
}

// the forks' ids in id order, as `expected` lists them
fn expectForks(expected: []const []const u8, forks: []const hx.ui.User.ForkItem) !void {
    var ids: [32][]const u8 = undefined;
    for (forks, 0..) |item, i| ids[i] = item.id;
    std.mem.sort([]const u8, ids[0..forks.len], {}, lessThan);
    errdefer for (ids[0..forks.len]) |id| std.debug.print("got {s}\n", .{id});
    try std.testing.expectEqual(expected.len, forks.len);
    for (expected, ids[0..forks.len]) |id, got| try std.testing.expectEqualStrings(id, got);
}

test "domain: accounts: ListForks lists a user's forks whose targets the viewer may read" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try addBobsDrafts(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    for ([_]?fixture.Id{ server.bob, server.alice }) |user| {
        var ctx = try server.ctx(&arena, user);
        const forks = try (domain.ListForks{ .user = "bob" }).run(&ctx);
        try expectForks(&.{ open_draft_hex, secret_draft_hex }, forks.forks);
        try std.testing.expectEqual(0, forks.start);
        try std.testing.expectEqual(null, forks.next_start);
        for (forks.forks) |item| {
            const on_open = std.mem.eql(u8, item.id, open_draft_hex);
            try std.testing.expectEqualStrings(if (on_open) "open" else "secret", item.repo_name);
            try std.testing.expectEqual(@as(?evt.Repo.Access, if (on_open) .public else .private), item.access);
            try std.testing.expectEqualStrings("a draft", item.title);
        }
    }
    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        const forks = try (domain.ListForks{ .user = "bob" }).run(&ctx);
        try expectForks(&.{open_draft_hex}, forks.forks);
    }
    // alice has made no forks
    var ctx = try server.ctx(&arena, server.alice);
    try expectForks(&.{}, (try (domain.ListForks{ .user = "alice" }).run(&ctx)).forks);
    try std.testing.expectError(error.NotFound, (domain.ListForks{ .user = "alice", .start = 20 }).run(&ctx));
}

test "domain: accounts: ListForks leaves a fork of a deleted target to its forker, and hides one whose patches are off" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try addBobsDrafts(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&alice);
    try server.setTabs(server.secret, .read, .read, null);

    {
        var ctx = try server.ctx(&arena, server.bob);
        const forks = try (domain.ListForks{ .user = "bob" }).run(&ctx);
        try expectForks(&.{open_draft_hex}, forks.forks);
        try std.testing.expectEqual(null, forks.forks[0].access);
        try std.testing.expectEqualStrings("open", forks.forks[0].repo_name);
    }
    for ([_]?fixture.Id{ server.alice, server.carol, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try expectForks(&.{}, (try (domain.ListForks{ .user = "bob" }).run(&ctx)).forks);
        // a window the viewer can read none of is short, not past the end
        _ = try (domain.ListForks{ .user = "bob", .start = 1 }).run(&ctx);
        try std.testing.expectError(error.NotFound, (domain.ListForks{ .user = "bob", .start = 2 }).run(&ctx));
    }
}

test "domain: accounts: ListForks pages across a window boundary" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try server.setTabs(server.open, .read, .read, .read);
    try server.commitReadme(server.open);
    var expected: [21][]const u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (&expected, 1..) |*hex, i| {
        const id: fixture.Id = @splat(@intCast(i));
        try server.addDraft(server.open, server.bob, Server.bob_author, id);
        hex.* = try arena.allocator().dupe(u8, &std.fmt.bytesToHex(id, .lower));
    }
    var ctx = try server.ctx(&arena, server.carol);
    const first = try (domain.ListForks{ .user = "bob" }).run(&ctx);
    try std.testing.expectEqual(20, first.forks.len);
    try std.testing.expectEqual(20, first.next_start.?);
    const second = try (domain.ListForks{ .user = "bob", .start = 20 }).run(&ctx);
    try std.testing.expectEqual(1, second.forks.len);
    try std.testing.expectEqual(null, second.next_start);
    var both: std.ArrayList(hx.ui.User.ForkItem) = .empty;
    try both.appendSlice(arena.allocator(), first.forks);
    try both.appendSlice(arena.allocator(), second.forks);
    try expectForks(&expected, both.items);
    try std.testing.expectError(error.NotFound, (domain.ListForks{ .user = "bob", .start = 21 }).run(&ctx));
}

test "domain: accounts: resolveFork finds a fork by its forker, the name it was made under and its id" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    try addBobsDrafts(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // a fork is read with the viewer's role in its target
    for ([_]?fixture.Id{ server.bob, server.alice, server.carol, server.dave, null }, [_]evt.Repo.Role{ .write, .owner, .read, .read, .read }) |user, role| {
        var ctx = try server.ctx(&arena, user);
        const found = (try domain.resolveFork(&ctx, "bob:open", open_draft_hex)) orelse return error.TestExpectedFork;
        try std.testing.expectEqual(role, found.role);
        try std.testing.expectEqual(user != null and std.mem.eql(u8, &user.?, &server.bob), found.forker);
        try std.testing.expectEqualSlices(u8, &open_draft, &found.id);
        try std.testing.expectEqualSlices(u8, &server.bob, &found.forker_id);
        try std.testing.expectEqualSlices(u8, &server.open.repo_id, &found.target_id);
        try std.testing.expectEqualSlices(u8, &server.alice, &found.owner_id);
        try std.testing.expectEqualStrings("alice", found.owner.event.name);
        try std.testing.expectEqualStrings("open", found.target.?.repo.event.name);
        try std.testing.expectEqualStrings(try hx.fork.forkPath(arena.allocator(), server.users_dir, &server.bob, &open_draft), found.path);
    }
    // a private target's fork is as hidden as the target
    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectEqual(null, try domain.resolveFork(&ctx, "bob:secret", secret_draft_hex));
    }
    var bob = try server.ctx(&arena, server.bob);
    try std.testing.expect(try domain.resolveFork(&bob, "bob:secret", secret_draft_hex) != null);
    // the identity and the id must name the same fork
    for ([_][2][]const u8{
        .{ "bob:secret", open_draft_hex },
        .{ "alice:open", open_draft_hex },
        .{ "nobody:open", open_draft_hex },
        .{ "bob", open_draft_hex },
        .{ "bob:open:x", open_draft_hex },
        .{ "bob:open", "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1" },
        .{ "bob:open", "not an id" },
        .{ "bob:open", "" },
    }) |case| {
        errdefer std.debug.print("{s} + {s}\n", .{ case[0], case[1] });
        try std.testing.expectEqual(null, try domain.resolveFork(&bob, case[0], case[1]));
    }
}

test "domain: accounts: resolveFork follows its target: renamed, deleted, patches off" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try addBobsDrafts(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var bob = try server.ctx(&arena, server.bob);
    var carol = try server.ctx(&arena, server.carol);

    // a renamed target keeps the name the fork was made under
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "open", "moved", "", .public, .read, .read, .read);
    {
        const found = (try domain.resolveFork(&carol, "bob:open", open_draft_hex)) orelse return error.TestExpectedFork;
        try std.testing.expectEqualStrings("moved", found.target.?.repo.event.name);
        try std.testing.expectEqual(null, try domain.resolveFork(&carol, "bob:moved", open_draft_hex));
    }
    // patches that are off take their drafts with them, even from the forker
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "moved", "moved", "", .public, .read, .read, null);
    try std.testing.expectEqual(null, try domain.resolveFork(&bob, "bob:open", open_draft_hex));
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, Server.alice_author, "moved", "moved", "", .public, .read, .read, .read);
    // a deleted target leaves the fork to its forker, to read
    var alice = try server.ctx(&arena, server.alice);
    try (domain.DeleteRepo{ .repo = "alice:moved", .confirm = "alice:moved", .password = "password" }).run(&alice);
    {
        const found = (try domain.resolveFork(&bob, "bob:open", open_draft_hex)) orelse return error.TestExpectedFork;
        try std.testing.expectEqual(.read, found.role);
        try std.testing.expectEqual(null, found.target);
        try std.testing.expect(found.forker);
        try std.testing.expectEqualStrings("alice", found.owner.event.name);
    }
    for ([_]*domain.Ctx{ &carol, &alice }) |ctx| try std.testing.expectEqual(null, try domain.resolveFork(ctx, "bob:open", open_draft_hex));
    var nobody = try server.ctx(&arena, null);
    try std.testing.expectEqual(null, try domain.resolveFork(&nobody, "bob:open", open_draft_hex));
    // a deleted fork is gone
    try (domain.DeleteFork{ .identity = "bob:secret", .fork_id = secret_draft_hex, .confirm = "bob:secret", .password = "password" }).run(&bob);
    try std.testing.expectEqual(null, try domain.resolveFork(&bob, "bob:secret", secret_draft_hex));
}

test "domain: accounts: resolveFork is server only" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, domain.resolveFork(&ctx, "bob:open", open_draft_hex));
}

// a directory whose name a second decoding would change
const odd_dir = "50%41 café/sub";

// bob's draft on alice's public repo, with two commits on its patch branch
// pushed as its revision. master holds README.
fn addForkCommits(server: *Server) !void {
    try server.setTabs(server.open, .read, .read, .read);
    try server.setTabs(server.secret, .read, .read, .read);
    try fixture.commitServerFiles(server, server.open, "master", &.{.{ .path = "README", .contents = "base\n" }}, "base");
    try server.addDraft(server.open, server.bob, Server.bob_author, open_draft);
    try fixture.commitForkFiles(server, server.bob, open_draft, &.{.{ .path = "fork.txt", .contents = "forked\n" }}, "on the fork");
    try fixture.commitForkFiles(server, server.bob, open_draft, &.{.{ .path = odd_dir ++ "/x.txt", .contents = "x\n" }}, "second on the fork");
    try server.pushDraft(server.bob, Server.bob_author, open_draft, "patch");
}

fn expectForkReads(comptime hash_kind: hx.xit.hash.HashKind) !void {
    const server = try Server.init(hash_kind);
    defer server.deinit();
    try addForkCommits(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const head = try fixture.forkHead(server, arena.allocator(), server.bob, open_draft);

    for ([_]?fixture.Id{ server.bob, server.carol, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        // the fork's files at its patch branch, linked to the fork
        {
            const files = try (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx);
            try std.testing.expectEqual(3, files.entries.len);
            try std.testing.expectEqualStrings("50%41 café", files.entries[0].name);
            try std.testing.expect(files.entries[0].is_dir);
            try std.testing.expectEqualStrings("README", files.entries[1].name);
            try std.testing.expectEqualStrings("fork.txt", files.entries[2].name);
            try std.testing.expectEqualStrings("bob:open", files.handle.location.fork.identity);
            try std.testing.expectEqualStrings(open_draft_hex, files.handle.location.fork.id);
            const sub = try (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex, .path = odd_dir }).run(&ctx);
            try std.testing.expectEqual(1, sub.entries.len);
            try std.testing.expectEqualStrings("x.txt", sub.entries[0].name);
        }
        {
            const file = try (domain.ReadFile{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "fork.txt" }).run(&ctx);
            try std.testing.expectEqualStrings("forked", file.lines[0]);
            const odd = try (domain.ReadFile{ .repo = "bob:open", .fork_id = open_draft_hex, .ref_kind = .object, .ref = head, .path = odd_dir ++ "/x.txt" }).run(&ctx);
            try std.testing.expectEqualStrings("x", odd.lines[0]);
        }
        // the log back to the revision's base, counted as the revision counts it
        {
            const log = try (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx);
            try std.testing.expectEqual(2, log.commits.len);
            try std.testing.expectEqualStrings("second on the fork", log.commits[0].message);
            try std.testing.expectEqualStrings("on the fork", log.commits[1].message);
            // the fixture's revision carries no count, where a push would count it
            try std.testing.expectEqual(null, log.commit_count);
            const commit = try (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = head }).run(&ctx);
            try std.testing.expectEqualStrings("second on the fork", commit.message);
            try std.testing.expectEqualStrings(head, commit.oid);
        }
        // the whole patch's diff, and one commit's against its parent
        {
            const whole = try (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx);
            try std.testing.expectEqual(2, countPaths(whole.window.hunks));
            try std.testing.expectEqualStrings(open_draft_hex, whole.route.fork.id);
            const one = try (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = head }).run(&ctx);
            try std.testing.expectEqual(1, countPaths(one.window.hunks));
            try std.testing.expectEqualStrings(odd_dir ++ "/x.txt", one.window.hunks[0].path.?);
            const on_path = try (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "fork.txt" }).run(&ctx);
            try std.testing.expectEqual(1, countPaths(on_path.window.hunks));
        }
    }
}

// how many files a diff's hunks touch: a file's first hunk names it
fn countPaths(hunks: []const hx.ui.Repo.Diff.Hunk) usize {
    var count: usize = 0;
    for (hunks) |hunk| {
        if (hunk.path != null) count += 1;
    }
    return count;
}

test "domain: accounts: a fork input reads the fork's files, log and diff as the fork page shows them" {
    try expectForkReads(.sha1);
    try expectForkReads(.sha256);
}

test "domain: accounts: a fork input finds nothing the fork page wouldn't show" {
    const server = try Server.init(.sha1);
    defer server.deinit();
    // a commit before the one the fork is based on
    try server.commitReadme(server.open);
    try addForkCommits(server);
    try server.commitReadme(server.secret);
    try server.addDraft(server.secret, server.bob, Server.bob_author, secret_draft);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const head = try fixture.forkHead(server, arena.allocator(), server.bob, open_draft);
    var carol = try server.ctx(&arena, server.carol);
    var bob = try server.ctx(&arena, server.bob);

    // a fork of a private repo is hidden from a stranger, as is a wrong name or id
    for ([_][2][]const u8{ .{ "bob:secret", secret_draft_hex }, .{ "bob:secret", open_draft_hex }, .{ "alice:open", open_draft_hex }, .{ "bob:open", "c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1c1" } }) |case| {
        errdefer std.debug.print("{s} + {s}\n", .{ case[0], case[1] });
        try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = case[0], .fork_id = case[1] }).run(&carol));
        try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = case[0], .fork_id = case[1], .path = "README" }).run(&carol));
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = case[0], .fork_id = case[1] }).run(&carol));
        try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = case[0], .fork_id = case[1], .oid = head }).run(&carol));
        try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = case[0], .fork_id = case[1] }).run(&carol));
    }
    _ = try (domain.ListFiles{ .repo = "bob:secret", .fork_id = secret_draft_hex }).run(&bob);

    // the fork page routes its patch branch or a commit, no branch, tag or revision
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex, .ref_kind = .branch, .ref = "master" }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex, .patchrev = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ReadFile{ .repo = "bob:open", .fork_id = open_draft_hex, .ref_kind = .tag, .ref = "v1", .path = "README" }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .ref_kind = .branch, .ref = "master" }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .patchrev = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee" }).run(&bob));
    // its log has its own base and no search
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .base = head }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .search = "fork" }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .merge = head }).run(&bob));
    try std.testing.expectError(error.InvalidReadArguments, (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .base = head }).run(&bob));
    // missing paths, commits and cursors
    const zeros = "0000000000000000000000000000000000000000";
    try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "missing" }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.ReadFile{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "missing.txt" }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = zeros }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .from = zeros }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = zeros }).run(&bob));
    try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "README" }).run(&bob));
    // the fork's log stops at its base commit exactly: the base itself reads
    // as missing, a commit after it reads, and so does one before it, whose
    // walk never meets the base. ancestry isn't checked.
    const base = (try server.readBranch(server.open, "master")) orelse return error.TestExpectedBranch;
    try std.testing.expectError(error.NotFound, (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = base }).run(&bob));
    try std.testing.expectEqualStrings("second on the fork", (try (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = head }).run(&bob)).message);
    const before = (try (domain.GetCommit{ .repo = "alice:open", .oid = base }).run(&bob)).parent_oid;
    const ancestor = try (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = before }).run(&bob);
    try std.testing.expectEqualStrings("initial", ancestor.message);
    const from_ancestor = try (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex, .from = before }).run(&bob);
    try std.testing.expectEqual(1, from_ancestor.commits.len);
    try std.testing.expectEqualStrings(before, from_ancestor.commits[0].oid);
}

test "domain: accounts: a fork input leaves a deleted target's fork to its forker" {
    const server = try Server.init(.sha256);
    defer server.deinit();
    try addForkCommits(server);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var alice = try server.ctx(&arena, server.alice);
    try (domain.DeleteRepo{ .repo = "alice:open", .confirm = "alice:open", .password = "password" }).run(&alice);

    var bob = try server.ctx(&arena, server.bob);
    const log = try (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&bob);
    try std.testing.expectEqual(2, log.commits.len);
    try std.testing.expectEqualStrings("second on the fork", log.commits[0].message);
    const files = try (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&bob);
    try std.testing.expectEqual(.read, files.handle.viewer.?.role);
    for ([_]?fixture.Id{ server.carol, server.alice, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx));
    }
}

test "domain: accounts: a fork input is server only, and an open repo is no fork's" {
    var local = try fixture.Local(.xit, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    try std.testing.expectError(error.UnavailableHere, (domain.ListFiles{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.ReadFile{ .repo = "bob:open", .fork_id = open_draft_hex, .path = "README" }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.ListCommits{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.GetCommit{ .repo = "bob:open", .fork_id = open_draft_hex, .oid = "" }).run(&ctx));
    try std.testing.expectError(error.UnavailableHere, (domain.Diff{ .repo = "bob:open", .fork_id = open_draft_hex }).run(&ctx));

    // a page that holds the repo open can't name a fork in it
    const resolved = (try domain.resolveRepo(&ctx, "")) orelse return error.TestExpectedRepo;
    const Body = struct {
        fn body(comptime repo_kind: hx.xit.repo.RepoKind, comptime repo_opts: hx.xit.repo.RepoOpts(repo_kind), c: *domain.Ctx, repo: *hx.xit.repo.Repo(repo_kind, repo_opts), r: domain.Resolved) !void {
            try std.testing.expectError(error.NotFound, (domain.ListFiles{ .repo = "", .fork_id = open_draft_hex }).runOpen(c, repo_kind, repo_opts, repo, r));
            try std.testing.expectError(error.NotFound, (domain.ListCommits{ .repo = "", .fork_id = open_draft_hex }).runOpen(c, repo_kind, repo_opts, repo, r));
            try std.testing.expectError(error.NotFound, (domain.Diff{ .repo = "", .oid = "x", .fork_id = open_draft_hex }).runOpen(c, repo_kind, repo_opts, repo, r));
        }
    };
    try domain.withRepo(&ctx, resolved, resolved, Body.body);
}
