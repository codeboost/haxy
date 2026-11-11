//! the harness's first tests, one per feature it gives the rest

const std = @import("std");
const h = @import("harness.zig");

test "web: a logged-out visitor gets the home page as html, and as a snapshot with no user" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const page = try visitor.get("/");
    defer page.deinit();
    try page.expectStatus(.ok);
    try std.testing.expectEqualStrings("text/html; charset=utf-8", page.header("content-type").?);

    const snapshot = try visitor.getJson("/");
    defer snapshot.deinit();
    try snapshot.expectStatus(.ok);
    try std.testing.expectEqualStrings("application/json", snapshot.header("content-type").?);
    try snapshot.expectJson("session.user_id", null);
}

test "web: an unknown path is not found" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.get("/alice:open/no/such/page");
    defer r.deinit();
    try r.expectStatus(.not_found);
}

test "web: a method other than get, head or post is not allowed" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.send(.{ .method = "PUT", .path = "/", .body = "x=1", .headers = &.{.{ .name = "content-type", .value = null }} });
    defer r.deinit();
    try r.expectStatus(.method_not_allowed);
    try std.testing.expectEqualStrings("method not allowed", r.body);
}

test "web: logging in with the right password sets a session that names the user" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = server.client();
    defer alice.deinit();

    const r = try alice.post("/home/user/login", &.{ .{ "username", "alice" }, .{ "password", "password" } });
    defer r.deinit();
    try r.expectRedirect("/");
    const cookies = try r.headerValues("set-cookie");
    try std.testing.expectEqual(1, cookies.len);
    const cookie = cookies[0];
    try std.testing.expect(std.mem.startsWith(u8, cookie, "haxy_session="));
    try std.testing.expect(std.mem.endsWith(u8, cookie, "; Path=/; HttpOnly; SameSite=Lax; Max-Age=34560000"));

    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("session.user_name", "alice");
}

test "web: a wrong password comes back once as login feedback that keeps the name but not the password" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.post("/home/user/login", &.{ .{ "username", "alice" }, .{ "password", "not-her-password" } });
    defer r.deinit();
    try r.expectRedirect("/home/user");
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));

    const page = try visitor.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("session.user_id", null);
    try page.expectJson("session.form_feedback.login.failure", "wrong_password");
    try page.expectJson("session.form_feedback.login.username", "alice");
    try page.expectBodyLacks("not-her-password");

    // the flash is consumed by the first page that shows it
    const again = try visitor.getJson("/home/user");
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);
}

test "web: a form posted from another site is forbidden" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.postWith("/home/user/login", &.{ .{ "username", "alice" }, .{ "password", "password" } }, .{
        .headers = &.{.{ .name = "origin", .value = "http://elsewhere.test" }},
    });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));
}

test "web: a stranger finds a private repo missing and a public one open" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = try server.clientAs("carol");
    defer carol.deinit();

    const secret = try carol.getJson("/alice:secret");
    defer secret.deinit();
    try secret.expectStatus(.not_found);
    try secret.expectJsonHas("session.current_page.not_found");

    const open = try carol.get("/alice:open");
    defer open.deinit();
    try open.expectStatus(.ok);
}

test "web: creating a repo leads to it, and a taken name comes back with the form filled in" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const created = try alice.post("/home/repo/new", &.{
        .{ "name", "fresh" }, .{ "description", "a new one" }, .{ "hash", "sha1" }, .{ "access", "public" },
    });
    defer created.deinit();
    try created.expectRedirect("/alice:fresh");
    const repo = try alice.follow(created);
    defer repo.deinit();
    try repo.expectStatus(.ok);

    const taken = try alice.post("/home/repo/new", &.{
        .{ "name", "open" }, .{ "description", "again" }, .{ "hash", "sha1" }, .{ "access", "private" },
    });
    defer taken.deinit();
    try taken.expectRedirect("/home/repo/new");
    const form = try alice.followJson(taken);
    defer form.deinit();
    try form.expectJson("session.form_feedback.repo.failure", "name_taken");
    try form.expectJson("session.form_feedback.repo.fields.name", "open");
    try form.expectJson("session.form_feedback.repo.fields.description", "again");
    try form.expectJson("session.form_feedback.repo.fields.access", "private");
}

test "web: a local issue with a title is listed, and one without a title sets the local flash" {
    try expectLocalIssue(.git);
    try expectLocalIssue(.xit);
}

fn expectLocalIssue(comptime kind: @import("xit").repo.RepoKind) !void {
    var local = try h.Local(kind).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    const created = try browser.post("/issues/new", &.{ .{ "title", "the roof leaks" }, .{ "labels", "" }, .{ "description", "" } });
    defer created.deinit();
    try created.expectStatus(.see_other);
    try std.testing.expect(std.mem.startsWith(u8, created.header("location").?, "/issue:"));
    const issue = try browser.follow(created);
    defer issue.deinit();
    try issue.expectStatus(.ok);
    const list = try browser.getJson("/issues");
    defer list.deinit();
    try list.expectBodyContains("the roof leaks");

    const untitled = try browser.post("/issues/new", &.{ .{ "title", "" }, .{ "labels", "" }, .{ "description", "no title" } });
    defer untitled.deinit();
    try untitled.expectRedirect("/issues/new");
    try std.testing.expectEqualStrings("required_title:issue", browser.cookie("haxy_local_flash") orelse "(none)");
    const form = try browser.followJson(untitled);
    defer form.deinit();
    try form.expectJson("session.form_feedback.issue.failure", "required_title");
    // the page that showed the flash expired it
    try std.testing.expectEqual(null, browser.cookie("haxy_local_flash"));
}

// changes alice's password through the settings form with another browser
const ChangePassword = struct {
    browser: *h.Client,
    status: ?std.http.Status = null,

    fn run(self: *ChangePassword) anyerror!void {
        const r = try self.browser.post("/home/user/settings/user", &.{
            .{ "email", "alice@example.test" },
            .{ "current_password", "password" },
            .{ "new_password", "changed" },
            .{ "new_password_again", "changed" },
        });
        defer r.deinit();
        self.status = r.status;
        try r.expectRedirect("/home/user/settings");
    }
};

test "web: a delete is refused when the password changes while its body is in flight" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var other_tab = try server.clientAs("alice");
    defer other_tab.deinit();

    var change: ChangePassword = .{ .browser = &other_tab };
    const r = try alice.postWith("/alice:open/repo/delete/delete", &.{ .{ "confirm", "alice:open" }, .{ "password", "password" } }, .{
        .between = .init(&change, ChangePassword.run),
    });
    defer r.deinit();
    try std.testing.expect(r.hook_ran);
    try std.testing.expectEqual(.see_other, change.status.?);
    try r.expectRedirect("/alice:open/repo/delete");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.delete.failure", "wrong_password");

    const repo = try alice.get("/alice:open");
    defer repo.deinit();
    try repo.expectStatus(.ok);
}

test "web: a removed account's old session is logged out and cannot create a repo" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    const r = try dave.post("/home/repo/new", &.{
        .{ "name", "mine" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" },
    });
    defer r.deinit();
    try r.expectStatus(.forbidden);
    try std.testing.expectEqualStrings("log in to make changes", r.body);

    const page = try dave.getJson("/");
    defer page.deinit();
    try page.expectJson("session.user_id", null);
}
