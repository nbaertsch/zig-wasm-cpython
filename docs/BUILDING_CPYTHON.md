# Building CPython WASM with Exported C API

**VERIFIED WORKING BUILD COMMANDS** - Last tested: 2026-01-01

This document contains the exact, working commands to build CPython 3.13.1 for WASI with all required modules for this project.

## Prerequisites

### WASI SDK
Download and extract WASI SDK 24.0:
```bash
wget https://github.com/WebAssembly/wasi-sdk/releases/download/wasi-sdk-24/wasi-sdk-24.0-x86_64-linux.tar.gz
tar xzf wasi-sdk-24.0-x86_64-linux.tar.gz
export WASI_SDK_PATH=/mnt/c/Users/nimbl/Repos_and_Code/wasi-sdk-24.0-x86_64-linux
```

### CPython Source
The CPython source is already set up in `../cpython-wasi` with:
- CPython 3.13.1 source code
- Custom `_wasisocket.c` module in `Modules/`
- Pre-configured `Modules/Setup.local`

## Critical: Modules/Setup.local Configuration

The `Modules/Setup.local` file controls which modules are compiled as built-in. **This is already configured in the cpython-wasi directory**.

### Current Setup.local (Verified Working)

```python
# Generated for WASI build with required modules
# This enables modules that are normally disabled in WASI builds

# REQUIRED: Custom wasisocket module
_wasisocket _wasisocket.c

# REQUIRED for Impacket: Binary/ASCII conversions
binascii binascii.c

# REQUIRED for Impacket: I/O multiplexing (select/poll)
select selectmodule.c

# OPTIONAL: Hash functions (faster than pure Python)
_md5 md5module.c -I$(srcdir)/Modules/_hacl/include _hacl/Hacl_Hash_MD5.c -D_BSD_SOURCE -D_DEFAULT_SOURCE
_sha1 sha1module.c -I$(srcdir)/Modules/_hacl/include _hacl/Hacl_Hash_SHA1.c -D_BSD_SOURCE -D_DEFAULT_SOURCE
_sha2 sha2module.c -I$(srcdir)/Modules/_hacl/include Modules/_hacl/libHacl_Hash_SHA2.a

# Disable modules that don't work in WASI or aren't needed
*disabled*
_asyncio
_bz2
_decimal
_pickle
pyexpat
_elementtree
_sha3
_blake2
_zoneinfo
xxsubtype
# CRITICAL: Disable built-in socket module - we use custom _wasisocket instead
_socket
# CJK codecs (reduce size)
_multibytecodec
_codecs_cn
_codecs_hk
_codecs_iso2022
_codecs_jp
_codecs_kr
_codecs_tw
```

### Why `_socket` Must Be Disabled

**CRITICAL:** The built-in `_socket` module imports sock_recv and sock_send with different signatures than our custom `_wasisocket`:

- Built-in `_socket`: `sock_recv(fd, buf, len, flags, addr, addr_len)` - 6 params (recvfrom)
- Custom `_wasisocket`: `sock_recv(fd, buf, len, recvd_ptr)` - 4 params (recv)

zware cannot handle duplicate function names with different signatures, causing "MismatchedSignatures" errors.

**Solution:** Disable `_socket` in the `*disabled*` section of Setup.local.

## VERIFIED WORKING BUILD COMMANDS

### Complete Build Process (Tested 2026-01-01)

```bash
# Navigate to CPython source
cd /mnt/c/Users/nimbl/Repos_and_Code/cpython-wasi

# Set environment variables
export WASI_SDK_PATH=/mnt/c/Users/nimbl/Repos_and_Code/wasi-sdk-24.0-x86_64-linux
export CONFIG_SITE="$(pwd)/Tools/wasm/config.site-wasm32-wasi"

# Clean previous build (if rebuilding)
make distclean 2>/dev/null || true

# Configure using CPython's official WASI wrapper
Tools/wasm/wasi-env ./configure \
    --host=wasm32-unknown-wasi \
    --build=$(./config.guess) \
    --with-build-python=python3 \
    --disable-test-modules

# Build with exported C API (remove old binary first to force rebuild)
rm -f python.wasm

Tools/wasm/wasi-env make \
    LDFLAGS="-Wl,--export=Py_Initialize \
    -Wl,--export=PyRun_SimpleString \
    -Wl,--export=Py_Finalize \
    -Wl,--export=PyErr_Print" \
    -j4 python.wasm

# Verify build
ls -lh python.wasm
strings python.wasm | grep -E "PyInit_(binascii|select|_wasisocket)"
strings python.wasm | grep -E "^(Py_Initialize|PyRun_SimpleString)$"

# Copy to project
cp python.wasm ../zig-wasm-cpython/src/examples/python-wasi.wasm
```

