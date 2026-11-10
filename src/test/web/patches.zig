//! creating patches, from a branch and as fork-backed drafts; publishing and
//! removing drafts; resolving a thread's fields

const std = @import("std");
const xit = @import("xit");
const evt = @import("../../event.zig");
const h = @import("harness.zig");
const rp = xit.repo;

const io = std.testing.io;
const gpa = std.testing.allocator;

// the tab roles the settings form posts, with the patch tab's as given:
// "anybody", "members" or "nobody"
pub fn setPatchTab(alice: *h.Client, name: []const u8, access: []const u8, patch_role: []const u8) !void {
    const r = try alice.post(try url(alice, "/alice:{s}/repo/settings", .{name}), &.{
        .{ "name", name },              .{ "description", "" },       .{ "access", access },
        .{ "discuss_role", "anybody" }, .{ "issue_role", "anybody" }, .{ "patch_role", patch_role },
    });
    defer r.deinit();
    try r.expectStatus(.see_other);
}

// master with one commit and feature one commit past it
pub fn arrangeBranches(server: *const h.Server, repo: evt.RepoLocation) !void {
    try h.commitOnBranch(server, repo, "master", "README", "repo\n");
    try h.commitOnBranch(server, repo, "feature", "README", "feature work\n");
}

// a server whose open repo has branches and a patch tab anybody may use
pub fn arrangePatches(comptime hash_kind: xit.hash.HashKind) !*h.Server {
    const server = try h.Server.init(hash_kind);
    errdefer server.deinit();
    try arrangeBranches(server, server.open);
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setPatchTab(&alice, "open", "public", "anybody");
    return server;
}

// a path formatted in the client's arena, which outlives the test's requests
pub fn url(c: *h.Client, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(c.arena.allocator(), fmt, args);
}

// the location a successful post redirected to, kept in the client's arena
pub fn location(c: *h.Client, r: *const h.Response) ![]const u8 {
    try r.expectStatus(.see_other);
    return c.arena.allocator().dupe(u8, r.header("location") orelse return error.TestExpectedLocation);
}

// a patch of `source` onto master in alice:open, as the form creates one;
// its page's url
pub fn newBranchPatch(c: *h.Client, source: []const u8) ![]const u8 {
    const r = try c.post("/alice:open/patches/new", &.{
        .{ "title", "a fix" },          .{ "labels", "bug" },         .{ "description", "it fixes" },
        .{ "target_branch", "master" }, .{ "source_branch", source },
    });
    defer r.deinit();
    const page = try location(c, r);
    try std.testing.expect(std.mem.startsWith(u8, page, "/alice:open/patch:"));
    return page;
}

// a fork-backed draft onto master in alice:open; its page's url
pub fn newDraft(c: *h.Client) ![]const u8 {
    const r = try c.post("/alice:open/patches/new", &.{
        .{ "title", "a draft" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" },
    });
    defer r.deinit();
    const page = try location(c, r);
    try std.testing.expect(std.mem.startsWith(u8, page, "/alice:open/patch:"));
    return page;
}

pub fn expectCount(c: *h.Client, page: []const u8, path: []const u8, expected: i64) !void {
    const r = try c.getJson(page);
    defer r.deinit();
    try r.expectJson(path, expected);
}

// a root commit with an empty tree on `branch`, sharing no history with master
fn commitOrphan(server: *const h.Server, location_: evt.RepoLocation, branch: []const u8) !void {
    const path = try evt.repoPath(gpa, server.users_dir, &location_.owner_id, &location_.repo_id);
    defer gpa.free(path);
    var any_repo = try rp.AnyRepo(.xit, .{}).open(io, gpa, .{ .path = path });
    defer any_repo.deinit(io, gpa);
    switch (any_repo) {
        inline else => |*repo| _ = try repo.commitAtRef(io, gpa, .{
            .message = "orphan",
            .author = "tester <tester@example.test>",
            .parent_oids = &.{},
            .allow_empty = true,
        }, null, .{ .kind = .head, .name = branch }),
    }
}

// a branch one commit past master in a local repo
pub fn localBranch(comptime kind: rp.RepoKind, local: *const h.Local(kind), branch: []const u8) !void {
    var repo = try rp.Repo(kind, h.Local(kind).repo_opts).open(io, gpa, .{ .path = local.path });
    defer repo.deinit(io, gpa);
    try repo.addBranch(io, .{ .name = branch });
    {
        var selected = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = branch } } });
        selected.deinit();
    }
    {
        const file = try repo.core.work_dir.createFile(io, "readme.txt", .{ .truncate = true });
        defer file.close(io);
        try file.writeStreamingAll(io, "changed\n");
    }
    try repo.add(io, gpa, &.{"readme.txt"});
    _ = try repo.commit(io, gpa, .{ .message = "change", .author = "tester <tester@example.test>" });
    var restored = try repo.switchDir(io, gpa, .{ .target = .{ .ref = .{ .kind = .head, .name = "master" } } });
    restored.deinit();
}

