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

test "mcp: tools/list names the tools in registry order with schemas derived from the operations" {
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
    try std.testing.expectEqualStrings("refresh_local list_issues get_issue get_discussion list_patches get_patch list_notifications create_thread edit_thread resolve_conflict set_thread_status create_comment edit_comment attach assign unassign subscribe mute publish_patch create_repo update_repo_settings grant promote revoke demote protect_branch unprotect_branch set_default_branch sync add_key mark_notification_read dismiss_notification ", names.items);

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
            \\  "refresh_local": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "list_issues": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "get_issue": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "get_discussion": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "list_patches": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "get_patch": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "list_notifications": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "create_thread": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false },
            \\  "edit_thread": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "resolve_conflict": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "set_thread_status": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "create_comment": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false },
            \\  "edit_comment": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "attach": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false },
            \\  "assign": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "unassign": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "subscribe": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "mute": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "publish_patch": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "create_repo": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "update_repo_settings": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "grant": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "promote": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false },
            \\  "revoke": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "demote": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "protect_branch": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "unprotect_branch": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "set_default_branch": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false },
            \\  "sync": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": true },
            \\  "add_key": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false },
            \\  "mark_notification_read": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false },
            \\  "dismiss_notification": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false }
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
            \\  "description": "Open a new issue, patch or discussion in a repository.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "kind": { "type": "string", "enum": ["issue", "patch", "discuss"], "description": "The kind of thread to open." },
            \\      "title": { "type": "string", "description": "A title that isn't blank." },
            \\      "labels": { "type": "string", "description": "Space-separated labels, each at most 64 bytes." },
            \\      "body": { "type": "string", "description": "The thread's text, in markdown." },
            \\      "target_branch": { "type": "string", "description": "Patches only: the branch the patch merges into." },
            \\      "source_branch": { "type": ["string", "null"], "description": "Patches only: the branch the patch proposes; null or omitted starts a draft in a fork of the repository instead, which is server only." }
            \\    },
            \\    "required": ["repo", "kind", "title"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false }
            \\}
        , entry);
    }
    // a write with a list of strings
    {
        const entry = try toolEntry(tools, "resolve_conflict");
        defer allocator.free(entry);
        try expectJson(
            \\{
            \\  "name": "resolve_conflict",
            \\  "description": "Settle an issue or patch whose fields two merged event histories set apart, keeping our side except where the inputs say otherwise.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "kind": { "type": "string", "enum": ["issue", "patch", "discuss"], "description": "issue or patch; discussions have no field conflicts." },
            \\      "thread_id": { "type": "string", "description": "The thread's hex event id." },
            \\      "title": { "type": ["string", "null"], "description": "The resolved title; null or omitted keeps the current one." },
            \\      "labels": { "type": ["string", "null"], "description": "The resolved space-separated labels; null or omitted keeps the current ones." },
            \\      "hunks": { "type": "array", "items": { "type": "string" }, "description": "The resolutions of the description's conflicting hunks, in order; missing trailing ones keep our side." },
            \\      "theirs": { "type": "string", "description": "Patches only: comma-separated fields to take from their side, of status, revision and target_branch." }
            \\    },
            \\    "required": ["repo", "kind", "thread_id"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": false, "openWorldHint": false }
            \\}
        , entry);
    }
    // the adapter that takes a file as base64
    {
        const entry = try toolEntry(tools, "attach");
        defer allocator.free(entry);
        try expectJson(
            \\{
            \\  "name": "attach",
            \\  "description": "Attach a file, sent as base64, to an issue, patch or discussion.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "kind": { "type": "string", "enum": ["issue", "patch", "discuss"], "description": "The kind of the thread the file is attached to." },
            \\      "thread_id": { "type": "string", "description": "The thread's hex event id." },
            \\      "name": { "type": "string", "description": "The file's name, without a directory." },
            \\      "content_base64": { "type": "string", "description": "The file's bytes in padded standard base64, at most 10 MiB once decoded." }
            \\    },
            \\    "required": ["repo", "kind", "thread_id", "name", "content_base64"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": false, "openWorldHint": false }
            \\}
        , entry);
    }
    // a read with an enum argument
    {
        const entry = try toolEntry(tools, "list_patches");
        defer allocator.free(entry);
        try expectJson(
            \\{
            \\  "name": "list_patches",
            \\  "description": "List a repository's patches by view, newest first: open, closed, merged, the acting user's drafts, or conflicted.",
            \\  "inputSchema": {
            \\    "type": "object",
            \\    "properties": {
            \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\      "view": { "type": "string", "enum": ["open", "closed", "merged", "drafts", "conflicts"], "description": "Which patches: open, closed, merged, drafts (the acting user's unpublished drafts, server only) or conflicts." },
            \\      "search": { "type": "string", "description": "Words to find, with label:x filters." },
            \\      "from": { "type": "string", "description": "The id of the first patch of the window to list; \"\" or omitted lists the first window." }
            \\    },
            \\    "required": ["repo"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
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
            \\      "comments_from": { "type": "integer", "minimum": 0, "description": "The index of the first comment in the returned window of comments." }
            \\    },
            \\    "required": ["repo", "id"],
            \\    "additionalProperties": false
            \\  },
            \\  "annotations": { "readOnlyHint": false, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false }
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
        // a string, and an array holding a non-string, for a list of strings
        .{
            \\{"jsonrpc":"2.0","id":68,"method":"tools/call","params":{"name":"resolve_conflict","arguments":{"repo":"alice:open","kind":"issue","thread_id":"11111111111111111111111111111111","hunks":"ours"}}}
            ,
            \\{"jsonrpc":"2.0","id":68,"error":{"code":-32602,"message":"invalid arguments for resolve_conflict: hunks must be an array of strings"}}
        },
        .{
            \\{"jsonrpc":"2.0","id":69,"method":"tools/call","params":{"name":"resolve_conflict","arguments":{"repo":"alice:open","kind":"issue","thread_id":"11111111111111111111111111111111","hunks":["ours",1]}}}
            ,
            \\{"jsonrpc":"2.0","id":69,"error":{"code":-32602,"message":"invalid arguments for resolve_conflict: hunks must be an array of strings"}}
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
    tags: []const []const u8 = &.{},

    pub const tool_schema_notes = .{ .name = "A name, or null." };
};

test "mcp schema: optionals allow null, enums list their names, unsigned integers have a minimum, nested structs recurse, string slices are arrays" {
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
        \\        "width": { "type": "integer", "minimum": 0 },
        \\        "depth": { "type": ["string", "null"], "enum": ["flat", "deep", null] }
        \\      },
        \\      "required": ["width"],
        \\      "additionalProperties": false
        \\    },
        \\    "count": { "type": "integer", "minimum": 0 },
        \\    "on": { "type": "boolean" },
        \\    "tags": { "type": "array", "items": { "type": "string" } }
        \\  },
        \\  "required": ["name", "color", "size"],
        \\  "additionalProperties": false
        \\}
    , schema);
}

