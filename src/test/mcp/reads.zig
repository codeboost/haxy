//! the phase 5 reads as tools: their schemas, results, paging and failures
//! through tools/list and tools/call. expected replies are hand-written json.

const std = @import("std");
const hx = @import("../../lib.zig");
const mcp = hx.mcp;
const fixture = @import("../domain/fixture.zig");
const t = @import("../mcp.zig");

const io = std.testing.io;
const allocator = std.testing.allocator;
const Server = fixture.Server;

const repo_note = "The repository as \\\"owner:name\\\", or \\\"\\\" in local mode.";
const fork_id_note = "A fork's hex id, to read the fork instead of a repository; `repo` is then the fork as \\\"forker:name\\\", the name it was made under. A fork is read at its patch branch or a commit (ref_kind object), and has no patch revisions to name: with fork_id, ref_kind branch or tag and patchrev are invalid. Server only.";
const ref_kinds = "\"enum\": [\"branch\", \"tag\", \"object\", null]";

test "mcp reads: the new reads' schemas list every enum's values, describe every field and offer none a caller can't set" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };
    const parsed = try t.listTools(&server);
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?;
    for ([_][2][]const u8{
        .{
            "get_repo",
            \\{
            \\  "type": "object",
            \\  "properties": { "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" } },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_files",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "ref_kind": { "type": ["string", "null"],
            ++ ref_kinds ++
                \\, "description": "What `ref` names: branch, tag or object (a commit's full hex oid); omitted lists the default branch. Given with `ref`, and not with `patchrev`." },
                \\    "ref": { "type": "string", "description": "The branch or tag name or the commit oid; given with ref_kind, and omitted with it." },
                \\    "path": { "type": "string", "description": "The directory, relative to the repository's root; \"\" or omitted is the root." },
                \\    "patchrev": { "type": "string", "description": "A patch revision's hex event id, to list its files instead of a ref's; not with ref_kind or ref." },
                \\    "fork_id": { "type": "string", "description": "
            ++ fork_id_note ++
                \\" }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        // the file finder's prefix only narrows which path may be read, so
        // the tool doesn't offer it
        .{
            "read_file",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "ref_kind": { "type": ["string", "null"],
            ++ ref_kinds ++
                \\, "description": "What `ref` names: branch, tag or object (a commit's full hex oid); omitted reads the default branch. Given with `ref`, and not with `patchrev`." },
                \\    "ref": { "type": "string", "description": "The branch or tag name or the commit oid; given with ref_kind, and omitted with it." },
                \\    "path": { "type": "string", "description": "The file's path, relative to the repository's root." },
                \\    "line": { "type": "integer", "minimum": 0, "description": "The 1-based number of the window's first line; 0 or omitted is 1. The next window's is window_start + lines.len + 1." },
                \\    "patchrev": { "type": "string", "description": "A patch revision's hex event id, to read its file instead of a ref's; not with ref_kind or ref." },
                \\    "fork_id": { "type": "string", "description": "
            ++ fork_id_note ++
                \\" }
                \\  },
                \\  "required": ["repo", "path"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_refs",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "kind": { "type": "string", "enum": ["branch", "tag"], "description": "Which refs: branch or tag; omitted lists branches." },
                \\    "search": { "type": "string", "description": "A prefix the names must start with." },
                \\    "from": { "type": "string", "description": "The name of the first ref of the window to list; \"\" or omitted lists the first window." }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_commits",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "ref_kind": { "type": ["string", "null"],
            ++ ref_kinds ++
                \\, "description": "What ref names: branch, tag or object (a commit oid); omitted lists the default branch." },
                \\    "ref": { "type": "string", "description": "The branch or tag name, or the commit's hex oid; needs ref_kind, else the arguments are invalid." },
                \\    "base": { "type": "string", "description": "A commit's hex oid where the walk stops, leaving it out; it isn't checked to be an ancestor, so a base the walk never meets lists to the root. Omitted lists to the root." },
                \\    "merge": { "type": "string", "description": "A merge commit's hex oid: lists the commits it brought in, from its second parent back to the parents' common ancestor. Goes with from only; with ref_kind, ref, base or search the arguments are invalid." },
                \\    "search": { "type": "string", "description": "Words to find in the commit messages of an indexed branch or tag (server repos)." },
                \\    "from": { "type": "string", "description": "The oid of the first commit of the window to list, a previous result's next_start; \"\" or omitted lists the first window. In a plain log the cursor may be any commit and the walk goes on from it; it isn't checked to be on the named branch. In a search it must be one of the results." },
                \\    "fork_id": { "type": "string", "description": "
            ++ fork_id_note ++
                \\ A fork's log names a commit by object or none (its patch branch) and stops at its newest revision's base, leaving the base out; a commit before the base walks on to the root. With a branch or tag, base, merge or search the arguments are invalid." }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "get_commit",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "oid": { "type": "string", "description": "The commit's hex oid." },
                \\    "fork_id": { "type": "string", "description": "
            ++ fork_id_note ++
                \\ The fork's log stops at its newest revision's base, so that commit itself isn't found; a commit before it is." }
                \\  },
                \\  "required": ["repo", "oid"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "get_diff",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "oid": { "type": "string", "description": "The commit's hex oid; set exactly one of oid and patchrev, else the arguments are invalid." },
                \\    "base": { "type": "string", "description": "The hex oid of the commit to compare the commit with, all zeros for none; omitted is its first parent. Not with patchrev, whose base is its own." },
                \\    "patchrev": { "type": "string", "description": "A patch revision's hex event id, whose diff against its base is read; set exactly one of oid and patchrev." },
                \\    "start": { "type": "integer", "minimum": 0, "description": "The index of the first hunk of the window, a previous window's start plus its number of hunks; 0 or omitted reads the first window." },
                \\    "path": { "type": "string", "description": "A changed file's path, to read only its hunks; omitted reads every file. At most 1024 bytes." },
                \\    "fork_id": { "type": "string", "description": "
            ++ fork_id_note ++
                \\ Without oid, a fork's diff is its whole patch's, against its newest revision's base, and takes no base. A fork has no patchrev." }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_discussions",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "search": { "type": "string", "description": "Words to find, with label:x filters." },
                \\    "from": { "type": "string", "description": "The id of the first discussion of the window to list; \"\" or omitted lists the first window." }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_events",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "repo": { "type": "string", "description": "
            ++ repo_note ++
                \\" },
                \\    "view": { "type": "string", "enum": ["active", "removed"], "description": "Which events: active or removed; omitted lists the active ones." },
                \\    "from": { "type": "string", "description": "The hex id of the first event of the window to list; \"\" or omitted lists the first window." },
                \\    "from_kind": { "type": ["string", "null"], "enum": ["user", "repo", "fork", "grant", "notify", "discuss", "issue", "comment", "attach", "assign", "patchrev", "patch", null], "description": "The kind of the event `from` names, as the previous window's next reports it; required with `from`." },
                \\    "moment": { "type": ["integer", "null"], "minimum": 0, "description": "The index of a transaction in the repo's history (xit repos only): lists only the events it wrote, as they were then." }
                \\  },
                \\  "required": ["repo"],
                \\  "additionalProperties": false
                \\}
        },
        .{
            "list_users",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "search": { "type": "string", "description": "A prefix the names must start with." },
            \\    "start": { "type": "integer", "minimum": 0, "description": "The index of the window's first account, a previous result's next_start; 0 or omitted lists the first window." }
            \\  },
            \\  "required": [],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "list_repos",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "user": { "type": "string", "description": "The user's name." },
            \\    "search": { "type": "string", "description": "A prefix the repository names must start with." },
            \\    "start": { "type": "integer", "minimum": 0, "description": "The index of the window's first repository, a previous result's next_start; 0 or omitted lists the first window." }
            \\  },
            \\  "required": ["user"],
            \\  "additionalProperties": false
            \\}
        },
        .{
            "list_forks",
            \\{
            \\  "type": "object",
            \\  "properties": {
            \\    "user": { "type": "string", "description": "The forker's name." },
            \\    "start": { "type": "integer", "minimum": 0, "description": "The index of the window's first fork, a previous result's next_start; 0 or omitted lists the first window." }
            \\  },
            \\  "required": ["user"],
            \\  "additionalProperties": false
            \\}
        },
    }) |case| {
        const schema = try t.toolSchema(tools, case[0]);
        defer allocator.free(schema);
        t.expectJson(case[1], schema) catch |err| {
            std.debug.print("in the schema of {s}\n", .{case[0]});
            return err;
        };
    }
}

