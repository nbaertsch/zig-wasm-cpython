// Virtual File System
//
// The main VFS implementation that:
// - Manages the in-memory filesystem tree
// - Handles path resolution
// - Provides file operations (open, read, write, etc.)
// - Manages preopens and mount points
// - Optionally passes through to real filesystem

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const fs = std.fs;

const vfs = @import("vfs.zig");
const MemoryFile = @import("memory_file.zig").MemoryFile;
const MemoryDirectory = @import("memory_directory.zig").MemoryDirectory;
const Node = @import("memory_directory.zig").Node;
const FdTable = @import("fd_table.zig").FdTable;
const FileDescriptor = @import("fd_table.zig").FileDescriptor;
const PreopenInfo = @import("fd_table.zig").PreopenInfo;
const Backend = @import("fd_table.zig").Backend;

const FileType = vfs.FileType;
const FileStat = vfs.FileStat;
const OpenFlags = vfs.OpenFlags;
const SeekWhence = vfs.SeekWhence;
const DirEntry = vfs.DirEntry;
const VfsError = vfs.VfsError;

/// Mount point for real filesystem passthrough
const MountPoint = struct {
    guest_path: []const u8,
    host_path: []const u8,
    host_fd: posix.fd_t,
};

/// Magic path prefix for VFS routing
/// Paths starting with this prefix are routed to the in-memory VFS
/// All other paths go to the real filesystem via WASI
pub const VFS_PREFIX = "/vfs";

