//! the mcp server: json-rpc requests in, the domain operations as tools.

const std = @import("std");
const domain = @import("./domain.zig");
const xit = @import("xit");
const rp = xit.repo;
const evt = @import("./event.zig");
pub const jsonrpc = @import("./mcp/jsonrpc.zig");
pub const stdio = @import("./mcp/stdio.zig");

pub const server_name = "haxy";
// build.zig.zon's version, which src/ can't import
pub const server_version = "0.0.0";

// the protocol versions this server speaks, newest first
pub const protocol_versions = [_][]const u8{"2025-06-18"};

pub const Server = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    mode: Mode,
    // whether the removal tools are listed and callable
    allow_destructive: bool = false,

    // answer the json-rpc message `line` holds, writing zero or one response
    // line to `out`
    pub fn handle(self: *Server, line: []const u8, out: *std.Io.Writer) !void {
        var arena = std.heap.ArenaAllocator.init(self.gpa);
        defer arena.deinit();
        const request = switch (try jsonrpc.parse(arena.allocator(), line)) {
            .request => |request| request,
            .invalid => |invalid| return try jsonrpc.writeError(out, invalid.id, invalid.code, invalid.message),
        };
        const id = request.id orelse return;
        if (std.mem.eql(u8, request.method, "initialize")) {
            const requested = initializeVersion(request.params) orelse
                return try jsonrpc.writeError(out, id, .invalid_params, "initialize needs a protocolVersion string, a capabilities object and a clientInfo object");
            try jsonrpc.writeResult(out, id, .{
                .protocolVersion = negotiateVersion(requested),
                .capabilities = .{ .tools = Empty{} },
                .serverInfo = .{ .name = server_name, .version = server_version },
            });
        } else if (std.mem.eql(u8, request.method, "tools/list")) {
            try jsonrpc.writeResult(out, id, ToolList{ .allow_destructive = self.allow_destructive });
        } else if (std.mem.eql(u8, request.method, "tools/call")) {
            try self.callTool(arena.allocator(), id, request.params, out);
        } else if (std.mem.eql(u8, request.method, "ping")) {
            try jsonrpc.writeResult(out, id, Empty{});
        } else {
            try jsonrpc.writeError(out, id, .method_not_found, try std.fmt.allocPrint(arena.allocator(), "method not found: {s}", .{request.method}));
        }
    }

    // answer a tools/call request. `arena` holds the request.
    fn callTool(self: *Server, arena: std.mem.Allocator, id: jsonrpc.Id, params: ?std.json.Value, out: *std.Io.Writer) !void {
        const object = switch (params orelse .null) {
            .object => |object| object,
            else => return try jsonrpc.writeError(out, id, .invalid_params, "tools/call needs params"),
        };
        const name = switch (object.get("name") orelse .null) {
            .string => |string| string,
            else => return try jsonrpc.writeError(out, id, .invalid_params, "tools/call needs a tool name"),
        };
        // a tool without arguments may leave them out
        const arguments = object.get("arguments") orelse std.json.Value{ .object = .empty };
        inline for (tools) |tool| {
            // a removal not allowed is no tool at all
            if (std.mem.eql(u8, name, tool.Operation.tool_name) and self.serves(tool)) return try self.runTool(tool.Operation, arena, id, arguments, out);
        }
        try jsonrpc.writeError(out, id, .invalid_params, try std.fmt.allocPrint(arena, "unknown tool: {s}", .{name}));
    }

    // whether this server lists and calls `tool`
    fn serves(self: *const Server, comptime tool: Tool) bool {
        return !tool.removal or self.allow_destructive;
    }

    fn runTool(self: *Server, comptime Operation: type, arena: std.mem.Allocator, id: jsonrpc.Id, arguments: std.json.Value, out: *std.Io.Writer) !void {
        // std.json coerces what the schema forbids (enum tags from integers,
        // strings from byte arrays, integers from strings), so the arguments
        // are held to the schema first
        if (try checkArguments(Operation, arena, arguments)) |problem| {
            return try jsonrpc.writeError(out, id, .invalid_params, try std.fmt.allocPrint(arena, "invalid arguments for {s}: {s}", .{ Operation.tool_name, problem }));
        }
        const input = std.json.parseFromValueLeaky(Operation, arena, arguments, .{ .ignore_unknown_fields = false }) catch |err| switch (err) {
            error.OutOfMemory => |e| return e,
            else => return try jsonrpc.writeError(out, id, .invalid_params, try std.fmt.allocPrint(arena, "invalid arguments for {s}: {t}", .{ Operation.tool_name, err })),
        };
        // the result's lifetime: this call
        var call_arena = std.heap.ArenaAllocator.init(self.gpa);
        defer call_arena.deinit();
        // an adapter turns its arguments into what the operation takes, or
        // refuses them like the schema would
        // preparing failing, like the host failing below, is no tool result
        const prepared = if (@hasDecl(Operation, "prepare")) input.prepare(call_arena.allocator()) catch |err| {
            return try jsonrpc.writeError(out, id, .internal_error, try std.fmt.allocPrint(arena, "internal error: {t}", .{err}));
        } else {};
        const ready = if (@hasDecl(Operation, "prepare")) switch (prepared) {
            .ready => |ready| ready,
            .invalid => |problem| return try jsonrpc.writeError(out, id, .invalid_params, try std.fmt.allocPrint(arena, "invalid arguments for {s}: {s}", .{ Operation.tool_name, problem })),
        } else input;
        var admin: ?AdminRepo = null;
        defer if (admin) |*repo| repo.deinit(self.io, self.gpa);
        // the host failing before the operation runs is no tool result
        var ctx = self.initCtx(&call_arena, &admin) catch |err| {
            return try jsonrpc.writeError(out, id, .internal_error, try std.fmt.allocPrint(arena, "internal error: {t}", .{err}));
        };
        if (run(@TypeOf(ready), ready, &ctx)) |result| {
            const structured = structuredContent(result);
            try jsonrpc.writeResult(out, id, ToolResult(@TypeOf(structured)){
                .text = try std.json.Stringify.valueAlloc(arena, structured, .{}),
                .structured = structured,
            });
        } else |err| switch (err) {
            error.OutOfMemory => return try jsonrpc.writeError(out, id, .internal_error, "internal error: OutOfMemory"),
            else => try jsonrpc.writeResult(out, id, ToolFailure{
                .text = try std.fmt.allocPrint(arena, "{s} failed ({t}): {t}", .{ Operation.tool_name, domain.classify(err).kind, err }),
            }),
        }
    }

    // a fresh context for one call. a server context reads the admin repo,
    // which `admin` holds open for the caller to close.
    fn initCtx(self: *Server, arena: *std.heap.ArenaAllocator, admin: *?AdminRepo) !domain.Ctx {
        const now = std.math.cast(i64, std.Io.Timestamp.now(self.io, .real).toSeconds()) orelse return error.TimestampOutOfRange;
        return switch (self.mode) {
            .local => |src| domain.Ctx.initLocal(self.io, self.gpa, arena, src, now),
            .server => |server| blk: {
                admin.* = try AdminRepo.open(self.io, self.gpa, .{ .path = server.admin_repo_path });
                break :blk try domain.Ctx.initServer(self.io, self.gpa, arena, &admin.*.?, server.users_dir, server.user_id, now);
            },
        };
    }
};

