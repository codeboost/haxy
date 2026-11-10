//! creating a repo and changing its settings through the web forms

const std = @import("std");
const h = @import("harness.zig");

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

fn newRepo(c: *h.Client, name: []const u8, hash: []const u8, access: []const u8, copy: []const u8) !*h.Response {
    return c.post("/home/repo/new", &.{
        .{ "name", name }, .{ "description", "made here" }, .{ "hash", hash }, .{ "access", access }, .{ "copy", copy },
    });
}

// the settings form as the page submits it
fn postSettings(c: *h.Client, repo: []const u8, fields: struct {
    name: []const u8,
    description: []const u8 = "",
    access: []const u8 = "public",
    discuss_role: []const u8 = "anybody",
    issue_role: []const u8 = "anybody",
    patch_role: []const u8 = "nobody",
}) !*h.Response {
    var buf: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&buf, "/{s}/repo/settings", .{repo});
    return c.post(path, &.{
        .{ "name", fields.name },
        .{ "description", fields.description },
        .{ "access", fields.access },
        .{ "discuss_role", fields.discuss_role },
        .{ "issue_role", fields.issue_role },
        .{ "patch_role", fields.patch_role },
    });
}

// ---- POST /repo/new

test "web: a new sha256 repo is created with that hash" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try newRepo(&alice, "wide", "sha256", "public", "");
    defer r.deinit();
    try r.expectRedirect("/alice:wide");
    const settings = try alice.getJson("/alice:wide/repo/settings");
    defer settings.deinit();
    try settings.expectStatus(.ok);
    try settings.expectJson("page.repo.settings.hash_kind", "sha256");
    try settings.expectJson("page.repo.settings.description", "made here");
}

test "web: a new sha1 repo is created with that hash" {
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try newRepo(&alice, "narrow", "sha1", "public", "");
    defer r.deinit();
    try r.expectRedirect("/alice:narrow");
    const settings = try alice.getJson("/alice:narrow/repo/settings");
    defer settings.deinit();
    try settings.expectJson("page.repo.settings.hash_kind", "sha1");
}

test "web: a new private repo is hidden from a stranger and a new public one is not" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const private = try newRepo(&alice, "hidden", "sha1", "private", "");
    defer private.deinit();
    try private.expectRedirect("/alice:hidden");
    const public = try newRepo(&alice, "shown", "sha1", "public", "");
    defer public.deinit();
    try public.expectRedirect("/alice:shown");

    const mine = try alice.getJson("/alice:hidden/repo/settings");
    defer mine.deinit();
    try mine.expectJson("page.repo.settings.access", "private");
    const hidden = try carol.get("/alice:hidden");
    defer hidden.deinit();
    try hidden.expectStatus(.not_found);
    const shown = try carol.get("/alice:shown");
    defer shown.deinit();
    try shown.expectStatus(.ok);
}

test "web: a copy of a readable repo starts with its files" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try h.commitOnBranch(server, server.open, "master", "README", "hello\n");
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try newRepo(&carol, "mine", "sha1", "public", "alice:open");
    defer r.deinit();
    try r.expectRedirect("/carol:mine");
    const files = try carol.getJson("/carol:mine");
    defer files.deinit();
    try files.expectStatus(.ok);
    try files.expectJson("page.repo.files.no_commits", false);
    try files.expectJson("page.repo.files.entries.0.name", "README");
}

test "web: copying a private repo the actor can't read fails as copying one that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "alice:secret", "alice:nothing" }) |copy| {
        const r = try newRepo(&carol, "mine", "sha1", "private", copy);
        defer r.deinit();
        try r.expectRedirect("/home/repo/new");
        const form = try carol.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.repo.failure", "invalid_copy");
        try form.expectJson("session.form_feedback.repo.fields.name", "mine");
        try form.expectJson("session.form_feedback.repo.fields.description", "made here");
        try form.expectJson("session.form_feedback.repo.fields.hash", "sha1");
        try form.expectJson("session.form_feedback.repo.fields.access", "private");
        try form.expectJson("session.form_feedback.repo.fields.copy", copy);
    }
    const none = try carol.get("/carol:mine");
    defer none.deinit();
    try none.expectStatus(.not_found);
}

test "web: a new repo without a name comes back as required, keeping the other fields" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try newRepo(&alice, "", "sha256", "private", "");
    defer r.deinit();
    try r.expectRedirect("/home/repo/new");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo.failure", "required_name");
    try form.expectJson("session.form_feedback.repo.fields.name", "");
    try form.expectJson("session.form_feedback.repo.fields.hash", "sha256");
    try form.expectJson("session.form_feedback.repo.fields.access", "private");
    try form.expectJson("session.form_feedback.repo.fields.copy", "");
}