/// The main Virtual File System
pub const VirtualFileSystem = struct {
    allocator: Allocator,

    /// Root of the in-memory filesystem
    root: *MemoryDirectory,

    /// File descriptor table
    fd_table: FdTable,

    /// Next inode number to assign
    next_inode: u64,

    /// Mount points for real filesystem passthrough
    mounts: std.ArrayListUnmanaged(MountPoint),

    /// Whether to enable debug logging
    debug: bool,

    pub fn init(allocator: Allocator) !*VirtualFileSystem {
        const self = try allocator.create(VirtualFileSystem);
        errdefer allocator.destroy(self);

        self.* = .{
            .allocator = allocator,
            .root = try MemoryDirectory.init(allocator, 1, "/"),
            .fd_table = FdTable.init(allocator),
            .next_inode = 2, // 1 is reserved for root
            .mounts = .empty,
            .debug = false,
        };

        // Initialize stdio
        try self.fd_table.initStdio();

        return self;
    }

    pub fn deinit(self: *VirtualFileSystem) void {
        // Close mount points
        for (self.mounts.items) |mount| {
            self.allocator.free(mount.guest_path);
            self.allocator.free(mount.host_path);
            posix.close(mount.host_fd);
        }
        self.mounts.deinit(self.allocator);

        self.fd_table.deinit();
        self.root.deinit();
        self.allocator.destroy(self);
    }

    /// Enable or disable debug logging
    pub fn setDebug(self: *VirtualFileSystem, enabled: bool) void {
        self.debug = enabled;
    }

    fn debugLog(self: *VirtualFileSystem, comptime fmt: []const u8, args: anytype) void {
        if (self.debug) {
            std.debug.print("[VFS] " ++ fmt ++ "\n", args);
        }
    }

    /// Generate a new unique inode number
    fn nextInode(self: *VirtualFileSystem) u64 {
        const inode = self.next_inode;
        self.next_inode += 1;
        return inode;
    }

    // ========================================================================
    // Path-Based Routing
    // ========================================================================

    /// Check if a path should be routed to the VFS
    /// Handles both absolute ("/vfs/...") and relative ("vfs/...") paths
    pub fn isVfsPath(path: []const u8) bool {
        // Check for absolute path "/vfs" or "/vfs/..."
        if (std.mem.startsWith(u8, path, VFS_PREFIX)) {
            return path.len == VFS_PREFIX.len or path[VFS_PREFIX.len] == '/';
        }
        // Check for relative path "vfs" or "vfs/..."
        const relative_prefix = "vfs";
        if (std.mem.startsWith(u8, path, relative_prefix)) {
            return path.len == relative_prefix.len or path[relative_prefix.len] == '/';
        }
        return false;
    }

    /// Strip the VFS prefix from a path
    /// "/vfs/app/test.py" -> "/app/test.py"
    /// "vfs/app/test.py" -> "/app/test.py"
    pub fn stripVfsPrefix(path: []const u8) []const u8 {
        // Handle absolute path "/vfs" or "/vfs/..."
        if (std.mem.startsWith(u8, path, VFS_PREFIX)) {
            if (path.len == VFS_PREFIX.len) return "/";
            const stripped = path[VFS_PREFIX.len..];
            return if (stripped.len == 0) "/" else stripped;
        }
        // Handle relative path "vfs" or "vfs/..."
        const relative_prefix = "vfs";
        if (std.mem.startsWith(u8, path, relative_prefix)) {
            if (path.len == relative_prefix.len) return "/";
            if (path[relative_prefix.len] == '/') {
                const stripped = path[relative_prefix.len..];
                return if (stripped.len == 0) "/" else stripped;
            }
        }
        return path;
    }

    /// Check if an fd is backed by the VFS
    pub fn isVfsFd(self: *VirtualFileSystem, fd: i32) bool {
        return self.fd_table.isVfsFd(fd);
    }

    /// Check if an fd is backed by the real filesystem
    pub fn isRealFd(self: *VirtualFileSystem, fd: i32) bool {
        return self.fd_table.isRealFd(fd);
    }

    /// Get the backend type for an fd
    pub fn getFdBackend(self: *VirtualFileSystem, fd: i32) ?Backend {
        if (self.fd_table.get(fd)) |desc| {
            return desc.backend;
        }
        return null;
    }

    // ========================================================================
    // Path Operations
    // ========================================================================

    /// Normalize a path (remove . and .., handle //)
    pub fn normalizePath(self: *VirtualFileSystem, path: []const u8) ![]const u8 {
        if (path.len == 0) return try self.allocator.dupe(u8, "/");

        var components = std.ArrayList([]const u8).init(self.allocator);
        defer components.deinit();

        var iter = std.mem.splitSequence(u8, path, "/");
        while (iter.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) {
                continue;
            } else if (std.mem.eql(u8, component, "..")) {
                if (components.items.len > 0) {
                    _ = components.pop();
                }
            } else {
                try components.append(component);
            }
        }

        if (components.items.len == 0) {
            return try self.allocator.dupe(u8, "/");
        }

        var result = std.ArrayList(u8).init(self.allocator);
        for (components.items) |component| {
            try result.append('/');
            try result.appendSlice(component);
        }

        return try result.toOwnedSlice();
    }

    /// Resolve a path relative to a directory fd
    fn resolvePath(self: *VirtualFileSystem, dir_fd: i32, path: []const u8) !struct { dir: *MemoryDirectory, name: []const u8 } {
        // Get the starting directory
        var current_dir: *MemoryDirectory = undefined;

        if (path.len > 0 and path[0] == '/') {
            // Absolute path - start from root
            current_dir = self.root;
        } else {
            // Relative path - start from dir_fd
            const fd_info = self.fd_table.get(dir_fd) orelse return error.BadFileDescriptor;

            switch (fd_info.kind) {
                .preopen => {
                    if (fd_info.resource.preopen.host_dir) |dir| {
                        current_dir = dir;
                    } else {
                        // Real filesystem preopen - not supported for VFS operations
                        return error.InvalidArgument;
                    }
                },
                .memory_directory => {
                    current_dir = fd_info.resource.memory_directory;
                },
                else => return error.NotADirectory,
            }
        }

        // Parse path components
        var iter = std.mem.splitSequence(u8, path, "/");
        var last_component: []const u8 = "";
        var last_dir = current_dir;

        while (iter.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) {
                continue;
            }

            // If we have a pending component, traverse into it
            if (last_component.len > 0) {
                if (std.mem.eql(u8, last_component, "..")) {
                    if (current_dir.parent) |parent| {
                        current_dir = parent;
                    }
                } else {
                    const node = current_dir.lookup(last_component) orelse return error.FileNotFound;
                    switch (node) {
                        .directory => |dir| {
                            current_dir = dir;
                        },
                        .file => return error.NotADirectory,
                    }
                }
            }

            last_dir = current_dir;
            last_component = component;
        }

        return .{ .dir = last_dir, .name = last_component };
    }

    // ========================================================================
    // File System Operations
    // ========================================================================

    /// Create a directory at the given path
    pub fn mkdir(self: *VirtualFileSystem, dir_fd: i32, path: []const u8) VfsError!void {
        self.debugLog("mkdir(fd={}, path=\"{s}\")", .{ dir_fd, path });

        const resolved = self.resolvePath(dir_fd, path) catch |err| return @as(VfsError, @errorCast(err));

        if (resolved.name.len == 0) {
            return error.InvalidPath;
        }

        _ = try resolved.dir.createDirectory(resolved.name, self.nextInode());
    }

    /// Create a file with content at the given path
    pub fn createFile(self: *VirtualFileSystem, path: []const u8, content: []const u8) VfsError!void {
        self.debugLog("createFile(path=\"{s}\", len={})", .{ path, content.len });

        // Ensure parent directories exist
        try self.mkdirp(path);

        const resolved = self.resolvePath(3, path) catch |err| return @as(VfsError, @errorCast(err)); // Use first preopen as base

        if (resolved.name.len == 0) {
            return error.InvalidPath;
        }

        // Check if file already exists
        if (resolved.dir.lookup(resolved.name)) |existing| {
            switch (existing) {
                .file => |f| {
                    // Overwrite existing file
                    try f.setContent(content);
                    return;
                },
                .directory => return error.IsADirectory,
            }
        }

        // Create new file
        const file = try resolved.dir.createFile(resolved.name, self.nextInode());
        _ = try file.pwrite(content, 0);
    }

    /// Create all directories in path (like mkdir -p)
    pub fn mkdirp(self: *VirtualFileSystem, path: []const u8) VfsError!void {
        var current_dir = self.root;

        var iter = std.mem.splitSequence(u8, path, "/");
        var remaining_path: std.ArrayListUnmanaged([]const u8) = .empty;
        defer remaining_path.deinit(self.allocator);

        // Collect all components except the last (which is the filename)
        while (iter.next()) |component| {
            if (component.len == 0 or std.mem.eql(u8, component, ".")) {
                continue;
            }
            remaining_path.append(self.allocator, component) catch return error.OutOfMemory;
        }

        // Create directories for all but the last component
        if (remaining_path.items.len > 0) {
            for (remaining_path.items[0 .. remaining_path.items.len - 1]) |component| {
                if (current_dir.lookup(component)) |node| {
                    switch (node) {
                        .directory => |dir| {
                            current_dir = dir;
                        },
                        .file => return error.FileExists,
                    }
                } else {
                    current_dir = try current_dir.createDirectory(component, self.nextInode());
                }
            }
        }
    }

    /// Open a file or directory
    pub fn open(self: *VirtualFileSystem, dir_fd: i32, path: []const u8, flags: OpenFlags) VfsError!i32 {
        self.debugLog("open(fd={}, path=\"{s}\", flags={{read={},write={},create={}}})", .{ dir_fd, path, flags.read, flags.write, flags.create });

        // Check if this path matches a mount point
        for (self.mounts.items) |mount| {
            if (std.mem.startsWith(u8, path, mount.guest_path)) {
                // This is a passthrough to real filesystem
                return self.openReal(mount, path[mount.guest_path.len..], flags);
            }
        }

        const resolved = self.resolvePath(dir_fd, path) catch |err| return @as(VfsError, @errorCast(err));

        if (resolved.name.len == 0) {
            // Opening the directory itself
            return try self.fd_table.openMemoryDirectory(resolved.dir, path);
        }

        // Look up the file/directory
        if (resolved.dir.lookup(resolved.name)) |node| {
            switch (node) {
                .file => |file| {
                    if (flags.directory) {
                        return error.NotADirectory;
                    }
                    if (flags.exclusive) {
                        return error.FileExists;
                    }
                    if (flags.truncate) {
                        try file.truncate(0);
                    }
                    return try self.fd_table.openMemoryFile(file, flags, path);
                },
                .directory => |dir| {
                    if (flags.write and !flags.directory) {
                        return error.IsADirectory;
                    }
                    return try self.fd_table.openMemoryDirectory(dir, path);
                },
            }
        } else if (flags.create) {
            // Create new file
            const file = try resolved.dir.createFile(resolved.name, self.nextInode());
            return try self.fd_table.openMemoryFile(file, flags, path);
        } else {
            return error.FileNotFound;
        }
    }

    /// Open a file from the real filesystem (passthrough)
    fn openReal(self: *VirtualFileSystem, mount: MountPoint, sub_path: []const u8, flags: OpenFlags) VfsError!i32 {
        _ = flags;
        _ = sub_path;
        _ = mount;
        _ = self;
        // TODO: Implement real filesystem passthrough
        return error.FileNotFound;
    }

    /// Close a file descriptor
    pub fn close(self: *VirtualFileSystem, fd: i32) VfsError!void {
        self.debugLog("close(fd={})", .{fd});
        return self.fd_table.close(fd);
    }

    /// Read from a file descriptor
    pub fn read(self: *VirtualFileSystem, fd: i32, buf: []u8) VfsError!usize {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        if (!desc.flags.read) {
            return error.NotOpenForReading;
        }

        switch (desc.kind) {
            .memory_file => {
                const file = desc.resource.memory_file;
                const bytes_read = file.pread(buf, desc.position);
                desc.position += bytes_read;
                return bytes_read;
            },
            .stdio => {
                // Pass through to real stdio
                return posix.read(desc.resource.real_fd, buf) catch return error.IO;
            },
            else => return error.BadFileDescriptor,
        }
    }

    /// Write to a file descriptor
    pub fn write(self: *VirtualFileSystem, fd: i32, data: []const u8) VfsError!usize {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        if (!desc.flags.write) {
            return error.NotOpenForWriting;
        }

        switch (desc.kind) {
            .memory_file => {
                const file = desc.resource.memory_file;
                const bytes_written = try file.pwrite(data, desc.position);
                desc.position += bytes_written;
                return bytes_written;
            },
            .stdio => {
                // Pass through to real stdio
                return posix.write(desc.resource.real_fd, data) catch return error.IO;
            },
            else => return error.BadFileDescriptor,
        }
    }

    /// Seek within a file
    pub fn seek(self: *VirtualFileSystem, fd: i32, offset: i64, whence: SeekWhence) VfsError!u64 {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        switch (desc.kind) {
            .memory_file => {
                const file = desc.resource.memory_file;
                const file_size = file.size();

                const new_pos: i64 = switch (whence) {
                    .set => offset,
                    .cur => @as(i64, @intCast(desc.position)) + offset,
                    .end => @as(i64, @intCast(file_size)) + offset,
                };

                if (new_pos < 0) {
                    return error.InvalidSeek;
                }

                desc.position = @intCast(new_pos);
                return desc.position;
            },
            else => return error.BadFileDescriptor,
        }
    }

    /// Get current position in file
    pub fn tell(self: *VirtualFileSystem, fd: i32) VfsError!u64 {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        switch (desc.kind) {
            .memory_file => {
                return desc.position;
            },
            else => return error.BadFileDescriptor,
        }
    }

    /// Get file statistics
    pub fn fstat(self: *VirtualFileSystem, fd: i32) VfsError!FileStat {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        switch (desc.kind) {
            .memory_file => {
                return desc.resource.memory_file.stat();
            },
            .memory_directory => {
                return desc.resource.memory_directory.stat();
            },
            .preopen => {
                if (desc.resource.preopen.host_dir) |dir| {
                    return dir.stat();
                }
                // Real filesystem preopen
                return .{
                    .filetype = .directory,
                    .size = 4096,
                };
            },
            .stdio => {
                // Stdio stats
                return .{
                    .filetype = .regular_file,
                    .size = 0,
                };
            },
        }
    }

    /// Get file statistics by path
    pub fn stat(self: *VirtualFileSystem, dir_fd: i32, path: []const u8) VfsError!FileStat {
        const resolved = self.resolvePath(dir_fd, path) catch |err| return @as(VfsError, @errorCast(err));

        if (resolved.name.len == 0) {
            return resolved.dir.stat();
        }

        const node = resolved.dir.lookup(resolved.name) orelse return error.FileNotFound;
        return node.stat();
    }

    /// Read directory entries
    pub fn readdir(self: *VirtualFileSystem, fd: i32) VfsError![]DirEntry {
        const desc = self.fd_table.get(fd) orelse return error.BadFileDescriptor;

        const dir: *MemoryDirectory = switch (desc.kind) {
            .memory_directory => desc.resource.memory_directory,
            .preopen => desc.resource.preopen.host_dir orelse return error.InvalidArgument,
            else => return error.NotADirectory,
        };

        return dir.readdir(self.allocator);
    }

    /// Free directory entries allocated by readdir
    pub fn freeReaddir(self: *VirtualFileSystem, entries: []DirEntry) void {
        self.allocator.free(entries);
    }

    // ========================================================================
    // Preopen Management
    // ========================================================================

    /// Add a preopen directory backed by in-memory VFS
    pub fn addPreopen(self: *VirtualFileSystem, guest_path: []const u8) VfsError!i32 {
        self.debugLog("addPreopen(guest_path=\"{s}\")", .{guest_path});

        // Create the directory in the VFS if it doesn't exist
        try self.mkdirp(guest_path);

        // Get or create the directory
        const resolved = self.resolvePath(3, guest_path) catch |err| return @as(VfsError, @errorCast(err));
        var dir: *MemoryDirectory = undefined;

        if (resolved.name.len == 0) {
            dir = resolved.dir;
        } else if (resolved.dir.lookup(resolved.name)) |node| {
            switch (node) {
                .directory => |d| {
                    dir = d;
                },
                .file => return error.FileExists,
            }
        } else {
            dir = try resolved.dir.createDirectory(resolved.name, self.nextInode());
        }

        return try self.fd_table.addVfsPreopen(guest_path, dir);
    }

    /// Add a preopen that passes through to real filesystem
    pub fn addRealPreopen(self: *VirtualFileSystem, guest_path: []const u8, host_path: []const u8) VfsError!i32 {
        self.debugLog("addRealPreopen(guest_path=\"{s}\", host_path=\"{s}\")", .{ guest_path, host_path });

        const dir = fs.openDirAbsolute(host_path, .{}) catch return error.FileNotFound;

        const guest_copy = self.allocator.dupe(u8, guest_path) catch return error.OutOfMemory;
        const host_copy = self.allocator.dupe(u8, host_path) catch {
            self.allocator.free(guest_copy);
            return error.OutOfMemory;
        };

        self.mounts.append(self.allocator, .{
            .guest_path = guest_copy,
            .host_path = host_copy,
            .host_fd = dir.fd,
        }) catch {
            self.allocator.free(guest_copy);
            self.allocator.free(host_copy);
            posix.close(dir.fd);
            return error.OutOfMemory;
        };

        return try self.fd_table.addRealPreopen(guest_path, dir.fd);
    }

    /// Get preopen information for fd_prestat_get
    pub fn getPreopen(self: *VirtualFileSystem, fd: i32) ?PreopenInfo {
        if (self.fd_table.get(fd)) |desc| {
            if (desc.kind == .preopen) {
                return desc.resource.preopen;
            }
        }
        return null;
    }

    /// Check if a fd is a valid preopen
    pub fn isPreopen(self: *VirtualFileSystem, fd: i32) bool {
        return self.fd_table.isPreopen(fd);
    }
};

