//! repository paths in the JSON API. git paths are bytes and needn't be
//! utf-8, so JSON can't carry them raw. every path a response names is sent
//! percent-encoded (see haxy-hub's docs/api-conventions.md, "Repository
//! paths"), which a client sends back unchanged as a `path` parameter, and
//! every name has a utf-8 form for display.

const std = @import("std");

/// `bytes` with every byte but an unreserved one (A-Z a-z 0-9 - . _ ~) and
/// the `/` separator written as %XX in uppercase hex. it is plain ascii, so
/// it goes into json, urls and query strings as is, and decoding it once
/// gives back the exact bytes.
pub fn encode(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    for (bytes) |byte| {
        if (std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '.' or byte == '_' or byte == '~' or byte == '/') {
            try out.writer.writeByte(byte);
        } else {
            try out.writer.print("%{X:0>2}", .{byte});
        }
    }
    return out.written();
}

/// `bytes` as utf-8 for display, ill-formed sequences replaced by U+FFFD
/// as the WHATWG decoder (and so a browser's TextDecoder) replaces them
pub fn display(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
    return std.fmt.allocPrint(arena, "{f}", .{std.unicode.fmtUtf8(bytes)});
}

/// a path as a response names it: encoded to travel, and its last segment's
/// display name
pub const Named = struct {
    name: []const u8,
    path: []const u8,

    pub fn init(arena: std.mem.Allocator, path: []const u8) !Named {
        const slash = std.mem.lastIndexOfScalar(u8, path, '/');
        return .{
            .name = try display(arena, if (slash) |s| path[s + 1 ..] else path),
            .path = try encode(arena, path),
        };
    }
};