test "web: a new repo with an invalid name comes back as invalid and is not created" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try newRepo(&alice, "two words", "sha1", "public", "");
    defer r.deinit();
    try r.expectRedirect("/home/repo/new");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo.failure", "invalid_name");
    try form.expectJson("session.form_feedback.repo.fields.name", "two words");
}

test "web: a failed new repo form posted from a repo's page goes back to that page" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/repo/new", &.{
        .{ "name", "secret" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" },
    });
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/new");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo.failure", "name_taken");
}

test "web: a new repo with an unknown or missing hash or access is a bad request" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const bad_hash = try newRepo(&alice, "fresh", "md5", "public", "");
    defer bad_hash.deinit();
    try expectRefused(bad_hash, .bad_request, "invalid hash");
    const no_hash = try alice.post("/home/repo/new", &.{ .{ "name", "fresh" }, .{ "access", "public" } });
    defer no_hash.deinit();
    try expectRefused(no_hash, .bad_request, "invalid hash");
    const no_access = try alice.post("/home/repo/new", &.{ .{ "name", "fresh" }, .{ "hash", "sha1" } });
    defer no_access.deinit();
    try expectRefused(no_access, .bad_request, "invalid access");
    const bad_access = try newRepo(&alice, "fresh", "sha1", "secret", "");
    defer bad_access.deinit();
    try expectRefused(bad_access, .bad_request, "invalid access");

    const none = try alice.get("/alice:fresh");
    defer none.deinit();
    try none.expectStatus(.not_found);
}

test "web: a logged-out visitor cannot create a repo, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // a body that would be a bad request is never read
    const r = try newRepo(&visitor, "", "md5", "public", "");
    defer r.deinit();
    try expectRefused(r, .forbidden, "log in to make changes");
}

// ---- POST <repo>/repo/settings

test "web: an owner renames a repo and changes its settings, landing on its settings under the new name" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, "alice:open", .{
        .name = "renamed",
        .description = "a new description",
        .access = "public",
        .discuss_role = "members",
        .issue_role = "nobody",
        .patch_role = "anybody",
    });
    defer r.deinit();
    try r.expectRedirect("/alice:renamed/repo/settings");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.settings.name", "renamed");
    try page.expectJson("page.repo.settings.description", "a new description");
    try page.expectJson("page.repo.settings.access", "public");
    try page.expectJson("page.repo.settings.discuss_role", "write");
    try page.expectJson("page.repo.settings.issue_role", null);
    try page.expectJson("page.repo.settings.patch_role", "read");

    const old = try alice.get("/alice:open");
    defer old.deinit();
    try old.expectStatus(.not_found);
}

test "web: making a repo private hides it from a stranger" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const r = try postSettings(&alice, "alice:open", .{ .name = "open", .access = "private" });
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/settings");
    const hidden = try carol.get("/alice:open");
    defer hidden.deinit();
    try hidden.expectStatus(.not_found);
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const seen = try bob.get("/alice:open");
    defer seen.deinit();
    try seen.expectStatus(.ok);
}

test "web: renaming a repo to a taken name comes back with every setting filled in, and nothing changes" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, "alice:open", .{
        .name = "secret",
        .description = "kept",
        .access = "private",
        .discuss_role = "nobody",
        .issue_role = "members",
        .patch_role = "anybody",
    });
    defer r.deinit();
    try r.expectRedirect("/alice:open/repo/settings");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo_settings.failure", "name_taken");
    try form.expectJson("session.form_feedback.repo_settings.fields.name", "secret");
    try form.expectJson("session.form_feedback.repo_settings.fields.description", "kept");
    try form.expectJson("session.form_feedback.repo_settings.fields.access", "private");
    try form.expectJson("session.form_feedback.repo_settings.fields.discuss_role", null);
    try form.expectJson("session.form_feedback.repo_settings.fields.issue_role", "write");
    try form.expectJson("session.form_feedback.repo_settings.fields.patch_role", "read");
    // the page under the feedback still shows the repo as it was
    try form.expectJson("page.repo.settings.name", "open");
    try form.expectJson("page.repo.settings.description", "");
    try form.expectJson("page.repo.settings.access", "public");
}

test "web: renaming a repo to nothing or to an invalid name comes back as such" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    for ([_]struct { []const u8, []const u8 }{ .{ "", "required_name" }, .{ "two words", "invalid_name" } }) |case| {
        const r = try postSettings(&alice, "alice:open", .{ .name = case[0] });
        defer r.deinit();
        try r.expectRedirect("/alice:open/repo/settings");
        const form = try alice.followJson(r);
        defer form.deinit();
        try form.expectJson("session.form_feedback.repo_settings.failure", case[1]);
        try form.expectJson("session.form_feedback.repo_settings.fields.name", case[0]);
    }
}