// ---- new patches

test "web: a patch from a branch leads to its page, open to its author and to a stranger" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newBranchPatch(&alice, "feature");
    for ([_]*h.Client{ &alice, &carol }) |viewer| {
        const r = try viewer.getJson(page);
        defer r.deinit();
        try r.expectStatus(.ok);
        try r.expectJson("page.repo.patches.open.count", 1);
        try r.expectJson("page.repo.patches.open.items.0.record.event.title", "a fix");
        try r.expectJson("page.repo.patches.open.items.0.record.event.labels", "bug");
        try r.expectJson("page.repo.patches.open.items.0.record.event.description", "it fixes");
        try r.expectJson("page.repo.patches.open.items.0.record.event.source_branch", "feature");
        try r.expectJson("page.repo.patches.open.items.0.record.event.target_branch", "master");
    }
}

test "web: a patch on a sha256 repo is created from a branch" {
    const server = try arrangePatches(.sha256);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newBranchPatch(&alice, "feature");
    const r = try alice.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.open.items.0.record.event.source_branch", "feature");
}

pub const Retained = struct { title: []const u8, labels: []const u8, description: []const u8, target_branch: []const u8, source_branch: []const u8, source_kind: []const u8 };

// one failed patch form posted to `post_path` by `c`: the redirect back to
// `form_path`, the failure and all six retained fields, in the first page
// `c` gets there. that page's response is returned for further checks.
pub fn expectPatchFailure(c: *h.Client, post_path: []const u8, form_path: []const u8, fields: []const h.Field, failure: []const u8, retained: Retained) !*h.Response {
    const r = try c.post(post_path, fields);
    defer r.deinit();
    try r.expectRedirect(form_path);
    try std.testing.expect(c.cookie("haxy_form_flash") != null);
    const form = try c.followJson(r);
    errdefer form.deinit();
    try form.expectJson("session.form_feedback.patch.failure", failure);
    try form.expectJson("session.form_feedback.patch.fields.title", retained.title);
    try form.expectJson("session.form_feedback.patch.fields.labels", retained.labels);
    try form.expectJson("session.form_feedback.patch.fields.description", retained.description);
    try form.expectJson("session.form_feedback.patch.fields.target_branch", retained.target_branch);
    try form.expectJson("session.form_feedback.patch.fields.source_branch", retained.source_branch);
    try form.expectJson("session.form_feedback.patch.fields.source_kind", retained.source_kind);
    return form;
}

// a failed new-patch form, after which nothing was created
fn expectNewPatchFailure(server: *const h.Server, fields: []const h.Field, failure: []const u8, retained: Retained) !void {
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const form = try expectPatchFailure(&alice, "/alice:open/patches/new", "/alice:open/patches/new", fields, failure, retained);
    defer form.deinit();
    try form.expectJson("page.repo.patches.open.count", 0);
    try form.expectJson("page.repo.patches.drafts.count", 0);
}

