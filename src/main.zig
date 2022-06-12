const std = @import("std");
const net = std.net;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const print = std.debug.print;
const http = @import("http.zig");
const HTTPServer = http.HTTPServer;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var server = try HTTPServer.init(allocator, .{ });
    defer server.deinit();

    try server.listen();
}