// the names `tools/list` lists, space-separated
fn toolNames(server: *mcp.Server) ![]u8 {
    const parsed = try listTools(server);
    defer parsed.deinit();
    var names: std.ArrayList(u8) = .empty;
    errdefer names.deinit(allocator);
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        try names.appendSlice(allocator, tool.object.get("name").?.string);
        try names.append(allocator, ' ');
    }
    return try names.toOwnedSlice(allocator);
}

test "mcp: tools/list lists exactly the registered tools in each mode, and never one that takes a password" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    const always = "refresh_local list_issues get_issue get_discussion list_patches get_patch list_notifications " ++
        "create_thread edit_thread resolve_conflict set_thread_status create_comment edit_comment attach assign unassign subscribe mute publish_patch " ++
        "create_repo update_repo_settings grant promote revoke demote protect_branch unprotect_branch set_default_branch sync add_key mark_notification_read dismiss_notification ";
    const flagged = "merge_patch remove_thread remove_comment remove_attachment undo remove_key ";
    {
        const names = try toolNames(&server);
        defer allocator.free(names);
        try std.testing.expectEqualStrings(always, names);
        try std.testing.expectEqual(32, std.mem.count(u8, names, " "));
    }
    server.allow_destructive = true;
    {
        const names = try toolNames(&server);
        defer allocator.free(names);
        try std.testing.expectEqualStrings(always ++ flagged, names);
        try std.testing.expectEqual(38, std.mem.count(u8, names, " "));
        // each takes the account password, which tool arguments never carry
        for ([_][]const u8{ " delete_repo ", " delete_user ", " register_user ", " update_user_settings ", " delete_fork " }) |name| {
            try std.testing.expect(std.mem.indexOf(u8, names, name) == null);
        }
    }
    const parsed = try listTools(&server);
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?;
    for ([_][2][]const u8{
        .{ "undo", "{ \"readOnlyHint\": false, \"destructiveHint\": true, \"idempotentHint\": false, \"openWorldHint\": false }" },
        .{ "remove_key", "{ \"readOnlyHint\": false, \"destructiveHint\": true, \"idempotentHint\": true, \"openWorldHint\": false }" },
    }) |case| {
        const entry = try toolEntry(tools, case[0]);
        defer allocator.free(entry);
        const entry_parsed = try std.json.parseFromSlice(std.json.Value, allocator, entry, .{});
        defer entry_parsed.deinit();
        const annotations = try std.json.Stringify.valueAlloc(allocator, entry_parsed.value.object.get("annotations").?, .{});
        defer allocator.free(annotations);
        try expectJson(case[1], annotations);
    }
}

test "mcp: removals and merging are listed only when destructive tools are allowed, and nothing asks for a password" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    {
        const names = try toolNames(&server);
        defer allocator.free(names);
        try std.testing.expect(std.mem.indexOf(u8, names, "remove_") == null);
        try std.testing.expect(std.mem.indexOf(u8, names, "merge_patch") == null);
    }
    server.allow_destructive = true;
    {
        const names = try toolNames(&server);
        defer allocator.free(names);
        // delete_fork asks for the account password, so it is no tool
        try std.testing.expect(std.mem.endsWith(u8, names, " dismiss_notification merge_patch remove_thread remove_comment remove_attachment undo remove_key "));
    }
    const parsed = try listTools(&server);
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        const properties = tool.object.get("inputSchema").?.object.get("properties").?.object;
        try std.testing.expect(properties.get("password") == null);
    }
    const entry = try toolEntry(parsed.value.object.get("result").?.object.get("tools").?, "remove_comment");
    defer allocator.free(entry);
    try expectJson(
        \\{
        \\  "name": "remove_comment",
        \\  "description": "Remove a comment from an issue, patch or discussion.",
        \\  "inputSchema": {
        \\    "type": "object",
        \\    "properties": {
        \\      "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
        \\      "kind": { "type": "string", "enum": ["issue", "patch", "discuss"], "description": "The kind of the thread the comment is on." },
        \\      "thread_id": { "type": "string", "description": "The thread's hex event id." },
        \\      "comment_id": { "type": "string", "description": "The comment's hex event id." }
        \\    },
        \\    "required": ["repo", "kind", "thread_id", "comment_id"],
        \\    "additionalProperties": false
        \\  },
        \\  "annotations": { "readOnlyHint": false, "destructiveHint": true, "idempotentHint": true, "openWorldHint": false }
        \\}
    , entry);
}

