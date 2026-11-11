const std = @import("std");
const hx = @import("../lib.zig");
const domain = hx.domain;
const evt = hx.event;
const xit = hx.xit;
const fixture = @import("domain/fixture.zig");

comptime {
    _ = @import("domain/list_issues.zig");
    _ = @import("domain/get_issue.zig");
    _ = @import("domain/refresh_local.zig");
    _ = @import("domain/create_thread.zig");
    _ = @import("domain/create_comment.zig");
    _ = @import("domain/set_thread_status.zig");
    _ = @import("domain/thread_widget.zig");
    _ = @import("domain/get_discussion.zig");
    _ = @import("domain/edit_thread.zig");
    _ = @import("domain/edit_comment.zig");
    _ = @import("domain/remove.zig");
    _ = @import("domain/assign.zig");
    _ = @import("domain/notifications.zig");
    _ = @import("domain/list_notifications.zig");
    _ = @import("domain/notify_action.zig");
    _ = @import("domain/notify_page.zig");
    _ = @import("domain/patches.zig");
    _ = @import("domain/resolve_conflict.zig");
    _ = @import("domain/delete_fork.zig");
    _ = @import("domain/attach.zig");
    _ = @import("domain/repos.zig");
    _ = @import("domain/members.zig");
    _ = @import("domain/branches.zig");
    _ = @import("domain/undo.zig");
    _ = @import("domain/sync.zig");
    _ = @import("domain/delete_fresh.zig");
    _ = @import("domain/users.zig");
    _ = @import("domain/keys.zig");
    _ = @import("domain/delete_user.zig");
    _ = @import("domain/get_repo.zig");
    _ = @import("domain/list_files.zig");
    _ = @import("domain/read_file.zig");
    _ = @import("domain/list_refs.zig");
    _ = @import("domain/list_discussions.zig");
    _ = @import("domain/list_events.zig");
    _ = @import("domain/run_open.zig");
    _ = @import("domain/list_commits.zig");
    _ = @import("domain/get_commit.zig");
    _ = @import("domain/diff.zig");
    _ = @import("domain/accounts.zig");
    _ = @import("domain/page_ctx.zig");
    _ = @import("domain/resolve_ref.zig");
    _ = @import("domain/thread_reads.zig");
}

const io = std.testing.io;
const allocator = std.testing.allocator;

test "domain: a server ctx keeps an active user and drops a removed one" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const active = try server.ctx(&arena, server.bob);
    try std.testing.expectEqualSlices(u8, &server.bob, &(active.user_id orelse return error.TestExpectedUser));
    try std.testing.expect(active.moment != null);

    const removed = try server.ctx(&arena, server.dave);
    try std.testing.expectEqual(null, removed.user_id);

    const logged_out = try server.ctx(&arena, null);
    try std.testing.expectEqual(null, logged_out.user_id);
}

test "domain: a local ctx has no moment and no user" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const ctx = local.ctx(&arena);
    try std.testing.expectEqual(null, ctx.moment);
    try std.testing.expectEqual(null, ctx.user_id);
    try std.testing.expect(ctx.host == .local);
}