// a successful tools/call's parsed reply and its structured content
const Called = struct {
    parsed: std.json.Parsed(std.json.Value),
    content: std.json.Value,

    fn deinit(self: Called) void {
        self.parsed.deinit();
    }
};

// call `name` with `arguments`, which must succeed
fn structured(server: *mcp.Server, name: []const u8, arguments: []const u8) !Called {
    const out = try t.call(server, name, arguments);
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    errdefer parsed.deinit();
    const result = (parsed.value.object.get("result") orelse {
        std.debug.print("{s} {s}: {s}\n", .{ name, arguments, out });
        return error.TestExpectedResult;
    }).object;
    if (result.get("isError").?.bool) {
        std.debug.print("{s} {s}: {s}\n", .{ name, arguments, out });
        return error.TestExpectedSuccess;
    }
    return .{ .parsed = parsed, .content = result.get("structuredContent").? };
}

fn expectValue(expected: []const u8, value: std.json.Value) !void {
    const text = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(text);
    try t.expectJson(expected, text);
}

// a call of `name` with `arguments` succeeds with `expected` as its content
fn expectContent(server: *mcp.Server, name: []const u8, arguments: []const u8, expected: []const u8) !void {
    const called = try structured(server, name, arguments);
    defer called.deinit();
    expectValue(expected, called.content) catch |err| {
        std.debug.print("from {s} {s}\n", .{ name, arguments });
        return err;
    };
}

// `value` without the key `key` wherever it appears in an object, each one
// checked to be an integer between `low` and `high` first. the key must
// appear exactly `count` times, so a result that lost it doesn't compare
// equal to an expectation that leaves it out.
fn dropBetween(value: *std.json.Value, key: []const u8, low: i64, high: i64, count: usize) !void {
    const dropped = try dropAll(value, key, low, high);
    if (dropped != count) {
        std.debug.print("{s} appears {d} times, not {d}\n", .{ key, dropped, count });
        return error.TestExpectedKey;
    }
}

fn dropAll(value: *std.json.Value, key: []const u8, low: i64, high: i64) !usize {
    var dropped: usize = 0;
    switch (value.*) {
        .object => |*object| {
            if (object.get(key)) |found| {
                if (found != .integer or found.integer < low or found.integer > high) {
                    std.debug.print("{s} is {any}, not within {d}..{d}\n", .{ key, found, low, high });
                    return error.TestExpectedWithin;
                }
                _ = object.orderedRemove(key);
                dropped += 1;
            }
            var it = object.iterator();
            while (it.next()) |entry| dropped += try dropAll(entry.value_ptr, key, low, high);
        },
        .array => |array| for (array.items) |*item| {
            dropped += try dropAll(item, key, low, high);
        },
        else => {},
    }
    return dropped;
}

fn now() i64 {
    return std.Io.Timestamp.now(io, .real).toSeconds();
}

fn replace(text: []const u8, pairs: []const [2][]const u8) ![]u8 {
    var result = try allocator.dupe(u8, text);
    for (pairs) |pair| {
        const next = try std.mem.replaceOwned(u8, allocator, result, pair[0], pair[1]);
        allocator.free(result);
        result = next;
    }
    return result;
}

const discussion_id: fixture.Id = @splat(0x44);
const revision_id: fixture.Id = @splat(0x33);
const draft_id: fixture.Id = @splat(0x66);

// alice:open with files on master, a change on team/next recorded as a patch
// revision, a tag, a discussion and the patch tab on
fn arrange(data: *Server) !void {
    try data.setTabs(data.open, .read, .read, .read);
    try fixture.commitServerFiles(data, data.open, "master", &.{
        .{ .path = "README", .contents = "hello\nworld\n" },
        .{ .path = "src/main.zig", .contents = "const a = 1;\nconst b = 2;\n" },
        .{ .path = "50%41 café/x.txt", .contents = "x\n" },
    }, "add files");
    try fixture.commitServerFiles(data, data.open, "team/next", &.{.{ .path = "src/main.zig", .contents = "const a = 3;\nconst b = 2;\n" }}, "change a");
    try fixture.addServerRefs(data, data.open, .tag, &.{"v1.0"});
    try data.addEvent(data.open, Server.alice_author, discussion_id, .{ .discuss = .{ .title = "a talk", .description = "desc", .labels = "x" } });
    try fixture.addServerRevision(data, data.open, Server.bob_author, revision_id, "team/next");
}

