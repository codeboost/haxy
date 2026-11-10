//! signing up, logging in and out, and changing an account's settings

const std = @import("std");
const h = @import("harness.zig");

fn expectRefused(r: *const h.Response, status: std.http.Status, text: []const u8) !void {
    try r.expectStatus(status);
    if (std.mem.eql(u8, r.body, text)) return;
    r.describe();
    std.debug.print("expected the body \"{s}\"\n", .{text});
    return error.TestExpectedEqual;
}

// neither a header nor the body carries `secret`
fn expectNoSecret(r: *const h.Response, secret: []const u8) !void {
    for (r.headers) |header| if (std.mem.indexOf(u8, header.value, secret) != null) {
        r.describe();
        std.debug.print("a header carries \"{s}\"\n", .{secret});
        return error.TestUnexpectedText;
    };
    try r.expectBodyLacks(secret);
}

fn signUp(c: *h.Client, path: []const u8, name: []const u8, email: []const u8, password: []const u8, again: []const u8) !*h.Response {
    return c.post(path, &.{ .{ "name", name }, .{ "email", email }, .{ "password", password }, .{ "password_again", again } });
}

// a sign-up that fails goes back to the form with the failure, name and email
fn expectSignUpFailure(name: []const u8, email: []const u8, password: []const u8, again: []const u8, failure: []const u8) !void {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try signUp(&visitor, "/home/user/new", name, email, password, again);
    defer r.deinit();
    try r.expectRedirect("/home/user/new");
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));
    const form = try visitor.followJson(r);
    defer form.deinit();
    try form.expectJson("session.user_id", null);
    try form.expectJson("session.form_feedback.user.failure", failure);
    try form.expectJson("session.form_feedback.user.fields.name", name);
    try form.expectJson("session.form_feedback.user.fields.email", email);
}

// ---- POST …/user/new

test "web: signing up logs the new user in and leads to their page" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try signUp(&visitor, "/home/user/new", "erin", "erin@example.test", "erins-secret", "erins-secret");
    defer r.deinit();
    try r.expectRedirect("/erin");
    const cookies = try r.headerValues("set-cookie");
    try std.testing.expectEqual(1, cookies.len);
    try std.testing.expect(std.mem.startsWith(u8, cookies[0], "haxy_session="));
    try std.testing.expect(std.mem.endsWith(u8, cookies[0], "; Path=/; HttpOnly; SameSite=Lax; Max-Age=34560000"));

    const page = try visitor.followJson(r);
    defer page.deinit();
    try page.expectStatus(.ok);
    try page.expectJson("session.user_name", "erin");
    try page.expectJson("session.user_email", "erin@example.test");
    try page.expectJson("page.user.user.name", "erin");

    // the password chosen is the one that logs in
    var later = server.client();
    defer later.deinit();
    try later.login("erin", "erins-secret");
}

test "web: a sign-up without a name comes back as required, keeping the email" {
    try expectSignUpFailure("", "erin@example.test", "pw-one", "pw-one", "required_name");
}

test "web: a sign-up with a short, long, reserved or badly formed name comes back as invalid" {
    try expectSignUpFailure("er", "erin@example.test", "pw-one", "pw-one", "invalid_name");
    try expectSignUpFailure("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", "erin@example.test", "pw-one", "pw-one", "invalid_name");
    try expectSignUpFailure("home", "erin@example.test", "pw-one", "pw-one", "invalid_name");
    try expectSignUpFailure("-erin", "erin@example.test", "pw-one", "pw-one", "invalid_name");
    try expectSignUpFailure("er--in", "erin@example.test", "pw-one", "pw-one", "invalid_name");
    try expectSignUpFailure("er in", "erin@example.test", "pw-one", "pw-one", "invalid_name");
}

test "web: a sign-up without an email comes back as required, keeping the name" {
    try expectSignUpFailure("erin", "", "pw-one", "pw-one", "required_email");
}

test "web: a sign-up without a password comes back as required" {
    try expectSignUpFailure("erin", "erin@example.test", "", "", "required_password");
}

test "web: a sign-up whose passwords differ comes back as a mismatch" {
    try expectSignUpFailure("erin", "erin@example.test", "pw-one", "pw-two", "password_mismatch");
}

test "web: a sign-up with a taken name or email comes back as taken" {
    try expectSignUpFailure("bob", "new@example.test", "pw-one", "pw-one", "name_taken");
    try expectSignUpFailure("erin", "bob@example.test", "pw-one", "pw-one", "email_taken");
}

test "web: a name check comes before the email and password checks" {
    try expectSignUpFailure("", "", "", "x", "required_name");
    try expectSignUpFailure("erin", "", "", "x", "required_email");
    try expectSignUpFailure("erin", "erin@example.test", "", "x", "required_password");
}