test "domain: resolveRepo hides private repos from non-members and reports tabs and events" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the creator sees their private repo, its path and every tab that is on
    {
        var ctx = try server.ctx(&arena, server.alice);
        const resolved = (try domain.resolveRepo(&ctx, "alice:secret")) orelse return error.TestExpectedRepo;
        try std.testing.expectEqual(.owner, resolved.role);
        try std.testing.expectEqualStrings("secret", resolved.record.event.name);
        try std.testing.expectEqualStrings(try server.repoPath(server.secret), resolved.source.path);
        try std.testing.expectEqual(.xit, resolved.source.repo_kind);
        try std.testing.expect(resolved.hasEvents());
        try std.testing.expect(resolved.hasTab(.issue));
        try std.testing.expect(resolved.hasTab(.discuss));
        try std.testing.expect(!resolved.hasTab(.patch));
    }
    // a member sees it with their grant
    {
        var ctx = try server.ctx(&arena, server.bob);
        const resolved = (try domain.resolveRepo(&ctx, "alice:secret")) orelse return error.TestExpectedRepo;
        try std.testing.expectEqual(.write, resolved.role);
        try std.testing.expect(resolved.hasEvents());
    }
    // a stranger, a removed member and a logged-out viewer don't see it at all
    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        try std.testing.expectEqual(null, try domain.resolveRepo(&ctx, "alice:secret"));
    }
    // the creator owns the public repo and a member writes to it, both with its history
    for ([_]fixture.Id{ server.alice, server.bob }, [_]evt.Repo.Role{ .owner, .write }) |user, role| {
        var ctx = try server.ctx(&arena, user);
        const resolved = (try domain.resolveRepo(&ctx, "alice:open")) orelse return error.TestExpectedRepo;
        try std.testing.expectEqual(role, resolved.role);
        try std.testing.expectEqualStrings(try server.repoPath(server.open), resolved.source.path);
        try std.testing.expect(resolved.hasEvents());
        try std.testing.expect(resolved.hasTab(.issue));
        try std.testing.expect(!resolved.hasTab(.patch));
    }
    // others read the public repo, without its event history
    for ([_]?fixture.Id{ server.carol, server.dave, null }) |user| {
        var ctx = try server.ctx(&arena, user);
        const resolved = (try domain.resolveRepo(&ctx, "alice:open")) orelse return error.TestExpectedRepo;
        try std.testing.expectEqual(.read, resolved.role);
        try std.testing.expectEqualStrings(try server.repoPath(server.open), resolved.source.path);
        try std.testing.expect(!resolved.hasEvents());
        try std.testing.expect(resolved.hasTab(.issue));
        try std.testing.expect(!resolved.hasTab(.patch));
    }
    // a missing repo, a missing owner and a malformed identity are not found
    {
        var ctx = try server.ctx(&arena, server.alice);
        for ([_][]const u8{ "alice:missing", "nobody:open", "alice", "alice:open:x", "" }) |identity| {
            try std.testing.expectEqual(null, try domain.resolveRepo(&ctx, identity));
        }
    }
}

test "domain: resolveRepo in local mode is the local repo, owned, with every tab" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const resolved = (try domain.resolveRepo(&ctx, "")) orelse return error.TestExpectedRepo;
    try std.testing.expectEqual(.owner, resolved.role);
    try std.testing.expectEqualStrings(local.path, resolved.source.path);
    try std.testing.expectEqual(.git, resolved.source.repo_kind);
    try std.testing.expect(resolved.hasEvents());
    try std.testing.expect(resolved.hasTab(.issue));
    try std.testing.expect(resolved.hasTab(.discuss));
    try std.testing.expect(resolved.hasTab(.patch));
}

test "domain: a local resolved repo owns its paths" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    // the caller's copies of the paths, which it may change or free once resolved
    const path = try allocator.dupe(u8, local.path);
    const global_config_path = try allocator.dupe(u8, "/nowhere/gitconfig");
    var ctx = domain.Ctx.initLocal(io, allocator, &arena, .{ .path = path, .repo_kind = .git, .global_config_path = global_config_path }, 0);
    const resolved = (try domain.resolveRepo(&ctx, "")) orelse return error.TestExpectedRepo;
    @memset(path, 'x');
    @memset(global_config_path, 'x');
    allocator.free(path);
    allocator.free(global_config_path);

    try std.testing.expectEqualStrings(local.path, resolved.source.path);
    try std.testing.expectEqualStrings("/nowhere/gitconfig", resolved.source.global_config_path.?);
}

fn expectActor(authorization: domain.Authorization, role: evt.Repo.Role, user: fixture.Id, author: evt.CommitAuthor, repo_user: fixture.Id) !void {
    const actor = switch (authorization) {
        .actor => |actor| actor,
        else => |other| {
            std.debug.print("expected an actor, got {t}\n", .{other});
            return error.TestExpectedActor;
        },
    };
    try std.testing.expectEqual(role, actor.role);
    try std.testing.expectEqualSlices(u8, &user, &(actor.user_id orelse return error.TestExpectedUser));
    try std.testing.expectEqualStrings(author.name, actor.author.name);
    try std.testing.expectEqualStrings(author.email, actor.author.email);
    try std.testing.expectEqualSlices(u8, &repo_user, &(actor.repo_user_id orelse return error.TestExpectedUser));
}