// run `input` in `ctx`. reads otherwise see the local event db as of the last
// refresh, so a local call refreshes first; a server consumes every write as
// it happens.
fn run(comptime Operation: type, input: Operation, ctx: *domain.Ctx) !RunResult(Operation) {
    if (ctx.host == .local and Operation != domain.RefreshLocal) try (domain.RefreshLocal{}).run(ctx);
    return try input.run(ctx);
}

const AdminRepo = rp.Repo(.xit, evt.admin_repo_opts);

// what an operation's run returns on success
fn RunResult(comptime Operation: type) type {
    return @typeInfo(@typeInfo(@TypeOf(Operation.run)).@"fn".return_type.?).error_union.payload;
}

// a tools/call result for an operation that succeeded: its result as a json
// text block and as structured content
fn ToolResult(comptime Structured: type) type {
    return struct {
        // `structured` as json
        text: []const u8,
        structured: Structured,

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.write(.{
                .content = .{.{ .type = "text", .text = self.text }},
                .structuredContent = self.structured,
                .isError = false,
            });
        }
    };
}

// structured content is an object, so a void result is `{}` and any other
// result that isn't a struct is wrapped as `{"result": ...}`
fn structuredContent(result: anytype) StructuredContent(@TypeOf(result)) {
    const Result = @TypeOf(result);
    if (Result == void) return .{};
    if (@typeInfo(Result) == .@"struct") return result;
    return .{ .result = result };
}

