// WASI Function Handlers
//
// This module contains all WASI function implementations that route between
// VFS-backed operations and zware's native implementations.
//
// The handlers check if a file descriptor or path belongs to VFS and route
// accordingly, providing transparent integration between in-memory and real
// filesystem operations.

const std = @import("std");
const zware = @import("zware");
const hooks = @import("hooks.zig");
const vfs_mod = @import("../vfs/vfs.zig");
const VirtualFileSystem = vfs_mod.VirtualFileSystem;
const WasiVfsHooks = vfs_mod.WasiVfsHooks;
const VFS_PREFIX = @import("../vfs/filesystem.zig").VFS_PREFIX;

const WasiHook = hooks.WasiHook;
const makeStub = hooks.makeStub;
const makeZwarePassthrough = hooks.makeZwarePassthrough;
const debug_print = hooks.debug_print;

// Global VFS instance for WASI hooks
// This is necessary because zware's exposeHostFunction doesn't support user data
var global_vfs: ?*VirtualFileSystem = null;
var global_vfs_hooks: ?*WasiVfsHooks = null;

/// Set the global VFS instance used by all WASI handlers
pub fn setVfs(vfs: *VirtualFileSystem, vfs_hooks: *WasiVfsHooks) void {
    global_vfs = vfs;
    global_vfs_hooks = vfs_hooks;
}

/// Clear the global VFS instance
pub fn clearVfs() void {
    global_vfs = null;
    global_vfs_hooks = null;
}