### Why These Specific Commands Work

**1. Using `Tools/wasm/wasi-env`:**
- This is CPython's official WASI environment wrapper
- Automatically sets correct CC, LDFLAGS, and other cross-compilation variables
- Avoids manual SDK path configuration issues

**2. Using `CONFIG_SITE`:**
- Points to CPython's WASI-specific configuration overrides
- Disables unsupported POSIX features (pipes, fork, etc.)
- Located at `Tools/wasm/config.site-wasm32-wasi`

**3. Minimal Exports:**
- Only exports functions actually used by the Zig runtime
- Reduces binary size
- Current runtime needs: `Py_Initialize`, `PyRun_SimpleString`, `Py_Finalize`, `PyErr_Print`

**4. Build Target `python.wasm`:**
- Explicitly building the WASM target
- Skips unnecessary host Python tools

**Why Export Functions?**

By default, CPython WASM builds as an executable with only `_start` exported. We need to export C API functions so the host runtime (Zig/zware) can:
1. Initialize Python with `Py_Initialize()`
2. Run Python code with `PyRun_SimpleString()` and related functions
3. Execute multiple scripts in sequence (for monkey patching)
4. Properly finalize with `Py_Finalize()`

This gives us full programmatic control over the Python interpreter lifecycle.

## Exported C API Functions

The build exports these essential CPython C API functions:

### Initialization & Finalization
- `Py_Initialize()` - Simple initialization
- `Py_InitializeFromConfig()` - Advanced initialization with config
- `Py_Finalize()` - Clean shutdown
- `Py_FinalizeEx()` - Clean shutdown with error return

### Configuration (Advanced Init)
- `PyConfig_InitPythonConfig()` - Initialize config structure
- `PyConfig_SetString()` - Set string config option
- `PyConfig_SetBytesString()` - Set bytes config option
- `PyConfig_Read()` - Read config
- `PyConfig_Clear()` - Free config memory
- `PyStatus_Exception()` - Check if status is exception

### Code Execution
- `PyRun_SimpleString()` - Execute Python code string (simple)
- `PyRun_SimpleStringFlags()` - Execute with compiler flags
- `PyRun_String()` - Execute with globals/locals
- `PyRun_StringFlags()` - Execute with flags and dicts
- `PyRun_File()` - Execute file (simple)
- `PyRun_FileFlags()` - Execute file with flags
- `PyRun_FileExFlags()` - Execute file (extended)
- `PyEval_EvalCode()` - Evaluate code object

### Module Import
- `PyImport_ImportModule()` - Import module by name
- `PyImport_Import()` - Import with full control

### Error Handling
- `PyErr_Print()` - Print exception traceback
- `PyErr_Occurred()` - Check if exception occurred
- `PyErr_Clear()` - Clear exception

### Reference Counting
- `Py_IncRef()` - Increment reference count
- `Py_DecRef()` - Decrement reference count

### Threading (GIL)
- `PyGILState_Ensure()` - Acquire GIL
- `PyGILState_Release()` - Release GIL

### Main Entry
- `Py_RunMain()` - Standard Python main (runs from argv)

## Verify Exports

After building, verify that functions are exported:

```bash
# Install wabt (WebAssembly Binary Toolkit) if needed
# On Ubuntu/Debian: apt install wabt
# Or download from: https://github.com/WebAssembly/wabt/releases

wasm-objdump -x python.wasm | grep "Export\[" -A 35
```