test "mcp reads: get_repo, the file reads and list_refs answer what the repo holds" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try arrange(data);
    var bob = t.serverMode(data, data.bob);

    try expectContent(&bob, "get_repo", "{\"repo\":\"alice:open\"}",
        \\{"name":"open","owner_name":"alice","description":"","access":"public","discuss_role":"read","issue_role":"read","patch_role":"read","default_branch":"master","hash_kind":"sha1","role":"write"}
    );
    // directories first, each file with its first window
    try expectContent(&bob, "list_files", "{\"repo\":\"alice:open\"}",
        \\{"handle":{"location":{"repo":"alice:open"},"viewer":{"role":"write","email":"bob@example.test"},"read_access":"public"},
        \\ "ref_or_oid":"branch","ref_or_oid_value":"master","patchrev_id":null,"dir":"","selected_file":null,
        \\ "entries":[
        \\  {"name":"50%41 café","is_dir":true,"lines":[],"is_binary":false,"window_start":0,"has_more":false,"loaded":false},
        \\  {"name":"src","is_dir":true,"lines":[],"is_binary":false,"window_start":0,"has_more":false,"loaded":false},
        \\  {"name":"README","is_dir":false,"lines":["hello","world",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}],
        \\ "capped":false,"find":null,"find_available":false,"no_commits":false}
    );
    {
        const called = try structured(&bob, "list_files", "{\"repo\":\"alice:open\",\"ref_kind\":\"branch\",\"ref\":\"team/next\",\"path\":\"src\"}");
        defer called.deinit();
        try std.testing.expectEqualStrings("src", called.content.object.get("dir").?.string);
        try expectValue(
            \\[{"name":"main.zig","is_dir":false,"lines":["const a = 3;","const b = 2;",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}]
        , called.content.object.get("entries").?);
    }
    try expectContent(&bob, "read_file", "{\"repo\":\"alice:open\",\"path\":\"src/main.zig\"}",
        \\{"name":"main.zig","is_dir":false,"lines":["const a = 1;","const b = 2;",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}
    );
    // the path as it is, never decoded again
    try expectContent(&bob, "read_file", "{\"repo\":\"alice:open\",\"path\":\"50%41 café/x.txt\"}",
        \\{"name":"x.txt","is_dir":false,"lines":["x",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}
    );
    try expectContent(&bob, "read_file", "{\"repo\":\"alice:open\",\"ref_kind\":\"tag\",\"ref\":\"v1.0\",\"path\":\"README\",\"line\":2}",
        \\{"name":"README","is_dir":false,"lines":["world",""],"is_binary":false,"window_start":1,"has_more":false,"loaded":true}
    );
    // the events branch is a branch like any other
    try expectContent(&bob, "list_refs", "{\"repo\":\"alice:open\"}",
        \\{"names":["haxy/events","master","team/next"],"prev":null,"next":null}
    );
    try expectContent(&bob, "list_refs", "{\"repo\":\"alice:open\",\"kind\":\"tag\"}",
        \\{"names":["v1.0"],"prev":null,"next":null}
    );
}

test "mcp reads: the history reads answer a branch's log, a commit and its diff, and a revision's diff" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    const before = now();
    try arrange(data);
    const after = now();
    const master = (try data.readBranch(data.open, "master")).?;
    const next = (try data.readBranch(data.open, "team/next")).?;
    var bob = t.serverMode(data, data.bob);
    const commit =
        \\{"oid":"NEXT","parent_oid":"MASTER","message":"change a","message_truncated":false,"author":{"email":"tester@example.test"},"committer":{"unknown":{}},"merge":false,"stats":null}
    ;
    const hunks =
        \\[{"path":"src/main.zig","text":"1 -const a = 1;\n1 +const a = 3;\n2  const b = 2;\n3  ","prefixes":"-+  ","status":"changed"}]
    ;
    const pairs = [_][2][]const u8{ .{ "NEXT", next }, .{ "MASTER", master } };

    {
        const arguments = "{\"repo\":\"alice:open\",\"ref_kind\":\"branch\",\"ref\":\"team/next\"}";
        var called = try structured(&bob, "list_commits", arguments);
        defer called.deinit();
        try dropBetween(&called.content, "timestamp", before, after, 2);
        const expected = try replace("[" ++ commit ++
            \\,{"oid":"MASTER","parent_oid":"0000000000000000000000000000000000000000","message":"add files","message_truncated":false,"author":{"email":"tester@example.test"},"committer":{"unknown":{}},"merge":false,"stats":null}]
        , &pairs);
        defer allocator.free(expected);
        try expectValue(expected, called.content.object.get("commits").?);
        try std.testing.expectEqual(.null, called.content.object.get("next_start").?);
    }
    {
        const arguments = try replace("{\"repo\":\"alice:open\",\"oid\":\"NEXT\"}", &pairs);
        defer allocator.free(arguments);
        var called = try structured(&bob, "get_commit", arguments);
        defer called.deinit();
        try dropBetween(&called.content, "timestamp", before, after, 1);
        const expected = try replace(commit, &pairs);
        defer allocator.free(expected);
        try expectValue(expected, called.content);

        const diff = try replace(
            \\{"route":{"repo":{"identity":"alice:open","ref_or_oid":"object","value":"NEXT","base_oid":"MASTER"}},"path":"","window":{"hunks":
        ++ hunks ++
            \\,"start":0,"has_more":false,"truncated":false}}
        , &pairs);
        defer allocator.free(diff);
        try expectContent(&bob, "get_diff", arguments, diff);
    }
    {
        const diff = try replace(
            \\{"route":{"patchrev":{"identity":"alice:open","id":"33333333333333333333333333333333","base_oid":"MASTER"}},"path":"","window":{"hunks":
        ++ hunks ++
            \\,"start":0,"has_more":false,"truncated":false}}
        , &pairs);
        defer allocator.free(diff);
        try expectContent(&bob, "get_diff", "{\"repo\":\"alice:open\",\"patchrev\":\"33333333333333333333333333333333\"}", diff);
    }
}

test "mcp reads: list_discussions and list_events answer a repo's discussions and event history" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    const before = now();
    try arrange(data);
    const after = now();
    var bob = t.serverMode(data, data.bob);

    {
        var called = try structured(&bob, "list_discussions", "{\"repo\":\"alice:open\"}");
        defer called.deinit();
        try dropBetween(&called.content, "created_timestamp", before, after, 1);
        try expectValue(
            \\{"items":[{"id":"44444444444444444444444444444444",
            \\  "record":{"event":{"title":"a talk","description":"desc","labels":"x"},"removed":false,"author_email":"alice@example.test","created_order":1,"updated_order":1},
            \\  "author":{"user_name":"alice"},"comments":{"comments":[],"start":0,"count":0},"attachments":[],"assignees":[],"can_modify":true,"notify_action":"subscribe"}],
            \\ "prev_id":null,"next_id":null,"count":1,"more":false}
        , called.content);
    }
    // newest first, each with the page that shows it, if any
    try expectContent(&bob, "list_events", "{\"repo\":\"alice:open\"}",
        \\{"count":2,"events":[
        \\  {"id":"33333333333333333333333333333333","kind":"patchrev","author":{"user_name":"bob"},"view_url":null},
        \\  {"id":"44444444444444444444444444444444","kind":"discuss","author":{"user_name":"alice"},"view_url":"/alice:open/discuss:44444444444444444444444444444444"}],
        \\ "next":null}
    );
    try expectContent(&bob, "list_events", "{\"repo\":\"alice:open\",\"view\":\"removed\"}",
        \\{"count":0,"events":[],"next":null}
    );
}

