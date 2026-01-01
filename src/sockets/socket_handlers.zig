const std = @import("std");
const zware = @import("zware");
const socket_mod = @import("socket.zig");
const SocketTable = socket_mod.SocketTable;
const SocketType = socket_mod.SocketType;
const AddressFamily = socket_mod.AddressFamily;
const SocketAddress = socket_mod.SocketAddress;
const SocketError = socket_mod.SocketError;

/// Global socket table
var global_socket_table: ?*SocketTable = null;

/// Initialize the socket system
pub fn init(allocator: std.mem.Allocator) !void {
    if (global_socket_table == null) {
        const table = try allocator.create(SocketTable);
        table.* = SocketTable.init(allocator);
        global_socket_table = table;
    }
}

/// Deinitialize the socket system
pub fn deinit(allocator: std.mem.Allocator) void {
    if (global_socket_table) |table| {
        table.deinit();
        allocator.destroy(table);
        global_socket_table = null;
    }
}

/// Helper to convert Zig errors to WASI socket errors
fn toSocketError(err: anyerror) u32 {
    return switch (err) {
        error.AccessDenied => @intFromEnum(SocketError.access),
        error.AddressInUse => @intFromEnum(SocketError.addrinuse),
        error.AddressNotAvailable => @intFromEnum(SocketError.addrnotavail),
        error.AddressFamilyNotSupported => @intFromEnum(SocketError.afnosupport),
        error.WouldBlock => @intFromEnum(SocketError.wouldblock),
        error.ConnectionAborted => @intFromEnum(SocketError.connaborted),
        error.ConnectionRefused => @intFromEnum(SocketError.connrefused),
        error.ConnectionResetByPeer => @intFromEnum(SocketError.connreset),
        error.HostUnreachable => @intFromEnum(SocketError.hostunreach),
        error.NetworkUnreachable => @intFromEnum(SocketError.netunreach),
        error.NotConnected => @intFromEnum(SocketError.notconn),
        error.ConnectionTimedOut => @intFromEnum(SocketError.timedout),
        else => @intFromEnum(SocketError.inval),
    };
}