test "web: a patch without a title comes back once with all six fields, the description's line breaks normalized" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const form = try expectPatchFailure(&alice, "/alice:open/patches/new", "/alice:open/patches/new", &.{
        .{ "title", " " },              .{ "labels", "bug" },            .{ "description", "one\r\ntwo" },
        .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    }, "required_title", .{ .title = " ", .labels = "bug", .description = "one\ntwo", .target_branch = "master", .source_branch = "feature", .source_kind = "branch" });
    defer form.deinit();
    try form.expectJson("page.repo.patches.open.count", 0);

    // the page that showed the flash expired its cookie, so the same browser
    // sees the form clean the next time
    const expired = try form.headerValues("set-cookie");
    try std.testing.expectEqual(1, expired.len);
    try std.testing.expectEqualStrings("haxy_form_flash=; Path=/alice:open/patches/new; Max-Age=0", expired[0]);
    try std.testing.expectEqual(null, alice.cookie("haxy_form_flash"));
    const again = try alice.getJson("/alice:open/patches/new");
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);
}

test "web: a patch onto a target branch that does not exist comes back with its fields" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    try expectNewPatchFailure(server, &.{
        .{ "title", "a fix" },        .{ "labels", "bug" },            .{ "description", "why" },
        .{ "target_branch", "nope" }, .{ "source_branch", "feature" },
    }, "invalid_target_branch", .{ .title = "a fix", .labels = "bug", .description = "why", .target_branch = "nope", .source_branch = "feature", .source_kind = "branch" });
}

test "web: a patch from a source branch that does not exist comes back with its fields" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    try expectNewPatchFailure(server, &.{
        .{ "title", "a fix" },          .{ "labels", "bug" },         .{ "description", "why" },
        .{ "target_branch", "master" }, .{ "source_branch", "nope" },
    }, "invalid_source_branch", .{ .title = "a fix", .labels = "bug", .description = "why", .target_branch = "master", .source_branch = "nope", .source_kind = "branch" });
}

test "web: a patch from a branch onto itself comes back with its fields" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    try expectNewPatchFailure(server, &.{
        .{ "title", "a fix" },          .{ "labels", "" },              .{ "description", "" },
        .{ "target_branch", "master" }, .{ "source_branch", "master" },
    }, "same_branch", .{ .title = "a fix", .labels = "", .description = "", .target_branch = "master", .source_branch = "master", .source_kind = "branch" });
}

test "web: a patch between branches with no common history comes back with its fields" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    try commitOrphan(server, server.open, "orphan");
    try expectNewPatchFailure(server, &.{
        .{ "title", "a fix" },          .{ "labels", "" },              .{ "description", "" },
        .{ "target_branch", "master" }, .{ "source_branch", "orphan" },
    }, "unrelated_branches", .{ .title = "a fix", .labels = "", .description = "", .target_branch = "master", .source_branch = "orphan", .source_kind = "branch" });
}

test "web: a draft onto a target branch that does not exist comes back as a fork form" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    try expectNewPatchFailure(server, &.{
        .{ "title", "a draft" }, .{ "labels", "x" }, .{ "description", "d" }, .{ "target_branch", "nope" },
    }, "invalid_target_branch", .{ .title = "a draft", .labels = "x", .description = "d", .target_branch = "nope", .source_branch = "", .source_kind = "fork" });
}

test "web: a patch with an overlong label goes back to the form with no feedback" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/patches/new", &.{
        .{ "title", "a fix" },          .{ "labels", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" }, .{ "description", "" },
        .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    });
    defer r.deinit();
    try r.expectRedirect("/alice:open/patches/new");
    try std.testing.expectEqual(null, alice.cookie("haxy_form_flash"));
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback", null);
    try form.expectJson("page.repo.patches.open.count", 0);
}

test "web: a draft lands among its author's drafts and nobody else's" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const page = try newDraft(&alice);
    const r = try alice.getJson(page);
    defer r.deinit();
    try r.expectJson("page.repo.patches.drafts.count", 1);
    try r.expectJson("page.repo.patches.drafts.items.0.record.event.title", "a draft");
    try r.expectJson("page.repo.patches.drafts.items.0.record.event.source_branch", null);
    try r.expectJson("page.repo.patches.open.count", 0);

    try expectCount(&alice, "/alice:open/patches/drafts", "page.repo.patches.drafts.count", 1);
    try expectCount(&bob, "/alice:open/patches/drafts", "page.repo.patches.drafts.count", 0);
}

