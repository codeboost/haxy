const std = @import("std");
const api = @import("../api.zig");
const evt = @import("../event.zig");
const api_thread = @import("../api/thread.zig");
const query_params = @import("../api/query.zig");
const ui = @import("../ui.zig");

test "thread routes name a kind's list, its labels or one thread, on a server or the local repo" {
    const list = api_thread.route("/api/v1/repos/bobby/linux/issues", "issues").?;
    try std.testing.expectEqualStrings("bobby", list.target.server.owner);
    try std.testing.expectEqualStrings("linux", list.target.server.name);
    try std.testing.expectEqual(.list, std.meta.activeTag(list.resource));
    try std.testing.expectEqual(.labels, std.meta.activeTag(api_thread.route("/api/v1/repos/bobby/linux/issues/labels", "issues").?.resource));
    const one = api_thread.route("/api/v1/repos/bobby/linux/issues/0123456789abcdef0123456789abcdef", "issues").?;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", one.resource.thread);
    // names stay encoded until the handler decodes them
    try std.testing.expectEqualStrings("a%20b", api_thread.route("/api/v1/repos/a%20b/c/issues", "issues").?.target.server.owner);

    try std.testing.expectEqual(.local, std.meta.activeTag(api_thread.route("/api/v1/repo/issues", "issues").?.target));
    try std.testing.expectEqual(.labels, std.meta.activeTag(api_thread.route("/api/v1/repo/issues/labels", "issues").?.resource));
    try std.testing.expectEqualStrings("abc", api_thread.route("/api/v1/repo/issues/abc", "issues").?.resource.thread);

    for ([_][]const u8{
        "/api/v1/repos/bobby/linux",
        "/api/v1/repos/bobby/linux/files",
        "/api/v1/repos/bobby/linux/issues/",
        "/api/v1/repos/bobby/linux/issues/abc/comments/",
        "/api/v1/repos/bobby/linux/issues/abc/comments/x/y",
        "/api/v1/repos/bobby/linux/issues//comments",
        "/api/v1/repos/bobby/linux/issues/labels/comments",
        "/api/v1/repos/bobby/linux/issues/abc/replies",
        "/api/v1/repos/bobby/linux/issuesx",
        "/api/v1/repos//linux/issues",
        "/api/v1/repos/bobby/issues",
        "/api/v1/repo/issues/",
        "/api/v1/repo/patches",
        "/api/v1/repo",
    }) |path| {
        try std.testing.expectEqual(null, api_thread.route(path, "issues"));
    }
}

test "comment routes name a thread's comments, or one comment in it" {
    const all = api_thread.route("/api/v1/repos/bobby/linux/issues/0123/comments", "issues").?;
    try std.testing.expectEqualStrings("0123", all.resource.comments);
    const one = api_thread.route("/api/v1/repo/issues/0123/comments/4567", "issues").?;
    try std.testing.expectEqual(.local, std.meta.activeTag(one.target));
    try std.testing.expectEqualStrings("0123", one.resource.comment.thread);
    try std.testing.expectEqualStrings("4567", one.resource.comment.comment);
}

test "an instant is written as an RFC 3339 UTC string with whole seconds" {
    var buffer: [api.Instant.max_len]u8 = undefined;
    try std.testing.expectEqualStrings("1970-01-01T00:00:00Z", api.Instant.format(&buffer, 0));
    try std.testing.expectEqualStrings("2026-11-04T14:03:00Z", api.Instant.format(&buffer, 1793800980));
    try std.testing.expectEqualStrings("2024-02-29T23:59:59Z", api.Instant.format(&buffer, 1709251199));
    // a commit may claim any time; years stay four digits
    try std.testing.expectEqualStrings("9999-12-31T23:59:59Z", api.Instant.format(&buffer, std.math.maxInt(u64)));

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(.{ .created_at = api.Instant{ .seconds = 1793800980 } }, .{}, &out.writer);
    try std.testing.expectEqualStrings("{\"created_at\":\"2026-11-04T14:03:00Z\"}", out.written());
}