test "mcp: a removal without destructive tools allowed is an unknown tool, with them it removes" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);

    const created = try reply(&server,
        \\{"jsonrpc":"2.0","id":100,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"doomed"}}}
    );
    defer allocator.free(created);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer parsed.deinit();
    const id = parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("id").?.string;
    const line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":101,"method":"tools/call","params":{"name":"remove_thread","arguments":{"repo":"alice:open","kind":"issue","thread_id":"ID"}}}
    , "ID", id);
    defer allocator.free(line);

    {
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":101,"error":{"code":-32602,"message":"unknown tool: remove_thread"}}
        , out);
        try std.testing.expectEqual(1, try openIssueCount(&server));
    }
    server.allow_destructive = true;
    {
        const out = try reply(&server, line);
        defer allocator.free(out);
        // structured content is an object, so a result that isn't one is
        // wrapped as `result`
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":101,"result":{"content":[{"type":"text","text":"{\"result\":\"thread\"}"}],"structuredContent":{"result":"thread"},"isError":false}}
        , out);
        try std.testing.expectEqual(0, try openIssueCount(&server));
    }
}

// the id of the issue bob opens in alice:open through `server`, which the
// caller frees
fn openIssue(server: *mcp.Server) ![]u8 {
    const created = try reply(server,
        \\{"jsonrpc":"2.0","id":98,"method":"tools/call","params":{"name":"create_thread","arguments":{"repo":"alice:open","kind":"issue","title":"t"}}}
    );
    defer allocator.free(created);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer parsed.deinit();
    return try allocator.dupe(u8, parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("id").?.string);
}

test "mcp: attach decodes a base64 file onto a thread get_issue then lists" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);
    const issue_id = try openIssue(&server);
    defer allocator.free(issue_id);

    // "hello\n"
    const line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":110,"method":"tools/call","params":{"name":"attach","arguments":{"repo":"alice:open","kind":"issue","thread_id":"ID","name":"notes.txt","content_base64":"aGVsbG8K"}}}
    , "ID", issue_id);
    defer allocator.free(line);
    const attached = try reply(&server, line);
    defer allocator.free(attached);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, attached, .{});
    defer parsed.deinit();
    const attachment_id = parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("id").?.string;
    {
        const expected = try std.mem.replaceOwned(u8, allocator,
            \\{"jsonrpc":"2.0","id":110,"result":{"content":[{"type":"text","text":"{\"id\":\"ID\"}"}],"structuredContent":{"id":"ID"},"isError":false}}
        , "ID", attachment_id);
        defer allocator.free(expected);
        try expectJsonLine(expected, attached);
    }

    const get_line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":111,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"ID"}}}
    , "ID", issue_id);
    defer allocator.free(get_line);
    const read = try reply(&server, get_line);
    defer allocator.free(read);
    const read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, read, .{});
    defer read_parsed.deinit();
    const attachments = read_parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("attachments").?;
    const listed = try std.json.Stringify.valueAlloc(allocator, attachments, .{});
    defer allocator.free(listed);
    const expected = try std.mem.replaceOwned(u8, allocator,
        \\[{"id":"ID","name":"notes.txt"}]
    , "ID", attachment_id);
    defer allocator.free(expected);
    try expectJson(expected, listed);
}

test "mcp: attach content that isn't base64 or decodes past the size limit is invalid params" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);
    const issue_id = try openIssue(&server);
    defer allocator.free(issue_id);

    {
        const line = try std.mem.replaceOwned(u8, allocator,
            \\{"jsonrpc":"2.0","id":120,"method":"tools/call","params":{"name":"attach","arguments":{"repo":"alice:open","kind":"issue","thread_id":"ID","name":"notes.txt","content_base64":"aGVsbG8K!!!"}}}
        , "ID", issue_id);
        defer allocator.free(line);
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":120,"error":{"code":-32602,"message":"invalid arguments for attach: content_base64 is not base64"}}
        , out);
    }
    {
        // one quad past what decodes to the limit, of characters that aren't
        // base64: the length is refused before anything is decoded
        const bound = ((hx.event.Attachment.max_size + 2) / 3) * 4;
        const content = try allocator.alloc(u8, bound + 4);
        defer allocator.free(content);
        @memset(content, '!');
        const head = try std.mem.replaceOwned(u8, allocator,
            \\{"jsonrpc":"2.0","id":121,"method":"tools/call","params":{"name":"attach","arguments":{"repo":"alice:open","kind":"issue","thread_id":"ID","name":"big.bin","content_base64":"
        , "ID", issue_id);
        defer allocator.free(head);
        const line = try std.mem.concat(allocator, u8, &.{ head, content, "\"}}}" });
        defer allocator.free(line);
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":121,"error":{"code":-32602,"message":"invalid arguments for attach: content_base64 decodes to more than 10485760 bytes"}}
        , out);
    }
    // nothing was attached
    const get_line = try std.mem.replaceOwned(u8, allocator,
        \\{"jsonrpc":"2.0","id":122,"method":"tools/call","params":{"name":"get_issue","arguments":{"repo":"alice:open","id":"ID"}}}
    , "ID", issue_id);
    defer allocator.free(get_line);
    const read = try reply(&server, get_line);
    defer allocator.free(read);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, read, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(0, parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("attachments").?.array.items.len);
}

test "mcp: merge_patch is an unknown tool without destructive tools allowed" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);
    const line =
        \\{"jsonrpc":"2.0","id":130,"method":"tools/call","params":{"name":"merge_patch","arguments":{"repo":"alice:open","patch_id":"22222222222222222222222222222222"}}}
    ;
    {
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":130,"error":{"code":-32602,"message":"unknown tool: merge_patch"}}
        , out);
    }
    server.allow_destructive = true;
    {
        // with them the call reaches the operation, which finds no such patch
        const out = try reply(&server, line);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":130,"result":{"content":[{"type":"text","text":"merge_patch failed (not_found): NotFound"}],"isError":true}}
        , out);
    }
}

