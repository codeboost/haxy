//! what the metadata conflict routes answer and accept, apart from where
//! they read it: a conflict's sides per field and description chunk, and a
//! resolution request checked against the conflict it resolves. the fields
//! and chunks are the TUI's resolve form's (`ui.widget.thread.readConflict`),
//! so a resolution offers exactly what that form offers: free text for a
//! conflicted title or labels, one text per conflicting description chunk,
//! and either whole side of a patch's status, revision and target.

const std = @import("std");
const api = @import("../api.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_thread = @import("./thread.zig");
const diff3 = @import("../diff3.zig");
const evt = @import("../event.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

/// the fields a resolution picks a whole side of, by the API's names, with
/// the field each is in Haxy's patch events
pub const Choice = enum {
    status,
    revision,
    target,

    pub fn eventField(self: Choice) []const u8 {
        return switch (self) {
            .status, .revision => @tagName(self),
            .target => "target_branch",
        };
    }
};

/// what a conflict lets a resolution settle
pub const Offered = struct {
    title: bool = false,
    labels: bool = false,
    // how many description chunks conflict; 0 when the description doesn't
    hunks: usize = 0,
    choices: []const Choice = &.{},
};

/// one side's value of a conflicted field, as a resolution may take it
pub const Value = union(enum) {
    text: []const u8,
    status: []const u8,
    revision: ?struct { source_commit: []const u8, squash_commit: []const u8 },
    target: struct { name: []const u8, id: []const u8 },

    pub fn jsonStringify(self: Value, json: *std.json.Stringify) std.Io.Writer.Error!void {
        switch (self) {
            inline else => |value| try json.write(value),
        }
    }
};

pub const Side = struct {
    value: Value,
    author: api_thread.Author,
};

/// one conflicted field: `text` fields take any text as their resolution,
/// `choice` fields one side whole
pub const Field = struct {
    name: []const u8,
    resolution: enum { text, choice },
    ours: Side,
    theirs: Side,
};

pub const Chunk = union(enum) {
    // both sides agree on it
    same: []const u8,
    // only one side changed it, so its version stands (null: it removed the lines)
    auto: struct { side: enum { ours, theirs }, text: ?[]const u8 },
    // both changed it differently: a resolution gives its text
    conflict: struct { ours: ?[]const u8, theirs: ?[]const u8 },

    pub fn jsonStringify(self: Chunk, json: *std.json.Stringify) std.Io.Writer.Error!void {
        try json.beginObject();
        try json.objectField("kind");
        try json.write(@tagName(self));
        switch (self) {
            .same => |text| {
                try json.objectField("text");
                try json.write(text);
            },
            inline .auto, .conflict => |value| inline for (@typeInfo(@TypeOf(value)).@"struct".field_names) |name| {
                try json.objectField(name);
                try json.write(@field(value, name));
            },
        }
        try json.endObject();
    }
};

pub const Description = struct {
    ours_author: api_thread.Author,
    theirs_author: api_thread.Author,
    chunks: []const Chunk,
};

/// a thread's unresolved conflict, as its route answers it
pub const Conflict = struct {
    // hex `evt.ConflictRevision`, which a resolution sends back
    revision: []const u8,
    fields: []const Field,
    description: ?Description,
};

fn author(value: ui.Author) api_thread.Author {
    return .{ .author = value };
}

fn textField(name: []const u8, field: anytype) Field {
    return .{
        .name = name,
        .resolution = .text,
        .ours = .{ .value = .{ .text = field.ours.text }, .author = author(field.ours.author) },
        .theirs = .{ .value = .{ .text = field.theirs.text }, .author = author(field.theirs.author) },
    };
}

fn chunkOf(chunk: diff3.Chunk) Chunk {
    return switch (chunk) {
        .same => |text| .{ .same = text },
        .auto => |auto| .{ .auto = .{ .side = if (auto.theirs) .theirs else .ours, .text = auto.text } },
        .conflict => |hunk| .{ .conflict = .{ .ours = hunk.ours, .theirs = hunk.theirs } },
    };
}

fn description(aa: std.mem.Allocator, read: anytype) !?Description {
    const desc = read.description orelse return null;
    const chunks = try aa.alloc(Chunk, desc.chunks.len);
    for (chunks, desc.chunks) |*chunk, source| chunk.* = chunkOf(source);
    return .{ .ours_author = author(desc.ours_author), .theirs_author = author(desc.theirs_author), .chunks = chunks };
}

/// the conflict a thread tab read for its resolve view (`ui.Repo.Issues` or
/// `ui.Repo.Patches`' `Conflict`), as the route answers it
pub fn fromRead(aa: std.mem.Allocator, read: anytype) !Conflict {
    var fields: std.ArrayList(Field) = .empty;
    if (read.title) |title| try fields.append(aa, textField("title", title));
    if (read.labels) |labels| try fields.append(aa, textField("labels", labels));
    if (comptime @hasField(@TypeOf(read), "events")) try appendChoices(aa, &fields, read);
    return .{
        .revision = try aa.dupe(u8, &std.fmt.bytesToHex(read.conflict_revision, .lower)),
        .fields = fields.items,
        .description = try description(aa, read),
    };
}

fn appendChoices(aa: std.mem.Allocator, fields: *std.ArrayList(Field), read: anytype) !void {
    const events = read.events orelse return;
    inline for (.{ .{ "status", Choice.status }, .{ "revision", Choice.revision }, .{ "target_branch", Choice.target } }) |pair| {
        if (@field(read, pair[0])) |field| try fields.append(aa, .{
            .name = @tagName(pair[1]),
            .resolution = .choice,
            .ours = .{ .value = try choiceValue(aa, pair[1], events.ours), .author = author(field.ours.author) },
            .theirs = .{ .value = try choiceValue(aa, pair[1], events.theirs), .author = author(field.theirs.author) },
        });
    }
}

fn choiceValue(aa: std.mem.Allocator, choice: Choice, patch: evt.Patch) !Value {
    return switch (choice) {
        .status => .{ .status = @tagName(patch.status.kind()) },
        .revision => .{ .revision = if (patch.revision) |revision| .{ .source_commit = revision.source_oid, .squash_commit = revision.squash_oid } else null },
        .target => .{ .target = .{
            .name = try api_path.display(aa, patch.target_branch),
            .id = try (api_refs.Selection{ .branch = patch.target_branch }).id(aa),
        } },
    };
}

/// what a conflict lets a resolution settle
pub fn offered(aa: std.mem.Allocator, read: Conflict) !Offered {
    var result: Offered = .{};
    var choices: std.ArrayList(Choice) = .empty;
    for (read.fields) |field| {
        if (std.mem.eql(u8, field.name, "title")) result.title = true;
        if (std.mem.eql(u8, field.name, "labels")) result.labels = true;
        if (std.meta.stringToEnum(Choice, field.name)) |choice| try choices.append(aa, choice);
    }
    if (read.description) |desc| {
        for (desc.chunks) |chunk| result.hunks += @intFromBool(chunk == .conflict);
    }
    result.choices = choices.items;
    return result;
}

// --- resolution requests ------------------------------------------------------

/// `POST …/{id}/conflict`: the conflict's `revision` as loaded, a text for
/// each conflicted title or labels (absent keeps this side's), one text per
/// conflicting description chunk (absent keeps this side's chunks), and the
/// choice fields taken from their side (the others keep this side's)
pub const Request = struct {
    revision: []const u8,
    title: ?[]const u8 = null,
    labels: ?[]const u8 = null,
    description: ?[]const []const u8 = null,
    theirs: []const []const u8 = &.{},
};

pub const Parsed = union(enum) { ok: Request, invalid: api.Error };

const malformed: api.Error = .{ .code = .validation, .message = "Send the resolution as a JSON object: revision, title and labels as strings, description and theirs as arrays of strings." };

/// a resolution request's JSON body, or why it isn't one
pub fn parseRequest(aa: std.mem.Allocator, body: []const u8) !Parsed {
    const value = std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .invalid = malformed },
    };
    const object = switch (value) {
        .object => |object| object,
        else => return .{ .invalid = malformed },
    };
    return .{ .ok = .{
        .revision = (optionalString(object.get("revision")) catch return .{ .invalid = malformed }) orelse "",
        .title = optionalString(object.get("title")) catch return .{ .invalid = malformed },
        .labels = optionalString(object.get("labels")) catch return .{ .invalid = malformed },
        .description = stringList(aa, object.get("description")) catch |err| return listFailure(err),
        .theirs = (stringList(aa, object.get("theirs")) catch |err| return listFailure(err)) orelse &.{},
    } };
}