test "web: repo settings with an unknown access or tab role are a bad request" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const access = try postSettings(&alice, "alice:open", .{ .name = "changed", .access = "everyone" });
    defer access.deinit();
    try expectRefused(access, .bad_request, "invalid access");
    // the form's labels name roles, not the roles themselves
    const role = try postSettings(&alice, "alice:open", .{ .name = "changed", .issue_role = "write" });
    defer role.deinit();
    try expectRefused(role, .bad_request, "invalid role");
    const owner = try postSettings(&alice, "alice:open", .{ .name = "changed", .patch_role = "owner" });
    defer owner.deinit();
    try expectRefused(owner, .bad_request, "invalid role");

    const page = try alice.getJson("/alice:open/repo/settings");
    defer page.deinit();
    try page.expectJson("page.repo.settings.name", "open");
}

test "web: repo settings are refused to the logged out and a removed account's session, even for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        for ([_][]const u8{ "alice:open", "alice:secret", "alice:nothing" }) |repo| {
            const r = try postSettings(c, repo, .{ .name = "taken-over" });
            defer r.deinit();
            try expectRefused(r, .forbidden, "log in to make changes");
        }
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const page = try alice.getJson("/alice:open/repo/settings");
    defer page.deinit();
    try page.expectJson("page.repo.settings.name", "open");
}

test "web: repo settings are forbidden to a stranger and a member, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    for ([_]*h.Client{ &carol, &bob }) |c| {
        const r = try postSettings(c, "alice:open", .{ .name = "taken-over" });
        defer r.deinit();
        try expectRefused(r, .forbidden, "you don't have permission to do that");
        // a body that would be a bad request is never read
        const bad = try postSettings(c, "alice:open", .{ .name = "", .access = "everyone" });
        defer bad.deinit();
        try expectRefused(bad, .forbidden, "you don't have permission to do that");
    }
    const page = try bob.getJson("/alice:open");
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("page.repo.header.name", "open");
}

test "web: a stranger's settings for a private repo answer as for a repo that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "alice:secret", "alice:nothing" }) |repo| {
        const r = try postSettings(&carol, repo, .{ .name = "mine" });
        defer r.deinit();
        try expectRefused(r, .not_found, "repo not found");
    }
}

test "web: a settings form posted to a page that is not a repo's settings is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issues/settings", &.{ .{ "name", "x" }, .{ "access", "public" } });
    defer r.deinit();
    try expectRefused(r, .not_found, "repo not found");
}

// demotes bob through the members form while his settings form is in flight
const DemoteBob = struct {
    alice: *h.Client,
    status: ?std.http.Status = null,

    fn run(self: *DemoteBob) anyerror!void {
        const r = try self.alice.post("/alice:open/repo/members/user:bob/demote", &.{});
        defer r.deinit();
        self.status = r.status;
        try r.expectRedirect("/alice:open/repo/members");
    }
};

test "web: an owner demoted while the settings form is in flight is refused" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const promoted = try alice.post("/alice:open/repo/members/user:bob/promote", &.{});
    defer promoted.deinit();
    try promoted.expectRedirect("/alice:open/repo/members");

    var demote: DemoteBob = .{ .alice = &alice };
    const r = try bob.postWith("/alice:open/repo/settings", &.{
        .{ "name", "bobs" },        .{ "description", "" },       .{ "access", "public" },
        .{ "discuss_role", "anybody" }, .{ "issue_role", "anybody" }, .{ "patch_role", "nobody" },
    }, .{ .between = .init(&demote, DemoteBob.run) });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try std.testing.expectEqual(.see_other, demote.status.?);
    // differs from 66c1ab6: the handler authorized only before the body, so the
    // rename went through as a 303 to /alice:bobs/repo/settings. the operation
    // now authorizes again after it ("additional authorization after body can
    // reject newly revoked permissions", docs/reviews/05-phase4-codex.md).
    try expectRefused(r, .forbidden, "you don't have permission to do that");
    const page = try alice.getJson("/alice:open/repo/settings");
    defer page.deinit();
    try page.expectJson("page.repo.settings.name", "open");
}

test "web: the repo routes do not exist in local mode, and the server answers a sync as a method it lacks" {
    var local = try h.Local(.git).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    for ([_][]const u8{ "/repo/settings", "/repo/members/grant", "/repo/branches/protect", "/undo/0/undo" }) |path| {
        const r = try browser.post(path, &.{.{ "name", "x" }});
        defer r.deinit();
        try expectRefused(r, .method_not_allowed, "method not allowed");
    }

    // the new-repo and new-user forms end in "new", which local mode routes
    // to its thread and comment forms, and they name neither
    for ([_][]const u8{ "/repo/new", "/user/new" }) |path| {
        const r = try browser.post(path, &.{ .{ "name", "x" }, .{ "hash", "sha1" }, .{ "access", "public" } });
        defer r.deinit();
        try expectRefused(r, .not_found, "new event target not found");
    }

    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const sync = try alice.post("/alice:open/sync", &.{});
    defer sync.deinit();
    try expectRefused(sync, .method_not_allowed, "method not allowed");
}