test "mcp reads: list_users, list_repos and list_forks answer the server's accounts and what a user made" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try arrange(data);
    try data.addDraft(data.open, data.bob, Server.bob_author, draft_id);
    var carol = t.serverMode(data, data.carol);
    const alice_hex = std.fmt.bytesToHex(data.alice, .lower);

    // the removed account isn't listed
    try expectContent(&carol, "list_users", "{}",
        \\{"users":[{"name":"alice"},{"name":"bob"},{"name":"carol"}],"start":0,"next_start":null,"search":null}
    );
    try expectContent(&carol, "list_users", "{\"search\":\"b\"}",
        \\{"users":[{"name":"bob"}],"start":0,"next_start":null,"search":"b"}
    );
    {
        // a stranger sees only the public repo
        var called = try structured(&carol, "list_repos", "{\"user\":\"alice\"}");
        defer called.deinit();
        try dropBetween(&called.content, "created_order", 0, 1000, 1);
        try dropBetween(&called.content, "updated_order", 0, 1000, 1);
        const expected = try replace(
            \\{"repos":[{"event":{"user_id":"ALICE","name":"open","description":"","read_access":"public","discuss_role":"read","issue_role":"read","patch_role":"read","protected_branches":""},"removed":false}],
            \\ "start":0,"next_start":null,"search":null,"past_end":false}
        , &.{.{ "ALICE", &alice_hex }});
        defer allocator.free(expected);
        try expectValue(expected, called.content);
    }
    try expectContent(&carol, "list_forks", "{\"user\":\"bob\"}",
        \\{"forks":[{"id":"66666666666666666666666666666666","repo_name":"open","access":"public","title":"a draft"}],"start":0,"next_start":null,"past_end":false}
    );
}

test "mcp reads: a fork's files, log and diff are read through its fork_id" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try arrange(data);
    try data.addDraft(data.open, data.bob, Server.bob_author, draft_id);
    try fixture.commitForkFiles(data, data.bob, draft_id, &.{.{ .path = "fork.txt", .contents = "forked\n" }}, "on the fork");
    try data.pushDraft(data.bob, Server.bob_author, draft_id, "patch");
    var carol = t.serverMode(data, data.carol);
    const fork = "\"repo\":\"bob:open\",\"fork_id\":\"66666666666666666666666666666666\"";

    try expectContent(&carol, "read_file", "{" ++ fork ++ ",\"path\":\"fork.txt\"}",
        \\{"name":"fork.txt","is_dir":false,"lines":["forked",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}
    );
    {
        const called = try structured(&carol, "list_files", "{" ++ fork ++ "}");
        defer called.deinit();
        try expectValue(
            \\{"fork":{"identity":"bob:open","id":"66666666666666666666666666666666"}}
        , called.content.object.get("handle").?.object.get("location").?);
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(allocator);
        for (called.content.object.get("entries").?.array.items) |entry| try names.print(allocator, "{s} ", .{entry.object.get("name").?.string});
        try std.testing.expectEqualStrings("50%41 café src README fork.txt ", names.items);
    }
    {
        const called = try structured(&carol, "list_commits", "{" ++ fork ++ "}");
        defer called.deinit();
        const commits = called.content.object.get("commits").?.array.items;
        try std.testing.expectEqual(1, commits.len);
        try std.testing.expectEqualStrings("on the fork", commits[0].object.get("message").?.string);
    }
    {
        const called = try structured(&carol, "get_diff", "{" ++ fork ++ "}");
        defer called.deinit();
        const hunks = called.content.object.get("window").?.object.get("hunks").?.array.items;
        try std.testing.expectEqual(1, hunks.len);
        try std.testing.expectEqualStrings("fork.txt", hunks[0].object.get("path").?.string);
        try std.testing.expectEqualStrings("added", hunks[0].object.get("status").?.string);
    }
}

test "mcp reads: a missing repo, ref, path or commit and a private repo to a stranger are the same not found" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try arrange(data);
    try fixture.commitServerFiles(data, data.secret, "master", &.{.{ .path = "README", .contents = "secret\n" }}, "secret");
    var carol = t.serverMode(data, data.carol);
    var bob = t.serverMode(data, data.bob);
    const zeros = "0000000000000000000000000000000000000000";

    for ([_][2][]const u8{
        .{ "get_repo", "{\"repo\":\"alice:nothing\"}" },
        .{ "get_repo", "{\"repo\":\"alice:secret\"}" },
        .{ "list_files", "{\"repo\":\"alice:secret\"}" },
        .{ "read_file", "{\"repo\":\"alice:secret\",\"path\":\"README\"}" },
        .{ "list_refs", "{\"repo\":\"alice:secret\"}" },
        .{ "list_commits", "{\"repo\":\"alice:secret\"}" },
        .{ "list_discussions", "{\"repo\":\"alice:secret\"}" },
        .{ "list_files", "{\"repo\":\"alice:open\",\"ref_kind\":\"branch\",\"ref\":\"nothing\"}" },
        .{ "read_file", "{\"repo\":\"alice:open\",\"path\":\"nothing.txt\"}" },
        .{ "get_commit", "{\"repo\":\"alice:open\",\"oid\":\"" ++ zeros ++ "\"}" },
        .{ "get_diff", "{\"repo\":\"alice:open\",\"oid\":\"" ++ zeros ++ "\"}" },
        .{ "list_refs", "{\"repo\":\"alice:open\",\"from\":\"nothing\"}" },
        // the event history needs write access
        .{ "list_events", "{\"repo\":\"alice:open\"}" },
        .{ "list_repos", "{\"user\":\"nobody\"}" },
        .{ "list_forks", "{\"user\":\"dave\"}" },
        .{ "list_users", "{\"start\":40}" },
        .{ "list_files", "{\"repo\":\"bob:open\",\"fork_id\":\"77777777777777777777777777777777\"}" },
    }) |case| {
        const text = try std.fmt.allocPrint(allocator, "{s} failed (not_found): NotFound", .{case[0]});
        defer allocator.free(text);
        t.expectToolError(&carol, case[0], case[1], text) catch |err| {
            std.debug.print("from {s} {s}\n", .{ case[0], case[1] });
            return err;
        };
    }
    // the member reads what the stranger doesn't find
    {
        const called = try structured(&bob, "read_file", "{\"repo\":\"alice:secret\",\"path\":\"README\"}");
        called.deinit();
    }
    try t.expectToolError(&bob, "read_file", "{\"repo\":\"alice:open\",\"path\":\"src\"}", "read_file failed (invalid_input): NotAFile");
    try t.expectToolError(&bob, "read_file", "{\"repo\":\"alice:open\",\"path\":\"\"}", "read_file failed (invalid_input): NotAFile");
    try t.expectToolError(&bob, "list_files", "{\"repo\":\"alice:open\",\"path\":\"README\"}", "list_files failed (invalid_input): NotADirectory");
}

test "mcp reads: arguments the read schemas don't allow are invalid params" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    var bob = t.serverMode(data, data.bob);

    for ([_][3][]const u8{
        .{ "read_file", "{\"repo\":\"alice:open\",\"path\":\"README\",\"find\":\"READ\"}", "unknown field find" },
        .{ "read_file", "{\"repo\":\"alice:open\",\"path\":\"README\",\"line\":-1}", "line must be an integer in range" },
        .{ "list_files", "{\"repo\":\"alice:open\",\"ref_kind\":\"commit\"}", "ref_kind must be one of branch, tag, object" },
        .{ "list_refs", "{\"repo\":\"alice:open\",\"kind\":\"object\"}", "kind must be one of branch, tag" },
        .{ "list_events", "{\"repo\":\"alice:open\",\"from_kind\":\"thread\"}", "from_kind must be one of user, repo, fork, grant, notify, discuss, issue, comment, attach, assign, patchrev, patch" },
        .{ "list_events", "{\"repo\":\"alice:open\",\"moment\":-1}", "moment must be an integer in range" },
        .{ "list_events", "{\"repo\":\"alice:open\",\"view\":\"all\"}", "view must be one of active, removed" },
        .{ "get_diff", "{\"repo\":\"alice:open\",\"start\":0.5}", "start must be an integer in range" },
        .{ "list_users", "{\"start\":\"20\"}", "start must be an integer in range" },
    }) |case| {
        const out = try t.call(&bob, case[0], case[1]);
        defer allocator.free(out);
        const expected = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":1,"error":{{"code":-32602,"message":"invalid arguments for {s}: {s}"}}}}
        , .{ case[0], case[2] });
        defer allocator.free(expected);
        try t.expectJsonLine(expected, out);
    }
}

