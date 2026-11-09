//! the mcp server through its public seams: json-rpc lines in, json-rpc lines
//! out. expected replies are hand-written json, compared structurally.

const std = @import("std");
const hx = @import("../lib.zig");
const mcp = hx.mcp;
const fixture = @import("domain/fixture.zig");

comptime {
    _ = @import("mcp/cli.zig");
    _ = @import("mcp/stdio.zig");
}

const io = std.testing.io;
const allocator = std.testing.allocator;

// the reply `server` writes for `line`, which the caller frees
fn reply(server: *mcp.Server, line: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try server.handle(line, &out.writer);
    return try out.toOwnedSlice();
}

// `actual` holds exactly one json-rpc message, a line ending in "\n", equal
// to `expected` as json values (key order and spacing don't matter)
fn expectJsonLine(expected: []const u8, actual: []const u8) !void {
    if (actual.len == 0 or actual[actual.len - 1] != '\n' or std.mem.indexOfScalar(u8, actual, '\n') != actual.len - 1) {
        std.debug.print("expected one line, got: {s}\n", .{actual});
        return error.TestExpectedOneLine;
    }
    try expectJson(expected, actual[0 .. actual.len - 1]);
}

fn expectJson(expected: []const u8, actual: []const u8) !void {
    const want = try std.json.parseFromSlice(std.json.Value, allocator, expected, .{});
    defer want.deinit();
    const got = std.json.parseFromSlice(std.json.Value, allocator, actual, .{}) catch |err| {
        std.debug.print("not json: {s}\n", .{actual});
        return err;
    };
    defer got.deinit();
    if (!jsonEql(want.value, got.value)) {
        std.debug.print("expected: {s}\nactual:   {s}\n", .{ expected, actual });
        return error.TestExpectedEqual;
    }
}

fn jsonEql(a: std.json.Value, b: std.json.Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .bool => |x| x == b.bool,
        .integer => |x| x == b.integer,
        .float => |x| x == b.float,
        .number_string => |x| std.mem.eql(u8, x, b.number_string),
        .string => |x| std.mem.eql(u8, x, b.string),
        .array => |x| blk: {
            if (x.items.len != b.array.items.len) break :blk false;
            for (x.items, b.array.items) |l, r| if (!jsonEql(l, r)) break :blk false;
            break :blk true;
        },
        .object => |x| blk: {
            if (x.count() != b.object.count()) break :blk false;
            var it = x.iterator();
            while (it.next()) |kv| {
                const other = b.object.get(kv.key_ptr.*) orelse break :blk false;
                if (!jsonEql(kv.value_ptr.*, other)) break :blk false;
            }
            break :blk true;
        },
    };
}

test "mcp: initialize answers with the requested supported version and the tools capability" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"haxy","version":"0.0.0"}}}
    , out);
}

test "mcp: initialize answers an unsupported version with the newest supported one" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":"init","result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"haxy","version":"0.0.0"}}}
    , out);
}

test "mcp: ping answers an empty result" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":7,"method":"ping"}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":7,"result":{}}
    , out);
}

test "mcp: the initialized notification gets no reply" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    );
    defer allocator.free(out);
    try std.testing.expectEqualStrings("", out);
}

test "mcp: an unknown method is method not found" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":3,"method":"resources/list"}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":3,"error":{"code":-32601,"message":"method not found: resources/list"}}
    , out);
}

test "mcp: a batch array is an invalid request" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\[{"jsonrpc":"2.0","id":1,"method":"ping"},{"jsonrpc":"2.0","id":2,"method":"ping"}]
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"invalid request"}}
    , out);
}

test "mcp: a line that isn't json is a parse error and one without a version or method is an invalid request" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    {
        const out = try reply(&server, "{\"jsonrpc\":\"2.0\",\"id\":1,");
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"parse error"}}
        , out);
    }
    for ([_][]const u8{
        \\{"id":4,"method":"ping"}
        ,
        \\{"jsonrpc":"1.0","id":4,"method":"ping"}
        ,
        \\{"jsonrpc":"2.0","id":4}
        ,
        \\{"jsonrpc":"2.0","id":4,"method":5}
    }) |line| {
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":4,"error":{"code":-32600,"message":"invalid request"}}
        , out);
    }
}

// the `tools` array of a tools/list reply, for the caller to deinit
fn listTools(server: *mcp.Server) !std.json.Parsed(std.json.Value) {
    const out = try reply(server,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
    );
    defer allocator.free(out);
    return try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
}