fn StructuredContent(comptime Result: type) type {
    if (Result == void) return Empty;
    if (@typeInfo(Result) == .@"struct") return Result;
    return struct { result: Result };
}

// a tools/call result for an operation that failed
const ToolFailure = struct {
    text: []const u8,

    pub fn jsonStringify(self: ToolFailure, jw: anytype) !void {
        try jw.write(.{ .content = .{.{ .type = "text", .text = self.text }}, .isError = true });
    }
};

// the protocol version well-formed `initialize` params ask for, or null when
// they lack it, the capabilities or the client info
fn initializeVersion(params: ?std.json.Value) ?[]const u8 {
    const object = (params orelse return null).object;
    const version = object.get("protocolVersion") orelse return null;
    const capabilities = object.get("capabilities") orelse return null;
    const client_info = object.get("clientInfo") orelse return null;
    if (version != .string or capabilities != .object or client_info != .object) return null;
    return version.string;
}

// the `requested` version when this server speaks it, otherwise the newest it
// speaks
fn negotiateVersion(requested: []const u8) []const u8 {
    for (protocol_versions) |supported| {
        if (std.mem.eql(u8, supported, requested)) return supported;
    }
    return protocol_versions[0];
}

// what a tool tells the client about its effects. every hint is set, as
// mcp reads a missing destructiveHint as true.
pub const Annotations = struct {
    readOnlyHint: bool,
    destructiveHint: bool,
    idempotentHint: bool,

    // a read, which in local mode refreshes the repo first, and that writes
    pub const read: Annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = true };
    // a write that adds to what is there
    pub const add: Annotations = .{ .readOnlyHint = false, .destructiveHint = false, .idempotentHint = false };
    // a write that changes or removes what is there, where a repeated call
    // has no further effect
    pub const replace: Annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = true };
    // a write that changes what is there and writes again on every call
    pub const rewrite: Annotations = .{ .readOnlyHint = false, .destructiveHint = true, .idempotentHint = false };
};

pub const Tool = struct {
    Operation: type,
    annotations: Annotations,
    // a removal or merge, served only with --allow-destructive
    removal: bool = false,
};

// the operations served as tools, in tools/list order. annotations cover the
// whole call, including local mode's refresh; idempotent means a repeated call
// has no further effect.
//
// domain.DeleteFork is no tool: it checks the account password, which tool
// arguments must never carry. a password-free operator-mode adapter waits for
// personal tokens (phase 6).
pub const tools = [_]Tool{
    .{ .Operation = domain.RefreshLocal, .annotations = .read },
    .{ .Operation = domain.ListIssues, .annotations = .read },
    .{ .Operation = domain.GetIssue, .annotations = .read },
    .{ .Operation = domain.GetDiscussion, .annotations = .read },
    .{ .Operation = domain.ListPatches, .annotations = .read },
    .{ .Operation = domain.GetPatch, .annotations = .read },
    // each call opens another thread
    .{ .Operation = domain.CreateThread, .annotations = .add },
    // the update commits again even when nothing changed
    .{ .Operation = domain.EditThread, .annotations = .rewrite },
    // the update commits again even once the conflict is settled
    .{ .Operation = domain.ResolveConflict, .annotations = .rewrite },
    // the update returns without writing when the status is already set
    .{ .Operation = domain.SetThreadStatus, .annotations = .replace },
    // each call adds another comment
    .{ .Operation = domain.CreateComment, .annotations = .add },
    // the edit commits again even when the body is the same
    .{ .Operation = domain.EditComment, .annotations = .rewrite },
    // each call adds another attachment
    .{ .Operation = AttachTool, .annotations = .add },
    // a repeat fails as already assigned without writing
    .{ .Operation = domain.Assign, .annotations = .replace },
    // a repeat fails as not found without writing
    .{ .Operation = domain.Unassign, .annotations = .replace },
    // a repeat returns early when already subscribed
    .{ .Operation = domain.Subscribe, .annotations = .replace },
    // each call writes another notify event
    .{ .Operation = domain.Mute, .annotations = .rewrite },
    // a repeat finds the draft already published
    .{ .Operation = domain.PublishPatch, .annotations = .replace },
    // merging may remove the patch's fork; a repeat finds the patch merged
    .{ .Operation = domain.MergePatch, .annotations = .replace, .removal = true },
    // removals: a repeat finds nothing to remove
    .{ .Operation = domain.RemoveThread, .annotations = .replace, .removal = true },
    .{ .Operation = domain.RemoveComment, .annotations = .replace, .removal = true },
    .{ .Operation = domain.RemoveAttachment, .annotations = .replace, .removal = true },
};

