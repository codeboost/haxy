//! the draft routes of the JSON API: a patch started with a new fork of its
//! repository stays its author's draft until it is published. a draft is its
//! author's alone: anyone else, by any route, finds none. every write goes
//! through the operations the TUI's patches tab and Haxy's HTML forms use
//! (src/draft.zig). drafts live on a server only.

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const api = @import("../api.zig");
const api_account = @import("./account.zig");
const api_md = @import("./markdown.zig");
const api_patches = @import("./patches.zig");
const api_path = @import("./path.zig");
const api_refs = @import("./refs.zig");
const api_repo = @import("./repo.zig");
const api_thread = @import("./thread.zig");
const draft = @import("../draft.zig");
const evt = @import("../event.zig");
const md = @import("../markdown.zig");
const query_params = @import("./query.zig");
const thread_write = @import("../thread_write.zig");
const ui = @import("../ui.zig");

const Patches = ui.Repo.Patches;

// a list page defaults to the TUI's window; clients may ask for up to this many
const max_page_size = 100;

pub const Route = struct {
    target: api_repo.Route.Target,
    resource: Resource,

    pub const Resource = union(enum) {
        // the viewer's drafts, `?cursor=&page_size=`, and starting one
        list,
        // one draft by its hex event id, still encoded
        draft: []const u8,
        // publishing one, `<id>/publish`, its id still encoded
        publish: []const u8,
    };
};

const segment = "/patches/drafts";

/// the draft route `path` names, or null when it names none
pub fn route(path: []const u8) ?Route {
    const local_prefix = "/api/v1/repo" ++ segment;
    if (std.mem.startsWith(u8, path, local_prefix))
        return .{ .target = .local, .resource = resourceOf(path[local_prefix.len..]) orelse return null };

    const prefix = "/api/v1/repos/";
    if (!std.mem.startsWith(u8, path, prefix)) return null;
    var segments = std.mem.splitScalar(u8, path[prefix.len..], '/');
    const owner = segments.next() orelse return null;
    const name = segments.next() orelse return null;
    if (owner.len == 0 or name.len == 0) return null;
    const tail = path[prefix.len + owner.len + 1 + name.len ..];
    if (!std.mem.startsWith(u8, tail, segment)) return null;
    return .{
        .target = .{ .server = .{ .owner = owner, .name = name } },
        .resource = resourceOf(tail[segment.len..]) orelse return null,
    };
}

// what follows the drafts segment: nothing, "/<id>" or "/<id>/publish"
fn resourceOf(tail: []const u8) ?Route.Resource {
    if (tail.len == 0) return .list;
    if (tail[0] != '/') return null;
    var segments = std.mem.splitScalar(u8, tail[1..], '/');
    const id = segments.first();
    if (id.len == 0) return null;
    const action = segments.next() orelse return .{ .draft = id };
    if (!std.mem.eql(u8, action, "publish") or segments.next() != null) return null;
    return .{ .publish = id };
}