fn listFailure(err: anyerror) !Parsed {
    if (err == error.OutOfMemory) return error.OutOfMemory;
    return .{ .invalid = malformed };
}

fn optionalString(value: ?std.json.Value) !?[]const u8 {
    return switch (value orelse return null) {
        .null => null,
        .string => |string| string,
        else => error.Malformed,
    };
}

fn stringList(aa: std.mem.Allocator, value: ?std.json.Value) !?[]const []const u8 {
    const array = switch (value orelse return null) {
        .null => return null,
        .array => |array| array,
        else => return error.Malformed,
    };
    const list = try aa.alloc([]const u8, array.items.len);
    for (list, array.items) |*item, element| item.* = switch (element) {
        .string => |string| string,
        else => return error.Malformed,
    };
    return list;
}

/// a request's resolution, in the terms of Haxy's resolve form: the texts
/// with plain newlines, and their side's choice fields comma-separated by
/// their names in Haxy's events
pub const Resolution = struct {
    title: ?[]const u8,
    labels: ?[]const u8,
    hunks: []const []const u8,
    theirs: []const u8,
};

pub const Checked = union(enum) { ok: Resolution, invalid: api.Error };

/// `request` checked against what the conflict offers, for a thread of `kind`
pub fn check(aa: std.mem.Allocator, kind: evt.EventKind, conflict_offered: Offered, request: Request) !Checked {
    if (request.title != null and !conflict_offered.title) return .{ .invalid = unconflicted("title") };
    if (request.labels != null and !conflict_offered.labels) return .{ .invalid = unconflicted("labels") };
    const hunks = request.description orelse &.{};
    if (request.description != null and conflict_offered.hunks == 0) return .{ .invalid = unconflicted("description") };
    if (request.description != null and hunks.len != conflict_offered.hunks) return .{ .invalid = hunk_count };
    const theirs = (try theirFields(aa, conflict_offered.choices, request.theirs)) orelse return .{ .invalid = unknown_choice };
    if (try fieldsFailure(kind, request)) |failure| return .{ .invalid = api_thread.fieldsError(failure) };
    const plain = try aa.alloc([]const u8, hunks.len);
    for (plain, hunks) |*hunk, text| hunk.* = try thread_write.plainNewlines(aa, text);
    return .{ .ok = .{ .title = request.title, .labels = request.labels, .hunks = plain, .theirs = theirs } };
}

