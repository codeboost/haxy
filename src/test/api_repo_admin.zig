const std = @import("std");
const api = @import("../api.zig");
const admin = @import("../api/repo_admin.zig");
const evt = @import("../event.zig");

fn expectRoute(path: []const u8, method: std.http.Method, expected: std.meta.Tag(admin.Resource)) !admin.Route {
    const matched = admin.route(path, method) orelse return error.TestExpectedRoute;
    try std.testing.expectEqual(expected, std.meta.activeTag(matched.resource));
    return matched;
}

test "settings routes live under a repo's settings path, on a server and in local mode" {
    const server = try expectRoute("/api/v1/repos/alice/tools/settings", .GET, .settings);
    try std.testing.expectEqualStrings("alice", server.target.server.owner);
    try std.testing.expectEqualStrings("tools", server.target.server.name);
    _ = try expectRoute("/api/v1/repos/alice/tools/settings/members", .GET, .members);
    const member = try expectRoute("/api/v1/repos/alice/tools/settings/members/bob", .DELETE, .member);
    try std.testing.expectEqualStrings("bob", member.resource.member);
    _ = try expectRoute("/api/v1/repos/alice/tools/settings/branches", .GET, .branches);
    _ = try expectRoute("/api/v1/repos/alice/tools/settings/branches/default", .PUT, .default_branch);
    _ = try expectRoute("/api/v1/repos/alice/tools/settings/branches/protected", .POST, .protected);
    const local = try expectRoute("/api/v1/repo/settings", .GET, .settings);
    try std.testing.expect(local.target == .local);
    _ = try expectRoute("/api/v1/repo/settings/members", .GET, .members);
}

test "deleting a repo is a DELETE of the repo itself; its other methods stay the overview's" {
    _ = try expectRoute("/api/v1/repos/alice/tools", .DELETE, .repo);
    _ = try expectRoute("/api/v1/repo", .DELETE, .repo);
    for ([_]std.http.Method{ .GET, .HEAD, .PUT, .POST }) |method| {
        try std.testing.expect(admin.route("/api/v1/repos/alice/tools", method) == null);
    }
}

test "other paths aren't settings routes" {
    for ([_][]const u8{
        "/api/v1/repos/alice/tools/files",
        "/api/v1/repos/alice/tools/branches",
        "/api/v1/repos/alice/tools/settings/",
        "/api/v1/repos/alice/tools/settings/members/",
        "/api/v1/repos/alice/tools/settings/members/bob/role",
        "/api/v1/repos/alice/tools/settings/branches/other",
        "/api/v1/repos/alice/tools/settingsx",
        "/api/v1/repos/alice//settings",
        "/api/v1/repos/alice",
        "/api/v1/repo/files",
    }) |path| {
        try std.testing.expect(admin.route(path, .GET) == null);
        try std.testing.expect(admin.route(path, .DELETE) == null);
    }
}

fn settings(overrides: anytype) admin.SettingsRequest {
    var value: admin.SettingsRequest = .{ .revision = "00112233445566778899aabbccddeeff", .description = "tools", .access = "public", .discuss_role = "anybody", .issue_role = "members", .patch_role = "nobody" };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| @field(value, name) = @field(overrides, name);
    return value;
}

fn expectRefused(err: api.Error, code: api.ErrorCode, field: []const u8) !void {
    try std.testing.expectEqual(code, err.code);
    try std.testing.expectEqual(1, err.field_errors.len);
    try std.testing.expectEqualStrings(field, err.field_errors[0].field);
    try std.testing.expect(err.field_errors[0].message.len > 0);
}

test "settings name visibility and each thread kind's creation role by the TUI's choices" {
    const fields = switch (admin.readSettings(settings(.{}))) {
        .ok => |fields| fields,
        .invalid => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualStrings("tools", fields.description);
    try std.testing.expectEqual(.public, fields.access);
    try std.testing.expectEqual(.read, fields.discuss_role);
    try std.testing.expectEqual(.write, fields.issue_role);
    try std.testing.expectEqual(null, fields.patch_role);
    try std.testing.expectEqualSlices(u8, &.{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff }, &fields.revision);
}

test "a settings change names the revision of the settings it was made from" {
    for ([_][]const u8{ "", "0011", "00112233445566778899aabbccddeefg", "00112233445566778899aabbccddeeff00" }) |revision| {
        try expectRefused(admin.readSettings(settings(.{ .revision = revision })).invalid, .validation, "revision");
    }
}

test "an unknown visibility or role is refused beside its field" {
    try expectRefused(admin.readSettings(settings(.{ .access = "secret" })).invalid, .validation, "access");
    try expectRefused(admin.readSettings(settings(.{ .access = "" })).invalid, .validation, "access");
    try expectRefused(admin.readSettings(settings(.{ .discuss_role = "owners" })).invalid, .validation, "discuss_role");
    try expectRefused(admin.readSettings(settings(.{ .issue_role = "" })).invalid, .validation, "issue_role");
    try expectRefused(admin.readSettings(settings(.{ .patch_role = "Members" })).invalid, .validation, "patch_role");
}

test "a member's role travels as owner or member" {
    try std.testing.expectEqual(.owner, admin.parseMemberRole("owner").?);
    try std.testing.expectEqual(.write, admin.parseMemberRole("member").?);
    try std.testing.expectEqual(null, admin.parseMemberRole("reader"));
    try std.testing.expectEqual(null, admin.parseMemberRole(""));
    try std.testing.expectEqualStrings("owner", admin.memberRoleName(.owner));
    try std.testing.expectEqualStrings("member", admin.memberRoleName(.write));
}

test "a branch is named by its ref id, decoded exactly once" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try std.testing.expectEqualStrings("main", (try admin.parseBranchId(aa, "branch:main")).branch);
    try std.testing.expectEqualSlices(u8, "feature/caf\xe9 x", (try admin.parseBranchId(aa, "branch:feature/caf%E9%20x")).branch);
    try std.testing.expectEqualStrings("a%2Fb", (try admin.parseBranchId(aa, "branch:a%252Fb")).branch);
    for ([_][]const u8{ "", "main", "tag:v1", "commit:abc", "branch:", "branch:bad%2", "branch:bad%zz" }) |id| {
        try expectRefused((try admin.parseBranchId(aa, id)).invalid, .validation, "ref");
    }
}