pub fn handle(
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    host: api_repo.Host,
    // the logged-in viewer, or null when anonymous
    viewer: ?[evt.event_id_size]u8,
    matched: Route,
    // the still-encoded query string
    query: []const u8,
) !void {
    const server = switch (host) {
        .server => |server| server,
        .local => return api.respondError(request, allocator, local_unsupported, .{ .keep_alive = false }),
    };
    const action = actionOf(request.head.method, matched.resource) orelse return switch (matched.resource) {
        .list => api_thread.unsupported(request, allocator, "GET, HEAD, POST"),
        .draft => api_thread.unsupported(request, allocator, "GET, HEAD, PATCH, DELETE"),
        .publish => api_thread.unsupported(request, allocator, "POST"),
    };

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    // the body is read before anything answers, so no answer leaves it unread
    const body: Body = switch (action) {
        .start => .{ .start = (try api_account.readBody(StartRequest, request, allocator, &arena)) orelse return },
        .edit => .{ .edit = (try api_account.readBody(EditRequest, request, allocator, &arena)) orelse return },
        .list, .read, .remove, .publish => .none,
    };

    var admin_repo_maybe: ?rp.Repo(.xit, evt.admin_repo_opts) = null;
    defer if (admin_repo_maybe) |*admin_repo| admin_repo.deinit(io, allocator);
    var opened = (try api_thread.openRepo(io, request, allocator, &arena, host, viewer, matched.target, &admin_repo_maybe)) orelse return;
    if (!ui.Repo.hasSection(.patches, opened.resolved.repo.event, opened.handle, opened.session.data.host_kind, opened.source.repo_kind))
        return api.respondError(request, allocator, api_patches.patches_off, .{});

    var ctx: Context = .{ .io = io, .allocator = allocator, .arena = &arena, .server = server, .viewer = viewer, .opened = &opened, .admin_repo = &admin_repo_maybe.? };
    const answer = switch (matched.resource) {
        .list => try ctx.onList(action, body, query),
        .draft => |encoded| try ctx.onDraft(action, body, encoded),
        .publish => |encoded| try ctx.onPublish(encoded),
    };
    return switch (answer) {
        .ok => |ok| api.respondJson(request, ok.body, .{ .status = ok.status }),
        .failed => |err| api.respondError(request, allocator, err, .{}),
    };
}

const Action = enum { list, start, read, edit, remove, publish };

fn actionOf(method: std.http.Method, resource: Route.Resource) ?Action {
    const reads = method == .GET or method == .HEAD;
    return switch (resource) {
        .list => if (reads) .list else if (method == .POST) .start else null,
        .draft => if (reads) .read else if (method == .PATCH) .edit else if (method == .DELETE) .remove else null,
        .publish => if (method == .POST) .publish else null,
    };
}

// --- requests and answers ----------------------------------------------------

/// `POST …/patches/drafts`: a new draft with a new fork, proposing changes
/// into `target` (a branch ref id, as answers name it). `id` is optional: a
/// client that chooses one (32 lowercase hex digits) can retry without
/// starting a second draft.
pub const StartRequest = struct {
    id: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    target: []const u8,
};

/// `PATCH …/patches/drafts/{id}`: the draft's fields and target, replaced as
/// of `revision` (its `edit_revision`)
pub const EditRequest = struct {
    revision: []const u8,
    title: []const u8,
    labels: []const u8,
    description: []const u8,
    target: []const u8,
};

const Body = union(enum) { none, start: StartRequest, edit: EditRequest };

const Answer = union(enum) {
    ok: struct { body: []const u8, status: std.http.Status = .ok },
    failed: api.Error,
};

const local_unsupported: api.Error = .{ .code = .unsupported, .message = "Local mode has no drafts; propose changes from a branch instead." };
const no_such_draft: api.Error = .{ .code = .not_found, .message = "There is no draft with this id." };
const log_in: api.Error = .{ .code = .unauthenticated, .message = "Log in to see your drafts." };
const role_forbidden: Availability = .{ .unavailable = .{ .code = .forbidden, .message = "Your role in this repository doesn't allow writing patches." } };
const stale_revision: api.Error = .{
    .code = .conflict,
    .message = "This draft changed since you loaded it.",
    .field_errors = &.{.{ .field = "revision", .message = "The draft changed meanwhile. Load it again, then make your change." }},
};
const patch_id_taken: api.Error = .{ .code = .conflict, .message = "The repository already has another patch under this draft's id, so it can't be published." };
const not_pushed: api.Error = .{ .code = .conflict, .message = "This draft's fork no longer holds the revision it names; push to it again, then publish." };
const fork_unreadable: api.Error = .{ .code = .conflict, .message = "Haxy can't read this draft's fork, so it can't be published." };

const Availability = api_thread.Availability;

// --- shapes ------------------------------------------------------------------