// the entry of `tools` named `name`, as json
fn toolEntry(tools: std.json.Value, name: []const u8) ![]u8 {
    for (tools.array.items) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) {
            return try std.json.Stringify.valueAlloc(allocator, tool, .{});
        }
    }
    return error.TestExpectedTool;
}

test "mcp: tools/list names the slice's tools with schemas derived from the operations" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const parsed = try listTools(&server);
    defer parsed.deinit();
    try std.testing.expectEqualStrings("2.0", parsed.value.object.get("jsonrpc").?.string);
    try std.testing.expectEqual(2, parsed.value.object.get("id").?.integer);
    const tools = parsed.value.object.get("result").?.object.get("tools").?;

    var names: std.ArrayList(u8) = .empty;
    defer names.deinit(allocator);
    for (tools.array.items) |tool| {
        try names.appendSlice(allocator, tool.object.get("name").?.string);
        try names.append(allocator, ' ');
    }
    try std.testing.expectEqualStrings("refresh_local list_issues get_issue create_thread create_comment set_thread_status ", names.items);

    // every tool's annotations cover the whole call, which in local mode
    // refreshes the repo first, so no tool is read-only
    {
        var annotations: std.ArrayList(u8) = .empty;
        defer annotations.deinit(allocator);
        try annotations.append(allocator, '{');
        for (tools.array.items, 0..) |tool, i| {
            if (i != 0) try annotations.append(allocator, ',');
            const text = try std.json.Stringify.valueAlloc(allocator, tool.object.get("annotations").?, .{});
            defer allocator.free(text);
            try annotations.print(allocator, "\"{s}\":{s}", .{ tool.object.get("name").?.string, text });
        }
        try annotations.append(allocator, '}');
        try expectJson(
            \\{
            \\  "refresh_local": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true },
            \\  "list_issues": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true },
            \\  "get_issue": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true },
            \\  "create_thread": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false },
            \\  "create_comment": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false },
            \\  "set_thread_status": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true }
            \\}
        , annotations.items);
    }
    // a write
    {
        const entry = try toolEntry(tools, "create_thread");
        defer allocator.free(entry);
        try expectJson(
            \\{
            \\  "name": "create_thread",
            \\  "description": "Open a new issue or discussion in a repository.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "kind": { "type": "string", "enum": ["issue", "patch", "discuss"], "description": "issue or discuss; patch is not available yet." },
            \\      "title": { "type": "string", "description": "A title that isn't blank." },
            \\      "labels": { "type": "string", "description": "Space-separated labels, each at most 64 bytes." },
            \\      "body": { "type": "string", "description": "The thread's text, in markdown." }
            \\    },
            \\    "required": ["repo", "kind", "title"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false }
            \\}
        , entry);
    }
    // a read
    {
        const entry = try toolEntry(tools, "get_issue");
        defer allocator.free(entry);
        try expectJson(
            \\{
            \\  "name": "get_issue",
            \\  "description": "Read one issue of a repository with a window of its comments.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "id": { "type": "string", "description": "The issue's hex event id." },
            \\      "comments_from": { "type": "integer", "description": "The index of the first comment in the returned window of comments." }
            \\    },
            \\    "required": ["repo", "id"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true }
            \\}
        , entry);
    }
}

// an mcp server over the fixture's data, acting as `user`
fn serverMode(server: *fixture.Server, user: ?fixture.Id) mcp.Server {
    return .{ .io = io, .gpa = allocator, .mode = .{ .server = .{
        .admin_repo_path = server.admin.core.work_path,
        .users_dir = server.users_dir,
        .user_id = user,
    } } };
}