test "web: a failed sign-up returns neither password and creates no account" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try signUp(&visitor, "/home/user/new", "erin", "erin@example.test", "first-Secret-71", "second-Secret-72");
    defer r.deinit();
    try r.expectRedirect("/home/user/new");
    try expectNoSecret(r, "first-Secret-71");
    try expectNoSecret(r, "second-Secret-72");
    const form = try visitor.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user.failure", "password_mismatch");
    try expectNoSecret(form, "first-Secret-71");
    try expectNoSecret(form, "second-Secret-72");

    // the flash is consumed by the page that showed it
    const again = try visitor.getJson("/home/user/new");
    defer again.deinit();
    try again.expectJson("session.form_feedback", null);

    const missing = try visitor.getJson("/erin");
    defer missing.deinit();
    try missing.expectStatus(.not_found);
}

test "web: a failed sign-up from a repo's page goes back to that page's form" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try signUp(&visitor, "/alice:open/user/new", "bob", "new@example.test", "pw-one", "pw-one");
    defer r.deinit();
    try r.expectRedirect("/alice:open/user/new");
    const form = try visitor.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user.failure", "name_taken");
    try form.expectJson("session.form_feedback.user.fields.name", "bob");
}

test "web: signing up while logged in is refused, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try signUp(&alice, "/home/user/new", "erin", "erin@example.test", "pw-one", "pw-one");
    defer r.deinit();
    try expectRefused(r, .forbidden, "log out to create a user");
    // a form failure is refused the same way
    const bad = try signUp(&alice, "/home/user/new", "", "", "", "x");
    defer bad.deinit();
    try expectRefused(bad, .forbidden, "log out to create a user");

    const missing = try alice.getJson("/erin");
    defer missing.deinit();
    try missing.expectStatus(.not_found);
}

test "web: a removed account's session cannot sign up" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    const r = try signUp(&dave, "/home/user/new", "erin", "erin@example.test", "pw-one", "pw-one");
    defer r.deinit();
    try expectRefused(r, .forbidden, "log out to create a user");

    var visitor = server.client();
    defer visitor.deinit();
    const missing = try visitor.getJson("/erin");
    defer missing.deinit();
    try missing.expectStatus(.not_found);
}

// ---- POST …/login and …/logout

test "web: logging in as an unknown user comes back as unknown, keeping the name" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.post("/home/user/login", &.{ .{ "username", "zed" }, .{ "password", "zeds-Secret-9" } });
    defer r.deinit();
    try r.expectRedirect("/home/user");
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));
    try expectNoSecret(r, "zeds-Secret-9");
    const page = try visitor.followJson(r);
    defer page.deinit();
    try page.expectJson("session.user_id", null);
    try page.expectJson("session.form_feedback.login.failure", "unknown_user");
    try page.expectJson("session.form_feedback.login.username", "zed");
    try expectNoSecret(page, "zeds-Secret-9");
}

test "web: a removed account cannot log in" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const r = try visitor.post("/home/user/login", &.{ .{ "username", "dave" }, .{ "password", h.password } });
    defer r.deinit();
    try r.expectRedirect("/home/user");
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));
    const page = try visitor.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback.login.failure", "unknown_user");
}

test "web: logging in from a repo's user tab returns to the repo, and a failure stays on the tab" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    const wrong = try visitor.post("/alice:open/user/login", &.{ .{ "username", "alice" }, .{ "password", "nope" } });
    defer wrong.deinit();
    try wrong.expectRedirect("/alice:open/user");
    const form = try visitor.followJson(wrong);
    defer form.deinit();
    try form.expectJson("session.form_feedback.login.failure", "wrong_password");

    const right = try visitor.post("/alice:open/user/login", &.{ .{ "username", "alice" }, .{ "password", h.password } });
    defer right.deinit();
    try right.expectRedirect("/alice:open");
    const repo = try visitor.followJson(right);
    defer repo.deinit();
    try repo.expectJson("session.user_name", "alice");
}

test "web: logging out expires the cookie and returns to the page the user tab belongs to" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try alice.post("/alice:open/user/logout", &.{});
    defer r.deinit();
    try r.expectRedirect("/alice:open");
    const cookies = try r.headerValues("set-cookie");
    try std.testing.expectEqual(1, cookies.len);
    try std.testing.expectEqualStrings("haxy_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0", cookies[0]);
    try std.testing.expectEqual(null, alice.cookie("haxy_session"));

    var home = try server.clientAs("alice");
    defer home.deinit();
    const from_home = try home.post("/home/user/logout", &.{});
    defer from_home.deinit();
    try from_home.expectRedirect("/");
}