test "mcp reads: in local mode the account reads answer unavailable without bringing the repo up to date" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    // an issue fetched from elsewhere, which a refresh would consume
    try local.commitUnconsumed(Server.alice_author, @splat(0x11), .{ .issue = .{ .title = "fetched", .description = "", .labels = "" } });
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    try t.expectToolError(&server, "list_users", "{}", "list_users failed (unavailable_here): UnavailableHere");
    try t.expectToolError(&server, "list_repos", "{\"user\":\"alice\"}", "list_repos failed (unavailable_here): UnavailableHere");
    try t.expectToolError(&server, "list_forks", "{\"user\":\"alice\"}", "list_forks failed (unavailable_here): UnavailableHere");
    try std.testing.expectEqual(0, try t.consumedIssueCount(&local));
    // a fork is a server's
    try t.expectToolError(&server, "list_files", "{\"repo\":\"\",\"fork_id\":\"66666666666666666666666666666666\"}", "list_files failed (unavailable_here): UnavailableHere");
}

fn expectLocalReads(comptime kind: hx.xit.repo.RepoKind) !void {
    var local = try fixture.Local(kind, .sha1).init();
    defer local.deinit();
    const first = local.master_oid;
    try fixture.commitLocalFiles(kind, &local, "master", &.{.{ .path = "src/main.zig", .contents = "const a = 1;\n" }}, "add main");
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const second = try fixture.localBranchOid(kind, &local, arena.allocator(), "master");
    try fixture.addLocalRefs(kind, &local, .tag, &.{"v1"});
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    {
        const called = try structured(&server, "get_repo", "{\"repo\":\"\"}");
        defer called.deinit();
        const expected = try std.fmt.allocPrint(allocator,
            \\{{"name":"{s}","owner_name":"","description":"","access":"private","discuss_role":"read","issue_role":"read","patch_role":"read","default_branch":"master","hash_kind":"sha1","role":"owner"}}
        , .{std.Io.Dir.path.basename(local.path)});
        defer allocator.free(expected);
        try expectValue(expected, called.content);
    }
    {
        const called = try structured(&server, "list_files", "{\"repo\":\"\"}");
        defer called.deinit();
        var names: std.ArrayList(u8) = .empty;
        defer names.deinit(allocator);
        for (called.content.object.get("entries").?.array.items) |entry| try names.print(allocator, "{s} ", .{entry.object.get("name").?.string});
        try std.testing.expectEqualStrings("src readme.txt ", names.items);
    }
    try expectContent(&server, "read_file", "{\"repo\":\"\",\"path\":\"src/main.zig\"}",
        \\{"name":"main.zig","is_dir":false,"lines":["const a = 1;",""],"is_binary":false,"window_start":0,"has_more":false,"loaded":true}
    );
    try expectContent(&server, "list_refs", "{\"repo\":\"\",\"kind\":\"tag\"}",
        \\{"names":["v1"],"prev":null,"next":null}
    );
    {
        const called = try structured(&server, "list_commits", "{\"repo\":\"\"}");
        defer called.deinit();
        const commits = called.content.object.get("commits").?.array.items;
        try std.testing.expectEqual(2, commits.len);
        try std.testing.expectEqualStrings(second, commits[0].object.get("oid").?.string);
        try std.testing.expectEqualStrings(&first, commits[1].object.get("oid").?.string);
    }
    {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"\",\"oid\":\"{s}\"}}", .{second});
        defer allocator.free(arguments);
        const commit = try structured(&server, "get_commit", arguments);
        defer commit.deinit();
        try std.testing.expectEqualStrings("add main", commit.content.object.get("message").?.string);
        try std.testing.expectEqualStrings(&first, commit.content.object.get("parent_oid").?.string);
        const diff = try structured(&server, "get_diff", arguments);
        defer diff.deinit();
        // an added file's hunk names it without its lines
        try expectValue(
            \\[{"path":"src/main.zig","text":"","prefixes":"","status":"added"}]
        , diff.content.object.get("window").?.object.get("hunks").?);
    }
}

test "mcp reads: in local mode the file reads, the history reads and list_refs read the repo haxy mcp runs in" {
    try expectLocalReads(.git);
    try expectLocalReads(.xit);
}

// paging: each walk feeds back the cursor the previous window carried and
// sees every item once, in order

test "mcp reads: read_file pages through a long file by line" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    var contents: std.ArrayList(u8) = .empty;
    defer contents.deinit(allocator);
    for (1..12001) |i| try contents.print(allocator, "l{d}\n", .{i});
    try fixture.commitServerFiles(data, data.open, "master", &.{.{ .path = "long.txt", .contents = contents.items }}, "long");
    var bob = t.serverMode(data, data.bob);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var line: usize = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"path\":\"long.txt\",\"line\":{d}}}", .{line});
        defer allocator.free(arguments);
        const called = try structured(&bob, "read_file", arguments);
        defer called.deinit();
        const lines = called.content.object.get("lines").?.array.items;
        for (lines) |l| try seen.print(allocator, "{s}\n", .{l.string});
        if (!called.content.object.get("has_more").?.bool) break;
        // window_start counts from 0 and `line` from 1
        line = @as(usize, @intCast(called.content.object.get("window_start").?.integer)) + lines.len + 1;
    }
    try std.testing.expectEqual(3, windows);
    // the file's lines, then the empty line after its last newline
    try std.testing.expectEqualStrings(contents.items, seen.items[0 .. seen.items.len - 1]);
    try std.testing.expectEqualStrings("\n", seen.items[seen.items.len - 1 ..]);
}

test "mcp reads: list_refs pages through the branches by next" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try data.commitReadme(data.open);
    var names: [120][]const u8 = undefined;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    for (&names, 0..) |*name, i| name.* = try std.fmt.allocPrint(arena.allocator(), "b{d:0>3}", .{i});
    try fixture.addServerRefs(data, data.open, .branch, &names);
    var bob = t.serverMode(data, data.bob);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (names) |name| try expected.print(allocator, "{s} ", .{name});
    if (try data.readBranch(data.open, "haxy/events") != null) try expected.appendSlice(allocator, "haxy/events ");
    try expected.appendSlice(allocator, "master ");

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var from: []const u8 = "";
    var windows: usize = 1;
    var owned: ?[]u8 = null;
    defer if (owned) |o| allocator.free(o);
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"from\":\"{s}\"}}", .{from});
        defer allocator.free(arguments);
        const called = try structured(&bob, "list_refs", arguments);
        defer called.deinit();
        for (called.content.object.get("names").?.array.items) |name| try seen.print(allocator, "{s} ", .{name.string});
        const next = called.content.object.get("next").?;
        if (next == .null) break;
        if (owned) |o| allocator.free(o);
        owned = try allocator.dupe(u8, next.string);
        from = owned.?;
    }
    try std.testing.expectEqual(3, windows);
    try std.testing.expectEqualStrings(expected.items, seen.items);
}

