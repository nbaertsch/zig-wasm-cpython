// Python Environment Configuration
//
// This module handles setting up Python's environment variables and
// command-line arguments for execution in the WASM environment.

const std = @import("std");
const zware = @import("zware");

pub const PythonConfig = struct {
    python_home: []const u8 = "/vfs/usr/local",           // Python home directory (PYTHONHOME)
    python_path: []const u8 = "/vfs/usr/local/lib/python3.13", // Python path for stdlib (PYTHONPATH)
    locale: []const u8 = "C.UTF-8",                       // Locale settings
    io_encoding: []const u8 = "utf-8",                    // IO encoding
    utf8_mode: bool = true,                               // Enable UTF-8 mode
    coerce_locale: bool = false,                          // Disable locale coercion
    frozen_modules: []const u8 = "on",                    // Frozen modules setting
};

/// Configure Python environment variables in the zware instance
pub fn setupEnvironment(
    instance: *zware.Instance,
    config: PythonConfig,
    allocator: std.mem.Allocator,
) !void {
    try instance.wasi_env.put(allocator, "PYTHONHOME", config.python_home);
    try instance.wasi_env.put(allocator, "PYTHONPATH", config.python_path);
    try instance.wasi_env.put(allocator, "LC_ALL", config.locale);
    try instance.wasi_env.put(allocator, "LC_CTYPE", config.locale);
    try instance.wasi_env.put(allocator, "LANG", config.locale);
    try instance.wasi_env.put(allocator, "PYTHONIOENCODING", config.io_encoding);
    try instance.wasi_env.put(allocator, "PYTHONUTF8", if (config.utf8_mode) "1" else "0");
    try instance.wasi_env.put(allocator, "PYTHONCOERCECLOCALE", if (config.coerce_locale) "1" else "0");
    try instance.wasi_env.put(allocator, "PYTHON_FROZEN_MODULES", config.frozen_modules);
}

/// Python command configuration
pub const CommandConfig = struct {
    /// Type of Python command to execute
    mode: union(enum) {
        /// Execute a script file from VFS or real filesystem
        script: []const u8,
        /// Execute Python code directly from command line
        command: []const u8,
        /// Run Python's interactive REPL
        interactive,
    },

    /// Additional arguments to pass to the Python script
    args: []const []const u8 = &.{},
};

/// Setup Python command-line arguments (argv) in the zware instance
pub fn setupArguments(
    instance: *zware.Instance,
    config: CommandConfig,
    allocator: std.mem.Allocator,
) !void {
    instance.wasi_args.clearRetainingCapacity();

    // First argument is always the program name
    const python_name = try allocator.dupeZ(u8, "python");
    try instance.wasi_args.append(allocator, python_name);

    // Add mode-specific arguments
    switch (config.mode) {
        .script => |script_path| {
            const path = try allocator.dupeZ(u8, script_path);
            try instance.wasi_args.append(allocator, path);
        },
        .command => |code| {
            const c_flag = try allocator.dupeZ(u8, "-c");
            try instance.wasi_args.append(allocator, c_flag);
            const code_arg = try allocator.dupeZ(u8, code);
            try instance.wasi_args.append(allocator, code_arg);
        },
        .interactive => {
            // No additional flags needed for interactive mode
        },
    }

    // Add any additional arguments
    for (config.args) |arg| {
        const arg_z = try allocator.dupeZ(u8, arg);
        try instance.wasi_args.append(allocator, arg_z);
    }
}

/// Default Python configuration for VFS-based execution
pub fn defaultConfig() PythonConfig {
    return .{};
}

/// Create a script execution command
pub fn scriptCommand(script_path: []const u8) CommandConfig {
    return .{
        .mode = .{ .script = script_path },
    };
}

/// Create a command-line code execution command
pub fn codeCommand(code: []const u8) CommandConfig {
    return .{
        .mode = .{ .command = code },
    };
}

/// Create an interactive REPL command
pub fn interactiveCommand() CommandConfig {
    return .{
        .mode = .interactive,
    };
}