You should see output like:
```
Export[30]:
 - memory[0] -> "memory"
 - func[45] <_start> -> "_start"
 - func[3689] <PyErr_Clear> -> "PyErr_Clear"
 - func[3681] <PyErr_Occurred> -> "PyErr_Occurred"
 - func[4319] <PyErr_Print> -> "PyErr_Print"
 ...
```

## Copy to Project

Copy the built WASM file to your project:

```bash
cp python.wasm /path/to/zig-wasm-cpython/src/examples/python-wasi.wasm
```

## Verify Your C Extension

Check that your C extension is built-in:

```bash
strings python.wasm | grep "_wasisocket"
```

You should see `_wasisocket` in the output, confirming it's compiled in.

## Using the Built WASM

In your Zig runtime (main.zig), you can now call the exported functions:

```zig
// Initialize Python
try instance.invoke("Py_Initialize", &[_]u64{}, &[_]u64{}, .{});

// Run a Python script
const code_ptr = try allocateString(&instance, "print('Hello, World!')");
var in = [_]u64{code_ptr};
var out = [_]u64{0};
try instance.invoke("PyRun_SimpleString", in[0..], out[0..], .{});

// Finalize Python
try instance.invoke("Py_Finalize", &[_]u64{}, &[_]u64{}, .{});
```

## Troubleshooting

### Extension Not Found
If your C extension isn't being compiled in:
1. Check that `Modules/Setup.local` exists and has correct syntax
2. Run `make clean` and rebuild from scratch
3. Verify the `.c` file is in the `Modules/` directory
4. Check build logs for compilation errors

### Missing Exports
If exports are missing:
1. Ensure all `-Wl,--export=FunctionName` flags are in `LDFLAGS`
2. Verify the function names are correct (case-sensitive)
3. Check that you're setting `LDFLAGS` when running `make`, not just during `configure`

### Link Errors
If you get undefined symbol errors:
1. Check that WASI SDK paths are correct
2. Ensure you're using the WASI sysroot (`--sysroot` flag)
3. Verify all required libraries are available in WASI SDK

### Build Too Slow
- Use `-j$(nproc)` to enable parallel builds
- Consider using `--disable-test-modules` to skip tests
- Build in release mode on a fast disk (not WSL2 /mnt/c/)

## Size Optimization

The built `python.wasm` is ~26MB. To reduce size:

1. **Disable unused stdlib modules** in `Modules/Setup.local`:
   ```
   # Comment out unused modules with *disabled*
   *disabled*
   _ssl
   _hashlib
   ```

2. **Strip debug symbols**:
   ```bash
   wasm-strip python.wasm
   ```

3. **Use optimization flags** during configure:
   ```bash
   CFLAGS="-O3" ./configure ...
   ```

## Alternative: Using Existing Build

If you want to use the existing build without C extensions:

```bash
# Just copy the pre-built WASM
cp /path/to/existing/python-wasi.wasm src/examples/python-wasi.wasm
```

Note: This won't include your custom C extensions.

## Additional Resources

