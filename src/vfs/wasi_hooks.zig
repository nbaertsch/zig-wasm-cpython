// WASI VFS Hooks
//
// This module provides WASI function implementations that use the VFS
// instead of (or in addition to) the real filesystem. These can be used
// to intercept WASI calls and route them through the in-memory VFS.
//
// Usage:
//   const vfs = try VirtualFileSystem.init(allocator);
//   const hooks = WasiVfsHooks.init(vfs);
//
//   // Register hooks with zware store
//   try hooks.registerAll(store);

const std = @import("std");
const Allocator = std.mem.Allocator;
const wasi = std.os.wasi;

const vfs_mod = @import("vfs.zig");
const VirtualFileSystem = @import("filesystem.zig").VirtualFileSystem;
const FileDescriptor = @import("fd_table.zig").FileDescriptor;
const MemoryFile = @import("memory_file.zig").MemoryFile;

const OpenFlags = vfs_mod.OpenFlags;
const SeekWhence = vfs_mod.SeekWhence;
const VfsError = vfs_mod.VfsError;
const toWasiErrno = vfs_mod.toWasiErrno;

/// WASI hooks backed by VFS
/// This can be used to replace zware's WASI implementations
pub const WasiVfsHooks = struct {
    vfs: *VirtualFileSystem,
    debug: bool,

    pub fn init(vfs_instance: *VirtualFileSystem) WasiVfsHooks {
        return .{
            .vfs = vfs_instance,
            .debug = false,
        };
    }

    pub fn setDebug(self: *WasiVfsHooks, enabled: bool) void {
        self.debug = enabled;
    }

    fn debugLog(self: *const WasiVfsHooks, comptime fmt: []const u8, args: anytype) void {
        if (self.debug) {
            std.debug.print("[WASI-VFS] " ++ fmt ++ "\n", args);
        }
    }

    // ========================================================================
    // Preopen Functions
    // ========================================================================

    /// fd_prestat_get - Get preopen information
    /// Returns: 0 on success, BADF if fd is not a preopen
    pub fn fd_prestat_get(self: *const WasiVfsHooks, fd: i32) WasiResult(Prestat) {
        self.debugLog("fd_prestat_get(fd={})", .{fd});

        if (self.vfs.getPreopen(fd)) |preopen| {
            return .{
                .result = .{
                    .pr_type = 0, // __WASI_PREOPENTYPE_DIR
                    .pr_name_len = @intCast(preopen.guest_path.len),
                },
            };
        }
        return .{ .err = .BADF };
    }

    /// fd_prestat_dir_name - Get preopen directory name
    pub fn fd_prestat_dir_name(self: *const WasiVfsHooks, fd: i32, buf: []u8) WasiResult(void) {
        self.debugLog("fd_prestat_dir_name(fd={}, buf_len={})", .{ fd, buf.len });

        if (self.vfs.getPreopen(fd)) |preopen| {
            const len = @min(buf.len, preopen.guest_path.len);
            @memcpy(buf[0..len], preopen.guest_path[0..len]);
            return .{ .result = {} };
        }
        return .{ .err = .BADF };
    }

    // ========================================================================
    // File Descriptor Functions
    // ========================================================================

    /// fd_close - Close a file descriptor
    pub fn fd_close(self: *WasiVfsHooks, fd: i32) WasiResult(void) {
        self.debugLog("fd_close(fd={})", .{fd});

        self.vfs.close(fd) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };
        return .{ .result = {} };
    }

    /// fd_read - Read from a file descriptor
    pub fn fd_read(self: *WasiVfsHooks, fd: i32, iovs: []Iovec) WasiResult(usize) {
        var total_read: usize = 0;

        for (iovs) |iov| {
            const n = self.vfs.read(fd, iov.buf[0..iov.buf_len]) catch |err| {
                if (total_read > 0) {
                    return .{ .result = total_read };
                }
                return .{ .err = toWasiErrno(err) };
            };
            total_read += n;
            if (n < iov.buf_len) break; // Short read
        }

        self.debugLog("fd_read(fd={}) -> {} bytes", .{ fd, total_read });
        return .{ .result = total_read };
    }

    /// fd_write - Write to a file descriptor
    pub fn fd_write(self: *WasiVfsHooks, fd: i32, iovs: []const Ciovec) WasiResult(usize) {
        var total_written: usize = 0;

        for (iovs) |iov| {
            const n = self.vfs.write(fd, iov.buf[0..iov.buf_len]) catch |err| {
                if (total_written > 0) {
                    return .{ .result = total_written };
                }
                return .{ .err = toWasiErrno(err) };
            };
            total_written += n;
            if (n < iov.buf_len) break; // Short write
        }

        self.debugLog("fd_write(fd={}) -> {} bytes", .{ fd, total_written });
        return .{ .result = total_written };
    }

    /// fd_seek - Seek within a file
    pub fn fd_seek(self: *WasiVfsHooks, fd: i32, offset: i64, whence: wasi.whence_t) WasiResult(u64) {
        self.debugLog("fd_seek(fd={}, offset={}, whence={})", .{ fd, offset, @intFromEnum(whence) });

        const vfs_whence = SeekWhence.fromWasi(whence);
        const new_pos = self.vfs.seek(fd, offset, vfs_whence) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };
        return .{ .result = new_pos };
    }

    /// fd_tell - Get current file position
    pub fn fd_tell(self: *WasiVfsHooks, fd: i32) WasiResult(u64) {
        self.debugLog("fd_tell(fd={})", .{fd});

        const pos = self.vfs.tell(fd) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };
        return .{ .result = pos };
    }

    /// fd_fdstat_get - Get file descriptor status
    pub fn fd_fdstat_get(self: *WasiVfsHooks, fd: i32) WasiResult(Fdstat) {
        self.debugLog("fd_fdstat_get(fd={})", .{fd});

        const fd_info = self.vfs.fd_table.get(fd) orelse return .{ .err = .BADF };
        _ = fd_info; // TODO: use for flags

        const file_stat = self.vfs.fstat(fd) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };

        return .{
            .result = .{
                .fs_filetype = file_stat.filetype.toWasi(),
                .fs_flags = 0, // TODO: populate from fd_info.flags
                .fs_rights_base = std.math.maxInt(u64),
                .fs_rights_inheriting = std.math.maxInt(u64),
            },
        };
    }

    /// fd_filestat_get - Get file statistics
    pub fn fd_filestat_get(self: *WasiVfsHooks, fd: i32) WasiResult(Filestat) {
        self.debugLog("fd_filestat_get(fd={})", .{fd});

        const file_stat = self.vfs.fstat(fd) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };

        return .{
            .result = .{
                .dev = file_stat.dev,
                .ino = file_stat.ino,
                .filetype = file_stat.filetype.toWasi(),
                .nlink = file_stat.nlink,
                .size = file_stat.size,
                .atim = file_stat.atim,
                .mtim = file_stat.mtim,
                .ctim = file_stat.ctim,
            },
        };
    }

    /// fd_readdir - Read directory entries
    pub fn fd_readdir(self: *WasiVfsHooks, fd: i32, buf: []u8, cookie: u64) WasiResult(usize) {
        self.debugLog("fd_readdir(fd={}, buf_len={}, cookie={})", .{ fd, buf.len, cookie });

        const entries = self.vfs.readdir(fd) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };
        defer self.vfs.freeReaddir(entries);

        var buf_used: usize = 0;
        var entry_idx: u64 = 0;

        for (entries) |entry| {
            if (entry_idx < cookie) {
                entry_idx += 1;
                continue;
            }

            // WASI dirent structure (24 bytes header):
            // d_next: u64 (8 bytes)
            // d_ino: u64 (8 bytes)
            // d_namlen: u32 (4 bytes)
            // d_type: u8 (1 byte)
            // padding: [3]u8 (3 bytes for 8-byte alignment)
            // name: [d_namlen]u8
            const dirent_size = 24; // 8 + 8 + 4 + 1 + 3 padding
            const total_size = dirent_size + entry.name.len;

            if (buf_used + total_size > buf.len) {
                break; // Buffer full
            }

            // Write dirent header
            const next_cookie = entry_idx + 1;
            std.mem.writeInt(u64, buf[buf_used..][0..8], next_cookie, .little);
            buf_used += 8;

            std.mem.writeInt(u64, buf[buf_used..][0..8], entry.inode, .little);
            buf_used += 8;

            std.mem.writeInt(u32, buf[buf_used..][0..4], @intCast(entry.name.len), .little);
            buf_used += 4;

            buf[buf_used] = @intFromEnum(entry.filetype.toWasi());
            buf_used += 1;

            // Padding for 8-byte alignment
            buf[buf_used] = 0;
            buf[buf_used + 1] = 0;
            buf[buf_used + 2] = 0;
            buf_used += 3;

            // Write name
            @memcpy(buf[buf_used..][0..entry.name.len], entry.name);
            buf_used += entry.name.len;

            entry_idx += 1;
        }

        return .{ .result = buf_used };
    }

    // ========================================================================
    // Path Functions
    // ========================================================================

    /// path_open - Open a file or directory
    pub fn path_open(
        self: *WasiVfsHooks,
        dir_fd: i32,
        dirflags: u32,
        path: []const u8,
        oflags: wasi.oflags_t,
        fs_rights_base: wasi.rights_t,
        fs_rights_inheriting: wasi.rights_t,
        fdflags: wasi.fdflags_t,
    ) WasiResult(i32) {
        _ = dirflags;
        _ = fs_rights_inheriting;
        _ = fdflags;

        self.debugLog("path_open(dir_fd={}, path=\"{s}\")", .{ dir_fd, path });

        const flags = OpenFlags.fromWasi(oflags, fs_rights_base);
        const new_fd = self.vfs.open(dir_fd, path, flags) catch |err| {
            self.debugLog("path_open failed: {}", .{err});
            return .{ .err = toWasiErrno(err) };
        };

        self.debugLog("path_open -> fd={}", .{new_fd});
        return .{ .result = new_fd };
    }

    /// path_filestat_get - Get file statistics by path
    pub fn path_filestat_get(self: *WasiVfsHooks, dir_fd: i32, flags: u32, path: []const u8) WasiResult(Filestat) {
        _ = flags;
        self.debugLog("path_filestat_get(dir_fd={}, path=\"{s}\")", .{ dir_fd, path });

        const file_stat = self.vfs.stat(dir_fd, path) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };

        return .{
            .result = .{
                .dev = file_stat.dev,
                .ino = file_stat.ino,
                .filetype = file_stat.filetype.toWasi(),
                .nlink = file_stat.nlink,
                .size = file_stat.size,
                .atim = file_stat.atim,
                .mtim = file_stat.mtim,
                .ctim = file_stat.ctim,
            },
        };
    }

    /// path_create_directory - Create a directory
    pub fn path_create_directory(self: *WasiVfsHooks, dir_fd: i32, path: []const u8) WasiResult(void) {
        self.debugLog("path_create_directory(dir_fd={}, path=\"{s}\")", .{ dir_fd, path });

        self.vfs.mkdir(dir_fd, path) catch |err| {
            return .{ .err = toWasiErrno(err) };
        };
        return .{ .result = {} };
    }
};

