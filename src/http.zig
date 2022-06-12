const std = @import("std");
const net = std.net;
const print = std.debug.print;
const Allocator = std.mem.Allocator;
const Address = net.Address;
const StreamServer = net.StreamServer;

pub const ParsingError = error{
    MethodNotValid,
    VersionNotValid,
};

pub const Method = enum {
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

pub const Version = enum {
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

pub const Status = enum {
    OK,
    // TODO: add other HTTP status codes

    const Self = @This();

    pub fn asString(self: Self) []const u8 {
        if (self == .OK) return "OK";
    }

    pub fn asNumber(self: Self) usize {
        if (self == .OK) return 200;
    }
};

pub const Context = struct {
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
        print("\n{s} {s} {s}\n", .{ self.method.asString(), self.uri, self.version.asString() });
        var headers_iter = self.headers.iterator();
        while (headers_iter.next()) |entry| {
            print("{s}: {s}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }

    pub fn init(allocator: Allocator, stream: net.Stream) !Self {
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

        return Context{
            .headers = headers,
            .method = try Method.fromString(method),
            .version = try Version.fromString(version),
            .uri = uri,
            .stream = stream,
        };
    }
};

pub const Server = struct {
    config: Config,
    allocator: Allocator,
    address: Address,
    stream_server: StreamServer = undefined,
    frames: std.ArrayList(*Connection),

    const Self = @This();

    pub const Connection = struct {
        frame: @Frame(run_handler),
    };

    pub const Config = struct {
        host: []const u8 = "127.0.0.1",
        port: u16 = 8080,
        handlers: []Handler = undefined,
    };

    pub fn deinit(self: *Self) void {
        self.stream_server.deinit();
    }

    pub fn init(allocator: Allocator, config: Config) !Self {
        return Self{
            .allocator = allocator,
            .config = config,
            .address = try Address.resolveIp(config.host, config.port),
            .frames = std.ArrayList(*Connection).init(allocator),
        };
    }

    pub fn run_handler(self: Self, stream: net.Stream) !void {
        defer stream.close();

        var context = try Context.init(self.allocator, stream);
        context.debugPrintRequest();

        for (self.config.handlers) |handler| {
            if (try handler.predicate(context)) {
                try handler.func(context);
                break;
            }
        }
    }

    pub fn listen(self: *Self) !void {
        var stream_server = StreamServer.init(.{});
        try stream_server.listen(self.address);

        print("[INFO] Server listening on port {} ({})\n", .{ self.config.port, self.address });

        while (true) {
            const connection = try stream_server.accept();
            var conn = try self.allocator.create(Connection);
            conn.* = .{ .frame = async self.run_handler(connection.stream) };
            try self.frames.append(conn);
        }
    }
};

const Handler = struct {
    predicate: fn (Context) anyerror!bool,
    func: fn (Context) anyerror!void,

    const Self = @This();
};