// the shared field rules, on the title and labels a resolution gives
fn fieldsFailure(kind: evt.EventKind, request: Request) !?thread_write.FieldFailure {
    if (request.title) |title| {
        if (thread_write.checkFields(kind, .{ .title = title, .labels = "", .description = "" })) |failure| return failure;
    }
    if (request.labels) |labels| return thread_write.checkFields(kind, .{ .title = "-", .labels = labels, .description = "" });
    return null;
}

// the choice fields taken from their side, by their event names, or null
// when one names no field of the conflict's
fn theirFields(aa: std.mem.Allocator, choices: []const Choice, names: []const []const u8) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names) |name| {
        const choice = std.meta.stringToEnum(Choice, name) orelse return null;
        if (std.mem.indexOfScalar(Choice, choices, choice) == null) return null;
        if (out.items.len > 0) try out.append(aa, ',');
        try out.appendSlice(aa, choice.eventField());
    }
    return out.items;
}

const check_fields = "Check the highlighted fields.";

fn unconflicted(comptime field: []const u8) api.Error {
    return .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = field, .message = "This field has no conflict to resolve." }} };
}

const hunk_count: api.Error = .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "description", .message = "Send one text for each conflicting part of the description, in order." }} };
const unknown_choice: api.Error = .{ .code = .validation, .message = check_fields, .field_errors = &.{.{ .field = "theirs", .message = "Name only conflicted fields that take one side whole: status, revision or target." }} };