test "web: a patch tab that is off is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, server.open);
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/patches/new", &.{
        .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
}

test "web: a stranger cannot open a patch where only members may, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, server.open);
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setPatchTab(&alice, "open", "public", "members");
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    // a missing title would be a form failure for someone allowed
    for ([_][]const u8{ "a fix", "" }) |title| {
        const r = try carol.post("/alice:open/patches/new", &.{
            .{ "title", title }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
        });
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try std.testing.expectEqual(null, carol.cookie("haxy_form_flash"));
    try expectCount(&alice, "/alice:open/patches", "page.repo.patches.open.count", 0);
}

test "web: a logged-out visitor and a removed account's session cannot open a patch" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        const r = try c.post("/alice:open/patches/new", &.{
            .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
        });
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try expectCount(&alice, "/alice:open/patches", "page.repo.patches.open.count", 0);
}

test "web: a stranger's patch to a private repo is answered as to one that does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    try arrangeBranches(server, server.secret);
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    try setPatchTab(&alice, "secret", "private", "anybody");
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    for ([_][]const u8{ "/alice:secret/patches/new", "/alice:nothing/patches/new" }) |path| {
        const r = try carol.post(path, &.{
            .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
        });
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
}

// turns the patch tab off through the settings form while another request's
// body is in flight
const TurnPatchTabOff = struct {
    alice: *h.Client,

    fn run(self: *TurnPatchTabOff) anyerror!void {
        try setPatchTab(self.alice, "open", "public", "nobody");
    }
};

test "web: a patch whose tab is turned off while its body is in flight is refused and not created" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    var off: TurnPatchTabOff = .{ .alice = &alice };
    const r = try bob.postWith("/alice:open/patches/new", &.{
        .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    }, .{ .between = .init(&off, TurnPatchTabOff.run) });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    // differs from 66c1ab6: authorized once from the head, the old handler
    // created the patch anyway and answered 303 to /alice:open/patch:<id>.
    // the write now authorizes again and finds the tab gone. accepted as D1
    // in the http review (codex-review-http-out.md, section 3)
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);

    // with the tab back on, there is no patch
    try setPatchTab(&alice, "open", "public", "anybody");
    try expectCount(&alice, "/alice:open/patches", "page.repo.patches.open.count", 0);
    try expectCount(&alice, "/alice:open/patches", "page.repo.patches.closed.count", 0);
}

test "web: a local patch from a branch is created, a local draft is not found, and a missing title sets the local flash" {
    try expectLocalPatch(.xit);
    try expectLocalPatch(.git);
}

fn expectLocalPatch(comptime kind: rp.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    try localBranch(kind, &local, "feature");
    var browser = local.client();
    defer browser.deinit();

    const created = try browser.post("/patches/new", &.{
        .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    });
    defer created.deinit();
    const page = try location(&browser, created);
    try std.testing.expect(std.mem.startsWith(u8, page, "/patch:"));
    const shown = try browser.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "a fix");

    // local mode has no forks for a draft
    const draft = try browser.post("/patches/new", &.{
        .{ "title", "a draft" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" },
    });
    defer draft.deinit();
    try draft.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", draft.body);

    const untitled = try browser.post("/patches/new", &.{
        .{ "title", "" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "feature" },
    });
    defer untitled.deinit();
    try untitled.expectRedirect("/patches/new");
    try std.testing.expectEqualStrings("required_title:patch", browser.cookie("haxy_local_flash") orelse "(none)");
    const form = try browser.followJson(untitled);
    defer form.deinit();
    try form.expectJson("session.form_feedback.patch.failure", "required_title");
}

test "web: a local patch from a missing branch fails, since the local flash only carries a missing title" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/patches/new", &.{
        .{ "title", "a fix" }, .{ "labels", "" }, .{ "description", "" }, .{ "target_branch", "master" }, .{ "source_branch", "nope" },
    });
    defer r.deinit();
    try r.expectStatus(.internal_server_error);
    try std.testing.expectEqualStrings("InvalidFormFeedback", r.body);
}

