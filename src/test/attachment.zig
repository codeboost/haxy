const std = @import("std");
const attachment = @import("../attachment.zig");
const evt = @import("../event.zig");

test "only images on the safe list open inline; known files download with their type, and active content as opaque bytes" {
    const cases = [_]struct { name: []const u8, content_type: []const u8, inline_: bool }{
        .{ .name = "screenshot.png", .content_type = "image/png", .inline_ = true },
        .{ .name = "PHOTO.JPG", .content_type = "image/jpeg", .inline_ = true },
        .{ .name = "photo.jpeg", .content_type = "image/jpeg", .inline_ = true },
        .{ .name = "anim.gif", .content_type = "image/gif", .inline_ = true },
        .{ .name = "pic.webp", .content_type = "image/webp", .inline_ = true },
        .{ .name = "report.pdf", .content_type = "application/pdf", .inline_ = false },
        .{ .name = "notes.txt", .content_type = "text/plain; charset=utf-8", .inline_ = false },
        .{ .name = "data.json", .content_type = "application/json", .inline_ = false },
        .{ .name = "table.csv", .content_type = "text/csv; charset=utf-8", .inline_ = false },
        .{ .name = "bundle.zip", .content_type = "application/zip", .inline_ = false },
        // anything that could run as script on this origin is opaque bytes
        .{ .name = "page.html", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "page.HTM", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "logo.svg", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "app.js", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "feed.xml", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "Makefile", .content_type = "application/octet-stream", .inline_ = false },
        // a name that is only an extension has no type
        .{ .name = ".png", .content_type = "application/octet-stream", .inline_ = false },
        .{ .name = "image.png.html", .content_type = "application/octet-stream", .inline_ = false },
    };
    for (cases) |case| {
        const handling = attachment.handling(case.name);
        try std.testing.expectEqualStrings(case.content_type, handling.content_type);
        try std.testing.expectEqual(case.inline_, handling.inline_);
    }
}

test "the content disposition names the file as RFC 6266 does, with an ASCII fallback" {
    const allocator = std.testing.allocator;
    const plain = try attachment.disposition(allocator, "report.pdf", false);
    defer allocator.free(plain);
    try std.testing.expectEqualStrings("attachment; filename=\"report.pdf\"; filename*=UTF-8''report.pdf", plain);

    const fancy = try attachment.disposition(allocator, "café \"x\";y.png", true);
    defer allocator.free(fancy);
    try std.testing.expectEqualStrings("inline; filename=\"caf__ _x__y.png\"; filename*=UTF-8''caf%C3%A9%20%22x%22%3By.png", fancy);
}

test "an upload needs a valid name and a declared length between one byte and the limit" {
    try std.testing.expectEqual(null, attachment.checkUpload("notes.txt", 1));
    try std.testing.expectEqual(null, attachment.checkUpload("notes.txt", attachment.max_size));
    try std.testing.expectEqual(.name_required, attachment.checkUpload(null, 1).?);
    try std.testing.expectEqual(.name_required, attachment.checkUpload("", 1).?);
    try std.testing.expectEqual(.invalid_name, attachment.checkUpload("a/b.txt", 1).?);
    try std.testing.expectEqual(.invalid_name, attachment.checkUpload("..", 1).?);
    try std.testing.expectEqual(.invalid_name, attachment.checkUpload("tab\there", 1).?);
    const long: [evt.Attachment.name_max_len + 1]u8 = @splat('n');
    try std.testing.expectEqual(.invalid_name, attachment.checkUpload(&long, 1).?);
    try std.testing.expectEqual(.length_required, attachment.checkUpload("notes.txt", null).?);
    try std.testing.expectEqual(.empty, attachment.checkUpload("notes.txt", 0).?);
    try std.testing.expectEqual(.too_large, attachment.checkUpload("notes.txt", attachment.max_size + 1).?);
}

test "an upload's length is the one it declares only when it isn't chunked" {
    try std.testing.expectEqual(@as(?u64, 5), attachment.declaredLength(5, .none));
    try std.testing.expectEqual(@as(?u64, null), attachment.declaredLength(null, .none));
    // the body reader follows the chunks, whatever length the request also claims
    try std.testing.expectEqual(@as(?u64, null), attachment.declaredLength(5, .chunked));
}
