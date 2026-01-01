// In-Memory Directory Implementation
//
// Provides directory functionality with:
// - File and subdirectory management
// - Directory listing (readdir)
// - Path resolution
// - Stat information

const std = @import("std");
const Allocator = std.mem.Allocator;
const StringHashMap = std.StringHashMap;
const ArrayList = std.ArrayList;
const vfs = @import("vfs.zig");
const MemoryFile = @import("memory_file.zig").MemoryFile;

const FileType = vfs.FileType;
const FileStat = vfs.FileStat;
const DirEntry = vfs.DirEntry;
const VfsError = vfs.VfsError;

/// Represents either a file or directory in the VFS
pub const Node = union(enum) {
    file: *MemoryFile,
    directory: *MemoryDirectory,

    pub fn getType(self: Node) FileType {
        return switch (self) {
            .file => .regular_file,
            .directory => .directory,
        };
    }

    pub fn stat(self: Node) FileStat {
        return switch (self) {
            .file => |f| f.stat(),
            .directory => |d| d.stat(),
        };
    }

    pub fn getInode(self: Node) u64 {
        return switch (self) {
            .file => |f| f.inode,
            .directory => |d| d.inode,
        };
    }
};

/// An in-memory directory
pub const MemoryDirectory = struct {
    allocator: Allocator,

    /// Directory entries (name -> Node)
    children: StringHashMap(Node),

    /// Parent directory (null for root)
    parent: ?*MemoryDirectory,

    /// Inode number
    inode: u64,

    /// Access times
    atime: u64,
    mtime: u64,
    ctime: u64,

    /// Directory name (for debugging)
    name: []const u8,

    pub fn init(allocator: Allocator, inode: u64, name: []const u8) !*MemoryDirectory {
        const dir = try allocator.create(MemoryDirectory);
        const now = getCurrentTimestamp();

        dir.* = .{
            .allocator = allocator,
            .children = StringHashMap(Node).init(allocator),
            .parent = null,
            .inode = inode,
            .atime = now,
            .mtime = now,
            .ctime = now,
            .name = try allocator.dupe(u8, name),
        };

        return dir;
    }

    pub fn deinit(self: *MemoryDirectory) void {
        // Recursively free all children
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            switch (entry.value_ptr.*) {
                .file => |f| {
                    f.deinit();
                    self.allocator.destroy(f);
                },
                .directory => |d| {
                    d.deinit();
                },
            }
        }
        self.children.deinit();
        self.allocator.free(self.name);
        self.allocator.destroy(self);
    }

    /// Add a file to this directory
    pub fn addFile(self: *MemoryDirectory, name: []const u8, file: *MemoryFile) VfsError!void {
        if (self.children.contains(name)) {
            return error.FileExists;
        }

        const owned_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        self.children.put(owned_name, .{ .file = file }) catch {
            self.allocator.free(owned_name);
            return error.OutOfMemory;
        };

        self.updateModTime();
    }

    /// Add a subdirectory to this directory
    pub fn addDirectory(self: *MemoryDirectory, name: []const u8, dir: *MemoryDirectory) VfsError!void {
        if (self.children.contains(name)) {
            return error.FileExists;
        }

        const owned_name = self.allocator.dupe(u8, name) catch return error.OutOfMemory;
        dir.parent = self;
        self.children.put(owned_name, .{ .directory = dir }) catch {
            self.allocator.free(owned_name);
            return error.OutOfMemory;
        };

        self.updateModTime();
    }

    /// Create a new file in this directory
    pub fn createFile(self: *MemoryDirectory, name: []const u8, inode: u64) VfsError!*MemoryFile {
        if (self.children.contains(name)) {
            return error.FileExists;
        }

        const file = self.allocator.create(MemoryFile) catch return error.OutOfMemory;
        file.* = MemoryFile.init(self.allocator, inode);

        self.addFile(name, file) catch |err| {
            file.deinit();
            self.allocator.destroy(file);
            return err;
        };

        return file;
    }

    /// Create a new subdirectory in this directory
    pub fn createDirectory(self: *MemoryDirectory, name: []const u8, inode: u64) VfsError!*MemoryDirectory {
        if (self.children.contains(name)) {
            return error.FileExists;
        }

        const dir = MemoryDirectory.init(self.allocator, inode, name) catch return error.OutOfMemory;

        self.addDirectory(name, dir) catch |err| {
            dir.deinit();
            return err;
        };

        return dir;
    }

    /// Look up a child by name
    pub fn lookup(self: *MemoryDirectory, name: []const u8) ?Node {
        self.atime = getCurrentTimestamp();
        return self.children.get(name);
    }

    /// Remove a child by name
    pub fn remove(self: *MemoryDirectory, name: []const u8) VfsError!Node {
        const kv = self.children.fetchRemove(name) orelse return error.FileNotFound;

        // Free the owned key
        self.allocator.free(kv.key);
        self.updateModTime();

        return kv.value;
    }

    /// Check if directory is empty
    pub fn isEmpty(self: *const MemoryDirectory) bool {
        return self.children.count() == 0;
    }

    /// Get number of entries
    pub fn count(self: *const MemoryDirectory) usize {
        return self.children.count();
    }

    /// Get directory statistics
    pub fn stat(self: *const MemoryDirectory) FileStat {
        return .{
            .dev = 0,
            .ino = self.inode,
            .filetype = .directory,
            .nlink = 2 + self.countSubdirectories(), // . and .. plus subdirs
            .size = 4096, // Typical directory size
            .atim = self.atime,
            .mtim = self.mtime,
            .ctim = self.ctime,
        };
    }

    /// List directory entries
    pub fn readdir(self: *MemoryDirectory, allocator: Allocator) VfsError![]DirEntry {
        self.atime = getCurrentTimestamp();

        // Count entries: children + . + ..
        const entry_count = self.children.count() + 2;
        var entries = allocator.alloc(DirEntry, entry_count) catch return error.OutOfMemory;

        var i: usize = 0;

        // Add "." entry
        entries[i] = .{
            .name = ".",
            .filetype = .directory,
            .inode = self.inode,
        };
        i += 1;

        // Add ".." entry
        entries[i] = .{
            .name = "..",
            .filetype = .directory,
            .inode = if (self.parent) |p| p.inode else self.inode,
        };
        i += 1;

        // Add all children
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            entries[i] = .{
                .name = entry.key_ptr.*,
                .filetype = entry.value_ptr.getType(),
                .inode = entry.value_ptr.getInode(),
            };
            i += 1;
        }

        return entries;
    }

    /// Free entries allocated by readdir
    pub fn freeReaddir(allocator: Allocator, entries: []DirEntry) void {
        allocator.free(entries);
    }

    fn countSubdirectories(self: *const MemoryDirectory) u64 {
        var count_val: u64 = 0;
        var iter = self.children.iterator();
        while (iter.next()) |entry| {
            if (entry.value_ptr.* == .directory) {
                count_val += 1;
            }
        }
        return count_val;
    }

    fn updateModTime(self: *MemoryDirectory) void {
        const now = getCurrentTimestamp();
        self.mtime = now;
        self.ctime = now;
    }
};

