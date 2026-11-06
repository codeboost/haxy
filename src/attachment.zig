//! the rules every way of reading or uploading an attachment shares: Haxy's
//! own pages (the TUI's `add attachment` and download links), its HTML
//! upload route and the JSON API all come through here, so the size and
//! name limits, which files a browser may render inline, how a download is
//! named and who may read the bytes live in one place. writing (attaching
//! and removing) is `thread_write.attach` and `thread_write.remove`.
//!
//! - an upload is one file, the whole request body, of at most `max_size`
//!   bytes with a name `evt.Attachment.nameValid` accepts (`checkUpload`);
//! - a download is served only from a repo the viewer may read, while the
//!   attachment and the thread it hangs off are live (`readServable`);
//! - only images on a safe list open inline; everything else downloads, and
//!   anything that could run as script on this origin is opaque bytes
//!   (`handling`), served with `nosniff` and a sandboxing CSP (`send`).

const std = @import("std");
const xit = @import("xit");
const rp = xit.repo;
const hash = xit.hash;
const obj = xit.object;
const evt = @import("./event.zig");
const thread_write = @import("./thread_write.zig");

/// the largest file an attachment may hold, in bytes
pub const max_size: u64 = evt.Attachment.max_size;
/// the longest name an attachment may have, in bytes
pub const name_max_len: usize = evt.Attachment.name_max_len;

/// how a download is served: its content type, and whether a browser may
/// render it in place
pub const Handling = struct {
    content_type: []const u8,
    inline_: bool,
};

const opaque_bytes: Handling = .{ .content_type = "application/octet-stream", .inline_ = false };

// by extension. only images a browser renders as images (never as a
// document that could run script) open inline; the rest download with their
// type. svg, html, js, xml and anything unknown are left out on purpose:
// they download as opaque bytes.
const known = [_]struct { ext: []const u8, handling: Handling }{
    .{ .ext = ".png", .handling = .{ .content_type = "image/png", .inline_ = true } },
    .{ .ext = ".jpg", .handling = .{ .content_type = "image/jpeg", .inline_ = true } },
    .{ .ext = ".jpeg", .handling = .{ .content_type = "image/jpeg", .inline_ = true } },
    .{ .ext = ".gif", .handling = .{ .content_type = "image/gif", .inline_ = true } },
    .{ .ext = ".webp", .handling = .{ .content_type = "image/webp", .inline_ = true } },
    .{ .ext = ".pdf", .handling = .{ .content_type = "application/pdf", .inline_ = false } },
    .{ .ext = ".txt", .handling = .{ .content_type = "text/plain; charset=utf-8", .inline_ = false } },
    .{ .ext = ".log", .handling = .{ .content_type = "text/plain; charset=utf-8", .inline_ = false } },
    .{ .ext = ".md", .handling = .{ .content_type = "text/markdown; charset=utf-8", .inline_ = false } },
    .{ .ext = ".csv", .handling = .{ .content_type = "text/csv; charset=utf-8", .inline_ = false } },
    .{ .ext = ".json", .handling = .{ .content_type = "application/json", .inline_ = false } },
    .{ .ext = ".zip", .handling = .{ .content_type = "application/zip", .inline_ = false } },
    .{ .ext = ".gz", .handling = .{ .content_type = "application/gzip", .inline_ = false } },
    .{ .ext = ".tar", .handling = .{ .content_type = "application/x-tar", .inline_ = false } },
    .{ .ext = ".mp4", .handling = .{ .content_type = "video/mp4", .inline_ = false } },
    .{ .ext = ".webm", .handling = .{ .content_type = "video/webm", .inline_ = false } },
    .{ .ext = ".mp3", .handling = .{ .content_type = "audio/mpeg", .inline_ = false } },
};

/// how the attachment `name` is served, by its extension
pub fn handling(name: []const u8) Handling {
    for (known) |entry| {
        if (name.len > entry.ext.len and std.ascii.eqlIgnoreCase(name[name.len - entry.ext.len ..], entry.ext)) return entry.handling;
    }
    return opaque_bytes;
}

/// the `Content-Disposition` naming a download `name` (RFC 6266): `filename*`
/// with the name's bytes percent-encoded as UTF-8, and a `filename` fallback
/// for clients without it, where every byte that isn't plain printable ASCII
/// (or is a quote or backslash) becomes `_`. owned by the caller.
pub fn disposition(allocator: std.mem.Allocator, name: []const u8, inline_: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    try w.writeAll(if (inline_) "inline" else "attachment");
    try w.writeAll("; filename=\"");
    for (name) |byte| try w.writeByte(if (byte < 0x20 or byte >= 0x7f or byte == '"' or byte == '\\' or byte == ';') '_' else byte);
    try w.writeAll("\"; filename*=UTF-8''");
    try std.Uri.Component.percentEncode(w, name, isAttrChar);
    return out.toOwnedSlice();
}

