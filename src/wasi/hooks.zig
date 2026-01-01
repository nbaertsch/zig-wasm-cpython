// Generic WASI Hook System
//
// This module provides utilities for wrapping WASI function calls with
// debug logging and standardized error handling patterns.

const std = @import("std");
const zware = @import("zware");
const builtin = @import("builtin");

const debug_enabled = builtin.mode == .Debug;

/// Generic wrapper for WASI calls that adds debug logging
/// This provides a unified way to hook all WASI calls with debug printing
pub fn WasiHook(comptime name: []const u8, comptime Impl: type) type {
    return struct {
        pub fn wrapper(vm: *zware.VirtualMachine, user_data: usize) zware.WasmError!void {
            if (debug_enabled) {
                std.debug.print("[WASI] {s}", .{name});
            }

            // Call the actual implementation
            try Impl.call(vm, user_data);

            if (debug_enabled) {
                std.debug.print("\n", .{});
            }
        }
    };
}

/// Create a stub implementation that returns success (errno 0)
pub fn makeStub(comptime name: []const u8) fn (*zware.VirtualMachine, usize) zware.WasmError!void {
    return WasiHook(name, struct {
        pub fn call(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            try vm.pushOperand(u32, 0);
        }
    }).wrapper;
}

/// Helper to create a zware passthrough wrapper with debug logging
pub fn makeZwarePassthrough(comptime name: []const u8, comptime zware_fn: anytype) fn (*zware.VirtualMachine, usize) zware.WasmError!void {
    return WasiHook(name, struct {
        pub fn call(vm: *zware.VirtualMachine, _: usize) zware.WasmError!void {
            try zware_fn(vm);
        }
    }).wrapper;
}

/// Debug print function - only prints in debug builds
pub fn debug_print(comptime fmt: []const u8, args: anytype) void {
    if (debug_enabled) {
        std.debug.print(fmt, args);
    }
}