fn getCurrentTimestamp() u64 {
    const ns = std.time.nanoTimestamp();
    return @as(u64, @intCast(@max(0, ns)));
}

// Tests
test "memory directory basic operations" {
    const allocator = std.testing.allocator;

    var dir = try MemoryDirectory.init(allocator, 1, "root");
    defer dir.deinit();

    // Create a file
    var file = try dir.createFile("test.txt", 2);
    _ = try file.write("Hello!");

    // Look it up
    const found = dir.lookup("test.txt");
    try std.testing.expect(found != null);
    try std.testing.expect(found.?.getType() == .regular_file);
}

test "memory directory subdirectories" {
    const allocator = std.testing.allocator;

    var root = try MemoryDirectory.init(allocator, 1, "root");
    defer root.deinit();

    // Create subdirectory
    var subdir = try root.createDirectory("subdir", 2);

    // Create file in subdirectory
    _ = try subdir.createFile("nested.txt", 3);

    // Verify structure
    const sub_node = root.lookup("subdir");
    try std.testing.expect(sub_node != null);
    try std.testing.expect(sub_node.?.getType() == .directory);

    const sub = sub_node.?.directory;
    const file_node = sub.lookup("nested.txt");
    try std.testing.expect(file_node != null);
}

test "memory directory readdir" {
    const allocator = std.testing.allocator;

    var dir = try MemoryDirectory.init(allocator, 1, "testdir");
    defer dir.deinit();

    _ = try dir.createFile("file1.txt", 2);
    _ = try dir.createFile("file2.txt", 3);
    _ = try dir.createDirectory("subdir", 4);

    const entries = try dir.readdir(allocator);
    defer MemoryDirectory.freeReaddir(allocator, entries);

    // Should have: . .. file1.txt file2.txt subdir
    try std.testing.expectEqual(@as(usize, 5), entries.len);

    // First two should be . and ..
    try std.testing.expectEqualSlices(u8, ".", entries[0].name);
    try std.testing.expectEqualSlices(u8, "..", entries[1].name);
}
