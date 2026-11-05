const std = @import("std");
const api_undo = @import("../api/undo.zig");

test "undo routes name a repo's history, or its window from one transaction, on a server or the local repo" {
    const history = api_undo.route("/api/v1/repos/bobby/linux/undo").?;
    try std.testing.expectEqualStrings("bobby", history.target.server.owner);
    try std.testing.expectEqualStrings("linux", history.target.server.name);
    try std.testing.expectEqual(null, history.transaction);
    try std.testing.expectEqualStrings("12", api_undo.route("/api/v1/repos/bobby/linux/undo/12").?.transaction.?);
    // names stay encoded until the handler decodes them
    try std.testing.expectEqualStrings("a%20b", api_undo.route("/api/v1/repos/a%20b/c/undo").?.target.server.owner);

    const local = api_undo.route("/api/v1/repo/undo").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(local.target));
    try std.testing.expectEqualStrings("abc", api_undo.route("/api/v1/repo/undo/abc").?.transaction.?);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux",
        "/api/v1/repos/bobby/linux/undo/",
        "/api/v1/repos/bobby/linux/undo/1/2",
        "/api/v1/repos/bobby/linux/undox",
        "/api/v1/repos//linux/undo",
        "/api/v1/repos/bobby/undo",
        "/api/v1/repo/undo/",
        "/api/v1/repo",
    }) |path| {
        try std.testing.expectEqual(null, api_undo.route(path));
    }
}

test "an undo request names a transaction in canonical decimal and the history's revision in hex" {
    const revision = "000102030405060708090a0b0c0d0e0f";
    const ok = api_undo.readExecution(.{ .transaction = "3", .revision = revision }).ok;
    try std.testing.expectEqual(3, ok.transaction);
    try std.testing.expectEqual(15, ok.revision[15]);
    for ([_][]const u8{ "", "03", "-1", "x", "18446744073709551616" }) |text| {
        const refused = api_undo.readExecution(.{ .transaction = text, .revision = revision }).invalid;
        try std.testing.expectEqual(.validation, refused.code);
        try std.testing.expectEqualStrings("transaction", refused.field_errors[0].field);
    }
    // a revision is no number, so no id a client sends is ever added to
    for ([_][]const u8{ "", "12", "18446744073709551615", revision ++ "00", "zz0102030405060708090a0b0c0d0e0f" }) |text| {
        const refused = api_undo.readExecution(.{ .transaction = "3", .revision = text }).invalid;
        try std.testing.expectEqualStrings("revision", refused.field_errors[0].field);
    }
}
