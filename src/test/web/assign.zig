//! assigning people to issues and discussions, and unassigning them

const std = @import("std");
const h = @import("harness.zig");

const no_thread = "/alice:open/issue:00000000000000000000000000000000";

// post a form that must redirect, and give back where it leads
fn redirected(c: *h.Client, url: []const u8, fields: []const h.Field) ![]const u8 {
    const r = try c.post(url, fields);
    defer r.deinit();
    try r.expectStatus(.see_other);
    return try c.arena.allocator().dupe(u8, r.header("location").?);
}

fn path(c: *h.Client, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(c.arena.allocator(), fmt, args);
}

fn newIssue(c: *h.Client, repo: []const u8, title: []const u8) ![]const u8 {
    return redirected(c, try path(c, "{s}/issues/new", .{repo}), &.{ .{ "title", title }, .{ "labels", "" }, .{ "description", "" } });
}

fn assign(c: *h.Client, thread: []const u8, assignee: []const u8) !*h.Response {
    return c.post(try path(c, "{s}/assign", .{thread}), &.{.{ "assignee", assignee }});
}

fn expectAssignees(c: *h.Client, issue: []const u8, count: usize) !void {
    const page = try c.getJson(issue);
    defer page.deinit();
    try page.expectStatus(.ok);
    const assignees = page.jsonAt("page.repo.issues.open.items.0.assignees") orelse {
        page.describe();
        return error.TestExpectedJson;
    };
    try std.testing.expectEqual(count, assignees.array.items.len);
}

// a refused assignment comes back to the thread with why and what was typed
fn expectAssignFailure(c: *h.Client, issue: []const u8, text: []const u8, failure: []const u8) !void {
    const r = try assign(c, issue, text);
    defer r.deinit();
    try r.expectRedirect(issue);
    const page = try c.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback.assignment.failure", failure);
    try page.expectJson("session.form_feedback.assignment.text", text);
}

// assigning

test "web: assigning a user by name shows them on the thread to anyone" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who fixes this");

    const r = try assign(&alice, issue, " bob ");
    defer r.deinit();
    try r.expectRedirect(issue);
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback", null);
    try page.expectJson("page.repo.issues.open.items.0.assignees.0.email", "bob@example.test");
    try page.expectJson("page.repo.issues.open.items.0.assignees.0.name", "bob");

    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const seen = try carol.getJson(issue);
    defer seen.deinit();
    try seen.expectJson("page.repo.issues.open.items.0.assignees.0.email", "bob@example.test");
}

test "web: assigning an email that names no account assigns the email" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try newIssue(&bob, "/alice:open", "outside help");

    const r = try assign(&bob, issue, "helper@elsewhere.test");
    defer r.deinit();
    try r.expectRedirect(issue);
    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.assignees.0.email", "helper@elsewhere.test");
}

test "web: assigning an unknown name comes back once with the text retained, and assigns nobody" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");

    try expectAssignFailure(&alice, issue, "  nobody here", "not_found");
    const again = try alice.getJson(issue);
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);
    try expectAssignees(&alice, issue, 0);
}

test "web: a removed account's name cannot be assigned" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");

    try expectAssignFailure(&alice, issue, "dave", "not_found");
    try expectAssignees(&alice, issue, 0);
}

test "web: assigning someone twice says they already are" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");
    {
        const r = try assign(&alice, issue, "bob");
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    // by email this time, which is the same assignment
    try expectAssignFailure(&alice, issue, "bob@example.test", "already_assigned");
    try expectAssignees(&alice, issue, 1);
}

test "web: an email with a space in it is not an email" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");

    try expectAssignFailure(&alice, issue, "not an@email", "not_an_email");
    try expectAssignees(&alice, issue, 0);
}