test "web: logging in with blank or missing fields comes back as an unknown user" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();

    // each failure is followed before the next, whose flash would replace it
    for ([_][]const h.Field{ &.{ .{ "username", "" }, .{ "password", "" } }, &.{} }) |fields| {
        const r = try visitor.post("/home/user/login", fields);
        defer r.deinit();
        try r.expectRedirect("/home/user");
        const page = try visitor.followJson(r);
        defer page.deinit();
        try page.expectJson("session.user_id", null);
        try page.expectJson("session.form_feedback.login.failure", "unknown_user");
        try page.expectJson("session.form_feedback.login.username", "");
    }
    try std.testing.expectEqual(null, visitor.cookie("haxy_session"));
}

test "web: logging in from a private repo's user tab redirects to that repo, which the stranger still cannot see" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var carol = server.client();
    defer carol.deinit();

    const wrong = try carol.post("/alice:secret/user/login", &.{ .{ "username", "carol" }, .{ "password", "nope" } });
    defer wrong.deinit();
    try wrong.expectRedirect("/alice:secret/user");

    const right = try carol.post("/alice:secret/user/login", &.{ .{ "username", "carol" }, .{ "password", h.password } });
    defer right.deinit();
    try right.expectRedirect("/alice:secret");
    const page = try carol.followJson(right);
    defer page.deinit();
    try page.expectStatus(.not_found);
    try page.expectJson("session.user_name", "carol");
    try page.expectJsonHas("session.current_page.not_found");
}

test "web: logging out while logged out, with a malformed cookie or from an unknown page still expires the cookie" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    const expired = "haxy_session=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0";

    var visitor = server.client();
    defer visitor.deinit();
    const logged_out = try visitor.post("/alice:open/user/logout", &.{});
    defer logged_out.deinit();
    try logged_out.expectRedirect("/alice:open");
    try std.testing.expectEqualStrings(expired, logged_out.header("set-cookie").?);

    var garbled = server.client();
    defer garbled.deinit();
    try garbled.setCookie("haxy_session", "not-a-token", "/");
    const malformed = try garbled.post("/home/user/logout", &.{});
    defer malformed.deinit();
    try malformed.expectRedirect("/");
    try std.testing.expectEqualStrings(expired, malformed.header("set-cookie").?);
    try std.testing.expectEqual(null, garbled.cookie("haxy_session"));

    // a page that does not exist sends the browser home, and the session ends
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    var copy = server.client();
    defer copy.deinit();
    try copy.setCookie("haxy_session", alice.cookie("haxy_session").?, "/");
    const unknown = try alice.post("/no/such/page/logout", &.{});
    defer unknown.deinit();
    try unknown.expectRedirect("/");
    try std.testing.expectEqualStrings(expired, unknown.header("set-cookie").?);
    const page = try copy.getJson("/");
    defer page.deinit();
    try page.expectJson("session.user_id", null);
}

test "web: logging out ends the session for every copy of its cookie" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();
    // a second browser holding the same cookie
    var copy = server.client();
    defer copy.deinit();
    try copy.setCookie("haxy_session", alice.cookie("haxy_session").?, "/");

    const r = try alice.post("/home/user/logout", &.{});
    defer r.deinit();
    try r.expectRedirect("/");

    const page = try copy.getJson("/home/user");
    defer page.deinit();
    try page.expectJson("session.user_id", null);
    const write = try copy.post("/home/repo/new", &.{ .{ "name", "late" }, .{ "description", "" }, .{ "hash", "sha1" }, .{ "access", "public" } });
    defer write.deinit();
    try expectRefused(write, .forbidden, "log in to make changes");
}

// ---- POST …/user (user settings)

fn postSettings(c: *h.Client, email: []const u8, current: []const u8, new: []const u8, again: []const u8) !*h.Response {
    return c.post("/home/user/settings/user", &.{
        .{ "email", email }, .{ "current_password", current }, .{ "new_password", new }, .{ "new_password_again", again },
    });
}

// a settings form that fails goes back to the tab with the failure and the
// email, and alice's account is as it was
fn expectSettingsFailure(email: []const u8, current: []const u8, new: []const u8, again: []const u8, failure: []const u8) !void {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, email, current, new, again);
    defer r.deinit();
    try r.expectRedirect("/home/user/settings");
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user_settings.failure", failure);
    try form.expectJson("session.form_feedback.user_settings.fields.email", email);
    try form.expectJson("session.user_email", "alice@example.test");

    var later = server.client();
    defer later.deinit();
    try later.login("alice", h.password);
}