// ---- publishing and removing drafts

test "web: publishing a draft makes it an open patch and takes it out of the drafts" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newDraft(&alice);
    const r = try alice.post(try url(&alice, "{s}/publish", .{page}), &.{});
    defer r.deinit();
    try r.expectRedirect(page);

    const shown = try alice.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.count", 1);
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "a draft");
    try shown.expectJson("page.repo.patches.drafts.count", 0);
    // published, it is everyone's to see
    try expectCount(&carol, "/alice:open/patches", "page.repo.patches.open.count", 1);
}

test "web: another member cannot publish someone's draft" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const page = try newDraft(&alice);
    const r = try bob.post(try url(&bob, "{s}/publish", .{page}), &.{});
    defer r.deinit();
    // differs from 66c1ab6: a draft that is not the actor's failed the publish
    // with a 500 (InvalidPatchDraft); now 404. accepted as deviation F in
    // docs/reviews/04-phase3-codex.md
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
    try expectCount(&alice, page, "page.repo.patches.drafts.count", 1);
    try expectCount(&alice, page, "page.repo.patches.open.count", 0);
}

test "web: publishing logged out, on a hidden repo or at a malformed id is refused" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const page = try newDraft(&alice);
    {
        const r = try visitor.post(try url(&visitor, "{s}/publish", .{page}), &.{});
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    {
        const r = try carol.post("/alice:secret/patch:00000000000000000000000000000000/publish", &.{});
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    {
        const r = try alice.post("/alice:open/patch:xyz/publish", &.{});
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("event not found", r.body);
    }
    try expectCount(&alice, page, "page.repo.patches.drafts.count", 1);
}

test "web: a local host has no publish route" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const r = try browser.post("/patch:00000000000000000000000000000000/publish", &.{});
    defer r.deinit();
    try r.expectStatus(.method_not_allowed);
    try std.testing.expectEqualStrings("method not allowed", r.body);
}

test "web: removing a draft returns to the drafts, which no longer list it" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newDraft(&alice);
    const r = try alice.post(try url(&alice, "{s}/remove", .{page}), &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/patches/drafts");
    const drafts = try alice.followJson(r);
    defer drafts.deinit();
    try drafts.expectJson("page.repo.patches.drafts.count", 0);
}

test "web: another member removing someone's draft finds no such patch" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const page = try newDraft(&alice);
    const r = try bob.post(try url(&bob, "{s}/remove", .{page}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
    try expectCount(&alice, "/alice:open/patches/drafts", "page.repo.patches.drafts.count", 1);
}

// ---- resolve

fn newIssue(c: *h.Client, base: []const u8) ![]const u8 {
    const r = try c.post(try url(c, "{s}/issues/new", .{base}), &.{ .{ "title", "an issue" }, .{ "labels", "old" }, .{ "description", "" } });
    defer r.deinit();
    return location(c, r);
}

test "web: resolving an issue sets the title and labels it names and returns to it" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();

    const page = try newIssue(&alice, "/alice:open");
    // a member may resolve as well as an owner
    const r = try bob.post(try url(&bob, "{s}/resolve", .{page}), &.{ .{ "title", "settled" }, .{ "labels", "new" } });
    defer r.deinit();
    try r.expectRedirect(page);
    const shown = try alice.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.record.event.title", "settled");
    try shown.expectJson("page.repo.issues.open.items.0.record.event.labels", "new");
}

test "web: resolving a patch with no title field keeps its title" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newBranchPatch(&alice, "feature");
    const r = try alice.post(try url(&alice, "{s}/resolve", .{page}), &.{.{ "labels", "settled" }});
    defer r.deinit();
    try r.expectRedirect(page);
    const shown = try alice.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "a fix");
    try shown.expectJson("page.repo.patches.open.items.0.record.event.labels", "settled");
}

