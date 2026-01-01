# Socket WASI Extensions

This document describes the custom WASI socket extensions implemented for the zig-wasm-cpython runtime.

## Overview

The socket extensions add network connectivity to WASM Python by providing custom WASI functions in the `wasi_snapshot_preview1` namespace. These functions follow the design principles of the wasi-sockets proposal but are implemented for WASI Preview 1 compatibility.

## Architecture

```
┌─────────────────────────────────────────┐
│   Python WASM (CPython 3.13.1 WASI)   │
│                                         │
│  ┌─────────────────────────────────┐   │
│  │   Python socket module          │   │
│  │   (needs monkey patching)       │   │
│  └───────────┬─────────────────────┘   │
│              │                          │
│  ┌───────────▼─────────────────────┐   │
│  │   WASI sock_* imports           │   │
│  └───────────┬─────────────────────┘   │
└──────────────┼──────────────────────────┘
               │ WASM/WASI boundary
┌──────────────▼──────────────────────────┐
│   Zig Host Runtime (zware)              │
│                                          │
│  ┌────────────────────────────────────┐ │
│  │  Socket Handlers                   │ │
│  │  (src/sockets/socket_handlers.zig)│ │
│  └─────────┬──────────────────────────┘ │
│            │                             │
│  ┌─────────▼──────────────────────────┐ │
│  │  Socket Implementation             │ │
│  │  (src/sockets/socket.zig)          │ │
│  │  - Uses Zig std.net                │ │
│  │  - Real TCP/UDP sockets            │ │
│  │  - DNS resolution                  │ │
│  └────────────────────────────────────┘ │
└─────────────────────────────────────────┘
```

## WASI Socket Functions

All functions are exposed in the `wasi_snapshot_preview1` module namespace.

### sock_open

Create a new socket.

```c
i32 sock_open(i32 af, i32 socktype, i32* fd_ptr)
```

**Parameters:**
- `af`: Address family (2 = IPv4, 10 = IPv6)
- `socktype`: Socket type (1 = STREAM/TCP, 2 = DGRAM/UDP)
- `fd_ptr`: Pointer to write the socket handle

**Returns:** 0 on success, error code otherwise

**Errors:**
- 97 (EAFNOSUPPORT): Unsupported address family
- 91 (EPROTOTYPE): Unsupported socket type
- 22 (EINVAL): Invalid parameters

### sock_resolve

Resolve a hostname to IP addresses (DNS lookup).

```c
i32 sock_resolve(
    i32 hostname_ptr,
    i32 hostname_len,
    i32 port,
    i32 addrs_ptr,
    i32 addrs_len,
    i32* count_ptr
)
```

**Parameters:**
- `hostname_ptr`: Pointer to hostname string
- `hostname_len`: Length of hostname string
- `port`: Port number (0-65535)
- `addrs_ptr`: Pointer to array of address structures
- `addrs_len`: Maximum number of addresses to return
- `count_ptr`: Pointer to write actual count of addresses

**Address Structure (19 bytes):**
```
Offset  Size  Field
0       1     family (2=IPv4, 10=IPv6)
1       2     port (big-endian u16)
3       16    address (4 bytes IPv4 or 16 bytes IPv6)
```

**Returns:** 0 on success, error code otherwise

**Errors:**
- 113 (EHOSTUNREACH): Host not found
- 101 (ENETUNREACH): Network unreachable
- 22 (EINVAL): Invalid parameters

### sock_connect

Connect a socket to a remote address.

```c
i32 sock_connect(i32 sock_fd, i32 addr_ptr)
```

**Parameters:**
- `sock_fd`: Socket handle from sock_open
- `addr_ptr`: Pointer to address structure (19 bytes)

**Returns:** 0 on success, error code otherwise

**Errors:**
- 111 (ECONNREFUSED): Connection refused
- 110 (ETIMEDOUT): Connection timed out
- 107 (ENOTCONN): Socket not connected
- 9 (EBADF): Invalid socket handle

### sock_send

Send data on a connected socket.

```c
i32 sock_send(i32 sock_fd, i32 buf_ptr, i32 buf_len, i32* sent_ptr)
```

**Parameters:**
- `sock_fd`: Socket handle
- `buf_ptr`: Pointer to data buffer
- `buf_len`: Number of bytes to send
- `sent_ptr`: Pointer to write number of bytes actually sent

**Returns:** 0 on success, error code otherwise

**Errors:**
- 107 (ENOTCONN): Socket not connected
- 104 (ECONNRESET): Connection reset by peer
- 9 (EBADF): Invalid socket handle

### sock_recv

Receive data from a connected socket.

```c
i32 sock_recv(i32 sock_fd, i32 buf_ptr, i32 buf_len, i32* recvd_ptr)
```

**Parameters:**
- `sock_fd`: Socket handle
- `buf_ptr`: Pointer to buffer for received data
- `buf_len`: Size of buffer
- `recvd_ptr`: Pointer to write number of bytes actually received

**Returns:** 0 on success, error code otherwise

**Errors:**
- 107 (ENOTCONN): Socket not connected
- 104 (ECONNRESET): Connection reset by peer
- 9 (EBADF): Invalid socket handle

### sock_close

Close a socket.

```c
i32 sock_close(i32 sock_fd)
```

**Parameters:**
- `sock_fd`: Socket handle to close

