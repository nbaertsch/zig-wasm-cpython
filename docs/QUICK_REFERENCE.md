# zig-wasm-cpython Quick Reference

## Build & Run

```bash
# Build (debug)
zig build

# Build (optimized)
zig build -Doptimize=ReleaseFast

# Run default test
./zig-out/bin/zig_wasm_cpython

# Run custom script
./zig-out/bin/zig_wasm_cpython --script path/to/script.py

# Show help
./zig-out/bin/zig_wasm_cpython --help
```

## Project Structure

```
src/
├── main.zig                 # Entry point, CLI handling
├── vfs/                     # Virtual file system
│   ├── vfs.zig             # Core VFS implementation
│   ├── filesystem.zig      # File/directory operations
│   ├── fd_table.zig        # File descriptor management
│   └── wasi_hooks.zig      # WASI integration
├── wasi/                    # WASI syscall handlers
│   ├── handlers.zig        # fd_*, path_* implementations
│   └── hooks.zig           # Hook utilities
├── sockets/                 # Socket support
│   ├── socket.zig          # Socket abstraction
│   └── socket_handlers.zig # Socket WASI integration
└── python/                  # Python environment
    ├── environment.zig     # Env vars, argv setup
    ├── stdlib_loader.zig   # Load Python stdlib into VFS
    └── monkey_patches/     # Runtime patches
```

## Key Features

| Feature | Status | Location |
|---------|--------|----------|
| In-memory VFS | ✅ Working | `src/vfs/` |
| Python 3.13 | ✅ Working | `src/examples/python-wasi.wasm` |
| Standard Library | ✅ Working | Loaded into VFS at runtime |
| Socket I/O | ✅ Working | `src/sockets/` + `_wasisocket` |
| Bytecode Libraries | ✅ Working | `compiled_libs/` |
| CLI Arguments | ✅ Working | `src/main.zig` |

## Python Script Examples

### Hello World
```python
print("Hello from Python in WASM!")
```

### Using JSON
```python
import json
data = {"message": "Hello", "status": "working"}
print(json.dumps(data, indent=2))
```

### Socket Example
```python
import socket
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("example.com", 80))
s.send(b"GET / HTTP/1.0\r\n\r\n")
response = s.recv(4096)
s.close()
print(response.decode())
```

### File Operations (VFS)
```python
# Write to VFS
with open("/vfs/data.txt", "w") as f:
    f.write("Hello VFS!")

# Read from VFS
with open("/vfs/data.txt", "r") as f:
    print(f.read())
```

## Building CPython WASM

If you need to rebuild the Python WASM binary:

```bash
# Prerequisites
export WASI_SDK=/path/to/wasi-sdk-24.0

# Clone CPython
git clone https://github.com/python/cpython
cd cpython
git checkout v3.13.1

# Add your C extensions to Modules/Setup.local
# See docs/BUILDING_CPYTHON.md for details

# Configure
./configure \
  --host=wasm32-wasi \
  --build=x86_64-linux-gnu \
  --with-build-python=python3 \
  --disable-test-modules \
  CC="$WASI_SDK/bin/clang --sysroot=$WASI_SDK/share/wasi-sysroot"

# Build
make

# Copy binary
cp python.wasm /path/to/zig-wasm-cpython/src/examples/python-wasi.wasm
```

## Compiling Bytecode Libraries

```bash
# Compile a Python package to bytecode
python3 compile_library.py /path/to/package output_dir

# The compiled library will be in output_dir/
# Copy it to compiled_libs/ to include in the runtime
```

## Development Workflow

```bash
# 1. Make changes to Zig code
vim src/main.zig

# 2. Build
zig build

# 3. Test with example
./zig-out/bin/zig_wasm_cpython --script examples/hello.py

# 4. Debug build for more info
zig build -Doptimize=Debug
# This enables debug logging in VFS and WASI handlers
```

## Limitations

- ❌ No ctypes/FFI (libffi doesn't compile to WASM)
- ❌ Limited threading (WASI limitation)
- ❌ No dynamic C extension loading
- ⚠️ C extensions must be compiled into python.wasm

## Key Dependencies

```zig
// build.zig.zon
.{
    .name = "zig_wasm_cpython",
    .version = "1.0.0",
    .dependencies = .{
        .zware = .{
            .url = "...",  // WebAssembly runtime
        },
    },
}
```

## Environment Variables

The runtime sets these automatically:

```bash
PYTHONHOME=/usr/local
PYTHONPATH=/usr/local/lib/python3.13:/usr/local/lib/python3.13/site-packages
PYTHONIOENCODING=utf-8
LANG=en_US.UTF-8
```

## Debugging

```bash
# Enable debug mode
zig build -Doptimize=Debug

# Run with debug output
./zig-out/bin/zig_wasm_cpython --script test.py

# Debug output includes:
# - VFS operations: [VFS] createFile, openFile, etc.
# - WASI calls: fd_read, fd_write, path_open, etc.
# - Python initialization steps
# - Memory usage stats
```

## Common Issues

### "Module not found"
- Ensure module is in Python stdlib
- Check if module needs C extension
- Verify VFS loaded stdlib correctly

### "Socket error"
- Ensure network access is allowed
- Check socket_patch.py is loaded
- Verify _wasisocket module is available

### "Out of memory"
- WASM has limited memory (2GB max)
- Optimize script to use less memory
- Consider splitting large operations

## Performance Tips

1. **Use bytecode libraries** - Faster loading
2. **Minimize stdlib loading** - Only load needed modules
3. **Optimize flag** - Use `-Doptimize=ReleaseFast`
4. **VFS caching** - Files stay in memory
5. **Batch operations** - Reduce WASI call overhead

## Resources

- [Full README](../README.md)
- [Building CPython](BUILDING_CPYTHON.md)
- [Socket API](SOCKET_API.md)
- [Bytecode Libraries](BYTECODE_LIBRARY_FEATURE.md)
- [Contributing](../CONTRIBUTING.md)