// ============================================================================
// WASI Types
// ============================================================================

/// Result type for WASI functions
pub fn WasiResult(comptime T: type) type {
    return union(enum) {
        result: T,
        err: wasi.errno_t,

        pub fn isSuccess(self: @This()) bool {
            return self == .result;
        }

        pub fn unwrap(self: @This()) T {
            return self.result;
        }

        pub fn errno(self: @This()) wasi.errno_t {
            return switch (self) {
                .result => .SUCCESS,
                .err => |e| e,
            };
        }
    };
}

/// WASI prestat structure
pub const Prestat = extern struct {
    pr_type: u8,
    pr_name_len: u32,
};

/// WASI fdstat structure
pub const Fdstat = extern struct {
    fs_filetype: wasi.filetype_t,
    fs_flags: u16,
    fs_rights_base: u64,
    fs_rights_inheriting: u64,
};

/// WASI filestat structure
pub const Filestat = extern struct {
    dev: u64,
    ino: u64,
    filetype: wasi.filetype_t,
    nlink: u64,
    size: u64,
    atim: u64,
    mtim: u64,
    ctim: u64,
};

/// WASI iovec for scatter/gather read
pub const Iovec = struct {
    buf: [*]u8,
    buf_len: usize,
};

/// WASI ciovec for scatter/gather write
pub const Ciovec = struct {
    buf: [*]const u8,
    buf_len: usize,
};