// RFC 5987's attr-char: what `filename*` may hold unescaped
fn isAttrChar(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '!', '#', '$', '&', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

/// why an upload is refused before any of it is read
pub const UploadFailure = enum {
    // no name was given
    name_required,
    // the name isn't one an attachment may have (`evt.Attachment.nameValid`)
    invalid_name,
    // the request doesn't declare its length
    length_required,
    // the file has no bytes
    empty,
    // the file is larger than `max_size`
    too_large,
};

/// the length an upload declares for its body: its `Content-Length`, unless
/// it is also chunked, when the body reader follows the chunks and the
/// length bounds nothing (null, so `checkUpload` asks for a length)
pub fn declaredLength(content_length: ?u64, transfer_encoding: std.http.TransferEncoding) ?u64 {
    return if (transfer_encoding == .none) content_length else null;
}

/// what is wrong with an upload of `size` bytes (null when undeclared) named
/// `name`, or null when nothing is
pub fn checkUpload(name: ?[]const u8, size: ?u64) ?UploadFailure {
    const given = name orelse return .name_required;
    if (given.len == 0) return .name_required;
    if (!evt.Attachment.nameValid(given)) return .invalid_name;
    const length = size orelse return .length_required;
    if (length == 0) return .empty;
    if (length > max_size) return .too_large;
    return null;
}

/// the thread a download's route names, which must hold the attachment
pub const ThreadRef = struct {
    kind: evt.EventKind,
    id: *const [evt.event_id_size]u8,
};

/// the attachment `id` names in `moment`, when it may be served: it exists,
/// isn't removed, and hangs off a live thread (the thread `thread` names,
/// when given). null otherwise, however it failed, so a removed attachment
/// or one under a removed thread answers like one that never was.
pub fn readServable(
    comptime hash_kind: hash.HashKind,
    arena: *std.heap.ArenaAllocator,
    moment: evt.EventDB(hash_kind).HashMap(.read_only),
    id: *const [evt.event_id_size]u8,
    thread: ?ThreadRef,
) !?evt.Attachment.Record {
    const DB = evt.EventDB(hash_kind);
    const record = (try evt.Attachment.readById(DB, hash_kind, moment, arena, id)) orelse return null;
    if (record.removed) return null;
    if (record.blob_oid.len != hash.hexLen(hash_kind)) return null;
    const target_id = evt.parseEventId(&record.event.target_id) catch return null;
    if (thread) |named| {
        if (!std.mem.eql(u8, &target_id, named.id)) return null;
        if (!try thread_write.threadLiveAt(hash_kind, arena, moment, named.kind, &target_id)) return null;
    } else {
        const kind = (try thread_write.kindOf(hash_kind, moment, &target_id)) orelse return null;
        if (!try thread_write.threadLiveAt(hash_kind, arena, moment, kind, &target_id)) return null;
    }
    return record;
}

/// the headers every download carries besides its length
pub const download_headers = struct {
    // uploaded bytes are never sniffed into a type that could run as script
    // on this origin, and even a document rendered from them runs nothing
    pub const nosniff: std.http.Header = .{ .name = "x-content-type-options", .value = "nosniff" };
    pub const csp: std.http.Header = .{ .name = "content-security-policy", .value = "default-src 'none'; style-src 'unsafe-inline'; sandbox" };
    // who may read an attachment can change, so nothing keeps a copy
    pub const no_store: std.http.Header = .{ .name = "cache-control", .value = "private, no-store" };
};

/// serves the attachment `id` names from `repo`, streamed from the object
/// store, when `readServable` allows it; false (and nothing sent) when it
/// doesn't, so the caller answers "not found" in its own way. the caller has
/// checked that the viewer may read the repo.
pub fn send(
    comptime repo_kind: rp.RepoKind,
    comptime repo_opts: rp.RepoOpts(repo_kind),
    io: std.Io,
    request: *std.http.Server.Request,
    allocator: std.mem.Allocator,
    repo: *rp.Repo(repo_kind, repo_opts),
    id: *const [evt.event_id_size]u8,
    thread: ?ThreadRef,
) !bool {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var event_db_maybe: ?evt.LocalEventDB(repo_opts.hash) = if (repo_kind == .git) try evt.LocalEventDB(repo_opts.hash).openReadOnly(io, allocator, repo.core.repo_dir) else null;
    defer if (event_db_maybe) |*event_db| event_db.deinit(io, allocator);
    const haxy_moment = (if (event_db_maybe) |*event_db|
        evt.currentMomentFromDb(repo_opts.hash, event_db.db)
    else if (repo_kind == .git)
        return false
    else
        evt.currentMoment(repo_opts, repo)) catch return false;

    const record = (try readServable(repo_opts.hash, &arena, haxy_moment, id, thread)) orelse return false;
    const blob_oid: *const [hash.hexLen(repo_opts.hash)]u8 = record.blob_oid[0..comptime hash.hexLen(repo_opts.hash)];

    var moment = repo.core.latestMoment() catch return false;
    const state = rp.Repo(repo_kind, repo_opts).State(.read_only){ .core = &repo.core, .extra = .{ .moment = &moment } };
    var object_reader = obj.ObjectReader(repo_kind, repo_opts).init(state, io, allocator, blob_oid) catch return false;
    defer object_reader.deinit();
    if (object_reader.header().kind != .blob) return false;

    const how = handling(record.name);
    const content_disposition = try disposition(allocator, record.name, how.inline_);
    defer allocator.free(content_disposition);

    var send_buf: [8192]u8 = undefined;
    var body = try request.respondStreaming(&send_buf, .{
        .content_length = object_reader.header().size,
        .respond_options = .{
            .extra_headers = &.{
                .{ .name = "content-type", .value = how.content_type },
                .{ .name = "content-disposition", .value = content_disposition },
                download_headers.nosniff,
                download_headers.csp,
                download_headers.no_store,
            },
        },
    });
    // a HEAD request's body is elided as it is written, so the length the
    // header promised still adds up
    _ = try object_reader.interface.streamRemaining(&body.writer);
    try body.end();
    return true;
}