test "mcp reads: list_commits pages through a log by next_start" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    for (0..45) |i| {
        var buffer: [8]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "c{d:0>2}", .{i});
        try fixture.commitServerFiles(data, data.open, "master", &.{.{ .path = "README", .contents = message }}, message);
    }
    var bob = t.serverMode(data, data.bob);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (0..45) |i| try expected.print(allocator, "c{d:0>2} ", .{44 - i});
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var from: [40]u8 = undefined;
    var from_len: usize = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"from\":\"{s}\"}}", .{from[0..from_len]});
        defer allocator.free(arguments);
        const called = try structured(&bob, "list_commits", arguments);
        defer called.deinit();
        for (called.content.object.get("commits").?.array.items) |commit| try seen.print(allocator, "{s} ", .{commit.object.get("message").?.string});
        const next = called.content.object.get("next_start").?;
        if (next == .null) break;
        @memcpy(from[0..next.string.len], next.string);
        from_len = next.string.len;
    }
    try std.testing.expectEqual(3, windows);
    try std.testing.expectEqualStrings(expected.items, seen.items);
}

test "mcp reads: get_diff pages through a diff's hunks by start, a file's hunks across a window boundary named again" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // 25 files of one hunk each and, between f08 and f09, one of three
    // hunks, the 10th to 12th of the diff, so the first window ends inside it
    var before: std.ArrayList(fixture.TreeFile) = .empty;
    var after: std.ArrayList(fixture.TreeFile) = .empty;
    for (0..25) |i| {
        const path = try std.fmt.allocPrint(aa, "f{d:0>2}", .{i});
        try before.append(aa, .{ .path = path, .contents = "old\n" });
        try after.append(aa, .{ .path = path, .contents = "new\n" });
    }
    var old_lines: std.ArrayList(u8) = .empty;
    var new_lines: std.ArrayList(u8) = .empty;
    for (1..41) |n| {
        try old_lines.print(aa, "l{d}\n", .{n});
        try new_lines.print(aa, "{s}{d}\n", .{ if (n == 1 or n == 20 or n == 40) "changed" else "l", n });
    }
    try before.append(aa, .{ .path = "f08z", .contents = old_lines.items });
    try after.append(aa, .{ .path = "f08z", .contents = new_lines.items });
    try fixture.commitServerFiles(data, data.open, "master", before.items, "before");
    try fixture.commitServerFiles(data, data.open, "master", after.items, "after");
    const head = (try data.readBranch(data.open, "master")).?;
    var bob = t.serverMode(data, data.bob);

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (0..9) |i| try expected.print(allocator, "f{d:0>2} ", .{i});
    try expected.appendSlice(allocator, "f08z f08z f08z ");
    for (9..25) |i| try expected.print(allocator, "f{d:0>2} ", .{i});
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var start: usize = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"oid\":\"{s}\",\"start\":{d}}}", .{ head, start });
        defer allocator.free(arguments);
        const called = try structured(&bob, "get_diff", arguments);
        defer called.deinit();
        const window = called.content.object.get("window").?.object;
        const hunks = window.get("hunks").?.array.items;
        // as the description says: a window's first hunk names its file, and
        // a null path continues the file of the hunk before
        var file: ?[]const u8 = null;
        for (hunks) |hunk| {
            switch (hunk.object.get("path").?) {
                .string => |path| file = path,
                .null => {},
                else => return error.TestExpectedPath,
            }
            try seen.print(allocator, "{s} ", .{file orelse return error.TestExpectedPath});
        }
        if (!window.get("has_more").?.bool) break;
        start += hunks.len;
    }
    try std.testing.expectEqual(3, windows);
    try std.testing.expectEqualStrings(expected.items, seen.items);
}

// 45 discussions in alice:open, the nth with the id of n repeated
fn addDiscussions(data: *Server) !void {
    for (1..46) |i| {
        try data.addEvent(data.open, Server.alice_author, @splat(@intCast(i)), .{ .discuss = .{ .title = "talk", .description = "", .labels = "" } });
    }
}

// the hex ids of the discussions `addDiscussions` adds, newest first
fn discussionIds() ![]u8 {
    var expected: std.ArrayList(u8) = .empty;
    errdefer expected.deinit(allocator);
    for (0..45) |i| {
        const id: fixture.Id = @splat(@intCast(45 - i));
        try expected.print(allocator, "{s} ", .{std.fmt.bytesToHex(id, .lower)});
    }
    return try expected.toOwnedSlice(allocator);
}

test "mcp reads: list_discussions pages through the discussions by next_id" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try addDiscussions(data);
    var bob = t.serverMode(data, data.bob);

    const expected = try discussionIds();
    defer allocator.free(expected);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var from: [32]u8 = undefined;
    var from_len: usize = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"from\":\"{s}\"}}", .{from[0..from_len]});
        defer allocator.free(arguments);
        const called = try structured(&bob, "list_discussions", arguments);
        defer called.deinit();
        for (called.content.object.get("items").?.array.items) |item| try seen.print(allocator, "{s} ", .{item.object.get("id").?.string});
        const next = called.content.object.get("next_id").?;
        if (next == .null) break;
        @memcpy(from[0..next.string.len], next.string);
        from_len = next.string.len;
    }
    try std.testing.expectEqual(3, windows);
    try std.testing.expectEqualStrings(expected, seen.items);
}

test "mcp reads: list_events pages through the event history by next's id and kind" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try addDiscussions(data);
    var bob = t.serverMode(data, data.bob);

    const expected = try discussionIds();
    defer allocator.free(expected);
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var cursor: []u8 = try allocator.dupe(u8, "");
    defer allocator.free(cursor);
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\"{s}}}", .{cursor});
        defer allocator.free(arguments);
        const called = try structured(&bob, "list_events", arguments);
        defer called.deinit();
        for (called.content.object.get("events").?.array.items) |event| try seen.print(allocator, "{s} ", .{event.object.get("id").?.string});
        const next = called.content.object.get("next").?;
        if (next == .null) break;
        allocator.free(cursor);
        cursor = try std.fmt.allocPrint(allocator, ",\"from\":\"{s}\",\"from_kind\":\"{s}\"", .{ next.object.get("id").?.string, next.object.get("kind").?.string });
    }
    try std.testing.expectEqual(3, windows);
    try std.testing.expectEqualStrings(expected, seen.items);
}