test "each refusal of the shared members rules names the name field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try expectRefused(try admin.membersError(arena.allocator(), .not_found, "nobody"), .not_found, "name");
    try expectRefused(try admin.membersError(arena.allocator(), .already_added, "bob"), .conflict, "name");
}

test "each refusal of the shared branches rules names the ref field" {
    try expectRefused(admin.branchesError(.not_found), .not_found, "ref");
    try expectRefused(admin.branchesError(.already_added), .conflict, "ref");
    try expectRefused(admin.branchesError(.too_many), .validation, "ref");
    try expectRefused(admin.branchesError(.too_long), .validation, "ref");
}

test "an admin request reads and changes the repository it authorized, never one that took its name meanwhile" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const xit = @import("xit");
    const ui = @import("../ui.zig");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const base = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const admin_path = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "admin" });
    const users_dir = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "users" });
    var admin_repo = try xit.repo.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin_repo.deinit(io, allocator);
    const alice_id = try evt.createUser(io, allocator, users_dir, &admin_repo, "alice", "alice@example.test", "pw", "pw");
    const bob_id = try evt.createUser(io, allocator, users_dir, &admin_repo, "bobby", "bob@example.test", "pw", "pw");
    _ = try evt.createUser(io, allocator, users_dir, &admin_repo, "carol", "carol@example.test", "pw", "pw");
    const alice = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };
    const original = try evt.createRepo(io, allocator, users_dir, &alice_id, alice, "tools", "the original", .private, .sha1, null);
    try evt.changeRole(io, allocator, users_dir, &alice_id, &original.repo_id, &alice_id, &bob_id, null, .owner, alice, null);

    // bob, a granted owner of the original, is authorized for alice:tools...
    const target = switch (try admin.resolveTarget(io, allocator, &arena, try evt.currentMoment(evt.admin_repo_opts, &admin_repo), users_dir, "alice", "tools", bob_id)) {
        .ok => |target| target,
        .refused => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, &original.repo_id, &target.repo_id);
    // ...then alice renames it, and a new private repo she alone owns takes its name
    try evt.updateRepo(io, allocator, users_dir, &alice_id, &alice_id, alice, "tools", "old-tools", "the original", .private, .read, .read, null, null);
    const replacement = try evt.createRepo(io, allocator, users_dir, &alice_id, alice, "tools", "the replacement", .private, .sha1, null);

    // the request finds no repository by that name rather than the replacement
    try std.testing.expectEqual(null, try evt.readNamedRepo(io, allocator, &arena, users_dir, &alice_id, &target.repo_id, "tools"));
    const moment = try evt.currentMoment(evt.admin_repo_opts, &admin_repo);
    try std.testing.expectError(error.NotFound, ui.Repo.Members.perform(io, allocator, moment, users_dir, target.actor, "alice:tools", &target.repo_id, .grant, "carol"));
    try std.testing.expectError(error.NotFound, ui.Repo.Branches.perform(io, allocator, users_dir, target.actor, "alice:tools", &target.repo_id, .unprotect, "main"));
    try std.testing.expectError(error.NotFound, ui.Repo.Settings.update(io, allocator, users_dir, target.actor, "alice:tools", "tools", "by bob", .public, .read, .read, null, null, &target.repo_id));

    // the replacement is untouched, and bob can't even see it
    const now = (try evt.readNamedRepo(io, allocator, &arena, users_dir, &alice_id, &replacement.repo_id, "tools")).?;
    try std.testing.expectEqualStrings("the replacement", now.repo.event.description);
    try std.testing.expectEqual(.private, now.repo.event.read_access);
    try std.testing.expectEqual(0, (try evt.readRepoGrants(io, allocator, &arena, users_dir, &alice_id, &replacement.repo_id)).len);
    switch (try admin.resolveTarget(io, allocator, &arena, moment, users_dir, "alice", "tools", bob_id)) {
        .ok => return error.TestUnexpectedResult,
        .refused => |err| try std.testing.expectEqual(.not_found, err.code),
    }
}