test "mcp: tools/call create_thread opens an issue get_issue reads back" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);

    const created = try reply(&server,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"it breaks","labels":"bug"}}}
    );
    defer allocator.free(created);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("id").?.string;
    try std.testing.expectEqual(32, id.len);
    {
        const expected = try std.mem.replaceOwned(u8, allocator,
            \\{"jsonrpc":"2.0","id":10,"result":{"content":[{"type":"text","text":"{\"id\":\"ID\"}"}],"structuredContent":{"id":"ID"},"isError":false}}
        , "ID", id);
        defer allocator.free(expected);
        try expectJsonLine(expected, created);
    }

    const line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"ID"}}}
    , "ID", id);
    defer allocator.free(line);
    const read = try reply(&server, line);
    defer allocator.free(read);
    const read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, read, .{});
    defer read_parsed.deinit();
    const result = read_parsed.value.object.get("result").?.object;
    try std.testing.expectEqual(false, result.get("isError").?.bool);
    const issue = result.get("structuredContent").?.object;
    try std.testing.expectEqualStrings(id, issue.get("id").?.string);
    const event = issue.get("record").?.object.get("event").?.object;
    try std.testing.expectEqualStrings("it breaks", event.get("title").?.string);
    try std.testing.expectEqualStrings("bug", event.get("labels").?.string);
    try std.testing.expectEqualStrings("open", event.get("status").?.string);
    // the text block carries the same result
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    const text_parsed = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer text_parsed.deinit();
    try std.testing.expect(jsonEql(result.get("structuredContent").?, text_parsed.value));
}

test "mcp: tools/call arguments that don't fit the operation are invalid params" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);

    for ([_][2][]const u8{
        // a number for a string
        .{
            \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":42}}}
            ,
            \\{"jsonrpc":"2.0","id":20,"error":{"code":-32602,"message":"invalid arguments for create_thread: title must be a string"}}
        },
        // a kind that isn't one
        .{
            \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"bug","title":"t"}}}
            ,
            \\{"jsonrpc":"2.0","id":21,"error":{"code":-32602,"message":"invalid arguments for create_thread: kind must be one of issue, patch, discuss"}}
        },
        // an unknown field
        .{
            \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"t","author":"mallory"}}}
            ,
            \\{"jsonrpc":"2.0","id":22,"error":{"code":-32602,"message":"invalid arguments for create_thread: unknown field author"}}
        },
        // a missing required field
        .{
            \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue"}}}
            ,
            \\{"jsonrpc":"2.0","id":23,"error":{"code":-32602,"message":"invalid arguments for create_thread: missing field title"}}
        },
    }) |case| {
        const out = try reply(&server, case[0]);
        defer allocator.free(out);
        try expectJsonLine(case[1], out);
    }
    // nothing was written
    const listed = try reply(&server,
        \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":"alice:open"}}}
    );
    defer allocator.free(listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(0, parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("count").?.integer);
}

test "mcp: tools/call of an unknown tool is invalid params" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"delete_repo","arguments":{}}}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":30,"error":{"code":-32602,"message":"unknown tool: delete_repo"}}
    , out);
}

test "mcp: a tools/call the domain refuses is a tool error, not a protocol error" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    const line =
        \\{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"t"}}}
    ;
    // logged out, and acting as dave, whose account was removed after the
    // server started
    for ([_]?fixture.Id{ null, data.dave }) |user| {
        var server = serverMode(data, user);
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":40,"result":{"content":[{"type":"text","text":"create_thread failed (login_required): LoginRequired"}],"isError":true}}
        , out);
    }
    // a repo carol can't see doesn't exist to her
    var server = serverMode(data, data.carol);
    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:secret","id":"11111111111111111111111111111111"}}}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":41,"result":{"content":[{"type":"text","text":"get_issue failed (not_found): NotFound"}],"isError":true}}
    , out);
}

test "mcp: a local tools/call first brings the repo up to date with its events branch" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    // an issue fetched from elsewhere, not yet consumed into the event db
    try local.commitUnconsumed(fixture.Server.alice_author, @splat(0x11), .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":""}}}
    );
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    const window = parsed.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqual(1, window.get("count").?.integer);
    try std.testing.expectEqualStrings("11111111111111111111111111111111", window.get("items").?.array.items[0].object.get("id").?.string);
}