/// Register all WASI handlers with the zware store
pub fn addWasiImports(store: *zware.Store) !void {
    const wasi = zware.wasi;
    const empty_params = &[_]zware.ValType{};
    const i32_result = &[_]zware.ValType{.I32};

    // Add all WASI preview1 functions that are implemented in zware
    try store.exposeHostFunction("wasi_snapshot_preview1", "args_get", makeZwarePassthrough("args_get", wasi.args_get), 0, &.{ .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "args_sizes_get", makeZwarePassthrough("args_sizes_get", wasi.args_sizes_get), 0, &.{ .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "environ_get", makeZwarePassthrough("environ_get", wasi.environ_get), 0, &.{ .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "environ_sizes_get", makeZwarePassthrough("environ_sizes_get", wasi.environ_sizes_get), 0, &.{ .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "clock_res_get", makeStub("clock_res_get"), 0, &.{ .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "clock_time_get", makeZwarePassthrough("clock_time_get", wasi.clock_time_get), 0, &.{ .I32, .I64, .I32 }, i32_result);

    // Add stubs for fd_* functions not implemented
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_advise", makeStub("fd_advise"), 0, &.{ .I32, .I64, .I64, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_allocate", makeStub("fd_allocate"), 0, &.{ .I32, .I64, .I64 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_datasync", makeStub("fd_datasync"), 0, &.{.I32}, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_filestat_set_size", makeStub("fd_filestat_set_size"), 0, &.{ .I32, .I64 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_filestat_set_times", makeStub("fd_filestat_set_times"), 0, &.{ .I32, .I64, .I64, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_pread", makeStub("fd_pread"), 0, &.{ .I32, .I32, .I32, .I64, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_pwrite", makeStub("fd_pwrite"), 0, &.{ .I32, .I32, .I32, .I64, .I32 }, i32_result);

    // fd_readdir - read directory entries (uses zware's cross-platform implementation)
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_readdir", fdReaddirHandler, 0, &.{ .I32, .I32, .I32, .I64, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_sync", makeStub("fd_sync"), 0, &.{.I32}, i32_result);

    // fd_tell - get current file offset (uses zware's cross-platform implementation)
    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_tell", fdTellHandler, 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_close", fdCloseHandler, 0, &.{.I32}, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_fdstat_get", fdFdstatGetHandler, 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_fdstat_set_flags", makeZwarePassthrough("fd_fdstat_set_flags", zware.wasi.fd_fdstat_set_flags), 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_filestat_get", fdFilestatGetHandler, 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_prestat_get", fdPrestatGetHandler, 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_prestat_dir_name", fdPrestatDirNameHandler, 0, &.{ .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_read", fdReadHandler, 0, &.{ .I32, .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_seek", fdSeekHandler, 0, &.{ .I32, .I64, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "fd_write", fdWriteHandler, 0, &.{ .I32, .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "path_create_directory", pathCreateDirectoryHandler, 0, &.{ .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "path_filestat_get", pathFilestatGetHandler, 0, &.{ .I32, .I32, .I32, .I32, .I32 }, i32_result);

    // Add stubs for path_* functions not implemented
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_filestat_set_times", makeStub("path_filestat_set_times"), 0, &.{ .I32, .I32, .I32, .I32, .I64, .I64, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_link", makeStub("path_link"), 0, &.{ .I32, .I32, .I32, .I32, .I32, .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_readlink", pathReadlinkHandler, 0, &.{ .I32, .I32, .I32, .I32, .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_remove_directory", makeStub("path_remove_directory"), 0, &.{ .I32, .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_rename", makeStub("path_rename"), 0, &.{ .I32, .I32, .I32, .I32, .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_symlink", makeStub("path_symlink"), 0, &.{ .I32, .I32, .I32, .I32, .I32 }, i32_result);
    try store.exposeHostFunction("wasi_snapshot_preview1", "path_unlink_file", makeStub("path_unlink_file"), 0, &.{ .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "path_open", pathOpenHandler, 0, &.{ .I32, .I32, .I32, .I32, .I32, .I64, .I64, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "poll_oneoff", makeZwarePassthrough("poll_oneoff", zware.wasi.poll_oneoff), 0, &.{ .I32, .I32, .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "proc_exit", makeZwarePassthrough("proc_exit", zware.wasi.proc_exit), 0, &.{.I32}, empty_params);

    try store.exposeHostFunction("wasi_snapshot_preview1", "random_get", makeZwarePassthrough("random_get", zware.wasi.random_get), 0, &.{ .I32, .I32 }, i32_result);

    try store.exposeHostFunction("wasi_snapshot_preview1", "sched_yield", makeStub("sched_yield"), 0, empty_params, i32_result);

    // NOTE: Socket functions (sock_open, sock_connect, sock_send, sock_recv, sock_close, sock_resolve)
    // are registered by socket_handlers.zig with custom implementations.
    // Do NOT add stub implementations here as they will conflict.
}

// ============================================================================
// Individual Handler Implementations
// ============================================================================

fn fdReaddirHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const bufused_ptr = vm.popOperand(u32);
    const cookie = vm.popOperand(u64);
    const buf_len = vm.popOperand(u32);
    const buf_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(u32);
    debug_print("[WASI] fd_readdir(fd={}, buf_len={}, cookie={})\n", .{ fd, buf_len, cookie });

    // Check if this is a VFS fd (using backend tracking instead of magic numbers)
    if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
        const mem = try vm.inst.getMemory(0);
        const mem_data = mem.memory();
        const buf = mem_data[buf_ptr..][0..buf_len];

        const entries = global_vfs.?.readdir(@intCast(fd)) catch |err| {
            const errno = vfs_mod.toWasiErrno(err);
            debug_print("[WASI-VFS] fd_readdir -> errno={}\n", .{@intFromEnum(errno)});
            try vm.pushOperand(u32, @intFromEnum(errno));
            return;
        };
        defer global_vfs.?.freeReaddir(entries);

        // If cookie is past all entries, return 0 bytes to signal EOF
        if (cookie >= entries.len) {
            try mem.write(u32, 0, bufused_ptr, 0);
            debug_print("[WASI-VFS] fd_readdir -> 0 bytes (EOF, cookie={} >= entries={})\n", .{ cookie, entries.len });
            try vm.pushOperand(u32, 0); // SUCCESS
            return;
        }

        var buf_used: usize = 0;
        var entry_idx: u64 = 0;
        var entries_written: u64 = 0;

        for (entries) |entry| {
            if (entry_idx < cookie) {
                entry_idx += 1;
                continue;
            }

            // WASI dirent structure is 24 bytes due to alignment padding:
            // d_next(8) + d_ino(8) + d_namlen(4) + d_type(1) + padding(3) = 24
            const dirent_size = 24;
            const total_size = dirent_size + entry.name.len;

            if (buf_used + total_size > buf.len) break;

            const next_cookie = entry_idx + 1;
            std.mem.writeInt(u64, buf[buf_used..][0..8], next_cookie, .little);
            buf_used += 8;

            std.mem.writeInt(u64, buf[buf_used..][0..8], entry.inode, .little);
            buf_used += 8;

            std.mem.writeInt(u32, buf[buf_used..][0..4], @intCast(entry.name.len), .little);
            buf_used += 4;

            buf[buf_used] = @intFromEnum(entry.filetype.toWasi());
            buf_used += 1;

            // 3 bytes padding for struct alignment
            buf[buf_used] = 0;
            buf[buf_used + 1] = 0;
            buf[buf_used + 2] = 0;
            buf_used += 3;

            @memcpy(buf[buf_used..][0..entry.name.len], entry.name);
            buf_used += entry.name.len;

            entry_idx += 1;
            entries_written += 1;
        }

        // Check if there are more entries that didn't fit
        const last_cookie = cookie + entries_written;
        const has_more_entries = last_cookie < entries.len;

        // WASI spec: bufused < buf_len signals EOF.
        // If there are more entries, we MUST return buf_len to signal "continue reading".
        // Zero-fill any remaining buffer space to avoid garbage data.
        if (has_more_entries and buf_used < buf.len) {
            @memset(buf[buf_used..], 0);
        }

        const final_buf_used: usize = if (has_more_entries) buf.len else buf_used;
        try mem.write(u32, 0, bufused_ptr, @intCast(final_buf_used));
        debug_print("[WASI-VFS] fd_readdir -> {} bytes ({} entries, cookie {} -> {}, total={}, has_more={})\n", .{ final_buf_used, entries_written, cookie, last_cookie, entries.len, has_more_entries });
        try vm.pushOperand(u32, 0); // SUCCESS
        return;
    }

    // Fall through to zware
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, buf_ptr);
    try vm.pushOperand(u32, buf_len);
    try vm.pushOperand(u64, cookie);
    try vm.pushOperand(u32, bufused_ptr);
    try zware.wasi.fd_readdir(vm);
}

fn fdTellHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_tell", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const offset_ptr = vm_inner.popOperand(u32);
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={})", .{fd});

            // Check if this is a VFS fd (using backend tracking instead of magic numbers)
            if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
                const mem = try vm_inner.inst.getMemory(0);
                const pos = global_vfs.?.tell(@intCast(fd)) catch |err| {
                    const errno = vfs_mod.toWasiErrno(err);
                    debug_print(" [VFS errno={}]", .{@intFromEnum(errno)});
                    try vm_inner.pushOperand(u32, @intFromEnum(errno));
                    return;
                };

                try mem.write(u64, 0, offset_ptr, pos);
                debug_print(" [VFS pos={}]", .{pos});
                try vm_inner.pushOperand(u32, 0); // SUCCESS
                return;
            }

            // Fall through to zware
            try vm_inner.pushOperand(u32, fd);
            try vm_inner.pushOperand(u32, offset_ptr);
            try zware.wasi.fd_tell(vm_inner);
        }
    }).wrapper(vm, 0);
}

fn fdCloseHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_close", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={})", .{fd});

            // Check if this is a VFS fd (using backend tracking instead of magic numbers)
            if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
                global_vfs.?.close(@intCast(fd)) catch |err| {
                    const errno = vfs_mod.toWasiErrno(err);
                    debug_print(" [VFS errno={}]", .{@intFromEnum(errno)});
                    try vm_inner.pushOperand(u32, @intFromEnum(errno));
                    return;
                };
                debug_print(" [VFS]", .{});
                try vm_inner.pushOperand(u32, 0); // SUCCESS
                return;
            }

            try vm_inner.pushOperand(u32, fd);
            try zware.wasi.fd_close(vm_inner);
        }
    }).wrapper(vm, 0);
}