// walk a start-paged account read of `name` with `arguments` (without the
// braces) through every window, writing `field` of each row of `rows` to
// `seen`. returns the number of windows.
fn walkStart(server: *mcp.Server, name: []const u8, arguments: []const u8, rows: []const u8, field: ?[]const u8, seen: *std.ArrayList(u8)) !usize {
    var start: i64 = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const line = try std.fmt.allocPrint(allocator, "{{{s}\"start\":{d}}}", .{ arguments, start });
        defer allocator.free(line);
        const called = try structured(server, name, line);
        defer called.deinit();
        for (called.content.object.get(rows).?.array.items) |row| {
            const value = if (field) |f| row.object.get(f).? else row.object.get("event").?.object.get("name").?;
            try seen.print(allocator, "{s} ", .{value.string});
        }
        const next = called.content.object.get("next_start").?;
        if (next == .null) return windows;
        start = next.integer;
    }
}

test "mcp reads: list_users pages through the accounts by next_start" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    try expected.appendSlice(allocator, "alice bob carol ");
    for (0..25) |i| {
        var name_buffer: [8]u8 = undefined;
        var email_buffer: [32]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "user{d:0>2}", .{i});
        _ = try hx.event.createUser(io, allocator, data.users_dir, &data.admin, name, try std.fmt.bufPrint(&email_buffer, "{s}@example.test", .{name}), "password", "password");
        try expected.print(allocator, "{s} ", .{name});
    }
    var carol = t.serverMode(data, data.carol);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    try std.testing.expectEqual(2, try walkStart(&carol, "list_users", "", "users", "name", &seen));
    try std.testing.expectEqualStrings(expected.items, seen.items);
}

test "mcp reads: list_repos pages through a user's repos by next_start" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    for (0..23) |i| {
        var buffer: [8]u8 = undefined;
        _ = try hx.event.createRepo(io, allocator, data.users_dir, &data.alice, Server.alice_author, try std.fmt.bufPrint(&buffer, "r{d:0>2}", .{i}), "", .public, .sha1, null);
    }
    var alice = t.serverMode(data, data.alice);

    // by name when searching
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (0..23) |i| try expected.print(allocator, "r{d:0>2} ", .{i});
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    try std.testing.expectEqual(2, try walkStart(&alice, "list_repos", "\"user\":\"alice\",\"search\":\"r\",", "repos", null, &seen));
    try std.testing.expectEqualStrings(expected.items, seen.items);
    // most recently active first, to the second, so the repos made within
    // one come in no order of their own: each is seen once
    seen.clearRetainingCapacity();
    try std.testing.expectEqual(2, try walkStart(&alice, "list_repos", "\"user\":\"alice\",", "repos", null, &seen));
    try expected.appendSlice(allocator, "secret open ");
    try expectEachOnce(seen.items, expected.items);
}

test "mcp reads: list_forks pages through a user's forks by next_start" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try data.setTabs(data.open, .read, .read, .read);
    try data.commitReadme(data.open);
    for (1..26) |i| try data.addDraft(data.open, data.bob, Server.bob_author, @splat(@intCast(i)));
    var bob = t.serverMode(data, data.bob);

    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    try std.testing.expectEqual(2, try walkStart(&bob, "list_forks", "\"user\":\"bob\",", "forks", "id", &seen));
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (1..26) |i| {
        const id: fixture.Id = @splat(@intCast(i));
        try expected.print(allocator, "{s} ", .{std.fmt.bytesToHex(id, .lower)});
    }
    try expectEachOnce(seen.items, expected.items);
}

// `seen` and `expected`, space-separated words, hold the same words, each once
fn expectEachOnce(seen: []const u8, expected: []const u8) !void {
    var it = std.mem.tokenizeScalar(u8, seen, ' ');
    var count: usize = 0;
    while (it.next()) |word| : (count += 1) {
        const padded = try std.fmt.allocPrint(allocator, " {s} ", .{word});
        defer allocator.free(padded);
        const in_seen = try std.fmt.allocPrint(allocator, " {s}", .{seen});
        defer allocator.free(in_seen);
        const in_expected = try std.fmt.allocPrint(allocator, " {s}", .{expected});
        defer allocator.free(in_expected);
        try std.testing.expectEqual(1, std.mem.count(u8, in_seen, padded));
        try std.testing.expectEqual(1, std.mem.count(u8, in_expected, padded));
    }
    try std.testing.expectEqual(std.mem.count(u8, expected, " "), count);
}

// the length of the reply line to a call of `name` with `arguments`, whose
// result holds `rows` items at `path`
fn replyLen(server: *mcp.Server, name: []const u8, arguments: []const u8, comptime path: []const []const u8, rows: usize) !usize {
    const out = try t.call(server, name, arguments);
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    var value = parsed.value.object.get("result").?.object.get("structuredContent").?;
    inline for (path) |key| value = value.object.get(key).?;
    try std.testing.expectEqual(rows, value.array.items.len);
    return out.len;
}

// the longest reply that fits a line the stdio transport reads, with room.
// the bound is on requests: nothing bounds a reply.
fn expectFits(len: usize) !void {
    if (len > mcp.stdio.max_line_len - (2 << 20)) {
        std.debug.print("a reply of {d} bytes\n", .{len});
        return error.TestExpectedFit;
    }
}

test "mcp reads: the worst file and diff windows fit a stdio line, and the worst directory listing doesn't" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    // as many lines of the widest kind a window holds, of control bytes,
    // which json escapes six bytes wide in the result and seven in its text
    // block: valid utf-8, so text, not binary
    const control = try aa.alloc(u8, 5001 * 200);
    const changed = try aa.alloc(u8, 5001 * 200);
    for (0..5001) |i| {
        @memset(control[i * 200 ..][0..199], 0x01);
        @memset(changed[i * 200 ..][0..199], 0x02);
        for ([_][]u8{ control, changed }) |contents| contents[i * 200 + 199] = '\n';
    }
    // a directory over the listing's cap whose first files fill the preload
    // budget, ten changed files, and one file
    var files: std.ArrayList(fixture.TreeFile) = .empty;
    for (0..4) |i| try files.append(aa, .{ .path = try std.fmt.allocPrint(aa, "dir/a{d}", .{i}), .contents = control });
    for (0..997) |i| try files.append(aa, .{ .path = try std.fmt.allocPrint(aa, "dir/z{d:0>4}", .{i}), .contents = "z\n" });
    for (0..10) |i| try files.append(aa, .{ .path = try std.fmt.allocPrint(aa, "diff/d{d}", .{i}), .contents = control });
    try files.append(aa, .{ .path = "control.txt", .contents = control });
    // an add of many files at once overflows xit's index buffer
    var i: usize = 0;
    while (i < files.items.len) : (i += 100) try fixture.commitServerFiles(data, data.open, "master", files.items[i..@min(i + 100, files.items.len)], "files");
    var after: [10]fixture.TreeFile = undefined;
    for (&after, 0..) |*file, j| file.* = .{ .path = try std.fmt.allocPrint(aa, "diff/d{d}", .{j}), .contents = changed };
    try fixture.commitServerFiles(data, data.open, "master", &after, "change");
    const head = (try data.readBranch(data.open, "master")).?;
    var bob = t.serverMode(data, data.bob);

    try expectFits(try replyLen(&bob, "read_file", "{\"repo\":\"alice:open\",\"path\":\"control.txt\"}", &.{"lines"}, 5000));
    const diff = try std.fmt.allocPrint(aa, "{{\"repo\":\"alice:open\",\"oid\":\"{s}\"}}", .{head});
    // the window stops short of ten hunks at its cell budget
    try expectFits(try replyLen(&bob, "get_diff", diff, &.{ "window", "hunks" }, 9));

    // a known defect, recorded for phase 6: the directory listing preloads
    // about 4 MB of file content, which escapes past the 16 MiB a request
    // line may hold (39.2 MB measured). the stdio transport writes it whole,
    // as one line, since nothing bounds a reply.
    const listing = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"list_files\",\"arguments\":{\"repo\":\"alice:open\",\"path\":\"dir\"}}}\n";
    var in: std.Io.Reader = .fixed(listing);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var err: std.Io.Writer.Allocating = .init(allocator);
    defer err.deinit();
    try mcp.stdio.run(&bob, &in, &out.writer, &err.writer);
    const written = out.written();
    try std.testing.expect(written.len > mcp.stdio.max_line_len);
    try std.testing.expectEqual(written.len - 1, std.mem.indexOfScalar(u8, written, '\n').?);
    try std.testing.expectEqualStrings("", err.written());
    try std.testing.expectEqual(written.len, try replyLen(&bob, "list_files", "{\"repo\":\"alice:open\",\"path\":\"dir\"}", &.{"entries"}, 1000));
}