// an attach call for `issue_id` in alice:open whose content is `content`,
// which the caller frees
fn attachLine(issue_id: []const u8, id: u32, content: []const u8) ![]u8 {
    const head = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"attach","arguments":{{"repo":"alice:open","kind":"issue","thread_id":"{s}","name":"big.bin","content_base64":"
    , .{ id, issue_id });
    defer allocator.free(head);
    return try std.mem.concat(allocator, u8, &.{ head, content, "\"}}}" });
}

test "mcp: attach takes a file of exactly the size limit and refuses one a padding byte over it" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var server = serverMode(data, data.bob);
    const issue_id = try openIssue(&server);
    defer allocator.free(issue_id);

    // the size limit is 1 more than a multiple of 3, so the longest encoding
    // that can hold it decodes to the limit with "==", one over it with "="
    // and two over it with no padding
    const len = mcp.AttachTool.max_encoded_len;
    const content = try allocator.alloc(u8, len);
    defer allocator.free(content);
    for ([_]struct { pad: usize, id: u32 }{ .{ .pad = 0, .id = 140 }, .{ .pad = 1, .id = 141 } }) |case| {
        @memset(content, 'A');
        @memset(content[len - case.pad ..], '=');
        const line = try attachLine(issue_id, case.id, content);
        defer allocator.free(line);
        const out = try reply(&server, line);
        defer allocator.free(out);
        const expected = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":-32602,"message":"invalid arguments for attach: content_base64 decodes to more than 10485760 bytes"}}}}
        , .{case.id});
        defer allocator.free(expected);
        try expectJsonLine(expected, out);
    }
    @memset(content, 'A');
    @memset(content[len - 2 ..], '=');
    const line = try attachLine(issue_id, 142, content);
    defer allocator.free(line);
    const out = try reply(&server, line);
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(false, parsed.value.object.get("result").?.object.get("isError").?.bool);
}

test "mcp stdio: a line holding the largest attachment fits the bound" {
    try std.testing.expect(mcp.stdio.max_line_len >= mcp.AttachTool.max_encoded_len + 64 * 1024);
}

test "mcp: the password guard refuses any input with a field naming a password" {
    // each takes a password under some name, and none is served
    try std.testing.expect(mcp.takesPassword(hx.domain.DeleteRepo));
    try std.testing.expect(mcp.takesPassword(hx.domain.DeleteUser));
    try std.testing.expect(mcp.takesPassword(hx.domain.DeleteFork));
    try std.testing.expect(mcp.takesPassword(hx.domain.RegisterUser));
    try std.testing.expect(mcp.takesPassword(hx.domain.UpdateUserSettings));
    try std.testing.expect(mcp.takesPassword(struct { new_password_again: []const u8 }));
    try std.testing.expect(mcp.takesPassword(struct { passwords: []const []const u8 }));
    // nested in a struct, an optional, a slice or an array
    const Login = struct { name: []const u8, password: []const u8 };
    try std.testing.expect(mcp.takesPassword(struct { login: Login }));
    try std.testing.expect(mcp.takesPassword(struct { login: ?Login }));
    try std.testing.expect(mcp.takesPassword(struct { logins: []const Login }));
    try std.testing.expect(mcp.takesPassword(struct { logins: [2]Login }));
    try std.testing.expect(mcp.takesPassword(struct { outer: struct { inner: ?[]const struct { old_password: []const u8 } } }));
    try std.testing.expect(!mcp.takesPassword(struct { login: struct { name: []const u8 }, tags: []const []const u8, count: ?u32 }));
    // the served tools take none
    inline for (mcp.tools) |tool| try std.testing.expect(!mcp.takesPassword(tool.Operation));
    try std.testing.expect(!mcp.takesPassword(struct { pass: []const u8 }));
}

// the input schema `tools/list` gives the tool `name`, as json
fn toolSchema(tools: std.json.Value, name: []const u8) ![]u8 {
    for (tools.array.items) |tool| {
        if (std.mem.eql(u8, tool.object.get("name").?.string, name)) {
            return try std.json.Stringify.valueAlloc(allocator, tool.object.get("inputSchema").?, .{});
        }
    }
    return error.TestExpectedTool;
}

test "mcp: the new tools' schemas carry enums from other modules, nullable roles and unsigned indexes" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() }, .allow_destructive = true };
    const parsed = try listTools(&server);
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?;
    for ([_][2][]const u8{
        .{
            "create_repo",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "name": { "type": "string", "description": "The new repository's name." },
            \\    "description": { "type": "string", "description": "A short description." },
            \\    "access": { "type": "string", "enum": ["private", "public"], "description": "Who may read it: private (members only) or public (anybody)." },
            \\    "hash": { "type": "string", "enum": ["sha1", "sha256"], "description": "The hash an empty repository uses; a copy keeps its source's." },
            \\    "copy": { "type": "string", "description": "A repository to copy as \"owner:name\", or \"\" for an empty one." }
            \\  },
            \\  "required": ["name"],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "update_repo_settings",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\    "name": { "type": "string", "description": "The repository's name, new or unchanged." },
            \\    "description": { "type": "string", "description": "The description, new or unchanged; \"\" clears it." },
            \\    "access": { "type": "string", "enum": ["private", "public"], "description": "Who may read it: private (members only) or public (anybody)." },
            \\    "discuss_role": { "type": ["string", "null"], "enum": ["read", "write", null], "description": "Who may open discussions: read (anybody), write (members), or null to turn the tab off." },
            \\    "issue_role": { "type": ["string", "null"], "enum": ["read", "write", null], "description": "Who may open issues: read (anybody), write (members), or null to turn the tab off." },
            \\    "patch_role": { "type": ["string", "null"], "enum": ["read", "write", null], "description": "Who may open patches: read (anybody), write (members), or null to turn the tab off." }
            \\  },
            \\  "required": ["repo", "name", "description", "access", "discuss_role", "issue_role", "patch_role"],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "undo",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "The repository as \"owner:name\", or \"\" in local mode." },
            \\    "index": { "type": "integer", "minimum": 0, "description": "The index of the oldest transaction to undo, as the repository's undo history lists it." }
            \\  },
            \\  "required": ["repo", "index"],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "list_notifications",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "start": { "type": "integer", "minimum": 0, "description": "The index of the first notification to list; 0 or omitted lists the first page." }
            \\  },
            \\  "required": [],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "sync",
            \\{ "type": "object", "properties": {}, "required": [], "additionalProperties": false }
        },
    }) |case| {
        const schema = try toolSchema(tools, case[0]);
        defer allocator.free(schema);
        try expectJson(case[1], schema);
    }
}