fn fdFdstatGetHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_fdstat_get", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const fdstat_ptr = vm_inner.popOperand(u32);
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={})", .{fd});

            // Check if this is a VFS fd (using backend tracking instead of magic numbers)
            if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
                const mem = try vm_inner.inst.getMemory(0);
                const stat_result = global_vfs.?.fstat(@intCast(fd)) catch |err| {
                    const errno = vfs_mod.toWasiErrno(err);
                    debug_print(" [VFS errno={}]", .{@intFromEnum(errno)});
                    try vm_inner.pushOperand(u32, @intFromEnum(errno));
                    return;
                };

                // Write fdstat structure (24 bytes):
                // fs_filetype: u8
                // fs_flags: u16 (offset 2)
                // fs_rights_base: u64 (offset 8)
                // fs_rights_inheriting: u64 (offset 16)
                try mem.write(u8, 0, fdstat_ptr, @intFromEnum(stat_result.filetype.toWasi()));
                try mem.write(u16, 0, fdstat_ptr + 2, 0); // flags
                try mem.write(u64, 0, fdstat_ptr + 8, std.math.maxInt(u64)); // rights_base
                try mem.write(u64, 0, fdstat_ptr + 16, std.math.maxInt(u64)); // rights_inheriting

                debug_print(" [VFS]", .{});
                try vm_inner.pushOperand(u32, 0); // SUCCESS
                return;
            }

            try vm_inner.pushOperand(u32, fd);
            try vm_inner.pushOperand(u32, fdstat_ptr);
            try zware.wasi.fd_fdstat_get(vm_inner);
        }
    }).wrapper(vm, 0);
}