/// WASI sock_open: Create a new socket
pub fn sockOpen(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const fd_ptr = vm.popOperand(u32);
    const socktype_raw = vm.popOperand(i32);
    const af_raw = vm.popOperand(i32);

    const table = global_socket_table orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    };

    const af: AddressFamily = switch (af_raw) {
        2 => .inet,
        10 => .inet6,
        else => {
            try vm.pushOperand(u32, @intFromEnum(SocketError.afnosupport));
            return;
        },
    };

    const socktype: SocketType = switch (socktype_raw) {
        1 => .stream,
        2 => .dgram,
        else => {
            try vm.pushOperand(u32, @intFromEnum(SocketError.prototype));
            return;
        },
    };

    const handle = table.create(socktype, af) catch |err| {
        try vm.pushOperand(u32, toSocketError(err));
        return;
    };

    // Write socket handle to WASM memory
    const mem = try vm.inst.getMemory(0);
    try mem.write(u32, 0, fd_ptr, handle);

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_connect: Connect a socket to a remote address
pub fn sockConnect(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const addr_ptr = vm.popOperand(u32);
    const sock_fd = vm.popOperand(u32);

    const table = global_socket_table orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    };

    const socket = table.get(sock_fd) orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.badf));
        return;
    };

    // Read address from WASM memory
    const mem = try vm.inst.getMemory(0);

    const family_byte = try mem.read(u8, 0, addr_ptr);
    const family: AddressFamily = switch (family_byte) {
        2 => .inet,
        10 => .inet6,
        else => {
            try vm.pushOperand(u32, @intFromEnum(SocketError.afnosupport));
            return;
        },
    };

    const port = try mem.read(u16, 0, addr_ptr + 1);

    const sock_addr = switch (family) {
        .inet => blk: {
            var ipv4: [4]u8 = undefined;
            for (0..4) |i| {
                ipv4[i] = try mem.read(u8, 0, addr_ptr + 3 + @as(u32, @intCast(i)));
            }
            break :blk SocketAddress{
                .family = .inet,
                .port = std.mem.bigToNative(u16, port),
                .addr = .{ .ipv4 = ipv4 },
            };
        },
        .inet6 => blk: {
            var ipv6: [16]u8 = undefined;
            for (0..16) |i| {
                ipv6[i] = try mem.read(u8, 0, addr_ptr + 3 + @as(u32, @intCast(i)));
            }
            break :blk SocketAddress{
                .family = .inet6,
                .port = std.mem.bigToNative(u16, port),
                .addr = .{ .ipv6 = ipv6 },
            };
        },
    };

    const std_addr = sock_addr.toStdAddress();
    socket_mod.connect(socket, std_addr) catch |err| {
        try vm.pushOperand(u32, toSocketError(err));
        return;
    };

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_send: Send data on a connected socket
pub fn sockSend(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const sent_ptr = vm.popOperand(u32);
    const buf_len = vm.popOperand(u32);
    const buf_ptr = vm.popOperand(u32);
    const sock_fd = vm.popOperand(u32);

    const table = global_socket_table orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    };

    const socket = table.get(sock_fd) orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.badf));
        return;
    };

    const mem = try vm.inst.getMemory(0);
    const memory_slice = mem.memory();

    if (buf_ptr + buf_len > memory_slice.len) {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    }

    const data = memory_slice[buf_ptr .. buf_ptr + buf_len];

    const sent = socket_mod.send(socket, data) catch |err| {
        try vm.pushOperand(u32, toSocketError(err));
        return;
    };

    // Write bytes sent to WASM memory
    try mem.write(u32, 0, sent_ptr, @intCast(sent));

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_recv: Receive data from a connected socket
pub fn sockRecv(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const recvd_ptr = vm.popOperand(u32);
    const buf_len = vm.popOperand(u32);
    const buf_ptr = vm.popOperand(u32);
    const sock_fd = vm.popOperand(u32);

    const table = global_socket_table orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    };

    const socket = table.get(sock_fd) orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.badf));
        return;
    };

    const mem = try vm.inst.getMemory(0);
    const memory_slice = mem.memory();

    if (buf_ptr + buf_len > memory_slice.len) {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    }

    const buffer = memory_slice[buf_ptr .. buf_ptr + buf_len];

    const recvd = socket_mod.recv(socket, buffer) catch |err| {
        try vm.pushOperand(u32, toSocketError(err));
        return;
    };

    // Write bytes received to WASM memory
    try mem.write(u32, 0, recvd_ptr, @intCast(recvd));

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_close: Close a socket
pub fn sockClose(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const sock_fd = vm.popOperand(u32);

    const table = global_socket_table orelse {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    };

    table.remove(sock_fd);

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_resolve: Resolve a hostname to IP addresses
pub fn sockResolve(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const count_ptr = vm.popOperand(u32);
    const addrs_len = vm.popOperand(u32);
    const addrs_ptr = vm.popOperand(u32);
    const port = vm.popOperand(u32);
    const hostname_len = vm.popOperand(u32);
    const hostname_ptr = vm.popOperand(u32);

    const mem = try vm.inst.getMemory(0);
    const memory_slice = mem.memory();

    if (hostname_ptr + hostname_len > memory_slice.len) {
        try vm.pushOperand(u32, @intFromEnum(SocketError.inval));
        return;
    }

    const hostname = memory_slice[hostname_ptr .. hostname_ptr + hostname_len];

    const port_u16: u16 = @intCast(port);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const result = socket_mod.resolveHost(allocator, hostname, port_u16) catch |err| {
        try vm.pushOperand(u32, toSocketError(err));
        return;
    };
    defer result.deinit();

    const count = @min(result.addresses.len, addrs_len);

    // Write addresses to WASM memory
    // Each address: family (1 byte) + port (2 bytes) + addr (16 bytes max) = 19 bytes
    for (result.addresses[0..count], 0..) |addr, i| {
        const offset = addrs_ptr + (@as(u32, @intCast(i)) * 19);
        const sock_addr = SocketAddress.fromStdAddress(addr);

        try mem.write(u8, 0, offset, @intFromEnum(sock_addr.family));
        try mem.write(u16, 0, offset + 1, std.mem.nativeToBig(u16, sock_addr.port));

        switch (sock_addr.family) {
            .inet => {
                for (sock_addr.addr.ipv4, 0..) |byte, j| {
                    try mem.write(u8, 0, offset + 3 + @as(u32, @intCast(j)), byte);
                }
                // Zero out remaining bytes
                for (7..19) |j| {
                    try mem.write(u8, 0, offset + @as(u32, @intCast(j)), 0);
                }
            },
            .inet6 => {
                for (sock_addr.addr.ipv6, 0..) |byte, j| {
                    try mem.write(u8, 0, offset + 3 + @as(u32, @intCast(j)), byte);
                }
            },
        }
    }

    // Write count to WASM memory
    try mem.write(u32, 0, count_ptr, @intCast(count));

    try vm.pushOperand(u32, 0); // Success
}

/// WASI sock_accept: Accept a connection on a socket (stub)
pub fn sockAccept(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const fd_ptr = vm.popOperand(u32);
    const addr_ptr = vm.popOperand(u32);
    const sock_fd = vm.popOperand(u32);

    _ = fd_ptr;
    _ = addr_ptr;
    _ = sock_fd;

    // Not implemented - return EOPNOTSUPP
    try vm.pushOperand(u32, @intFromEnum(SocketError.opnotsupp));
}

/// WASI sock_shutdown: Shutdown socket send and/or receive (stub)
pub fn sockShutdown(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const how = vm.popOperand(u32);
    const sock_fd = vm.popOperand(u32);

    _ = how;
    _ = sock_fd;

    // Not implemented - return EOPNOTSUPP
    try vm.pushOperand(u32, @intFromEnum(SocketError.opnotsupp));
}

/// Register all socket WASI functions
pub fn registerSocketFunctions(store: *zware.Store) !void {
    const i32_result = &[_]zware.ValType{.I32};

    // sock_open(af: i32, socktype: i32, fd_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_open",
        sockOpen,
        0,
        &.{ .I32, .I32, .I32 },
        i32_result,
    );

    // sock_connect(sock_fd: i32, addr_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_connect",
        sockConnect,
        0,
        &.{ .I32, .I32 },
        i32_result,
    );

    // sock_send(sock_fd: i32, buf_ptr: i32, buf_len: i32, sent_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_send",
        sockSend,
        0,
        &.{ .I32, .I32, .I32, .I32 },
        i32_result,
    );

    // sock_recv(sock_fd: i32, buf_ptr: i32, buf_len: i32, recvd_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_recv",
        sockRecv,
        0,
        &.{ .I32, .I32, .I32, .I32 },
        i32_result,
    );

    // sock_close(sock_fd: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_close",
        sockClose,
        0,
        &.{.I32},
        i32_result,
    );

    // sock_resolve(hostname_ptr: i32, hostname_len: i32, port: i32, addrs_ptr: i32, addrs_len: i32, count_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_resolve",
        sockResolve,
        0,
        &.{ .I32, .I32, .I32, .I32, .I32, .I32 },
        i32_result,
    );

    // sock_accept(sock_fd: i32, addr_ptr: i32, fd_ptr: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_accept",
        sockAccept,
        0,
        &.{ .I32, .I32, .I32 },
        i32_result,
    );

    // sock_shutdown(sock_fd: i32, how: i32) -> i32
    try store.exposeHostFunction(
        "wasi_snapshot_preview1",
        "sock_shutdown",
        sockShutdown,
        0,
        &.{ .I32, .I32 },
        i32_result,
    );
}
