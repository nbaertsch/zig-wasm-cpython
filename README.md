# zig-wasm-cpython

A runtime for executing CPython compiled to WebAssembly/WASI with an in-memory virtual filesystem and socket support.

## Features

- **In-Memory VFS**: Run Python scripts from memory without touching the filesystem
- **Python Standard Library**: Full access to Python's standard library via VFS
- **Socket Support**: Custom WASI socket implementation for network I/O
- **HTTP Requests**: Full support for `requests` library with HTTP (HTTPS requires TLS)
- **Bytecode Libraries**: Support for pre-compiled Python bytecode packages (e.g., requests, urllib3, impacket)
- **Command-line Interface**: Run arbitrary Python scripts with a simple CLI

## Quick Start

### Prerequisites

- Zig 0.15.2 or later
- CPython WASM binary (included: `src/examples/python-wasi.wasm`)

### Building

```bash
zig build
```

### Running

Run the default test script:
```bash
./zig-out/bin/zig_wasm_cpython
```

Run your own Python script:
```bash
./zig-out/bin/zig_wasm_cpython --script path/to/your/script.py
```

For optimized builds:
```bash
zig build -Doptimize=ReleaseFast
./zig-out/bin/zig_wasm_cpython --script your_script.py
```

### Command-line Options

- `--script, -s <path>` - Run a Python script from the host filesystem
- `--help, -h` - Show help message

## Architecture

### Components

1. **VFS (Virtual File System)** - In-memory filesystem for Python scripts and libraries
   - Located in `src/vfs/`
   - Supports files, directories, and passthrough to real filesystem
   - WASI-compatible interface

2. **WASI Handlers** - WebAssembly System Interface implementations
   - Located in `src/wasi/`
   - Bridges between zware runtime and VFS
   - Full `fd_*` and `path_*` function support

3. **Socket Support** - Network I/O for Python
   - Located in `src/sockets/`
   - Custom WASI socket implementation
   - Python extension module `_wasisocket`

4. **Python Environment** - Configuration and initialization
   - Located in `src/python/`
   - Environment variable setup
   - Standard library loader
   - Bytecode library support

### How It Works

1. **Initialization**: VFS is created and populated with Python stdlib and custom scripts
2. **WASM Loading**: CPython WASM binary is loaded via zware
3. **Environment Setup**: Python paths and environment variables are configured
4. **Execution**: Python interpreter is initialized and runs the target script
5. **Cleanup**: Resources are freed and Python is finalized

## Python Support

### Standard Library

The runtime includes Python 3.13's standard library, loaded into VFS from the host CPython installation.

### Bytecode Libraries

Pre-compiled Python bytecode libraries can be included for faster loading and reduced memory footprint. The included example demonstrates impacket support.

To compile your own bytecode libraries:
```bash
python3 compile_library.py path/to/package output_dir
```

### Socket Programming

Network I/O is supported through a custom `_wasisocket` C extension module. Example:

```python
import socket

# Standard Python socket API works!
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.connect(("example.com", 80))
s.send(b"GET / HTTP/1.0\r\nHost: example.com\r\n\r\n")
response = s.recv(4096)
s.close()
```

### HTTP Requests Library

The popular `requests` library is fully supported for HTTP operations:

```python
import requests

# HTTP GET (disable compression since zlib not available)
headers = {'Accept-Encoding': 'identity'}
response = requests.get('http://example.com', headers=headers, timeout=10)
print(response.text)

# HTTP POST with JSON
payload = {'message': 'Hello from WASM!'}
response = requests.post('http://httpbin.org/post', json=payload, headers=headers)
print(response.json())
```

**Note**: HTTPS is not yet supported as it requires TLS implementation in WASI. Compression (gzip/deflate) is disabled as zlib is not available in WASM.

## Use Cases

- **Embedded Python Execution**: Run Python in WASM environments
- **Sandboxed Python**: Execute untrusted Python code safely
- **Network Tool Development**: Build Python-based network utilities
- **Testing**: Test Python code in isolated environments
- **Cross-platform**: Run Python anywhere zig is supported

## Documentation

- [Building CPython WASM](docs/BUILDING_CPYTHON.md) - How to build the CPython WASM binary
- [Socket API](docs/SOCKET_API.md) - Details on socket implementation
- [Bytecode Libraries](docs/BYTECODE_LIBRARY_FEATURE.md) - How to use pre-compiled bytecode
- [Architecture Details](docs/REORGANIZATION.md) - Deep dive into code organization
- [Development Notes](docs/HANDOFF.md) - Historical development information

## Project Structure

```
├── src/
│   ├── main.zig                      # Entry point and orchestration
│   ├── examples/
│   │   ├── python-wasi.wasm          # CPython WASM binary
│   │   └── python/                   # Example Python scripts
│   ├── vfs/                          # Virtual filesystem
│   ├── wasi/                         # WASI handlers
│   ├── sockets/                      # Socket implementation
│   ├── python/                       # Python environment setup
│   └── python_extensions/            # C extension modules
├── compiled_libs/                    # Pre-compiled bytecode libraries
├── python_libs/                      # Source Python libraries
├── docs/                            # Documentation
├── build.zig                        # Build configuration
└── README.md                        # This file
```

## Dependencies

- [zware](https://github.com/sissbruecker/zware) - WebAssembly runtime for Zig
- CPython 3.13 compiled to WASI (included)

## Building CPython WASM

If you need to rebuild the CPython WASM binary (e.g., to add more C extensions), see [docs/BUILDING_CPYTHON.md](docs/BUILDING_CPYTHON.md).

## Limitations

- **No HTTPS/TLS**: HTTPS is not supported as WASI lacks TLS support
- **No compression**: zlib is not available, so gzip/deflate compression is disabled  
- **No ctypes/FFI**: libffi cannot be compiled to WASM/WASI, so ctypes is not available
- **Limited threading**: WASI has limited threading support
- **No dynamic loading**: C extensions must be compiled into the WASM binary

## Contributing

Contributions are welcome! Areas for improvement:

- Additional WASI syscall implementations
- Performance optimizations
- More Python C extensions
- Better error handling
- Documentation improvements

## License

This project builds upon:
- CPython (Python Software Foundation License)
- zware (MIT License)
- WASI SDK (Apache License 2.0)

See individual components for their respective licenses.

## Acknowledgments

- [zware](https://github.com/sissbruecker/zware) by @sissbruecker for the excellent WASM runtime
- CPython team for WASI support
- WebAssembly/WASI community

## Status

**Production Ready** - Core features are stable and tested:
- ✅ VFS and file operations
- ✅ Python standard library
- ✅ Socket I/O
- ✅ Bytecode library loading
- ✅ Command-line interface

**Known Working**:
- JSON parsing and manipulation
- Network requests (HTTP, raw TCP)
- File I/O (via VFS)
- Complex libraries like impacket

## Example Scripts

See `src/examples/python/` for example scripts including:
- `test_modules.py` - Standard library imports
- `test_wasisocket.py` - Socket programming
- `test_impacket.py` - Network protocol library usage
