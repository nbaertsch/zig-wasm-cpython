// In-Memory File Implementation
//
// Provides a file-like interface backed by memory. Supports:
// - Reading and writing at arbitrary positions
// - Seeking
// - Dynamic sizing (grows as needed)
// - Stat information

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayListUnmanaged = std.ArrayListUnmanaged;
const vfs = @import("vfs.zig");

const FileType = vfs.FileType;
const FileStat = vfs.FileStat;
const VfsError = vfs.VfsError;

/// An in-memory file (content-only, position tracked per-fd in FdTable)
pub const MemoryFile = struct {
    allocator: Allocator,

    /// File content
    data: ArrayListUnmanaged(u8),

    /// Inode number (unique identifier)
    inode: u64,

    /// Access times (nanoseconds since epoch)
    atime: u64,
    mtime: u64,
    ctime: u64,

    /// Whether the file is read-only
    read_only: bool,

    pub fn init(allocator: Allocator, inode: u64) MemoryFile {
        const now = getCurrentTimestamp();
        return .{
            .allocator = allocator,
            .data = .empty,
            .inode = inode,
            .atime = now,
            .mtime = now,
            .ctime = now,
            .read_only = false,
        };
    }

    pub fn initWithContent(allocator: Allocator, inode: u64, content: []const u8) !MemoryFile {
        var file = init(allocator, inode);
        try file.data.appendSlice(allocator, content);
        return file;
    }

    pub fn deinit(self: *MemoryFile) void {
        self.data.deinit(self.allocator);
    }

    /// Read up to buf.len bytes from a specific offset
    pub fn pread(self: *MemoryFile, buf: []u8, offset: u64) usize {
        const off = @as(usize, @intCast(@min(offset, std.math.maxInt(usize))));
        if (off >= self.data.items.len) {
            return 0;
        }

        const available = self.data.items.len - off;
        const to_read = @min(buf.len, available);

        @memcpy(buf[0..to_read], self.data.items[off..][0..to_read]);
        self.atime = getCurrentTimestamp();

        return to_read;
    }

    /// Write data at a specific offset, growing file if necessary
    pub fn pwrite(self: *MemoryFile, data: []const u8, offset: u64) VfsError!usize {
        if (self.read_only) {
            return error.NotOpenForWriting;
        }

        const off = @as(usize, @intCast(@min(offset, std.math.maxInt(usize))));
        const end_pos = off + data.len;

        // Grow the buffer if needed
        if (end_pos > self.data.items.len) {
            if (off > self.data.items.len) {
                const zeros_needed = off - self.data.items.len;
                self.data.appendNTimes(self.allocator, 0, zeros_needed) catch return error.OutOfMemory;
            }
            self.data.appendSlice(self.allocator, data) catch return error.OutOfMemory;
        } else {
            @memcpy(self.data.items[off..][0..data.len], data);
        }

        const now = getCurrentTimestamp();
        self.mtime = now;
        self.ctime = now;

        return data.len;
    }

    /// Truncate or extend file to specified size
    pub fn truncate(self: *MemoryFile, new_len: u64) VfsError!void {
        if (self.read_only) {
            return error.NotOpenForWriting;
        }

        const new_size = @as(usize, @intCast(@min(new_len, std.math.maxInt(usize))));

        if (new_size < self.data.items.len) {
            self.data.shrinkRetainingCapacity(new_size);
        } else if (new_size > self.data.items.len) {
            const zeros_needed = new_size - self.data.items.len;
            self.data.appendNTimes(self.allocator, 0, zeros_needed) catch return error.OutOfMemory;
        }

        const now = getCurrentTimestamp();
        self.mtime = now;
        self.ctime = now;
    }

    /// Get file statistics
    pub fn stat(self: *const MemoryFile) FileStat {
        return .{
            .dev = 0,
            .ino = self.inode,
            .filetype = .regular_file,
            .nlink = 1,
            .size = @intCast(self.data.items.len),
            .atim = self.atime,
            .mtim = self.mtime,
            .ctim = self.ctime,
        };
    }

    /// Get file size
    pub fn size(self: *const MemoryFile) u64 {
        return @intCast(self.data.items.len);
    }

    /// Get a slice of the file's content (for reading without copying)
    pub fn getContent(self: *const MemoryFile) []const u8 {
        return self.data.items;
    }

    /// Set the entire content of the file
    pub fn setContent(self: *MemoryFile, content: []const u8) VfsError!void {
        if (self.read_only) {
            return error.NotOpenForWriting;
        }

        self.data.clearRetainingCapacity();
        self.data.appendSlice(self.allocator, content) catch return error.OutOfMemory;

        const now = getCurrentTimestamp();
        self.mtime = now;
        self.ctime = now;
    }
};

fn getCurrentTimestamp() u64 {
    // Return nanoseconds since epoch
    const ns = std.time.nanoTimestamp();
    return @as(u64, @intCast(@max(0, ns)));
}

// Tests
test "memory file basic operations" {
    const allocator = std.testing.allocator;

    var file = MemoryFile.init(allocator, 1);
    defer file.deinit();

    // Write some data at offset 0
    const written = try file.pwrite("Hello, World!", 0);
    try std.testing.expectEqual(@as(usize, 13), written);

    // Check size
    try std.testing.expectEqual(@as(u64, 13), file.size());

    // Read it back from offset 0
    var buf: [20]u8 = undefined;
    const read_count = file.pread(&buf, 0);
    try std.testing.expectEqual(@as(usize, 13), read_count);
    try std.testing.expectEqualSlices(u8, "Hello, World!", buf[0..read_count]);
}

test "memory file pread at offset" {
    const allocator = std.testing.allocator;

    var file = try MemoryFile.initWithContent(allocator, 1, "0123456789");
    defer file.deinit();

    // Read from middle
    var buf: [5]u8 = undefined;
    const count = file.pread(&buf, 3);
    try std.testing.expectEqual(@as(usize, 5), count);
    try std.testing.expectEqualSlices(u8, "34567", buf[0..count]);

    // Read from end (partial)
    const count2 = file.pread(&buf, 8);
    try std.testing.expectEqual(@as(usize, 2), count2);
    try std.testing.expectEqualSlices(u8, "89", buf[0..count2]);
}

test "memory file truncate" {
    const allocator = std.testing.allocator;

    var file = try MemoryFile.initWithContent(allocator, 1, "Hello, World!");
    defer file.deinit();

    // Truncate to smaller
    try file.truncate(5);
    try std.testing.expectEqual(@as(u64, 5), file.size());
    try std.testing.expectEqualSlices(u8, "Hello", file.getContent());

    // Extend with zeros
    try file.truncate(8);
    try std.testing.expectEqual(@as(u64, 8), file.size());
    try std.testing.expectEqualSlices(u8, "Hello\x00\x00\x00", file.getContent());
}
