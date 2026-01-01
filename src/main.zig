// Python WASM Runtime using zware
//
// This runtime executes CPython compiled to WASI, with support for:
// - In-memory Python scripts via VFS
// - Python standard library passthrough from real filesystem
// - Full WASI compatibility via zware
//
// Usage:
//   zig build && ./zig-out/bin/zig_wasm_cpython
//
// The runtime can execute Python code:
//   1. From command line: python -c "print('hello')"
//   2. From in-memory VFS files: python /app/script.py
//   3. From real filesystem via mount points

const std = @import("std");
const zware = @import("zware");
const builtin = @import("builtin");

// VFS module for in-memory filesystem
const vfs_mod = @import("vfs/vfs.zig");
const VirtualFileSystem = vfs_mod.VirtualFileSystem;
const WasiVfsHooks = vfs_mod.WasiVfsHooks;
const VFS_PREFIX = @import("vfs/filesystem.zig").VFS_PREFIX;

// WASI handlers module
const wasi_handlers = @import("wasi/handlers.zig");

// Socket module
const socket_handlers = @import("sockets/socket_handlers.zig");

// Python modules
const python_env = @import("python/environment.zig");
const stdlib_loader = @import("python/stdlib_loader.zig");

// Debug logging - only prints in debug builds
const debug_enabled = builtin.mode == .Debug;

fn debug_print(comptime fmt: []const u8, args: anytype) void {
    if (debug_enabled) {
        std.debug.print(fmt, args);
    }
}