// Tests
test "vfs basic file operations" {
    const allocator = std.testing.allocator;

    var vfs_inst = try VirtualFileSystem.init(allocator);
    defer vfs_inst.deinit();

    // Add a preopen
    const preopen_fd = try vfs_inst.addPreopen("/app");

    // Create a file
    try vfs_inst.createFile("/app/test.txt", "Hello, World!");

    // Open it
    const fd = try vfs_inst.open(preopen_fd, "test.txt", .{ .read = true });

    // Read it
    var buf: [20]u8 = undefined;
    const n = try vfs_inst.read(fd, &buf);
    try std.testing.expectEqualSlices(u8, "Hello, World!", buf[0..n]);

    // Close it
    try vfs_inst.close(fd);
}

test "vfs directory operations" {
    const allocator = std.testing.allocator;

    var vfs_inst = try VirtualFileSystem.init(allocator);
    defer vfs_inst.deinit();

    // Add preopen
    const preopen_fd = try vfs_inst.addPreopen("/test");

    // Create nested directories and file
    try vfs_inst.createFile("/test/sub/dir/file.txt", "nested");

    // Stat the file
    const file_stat = try vfs_inst.stat(preopen_fd, "sub/dir/file.txt");
    try std.testing.expect(file_stat.filetype == .regular_file);
    try std.testing.expectEqual(@as(u64, 6), file_stat.size);
}
