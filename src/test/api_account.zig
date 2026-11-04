const std = @import("std");
const api = @import("../api.zig");
const account = @import("../api/account.zig");
const ui = @import("../ui.zig");

fn expectInvalid(result: anytype, code: api.ErrorCode, fields: []const []const u8) !void {
    switch (result) {
        .ok => return error.TestExpectedInvalid,
        .invalid => |err| {
            try std.testing.expectEqual(code, err.code);
            try std.testing.expect(err.message.len > 0);
            try std.testing.expectEqual(fields.len, err.field_errors.len);
            for (fields, err.field_errors) |expected, actual| {
                try std.testing.expectEqualStrings(expected, actual.field);
                try std.testing.expect(actual.message.len > 0);
            }
        },
    }
}

test "the account routes are matched under /api/v1/account" {
    try std.testing.expectEqual(account.Route.account, account.route("/api/v1/account").?);
    try std.testing.expectEqual(account.Route.email, account.route("/api/v1/account/email").?);
    try std.testing.expectEqual(account.Route.password, account.route("/api/v1/account/password").?);
    try std.testing.expectEqual(account.Route.keys, account.route("/api/v1/account/keys").?);
    try std.testing.expectEqualStrings("SHA256%3Aabc%2Fdef", account.route("/api/v1/account/keys/SHA256%3Aabc%2Fdef").?.key);
    try std.testing.expectEqual(null, account.route("/api/v1/account/keys/"));
    try std.testing.expectEqual(null, account.route("/api/v1/account/keys/a/b"));
    try std.testing.expectEqual(null, account.route("/api/v1/accounts"));
    try std.testing.expectEqual(null, account.route("/api/v1/account/"));
}

test "a registration reads its fields from a JSON object, treating missing ones as empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try account.parseBody(account.Registration, arena.allocator(), "application/json",
        \\{"name":"carol","email":"carol@example.test","password":"pw"}
    );
    try std.testing.expectEqualStrings("carol", result.ok.name);
    try std.testing.expectEqualStrings("carol@example.test", result.ok.email);
    try std.testing.expectEqualStrings("pw", result.ok.password);
    try std.testing.expectEqualStrings("", result.ok.password_again);
}

test "a request body that isn't a JSON object of strings is a validation error without field errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    try expectInvalid(try account.parseBody(account.Registration, aa, "application/json", "nope"), .validation, &.{});
    try expectInvalid(try account.parseBody(account.Registration, aa, "application/json", "[]"), .validation, &.{});
    try expectInvalid(try account.parseBody(account.Registration, aa, "application/json",
        \\{"name":1}
    ), .validation, &.{});
    // a form post, which any page can send, is refused
    try expectInvalid(try account.parseBody(account.Registration, aa, "application/x-www-form-urlencoded", "name=carol"), .validation, &.{});
}

test "each registration failure names the field the shared rules rejected" {
    const cases = [_]struct { ui.Session.FormFeedback.UserFailure, api.ErrorCode, []const u8 }{
        .{ .required_name, .validation, "name" },
        .{ .invalid_name, .validation, "name" },
        .{ .name_taken, .conflict, "name" },
        .{ .required_email, .validation, "email" },
        .{ .email_taken, .conflict, "email" },
        .{ .required_password, .validation, "password" },
        .{ .password_mismatch, .validation, "password_again" },
    };
    for (cases) |case| {
        const failure, const code, const field = case;
        const err = account.registrationError(failure);
        try std.testing.expectEqual(code, err.code);
        try std.testing.expectEqual(1, err.field_errors.len);
        try std.testing.expectEqualStrings(field, err.field_errors[0].field);
        try std.testing.expect(err.field_errors[0].message.len > 0);
    }
}

test "each settings failure names the field the shared rules rejected" {
    const cases = [_]struct { ui.Session.FormFeedback.UserFailure, api.ErrorCode, []const u8 }{
        .{ .required_email, .validation, "email" },
        .{ .email_taken, .conflict, "email" },
        .{ .wrong_password, .validation, "current_password" },
        .{ .required_password, .validation, "new_password" },
        .{ .password_mismatch, .validation, "new_password_again" },
    };
    for (cases) |case| {
        const failure, const code, const field = case;
        const err = account.settingsError(failure);
        try std.testing.expectEqual(code, err.code);
        try std.testing.expectEqual(1, err.field_errors.len);
        try std.testing.expectEqualStrings(field, err.field_errors[0].field);
        try std.testing.expect(err.field_errors[0].message.len > 0);
    }
}

