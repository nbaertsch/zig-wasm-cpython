// File Descriptor Table
//
// Manages the mapping between integer file descriptors and open file handles.
// This is the core of WASI fd management.
//
// Architecture:
// - Single fd namespace (no magic fd numbers)
// - Each fd tracks which backend owns it (VFS or real filesystem)
// - Position is tracked per-fd, not per-file (POSIX semantics)

const std = @import("std");
const Allocator = std.mem.Allocator;
const AutoHashMap = std.AutoHashMap;
const vfs = @import("vfs.zig");
const MemoryFile = @import("memory_file.zig").MemoryFile;
const MemoryDirectory = @import("memory_directory.zig").MemoryDirectory;

const FileType = vfs.FileType;
const OpenFlags = vfs.OpenFlags;
const VfsError = vfs.VfsError;

/// Which backend owns this file descriptor
pub const Backend = enum {
    /// In-memory VFS (for /vfs/* paths)
    vfs,
    /// Real filesystem (passthrough to host)
    real,
    /// Standard I/O (stdin/stdout/stderr)
    stdio,
};

/// What kind of resource is backing this file descriptor
pub const FdKind = enum {
    /// Standard input/output (stdin, stdout, stderr)
    stdio,
    /// In-memory file
    memory_file,
    /// In-memory directory
    memory_directory,
    /// Preopen directory (virtual mount point)
    preopen,
};

/// State for an open directory (for readdir iteration)
pub const DirState = struct {
    /// Cookie for readdir continuation
    cookie: u64,
    /// Cached entries (if any)
    cached_entries: ?[]vfs.DirEntry,
};

/// An open file descriptor
pub const FileDescriptor = struct {
    /// Which backend owns this fd
    backend: Backend,

    /// What kind of resource this is
    kind: FdKind,

    /// The underlying resource (depends on kind)
    resource: union {
        /// For memory_file: pointer to MemoryFile
        memory_file: *MemoryFile,
        /// For memory_directory: pointer to MemoryDirectory
        memory_directory: *MemoryDirectory,
        /// For stdio: actual OS fd
        real_fd: std.posix.fd_t,
        /// For preopen: preopen info
        preopen: PreopenInfo,
    },

    /// Open flags (what operations are allowed)
    flags: OpenFlags,

    /// Current position in file (per-fd, not per-file!)
    position: u64,

    /// Path this fd was opened from (for debugging and path resolution)
    path: ?[]const u8,

    /// Directory state (for directories)
    dir_state: DirState,

    pub fn isReadable(self: *const FileDescriptor) bool {
        return self.flags.read;
    }

    pub fn isWritable(self: *const FileDescriptor) bool {
        return self.flags.write;
    }

    pub fn isDirectory(self: *const FileDescriptor) bool {
        return self.kind == .memory_directory or self.kind == .preopen;
    }

    pub fn isVfs(self: *const FileDescriptor) bool {
        return self.backend == .vfs;
    }
};

/// Preopen information
pub const PreopenInfo = struct {
    /// The guest path this preopen maps to
    guest_path: []const u8,
    /// For VFS preopens: the memory directory
    host_dir: ?*MemoryDirectory,
    /// For real filesystem passthrough: the real fd
    real_fd: ?std.posix.fd_t,
};