test "web: a stranger cannot assign on someone else's issue, whatever the text, but may on their own" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const alices = try newIssue(&alice, "/alice:open", "alice's");

    // an unknown name would be form feedback for anyone allowed to assign
    for ([_][]const u8{ "carol", "nobody here" }) |text| {
        const r = try assign(&carol, alices, text);
        defer r.deinit();
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try expectAssignees(&alice, alices, 0);

    const carols = try newIssue(&carol, "/alice:open", "carol's");
    const own = try assign(&carol, carols, "carol");
    defer own.deinit();
    try own.expectRedirect(carols);
    try expectAssignees(&carol, carols, 1);
}

test "web: a logged-out visitor cannot assign" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");

    var visitor = server.client();
    defer visitor.deinit();
    const r = try assign(&visitor, issue, "bob");
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectAssignees(&alice, issue, 0);
}

test "web: a stranger assigning on a private repo's issue is told the repo does not exist, as for one that does not" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:secret", "hidden");

    const hidden = try assign(&carol, issue, "carol");
    defer hidden.deinit();
    const missing = try assign(&carol, "/alice:nothing/issue:00000000000000000000000000000000", "carol");
    defer missing.deinit();
    for ([_]*h.Response{ hidden, missing }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("repo not found", r.body);
    }
    try expectAssignees(&alice, issue, 0);
}

test "web: assigning on a thread that does not exist, a comment or a malformed id names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "real");
    const first = try redirected(&alice, try path(&alice, "{s}/new", .{issue}), &.{.{ "body", "a comment" }});

    const missing = try assign(&alice, no_thread, "bob");
    defer missing.deinit();
    const on_comment = try assign(&alice, first, "bob");
    defer on_comment.deinit();
    const malformed = try assign(&alice, "/alice:open/issue:nothex", "bob");
    defer malformed.deinit();
    for ([_]*h.Response{ missing, on_comment, malformed }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("event not found", r.body);
    }
    try expectAssignees(&alice, issue, 0);
}

test "web: an unknown name on a thread that does not exist is looked up before the thread" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    // 66c1ab6 resolved the name before writing to the thread
    try expectAssignFailure(&alice, no_thread, "nobody here", "not_found");
}

test "web: a discussion can be assigned" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const discussion = try redirected(&alice, "/alice:open/discussions/new", &.{ .{ "title", "talk" }, .{ "labels", "" }, .{ "description", "" } });

    const r = try assign(&alice, discussion, "bob");
    defer r.deinit();
    try r.expectRedirect(discussion);
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.discussions.recent.items.0.assignees.0.email", "bob@example.test");
}

test "web: assigning on a sha256 repo shows the assignee" {
    const server = try h.Server.init(.sha256);
    defer server.deinit();
    var bob = try server.clientAs("bob");
    defer bob.deinit();
    const issue = try newIssue(&bob, "/alice:secret", "hashed");

    const r = try assign(&bob, issue, "alice");
    defer r.deinit();
    try r.expectRedirect(issue);
    const page = try bob.followJson(r);
    defer page.deinit();
    try page.expectJson("page.repo.issues.open.items.0.assignees.0.email", "alice@example.test");
}

// unassigning

test "web: unassigning goes back to the thread, which no longer shows the assignee" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");
    {
        const r = try assign(&alice, issue, "bob");
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    const r = try alice.post(try path(&alice, "{s}/assignee:bob%40example.test/unassign", .{issue}), &.{});
    defer r.deinit();
    try r.expectRedirect(issue);
    try expectAssignees(&alice, issue, 0);
}