fn fdFilestatGetHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const filestat_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(u32);
    debug_print("[WASI] fd_filestat_get(fd={})\n", .{fd});

    // Check if this is a VFS fd (using backend tracking instead of magic numbers)
    if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
        const mem = try vm.inst.getMemory(0);
        const stat_result = global_vfs.?.fstat(@intCast(fd)) catch |err| {
            const errno = vfs_mod.toWasiErrno(err);
            debug_print("[WASI-VFS] fd_filestat_get -> errno={}\n", .{@intFromEnum(errno)});
            try vm.pushOperand(u32, @intFromEnum(errno));
            return;
        };

        // Write filestat structure (64 bytes):
        // dev: u64 (offset 0)
        // ino: u64 (offset 8)
        // filetype: u8 (offset 16)
        // nlink: u64 (offset 24)
        // size: u64 (offset 32)
        // atim: u64 (offset 40)
        // mtim: u64 (offset 48)
        // ctim: u64 (offset 56)
        try mem.write(u64, 0, filestat_ptr, stat_result.dev);
        try mem.write(u64, 0, filestat_ptr + 8, stat_result.ino);
        try mem.write(u8, 0, filestat_ptr + 16, @intFromEnum(stat_result.filetype.toWasi()));
        try mem.write(u64, 0, filestat_ptr + 24, stat_result.nlink);
        try mem.write(u64, 0, filestat_ptr + 32, stat_result.size);
        try mem.write(u64, 0, filestat_ptr + 40, stat_result.atim);
        try mem.write(u64, 0, filestat_ptr + 48, stat_result.mtim);
        try mem.write(u64, 0, filestat_ptr + 56, stat_result.ctim);

        debug_print("[WASI-VFS] fd_filestat_get -> 0 (size={})\n", .{stat_result.size});
        try vm.pushOperand(u32, 0); // SUCCESS
        return;
    }

    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, filestat_ptr);
    try zware.wasi.fd_filestat_get(vm);
}

fn fdPrestatGetHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const prestat_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(u32);
    debug_print("[WASI] fd_prestat_get(fd={})\n", .{fd});

    // Check VFS preopens (using backend tracking)
    if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
        const result = global_vfs_hooks.?.fd_prestat_get(@intCast(fd));
        switch (result) {
            .result => |prestat| {
                const mem = try vm.inst.getMemory(0);
                // Write prestat: pr_type (u8) + padding (3 bytes) + pr_name_len (u32)
                try mem.write(u8, 0, prestat_ptr, prestat.pr_type);
                try mem.write(u32, 0, prestat_ptr + 4, prestat.pr_name_len);
                debug_print("[WASI-VFS] fd_prestat_get -> 0 (name_len={})\n", .{prestat.pr_name_len});
                try vm.pushOperand(u32, 0); // SUCCESS
            },
            .err => |errno| {
                debug_print("[WASI-VFS] fd_prestat_get -> {}\n", .{@intFromEnum(errno)});
                try vm.pushOperand(u32, @intFromEnum(errno));
            },
        }
        return;
    }

    // Use zware for fd < 100
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, prestat_ptr);
    try zware.wasi.fd_prestat_get(vm);
    // Check the return value
    const result = vm.popOperand(u32);
    debug_print("[WASI] fd_prestat_get -> {}\n", .{result});
    try vm.pushOperand(u32, result);
}

