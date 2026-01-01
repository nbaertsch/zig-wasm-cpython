"""
Socket Monkey Patch for Python WASM

This module monkey patches the built-in _socket C extension with our custom
_wasisocket implementation. This allows Python's standard socket.py module
to work with our WASM socket implementation while keeping all the high-level
logic, exception classes, and compatibility features from the standard library.

CRITICAL: This must be executed BEFORE any module that imports socket!
"""

import sys

# Import our custom C extension
import _wasisocket

# Create a wrapper class that mimics _socket.socket
class socket:
    """Socket wrapper that uses _wasisocket low-level functions"""
    __slots__ = ['_fd', '_family', '_type', '_proto', '_connected']
    
    def __init__(self, family=-1, type=-1, proto=-1, fileno=None):
        if family == -1:
            family = _wasisocket.AF_INET
        if type == -1:
            type = _wasisocket.SOCK_STREAM
        if proto == -1:
            proto = 0
        self._family = family
        self._type = type
        self._proto = proto
        self._fd = _wasisocket.sock_open(family, type) if fileno is None else fileno
        self._connected = False
    
    def __enter__(self):
        return self
    
    def __exit__(self, *args):
        self.close()
    
    def accept(self):
        raise OSError("accept not implemented in WASI")
    
    def bind(self, address):
        raise OSError("bind not implemented in WASI")
    
    def close(self):
        if hasattr(self, '_fd') and self._fd is not None:
            _wasisocket.sock_close(self._fd)
            self._fd = None
            self._connected = False
    
    def connect(self, address):
        hostname, port = address
        # Resolve hostname
        addrs = _wasisocket.sock_resolve(hostname, port)
        if not addrs:
            raise _wasisocket.gaierror(f"Cannot resolve hostname: {hostname}")
        family, resolved_port, addr_bytes = addrs[0]
        _wasisocket.sock_connect(self._fd, family, resolved_port, addr_bytes)
        self._connected = True
    
    def connect_ex(self, address):
        try:
            self.connect(address)
            return 0
        except OSError as e:
            return e.errno if hasattr(e, 'errno') else 1
    
    def fileno(self):
        return self._fd if self._fd is not None else -1
    
    def getpeername(self):
        raise OSError("getpeername not implemented in WASI")
    
    def getsockname(self):
        raise OSError("getsockname not implemented in WASI")
    
    def getsockopt(self, level, optname, buflen=None):
        # Return dummy values for common options
        return 0
    
    def listen(self, backlog=None):
        raise OSError("listen not implemented in WASI")
    
    def recv(self, bufsize, flags=0):
        return _wasisocket.sock_recv(self._fd, bufsize)
    
    def recvfrom(self, bufsize, flags=0):
        data = _wasisocket.sock_recv(self._fd, bufsize)
        return (data, None)
    
    def recvfrom_into(self, buffer, nbytes=0, flags=0):
        raise OSError("recvfrom_into not implemented in WASI")
    
    def recv_into(self, buffer, nbytes=0, flags=0):
        if nbytes == 0:
            nbytes = len(buffer)
        data = _wasisocket.sock_recv(self._fd, nbytes)
        n = len(data)
        buffer[:n] = data
        return n
    
    def send(self, data, flags=0):
        return _wasisocket.sock_send(self._fd, data)
    
    def sendall(self, data, flags=0):
        total_sent = 0
        data_len = len(data)
        while total_sent < data_len:
            sent = _wasisocket.sock_send(self._fd, data[total_sent:])
            if sent == 0:
                raise OSError("Connection closed during send")
            total_sent += sent
    
    def sendto(self, data, address):
        raise OSError("sendto not implemented in WASI")
    
    def setblocking(self, flag):
        # Ignore for now
        pass
    
    def settimeout(self, value):
        # Ignore for now
        pass
    
    def gettimeout(self):
        return None
    
    def setsockopt(self, level, optname, value):
        # Ignore for now
        pass
    
    def shutdown(self, how):
        # Ignore for now
        pass
    
    @property
    def family(self):
        return self._family
    
    @property
    def type(self):
        return self._type
    
    @property
    def proto(self):
        return self._proto

# Replace _socket with our implementation in sys.modules
_wasisocket.socket = socket

# Add exception classes
if not hasattr(_wasisocket, 'error'):
    _wasisocket.error = OSError

if not hasattr(_wasisocket, 'timeout'):
    class timeout(OSError):
        pass
    _wasisocket.timeout = timeout

if not hasattr(_wasisocket, 'gaierror'):
    class gaierror(OSError):
        pass
    _wasisocket.gaierror = gaierror

if not hasattr(_wasisocket, 'herror'):
    class herror(OSError):
        pass
    _wasisocket.herror = herror

# Add socket option constants if missing
if not hasattr(_wasisocket, 'SOL_SOCKET'):
    _wasisocket.SOL_SOCKET = 1
    _wasisocket.SO_REUSEADDR = 2
    _wasisocket.SO_KEEPALIVE = 9
    _wasisocket.IPPROTO_TCP = 6
    _wasisocket.TCP_NODELAY = 1

# Add timeout defaults
if not hasattr(_wasisocket, 'getdefaulttimeout'):
    _default_timeout = None
    
    def getdefaulttimeout():
        return _default_timeout
    
    def setdefaulttimeout(timeout_val):
        global _default_timeout
        _default_timeout = timeout_val
    
    _wasisocket.getdefaulttimeout = getdefaulttimeout
    _wasisocket.setdefaulttimeout = setdefaulttimeout

# Add getaddrinfo if missing
if not hasattr(_wasisocket, 'getaddrinfo'):
    def getaddrinfo(host, port, family=0, type=0, proto=0, flags=0):
        # Simple implementation that returns a single result
        return [(family or _wasisocket.AF_INET, type or _wasisocket.SOCK_STREAM, proto, '', (host, port))]
    _wasisocket.getaddrinfo = getaddrinfo

# Add has_ipv6 attribute
if not hasattr(_wasisocket, 'has_ipv6'):
    # WASI doesn't support IPv6 yet
    _wasisocket.has_ipv6 = False

# Replace _socket module
sys.modules['_socket'] = _wasisocket

print("[PATCH] _socket module replaced with _wasisocket")
print(f"[PATCH]   _socket -> {_wasisocket}")
print("[PATCH] Python's standard socket.py will now use WASI sockets")