/// a branch as a response names it: for display, and as a `ref` parameter
const Branch = struct {
    name: []const u8,
    id: []const u8,

    fn init(aa: std.mem.Allocator, name: []const u8) !Branch {
        return .{ .name = try api_path.display(aa, name), .id = try (api_refs.Selection{ .branch = name }).id(aa) };
    }
};

/// what was last pushed to the draft's fork; its commits stay in the fork
const Revision = struct {
    id: []const u8,
    source_commit: []const u8,
    squash_commit: []const u8,
    commit_count: ?u64,
};

/// a git command for a patch's fork, as the TUI offers it
pub const Command = struct {
    action: ui.widget.ForkCommand.Action,
    protocol: ui.widget.GitCommand.Protocol = .ssh,
    url: []const u8,
    command: []const u8,
};

const Actions = struct { edit: Availability, remove: Availability, publish: Availability };

/// a listed draft
const Summary = struct {
    id: []const u8,
    title: []const u8,
    labels: []const []const u8,
    created_at: api.Instant,
    target: Branch,
    revision: ?Revision,
    // the target branch is at the fork's patch branch already
    no_changes: bool,
};

/// one draft: what it proposes, where its fork is and how to work with it,
/// and what its author may do
const Detail = struct {
    id: []const u8,
    title: []const u8,
    labels: []const []const u8,
    author: api_thread.Author,
    created_at: api.Instant,
    description: api_md.Blocks,
    description_text: []const u8,
    target: Branch,
    fork: struct { owner: []const u8, name: []const u8 },
    revision: ?Revision,
    no_changes: bool,
    commands: []const Command,
    // what an edit replaces (`evt.Patch.contentRevision`), as 32 hex digits
    edit_revision: []const u8,
    actions: Actions,
};

fn labelsOf(aa: std.mem.Allocator, labels: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.tokenizeScalar(u8, labels, ' ');
    while (iter.next()) |label| try list.append(aa, label);
    return list.items;
}

fn revisionOf(patch: *const evt.Patch) ?Revision {
    const revision = if (patch.revision) |*revision| revision else return null;
    return .{ .id = &revision.id, .source_commit = revision.source_oid, .squash_commit = revision.squash_oid, .commit_count = revision.commit_count };
}

fn summary(aa: std.mem.Allocator, entry: *const Patches.PatchWithId) !Summary {
    const patch = &entry.record.event;
    return .{
        .id = entry.id,
        .title = patch.title,
        .labels = try labelsOf(aa, patch.labels),
        .created_at = .{ .seconds = entry.record.created_timestamp },
        .target = try .init(aa, patch.target_branch),
        .revision = revisionOf(patch),
        .no_changes = entry.no_changes,
    };
}

/// the git commands for the fork of `entry` (a draft, or a patch published
/// from one), as the TUI shows them: none once the patch is merged or its
/// fork gone, or where the host serves no ssh
pub fn commandsOf(aa: std.mem.Allocator, data: ui.Session.Data, entry: *const Patches.PatchWithId) ![]const Command {
    if (!entry.fork_exists or entry.record.event.status.kind() == .merged) return &.{};
    const commands = try ui.widget.forkCommands(aa, data, entry.fork_identity, entry.id, .{ .target_deleted = entry.target_deleted });
    const out = try aa.alloc(Command, commands.len);
    for (out, commands) |*item, command| item.* = .{ .action = command.action, .url = command.url, .command = command.command };
    return out;
}