// ============================================================================
// Tests
// ============================================================================

test "wasi hooks prestat" {
    const allocator = std.testing.allocator;

    var vfs_instance = try VirtualFileSystem.init(allocator);
    defer vfs_instance.deinit();

    _ = try vfs_instance.addPreopen("/test");

    var hooks = WasiVfsHooks.init(vfs_instance);

    // Check prestat for fd 3 (first preopen)
    const result = hooks.fd_prestat_get(3);
    try std.testing.expect(result.isSuccess());
    try std.testing.expectEqual(@as(u8, 0), result.unwrap().pr_type);
    try std.testing.expectEqual(@as(u32, 5), result.unwrap().pr_name_len); // "/test"
}

test "wasi hooks file operations" {
    const allocator = std.testing.allocator;

    var vfs_instance = try VirtualFileSystem.init(allocator);
    defer vfs_instance.deinit();

    const preopen_fd = try vfs_instance.addPreopen("/app");
    try vfs_instance.createFile("/app/hello.txt", "Hello from VFS!");

    var hooks = WasiVfsHooks.init(vfs_instance);

    // Open the file
    const open_result = hooks.path_open(
        preopen_fd,
        0,
        "hello.txt",
        .{},
        .{ .FD_READ = true },
        .{},
        .{},
    );
    try std.testing.expect(open_result.isSuccess());

    const fd = open_result.unwrap();

    // Read from it
    var buf: [32]u8 = undefined;
    var iov = [_]Iovec{.{ .buf = &buf, .buf_len = buf.len }};
    const read_result = hooks.fd_read(fd, &iov);
    try std.testing.expect(read_result.isSuccess());

    const n = read_result.unwrap();
    try std.testing.expectEqualSlices(u8, "Hello from VFS!", buf[0..n]);
}