fn fdPrestatDirNameHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const buf_len = vm.popOperand(u32);
    const buf_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(u32);
    debug_print("[WASI] fd_prestat_dir_name(fd={}, buf_len={})\n", .{ fd, buf_len });

    // Check VFS preopens (using backend tracking)
    if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
        const mem = try vm.inst.getMemory(0);
        const mem_data = mem.memory();
        const buf = mem_data[buf_ptr..][0..buf_len];

        const result = global_vfs_hooks.?.fd_prestat_dir_name(@intCast(fd), buf);
        switch (result) {
            .result => {
                debug_print("[WASI-VFS] fd_prestat_dir_name -> 0\n", .{});
                try vm.pushOperand(u32, 0); // SUCCESS
            },
            .err => |errno| {
                debug_print("[WASI-VFS] fd_prestat_dir_name -> {}\n", .{@intFromEnum(errno)});
                try vm.pushOperand(u32, @intFromEnum(errno));
            },
        }
        return;
    }

    // Use zware for fd < 100
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, buf_ptr);
    try vm.pushOperand(u32, buf_len);
    try zware.wasi.fd_prestat_dir_name(vm);
}

fn fdReadHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_read", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const n_read_ptr = vm_inner.popOperand(u32);
            const iovs_len = vm_inner.popOperand(u32);
            const iovs_ptr = vm_inner.popOperand(u32);
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={}, iovs=0x{x}, len={})", .{ fd, iovs_ptr, iovs_len });

            // Check if this is a VFS fd (using backend tracking instead of magic numbers)
            if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
                const mem = try vm_inner.inst.getMemory(0);
                const mem_data = mem.memory();

                // Parse iovs to get buffer info and read into each
                var total_read: u32 = 0;
                var iov_idx: u32 = 0;
                while (iov_idx < iovs_len) : (iov_idx += 1) {
                    const iov_offset = iovs_ptr + iov_idx * 8;
                    const buf_ptr = try mem.read(u32, 0, iov_offset);
                    const buf_len = try mem.read(u32, 0, iov_offset + 4);

                    const buf = mem_data[buf_ptr..][0..buf_len];
                    const bytes_read = global_vfs.?.read(@intCast(fd), buf) catch |err| {
                        try mem.write(u32, 0, n_read_ptr, total_read);
                        const errno = vfs_mod.toWasiErrno(err);
                        debug_print(" [VFS errno={}]", .{@intFromEnum(errno)});
                        try vm_inner.pushOperand(u32, @intFromEnum(errno));
                        return;
                    };

                    total_read += @intCast(bytes_read);
                    if (bytes_read < buf.len) break; // Short read
                }

                try mem.write(u32, 0, n_read_ptr, total_read);
                debug_print(" [VFS {} bytes]", .{total_read});
                try vm_inner.pushOperand(u32, 0); // SUCCESS
                return;
            }

            // Fall through to zware
            try vm_inner.pushOperand(u32, fd);
            try vm_inner.pushOperand(u32, iovs_ptr);
            try vm_inner.pushOperand(u32, iovs_len);
            try vm_inner.pushOperand(u32, n_read_ptr);

            try zware.wasi.fd_read(vm_inner);

            // Read back how many bytes were read
            const mem = try vm_inner.inst.getMemory(0);
            const n_read = try mem.read(u32, 0, n_read_ptr);
            debug_print(" [zware {} bytes]", .{n_read});
        }
    }).wrapper(vm, 0);
}