test "web: changing the email shows the new one" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, "alice@elsewhere.test", "", "", "");
    defer r.deinit();
    try r.expectRedirect("/home/user/settings");
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("session.form_feedback", null);
    try page.expectJson("session.user_email", "alice@elsewhere.test");
}

test "web: after a password change the old password no longer logs in and the new one does" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, "alice@example.test", h.password, "brand-New-55", "brand-New-55");
    defer r.deinit();
    try r.expectRedirect("/home/user/settings");
    // the session that changed it stays logged in
    const page = try alice.followJson(r);
    defer page.deinit();
    try page.expectJson("session.user_name", "alice");

    var old = server.client();
    defer old.deinit();
    const refused = try old.post("/home/user/login", &.{ .{ "username", "alice" }, .{ "password", h.password } });
    defer refused.deinit();
    try refused.expectRedirect("/home/user");
    try std.testing.expectEqual(null, old.cookie("haxy_session"));

    var fresh = server.client();
    defer fresh.deinit();
    try fresh.login("alice", "brand-New-55");
}

test "web: user settings without an email come back as required" {
    try expectSettingsFailure("", "", "", "", "required_email");
}

test "web: user settings with another user's email come back as taken" {
    try expectSettingsFailure("bob@example.test", "", "", "", "email_taken");
}

test "web: a password change with the wrong current password comes back as wrong" {
    try expectSettingsFailure("alice@example.test", "not-hers", "brand-New-55", "brand-New-55", "wrong_password");
}

test "web: a password change to an empty password comes back as required" {
    try expectSettingsFailure("alice@example.test", h.password, "", "", "required_password");
}

test "web: a password change whose new passwords differ comes back as a mismatch" {
    try expectSettingsFailure("alice@example.test", h.password, "brand-New-55", "brand-New-56", "password_mismatch");
}

test "web: a failed password change keeps the email and returns no password" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var alice = try server.clientAs("alice");
    defer alice.deinit();

    const r = try postSettings(&alice, "alice@elsewhere.test", "Current-Guess-31", "Next-Secret-32", "Next-Secret-33");
    defer r.deinit();
    try r.expectRedirect("/home/user/settings");
    for ([_][]const u8{ "Current-Guess-31", "Next-Secret-32", "Next-Secret-33" }) |secret| try expectNoSecret(r, secret);
    const form = try alice.followJson(r);
    defer form.deinit();
    try form.expectJson("session.form_feedback.user_settings.failure", "wrong_password");
    try form.expectJson("session.form_feedback.user_settings.fields.email", "alice@elsewhere.test");
    for ([_][]const u8{ "Current-Guess-31", "Next-Secret-32", "Next-Secret-33" }) |secret| try expectNoSecret(form, secret);
    // nothing changed, the email included
    try form.expectJson("session.user_email", "alice@example.test");
}

test "web: user settings are refused to the logged out and a removed account's session, whatever the form says" {
    const server = try h.Server.init(.sha1);
    defer server.deinit();
    var visitor = server.client();
    defer visitor.deinit();
    var dave = server.client();
    defer dave.deinit();
    try server.mintSession(&dave, server.dave);

    for ([_]*h.Client{ &visitor, &dave }) |c| {
        const r = try postSettings(c, "dave@new.test", h.password, "x", "x");
        defer r.deinit();
        try expectRefused(r, .forbidden, "log in to make changes");
        // differs from 66c1ab6: there a removed account's empty email failed
        // validation first and came back as a 303 with required_email; it is
        // now refused before the body is read. accepted as B2 in
        // docs/reviews/05-phase4-codex.md (user settings row).
        const bad = try postSettings(c, "", "wrong", "x", "y");
        defer bad.deinit();
        try expectRefused(bad, .forbidden, "log in to make changes");
    }
}

// ---- server routes asked of a local host

test "web: the account routes do not exist in local mode" {
    var local = try h.Local(.xit).init();
    defer local.deinit();
    var browser = local.client();
    defer browser.deinit();

    for ([_][]const u8{
        "/user/login",
        "/user/logout",
        "/user/settings/user",
        "/user/keys/addkey",
        "/user/keys/key:SHA256%3A8wligOakas02tWoqup%2B5u9f%2ByfYeK5dIgSHRhyrb9mw/removekey/removekey",
        "/user/delete/delete",
    }) |path| {
        const r = try browser.post(path, &.{ .{ "username", "tester" }, .{ "password", "x" } });
        defer r.deinit();
        try expectRefused(r, .method_not_allowed, "method not allowed");
    }
    // local mode's "new" route claims the sign-up url and finds no thread list in it
    const signup = try signUp(&browser, "/user/new", "erin", "erin@example.test", "pw-one", "pw-one");
    defer signup.deinit();
    try expectRefused(signup, .not_found, "new event target not found");
}