fn detail(aa: std.mem.Allocator, data: ui.Session.Data, entry: *const Patches.PatchWithId, actions: Actions) !Detail {
    const patch = &entry.record.event;
    // "owner:name", as fork urls name it
    const colon = std.mem.indexOfScalar(u8, entry.fork_identity, ':') orelse return error.InvalidForkIdentity;
    return .{
        .id = entry.id,
        .title = patch.title,
        .labels = try labelsOf(aa, patch.labels),
        .author = .{ .author = entry.author },
        .created_at = .{ .seconds = entry.record.created_timestamp },
        .description = .{ .blocks = (try md.parseText(aa, patch.description)).blocks },
        .description_text = patch.description,
        .target = try .init(aa, patch.target_branch),
        .fork = .{ .owner = entry.fork_identity[0..colon], .name = entry.fork_identity[colon + 1 ..] },
        .revision = revisionOf(patch),
        .no_changes = entry.no_changes,
        .commands = try commandsOf(aa, data, entry),
        .edit_revision = try aa.dupe(u8, &std.fmt.bytesToHex(evt.Patch.contentRevision(patch.*), .lower)),
        .actions = actions,
    };
}

fn json(aa: std.mem.Allocator, value: anytype) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(aa);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

// --- handlers ----------------------------------------------------------------
//
// a draft is its author's alone, so every route on one first finds it as the
// viewer's own (anyone else, signed in or not, is told there is none), then
// authorizes them afresh, as the TUI and the HTML forms do (`ui.authorizeUser`
// with the patches tab's role), and writes through src/draft.zig.