comptime {
    // an operation that can't take json arguments is served through an
    // adapter, never directly
    for (tools) |tool| {
        if (@hasDecl(tool.Operation, "not_a_tool")) @compileError(@typeName(tool.Operation) ++ " is not a tool");
        // passwords never travel in tool arguments
        if (@hasField(tool.Operation, "password")) @compileError(@typeName(tool.Operation) ++ " takes a password");
        // every argument is described
        for (@typeInfo(tool.Operation).@"struct".field_names) |name| {
            if (!@hasDecl(tool.Operation, "tool_schema_notes") or !@hasField(@TypeOf(tool.Operation.tool_schema_notes), name)) {
                @compileError(@typeName(tool.Operation) ++ ".tool_schema_notes doesn't describe " ++ name);
            }
        }
    }
}

// the `attach` tool: domain.Attach streams from a reader, which json can't
// carry, so the file comes as base64, decoded into a bounded buffer
pub const AttachTool = struct {
    pub const tool_name = "attach";
    pub const tool_description = "Attach a file, sent as base64, to an issue, patch or discussion.";
    pub const tool_schema_notes = .{
        .repo = domain.repo_note,
        .kind = "The kind of the thread the file is attached to.",
        .thread_id = "The thread's hex event id.",
        .name = "The file's name, without a directory.",
        .content_base64 = "The file's bytes in padded standard base64, at most 10 MiB once decoded.",
    };

    // "owner:name"; "" in local mode
    repo: []const u8,
    kind: domain.ThreadKind,
    // the thread's hex event id
    thread_id: []const u8,
    name: []const u8,
    content_base64: []const u8,

    // the longest encoding of an attachment
    pub const max_encoded_len = ((evt.Attachment.max_size + 2) / 3) * 4;

    // the file decoded into `arena`, or why it can't be. the decoded size,
    // which the length and padding fix, is checked before anything is
    // allocated or decoded.
    pub fn prepare(self: AttachTool, arena: std.mem.Allocator) !union(enum) { ready: Decoded, invalid: []const u8 } {
        const decoder = std.base64.standard.Decoder;
        const size = decoder.calcSizeForSlice(self.content_base64) catch return .{ .invalid = "content_base64 is not base64" };
        if (size > evt.Attachment.max_size) return .{ .invalid = std.fmt.comptimePrint("content_base64 decodes to more than {d} bytes", .{evt.Attachment.max_size}) };
        const bytes = try arena.alloc(u8, size);
        decoder.decode(bytes, self.content_base64) catch return .{ .invalid = "content_base64 is not base64" };
        return .{ .ready = .{ .tool = self, .bytes = bytes } };
    }

    pub const Decoded = struct {
        tool: AttachTool,
        bytes: []const u8,

        pub fn run(self: Decoded, ctx: *domain.Ctx) !domain.Attach.Result {
            var reader = std.Io.Reader.fixed(self.bytes);
            return try (domain.Attach{
                .repo = self.tool.repo,
                .kind = self.tool.kind,
                .thread_id = self.tool.thread_id,
                .name = self.tool.name,
                .size = self.bytes.len,
                .reader = &reader,
            }).run(ctx);
        }
    };
};

