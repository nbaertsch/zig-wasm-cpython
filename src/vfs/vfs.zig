// Virtual File System for WASM Python
//
// This VFS provides a complete in-memory filesystem that can be transparently
// presented to WASI programs. It supports:
// - In-memory files and directories
// - Mounting real filesystem directories (passthrough)
// - File descriptor management
// - All standard filesystem operations (open, read, write, seek, stat, etc.)
//
// Usage:
//   var vfs = try VirtualFileSystem.init(allocator);
//   defer vfs.deinit();
//
//   // Create in-memory file
//   try vfs.createFile("/app/script.py", "print('hello')");
//
//   // Mount real directory
//   try vfs.mount("/lib", "/usr/local/lib/python3.13");
//
//   // Use in WASI hooks - VFS intercepts all filesystem operations

const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const StringHashMap = std.StringHashMap;
const AutoHashMap = std.AutoHashMap;

const wasi = std.os.wasi;

/// Represents a file type in the VFS
pub const FileType = enum {
    regular_file,
    directory,
    symbolic_link,

    pub fn toWasi(self: FileType) wasi.filetype_t {
        return switch (self) {
            .regular_file => .REGULAR_FILE,
            .directory => .DIRECTORY,
            .symbolic_link => .SYMBOLIC_LINK,
        };
    }
};

/// File statistics matching WASI filestat structure
pub const FileStat = struct {
    dev: u64 = 0,
    ino: u64 = 0,
    filetype: FileType,
    nlink: u64 = 1,
    size: u64 = 0,
    atim: u64 = 0,
    mtim: u64 = 0,
    ctim: u64 = 0,
};

/// Open flags for file operations
pub const OpenFlags = struct {
    read: bool = false,
    write: bool = false,
    append: bool = false,
    create: bool = false,
    exclusive: bool = false,
    truncate: bool = false,
    directory: bool = false,

    pub fn fromWasi(oflags: wasi.oflags_t, rights: wasi.rights_t) OpenFlags {
        return .{
            .read = rights.FD_READ,
            .write = rights.FD_WRITE,
            .append = false, // handled via fdflags
            .create = oflags.CREAT,
            .exclusive = oflags.EXCL,
            .truncate = oflags.TRUNC,
            .directory = oflags.DIRECTORY,
        };
    }
};

/// Seek origin for file positioning
pub const SeekWhence = enum {
    set,
    cur,
    end,

    pub fn fromWasi(whence: wasi.whence_t) SeekWhence {
        return switch (whence) {
            .SET => .set,
            .CUR => .cur,
            .END => .end,
        };
    }
};

/// Directory entry for readdir operations
pub const DirEntry = struct {
    name: []const u8,
    filetype: FileType,
    inode: u64,
};

/// Error types for VFS operations
pub const VfsError = error{
    FileNotFound,
    NotADirectory,
    IsADirectory,
    FileExists,
    InvalidPath,
    PermissionDenied,
    NotOpenForReading,
    NotOpenForWriting,
    InvalidSeek,
    OutOfMemory,
    BadFileDescriptor,
    TooManyOpenFiles,
    NameTooLong,
    NoSpace,
    NotEmpty,
    InvalidArgument,
    IO,
};

/// Convert VFS error to WASI errno
pub fn toWasiErrno(err: VfsError) wasi.errno_t {
    return switch (err) {
        error.FileNotFound => .NOENT,
        error.NotADirectory => .NOTDIR,
        error.IsADirectory => .ISDIR,
        error.FileExists => .EXIST,
        error.InvalidPath => .INVAL,
        error.PermissionDenied => .ACCES,
        error.NotOpenForReading => .BADF,
        error.NotOpenForWriting => .BADF,
        error.InvalidSeek => .INVAL,
        error.OutOfMemory => .NOMEM,
        error.BadFileDescriptor => .BADF,
        error.TooManyOpenFiles => .NFILE,
        error.NameTooLong => .NAMETOOLONG,
        error.NoSpace => .NOSPC,
        error.NotEmpty => .NOTEMPTY,
        error.InvalidArgument => .INVAL,
        error.IO => .IO,
    };
}

// Re-export submodules
pub const MemoryFile = @import("memory_file.zig").MemoryFile;
pub const MemoryDirectory = @import("memory_directory.zig").MemoryDirectory;
pub const FileDescriptor = @import("fd_table.zig").FileDescriptor;
pub const FdTable = @import("fd_table.zig").FdTable;
pub const VirtualFileSystem = @import("filesystem.zig").VirtualFileSystem;
pub const WasiVfsHooks = @import("wasi_hooks.zig").WasiVfsHooks;
pub const WasiResult = @import("wasi_hooks.zig").WasiResult;

test "vfs module compiles" {
    _ = MemoryFile;
    _ = MemoryDirectory;
    _ = FileDescriptor;
    _ = FdTable;
    _ = VirtualFileSystem;
    _ = WasiVfsHooks;
}