// the reply to a tools/call of `name` with `arguments`, a json object, under
// the request id 1, which the caller frees
fn call(server: *mcp.Server, name: []const u8, arguments: []const u8) ![]u8 {
    const line = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"{s}","arguments":{s}}}}}
    , .{ name, arguments });
    defer allocator.free(line);
    return try reply(server, line);
}

// a tools/call of `name` with `arguments` answers `result`, a json value
fn expectCall(server: *mcp.Server, name: []const u8, arguments: []const u8, result: []const u8) !void {
    const out = try call(server, name, arguments);
    defer allocator.free(out);
    const expected = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"result":{s}}}
    , .{result});
    defer allocator.free(expected);
    try expectJsonLine(expected, out);
}

// a tools/call of `name` with `arguments` answers a tool error saying `text`
fn expectToolError(server: *mcp.Server, name: []const u8, arguments: []const u8, text: []const u8) !void {
    const result = try std.fmt.allocPrint(allocator,
        \\{{"content":[{{"type":"text","text":"{s}"}}],"isError":true}}
    , .{text});
    defer allocator.free(result);
    try expectCall(server, name, arguments, result);
}

// the tools/call result of a void operation
const void_result =
    \\{"content":[{"type":"text","text":"{}"}],"structuredContent":{},"isError":false}
;

test "mcp: create_repo makes a private repo for the acting user, which list_issues then reads" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var bob = serverMode(data, data.bob);
    var carol = serverMode(data, data.carol);

    try expectToolError(&bob, "list_issues", "{\"repo\":\"bob:tools\"}", "list_issues failed (not_found): NotFound");
    try expectCall(&bob, "create_repo", "{\"name\":\"tools\"}",
        \\{"content":[{"type":"text","text":"{\"identity\":\"bob:tools\"}"}],"structuredContent":{"identity":"bob:tools"},"isError":false}
    );
    try expectCall(&bob, "list_issues", "{\"repo\":\"bob:tools\"}",
        \\{"content":[{"type":"text","text":"{\"items\":[],\"prev_id\":null,\"next_id\":null,\"count\":0,\"more\":false}"}],"structuredContent":{"items":[],"prev_id":null,"next_id":null,"count":0,"more":false},"isError":false}
    );
    // private by default, so a stranger finds nothing
    try expectToolError(&carol, "list_issues", "{\"repo\":\"bob:tools\"}", "list_issues failed (not_found): NotFound");
    // a repeat is a conflict that writes nothing
    try expectToolError(&bob, "create_repo", "{\"name\":\"tools\"}", "create_repo failed (conflict): NameTaken");
}

test "mcp: grant lets a user open issues where only members may" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var alice = serverMode(data, data.alice);
    var carol = serverMode(data, data.carol);
    const issue = "{\"repo\":\"alice:open\",\"kind\":\"issue\",\"title\":\"members only\"}";

    try expectCall(&alice, "update_repo_settings",
        \\{"repo":"alice:open","name":"open","description":"","access":"public","discuss_role":"read","issue_role":"write","patch_role":null}
    ,
        \\{"content":[{"type":"text","text":"{\"identity\":\"alice:open\"}"}],"structuredContent":{"identity":"alice:open"},"isError":false}
    );
    try expectToolError(&carol, "create_thread", issue, "create_thread failed (forbidden): Forbidden");
    try expectCall(&alice, "grant", "{\"repo\":\"alice:open\",\"user\":\"carol\"}", void_result);
    {
        const out = try call(&carol, "create_thread", issue);
        defer allocator.free(out);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(false, parsed.value.object.get("result").?.object.get("isError").?.bool);
    }
    // carol, a member now, may not manage the repo
    try expectToolError(&carol, "grant", "{\"repo\":\"alice:open\",\"user\":\"carol\"}", "grant failed (forbidden): Forbidden");
    try expectToolError(&alice, "grant", "{\"repo\":\"alice:open\",\"user\":\"carol\"}", "grant failed (conflict): AlreadyMember");
}

test "mcp: protecting a protected branch is a conflict" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    try data.commitReadme(data.open);
    var alice = serverMode(data, data.alice);

    try expectCall(&alice, "protect_branch", "{\"repo\":\"alice:open\",\"branch\":\"master\"}", void_result);
    try expectToolError(&alice, "protect_branch", "{\"repo\":\"alice:open\",\"branch\":\"master\"}", "protect_branch failed (conflict): BranchProtected");
    try expectCall(&alice, "unprotect_branch", "{\"repo\":\"alice:open\",\"branch\":\"master\"}", void_result);
    try expectCall(&alice, "protect_branch", "{\"repo\":\"alice:open\",\"branch\":\"master\"}", void_result);
}

