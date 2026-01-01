# Contributing to zig-wasm-cpython

Thank you for your interest in contributing! This document provides guidelines and information for contributors.

## Getting Started

### Prerequisites

1. **Zig 0.15.2 or later** - [Download here](https://ziglang.org/download/)
2. **Python 3.13** - For building CPython WASM (if needed)
3. **WASI SDK 24.0** - For rebuilding CPython (if needed)
4. **Git** - For version control

### Building the Project

```bash
# Clone the repository
git clone <repository-url>
cd zig-wasm-cpython

# Build
zig build

# Run tests
zig build test

# Run with example script
./zig-out/bin/zig_wasm_cpython --script examples/hello.py
```

## Project Structure

```
├── src/
│   ├── main.zig              # Main entry point and orchestration
│   ├── vfs/                  # Virtual filesystem implementation
│   ├── wasi/                 # WASI syscall handlers
│   ├── sockets/              # Socket implementation
│   ├── python/               # Python environment setup
│   └── python_extensions/    # C extension modules
├── examples/                 # Example Python scripts
├── compiled_libs/            # Pre-compiled bytecode libraries
├── docs/                     # Documentation
└── build.zig                 # Build configuration
```

## Areas for Contribution

### 1. WASI Implementation

**Location**: `src/wasi/handlers.zig`

We currently have stubs for many WASI functions. Implementing these would improve compatibility:

- `fd_advise`, `fd_allocate`, `fd_datasync`
- `fd_pread`, `fd_pwrite`
- `path_link`, `path_readlink`, `path_symlink`
- `path_rename`, `path_unlink_file`

**Requirements**:
- Follow existing patterns in handlers.zig
- Add proper error handling
- Include debug logging
- Test with real Python scripts

### 2. Python C Extensions

**Location**: `src/python_extensions/`

Adding more C extensions would expand Python's capabilities:

- **Crypto modules**: hashlib implementations
- **Data formats**: XML, YAML parsers
- **Compression**: zlib, bzip2, lzma
- **Math**: numpy-like operations

**Requirements**:
- Must be compilable with WASI SDK
- Cannot use libffi (not available in WASM)
- Include Setup.local configuration
- Document build instructions

### 3. Performance Optimization

**Areas to investigate**:
- VFS caching for frequently accessed files
- Bytecode library loading optimization
- Memory pool allocation
- WASM memory management

**Process**:
1. Profile with Zig's built-in profiler
2. Identify bottlenecks
3. Propose optimization
4. Benchmark improvements

### 4. Testing

**Location**: Create `tests/` directory

We need:
- Unit tests for VFS operations
- Integration tests for WASI handlers
- Python script test suite
- Performance benchmarks

**Example test structure**:
```zig
test "VFS file creation" {
    var vfs = try VirtualFileSystem.init(std.testing.allocator);
    defer vfs.deinit();
    
    try vfs.createFile("/test.txt", "content");
    const file = try vfs.openFile("/test.txt");
    // assertions...
}
```

### 5. Documentation

**What we need**:
- API documentation for modules
- More usage examples
- Tutorial for adding C extensions
- Architecture deep-dive
- Performance tuning guide

### 6. Bug Fixes

Check the issue tracker for bugs. When fixing:
- Write a test that demonstrates the bug
- Fix the bug
- Ensure the test passes
- Document the fix in commit message

## Code Style

### Zig Code

Follow Zig's standard style:
- Use `zig fmt` before committing
- Meaningful variable names
- Document public functions
- Handle errors explicitly
- Use `defer` for cleanup

Example:
```zig
/// Load a Python script from the host filesystem into VFS
/// Returns error if file cannot be read or VFS operation fails
pub fn loadScript(vfs: *VirtualFileSystem, path: []const u8) !void {
    const content = try std.fs.cwd().readFileAlloc(allocator, path, max_size);
    defer allocator.free(content);
    try vfs.createFile("/script.py", content);
}
```

### Python Code

Follow PEP 8:
- 4 spaces for indentation
- Max line length 88 characters
- Type hints where appropriate
- Docstrings for modules and functions

### Commit Messages

Format:
```
<type>: <short description>

<detailed description if needed>

<footer with issue references>
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation changes
- `refactor`: Code restructuring
- `test`: Adding tests
- `perf`: Performance improvement

Example:
```
feat: Add fd_pwrite WASI implementation

Implements fd_pwrite syscall for positional writes without
changing file offset. Useful for concurrent file access.

Closes #42
```

## Pull Request Process

1. **Fork and Branch**
   ```bash
   git checkout -b feat/my-new-feature
   ```

2. **Make Changes**
   - Write code
   - Add tests
   - Update documentation
   - Run `zig fmt`

3. **Test**
   ```bash
   zig build test
   zig build
   ./zig-out/bin/zig_wasm_cpython --script examples/hello.py
   ```

4. **Commit**
   ```bash
   git add .
   git commit -m "feat: description"
   ```

5. **Push and PR**
   ```bash
   git push origin feat/my-new-feature
   ```
   Create PR on GitHub with:
   - Clear description
   - Related issue numbers
   - Test results
   - Screenshots if UI changes

6. **Review Process**
   - Maintainer reviews code
   - Address feedback
   - Once approved, PR is merged

## Building CPython WASM

If you need to modify the CPython WASM binary (e.g., add C extensions):

See [docs/BUILDING_CPYTHON.md](docs/BUILDING_CPYTHON.md) for detailed instructions.

Quick version:
1. Install WASI SDK 24.0
2. Clone CPython 3.13
3. Add your module to `Modules/Setup.local`
4. Build with provided commands
5. Copy resulting `python.wasm` to `src/examples/python-wasi.wasm`

## Questions?

- Open an issue for questions
- Check existing documentation
- Read the code - it's well-commented!

## Code of Conduct

- Be respectful and constructive
- Welcome newcomers
- Focus on the code, not the person
- Assume good intentions

## License

By contributing, you agree that your contributions will be licensed under the same license as the project (MIT).

Thank you for contributing! 🎉