test "web: resolving to a blank title goes back to the resolve form and changes nothing" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const r = try alice.post(try url(&alice, "{s}/resolve", .{page}), &.{ .{ "title", " " }, .{ "labels", "new" } });
    defer r.deinit();
    try r.expectRedirect(try url(&alice, "{s}/resolve", .{page}));
    try std.testing.expectEqual(null, alice.cookie("haxy_form_flash"));
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.record.event.title", "an issue");
    try shown.expectJson("page.repo.issues.open.items.0.record.event.labels", "old");
}

test "web: resolving a missing issue is not found even with a blank title" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/issue:00000000000000000000000000000000/resolve", &.{ .{ "title", "" }, .{ "labels", "" } });
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("issue not found", r.body);
}

test "web: resolving needs a member, a login, a visible repo and an issue or patch" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const page = try newIssue(&alice, "/alice:open");
    const resolve = try url(&alice, "{s}/resolve", .{page});
    {
        const r = try carol.post(resolve, &.{.{ "title", "" }});
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    {
        const r = try visitor.post(resolve, &.{.{ "title", "x" }});
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    {
        const r = try carol.post("/alice:secret/issue:00000000000000000000000000000000/resolve", &.{.{ "title", "x" }});
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    {
        const discussion = blk: {
            const d = try alice.post("/alice:open/discussions/new", &.{ .{ "title", "a talk" }, .{ "labels", "" }, .{ "description", "" } });
            defer d.deinit();
            break :blk try location(&alice, d);
        };
        const r = try alice.post(try url(&alice, "{s}/resolve", .{discussion}), &.{.{ "title", "x" }});
        defer r.deinit();
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("thread not found", r.body);
    }
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.record.event.title", "an issue");
}

test "web: a local issue is resolved in place" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const page = try newIssue(&browser, "");
    const r = try browser.post(try url(&browser, "{s}/resolve", .{page}), &.{.{ "title", "settled" }});
    defer r.deinit();
    try r.expectRedirect(page);
    const shown = try browser.followJson(r);
    defer shown.deinit();
    try shown.expectJson("page.repo.issues.open.items.0.record.event.title", "settled");
}

// ---- more publishing and removal

test "web: publishing a draft that is already published changes nothing" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newDraft(&alice);
    for (0..2) |_| {
        const r = try alice.post(try url(&alice, "{s}/publish", .{page}), &.{});
        defer r.deinit();
        try r.expectRedirect(page);
    }
    const shown = try alice.getJson(page);
    defer shown.deinit();
    try shown.expectJson("page.repo.patches.open.count", 1);
    try shown.expectJson("page.repo.patches.open.items.0.record.event.title", "a draft");
    try shown.expectJson("page.repo.patches.drafts.count", 0);
}

test "web: publishing a well-formed id that names no draft is not found" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/patch:00000000000000000000000000000000/publish", &.{});
    defer r.deinit();
    // differs from 66c1ab6: a draft the user does not have failed the
    // publish with 500 "InvalidPatchDraft"; now 404. accepted as deviation F
    // in docs/reviews/04-phase3-codex.md
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
    try expectCount(&alice, "/alice:open/patches", "page.repo.patches.open.count", 0);
}

test "web: removing a patch from a branch returns to the list, which no longer has it" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newBranchPatch(&alice, "feature");
    const r = try alice.post(try url(&alice, "{s}/remove", .{page}), &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/patches");
    const list = try alice.followJson(r);
    defer list.deinit();
    try list.expectJson("page.repo.patches.open.count", 0);
    try list.expectJson("page.repo.patches.closed.count", 0);
}

test "web: removing a published draft returns to the list, not the drafts" {
    const server = try arrangePatches(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const page = try newDraft(&alice);
    {
        const r = try alice.post(try url(&alice, "{s}/publish", .{page}), &.{});
        defer r.deinit();
        try r.expectRedirect(page);
    }
    const r = try alice.post(try url(&alice, "{s}/remove", .{page}), &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open/patches");
    const list = try alice.followJson(r);
    defer list.deinit();
    try list.expectJson("page.repo.patches.open.count", 0);
    try list.expectJson("page.repo.patches.drafts.count", 0);
}