pub fn main() !void {
    const alloc = std.heap.page_allocator;

    // ========================================================================
    // Parse command-line arguments
    // ========================================================================

    var args = std.process.args();
    _ = args.skip(); // Skip program name

    var script_path: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--script") or std.mem.eql(u8, arg, "-s")) {
            script_path = args.next() orelse {
                std.debug.print("Error: --script requires a file path argument\n", .{});
                std.process.exit(1);
            };
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            std.debug.print(
                \\Usage: zig_wasm_cpython [options]
                \\
                \\Options:
                \\  --script, -s <path>    Run a Python script from the host filesystem
                \\  --help, -h             Show this help message
                \\
                \\If no script is specified, runs the embedded test script.
                \\
            , .{});
            std.process.exit(0);
        } else {
            std.debug.print("Error: Unknown argument: {s}\n", .{arg});
            std.debug.print("Use --help for usage information\n", .{});
            std.process.exit(1);
        }
    }

    // ========================================================================
    // Initialize VFS for in-memory Python scripts
    // ========================================================================

    var vfs = try VirtualFileSystem.init(alloc);
    defer vfs.deinit();

    if (debug_enabled) {
        vfs.setDebug(true);
    }

    // Add VFS root preopen - all VFS content goes under /vfs/
    const vfs_preopen_fd = try vfs.addPreopen("/");
    debug_print("VFS preopen created at fd={}\n", .{vfs_preopen_fd});

    // Load Python standard library into VFS
    const python_lib_path = "/mnt/c/Users/nimbl/Repos_and_Code/cpython-wasi/Lib";
    try stdlib_loader.loadStdlib(vfs, "/usr/local/lib/python3.13", python_lib_path, alloc);

    // Load ALL compiled bytecode libraries into VFS from compiled_libs/
    const compiled_libs_base = "/mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython/compiled_libs";
    debug_print("Loading compiled bytecode libraries from: {s}\n", .{compiled_libs_base});

    // Load impacket
    const impacket_path = compiled_libs_base ++ "/impacket";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/impacket", impacket_path, alloc);
    debug_print("Loaded impacket bytecode library\n", .{});

    // Load mylib (example library)
    const mylib_path = compiled_libs_base ++ "/mylib";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/mylib", mylib_path, alloc);
    debug_print("Loaded mylib bytecode library\n", .{});

    // Load requests and dependencies
    const requests_path = compiled_libs_base ++ "/requests";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/requests", requests_path, alloc);
    debug_print("Loaded requests bytecode library\n", .{});

    const urllib3_path = compiled_libs_base ++ "/urllib3";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/urllib3", urllib3_path, alloc);
    debug_print("Loaded urllib3 bytecode library\n", .{});

    const charset_normalizer_path = compiled_libs_base ++ "/charset_normalizer";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/charset_normalizer", charset_normalizer_path, alloc);
    debug_print("Loaded charset_normalizer bytecode library\n", .{});

    const idna_path = compiled_libs_base ++ "/idna";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/idna", idna_path, alloc);
    debug_print("Loaded idna bytecode library\n", .{});

    const certifi_path = compiled_libs_base ++ "/certifi";
    try stdlib_loader.loadBytecodeLibrary(vfs, "/usr/local/lib/python3.13/site-packages/certifi", certifi_path, alloc);
    debug_print("Loaded certifi bytecode library\n", .{});

    // Load wasisocket Python wrapper module
    const wrapper_script = @embedFile("python_extensions/wasisocket/wasisocket.py");
    try vfs.createFile("/usr/local/lib/python3.13/wasisocket.py", wrapper_script);
    debug_print("Created wasisocket.py wrapper at /vfs/usr/local/lib/python3.13/wasisocket.py\n", .{});

    // Load monkey patches (required for host function interop)
    const socket_patch = @embedFile("python/monkey_patches/socket_patch.py");
    try vfs.createFile("/socket_patch.py", socket_patch);
    debug_print("Loaded socket_patch.py\n", .{});

    // Load zlib stub (zlib not available in WASM)
    const zlib_stub = @embedFile("python/monkey_patches/zlib_stub.py");
    try vfs.createFile("/usr/local/lib/python3.13/zlib.py", zlib_stub);
    debug_print("Loaded zlib stub\n", .{});

    // Load Python script into VFS
    if (script_path) |path| {
        // Load script from host filesystem
        const script_content = std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024) catch |err| {
            std.debug.print("Error: Failed to read script file '{s}': {}\n", .{ path, err });
            std.process.exit(1);
        };
        defer alloc.free(script_content);
        try vfs.createFile("/script.py", script_content);
        debug_print("Loaded script from {s} into /vfs/script.py\n", .{path});
    } else {
        // Load default test script from embedded file
        const test_script = "print('No script specified. Use --script to run a Python script.')";
        try vfs.createFile("/script.py", test_script);
        debug_print("No script specified, using default message\n", .{});
    }

    // Create WASI hooks backed by VFS
    var vfs_hooks = WasiVfsHooks.init(vfs);
    vfs_hooks.setDebug(debug_enabled);

    // Set global VFS for WASI handlers
    wasi_handlers.setVfs(vfs, &vfs_hooks);
    defer wasi_handlers.clearVfs();

    // ========================================================================
    // Load Python WASM and initialize zware
    // ========================================================================

    const python_bytes = @embedFile("./python/python-wasi.wasm");

    var store = zware.Store.init(alloc);
    defer store.deinit();
    try wasi_handlers.addWasiImports(&store);

    // Initialize socket system
    try socket_handlers.init(alloc);
    defer socket_handlers.deinit(alloc);
    try socket_handlers.registerSocketFunctions(&store);
    debug_print("Socket system initialized and functions registered\n", .{});

    var module = zware.Module.init(alloc, python_bytes);
    defer module.deinit();
    try module.decode();

    var instance = zware.Instance.init(alloc, &store, module);
    defer instance.deinit();
    try instance.instantiate();

    // ========================================================================
    // Set up filesystem preopens
    // ========================================================================

    // Register VFS preopen with zware instance
    // The VFS preopen was already created (vfs_preopen_fd), now tell zware about it
    try instance.addWasiPreopen(@intCast(vfs_preopen_fd), VFS_PREFIX, 0);
    debug_print("Added preopen: fd={}, path={s} (VFS-backed)\n", .{ vfs_preopen_fd, VFS_PREFIX });

    // ========================================================================
    // Configure Python environment and arguments
    // ========================================================================

    // Setup environment variables
    const py_config = python_env.defaultConfig();
    try python_env.setupEnvironment(&instance, py_config, alloc);
    debug_print("Set {} environment variables\n", .{instance.wasi_env.count()});

    // Setup minimal command-line arguments (required by Python initialization)
    const cmd_config = python_env.CommandConfig{
        .mode = .interactive,
        .args = &[_][]const u8{},
    };
    try python_env.setupArguments(&instance, cmd_config, alloc);
    debug_print("Set argv: python\n", .{});

    // ========================================================================
    // Initialize Python using C API
    // ========================================================================

    const memory = try instance.getMemory(0);
    const mem_data = memory.memory();
    debug_print("Memory size: {} bytes ({} pages)\n", .{ mem_data.len, mem_data.len / 65536 });

    debug_print("Initializing Python interpreter via C API...\n", .{});

    // Call Py_Initialize() to start the interpreter
    var init_in = [_]u64{};
    var init_out = [_]u64{};
    try instance.invoke("Py_Initialize", init_in[0..], init_out[0..], .{
        .frame_stack_size = 8192,
        .label_stack_size = 8192,
        .operand_stack_size = 8192,
    });
    debug_print("Python interpreter initialized\n", .{});

    // ========================================================================
    // Run monkey patches first
    // ========================================================================

    debug_print("Applying monkey patches...\n", .{});

    // Run socket patch
    const socket_patch_code = "exec(open('/vfs/socket_patch.py').read())";
    const socket_patch_ptr = try allocateString(&instance, socket_patch_code);

    var patch_in = [_]u64{socket_patch_ptr};
    var patch_out = [_]u64{0};
    try instance.invoke("PyRun_SimpleString", patch_in[0..], patch_out[0..], .{
        .frame_stack_size = 8192,
        .label_stack_size = 8192,
        .operand_stack_size = 8192,
    });

    if (patch_out[0] != 0) {
        debug_print("Warning: Socket patch returned error code: {}\n", .{patch_out[0]});
    } else {
        debug_print("Socket patch applied successfully\n", .{});
    }

    // ========================================================================
    // Run main script
    // ========================================================================

    debug_print("Running main script...\n", .{});

    const main_script_code = "exec(open('/vfs/script.py').read())";
    const main_script_ptr = try allocateString(&instance, main_script_code);

    var main_in = [_]u64{main_script_ptr};
    var main_out = [_]u64{0};
    try instance.invoke("PyRun_SimpleString", main_in[0..], main_out[0..], .{
        .frame_stack_size = 8192,
        .label_stack_size = 8192,
        .operand_stack_size = 8192,
    });

    if (main_out[0] != 0) {
        debug_print("Main script returned error code: {}\n", .{main_out[0]});
    } else {
        debug_print("Main script completed successfully\n", .{});
    }

    // ========================================================================
    // Finalize Python
    // ========================================================================

    debug_print("Finalizing Python interpreter...\n", .{});
    var fin_in = [_]u64{};
    var fin_out = [_]u64{};
    try instance.invoke("Py_Finalize", fin_in[0..], fin_out[0..], .{
        .frame_stack_size = 8192,
        .label_stack_size = 8192,
        .operand_stack_size = 8192,
    });
    debug_print("Python interpreter finalized\n", .{});
}

// Helper function to allocate a string in WASM memory and return its pointer
fn allocateString(instance: *zware.Instance, str: []const u8) !u64 {
    const memory = try instance.getMemory(0);
    const mem_data = memory.memory();

    // Find a safe place in memory to write the string
    // We'll use a simple approach: write at a high address
    // In a production system, you'd want proper memory allocation
    const offset: u32 = 1024 * 1024; // 1MB offset

    if (offset + str.len >= mem_data.len) {
        return error.OutOfMemory;
    }

    // Copy string to WASM memory
    @memcpy(mem_data[offset..][0..str.len], str);
    // Null-terminate
    mem_data[offset + str.len] = 0;

    return offset;
}