test "a password change without the current password names that field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const parsed = try account.parseBody(account.PasswordChange, arena.allocator(), "application/json",
        \\{"new_password":"n","new_password_again":"n"}
    );
    const err = account.passwordChangeMissing(parsed.ok).?;
    try std.testing.expectEqual(api.ErrorCode.validation, err.code);
    try std.testing.expectEqualStrings("current_password", err.field_errors[0].field);
    const complete: account.PasswordChange = .{ .current_password = "c", .new_password = "", .new_password_again = "" };
    // the shared rules judge the rest
    try std.testing.expectEqual(null, account.passwordChangeMissing(complete));
}

test "each ssh key failure is reported beside the key field" {
    const cases = [_]struct { ui.Session.FormFeedback.KeyFailure, api.ErrorCode, []const u8 }{
        .{ .invalid, .validation, "OpenSSH public key" },
        .{ .unsupported, .validation, "ssh-ed25519, ssh-rsa, ecdsa-sha2-nistp256 and ecdsa-sha2-nistp384" },
        .{ .already_added, .conflict, "already added" },
        .{ .too_many, .validation, "at most 50" },
    };
    for (cases) |case| {
        const failure, const code, const words = case;
        const err = account.keyError(failure);
        try std.testing.expectEqual(code, err.code);
        try std.testing.expectEqual(1, err.field_errors.len);
        try std.testing.expectEqualStrings("key", err.field_errors[0].field);
        try std.testing.expect(std.mem.indexOf(u8, err.field_errors[0].message, words) != null);
    }
}

fn expectKeysJson(expected: []const u8, ssh_keys: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try account.writeKeys(&out.writer, try ui.UserKeys.parseKeys(arena.allocator(), ssh_keys));
    try std.testing.expectEqualStrings(expected, out.written());
}

test "ssh keys are listed with their type, comment and fingerprint, skipping unreadable lines" {
    // "AAAA" decodes to three zero bytes
    try expectKeysJson(
        \\{"items":[{"fingerprint":"SHA256:cJ6AyISHokEeHuTfufIqhhSS0gxHZRUMDHlKvXD4FHw","type":"ssh-ed25519","comment":"me@laptop","key":"ssh-ed25519 AAAA me@laptop"},{"fingerprint":"SHA256:cJ6AyISHokEeHuTfufIqhhSS0gxHZRUMDHlKvXD4FHw","type":"ssh-rsa","comment":null,"key":"ssh-rsa AAAA"}],"page":{"has_more":false,"next_cursor":null,"count":{"kind":"exact","value":2}}}
    , "ssh-ed25519 AAAA me@laptop\nnot a key!\nssh-rsa AAAA");
}

test "each account deletion failure is reported beside its field" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const wrong_confirm = try account.deletionError(arena.allocator(), .wrong_confirm, "alice");
    try std.testing.expectEqual(api.ErrorCode.validation, wrong_confirm.code);
    try std.testing.expectEqualStrings("confirm", wrong_confirm.field_errors[0].field);
    // the message says what to type
    try std.testing.expect(std.mem.indexOf(u8, wrong_confirm.field_errors[0].message, "alice") != null);
    const wrong_password = try account.deletionError(arena.allocator(), .wrong_password, "alice");
    try std.testing.expectEqual(api.ErrorCode.validation, wrong_password.code);
    try std.testing.expectEqualStrings("password", wrong_password.field_errors[0].field);
}

test "an account change naming a viewer is refused for anyone else, and one naming nobody proceeds" {
    // optional: a non-browser client needn't name the viewer
    try std.testing.expectEqual(null, account.checkViewer(null, "alice"));
    // another viewer signed in since the form loaded (e.g. in another tab)
    const switched = account.checkViewer("alice", "bobby").?;
    try std.testing.expectEqual(api.ErrorCode.conflict, switched.code);
    try std.testing.expectEqual(0, switched.field_errors.len);
    try std.testing.expectEqual(null, account.checkViewer("alice", "alice"));
}

test "a password change leaves an email changed meanwhile alone" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    const evt = @import("../event.zig");
    const xit = @import("xit");
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const base = try temp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const admin_path = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "admin" });
    const users_dir = try std.Io.Dir.path.join(arena.allocator(), &.{ base, "users" });
    var admin = try xit.repo.Repo(.xit, evt.admin_repo_opts).init(io, allocator, .{ .path = admin_path });
    defer admin.deinit(io, allocator);

    const id = try evt.createUser(io, allocator, users_dir, &admin, "alice", "alice@example.test", "old", "old");
    // an email change lands while a password change is in flight
    try evt.updateUser(io, allocator, users_dir, &admin, &id, "alice@new.example.test", "", "", "");
    // the password change names no email, so it keeps the stored one
    try evt.updateUser(io, allocator, users_dir, &admin, &id, null, "old", "new", "new");

    const user = (try ui.activeUser(try evt.currentMoment(evt.admin_repo_opts, &admin), &arena, id)).?;
    try std.testing.expectEqualStrings("alice@new.example.test", user.event.email);
    try std.testing.expect(evt.User.verifyPassword(user.event.password_hash, "new"));
}