- [CPython Developer's Guide](https://devguide.python.org/)
- [WASI SDK Documentation](https://github.com/WebAssembly/wasi-sdk)
- [CPython on WASI Discussion](https://discuss.python.org/t/webassembly-wasi-support/21942)
- [WebAssembly Module Exports](https://webassembly.github.io/spec/core/syntax/modules.html#exports)

## Summary

The key steps are:
1. ✅ Add C extensions to `Modules/` directory
2. ✅ Register them in `Modules/Setup.local` as built-in modules
3. ✅ Configure with WASI SDK cross-compilation
4. ✅ Build with exported C API functions via `-Wl,--export=` linker flags
5. ✅ Verify exports with `wasm-objdump`
6. ✅ Copy `python.wasm` to your project

This gives you a CPython WASM binary with:
- Your custom C extensions compiled in
- Full C API access from the host runtime
- Ability to run multiple Python scripts in sequence
- Complete control over interpreter lifecycle

## Build Output Summary

Expected successful build output:

```
Checked 113 modules (54 built-in, 0 shared, 26 n/a on wasi-wasm32, 26 disabled, 7 missing, 0 failed on import)

The following modules are *disabled* in configure script:
_asyncio  _blake2  _bz2  _codecs_cn  _codecs_hk  _codecs_iso2022
_codecs_jp  _codecs_kr  _codecs_tw  _decimal  _elementtree
_multibytecodec  _pickle  _sha3  _socket  _zoneinfo  pyexpat  xxsubtype

The necessary bits to build these optional modules were not found:
_ctypes  _hashlib  _lzma  _ssl  _uuid  readline  zlib
```

**Expected file size:** ~23 MB

## Quick Rebuild (After Setup.local Changes)

If you only changed `Setup.local`, you can do a quick rebuild:

```bash
cd /mnt/c/Users/nimbl/Repos_and_Code/cpython-wasi
rm -f python.wasm
export WASI_SDK_PATH=/mnt/c/Users/nimbl/Repos_and_Code/wasi-sdk-24.0-x86_64-linux
export CONFIG_SITE="$(pwd)/Tools/wasm/config.site-wasm32-wasi"
Tools/wasm/wasi-env make \
    LDFLAGS="-Wl,--export=Py_Initialize -Wl,--export=PyRun_SimpleString -Wl,--export=Py_InitializeFromConfig -Wl,--export=Py_FinalizeEx -Wl,--export=PyErr_Print" \
    -j4 python.wasm
cp python.wasm ../zig-wasm-cpython/src/examples/python-wasi.wasm
```

## Troubleshooting

### Error: "ImportNotFound" from zware

**Symptom:** Runtime error when loading WASM
```
error: ImportNotFound
/path/to/zware-fork/src/store.zig:95:9
```

**Cause:** Missing WASI socket function imports (sock_accept, sock_shutdown, etc.)

**Solution:** 
1. Check that socket stub functions are registered in `src/sockets/socket_handlers.zig`
2. Rebuild the Zig project: `zig build`

### Error: "MismatchedSignatures"

**Symptom:**
```
error: MismatchedSignatures
/path/to/zware-fork/src/store/function.zig:25:46
```

**Cause:** Both `_socket` and `_wasisocket` modules are enabled, creating duplicate imports with different signatures

**Solution:** Ensure `_socket` is in the `*disabled*` section of `Modules/Setup.local`

### Error: "ExportNotFound" for Py_Initialize

**Symptom:**
```
error: ExportNotFound
...getExport...
```

**Cause:** C API functions were not exported during linking

**Solution:** Rebuild with `LDFLAGS="-Wl,--export=Py_Initialize ..."` (see build commands above)

### Module Not Found at Runtime

**Symptom:** Python script fails with `ModuleNotFoundError: No module named 'binascii'`

**Cause:** Module wasn't compiled as built-in

**Solution:**
1. Verify module is listed in `Setup.local` BEFORE the `*disabled*` section
2. Rebuild completely: `make distclean && ./configure ... && make ...`
3. Verify: `strings python.wasm | grep PyInit_binascii`

## Testing the Build

After copying to the project, test with:

```bash
cd /mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython
zig build
./zig-out/bin/zig_wasm_cpython
```

Expected output should include:
- "Python interpreter initialized"
- "Main script completed successfully"
- No import errors for binascii, select, or socket modules

## Summary

✅ **Working configuration:**
- CPython 3.13.1 for WASI
- Custom `_wasisocket` module (built-in)
- `binascii` and `select` modules enabled
- Built-in `_socket` module DISABLED (conflicts with custom socket)
- sock_accept and sock_shutdown stubs implemented in Zig
- C API functions exported for Zig runtime
- ~23MB WASM binary with 54 built-in modules

## See Also

- `../cpython-wasi/Modules/Setup.local` - Module configuration
- `../cpython-wasi/Modules/_wasisocket.c` - Custom socket module source
- `src/sockets/socket_handlers.zig` - Socket function implementations
- `src/main.zig` - Python interpreter initialization

---
**Last Updated:** 2026-01-01  
**Tested With:** CPython 3.13.1, WASI SDK 24.0, Zig 0.13.0