test "a deletion deletes the repository it authorized, never one that took its name meanwhile" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const xit = @import("xit");
    const ui = @import("../ui.zig");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const base = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const admin_path = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "admin" });
    const users_dir = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "users" });
    var admin_repo = try xit.repo.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin_repo.deinit(io, allocator);
    const alice_id = try evt.createUser(io, allocator, users_dir, &admin_repo, "alice", "alice@example.test", "pw", "pw");
    const alice = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };
    const target: ui.Delete.Target = .{ .repo = "alice:tools" };

    for ([_]enum { renamed, deleted }{ .renamed, .deleted }) |interleaving| {
        const original = try evt.createRepo(io, allocator, users_dir, &alice_id, alice, "tools", "the original", .private, .sha1, null);
        // alice is authorized to delete alice:tools...
        const authorized = switch (try admin.resolveTarget(io, allocator, &arena, try evt.currentMoment(evt.admin_repo_opts, &admin_repo), users_dir, "alice", "tools", alice_id)) {
            .ok => |value| value,
            .refused => return error.TestUnexpectedResult,
        };
        // ...then, from another client, the repo is renamed (or deleted) and a new one takes its name
        switch (interleaving) {
            .renamed => try evt.updateRepo(io, allocator, users_dir, &alice_id, &alice_id, alice, "tools", "old-tools", "the original", .private, .read, .read, null, null),
            .deleted => try evt.deleteRepo(io, allocator, users_dir, &alice_id, &original.repo_id, alice, null),
        }
        const replacement = try evt.createRepo(io, allocator, users_dir, &alice_id, alice, "tools", "the replacement", .private, .sha1, null);

        try std.testing.expectError(error.NotFound, ui.Delete.perform(io, allocator, users_dir, &admin_repo, alice_id, target, "alice:tools", "pw", &authorized.repo_id));
        const kept = (try evt.readNamedRepo(io, allocator, &arena, users_dir, &alice_id, &replacement.repo_id, "tools")).?;
        try std.testing.expectEqualStrings("the replacement", kept.repo.event.description);
        const path = try evt.repoPath(arena.allocator(), users_dir, &alice_id, &replacement.repo_id);
        var dir = try std.Io.Dir.cwd().openDir(io, path, .{});
        dir.close(io);

        // deleted by its own authorization, it goes
        const again = switch (try admin.resolveTarget(io, allocator, &arena, try evt.currentMoment(evt.admin_repo_opts, &admin_repo), users_dir, "alice", "tools", alice_id)) {
            .ok => |value| value,
            .refused => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(null, try ui.Delete.perform(io, allocator, users_dir, &admin_repo, alice_id, target, "alice:tools", "pw", &again.repo_id));
        try std.testing.expectEqual(null, try evt.readNamedRepo(io, allocator, &arena, users_dir, &alice_id, &replacement.repo_id, "tools"));
        if (interleaving == .renamed) try evt.updateRepo(io, allocator, users_dir, &alice_id, &alice_id, alice, "old-tools", "gone", "", .private, .read, .read, null, null);
    }
}

test "a repo's removal lands only while it still has the name it was deleted by" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const base = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const users_dir = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "users" });
    var prng = std.Random.DefaultPrng.init(std.testing.random_seed);
    const owner_id = evt.EventWithId.randomId(prng.random());
    {
        var user_repo = try evt.initUserRepo(io, allocator, try evt.userRepoPath(arena.allocator(), users_dir, &owner_id));
        user_repo.deinit(io, allocator);
    }
    const alice = evt.CommitAuthor{ .name = "alice", .email = "alice@example.test" };
    const created = try evt.createRepo(io, allocator, users_dir, &owner_id, alice, "tools", "", .private, .sha1, null);
    try evt.updateRepo(io, allocator, users_dir, &owner_id, &owner_id, alice, "tools", "renamed", "", .private, .read, .read, null, null);
    try std.testing.expectError(error.NotFound, evt.deleteRepo(io, allocator, users_dir, &owner_id, &created.repo_id, alice, "tools"));
    try std.testing.expect(try evt.readNamedRepo(io, allocator, &arena, users_dir, &owner_id, &created.repo_id, "renamed") != null);
    try evt.deleteRepo(io, allocator, users_dir, &owner_id, &created.repo_id, alice, "renamed");
    try std.testing.expectEqual(null, try evt.readNamedRepo(io, allocator, &arena, users_dir, &owner_id, &created.repo_id, "renamed"));
    try std.testing.expectError(error.NotFound, evt.deleteRepo(io, allocator, users_dir, &owner_id, &created.repo_id, alice, null));
}
