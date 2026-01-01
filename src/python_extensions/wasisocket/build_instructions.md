# Building the WASI Socket Extension for CPython

This guide explains how to compile the `_wasisocket` C extension as part of CPython WASI.

## Prerequisites

- **WASI SDK**: Version 24.0 or later
- **CPython source**: Version 3.13.1 (as used in your project)
- **Build tools**: make, clang

## Directory Structure

```
cpython/
├── Modules/
│   ├── _wasisocket.c          ← Add this file
│   ├── Setup.local            ← Add/modify this
│   └── ...
└── Lib/
    └── wasisocket.py          ← Add this file
```

## Step 1: Copy Extension Files

```bash
# Set paths
CPYTHON_DIR="/mnt/c/Users/nimbl/Repos_and_Code/cpython-wasi"
EXTENSION_DIR="/mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython/python_extension"

# Copy C extension to Modules/
cp "$EXTENSION_DIR/_wasisocket.c" "$CPYTHON_DIR/Modules/"

# Copy Python wrapper to Lib/
cp "$EXTENSION_DIR/wasisocket.py" "$CPYTHON_DIR/Lib/"
```

## Step 2: Configure Module Build

### Option A: Using Setup.local (Recommended)

```bash
cd "$CPYTHON_DIR"

# Add to Modules/Setup.local
echo "_wasisocket _wasisocket.c" >> Modules/Setup.local
```

### Option B: Using configure

```bash
cd "$CPYTHON_DIR"

# Add to configure options
./configure --host=wasm32-wasi \
    --with-build-python=/usr/bin/python3 \
    --with-c-locale-coercion \
    --without-pymalloc \
    --disable-ipv6 \
    --enable-wasm-dynamic-linking=no \
    MODULE__WASISOCKET=yes
```

## Step 3: Build CPython WASI

```bash
cd "$CPYTHON_DIR"

# Set WASI SDK path
export WASI_SDK_PATH="/mnt/c/Users/nimbl/Repos_and_Code/wasi-sdk-24.0-x86_64-linux"
export PATH="$WASI_SDK_PATH/bin:$PATH"

# Configure (if not already done)
./configure \
    --host=wasm32-wasi \
    --build=$(./config.guess) \
    --with-build-python=$(which python3) \
    --prefix=/usr/local \
    CC="${WASI_SDK_PATH}/bin/clang" \
    CFLAGS="--sysroot=${WASI_SDK_PATH}/share/wasi-sysroot" \
    LDFLAGS="--sysroot=${WASI_SDK_PATH}/share/wasi-sysroot"

# Build
make -j$(nproc)
```

## Step 4: Verify Build

```bash
# Check if _wasisocket was built
ls -la build/lib.wasi-wasm32-3.13/_wasisocket*.so 2>/dev/null || \
    echo "Extension built as static module (expected for WASI)"

# Check the WASM binary for imports
wasm-objdump -x python.wasm | grep sock_

# Should see:
# - import sock_open
# - import sock_resolve  
# - import sock_connect
# - import sock_send
# - import sock_recv
# - import sock_close
```

## Step 5: Extract WASM Binary

```bash
cd "$CPYTHON_DIR"

# The WASM binary location depends on build configuration
# Common locations:
ls python.wasm
ls Programs/python.wasm  
ls build/*/python.wasm

# Copy to zig-wasm-cpython project
cp python.wasm /mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython/src/examples/python-wasi.wasm
```

## Step 6: Update zig-wasm-cpython

The extension requires no changes to the Zig runtime - the socket functions are already registered!

Just rebuild with the new Python WASM:

```bash
cd /mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython
zig build
```

## Step 7: Test

```bash
# Copy test script to VFS
cp python_extension/test_wasisocket.py .

# Update main.zig to load test_wasisocket.py instead of demo_bytecode.py

# Build and run
zig build && ./zig-out/bin/zig_wasm_cpython
```

## Troubleshooting

### Module not found

If Python can't find `_wasisocket`:

```python
import sys
print(sys.builtin_module_names)  # Should include '_wasisocket'
```

If not included, check that:
1. `Setup.local` was updated
2. `make clean && make` was run
3. Module compiled without errors

### Import errors in WASM

If you see "undefined symbol" errors:

```bash
# Verify WASI imports are declared
wasm-objdump -x python.wasm | grep "import.*sock_"

# Should show imports from "wasi_snapshot_preview1" module
```

### Linker errors

If you get undefined reference errors during link:

- The WASI functions are **imports**, not definitions
- They're provided by the WASM runtime (zig-wasm-cpython)
- No linking is needed - just import declarations

### Runtime errors

If socket functions fail at runtime:

1. Check that zig-wasm-cpython has socket functions registered
2. Verify socket handler initialization in main.zig
3. Enable debug mode to see WASI calls

## Advanced: Custom Build Script

For automation, create `build_wasi_extension.sh`:

```bash
#!/bin/bash
set -e

CPYTHON_DIR="/mnt/c/Users/nimbl/Repos_and_Code/cpython-wasi"
EXTENSION_DIR="/mnt/c/Users/nimbl/Repos_and_Code/zig-wasm-cpython/python_extension"
WASI_SDK="/mnt/c/Users/nimbl/Repos_and_Code/wasi-sdk-24.0-x86_64-linux"

echo "Building CPython WASI with socket extension..."

# Copy files
cp "$EXTENSION_DIR/_wasisocket.c" "$CPYTHON_DIR/Modules/"
cp "$EXTENSION_DIR/wasisocket.py" "$CPYTHON_DIR/Lib/"

# Update Setup.local
if ! grep -q "_wasisocket" "$CPYTHON_DIR/Modules/Setup.local" 2>/dev/null; then
    echo "_wasisocket _wasisocket.c" >> "$CPYTHON_DIR/Modules/Setup.local"
fi

# Build
cd "$CPYTHON_DIR"
make clean
make -j$(nproc) \
    CC="$WASI_SDK/bin/clang" \
    CFLAGS="--sysroot=$WASI_SDK/share/wasi-sysroot"

echo "Build complete!"
echo "WASM binary: $CPYTHON_DIR/python.wasm"
```

## Next Steps

After successful build:

1. **Test the extension**: Run `test_wasisocket.py`
2. **Update HANDOFF.md**: Document the extension
3. **Create examples**: Write socket usage examples
4. **Performance tuning**: Optimize buffer sizes
5. **Error handling**: Improve error messages

## References

- [CPython Build Instructions](https://devguide.python.org/getting-started/setup-building/)
- [WASI SDK Documentation](https://github.com/WebAssembly/wasi-sdk)
- [Python C Extension Guide](https://docs.python.org/3/extending/extending.html)
- [zig-wasm-cpython SOCKET_API.md](../SOCKET_API.md)
