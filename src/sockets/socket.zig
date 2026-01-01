const std = @import("std");
const net = std.net;

/// Socket type
pub const SocketType = enum(u8) {
    stream = 1, // TCP
    dgram = 2, // UDP
};

/// Address family
pub const AddressFamily = enum(u8) {
    inet = 2, // IPv4
    inet6 = 10, // IPv6
};

/// Socket protocol
pub const Protocol = enum(u8) {
    tcp = 6,
    udp = 17,
};

/// Socket error codes (matching POSIX errno values)
pub const SocketError = enum(u16) {
    success = 0,
    access = 13, // EACCES - Permission denied
    addrinuse = 98, // EADDRINUSE - Address already in use
    addrnotavail = 99, // EADDRNOTAVAIL - Address not available
    afnosupport = 97, // EAFNOSUPPORT - Address family not supported
    wouldblock = 11, // EAGAIN / EWOULDBLOCK - Resource temporarily unavailable
    already = 114, // EALREADY - Connection already in progress
    badf = 9, // EBADF - Bad file descriptor
    connaborted = 103, // ECONNABORTED - Connection aborted
    connrefused = 111, // ECONNREFUSED - Connection refused
    connreset = 104, // ECONNRESET - Connection reset
    destaddrreq = 89, // EDESTADDRREQ - Destination address required
    hostunreach = 113, // EHOSTUNREACH - Host is unreachable
    inprogress = 115, // EINPROGRESS - Operation in progress
    intr = 4, // EINTR - Interrupted system call
    inval = 22, // EINVAL - Invalid argument
    isconn = 106, // EISCONN - Socket is connected
    msgsize = 90, // EMSGSIZE - Message too long
    netdown = 100, // ENETDOWN - Network is down
    netunreach = 101, // ENETUNREACH - Network unreachable
    nobufs = 105, // ENOBUFS - No buffer space available
    notconn = 107, // ENOTCONN - Socket not connected
    notsock = 88, // ENOTSOCK - Not a socket
    opnotsupp = 95, // EOPNOTSUPP / ENOTSUP - Operation not supported
    protonosupport = 93, // EPROTONOSUPPORT - Protocol not supported
    prototype = 91, // EPROTOTYPE - Protocol wrong type for socket
    timedout = 110, // ETIMEDOUT - Connection timed out
};

/// Socket address structure for WASI interface
pub const SocketAddress = struct {
    family: AddressFamily,
    port: u16,
    addr: union {
        ipv4: [4]u8,
        ipv6: [16]u8,
    },

    pub fn fromStdAddress(std_addr: net.Address) SocketAddress {
        return switch (std_addr.any.family) {
            std.posix.AF.INET => SocketAddress{
                .family = .inet,
                .port = std_addr.in.getPort(),
                .addr = .{ .ipv4 = @bitCast(std_addr.in.sa.addr) },
            },
            std.posix.AF.INET6 => SocketAddress{
                .family = .inet6,
                .port = std_addr.in6.getPort(),
                .addr = .{ .ipv6 = std_addr.in6.sa.addr },
            },
            else => unreachable,
        };
    }

    pub fn toStdAddress(self: SocketAddress) net.Address {
        return switch (self.family) {
            .inet => net.Address.initIp4(self.addr.ipv4, self.port),
            .inet6 => net.Address.initIp6(self.addr.ipv6, self.port, 0, 0),
        };
    }
};

/// Socket handle (file descriptor)
pub const SocketHandle = u32;

/// Socket state
pub const SocketState = enum {
    unbound,
    bound,
    listening,
    connecting,
    connected,
    closed,
};

/// Socket instance
pub const Socket = struct {
    handle: SocketHandle,
    socket_type: SocketType,
    family: AddressFamily,
    stream: ?net.Stream,
    server: ?net.Server,
    state: SocketState,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, handle: SocketHandle, socket_type: SocketType, family: AddressFamily) Socket {
        return Socket{
            .handle = handle,
            .socket_type = socket_type,
            .family = family,
            .stream = null,
            .server = null,
            .state = .unbound,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Socket) void {
        self.close();
    }

    pub fn close(self: *Socket) void {
        if (self.stream) |s| {
            s.close();
            self.stream = null;
        }
        if (self.server) |*s| {
            s.deinit();
            self.server = null;
        }
        self.state = .closed;
    }
};