/// File descriptor table managing all open fds
pub const FdTable = struct {
    allocator: Allocator,

    /// Map of fd number -> FileDescriptor
    fds: AutoHashMap(i32, FileDescriptor),

    /// Next available fd number (starts at 3, after stdio)
    next_fd: i32,

    /// Reserved fds (0=stdin, 1=stdout, 2=stderr)
    pub const RESERVED_FDS: i32 = 3;

    pub fn init(allocator: Allocator) FdTable {
        return FdTable{
            .allocator = allocator,
            .fds = AutoHashMap(i32, FileDescriptor).init(allocator),
            .next_fd = RESERVED_FDS, // Start after stdio
        };
    }

    pub fn deinit(self: *FdTable) void {
        // Free any allocated paths
        var iter = self.fds.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.path) |path| {
                self.allocator.free(path);
            }
            if (entry.value_ptr.dir_state.cached_entries) |entries| {
                self.allocator.free(entries);
            }
        }
        self.fds.deinit();
    }

    /// Initialize standard streams (stdin, stdout, stderr)
    pub fn initStdio(self: *FdTable) !void {
        // stdin (fd 0)
        try self.fds.put(0, .{
            .backend = .stdio,
            .kind = .stdio,
            .resource = .{ .real_fd = std.posix.STDIN_FILENO },
            .flags = .{ .read = true },
            .position = 0,
            .path = null,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        });

        // stdout (fd 1)
        try self.fds.put(1, .{
            .backend = .stdio,
            .kind = .stdio,
            .resource = .{ .real_fd = std.posix.STDOUT_FILENO },
            .flags = .{ .write = true },
            .position = 0,
            .path = null,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        });

        // stderr (fd 2)
        try self.fds.put(2, .{
            .backend = .stdio,
            .kind = .stdio,
            .resource = .{ .real_fd = std.posix.STDERR_FILENO },
            .flags = .{ .write = true },
            .position = 0,
            .path = null,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        });
    }

    /// Allocate a new fd number
    pub fn allocateFd(self: *FdTable) VfsError!i32 {
        const fd = self.next_fd;
        if (fd >= 1024) { // Arbitrary limit
            return error.TooManyOpenFiles;
        }
        self.next_fd += 1;
        return fd;
    }

    /// Add a VFS-backed preopen directory
    pub fn addVfsPreopen(self: *FdTable, guest_path: []const u8, dir: *MemoryDirectory) VfsError!i32 {
        const fd = try self.allocateFd();
        const path_copy = self.allocator.dupe(u8, guest_path) catch return error.OutOfMemory;

        self.fds.put(fd, .{
            .backend = .vfs,
            .kind = .preopen,
            .resource = .{
                .preopen = .{
                    .guest_path = path_copy,
                    .host_dir = dir,
                    .real_fd = null,
                },
            },
            .flags = .{ .read = true, .write = true, .directory = true },
            .position = 0,
            .path = path_copy,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        }) catch return error.OutOfMemory;

        return fd;
    }

    /// Add a real filesystem preopen directory
    pub fn addRealPreopen(self: *FdTable, guest_path: []const u8, real_fd: std.posix.fd_t) VfsError!i32 {
        const fd = try self.allocateFd();
        const path_copy = self.allocator.dupe(u8, guest_path) catch return error.OutOfMemory;

        self.fds.put(fd, .{
            .backend = .real,
            .kind = .preopen,
            .resource = .{
                .preopen = .{
                    .guest_path = path_copy,
                    .host_dir = null,
                    .real_fd = real_fd,
                },
            },
            .flags = .{ .read = true, .write = true, .directory = true },
            .position = 0,
            .path = path_copy,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        }) catch return error.OutOfMemory;

        return fd;
    }

    /// Open a VFS memory file and return its fd
    pub fn openMemoryFile(self: *FdTable, file: *MemoryFile, flags: OpenFlags, path: ?[]const u8) VfsError!i32 {
        const fd = try self.allocateFd();
        const path_copy = if (path) |p| self.allocator.dupe(u8, p) catch return error.OutOfMemory else null;

        self.fds.put(fd, .{
            .backend = .vfs,
            .kind = .memory_file,
            .resource = .{ .memory_file = file },
            .flags = flags,
            .position = 0, // Each fd starts at position 0
            .path = path_copy,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        }) catch return error.OutOfMemory;

        return fd;
    }

    /// Open a VFS memory directory and return its fd
    pub fn openMemoryDirectory(self: *FdTable, dir: *MemoryDirectory, path: ?[]const u8) VfsError!i32 {
        const fd = try self.allocateFd();
        const path_copy = if (path) |p| self.allocator.dupe(u8, p) catch return error.OutOfMemory else null;

        self.fds.put(fd, .{
            .backend = .vfs,
            .kind = .memory_directory,
            .resource = .{ .memory_directory = dir },
            .flags = .{ .read = true, .directory = true },
            .position = 0,
            .path = path_copy,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        }) catch return error.OutOfMemory;

        return fd;
    }

    /// Get a file descriptor by number
    pub fn get(self: *FdTable, fd: i32) ?*FileDescriptor {
        return self.fds.getPtr(fd);
    }

    /// Check if an fd exists and is VFS-backed
    pub fn isVfsFd(self: *FdTable, fd: i32) bool {
        if (self.get(fd)) |desc| {
            return desc.backend == .vfs;
        }
        return false;
    }

    /// Check if an fd exists and is real filesystem-backed
    pub fn isRealFd(self: *FdTable, fd: i32) bool {
        if (self.get(fd)) |desc| {
            return desc.backend == .real;
        }
        return false;
    }

    /// Close a file descriptor
    pub fn close(self: *FdTable, fd: i32) VfsError!void {
        const entry = self.fds.fetchRemove(fd) orelse return error.BadFileDescriptor;

        if (entry.value.path) |path| {
            self.allocator.free(path);
        }
        if (entry.value.dir_state.cached_entries) |entries| {
            self.allocator.free(entries);
        }

        // Note: We don't free the underlying file/directory here,
        // that's managed by the VFS
    }

    /// Duplicate a file descriptor
    pub fn dup(self: *FdTable, old_fd: i32) VfsError!i32 {
        const old = self.get(old_fd) orelse return error.BadFileDescriptor;
        const new_fd = try self.allocateFd();

        const path_copy = if (old.path) |p| self.allocator.dupe(u8, p) catch return error.OutOfMemory else null;

        self.fds.put(new_fd, .{
            .backend = old.backend,
            .kind = old.kind,
            .resource = old.resource,
            .flags = old.flags,
            .position = old.position, // Duped fds share position initially
            .path = path_copy,
            .dir_state = .{ .cookie = 0, .cached_entries = null },
        }) catch return error.OutOfMemory;

        return new_fd;
    }

    /// Get the list of preopens (for fd_prestat_get iteration)
    pub fn getPreopens(self: *FdTable, allocator: Allocator) ![]PreopenEntry {
        var preopens = std.ArrayList(PreopenEntry).init(allocator);

        var iter = self.fds.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.kind == .preopen) {
                try preopens.append(.{
                    .fd = entry.key_ptr.*,
                    .path = entry.value_ptr.resource.preopen.guest_path,
                    .backend = entry.value_ptr.backend,
                });
            }
        }

        return preopens.toOwnedSlice();
    }

    /// Check if fd is a preopen
    pub fn isPreopen(self: *FdTable, fd: i32) bool {
        if (self.get(fd)) |desc| {
            return desc.kind == .preopen;
        }
        return false;
    }

    /// Get preopen path for a fd
    pub fn getPreopenPath(self: *FdTable, fd: i32) ?[]const u8 {
        if (self.get(fd)) |desc| {
            if (desc.kind == .preopen) {
                return desc.resource.preopen.guest_path;
            }
        }
        return null;
    }

    /// Update position for a file descriptor
    pub fn setPosition(self: *FdTable, fd: i32, pos: u64) VfsError!void {
        const desc = self.get(fd) orelse return error.BadFileDescriptor;
        desc.position = pos;
    }

    /// Get position for a file descriptor
    pub fn getPosition(self: *FdTable, fd: i32) VfsError!u64 {
        const desc = self.get(fd) orelse return error.BadFileDescriptor;
        return desc.position;
    }
};