fn fdSeekHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_seek", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const newoffset_ptr = vm_inner.popOperand(u32);
            const whence = vm_inner.popOperand(u32);
            const offset = vm_inner.popOperand(i64);
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={}, offset={}, whence={})", .{ fd, offset, whence });

            // Check if this is a VFS fd (using backend tracking instead of magic numbers)
            if (global_vfs != null and global_vfs.?.isVfsFd(@intCast(fd))) {
                const mem = try vm_inner.inst.getMemory(0);
                const seek_whence: vfs_mod.SeekWhence = switch (whence) {
                    0 => .set,
                    1 => .cur,
                    2 => .end,
                    else => .set,
                };

                const new_pos = global_vfs.?.seek(@intCast(fd), offset, seek_whence) catch |err| {
                    const errno = vfs_mod.toWasiErrno(err);
                    debug_print(" [VFS errno={}]", .{@intFromEnum(errno)});
                    try vm_inner.pushOperand(u32, @intFromEnum(errno));
                    return;
                };

                try mem.write(u64, 0, newoffset_ptr, new_pos);
                debug_print(" [VFS pos={}]", .{new_pos});
                try vm_inner.pushOperand(u32, 0); // SUCCESS
                return;
            }

            // Fall through to zware
            try vm_inner.pushOperand(u32, fd);
            try vm_inner.pushOperand(i64, offset);
            try vm_inner.pushOperand(u32, whence);
            try vm_inner.pushOperand(u32, newoffset_ptr);
            try zware.wasi.fd_seek(vm_inner);
        }
    }).wrapper(vm, 0);
}

fn fdWriteHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    return WasiHook("fd_write", struct {
        pub fn call(vm_inner: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            const nwritten_ptr = vm_inner.popOperand(u32);
            const iovs_len = vm_inner.popOperand(u32);
            const iovs_ptr = vm_inner.popOperand(u32);
            const fd = vm_inner.popOperand(u32);

            debug_print("(fd={}, iovs=0x{x}, len={})", .{ fd, iovs_ptr, iovs_len });

            // Push back in correct order for wasi.fd_write
            try vm_inner.pushOperand(u32, fd);
            try vm_inner.pushOperand(u32, iovs_ptr);
            try vm_inner.pushOperand(u32, iovs_len);
            try vm_inner.pushOperand(u32, nwritten_ptr);

            try zware.wasi.fd_write(vm_inner);
        }
    }).wrapper(vm, 0);
}

fn pathCreateDirectoryHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    // path_create_directory(fd, path, path_len) -> errno
    const path_len = vm.popOperand(u32);
    const path_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(u32);

    const mem = try vm.inst.getMemory(0);
    const mem_data = mem.memory();
    const path = mem_data[path_ptr..][0..path_len];

    debug_print("[WASI] path_create_directory(fd={}, path=\"{s}\")\n", .{ fd, path });

    // Route to VFS if fd is VFS-backed or path starts with VFS prefix
    if (global_vfs) |vfs| {
        const is_vfs_fd = vfs.isVfsFd(@intCast(fd));
        const is_vfs_path = VirtualFileSystem.isVfsPath(path);

        if (is_vfs_fd or is_vfs_path) {
            // Strip VFS prefix if present and use VFS root preopen
            const vfs_path = VirtualFileSystem.stripVfsPrefix(path);
            const vfs_fd: i32 = if (is_vfs_fd) @intCast(fd) else 3; // Use first VFS preopen

            debug_print("[WASI-VFS] path_create_directory routing to VFS (fd={}): \"{s}\"\n", .{ vfs_fd, vfs_path });

            vfs.mkdir(vfs_fd, vfs_path) catch |err| {
                const errno = vfs_mod.toWasiErrno(err);
                debug_print("[WASI-VFS] path_create_directory -> errno={}\n", .{@intFromEnum(errno)});
                try vm.pushOperand(u32, @intFromEnum(errno));
                return;
            };

            debug_print("[WASI-VFS] path_create_directory -> success\n", .{});
            try vm.pushOperand(u32, 0); // SUCCESS
            return;
        }
    }

    // Fall through to zware for real filesystem
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, path_ptr);
    try vm.pushOperand(u32, path_len);
    try zware.wasi.path_create_directory(vm);
}