test "mcp reads: list_commits pages through a merge's log by next_start" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try data.commitReadme(data.open);
    // a side branch of 25 commits merged into a master that moved on
    for (0..25) |i| {
        var buffer: [8]u8 = undefined;
        const message = try std.fmt.bufPrint(&buffer, "s{d:0>2}", .{i});
        try fixture.commitServerFiles(data, data.open, "side", &.{.{ .path = "side.txt", .contents = message }}, message);
    }
    try fixture.commitServerFiles(data, data.open, "master", &.{.{ .path = "main.txt", .contents = "main\n" }}, "on master");
    try fixture.mergeServerBranch(data, data.open, "side");
    const merge = (try data.readBranch(data.open, "master")).?;
    var bob = t.serverMode(data, data.bob);

    // what it brought in, from its second parent back to the common ancestor
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(allocator);
    for (0..25) |i| try expected.print(allocator, "s{d:0>2} ", .{24 - i});
    var seen: std.ArrayList(u8) = .empty;
    defer seen.deinit(allocator);
    var from: [40]u8 = undefined;
    var from_len: usize = 0;
    var windows: usize = 1;
    while (true) : (windows += 1) {
        const arguments = try std.fmt.allocPrint(allocator, "{{\"repo\":\"alice:open\",\"merge\":\"{s}\",\"from\":\"{s}\"}}", .{ merge, from[0..from_len] });
        defer allocator.free(arguments);
        const called = try structured(&bob, "list_commits", arguments);
        defer called.deinit();
        for (called.content.object.get("commits").?.array.items) |commit| try seen.print(allocator, "{s} ", .{commit.object.get("message").?.string});
        const next = called.content.object.get("next_start").?;
        if (next == .null) break;
        @memcpy(from[0..next.string.len], next.string);
        from_len = next.string.len;
    }
    try std.testing.expectEqual(2, windows);
    try std.testing.expectEqualStrings(expected.items, seen.items);
}

test "mcp reads: inputs that contradict each other or are incomplete are invalid input, not not found" {
    const data = try Server.init(.sha1);
    defer data.deinit();
    try arrange(data);
    try data.addDraft(data.open, data.bob, Server.bob_author, draft_id);
    var bob = t.serverMode(data, data.bob);
    const master = (try data.readBranch(data.open, "master")).?;
    const revision = "33333333333333333333333333333333";
    const fork = "66666666666666666666666666666666";

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    for ([_][2][]const u8{
        // a ref without its kind, and a kind without its ref
        .{ "read_file", "{\"repo\":\"alice:open\",\"path\":\"README\",\"ref\":\"master\"}" },
        .{ "list_files", "{\"repo\":\"alice:open\",\"ref_kind\":\"branch\"}" },
        .{ "list_commits", "{\"repo\":\"alice:open\",\"ref\":\"master\"}" },
        // a revision names its own tree and base
        .{ "list_files", "{\"repo\":\"alice:open\",\"patchrev\":\"" ++ revision ++ "\",\"ref_kind\":\"branch\",\"ref\":\"master\"}" },
        .{ "get_diff", "{\"repo\":\"alice:open\",\"patchrev\":\"" ++ revision ++ "\",\"base\":\"MASTER\"}" },
        // a diff of neither or both
        .{ "get_diff", "{\"repo\":\"alice:open\"}" },
        .{ "get_diff", "{\"repo\":\"alice:open\",\"oid\":\"MASTER\",\"patchrev\":\"" ++ revision ++ "\"}" },
        // a merge's log takes no base
        .{ "list_commits", "{\"repo\":\"alice:open\",\"merge\":\"MASTER\",\"base\":\"MASTER\"}" },
        // a fork has no branch to name
        .{ "list_files", "{\"repo\":\"bob:open\",\"fork_id\":\"" ++ fork ++ "\",\"ref_kind\":\"branch\",\"ref\":\"master\"}" },
        // a cursor without its kind
        .{ "list_events", "{\"repo\":\"alice:open\",\"from\":\"" ++ revision ++ "\"}" },
        // the drafts take no search
        .{ "list_patches", "{\"repo\":\"alice:open\",\"view\":\"drafts\",\"search\":\"x\"}" },
    }) |case| {
        const arguments = try replace(case[1], &.{.{ "MASTER", master }});
        defer allocator.free(arguments);
        // the text names the error, not which input
        const text = try std.fmt.allocPrint(aa, "{s} failed (invalid_input): InvalidReadArguments", .{case[0]});
        t.expectToolError(&bob, case[0], arguments, text) catch |err| {
            std.debug.print("from {s} {s}\n", .{ case[0], arguments });
            return err;
        };
    }
}

test "mcp reads: a damaged object is an internal tool error, not a missing file" {
    var local = try fixture.Local(.git, .sha1).init();
    defer local.deinit();
    // the blob of "hello\n", as git hash-object names it
    try fixture.corruptGitObject(&local, "ce013625030ba8dba906f756967f9e9ca394464a");
    var server = mcp.Server{ .io = io, .gpa = allocator, .mode = .{ .local = local.source() } };

    const out = try t.call(&server, "read_file", "{\"repo\":\"\",\"path\":\"readme.txt\"}");
    defer allocator.free(out);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, out, .{});
    defer parsed.deinit();
    // a tool error, as any failure of the operation is, classified internal
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    if (!std.mem.startsWith(u8, text, "read_file failed (internal): ")) {
        std.debug.print("{s}\n", .{text});
        return error.TestExpectedInternal;
    }
}