// the issue count `list_issues` reports for alice:open
fn openIssueCount(server: *mcp.Server) !i64 {
    const listed = try reply(server,
        \\{"jsonrpc":"2.0","id":99,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":"alice:open"}}}
    );
    defer allocator.free(listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
    defer parsed.deinit();
    return parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("count").?.integer;
}

test "mcp: tools/call arguments must have the types the schema advertises, not ones json parsing would coerce" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);

    for ([_][2][]const u8{
        // a numeric enum tag
        .{
            \\{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":0,"title":"t"}}}
            ,
            \\{"jsonrpc":"2.0","id":60,"error":{"code":-32602,"message":"invalid arguments for create_thread: kind must be one of issue, patch, discuss"}}
        },
        // an array of bytes for a string
        .{
            \\{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":[116]}}}
            ,
            \\{"jsonrpc":"2.0","id":61,"error":{"code":-32602,"message":"invalid arguments for create_thread: title must be a string"}}
        },
        // a string for an integer
        .{
            \\{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"11111111111111111111111111111111","comments_from":"3"}}}
            ,
            \\{"jsonrpc":"2.0","id":62,"error":{"code":-32602,"message":"invalid arguments for get_issue: comments_from must be an integer in range"}}
        },
        // a fraction for an integer
        .{
            \\{"jsonrpc":"2.0","id":63,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"11111111111111111111111111111111","comments_from":1.5}}}
            ,
            \\{"jsonrpc":"2.0","id":63,"error":{"code":-32602,"message":"invalid arguments for get_issue: comments_from must be an integer in range"}}
        },
        // an integer past the field's range, which must not panic
        .{
            \\{"jsonrpc":"2.0","id":64,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"11111111111111111111111111111111","comments_from":18446744073709551616.0}}}
            ,
            \\{"jsonrpc":"2.0","id":64,"error":{"code":-32602,"message":"invalid arguments for get_issue: comments_from must be an integer in range"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":65,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"11111111111111111111111111111111","comments_from":-1}}}
            ,
            \\{"jsonrpc":"2.0","id":65,"error":{"code":-32602,"message":"invalid arguments for get_issue: comments_from must be an integer in range"}}
        },
        // null for a field that isn't optional
        .{
            \\{"jsonrpc":"2.0","id":66,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"t","body":null}}}
            ,
            \\{"jsonrpc":"2.0","id":66,"error":{"code":-32602,"message":"invalid arguments for create_thread: body must be a string"}}
        },
        // arguments that aren't an object
        .{
            \\{"jsonrpc":"2.0","id":67,"method":"tools/call","params":{"name":"create_thread","arguments":["alice:open"]}}
            ,
            \\{"jsonrpc":"2.0","id":67,"error":{"code":-32602,"message":"invalid arguments for create_thread: arguments must be an object"}}
        },
    }) |case| {
        const out = try reply(&server, case[0]);
        defer allocator.free(out);
        try expectJsonLine(case[1], out);
    }
    // nothing was written
    try std.testing.expectEqual(0, try openIssueCount(&server));
}