test "a thread listing's count is exact unless a search stopped counting at its cap" {
    try std.testing.expectEqual(api.Count{ .exact = 22 }, api_thread.count(ui.Repo.Issues.Window{ .items = &.{}, .prev_id = null, .next_id = null, .count = 22 }));
    try std.testing.expectEqual(api.Count{ .at_least = 1000 }, api_thread.count(ui.Repo.Issues.Window{ .items = &.{}, .prev_id = null, .next_id = null, .count = 1000, .more = true }));
}

test "page_size alone is a positive whole number, lowered to the route's maximum" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const limits: query_params.Page.Limits = .{ .default = 20, .max = 100 };

    try std.testing.expectEqual(20, (try query_params.pageSize(aa, "cursor=abc", limits)).ok);
    try std.testing.expectEqual(5, (try query_params.pageSize(aa, "page_size=5", limits)).ok);
    try std.testing.expectEqual(100, (try query_params.pageSize(aa, "page_size=1000", limits)).ok);
    for ([_][]const u8{ "page_size=0", "page_size=-1", "page_size=ten", "page_size=", "page_size=%zz" }) |query| {
        const err = (try query_params.pageSize(aa, query, limits)).invalid;
        try std.testing.expectEqual(.validation, err.code);
        try std.testing.expectEqualStrings("page_size", err.field_errors[0].field);
    }
}

test "label and assignee links replace the search's own filter of that kind and keep the rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const labels = try api_thread.labelLinks(aa, "bug  ui", "label:docs crash assignee:alice");
    try std.testing.expectEqual(2, labels.len);
    try std.testing.expectEqualStrings("bug", labels[0].name);
    try std.testing.expectEqualStrings("label:bug crash assignee:alice", labels[0].search);
    try std.testing.expectEqualStrings("label:ui crash assignee:alice", labels[1].search);

    // an assignee no account holds is shown, and filtered, by email alone;
    // each names its assignment, which unassigns them
    const thread_id: [evt.event_id_size]u8 = @splat(3);
    const assignees = try api_thread.assigneeLinks(aa, &thread_id, &.{ .{ .email = "alice@example.test", .name = "alice" }, .{ .email = "x@example.test" } }, "");
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(evt.Assignment.idOf(&thread_id, "alice@example.test"), .lower), &assignees[0].id);
    try std.testing.expectEqualStrings(&std.fmt.bytesToHex(evt.Assignment.idOf(&thread_id, "x@example.test"), .lower), &assignees[1].id);
    try std.testing.expectEqualStrings("alice", assignees[0].name.?);
    try std.testing.expectEqual(null, assignees[0].email);
    try std.testing.expectEqualStrings("assignee:alice", assignees[0].search);
    try std.testing.expectEqual(null, assignees[1].name);
    try std.testing.expectEqualStrings("x@example.test", assignees[1].email.?);
    try std.testing.expectEqualStrings("assignee:x@example.test", assignees[1].search);
}

test "a search's filters are split by haxy's own parser" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const filters = try api_thread.Filters.init(arena.allocator(), "  crash label:bug assignee:alice label: tab  ", false);
    try std.testing.expectEqual(1, filters.labels.len);
    try std.testing.expectEqualStrings("bug", filters.labels[0]);
    try std.testing.expectEqualStrings("alice", filters.assignees[0]);
    try std.testing.expectEqualStrings("crash tab", filters.words);
}

test "a thread's status is its own route under the thread; nothing else follows a thread" {
    const status = api_thread.route("/api/v1/repos/bobby/linux/issues/0123456789abcdef0123456789abcdef/status", "issues").?;
    try std.testing.expectEqualStrings("0123456789abcdef0123456789abcdef", status.resource.status);
    try std.testing.expectEqualStrings("abc", api_thread.route("/api/v1/repo/issues/abc/status", "issues").?.resource.status);
    for ([_][]const u8{
        "/api/v1/repos/bobby/linux/issues/abc/status/",
        "/api/v1/repos/bobby/linux/issues/abc/edit",
        "/api/v1/repos/bobby/linux/issues//status",
        "/api/v1/repos/bobby/linux/issues/labels/status",
    }) |path| {
        try std.testing.expectEqual(null, api_thread.route(path, "issues"));
    }
}

fn expectJson(expected: []const u8, value: anytype) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    try std.testing.expectEqualStrings(expected, out.written());
}