/// Entry for preopen listing
pub const PreopenEntry = struct {
    fd: i32,
    path: []const u8,
    backend: Backend,
};

// Tests
test "fd table basic operations" {
    const allocator = std.testing.allocator;

    var table = FdTable.init(allocator);
    defer table.deinit();

    try table.initStdio();

    // Check stdio fds exist
    try std.testing.expect(table.get(0) != null);
    try std.testing.expect(table.get(1) != null);
    try std.testing.expect(table.get(2) != null);

    // Check properties
    try std.testing.expect(table.get(0).?.flags.read);
    try std.testing.expect(table.get(1).?.flags.write);
    try std.testing.expect(table.get(0).?.backend == .stdio);
}

test "fd table allocate starts at 3" {
    const allocator = std.testing.allocator;

    var table = FdTable.init(allocator);
    defer table.deinit();

    const fd1 = try table.allocateFd();
    const fd2 = try table.allocateFd();

    try std.testing.expectEqual(@as(i32, 3), fd1);
    try std.testing.expectEqual(@as(i32, 4), fd2);
}

test "fd table backend tracking" {
    const allocator = std.testing.allocator;

    var table = FdTable.init(allocator);
    defer table.deinit();

    // Simulate adding a VFS preopen (need a mock directory)
    const fd = try table.allocateFd();
    try std.testing.expectEqual(@as(i32, 3), fd);

    // isVfsFd should return false for non-existent fd
    try std.testing.expect(!table.isVfsFd(99));
}