// tools/list's result
const ToolList = struct {
    allow_destructive: bool,

    pub fn jsonStringify(self: ToolList, jw: anytype) !void {
        try jw.beginObject();
        try jw.objectField("tools");
        try jw.beginArray();
        inline for (tools) |tool| if (!tool.removal or self.allow_destructive) {
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tool.Operation.tool_name);
            try jw.objectField("description");
            try jw.write(tool.Operation.tool_description);
            try jw.objectField("inputSchema");
            try jw.write(InputSchema(tool.Operation){});
            try jw.objectField("annotations");
            try jw.write(tool.annotations);
            try jw.endObject();
        };
        try jw.endArray();
        try jw.endObject();
    }
};

// the json schema of an input struct `T`'s fields, described by its
// `tool_schema_notes` when it has them
pub fn InputSchema(comptime T: type) type {
    return struct {
        pub fn jsonStringify(_: @This(), jw: anytype) !void {
            try writeObjectSchema(jw, T, schemaNotes(T));
        }
    };
}

// the field descriptions an operation declares as `tool_schema_notes`, a
// struct literal mapping field names to text, or none
fn schemaNotes(comptime Operation: type) @TypeOf(if (@hasDecl(Operation, "tool_schema_notes")) Operation.tool_schema_notes else .{}) {
    if (!@hasDecl(Operation, "tool_schema_notes")) return .{};
    // a note naming no field is a typo
    for (@typeInfo(@TypeOf(Operation.tool_schema_notes)).@"struct".field_names) |name| {
        if (!@hasField(Operation, name)) @compileError(@typeName(Operation) ++ ".tool_schema_notes names no field " ++ name);
    }
    return Operation.tool_schema_notes;
}

// the json schema of a struct: its fields as properties, described by
// `notes`, the ones without a default required, and no others allowed
fn writeObjectSchema(jw: anytype, comptime T: type, comptime notes: anytype) !void {
    try writeObjectSchemaNullable(jw, T, notes, false);
}

fn writeObjectSchemaNullable(jw: anytype, comptime T: type, comptime notes: anytype, comptime nullable: bool) !void {
    const info = @typeInfo(T).@"struct";
    try jw.beginObject();
    try jw.objectField("type");
    try writeTypeName(jw, "object", nullable);
    try jw.objectField("properties");
    try jw.beginObject();
    inline for (info.field_names, info.field_types) |name, Field| {
        try jw.objectField(name);
        try writeSchema(jw, Field, fieldNote(notes, name), false);
    }
    try jw.endObject();
    try jw.objectField("required");
    try jw.beginArray();
    inline for (info.field_names, info.field_attrs) |name, attrs| {
        if (attrs.default_value_ptr == null) try jw.write(name);
    }
    try jw.endArray();
    try jw.objectField("additionalProperties");
    try jw.write(false);
    try jw.endObject();
}

// the json schema of a field of type `T`, which allows null when `nullable`
fn writeSchema(jw: anytype, comptime T: type, comptime description: ?[]const u8, comptime nullable: bool) !void {
    switch (@typeInfo(T)) {
        .optional => |optional| return try writeSchema(jw, optional.child, description, true),
        // nested structs carry no notes
        .@"struct" => return try writeObjectSchemaNullable(jw, T, .{}, nullable),
        else => {},
    }
    try jw.beginObject();
    try jw.objectField("type");
    switch (@typeInfo(T)) {
        .bool => try writeTypeName(jw, "boolean", nullable),
        .int => try writeTypeName(jw, "integer", nullable),
        .@"enum" => |info| {
            try writeTypeName(jw, "string", nullable);
            try jw.objectField("enum");
            try jw.beginArray();
            inline for (info.field_names) |name| try jw.write(name);
            if (nullable) try jw.write(null);
            try jw.endArray();
        },
        .pointer => if (T == []const u8) {
            try writeTypeName(jw, "string", nullable);
        } else if (T == []const []const u8) {
            try writeTypeName(jw, "array", nullable);
            try jw.objectField("items");
            try jw.write(.{ .type = "string" });
        } else @compileError("no json schema for " ++ @typeName(T)),
        else => @compileError("no json schema for " ++ @typeName(T)),
    }
    if (description) |text| {
        try jw.objectField("description");
        try jw.write(text);
    }
    try jw.endObject();
}