test "what a viewer may do with a kind's threads follows the TUI's rules, with a reason when they may not" {
    // anyone who may write in the tab may open a thread
    try expectJson("{\"create\":{\"available\":true}}", api_thread.listActions(.issue, .{ .may_write = true, .signed_in = true }));
    try expectJson("{\"create\":{\"available\":false,\"reason\":{\"code\":\"unauthenticated\",\"message\":\"Log in to open an issue.\"}}}", api_thread.listActions(.issue, .{ .may_write = false, .signed_in = false }));
    try expectJson("{\"create\":{\"available\":false,\"reason\":{\"code\":\"forbidden\",\"message\":\"Your role in this repository doesn't allow opening issues.\"}}}", api_thread.listActions(.issue, .{ .may_write = false, .signed_in = true }));

    // changing one, or who is assigned to it, takes its author or a writer
    try expectJson("{\"edit\":{\"available\":true},\"set_status\":{\"available\":true},\"remove\":{\"available\":true},\"assign\":{\"available\":true},\"attach\":{\"available\":true}}", api_thread.threadActions(.issue, .{ .may_write = true, .signed_in = true }));
    const refused = api_thread.threadActions(.issue, .{ .may_write = false, .signed_in = true });
    try expectJson("{\"available\":false,\"reason\":{\"code\":\"forbidden\",\"message\":\"Only the issue's author and the repository's writers can change it.\"}}", refused.edit);
    try expectJson("{\"available\":false,\"reason\":{\"code\":\"unauthenticated\",\"message\":\"Log in to change this issue.\"}}", api_thread.threadActions(.issue, .{ .may_write = false, .signed_in = false }).remove);
    try expectJson("{\"available\":false,\"reason\":{\"code\":\"forbidden\",\"message\":\"Only the issue's author and the repository's writers can assign people to it.\"}}", refused.assign);
    try expectJson("{\"available\":false,\"reason\":{\"code\":\"forbidden\",\"message\":\"Only the issue's author and the repository's writers can attach files to it.\"}}", refused.attach);
}

test "a write names a thread's fields; an id or revision it sends must be one haxy could have given out" {
    try std.testing.expectEqual(null, api_thread.parseNewId("").?);
    const id = api_thread.parseNewId("0123456789abcdef0123456789abcdef").?.?;
    try std.testing.expectEqual(0x01, id[0]);
    try std.testing.expectEqual(0xef, id[15]);
    for ([_][]const u8{ "0123", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdeg", "0123456789abcdef0123456789abcdef0" }) |text| {
        try std.testing.expectEqual(null, api_thread.parseNewId(text));
    }

    // a revision is as an issue's answer writes it: its fields' digest, in hex
    const revision = evt.Issue.contentRevision(.{ .title = "Crash", .labels = "bug", .description = "" });
    const written = std.fmt.bytesToHex(revision, .lower);
    try std.testing.expectEqualSlices(u8, &revision, &api_thread.parseRevision(&written).?);
    for ([_][]const u8{ "", "42", "x", "0123456789ABCDEF0123456789ABCDEF", "0123456789abcdef0123456789abcdef0" }) |text| {
        try std.testing.expectEqual(null, api_thread.parseRevision(text));
    }
    // it moves with any field an edit replaces, never with the status
    try std.testing.expect(!std.mem.eql(u8, &revision, &evt.Issue.contentRevision(.{ .title = "Crash", .labels = "bug ui", .description = "" })));
    try std.testing.expect(!std.mem.eql(u8, &evt.Issue.contentRevision(.{ .title = "ab", .labels = "", .description = "c" }), &evt.Issue.contentRevision(.{ .title = "a", .labels = "", .description = "bc" })));
    try std.testing.expectEqualSlices(u8, &revision, &evt.Issue.contentRevision(.{ .title = "Crash", .labels = "bug", .description = "", .status = .closed }));

    // the shared field rules, reported beside the field
    try std.testing.expectEqualStrings("title", api_thread.fieldsError(.required_title).field_errors[0].field);
    try std.testing.expectEqualStrings("labels", api_thread.fieldsError(.invalid_labels).field_errors[0].field);
    try std.testing.expectEqual(.validation, api_thread.fieldsError(.invalid_labels).code);
}