test "mcp: add_key adds a key that remove_key, served only with destructive tools allowed, removes" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var alice = serverMode(data, data.alice);
    const key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeIs8mJqigBZ5y84J4COgnAJJ5bHPKy+lM2SliMXbYm one@example";
    // as ssh-keygen -lf prints it
    const fingerprint = "{\"fingerprint\":\"SHA256:R2bMBdC74Hm8ul5Quuj0fIz14HCoV8UBwiuMQ9JREpQ\"}";

    try expectCall(&alice, "add_key", "{\"key\":\"" ++ key ++ "\"}", void_result);
    try expectToolError(&alice, "add_key", "{\"key\":\"" ++ key ++ "\"}", "add_key failed (conflict): KeyAdded");
    {
        const out = try call(&alice, "remove_key", fingerprint);
        defer allocator.free(out);
        try expectJsonLine(
            \\{"jsonrpc":"2.0","id":1,"error":{"code":-32602,"message":"unknown tool: remove_key"}}
        , out);
    }
    alice.allow_destructive = true;
    try expectCall(&alice, "remove_key", fingerprint, void_result);
    try expectToolError(&alice, "remove_key", fingerprint, "remove_key failed (not_found): NotFound");
    // removed, it may be added again
    try expectCall(&alice, "add_key", "{\"key\":\"" ++ key ++ "\"}", void_result);
}

test "mcp: list_notifications lists another user's comment, which mark_notification_read marks read" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    // delivery stamps the wall clock, so the row's time falls between these
    // two reads
    const before = std.Io.Timestamp.now(io, .real).toSeconds();
    try data.notifyAlice(@splat(0xa1), @splat(0xb1));
    const after = std.Io.Timestamp.now(io, .real).toSeconds();
    var alice = serverMode(data, data.alice);
    // ids are hex strings, as mark_notification_read takes them
    const id = std.fmt.bytesToHex(hx.notify.idOf(&data.open.repo_id, &@as(fixture.Id, @splat(0xa1))), .lower);

    const listed = try call(&alice, "list_notifications", "{}");
    defer allocator.free(listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
    defer parsed.deinit();
    const content = parsed.value.object.get("result").?.object.get("structuredContent").?;
    const rows = content.object.get("rows").?.array.items;
    try std.testing.expectEqual(1, rows.len);
    const time = rows[0].object.get("time").?.integer;
    try std.testing.expect(before <= time and time <= after);
    {
        // the time, bounded above, is left out of the comparison
        _ = rows[0].object.orderedRemove("time");
        const expected = try std.mem.replaceOwned(u8, allocator,
            \\{"rows":[{"id":"ID","owner_name":"alice","repo_name":"open","thread_id":"a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1","thread_kind":"issue","title":"an issue","unread":true,"last_child_id":"b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"}],"unread_count":1,"more":false}
        , "ID", &id);
        defer allocator.free(expected);
        const actual = try std.json.Stringify.valueAlloc(allocator, content, .{});
        defer allocator.free(actual);
        try expectJson(expected, actual);
    }

    const mark = try std.mem.replaceOwned(u8, allocator,
        \\{"notification_id":"ID","last_child_id":"b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1"}
    , "ID", &id);
    defer allocator.free(mark);
    try expectCall(&alice, "mark_notification_read", mark, void_result);
    const again = try call(&alice, "list_notifications", "{}");
    defer allocator.free(again);
    const again_parsed = try std.json.parseFromSlice(std.json.Value, allocator, again, .{});
    defer again_parsed.deinit();
    const marked = again_parsed.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqual(0, marked.get("unread_count").?.integer);
    try std.testing.expectEqual(false, marked.get("rows").?.array.items[0].object.get("unread").?.bool);
}

test "mcp: arguments of the new shapes that don't fit are invalid params" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var alice = serverMode(data, data.alice);
    alice.allow_destructive = true;

    for ([_][3][]const u8{
        .{
            "update_repo_settings",
            \\{"repo":"alice:open","name":"open","description":"","access":"public","discuss_role":"admin","issue_role":"read","patch_role":null}
            ,
            "discuss_role must be one of read, write",
        },
        .{
            "update_repo_settings",
            \\{"repo":"alice:open","name":"open","description":"","access":"secret","discuss_role":"read","issue_role":"read","patch_role":null}
            ,
            "access must be one of private, public",
        },
        // an owners-only tab is nothing the pages show, so no tool offers it
        .{
            "update_repo_settings",
            \\{"repo":"alice:open","name":"open","description":"","access":"public","discuss_role":"read","issue_role":"owner","patch_role":null}
            ,
            "issue_role must be one of read, write",
        },
        // the settings are replaced whole, so the description must be given
        .{
            "update_repo_settings",
            \\{"repo":"alice:open","name":"open","access":"public","discuss_role":"read","issue_role":"read","patch_role":null}
            ,
            "missing field description",
        },
        .{
            "create_repo",
            \\{"name":"tools","hash":"md5"}
            ,
            "hash must be one of sha1, sha256",
        },
        .{
            "create_repo",
            \\{"name":"tools","owner":"bob"}
            ,
            "unknown field owner",
        },
        .{
            "undo",
            \\{"repo":"alice:open","index":-1}
            ,
            "index must be an integer in range",
        },
        .{
            "undo",
            \\{"repo":"alice:open","index":1.5}
            ,
            "index must be an integer in range",
        },
        .{
            "list_notifications",
            \\{"start":-20}
            ,
            "start must be an integer in range",
        },
    }) |case| {
        const out = try call(&alice, case[0], case[1]);
        defer allocator.free(out);
        const expected = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":1,"error":{{"code":-32602,"message":"invalid arguments for {s}: {s}"}}}}
        , .{ case[0], case[2] });
        defer allocator.free(expected);
        try expectJsonLine(expected, out);
    }
    // nothing was written
    try expectToolError(&alice, "list_issues", "{\"repo\":\"alice:tools\"}", "list_issues failed (not_found): NotFound");
}

