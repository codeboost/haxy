const std = @import("std");
const api = @import("../api.zig");
const repo_create = @import("../api/repo_create.zig");
const ui = @import("../ui.zig");

fn request(overrides: anytype) repo_create.Request {
    var value: repo_create.Request = .{ .name = "tools", .description = "", .access = "private", .hash = "sha1", .copy = "" };
    inline for (@typeInfo(@TypeOf(overrides)).@"struct".field_names) |name| @field(value, name) = @field(overrides, name);
    return value;
}

fn expectRefused(result: repo_create.ReadFields, code: api.ErrorCode, field: []const u8) !void {
    switch (result) {
        .ok => return error.TestExpectedRefusal,
        .invalid => |err| {
            try std.testing.expectEqual(code, err.code);
            try std.testing.expectEqual(1, err.field_errors.len);
            try std.testing.expectEqualStrings(field, err.field_errors[0].field);
            try std.testing.expect(err.field_errors[0].message.len > 0);
        },
    }
}

test "repo creation is routed at /api/v1/repos only" {
    try std.testing.expect(repo_create.route("/api/v1/repos"));
    for ([_][]const u8{ "/api/v1/repos/", "/api/v1/repos/bobby", "/api/v1/repos/bobby/linux", "/api/v1/repo", "/api/v1/repositories" }) |path| {
        try std.testing.expect(!repo_create.route(path));
    }
}

test "a request names the new repo's visibility and hash format by their TUI names" {
    const fields = repo_create.readFields(request(.{ .name = "tools", .description = "Handy", .access = "public", .hash = "sha256" })).ok;
    try std.testing.expectEqualStrings("tools", fields.name);
    try std.testing.expectEqualStrings("Handy", fields.description);
    try std.testing.expectEqual(.public, fields.access);
    try std.testing.expectEqual(.sha256, fields.hash);
    try std.testing.expectEqualStrings("", fields.copy);
    try std.testing.expectEqual(.sha1, repo_create.readFields(request(.{ .hash = "sha1" })).ok.hash);
    try std.testing.expectEqual(.private, repo_create.readFields(request(.{ .access = "private" })).ok.access);
}

test "an unknown or missing visibility or hash format is refused beside its field" {
    try expectRefused(repo_create.readFields(request(.{ .access = "" })), .validation, "access");
    try expectRefused(repo_create.readFields(request(.{ .access = "internal" })), .validation, "access");
    try expectRefused(repo_create.readFields(request(.{ .hash = "" })), .validation, "hash");
    try expectRefused(repo_create.readFields(request(.{ .hash = "md5" })), .validation, "hash");
    try expectRefused(repo_create.readFields(request(.{ .hash = "SHA1" })), .validation, "hash");
}

test "a copy keeps its source's hash format, so it names none" {
    const fields = repo_create.readFields(request(.{ .hash = "", .copy = "bobby:linux" })).ok;
    try std.testing.expectEqualStrings("bobby:linux", fields.copy);
    try expectRefused(repo_create.readFields(request(.{ .hash = "sha256", .copy = "bobby:linux" })), .validation, "hash");
}

test "a copy source that isn't owner:name is refused beside the copy field" {
    for ([_][]const u8{ "linux", "bobby/linux", ":linux", "bobby:", "a:b:c" }) |copy| {
        try expectRefused(repo_create.readFields(request(.{ .hash = "", .copy = copy })), .validation, "copy");
    }
}

test "each refusal of the shared rules names its field, and an unseen copy source is just not found" {
    const cases = [_]struct { ui.Session.FormFeedback.RepoFailure, api.ErrorCode, []const u8 }{
        .{ .required_name, .validation, "name" },
        .{ .invalid_name, .validation, "name" },
        .{ .name_taken, .conflict, "name" },
        .{ .invalid_copy, .not_found, "copy" },
    };
    for (cases) |case| {
        const failure, const code, const field = case;
        const err = repo_create.createError(failure);
        try std.testing.expectEqual(code, err.code);
        try std.testing.expectEqual(1, err.field_errors.len);
        try std.testing.expectEqualStrings(field, err.field_errors[0].field);
        try std.testing.expect(err.field_errors[0].message.len > 0);
    }
}