const Context = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: *std.heap.ArenaAllocator,
    server: api_repo.Server,
    viewer: ?[evt.event_id_size]u8,
    opened: *api_thread.Opened,
    admin_repo: *rp.Repo(.xit, evt.admin_repo_opts),

    fn onList(self: *Context, action: Action, body: Body, query: []const u8) !Answer {
        return switch (action) {
            .list => self.list(query),
            .start => self.start(body.start),
            else => unreachable,
        };
    }

    fn onDraft(self: *Context, action: Action, body: Body, encoded: []const u8) !Answer {
        const id = try parseId(self.arena.allocator(), encoded) orelse return .{ .failed = no_such_draft };
        const entry = (try self.readEntry(&id)) orelse return .{ .failed = no_such_draft };
        return switch (action) {
            .read => self.detailAnswer(&entry, .ok),
            .edit => self.edit(&id, body.edit),
            .remove => self.remove(&id),
            else => unreachable,
        };
    }

    // a retry of a publish that landed finds the draft published, and answers
    // the patch again
    fn onPublish(self: *Context, encoded: []const u8) !Answer {
        const id = try parseId(self.arena.allocator(), encoded) orelse return .{ .failed = no_such_draft };
        const owner = self.author() orelse return .{ .failed = no_such_draft };
        if (!try draft.ownsFork(self.io, self.allocator, self.server.users_dir, &owner.id, &self.target().repo_id, &id)) return .{ .failed = no_such_draft };
        const actor = switch (try self.authorize()) {
            .actor => |actor| actor,
            .refused => |err| return .{ .failed = err },
        };
        const host: evt.Host.Server = .{ .users_dir = self.server.users_dir, .admin_repo_path = self.server.admin_repo_path };
        draft.publish(host, self.io, self.allocator, self.admin_repo, self.target(), actor, &id) catch |err| return .{ .failed = try publishError(err) };
        const answer = (try api_patches.readDetail(self.arena, self.io, self.opened, &id)) orelse return .{ .failed = api_patches.no_such_patch };
        return .{ .ok = .{ .body = answer } };
    }

    fn list(self: *Context, query: []const u8) !Answer {
        const aa = self.arena.allocator();
        if (self.author() == null) return .{ .failed = log_in };
        const cursor = (query_params.param(aa, query, "cursor") catch |err| switch (err) {
            error.InvalidPercentEncoding => return .{ .failed = api_thread.stale_cursor },
            else => |e| return e,
        }) orelse "";
        const size = switch (try query_params.pageSize(aa, query, .{ .default = Patches.page_size, .max = max_page_size })) {
            .ok => |size| size,
            .invalid => |err| return .{ .failed = err },
        };
        const window = (try self.draftWindow(cursor, size)) orelse return .{ .failed = api_thread.stale_cursor };
        const items = try aa.alloc(Summary, window.items.len);
        for (items, window.items) |*item, *entry| item.* = try summary(aa, entry);
        return .{ .ok = .{ .body = try json(aa, .{
            .actions = .{ .create = self.writeAction() },
            .items = items,
            .page = .{ .has_more = window.next_id != null, .next_cursor = window.next_id, .count = api_thread.count(window) },
        }) } };
    }

    fn start(self: *Context, fields: StartRequest) !Answer {
        const aa = self.arena.allocator();
        const actor = switch (try self.authorize()) {
            .actor => |actor| actor,
            .refused => |err| return .{ .failed = err },
        };
        const chosen = api_thread.parseNewId(fields.id) orelse return .{ .failed = api_thread.invalidField("id", "Leave the id out, or send 32 lowercase hex digits.") };
        const new_fields = switch (try draftFields(aa, fields)) {
            .ok => |value| value,
            .invalid => |err| return .{ .failed = err },
        };
        const id = chosen orelse random: {
            var bytes: [evt.event_id_size]u8 = undefined;
            self.io.random(&bytes);
            break :random bytes;
        };
        draft.start(self.server.users_dir, self.io, self.allocator, self.target(), self.opened.resolved.repo.event.name, actor, &id, new_fields) catch |err| return .{ .failed = try writeError(err) };
        const entry = (try self.readEntry(&id)) orelse return .{ .failed = no_such_draft };
        return self.detailAnswer(&entry, .created);
    }

    fn edit(self: *Context, id: *const [evt.event_id_size]u8, fields: EditRequest) !Answer {
        const actor = switch (try self.authorize()) {
            .actor => |actor| actor,
            .refused => |err| return .{ .failed = err },
        };
        const revision = api_thread.parseRevision(fields.revision) orelse return .{ .failed = api_thread.invalidField("revision", "Send the edit_revision of the draft as you loaded it.") };
        const new_fields = switch (try draftFields(self.arena.allocator(), fields)) {
            .ok => |value| value,
            .invalid => |err| return .{ .failed = err },
        };
        draft.edit(self.server.users_dir, self.io, self.allocator, self.admin_repo, self.target(), actor, id, new_fields, revision) catch |err| return .{ .failed = try writeError(err) };
        const entry = (try self.readEntry(id)) orelse return .{ .failed = no_such_draft };
        return self.detailAnswer(&entry, .ok);
    }

    fn remove(self: *Context, id: *const [evt.event_id_size]u8) !Answer {
        const actor = switch (try self.authorize()) {
            .actor => |actor| actor,
            .refused => |err| return .{ .failed = err },
        };
        draft.remove(self.server.users_dir, self.io, self.allocator, &self.target().repo_id, actor, id) catch |err| return .{ .failed = try writeError(err) };
        return .{ .ok = .{ .body = try json(self.arena.allocator(), .{ .id = std.fmt.bytesToHex(id.*, .lower) }) } };
    }

    fn detailAnswer(self: *Context, entry: *const Patches.PatchWithId, status: std.http.Status) !Answer {
        const action = self.writeAction();
        const value = try detail(self.arena.allocator(), self.opened.session.data, entry, .{ .edit = action, .remove = action, .publish = action });
        return .{ .ok = .{ .body = try json(self.arena.allocator(), value), .status = status } };
    }

    // whether the viewer may write patches, which every change to a draft
    // needs, as the TUI's and the HTML forms' do
    fn writeAction(self: *Context) Availability {
        return if (ui.Repo.tabViewer(self.opened.handle, self.opened.resolved.repo, .patch) != null) .available else role_forbidden;
    }

    fn authorize(self: *Context) !api_thread.Authorized {
        return api_thread.authorize(.patch, self.io, self.allocator, self.arena, .{ .server = self.server }, self.viewer, self.opened);
    }

    fn author(self: *Context) ?draft.Owner {
        const id = self.opened.session.userId() orelse return null;
        return .{ .id = id, .name = self.opened.session.data.user_name orelse return null };
    }

    fn target(self: *Context) draft.Target {
        // a server always resolves a repo's id
        return .{ .source = self.opened.source, .repo_id = self.opened.resolved.repo_id.? };
    }

    // the viewer's draft `id` of this repo, or null when they have none
    fn readEntry(self: *Context, id: *const [evt.event_id_size]u8) !?Patches.PatchWithId {
        const user = self.author() orelse return null;
        const admin_moment = self.opened.session.haxy_moment orelse return null;
        const source = self.opened.source;
        switch (source.repo_kind) {
            inline else => |repo_kind| {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(self.io, self.allocator, source.localInitOpts());
                defer any_repo.deinit(self.io, self.allocator);
                return switch (any_repo) {
                    inline else => |*repo| draft.read(repo_kind, repo.self_repo_opts, self.arena, self.io, admin_moment, self.server.users_dir, user, &self.target().repo_id, repo, id),
                };
            },
        }
    }

    // the viewer's drafts from the one `cursor` names ("" for the first), or
    // null when it names none of them
    fn draftWindow(self: *Context, cursor: []const u8, size: usize) !?Patches.Window {
        // a cursor names one of the viewer's drafts of this repo, even one
        // whose fork can't be read any more (the window starts past it)
        if (cursor.len != 0) {
            const user = self.author() orelse return null;
            const id = evt.parseEventId(cursor) catch return null;
            if (!try draft.isDraft(self.io, self.allocator, self.server.users_dir, &user.id, &self.target().repo_id, &id)) return null;
        }
        const admin_moment = self.opened.session.haxy_moment orelse return null;
        const source = self.opened.source;
        const window = switch (source.repo_kind) {
            inline else => |repo_kind| window: {
                var any_repo = try rp.AnyRepo(repo_kind, .{}).open(self.io, self.allocator, source.localInitOpts());
                defer any_repo.deinit(self.io, self.allocator);
                break :window switch (any_repo) {
                    inline else => |*repo| Patches.loadDraftWindow(repo_kind, repo.self_repo_opts, self.arena, &self.opened.session, admin_moment, &self.target().repo_id, cursor, repo, size),
                };
            },
        } catch |err| switch (err) {
            error.NotFound => return null,
            else => |e| return e,
        };
        return window;
    }
};