test "mcp: in local mode a server-only tool is a tool error, and sync without a remote is its classified failure" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() }, .allow_destructive = true };

    try expectToolError(&server, "create_repo", "{\"name\":\"tools\"}", "create_repo failed (unavailable_here): UnavailableHere");
    try expectToolError(&server, "list_notifications", "{}", "list_notifications failed (unavailable_here): UnavailableHere");
    try expectToolError(&server, "undo", "{\"repo\":\"\",\"index\":0}", "undo failed (unavailable_here): UnavailableHere");
    try expectToolError(&server, "sync", "{}", "sync failed (not_found): RemoteNotFound");
}

test "mcp: a sync whose fetch the remote refuses is a tool error saying nothing was merged" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const script = try refusingSsh(&temp);
    defer allocator.free(script);
    try local.addRemote("origin", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", script);
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    try expectCall(&server, "sync", "{}",
        \\{"content":[{"type":"text","text":"sync failed (remote_failure): the remote refused the fetch, before any merge: no such repo"}],"structuredContent":{"remote_failure":"no such repo","failed_stage":"fetch","merged":false},"isError":true}
    );
}

test "mcp: a sync whose push the remote refuses is a tool error saying the merge was applied" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var remote = try fixture.Local(.git, .sha1).init();
    defer remote.deinit();
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const script = try refusingSsh(&temp);
    defer allocator.free(script);
    try local.setAuthor(fixture.Server.alice_author);
    // fetch from the file remote, push over an ssh that refuses
    try local.addRemote("origin", remote.path);
    try local.setConfig("remote.origin.pushurl", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", script);
    try remote.addEvent(fixture.Server.alice_author, @splat(0x22), .{ .issue = .{ .title = "remote", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    try expectCall(&server, "sync", "{}",
        \\{"content":[{"type":"text","text":"sync failed (remote_failure): the remote refused the push, after the merge was applied here: no such repo"}],"structuredContent":{"remote_failure":"no such repo","failed_stage":"push","merged":true},"isError":true}
    );
    // the merge stays
    try std.testing.expectEqual(1, try consumedIssueCount(&local));
}

test "mcp: a sync that fails after its merge names the change in its error" {
    var remote = try fixture.Local(.git, .sha1).init();
    defer remote.deinit();
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try local.setAuthor(fixture.Server.alice_author);
    // an ssh that exits at once, saying nothing
    try local.addRemote("origin", remote.path);
    try local.setConfig("remote.origin.pushurl", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", "false");
    try remote.addEvent(fixture.Server.alice_author, @splat(0x22), .{ .issue = .{ .title = "remote", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const log_level = std.testing.log_level;
    std.testing.log_level = .err;
    defer std.testing.log_level = log_level;
    // as phase 3's changed failures do, the error's name says what changed
    try expectToolError(&server, "sync", "{}", "sync failed (internal): SyncMergedNotPushed");
    try std.testing.expectEqual(1, try consumedIssueCount(&local));
}

test "mcp: a local sync trades events with a file remote and answers a null remote failure" {
    var remote = try fixture.Local(.git, .sha1).init();
    defer remote.deinit();
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try local.setAuthor(fixture.Server.alice_author);
    try local.addRemote("origin", remote.path);
    try local.addEvent(fixture.Server.alice_author, @splat(0x11), .{ .issue = .{ .title = "local", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    var remote_server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = remote.source() } };

    try expectCall(&server, "sync", "{}",
        \\{"content":[{"type":"text","text":"{\"remote_failure\":null}"}],"structuredContent":{"remote_failure":null},"isError":false}
    );
    const listed = try call(&remote_server, "list_issues", "{\"repo\":\"\"}");
    defer allocator.free(listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
    defer parsed.deinit();
    const window = parsed.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqual(1, window.get("count").?.integer);
    try std.testing.expectEqualStrings("11111111111111111111111111111111", window.get("items").?.array.items[0].object.get("id").?.string);
}

test "mcp: sync brings the remote's edits and removals here, not only its additions" {
    var remote = try fixture.Local(.git, .sha1).init();
    defer remote.deinit();
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    try remote.setAuthor(fixture.Server.alice_author);
    try local.setAuthor(fixture.Server.alice_author);
    try local.addRemote("origin", remote.path);
    try remote.addEvent(fixture.Server.alice_author, @splat(0x22), .{ .issue = .{ .title = "kept", .description = "", .labels = "" } });
    try remote.addEvent(fixture.Server.alice_author, @splat(0x33), .{ .issue = .{ .title = "doomed", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    var remote_server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = remote.source() }, .allow_destructive = true };
    const synced =
        \\{"content":[{"type":"text","text":"{\"remote_failure\":null}"}],"structuredContent":{"remote_failure":null},"isError":false}
    ;

    try expectCall(&server, "sync", "{}", synced);
    try std.testing.expectEqual(2, try consumedIssueCount(&local));
    // the remote edits one issue and removes the other
    try expectCall(&remote_server, "edit_thread",
        \\{"repo":"","kind":"issue","thread_id":"22222222222222222222222222222222","title":"edited"}
    , void_result);
    {
        const out = try call(&remote_server, "remove_thread",
            \\{"repo":"","kind":"issue","thread_id":"33333333333333333333333333333333"}
        );
        defer allocator.free(out);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(false, parsed.value.object.get("result").?.object.get("isError").?.bool);
    }

    try expectCall(&server, "sync", "{}", synced);
    const listed = try call(&server, "list_issues", "{\"repo\":\"\"}");
    defer allocator.free(listed);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listed, .{});
    defer parsed.deinit();
    const window = parsed.value.object.get("result").?.object.get("structuredContent").?.object;
    try std.testing.expectEqual(1, window.get("count").?.integer);
    const item = window.get("items").?.array.items[0].object;
    try std.testing.expectEqualStrings("22222222222222222222222222222222", item.get("id").?.string);
    const read = try call(&server, "get_issue", "{\"repo\":\"\",\"id\":\"22222222222222222222222222222222\"}");
    defer allocator.free(read);
    const read_parsed = try std.json.parseFromSlice(std.json.Value, allocator, read, .{});
    defer read_parsed.deinit();
    try std.testing.expectEqualStrings("edited", read_parsed.value.object.get("result").?.object.get("structuredContent").?.object.get("record").?.object.get("event").?.object.get("title").?.string);
}

test "mcp: a user removed between two list_notifications calls is logged out from the second on" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var bob = serverMode(data, data.bob);

    try expectCall(&bob, "list_notifications", "{}",
        \\{"content":[{"type":"text","text":"{\"rows\":[],\"unread_count\":0,\"more\":false}"}],"structuredContent":{"rows":[],"unread_count":0,"more":false},"isError":false}
    );
    try hx.event.deleteUser(io, allocator, data.users_dir, &data.admin, &data.bob, fixture.Server.bob_author);
    try expectToolError(&bob, "list_notifications", "{}", "list_notifications failed (login_required): LoginRequired");
}

// how many issues the local repo's event db holds, read without bringing it
// up to date first
fn consumedIssueCount(local: anytype) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    var ctx = local.ctx(&arena);
    return (try (hx.domain.ListIssues{ .repo = "" }).run(&ctx)).items.len;
}

test "mcp: a server-only tool in local mode answers unavailable without bringing the repo up to date" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    // an issue fetched from elsewhere, which a refresh would consume
    try local.commitUnconsumed(fixture.Server.alice_author, @splat(0x11), .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    try expectToolError(&server, "create_repo", "{\"name\":\"tools\"}", "create_repo failed (unavailable_here): UnavailableHere");
    try std.testing.expectEqual(0, try consumedIssueCount(&local));
}

// an ssh command standing in for a remote that answers with an ERR line, in
// `temp`. returns the script's path, which the caller frees.
fn refusingSsh(temp: *std.testing.TmpDir) ![]u8 {
    const base = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const script = try std.Io.Dir.path.join(allocator, &.{ base, "refuse.sh" });
    errdefer allocator.free(script);
    const file = try std.Io.Dir.cwd().createFile(io, script, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, "#!/bin/sh\nprintf '0014ERR no such repo'\n");
    try file.setPermissions(io, @fromBackingInt(@intCast(0o755)));
    return script;
}

test "mcp: sync doesn't bring the repo up to date before it runs, as it consumes what it merges itself" {
    if (@import("builtin").target.os.tag == .windows) return error.SkipZigTest;
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    const script = try refusingSsh(&temp);
    defer allocator.free(script);
    try local.addRemote("origin", "ssh://localhost/nowhere");
    try local.setConfig("core.sshCommand", script);
    try local.commitUnconsumed(fixture.Server.alice_author, @splat(0x11), .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    // refused at the fetch, the sync merges and consumes nothing
    const out = try call(&server, "sync", "{}");
    defer allocator.free(out);
    try std.testing.expectEqual(0, try consumedIssueCount(&local));
}

// an input of type `T` with each field at its default, or else at its
// smallest value: "", the first enum tag, 0, false, null or empty
fn minimal(comptime T: type) T {
    var value: T = undefined;
    inline for (@typeInfo(T).@"struct".field_names, @typeInfo(T).@"struct".field_types, @typeInfo(T).@"struct".field_attrs) |name, Field, attrs| {
        @field(value, name) = if (attrs.default_value_ptr) |ptr| @as(*const Field, @ptrCast(@alignCast(ptr))).* else smallest(Field);
    }
    return value;
}

fn smallest(comptime T: type) T {
    return switch (@typeInfo(T)) {
        .optional => null,
        .bool => false,
        .int => 0,
        .@"enum" => |info| @field(T, info.field_names[0]),
        .@"struct" => minimal(T),
        .pointer => if (T == []const u8) "" else &.{},
        else => @compileError("no smallest " ++ @typeName(T)),
    };
}

// what running the tool `Operation` with minimal arguments in `ctx` returns,
// as an error or none
fn runMinimal(comptime Operation: type, arena: *std.heap.ArenaAllocator, ctx: *hx.domain.Ctx) ?anyerror {
    const input = minimal(Operation);
    if (@hasDecl(Operation, "prepare")) {
        const ready = switch (input.prepare(arena.allocator()) catch |err| return err) {
            .ready => |ready| ready,
            .invalid => return error.TestInvalidMinimal,
        };
        _ = ready.run(ctx) catch |err| return err;
    } else {
        _ = input.run(ctx) catch |err| return err;
    }
    return null;
}

test "mcp: every tool's hosts declaration agrees with the operation's own UnavailableHere" {
    const data = try fixture.Server.init(.sha1);
    defer data.deinit();
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    inline for (mcp.tools) |tool| {
        const Operation = tool.Operation;
        inline for ([_]hx.event.HostKind{ .local, .server }) |kind| {
            var ctx = switch (kind) {
                .local => local.ctx(&arena),
                .server => try data.ctx(&arena, data.alice),
            };
            const declared = !@hasDecl(Operation, "hosts") or std.mem.indexOfScalar(hx.event.HostKind, Operation.hosts, kind) != null;
            const unavailable = if (runMinimal(Operation, &arena, &ctx)) |err| err == error.UnavailableHere else false;
            if (declared == unavailable) {
                std.debug.print("{s} on {t}: declared {}, answers unavailable {}\n", .{ Operation.tool_name, kind, declared, unavailable });
                return error.TestHostsDisagree;
            }
        }
    }
}