fn pathFilestatGetHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    // path_filestat_get(fd, flags, path, path_len, buf) -> errno
    const buf_ptr = vm.popOperand(u32);
    const path_len = vm.popOperand(u32);
    const path_ptr = vm.popOperand(u32);
    const flags = vm.popOperand(u32);
    const fd = vm.popOperand(u32);

    const mem = try vm.inst.getMemory(0);
    const mem_data = mem.memory();
    const path = mem_data[path_ptr..][0..path_len];

    debug_print("[WASI] path_filestat_get(fd={}, path=\"{s}\")\n", .{ fd, path });

    // Route to VFS if fd is VFS-backed or path starts with VFS prefix
    if (global_vfs) |vfs| {
        const is_vfs_fd = vfs.isVfsFd(@intCast(fd));
        const is_vfs_path = VirtualFileSystem.isVfsPath(path);

        if (is_vfs_fd or is_vfs_path) {
            // Strip VFS prefix if present
            const vfs_path = VirtualFileSystem.stripVfsPrefix(path);
            const vfs_fd: i32 = if (is_vfs_fd) @intCast(fd) else 3;

            debug_print("[WASI-VFS] path_filestat_get routing to VFS (fd={}): \"{s}\"\n", .{ vfs_fd, vfs_path });

            const stat_result = vfs.stat(vfs_fd, vfs_path) catch |err| {
                const errno = vfs_mod.toWasiErrno(err);
                debug_print("[WASI-VFS] path_filestat_get -> errno={}\n", .{@intFromEnum(errno)});
                try vm.pushOperand(u32, @intFromEnum(errno));
                return;
            };

            // Write filestat to memory (64 bytes total)
            // WASI filestat layout:
            // dev: u64, ino: u64, filetype: u8, pad: 7 bytes, nlink: u64, size: u64, atim: u64, mtim: u64, ctim: u64
            std.mem.writeInt(u64, mem_data[buf_ptr..][0..8], stat_result.dev, .little);
            std.mem.writeInt(u64, mem_data[buf_ptr + 8 ..][0..8], stat_result.ino, .little);
            mem_data[buf_ptr + 16] = @intFromEnum(stat_result.filetype.toWasi());
            @memset(mem_data[buf_ptr + 17 ..][0..7], 0); // 7 bytes padding
            std.mem.writeInt(u64, mem_data[buf_ptr + 24 ..][0..8], stat_result.nlink, .little);
            std.mem.writeInt(u64, mem_data[buf_ptr + 32 ..][0..8], stat_result.size, .little);
            std.mem.writeInt(u64, mem_data[buf_ptr + 40 ..][0..8], stat_result.atim, .little);
            std.mem.writeInt(u64, mem_data[buf_ptr + 48 ..][0..8], stat_result.mtim, .little);
            std.mem.writeInt(u64, mem_data[buf_ptr + 56 ..][0..8], stat_result.ctim, .little);

            debug_print("[WASI-VFS] path_filestat_get -> filetype={}, size={}\n", .{ @intFromEnum(stat_result.filetype.toWasi()), stat_result.size });
            try vm.pushOperand(u32, 0); // SUCCESS
            return;
        }
    }

    // Fall through to zware for real filesystem
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, flags);
    try vm.pushOperand(u32, path_ptr);
    try vm.pushOperand(u32, path_len);
    try vm.pushOperand(u32, buf_ptr);
    try zware.wasi.path_filestat_get(vm);
}

fn pathReadlinkHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    const bufused_ptr = vm.popOperand(u32);
    const buf_len = vm.popOperand(u32);
    const buf_ptr = vm.popOperand(u32);
    const path_len = vm.popOperand(u32);
    const path_ptr = vm.popOperand(u32);
    const fd = vm.popOperand(i32);

    const mem = try vm.inst.getMemory(0);
    const data = mem.memory();
    const path = data[path_ptr..][0..path_len];

    debug_print("[WASI] path_readlink(fd={}, path=\"{s}\")\n", .{ fd, path });

    // VFS doesn't support symlinks - return EINVAL (not a symlink) or ENOENT
    if (VirtualFileSystem.isVfsPath(path)) {
        debug_print("[WASI-VFS] path_readlink -> EINVAL (VFS has no symlinks)\n", .{});
        try vm.pushOperand(u32, @intFromEnum(std.os.wasi.errno_t.INVAL));
        return;
    }

    // Fall through to zware for real filesystem
    try vm.pushOperand(i32, fd);
    try vm.pushOperand(u32, path_ptr);
    try vm.pushOperand(u32, path_len);
    try vm.pushOperand(u32, buf_ptr);
    try vm.pushOperand(u32, buf_len);
    try vm.pushOperand(u32, bufused_ptr);

    try zware.wasi.path_readlink(vm);
    const result = vm.popOperand(u32);
    debug_print("[WASI] path_readlink -> {}\n", .{result});
    try vm.pushOperand(u32, result);
}

