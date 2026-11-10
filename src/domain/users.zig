//! account operations: registering, settings, ssh keys and deletion. all are
//! server only; local mode has no accounts.

const std = @import("std");
const evt = @import("../event.zig");
const domain = @import("../domain.zig");

pub const RegisterUser = struct {
    pub const tool_name = "register_user";
    pub const hosts = domain.server_only;
    pub const tool_description = "Create an account. Only for a caller who is logged out. Server only.";
    pub const tool_schema_notes = .{
        .name = "The new account's name.",
        .email = "The new account's email.",
        .password = "The new account's password.",
        .password_again = "The password again, to confirm.",
    };

    name: []const u8,
    email: []const u8,
    password: []const u8,
    password_again: []const u8,

    pub const Result = struct {
        id: [evt.event_id_size]u8,
    };

    pub fn run(self: RegisterUser, ctx: *domain.Ctx) !Result {
        const server = try serverHost(ctx);
        // an account is made by someone without one; a removed account's
        // context has no user, so it may
        if (ctx.user_id != null) return error.Forbidden;
        const admin = ctx.admin orelse unreachable;
        return .{ .id = try evt.createUser(ctx.io, ctx.gpa, server.users_dir, admin, self.name, self.email, self.password, self.password_again) };
    }
};

// the server the context runs on. local mode has no accounts.
fn serverHost(ctx: *domain.Ctx) !domain.Host.Server {
    return switch (ctx.host) {
        .server => |server| server,
        .local => error.UnavailableHere,
    };
}

pub const UpdateUserSettings = struct {
    pub const tool_name = "update_user_settings";
    pub const hosts = domain.server_only;
    pub const tool_description = "Change the acting user's email, and their password when the password fields are filled in. Server only.";
    pub const tool_schema_notes = .{
        .email = "The account's email, new or unchanged.",
        .current_password = "The account's password, needed to change it; \"\" to keep it.",
        .new_password = "The new password; \"\" to keep it.",
        .new_password_again = "The new password again, to confirm.",
    };

    email: []const u8,
    current_password: []const u8 = "",
    new_password: []const u8 = "",
    new_password_again: []const u8 = "",

    pub fn run(self: UpdateUserSettings, ctx: *domain.Ctx) !void {
        const server = try serverHost(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const admin = ctx.admin orelse unreachable;
        evt.updateUser(ctx.io, ctx.gpa, server.users_dir, admin, &user_id, self.email, self.current_password, self.new_password, self.new_password_again) catch |err| return switch (err) {
            // removed since the context checked it
            error.NotFound => error.LoginRequired,
            else => err,
        };
    }
};

pub const AddKey = struct {
    pub const tool_name = "add_key";
    pub const hosts = domain.server_only;
    pub const tool_description = "Add an ssh public key to the acting user's keys, for pushing and logging in over ssh. Server only.";
    pub const tool_schema_notes = .{
        .key = "One authorized_keys line: the key type, the base64 key and an optional comment.",
    };

    // an authorized_keys line
    key: []const u8,

    pub fn run(self: AddKey, ctx: *domain.Ctx) !void {
        const server = try serverHost(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const admin = ctx.admin orelse unreachable;
        evt.addUserKey(ctx.io, ctx.gpa, server.users_dir, admin, &user_id, self.key) catch |err| return switch (err) {
            // removed since the context checked it
            error.NotFound => error.LoginRequired,
            else => err,
        };
    }
};

pub const RemoveKey = struct {
    pub const tool_name = "remove_key";
    pub const hosts = domain.server_only;
    pub const tool_description = "Remove one of the acting user's ssh keys. Server only.";
    pub const tool_schema_notes = .{
        .fingerprint = "The key's fingerprint, as \"SHA256:\" and its base64 hash.",
    };

    fingerprint: []const u8,

    pub fn run(self: RemoveKey, ctx: *domain.Ctx) !void {
        const server = try serverHost(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const admin = ctx.admin orelse unreachable;
        if (self.fingerprint.len != evt.User.fingerprint_len) return error.NotFound;
        const fingerprint = self.fingerprint[0..evt.User.fingerprint_len];
        // the event module writes nothing for a key the user doesn't hold;
        // say so rather than report a removal. the keys are read as they are
        // now, not as the context loaded them.
        var arena = std.heap.ArenaAllocator.init(ctx.gpa);
        defer arena.deinit();
        const user = (try domain.activeUser(try evt.currentMoment(evt.admin_repo_opts, admin), &arena, user_id)) orelse return error.LoginRequired;
        var keys = std.mem.splitScalar(u8, user.event.ssh_keys, '\n');
        while (keys.next()) |line| {
            const held = evt.User.fingerprintOfKey(line) orelse continue;
            if (std.mem.eql(u8, &held, fingerprint)) break;
        } else return error.NotFound;
        evt.removeUserKey(ctx.io, ctx.gpa, server.users_dir, admin, &user_id, fingerprint) catch |err| return switch (err) {
            // removed since the context checked it
            error.NotFound => error.LoginRequired,
            else => err,
        };
    }
};

pub const DeleteUser = struct {
    pub const tool_name = "delete_user";
    pub const hosts = domain.server_only;
    pub const tool_description = "Permanently delete the acting user's account with every repository and fork it owns. Server only.";
    pub const tool_schema_notes = .{
        .confirm = "The account's name, to confirm.",
        .password = "The account's password.",
    };

    // the text typed to confirm, which must be the acting user's name
    confirm: []const u8,
    password: []const u8,

    pub fn run(self: DeleteUser, ctx: *domain.Ctx) !void {
        _ = try serverHost(ctx);
        // the password as it is now, which may have changed since the context was built
        const user = try domain.currentUser(ctx);
        // the typed text is checked before the slow password check
        if (!std.mem.eql(u8, self.confirm, user.event.name)) return error.WrongConfirm;
        if (!evt.User.verifyPassword(user.event.password_hash, self.password)) return error.WrongPassword;
        try deleteAsOperator(ctx);
    }

    // delete the context's acting user without their confirmation or
    // password. operator only: `haxy delete-user` holds the data dir already.
    // no decoded input reaches it except through `run`, which checks both.
    pub fn deleteAsOperator(ctx: *domain.Ctx) !void {
        const server = try serverHost(ctx);
        const user_id = ctx.user_id orelse return error.LoginRequired;
        const user = ctx.user orelse unreachable;
        const admin = ctx.admin orelse unreachable;
        try evt.deleteUser(ctx.io, ctx.gpa, server.users_dir, admin, &user_id, .{ .name = user.event.name, .email = user.event.email });
    }
};
