// Python Standard Library Loader
//
// This module handles loading Python's standard library from the filesystem
// into the in-memory VFS. It filters out unnecessary files (tests, caches, etc.)
// to minimize memory usage while keeping essential functionality.

const std = @import("std");
const VirtualFileSystem = @import("../vfs/vfs.zig").VirtualFileSystem;
const builtin = @import("builtin");

const debug_enabled = builtin.mode == .Debug;

fn debug_print(comptime fmt: []const u8, args: anytype) void {
    if (debug_enabled) {
        std.debug.print(fmt, args);
    }
}

/// Recursively load a directory tree into VFS
/// Filters out test directories, caches, and non-essential files to save memory
pub fn loadDirectoryIntoVFS(
    vfs: *VirtualFileSystem,
    vfs_base_path: []const u8,
    real_dir_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var dir = try std.fs.openDirAbsolute(real_dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var file_count: usize = 0;
    var dir_count: usize = 0;

    while (try iter.next()) |entry| {
        const vfs_entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ vfs_base_path, entry.name });
        defer allocator.free(vfs_entry_path);

        const real_entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ real_dir_path, entry.name });
        defer allocator.free(real_entry_path);

        switch (entry.kind) {
            .directory => {
                // Skip common cache/build directories to save memory
                if (shouldSkipDirectory(entry.name)) {
                    continue;
                }

                dir_count += 1;
                try vfs.mkdirp(vfs_entry_path);
                // Recursively load subdirectory
                try loadDirectoryIntoVFS(vfs, vfs_entry_path, real_entry_path, allocator);
            },
            .file => {
                // Only load Python files and essential files
                if (shouldLoadFile(entry.name)) {
                    const file = try std.fs.openFileAbsolute(real_entry_path, .{});
                    defer file.close();

                    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // Max 10MB per file
                    defer allocator.free(content);

                    try vfs.createFile(vfs_entry_path, content);
                    file_count += 1;
                }
            },
            else => {},
        }
    }

    if (file_count > 0 or dir_count > 0) {
        debug_print("  Loaded: {s} ({} files, {} dirs)\n", .{ vfs_base_path, file_count, dir_count });
    }
}

/// Determine if a directory should be skipped to save memory
fn shouldSkipDirectory(name: []const u8) bool {
    const skip_dirs = [_][]const u8{
        "__pycache__", // Python bytecode cache
        ".git", // Version control
        "test", // Test directories
        "tests",
        "ensurepip", // Package installers
        "idlelib", // IDE components
        "tkinter", // GUI toolkit
        "turtle", // Graphics library
        "turtledemo",
        ".pytest_cache", // Pytest cache
        ".mypy_cache", // Type checker cache
        "node_modules", // JavaScript dependencies (shouldn't be here, but just in case)
    };

    for (skip_dirs) |skip| {
        if (std.mem.eql(u8, name, skip)) {
            return true;
        }
    }
    return false;
}

/// Determine if a file should be loaded into VFS
fn shouldLoadFile(name: []const u8) bool {
    // Load Python source and bytecode files
    if (std.mem.endsWith(u8, name, ".py") or
        std.mem.endsWith(u8, name, ".pyc") or
        std.mem.eql(u8, name, "__init__.py"))
    {
        return true;
    }

    // Skip everything else to save memory
    return false;
}

/// Load a compiled bytecode library into VFS
/// This function loads ONLY pre-compiled .pyc files from __pycache__ directories
/// Python will use these bytecode files directly without requiring source .py files
pub fn loadBytecodeLibrary(
    vfs: *VirtualFileSystem,
    vfs_library_path: []const u8,
    real_bytecode_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    debug_print("Loading bytecode library into VFS...\n", .{});
    debug_print("  Source: {s}\n", .{real_bytecode_path});
    debug_print("  Target: {s}\n", .{vfs_library_path});

    // Ensure target directory exists
    try vfs.mkdirp(vfs_library_path);

    // Recursively load all .pyc files from __pycache__ directories
    try loadBytecodeDirectoryIntoVFS(vfs, vfs_library_path, real_bytecode_path, allocator);

    debug_print("Bytecode library loaded: {s}\n", .{vfs_library_path});
}

/// Recursively load bytecode files from __pycache__ directories
fn loadBytecodeDirectoryIntoVFS(
    vfs: *VirtualFileSystem,
    vfs_base_path: []const u8,
    real_dir_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    var dir = try std.fs.openDirAbsolute(real_dir_path, .{ .iterate = true });
    defer dir.close();

    var iter = dir.iterate();
    var file_count: usize = 0;

    while (try iter.next()) |entry| {
        const vfs_entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ vfs_base_path, entry.name });
        defer allocator.free(vfs_entry_path);

        const real_entry_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ real_dir_path, entry.name });
        defer allocator.free(real_entry_path);

        switch (entry.kind) {
            .directory => {
                // Skip __pycache__ directories (we load .pyc files from package root)
                if (std.mem.eql(u8, entry.name, "__pycache__")) {
                    continue;
                }
                // Create directory in VFS
                try vfs.mkdirp(vfs_entry_path);
                // Recursively load subdirectory
                try loadBytecodeDirectoryIntoVFS(vfs, vfs_entry_path, real_entry_path, allocator);
            },
            .file => {
                // Only load .pyc files and MANIFEST.txt
                if (std.mem.endsWith(u8, entry.name, ".pyc") or
                    std.mem.eql(u8, entry.name, "MANIFEST.txt"))
                {
                    const file = try std.fs.openFileAbsolute(real_entry_path, .{});
                    defer file.close();

                    const content = try file.readToEndAlloc(allocator, 10 * 1024 * 1024); // Max 10MB
                    defer allocator.free(content);

                    try vfs.createFile(vfs_entry_path, content);
                    file_count += 1;

                    debug_print("  Loaded bytecode: {s}\n", .{entry.name});
                }
            },
            else => {},
        }
    }

    if (file_count > 0) {
        debug_print("  Loaded {s}: {} bytecode files\n", .{ vfs_base_path, file_count });
    }
}

/// Load Python standard library into VFS
/// This is the main entry point for loading the stdlib
pub fn loadStdlib(
    vfs: *VirtualFileSystem,
    vfs_stdlib_path: []const u8,
    real_stdlib_path: []const u8,
    allocator: std.mem.Allocator,
) !void {
    debug_print("Loading Python stdlib into VFS (minimal subset)...\n", .{});
    debug_print("  Source: {s}\n", .{real_stdlib_path});
    debug_print("  Target: {s}\n", .{vfs_stdlib_path});

    try loadDirectoryIntoVFS(vfs, vfs_stdlib_path, real_stdlib_path, allocator);

    debug_print("Python stdlib loaded successfully\n", .{});
}