**Returns:** 0 on success, error code otherwise

## Error Codes

All socket functions return POSIX-compatible errno values:

| Code | Name | Description |
|------|------|-------------|
| 0 | SUCCESS | Operation succeeded |
| 9 | EBADF | Bad file descriptor |
| 11 | EAGAIN/EWOULDBLOCK | Resource temporarily unavailable |
| 13 | EACCES | Permission denied |
| 22 | EINVAL | Invalid argument |
| 88 | ENOTSOCK | Not a socket |
| 91 | EPROTOTYPE | Protocol wrong type for socket |
| 93 | EPROTONOSUPPORT | Protocol not supported |
| 95 | EOPNOTSUPP | Operation not supported |
| 97 | EAFNOSUPPORT | Address family not supported |
| 98 | EADDRINUSE | Address already in use |
| 99 | EADDRNOTAVAIL | Address not available |
| 100 | ENETDOWN | Network is down |
| 101 | ENETUNREACH | Network unreachable |
| 103 | ECONNABORTED | Connection aborted |
| 104 | ECONNRESET | Connection reset by peer |
| 107 | ENOTCONN | Socket not connected |
| 110 | ETIMEDOUT | Connection timed out |
| 111 | ECONNREFUSED | Connection refused |
| 113 | EHOSTUNREACH | Host unreachable |

## Python Integration

To use these socket functions from Python, you need to:

1. **Import WASI functions** (from the WASM runtime)
2. **Create Python socket wrapper** (monkey patch Python's socket module)
3. **Use standard Python socket API** (the wrapper handles WASI calls)

### Example: Low-Level WASI Socket Usage

```python
import ctypes

# Load WASI socket functions (implementation depends on your WASM runtime)
# This is pseudocode - actual implementation varies
class WasiSocket:
    def __init__(self):
        self.sock_open = load_wasi_func("sock_open")
        self.sock_resolve = load_wasi_func("sock_resolve")
        self.sock_connect = load_wasi_func("sock_connect")
        self.sock_send = load_wasi_func("sock_send")
        self.sock_recv = load_wasi_func("sock_recv")
        self.sock_close = load_wasi_func("sock_close")
    
    def create_socket(self, family=2, socktype=1):
        """Create a TCP/IP socket"""
        fd = ctypes.c_uint32()
        err = self.sock_open(family, socktype, ctypes.byref(fd))
        if err != 0:
            raise OSError(err, "sock_open failed")
        return fd.value
    
    def resolve(self, hostname, port):
        """Resolve hostname to IP addresses"""
        hostname_bytes = hostname.encode('utf-8')
        addrs = (ctypes.c_uint8 * (19 * 10))()  # Max 10 addresses
        count = ctypes.c_uint32()
        
        err = self.sock_resolve(
            hostname_bytes, len(hostname_bytes), port,
            addrs, 10, ctypes.byref(count)
        )
        if err != 0:
            raise OSError(err, "sock_resolve failed")
        
        # Parse addresses...
        return parsed_addresses
```

### Next Steps

The next phase of development will create:
1. **Python socket module wrapper** - Monkey patch Python's `socket` module to use WASI functions
2. **ctypes FFI bindings** - Proper bindings for calling WASI functions from Python
3. **impacket compatibility layer** - Ensure impacket's SMB/LDAP/RPC protocols work over WASI sockets

## Implementation Details

### Socket Table

The Zig host maintains a global socket table that maps socket handles (u32) to actual socket objects. Socket handles start at 1000 to avoid conflicts with regular file descriptors.

### Thread Safety

The socket table uses a mutex for thread-safe access, allowing concurrent socket operations from multiple WASM instances.

### Memory Management

- Socket handles are managed by the host (Zig runtime)
- WASM memory is accessed directly for passing data
- DNS results are temporarily allocated and freed after copying to WASM memory

### DNS Resolution

DNS resolution uses Zig's `std.net.getAddressList()`, which:
- Resolves both IPv4 and IPv6 addresses
- Uses the system's DNS resolver
- Returns multiple addresses if available

### Connection Management

Sockets maintain state tracking:
- `unbound`: Initial state after creation
- `bound`: After bind() (for servers)
- `listening`: After listen() (for servers)
- `connecting`: During async connect (not yet implemented)
- `connected`: After successful connect
- `closed`: After close()

## Limitations

Current implementation limitations:

1. **No async/non-blocking support** - All operations are blocking
2. **No UDP support** - Only TCP sockets implemented
3. **No server sockets (bind/listen/accept)** - Client sockets only
4. **No socket options** - setsockopt/getsockopt not implemented
5. **No TLS/SSL** - Plain TCP only

These can be added in future iterations as needed.

## Testing

See `test_socket.py` for example usage demonstrating the socket API structure.

To run tests:
```bash
zig build run
```

## Future Enhancements

Planned improvements:

1. **Python socket module monkey patch** - Full Python `socket` module compatibility
2. **Async socket support** - Non-blocking I/O with `start_*` / `finish_*` pattern
3. **UDP sockets** - Datagram protocol support
4. **Server sockets** - bind(), listen(), accept() for server applications
5. **Socket options** - setsockopt(), getsockopt() for tuning
6. **TLS/SSL** - Secure connections (possibly via Python's ssl module)
7. **WASI Preview 2 migration** - When zware supports it, migrate to standard wasi-sockets