fn pathOpenHandler(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
    // path_open(fd: fd, dirflags: lookupflags, path: string, oflags: oflags,
    //           fs_rights_base: rights, fs_rights_inheriting: rights, fdflags: fdflags, opened_fd: *fd) errno
    const opened_fd_ptr = vm.popOperand(u32);
    const fdflags = vm.popOperand(u32);
    const fs_rights_inheriting = vm.popOperand(u64);
    const fs_rights_base = vm.popOperand(u64);
    const oflags = vm.popOperand(u32);
    const path_len = vm.popOperand(u32);
    const path_ptr = vm.popOperand(u32);
    const dirflags = vm.popOperand(u32);
    const fd = vm.popOperand(u32);

    // Read the path string for debugging
    const mem = try vm.inst.getMemory(0);
    const mem_data = mem.memory();
    const path = mem_data[path_ptr..][0..path_len];
    debug_print("[WASI] path_open(fd={}, path=\"{s}\", oflags=0x{x})\n", .{ fd, path, oflags });

    // Route to VFS if fd is VFS-backed or path starts with VFS prefix
    if (global_vfs) |vfs| {
        const is_vfs_fd = vfs.isVfsFd(@intCast(fd));
        const is_vfs_path = VirtualFileSystem.isVfsPath(path);

        if (is_vfs_fd or is_vfs_path) {
            // Strip VFS prefix if present
            const vfs_path = VirtualFileSystem.stripVfsPrefix(path);
            const vfs_fd: i32 = if (is_vfs_fd) @intCast(fd) else 3;

            debug_print("[WASI-VFS] Routing to VFS (fd={}): \"{s}\"\n", .{ vfs_fd, vfs_path });

            // Convert WASI oflags to VFS OpenFlags
            const open_flags = vfs_mod.OpenFlags{
                .read = (fs_rights_base & 0x02) != 0, // FD_READ
                .write = (fs_rights_base & 0x40) != 0, // FD_WRITE
                .create = (oflags & 0x01) != 0, // CREAT
                .exclusive = (oflags & 0x04) != 0, // EXCL
                .truncate = (oflags & 0x08) != 0, // TRUNC
                .directory = (oflags & 0x02) != 0, // DIRECTORY
            };

            const new_fd = vfs.open(vfs_fd, vfs_path, open_flags) catch |err| {
                const errno = vfs_mod.toWasiErrno(err);
                debug_print("[WASI-VFS] path_open -> errno={}\n", .{@intFromEnum(errno)});
                try vm.pushOperand(u32, @intFromEnum(errno));
                return;
            };

            debug_print("[WASI-VFS] path_open -> fd={}\n", .{new_fd});
            try mem.write(u32, 0, opened_fd_ptr, @intCast(new_fd));
            try vm.pushOperand(u32, 0); // SUCCESS
            return;
        }
    }

    // Fall through to zware's implementation for non-VFS paths
    try vm.pushOperand(u32, fd);
    try vm.pushOperand(u32, dirflags);
    try vm.pushOperand(u32, path_ptr);
    try vm.pushOperand(u32, path_len);
    try vm.pushOperand(u32, oflags);
    try vm.pushOperand(u64, fs_rights_base);
    try vm.pushOperand(u64, fs_rights_inheriting);
    try vm.pushOperand(u32, fdflags);
    try vm.pushOperand(u32, opened_fd_ptr);

    try zware.wasi.path_open(vm);
    const result = vm.popOperand(u32);

    // Debug: read back the opened fd
    if (result == 0) {
        const opened_fd = try mem.read(i32, 0, opened_fd_ptr);
        debug_print("[WASI] path_open -> {} (opened_fd={})\n", .{ result, opened_fd });
    } else {
        debug_print("[WASI] path_open -> {}\n", .{result});
    }
    try vm.pushOperand(u32, result);
}