test "domain: authorize on a public repo" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Server = fixture.Server;

    var alice = try server.ctx(&arena, server.alice);
    var bob = try server.ctx(&arena, server.bob);
    var carol = try server.ctx(&arena, server.carol);
    var dave = try server.ctx(&arena, server.dave);
    var nobody = try server.ctx(&arena, null);

    try expectActor(try alice.authorize("alice:open", .owner, null), .owner, server.alice, Server.alice_author, server.alice);
    try expectActor(try bob.authorize("alice:open", .write, null), .write, server.bob, Server.bob_author, server.alice);
    try std.testing.expectEqual(.forbidden, try bob.authorize("alice:open", .owner, null));
    try expectActor(try carol.authorize("alice:open", .read, .issue), .read, server.carol, Server.carol_author, server.alice);
    try std.testing.expectEqual(.forbidden, try carol.authorize("alice:open", .write, null));
    try std.testing.expectEqual(.login_required, try dave.authorize("alice:open", .read, null));
    try std.testing.expectEqual(.login_required, try nobody.authorize("alice:open", .read, null));
    try std.testing.expectEqual(.repo_not_found, try alice.authorize("alice:missing", .read, null));
    try std.testing.expectEqual(.repo_not_found, try alice.authorize("alice", .read, null));
    // the patch tab is off, so it doesn't exist even to the owner
    try std.testing.expectEqual(.repo_not_found, try alice.authorize("alice:open", .read, .patch));
}

test "domain: authorize on a private repo" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const Server = fixture.Server;

    var alice = try server.ctx(&arena, server.alice);
    var bob = try server.ctx(&arena, server.bob);
    var carol = try server.ctx(&arena, server.carol);
    var dave = try server.ctx(&arena, server.dave);
    var nobody = try server.ctx(&arena, null);

    try expectActor(try alice.authorize("alice:secret", .owner, .issue), .owner, server.alice, Server.alice_author, server.alice);
    try expectActor(try bob.authorize("alice:secret", .write, .discuss), .write, server.bob, Server.bob_author, server.alice);
    try std.testing.expectEqual(.repo_not_found, try carol.authorize("alice:secret", .read, null));
    try std.testing.expectEqual(.login_required, try dave.authorize("alice:secret", .read, null));
    try std.testing.expectEqual(.login_required, try nobody.authorize("alice:secret", .read, null));
}

test "domain: authorize refuses a tab whose role the user lacks" {
    const server = try fixture.Server.init(.sha1);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // only writers may open issues on the public repo
    try evt.updateRepo(io, allocator, server.users_dir, &server.alice, fixture.Server.alice_author, "open", "open", "", .public, .read, .write, null);

    var carol = try server.ctx(&arena, server.carol);
    try std.testing.expectEqual(.forbidden, try carol.authorize("alice:open", .read, .issue));
    try expectActor(try carol.authorize("alice:open", .read, .discuss), .read, server.carol, fixture.Server.carol_author, server.alice);
}

test "domain: canModify lets authors and writers change an event" {
    try expectCanModify(.sha1);
    try expectCanModify(.sha256);
}

fn expectCanModify(comptime hash_kind: xit.hash.HashKind) !void {
    const server = try fixture.Server.init(hash_kind);
    defer server.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const carols_issue: fixture.Id = @splat(0xc1);
    const alices_issue: fixture.Id = @splat(0xa1);
    const missing: fixture.Id = @splat(0xff);
    try server.addIssue(server.open, fixture.Server.carol_author, carols_issue);
    try server.addIssue(server.open, fixture.Server.alice_author, alices_issue);

    var carol = try server.ctx(&arena, server.carol);
    const carol_actor = (try carol.authorize("alice:open", .read, .issue)).actor;
    const for_carol = (try domain.resolveRepo(&carol, "alice:open")).?;
    try std.testing.expect(try domain.canModify(&carol, for_carol, carol_actor, .issue, &carols_issue));
    try std.testing.expect(!try domain.canModify(&carol, for_carol, carol_actor, .issue, &alices_issue));
    try std.testing.expect(!try domain.canModify(&carol, for_carol, carol_actor, .issue, &missing));

    var bob = try server.ctx(&arena, server.bob);
    const bob_actor = (try bob.authorize("alice:open", .read, .issue)).actor;
    const for_bob = (try domain.resolveRepo(&bob, "alice:open")).?;
    try std.testing.expect(try domain.canModify(&bob, for_bob, bob_actor, .issue, &carols_issue));
    try std.testing.expect(try domain.canModify(&bob, for_bob, bob_actor, .issue, &alices_issue));
}