/// Global socket table
pub const SocketTable = struct {
    sockets: std.AutoHashMap(SocketHandle, Socket),
    next_handle: SocketHandle,
    allocator: std.mem.Allocator,
    mutex: std.Thread.Mutex,

    pub fn init(allocator: std.mem.Allocator) SocketTable {
        return SocketTable{
            .sockets = std.AutoHashMap(SocketHandle, Socket).init(allocator),
            .next_handle = 1000, // Start at 1000 to avoid conflicts with FDs
            .allocator = allocator,
            .mutex = std.Thread.Mutex{},
        };
    }

    pub fn deinit(self: *SocketTable) void {
        var iter = self.sockets.valueIterator();
        while (iter.next()) |socket| {
            var s = socket.*;
            s.deinit();
        }
        self.sockets.deinit();
    }

    pub fn create(self: *SocketTable, socket_type: SocketType, family: AddressFamily) !SocketHandle {
        self.mutex.lock();
        defer self.mutex.unlock();

        const handle = self.next_handle;
        self.next_handle += 1;

        const socket = Socket.init(self.allocator, handle, socket_type, family);
        try self.sockets.put(handle, socket);

        return handle;
    }

    pub fn get(self: *SocketTable, handle: SocketHandle) ?*Socket {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.sockets.getPtr(handle);
    }

    pub fn remove(self: *SocketTable, handle: SocketHandle) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.sockets.getPtr(handle)) |socket| {
            socket.deinit();
            _ = self.sockets.remove(handle);
        }
    }
};

/// DNS resolution result
pub const DnsResult = struct {
    addresses: []net.Address,
    allocator: std.mem.Allocator,

    pub fn deinit(self: DnsResult) void {
        self.allocator.free(self.addresses);
    }
};

/// Resolve a hostname to IP addresses
pub fn resolveHost(allocator: std.mem.Allocator, hostname: []const u8, port: u16) !DnsResult {
    const list = try net.getAddressList(allocator, hostname, port);
    defer list.deinit();

    if (list.addrs.len == 0) {
        return error.HostNotFound;
    }

    const addresses = try allocator.alloc(net.Address, list.addrs.len);
    @memcpy(addresses, list.addrs);

    return DnsResult{
        .addresses = addresses,
        .allocator = allocator,
    };
}

/// Connect a socket to a remote address
pub fn connect(socket: *Socket, address: net.Address) !void {
    if (socket.state != .unbound) {
        return error.InvalidState;
    }

    socket.state = .connecting;

    const stream = try net.tcpConnectToAddress(address);
    socket.stream = stream;
    socket.state = .connected;
}

/// Send data on a connected socket
pub fn send(socket: *Socket, data: []const u8) !usize {
    if (socket.state != .connected) {
        return error.NotConnected;
    }

    if (socket.stream) |stream| {
        return try stream.write(data);
    }

    return error.InvalidSocket;
}

/// Receive data from a connected socket
pub fn recv(socket: *Socket, buffer: []u8) !usize {
    if (socket.state != .connected) {
        return error.NotConnected;
    }

    if (socket.stream) |stream| {
        return try stream.read(buffer);
    }

    return error.InvalidSocket;
}

/// Bind a socket to a local address
pub fn bind(socket: *Socket, address: net.Address) !void {
    _ = address; // Will be used in listen() for TCP
    if (socket.state != .unbound) {
        return error.AlreadyBound;
    }

    if (socket.socket_type == .stream) {
        // For TCP, we'll create the server on listen()
        socket.state = .bound;
    } else {
        // UDP binding would go here
        return error.NotImplemented;
    }
}

/// Listen for connections on a socket
pub fn listen(socket: *Socket, address: net.Address, backlog: u31) !void {
    if (socket.state != .bound and socket.state != .unbound) {
        return error.InvalidState;
    }

    const server = try address.listen(.{
        .reuse_address = true,
        .kernel_backlog = backlog,
    });

    socket.server = server;
    socket.state = .listening;
}

/// Accept a connection on a listening socket
pub fn accept(socket: *Socket) !net.Server.Connection {
    if (socket.state != .listening) {
        return error.NotListening;
    }

    if (socket.server) |*server| {
        return try server.accept();
    }

    return error.InvalidSocket;
}