fn writeTypeName(jw: anytype, comptime name: []const u8, comptime nullable: bool) !void {
    if (nullable) try jw.write(.{ name, "null" }) else try jw.write(name);
}

// the description `notes` holds for the field `name`
fn fieldNote(comptime notes: anytype, comptime name: []const u8) ?[]const u8 {
    if (!@hasField(@TypeOf(notes), name)) return null;
    return @field(notes, name);
}

// what is wrong with `arguments` as an input for `T` under its derived
// schema, or null when nothing is. the text names the field.
fn checkArguments(comptime T: type, arena: std.mem.Allocator, arguments: std.json.Value) !?[]const u8 {
    if (arguments != .object) return "arguments must be an object";
    return try checkObject(T, arena, "", arguments.object);
}

fn checkObject(comptime T: type, arena: std.mem.Allocator, comptime prefix: []const u8, object: std.json.ObjectMap) !?[]const u8 {
    const info = @typeInfo(T).@"struct";
    var it = object.iterator();
    next_key: while (it.next()) |entry| {
        inline for (info.field_names) |name| {
            if (std.mem.eql(u8, entry.key_ptr.*, name)) continue :next_key;
        }
        return try std.fmt.allocPrint(arena, "unknown field {s}{s}", .{ prefix, entry.key_ptr.* });
    }
    inline for (info.field_names, info.field_types, info.field_attrs) |name, Field, attrs| {
        if (object.get(name)) |value| {
            if (try checkValue(Field, arena, prefix ++ name, value)) |problem| return problem;
        } else if (attrs.default_value_ptr == null) {
            return "missing field " ++ prefix ++ name;
        }
    }
    return null;
}

// what is wrong with `value` as a `T` named `path`, or null when nothing is
fn checkValue(comptime T: type, arena: std.mem.Allocator, comptime path: []const u8, value: std.json.Value) !?[]const u8 {
    switch (@typeInfo(T)) {
        .optional => |optional| return if (value == .null) null else try checkValue(optional.child, arena, path, value),
        .@"struct" => return if (value == .object) try checkObject(T, arena, path ++ ".", value.object) else path ++ " must be an object",
        .bool => return if (value == .bool) null else path ++ " must be a boolean",
        .int => return if (integerFits(T, value)) null else path ++ " must be an integer in range",
        .@"enum" => |info| {
            const names = comptime blk: {
                var joined: []const u8 = "";
                for (info.field_names, 0..) |name, i| joined = joined ++ (if (i == 0) "" else ", ") ++ name;
                break :blk joined;
            };
            if (value == .string) {
                inline for (info.field_names) |name| {
                    if (std.mem.eql(u8, value.string, name)) return null;
                }
            }
            return path ++ " must be one of " ++ names;
        },
        .pointer => if (T == []const u8) {
            return if (value == .string) null else path ++ " must be a string";
        } else if (T == []const []const u8) {
            if (value != .array) return path ++ " must be an array of strings";
            for (value.array.items) |item| {
                if (item != .string) return path ++ " must be an array of strings";
            }
            return null;
        } else @compileError("no json schema for " ++ @typeName(T)),
        else => @compileError("no json schema for " ++ @typeName(T)),
    }
}

// whether `value` is a json integer a `T` holds. a float counts when it is a
// whole number, as json doesn't tell 3 from 3.0.
fn integerFits(comptime T: type, value: std.json.Value) bool {
    const whole: i128 = switch (value) {
        .integer => |integer| integer,
        .float => |float| blk: {
            // past any field's range, and keeps the cast below defined
            if (@round(float) != float or @abs(float) >= 0x1p100) return false;
            break :blk @intFromFloat(float);
        },
        else => return false,
    };
    return std.math.cast(T, whole) != null;
}

// where tool calls run
pub const Mode = union(enum) {
    // the repo `haxy mcp` was started in
    local: domain.RepoSource,
    // server data, acting as one account
    server: struct {
        admin_repo_path: []const u8,
        users_dir: []const u8,
        // null acts logged out
        user_id: ?[evt.event_id_size]u8,
    },
};

// serializes as `{}`; an empty anonymous literal is a tuple, `[]`
const Empty = struct {};