test "domain: classify sorts every expected failure and leaves the rest internal" {
    const Kind = domain.Failure.Kind;
    const cases = [_]struct { anyerror, Kind }{
        // thread and comment forms
        .{ error.InvalidTitle, .invalid_input },
        .{ error.InvalidLabels, .invalid_input },
        .{ error.InvalidBody, .invalid_input },
        // patch form
        .{ error.InvalidTargetBranch, .invalid_input },
        .{ error.InvalidSourceBranch, .invalid_input },
        .{ error.SameBranch, .invalid_input },
        .{ error.UnrelatedBranches, .invalid_input },
        // repo and user forms
        .{ error.NameEmpty, .invalid_input },
        .{ error.NameTooShort, .invalid_input },
        .{ error.NameTooLong, .invalid_input },
        .{ error.InvalidName, .invalid_input },
        .{ error.NameTaken, .conflict },
        .{ error.InvalidCopySource, .invalid_input },
        .{ error.EmailEmpty, .invalid_input },
        .{ error.EmailTaken, .conflict },
        .{ error.PasswordEmpty, .invalid_input },
        .{ error.PasswordMismatch, .invalid_input },
        .{ error.WrongPassword, .forbidden },
        // branches form
        .{ error.BranchProtected, .conflict },
        .{ error.TooManyProtectedBranches, .limit_reached },
        // keys form
        .{ error.InvalidKey, .invalid_input },
        .{ error.UnsupportedKey, .invalid_input },
        .{ error.KeyAdded, .conflict },
        .{ error.TooManyKeys, .limit_reached },
        // assignments
        .{ error.UnknownAssignee, .invalid_input },
        .{ error.NotAnEmail, .invalid_input },
        .{ error.AlreadyAssigned, .conflict },
        // merges and publishing
        .{ error.MergeConflict, .conflict },
        .{ error.PatchOutOfDate, .conflict },
        .{ error.PatchClosed, .conflict },
        .{ error.PatchAlreadyMerged, .conflict },
        .{ error.PatchNotPushed, .conflict },
        // a notification bumped since the caller saw it
        .{ error.NotificationOutOfDate, .conflict },
        .{ error.MergeCheckUnavailable, .internal },
        .{ error.PatchDataUnavailable, .internal },
        // deletes and attachments
        .{ error.WrongConfirm, .invalid_input },
        .{ error.InvalidAttachmentName, .invalid_input },
        .{ error.AttachmentEmpty, .invalid_input },
        .{ error.AttachmentTooLarge, .limit_reached },
        // authorization and capability
        .{ error.NotFound, .not_found },
        .{ error.LoginRequired, .login_required },
        .{ error.Forbidden, .forbidden },
        .{ error.UnavailableHere, .unavailable_here },
    };
    for (cases) |case| {
        const failure = domain.classify(case[0]);
        errdefer std.debug.print("classify(error.{t})\n", .{case[0]});
        try std.testing.expectEqual(case[1], failure.kind);
        try std.testing.expect(!failure.retryable);
        try std.testing.expect(!failure.changed);
    }

    // a write that committed before what follows it failed
    for ([_]anyerror{ error.CommittedUnconsumed, error.MergedForkKept, error.PublishedForkKept, error.ForkRemovedDirKept, error.MutedNotDismissed }) |err| {
        const failure = domain.classify(err);
        errdefer std.debug.print("classify(error.{t})\n", .{err});
        try std.testing.expectEqual(.internal, failure.kind);
        try std.testing.expect(!failure.retryable);
        try std.testing.expect(failure.changed);
    }

    // anything else is the host failing. nothing is retried automatically.
    for ([_]anyerror{ error.OutOfMemory, error.AccessDenied, error.Unexpected }) |err| {
        const failure = domain.classify(err);
        try std.testing.expectEqual(.internal, failure.kind);
        try std.testing.expect(!failure.retryable);
        try std.testing.expect(!failure.changed);
    }
}