test "mcp: params must be an object, and initialize's must name a version, capabilities and client" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    for ([_][2][]const u8{
        .{
            \\{"jsonrpc":"2.0","id":70,"method":"ping","params":42}
            ,
            \\{"jsonrpc":"2.0","id":70,"error":{"code":-32600,"message":"invalid request"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":71,"method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
            ,
            \\{"jsonrpc":"2.0","id":71,"error":{"code":-32602,"message":"initialize needs a protocolVersion string, a capabilities object and a clientInfo object"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":72,"method":"initialize","params":{"protocolVersion":5,"capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
            ,
            \\{"jsonrpc":"2.0","id":72,"error":{"code":-32602,"message":"initialize needs a protocolVersion string, a capabilities object and a clientInfo object"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":73,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"t","version":"0"}}}
            ,
            \\{"jsonrpc":"2.0","id":73,"error":{"code":-32602,"message":"initialize needs a protocolVersion string, a capabilities object and a clientInfo object"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":74,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":"t"}}
            ,
            \\{"jsonrpc":"2.0","id":74,"error":{"code":-32602,"message":"initialize needs a protocolVersion string, a capabilities object and a clientInfo object"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":75,"method":"initialize"}
            ,
            \\{"jsonrpc":"2.0","id":75,"error":{"code":-32602,"message":"initialize needs a protocolVersion string, a capabilities object and a clientInfo object"}}
        },
    }) |case| {
        const out = try reply(&server, case[0]);
        defer allocator.free(out);
        try expectJsonLine(case[1], out);
    }
}

test "mcp: a tools/call whose context can't be built is an internal error, not a tool error" {
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const base = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const admin_path = try std.Io.Dir.path.join(allocator, &.{ base, "gone", "admin" });
    defer allocator.free(admin_path);
    const users_dir = try std.Io.Dir.path.join(allocator, &.{ base, "gone", "users" });
    defer allocator.free(users_dir);
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .server = .{
        .admin_repo_path = admin_path,
        .users_dir = users_dir,
        .user_id = @splat(0x11),
    } } };

    const out = try reply(&server,
        \\{"jsonrpc":"2.0","id":80,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":"alice:open"}}}
    );
    defer allocator.free(out);
    try expectJsonLine(
        \\{"jsonrpc":"2.0","id":80,"error":{"code":-32603,"message":"internal error: FileNotFound"}}
    , out);
}

test "mcp: a user removed between two calls is logged out from the second on" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);
    const line =
        \\{"jsonrpc":"2.0","id":90,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"t"}}}
    ;
    {
        const out = try reply(&server, line);
        defer allocator.free(out);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(false, parsed.value.object.get("result").?.object.get("isError").?.bool);
    }
    try hx.event.deleteUser(io, allocator, data.users_dir, &data.admin, &data.bob, fixture.Server.bob_author);
    {
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":90,"result":{"content":[{"type":"text","text":"create_thread failed (login_required): LoginRequired"}],"isError":true}}
        , out);
    }
}

test "mcp: a local session opens an issue, comments on it and reads both back" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    {
        const out = try reply(&server,
            \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}
        );
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"haxy","version":"0.0.0"}}}
        , out);
    }
    const created = try reply(&server,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"","kind":"issue","title":"local issue","body":"it breaks"}}}
    );
    defer allocator.free(created);
    const created_parsed = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer created_parsed.deinit();
    const issue_id = created_parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("id").?.string;

    const comment_line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"create_comment","arguments":{"repo":"","kind":"issue","thread_id":"ID","body":"me too"}}}
    , "ID", issue_id);
    defer allocator.free(comment_line);
    const commented = try reply(&server, comment_line);
    defer allocator.free(commented);
    const commented_parsed = try std.json.parseFromSlice(std.json.Value, allocator, commented, .{});
    defer commented_parsed.deinit();
    try std.testing.expectEqual(false, commented_parsed.value.object.get("result").?.object.get("isError").?.bool);

    {
        const listed = try reply(&server,
            \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_issues","arguments":{"repo":""}}}
        );
        defer allocator.free(listed);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
        defer parsed.deinit();
        const window = parsed.value.object.get("result").?.object.get("structuredContent").?.object;
        try std.testing.expectEqual(1, window.get("count").?.integer);
        try std.testing.expectEqualStrings(issue_id, window.get("items").?.array.items[0].object.get("id").?.string);
    }
    {
        const get_line = try std.mem.replaceOwned(u8, allocator,
            \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"","id":"ID"}}}
        , "ID", issue_id);
        defer allocator.free(get_line);
        const read = try reply(&server, get_line);
        defer allocator.free(read);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, read, .{});
        defer parsed.deinit();
        const issue = parsed.value.object.get("result").?.object.get("structuredContent").?.object;
        try std.testing.expectEqualStrings("local issue", issue.get("record").?.object.get("event").?.object.get("title").?.string);
        const comments = issue.get("comments").?.object;
        try std.testing.expectEqual(1, comments.get("count").?.integer);
        try std.testing.expectEqualStrings("me too", comments.get("comments").?.array.items[0].object.get("comment").?.object.get("event").?.object.get("body").?.string);
    }
}

// a test-only input with every field shape the derivation knows
const SchemaShapes = struct {
    name: ?[]const u8,
    color: enum { red, green },
    size: struct {
        width: u32,
        depth: ?enum { flat, deep } = null,
    },
    count: u32 = 0,
    on: bool = false,

    pub const tool_schema_notes = .{ .name = "A name, or null." };
};

test "mcp schema: optionals allow null, enums list their names, nested structs recurse" {
    const schema = try std.json.Stringify.valueAlloc(allocator, mcp.InputSchema(SchemaShapes){}, .{});
    defer allocator.free(schema);
    try expectJson(
        \\{
        \\  "type": "object",
        \\  "properties": {
        \\    "name": { "type": ["string", "null"], "description": "A name, or null." },
        \\    "color": { "type": "string", "enum": ["red", "green"] },
        \\    "size": {
        \\      "type": "object",
        \\      "properties": {
        \\        "width": { "type": "integer" },
        \\        "depth": { "type": ["string", "null"], "enum": ["flat", "deep", null] }
        \\      },
        \\      "required": ["width"],
        \\      "additionalProperties": false
        \\    },
        \\    "count": { "type": "integer" },
        \\    "on": { "type": "boolean" }
        \\  },
        \\  "required": ["name", "color", "size"],
        \\  "additionalProperties": false
        \\}
    , schema);
}