// a draft id from a route, or null when it names none
fn parseId(aa: std.mem.Allocator, encoded: []const u8) !?[evt.event_id_size]u8 {
    return evt.parseEventId(std.Uri.percentDecodeInPlace(try aa.dupe(u8, encoded))) catch null;
}

// a draft's fields from a write's body, its target a branch ref id, checked by the shared field rules
fn draftFields(aa: std.mem.Allocator, fields: anytype) !union(enum) { ok: thread_write.Fields, invalid: api.Error } {
    const target_branch = try api_patches.branchName(aa, fields.target) orelse return .{ .invalid = api_patches.branchesError(error.InvalidTargetBranch).? };
    var new_fields = try api_thread.bodyFields(aa, fields);
    new_fields.target_branch = target_branch;
    if (thread_write.checkFields(.patch, new_fields)) |failure| return .{ .invalid = api_thread.fieldsError(failure) };
    return .{ .ok = new_fields };
}

// a draft write's refusal, as the API answers it
fn writeError(err: anyerror) !api.Error {
    if (api_patches.branchesError(err)) |refused| return refused;
    return switch (err) {
        error.IdTaken => api_thread.id_taken,
        error.NotFound => no_such_draft,
        error.Stale => stale_revision,
        else => return err,
    };
}

// why publishing a draft was refused, as Haxy's publish says it
fn publishError(err: anyerror) !api.Error {
    return switch (err) {
        error.NotFound => no_such_draft,
        error.PatchIdTaken => patch_id_taken,
        error.PatchNotPushed => not_pushed,
        error.PatchDataUnavailable => fork_unreadable,
        else => return err,
    };
}