test "domain: form feedback still reads the domain errors" {
    const FormFeedback = hx.ui.Session.FormFeedback;
    try std.testing.expectEqual(.same_branch, FormFeedback.PatchFailure.fromError(error.SameBranch).?);
    try std.testing.expectEqual(.invalid_target_branch, FormFeedback.PatchFailure.fromError(error.InvalidTargetBranch).?);
    try std.testing.expectEqual(.invalid_copy, FormFeedback.RepoFailure.fromError(error.InvalidCopySource).?);
    try std.testing.expectEqual(.name_taken, FormFeedback.RepoFailure.fromError(error.NameTaken).?);
    try std.testing.expectEqual(.too_many, FormFeedback.BranchesFailure.fromError(error.TooManyProtectedBranches).?);
    try std.testing.expectEqual(.already_added, FormFeedback.KeyFailure.fromError(error.KeyAdded).?);
    try std.testing.expectEqual(.invalid_name, FormFeedback.UserFailure.fromError(error.NameTooShort).?);
    try std.testing.expectEqual(.wrong_password, FormFeedback.UserFailure.fromError(error.WrongPassword).?);
    try std.testing.expectEqual(null, FormFeedback.UserFailure.fromError(error.OutOfMemory));
    try std.testing.expectEqual(.required_title, FormFeedback.ThreadFailure.fromError(error.InvalidTitle).?);
    try std.testing.expectEqual(.required_title, FormFeedback.PatchFailure.fromError(error.InvalidTitle).?);
    try std.testing.expectEqual(.not_found, FormFeedback.AssignmentFailure.fromError(error.UnknownAssignee).?);
    try std.testing.expectEqual(.not_an_email, FormFeedback.AssignmentFailure.fromError(error.NotAnEmail).?);
    try std.testing.expectEqual(.already_assigned, FormFeedback.AssignmentFailure.fromError(error.AlreadyAssigned).?);
    // a missing thread is no assignment failure
    try std.testing.expectEqual(null, FormFeedback.AssignmentFailure.fromError(error.NotFound));
    // an overlong label has no form feedback
    try std.testing.expectEqual(null, FormFeedback.ThreadFailure.fromError(error.InvalidLabels));
}

const ReadBranchArgs = struct { branch: []const u8 };

// the oid a branch points at, read through the repo withRepo opened
fn readBranch(
    comptime repo_kind: xit.repo.RepoKind,
    comptime repo_opts: xit.repo.RepoOpts(repo_kind),
    ctx: *domain.Ctx,
    repo: *xit.repo.Repo(repo_kind, repo_opts),
    args: ReadBranchArgs,
) ![]const u8 {
    const oid = (try repo.readRef(ctx.io, .{ .kind = .head, .name = args.branch })) orelse return error.NotFound;
    return try ctx.arena.allocator().dupe(u8, &oid);
}

fn expectWithRepoReadsMaster(comptime kind: xit.repo.RepoKind, comptime hash_kind: xit.hash.HashKind) !void {
    var local = try fixture.Local(kind, hash_kind).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var ctx = local.ctx(&arena);
    const resolved = (try domain.resolveRepo(&ctx, "")) orelse return error.TestExpectedRepo;
    const oid = try domain.withRepo(&ctx, resolved, ReadBranchArgs{ .branch = "master" }, readBranch);
    try std.testing.expectEqualStrings(&local.master_oid, oid);
    try std.testing.expectError(error.NotFound, domain.withRepo(&ctx, resolved, ReadBranchArgs{ .branch = "missing" }, readBranch));
}

test "domain: withRepo opens a local git or xit repo for its body" {
    try expectWithRepoReadsMaster(.git, .sha1);
    try expectWithRepoReadsMaster(.git, .sha256);
    try expectWithRepoReadsMaster(.xit, .sha1);
    try expectWithRepoReadsMaster(.xit, .sha256);
}

fn expectLocalOwner(comptime kind: xit.repo.RepoKind) !void {
    var local = try fixture.Local(kind, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);

    // with no config, writes fall back to haxy's own author
    {
        const actor = (try ctx.authorize("", .owner, .patch)).actor;
        try std.testing.expectEqual(.owner, actor.role);
        try std.testing.expectEqualStrings("haxy", actor.author.name);
        try std.testing.expectEqualStrings("user@haxy", actor.author.email);
        try std.testing.expectEqual(null, actor.user_id);
        try std.testing.expectEqual(null, actor.repo_user_id);
    }
    // the repo's config names the author
    try local.setAuthor(.{ .name = "Ada Lovelace", .email = "ada@example.test" });
    {
        const actor = (try ctx.authorize("", .owner, null)).actor;
        try std.testing.expectEqual(.owner, actor.role);
        try std.testing.expectEqualStrings("Ada Lovelace", actor.author.name);
        try std.testing.expectEqualStrings("ada@example.test", actor.author.email);
    }
}

test "domain: local mode acts as the owner, authored from the repo config" {
    try expectLocalOwner(.git);
    try expectLocalOwner(.xit);
}
