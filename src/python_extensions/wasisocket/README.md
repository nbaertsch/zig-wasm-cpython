# WASI Socket Python Extension

This directory contains a Python C extension that wraps the custom WASI socket functions implemented in the zig-wasm-cpython runtime.

## Files

- **`_wasisocket.c`** - C extension module (low-level interface)
- **`wasisocket.py`** - Python wrapper module (high-level interface)
- **`Setup.local`** - CPython build configuration
- **`test_wasisocket.py`** - Test suite
- **`build_instructions.md`** - Detailed build instructions

## Architecture

```
┌─────────────────────────────────────────┐
│   Python Application                    │
│                                         │
│   import wasisocket                     │
│   sock = wasisocket.Socket(...)        │
└─────────────┬───────────────────────────┘
              │
┌─────────────▼───────────────────────────┐
│   wasisocket.py (High-level wrapper)    │
│   - Socket class                        │
│   - Familiar API                        │
│   - Error handling                      │
└─────────────┬───────────────────────────┘
              │
┌─────────────▼───────────────────────────┐
│   _wasisocket.c (C Extension)           │
│   - PyArg_ParseTuple                    │
│   - WASI function imports               │
│   - Python object conversion            │
└─────────────┬───────────────────────────┘
              │ WASM import declarations
┌─────────────▼───────────────────────────┐
│   WASM Runtime (zig-wasm-cpython)       │
│   - sock_open, sock_connect, etc.      │
│   - Zig std.net implementation          │
│   - Real TCP/UDP sockets                │
└─────────────────────────────────────────┘
```

## API Overview

### Low-level API (`_wasisocket`)

Direct C function bindings:

```python
import _wasisocket

# Create socket
fd = _wasisocket.sock_open(AF_INET, SOCK_STREAM)

# Resolve hostname
addrs = _wasisocket.sock_resolve('example.com', 80)
# Returns: [(family, port, addr_bytes), ...]

# Connect
family, port, addr_bytes = addrs[0]
_wasisocket.sock_connect(fd, family, port, addr_bytes)

# Send/Receive
sent = _wasisocket.sock_send(fd, b'data')
data = _wasisocket.sock_recv(fd, 4096)

# Close
_wasisocket.sock_close(fd)
```

### High-level API (`wasisocket`)

Pythonic socket interface:

```python
import wasisocket

# Context manager (automatic cleanup)
with wasisocket.Socket() as sock:
    sock.connect(('example.com', 80))
    sock.send(b'GET / HTTP/1.1\r\n...')
    response = sock.recv(4096)

# Or manual management
sock = wasisocket.Socket(wasisocket.AF_INET, wasisocket.SOCK_STREAM)
sock.connect(('google.com', 80))
sock.sendall(request)
data = sock.recv(1024)
sock.close()

# Convenience function
sock = wasisocket.create_connection(('example.com', 80))
```

## Building

### Option 1: Add to CPython WASI Build

1. Copy `_wasisocket.c` to CPython's `Modules/` directory:
   ```bash
   cp _wasisocket.c /path/to/cpython/Modules/
   ```

2. Add to `Modules/Setup.local`:
   ```bash
   echo "_wasisocket _wasisocket.c" >> /path/to/cpython/Modules/Setup.local
   ```

3. Rebuild CPython WASI:
   ```bash
   cd /path/to/cpython
   make clean
   make -j$(nproc)
   ```

### Option 2: Manual Configuration

Add this to `pyconfig.h` or configure with:
```bash
./configure --host=wasm32-wasi \
    --with-build-python=/usr/bin/python3 \
    --enable-wasm-dynamic-linking=no
```

## Installation

After building CPython with the extension:

1. Copy `wasisocket.py` to your Python library path:
   ```bash
   cp wasisocket.py /path/to/python/lib/python3.13/
   ```

2. Or include it in your VFS when loading into zig-wasm-cpython

## Usage Examples

### HTTP GET Request

```python
import wasisocket

sock = wasisocket.Socket()
sock.connect(('example.com', 80))

request = b"""GET / HTTP/1.1
Host: example.com
Connection: close

"""

sock.sendall(request)

response = b''
while True:
    chunk = sock.recv(4096)
    if not chunk:
        break
    response += chunk

sock.close()

print(response.decode('utf-8'))
```

### Multiple Addresses

```python
import wasisocket

# Get all addresses for a hostname
addrs = wasisocket.getaddrinfo('google.com', 80)

for family, port, addr_bytes in addrs:
    if family == wasisocket.AF_INET:
        # Convert bytes to IP string
        ip = '.'.join(str(b) for b in addr_bytes)
        print(f"IPv4: {ip}:{port}")
    elif family == wasisocket.AF_INET6:
        print(f"IPv6: {addr_bytes.hex()}:{port}")
```

### Error Handling

```python
import wasisocket

try:
    sock = wasisocket.Socket()
    sock.connect(('nonexistent.invalid', 80))
except wasisocket.SocketError as e:
    print(f"Connection failed: {e}")
except OSError as e:
    print(f"OS error: {e}")
finally:
    sock.close()
```

## Testing

Run the test suite:

```bash
# From Python WASM
python3 test_wasisocket.py

# Or from zig-wasm-cpython runtime
./zig-out/bin/zig_wasm_cpython test_wasisocket.py
```

## Limitations

Current implementation:

- **Blocking sockets only** - No async/non-blocking support yet
- **TCP only** - UDP (SOCK_DGRAM) not fully tested
- **No socket options** - setsockopt/getsockopt not implemented
- **IPv4 preferred** - IPv6 works but always tries IPv4 first
- **No server sockets** - bind/listen/accept not yet implemented

## Future Enhancements

Planned features:

1. **Non-blocking sockets** - Add support for O_NONBLOCK
2. **Socket options** - Implement setsockopt/getsockopt
3. **Server support** - Add bind/listen/accept
4. **SSL/TLS** - Wrap Python's ssl module
5. **Better error handling** - More specific exception types
6. **IPv6 priority** - Happy Eyeballs algorithm
7. **Timeout support** - Add socket timeout functionality

## Debugging

Enable debug output:

```python
import _wasisocket
import sys

# The C extension will print debug info to stderr
sys.stderr.write("Debug mode enabled\n")
```

Check WASI imports:

```bash
# Inspect the WASM module
wasm-objdump -x python.wasm | grep sock_
```

## Contributing

When modifying the C extension:

1. Update both `_wasisocket.c` and `wasisocket.py`
2. Add tests to `test_wasisocket.py`
3. Update this README
4. Test in the zig-wasm-cpython runtime

## License

Same as CPython (PSF License) and zig-wasm-cpython project.
