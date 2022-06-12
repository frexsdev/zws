const std = @import("std");
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const http = @import("http.zig");
const Server = http.Server;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try Server.init(allocator, .{});
    defer server.deinit();

    try server.listen();
}