test "web: unassigning an email that is not assigned names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");

    const r = try alice.post(try path(&alice, "{s}/assignee:carol@example.test/unassign", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("event not found", r.body);
}

test "web: a stranger cannot unassign on someone else's issue" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");
    {
        const r = try assign(&alice, issue, "carol");
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    const assigned = try carol.post(try path(&carol, "{s}/assignee:carol%40example.test/unassign", .{issue}), &.{});
    defer assigned.deinit();
    // 66c1ab6 checked who may change the thread before looking for the assignment
    const unassigned = try carol.post(try path(&carol, "{s}/assignee:nobody%40example.test/unassign", .{issue}), &.{});
    defer unassigned.deinit();
    for ([_]*h.Response{ assigned, unassigned }) |r| {
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("you don't have permission to do that", r.body);
    }
    try expectAssignees(&alice, issue, 1);
}

test "web: a logged-out visitor cannot unassign" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");
    {
        const r = try assign(&alice, issue, "bob");
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    var visitor = server.client();
    defer visitor.deinit();
    const r = try visitor.post(try path(&visitor, "{s}/assignee:bob%40example.test/unassign", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);
    try expectAssignees(&alice, issue, 1);
}

test "web: an unassign url with no assignee or a malformed thread names no event" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const no_assignee = try alice.post(no_thread ++ "/unassign", &.{});
    defer no_assignee.deinit();
    const malformed = try alice.post("/alice:open/issue:nothex/assignee:bob%40example.test/unassign", &.{});
    defer malformed.deinit();
    for ([_]*h.Response{ no_assignee, malformed }) |r| {
        try r.expectStatus(.not_found);
        try std.testing.expectEqualStrings("event not found", r.body);
    }
}

// local mode

fn expectLocalAssign(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();
    const issue = try newIssue(&browser, "", "local");

    // local mode has no accounts, so a name is not an email
    {
        const r = try assign(&browser, issue, "bob smith");
        defer r.deinit();
        try r.expectRedirect(issue);
        try std.testing.expectEqualStrings("assignment:not_an_email:bob%20smith", browser.cookie("haxy_local_flash") orelse "(none)");
        const page = try browser.followJson(r);
        defer page.deinit();
        try page.expectJson("session.form_feedback.assignment.failure", "not_an_email");
        try page.expectJson("session.form_feedback.assignment.text", "bob smith");
        try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
    }
    {
        const r = try assign(&browser, issue, "bob@example.test");
        defer r.deinit();
        try r.expectRedirect(issue);
        const page = try browser.followJson(r);
        defer page.deinit();
        try page.expectJson("page.repo.issues.open.items.0.assignees.0.email", "bob@example.test");
    }
    {
        const r = try assign(&browser, issue, "bob@example.test");
        defer r.deinit();
        try r.expectRedirect(issue);
        try std.testing.expectEqualStrings("assignment:already_assigned:bob%40example.test", browser.cookie("haxy_local_flash") orelse "(none)");
    }
    {
        const r = try browser.post(try path(&browser, "{s}/assignee:bob%40example.test/unassign", .{issue}), &.{});
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    try expectAssignees(&browser, issue, 0);
}

test "web: a local repo's threads take emails as assignees and refuse names" {
    try expectLocalAssign(.git);
    try expectLocalAssign(.xit);
}

test "web: a stranger unassigning on a private repo's issue is told the repo does not exist" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();
    const issue = try newIssue(&alice, "/alice:secret", "hidden");
    {
        const r = try assign(&alice, issue, "bob");
        defer r.deinit();
        try r.expectRedirect(issue);
    }

    const r = try carol.post(try path(&carol, "{s}/assignee:bob%40example.test/unassign", .{issue}), &.{});
    defer r.deinit();
    try r.expectStatus(.not_found);
    try std.testing.expectEqualStrings("repo not found", r.body);
    try expectAssignees(&alice, issue, 1);
}

test "web: a removed account's old session cannot assign or unassign" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    const issue = try newIssue(&alice, "/alice:open", "who");
    {
        const r = try assign(&alice, issue, "bob");
        defer r.deinit();
        try r.expectRedirect(issue);
    }
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    const assigned = try assign(&dave, issue, "carol");
    defer assigned.deinit();
    const unassigned = try dave.post(try path(&dave, "{s}/assignee:bob%40example.test/unassign", .{issue}), &.{});
    defer unassigned.deinit();
    for ([_]*h.Response{ assigned, unassigned }) |r| {
        try r.expectStatus(.forbidden);
        try std.testing.expectEqualStrings("log in to make changes", r.body);
    }
    try expectAssignees(&alice, issue, 1);
}
