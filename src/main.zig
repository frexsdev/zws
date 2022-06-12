const std = @import("std");
const net = std.net;
const StreamServer = net.StreamServer;
const Address = net.Address;
const GeneralPurposeAllocator = std.heap.GeneralPurposeAllocator;
const print = std.debug.print;

pub const io_mode = .evented;

pub fn main() !void {
    var gpa = GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    var stream_server = StreamServer.init(.{});
    defer stream_server.close();

    const address = try Address.resolveIp("127.0.0.1", 8080);
    try stream_server.listen(address);

    var frames = std.ArrayList(*Connection).init(allocator);
    while (true) {
        const connection = try stream_server.accept();
        var conn = try allocator.create(Connection);
        conn.* = .{ .frame = async handler(allocator, connection.stream) };
        try frames.append(conn);
    }
}

const Connection = struct {
    frame: @Frame(handler),
};

const ParsingError = error{
    MethodNotValid,
    VersionNotValid,
};

const Method = enum {
    GET,
    POST,
    PUT,
    PATCH,
    OPTION,
    DELETE,

    const Self = @This();

    pub fn fromString(s: []const u8) ParsingError!Self {
        if (std.mem.eql(u8, "GET", s)) return .GET;
        if (std.mem.eql(u8, "POST", s)) return .POST;
        if (std.mem.eql(u8, "PUT", s)) return .PUT;
        if (std.mem.eql(u8, "PATCH", s)) return .PATCH;
        if (std.mem.eql(u8, "OPTION", s)) return .OPTION;
        if (std.mem.eql(u8, "DELETE", s)) return .DELETE;

        return ParsingError.MethodNotValid;
    }

    pub fn asString(self: Self) []const u8 {
        if (self == .GET) return "GET";
        if (self == .POST) return "POST";
        if (self == .PUT) return "PUT";
        if (self == .PATCH) return "PATCH";
        if (self == .OPTION) return "OPTION";
        if (self == .DELETE) return "DELETE";

        unreachable;
    }
};

const Version = enum {
    @"1.1",
    @"2",

    const Self = @This();

    pub fn fromString(s: []const u8) ParsingError!Self {
        if (std.mem.eql(u8, "HTTP/1.1", s)) return .@"1.1";
        if (std.mem.eql(u8, "HTTP/2", s)) return .@"2";

        return ParsingError.VersionNotValid;
    }

    pub fn asString(self: Self) []const u8 {
        if (self == .@"1.1") return "HTTP/1.1";
        if (self == .@"2") return "HTTP/2";

        unreachable;
    }
};

const Status = enum {
    OK,

    const Self = @This();

    pub fn asString(self: Self) []const u8 {
        if (self == .OK) return "OK";
    }

    pub fn asNumber(self: Self) usize {
        if (self == .OK) return 200;
    }
};

const HTTPContext = struct {
    method: Method,
    uri: []const u8,
    version: Version,
    headers: std.StringHashMap([]const u8),
    stream: net.Stream,

    const Self = @This();

    pub fn bodyReader(self: *Self) net.Stream.Reader {
        return self.stream.reader();
    }

    pub fn response(self: *Self) net.Stream.Writer {
        return self.stream.writer();
    }

    pub fn respond(self: *Self, status: Status, maybe_headers: ?std.StringHashMap([]const u8), body: []const u8) !void {
        var writer = self.response();
        try writer.print("{s} {} {s}\r\n", .{ self.version.asString(), status.asNumber(), status.asString() });

        if (maybe_headers) |headers| {
            var headers_iter = headers.iterator();
            while (headers_iter.next()) |entry| {
                try writer.print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
            }
        }

        try writer.print("\r\n", .{});
        _ = try writer.write(body);
    }

    pub fn debugPrintRequest(self: *Self) void {
        print("{s} {s} {s}\n", .{ self.method.asString(), self.uri, self.version.asString() });
        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    pub fn init(allocator: std.mem.Allocator, stream: net.Stream) !Self {
        var first_line = try stream.reader().readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize));
        first_line = first_line[0 .. first_line.len - 1];
        var first_line_iter = std.mem.split(u8, first_line, " ");

        const method = first_line_iter.next().?;
        const uri = first_line_iter.next().?;
        const version = first_line_iter.next().?;

        var headers = std.StringHashMap([]const u8).init(allocator);

        while (true) {
            var line = try stream.reader().readUntilDelimiterAlloc(allocator, '\n', std.math.maxInt(usize));
            if (line.len == 1 and std.mem.eql(u8, line, "\r")) break;

            line = line[0..line.len];
            var line_iter = std.mem.split(u8, line, ":");

            const key = line_iter.next().?;
            var value = line_iter.next().?;

            if (value[0] == ' ') value = value[1..];
            try headers.put(key, value);
        }

        return HTTPContext{
            .headers = headers,
            .method = try Method.fromString(method),
            .version = try Version.fromString(version),
            .uri = uri,
            .stream = stream,
        };
    }
};

fn handler(allocator: std.mem.Allocator, stream: net.Stream) !void {
    defer stream.close();

    var http_context = try HTTPContext.init(allocator, stream);
    if (std.mem.eql(u8, http_context.uri, "/sleep")) std.time.sleep(std.time.ns_per_s * 10);
    http_context.debugPrintRequest();

    try http_context.respond(Status.OK, null, "Hello, World!\n");
}
